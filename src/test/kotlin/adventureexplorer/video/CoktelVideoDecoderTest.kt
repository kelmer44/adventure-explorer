package adventureexplorer.video

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class CoktelVideoDecoderTest {
    private fun vmd(): ByteArray {
        // A keyframe, then a sparse delta at nonzero screen coordinates and a palette update.
        val table = 816
        val payload = table + 2 * (6 + 16)
        val b = ByteBuffer.allocate(payload + 5 + 773).order(ByteOrder.LITTLE_ENDIAN)
        b.putShort(814); b.putShort(0); b.putShort(1); b.putShort(2)
        b.putShort(30); b.putShort(40); b.putShort(2); b.putShort(2)
        b.putShort(0); b.putShort(1); b.putInt(payload); b.putInt(0)
        b.put(byteArrayOf(0, 0, 0, 63, 0, 0, 0, 63, 0, 0, 0, 63))
        b.position(812); b.putInt(table)
        b.putShort(0); b.putInt(payload); b.putShort(0); b.putInt(payload + 5)
        fun part(size: Int, x: Int, y: Int, right: Int, bottom: Int, flags: Int) {
            b.put(2); b.put(0); b.putInt(size)
            b.putShort(x.toShort()); b.putShort(y.toShort()); b.putShort(right.toShort()); b.putShort(bottom.toShort())
            b.put(0); b.put(flags.toByte())
        }
        part(5, 30, 40, 31, 41, 0)
        part(773, 31, 41, 31, 41, 2)
        b.put(byteArrayOf(2, 1, 2, 3, 1))
        val next = b.position()
        b.put(2); b.put(0); b.put(byteArrayOf(63, 63, 0))
        b.position(next + 770); b.put(byteArrayOf(1, 128.toByte(), 2))
        return b.array()
    }

    @Test fun `VMD keeps delta pixels and applies palette changes at nonzero origins`() {
        val clip = CoktelVideoDecoder.decode(vmd())!!
        assertEquals(2, clip.frames.size)
        assertEquals(0xFC0000, clip.frames[0].getRGB(0, 0) and 0xFFFFFF)
        assertEquals(0x00FC00, clip.frames[0].getRGB(1, 0) and 0xFFFFFF)
        assertEquals(0xFCFC00, clip.frames[1].getRGB(1, 0) and 0xFFFFFF)
        assertEquals(0xFC0000, clip.frames[1].getRGB(0, 0) and 0xFFFFFF)
        assertEquals(0xFCFC00, clip.frames[1].getRGB(1, 1) and 0xFFFFFF)
        val late = CoktelVideoDecoder.decode(vmd(), 1, 1)!!
        assertEquals(clip.frames[1].getRGB(0, 1), late.frames.single().getRGB(0, 1))
    }

    @Test fun `truncated movies and invalid frame ranges fail cleanly`() {
        assertNull(CoktelVideoDecoder.decode(vmd().copyOf(830)))
        assertNull(CoktelVideoDecoder.decode(vmd(), 2, 1))
        assertNull(CoktelVideoDecoder.decode(vmd(), 0, 257))
    }

    @Test fun `extended LZSS supports overlapping runs and rejects truncation`() {
        val data = byteArrayOf(20, 0, 0, 0, 0x34, 0x12, 0x78, 0x56, 1, 7, 0x11, 0x1F, 1)
        assertArrayEquals(ByteArray(20) { 7 }, CoktelVideoDecoder.unpack(data))
        assertTrue(runCatching { CoktelVideoDecoder.unpack(data.copyOf(11)) }.isFailure)
    }
    @Test fun `unused VMD descriptors may contain arbitrary size bytes`() {
        val bytes = vmd()
        val part = 816 + 12 + 16
        bytes[part] = 0
        repeat(4) { bytes[part + 2 + it] = 255.toByte() }
        val clip = CoktelVideoDecoder.decode(bytes)!!
        assertEquals(clip.frames[0].getRGB(1, 1), clip.frames[1].getRGB(1, 1))
    }
    @Test fun `early Fascination IMD inherits dimensions and palette and retains delta holes`() {
        val data = byteArrayOf(2, 0, 5, 0, 2, 1, 2, 3, 4, 0, 0,
            5, 0, 1, 0, 128.toByte(), 4, 1, 0, 0)
        val colors = IntArray(256) { it * 0x010101 }
        val clip = CoktelVideoDecoder.decodePreImd(data, 2, 2, colors, 0, 2)!!
        assertEquals(0x010101, clip.frames[1].getRGB(0, 0) and 0xFFFFFF)
        assertEquals(0x040404, clip.frames[1].getRGB(1, 0) and 0xFFFFFF)
        assertEquals(0x030303, clip.frames[1].getRGB(0, 1) and 0xFFFFFF)
    }

    @Test fun `VMD audio masks insert silence between unsigned PCM slices`() {
        val table = 816
        val payload = table + 44
        val b = ByteBuffer.allocate(payload + 8).order(ByteOrder.LITTLE_ENDIAN)
        b.putShort(814); b.position(6); b.putShort(2)
        b.position(18); b.putShort(1)
        b.position(804); b.putShort(22050); b.putShort(2); b.putShort(3); b.putShort(1); b.putInt(table)
        b.putShort(0); b.putInt(payload); b.putShort(0); b.putInt(payload + 6)
        b.put(1); b.put(0); b.putInt(6); b.put(2); b.position(b.position() + 9)
        b.put(1); b.put(0); b.putInt(2); b.put(1); b.position(payload)
        b.putInt(2); b.put(byteArrayOf(1, 2, 3, 4))
        val sound = CoktelVideoDecoder.decodeSound(b.array())!!
        assertEquals(22050, sound.sampleRate)
        assertFalse(sound.signed)
        assertArrayEquals(byteArrayOf(1, 2, 128.toByte(), 128.toByte(), 3, 4), sound.samples)
    }

}

package adventureexplorer.audio

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class GobMdyDecoderTest {
    private fun fixture(): Pair<ByteArray, ByteArray> {
        // 60 bpm, 10 ticks/beat; running status note-off at 500ms and end at 1000ms.
        val events = byteArrayOf(0, 0xC0.toByte(), 0, 0, 0x90.toByte(), 60, 127, 5, 60, 0, 5, 0xFC.toByte())
        val song = ByteBuffer.allocate(70 + events.size).order(ByteOrder.LITTLE_ENDIAN)
        song.put(1); song.position(36); song.put(10); song.put(4)
        song.position(42); song.putInt(events.size)
        song.position(59); song.put(2); song.putShort(60)
        song.position(70); song.put(events)
        val bank = ByteBuffer.allocate(15 + 56).order(ByteOrder.LITTLE_ENDIAN)
        bank.put(1); bank.put(0); bank.putShort(1); bank.putShort(15)
        bank.position(15)
        repeat(28) { bank.putShort(if (it == 1 || it == 15) 1 else 0) }
        return song.array() to bank.array()
    }
    @Test fun `MDY running status and tick timing render with TBR instruments`() {
        val (song, bank) = fixture()
        val sound = GobAdlDecoder.decodeMdy(song, bank)!!
        assertEquals(1249L, sound.durationMs)
        assertTrue(sound.samples.take(22050).any { it != 0.toByte() })
        assertTrue(sound.samples.drop(22050).all { it == 0.toByte() })
    }
    @Test fun `malformed timbre banks and truncated events fail safely`() {
        val (song, bank) = fixture()
        assertNull(GobAdlDecoder.decodeMdy(song, bank.copyOf(20)))
        assertNull(GobAdlDecoder.decodeMdy(song.copyOf(song.size - 1), bank))
    }
}

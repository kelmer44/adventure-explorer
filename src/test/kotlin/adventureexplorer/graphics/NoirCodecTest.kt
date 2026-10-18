package adventureexplorer.graphics

import org.junit.Assert.*
import org.junit.Test

class NoirCodecTest {
    private fun packed(bits: String): ByteArray = bits.padEnd((bits.length + 7) / 8 * 8, '0')
        .chunked(8).map { it.toInt(2).toByte() }.toByteArray()

    @Test fun `MSB stream supports overlapping dictionary copies and zero fill`() {
        // Literal A, then dictionary[1..4] (overlaps the write cursor), then terminator.
        assertArrayEquals("AAAAA".toByteArray(), NoirCodec.unpack(packed("1" + "01000001" + "0" + "000000000001" + "0010" + "0" + "000000000000"), 5))
        assertArrayEquals(byteArrayOf(0, 0), NoirCodec.unpack(packed("0" + "000000000010" + "0000" + "0" + "000000000000"), 2))
    }
    @Test fun `bad streams are rejected`() {
        for ((bytes, size) in listOf(byteArrayOf() to 1, packed("101000001") to 1,
            packed("1010000010000000000000") to 2, packed("101000001101000010") to 1)) {
            assertTrue(runCatching { NoirCodec.unpack(bytes, size) }.isFailure)
        }
    }
    @Test fun `RGB565 preserves colors and transparent magenta in raw and RLE rows`() {
        val raw = byteArrayOf(0, 0xF8.toByte(), 0xE0.toByte(), 7, 31, 0, 31, 0xF8.toByte())
        val image = NoirCodec.image(raw, 0, 4, 1, false)
        assertEquals(0xFFFF0000.toInt(), image.getRGB(0, 0))
        assertEquals(0xFF00FF00.toInt(), image.getRGB(1, 0))
        assertEquals(0xFF0000FF.toInt(), image.getRGB(2, 0))
        assertEquals(0, image.getRGB(3, 0))
        val rle = byteArrayOf(2, 0x80.toByte(), 0, 0xF8.toByte(), 2, 0, 31, 0, 31, 0xF8.toByte())
        val decoded = NoirCodec.image(rle, 0, 4, 1, true)
        assertEquals(image.getRGB(0, 0), decoded.getRGB(1, 0))
        assertEquals(image.getRGB(2, 0), decoded.getRGB(2, 0))
        assertEquals(0, decoded.getRGB(3, 0))
        assertTrue(runCatching { NoirCodec.image(rle, 0, 1, 1, true) }.isFailure)
        assertTrue(runCatching { NoirCodec.image(byteArrayOf(0, 0), 0, 1, 1, true) }.isFailure)
        assertTrue(runCatching { NoirCodec.image(raw, 0, 5, 1, false) }.isFailure)
    }
}

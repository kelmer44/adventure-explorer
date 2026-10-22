package adventureexplorer.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class EncodedAudioDecoderTest {
    private fun voc(vararg blocks: Int): ByteArray =
        ("Creative Voice File\u001a".map { it.code } + listOf(0x1A, 0, 0x0A, 1, 0x29, 0x11) + blocks.toList())
            .map { it.toByte() }.toByteArray()

    @Test fun `leading silence at another rate is resampled to the data rate`() {
        // Silence: 100 samples at 5000 Hz (0.02 s); data: 10 samples at 22222 Hz.
        val data = voc(3, 3, 0, 0, 99, 0, 0x38, 1, 12, 0, 0, 0xD3, 0, *IntArray(10) { 0x90 }, 0)
        val sound = EncodedAudioDecoder.decode(data)!!
        assertEquals(1_000_000 / (256 - 0xD3), sound.sampleRate)
        assertEquals(444 + 10, sound.samples.size)
        assertEquals(128, sound.samples[0].toInt() and 255)
    }
}

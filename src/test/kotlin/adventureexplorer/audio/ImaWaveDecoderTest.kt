package adventureexplorer.audio

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream

class ImaWaveDecoderTest {
    private fun wave(channels: Int, vararg blocks: Int): ByteArray {
        val out=ByteArrayOutputStream()
        fun str(s: String) { out.write(s.toByteArray()) }
        fun le(v: Int,n: Int=2) { repeat(n) { out.write((v ushr (it*8)) and 255) } }
        str("RIFF");le(52+blocks.size,4);str("WAVEfmt ");le(20,4);le(17);le(channels);le(22050,4);le(11025,4)
        le(channels*8);le(4);le(2);le(9);str("fact");le(4,4);le(9,4);str("data");le(blocks.size,4)
        blocks.forEach { out.write(it) };return out.toByteArray()
    }
    private fun samples(b: ByteArray) = b.toList().chunked(2).map { ((it[0].toInt() and 255) or (it[1].toInt() shl 8)).toShort().toInt() }
    @Test fun `mono uses low nibble first and retains the predictor`() {
        val s=ImaWaveDecoder.decode(wave(1,100,0,0,0,0x71,0,0,0))!!
        assertEquals(listOf(100,101,112,114,115,116,117,118,119),samples(s.samples))
        assertEquals(22050,s.sampleRate)
    }
    @Test fun `stereo blocks interleave channel groups`() {
        val s=ImaWaveDecoder.decode(wave(2,100,0,0,0,156,255,0,0,0,0,0,0,0,0,0,0))!!
        assertEquals(List(9) { listOf(100,-100) }.flatten(),samples(s.samples))
    }
    @Test fun `invalid indices truncated blocks and impossible fact counts are rejected`() {
        val good=wave(1,100,0,0,0,0,0,0,0)
        assertNull(ImaWaveDecoder.decode(good.copyOf(good.size-1)))
        assertNull(ImaWaveDecoder.decode(good.clone().also { it[it.size-6]=89 }))
        assertNull(ImaWaveDecoder.decode(good.clone().also { it[48]=10 }))
    }
}

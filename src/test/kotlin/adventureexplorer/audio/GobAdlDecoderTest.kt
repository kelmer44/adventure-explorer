package adventureexplorer.audio

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class GobAdlDecoderTest {
    private val piano = intArrayOf(1, 1, 3, 15, 5, 0, 1, 3, 15, 0, 0, 0, 1, 0, 1, 1, 15, 7, 0, 2, 4, 0, 0, 0, 1, 0, 0, 0)

    /** Percussion-mode ADL: a melody note, then bass drum and hi-hat hits. Delays are milliseconds. */
    private fun fixture(): ByteArray {
        val song = intArrayOf(
            0,                         // initial delay (ignored by the player)
            0xC0, 0, 0,                // voice 0: instrument 0
            0x00, 60, 127, 0x81, 0xF4, // voice 0: note 60, volume 127; wait 500 ms
            0x80, 10,                  // voice 0: note off
            0x06, 36, 127, 100,        // bass drum
            0x86, 10,
            0x0A, 60, 127, 100,        // hi-hat
            0x8A, 100,
            0xB0, 64, 10,              // voice 0 volume
            0x90, 64, 0x81, 0x00,      // voice 0: note 64; wait 256 ms
            0x80, 0,
            0xFF,
        )
        val buffer = ByteBuffer.allocate(3 + piano.size * 2 + song.size).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(1); buffer.put(0); buffer.put(0)
        piano.forEach { buffer.putShort(it.toShort()) }
        song.forEach { buffer.put(it.toByte()) }
        return buffer.array()
    }

    private fun energy(samples: ByteArray, fromMs: Int, toMs: Int): Double {
        val pcm = ByteBuffer.wrap(samples).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        return (fromMs * 441 / 10 until toMs * 441 / 10).sumOf { val v = pcm.get(it).toDouble(); v * v }
    }

    @Test fun `ADL melody and percussion voices render through the OPL chip`() {
        val sound = GobAdlDecoder.decode(fixture())!!
        assertEquals(44_100, sound.sampleRate)
        assertEquals(1086.0 + 250, sound.durationMs.toDouble(), 1.0)
        assertTrue("melody note", energy(sound.samples, 100, 450) > 0)
        assertTrue("bass drum", energy(sound.samples, 515, 600) > 0)
        assertTrue("hi-hat", energy(sound.samples, 625, 700) > 0)
        assertTrue("second note", energy(sound.samples, 840, 1080) > 0)
    }

    @Test fun `truncated ADL data fails safely`() {
        val data = fixture()
        assertNull(GobAdlDecoder.decode(data.copyOf(data.size - 1)))
        assertNull(GobAdlDecoder.decode(data.copyOf(40)))
    }
}

package adventureexplorer.audio

import adventureexplorer.model.ResourceNode
import adventureexplorer.scripting.ScriptManager
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ScummAdPlayerTest {
    private fun energy(samples: ByteArray, fromMs: Int, toMs: Int): Double {
        val pcm = ByteBuffer.wrap(samples).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        return (fromMs * 441 / 10 until minOf(toMs * 441 / 10, pcm.limit())).sumOf { val v = pcm.get(it).toDouble(); v * v }
    }

    /**
     * Music resource: priority/channel bytes, 0x80, ticks, play-once flag,
     * loop start, header padding, instrument count and channel map, eight
     * 16-byte instruments, then the event track from offset 0x93.
     */
    private fun music(track: IntArray, loop: Boolean = false): ByteArray {
        val data = ByteArray(0x93 + track.size)
        data[2] = 0x80.toByte()
        data[3] = 128.toByte()         // ticks: one event tick every two 472 Hz callbacks
        data[4] = if (loop) 0 else 1   // 0 = loop
        data[10] = 1                   // one instrument, used by MIDI channel 0
        data[11] = 1
        // Instrument at 19: frequency bytes, C0, then modulator and carrier (20/40/60/80/E0).
        val instrument = intArrayOf(0, 0, 0x00, 0x01, 0x10, 0xF2, 0x77, 0x00, 0x01, 0x00, 0xF2, 0x77, 0x00, 0, 0, 0)
        instrument.forEachIndexed { i, v -> data[19 + i] = v.toByte() }
        track.forEachIndexed { i, v -> data[0x93 + i] = v.toByte() }
        return data
    }

    @Test fun `music notes key on and off at the event times`() {
        // Note on (channel 0, note 72), 0x81 0x00 = 128 << 1 >> 1 = 128 event ticks, note off, end of track.
        val track = intArrayOf(0x90, 72, 100, 0x81, 0x00, 0x80, 72, 0, 0, 0xFF, 47, 0)
        val sound = ScummAdPlayer.render(music(track), loom = false)!!
        assertEquals(44_100, sound.sampleRate)
        // 40 initial event ticks, then 64 (the VLQ is halved), at 236 ticks/s: note from ~170 ms to ~440 ms.
        assertTrue(energy(sound.samples, 200, 420) > 0)
        assertTrue(energy(sound.samples, 1000, 1400) < energy(sound.samples, 200, 420) / 100)
    }

    @Test fun `looping music renders one pass and effects end on their own`() {
        val track = intArrayOf(0x90, 72, 100, 0x40, 0x80, 72, 0, 0, 0xFF, 47, 0)
        val looping = ScummAdPlayer.render(music(track, loop = true), loom = false)!!
        assertTrue(looping.durationMs < 3_000)
        // Effect: priority, channel, instrument definition, then the next channel's start (ends this one).
        val effect = byteArrayOf(10, 0, 1, 0x00, 0x2A, 0x00, 0x01, 0x10, 0xF2.toByte(), 0x77, 0x00, 0x01, 0x00, 0xF2.toByte(), 0x77, 0x00, 0x00, 0x03, 0xFF.toByte())
        assertNotNull(ScummAdPlayer.render(effect, loom = false))
        assertNull(ScummAdPlayer.render(ByteArray(3), loom = false))
    }

    @Test fun `installed Loom lists and renders AdLib music and effects`() {
        val path = System.getenv("LOOM_TEST_PATH")
        assumeTrue("Set LOOM_TEST_PATH to Loom EGA (SCUMM V3)", path != null)
        val mgr = ScriptManager()
        try {
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val sounds = leaves(mgr.detectGame(path!!)!!.resources).filter { it.id.startsWith("v3:snd:") }
            assertEquals(31, sounds.size)
            for (node in sounds) assertNotNull(node.id, mgr.loadResource(path, node.id)?.soundData)
            val opl = mgr.loadResource(path, "v3:snd:25")!!
            assertTrue(opl.playbackChoice)
            assertEquals(144_499.0, opl.soundData!!.durationMs.toDouble(), 50.0)
            // The same song as a General MIDI conversion for Java's synthesizer
            AdlibPlayback.current = AdlibPlayback.MIDI
            try {
                val midi = mgr.loadResource(path, "v3:snd:25")!!
                assertTrue(midi.playbackChoice)
                val sequence = javax.sound.midi.MidiSystem.getSequence(midi.midiData!!.bytes.inputStream())
                assertEquals(143.0, sequence.microsecondLength / 1e6, 2.0)
                // Effects have no MIDI form and stay on the OPL2 emulation.
                assertFalse(mgr.loadResource(path, "v3:snd:1")!!.playbackChoice)
            } finally { AdlibPlayback.current = AdlibPlayback.OPL }
        } finally { mgr.close() }
    }
}

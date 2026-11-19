package adventureexplorer.audio

import adventureexplorer.model.MidiData
import adventureexplorer.model.SciAdlibSong
import org.junit.Assert.*
import org.junit.Test
import javax.sound.midi.ShortMessage

class SciAdlibDeviceTest {
    /** A SCI1 patch bank (96 instruments) whose instrument 0 is a plain loud two-operator tone. */
    private fun patch(): ByteArray = ByteArray(2690).also { bank ->
        for (op in 0..1) {
            val base = op * 13
            bank[base + 1] = 1   // frequency multiplier
            bank[base + 3] = 15  // attack rate
            bank[base + 4] = 0   // sustain level
            bank[base + 5] = 1   // sustained envelope
            bank[base + 7] = 5   // release rate
            bank[base + 8] = 0   // total level: loudest
        }
        bank[12] = 0 // connection flag (inverted): additive off -> FM algorithm 1
    }

    private class Recorder { val writes = mutableListOf<Pair<Int, Int>>(); fun last(reg: Int) = writes.last { it.first == reg }.second }

    private fun device(recorder: Recorder, version: SciSoundVersion = SciSoundVersion.SCI1) =
        SciAdlibDevice(version, patch()) { reg, value -> recorder.writes.add(reg to value) }

    private fun SciAdlibDevice.cc(channel: Int, controller: Int, value: Int) =
        send(ShortMessage(ShortMessage.CONTROL_CHANGE, channel, controller, value))
    private fun SciAdlibDevice.on(channel: Int, note: Int, velocity: Int = 100) =
        send(ShortMessage(ShortMessage.NOTE_ON, channel, note, velocity))
    private fun SciAdlibDevice.off(channel: Int, note: Int) =
        send(ShortMessage(ShortMessage.NOTE_OFF, channel, note, 0))

    @Test fun `chip is reset like the original driver and a note writes the SCI frequency table`() {
        val rec = Recorder()
        val d = device(rec)
        assertEquals(listOf(0xBD to 0, 0x08 to 0, 0x01 to 0x20), rec.writes.take(3))

        d.cc(0, 0x4B, 1) // channel 0 owns one voice
        d.send(ShortMessage(ShortMessage.PROGRAM_CHANGE, 0, 0, 0))
        d.on(0, 60)
        // Note 60: index 240 -> table entry 0 (0x157), octave 240 / 48 - 1 = 4, key on
        assertEquals(0x57, rec.last(0xA0))
        assertEquals(0x20 or (4 shl 2) or 0x01, rec.last(0xB0))
        // The instrument is loaded into voice 0: attack/decay, sustain/release, characteristics
        assertEquals(0xF0, rec.last(0x60))
        assertEquals(0x05, rec.last(0x80))
        assertEquals(0x21, rec.last(0x20)) // sustained envelope + multiplier 1

        d.off(0, 60)
        assertEquals(4 shl 2 or 0x01, rec.last(0xB0)) // key bit cleared
    }

    @Test fun `channels without voices are silent and the pitch wheel moves the note in quarter semitones`() {
        val rec = Recorder()
        val d = device(rec)
        d.on(3, 60)
        assertTrue("no voice owned by the channel", rec.writes.none { it.first == 0xB0 })

        d.cc(3, 0x4B, 1)
        d.on(3, 60)
        val flat = rec.last(0xA0)
        d.send(ShortMessage(ShortMessage.PITCH_BEND, 3, 0x7F, 0x7F)) // wheel to the top: +8191 / 171 = 47 steps
        assertNotEquals(flat, rec.last(0xA0) or (rec.last(0xB0) shl 8))
        // 240 + 47 = 287: table entry 47 (0x2a4), octave 287 / 48 - 1 = 4
        assertEquals(0x2A4 and 0xFF, rec.last(0xA0))
        assertEquals(0x20 or (4 shl 2) or 0x02, rec.last(0xB0))
    }

    @Test fun `a full channel steals its oldest voice only after the timer has aged it`() {
        val rec = Recorder()
        val d = device(rec)
        d.cc(0, 0x4B, 1)
        d.on(0, 60)
        val before = rec.writes.size
        d.on(0, 64) // started in the same time slice: not eligible, the note is dropped
        assertEquals(before, rec.writes.size)
        d.onTimer()
        d.on(0, 64) // now the oldest note is released and its voice reused
        assertTrue(rec.writes.size > before)
        assertEquals(0xA0 + 0, rec.writes.last { it.first == 0xA0 }.first)
    }

    @Test fun `rendering an SCI AdLib song through the real chip produces sound`() {
        // delta 0: voices, program, then a note for 60 ticks (1 s)
        val track = byteArrayOf(
            0, 0xFF.toByte(), 0x51, 3, 0x0F, 0x42, 0x40,
            0, 0xB0.toByte(), 0x4B, 1,
            0, 0xC0.toByte(), 0,
            0, 0x90.toByte(), 60, 100,
            60, 0x80.toByte(), 60, 0,
            0, 0xFF.toByte(), 0x2F, 0)
        val smf = "MThd".toByteArray() + byteArrayOf(0, 0, 0, 6, 0, 0, 0, 1, 0, 60) +
            "MTrk".toByteArray() + byteArrayOf(0, 0, 0, track.size.toByte()) + track
        val gm = byteArrayOf(77, 84, 104, 100, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96, 77, 84, 114, 107, 0, 0, 0, 4, 0, 0xFF.toByte(), 0x2F, 0)
        val sound = MidiOplRenderer.render(MidiData(gm, null, SciAdlibSong(smf, patch(), SciSoundVersion.SCI1)))
        assertTrue("silent", sound.samples.any { it != 0.toByte() })
        assertTrue(sound.durationMs >= 1000)
    }

    @Test fun `SCI0 header voices decide which channels can play`() {
        val rec = Recorder()
        val d = device(rec, SciSoundVersion.SCI0_LATE)
        val header = ByteArray(0x21)
        // channel 1: 2 voices, played by AdLib (mask bit 0x04)
        header[1 + 2 * 1] = 2
        header[2 + 2 * 1] = 4
        d.initTrack(header)
        d.on(1, 60)
        assertTrue(rec.writes.any { it.first in 0xB0..0xB8 && it.second and 0x20 != 0 })
        val keyOns = rec.writes.count { it.first in 0xB0..0xB8 && it.second and 0x20 != 0 }
        d.on(2, 62) // channel 2 has no voices
        assertEquals(keyOns, rec.writes.count { it.first in 0xB0..0xB8 && it.second and 0x20 != 0 })
    }
}

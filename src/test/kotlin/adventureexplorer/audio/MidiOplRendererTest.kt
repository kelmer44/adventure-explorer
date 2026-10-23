package adventureexplorer.audio

import adventureexplorer.audio.imuse.ImusePlayback
import adventureexplorer.audio.imuse.ImuseSong
import adventureexplorer.model.MidiData
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import javax.sound.midi.*

class MidiOplRendererTest {
    private fun message(command: Int, channel: Int, a: Int, b: Int = 0) = ShortMessage(command, channel, a, b)
    private fun bytes(sequence: Sequence) = ByteArrayOutputStream().also { MidiSystem.write(sequence, 1, it) }.toByteArray()
    private fun meta(type: Int, vararg values: Int) = MetaMessage(type, values.map { it.toByte() }.toByteArray(), values.size)

    @Test fun `format one tempo map merges tracks and preserves end-of-track silence`() {
        val sequence = Sequence(Sequence.PPQ, 96)
        sequence.createTrack().apply {
            add(MidiEvent(meta(0x51, 0x0F, 0x42, 0x40), 96)) // 1,000,000 us/qn
            add(MidiEvent(meta(0x2F), 240))
        }
        sequence.createTrack().apply {
            add(MidiEvent(message(ShortMessage.NOTE_ON, 0, 60, 100), 0))
            add(MidiEvent(message(ShortMessage.NOTE_OFF, 0, 60), 192))
        }
        val timeline = MidiOplRenderer.timeline(sequence)
        assertEquals(22_050L, timeline.first { (it.second.message as? MetaMessage)?.type == 0x51 }.first)
        assertEquals(66_150L, timeline.first { (it.second.message as? ShortMessage)?.command == ShortMessage.NOTE_OFF }.first)
        val sound = MidiOplRenderer.render(MidiData(bytes(sequence)))
        assertEquals(3_000L, sound.durationMs) // 2 s including trailing silence + 1 s release
        assertTrue(sound.samples.any { it != 0.toByte() })
    }

    @Test fun `SMPTE timing ignores tempo events`() {
        val sequence = Sequence(Sequence.SMPTE_25, 40)
        sequence.createTrack().apply {
            add(MidiEvent(meta(0x51, 1, 2, 3), 0))
            add(MidiEvent(message(ShortMessage.NOTE_ON, 0, 60, 100), 1000))
        }
        assertEquals(44_100L, MidiOplRenderer.timeline(sequence).last().first)
    }

    @Test fun `GM programs and channel ten percussion render distinct audible instruments`() {
        fun render(channel: Int, program: Int, note: Int): ByteArray {
            val sequence = Sequence(Sequence.PPQ, 96)
            sequence.createTrack().apply {
                add(MidiEvent(message(ShortMessage.PROGRAM_CHANGE, channel, program), 0))
                add(MidiEvent(message(ShortMessage.NOTE_ON, channel, note, 110), 0))
                add(MidiEvent(message(ShortMessage.NOTE_OFF, channel, note), 48))
            }
            return MidiOplRenderer.render(MidiData(bytes(sequence))).samples
        }
        val piano = render(0, 0, 60)
        val organ = render(0, 19, 60)
        val kick = render(9, 0, 36)
        val snare = render(9, 0, 38)
        for (pcm in listOf(piano, organ, kick, snare)) assertTrue(pcm.any { it != 0.toByte() })
        assertFalse(piano.contentEquals(organ))
        assertFalse(kick.contentEquals(snare))
    }

    @Test fun `expression can silence a channel and reset controllers restores it`() {
        val sequence = Sequence(Sequence.PPQ, 96)
        sequence.createTrack().apply {
            add(MidiEvent(message(ShortMessage.CONTROL_CHANGE, 0, 11, 0), 0))
            add(MidiEvent(message(ShortMessage.NOTE_ON, 0, 60, 127), 0))
            add(MidiEvent(message(ShortMessage.CONTROL_CHANGE, 0, 121), 48))
            add(MidiEvent(message(ShortMessage.NOTE_OFF, 0, 60), 96))
        }
        val pcm = MidiOplRenderer.render(MidiData(bytes(sequence))).samples
        fun peak(from: Int, to: Int) = (from until to step 2).maxOf {
            kotlin.math.abs(((pcm[it].toInt() and 255) or (pcm[it + 1].toInt() shl 8)).toShort().toInt())
        }
        // OPL's maximum attenuation still has a small residual signal.
        assertTrue(peak(24_000, 40_000) > peak(0, 20_000) * 20)
    }

    @Test fun `CMF retains embedded patches original channels rhythm controls and header timing`() {
        val data = cmfFixture()
        val opl = CmfToMidiConverter.oplData(data)!!
        val sequence = MidiSystem.getSequence(opl.midi.inputStream())
        val messages = (0 until sequence.tracks[0].size()).map { sequence.tracks[0].get(it).message }
        assertTrue(messages.filterIsInstance<ShortMessage>().any { it.channel == 11 && it.command == ShortMessage.NOTE_ON })
        assertTrue(messages.filterIsInstance<ShortMessage>().any { it.command == ShortMessage.CONTROL_CHANGE && it.data1 == 0x67 })
        val midi = CmfToMidiConverter.convert(data)!!
        assertEquals(250_000L, MidiSystem.getSequence(midi.inputStream()).microsecondLength)
        val original = MidiOplRenderer.render(MidiData(midi, data))
        assertEquals(1250L, original.durationMs)
        assertTrue(original.samples.any { it != 0.toByte() })
        val changed = data.copyOf().also { it[48] = 4; it[49] = 8 }
        assertFalse(original.samples.contentEquals(MidiOplRenderer.render(MidiData(midi, changed)).samples))
        assertNotEquals(MidiData(midi, data), MidiData(midi, changed))
    }

    @Test fun `GM iMUSE songs including percussion use OPL without losing sequencing`() {
        val sequence = Sequence(Sequence.PPQ, 96)
        sequence.createTrack().apply {
            add(MidiEvent(message(ShortMessage.NOTE_ON, 9, 38, 100), 0))
            add(MidiEvent(message(ShortMessage.NOTE_OFF, 9, 38), 48))
        }
        val song = ImuseSong.parse("GMD ", bytes(sequence))!!
        val sound = ImusePlayback.renderOpl(song)!!
        assertTrue(sound.samples.any { it != 0.toByte() })
    }

    companion object {
        fun cmfFixture(): ByteArray {
            val header = ByteArray(64)
            "CTMF".toByteArray().copyInto(header)
            header[4] = 1; header[5] = 1
            header[6] = 48; header[8] = 64
            header[10] = 96; header[12] = 192.toByte(); header[36] = 1
            byteArrayOf(1, 1, 0, 0, 0xF0.toByte(), 0xF0.toByte(), 0x0F, 0x0F, 0, 0, 0).copyInto(header, 48)
            return header + byteArrayOf(0, 0xB0.toByte(), 0x67, 1, 0, 0x9B.toByte(), 60, 100,
                48, 0x8B.toByte(), 60, 0, 0, 0xFF.toByte(), 0x2F, 0)
        }
    }
}

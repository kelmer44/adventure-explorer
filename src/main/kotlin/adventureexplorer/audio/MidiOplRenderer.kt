package adventureexplorer.audio

import adventureexplorer.audio.imuse.AdlibOplDevice
import adventureexplorer.audio.imuse.ImuseChannel
import adventureexplorer.model.MidiData
import adventureexplorer.model.SoundData
import java.io.ByteArrayOutputStream
import javax.sound.midi.MetaMessage
import javax.sound.midi.MidiEvent
import javax.sound.midi.MidiSystem
import javax.sound.midi.Sequence
import javax.sound.midi.ShortMessage

/** Shared OPL playback/export for every engine's SMF, XMIDI, GMF and CMF music. */
object MidiOplRenderer {
    const val SAMPLE_RATE = 44_100
    private const val MAX_SECONDS = 10 * 60

    /** No Java synthesizer or audio output device is needed to render a song. */
    fun render(midi: MidiData): SoundData {
        val cmf = midi.cmfSource?.let { CmfToMidiConverter.oplData(it) }
        require(midi.cmfSource == null || cmf != null) { "Invalid CMF instrument data" }
        val sequence = MidiSystem.getSequence((cmf?.midi ?: midi.bytes).inputStream())
        val chip = Opl3(SAMPLE_RATE)
        val device: OplMidiOutput = if (cmf != null) CmfOplDevice(chip, cmf.instruments) else StandardMidiOplDevice(chip)
        val out = ByteArrayOutputStream()
        val frame = IntArray(2)
        val buffer = ByteArray(4096)
        val maxSamples = SAMPLE_RATE.toLong() * MAX_SECONDS
        var written = 0L
        var timer = 0L

        fun renderUntil(target: Long) {
            val end = target.coerceAtMost(maxSamples)
            while (written < end) {
                if (Thread.currentThread().isInterrupted) throw InterruptedException("MIDI rendering cancelled")
                val count = minOf(buffer.size / 2L, end - written).toInt()
                repeat(count) { i ->
                    if (written * 250 >= timer * SAMPLE_RATE) { device.onTimer(); timer++ }
                    chip.generate(frame)
                    val value = ((frame[0] + frame[1]) / 2).coerceIn(-32768, 32767)
                    buffer[i * 2] = value.toByte()
                    buffer[i * 2 + 1] = (value shr 8).toByte()
                    written++
                }
                out.write(buffer, 0, count * 2)
            }
        }

        for ((sample, event) in timeline(sequence)) {
            renderUntil(sample)
            if (written >= maxSamples) break
            (event.message as? ShortMessage)?.let(device::send)
        }
        device.allNotesOff()
        renderUntil(written + SAMPLE_RATE) // allow release envelopes to finish
        return SoundData(out.toByteArray(), SAMPLE_RATE, 16, 1, true)
    }

    /** Merge tracks before applying tempo changes; SMPTE divisions ignore tempo. */
    internal fun timeline(sequence: Sequence): List<Pair<Long, MidiEvent>> {
        val events = sequence.tracks.flatMap { track -> (0 until track.size()).map { track.get(it) } }.sortedBy { it.tick }
        var tick = 0L
        var samples = 0.0
        var tempo = 500_000
        return events.map { event ->
            val samplesPerTick = if (sequence.divisionType == Sequence.PPQ)
                SAMPLE_RATE.toDouble() * tempo / (1_000_000.0 * sequence.resolution)
            else SAMPLE_RATE.toDouble() / (sequence.divisionType * sequence.resolution)
            samples += (event.tick - tick) * samplesPerTick
            tick = event.tick
            val meta = event.message as? MetaMessage
            if (meta?.type == 0x51 && meta.data.size == 3) {
                val data = meta.data
                tempo = (((data[0].toInt() and 255) shl 16) or ((data[1].toInt() and 255) shl 8) or
                    (data[2].toInt() and 255)).coerceAtLeast(1)
            }
            samples.toLong() to event
        }
    }
}

internal interface OplMidiOutput {
    fun send(message: ShortMessage)
    fun onTimer() {}
    fun allNotesOff()
}

/** MIDI channel state over the existing ScummVM AdLib instruments and voice allocator. */
internal class StandardMidiOplDevice(chip: Opl3) : OplMidiOutput {
    private val device = AdlibOplDevice(chip, enablePercussion = true)
    private val channels = Array(16) { index -> Channel(if (index == 9) device.percussionChannel()!! else device.allocateChannel()!!) }

    override fun onTimer() = device.onTimer()
    override fun allNotesOff() { channels.forEach { it.output.sustain(false) }; device.allNotesOff() }

    override fun send(message: ShortMessage) {
        val channel = channels[message.channel]
        val a = message.data1
        val b = message.data2
        when (message.command) {
            ShortMessage.NOTE_ON -> if (b == 0) channel.output.noteOff(a) else channel.output.noteOn(a, b)
            ShortMessage.NOTE_OFF -> channel.output.noteOff(a)
            ShortMessage.PROGRAM_CHANGE -> channel.output.programChange(a)
            ShortMessage.PITCH_BEND -> channel.output.pitchBend((a or (b shl 7)) - 8192)
            ShortMessage.CONTROL_CHANGE -> channel.control(a, b)
        }
    }

    private class Channel(val output: ImuseChannel) {
        private var volume = 100
        private var expression = 127
        private var rpnMsb = 127
        private var rpnLsb = 127

        init { output.volume(volume); output.panPosition(64); output.pitchBendFactor(2) }

        fun control(controller: Int, value: Int) {
            when (controller) {
                1 -> output.modulationWheel(value)
                7 -> { volume = value; updateVolume() }
                10 -> output.panPosition(value)
                11 -> { expression = value; updateVolume() }
                64 -> output.sustain(value >= 64)
                91 -> output.effectLevel(value)
                93 -> output.chorusLevel(value)
                100 -> rpnLsb = value
                101 -> rpnMsb = value
                98, 99 -> { rpnMsb = 127; rpnLsb = 127 } // NRPN cancels RPN selection
                6 -> if (rpnMsb == 0 && rpnLsb == 0) output.pitchBendFactor(value)
                120 -> output.allNotesOff()
                121 -> {
                    output.sustain(false); output.pitchBend(0); output.modulationWheel(0)
                    expression = 127; rpnMsb = 127; rpnLsb = 127; updateVolume()
                }
                123 -> output.allNotesOff()
            }
        }

        private fun updateVolume() = output.volume(volume * expression / 127)
    }
}

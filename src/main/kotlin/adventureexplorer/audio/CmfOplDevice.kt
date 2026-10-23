package adventureexplorer.audio

import javax.sound.midi.ShortMessage
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * CMF's two-operator instrument bank and hardware rhythm channels (12–16).
 * Register layout follows ScummVM engines/igor/midi.cpp (GPLv3+) and the
 * Creative CMF layout: interleaved modulator/carrier register pairs.
 */
internal class CmfOplDevice(private val chip: Opl3, private val instruments: List<ByteArray>) : OplMidiOutput {
    private data class Voice(var channel: Int = -1, var note: Int = 0, var age: Long = 0)
    private val voices = Array(9) { Voice() }
    private val programs = IntArray(16)
    private val regs = IntArray(256)
    private val drumNotes = IntArray(5) { -1 }
    private var rhythm = false
    private var age = 0L

    init { write(1, 0x20); write(0xBD, 0xC0) }

    override fun send(message: ShortMessage) {
        val channel = message.channel
        val note = message.data1
        when (message.command) {
            ShortMessage.NOTE_ON -> if (message.data2 == 0) noteOff(channel, note) else noteOn(channel, note, message.data2)
            ShortMessage.NOTE_OFF -> noteOff(channel, note)
            ShortMessage.PROGRAM_CHANGE -> programs[channel] = note
            ShortMessage.CONTROL_CHANGE -> when (note) {
                0x63 -> write(0xBD, (regs[0xBD] and 0x3F) or ((message.data2 and 3) shl 6))
                0x67 -> {
                    allNotesOff()
                    rhythm = message.data2 != 0
                    write(0xBD, (regs[0xBD] and 0xC0) or if (rhythm) 0x20 else 0)
                }
                120, 123 -> {
                    voices.forEachIndexed { i, v -> if (v.channel == channel) keyOff(i) }
                    if (rhythm && channel >= 11) drumOff(channel - 11)
                }
            }
        }
    }

    override fun allNotesOff() {
        voices.indices.forEach(::keyOff)
        drumNotes.fill(-1)
        write(0xBD, regs[0xBD] and 0xE0)
    }

    private fun noteOff(channel: Int, note: Int) {
        if (rhythm && channel >= 11) {
            val drum = channel - 11
            if (drumNotes[drum] == note) drumOff(drum)
        } else voices.forEachIndexed { i, v -> if (v.channel == channel && v.note == note) keyOff(i) }
    }

    private fun noteOn(channel: Int, note: Int, velocity: Int) {
        val instrument = instruments.getOrNull(programs[channel]) ?: return
        if (rhythm && channel >= 11) {
            val drum = channel - 11
            val oplChannel = DRUM_CHANNELS[drum]
            drumOff(drum)
            if (drum == 0) setupInstrument(oplChannel, instrument, velocity)
            else setupOperator(DRUM_OPERATORS[drum], instrument, 0, velocity, true)
            // Hi-hat/snare and tom/cymbal share the pitch registers of channels 7/8.
            setPitch(oplChannel, note, false)
            drumNotes[drum] = note
            write(0xBD, regs[0xBD] or (0x10 shr drum))
            return
        }
        val candidates = 0 until if (rhythm) 6 else 9
        val index = candidates.firstOrNull { voices[it].channel < 0 } ?: candidates.minBy { voices[it].age }
        keyOff(index)
        setupInstrument(index, instrument, velocity)
        setPitch(index, note, true)
        voices[index] = Voice(channel, note, age++)
    }

    private fun setupInstrument(channel: Int, instrument: ByteArray, velocity: Int) {
        setupOperator(OPERATORS[channel], instrument, 0, velocity, instrument[10].toInt() and 1 != 0)
        setupOperator(OPERATORS[channel] + 3, instrument, 1, velocity, true)
        write(0xC0 + channel, instrument[10].toInt() and 15)
    }

    private fun setupOperator(operator: Int, instrument: ByteArray, offset: Int, velocity: Int, scale: Boolean) {
        write(0x20 + operator, instrument[offset].toInt() and 255)
        val level = instrument[2 + offset].toInt() and 255
        val attenuation = if (scale) 63 - ((63 - (level and 63)) * velocity / 127) else level and 63
        write(0x40 + operator, (level and 0xC0) or attenuation)
        write(0x60 + operator, instrument[4 + offset].toInt() and 255)
        write(0x80 + operator, instrument[6 + offset].toInt() and 255)
        write(0xE0 + operator, instrument[8 + offset].toInt() and 3)
    }

    private fun setPitch(channel: Int, note: Int, keyOn: Boolean) {
        val hz = 440.0 * 2.0.pow((note - 69) / 12.0)
        var block = 0
        var frequency = hz * (1 shl 20) / 49716.0
        while (frequency > 1023 && block < 7) { frequency /= 2; block++ }
        val fnum = frequency.roundToInt().coerceIn(0, 1023)
        write(0xA0 + channel, fnum and 255)
        write(0xB0 + channel, (fnum shr 8) or (block shl 2) or if (keyOn) 0x20 else 0)
    }

    private fun keyOff(index: Int) {
        write(0xB0 + index, regs[0xB0 + index] and 0x1F)
        voices[index].channel = -1
    }

    private fun drumOff(drum: Int) {
        write(0xBD, regs[0xBD] and (0x10 shr drum).inv())
        drumNotes[drum] = -1
    }

    private fun write(register: Int, value: Int) { regs[register] = value; chip.writeReg(register, value) }

    companion object {
        private val OPERATORS = intArrayOf(0, 1, 2, 8, 9, 10, 16, 17, 18)
        private val DRUM_CHANNELS = intArrayOf(6, 7, 8, 8, 7)
        private val DRUM_OPERATORS = intArrayOf(16, 20, 18, 21, 17)
    }
}

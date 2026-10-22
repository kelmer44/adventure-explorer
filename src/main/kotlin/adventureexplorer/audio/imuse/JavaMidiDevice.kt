package adventureexplorer.audio.imuse

import javax.sound.midi.Receiver
import javax.sound.midi.ShortMessage

/**
 * iMUSE General MIDI output to a javax.sound.midi [Receiver], after ScummVM's
 * `IMuseChannel_Midi` (engines/scumm/imuse/drivers/midi.cpp, GPLv2+): the old
 * iMUSE system (MI2, FOA, DOTT) realises transpose and detune through pitch
 * bend, so every channel is set to a 16-semitone bend range at start, as the
 * DOTT General MIDI driver does.
 */
class JavaMidiDevice(private val receiver: Receiver) : ImuseDevice {
    private val channels = Array(16) { Channel(it) }

    init {
        for (c in 0 until 16) {
            send(0xB0 or c, 0x64, 0); send(0xB0 or c, 0x65, 0); send(0xB0 or c, 0x06, 16)
            send(0xB0 or c, 0x07, 0x7F); send(0xB0 or c, 0x0A, 0x3F); send(0xC0 or c, 0, 0)
            send(0xE0 or c, 0, 0x40); send(0xB0 or c, 0x01, 0); send(0xB0 or c, 0x40, 0)
            send(0xB0 or c, 0x5B, 0x40); send(0xB0 or c, 0x5D, 0); send(0xB0 or c, 0x00, 0)
            send(0xB0 or c, 0x7B, 0)
        }
    }

    override fun allocateChannel(): ImuseChannel? =
        channels.firstOrNull { it.number != 9 && !it.allocated }?.also { it.allocated = true }

    override fun percussionChannel(): ImuseChannel = channels[9]

    override fun allNotesOff() {
        for (c in channels) { send(0xB0 or c.number, 0x40, 0); send(0xB0 or c.number, 0x7B, 0) }
    }

    private fun send(status: Int, a: Int, b: Int) {
        runCatching {
            val msg = ShortMessage()
            msg.setMessage(status and 0xF0, status and 0x0F, a and 0x7F, b and 0x7F)
            receiver.send(msg, -1)
        }
    }

    private inner class Channel(val number: Int) : ImuseChannel {
        var allocated = false
        private var transposeValue = 0
        private var detuneValue = 0
        private var bendTemp = 0
        private var sensitivity = 2

        override fun noteOn(note: Int, velocity: Int) = send(0x90 or number, note, velocity)
        override fun noteOff(note: Int) = send(0x80 or number, note, 0x40)
        override fun programChange(program: Int) = send(0xC0 or number, program, 0)
        override fun pitchBend(bend: Int) {
            bendTemp = bend
            // DOTT, INDY4 and MI2 formula
            val value = (((bend * sensitivity) shr 6) + detuneValue + (transposeValue shl 7)).coerceIn(-2048, 2047) shl 2
            val raw = value + 0x2000
            send(0xE0 or number, raw and 0x7F, (raw shr 7) and 0x7F)
        }
        override fun pitchBendFactor(semitones: Int) { pitchBend(0); sensitivity = semitones }
        override fun transpose(semitones: Int) { transposeValue = semitones; pitchBend(bendTemp) }
        override fun detune(value: Int) { detuneValue = value; pitchBend(bendTemp) }
        override fun volume(value: Int) = send(0xB0 or number, 0x07, value)
        override fun panPosition(value: Int) = send(0xB0 or number, 0x0A, value)
        override fun priority(value: Int) {}
        override fun sustain(on: Boolean) = send(0xB0 or number, 0x40, if (on) 0x7F else 0)
        override fun modulationWheel(value: Int) = send(0xB0 or number, 0x01, value)
        override fun effectLevel(value: Int) = send(0xB0 or number, 0x5B, value)
        override fun chorusLevel(value: Int) = send(0xB0 or number, 0x5D, value)
        override fun allNotesOff() = send(0xB0 or number, 0x7B, 0)
        override fun adlibInstrument(data: ByteArray) {}
        override fun release() { allocated = false }
    }
}

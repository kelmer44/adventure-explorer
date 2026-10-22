package adventureexplorer.audio.imuse

/**
 * Output side of the iMUSE sequencer, mirroring ScummVM's `MidiDriver` /
 * `MidiChannel` interface as used by iMUSE: channels are allocated per part and
 * receive high-level messages (transpose, detune and AdLib instruments are not
 * plain MIDI).
 */
interface ImuseDevice {
    fun allocateChannel(): ImuseChannel?
    fun percussionChannel(): ImuseChannel?
    /** Called on every 250 Hz driver tick (AdLib uses it for its software envelopes). */
    fun onTimer() {}
    /** Silence everything (stop or seek). */
    fun allNotesOff()
}

interface ImuseChannel {
    fun noteOn(note: Int, velocity: Int)
    fun noteOff(note: Int)
    fun programChange(program: Int)
    /** Bend in -8192..8191. */
    fun pitchBend(bend: Int)
    fun pitchBendFactor(semitones: Int)
    fun volume(value: Int)
    fun panPosition(value: Int)
    fun transpose(semitones: Int)
    fun detune(value: Int)
    fun priority(value: Int)
    fun sustain(on: Boolean)
    fun modulationWheel(value: Int)
    fun effectLevel(value: Int)
    fun chorusLevel(value: Int)
    fun allNotesOff()
    /** iMUSE AdLib instrument (30 bytes, ScummVM `AdLibInstrument` layout). Ignored by MIDI devices. */
    fun adlibInstrument(data: ByteArray)
    fun release()
}

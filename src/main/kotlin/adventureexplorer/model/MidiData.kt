package adventureexplorer.model

/**
 * A standard MIDI file (MThd/MTrk), ready to hand to javax.sound.midi so the
 * host system picks the synthesizer/instruments - no bespoke synth involved.
 */
data class MidiData(val bytes: ByteArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is MidiData) return false
        return bytes.contentEquals(other.bytes)
    }

    override fun hashCode(): Int = bytes.contentHashCode()
}

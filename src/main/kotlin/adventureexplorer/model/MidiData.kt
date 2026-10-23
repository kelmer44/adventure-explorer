package adventureexplorer.model

/**
 * A standard MIDI file (MThd/MTrk), playable through OPL or the Java synthesizer.
 * CMF also retains its source so OPL playback uses its own instruments and controllers.
 */
data class MidiData(val bytes: ByteArray, val cmfSource: ByteArray? = null) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is MidiData) return false
        return bytes.contentEquals(other.bytes) &&
            (cmfSource?.contentEquals(other.cmfSource) ?: (other.cmfSource == null))
    }

    override fun hashCode(): Int = 31 * bytes.contentHashCode() + (cmfSource?.contentHashCode() ?: 0)
}

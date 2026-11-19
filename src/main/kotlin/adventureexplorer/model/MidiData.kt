package adventureexplorer.model

/**
 * A standard MIDI file (MThd/MTrk), playable through OPL or the Java synthesizer.
 * CMF also retains its source so OPL playback uses its own instruments and controllers.
 */
data class MidiData(val bytes: ByteArray, val cmfSource: ByteArray? = null, val sciAdlib: SciAdlibSong? = null) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is MidiData) return false
        return bytes.contentEquals(other.bytes) &&
            (cmfSource?.contentEquals(other.cmfSource) ?: (other.cmfSource == null)) &&
            sciAdlib == other.sciAdlib
    }

    override fun hashCode(): Int = 31 * (31 * bytes.contentHashCode() + (cmfSource?.contentHashCode() ?: 0)) + (sciAdlib?.hashCode() ?: 0)
}

/**
 * A Sierra SCI song's AdLib arrangement: [midi] is the AdLib track as a standard MIDI file with the driver's
 * channel mapping and voice counts applied, [patch] is the game's `patch.003` instrument bank and [header] the
 * SCI0 channel header (empty for SCI1 and later). OPL playback uses these with Sierra's AdLib driver.
 */
class SciAdlibSong(
    val midi: ByteArray,
    val patch: ByteArray,
    val version: adventureexplorer.audio.SciSoundVersion,
    val header: ByteArray = ByteArray(0),
) {
    override fun equals(other: Any?): Boolean = other is SciAdlibSong && midi.contentEquals(other.midi) &&
        patch.contentEquals(other.patch) && version == other.version && header.contentEquals(other.header)

    override fun hashCode(): Int = ((midi.contentHashCode() * 31 + patch.contentHashCode()) * 31 + version.hashCode()) * 31 +
        header.contentHashCode()
}

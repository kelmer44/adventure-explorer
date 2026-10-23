package adventureexplorer.audio

/** Shared output choice for MIDI and native AdLib music previews and exports. */
enum class AdlibPlayback(val label: String, val luaName: String) {
    /** Embedded AdLib instruments, or a GM FM bank, on [Opl3] in OPL2 mode. */
    OPL("Nuked OPL3 emulation (OPL2)", "opl"),

    /** A General MIDI conversion played by Java's built-in MIDI synthesizer. */
    MIDI("Java MIDI synthesizer (General MIDI)", "midi");

    companion object {
        /** App-wide choice; the UI restores it from preferences at startup. */
        @Volatile var current: AdlibPlayback = OPL

        fun parse(name: String?): AdlibPlayback = entries.firstOrNull { it.name == name } ?: OPL
    }
}

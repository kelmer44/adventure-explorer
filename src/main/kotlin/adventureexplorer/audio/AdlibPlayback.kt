package adventureexplorer.audio

/** How AdLib music that can be played either way is previewed and exported. */
enum class AdlibPlayback(val label: String, val luaName: String) {
    /** The game's own instruments on an emulated OPL2 chip ([Opl3], a Nuked OPL3 port). */
    OPL("Nuked OPL3 emulation (OPL2)", "opl"),

    /** A General MIDI conversion played by Java's built-in MIDI synthesizer. */
    MIDI("Java MIDI synthesizer (General MIDI)", "midi");

    companion object {
        /** App-wide choice; the UI restores it from preferences at startup. */
        @Volatile var current: AdlibPlayback = OPL

        fun parse(name: String?): AdlibPlayback = entries.firstOrNull { it.name == name } ?: OPL
    }
}

package adventureexplorer.audio.imuse

import adventureexplorer.model.ResourceNode
import adventureexplorer.scripting.ScriptManager
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Installed MI2 / Fate of Atlantis / DOTT: every iMUSE MIDI chunk parses and AdLib songs render. */
class ImuseGamesTest {
    private fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }

    private fun check(env: String, songs: Int, hooks: Int, armable: Int, tags: Map<String, Int>) {
        val path = System.getenv(env)
        assumeTrue("Set $env to the game folder", path != null)
        val mgr = ScriptManager()
        try {
            val leaves = leaves(mgr.detectGame(path!!)!!.resources).filter { it.id.startsWith("snd:") && it.type == "midi" }
            val loaded = leaves.map { mgr.loadResource(path, it.id) }
            assertTrue("every MIDI chunk is an iMUSE song with its MIDI file", loaded.all { it?.imuse != null && it.midiData != null })
            val parsed = loaded.map { it!!.imuse!! }
            assertEquals(songs, parsed.size)
            assertEquals(hooks, parsed.sumOf { s -> s.catalogue.count { it is ImuseSong.CatalogueEntry.Hook } })
            assertEquals(armable, parsed.sumOf { it.armableHooks.size })
            assertEquals(tags, parsed.groupingBy { it.tag }.eachCount())
            assertTrue(loaded.filter { it!!.imuse!!.isAdlib }.all { it!!.playbackChoice })
            for (song in parsed.filter { it.isAdlib }.filterIndexed { i, _ -> i % 50 == 0 }) {
                assertNotNull(ImusePlayback.renderOpl(song))
            }
        } finally { mgr.close() }
    }

    @Test fun `Monkey Island 2`() = check("MONKEY2_TEST_PATH", 405, 4261, 263, mapOf("ROL " to 144, "ADL " to 194, "SPK " to 67))

    @Test fun `Fate of Atlantis`() = check("ATLANTIS_TEST_PATH", 456, 3609, 197, mapOf("ROL " to 204, "ADL " to 200, "SPK " to 52))

    @Test fun `Day of the Tentacle`() = check("DOTT_TEST_PATH", 303, 3692, 195, mapOf("ROL " to 101, "ADL " to 101, "GMD " to 101))

    @Test fun `arming a Monkey Island 2 transition hook changes where the song goes`() {
        val path = System.getenv("MONKEY2_TEST_PATH")
        assumeTrue("Set MONKEY2_TEST_PATH to the game folder", path != null)
        val mgr = ScriptManager()
        try {
            mgr.detectGame(path!!)
            val song = mgr.loadResource(path, "snd:MONKEY2:116:ADL_")!!.imuse!!
            assertEquals(20, song.tracks.size)
            fun play(arm: Boolean): List<ImuseEvent> {
                val events = mutableListOf<ImuseEvent>()
                val device = AdlibOplDevice(adventureexplorer.audio.Opl3(44_100))
                val seq = ImuseSequencer(song, device) { events += it }
                if (arm) seq.armHook(ImuseSong.HookKind.JUMP, 1)
                repeat(ImuseSequencer.TIMER_HZ * 60) { if (seq.active) { seq.onTimer(); device.onTimer() } }
                return events
            }
            // Unarmed, the song loops on track 0; with hook 1 it leaves for track 1 at beat 8.400 and ends there.
            assertTrue(play(false).filterIsInstance<ImuseEvent.Jumped>().all { it.to.track == 0 })
            val armed = play(true)
            val transition = armed.filterIsInstance<ImuseEvent.Jumped>().single { it.hookId == 1 }
            assertEquals(ImuseSong.Position(0, 8, 400), transition.from)
            assertEquals(ImuseSong.Position(1, 4, 400), transition.to)
            assertTrue(armed.last() is ImuseEvent.Ended)
        } finally { mgr.close() }
    }
}

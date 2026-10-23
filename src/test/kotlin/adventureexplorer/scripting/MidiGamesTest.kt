package adventureexplorer.scripting

import adventureexplorer.audio.AdlibPlayback
import adventureexplorer.audio.imuse.ImusePlayback
import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/** One real song from each installed MIDI engine, exercising the shared output choice. */
class MidiGamesTest {
    @Test fun `installed MIDI games offer both outputs and render OPL audio`() {
        val root = System.getenv("MIDI_GAMES_TEST_PATH")
        assumeTrue("Set MIDI_GAMES_TEST_PATH to the installed games directory", root != null)
        val previous = AdlibPlayback.current
        fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
        try {
            for (folder in listOf("IGOR", "Touche", "AGOS/SIMON", "AGOS/SIMON2", "INTERSPECTIVE/GENE",
                "LGOP2", "LURE", "TAKE2/B13", "IHNMAIMS", "AMAZON", "RIDDLE", "DARKSEED", "SKY", "SCUMM/DOTT")) {
                val path = File(root, folder).path
                val manager = ScriptManager()
                try {
                    val game = manager.detectGame(path) ?: error("No engine for $folder")
                    val node = leaves(game.resources).firstOrNull { it.type == "midi" } ?: error("No MIDI for $folder")
                    AdlibPlayback.current = AdlibPlayback.MIDI
                    val midi = manager.loadResource(path, node.id) ?: error("$folder: ${node.id}")
                    assertTrue(folder, midi.playbackChoice)
                    assertNotNull(folder, midi.midiData)
                    assertNull(folder, midi.soundData)
                    manager.releaseDecodedResources()
                    AdlibPlayback.current = AdlibPlayback.OPL
                    val opl = manager.loadResource(path, node.id) ?: error("$folder: OPL failed")
                    assertTrue(folder, opl.playbackChoice)
                    assertEquals(folder, midi.midiData, opl.midiData)
                    val sound = opl.soundData ?: opl.imuse?.let(ImusePlayback::renderOpl)
                    assertNotNull(folder, sound)
                    assertTrue("$folder: silent OPL output", sound!!.samples.any { it != 0.toByte() })
                    println("$folder (${game.engineId}): ${node.id}, ${sound.durationMs} ms OPL; MIDI preserved")
                } finally { manager.close() }
            }
        } finally { AdlibPlayback.current = previous }
    }
}

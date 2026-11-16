package adventureexplorer.scripting

import adventureexplorer.app.ResourceExporter
import adventureexplorer.audio.AdlibPlayback
import adventureexplorer.model.ResourceNode
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import javax.sound.midi.MidiSystem
import javax.sound.midi.ShortMessage

/** Sierra SCI sound resources (type 4) play as MIDI, or as PCM when they hold a digital sample. */
class SciMusicTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun leaves(nodes: List<ResourceNode>): List<ResourceNode> =
        nodes.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }

    private fun noteOns(bytes: ByteArray): Int =
        MidiSystem.getSequence(bytes.inputStream()).tracks.sumOf { track ->
            (0 until track.size()).count {
                val message = track.get(it).message
                message is ShortMessage && message.command == ShortMessage.NOTE_ON && message.data2 > 0
            }
        }

    @Test fun `SCI sounds load as playable MIDI with OPL and MIDI output and export`() = runBlocking {
        val path = System.getenv("SCI_TEST_PATH")
        assumeTrue("Set SCI_TEST_PATH to a Sierra SCI game folder with RESOURCE.MAP, such as Larry 6", path != null)
        val previous = AdlibPlayback.current
        val manager = ScriptManager()
        try {
            val game = manager.detectGame(path!!)!!
            assertEquals("sci", game.engineId)
            val songs = leaves(game.resources).filter { it.type == "midi" }
            assertTrue("No MIDI sounds listed", songs.isNotEmpty())

            // The first song with real notes must parse as a standard MIDI file.
            val node = songs.first { node ->
                val midi = manager.loadResource(path, node.id)?.midiData
                midi != null && noteOns(midi.bytes) > 20
            }
            AdlibPlayback.current = AdlibPlayback.MIDI
            val midi = manager.loadResource(path, node.id)!!
            assertTrue(midi.playbackChoice)
            assertNull(midi.soundData)
            manager.releaseDecodedResources()

            AdlibPlayback.current = AdlibPlayback.OPL
            val opl = manager.loadResource(path, node.id)!!
            assertTrue(opl.playbackChoice)
            assertArrayEquals(midi.midiData!!.bytes, opl.midiData!!.bytes)
            assertTrue("silent OPL output", opl.soundData!!.samples.any { it != 0.toByte() })

            val output = temporary.newFolder("export")
            val exported = ResourceExporter({ midi }).export(listOf(ResourceNode(node.id, node.name, "midi")), output)
            assertEquals(1, exported.exported)
            val file = output.walkTopDown().single { it.isFile && it.extension == "mid" }
            assertArrayEquals(midi.midiData!!.bytes, file.readBytes())
            println("${game.engineName}: ${songs.size} songs; ${node.id} ${opl.description} ${opl.soundData!!.durationMs} ms OPL")

            // Every listed song and sample resolves to the type the tree promised.
            AdlibPlayback.current = AdlibPlayback.MIDI
            for (leaf in leaves(game.resources).filter { it.type == "midi" || it.type == "sound" }.take(60)) {
                val data = manager.loadResource(path, leaf.id) ?: error("${leaf.id} did not load")
                if (leaf.type == "midi") assertNotNull(leaf.id, data.midiData) else assertNotNull(leaf.id, data.soundData)
                manager.releaseDecodedResources()
            }
        } finally { AdlibPlayback.current = previous; manager.close() }
    }
}

package adventureexplorer.scripting

import adventureexplorer.audio.AdlibPlayback
import adventureexplorer.audio.MidiOplRendererTest
import adventureexplorer.app.ResourceExporter
import adventureexplorer.model.ResourceNode
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class MidiOutputTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun `every MIDI host API offers OPL WAV and MIDI output without engine opt-in`() = runBlocking {
        val scripts = temporary.newFolder("engines")
        val script = File(scripts, "fixture/engine.lua").apply { parentFile.mkdirs() }
        script.writeText("""
            return {
                id = 'midi-fixture', name = 'MIDI fixture', detect = function() return true end,
                get_resources = function() return {} end,
                load_resource = function(path, id)
                    local f = file_open(path .. '/' .. id)
                    local bytes = file_read(f, 0, file_size(f)); file_close(f)
                    local create = ({raw = midi_create_raw, xmi = midi_create_from_xmi,
                        cmf = midi_create_from_cmf, auto_cmf = midi_create_auto, gmf = midi_create_auto})[id]
                    return {type = 'midi', midi = create(bytes)}
                end
            }
        """.trimIndent())
        val game = temporary.newFolder("game")
        val raw = byteArrayOf(77,84,104,100, 0,0,0,6, 0,0,0,1,0,96,
            77,84,114,107, 0,0,0,12, 0,0x90.toByte(),60,100, 24,0x80.toByte(),60,0, 0,0xFF.toByte(),0x2F,0)
        File(game, "raw").writeBytes(raw)
        File(game, "cmf").writeBytes(MidiOplRendererTest.cmfFixture())
        File(game, "auto_cmf").writeBytes(MidiOplRendererTest.cmfFixture())
        File(game, "gmf").writeBytes("GMF".toByteArray() + byteArrayOf(1,0,4,1, 0,0x90.toByte(),60,100, 24,0x80.toByte(),60,0, 0,0,0))
        // XMIDI note-on with embedded duration, then end of track.
        File(game, "xmi").writeBytes("EVNT".toByteArray() + byteArrayOf(0,0,0,8, 0x90.toByte(),60,100,24, 0xFF.toByte(),0x2F,0,0))
        val manager = ScriptManager()
        ScriptManager::class.java.getDeclaredField("scriptsDir").apply { isAccessible = true }.set(manager, scripts)
        val previous = AdlibPlayback.current
        try {
            assertNotNull(manager.detectGame(game.path))
            for (id in listOf("raw", "xmi", "gmf", "cmf", "auto_cmf")) {
                AdlibPlayback.current = AdlibPlayback.OPL
                val opl = manager.loadResource(game.path, id)!!
                assertTrue(id, opl.playbackChoice)
                assertNotNull(id, opl.soundData)
                assertTrue(id, opl.soundData!!.samples.any { it != 0.toByte() })
                assertNotNull(id, opl.midiData)
                if (id.contains("cmf")) assertNotNull(opl.midiData!!.cmfSource)
                val output = temporary.newFolder("opl-$id")
                val node = ResourceNode(id, id, "midi")
                assertEquals(1, ResourceExporter({ opl }).export(listOf(node), output).exported)
                assertTrue(File(output, "$id.wav").isFile)

                AdlibPlayback.current = AdlibPlayback.MIDI
                val midi = manager.loadResource(game.path, id)!!
                assertTrue(midi.playbackChoice)
                assertNull(midi.soundData)
                assertArrayEquals(opl.midiData!!.bytes, midi.midiData!!.bytes)
                val midiOutput = temporary.newFolder("midi-$id")
                assertEquals(1, ResourceExporter({ midi }).export(listOf(node), midiOutput).exported)
                assertArrayEquals(midi.midiData!!.bytes, File(midiOutput, "$id.mid").readBytes())
                manager.releaseDecodedResources()
            }
        } finally { AdlibPlayback.current = previous; manager.close() }
    }
}

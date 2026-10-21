package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaValue
import java.io.ByteArrayInputStream
import javax.sound.midi.MidiSystem
import javax.sound.midi.ShortMessage

class SkyAudioTextTest {
    private fun lua(b: ByteArray): LuaValue = LuaString.valueOf(b)
    private fun raw(v: LuaValue) = v.checkstring().let { s -> ByteArray(s.length()).also { s.copyInto(0, it, 0, it.size) } }
    private fun <T> withExtra(block: (LuaValue) -> T): T {
        val engine = LuaEngine()
        try { return block(engine.loadScript("scripts/engines/sky/sky_extra.lua")) } finally { engine.cleanup() }
    }
    private fun ByteArray.word(at: Int, v: Int) { this[at] = v.toByte(); this[at + 1] = (v shr 8).toByte() }
    private fun ByteArray.put(at: Int, vararg b: Int) = b.forEachIndexed { i, x -> this[at + i] = x.toByte() }

    @Test fun `GM sequencer channels become MIDI tracks with mapped instruments and tempo`() = withExtra { x ->
        val d = ByteArray(0x900)
        val loc = 0x800
        d.word(0x7DC, loc)
        d[loc] = 1                     // one song
        d.word(loc + 1, 3)             // song pointer table at loc + 3
        d.word(loc + 3, 5)             // song 1 at loc + 5
        d.put(loc + 5, 0x78, 0xC0, 1)  // tempo0, tempo1, one channel
        d.word(loc + 8, 10)            // channel data at loc + 10
        // delay 0; instrument 0x10; delay 0; note 60 velocity 0x7F; delay 24; key off; delay 0; stop
        d.put(loc + 10, 0x00, 0x92, 0x10, 0x00, 0x3C, 0x7F, 0x18, 0x99, 0x00, 0x91)
        assertEquals(1, x.get("song_count").call(lua(d), LuaValue.valueOf(331)).toint())
        val midi = raw(x.get("song_to_midi").call(lua(d), LuaValue.valueOf(331), LuaValue.valueOf(1)))
        val seq = MidiSystem.getSequence(ByteArrayInputStream(midi))
        assertEquals(24, seq.resolution)
        assertEquals(2, seq.tracks.size)
        val events = seq.tracks[1].let { t -> (0 until t.size()).map { t.get(it) } }
            .mapNotNull { e -> (e.message as? ShortMessage)?.let { Triple(e.tick, it.command, it.data1 to it.data2) } }
        assertTrue(Triple(0L, ShortMessage.PROGRAM_CHANGE, 6 to 0) in events)    // MT-32 0x10 -> GM 6
        assertTrue(Triple(0L, ShortMessage.NOTE_ON, 60 to 0x7F) in events)       // veloTab[0x7F]
        assertTrue(Triple(24L, ShortMessage.NOTE_ON, 60 to 0) in events)         // key off
        // 60,000,000 / (0x78 * 0xC0) us per tick at 24 ticks per quarter
        val tempo = seq.tracks[0].let { t -> (0 until t.size()).map { t.get(it).message } }
            .first { it.status == 0xFF && it.message[1] == 0x51.toByte() }.message
        assertEquals(24 * 60_000_000 / (0x78 * 0xC0), ((tempo[3].toInt() and 255) shl 16) or ((tempo[4].toInt() and 255) shl 8) or (tempo[5].toInt() and 255))
    }

    @Test fun `sound driver tables give big-endian rates offsets and sizes`() = withExtra { x ->
        val d = ByteArray(0x400)
        val asm = 0x7E
        d.put(asm, 0x3C, 1); d.put(asm + 0x27, 0x8D, 0x1E); d.put(asm + 0x2F, 0x8D, 0x36)
        d.word(asm + 0x29, 0x100)       // sample rate table
        d.word(asm + 0x31, 0x200)       // sfx base
        d.put(0x100, 0x2B, 0x11, 0, 0, 0x1F, 0x40)               // 11025 Hz, then 8000 Hz
        d.put(0x200 + 8, 0x00, 0x02, 0x00, 0x40)                 // sound 1: paragraph 2, 64 bytes
        val sounds = x.get("parse_sfx").call(lua(d), LuaValue.valueOf(331))
        assertEquals(1, sounds.length())
        assertEquals(1, sounds.get(1).get("index").toint())
        assertEquals(8000, sounds.get(1).get("rate").toint())
        assertEquals(0x200 + 0x20, sounds.get(1).get("offset").toint())
        assertTrue(x.get("parse_sfx").call(lua(ByteArray(0x400)), LuaValue.valueOf(331)).isnil())
    }

    @Test fun `game charset codes map to accented letters`() = withExtra { x ->
        val text = byteArrayOf(0x8A.toByte(), 'Q'.code.toByte(), 'u'.code.toByte(), 0x2B, ' '.code.toByte(), 'W'.code.toByte(), 'e'.code.toByte(), 'i'.code.toByte(), 0x28, 't'.code.toByte())
        assertEquals("¿Qué Weißt", String(raw(x.get("to_unicode").call(lua(text))), Charsets.UTF_8))
    }

    @Test fun `installed Beneath a Steel Sky floppy lists sounds, music and eight languages of text`() {
        val path = System.getenv("SKY_TEST_PATH")
        assumeTrue("Set SKY_TEST_PATH to Beneath a Steel Sky (SKY.DSK + SKY.DNR)", path != null)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path!!)!!
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val all = leaves(game.resources)
            assertEquals(30, all.count { it.type == "midi" })
            assertEquals(64, all.count { it.id.startsWith("sky_txt_") })
            assertEquals(142, all.count { it.type == "sound" })
            for (node in all.filter { it.type == "midi" }) {
                val seq = MidiSystem.getSequence(ByteArrayInputStream(mgr.loadResource(path, node.id)!!.midiData!!.bytes))
                assertTrue(node.id, seq.tracks.sumOf { t -> (0 until t.size()).count { (t.get(it).message as? ShortMessage)?.command == ShortMessage.NOTE_ON } } > 0)
            }
            for (node in all.filter { it.type == "sound" }) assertTrue(node.id, mgr.loadResource(path, node.id)!!.soundData!!.samples.isNotEmpty())
            fun text(id: String) = mgr.loadResource(path, id)!!.textContent!!
            assertTrue(text("sky_txt_0_2").contains("0x2001  What are YOU doing HERE?"))
            assertTrue(text("sky_txt_1_2").contains("0x2002  Weißt Du wer ich bin, Bürschchen?"))
            assertTrue(text("sky_txt_4_2").contains("0x2001  Vad gör DU här?"))
            assertTrue(text("sky_txt_6_2").contains("0x2003  Não faço a menor IDEIA."))
            assertTrue(text("sky_txt_7_2").contains("0x2002  ¿SABES quién soy YO, chico?"))
            assertNotNull(mgr.loadResource(path, "sky_font_60150")!!.image)
        } finally { mgr.close() }
    }
}

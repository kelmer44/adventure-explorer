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

class ScummV4AudioFontTest {
    private fun bytes(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }
    private fun lua(b: ByteArray): LuaValue = LuaString.valueOf(b)
    private fun raw(v: LuaValue): ByteArray = v.checkstring().let { s -> ByteArray(s.length()).also { s.copyInto(0, it, 0, it.size) } }
    private fun <T> withV4(block: (LuaValue) -> T): T {
        val engine = LuaEngine()
        try { return block(engine.loadScript("scripts/engines/scumm/scumm_v4.lua")) } finally { engine.cleanup() }
    }
    private fun notes(midi: ByteArray): List<Pair<Long, Int>> {
        val seq = MidiSystem.getSequence(ByteArrayInputStream(midi))
        return seq.tracks.single().let { t -> (0 until t.size()).map { t.get(it) } }
            .filter { (it.message as? ShortMessage)?.command == ShortMessage.NOTE_ON && (it.message as ShortMessage).data2 > 0 }
            .map { it.tick to (it.message as ShortMessage).data1 }
    }

    @Test fun `Roland RO streams become 120 PPQN MIDI with delays and program changes`() = withV4 { v ->
        // Small header (u32 size + "RO"), program 5, note on, Ax marker, F0 delay, F1 long delay, note on, end.
        val ro = bytes(0, 0, 0, 0, 'R'.code, 'O'.code, 0xC0, 5, 0x90, 60, 100, 0xA0, 0xF0, 0x10, 0xF1, 0x04,
            0x90, 62, 90, 0x00, 0x90, 64, 1)
        val midi = raw(v.get("ro_to_midi").call(lua(ro)))
        val seq = MidiSystem.getSequence(ByteArrayInputStream(midi))
        assertEquals(120, seq.resolution)
        assertEquals(listOf(0L to 60, (0x10 + 0x04 + 256).toLong() to 62), notes(midi))
    }

    @Test fun `AdLib music skips the instrument header and stops at end of track`() = withV4 { v ->
        val header = ByteArray(2 + 0x11 + 128).also { it[2] = 0x80.toByte(); it[3] = 128.toByte() }
        val track = bytes(0x90, 60, 100, 0x60, 0x80, 60, 0, 0x00, 0xFF, 0x2F, 0x00, 0xEE, 0xEE)
        val midi = raw(v.get("ad_to_midi").call(lua(header + track)))
        val seq = MidiSystem.getSequence(ByteArrayInputStream(midi))
        assertEquals(480, seq.resolution)
        assertEquals(listOf(160L to 60), notes(midi)) // ScummVM's initial ppqn/3 delay
        assertArrayEquals(bytes(0x00, 0xFF, 0x2F, 0x00), midi.copyOfRange(midi.size - 4, midi.size))
        // Tempo 500000 * 256 / ticks
        assertTrue(midi.toList().windowed(6).any { it == bytes(0xFF, 0x51, 3, 0x0F, 0x42, 0x40).toList() })
        // Sound effects (no 0x80 marker) are not music
        assertTrue(v.get("ad_to_midi").call(lua(ByteArray(200))).isnil())
    }

    @Test fun `charset glyphs decode a continuous bit stream`() = withV4 { v ->
        // 21 bytes before the font data, then bpp, height, u16 count, u32 offsets, glyph.
        val glyph = bytes(3, 2, 0, 0, 0b1011_1000)
        val font = ByteArray(21) + bytes(1, 2, 2, 0, 0, 0, 0, 0, 12, 0, 0, 0) + glyph
        val parsed = v.get("parse_charset").call(lua(font))
        assertEquals(1, parsed.get("bpp").toint())
        val g = parsed.get("glyphs").get(1)
        assertEquals(1, g.get("code").toint())
        assertEquals(listOf(1, -1, 1, 1, 1, -1), (1..6).map { g.get("pixels").get(it).toint() })
        assertTrue(v.get("parse_charset").call(lua(ByteArray(40))).isnil())
    }

    @Test fun `installed Monkey Island VGA floppy decodes rooms, costumes, music and fonts`() {
        val path = System.getenv("MONKEY_VGA_TEST_PATH")
        assumeTrue("Set MONKEY_VGA_TEST_PATH to Monkey Island 1 VGA floppy (SCUMM V4)", path != null)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path!!)!!
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val all = leaves(game.resources)
            // 83 rooms; 88 and 94 are script-only (height 0, empty bitmap)
            assertEquals(81, all.count { it.id.startsWith("v4:bg:") })
            assertEquals(81, all.count { it.id.startsWith("v4:pal:") })
            assertEquals(38, all.count { it.type == "midi" })
            assertEquals(mgr.defaultPaletteFor(path, "v4:bg:28"), "v4:pal:28")

            val bar = mgr.loadResource(path, "v4:comp:28")!!
            assertEquals(640 to 144, bar.image!!.width to bar.image!!.height)
            assertEquals(49, bar.layers!!.size)
            // V4 object strips only use opaque codecs; positions come from OC in 8-pixel units
            assertTrue(bar.layers!!.drop(1).all { l ->
                l.x % 8 == 0 && l.y % 8 == 0 && l.x + l.image.width <= 640 && l.y + l.image.height <= 144 &&
                (0 until l.image.height).all { y -> (0 until l.image.width).all { x -> l.image.getRGB(x, y) ushr 24 == 0xFF } } })

            // AdLib (100) and Roland (150) carry the same 754-note score
            val adlib = notes(mgr.loadResource(path, "v4:snd:100")!!.midiData!!.bytes)
            val roland = notes(mgr.loadResource(path, "v4:snd:150")!!.midiData!!.bytes)
            assertEquals(754, adlib.size)
            assertEquals(754, roland.size)
            for (node in all.filter { it.type == "midi" }) {
                MidiSystem.getSequence(ByteArrayInputStream(mgr.loadResource(path, node.id)!!.midiData!!.bytes))
            }
            for (node in all.filter { it.id.startsWith("v4:font:") || it.id.startsWith("v4:sheet:") }) {
                assertNotNull(node.id, mgr.loadResource(path, node.id, mgr.defaultPaletteFor(path, node.id))?.image)
            }
        } finally { mgr.close() }
    }
}

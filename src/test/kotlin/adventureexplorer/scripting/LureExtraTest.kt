package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaValue

class LureExtraTest {
    private fun lua(b: ByteArray): LuaValue = LuaString.valueOf(b)
    private fun raw(v: LuaValue) = v.checkstring().let { s -> ByteArray(s.length()).also { s.copyInto(0, it, 0, it.size) } }
    private fun <T> withExtra(block: (LuaValue) -> T): T {
        val engine = LuaEngine()
        try { return block(engine.loadScript("scripts/engines/lure/lure_extra.lua")) } finally { engine.cleanup() }
    }

    @Test fun `string decoder table and bit stream follow StringData`() = withExtra { x ->
        // ' ' = "0", 'a' = "10", end of string = "11" (first bit = lowest bit of the value)
        val table = byteArrayOf(' '.code.toByte(), '0'.code.toByte(), 0, 'a'.code.toByte(), '1'.code.toByte(), '0'.code.toByte(), 0,
            0, '1'.code.toByte(), '1'.code.toByte(), 0, 0xFF.toByte())
        val codes = x.get("parse_decoder").call(lua(table))
        // String table: u16 skip area at 8, u16 data at 8, no blocks. String 0 starts at bit 0:
        // 0 (no skip), 0 (no articles), 'a' = 1 0, ' ' = 0, 'a' = 1 0, end = 1 1 -> 0010 0101 1000
        val t = byteArrayOf(8, 0, 8, 0, 0, 0, 0, 0, 0b0010_0101, 0b1000_0000.toByte())
        val tables = LuaValue.tableOf().also { it.set(0, lua(t)) }
        assertEquals("a a", x.get("decode").invoke(LuaValue.varargsOf(arrayOf(tables, codes, LuaValue.NIL, LuaValue.valueOf(0)))).arg1().tojstring())
    }

    @Test fun `packed MIDI expands its word dictionary`() = withExtra { x ->
        val words = ByteArray(512).also { "MThd\u0000\u0000".toByteArray().copyInto(it) }   // words 0..2 = "MT" "hd" 00 00
        val packed = byteArrayOf('C'.code.toByte()) + words + byteArrayOf(0, 1, 2)
        assertEquals("MThd\u0000\u0000", String(raw(x.get("unpack_midi").call(lua(packed))), Charsets.ISO_8859_1))
        // 'c' drops the first output byte, so the result is no longer a MIDI file
        assertTrue(x.get("unpack_midi").call(lua(byteArrayOf('c'.code.toByte()) + words + byteArrayOf(0, 1, 2))).isnil())
        assertTrue(x.get("unpack_midi").call(lua("RIFF....".toByteArray())).isnil())
    }

    @Test fun `installed Lure with lure_dat lists music, text and character animations`() {
        val path = System.getenv("LURE_TEST_PATH")
        assumeTrue("Set LURE_TEST_PATH to a folder with DISK1-4.VGA and ScummVM's lure.dat", path != null)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path!!)!!
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val all = leaves(game.resources)
            assertEquals(162, all.count { it.type == "midi" })
            assertEquals(102, all.count { it.id.startsWith("lure_anim_") })
            for (node in all.filter { it.type == "midi" }) assertNotNull(node.id, mgr.loadResource(path, node.id)?.midiData)
            val text = mgr.loadResource(path, "lure_txt_0")!!
            assertTrue(text.description!!.contains("Spanish"))
            assertTrue(text.textContent!!.contains("   1  La celda"))
            assertTrue(text.textContent!!.contains("   3  El cuarto de guardia"))
            val hero = mgr.loadResource(path, "lure_anim_03e8")!!
            assertEquals(36, hero.frames!!.size)
            assertEquals(32 to 48, hero.frames!![0].width to hero.frames!![0].height)
            for (node in all.filter { it.id.startsWith("lure_anim_") }) {
                val r = mgr.loadResource(path, node.id)
                assertTrue(node.id, r?.image != null || !r?.frames.isNullOrEmpty())
            }
        } finally { mgr.close() }
    }
}

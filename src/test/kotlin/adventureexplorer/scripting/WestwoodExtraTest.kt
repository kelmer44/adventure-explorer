package adventureexplorer.scripting

import adventureexplorer.audio.XmiToMidiConverter
import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaValue
import org.luaj.vm2.lib.ThreeArgFunction
import java.io.File

class WestwoodExtraTest {
    private fun lua(b: ByteArray): LuaValue = LuaString.valueOf(b)
    private fun bytes(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }
    private fun <T> withW(block: (LuaValue) -> T): T {
        val engine = LuaEngine()
        try { return block(engine.loadScript(File("scripts/engines/shared/westwood.lua").absolutePath)) } finally { engine.cleanup() }
    }
    private fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }

    @Test fun `coded strings expand letter pairs and escapes`() = withW { w ->
        // 0x80 -> T1[0] ' ' + T2[0] 't'; 0x1B 0x02 -> 0x81 (code page 437 ü)
        val decoded = w.get("decode_string").call(lua(bytes('a'.code, 0x80, 0x1B, 0x02))).checkstring()
        assertArrayEquals(bytes('a'.code, ' '.code, 't'.code, 0x81), ByteArray(decoded.length()).also { decoded.copyInto(0, it, 0, it.size) })
    }

    @Test fun `string tables and script TEXT chunks list their strings`() = withW { w ->
        val table = bytes(4, 0, 7, 0, 'H'.code, 'i'.code, 0, 'b'.code, 0x1B, 0x02, 0)
        val t = w.get("table_strings").call(lua(table))
        assertEquals("Hi", t.get(1).tojstring())
        assertEquals("bü", t.get(2).tojstring())
        val text = bytes(0, 4, 0, 6, 'A'.code, 0, 'B'.code, 'C'.code, 0)
        val emc = "FORM".toByteArray() + bytes(0, 0, 0, 4 + 8 + text.size) + "EMC2".toByteArray() +
            "TEXT".toByteArray() + bytes(0, 0, 0, text.size) + text
        val s = w.get("emc_text").call(lua(emc))
        assertEquals(2, s.length())
        assertEquals("BC", s.get(2).tojstring())
    }

    @Test fun `raw shapes decode transparent runs and colour tables`() = withW { w ->
        // one shape, flags 3 (colour table, uncompressed), 1 x 3, rows: 5, 0 1 (skip), 7
        val shape = bytes(3, 0, 1, 3, 0, 0, 0, 0, 4, 0) + ByteArray(16) { (it + 0x40).toByte() } + bytes(5, 0, 1, 7)
        val file = bytes(1, 0, 4, 0, 0, 0) + shape
        val noLcw = object : ThreeArgFunction() { override fun call(a: LuaValue, b: LuaValue, c: LuaValue): LuaValue = LuaValue.tableOf() }
        val px = w.get("decode_shape").invoke(LuaValue.varargsOf(arrayOf(lua(file), LuaValue.valueOf(0), noLcw))).arg1()
        assertEquals(listOf(0x45, 256, 0x47), (1..3).map { px.get(it).toint() })
    }

    @Test fun `XMI note counts flag empty sequences`() {
        fun chunk(id: String, payload: ByteArray) =
            id.toByteArray() + bytes(0, 0, 0, payload.size) + payload + ByteArray(payload.size % 2) // IFF pad byte
        // sequence 0: one note (on + duration), sequence 1: end of track only
        val notes = chunk("FORM", "XMID".toByteArray() + chunk("EVNT", bytes(0x90, 60, 100, 10, 0xFF, 0x2F, 0)))
        val empty = chunk("FORM", "XMID".toByteArray() + chunk("EVNT", bytes(0xFF, 0x2F, 0)))
        val cat = chunk("CAT ", "XMID".toByteArray() + notes + empty)
        assertEquals(listOf(1, 0), XmiToMidiConverter.noteCounts(cat))
        assertEquals(2, XmiToMidiConverter.sequenceCount(cat))
        assertNotNull(XmiToMidiConverter.convert(cat, 0))
    }

    @Test fun `installed Kyrandia games list music, sounds, text, fonts and shapes`() {
        val k1 = System.getenv("KYRA1_TEST_PATH")
        val k2 = System.getenv("KYRA2_TEST_PATH")
        assumeTrue("Set KYRA1_TEST_PATH and KYRA2_TEST_PATH to Kyrandia 1 and Hand of Fate", k1 != null && k2 != null)
        val mgr = ScriptManager()
        try {
            val one = leaves(mgr.detectGame(k1!!)!!.resources)
            assertEquals(90, one.count { it.id.startsWith("ww_emc") })
            assertEquals(4, one.count { it.id.startsWith("ww_fnt") })
            assertTrue(mgr.loadResource(k1, "ww_emc||ALCHEMY.EMC|0")!!.textContent!!.contains("el dormitorio de Zanthia"))
            for (node in one.filter { it.id.startsWith("ww_") }) assertNotNull(node.id, mgr.loadResource(k1, node.id))

            val two = leaves(mgr.detectGame(k2!!)!!.resources)
            assertEquals(191, two.count { it.id.startsWith("ww_voc") })
            assertEquals(126, two.count { it.id.startsWith("ww_shp") })
            assertTrue(mgr.loadResource(k2, "ww_tbl|other.pak|C_CODE.GER|0")!!.textContent!!.contains("Lösche gespeicherten Spielstand"))
            val zanthia = mgr.loadResource(k2, "ww_shp|cost1_sh.pak|_Z1.SHP|0")!!.image!!
            assertTrue((0 until zanthia.width).any { x -> (0 until zanthia.height).any { y -> zanthia.getRGB(x, y) and 0xFFFFFF != 0xFFFFFF && zanthia.getRGB(x, y) ushr 24 != 0 } })
            for (node in two.filter { it.id.startsWith("ww_") }) assertNotNull(node.id, mgr.loadResource(k2, node.id))
        } finally { mgr.close() }
    }
}

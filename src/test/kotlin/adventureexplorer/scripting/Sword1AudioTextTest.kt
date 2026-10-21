package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaValue

class Sword1AudioTextTest {
    private fun lua(b: ByteArray): LuaValue = LuaString.valueOf(b)
    private fun le(vararg w: Int) = ByteArray(w.size * 4) { (w[it / 4] ushr (8 * (it % 4))).toByte() }
    private fun <T> withExtra(block: (LuaValue) -> T): T {
        val engine = LuaEngine()
        try { return block(engine.loadScript("scripts/engines/sword1/sword1_extra.lua")) } finally { engine.cleanup() }
    }

    @Test fun `speech cluster header maps rooms to absolute clip offsets`() = withExtra { x ->
        // header size 44 -> 10 words: room table [room 0 -> word 2, room 1 -> word 7];
        // a room's line k has its offset at word loc + 2k - 1 and its size at loc + 2k
        val head = le(44, 2 * 4, 7 * 4, 0, 1000, 50, 0, 0, 0, 2000, 70)
        val rooms = x.get("parse_cow").call(lua(head))
        assertEquals(2, rooms.length())
        val r0 = rooms.get(1)
        assertEquals(0, r0.get("room").toint())
        assertEquals(1, r0.get("lines").length())                 // second slot is empty
        assertEquals(1000, r0.get("lines").get(1).get("offset").toint())
        assertEquals(50, r0.get("lines").get(1).get("size").toint())
        assertEquals(2000, rooms.get(2).get("lines").get(1).get("offset").toint())
    }

    @Test fun `text resources skip the header and decode Latin-1`() = withExtra { x ->
        val strings = "Café\u0000Two\u0000".toByteArray(Charsets.ISO_8859_1)
        val data = ByteArray(20) + le(3, 16, 0, 21) + strings
        val lines = x.get("parse_text").call(lua(data), LuaValue.valueOf(2))
        assertEquals(2, lines.length())
        assertEquals("131072  Café", String(lines.get(1).checkstring().m_bytes.copyOf(lines.get(1).checkstring().m_length), Charsets.UTF_8))
        assertEquals("131074  Two", lines.get(2).tojstring())
    }

    @Test fun `installed Broken Sword lists text, MP3 speech and music`() {
        val path = System.getenv("SWORD1_TEST_PATH")
        assumeTrue("Set SWORD1_TEST_PATH to Broken Sword 1 with SPEECH/*.CL3 and MUSIC", path != null)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path!!)!!
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val all = leaves(game.resources)
            assertEquals(11828, all.count { it.id.startsWith("spch_") })
            assertEquals(252, all.count { it.id.startsWith("mus_") })
            assertEquals(6, game.resources.first { it.id == "text" }.children.size)
            assertTrue(mgr.loadResource(path, "txt_2_1")!!.textContent!!.contains("65537  Die Stadt ist für mich"))
            for (id in listOf("spch_1_1_2", all.first { it.id.startsWith("spch_2_") }.id, "mus_1M2.MP3", "mus_6M13.WAV")) {
                val sound = mgr.loadResource(path, id)!!.soundData!!
                assertTrue(id, sound.durationMs > 500)
            }
            for (node in all.filter { it.id.startsWith("txt_") }) assertNotNull(node.id, mgr.loadResource(path, node.id)?.textContent)
        } finally { mgr.close() }
    }
}

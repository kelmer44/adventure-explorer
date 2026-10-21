package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class Sword2AudioTextTest {
    @Test fun `installed Broken Sword II lists text, MP3 speech and music`() {
        val path = System.getenv("SWORD2_TEST_PATH")
        assumeTrue("Set SWORD2_TEST_PATH to Broken Sword II with speechN.cl3 and musicN.cl3", path != null)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path!!)!!
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val all = leaves(game.resources)
            assertEquals(112, all.count { it.id.startsWith("txt2_") })
            assertEquals(2841 + 3265, all.count { it.id.startsWith("cl3_speech") })
            assertEquals(237 + 257, all.count { it.id.startsWith("cl3_music") })
            for (node in all.filter { it.id.startsWith("txt2_") }) assertNotNull(node.id, mgr.loadResource(path, node.id)?.textContent)
            assertTrue(mgr.loadResource(path, "txt2_3")!!.textContent!!.contains("[speech 1754] Aquí tienes tu pez, tío."))
            for (id in listOf("cl3_speech1.cl3_5", "cl3_speech2.cl3_${all.first { it.id.startsWith("cl3_speech2") }.id.substringAfterLast('_')}", "cl3_music1.cl3_1")) {
                assertTrue(id, mgr.loadResource(path, id)!!.soundData!!.durationMs > 500)
            }
        } finally { mgr.close() }
    }
}

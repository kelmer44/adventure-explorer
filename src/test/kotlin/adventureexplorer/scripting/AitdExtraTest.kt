package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class AitdExtraTest {
    @Test fun `installed Alone in the Dark games list samples and text`() {
        val root = System.getenv("AITD_TEST_PATH")
        assumeTrue("Set AITD_TEST_PATH to the folder holding INDARK1, INDARK2 and INDARK3", root != null)
        val expected = mapOf("INDARK1" to (104 to 21), "INDARK2" to (175 to 48), "INDARK3" to (243 to 47))
        for ((game, counts) in expected) {
            val path = File(root, game).path
            val mgr = ScriptManager()
            try {
                fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
                val all = leaves(mgr.detectGame(path)!!.resources)
                assertEquals(game, counts.first, all.count { it.id.startsWith("ax_samp_") })
                assertEquals(game, counts.second, all.count { it.id.startsWith("ax_text_") })
                for (node in all.filter { it.id.startsWith("ax_") }.filterIndexed { i, _ -> i % 7 == 0 }) {
                    val r = mgr.loadResource(path, node.id)
                    assertTrue(node.id, r?.soundData != null || r?.textContent != null)
                }
            } finally { mgr.close() }
        }
        val mgr = ScriptManager()
        try {
            val one = File(root, "INDARK1").path
            mgr.detectGame(one)
            assertTrue(mgr.loadResource(one, "ax_text_ESPAGNOL_0")!!.textContent!!.contains("@101:¡Está cerrada!"))
        } finally { mgr.close() }
    }
}

package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class UniverseTextTest {
    @Test fun `installed Universe lists and decodes text in five languages`() {
        val path = System.getenv("UNIVERSE_TEST_PATH")
        assumeTrue("Set UNIVERSE_TEST_PATH to the Universe game folder", path != null)
        val mgr = ScriptManager()
        try {
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val texts = leaves(mgr.detectGame(path!!)!!.resources).filter { it.id.startsWith("txt:") }
            assertEquals(5 * 53, texts.size)
            for (node in texts) {
                val text = mgr.loadResource(path, node.id)?.textContent
                assertTrue(node.id, !text.isNullOrBlank())
            }
            assertTrue(mgr.loadResource(path, "txt:TEXT01.SPA")!!.textContent!!.contains("  0  Parece ser un asteroide."))
            assertTrue(mgr.loadResource(path, "txt:TEXT01.GER")!!.textContent!!.contains("Noch ein Asteroid."))
        } finally { mgr.close() }
    }
}

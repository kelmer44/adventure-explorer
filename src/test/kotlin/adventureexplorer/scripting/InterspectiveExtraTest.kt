package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class InterspectiveExtraTest {
    @Test fun `installed Interspective games list sound, music and text`() {
        val root = System.getenv("INTERSPECTIVE_TEST_PATH")
        assumeTrue("Set INTERSPECTIVE_TEST_PATH to the folder holding GENE, GUILTY, IUC and ORION", root != null)
        // sound clips, XMIDI sequences, text files
        val expected = mapOf(
            "GENE" to Triple(2416, 15, 2), "GUILTY" to Triple(56, 10, 25),
            "IUC" to Triple(28, 0, 2), "ORION" to Triple(52, 8, 0),
        )
        for ((game, counts) in expected) {
            val path = File(root, game).path
            val mgr = ScriptManager()
            try {
                fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
                val all = leaves(mgr.detectGame(path)!!.resources).filter { it.id.startsWith("ix_") }
                val sounds = all.filter { it.id.matches(Regex("ix_(wav|voc|raw)\\|.*")) }
                assertEquals(game, counts.first, sounds.size)
                assertEquals(game, counts.second, all.count { it.id.startsWith("ix_xmi|") })
                assertEquals(game, counts.third, all.count { it.id.startsWith("ix_text|") })
                for (node in all.filterIndexed { i, n -> i % 11 == 0 || !n.id.startsWith("ix_wav") }) {
                    val r = mgr.loadResource(path, node.id)
                    assertTrue(node.id, r?.soundData != null || r?.midiData != null || !r?.textContent.isNullOrBlank())
                }
            } finally { mgr.close() }
        }
        val mgr = ScriptManager()
        try {
            val guilty = File(root, "GUILTY").path
            mgr.detectGame(guilty)
            assertTrue(mgr.loadResource(guilty, "ix_text|GBG_PROG.DAT")!!.textContent!!.contains("Please select character"))
        } finally { mgr.close() }
    }
}

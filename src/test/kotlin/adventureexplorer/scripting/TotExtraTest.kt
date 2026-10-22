package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class TotExtraTest {
    @Test fun `installed Trick or Treat decrypts text and lists animations, sounds and music`() {
        val path = System.getenv("TOT_TEST_PATH")
        assumeTrue("Set TOT_TEST_PATH to Trick or Treat (TOT.EXE, CONVERSA.TXT, PERSONAJ.SPT)", path != null)
        val mgr = ScriptManager()
        try {
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val all = leaves(mgr.detectGame(path!!)!!.resources)
            assertEquals(30, all.count { it.id.startsWith("tt_anim_") })
            assertEquals(31, all.count { it.id.startsWith("tt_efx_") })
            assertEquals(9, all.count { it.id.startsWith("tt_mid_") })
            assertTrue(mgr.loadResource(path, "txt_0_49")!!.textContent!!.contains("[001] Hola, joven. ¿Eres el nuevo encargado?"))
            val hero = mgr.loadResource(path, "tt_anim_PERSONAJ.SPT")!!
            assertEquals(184, hero.frames!!.size)
            assertEquals(34 to 52, hero.frames!![0].width to hero.frames!![0].height)
            for (node in all.filter { it.id.startsWith("tt_") }) {
                val r = mgr.loadResource(path, node.id)
                assertTrue(node.id, !r?.frames.isNullOrEmpty() || r?.image != null || r?.soundData != null || r?.midiData != null)
            }
        } finally { mgr.close() }
    }
}

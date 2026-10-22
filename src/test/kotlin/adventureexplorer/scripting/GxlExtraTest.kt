package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class GxlExtraTest {
    @Test fun `installed GXL games list sound, music, text, fonts and masks`() {
        val root = System.getenv("GXL_TEST_PATH")
        assumeTrue("Set GXL_TEST_PATH to the folder holding WAYNE and DARKHALF", root != null)
        // SND, XMI sequences, TXT, GFT, MSK
        val expected = mapOf("WAYNE" to listOf(37, 4, 20, 3, 41), "DARKHALF" to listOf(15, 11, 6, 2, 0))
        for ((game, counts) in expected) {
            val path = File(root, game).path
            val mgr = ScriptManager()
            try {
                fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
                val all = leaves(mgr.detectGame(path)!!.resources).filter { it.id.startsWith("gx_") }
                val found = listOf("snd", "xmi", "txt", "gft", "msk").map { k -> all.count { it.id.startsWith("gx_${k}_") } }
                assertEquals(game, counts, found)
                for (node in all) {
                    val r = mgr.loadResource(path, node.id)
                    assertTrue(node.id, r?.soundData != null || r?.midiData != null || r?.image != null || !r?.textContent.isNullOrBlank())
                }
            } finally { mgr.close() }
        }
        val mgr = ScriptManager()
        try {
            val dh = File(root, "DARKHALF").path
            mgr.detectGame(dh)
            assertTrue(mgr.loadResource(dh, "gx_txt_HOTSPOT.TXT")!!.textContent!!.startsWith("Están todos los libros"))
        } finally { mgr.close() }
    }
}

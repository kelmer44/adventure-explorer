package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class DarkSeedAudioTextTest {
    @Test fun `installed Dark Seed lists text, speech, sound effects and music`() {
        val path = System.getenv("DARKSEED_TEST_PATH")
        assumeTrue("Set DARKSEED_TEST_PATH to the Dark Seed CD folder (TOSTEXT.BIN, SPEECH, SOUND)", path != null)
        val mgr = ScriptManager()
        try {
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val all = leaves(mgr.detectGame(path!!)!!.resources)
            assertEquals(667, all.count { it.id.startsWith("ds_speech_") })
            assertEquals(49, all.count { it.id.startsWith("ds_sfx_") })
            assertEquals(20, all.count { it.id.startsWith("ds_mid_") })
            val text = mgr.loadResource(path, "ds_text")!!
            assertTrue(text.description!!.contains("979 entries"))
            assertTrue(text.textContent!!.contains("   1  FIDO ARRANCA UN TROZO DE TU CABEZA."))
            for (node in all.filter { it.id.startsWith("ds_") && it.id != "ds_text" }) {
                val r = mgr.loadResource(path, node.id)
                assertTrue(node.id, r?.soundData != null || r?.midiData != null)
            }
        } finally { mgr.close() }
    }
}

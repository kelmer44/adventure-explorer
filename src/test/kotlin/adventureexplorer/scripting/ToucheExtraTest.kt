package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class ToucheExtraTest {
    @Test fun `installed Touche lists sprites, icons, sounds, music, text and speech`() {
        val path = System.getenv("TOUCHE_TEST_PATH")
        assumeTrue("Set TOUCHE_TEST_PATH to Touche (TOUCHE.DAT and the V* speech files)", path != null)
        val mgr = ScriptManager()
        try {
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val all = leaves(mgr.detectGame(path!!)!!.resources)
            assertEquals(49, all.count { it.id.startsWith("tx_sprite_") })
            assertEquals(85, all.count { it.id.startsWith("tx_icon_") })
            assertEquals(119, all.count { it.id.startsWith("tx_sound_") })
            assertEquals(25, all.count { it.id.startsWith("tx_music_") })
            assertEquals(58, all.count { it.id.startsWith("tx_program_") })
            assertEquals(7989, all.count { it.id.startsWith("tx_speech_") })
            assertTrue(mgr.loadResource(path, "tx_program_12")!!.textContent!!.contains("no es normal que vayáis tan lento"))
            val sheet = mgr.loadResource(path, "tx_sprite_0", "pal_1")!!
            assertEquals(576 to 375, sheet.image!!.width to sheet.image!!.height)
            assertTrue(sheet.description!!.contains("48x34 frames"))
            for (node in all.filter { it.id.startsWith("tx_") }.filterIndexed { i, _ -> i % 40 == 0 }) {
                val r = mgr.loadResource(path, node.id)
                assertTrue(node.id, r?.image != null || r?.soundData != null || r?.midiData != null || r?.textContent != null)
            }
        } finally { mgr.close() }
    }
}

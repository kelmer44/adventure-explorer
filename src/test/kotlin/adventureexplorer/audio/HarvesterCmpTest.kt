package adventureexplorer.audio

import adventureexplorer.model.ResourceNode
import adventureexplorer.scripting.ScriptManager
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class HarvesterCmpTest {
    private fun le(v: Int, n: Int) = ByteArray(n) { (v ushr (8 * it)).toByte() }

    @Test fun `FCMP decodes IMA ADPCM low nibble first and silences the first 50 samples`() {
        val payload = ByteArray(40) { 0x07 }     // code 7 then code 0, repeated
        val data = "FCMP".toByteArray() + le(payload.size, 4) + le(22050, 4) + le(16, 2) + payload
        val sound = HarvesterCmp.decode(data)!!
        assertEquals(22050, sound.sampleRate)
        assertEquals(80 * 2, sound.samples.size)
        fun s(i: Int) = (sound.samples[2 * i].toInt() and 255) or (sound.samples[2 * i + 1].toInt() shl 8)
        assertEquals(0, s(49))
        assertTrue((50 until 80).all { s(it) > 0 })          // rising: code 7 adds more than code 0
        assertNull(HarvesterCmp.decode("RIFF0000".toByteArray() + ByteArray(20)))
    }

    @Test fun `installed Harvester lists sound effects, voices, music and text`() {
        val path = System.getenv("HARVESTER_TEST_PATH")
        assumeTrue("Set HARVESTER_TEST_PATH to Harvester (HARVEST.DAT, SOUND.DAT, SOUND/MUSIC)", path != null)
        val mgr = ScriptManager()
        try {
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val all = leaves(mgr.detectGame(path!!)!!.resources)
            assertEquals(150, all.count { it.id.startsWith("hx_wav") })
            assertEquals(132, all.count { it.id.startsWith("hx_voice_") })
            assertEquals(46, all.count { it.id.startsWith("hx_music_") })
            assertTrue(mgr.loadResource(path, "hx_text_HARVEST.SCR")!!.textContent!!.contains("COMMAND \"GEN_RESP_1\""))
            assertTrue(mgr.loadResource(path, "hx_text_DIALOGUE.SPN")!!.textContent!!.contains("¿Si?"))
            for (node in all.filter { it.type == "sound" }.filterIndexed { i, _ -> i % 10 == 0 }) {
                assertTrue(node.id, mgr.loadResource(path, node.id)!!.soundData!!.durationMs > 0)
            }
        } finally { mgr.close() }
    }
}

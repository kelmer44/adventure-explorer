package adventureexplorer.audio

import adventureexplorer.model.ResourceNode
import adventureexplorer.scripting.ScriptManager
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class LastExpressAdpcmTest {
    @Test fun `computed tables match ScummVM's adpcmDeltaTable and adpcmStepSizeTable`() {
        // First three rows of both tables in engines/lastexpress/sound/mixer.cpp
        val delta = intArrayOf(0, 2, 4, 6, 7, 9, 11, 13, 0, -2, -4, -6, -7, -9, -11, -13,
            1, 3, 5, 7, 9, 11, 13, 15, -1, -3, -5, -7, -9, -11, -13, -15,
            1, 3, 5, 7, 10, 12, 14, 16, -1, -3, -5, -7, -10, -12, -14, -16)
        val step = intArrayOf(0, 0, 0, 0, 128, 256, 384, 512, 0, 0, 0, 0, 128, 256, 384, 512,
            0, 0, 0, 0, 192, 320, 448, 576, 0, 0, 0, 0, 192, 320, 448, 576,
            64, 64, 64, 64, 256, 384, 512, 640, 64, 64, 64, 64, 256, 384, 512, 640)
        for (i in delta.indices) {
            assertEquals("delta $i", delta[i], LastExpressAdpcm.delta(i / 16, i % 16))
            assertEquals("step $i", step[i], LastExpressAdpcm.nextStep(i / 16, i % 16) * 64)
        }
        assertEquals(0x7FFF, LastExpressAdpcm.delta(88, 7)) // clamped like the table
    }

    @Test fun `blocks decode high nibble first and stop at an invalid step`() {
        val block = ByteArray(739).also { it[0] = 100; it[2] = 0; it[4] = 0x47.toByte() }
        val bad = ByteArray(739).also { it[2] = 99 }
        val sound = LastExpressAdpcm.decode(byteArrayOf(0, 0, 0, 0, 2, 0) + block + bad)!!
        assertEquals(22050, sound.sampleRate)
        assertEquals(1470 * 2, sound.samples.size)                    // second block rejected
        fun s(i: Int) = (sound.samples[2 * i].toInt() and 255) or (sound.samples[2 * i + 1].toInt() shl 8)
        assertEquals(100 + 7, s(0))                                    // code 4 at step 0: +7
        assertEquals(100 + 7 + 16, s(1))                               // step 2 (size 9), code 7: 15 * 9 / 8
    }

    @Test fun `installed Last Express lists sounds and subtitles`() {
        val path = System.getenv("LASTEXPRESS_TEST_PATH")
        assumeTrue("Set LASTEXPRESS_TEST_PATH to The Last Express (CD*.HPF and Data/HD.HPF)", path != null)
        val mgr = ScriptManager()
        try {
            fun leaves(n: List<ResourceNode>): List<ResourceNode> = n.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
            val all = leaves(mgr.detectGame(path!!)!!.resources)
            assertEquals(1721, all.count { it.id.startsWith("sndf|") })
            assertEquals(227, all.count { it.id.startsWith("sbef|") })
            assertTrue(mgr.loadResource(path, "sbef|Data/Hd.hpf|1034.SBE")!!.textContent!!.contains("Ni un movimiento"))
            for (node in all.filter { it.id.startsWith("sndf|") }.filterIndexed { i, _ -> i % 25 == 0 } +
                    all.filter { it.id.endsWith("LIB044.SND") }) {
                assertTrue(node.id, mgr.loadResource(path, node.id)!!.soundData!!.durationMs > 0)
            }
        } finally { mgr.close() }
    }
}

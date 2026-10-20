package adventureexplorer.scripting

import adventureexplorer.app.ResourceExporter
import adventureexplorer.model.ExportCategory
import adventureexplorer.model.ResourceCategories
import adventureexplorer.model.ResourceNode
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import javax.imageio.ImageIO
import javax.sound.sampled.AudioSystem

class AsylumIntegrationTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun `official Sanitarium demo resources decode and export through the real host`() = runBlocking {
        val path = System.getenv("SANITARIUM_TEST_PATH")
        assumeTrue("Set SANITARIUM_TEST_PATH to the official Windows demo", path != null)
        val marker = File(path!!).listFiles()!!.first { it.name.equals("sntrm.dat", true) }
        assumeTrue("These coverage counts are for the demo", marker.length() == 326L)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path)!!
            assertEquals("asylum", game.engineId)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
                if (it.isCategory) leaves(it.children) else listOf(it)
            }
            val all = leaves(game.resources)
            assertEquals(all.size, all.map { it.id }.toSet().size)
            assertEquals(2494, all.size)
            assertEquals(2058, all.count { it.type == "image" })
            assertEquals(89, all.count { it.type == "animation" })
            assertEquals(171, all.count { it.type == "sound" })
            assertEquals(3, all.count { it.type == "palette" })
            assertEquals(173, all.count { it.type == "text" })
            assertEquals(1, ResourceCategories.counts(game.resources)[ExportCategory.BACKGROUNDS])
            assertEquals(1615, ResourceCategories.counts(game.resources)[ExportCategory.SPRITES])
            assertEquals("pal:RES.005:20", mgr.defaultPaletteFor(path, "frame:RES.005:0:0"))
            val previews = File("build/sanitarium-research/previews").apply { mkdirs() }
            for (node in all) {
                val r = mgr.loadResource(path, node.id) ?: error(node.id)
                when (node.type) {
                    "image", "palette" -> {
                        val image = r.image ?: error("${node.id}: ${r.textContent}")
                        if (node.id == "frame:RES.005:0:0") {
                            assertEquals(1095, image.width); assertEquals(897, image.height)
                            assertFalse(image.colorModel.hasAlpha())
                        } else if (node.id.startsWith("frame:")) assertTrue(node.id, image.colorModel.hasAlpha())
                        if (node.id in setOf("frame:RES.005:0:0", "frame:RES.005:24:0", "frame:RES.005:13:33", "mask:RES.005:39", "pal:RES.005:20")) {
                            ImageIO.write(image, "png", File(previews, node.id.replace(':', '_') + ".png"))
                        }
                    }
                    "animation" -> {
                        val frames = r.frames ?: error("${node.id}: ${r.textContent}")
                        assertTrue(node.id, frames.size > 1)
                        assertTrue(node.id, frames.all { it.width == frames[0].width && it.height == frames[0].height })
                        assertEquals(100, r.frameDelayMs)
                        if (node.id == "anim:RES.005:28") {
                            val blank = frames.first()
                            assertTrue(blank.getRGB(0, 0, blank.width, blank.height, null, 0, blank.width).all { it ushr 24 == 0 })
                        }
                    }
                    "sound" -> {
                        val sound = r.soundData ?: error("${node.id}: ${r.textContent}")
                        assertEquals(16, sound.bitsPerSample); assertEquals(1, sound.channels)
                        assertTrue(sound.signed); assertTrue(sound.samples.isNotEmpty())
                        assertTrue(sound.sampleRate == 11025 || sound.sampleRate == 22050)
                    }
                    "text" -> assertFalse(node.id, r.textContent.isNullOrEmpty())
                }
                mgr.releaseDecodedResources()
            }
            // Independent JVM WAV reading agrees byte-for-byte with the host's output.
            val archive = File(path, "RES.004").readBytes()
            fun dword(p: Int): Int = (0..3).sumOf { (archive[p + it].toInt() and 255) shl (it * 8) }
            val wave = archive.copyOfRange(dword(4), dword(8))
            val expectedPCM = AudioSystem.getAudioInputStream(wave.inputStream()).use { it.readBytes() }
            assertArrayEquals(expectedPCM, mgr.loadResource(path, "sound:RES.004:0")!!.soundData!!.samples)
            val normal = mgr.loadResource(path, "frame:RES.005:0:0")!!.image!!
            val override = mgr.loadResource(path, "frame:RES.005:0:0", "pal:RES.005:175")!!.image!!
            assertFalse(normal.getRGB(0, 0, normal.width, normal.height, null, 0, normal.width)
                .contentEquals(override.getRGB(0, 0, override.width, override.height, null, 0, override.width)))
            assertEquals("text", mgr.loadResource(path, "frame:RES.005:0:0", "invalid")!!.type)
            assertNull(mgr.loadResource(path, "frame:RES.005:0"))
            assertNull(mgr.loadResource(path, "unknown"))
            val selected = all.filter { it.id in setOf("frame:RES.005:24:0", "anim:RES.005:1", "sound:RES.004:0", "pal:RES.005:20", "text:RES.000:0", "mask:RES.005:39") }
                .map { it.copy(name = it.id.replace(':', '_')) }
            val exported = ResourceExporter({ mgr.loadResource(path, it.id) }, mgr::releaseDecodedResources).export(selected, temporary.root)
            assertEquals(6, exported.exported)
            assertTrue(exported.failures.toString(), exported.failures.isEmpty())
            assertTrue(ImageIO.read(File(temporary.root, "frame_RES.005_24_0.png")).colorModel.hasAlpha())
            assertEquals(7, File(temporary.root, "anim_RES.005_1").listFiles()!!.count { it.extension == "png" })
            assertEquals(768L, File(temporary.root, "pal_RES.005_20.bin").length())
            assertTrue(File(temporary.root, "text_RES.000_0.txt").readText().startsWith("{N} Hello."))
            AudioSystem.getAudioInputStream(File(temporary.root, "sound_RES.004_0.wav")).use {
                assertEquals(22050f, it.format.sampleRate, 0f)
                assertEquals(expectedPCM.size / 2L, it.frameLength)
            }
            println("Sanitarium demo: all ${all.size} leaves decoded; PNG/alpha, WAV, animation, text and palette export verified")
        } finally { mgr.close() }
    }
}

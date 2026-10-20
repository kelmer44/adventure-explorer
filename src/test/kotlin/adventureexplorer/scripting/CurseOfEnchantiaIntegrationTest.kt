package adventureexplorer.scripting

import adventureexplorer.app.ResourceExporter
import kotlinx.coroutines.runBlocking
import adventureexplorer.model.ResourceNode
import adventureexplorer.model.ResourceCategories
import adventureexplorer.model.ExportCategory
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import javax.sound.sampled.AudioSystem
import java.io.File
import javax.imageio.ImageIO

class CurseOfEnchantiaIntegrationTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun `installed Curse resources decode with alpha palettes animations and PCM`() = runBlocking {
        val path = System.getenv("CURSE_TEST_PATH")
        assumeTrue("Set CURSE_TEST_PATH to the game directory", path != null)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path!!)!!
            assertEquals("curseofenchantia", game.engineId)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
                if (it.isCategory) leaves(it.children) else listOf(it)
            }
            val all = leaves(game.resources)
            assertEquals(all.size, all.map { it.id }.toSet().size)
            assertEquals(2770, all.count { it.type == "image" })
            assertEquals(109, all.count { it.type == "sound" })
            assertEquals(62, all.count { it.type == "palette" })
            assertEquals(3, all.count { it.type == "animation" })
            assertEquals(2695, ResourceCategories.counts(game.resources)[ExportCategory.SPRITES])
            val out = File("build/curse-research").apply { mkdirs() }
            for (node in all) {
                val r = mgr.loadResource(path, node.id) ?: error(node.id)
                when (node.type) {
                    "image", "palette" -> assertNotNull("${node.id}: ${r.textContent}", r.image)
                    "sound" -> {
                        val sound = r.soundData ?: error(node.id)
                        assertEquals(8000, sound.sampleRate)
                        assertEquals(8, sound.bitsPerSample)
                        assertEquals(1, sound.channels)
                        assertFalse(sound.signed)
                        assertTrue(sound.samples.isNotEmpty())
                    }
                    "animation" -> {
                        assertEquals(if (node.id == "anim:BALCONY") 5 else if (node.id == "anim:BASEBAL") 6 else 4, r.frames!!.size)
                        assertEquals(100, r.frameDelayMs)
                        assertTrue(r.frames!!.all { it.width == 320 && it.height == 200 })
                    }
                }
                if (node.id in listOf("spr_CAVE_0", "brd_STD_0", "bg_CAVE", "pal:room:CAVE")) {
                    ImageIO.write(r.image, "png", File(out, node.id.replace(':', '_') + ".png"))
                }
                if (node.id.startsWith("spr_") || node.id.startsWith("brd_")) {
                    val image = r.image!!
                    assertTrue(node.id, image.colorModel.hasAlpha())
                }
                mgr.releaseDecodedResources()
            }
            assertEquals("pal:room:CAVE", mgr.defaultPaletteFor(path, "spr_CAVE_0"))
            val normal = mgr.loadResource(path, "spr_CAVE_0")!!.image!!
            val override = mgr.loadResource(path, "spr_CAVE_0", "pal:TITLE")!!.image!!
            assertFalse(normal.getRGB(0, 0, normal.width, normal.height, null, 0, normal.width)
                .contentEquals(override.getRGB(0, 0, override.width, override.height, null, 0, override.width)))
            assertNotNull(mgr.loadResource(path, "bg_CAVE")!!.paletteImage)
            assertNull(mgr.loadResource(path, "unknown"))
            val selected = all.filter { it.id in setOf("brd_STD_0", "sfx:STD:0", "anim:CAULDRN", "pal:SPRITES") }
                .map { it.copy(name = it.id.replace(':', '_')) }
            val exported = ResourceExporter({ mgr.loadResource(path, it.id) }, mgr::releaseDecodedResources)
                .export(selected, temporary.root)
            assertEquals(4, exported.exported)
            assertTrue(exported.failures.toString(), exported.failures.isEmpty())
            assertTrue(ImageIO.read(File(temporary.root, "brd_STD_0.png")).colorModel.hasAlpha())
            assertEquals(4, File(temporary.root, "anim_CAULDRN").listFiles()!!.count { it.extension == "png" })
            assertEquals(768L, File(temporary.root, "pal_SPRITES.bin").length())
            AudioSystem.getAudioInputStream(File(temporary.root, "sfx_STD_0.wav")).use {
                assertEquals(8000f, it.format.sampleRate, 0f)
                assertEquals(4124L, it.frameLength)
            }
            println("Curse: all ${all.size} leaves decoded; alpha PNG, PCM WAV, animation and palette export verified")
        } finally { mgr.close() }
    }
}

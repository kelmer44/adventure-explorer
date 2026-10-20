package adventureexplorer.scripting

import adventureexplorer.app.ResourceExporter
import adventureexplorer.model.ResourceNode
import adventureexplorer.model.ResourceCategories
import adventureexplorer.model.ExportCategory
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import javax.imageio.ImageIO

class ScummV2IntegrationTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun `installed enhanced Maniac Mansion objects masks names and palettes extract`() = runBlocking {
        val path = System.getenv("MANIAC_TEST_PATH")
        assumeTrue("Set MANIAC_TEST_PATH to enhanced Maniac Mansion", path != null)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path!!)!!
            assertEquals("scummv2", game.engineId)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
                if (it.isCategory) leaves(it.children) else listOf(it)
            }
            val all = leaves(game.resources)
            assertEquals(all.size, all.map { it.id }.toSet().size)
            assertEquals(53, all.count { it.id.startsWith("room_") })
            assertEquals(269, all.count { it.id.startsWith("obj_") })
            assertEquals(53, all.count { it.id.startsWith("mask_") })
            assertEquals(269, all.count { it.id.startsWith("objmask_") })
            assertEquals(53, all.count { it.type == "text" })
            assertEquals(269, ResourceCategories.counts(game.resources)[ExportCategory.SPRITES])
            val previews = File("build/maniac-previews").apply { mkdirs() }
            for (node in all) {
                val r = mgr.loadResource(path, node.id) ?: error(node.id)
                if (node.type == "text") {
                    assertTrue(r.textContent!!.contains("object records"))
                    if (node.id == "info_1") assertTrue(r.textContent!!.contains("puerta delantera"))
                } else {
                    val image = r.image ?: error("${node.id}: ${r.textContent}")
                    if (node.id in listOf("room_1", "obj_1_1", "mask_1", "objmask_1_1", "pal_ega")) {
                        ImageIO.write(image, "png", File(previews, node.id + ".png"))
                    }
                    if (node.id.contains("mask_")) {
                        for (y in 0 until image.height) for (x in 0 until image.width) {
                            assertTrue(image.getRGB(x, y) == -1 || image.getRGB(x, y) == -16777216)
                        }
                    }
                }
                mgr.releaseDecodedResources()
            }
            val selected = all.filter { it.id in setOf("obj_1_1", "mask_1", "info_1", "pal_ega") }
            val exported = ResourceExporter({ mgr.loadResource(path, it.id) }, mgr::releaseDecodedResources)
                .export(selected, temporary.root)
            assertEquals(4, exported.exported)
            assertTrue(exported.failures.toString(), exported.failures.isEmpty())
            assertEquals(48, temporary.root.listFiles()!!.single { it.extension == "bin" }.length().toInt())
            val paletteBytes = temporary.root.listFiles()!!.single { it.extension == "bin" }.readBytes()
            assertArrayEquals(byteArrayOf(0, 0, 0, 0, 0, 170.toByte()), paletteBytes.copyOfRange(0, 6))
            assertEquals(3, temporary.root.listFiles()!!.count { it.extension == "png" }) // object, mask, palette
            assertEquals(320 * 3, mgr.loadResource(path, "room_1")!!.image!!.width)
            assertNull(mgr.loadResource(path, "obj_1_9999"))
            println("Maniac Mansion: all ${all.size} resources decoded; PNG, text and palette export verified")
        } finally { mgr.close() }
    }
}

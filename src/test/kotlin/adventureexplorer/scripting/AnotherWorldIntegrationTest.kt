package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.imageio.ImageIO

class AnotherWorldIntegrationTest {
    @Test fun `original DOS resources decode through LuaJ`() {
        val path = System.getenv("ANOTHER_WORLD_TEST_PATH")
        assumeTrue("Set ANOTHER_WORLD_TEST_PATH to exercise original DOS data", path != null)
        val manager = ScriptManager()
        try {
            val game = manager.detectGame(path!!)!!
            assertEquals("anotherworld", game.engineId)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
                if (it.isCategory) leaves(it.children) else listOf(it)
            }
            val all = leaves(game.resources)
            assertEquals(12, all.count { it.id.startsWith("bitmap_") })
            assertEquals(576, all.count { it.type == "palette" })
            assertEquals(9, all.count { it.id.startsWith("script_") })
            val selected = all.filter { it.id.startsWith("bitmap_") || it.id.startsWith("script_") || it.id.startsWith("data_") } +
                all.filter { it.type == "palette" }.let { it.take(2) + it.takeLast(2) } +
                all.filter { it.type == "sound" }.let { it.take(3) + it.takeLast(3) } +
                game.resources.filter { it.id.startsWith("shapes_") }.flatMap { it.children.take(2) + it.children.takeLast(2) }
            val out = File("build/anotherworld-previews").apply { mkdirs() }
            for (node in selected) {
                val resource = manager.loadResource(path, node.id)
                assertNotNull(node.id, resource)
                when (node.type) {
                    "image", "palette" -> assertNotNull(node.id, resource!!.image)
                    "sound" -> {
                        val sound = resource!!.soundData!!
                        assertTrue(node.id, sound.samples.isNotEmpty())
                        assertTrue(node.id, sound.signed)
                    }
                    else -> assertNotNull(node.id, resource!!.textContent)
                }
                if (node.id.startsWith("bitmap_")) {
                    val image = resource.image!!
                    assertEquals(320, image.width)
                    assertEquals(200, image.height)
                    assertTrue("${node.id}: blank default palette",
                        (0 until image.height).any { y -> (0 until image.width).any { x -> image.getRGB(x, y) and 0xFFFFFF != 0 } })
                    ImageIO.write(image, "png", File(out, "${node.id}.png"))
                }
                manager.releaseDecodedResources()
            }
            val title = manager.loadResource(path, "bitmap_18")!!.image!!
            assertTrue("Interplay logo must have a visible default palette",
                (0 until title.height).any { y -> (0 until title.width).any { x -> title.getRGB(x, y) and 0xFFFFFF != 0 } })
            manager.releaseDecodedResources()
            assertNotNull(manager.loadResource(path, "bitmap_18", "pal_14_04_ega")!!.image)
            assertNull(manager.loadResource(path, "invalid"))
            println("Another World: ${selected.size} LuaJ resources decoded; ${all.size} catalog leaves")
        } finally { manager.close() }
    }
}

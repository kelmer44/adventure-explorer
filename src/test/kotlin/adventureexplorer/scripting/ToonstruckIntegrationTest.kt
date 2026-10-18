package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.imageio.ImageIO

class ToonstruckIntegrationTest {
    @Test fun `installed Toonstruck backgrounds masks dialogue and audio decode`() {
        val path = System.getenv("TOONSTRUCK_TEST_PATH")
        assumeTrue("Set TOONSTRUCK_TEST_PATH to exercise installed game data", path != null)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path!!)!!
            assertEquals("toonstruck", game.engineId)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
                if (it.isCategory) leaves(it.children) else listOf(it)
            }
            val all = leaves(game.resources)
            val selected = all.filter { it.type == "image" || it.type == "palette" || it.id.endsWith(".TRE") } +
                all.filter { it.type == "animation" } +
                all.filter { it.type == "sound" }.groupBy { it.id.substringBeforeLast(':') }.values.flatMap { it.take(1) + it.takeLast(1) }
            assertTrue(all.any { it.id.startsWith("audio:") })
            assertTrue(all.any { it.id.endsWith(".MSC") })
            assertTrue(all.any { it.id.endsWith(".TRE") })
            val failures = mutableListOf<String>()
            var decoded = 0
            val out = File("build/toonstruck-previews").apply { mkdirs() }
            for (node in selected) {
                val data = mgr.loadResource(path, node.id)
                val ok = when {
                    node.type == "sound" -> data?.soundData?.samples?.isNotEmpty() == true
                    node.type == "animation" -> data?.image != null || !data?.frames.isNullOrEmpty() ||
                        (data?.type == "text" && data.description?.contains("empty placeholder") == true)
                    node.type == "image" || node.type == "palette" -> data?.image != null
                    else -> !data?.textContent.isNullOrEmpty()
                }
                if (!ok) failures += node.id else decoded++
                if (node.id.endsWith(".CPS") && node.type == "image") data?.image?.let {
                    assertEquals(400, it.height)
                    assertTrue(it.width == 640 || it.width == 1280)
                    ImageIO.write(it, "png", File(out, node.id.replace(Regex("[^a-zA-Z0-9.]"), "_") + ".png"))
                }
                mgr.releaseDecodedResources()
                if (decoded % 200 == 0) println("Toonstruck scan: $decoded decoded, latest ${node.id}")
            }
            println("Toonstruck: $decoded/${selected.size} resources decoded; ${all.size} leaves")
            assertTrue(failures.joinToString("\n"), failures.isEmpty())
        } finally { mgr.close() }
    }
}

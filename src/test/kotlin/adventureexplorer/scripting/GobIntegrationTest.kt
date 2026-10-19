package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.imageio.ImageIO

class GobIntegrationTest {
    private fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
        if (it.isCategory) leaves(it.children) else listOf(it)
    }
    private fun scan(env: String, woodruff: Boolean) {
        val path = System.getenv(env)
        assumeTrue("Set $env to exercise installed game files", path != null)
        val manager = ScriptManager()
        try {
            val game = manager.detectGame(path!!)!!
            assertEquals("gob", game.engineId)
            assertEquals("GOB", game.engineName)
            val all = leaves(game.resources)
            assertTrue(all.size > if (woodruff) 3000 else 1900)
            val selected = if (System.getenv("GOB_SCAN_ALL") == "1") all else all.filter {
                it.type != "animation" || (!it.id.contains("_frame_") &&
                    (it.id.contains("SQ01") || it.id.contains("TIR") || it.id.contains("INTRO")))
            }
            val failures = mutableListOf<String>()
            for (node in selected) {
                val data = manager.loadResource(path, node.id)
                val ok = when (node.type) {
                    "image", "palette" -> data?.image != null
                    "sound" -> data?.soundData?.samples?.isNotEmpty() == true &&
                        (!node.id.endsWith(".MDY") || data.soundData!!.samples.any { it != 0.toByte() })
                    "animation" -> !data?.frames.isNullOrEmpty()
                    else -> false
                }
                if (!ok) failures += node.id
                if (node.id == (if (woodruff) "bg_EMAP2002" else "bg_NOM")) {
                    val img = data!!.image!!
                    assertEquals(if (woodruff) 640 else 320, img.width)
                    assertEquals(if (woodruff) 378 else 200, img.height)
                    val out = File("build/gob-previews").apply { mkdirs() }
                    ImageIO.write(img, "png", File(out, if (woodruff) "woodruff.png" else "fascination.png"))
                }
                if (node.id == "file_SQ01-01A.VMD" || node.id == "file_TIRA.IMD" || node.id == "file_TIRB.IMD") {
                    data?.frames?.firstOrNull()?.let { img ->
                        val out = File("build/gob-previews").apply { mkdirs() }
                        ImageIO.write(img, "png", File(out, node.id + ".png"))
                    }
                }
                manager.releaseDecodedResources()
            }
            println("$env: ${selected.size - failures.size}/${selected.size} decoded (${all.size} total leaves)")
            assertTrue(failures.joinToString("\n"), failures.isEmpty())
        } finally { manager.close() }
    }
    @Test fun `Fascination images palettes and IMD movies decode`() = scan("FASCINATION_TEST_PATH", false)
    @Test fun `Woodruff scene strips palettes SND and VMD clips decode`() = scan("WOODRUFF_TEST_PATH", true)
    @Test fun `Gobliiins series images and palettes still decode`() {
        val root = System.getenv("GOB_SERIES_TEST_ROOT")
        assumeTrue("Set GOB_SERIES_TEST_ROOT for Gobliiins 1-3 regression checks", root != null)
        for (name in listOf("GOB1", "GOB2", "GOB3")) {
            val mgr = ScriptManager()
            try {
                val path = File(root!!, name).absolutePath
                val game = mgr.detectGame(path)!!
                assertEquals("gob", game.engineId)
                val images = leaves(game.resources).filter { it.type == "image" || it.type == "palette" }
                assertTrue(images.isNotEmpty())
                val failures = mutableListOf<String>()
                for (node in images) {
                    if (mgr.loadResource(path, node.id)?.image == null) failures += node.id
                    mgr.releaseDecodedResources()
                }
                println("$name: ${images.size - failures.size}/${images.size} images decoded")
                assertTrue("$name: " + failures.joinToString("\n"), failures.isEmpty())
            } finally { mgr.close() }
        }
    }

}

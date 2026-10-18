package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.imageio.ImageIO
import javax.sound.midi.MidiSystem

class AgosIntegrationTest {
    @Test fun `installed Simon 1 resources decode`() = scan("SIMON1_TEST_PATH")
    @Test fun `installed Simon 2 resources decode`() = scan("SIMON2_TEST_PATH")

    private fun scan(variable: String) {
        val path = System.getenv(variable)
        assumeTrue("Set $variable to exercise installed game data", path != null)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path!!)!!
            assertEquals("agos", game.engineId)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
                if (it.isCategory) leaves(it.children) else listOf(it)
            }
            val all = leaves(game.resources)
            assertTrue(all.any { it.id.startsWith("speech_") })
            assertTrue(all.any { it.id.startsWith("sfx") })
            assertTrue(all.any { it.type == "midi" })
            val selected = all.filter { it.id.startsWith("room_") || it.id.startsWith("sfx") || it.id.startsWith("icon_") || it.type == "midi" } +
                all.filter { it.id.startsWith("speech_") }.let { it.take(10) + it.takeLast(10) } +
                game.resources.first().children.flatMap { zone ->
                    zone.children.filter { it.id.startsWith("anim_") }.take(2) +
                        zone.children.filter { it.id.startsWith("img_") }.take(3)
                }
            val failures = mutableListOf<String>()
            var decoded = 0
            val out = File("build/agos-previews").apply { mkdirs() }
            for (node in selected) {
                val data = mgr.loadResource(path, node.id)
                if (data == null) failures += node.id
                else {
                    decoded++
                    when (node.type) {
                        "sound" -> if (data.soundData?.samples?.isNotEmpty() != true) failures += node.id
                        "animation" -> if (data.frames.isNullOrEmpty()) failures += node.id
                        "image" -> if (data.image == null) failures += node.id
                        "midi" -> if (runCatching { MidiSystem.getSequence(data.midiData!!.bytes.inputStream()) }.isFailure) failures += node.id
                    }
                    if (node.id in listOf("room_10_10", "room_10_7", "img_6_1", "anim_10_1", "anim_11_1", "icon_10", "icon_20")) {
                        data.image?.let { image ->
                            ImageIO.write(image, "png", File(out, File(path).name + "_" + node.id + ".png"))
                            if (node.id.startsWith("anim_")) assertTrue("${node.id}: missing persistent sprite palette",
                                (0 until image.height).any { y -> (0 until image.width).any { x -> image.getRGB(x, y) and 0xFFFFFF != 0 } })
                        }
                    }
                }
                mgr.releaseDecodedResources()
            }
            println("${File(path).name}: $decoded/${selected.size} representative resources decoded, ${all.size} leaves")
            assertTrue(failures.joinToString(", "), failures.isEmpty())
        } finally { mgr.close() }
    }
}

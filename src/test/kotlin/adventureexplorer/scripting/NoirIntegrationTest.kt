package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.imageio.ImageIO

class NoirIntegrationTest {
    @Test fun `portable folder detection and missing resources`() {
        val root = java.nio.file.Files.createTempDirectory("noir-fixture").toFile()
        fun words(vararg values: Int) = java.nio.ByteBuffer.allocate(values.size * 4)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN).apply { values.forEach { putInt(it) } }.array()
        val data = File(root, "cd1").apply { mkdir() }
        val mgr = ScriptManager()
        try {
            // A raw scene with a red and transparent pixel, one image record,
            // and a reference to a missing scene in index slot 1.
            val scene = words(0x33340002, 12) + byteArrayOf(0, 0xF8.toByte(), 31, 0xF8.toByte()) +
                words(0x33340006, 0) + byteArrayOf(2, 0, 1, 0, 0, 0, 0, 0) + words(8, 0)
            File(data, "DW3.SCN").writeBytes(scene)
            fun entry(name: String, size: Int) = name.toByteArray().copyOf(12) + words(size, 0, 0)
            File(data, "INDEX").writeBytes(entry("dw3.scn", scene.size) + entry("missing.scn", 8))
            File(data, "ENGLISH.TXT").writeBytes(words(0x33340001, 0) +
                byteArrayOf(4, 99, 97, 102, 0xE9.toByte(), 0x80.toByte(), 128.toByte()) + ByteArray(128) { 97 } +
                byteArrayOf(0x90.toByte(), 0) + ByteArray(256) { 98 } + byteArrayOf(0x82.toByte(), 1, 65, 1, 66))
            for (path in listOf(root.absolutePath, data.absolutePath)) {
                val game = mgr.detectGame(path)!!
                assertEquals("noir", game.engineId)
                val image = mgr.loadResource(path, "image_0_20")!!.image!!
                assertEquals(0xFFFF0000.toInt(), image.getRGB(0, 0))
                assertEquals(0, image.getRGB(1, 0))
                assertTrue(mgr.loadResource(path, "noir_info")!!.textContent!!.contains("Unavailable: missing.scn"))
                val text = mgr.loadResource(path, "text_english.txt_1")!!.textContent!!
                assertTrue(text.contains("0.0: caf\u00E9"))
                assertTrue(text.contains("1.0: " + "a".repeat(128)))
                assertTrue(text.contains("2.0: " + "b".repeat(256)))
                assertTrue(text.contains("3.0: A\n3.1: B"))
            }
            File(data, "DW3.SCN").delete()
            assertNull(mgr.detectGame(root.absolutePath))
        } finally { mgr.close(); root.deleteRecursively() }
    }

    @Test fun `mounted three disc set decodes through LuaJ`() {
        val path = System.getenv("NOIR_TEST_PATH")
        assumeTrue("Set NOIR_TEST_PATH to the original Noir disc set", path != null)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path!!)!!
            assertEquals("noir", game.engineId)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
                if (it.isCategory) leaves(it.children) else listOf(it)
            }
            val all = leaves(game.resources)
            assertTrue(all.count { it.type == "image" } > 1000)
            assertTrue(all.count { it.id.startsWith("music_") } > 30)
            assertTrue(all.count { it.id.startsWith("speech_") } > 1000)
            assertTrue(all.count { it.id.startsWith("text_") } > 100)
            val out = File("build/noir-previews").apply { mkdirs() }
            val images = all.filter { it.type == "image" }
            val selected = if (System.getenv("NOIR_FULL_SCAN") == "1") images else
                game.resources.filter { it.id in listOf("backgrounds", "sprites") }.flatMap { category ->
                    category.children.flatMap { it.children.take(1) + it.children.takeLast(1) }
                }.distinctBy { it.id }
            for ((i, node) in selected.withIndex()) {
                val image = mgr.loadResource(path, node.id)?.image ?: error("Image failed: ${node.id}")
                assertTrue(image.width > 0 && image.height > 0)
                if (i < 6) ImageIO.write(image, "png", File(out, "${node.id}.png"))
                mgr.releaseDecodedResources()
            }
            for (prefix in listOf("music_", "speech_", "text_", "chunk_", "file_")) {
                val nodes = all.filter { it.id.startsWith(prefix) }
                val samples = when (prefix) {
                    "music_", "text_" -> nodes
                    "speech_" -> nodes.filterIndexed { i, _ -> i % maxOf(1, nodes.size / 30) == 0 } + nodes.takeLast(3)
                    else -> nodes.take(3) + nodes.takeLast(3)
                }
                for (node in samples.distinctBy { it.id }) {
                    val resource = mgr.loadResource(path, node.id) ?: error("Failed: ${node.id}")
                    if (node.type == "sound") assertTrue(node.id, resource.soundData!!.samples.isNotEmpty())
                    else {
                        assertFalse(node.id, resource.textContent.isNullOrBlank())
                        if (prefix == "text_") assertFalse(node.id, resource.textContent!!.contains("[Truncated string]"))
                    }
                    mgr.releaseDecodedResources()
                }
            }
            val text = all.first { it.id.startsWith("text_english.txt_") }
            assertTrue(mgr.loadResource(path, text.id)!!.textContent!!.contains("Sound/Subtitles"))
            assertNull(mgr.loadResource(path, "invalid"))
            for (category in game.resources) println("${category.id}: ${leaves(listOf(category)).size}")
            assertEquals(listOf("Unavailable: extra.scn"), mgr.loadResource(path, "noir_info")!!.textContent!!
                .lineSequence().filter { it.startsWith("Unavailable:") }.toList())
            println("Noir: ${images.size} images; scanned ${selected.size}; ${all.groupingBy { it.type }.eachCount()}")
        } finally { mgr.close() }
    }
}

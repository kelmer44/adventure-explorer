package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.luaj.vm2.LuaString
import java.io.File
import javax.imageio.ImageIO

class Take2DecoderTest {
    private fun fixture(w: Int, h: Int, data: ByteArray): ByteArray {
        val header = ByteArray(28)
        header[1] = 2; header[2] = -1; header[3] = -1; header[4] = 2
        header[6] = 1; header[7] = 2
        header[22] = h.toByte(); header[24] = w.toByte(); header[26] = data.size.toByte()
        return header + data
    }
    @Test fun `packed images decode deltas runs and reject malformed streams in LuaJ`() {
        val lua = LuaEngine()
        try {
            val d = lua.loadScript(File("scripts/engines/take2/engine.lua").absolutePath).get("_debug")
            val decoded = d.get("packed").invoke(LuaString.valueOf(fixture(3, 1, byteArrayOf(0, 0x11))))
            assertEquals(3, decoded.arg(1).toint()); assertEquals(1, decoded.arg(2).toint())
            assertEquals(listOf(0, 1, 2), (1..3).map { decoded.arg(3).get(it).toint() })
            val run = d.get("packed").invoke(LuaString.valueOf(fixture(6, 1, byteArrayOf(1, 0x3e, 0))))
            assertEquals(6, run.arg(3).length()); assertEquals(1, run.arg(3).get(6).toint())
            for (bad in listOf(fixture(5, 1, byteArrayOf(1, 0x3e, 0)), fixture(4, 1, byteArrayOf(0)))) {
                assertTrue(runCatching { d.get("packed").invoke(LuaString.valueOf(bad)) }.isFailure)
            }
            assertEquals("España\nSí", d.get("text").call(LuaString.valueOf(byteArrayOf(69,115,112,97,0xa4.toByte(),97,126,83,0xa1.toByte()))).tojstring())
        } finally { lua.cleanup() }
    }
    @Test fun `Hell FLC COPY repair requires exact enclosing frame size`() {
        val lua = LuaEngine()
        try {
            val d = lua.loadScript(File("scripts/engines/take2/engine.lua").absolutePath).get("_debug")
            val bytes = ByteArray(154)
            fun word(offset: Int, value: Int) {
                bytes[offset] = value.toByte(); bytes[offset + 1] = (value ushr 8).toByte()
            }
            word(0, bytes.size); word(4, 0xaf12); word(6, 1); word(8, 4); word(10, 1)
            word(12, 8); word(16, 100); word(80, 128)
            word(128, 26); word(132, 0xf1fa); word(134, 1)
            word(144, 8); word(148, 16) // encoder declares two bytes fewer than the actual COPY
            bytes[150] = 1; bytes[151] = 2; bytes[152] = 3; bytes[153] = 4
            val decoded = d.get("flc").invoke(LuaString.valueOf(bytes))
            val image = lua.getImage(decoded.arg1().get(1).toint())!!
            assertEquals(4, image.width); assertEquals(1, image.height)
            word(128, 24) // recovery must not read past the enclosing frame
            assertTrue(runCatching { d.get("flc").invoke(LuaString.valueOf(bytes)) }.isFailure)
        } finally { lua.cleanup() }
    }
    @Test fun `supplied DOS libraries detect and load through real host media APIs`() {
        val root = System.getenv("TAKE2_TEST_PATH")
        assumeTrue("Set TAKE2_TEST_PATH to the TAKE2 parent directory", root != null)
        for (folder in listOf("B13", "HELL")) {
            val manager = ScriptManager()
            try {
                val path = File(root!!, folder).absolutePath
                val game = manager.detectGame(path)!!; assertEquals("take2", game.engineId)
                fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
                    if (it.isCategory) leaves(it.children) else listOf(it)
                }
                val all = leaves(game.resources)
                assertEquals(all.size, all.map { it.id }.toSet().size)
                assertTrue(all.any { it.type == "image" }); assertTrue(all.any { it.type == "sound" })
                if (folder == "B13") {
                    assertEquals(3871, all.count { it.type == "image" })
                    assertEquals(3875, all.count { it.type == "text" })
                    assertEquals(10, all.count { it.type == "midi" })
                }
                val selected = if (System.getenv("TAKE2_FULL_SCAN") == "1") all else
                    game.resources.flatMap { group -> group.children.flatMap { pack ->
                        pack.children.take(2) + pack.children.takeLast(2)
                    } } + all.filter { it.type == "midi" } + all.filter { it.name == "TITLE" || it.name == "ABYSS" }
                for (node in selected.distinctBy { it.id }) {
                    val r = manager.loadResource(path, node.id) ?: error("Missing ${node.id}")
                    assertFalse("${node.id}: ${r.textContent}", r.description?.contains("decode error") == true)
                    when (node.type) {
                        "image", "palette" -> {
                            assertNotNull(node.id, r.image)
                            if (node.id == "BACKGRND.PL/1") {
                                assertEquals(640, r.image!!.width); assertEquals(480, r.image!!.height)
                            }
                        }
                        "animation" -> assertTrue(node.id, r.frames!!.isNotEmpty())
                        "sound" -> assertTrue(node.id, r.soundData!!.samples.isNotEmpty())
                        "midi" -> assertNotNull(javax.sound.midi.MidiSystem.getSequence(r.midiData!!.bytes.inputStream()))
                        else -> assertNotNull(node.id, r.textContent)
                    }
                    if (node.type == "image" && node.name in listOf("TITLE", "ABYSS")) {
                        val out = File("build/take2-previews/$folder").apply { mkdirs() }
                        ImageIO.write(r.image, "png", File(out, "${node.id.replace('/', '_')}_${node.name}.png"))
                    }
                    manager.releaseDecodedResources()
                }
                val image = all.first { it.type == "image" }
                val override = all.first { it.type == "palette" }
                assertNotNull(manager.loadResource(path, image.id, override.id)!!.image)
                assertNull(manager.loadResource(path, "invalid"))
                println("$folder: ${all.size} leaves; ${selected.distinctBy { it.id }.size} LuaJ previews verified")
            } finally { manager.close() }
        }
    }
}

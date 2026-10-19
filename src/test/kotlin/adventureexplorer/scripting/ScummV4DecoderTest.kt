package adventureexplorer.scripting

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaValue
import java.io.File
import javax.imageio.ImageIO

class ScummV4DecoderTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun le(n: Int, size: Int = 2) = ByteArray(size) { (n ushr (it * 8)).toByte() }
    private fun block(tag: String, payload: ByteArray) = le(payload.size + 6, 4) + tag.toByteArray() + payload
    private fun engine(lua: LuaEngine) = lua.loadScript(File("scripts/engines/scumm/engine.lua").absolutePath)
    private fun path(folder: File) = LuaValue.valueOf(folder.absolutePath)
    private fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
        if (it.isCategory) leaves(it.children) else listOf(it)
    }

    private fun fixture(): File {
        val folder = temporary.newFolder()
        val roomDirectory = le(3) + byteArrayOf(0) + le(0, 4) + byteArrayOf(2) + le(0, 4) + byteArrayOf(1) + le(0, 4)
        File(folder, "000.LFL").writeBytes(block("0R", roomDirectory) +
            listOf("0C", "0S", "0N").map { block(it, le(0)) }.reduce { a, b -> a + b })
        // The index maps room 1 to disk 2 and room 2 to disk 1. The nonzero
        // padding before LF catches code that mistakes a resource offset for
        // a physical archive offset or forgets the eight-byte wrapper.
        for (id in 1..2) {
            val bitmap = le(6) + le(4) + byteArrayOf(id.toByte(), 64)
            val room = block("RO", block("HD", le(8) + le(8) + le(0)) + block("BM", bitmap))
            val lf = block("LF", byteArrayOf(id.toByte(), 0) + room)
            val padding = ByteArray(19)
            val offset = 18 + padding.size
            val archive = block("LE", block("FO", byteArrayOf(1, id.toByte()) + le(offset, 4)) + padding + lf)
            File(folder, "DISK0${3 - id}.LEC").writeBytes(archive.map { (it.toInt() xor 0x69).toByte() }.toByteArray())
        }
        return folder
    }

    @Test fun `V4 routes room ids through disk tables and skips LF wrappers`() {
        val lua = LuaEngine()
        try {
            val script = engine(lua)
            val folder = fixture()
            assertTrue(script.get("detect").call(path(folder)).toboolean())
            for (id in 1..2) {
                val resource = script.get("load_resource").call(path(folder), LuaValue.valueOf("v4:bg:$id"))
                val image = lua.getImage(resource.get("image").toint())!!
                assertEquals(8, image.width); assertEquals(8, image.height)
                repeat(8) { y -> repeat(8) { x ->
                    assertEquals(if (id == 1) 0x0000aa else 0x00aa00, image.getRGB(x, y) and 0xffffff)
                } }
                assertEquals("v4:pal", script.get("default_palette").call(path(folder), LuaValue.valueOf("v4:bg:$id")).tojstring())
            }
            assertTrue(script.get("load_resource").call(path(folder), LuaValue.valueOf("v4:obj:1:999")).isnil())
        } finally { lua.cleanup() }
    }

    @Test fun `V4 rejects truncated directories invalid archive offsets and VGA strips`() {
        for (variant in listOf("index", "archive", "offset", "vga")) {
            val folder = fixture()
            if (variant == "index") {
                val index = File(folder, "000.LFL")
                index.writeBytes(index.readBytes().dropLast(1).toByteArray())
            } else {
                for (file in folder.listFiles()!!.filter { it.extension == "LEC" }) {
                    val data = file.readBytes().map { (it.toInt() xor 0x69).toByte() }.toByteArray()
                    when (variant) {
                        "archive" -> data[0] = 0 // bad enclosing size
                        "offset" -> le(0x7fffffff, 4).copyInto(data, 14)
                        "vga" -> {
                            // First EGA strip offset must match the width's u16 table.
                            data[data.size - 4] = 8
                        }
                    }
                    file.writeBytes(data.map { (it.toInt() xor 0x69).toByte() }.toByteArray())
                }
            }
            val lua = LuaEngine()
            try {
                assertFalse(variant, engine(lua).get("detect").call(path(folder)).toboolean())
            } finally { lua.cleanup() }
        }
    }

    @Test fun `V4 costume uses small headers explicit palette and word command offsets`() {
        val lua = LuaEngine()
        try {
            engine(lua) // installs the sibling module search path
            val cost = lua.loadScript(File("scripts/engines/scumm/scumm_cost.lua").absolutePath)
            val data = ByteArray(700)
            fun word(offset: Int, value: Int) { le(value).copyInto(data, offset) }
            le(data.size, 4).copyInto(data); "CO".toByteArray().copyInto(data, 4)
            data[7] = 0x58
            repeat(16) { data[8 + it] = it.toByte() }
            data[8] = 1; data[9] = 0
            word(24, 300); word(58, 64)
            word(64, 0x8000); word(66, 0x105); data[68] = 1
            val parsed = cost.get("parse").call(LuaString.valueOf(data), LuaValue.valueOf(4))
            assertFalse(parsed.isnil())
            assertEquals(0, parsed.get("base").toint())
            assertEquals(300, parsed.get("anim_cmds").toint())
            assertEquals(0, parsed.get("pal").get(1).toint())
            val limb = parsed.get("parse_anim").call(parsed, LuaValue.ZERO).get(0)
            assertEquals(0x105, limb.get("start").toint())
            assertEquals(0x106, limb.get("stop").toint())
        } finally { lua.cleanup() }
    }

    @Test fun `supplied Monkey Island EGA graphics decode through LuaJ`() {
        val root = System.getenv("SCUMM_V4_TEST_PATH")
        assumeTrue("Set SCUMM_V4_TEST_PATH to Monkey Island EGA", root != null)
        val manager = ScriptManager()
        try {
            val game = manager.detectGame(root!!)!!
            assertEquals("scumm", game.engineId)
            val all = leaves(game.resources)
            assertEquals(all.size, all.map { it.id }.toSet().size)
            assertEquals(81, all.count { it.id.startsWith("v4:bg:") })
            assertEquals(606, all.count { it.id.startsWith("v4:obj:") })
            assertEquals(115, all.count { it.id.startsWith("v4:sheet:") })
            assertEquals(2020, all.count { it.id.startsWith("v4:anim:") })
            val previews = File("build/scumm-v4-previews").apply { mkdirs() }
            val exportIds = setOf("v4:bg:1", "v4:bg:28", "v4:sheet:1",
                all.first { it.id.startsWith("v4:obj:28:") }.id)
            for (node in all) {
                val result = manager.loadResource(root, node.id) ?: error("Failed ${node.id}")
                if (result.type == "text") assertTrue(node.id, result.textContent!!.contains("no visible cels"))
                else assertTrue(node.id, result.image != null || !result.frames.isNullOrEmpty())
                if (node.id in exportIds && result.image != null) {
                    ImageIO.write(result.image, "png", File(previews, node.id.replace(':', '_') + ".png"))
                }
                manager.releaseDecodedResources()
            }
            println("SCUMM V4: ${all.size} graphics leaves decoded through LuaJ")
        } finally { manager.close() }
    }
}

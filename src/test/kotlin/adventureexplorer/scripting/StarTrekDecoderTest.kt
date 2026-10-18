package adventureexplorer.scripting

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaValue
import java.io.File

class StarTrekDecoderTest {
    private fun raw(vararg bytes: Int) = LuaString.valueOf(bytes.map { it.toByte() }.toByteArray())
    private fun decoder(block: (LuaValue) -> Unit) {
        val lua = LuaEngine()
        try { block(lua.loadScript(File("scripts/engines/startrek/engine.lua").absolutePath).get("_debug")) }
        finally { lua.cleanup() }
    }
    @Test fun `LZSS uses little endian distances overlapping copies and zero history`() = decoder { d ->
        val fn = d.get("lzss")
        assertEquals("ABCABCABC", fn.call(raw(7,65,66,67,0x33,0), LuaValue.valueOf(9)).tojstring())
        assertEquals("AAAAAA", fn.call(raw(1,65,0x12,0), LuaValue.valueOf(6)).tojstring())
        assertEquals("\u0000\u0000\u0000", fn.call(raw(0,0,0),LuaValue.valueOf(3)).tojstring())
    }
    @Test fun `LZSS rejects truncation and output overrun`() = decoder { d ->
        for ((bytes,size) in listOf(raw(1) to 1, raw(0,0) to 3, raw(0,0,0) to 2)) {
            assertTrue(runCatching { d.get("lzss").call(bytes,LuaValue.valueOf(size)) }.isFailure)
        }
    }
    @Test fun `bitmap keeps signed origins and validates dimensions`() = decoder { d ->
        val pic=d.get("bitmap").call(raw(255,255,2,0,2,0,1,0,7,8))
        assertEquals(-1,pic.get("x").toint());assertEquals(2,pic.get("y").toint())
        assertEquals(2,pic.get("w").toint());assertEquals(1,pic.get("h").toint())
        assertTrue(runCatching { d.get("bitmap").call(raw(0,0,0,0,2,0,2,0,1)) }.isFailure)
    }
    @Test fun `VGA palette and Spanish Latin1 text survive LuaJ`() = decoder { d ->
        val palette=ByteArray(768);palette[3]=63;palette[4]=32;palette[5]=1
        val p=d.get("palette").call(LuaString.valueOf(palette))
        assertEquals(252,p.get(4).toint());assertEquals(128,p.get(5).toint());assertEquals(4,p.get(6).toint())
        assertEquals("A\néñ",d.get("text").call(raw(65,0,0xe9,0xf1)).tojstring())
    }
    @Test fun `installed DOS games load images palettes sequences audio and data`() {
        val root=System.getenv("STAR_TREK_TEST_PATH")
        assumeTrue("Set STAR_TREK_TEST_PATH to the TREK parent folder",root!=null)
        for (folder in listOf("STARTREK","RITES")) {
            val path=File(root!!,folder).absolutePath
            val manager=ScriptManager()
            try {
                val game=manager.detectGame(path)!!;assertEquals("startrek",game.engineId)
                fun leaves(nodes: List<adventureexplorer.model.ResourceNode>): List<adventureexplorer.model.ResourceNode> =
                    nodes.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
                val all=leaves(game.resources)
                assertEquals(all.size,all.map { it.id }.toSet().size)
                val selected=game.resources.flatMap { category -> category.children.flatMap { pack ->
                    pack.children.take(2) + pack.children.takeLast(2)
                } } + all.filter { it.type=="midi" || it.type=="sound" || it.type=="palette" }
                val out=File("build/startrek-previews/$folder").apply { mkdirs() }
                for (node in selected.distinctBy { it.id }) {
                    val r=manager.loadResource(path,node.id) ?: error("Failed ${node.id}")
                    when (node.type) {
                        "image","palette" -> assertNotNull(node.id,r.image)
                        "animation" -> { assertNotNull(node.id,r.frames);assertTrue(r.frames!!.isNotEmpty()) }
                        "midi" -> {
                            assertNotNull(node.id,r.midiData)
                            assertNotNull(javax.sound.midi.MidiSystem.getSequence(r.midiData!!.bytes.inputStream()))
                        }
                        "sound" -> { assertNotNull(node.id,r.soundData);assertTrue(r.soundData!!.samples.isNotEmpty()) }
                        else -> assertNotNull(node.id,r.textContent)
                    }
                    if (node.id=="DATA:BRIDGE.BGD:0" || node.id=="DATA:BRIDGE.BMP:0")
                        javax.imageio.ImageIO.write(r.image,"png",File(out,"bridge.png"))
                    manager.releaseDecodedResources()
                }
                val imageId=if (folder=="RITES") "DATA:BRIDGE.BGD:0" else "DATA:BRIDGE.BMP:0"
                val original=manager.loadResource(path,imageId)!!.image!!
                val alternate=manager.loadResource(path,imageId,"pal:DATA:PALETTE.PAL:0")!!.image!!
                assertTrue((0 until original.height).any { y -> (0 until original.width).any { x -> original.getRGB(x,y)!=alternate.getRGB(x,y) } })
                if (folder=="STARTREK") {
                    val damaged=manager.loadResource(path,"DATA:S5ROOM3.BMP:0")!!
                    assertTrue(damaged.textContent!!.contains("Cannot decode resource"))
                }
                assertNull(manager.loadResource(path,"nonexistent"))
                println("$folder: ${all.size} leaves, ${selected.distinctBy { it.id }.size} real LuaJ previews verified")
            } finally { manager.close() }
        }
    }
}

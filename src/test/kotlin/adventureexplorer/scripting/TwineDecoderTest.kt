package adventureexplorer.scripting

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaValue
import java.io.File

class TwineDecoderTest {
    private fun raw(vararg b: Int) = LuaString.valueOf(b.map { it.toByte() }.toByteArray())
    private fun decoder(block: (LuaValue) -> Unit) {
        val lua=LuaEngine()
        try { block(lua.loadScript(File("scripts/engines/twine/engine.lua").absolutePath).get("_debug")) }
        finally { lua.cleanup() }
    }
    @Test fun `HQR compression supports both length biases and overlapping history`() = decoder { d ->
        val f=d.get("unpack")
        assertEquals("AAAA",f.invoke(arrayOf(raw(1,65,0,0),LuaValue.valueOf(4),LuaValue.valueOf(2))).arg1().tojstring())
        assertEquals("ABCABC",f.invoke(arrayOf(raw(7,65,66,67,0x21,0),LuaValue.valueOf(6),LuaValue.valueOf(1))).arg1().tojstring())
        for (s in listOf(raw(0,0,0),raw(1))) assertTrue(runCatching {
            f.invoke(arrayOf(s,LuaValue.valueOf(4),LuaValue.valueOf(1)))
        }.isFailure)
    }
    @Test fun `sprite runs retain skips literals repeats and image origins`() = decoder { d ->
        val s=d.get("sprite").call(raw(6,1,7,8,3,1,0x41,5,6,0x81,9),LuaValue.valueOf(0))
        assertEquals(6,s.get("w").toint());assertEquals(7,s.get("x").toint())
        assertEquals(listOf(0,0,5,6,9,9),(1..6).map { s.get("px").get(it).toint() })
        assertTrue(runCatching { d.get("sprite").call(raw(1,1,0,0,1,0x81,9),LuaValue.valueOf(0)) }.isFailure)
        assertEquals("España é",d.get("text").call(raw(69,115,112,97,164,97,32,130)).tojstring())
    }
    @Test fun `installed games load scenery sprites dialogue palettes and encoded audio through LuaJ`() {
        val root=System.getenv("LBA_TEST_PATH");assumeTrue("Set LBA_TEST_PATH to the LBA parent folder",root!=null)
        for (game in listOf("LBA1","LBA2")) {
            val manager=ScriptManager();val path=File(root!!,game).absolutePath
            try {
                val detected=manager.detectGame(path)!!;assertEquals("twine",detected.engineId)
                fun leaves(nodes: List<adventureexplorer.model.ResourceNode>): List<adventureexplorer.model.ResourceNode> =
                    nodes.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }
                val all=leaves(detected.resources)
                assertEquals(all.size,all.map { it.id }.toSet().size)
                val selected=detected.resources.flatMap { c -> c.children.flatMap { p -> p.children.take(2)+p.children.takeLast(1) } } + all.filter { it.type=="model" }
                val out=File("build/twine-previews/$game").apply { mkdirs() }
                val failures=mutableListOf<String>()
                for (n in selected.distinctBy { it.id }) {
                    val r=manager.loadResource(path,n.id)?:error(n.id)
                    if(r.description.orEmpty().contains("decode diagnostic")) { failures+="${n.id}: ${r.textContent}";continue }
                    when(n.type) {
                        "image","palette" -> assertNotNull(n.id,r.image)
                        "model" -> { assertNotNull(n.id,r.modelData);assertTrue(n.id,r.modelData!!.faces.isNotEmpty() || r.modelData!!.lines.isNotEmpty()) }
                        "sound" -> assertTrue(n.id,r.soundData?.samples?.isNotEmpty()==true)
                        "midi" -> assertNotNull(n.id,javax.sound.midi.MidiSystem.getSequence(r.midiData!!.bytes.inputStream()))
                        else -> assertNotNull(n.id,r.textContent)
                    }
                    if (n.id.startsWith("grids:") && n==selected.first { it.id.startsWith("grids:") })
                        javax.imageio.ImageIO.write(r.image,"png",File(out,"scenery.png"))
                    if (n.id in listOf("models:BODY.HQR:0","models:OBJFIX.HQR:0","models:CITADEL.OBL:0")) {
                        val m=r.modelData!!
                        assertTrue(n.id,m.vertices.all { it.x.isFinite() && it.y.isFinite() && it.z.isFinite() })
                        javax.imageio.ImageIO.write(adventureexplorer.models.ModelRenderer.render(m,yaw=205.0),"png",File(out,n.id.replace(':','_')+".png"))
                    }
                    manager.releaseDecodedResources()
                }
                assertTrue(failures.joinToString("\n"),failures.isEmpty())
                val sprite=all.first { it.id.startsWith("sprites:") }.id
                val a=manager.loadResource(path,sprite)!!.image!!
                val alternate=if(game=="LBA1") "palettes:RESS.HQR:22" else "palettes:RESS.HQR:9"
                val b=manager.loadResource(path,sprite,alternate)!!.image!!
                assertTrue((0 until a.height).any { y -> (0 until a.width).any { x -> a.getRGB(x,y)!=b.getRGB(x,y) } })
                assertNull(manager.loadResource(path,"missing"))
                println("$game: ${all.size} catalog leaves; ${selected.distinctBy { it.id }.size} LuaJ previews verified")
            } finally { manager.close() }
        }
    }
}

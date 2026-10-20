package adventureexplorer.scripting

import adventureexplorer.app.ResourceExporter
import adventureexplorer.model.ResourceNode
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import javax.imageio.ImageIO
import javax.sound.sampled.AudioSystem

class DreamwebIntegrationTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun `full freeware UK CD resources decode and export through the real host`() = runBlocking {
        val path = System.getenv("DREAMWEB_TEST_PATH")
        assumeTrue("Set DREAMWEB_TEST_PATH to the full English UK CD release", path != null)
        val mgr = ScriptManager()
        try {
            val game = mgr.detectGame(path!!)!!
            assertEquals("dreamweb", game.engineId)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
                if (it.isCategory) leaves(it.children) else listOf(it)
            }
            val all = leaves(game.resources)
            assertEquals(all.size, all.map { it.id }.toSet().size)
            println("DreamWeb catalog: ${all.size} leaves; ${all.groupingBy { it.type }.eachCount()}")
            assertEquals(11777, all.size)
            assertEquals(6665, all.count { it.type == "image" })
            assertEquals(589, all.count { it.type == "sound" })
            assertEquals(4503, all.count { it.type == "text" })
            assertEquals(8, all.count { it.type == "palette" })
            assertEquals(140, all.count { it.id.startsWith("map:") })
            assertEquals(7, all.count { it.id.startsWith("pcx:") })
            assertEquals(12, all.count { it.type == "animation" })
            assertEquals(469, all.count { it.id.startsWith("speech:") })
            assertEquals("pal:DREAMWEB.PAL", mgr.defaultPaletteFor(path,"frame:DREAMWEB.R00:2:3"))
            val previews = File("build/dreamweb-research/previews").apply { mkdirs() }
            for ((i,node) in all.withIndex()) {
                val r = mgr.loadResource(path,node.id) ?: error(node.id)
                when (node.type) {
                    "image", "palette" -> {
                        val image = r.image ?: error("${node.id}: ${r.textContent}")
                        assertTrue(image.width > 0 && image.height > 0)
                        if (node.id.startsWith("pcx:") || node.id in setOf("map:DREAMWEB.R00:1:0","frame:DREAMWEB.R00:2:3","tiles:DREAMWEB.R00")) {
                            ImageIO.write(image,"png",File(previews,node.id.replace(':','_')+".png"))
                        }
                        if (node.id.startsWith("map:") || node.id.startsWith("pcx:")) assertFalse(image.colorModel.hasAlpha())
                        if (node.id.startsWith("pcx:")) assertEquals(16,r.paletteColors)
                        if (node.id.startsWith("frame:")) assertTrue(image.colorModel.hasAlpha())
                    }
                    "animation" -> {
                        val frames = r.frames ?: error(node.id)
                        assertTrue(frames.size > 1)
                        assertTrue(frames.all { it.width==frames[0].width && it.height==frames[0].height })
                        if (node.id=="anim:DREAMWEB.R00:2") {
                            assertEquals(5, frames.size)
                            assertEquals(114,r.frameDelayMs)
                            assertArrayEquals(frames[0].getRGB(0,0,frames[0].width,frames[0].height,null,0,frames[0].width),
                                frames[4].getRGB(0,0,frames[4].width,frames[4].height,null,0,frames[4].width))
                        }
                    }
                    "sound" -> {
                        val s = r.soundData ?: error(node.id)
                        assertEquals(22050,s.sampleRate); assertEquals(8,s.bitsPerSample)
                        assertEquals(1,s.channels); assertFalse(s.signed); assertTrue(s.samples.isNotEmpty())
                    }
                    "text" -> assertFalse(node.id,r.textContent.isNullOrEmpty())
                }
                mgr.releaseDecodedResources()
                if ((i+1)%2000==0) println("DreamWeb ${i+1}/${all.size} resources verified")
            }
            // Independently compute an entire map image using file offsets and JVM byte arrays.
            val room=File(path,"DREAMWEB.R00").readBytes()
            fun word(p:Int)=(room[p].toInt() and 255) or ((room[p+1].toInt() and 255) shl 8)
            val tileStart=96+192
            val mapStart=96+word(50)
            val rgb=File(path,"DREAMWEB.PAL").readBytes().copyOfRange(48,816)
            val map=mgr.loadResource(path,"map:DREAMWEB.R00:1:0")!!.image!!
            assertEquals(176,map.width); assertEquals(160,map.height)
            for (y in 0 until 160) for (x in 0 until 176) {
                val tile=room[mapStart+y/16*132+11+x/16].toInt() and 255
                val color=if(tile==0) 0 else room[tileStart+tile*256+y%16*16+x%16].toInt() and 255
                val expected=(0..2).fold(0xff000000.toInt()) { v,c -> v or (((rgb[color*3+c].toInt() and 255)/4*4) shl ((2-c)*8)) }
                assertEquals("map pixel $x,$y",expected,map.getRGB(x,y))
            }
            val clip="SPEECH/R01C0000.RAW"
            assertArrayEquals(File(path,clip).readBytes(),mgr.loadResource(path,"speech:$clip")!!.soundData!!.samples)
            val bank=File(path,"DREAMWEB.V99").readBytes()
            assertArrayEquals(bank.copyOfRange(168,168+9*2048),mgr.loadResource(path,"sound:DREAMWEB.V99:0")!!.soundData!!.samples)
            val normal=mgr.loadResource(path,"frame:DREAMWEB.R00:2:3")!!.image!!
            val altered=mgr.loadResource(path,"frame:DREAMWEB.R00:2:3","pal:DREAMWEB.I00")!!.image!!
            assertFalse(normal.getRGB(0,0,normal.width,normal.height,null,0,normal.width)
                .contentEquals(altered.getRGB(0,0,altered.width,altered.height,null,0,altered.width)))
            assertEquals("text",mgr.loadResource(path,"frame:DREAMWEB.R00:2:3","invalid")!!.type)
            assertNull(mgr.loadResource(path,"unknown"))
            val chosen=setOf("map:DREAMWEB.R00:1:0","frame:DREAMWEB.R00:2:3","pcx:DREAMWEB.I00","anim:DREAMWEB.R00:2", "sound:DREAMWEB.V99:0","speech:$clip","pal:DREAMWEB.PAL","pal:DREAMWEB.I00","text:DREAMWEB.R00:9:0")
            val selected=all.filter { it.id in chosen }.map { it.copy(name=it.id.replace(':','_').replace('/','_')) }
            assertEquals(9,selected.size)
            val exported=ResourceExporter({mgr.loadResource(path,it.id)},mgr::releaseDecodedResources).export(selected,temporary.root)
            assertEquals(9,exported.exported); assertTrue(exported.failures.toString(),exported.failures.isEmpty())
            assertEquals(768L,File(temporary.root,"pal_DREAMWEB.PAL.bin").length())
            assertEquals(48L,File(temporary.root,"pal_DREAMWEB.I00.bin").length())
            assertTrue(ImageIO.read(File(temporary.root,"frame_DREAMWEB.R00_2_3.png")).colorModel.hasAlpha())
            assertEquals(5,File(temporary.root,"anim_DREAMWEB.R00_2").listFiles()!!.count { it.extension=="png" })
            AudioSystem.getAudioInputStream(File(temporary.root,"sound_DREAMWEB.V99_0.wav")).use {
                assertEquals(22050f,it.format.sampleRate,0f); assertEquals(9*2048L,it.frameLength)
            }
            println("DreamWeb full UK CD: all ${all.size} leaves loaded; independent map pixels and PCM bytes agree; PNG, WAV, animation, text and palette exports passed")
        } finally { mgr.close() }
    }
}

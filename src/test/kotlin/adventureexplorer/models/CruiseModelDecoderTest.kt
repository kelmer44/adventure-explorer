package adventureexplorer.models

import adventureexplorer.model.*
import adventureexplorer.scripting.ScriptManager
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File

class CruiseModelDecoderTest {
    private fun set(vararg poses: ByteArray): ByteArray {
        val out=ByteArrayOutputStream();val d=DataOutputStream(out)
        d.writeBytes("SET");d.writeByte(0);d.writeShort(poses.size)
        var offset=0
        poses.forEach { p ->
            d.writeInt(offset);d.writeShort(p.size);d.writeShort(1);d.writeShort(0)
            repeat(3) { d.writeShort(0) };offset+=p.size
        }
        poses.forEach { d.write(it) }
        return out.toByteArray()
    }
    // Square, overlaid triangle, and a final vector line, in authored order.
    private fun pose(): ByteArray = byteArrayOf(1,20,20,0,0,4,
        0,0,20,0,20,20,0,20,
        4,2,0,0,0,0,1,2,3,
        3,3,0,0,0,0,1,2,
        2,4,0,0,0,0,2,-1)
    @Test fun `flat poses keep palette indices and primitive drawing order`() {
        val pal=IntArray(256);pal[2]=0xFF0000;pal[3]=0x00FF00;pal[4]=0x0000FF
        val m=CruiseModelDecoder.decode(set(pose()),0,pal)
        assertTrue(m.planar);assertTrue(m.vertices.all { it.y==0.0 })
        assertEquals(listOf(4,3,2),m.faces.map { it.indices.size })
        assertEquals(listOf(0xFF0000,0x00FF00,0x0000FF),m.faces.map { it.rgb })
        val image=ModelRenderer.render(m,100,100)
        assertEquals(0x0000FF,image.getRGB(50,50) and 0xFFFFFF) // final line covers both fills
        assertEquals(0x00FF00,image.getRGB(65,40) and 0xFFFFFF)
        assertEquals(0xFF0000,image.getRGB(35,60) and 0xFFFFFF)
    }
    @Test fun `mirrored frames resolve signed relative indices and anchor offsets`() {
        val alias=byteArrayOf(0,0,-1,-1,0,3,0,4)
        val bytes=set(pose(),alias)
        val a=CruiseModelDecoder.decode(bytes,0)
        val b=CruiseModelDecoder.decode(bytes,1)
        for(i in a.vertices.indices) {
            assertEquals(-a.vertices[i].x-3,b.vertices[i].x,0.0)
            assertEquals(a.vertices[i].z+4,b.vertices[i].z,0.0)
        }
        assertEquals(a.faces,b.faces)
    }
    @Test fun `minimum scale and empty artwork are handled without fabricated geometry`() {
        val p=pose();p[17]=3 // first polygon only visible above scale 512
        val m=CruiseModelDecoder.decode(set(p),0)
        assertEquals(2,m.faces.size)
        val blank=byteArrayOf(1,0,0,0,0,2,0,0,1,1,-1)
        assertTrue(CruiseModelDecoder.decode(set(blank),0).faces.isEmpty())
    }
    @Test fun `invalid frame sizes references vertices and missing terminators fail`() {
        fun reject(bytes: ByteArray,frame: Int=0) {
            try { CruiseModelDecoder.decode(bytes,frame);fail("Expected rejection") } catch(_: IllegalArgumentException) {}
        }
        reject(set(pose()).dropLast(1).toByteArray())
        reject(set(pose()),1)
        reject(set(byteArrayOf(0,0,0,0,0,0,0,0))) // self reference
        reject(set(byteArrayOf(0,0,-1,-1,0,0,0,0))) // out of range
        val bad=pose();bad[19]=4;reject(set(bad)) // point index equals point count
        val noEnd=pose();noEnd[noEnd.lastIndex]=0;reject(set(noEnd))
    }
    @Test fun `concave polygon retains its notch`() {
        val vertices=listOf(ModelVertex(0.0,0.0,0.0),ModelVertex(2.0,0.0,0.0),
            ModelVertex(2.0,0.0,1.0),ModelVertex(1.0,0.0,1.0),
            ModelVertex(1.0,0.0,2.0),ModelVertex(0.0,0.0,2.0))
        val model=ModelData(vertices,listOf(ModelFace((0..5).toList(),rgb=0xFF0000)),1,planar=true)
        val img=ModelRenderer.render(model,100,100)
        assertEquals(0x1A1D24,img.getRGB(65,35) and 0xFFFFFF)
        assertEquals(0xFF0000,img.getRGB(35,35) and 0xFFFFFF)
    }
    @Test fun `local Cruise polygon poses decode through Lua and render`() {
        val path=System.getenv("CRUISE_MODEL_TEST_PATH")
        assumeTrue("Set CRUISE_MODEL_TEST_PATH to validate installed assets",path!=null)
        val manager=ScriptManager()
        try {
            val game=manager.detectGame(path!!)!!;assertEquals("cruise",game.engineId)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap { if(it.isCategory) leaves(it.children) else listOf(it) }
            val nodes=leaves(game.resources).filter { it.type=="model" }
            assertTrue(nodes.isNotEmpty())
            val failures=mutableListOf<String>()
            for(node in nodes) {
                try {
                    val model=manager.loadResource(path,node.id)?.modelData ?: error("No model returned")
                    assertTrue(model.planar)
                    val image=ModelRenderer.render(model,160,120)
                    if (node.id in listOf("poly_D1_BIGRAOUL.SET_0","poly_D1_BIGRAOUL.SET_3","poly_D1_LOGOFIN.SET_0")) {
                        val out=File("build/cruise-previews");out.mkdirs()
                        javax.imageio.ImageIO.write(ModelRenderer.render(model),"png",File(out,node.id+".png"))
                    }
                    assertEquals(160,image.width)
                } catch(e: Exception) { failures += "${node.id}: ${e.message}" }
                manager.releaseDecodedResources()
            }
            println("Cruise: ${nodes.size} polygon poses; ${failures.size} failures")
            assertTrue(failures.joinToString("\n"),failures.isEmpty())
        } finally { manager.close() }
    }
}

package adventureexplorer.models

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class AitdModelDecoderTest {
    private fun body(optimized: Boolean=false): ByteArray {
        val b=ByteBuffer.allocate(256).order(ByteOrder.LITTLE_ENDIAN)
        fun word(n: Int) { b.putShort(n.toShort()) }
        fun vertex(x: Int,y: Int,z: Int) { word(x);word(y);word(z) }
        word(if(optimized) 11 else 3); repeat(6) { word(0) }; word(0)
        word(4)
        vertex(0,0,0);vertex(10,0,0);vertex(1,0,0);vertex(0,-2,0)
        word(2);word(0);word(if(optimized) 24 else 16)
        word(0);word(2);word(0);b.put(-1);b.put(0);word(0);vertex(0,0,0)
        if(optimized) { vertex(0,0,0);word(0) }
        word(12);word(2);word(6);b.put(0);b.put(1);word(1);vertex(0,-4,0)
        if(optimized) { vertex(0,0,256);word(0) }
        word(3)
        b.put(1);b.put(3);b.put(0);b.put(7);word(0);word(12);word(18)
        b.put(0);b.put(0);b.put(8);b.put(0);word(12);word(18)
        b.put(3);b.put(0);b.put(9);b.put(0);word(2);word(18)
        return b.array().copyOf(b.position())
    }
    @Test fun `original body translates bones and attaches vertices in stored pose`() {
        val palette=IntArray(256) { 0x102030 }
        val model=AitdModelDecoder.decode(body(),palette)
        assertEquals(11.0,model.vertices[2].x,1e-8)
        assertEquals(4.0,model.vertices[2].z,1e-8)
        assertEquals(6.0,model.vertices[3].z,1e-8)
        assertEquals(0x102030,model.faces[0].rgb)
        assertEquals(1,model.lines.size)
        assertEquals(74,model.vertices.size) // 4 source vertices plus sphere approximation
        assertEquals(61,model.faces.size)
        assertTrue(ModelRenderer.render(model,100,100).getRGB(0,0,100,100,null,0,100).distinct().size>1)
    }
    @Test fun `optimized body applies local rotation after translation`() {
        val model=AitdModelDecoder.decode(body(true))
        assertEquals(14.0,model.vertices[2].x,1e-8)
        assertEquals(-1.0,model.vertices[2].z,1e-8)
    }
    @Test fun `truncated data and invalid bone or primitive references fail`() {
        val invalid=body()
        ByteBuffer.wrap(invalid).order(ByteOrder.LITTLE_ENDIAN).putShort(68,7) // unaligned bone base
        for(bytes in listOf(body().copyOf(40),invalid,byteArrayOf())) {
            assertThrows(IllegalArgumentException::class.java) { AitdModelDecoder.decode(bytes) }
        }
    }
}

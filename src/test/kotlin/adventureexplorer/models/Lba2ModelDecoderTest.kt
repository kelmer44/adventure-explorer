package adventureexplorer.models

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class Lba2ModelDecoderTest {
    private val palette=IntArray(256) { it*0x010101 }
    private fun model(): ByteArray {
        val b=ByteBuffer.allocate(176).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(0,0x10);b.putInt(4,96)
        for(p in 32..88 step 8) { b.putInt(p,0);b.putInt(p+4,176) }
        b.putInt(32,2);b.putInt(36,96)
        b.putShort(96,(-1).toShort());b.putShort(100,1)
        b.putShort(104,0);b.putShort(106,0);b.putShort(108,2)
        b.putInt(40,3);b.putInt(44,112)
        b.putShort(112,100);b.putShort(114,200);b.putShort(116,300)
        b.putShort(120,10);b.putShort(126,1)
        b.putShort(130,20);b.putShort(134,1)
        b.putInt(64,1);b.putInt(68,136);b.putInt(76,156)
        b.putShort(136,0);b.putShort(138,1);b.putShort(140,20)
        b.putShort(144,0);b.putShort(146,1);b.putShort(148,2);b.put(152,42)
        return b.array()
    }
    @Test fun `grouped faces use direct indices and bone-local vertices resolve to Z up`() {
        val m=Lba2ModelDecoder.decode(model(),palette)
        assertEquals(listOf(0,1,2),m.faces.single().indices)
        assertEquals(0x2a2a2a,m.faces.single().rgb)
        assertEquals(110.0,m.vertices[1].x,0.0)
        assertEquals(300.0,m.vertices[1].y,0.0)
        assertEquals(200.0,m.vertices[1].z,0.0)
    }
    @Test fun `malformed polygon sections indices and skeleton cycles are rejected`() {
        for (change in listOf<(ByteBuffer)->Unit>(
            { it.putShort(140,7) }, { it.putShort(146,3) }, { it.putShort(104,1) },
            { it.putInt(68,175) }, { it.putInt(64,2) }
        )) {
            val bytes=model();change(ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN))
            assertTrue(runCatching { Lba2ModelDecoder.decode(bytes,palette) }.isFailure)
        }
    }
    @Test fun `textured triangles keep UVs and use palette-colored atlas crops`() {
        val bytes=model().copyOf(180);val b=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(76,168);b.putInt(88,1);b.putInt(92,176)
        b.putShort(136,8);b.putShort(140,32)
        b.putShort(150,0);b.put(157,1);b.put(159,2);b.put(161,3);b.put(163,4);b.put(165,5);b.put(167,6)
        b.put(176,10);b.put(177,20);b.put(178,7);b.put(179,7)
        val atlas=ByteArray(65536);atlas[20*256+10]=12
        val m=Lba2ModelDecoder.decode(bytes,palette,atlas)
        assertEquals(1.0,m.faces.single().uvs.first().u,0.0)
        assertEquals(2.0,m.faces.single().uvs.first().v,0.0)
        assertEquals(8,m.textures[0]!!.width)
        assertEquals(0xff0c0c0c.toInt(),m.textures[0]!!.getRGB(0,0))
    }
}

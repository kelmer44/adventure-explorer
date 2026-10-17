package adventureexplorer.models

import adventureexplorer.model.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ModelDecoderTest {
    private fun grim(parent: Int = -1, index: Int = 2) = """
        SECTION: HEADER
        3DO 2.1
        SECTION: MODELRESOURCE
        MATERIALS 1
        0: test.mat
        SECTION: GEOMETRYDEF
        RADIUS 1
        INSERT OFFSET 0 0 0
        GEOSETS 1
        GEOSET 0
        MESHES 1
        MESH 0
        NAME triangle
        RADIUS 1
        GEOMETRYMODE\t4
        LIGHTINGMODE 3
        TEXTUREMODE 0
        VERTICES 3
        0: 0 0 0 1
        1: 1 0 0 1
        2: 0 0 1 1
        TEXTURE VERTICES 0
        VERTEX NORMALS
        0: 0 1 0
        1: 0 1 0
        2: 0 1 0
        FACES 1
        0: 0 0 4 3 0 0 3 0, 0 1, 0 $index, 0
        FACE NORMALS
        0: 0 1 0
        SECTION: HIERARCHYDEF
        HIERARCHY NODES 2
        0: 0 0 -1 $parent 1 -1 1 10 0 0 0 90 0 100 0 0 parent
        1: 0 0 0 0 -1 -1 0 2 0 0 0 0 0 1 0 0 mesh
    """.trimIndent().replace("\\t","\t").toByteArray()

    @Test fun `Grim child inherits rotation and translation but not parent pivot`() {
        val model=GrimModelDecoder.decode(grim())
        assertEquals(10.0,model.vertices[0].x,1e-8)
        assertEquals(3.0,model.vertices[0].y,1e-8)
        assertEquals(4.0,model.vertices[1].y,1e-8)
        assertEquals(1,model.meshCount)
    }
    @Test fun `invalid indices cycles nonfinite vertices and truncation are rejected`() {
        for (bytes in listOf(grim(index=3),grim(parent=1),grim().copyOf(90),
            String(grim()).replace("1: 1 0 0 1","1: NaN 0 0 1").toByteArray())) {
            assertThrows(IllegalArgumentException::class.java) { GrimModelDecoder.decode(bytes) }
        }
    }
    private fun city(): ByteArray {
        // One flat Gouraud triangle, three vertices and one normal.
        val b=ByteBuffer.allocate(104).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(0x41).putInt(0).putInt(1)
        b.putInt(48).putInt(3).putInt(72).putInt(1).putInt(28).putInt(1).putInt(0)
        b.put(byteArrayOf(6,4,0,0x30))
        b.putInt(0)
        repeat(3) { b.putShort(0).putShort(it.toShort()) }
        for (v in listOf(shortArrayOf(0,0,0,0),shortArrayOf(10,0,0,0),shortArrayOf(0,-10,0,0)))
            v.forEach { b.putShort(it) }
        b.putShort(0).putShort(0).putShort(4096).putShort(0)
        return b.array()
    }
    @Test fun `City relative pointers primitive indices and Z-up coordinates`() {
        val model=CityModelDecoder.decode(city())
        assertEquals(listOf(0,1,2),model.faces.single().indices)
        assertEquals(-10.0,model.vertices[2].y,0.0)
        val invalid=city(); ByteBuffer.wrap(invalid).order(ByteOrder.LITTLE_ENDIAN).putShort(50,99)
        assertThrows(IllegalArgumentException::class.java) { CityModelDecoder.decode(invalid) }
        assertThrows(IllegalArgumentException::class.java) { CityModelDecoder.decode(city().copyOf(70)) }
    }
    @Test fun `depth buffer resolves intersecting layers independent of polygon order`() {
        val vertices=listOf(ModelVertex(-1.0,-0.5,-1.0),ModelVertex(1.0,-0.5,-1.0),ModelVertex(0.0,-0.5,1.0),
            ModelVertex(-1.0,0.5,-1.0),ModelVertex(1.0,0.5,-1.0),ModelVertex(0.0,0.5,1.0))
        val near=ModelFace(listOf(0,1,2),0); val far=ModelFace(listOf(3,4,5),1)
        val first=ModelRenderer.render(ModelData(vertices,listOf(near,far),1),100,100,0.0,0.0)
        val second=ModelRenderer.render(ModelData(vertices,listOf(far,near),1),100,100,0.0,0.0)
        assertEquals(first.getRGB(50,50),second.getRGB(50,50))
        assertNotEquals(first.getRGB(0,0),first.getRGB(50,50))
        val wire=ModelRenderer.render(ModelData(vertices,listOf(near,far),1),100,100,0.0,0.0,wireframe=true)
        assertTrue(wire.getRGB(0,0,100,100,null,0,100).distinct().size>1)
    }
}

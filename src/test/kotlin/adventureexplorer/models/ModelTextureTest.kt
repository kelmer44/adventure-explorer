package adventureexplorer.models

import adventureexplorer.model.*
import adventureexplorer.scripting.ScriptManager
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.awt.image.BufferedImage
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ModelTextureTest {
    @Test fun `texture UVs interpolate without stretching and missing images fall back to solid`() {
        val vertices=listOf(ModelVertex(-1.0,0.0,-1.0),ModelVertex(1.0,0.0,-1.0),ModelVertex(-1.0,0.0,1.0))
        val face=ModelFace(listOf(0,1,2),uvs=listOf(ModelUv(0.0,2.0),ModelUv(2.0,2.0),ModelUv(0.0,0.0)))
        val texture=BufferedImage(2,2,BufferedImage.TYPE_INT_RGB)
        texture.setRGB(0,0,0xFF0000);texture.setRGB(1,0,0x00FF00)
        texture.setRGB(0,1,0x0000FF);texture.setRGB(1,1,0xFFFFFF)
        val model=ModelData(vertices,listOf(face),1,textures=mapOf(0 to texture))
        val image=ModelRenderer.render(model,100,100,0.0,0.0)
        assertEquals(0xFF0000,image.getRGB(25,35) and 0xFFFFFF)
        assertEquals(0x0000FF,image.getRGB(25,65) and 0xFFFFFF)
        assertNotEquals(image.getRGB(25,35),ModelRenderer.render(model.copy(textures=emptyMap()),100,100,0.0,0.0).getRGB(25,35))
    }
    @Test fun `City first pose composes child rotation and envelope ranges`() {
        val s=ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN)
        s.putShort(1).putShort(2)
        s.putShort(0).putShort(0).putShort(0).put(1).put(1)
        s.putShort(10).putShort(0).putShort(0).put(0).put(0)
        val e=ByteBuffer.allocate(36).order(ByteOrder.LITTLE_ENDIAN)
        e.putInt(1).putInt(2).putInt(0)
        e.putShort(1).putShort(0).putInt(0).putInt(0)
        e.putShort(1).putShort(1).putInt(0).putInt(0)
        val a=ByteBuffer.allocate(80).order(ByteOrder.LITTLE_ENDIAN)
        a.put("ANI0".toByteArray()).putInt(1).putInt(0)
        a.putShort(4).putShort(1).putShort(2).putShort(1).putInt(0)
        a.position(40)
        repeat(2) { for(v in listOf(4096,0,0,0,4096,0,0,0,4096,0)) a.putShort(v.toShort()) }
        val model=ModelData(listOf(ModelVertex(0.0,0.0,0.0),ModelVertex(2.0,0.0,0.0)),emptyList(),1)
        val posed=CityModelPose.apply(model,s.array(),e.array(),a.array())
        assertEquals(12.0,posed.vertices[1].x,1e-8)
        assertThrows(IllegalArgumentException::class.java) { CityModelPose.apply(model,s.array(),e.array(),a.array().copyOf(45)) }
    }
    @Test fun `installed City and Grim support automatic textures overrides and untextured mode`() {
        val paths=listOf("CITY_MODEL_TEST_PATH" to "CIMIET.TMM", "GRIM_MODEL_TEST_PATH" to "manny_deathrobe.3do")
        assumeTrue(paths.any { System.getenv(it.first)!=null })
        for((variable,name) in paths) {
            val path=System.getenv(variable) ?: continue
            val manager=ScriptManager()
            try {
                val game=manager.detectGame(path)!!
                fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap { if(it.isCategory) leaves(it.children) else listOf(it) }
                val node=leaves(game.resources).first { it.name==name }
                val palette=manager.defaultPaletteFor(path,node.id)
                val auto=manager.loadResource(path,node.id,palette)!!.modelData!!
                assertTrue(auto.faces.any { it.uvs.isNotEmpty() })
                assertTrue(auto.textures.isNotEmpty());assertTrue(auto.textureOptions.isNotEmpty())
                val choice=auto.textureOptions.first()
                val override=manager.loadResource(path,node.id,palette,choice.id)!!.modelData!!
                assertEquals(choice.id,override.selectedTextureId);assertTrue(override.textures.isNotEmpty())
                val solid=manager.loadResource(path,node.id,palette,"__none__")!!.modelData!!
                assertTrue(solid.textures.isEmpty());assertEquals(auto.vertices,solid.vertices)
                if (variable.startsWith("GRIM")) {
                    assertTrue(auto.textures.size>1)
                    assertEquals(1,override.textures.values.distinct().size)
                    val otherPalette=leaves(game.resources).first { it.type=="palette" && it.id!=palette }
                    val recolored=manager.loadResource(path,node.id,otherPalette.id)!!.modelData!!
                    assertTrue(auto.textures.any { (slot,image) ->
                        val other=recolored.textures[slot]!!
                        !image.getRGB(0,0,image.width,image.height,null,0,image.width).contentEquals(
                            other.getRGB(0,0,other.width,other.height,null,0,other.width))
                    })
                }
                val out=File("build/model-previews");out.mkdirs()
                javax.imageio.ImageIO.write(ModelRenderer.render(auto,yaw=if(variable.startsWith("GRIM")) 205.0 else 25.0),"png",File(out,"textured-$name.png"))
            } finally { manager.close() }
        }
    }
}

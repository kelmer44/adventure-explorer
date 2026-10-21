package adventureexplorer.graphics

import adventureexplorer.model.CompositeLayer
import adventureexplorer.scripting.LuaEngine
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.awt.image.BufferedImage

class CompositeTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun solid(w: Int, h: Int, argb: Int) = BufferedImage(w, h, BufferedImage.TYPE_INT_ARGB).apply {
        for (y in 0 until h) for (x in 0 until w) setRGB(x, y, argb)
    }

    private val background = CompositeLayer("Background", solid(4, 3, 0xFF0000FF.toInt()))
    private val top = CompositeLayer("Object", solid(2, 2, 0xFFFF0000.toInt()), x = 3, y = 2)
    private val hidden = CompositeLayer("Other state", solid(1, 1, 0xFF00FF00.toInt()), visible = false)

    @Test fun `canvas covers every layer unless a size is given`() {
        assertEquals(5 to 4, Composite.canvasSize(listOf(background, top)))
        assertEquals(4 to 3, Composite.canvasSize(listOf(background, top), 4, 3))
    }

    @Test fun `later layers draw on top and hidden layers are skipped`() {
        val layers = listOf(background, hidden, top)
        val out = Composite.flatten(layers, 4, 3)
        assertEquals(0xFF0000FF.toInt(), out.getRGB(0, 0))
        assertEquals(0xFFFF0000.toInt(), out.getRGB(3, 2))
        assertTrue(top.contains(3, 2) && !top.contains(2, 2))
        val custom = Composite.flatten(layers, 4, 3) { it == 1 }
        assertEquals(0xFF00FF00.toInt(), custom.getRGB(0, 0))
        assertEquals(0, custom.getRGB(3, 2))
    }

    @Test fun `out-of-palette transparent index keeps every palette colour opaque`() {
        val script = temporary.newFile("t.lua").apply {
            writeText("""
                local pal = {}
                for i = 1, 768 do pal[i] = 255 end
                return { image = image_create_indexed(3, 1, { 0, 255, 256 }, pal, 256) }
            """.trimIndent())
        }
        val lua = LuaEngine()
        try {
            val image = lua.getImage(lua.loadScript(script.absolutePath).get("image").toint())!!
            assertEquals(0xFF, image.getRGB(0, 0) ushr 24)
            assertEquals(0xFF, image.getRGB(1, 0) ushr 24)
            assertEquals(0, image.getRGB(2, 0) ushr 24)
        } finally { lua.cleanup() }
    }
}

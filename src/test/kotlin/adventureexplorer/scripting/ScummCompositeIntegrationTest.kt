package adventureexplorer.scripting

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class ScummCompositeIntegrationTest {
    @Test fun `Monkey Island VGA room composite places objects from CDHD`() {
        val path = System.getenv("MONKEY_TEST_PATH")
        assumeTrue("Set MONKEY_TEST_PATH to Monkey Island 1 (VGA, SCUMM V5)", path != null)
        val mgr = ScriptManager()
        try {
            assertEquals("scumm", mgr.detectGame(path!!)!!.engineId)
            val room = mgr.loadResource(path, "comp:MONKEY:28")!!
            assertEquals("composite", room.type)
            val layers = room.layers!!
            assertEquals("Background", layers.first().name)
            assertEquals(640 to 144, room.image!!.width to room.image!!.height)
            val objects = layers.drop(1)
            assertTrue(objects.size >= 48)
            // V5 positions are 8-pixel aligned and every image fits the room
            assertTrue(objects.all { it.x % 8 == 0 && it.y % 8 == 0 })
            assertTrue(objects.all { it.x + it.image.width <= 640 && it.y + it.image.height <= 144 })
            // Names come from OBNA, and transparent strips produce see-through pixels
            assertTrue(objects.any { ':' in it.name })
            assertTrue(objects.any { layer ->
                (0 until layer.image.height).any { y -> (0 until layer.image.width).any { x ->
                    layer.image.getRGB(x, y) ushr 24 == 0 } }
            })
            // Each object layer matches the standalone object sprite pixel for pixel
            val first = objects.first { it.visible }
            val id = Regex("^Object (\\d+)").find(first.name)!!.groupValues[1]
            val sprite = mgr.loadResource(path, "obj:MONKEY:28:$id:1")!!.image!!
            for (y in 0 until sprite.height) for (x in 0 until sprite.width) {
                val a = first.image.getRGB(x, y)
                if (a ushr 24 != 0) assertEquals(sprite.getRGB(x, y) and 0xFFFFFF, a and 0xFFFFFF)
            }
        } finally { mgr.close() }
    }
}

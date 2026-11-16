package adventureexplorer.graphics

import adventureexplorer.audio.CryoApc
import adventureexplorer.model.ResourceNode
import adventureexplorer.scripting.ScriptManager
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.awt.Color
import java.awt.image.BufferedImage

/** Cryo Interactive formats: APC audio, HNM6 warp panoramas, Aztec JP6 cube maps. */
class CryoDecodersTest {
    private fun apc(rate: Int, stereo: Boolean, left: Int, vararg codes: Int): ByteArray {
        val h = ByteArray(32)
        "CRYO_APC1.20".toByteArray().copyInto(h)
        fun put(p: Int, v: Int) { for (i in 0..3) h[p + i] = (v shr (8 * i)).toByte() }
        put(16, rate); put(20, left); put(28, if (stereo) 1 else 0)
        return h + ByteArray(codes.size) { codes[it].toByte() }
    }

    @Test fun `APC mono decodes both nibbles with one IMA state and truncates instead of clipping`() {
        // Step 7: code 0x0 adds 7/8 = 0, code 0x7 adds 15*7/8 = 13 and raises the step index by 8.
        val s = CryoApc.decode(apc(22050, false, 100, 0x07, 0x00))!!
        assertEquals(22050, s.sampleRate); assertEquals(1, s.channels)
        val pcm = (0 until 4).map { (s.samples[it * 2].toInt() and 255) or (s.samples[it * 2 + 1].toInt() shl 8) }
        assertEquals(listOf(100, 113, 115, 116), pcm) // step grows to 16 after the 0x7 code
        // 0x7FFF + delta wraps like Cryo's decoder rather than clamping.
        val wrap = CryoApc.decode(apc(11025, false, 32767, 0x70))!!
        assertEquals(-32756, (wrap.samples[0].toInt() and 255) or (wrap.samples[1].toInt() shl 8))
    }

    @Test fun `APC stereo sends the high nibble left and the low nibble right`() {
        val s = CryoApc.decode(apc(44100, true, 0, 0x70, 0x00))!!
        assertEquals(2, s.channels)
        fun at(i: Int) = (s.samples[i * 2].toInt() and 255) or (s.samples[i * 2 + 1].toInt() shl 8)
        assertEquals(listOf(13, 0, 15, 0), (0 until 4).map { at(it) })
        assertNull(CryoApc.decode(ByteArray(40)))
    }

    @Test fun `HNM6 decoder rejects data that is not a warp image`() {
        assertNull(CryoHnm6.decode(ByteArray(10)))
        assertNull(CryoHnm6.decode("HNM6".toByteArray() + ByteArray(200)))
    }

    private fun solid(c: Color) = BufferedImage(8, 8, BufferedImage.TYPE_INT_RGB).also {
        val g = it.createGraphics(); g.color = c; g.fillRect(0, 0, 8, 8); g.dispose()
    }

    @Test fun `cube panorama places the faces where their edges meet`() {
        val faces = listOf(Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.CYAN, Color.MAGENTA).map { solid(it) }
        val pano = CryoJp6.panorama(faces, 512, 256)
        fun at(x: Int, y: Int) = Color(pano.getRGB(x, y))
        assertEquals(Color.RED, at(256, 128))      // centre looks along wall 0
        assertEquals(Color.MAGENTA, at(384, 128))  // a quarter turn right: wall 5
        assertEquals(Color.GREEN, at(2, 128))      // behind: wall 1
        assertEquals(Color.CYAN, at(128, 128))     // a quarter turn left: wall 4
        assertEquals(Color.BLUE, at(256, 2))       // straight up: sky
        assertEquals(Color.YELLOW, at(256, 253))   // straight down: floor
        val net = CryoJp6.net(faces)
        assertEquals(32, net.width); assertEquals(24, net.height)
        assertEquals(Color.RED, Color(net.getRGB(12, 12)))
        assertEquals(Color.BLUE, Color(net.getRGB(12, 4)))
    }

    private fun leaves(nodes: List<ResourceNode>): List<ResourceNode> =
        nodes.flatMap { if (it.isCategory) leaves(it.children) else listOf(it) }

    @Test fun `Atlantis BigFile lists and decodes panoramas, audio and Targa images`() {
        val path = System.getenv("ATLANTIS_TEST_PATH")
        assumeTrue("Set ATLANTIS_TEST_PATH to the Atlantis: The Lost Tales CD 1 folder", path != null)
        val manager = ScriptManager()
        try {
            val game = manager.detectGame(path!!)!!
            assertEquals("atlantis_tlt", game.engineId)
            val all = leaves(game.resources)
            val panoramas = all.filter { it.id.startsWith("pan:") }
            assertEquals(377, panoramas.size)
            // Every panorama must decode to a full 2048x768 picture with real content.
            for (node in panoramas) {
                val image = manager.loadResource(path, node.id)!!.image ?: error("${node.name} did not decode")
                assertEquals(2048, image.width); assertEquals(768, image.height)
                val distinct = (0 until 64).map { image.getRGB(it * 31, (it * 13) % 768) }.toSet().size
                assertTrue("${node.name} looks flat", distinct > 8)
                manager.releaseDecodedResources()
            }
            val sounds = all.filter { it.type == "sound" }
            assertTrue(sounds.size > 1000)
            for (node in sounds.take(80)) {
                val s = manager.loadResource(path, node.id)!!.soundData ?: error("${node.name} did not decode")
                assertTrue(s.durationMs > 0)
                manager.releaseDecodedResources()
            }
            val tga = all.first { it.id.startsWith("tga:") }
            val image = manager.loadResource(path, tga.id)!!.image!!
            assertEquals(640, image.width); assertEquals(480, image.height)
        } finally { manager.close() }
    }

    @Test fun `Aztec lists and decodes cube panoramas, audio and pictures`() {
        val path = System.getenv("AZTEC_TEST_PATH")
        assumeTrue("Set AZTEC_TEST_PATH to the Aztec CD folder", path != null)
        val manager = ScriptManager()
        try {
            val game = manager.detectGame(path!!)!!
            assertEquals("aztec", game.engineId)
            val all = leaves(game.resources)
            assertEquals(198, all.count { it.id.startsWith("pan:") })
            assertEquals(198, all.count { it.id.startsWith("net:") })
            val pano = manager.loadResource(path, all.first { it.id.startsWith("pan:") }.id)!!.image!!
            assertEquals(2048, pano.width); assertEquals(1024, pano.height)
            val net = manager.loadResource(path, all.first { it.id.startsWith("net:") }.id)!!.image!!
            assertEquals(2048, net.width); assertEquals(1536, net.height)
            manager.releaseDecodedResources()
            val sounds = all.filter { it.type == "sound" }
            assertTrue(sounds.size > 700)
            for (node in sounds.filter { it.id.startsWith("snd:music") }.take(3) + sounds.take(20)) {
                val s = manager.loadResource(path, node.id)!!.soundData ?: error("${node.id} did not decode")
                assertTrue(s.durationMs > 0)
                manager.releaseDecodedResources()
            }
            val pic = all.first { it.id.startsWith("img:doczone") }
            assertNotNull(manager.loadResource(path, pic.id)!!.image)
        } finally { manager.close() }
    }
}

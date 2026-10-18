package adventureexplorer.scripting

import org.junit.Assert.*
import org.junit.Test
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaValue
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ToonstruckDecoderTest {
    private fun bytes(vararg values: Int) = LuaString.valueOf(values.map { it.toByte() }.toByteArray())
    private fun withDecoder(block: (LuaEngine, LuaValue) -> Unit) {
        val lua = LuaEngine()
        try { block(lua, lua.loadScript(File("scripts/engines/toonstruck/engine.lua").absolutePath).get("_debug")) }
        finally { lua.cleanup() }
    }
    @Test fun `SPCN skips marker and copies overlapping matches at exact distance`() = withDecoder { _, d ->
        // Marker, literal ABC, distance-three short match, then distance-one long match.
        val px = d.get("spcn").call(bytes(0, 0x83, 65,66,67, 0,3, 0xC0,1,0), LuaValue.valueOf(9))
        assertEquals("ABCABCCCC", (1..9).map { px.get(it).toint().toChar() }.joinToString(""))
    }
    @Test fun `SPCN handles markerless literals extended matches and fills`() = withDecoder { _, d ->
        val px = d.get("spcn").call(bytes(0x81,7, 0xFF,4,0,1,0, 0xFE,3,0,9), LuaValue.valueOf(8))
        assertEquals(listOf(7,7,7,7,7,9,9,9), (1..8).map { px.get(it).toint() })
    }
    @Test fun `LZSS final oversized token copies remaining raw bytes`() = withDecoder { _, d ->
        val px = d.get("lzss").call(bytes(2,65,0,0,66,67), LuaValue.valueOf(3))
        assertEquals(listOf(65,66,67), (1..3).map { px.get(it).toint() })
        val overlap = d.get("lzss").call(bytes(2,65,255,15), LuaValue.valueOf(4))
        assertEquals(listOf(65,65,65,65), (1..4).map { overlap.get(it).toint() })
    }
    @Test fun `truncated and invalid compression returns no fabricated image`() = withDecoder { _, d ->
        assertTrue(d.get("spcn").call(bytes(0xC0,1,0), LuaValue.valueOf(3)).isnil())
        assertTrue(d.get("spcn").call(bytes(0x83,1), LuaValue.valueOf(3)).isnil())
        assertTrue(d.get("lzss").call(bytes(0), LuaValue.valueOf(8)).isnil())
        assertTrue(d.get("rnc").call(bytes(82,78,67,2)).isnil())
    }
    @Test fun `ADPCM predictor persists between packets and consumes low nibble first`() = withDecoder { lua, d ->
        val raw = bytes(34,86,0,0,0,0,0,0, 1,0,4,0,0,0,0,0, 0x17, 1,0,4,0,0,0,0,0, 0x00)
        val result = d.get("audio").call(raw, LuaValue.valueOf("test"))
        val sound = lua.getSound(result.get("sound").toint())!!
        assertEquals(22100, sound.sampleRate)
        assertArrayEquals(byteArrayOf(11,0,17,0,18,0,19,0), sound.samples)
    }
    @Test fun `CAF references retain their own offsets on a transparent fixed canvas`() = withDecoder { lua, d ->
        val raw = ByteBuffer.allocate(68 + 6 + 65).order(ByteOrder.LITTLE_ENDIAN)
        raw.put("KevinAguilar".toByteArray())
        raw.putInt(16, 32); raw.putInt(20, 65); raw.putInt(24, 80); raw.putInt(28, 2)
        raw.putInt(56, 2); raw.putInt(60, 10); raw.putInt(64, 6)
        raw.position(68); raw.put(byteArrayOf(0,0,0, 12,34,56))
        fun frame(ref: Int, x: Int, size: Int) {
            raw.putInt(0x12345678); raw.putInt(ref); raw.putInt(size); raw.putInt(size)
            raw.putInt(x); raw.putInt(-1); raw.putInt(x+1); raw.putInt(0)
        }
        frame(-1, -2, 1); raw.put(1); frame(0, 0, 0)
        val result = d.get("caf").call(LuaString.valueOf(raw.array()), LuaValue.valueOf("offsets"))
        val frames = lua.getAnimation(result.get("animation").toint())!!.first
        assertEquals(2, frames.size)
        assertEquals(3, frames[0].width)
        assertEquals(0xFF0C2238.toInt(), frames[0].getRGB(0,0))
        assertEquals(0, frames[0].getRGB(2,0))
        assertEquals(0, frames[1].getRGB(0,0))
        assertEquals(0xFF0C2238.toInt(), frames[1].getRGB(2,0))
    }
    @Test fun `SPCN picture palettes use VGA scaling and partial palettes start at one`() = withDecoder { _, d ->
        val raw = ByteBuffer.allocate(16 + 3 + 16).order(ByteOrder.LITTLE_ENDIAN)
        raw.put("SPCN".toByteArray()); raw.putInt(10, 256000); raw.putShort(14, 3)
        raw.position(16); raw.put(byteArrayOf(63,32,1))
        repeat(4) { raw.put(254.toByte()); raw.putShort(64000.toShort()); raw.put(1) }
        val pic = d.get("picture").call(LuaString.valueOf(raw.array()))
        assertEquals(640, pic.get("width").toint())
        assertEquals(400, pic.get("height").toint())
        assertEquals(252, pic.get("palette").get(4).toint())
        assertEquals(128, pic.get("palette").get(5).toint())
        assertEquals(4, pic.get("palette").get(6).toint())
    }
    @Test fun `SPCN final mask run is clipped to the screen`() = withDecoder { _, d ->
        val px = d.get("spcn").call(bytes(0xFE,100,0,7), LuaValue.valueOf(7))
        assertEquals(7, px.length())
        assertEquals(7, px.get(7).toint())
    }

    @Test fun `Western dialogue preserves accented characters and punctuation`() = withDecoder { _, d ->
        assertEquals("¿é“", d.get("text").call(bytes(0xBF,0xE9,0x93)).tojstring())
    }

    @Test fun `double rooms apply their CUP palette to the closeup half`() {
        val folder = java.nio.file.Files.createTempDirectory("toon-room").toFile()
        val lua = LuaEngine()
        try {
            writeToonstruckPaletteGame(folder)
            val script = lua.loadScript(File("scripts/engines/toonstruck/engine.lua").absolutePath)
            val path = LuaValue.valueOf(folder.absolutePath)
            script.get("get_resources").call(path)
            fun load(id: String) = script.get("load_resource").call(path,LuaValue.valueOf(id)).let {
                lua.getImage(it.get("image").toint())!!
            }
            val paletteInfo = script.get("load_resource").call(path,LuaValue.valueOf("pak:LOCAL.PAK:TEST.CUP"))
            assertTrue(paletteInfo.get("description").tojstring().contains("128 stored colors at indices 1–128"))
            val combined = load("pak:LOCAL.PAK:TEST.CPS")
            assertEquals(0xFC0000,combined.getRGB(0,0) and 0xFFFFFF)
            assertEquals(0x00FC00,combined.getRGB(640,0) and 0xFFFFFF)
            val closeup = load("view:LOCAL.PAK:TEST.CPS:closeup")
            assertEquals(640,closeup.width)
            assertEquals(combined.getRGB(640,0),closeup.getRGB(0,0))
        } finally { lua.cleanup(); folder.deleteRecursively() }
    }

    @Test fun `empty CAF placeholders return an explanation`() = withDecoder { _, d ->
        val raw = ByteBuffer.allocate(100).order(ByteOrder.LITTLE_ENDIAN)
        raw.put("KevinAguilar".toByteArray())
        raw.putInt(16,32); raw.putInt(20,32); raw.putInt(24,32); raw.putInt(28,1)
        raw.putInt(68,0x12345678); raw.putInt(72,-1)
        val result = d.get("caf").call(LuaString.valueOf(raw.array()),LuaValue.valueOf("empty"))
        assertEquals("text",result.get("type").tojstring())
        assertTrue(result.get("text").tojstring().contains("no pixel data"))
    }

}

internal fun writeToonstruckPaletteGame(folder: File) {
    val picture = ByteBuffer.allocate(16+3+32).order(ByteOrder.LITTLE_ENDIAN)
    picture.put("SPCN".toByteArray()); picture.putInt(10,512000); picture.putShort(14,3)
    picture.position(16); picture.put(byteArrayOf(63,0,0))
    repeat(8) { picture.put(254.toByte()); picture.putShort(64000.toShort()); picture.put(1) }
    val cup = ByteArray(384).also { it[1] = 63 }
    val directorySize = 31
    val pak = ByteBuffer.allocate(directorySize+picture.capacity()+cup.size).order(ByteOrder.LITTLE_ENDIAN)
    pak.putInt(directorySize); pak.put("TEST.CPS\u0000".toByteArray())
    pak.putInt(directorySize+picture.capacity()); pak.put("TEST.CUP\u0000".toByteArray())
    pak.putInt(pak.capacity()); pak.put(0)
    pak.put(picture.array()); pak.put(cup)
    File(folder,"LOCAL.PAK").writeBytes(pak.array())
    File(folder,"ONETIME.PAK").writeBytes(byteArrayOf())
}

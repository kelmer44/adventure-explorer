package adventureexplorer.scripting

import org.junit.Assert.*
import org.junit.Test
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaValue
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class GobDecoderTest {
    private fun withDebug(block: (LuaValue) -> Unit) {
        val lua = LuaEngine()
        try { block(lua.loadScript(File("scripts/engines/gob/engine.lua").absolutePath).get("_debug")) }
        finally { lua.cleanup() }
    }
    @Test fun `truncated STK and EXT directories are rejected`() = withDebug { debug ->
        assertTrue(debug.get("parse_stk").call(LuaString.valueOf(byteArrayOf(2, 0, 1))).isnil())
        assertTrue(debug.get("parse_ext_table").call(LuaString.valueOf(byteArrayOf(2, 0, 0))).isnil())
    }
    @Test fun `Woodruff sprite length is 32 bit and large LZ output avoids vararg limits`() = withDebug { debug ->
        val n = 70000
        val b = ByteBuffer.allocate(7 + n + (n + 7) / 8).order(ByteOrder.LITTLE_ENDIAN)
        b.put(byteArrayOf(1, 2, 1)); b.putInt(n)
        repeat(n / 8) { b.put(255.toByte()); repeat(8) { b.put(42) } }
        val pixels = debug.get("decode_sprite").invoke(LuaValue.varargsOf(arrayOf(
            LuaString.valueOf(b.array()), LuaValue.valueOf(350), LuaValue.valueOf(200), LuaValue.FALSE, LuaValue.TRUE))).arg1()
        assertEquals(n, pixels.length())
        assertEquals(42, pixels.get(n).toint())
    }
    @Test fun `partial palette loads read resource after color range`() = withDebug { debug ->
        val tot = ByteArray(140)
        byteArrayOf(243.toByte(), 189.toByte(), 16, 255.toByte(), 1, 0).copyInto(tot, 128)
        val parsed = org.luaj.vm2.LuaTable().apply { set("script_end", 140) }
        val ids = debug.get("scan_palette_refs").invoke(LuaValue.varargsOf(arrayOf(LuaString.valueOf(tot), parsed))).arg1()
        assertEquals(1, ids.get(1).toint())
    }
    @Test fun `SND permits the eight trailing bytes present in Woodruff`() = withDebug { debug ->
        val snd = byteArrayOf(0, 0, 0, 2, 0x56, 0x22, 1, 2) + ByteArray(8)
        val info = debug.get("parse_snd").call(LuaString.valueOf(snd))
        assertEquals(2, info.get("sample_count").toint())
        assertEquals(22050, info.get("sample_rate").toint())
    }
    @Test fun `one byte RLE sprite in Goblins 3 menu is valid`() = withDebug { debug ->
        val pixels = debug.get("decode_sprite").invoke(LuaValue.varargsOf(arrayOf(
            LuaString.valueOf(byteArrayOf(8)), LuaValue.ONE, LuaValue.ONE, LuaValue.FALSE, LuaValue.TRUE))).arg1()
        assertEquals(1, pixels.length())
        assertEquals(0, pixels.get(1).toint())
    }

}

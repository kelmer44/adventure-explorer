package adventureexplorer.scripting

import org.junit.Assert.*
import org.junit.Test
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaTable
import org.luaj.vm2.LuaValue
import java.io.File
import java.nio.ByteBuffer

class AgosDecoderTest {
    private fun debug(lua: LuaEngine) = lua.loadScript(File("scripts/engines/agos/engine.lua").absolutePath).get("_debug")
    private fun bytes(vararg values: Int) = LuaString.valueOf(values.map { it.toByte() }.toByteArray())
    private fun entry(w: Int, h: Int, kind: String) = LuaTable().apply {
        set("width", w); set("height", h); set("offset", 0); set("kind", kind)
    }

    @Test fun `scroll column runs use per-entry offsets and repeat one source byte`() {
        val lua = LuaEngine()
        try {
            // 41 independent groups, 8 columns x 2 rows. Each run repeats its group id.
            val data = ByteBuffer.allocate(41 * 6)
            repeat(41) { data.putInt(41 * 4 + it * 2 - it * 4) }
            repeat(41) { data.put(15); data.put((it + 1).toByte()) }
            val px = debug(lua).get("decode_image").invoke(LuaValue.varargsOf(arrayOf(
                LuaString.valueOf(data.array()), entry(328, 2, "coltable"), LuaValue.ZERO))).arg1()
            repeat(2) { y -> repeat(328) { x -> assertEquals(x / 8 + 1, px.get(y * 328 + x + 1).toint()) } }
        } finally { lua.cleanup() }
    }

    @Test fun `negative variable frame does not consume following instruction or overwrite palette ops`() {
        val lua = LuaEngine()
        try {
            val data = bytes(22, 0,3,0,1, 24,255,255,0,0,0,0,0, 12,4, 24,0,7,0,0,0,0,1, 0)
            val ops = debug(lua).get("anim_ops").invoke(LuaValue.varargsOf(arrayOf(data, LuaValue.ZERO, LuaValue.valueOf(2)))).arg1()
            assertEquals("pal", ops.get(1).get("op").tojstring())
            assertEquals(7, ops.get(2).get("image").toint())
            assertEquals(4, ops.get(2).get("delay").toint())
            assertEquals(1, ops.get("frames").toint())
        } finally { lua.cleanup() }
    }

    @Test fun `draw palette is low byte and pathfinder starts after a whole word`() {
        val lua = LuaEngine()
        try {
            val data = bytes(17,0,1, 0,4,0,5, 3,231, 10,0,7,0,6,0,0,0,0,2, 0)
            val ops = debug(lua).get("room_ops").invoke(LuaValue.varargsOf(arrayOf(data, LuaValue.ZERO, LuaValue.valueOf(2)))).arg1()
            assertEquals(1, ops.length())
            assertEquals(6, ops.get(1).get("bank").toint())
            assertEquals(7, ops.get(1).get("image").toint())
        } finally { lua.cleanup() }
    }

    @Test fun `compressed flag controls sprite encoding even when size matches raw pixels`() {
        val lua = LuaEngine()
        try {
            val data = ByteBuffer.allocate(24)
            data.position(8); data.putInt(16); data.put(128.toByte()); data.put(1); data.putShort(16)
            val table = debug(lua).get("img_table").call(LuaString.valueOf(data.array()))
            assertEquals("rle", table.get(1).get("kind").tojstring())
        } finally { lua.cleanup() }
    }
}

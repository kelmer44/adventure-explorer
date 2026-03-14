package adventureexplorer.scripting

import org.luaj.vm2.*
import org.luaj.vm2.lib.*
import org.luaj.vm2.lib.jse.JsePlatform
import java.awt.image.BufferedImage
import java.io.File
import java.io.RandomAccessFile

/**
 * Wraps the LuaJ runtime and exposes the Adventure Explorer API to Lua scripts.
 *
 * API exposed to Lua:
 *   file_exists(path) -> boolean
 *   file_open(path) -> handle
 *   file_close(handle)
 *   file_size(handle) -> number
 *   file_read(handle, offset, length) -> string (binary)
 *   list_files(path) -> table of filenames
 *   image_create_indexed(w, h, pixel_table, palette_table) -> image_handle
 *   image_create_rgb(w, h, rgb_table) -> image_handle
 *   log_info(msg), log_warn(msg), log_error(msg)
 */
class LuaEngine {

    private val globals: Globals = JsePlatform.standardGlobals()
    private val openFiles = mutableMapOf<Int, RandomAccessFile>()
    private var nextFileHandle = 1
    private val images = mutableMapOf<Int, BufferedImage>()
    private var nextImageHandle = 1

    init {
        registerFileApi()
        registerImageApi()
        registerLogApi()
    }

    // ── File I/O API ────────────────────────────────────────────────

    private fun registerFileApi() {
        globals["file_exists"] = object : OneArgFunction() {
            override fun call(path: LuaValue): LuaValue {
                val f = findFileInsensitive(path.checkjstring())
                return valueOf(f != null)
            }
        }

        globals["file_open"] = object : OneArgFunction() {
            override fun call(path: LuaValue): LuaValue {
                val f = findFileInsensitive(path.checkjstring())
                    ?: throw LuaError("File not found: ${path.checkjstring()}")
                val raf = RandomAccessFile(f, "r")
                val handle = nextFileHandle++
                openFiles[handle] = raf
                return valueOf(handle)
            }
        }

        globals["file_close"] = object : OneArgFunction() {
            override fun call(handle: LuaValue): LuaValue {
                openFiles.remove(handle.checkint())?.close()
                return NIL
            }
        }

        globals["file_size"] = object : OneArgFunction() {
            override fun call(handle: LuaValue): LuaValue {
                val raf = openFiles[handle.checkint()] ?: return NIL
                return valueOf(raf.length().toDouble())
            }
        }

        // file_read(handle, offset, length) -> binary Lua string
        globals["file_read"] = object : ThreeArgFunction() {
            override fun call(handle: LuaValue, offset: LuaValue, length: LuaValue): LuaValue {
                val raf = openFiles[handle.checkint()] ?: return NIL
                val off = offset.checklong()
                val len = length.checkint()
                val buf = ByteArray(len)
                raf.seek(off)
                val n = raf.read(buf)
                return if (n > 0) LuaString.valueOf(buf, 0, n) else NIL
            }
        }

        // list_files(path) -> table of filenames
        globals["list_files"] = object : OneArgFunction() {
            override fun call(path: LuaValue): LuaValue {
                val dir = File(path.checkjstring())
                if (!dir.isDirectory) return LuaValue.tableOf()
                val table = LuaValue.tableOf()
                dir.listFiles()?.sorted()?.forEachIndexed { idx, file ->
                    table[idx + 1] = valueOf(file.name)
                }
                return table
            }
        }
    }

    // ── Image API ───────────────────────────────────────────────────

    private fun registerImageApi() {
        // image_create_indexed(width, height, pixel_table, palette_table) -> handle
        // pixel_table: 1-indexed, values 0-255 (color indices)
        // palette_table: 1-indexed, 768 entries (R,G,B triplets, values 0-255)
        globals["image_create_indexed"] = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val width = args.checkint(1)
                val height = args.checkint(2)
                val pixelTable = args.checktable(3)
                val paletteTable = args.checktable(4)

                val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)

                // Build palette lookup: index -> 0xRRGGBB
                val palette = IntArray(256)
                for (i in 0 until 256) {
                    val r = paletteTable.rawget(i * 3 + 1).optint(0).coerceIn(0, 255)
                    val g = paletteTable.rawget(i * 3 + 2).optint(0).coerceIn(0, 255)
                    val b = paletteTable.rawget(i * 3 + 3).optint(0).coerceIn(0, 255)
                    palette[i] = (r shl 16) or (g shl 8) or b
                }

                // Set pixels from indexed data
                val totalPixels = width * height
                val rgbArray = IntArray(totalPixels)
                for (i in 0 until totalPixels) {
                    val colorIdx = pixelTable.rawget(i + 1).optint(0).coerceIn(0, 255)
                    rgbArray[i] = palette[colorIdx]
                }
                image.setRGB(0, 0, width, height, rgbArray, 0, width)

                val handle = nextImageHandle++
                images[handle] = image
                return valueOf(handle)
            }
        }

        // image_create_rgb(width, height, rgb_table) -> handle
        // rgb_table: 1-indexed, w*h*3 entries (R,G,B values 0-255)
        globals["image_create_rgb"] = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val width = args.checkint(1)
                val height = args.checkint(2)
                val rgbTable = args.checktable(3)

                val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
                val totalPixels = width * height
                val rgbArray = IntArray(totalPixels)
                for (i in 0 until totalPixels) {
                    val r = rgbTable.rawget(i * 3 + 1).optint(0).coerceIn(0, 255)
                    val g = rgbTable.rawget(i * 3 + 2).optint(0).coerceIn(0, 255)
                    val b = rgbTable.rawget(i * 3 + 3).optint(0).coerceIn(0, 255)
                    rgbArray[i] = (r shl 16) or (g shl 8) or b
                }
                image.setRGB(0, 0, width, height, rgbArray, 0, width)

                val handle = nextImageHandle++
                images[handle] = image
                return valueOf(handle)
            }
        }
    }

    // ── Log API ─────────────────────────────────────────────────────

    private fun registerLogApi() {
        globals["log_info"] = object : OneArgFunction() {
            override fun call(msg: LuaValue): LuaValue {
                println("[LUA] ${msg.tojstring()}")
                return NIL
            }
        }
        globals["log_warn"] = object : OneArgFunction() {
            override fun call(msg: LuaValue): LuaValue {
                println("[LUA WARN] ${msg.tojstring()}")
                return NIL
            }
        }
        globals["log_error"] = object : OneArgFunction() {
            override fun call(msg: LuaValue): LuaValue {
                System.err.println("[LUA ERROR] ${msg.tojstring()}")
                return NIL
            }
        }
    }

    // ── Public interface ────────────────────────────────────────────

    fun loadScript(scriptPath: String): LuaValue {
        val chunk = globals.loadfile(scriptPath)
        return chunk.call()
    }

    fun getImage(handle: Int): BufferedImage? = images[handle]

    fun cleanup() {
        openFiles.values.forEach { runCatching { it.close() } }
        openFiles.clear()
        nextFileHandle = 1
        images.clear()
        nextImageHandle = 1
    }

    // ── Helpers ─────────────────────────────────────────────────────

    companion object {
        /**
         * Find a file using case-insensitive matching (for DOS game files).
         */
        fun findFileInsensitive(path: String): File? {
            val file = File(path)
            if (file.exists()) return file

            val parent = file.parentFile ?: return null
            if (!parent.exists()) return null

            val targetName = file.name.lowercase()
            return parent.listFiles()?.firstOrNull { it.name.lowercase() == targetName }
        }
    }
}

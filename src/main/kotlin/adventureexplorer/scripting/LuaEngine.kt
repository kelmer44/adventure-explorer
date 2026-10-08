package adventureexplorer.scripting

import adventureexplorer.model.SoundData
import adventureexplorer.model.MidiData
import adventureexplorer.audio.GobAdlDecoder
import adventureexplorer.audio.CmfToMidiConverter
import adventureexplorer.audio.XmiToMidiConverter
import adventureexplorer.audio.ImuseBundleCodecs
import org.luaj.vm2.*
import org.luaj.vm2.lib.*
import org.luaj.vm2.lib.jse.JsePlatform
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import java.io.File
import java.io.RandomAccessFile
import java.util.zip.DataFormatException
import java.util.zip.Inflater
import javax.imageio.ImageIO

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
 *   sound_create_pcm(sample_rate, bits, channels, signed, data) -> sound_handle
 *   sound_create_gob_adl(data) -> sound_handle
 *   midi_create_raw(data) -> midi_handle          (data is already a standard MIDI file)
 *   midi_create_from_cmf(data) -> midi_handle     (Creative Music Format)
 *   midi_create_from_xmi(data) -> midi_handle     (XMIDI, IFF-wrapped or bare EVNT)
 *   midi_create_auto(data) -> midi_handle          (sniffs the magic bytes to pick a decoder)
 *   imuse_bundle_sound(path, offset, size [, channels]) -> pcm, rate, bits, channels  (SCUMM .BUN sound)
 *   imuse_stream_sound(data) -> pcm, rate, bits, channels   (resident SCUMM `iMUS` stream)
 *   log_info(msg), log_warn(msg), log_error(msg)
 */
class LuaEngine {

    private val globals: Globals = JsePlatform.standardGlobals()
    private val openFiles = mutableMapOf<Int, RandomAccessFile>()
    private var nextFileHandle = 1
    private val images = mutableMapOf<Int, BufferedImage>()
    private var nextImageHandle = 1
    private val animations = mutableMapOf<Int, Pair<List<BufferedImage>, Int>>() // handle -> (frames, delayMs)
    private var nextAnimHandle = 1
    private val sounds = mutableMapOf<Int, SoundData>() // handle -> sound data
    private var nextSoundHandle = 1
    private val midis = mutableMapOf<Int, MidiData>() // handle -> standard MIDI file bytes
    private var nextMidiHandle = 1

    init {
        registerFileApi()
        registerImageApi()
        registerSoundApi()
        registerMidiApi()
        registerBinaryApi()
        registerImuseApi()
        registerImuseStream()
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
                val f = findFileInsensitive(path.checkjstring()) ?: return NIL
                return try {
                    val raf = RandomAccessFile(f, "r")
                    val handle = nextFileHandle++
                    openFiles[handle] = raf
                    valueOf(handle)
                } catch (e: Exception) {
                    NIL
                }
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

        // animation_create(image_handles_table [, delay_ms]) -> animation_handle
        // image_handles_table: 1-indexed table of image handles (from image_create_*)
        // delay_ms: optional milliseconds per frame (default 100)
        globals["animation_create"] = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val handlesTable = args.checktable(1)
                val delayMs = args.optint(2, 100)
                val frames = mutableListOf<BufferedImage>()
                var i = 1
                while (true) {
                    val v = handlesTable.rawget(i)
                    if (v.isnil()) break
                    val imgHandle = v.checkint()
                    val img = images[imgHandle] ?: return NIL
                    frames.add(img)
                    i++
                }
                if (frames.isEmpty()) return NIL
                val handle = nextAnimHandle++
                animations[handle] = Pair(frames.toList(), delayMs)
                return valueOf(handle)
            }
        }
    }

    // ── Sound API ───────────────────────────────────────────────────

    private fun registerSoundApi() {
        // sound_create_pcm(sample_rate, bits_per_sample, channels, signed, pcm_data) -> sound_handle
        // pcm_data: binary string of raw PCM samples
        globals["sound_create_pcm"] = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val sampleRate = args.checkint(1)
                val bitsPerSample = args.checkint(2)
                val channels = args.checkint(3)
                val signed = args.checkboolean(4)
                val luaStr = args.checkstring(5)
                val samples = ByteArray(luaStr.length())
                luaStr.copyInto(0, samples, 0, samples.size)
                if (samples.isEmpty()) return NIL
                val handle = nextSoundHandle++
                sounds[handle] = SoundData(samples, sampleRate, bitsPerSample, channels, signed)
                return valueOf(handle)
            }
        }

        // sound_create_gob_adl(data) -> sound_handle
        // Renders Coktel Vision ADL/OPL event data to signed 16-bit PCM.
        globals["sound_create_gob_adl"] = object : OneArgFunction() {
            override fun call(data: LuaValue): LuaValue {
                val bytes = try {
                    val luaStr = data.checkstring()
                    ByteArray(luaStr.length()).also { luaStr.copyInto(0, it, 0, it.size) }
                } catch (_: Exception) {
                    return NIL
                }
                val sound = GobAdlDecoder.decode(bytes) ?: return NIL
                val handle = nextSoundHandle++
                sounds[handle] = sound
                return valueOf(handle)
            }
        }

    }

    // ── MIDI API ────────────────────────────────────────────────────

    private fun registerMidiApi() {
        fun toBytes(data: LuaValue): ByteArray? = try {
            val luaStr = data.checkstring()
            ByteArray(luaStr.length()).also { luaStr.copyInto(0, it, 0, it.size) }
        } catch (_: Exception) { null }

        fun store(bytes: ByteArray?): LuaValue {
            if (bytes == null) return LuaValue.NIL
            val handle = nextMidiHandle++
            midis[handle] = MidiData(bytes)
            return LuaValue.valueOf(handle)
        }

        // midi_create_raw(data) -> midi_handle
        // Wraps data that is already a standard MIDI file (MThd/MTrk).
        globals["midi_create_raw"] = object : OneArgFunction() {
            override fun call(data: LuaValue): LuaValue {
                val bytes = toBytes(data) ?: return NIL
                if (bytes.size < 4 || String(bytes, 0, 4, Charsets.US_ASCII) != "MThd") return NIL
                return store(bytes)
            }
        }

        // midi_create_from_cmf(data) -> midi_handle
        // Converts Creative Music Format (CTMF) song data to a standard MIDI file.
        globals["midi_create_from_cmf"] = object : OneArgFunction() {
            override fun call(data: LuaValue): LuaValue {
                val bytes = toBytes(data) ?: return NIL
                return store(CmfToMidiConverter.convert(bytes))
            }
        }

        // midi_create_from_xmi(data) -> midi_handle
        // Converts an XMIDI (.xmi) resource to a standard MIDI file.
        globals["midi_create_from_xmi"] = object : OneArgFunction() {
            override fun call(data: LuaValue): LuaValue {
                val bytes = toBytes(data) ?: return NIL
                return store(XmiToMidiConverter.convert(bytes))
            }
        }

        // midi_create_auto(data) -> midi_handle
        // Sniffs the magic bytes (MThd / CTMF / FORM) to pick the right decoder.
        globals["midi_create_auto"] = object : OneArgFunction() {
            override fun call(data: LuaValue): LuaValue {
                val bytes = toBytes(data) ?: return NIL
                if (bytes.size < 4) return NIL
                val magic = String(bytes, 0, 4, Charsets.US_ASCII)
                val converted = when (magic) {
                    "MThd" -> bytes
                    "CTMF" -> CmfToMidiConverter.convert(bytes)
                    "FORM" -> XmiToMidiConverter.convert(bytes)
                    else -> XmiToMidiConverter.convert(bytes)
                }
                return store(converted)
            }
        }
    }

    // ── Binary utilities API ─────────────────────────────────────────

    private fun registerBinaryApi() {
        // zlib_decompress(compressed_data, uncompressed_size) -> decompressed binary string or nil
        // Handles both zlib-wrapped (0x78…) and raw deflate streams.
        globals["zlib_decompress"] = object : TwoArgFunction() {
            override fun call(data: LuaValue, expectedSize: LuaValue): LuaValue {
                val bytes = try {
                    val ls = data.checkstring()
                    ByteArray(ls.length()).also { ls.copyInto(0, it, 0, it.size) }
                } catch (e: Exception) { return NIL }
                val outSize = expectedSize.checkint()
                // Try standard zlib (with header) first, then raw deflate.
                for (nowrap in listOf(false, true)) {
                    try {
                        val inf = Inflater(nowrap)
                        inf.setInput(bytes)
                        val out = ByteArray(outSize)
                        val n = inf.inflate(out)
                        inf.end()
                        if (n > 0) return LuaString.valueOf(out, 0, n)
                    } catch (_: DataFormatException) { /* try the other mode */ }
                }
                return NIL
            }
        }

        // image_load_png(data) -> image handle or nil
        // Accepts any format supported by Java ImageIO (PNG, BMP, GIF, JPEG).
        globals["image_load_png"] = object : OneArgFunction() {
            override fun call(data: LuaValue): LuaValue {
                return try {
                    val ls = data.checkstring()
                    val bytes = ByteArray(ls.length()).also { ls.copyInto(0, it, 0, it.size) }
                    val src = ImageIO.read(ByteArrayInputStream(bytes)) ?: return NIL
                    val image = BufferedImage(src.width, src.height, BufferedImage.TYPE_INT_RGB)
                    val g2d = image.createGraphics()
                    g2d.drawImage(src, 0, 0, null)
                    g2d.dispose()
                    val handle = nextImageHandle++
                    images[handle] = image
                    valueOf(handle)
                } catch (e: Exception) { NIL }
            }
        }

        // xor_bytes(data, key) -> XOR-decrypted binary string
        // Each byte of data is XORed with the cycling key bytes.
        globals["xor_bytes"] = object : TwoArgFunction() {
            override fun call(data: LuaValue, key: LuaValue): LuaValue {
                return try {
                    val lsData = data.checkstring()
                    val input = ByteArray(lsData.length()).also { lsData.copyInto(0, it, 0, it.size) }
                    val lsKey = key.checkstring()
                    val keyBytes = ByteArray(lsKey.length()).also { lsKey.copyInto(0, it, 0, it.size) }
                    if (keyBytes.isEmpty()) return data
                    val output = ByteArray(input.size) { i ->
                        (input[i].toInt() and 0xFF xor (keyBytes[i % keyBytes.size].toInt() and 0xFF)).toByte()
                    }
                    LuaString.valueOf(output, 0, output.size)
                } catch (e: Exception) { NIL }
            }
        }
    }

    // ── iMUSE bundle API ─────────────────────────────────────────────

    private fun registerImuseApi() {
        // imuse_bundle_sound(path, offset, size [, default_channels]) -> pcm, rate, bits, channels
        // Decodes one sound stored in a SCUMM V7/V8 .BUN bundle into little-endian PCM
        // (16-bit signed or 8-bit unsigned). Returns nil on failure.
        globals["imuse_bundle_sound"] = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val file = findFileInsensitive(args.checkjstring(1)) ?: return NIL
                val offset = args.checklong(2)
                val size = args.checkint(3)
                val defChannels = args.optint(4, 0)
                return try {
                    decodeBundleSound(file, offset, size, defChannels)
                } catch (e: Exception) {
                    println("[LUA WARN] imuse_bundle_sound failed: ${e.message}")
                    NIL
                }
            }
        }
    }

    private fun be32(b: ByteArray, i: Int): Int =
        ((b[i].toInt() and 0xFF) shl 24) or ((b[i + 1].toInt() and 0xFF) shl 16) or
            ((b[i + 2].toInt() and 0xFF) shl 8) or (b[i + 3].toInt() and 0xFF)

    private fun registerImuseStream() {
        // imuse_stream_sound(data) -> pcm, rate, bits, channels
        // Decodes a resident `iMUS` stream (V7/V8 SOUN resources) into little-endian PCM.
        globals["imuse_stream_sound"] = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                return try {
                    val ls = args.checkstring(1)
                    val bytes = ByteArray(ls.length()).also { ls.copyInto(0, it, 0, it.size) }
                    finishImuse(bytes, 22050, 16, 1, true)
                } catch (e: Exception) { LuaValue.NIL }
            }
        }
    }

    private fun decodeBundleSound(file: File, offset: Long, size: Int, defChannels: Int): Varargs {
        RandomAccessFile(file, "r").use { raf ->
            raf.seek(offset)
            val head = ByteArray(16)
            raf.readFully(head)
            val tag = String(head, 0, 4, Charsets.US_ASCII)
            val pcm = java.io.ByteArrayOutputStream()
            var channels = defChannels
            var swapBE = false
            if (tag == "iMUS") {
                // Uncompressed iMUSE stream
                val body = ByteArray(size)
                raf.seek(offset)
                raf.readFully(body)
                pcm.write(body)
                swapBE = true
            } else if (tag == "COMP") {
                val numItems = be32(head, 4)
                val lastSize = be32(head, 12)
                if (numItems <= 0 || numItems > 1_000_000) return LuaValue.NIL
                val table = ByteArray(numItems * 16)
                raf.readFully(table)
                var firstCodec = -1
                for (i in 0 until numItems) {
                    val bOff = be32(table, i * 16)
                    val bSize = be32(table, i * 16 + 4)
                    val codec = be32(table, i * 16 + 8)
                    if (firstCodec < 0) firstCodec = codec
                    val comp = ByteArray(bSize + 1)
                    raf.seek(offset + bOff)
                    raf.readFully(comp, 0, bSize)
                    val ch = if (codec == 15) 2 else 1
                    var out = ImuseBundleCodecs.decompress(codec, comp.copyOf(bSize + 1), ch) ?: return LuaValue.NIL
                    if (codec == 13 || codec == 15) {
                        if (i == numItems - 1 && lastSize in 1 until out.size) out = out.copyOf(lastSize)
                    } else if (i == numItems - 1 && lastSize in 1 until out.size) {
                        out = out.copyOf(lastSize)
                    }
                    pcm.write(out)
                }
                swapBE = firstCodec in 0..12
                if (channels == 0 && (firstCodec == 13 || firstCodec == 15)) channels = if (firstCodec == 15) 2 else 1
                if (firstCodec == 13 || firstCodec == 15) swapBE = false
            } else {
                return LuaValue.NIL
            }

            return finishImuse(pcm.toByteArray(), 22050, 16, if (channels > 0) channels else 1, swapBE)
        }
    }

    /**
     * Turn a decoded iMUSE stream into plain PCM. If the data starts with an `iMUS` header the
     * FRMT chunk supplies bits/rate/channels (payload: start, ?, bits, rate, channels) and DATA
     * the samples. 12-bit packed samples (3 bytes -> 2 offset-binary values) become 16-bit LE.
     */
    private fun finishImuse(input: ByteArray, defRate: Int, defBits: Int, defCh: Int, bigEndian: Boolean): Varargs {
        var data = input
        var rate = defRate
        var bits = defBits
        var ch = defCh
        if (data.size > 16 && String(data, 0, 4, Charsets.US_ASCII) == "iMUS") {
            var p = 8
            var dataStart = -1
            var dataEnd = data.size
            while (p + 8 <= data.size) {
                val t = String(data, p, 4, Charsets.US_ASCII)
                val sz = be32(data, p + 4)
                if (t == "MAP ") {
                    var q = p + 8
                    val end = minOf(p + 8 + sz, data.size)
                    while (q + 8 <= end) {
                        val ct = String(data, q, 4, Charsets.US_ASCII)
                        val cs = be32(data, q + 4)
                        if (ct == "FRMT" && cs >= 20 && q + 8 + 20 <= data.size) {
                            bits = be32(data, q + 8 + 8)
                            rate = be32(data, q + 8 + 12)
                            ch = be32(data, q + 8 + 16)
                        }
                        if (cs < 0) break
                        q += 8 + cs
                    }
                    p += 8 + sz
                } else if (t == "DATA") {
                    dataStart = p + 8
                    if (sz in 1..(data.size - dataStart)) dataEnd = dataStart + sz
                    break
                } else {
                    if (sz < 0) break
                    p += 8 + sz
                }
            }
            if (dataStart < 0) return LuaValue.NIL
            data = data.copyOfRange(dataStart, dataEnd)
        }
        if (ch < 1) ch = 1
        if (bits == 12) {
            val n = data.size / 3 * 2
            val out = ByteArray(n * 2)
            var si = 0
            var di = 0
            while (si + 2 < data.size + 0 && di + 3 < out.size) {
                val b0 = data[si].toInt() and 0xFF
                val b1 = data[si + 1].toInt() and 0xFF
                val b2 = data[si + 2].toInt() and 0xFF
                val s0 = ((b0 or ((b1 and 0x0F) shl 8)) - 2048) shl 4
                val s1 = ((b2 or ((b1 and 0xF0) shl 4)) - 2048) shl 4
                out[di] = s0.toByte(); out[di + 1] = (s0 shr 8).toByte()
                out[di + 2] = s1.toByte(); out[di + 3] = (s1 shr 8).toByte()
                si += 3; di += 4
            }
            data = out
            bits = 16
        } else if (bits == 16 && bigEndian) {
            var i = 0
            while (i + 1 < data.size) {
                val t = data[i]; data[i] = data[i + 1]; data[i + 1] = t
                i += 2
            }
        }
        return LuaValue.varargsOf(arrayOf(
            LuaString.valueOf(data, 0, data.size),
            LuaValue.valueOf(rate), LuaValue.valueOf(bits), LuaValue.valueOf(ch)
        ))
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
        // Let engine scripts split themselves into sibling modules (require "name").
        val dir = File(scriptPath).absoluteFile.parentFile
        if (dir != null) {
            val pkg = globals.get("package")
            val cur = pkg.get("path").optjstring("")
            val entry = dir.path.replace('\\', '/') + "/?.lua"
            if (!cur.contains(entry)) pkg.set("path", LuaValue.valueOf("$entry;$cur"))
        }
        val chunk = globals.loadfile(scriptPath)
        return chunk.call()
    }

    fun getImage(handle: Int): BufferedImage? = images[handle]

    fun getAnimation(handle: Int): Pair<List<BufferedImage>, Int>? = animations[handle]

    fun getSound(handle: Int): SoundData? = sounds[handle]

    fun getMidi(handle: Int): MidiData? = midis[handle]

    fun cleanup() {
        openFiles.values.forEach { runCatching { it.close() } }
        openFiles.clear()
        nextFileHandle = 1
        images.clear()
        nextImageHandle = 1
        animations.clear()
        nextAnimHandle = 1
        sounds.clear()
        nextSoundHandle = 1
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

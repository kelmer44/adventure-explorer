package adventureexplorer.video

import java.awt.image.BufferedImage
import kotlin.math.abs

/** Indexed Coktel IMD/VMD video, including palette changes and delta rectangles.
 * Format reference: ScummVM video/coktel_decoder.cpp. Clips retain all frames;
 * callers split long movies to keep decoded images within a fixed memory budget.
 */
object CoktelVideoDecoder {
    data class Clip(val frames: List<BufferedImage>, val delayMs: Int)
    private class Reader(val data: ByteArray, var pos: Int = 0) {
        fun u8(): Int { require(pos in data.indices); return data[pos++].toInt() and 255 }
        fun u16() = u8() or (u8() shl 8)
        fun s16() = u16().let { if (it >= 32768) it - 65536 else it }
        fun u32(): Int { val v = u16().toLong() or (u16().toLong() shl 16); require(v <= Int.MAX_VALUE); return v.toInt() }
        fun skip(n: Int) { require(n >= 0 && n <= data.size - pos); pos += n }
        fun bytes(n: Int): ByteArray { require(n >= 0 && n <= data.size - pos); return data.copyOfRange(pos, pos + n).also { pos += n } }
    }
    private fun palette(r: Reader, colors: IntArray, start: Int = 0, count: Int = 256) {
        require(start + count <= 256)
        repeat(count) { colors[start + it] = ((r.u8() shl 2) shl 16) or ((r.u8() shl 2) shl 8) or (r.u8() shl 2) }
    }

    fun decode(data: ByteArray, firstFrame: Int = 0, frameCount: Int = 48): Clip? = runCatching {
        require(firstFrame >= 0 && frameCount in 1..256)
        if (Reader(data).u16() == 814) vmd(data, firstFrame, frameCount) else imd(data, firstFrame, frameCount)
    }.getOrNull()

    /** Archive and sprite LZSS use the same 4K window and optional extended runs. */
    internal fun unpack(data: ByteArray): ByteArray {
        val r = Reader(data)
        val size = r.u32()
        require(size in 1..16 * 1024 * 1024)
        val window = ByteArray(4096) { 32 }
        val extended = data.size >= 8 && r.u16() == 0x1234 && r.u16() == 0x5678
        if (!extended) r.pos = 4
        var wp = if (extended) 273 else 4078
        val out = ByteArray(size)
        var n = 0
        while (n < size) {
            val flags = r.u8()
            for (bit in 0..7) {
                if (n == size) break
                if (flags and (1 shl bit) != 0) {
                    val value = r.u8().toByte()
                    out[n++] = value; window[wp] = value; wp = (wp + 1) and 4095
                } else {
                    val lo = r.u8(); val hi = r.u8()
                    val offset = lo or ((hi and 240) shl 4)
                    var count = (hi and 15) + 3
                    if (extended && count == 18) count = r.u8() + 18
                    repeat(minOf(count, size - n)) { i ->
                        val value = window[(offset + i) and 4095]
                        out[n++] = value; window[wp] = value; wp = (wp + 1) and 4095
                    }
                }
            }
        }
        return out
    }

    private class Canvas(val width: Int, val height: Int) {
        init { require(width in 1..2048 && height in 1..2048 && width * height <= 2 * 1024 * 1024) }
        val pixels = ByteArray(width * height)
        val colors = IntArray(256)
        fun image(): BufferedImage = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB).also { img ->
            img.setRGB(0, 0, width, height, IntArray(pixels.size) { colors[pixels[it].toInt() and 255] }, 0, width)
        }
        fun block(bytes: ByteArray, left: Int, top: Int, w: Int, h: Int, imd: Boolean = false) {
            require(w in 1..4096 && h in 1..4096)
            var r = Reader(bytes)
            var type = r.u8()
            if (imd && type and 16 != 0) {
                val index = r.u8()
                palette(r, colors, index, minOf(16, 256 - index))
                r.pos = 50; type = type xor 16
            }
            if (type and 128 != 0) { type = type and 127; r = Reader(unpack(r.bytes(bytes.size - r.pos))) }
            fun put(x: Int, y: Int, value: Int) {
                if (x in 0 until width && y in 0 until height) pixels[y * width + x] = value.toByte()
            }
            val stepY = if (type != 1 && type != 2 && type != 3 && type != 0x42) 2 else 1
            for (y in 0 until h step stepY) {
                var x = 0
                while (x < w) {
                    if (type == 2 || type == 0x42 || type and 15 == 2) {
                        val value = r.u8()
                        val stepX = if (type == 0x42) 4 else 1
                        repeat(minOf(stepX, w - x)) { dx ->
                            put(left + x + dx, top + y, value)
                            if (stepY == 2 && y + 1 < h) put(left + x + dx, top + y + 1, value)
                        }
                        x += stepX
                    } else {
                        // Sparse deltas leave holes unchanged on the previous frame.
                        require(type != 3) // RLE is not used by the supported indexed releases.
                        val run = r.u8(); val count = minOf((run and 127) + 1, w - x)
                        if (run and 128 != 0) repeat(count) { dx ->
                            val value = r.u8(); put(left + x + dx, top + y, value)
                            if (stepY == 2 && y + 1 < h) put(left + x + dx, top + y + 1, value)
                        }
                        x += if (run and 128 != 0) count else run + 1
                    }
                }
            }
        }
    }
    private fun vmd(data: ByteArray, first: Int, count: Int): Clip {
        val r = Reader(data)
        require(r.u16() == 814)
        val handle = r.u16(); val version = r.u16(); val total = r.u16()
        val ox = r.s16(); val oy = r.s16(); val w = r.s16(); val h = r.s16()
        require(version and 4 == 0 || handle == 0)
        require(version and 2 == 0 || version and 8 != 0) // external codecs are separate formats
        require(first < total)
        val c = Canvas(w, h)
        r.skip(2); val parts = r.u16(); r.skip(8)
        require(parts in 1..1024)
        palette(r, c.colors)
        r.skip(8)
        val rate = r.u16(); val slice = abs(r.s16()); r.skip(4)
        val table = r.u32()
        require(table >= 816 && total.toLong() * (6 + parts * 16L) <= data.size - table)
        val end = minOf(total, first + count)
        require((end - first).toLong() * w * h * 4 <= 64 * 1024 * 1024)
        val frames = ArrayList<BufferedImage>()
        repeat(end) { frame ->
            r.pos = table + frame * 6 + 2
            var offset = r.u32()
            repeat(parts) partLoop@{ part ->
                r.pos = table + total * 6 + (frame * parts + part) * 16
                val type = r.u8()
                if (type == 0) return@partLoop // unused descriptors contain arbitrary bytes
                r.skip(1); val size = r.u32()
                require(offset >= 0 && size <= data.size - offset)
                if (type == 2 && size > 0) {
                    val x = r.u16() - ox; val y = r.u16() - oy
                    val right = r.u16() - ox; val bottom = r.u16() - oy
                    r.skip(1); val flags = r.u8()
                    val body = Reader(data, offset)
                    if (flags and 2 != 0) {
                        val index = body.u8(); val n = body.u8() + 1
                        palette(body, c.colors, index, n)
                        body.pos = offset + 770
                    }
                    if (body.pos < offset + size) c.block(body.bytes(offset + size - body.pos), x, y, right - x + 1, bottom - y + 1)
                }
                // Separator parts carry no payload, regardless of their size field.
                if (type != 0) offset += size
            }
            if (frame >= first) frames += c.image()
        }
        return Clip(frames, if (rate > 0 && slice > 0) (slice * 1000L / rate).toInt().coerceAtLeast(1) else 83)
    }

    /** Fascination's TIRA/TIRB clips inherit 128x80 and a TOT palette. */
    fun decodePreImd(data: ByteArray, width: Int, height: Int, colors: IntArray, first: Int, count: Int): Clip? = runCatching {
        val r = Reader(data)
        val total = r.u16()
        require(first >= 0 && first < total && count in 1..256 && colors.size == 256)
        val c = Canvas(width, height)
        colors.copyInto(c.colors)
        val end = minOf(total, first + count)
        require((end - first).toLong() * width * height * 4 <= 64 * 1024 * 1024)
        val frames = ArrayList<BufferedImage>()
        repeat(end) { frame ->
            val size = r.u16()
            if (size > 0) {
                val next = r.pos + size + 2
                require(next <= data.size)
                var cmd = r.u8()
                if (cmd == 0) { r.skip(768); cmd = r.u8() }
                if (cmd == 2) {
                    val pixels = r.bytes(minOf(c.pixels.size, next - r.pos))
                    pixels.copyInto(c.pixels)
                } else {
                    var pixel = 0
                    while (pixel < c.pixels.size && r.pos < next) {
                        val run = r.u8()
                        if (run and 128 != 0) {
                            val n = minOf((run and 127) + 1, c.pixels.size - pixel)
                            r.bytes(n).copyInto(c.pixels, pixel); pixel += n
                        } else pixel += run + 1
                    }
                }
                r.pos = next
            }
            if (frame >= first) frames += c.image()
        }
        Clip(frames, 83)
    }.getOrNull()

    /** Woodruff's video dialogue/music uses unsigned 8-bit mono slices. */
    fun decodeSound(data: ByteArray): adventureexplorer.model.SoundData? = runCatching {
        val r = Reader(data)
        require(r.u16() == 814)
        r.pos = 6; val total = r.u16()
        r.pos = 18; val parts = r.u16()
        r.pos = 804; val rate = r.u16(); val slice = r.s16(); val slices = r.s16(); val flags = r.u16(); val table = r.u32()
        require(rate > 0 && slice > 0 && slices > 0 && flags and 0x8200 == 0)
        require(parts in 1..1024 && total.toLong() * (6 + 16L * parts) <= data.size - table)
        val pcm = java.io.ByteArrayOutputStream()
        var lastFilled = -1
        repeat(total) { frame -> repeat(parts) { part ->
            r.pos = table + total * 6 + (frame * parts + part) * 16
            if (r.u8() == 1) { r.skip(5); if (r.u8() != 3) lastFilled = frame }
        } }
        fun silence(n: Int) { require(n >= 0 && pcm.size() + n <= 64 * 1024 * 1024); pcm.write(ByteArray(n) { 128.toByte() }) }
        repeat(total) { frame ->
            r.pos = table + frame * 6 + 2; var offset = r.u32()
            repeat(parts) partLoop@{ part ->
                r.pos = table + total * 6 + (frame * parts + part) * 16
                val type = r.u8()
                if (type == 0) return@partLoop
                r.skip(1); val size = r.u32(); val mode = r.u8()
                require(size <= data.size - offset)
                if (type == 1) {
                    val body = Reader(data, offset)
                    when (mode) {
                        1 -> pcm.write(body.bytes(size))
                        2 -> {
                            val mask = body.u16().toLong() or (body.u16().toLong() shl 16)
                            val limit = minOf(slices - 1, 31)
                            val filled = (0 until limit).count { mask and (1L shl it) == 0L }
                            val extra = if (filled == 0) 0 else maxOf(0, (size - 4 - filled * slice - maxOf(0, slices - 32) * slice) / filled)
                            repeat(limit) { i -> if (mask and (1L shl i) == 0L) pcm.write(body.bytes(slice + extra)) else silence(slice) }
                            if (slices > 32) pcm.write(body.bytes((slices - 32) * slice))
                        }
                        3 -> if (frame < lastFilled) silence(slice)
                        else -> error("Unsupported VMD sound slice")
                    }
                }
                offset += size
                require(pcm.size() <= 64 * 1024 * 1024)
            }
        }
        require(pcm.size() > 0)
        adventureexplorer.model.SoundData(pcm.toByteArray(), rate, 8, 1, false)
    }.getOrNull()

    private fun imd(data: ByteArray, first: Int, count: Int): Clip {
        val r = Reader(data)
        require(r.u16() == 0)
        val version = r.u8(); val features = r.u8(); val total = r.u16()
        require(version in 2..4 && first < total)
        val ox = r.s16(); val oy = r.s16(); val w = r.s16(); val h = r.s16()
        val c = Canvas(w, h)
        r.skip(2); val start = r.u16(); palette(r, c.colors)
        var std: IntArray? = null
        if (version >= 3) {
            val n = r.u16(); require(n <= 1)
            if (n == 1) std = intArrayOf(r.s16() - ox, r.s16() - oy, r.s16(), r.s16())
        }
        val positions = if (version >= 4) r.u32() else 0
        val coordinates = if (features and 128 != 0) r.u32() else 0
        var rate = 0; var slice = 0; var slices = 0
        if (features and 64 != 0) { rate = abs(r.s16()); slice = r.s16(); slices = r.s16().let { if (it < 0) -it - 1 else it }; require(slice > 0 && slices in 0..40) }
        val end = minOf(total, first + count)
        require((end - first).toLong() * w * h * 4 <= 64 * 1024 * 1024)
        r.pos = start
        val frames = ArrayList<BufferedImage>()
        repeat(end) { frame ->
            if (positions > 0) { val t = Reader(data, positions + frame * 4); r.pos = t.u32() }
            var cmd = r.u16()
            if (cmd == 0xFFF0) { r.skip(2); cmd = r.u16() }
            when (cmd) {
                0xFFF1 -> Unit
                0xFFF2 -> r.skip(r.u16())
                0xFFF3 -> r.skip(r.u32())
                else -> {
                    if (cmd == 0xFF00 || cmd == 0xFF01) { r.skip(slice * if (cmd == 0xFF01) slices else 1); cmd = r.u16() }
                    if (cmd == 0xFFF4) { r.skip(2); palette(r, c.colors); cmd = r.u16() }
                    require(cmd != 0xFFFD) // do not follow looping frame jumps in exported clips
                    val size = when (cmd) { 0 -> 0; 0xFFFC -> r.u32() + 2; else -> cmd + 2 }
                    if (size > 0) {
                        var rect = if (frame > 0) std else null
                        if (frame > 0 && coordinates > 0) {
                            val t = Reader(data, coordinates + frame * 8)
                            val left = t.s16(); val top = t.s16(); val right = t.s16(); val bottom = t.s16()
                            if (left != -1) rect = intArrayOf(left - ox, top - oy, right - left + 1, bottom - top + 1)
                        }
                        val box = rect ?: intArrayOf(0, 0, w, h)
                        c.block(r.bytes(size), box[0], box[1], box[2], box[3], true)
                    }
                }
            }
            if (frame >= first) frames += c.image()
        }
        return Clip(frames, if (rate > 0 && slice > 0) (slice * 1000L / rate).toInt().coerceAtLeast(1) else 83)
    }
}

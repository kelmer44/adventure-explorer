package adventureexplorer.graphics

import java.awt.image.BufferedImage

/**
 * Cryo HNM6 still images: the 360-degree "warp" panoramas of Versailles 1685 and Atlantis: The
 * Lost Tales (2048x768, one `IW` key frame inside a one-frame `.HNM`).
 *
 * Ported from ScummVM `image/codecs/hnm.cpp` and `engines/cryomni3d/image/hnm.cpp`
 * (GPL-2.0-or-later, the ScummVM Team). Only the warp key-frame path is implemented; `IX` still
 * images and inter frames belong to the video decoder and are not needed for the panoramas.
 *
 * Layout: a 64-byte file header (tag `HNM6`, u16le width and height at 8 and 10), a u32 frame
 * size, then a chunk `[u32 size][u8[2] tag][u16 unused]` whose payload starts with six u32:
 * quality, then the start offsets of four streams (bit stream, motion words, short motion words,
 * JPEG-style nibbles) and the end. Each 8x8 block is coded with the bit stream as a key block
 * (three JPEG-like planes through an AAN IDCT, YUV to RGB), a motion copy from earlier pixels of
 * the same image, or four 4x4 blocks that are themselves a motion copy or four 2x2 short motion
 * copies.
 */
object CryoHnm6 {
    private const val FILE_HEADER = 64
    private const val STREAM_HEADER = 24

    class Image(val width: Int, val height: Int, val rgb: IntArray) {
        /** The warp is stored with the sky at the bottom; [flipVertical] puts it the right way up. */
        fun toBufferedImage(flipVertical: Boolean = false): BufferedImage {
            val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
            if (flipVertical) {
                for (y in 0 until height) image.setRGB(0, y, width, 1, rgb, (height - 1 - y) * width, width)
            } else {
                image.setRGB(0, 0, width, height, rgb, 0, width)
            }
            return image
        }
    }

    private fun u16(d: ByteArray, p: Int) = (d[p].toInt() and 255) or ((d[p + 1].toInt() and 255) shl 8)
    private fun u32(d: ByteArray, p: Int): Long = (u16(d, p).toLong()) or (u16(d, p + 2).toLong() shl 16)

    /** True when [data] looks like a one-frame HNM6 warp image. */
    fun isWarp(data: ByteArray): Boolean =
        data.size > FILE_HEADER + 16 && data[0] == 'H'.code.toByte() && data[1] == 'N'.code.toByte() &&
            data[2] == 'M'.code.toByte() && data[3] == '6'.code.toByte() &&
            data[FILE_HEADER + 8] == 'I'.code.toByte() && data[FILE_HEADER + 9] == 'W'.code.toByte()

    fun dimensions(data: ByteArray): Pair<Int, Int>? =
        if (isWarp(data)) u16(data, 8) to u16(data, 10) else null

    /** Decodes the warp image, or returns null when [data] is not a decodable HNM6 warp. */
    fun decode(data: ByteArray): Image? {
        if (!isWarp(data)) return null
        val width = u16(data, 8)
        val height = u16(data, 10)
        if (width == 0 || height == 0 || width % 8 != 0 || height % 8 != 0 || width > 8192 || height > 8192) return null
        val frameSize = u32(data, FILE_HEADER)
        val chunkSize = u32(data, FILE_HEADER + 4)
        if (frameSize < 12 || frameSize - 4 < chunkSize || chunkSize < 8 + STREAM_HEADER) return null
        val start = FILE_HEADER + 12
        if (start + STREAM_HEADER > data.size) return null
        val quality = u32(data, start).toInt()
        val offsets = LongArray(5) { u32(data, start + 4 + it * 4) }
        val end = offsets[4]
        if (offsets.any { it > end } || end > chunkSize || start + end > data.size || quality <= 0) return null
        val buffer = data.copyOfRange(start, (start + end).toInt())
        return try {
            Decoder(width, height, buffer, offsets.map { it.toInt() }, quality).decode()
        } catch (e: IndexOutOfBoundsException) {
            null
        }
    }

    private val LUMA = intArrayOf(
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99)
    private val CHROMA = intArrayOf(
        17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99)
    private val AAN = intArrayOf(
        16384, 22725, 21407, 19266, 16384, 12873, 8867, 4520, 22725, 31521, 29692, 26722, 22725, 17855, 12299, 6270,
        21407, 29692, 27969, 25172, 21407, 16819, 11585, 5906, 19266, 26722, 25172, 22654, 19266, 15137, 10426, 5315,
        16384, 22725, 21407, 19266, 16384, 12873, 8867, 4520, 12873, 17855, 16819, 15137, 12873, 10114, 6967, 3552,
        8867, 12299, 11585, 10426, 8867, 6967, 4799, 2446, 4520, 6270, 5906, 5315, 4520, 3552, 2446, 1247)
    private val ZIGZAG = intArrayOf(
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63)
    private val MASKS = intArrayOf(
        0x0101, 0x0102, 0x0201, 0x0401, 0x0202, 0x0104, 0x0108, 0x0204, 0x0402, 0x0801, 0x1001, 0x0802, 0x0404,
        0x0208, 0x0110, 0x0120, 0x0210, 0x0408, 0x0804, 0x1002, 0x2001, 0x4001, 0x2002, 0x1004, 0x0808, 0x0410,
        0x0220, 0x0140, 0x0180, 0x0240, 0x0420, 0x0810, 0x1008, 0x2004, 0x4002, 0x8001, 0x8002, 0x4004, 0x2008,
        0x1010, 0x0820, 0x0440, 0x0280, 0x0480, 0x0840, 0x1020, 0x2010, 0x4008, 0x8004, 0x8008, 0x4010, 0x2020,
        0x1040, 0x0880, 0x1080, 0x2040, 0x4020, 0x8010, 0x8020, 0x4040, 0x2080, 0x4080, 0x8040, 0x8080)
    private val S2 = intArrayOf(
        1, 1, 1, 2, 1, -2, 1, -1, 2, 1, 2, 2, 2, -2, 2, -1,
        -2, 1, -2, 2, -2, -2, -2, -1, -1, 1, -1, 2, -1, -2, -1, -1)
    private val S4 = intArrayOf(1, 2, 3, 4, 5, 6, 7, 8, -8, -7, -6, -5, -4, -3, -2, -1)

    private class Decoder(
        val w: Int, val h: Int, val buf: ByteArray, offsets: List<Int>, quality: Int,
    ) {
        val pix = IntArray(w * h)
        val coeffs = IntArray(192)
        val lumaQuant = IntArray(64)
        val chromaQuant = IntArray(64)

        // Bit stream: little-endian words consumed from the most significant bit.
        var bitPos = offsets[0]
        val bitEnd = offsets[1]
        var bitReg = 0
        var bitCount = 0

        var motionPos = offsets[1]
        val motionEnd = offsets[2]

        var shortPos = offsets[2]
        val shortEnd = offsets[3]
        var shortOther = 0

        var jpegPos = offsets[3]
        val jpegEnd = offsets[4]
        var jpegOther = 0

        init {
            val q = quality.coerceIn(1, 100)
            val qf = if (q >= 50) 200 - 2 * q else 5000 / q
            for (i in 0 until 64) {
                lumaQuant[i] = (((LUMA[ZIGZAG[i]] * qf + 50) / 100).coerceIn(8, 255) * AAN[ZIGZAG[i]]) shr 13
                chromaQuant[i] = (((CHROMA[ZIGZAG[i]] * qf + 50) / 100).coerceIn(8, 255) * AAN[ZIGZAG[i]]) shr 13
            }
        }

        fun b(i: Int) = buf[i].toInt() and 255

        fun bit(): Int {
            if (bitCount == 0) {
                if (bitPos + 4 > bitEnd) throw IndexOutOfBoundsException("bit stream exhausted")
                bitReg = b(bitPos) or (b(bitPos + 1) shl 8) or (b(bitPos + 2) shl 16) or (b(bitPos + 3) shl 24)
                bitPos += 4
                bitCount = 32
            }
            val r = bitReg ushr 31
            bitReg = bitReg shl 1
            bitCount--
            return r
        }

        fun motion(): Int {
            if (motionPos + 2 > motionEnd) throw IndexOutOfBoundsException("motion stream exhausted")
            val r = b(motionPos) or (b(motionPos + 1) shl 8)
            motionPos += 2
            return r
        }

        fun shortMotion(): Int {
            if (shortOther != 0) {
                val r = shortOther and 0xFFF
                shortOther = 0
                return r
            }
            if (shortPos + 2 > shortEnd) throw IndexOutOfBoundsException("short motion stream exhausted")
            if (shortPos + 3 > shortEnd) {
                val r = b(shortPos) or (b(shortPos + 1) shl 8)
                shortPos += 2
                return r and 0xFFF
            }
            val full = b(shortPos) or (b(shortPos + 1) shl 8) or (b(shortPos + 2) shl 16)
            shortPos += 3
            shortOther = ((full shr 12) and 0xFFF) or 0x8000
            return full and 0xFFF
        }

        fun nibble(): Int {
            if (jpegOther != 0) {
                val r = jpegOther and 0xF
                jpegOther = 0
                return r
            }
            if (jpegPos >= jpegEnd) throw IndexOutOfBoundsException("jpeg stream exhausted")
            val full = b(jpegPos)
            jpegPos++
            jpegOther = (full shr 4) or 0x80
            return full and 0xF
        }

        fun decode(): Image {
            for (y in 0 until h step 8) for (x in 0 until w step 8) block88(x, y)
            return Image(w, h, pix)
        }

        fun block88(x: Int, y: Int) {
            if (bit() != 0) {
                if (bit() != 0) keyblock(x, y) else iwMotion(8, x, y)
            } else {
                block44(x, y)
                block44(x + 4, y)
                block44(x, y + 4)
                block44(x + 4, y + 4)
            }
        }

        fun block44(x: Int, y: Int) {
            if (bit() != 0) {
                shortMo(x, y)
                shortMo(x + 2, y)
                shortMo(x, y + 2)
                shortMo(x + 2, y + 2)
            } else {
                iwMotion(4, x, y)
            }
        }

        fun keyblock(x: Int, y: Int) {
            plane(0, lumaQuant)
            plane(64, chromaQuant)
            plane(128, chromaQuant)
            for (ry in 0 until 8) {
                val row = (y + ry) * w + x
                for (rx in 0 until 8) {
                    val k = ry * 8 + rx
                    val cy = coeffs[k] shr 4
                    val cu = coeffs[64 + k]
                    val cv = coeffs[128 + k]
                    val cr = (16 * ((cv shr 4) + 256 - 256) + 8) / 10
                    val cb = ((cu shr 4) + 256 - 256) / 3
                    val r = (cy + 128 + cr).coerceIn(0, 255)
                    val g = (cy + 128 - (cr shr 1) - cb).coerceIn(0, 255)
                    val bl = (cy + 128 + (cu shr 3)).coerceIn(0, 255)
                    pix[row + rx] = (r shl 16) or (g shl 8) or bl
                }
            }
        }

        fun plane(base: Int, quant: IntArray) {
            var i = 0
            var mask = 0
            java.util.Arrays.fill(coeffs, base, base + 64, 0)
            fun skip(n: Int) { i += n }
            fun write(v: Int) {
                if (i < 64) {
                    coeffs[base + ZIGZAG[i]] = v * quant[i]
                    mask = mask or MASKS[i]
                }
                i++
            }
            fun signedByte(): Int = (((nibble() shl 4) or nibble()) shl 24) shr 24
            write(signedByte())
            while (i < 64) {
                when (val code = nibble()) {
                    0 -> i = 64
                    1 -> skip(5)
                    2 -> { skip(1); write(1) }
                    3 -> { skip(1); write(-1) }
                    4 -> { skip(2); write(1) }
                    5 -> { skip(2); write(-1) }
                    6 -> { skip(3); write(1) }
                    7 -> { skip(3); write(-1) }
                    8 -> {
                        val v = nibble()
                        var t = (v and 3) + 2
                        skip(((v shr 2) and 3) + 1)
                        while (t > 1) {
                            val p = 2 * nibble()
                            write(S2[p]); write(S2[p + 1])
                            t -= 2
                        }
                        if (t > 0) write(S2[2 * nibble()])
                    }
                    9 -> {
                        val v = nibble()
                        var t = (v and 3) + 1
                        skip(((v shr 2) and 3) + 1)
                        while (t > 0) { write(S4[nibble()]); t-- }
                    }
                    10 -> { val p = 2 * nibble(); write(S2[p]); write(S2[p + 1]) }
                    11, 12, 13 -> repeat(code - 10) { write(S4[nibble()]) }
                    14 -> skip(1)
                    15 -> write(signedByte())
                }
            }
            idct(base, mask)
        }

        /** One pass of the Arai, Agui and Nakajima 1-D IDCT over up to eight lines. */
        fun aan(base: Int, stride: Int, inc: Int, mask: Int) {
            var x = base
            var m = mask and 255
            var i = 0
            val a = coeffs
            while (i < 8 && m != 0) {
                val x2n6 = a[x + 2 * stride] - a[x + 6 * stride]
                val x2p6 = a[x + 2 * stride] + a[x + 6 * stride]
                val x0n4 = a[x] - a[x + 4 * stride]
                val x0p4 = a[x] + a[x + 4 * stride]
                val x5n3 = a[x + 5 * stride] - a[x + 3 * stride]
                val x3p5 = a[x + 3 * stride] + a[x + 5 * stride]
                val x1n7 = a[x + stride] - a[x + 7 * stride]
                val x1p7 = a[x + stride] + a[x + 7 * stride]
                val tmp0 = ((3 * x2n6) shr 1) - x2p6
                val tmp1 = (3 * (x1p7 - x3p5)) shr 1
                val tmp2 = 30 * (x5n3 + x1n7)
                val tmp3 = (17 * x1n7 - tmp2) shr 4
                val tmp4 = (tmp2 - 40 * x5n3) shr 4
                val tmp5 = tmp4 - x3p5 - x1p7
                a[x] = x1p7 + x3p5 + x0p4 + x2p6
                a[x + 7 * stride] = x0p4 + x2p6 - x1p7 - x3p5
                a[x + stride] = tmp0 + x0n4 + tmp4 - x3p5 - x1p7
                a[x + 6 * stride] = tmp0 + x0n4 - tmp4 + x3p5 + x1p7
                a[x + 2 * stride] = x0n4 - tmp0 + tmp1 - tmp5
                a[x + 5 * stride] = x0n4 - tmp0 - tmp1 + tmp5
                a[x + 3 * stride] = x0p4 - x2p6 - tmp1 + tmp5 - tmp3
                a[x + 4 * stride] = x0p4 - x2p6 + tmp1 - tmp5 + tmp3
                x += inc
                m = m shr 1
                i++
            }
        }

        fun idct(base: Int, mask: Int) {
            val a = coeffs
            if (mask == 0x0101) {
                for (i in 1 until 64) a[base + i] = a[base]
                return
            }
            val rowMask = mask shr 8
            val colMask = mask and 0xFF
            if (rowMask < colMask) {
                aan(base, 1, 8, rowMask)
                if (rowMask == 0x01) {
                    for (i in 1 until 8) System.arraycopy(a, base, a, base + 8 * i, 8)
                } else {
                    aan(base, 8, 1, 0xFF)
                }
            } else {
                aan(base, 8, 1, colMask)
                if (colMask == 0x01) {
                    for (i in 0 until 8) java.util.Arrays.fill(a, base + 8 * i, base + 8 * i + 8, a[base + 8 * i])
                } else {
                    aan(base, 1, 8, 0xFF)
                }
            }
        }

        fun iwMotion(size: Int, x: Int, y: Int) {
            val word = motion()
            var xform = bit() shl 2
            xform = xform or (bit() shl 1)
            xform = xform or (word shr 15)
            val offY = if (size == 8) 0 else 4
            var srx = (x and 7.inv()) + 128 - ((word shr 7) and 0xFF)
            val sry = (y and 7.inv()) + offY - (word and 0x7F)
            if (srx < 0) srx += w else if (srx >= w) srx -= w
            copy(xform, size, size, srx, sry, x, y)
        }

        fun shortMo(x: Int, y: Int) {
            val word = shortMotion()
            val xform = (word shr 1) and 7
            var index = ((word and 1) shl 8) or (word and 0xF0) or (word shr 8)
            val xm: Int
            var ym: Int
            if (index < 12 * 8) {
                xm = -2 - index % 12
                ym = 6 - index / 12
            } else {
                index -= 12 * 8
                xm = 19 - index % 32
                ym = -2 - index / 32
                if (ym <= -8) ym--
            }
            copy(xform, 2, 2, (x and 7.inv()) + xm, (y and 7.inv()) + ym, x, y)
        }

        /**
         * ScummVM `doMotion`: copies a block within the image under one of eight transforms.
         * Source columns outside the line spill onto the neighbouring line because the image is
         * addressed linearly, as in the original.
         */
        fun copy(xform: Int, sx: Int, sy: Int, srx: Int, sry: Int, dx: Int, dy: Int) {
            fun src(x: Int, y: Int): Int {
                val i = y * w + x
                return if (i in pix.indices) pix[i] else 0
            }
            when (xform) {
                0 -> for (y in 0 until sy) {
                    val s = (sry + y) * w + srx
                    val d = (dy + y) * w + dx
                    if (s >= 0 && s + sx <= pix.size) System.arraycopy(pix, s, pix, d, sx)
                    else for (x in 0 until sx) pix[d + x] = src(srx + x, sry + y)
                }
                1 -> for (y in 0 until sy) for (x in 0 until sx) pix[(dy + y) * w + dx + x] = src(srx + sx - 1 - x, sry + y)
                2 -> for (y in 0 until sy) for (x in 0 until sx) pix[(dy + y) * w + dx + x] = src(srx + x, sry + sy - 1 - y)
                3 -> for (y in 0 until sy) for (x in 0 until sx) pix[(dy + y) * w + dx + x] = src(srx + sx - 1 - x, sry + sy - 1 - y)
                4 -> for (y in 0 until sy) for (x in 0 until sx) pix[(dy + y) * w + dx + x] = src(srx + sy - 1 - y, sry + sx - 1 - x)
                5 -> for (y in 0 until sy) for (x in 0 until sx) pix[(dy + y) * w + dx + x] = src(srx + y, sry + sx - 1 - x)
                6 -> for (y in 0 until sy) for (x in 0 until sx) pix[(dy + y) * w + dx + x] = src(srx + sy - 1 - y, sry + x)
                7 -> for (y in 0 until sy) for (x in 0 until sx) pix[(dy + y) * w + dx + x] = src(srx + y, sry + x)
            }
        }
    }
}

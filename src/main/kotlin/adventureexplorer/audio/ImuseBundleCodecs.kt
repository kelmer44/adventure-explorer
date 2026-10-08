package adventureexplorer.audio

/**
 * Port of ScummVM's `BundleCodecs::decompressCodec` (engines/scumm/imuse_digi/dimuse_codecs.cpp).
 *
 * Used by the SCUMM V7/V8 `.BUN` audio bundles (The Dig, The Curse of Monkey Island). Each
 * bundle sound is split into compressed blocks that expand to 0x2000 bytes; the block's codec id
 * (0..15) selects the decoder:
 *   0       raw copy
 *   1..12   LZ-style bit stream ("compDecode") followed by delta / nibble shuffling
 *   13, 15  variable bit-size IMA ADPCM (mono / stereo) - output is little-endian 16-bit
 */
object ImuseBundleCodecs {

    const val CHUNK_SIZE = 0x2000

    private val IMA_TABLE = intArrayOf(
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88,
        97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
        724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660,
        4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
        18500, 20350, 22385, 24623, 27086, 29794, 32767
    )

    private fun rows(vararg r: IntArray) = r
    private fun ff(n: Int, vararg tail: Int) = IntArray(n) { 0xFF } + tail

    private val IMX_OTHER = rows(
        ff(1, 4),
        ff(2, 2, 8),
        ff(4, 1, 2, 4, 6),
        ff(8, 1, 2, 4, 6, 8, 12, 16, 32),
        ff(16, 1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 32),
        ff(32, *IntArray(32) { it + 1 })
    )

    private val destImcTable = ByteArray(89)
    private val destImcTable2 = IntArray(89 * 64)

    init {
        for (pos in 0..88) {
            var put = 1
            var tableValue = ((IMA_TABLE[pos] * 4) / 7) / 2
            while (tableValue != 0) {
                tableValue /= 2
                put++
            }
            if (put < 3) put = 3
            if (put > 8) put = 8
            destImcTable[pos] = (put - 1).toByte()
        }
        for (n in 0 until 64) {
            for (pos in 0..88) {
                var count = 32
                var put = 0
                var tableValue = IMA_TABLE[pos]
                do {
                    if ((count and n) != 0) put += tableValue
                    count /= 2
                    tableValue /= 2
                } while (count != 0)
                destImcTable2[n + pos * 64] = put
            }
        }
    }

    private fun u8(b: ByteArray, i: Int): Int = if (i in b.indices) b[i].toInt() and 0xFF else 0

    /** LZ-style decoder. Returns the number of bytes written to [dst]. */
    private fun compDecode(src: ByteArray, dst: ByteArray): Int {
        var s = 0
        var d = 0
        var bitsLeft = 16
        var mask = u8(src, 0) or (u8(src, 1) shl 8)
        s = 2

        fun nextBit(): Int {
            val bit = mask and 1
            mask = mask ushr 1
            if (--bitsLeft == 0) {
                mask = u8(src, s) or (u8(src, s + 1) shl 8)
                s += 2
                bitsLeft = 16
            }
            return bit
        }

        while (true) {
            if (nextBit() != 0) {
                if (d >= dst.size || s >= src.size + 2) return d
                dst[d++] = src[s++]
            } else {
                var data: Int
                var size: Int
                if (nextBit() == 0) {
                    size = nextBit() shl 1
                    size = (size or nextBit()) + 3
                    data = u8(src, s++) or -256
                } else {
                    data = u8(src, s++)
                    size = u8(src, s++)
                    data = data or (-4096 + ((size and 0xF0) shl 4))
                    size = (size and 0x0F) + 3
                    if (size == 3) {
                        if (u8(src, s++) + 1 == 1) return d
                    }
                }
                var r = d + data
                if (r < 0 || s > src.size + 4) return d
                while (size-- > 0) {
                    if (d >= dst.size) return d
                    dst[d++] = dst[r++]
                }
            }
        }
    }

    /** Variable bit-width IMA ADPCM block (codec 13 = mono, 15 = stereo). Always 0x2000 bytes. */
    private fun decompressAdpcm(src: ByteArray, dst: ByteArray, channels: Int): Int {
        var p = 0
        var outputSamplesLeft = 0x1000
        val initialTablePos = IntArray(2)
        val initialOutputWord = IntArray(2)

        val firstWord = ((u8(src, 0) shl 8) or u8(src, 1)).toShort().toInt()
        p = 2
        if (firstWord != 0) {
            System.arraycopy(src, p, dst, 0, firstWord)
            p += firstWord
            outputSamplesLeft -= firstWord / 2
        } else {
            for (i in 0 until channels) {
                initialTablePos[i] = u8(src, p)
                p += 1 + 4
                initialOutputWord[i] = (u8(src, p) shl 24) or (u8(src, p + 1) shl 16) or
                    (u8(src, p + 2) shl 8) or u8(src, p + 3)
                p += 4
            }
        }

        var totalBitOffset = 0
        for (chan in 0 until channels) {
            var curTablePos = initialTablePos[chan]
            var outputWord = initialOutputWord[chan]
            var destPos = chan * 2
            val bound = if (channels == 1) outputSamplesLeft
            else if (chan == 0) (outputSamplesLeft + 1) / 2 else outputSamplesLeft / 2

            for (i in 0 until bound) {
                val bitCount = destImcTable[curTablePos].toInt()
                val readPos = p + (totalBitOffset shr 3)
                val readWord = (((u8(src, readPos) shl 8) or u8(src, readPos + 1)) shl (totalBitOffset and 7)) and 0xFFFF
                val packet = (readWord shr (16 - bitCount)) and 0xFF
                totalBitOffset += bitCount

                val signBitMask = 1 shl (bitCount - 1)
                val dataBitMask = signBitMask - 1
                val data = packet and dataBitMask

                val tmpA = data shl (7 - bitCount)
                val imcTableEntry = IMA_TABLE[curTablePos] shr (bitCount - 1)
                var delta = imcTableEntry + destImcTable2[tmpA + curTablePos * 64]
                if ((packet and signBitMask) != 0) delta = -delta

                outputWord += delta
                outputWord = outputWord.coerceIn(-0x8000, 0x7FFF)

                if (destPos + 1 < dst.size) {
                    dst[destPos] = outputWord.toByte()
                    dst[destPos + 1] = (outputWord shr 8).toByte()
                }
                destPos += channels shl 1

                curTablePos += IMX_OTHER[bitCount - 2][data].toByte().toInt()
                curTablePos = curTablePos.coerceIn(0, IMA_TABLE.size - 1)
            }
        }
        return 0x2000
    }

    private fun prefixSums(p: ByteArray, size: Int) {
        for (z in 2 until size) p[z] = (p[z] + p[z - 1]).toByte()
        for (z in 1 until size) p[z] = (p[z] + p[z - 1]).toByte()
    }

    /** Decode one compressed block. Returns the decoded bytes (length = decoded size). */
    fun decompress(codec: Int, input: ByteArray, channels: Int = 1): ByteArray? {
        val out = ByteArray(CHUNK_SIZE + 64)
        val size: Int

        when (codec) {
            0 -> {
                val n = minOf(input.size, CHUNK_SIZE)
                System.arraycopy(input, 0, out, 0, n)
                size = n
            }
            1 -> size = compDecode(input, out)
            2 -> {
                size = compDecode(input, out)
                for (z in 1 until size) out[z] = (out[z] + out[z - 1]).toByte()
            }
            3 -> {
                size = compDecode(input, out)
                prefixSums(out, size)
            }
            4 -> {
                size = compDecode(input, out)
                prefixSums(out, size)
                val t = ByteArray(size)
                val src = out
                val length = (size shl 3) / 12
                var k = 0
                var c = -12
                var s = 0
                var j = 0
                if (length > 0) {
                    do {
                        val ptr = length + (k shr 1)
                        val t2 = u8(src, j)
                        if ((k and 1) != 0) {
                            val r = c shr 3
                            t[r + 2] = (((t2 and 0x0F) shl 4) or (u8(src, ptr + 1) shr 4)).toByte()
                            t[r + 1] = ((t2 and 0xF0) or (t[r + 1].toInt() and 0xFF)).toByte()
                        } else {
                            val r = s shr 3
                            t[r] = (((t2 and 0x0F) shl 4) or (u8(src, ptr) and 0x0F)).toByte()
                            t[r + 1] = (t2 shr 4).toByte()
                        }
                        s += 12; c += 12; k++; j++
                    } while (k < length)
                }
                val offset1 = ((length - 1) * 3) shr 1
                t[offset1 + 1] = ((t[offset1 + 1].toInt() and 0xFF) or (src[length - 1].toInt() and 0xF0)).toByte()
                System.arraycopy(t, 0, out, 0, size)
            }
            5 -> {
                size = compDecode(input, out)
                prefixSums(out, size)
                val t = ByteArray(size)
                val src = out
                val length = (size shl 3) / 12
                var k = 1
                var c = 0
                var s = 12
                t[0] = (u8(src, length) shr 4).toByte()
                val tt = length + k
                var j = 1
                if (tt > k) {
                    do {
                        val t1 = u8(src, length + (k shr 1))
                        val t2 = u8(src, j - 1)
                        if ((k and 1) != 0) {
                            val r = c shr 3
                            t[r] = ((t2 and 0xF0) or (t[r].toInt() and 0xFF)).toByte()
                            t[r + 1] = (((t2 and 0x0F) shl 4) or (t1 and 0x0F)).toByte()
                        } else {
                            val r = s shr 3
                            t[r] = (t2 shr 4).toByte()
                            t[r - 1] = (((t2 and 0x0F) shl 4) or (t1 shr 4)).toByte()
                        }
                        s += 12; c += 12; k++; j++
                    } while (k < tt)
                }
                System.arraycopy(t, 0, out, 0, size)
            }
            6 -> {
                size = compDecode(input, out)
                prefixSums(out, size)
                val t = ByteArray(size)
                val src = out
                val length = (size shl 3) / 12
                var k = 0
                var c = 0
                var j = 0
                var s = -12
                t[0] = src[size - 1]
                t[size - 1] = src[length - 1]
                val tt = length - 1
                if (tt > 0) {
                    do {
                        val t1 = u8(src, length + (k shr 1))
                        val t2 = u8(src, j)
                        if ((k and 1) != 0) {
                            val r = s shr 3
                            t[r + 2] = ((t2 and 0xF0) or (t[r + 2].toInt() and 0xFF)).toByte()
                            t[r + 3] = (((t2 and 0x0F) shl 4) or (t1 shr 4)).toByte()
                        } else {
                            val r = c shr 3
                            t[r + 2] = (t2 shr 4).toByte()
                            t[r + 1] = (((t2 and 0x0F) shl 4) or (t1 and 0x0F)).toByte()
                        }
                        s += 12; c += 12; k++; j++
                    } while (k < tt)
                }
                System.arraycopy(t, 0, out, 0, size)
            }
            10, 11, 12 -> {
                size = compDecode(input, out)
                prefixSums(out, size)
                val t = out.copyOf(size)
                var offset1 = size / 3
                var offset2 = offset1 shl 1
                var offset3 = offset2
                val src = out
                while (offset1-- > 0) {
                    offset2 -= 2
                    offset3--
                    t[offset2] = src[offset1]
                    t[offset2 + 1] = src[offset3]
                }
                val length = (size shl 3) / 12
                when (codec) {
                    10 -> {
                        var k = 0
                        var c = -12
                        var s = 0
                        if (length > 0) {
                            do {
                                val j = length + (k shr 1)
                                val t1 = u8(t, k)
                                if ((k and 1) != 0) {
                                    val r = c shr 3
                                    val t2 = u8(t, j + 1)
                                    src[r + 2] = (((t1 and 0x0F) shl 4) or (t2 shr 4)).toByte()
                                    src[r + 1] = ((src[r + 1].toInt() and 0xFF) or (t1 and 0xF0)).toByte()
                                } else {
                                    val r = s shr 3
                                    val t2 = u8(t, j)
                                    src[r] = (((t1 and 0x0F) shl 4) or (t2 and 0x0F)).toByte()
                                    src[r + 1] = (t1 shr 4).toByte()
                                }
                                s += 12; c += 12; k++
                            } while (k < length)
                        }
                        val o1 = ((length - 1) * 3) shr 1
                        src[o1 + 1] = ((u8(t, length) and 0xF0) or (src[o1 + 1].toInt() and 0xFF)).toByte()
                    }
                    11 -> {
                        var k = 1
                        var c = 0
                        var s = 12
                        src[0] = (u8(t, length) shr 4).toByte()
                        val tt = length + k
                        if (tt > k) {
                            do {
                                val j = length + (k shr 1)
                                val t1 = u8(t, k - 1)
                                val t2 = u8(t, j)
                                if ((k and 1) != 0) {
                                    val r = c shr 3
                                    src[r] = ((src[r].toInt() and 0xFF) or (t1 and 0xF0)).toByte()
                                    src[r + 1] = (((t1 and 0x0F) shl 4) or (t2 and 0x0F)).toByte()
                                } else {
                                    val r = s shr 3
                                    src[r] = (t1 shr 4).toByte()
                                    src[r - 1] = (((t1 and 0x0F) shl 4) or (t2 shr 4)).toByte()
                                }
                                s += 12; c += 12; k++
                            } while (k < tt)
                        }
                    }
                    else -> {
                        var k = 0
                        var c = 0
                        var s = -12
                        src[0] = t[size - 1]
                        src[size - 1] = t[length - 1]
                        val tt = length - 1
                        if (tt > 0) {
                            do {
                                val j = length + (k shr 1)
                                val t1 = u8(t, k)
                                val t2 = u8(t, j)
                                if ((k and 1) != 0) {
                                    val r = s shr 3
                                    src[r + 2] = ((src[r + 2].toInt() and 0xFF) or (t1 and 0xF0)).toByte()
                                    src[r + 3] = (((t1 and 0x0F) shl 4) or (t2 shr 4)).toByte()
                                } else {
                                    val r = c shr 3
                                    src[r + 2] = (t1 shr 4).toByte()
                                    src[r + 1] = (((t1 and 0x0F) shl 4) or (t2 and 0x0F)).toByte()
                                }
                                s += 12; c += 12; k++
                            } while (k < tt)
                        }
                    }
                }
            }
            13, 15 -> size = decompressAdpcm(input, out, if (codec == 13) 1 else 2)
            else -> return null
        }
        return out.copyOf(size.coerceIn(0, out.size))
    }
}

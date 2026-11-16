package adventureexplorer.audio

import adventureexplorer.model.SoundData

/**
 * Cryo `.APC` audio (`CRYO_APC1.20`), used by Versailles 1685, Atlantis: The Lost Tales and
 * Aztec: The Curse in the Heart of the City of Gold. Ported from ScummVM `audio/decoders/apc.cpp`
 * (GPL-2.0-or-later, the ScummVM Team).
 *
 * A 32-byte header (12-byte magic, u32 sample count, u32 sample rate, i32 left and i32 right
 * start samples, u32 flags with bit 0 = stereo) is followed by IMA ADPCM nibbles. Each byte holds
 * two codes, high nibble first. Mono files decode both nibbles with one state; stereo files send
 * the high nibble to the left and the low nibble to the right channel.
 *
 * Unlike standard IMA the predictor is only truncated to 16 bits, never clipped, so a decoder that
 * clamps would diverge on loud passages.
 */
object CryoApc {
    private const val HEADER = 32
    private val MAGIC = "CRYO_APC1.20".toByteArray(Charsets.ISO_8859_1)
    private val IMA_STEPS = intArrayOf(
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66,
        73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408,
        449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630,
        9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767)
    private val ADJUST = intArrayOf(-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8)

    private fun u32(d: ByteArray, p: Int): Long =
        (d[p].toLong() and 255) or ((d[p + 1].toLong() and 255) shl 8) or
            ((d[p + 2].toLong() and 255) shl 16) or ((d[p + 3].toLong() and 255) shl 24)

    private fun i32(d: ByteArray, p: Int): Int = u32(d, p).toInt()

    /** True when [data] starts with the APC magic. */
    fun isApc(data: ByteArray): Boolean =
        data.size >= HEADER && MAGIC.indices.all { data[it] == MAGIC[it] }

    /** Sample rate and channel count from the header, or null when [data] is not APC. */
    fun format(data: ByteArray): Pair<Int, Int>? {
        if (!isApc(data)) return null
        val rate = u32(data, 16).toInt()
        val channels = if (u32(data, 28) and 1L != 0L) 2 else 1
        return if (rate in 1000..192000) rate to channels else null
    }

    fun decode(data: ByteArray): SoundData? {
        val (rate, channels) = format(data) ?: return null
        val stereo = channels == 2
        val last = intArrayOf(i32(data, 20), i32(data, 24))
        val index = intArrayOf(0, 0)
        val step = intArrayOf(IMA_STEPS[0], IMA_STEPS[0])
        val right = if (stereo) 1 else 0
        val count = data.size - HEADER
        if (count <= 0) return null
        val out = ByteArray(count * 4)
        var o = 0
        fun code(code: Int, ch: Int) {
            val e = (2 * (code and 7) + 1) * step[ch] / 8
            val sample = (last[ch] + if (code and 8 != 0) -e else e).toShort().toInt()
            index[ch] = (index[ch] + ADJUST[code]).coerceIn(0, IMA_STEPS.size - 1)
            last[ch] = sample
            step[ch] = IMA_STEPS[index[ch]]
            out[o++] = sample.toByte()
            out[o++] = (sample shr 8).toByte()
        }
        for (i in 0 until count) {
            val b = data[HEADER + i].toInt() and 255
            code(b shr 4, 0)
            code(b and 15, right)
        }
        return SoundData(out, rate, 16, channels, true)
    }
}

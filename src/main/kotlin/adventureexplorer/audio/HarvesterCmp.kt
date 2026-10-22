package adventureexplorer.audio

import adventureexplorer.model.SoundData

/**
 * Harvester (DigiFX/FutureVision) .CMP audio: "FCMP", u32 payload size, u32
 * sample rate, u16 bits per sample, then one continuous mono IMA ADPCM stream
 * (low nibble first) starting from predictor 0 and step index 0. The predictor
 * needs a moment to settle, so like the game's music player the first 50
 * samples are silenced.
 * References: MultimediaWiki "FutureVision audio formats"; alexbevi.com,
 * "Reverse engineering Harvester ... part 5: debugging audio issues".
 */
object HarvesterCmp {
    private val STEPS = intArrayOf(
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66,
        73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408,
        449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630,
        9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767)
    private val ADJUST = intArrayOf(-1, -1, -1, -1, 2, 4, 6, 8)
    private const val SILENCED = 50

    private fun le32(d: ByteArray, p: Int) = (d[p].toInt() and 255) or ((d[p + 1].toInt() and 255) shl 8) or
        ((d[p + 2].toInt() and 255) shl 16) or ((d[p + 3].toInt() and 255) shl 24)

    fun decode(data: ByteArray): SoundData? {
        if (data.size < 15 || String(data, 0, 4, Charsets.US_ASCII) != "FCMP") return null
        val payload = le32(data, 4).coerceIn(0, data.size - 14)
        val rate = le32(data, 8)
        if (payload <= 0 || rate !in 4000..48000) return null
        val out = ByteArray(payload * 4)
        var sample = 0
        var step = 0
        var o = 0
        for (i in 14 until 14 + payload) {
            val b = data[i].toInt() and 255
            for (code in intArrayOf(b and 15, b shr 4)) {
                val s = STEPS[step]
                var diff = s shr 3
                if (code and 4 != 0) diff += s
                if (code and 2 != 0) diff += s shr 1
                if (code and 1 != 0) diff += s shr 2
                sample = (if (code and 8 != 0) sample - diff else sample + diff).coerceIn(-32768, 32767)
                step = (step + ADJUST[code and 7]).coerceIn(0, 88)
                val v = if (o / 2 < SILENCED) 0 else sample
                out[o++] = v.toByte()
                out[o++] = (v shr 8).toByte()
            }
        }
        return SoundData(out, rate, 16, 1, true)
    }
}

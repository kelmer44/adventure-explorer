package adventureexplorer.audio

import adventureexplorer.model.SoundData

/**
 * The Last Express .SND audio (ScummVM engines/lastexpress/sound/mixer.cpp,
 * decodeSamples; slot.cpp for the header). A 6-byte header with the block count
 * at offset 4, then 739-byte blocks: i16 predictor, i16 step index, then 735
 * bytes holding 1470 4-bit codes, high nibble first. 22050 Hz mono.
 *
 * ScummVM's two 1424-entry tables are IMA ADPCM in disguise: for step index s
 * and code c the delta is (2 * (c & 7) + 1) * imaStep[s] / 8, negative when
 * c & 8, clamped to 16 bits, and the next index is the usual IMA adjustment.
 */
object LastExpressAdpcm {
    private const val BLOCK = 739
    private const val RATE = 22050
    private val IMA_STEPS = intArrayOf(
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66,
        73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408,
        449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630,
        9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767)
    private val ADJUST = intArrayOf(-1, -1, -1, -1, 2, 4, 6, 8)

    fun delta(step: Int, code: Int): Int {
        val d = ((2 * (code and 7) + 1) * IMA_STEPS[step] / 8).coerceAtMost(0x7FFF)
        return if (code and 8 != 0) -d else d
    }

    fun nextStep(step: Int, code: Int): Int = (step + ADJUST[code and 7]).coerceIn(0, 88)

    fun decode(data: ByteArray): SoundData? {
        if (data.size < 6 + BLOCK) return null
        val blocks = ((data[4].toInt() and 255) or ((data[5].toInt() and 255) shl 8))
            .coerceAtMost((data.size - 6) / BLOCK)
        if (blocks <= 0) return null
        val out = ByteArray(blocks * 1470 * 2)
        var o = 0
        blocks@ for (b in 0 until blocks) {
            val p = 6 + b * BLOCK
            var sample = ((data[p].toInt() and 255) or (data[p + 1].toInt() shl 8)).toShort().toInt()
            var step = ((data[p + 2].toInt() and 255) or (data[p + 3].toInt() shl 8)).toShort().toInt()
            // ScummVM stops a sound at a block with an invalid step (kSoundFlagDecodeError)
            if (step !in 0..88) break@blocks
            for (i in 0 until 735) {
                val byte = data[p + 4 + i].toInt() and 255
                for (code in intArrayOf(byte shr 4, byte and 15)) {
                    sample = (sample + delta(step, code)).coerceIn(-0x7FFF, 0x7FFF)
                    step = nextStep(step, code)
                    out[o++] = sample.toByte()
                    out[o++] = (sample shr 8).toByte()
                }
            }
        }
        if (o == 0) return null
        return SoundData(out.copyOf(o), RATE, 16, 1, true)
    }
}

package adventureexplorer.model

/**
 * Decoded audio data ready for playback via javax.sound.sampled.
 */
data class SoundData(
    val samples: ByteArray,
    val sampleRate: Int,
    val bitsPerSample: Int,   // 8 or 16
    val channels: Int,        // 1 (mono) or 2 (stereo)
    val signed: Boolean       // false for 8-bit unsigned, true for 16-bit signed
) {
    val durationMs: Long
        get() {
            val bytesPerSample = bitsPerSample / 8
            val totalFrames = samples.size / (bytesPerSample * channels)
            return (totalFrames * 1000L) / sampleRate
        }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SoundData) return false
        return sampleRate == other.sampleRate &&
               bitsPerSample == other.bitsPerSample &&
               channels == other.channels &&
               signed == other.signed &&
               samples.contentEquals(other.samples)
    }

    override fun hashCode(): Int {
        var result = samples.contentHashCode()
        result = 31 * result + sampleRate
        result = 31 * result + bitsPerSample
        result = 31 * result + channels
        result = 31 * result + signed.hashCode()
        return result
    }
}

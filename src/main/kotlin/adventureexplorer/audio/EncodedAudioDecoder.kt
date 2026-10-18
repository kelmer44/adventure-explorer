package adventureexplorer.audio

import adventureexplorer.model.SoundData
import javazoom.jl.decoder.Bitstream
import javazoom.jl.decoder.Decoder
import javazoom.jl.decoder.SampleBuffer
import java.io.ByteArrayOutputStream
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioSystem

/** Decodes individual archive clips, never an entire speech archive. */
object EncodedAudioDecoder {
    private const val MAX_PCM = 64 * 1024 * 1024

    fun decode(data: ByteArray): SoundData? = runCatching {
        when {
            data.size < 4 -> null
            data.startsWith("Creative Voice File") -> voc(data)
            data.startsWith("RIFF") -> wave(data)
            else -> mp3(data)
        }
    }.getOrNull()

    private fun ByteArray.startsWith(magic: String) = size >= magic.length &&
        magic.indices.all { this[it].toInt() and 255 == magic[it].code }
    private fun ByteArray.u8(p: Int) = this[p].toInt() and 255
    private fun ByteArray.le16(p: Int) = u8(p) or (u8(p + 1) shl 8)
    private fun ByteArray.le24(p: Int) = le16(p) or (u8(p + 2) shl 16)
    private fun ByteArray.le32(p: Int) = le16(p) or (le16(p + 2) shl 16)

    private fun voc(data: ByteArray): SoundData? {
        if (data.size < 26 || data.u8(19) != 26) return null
        var p = data.le16(20)
        if (p < 26 || p > data.size) return null
        var rate = 0; var bits = 8; var channels = 1
        var extendedRate = 0; var extendedChannels = 1
        val pcm = ByteArrayOutputStream()
        fun format(r: Int, b: Int, c: Int): Boolean {
            if (r <= 0 || b !in listOf(8, 16) || c !in 1..2) return false
            if (pcm.size() > 0 && (rate != r || bits != b || channels != c)) return false
            rate = r; bits = b; channels = c
            return true
        }
        while (p < data.size) {
            val type = data.u8(p++)
            if (type == 0) break
            if (p + 3 > data.size) return null
            val size = data.le24(p); p += 3
            if (size > data.size - p || pcm.size().toLong() + size > MAX_PCM) return null
            when (type) {
                1 -> {
                    if (size < 2 || data.u8(p + 1) != 0) return null
                    val r = if (extendedRate > 0) extendedRate else 1_000_000 / (256 - data.u8(p))
                    if (!format(r, 8, extendedChannels)) return null
                    pcm.write(data, p + 2, size - 2)
                    extendedRate = 0; extendedChannels = 1
                }
                2 -> { if (rate == 0) return null; pcm.write(data, p, size) }
                3 -> {
                    if (size < 3) return null
                    val r = 1_000_000 / (256 - data.u8(p + 2))
                    if (!format(r, 8, 1)) return null
                    pcm.write(ByteArray(data.le16(p) + 1) { 128.toByte() })
                }
                8 -> {
                    if (size < 4 || data.u8(p + 2) != 0) return null
                    extendedChannels = data.u8(p + 3) + 1
                    extendedRate = 256_000_000 / (65536 - data.le16(p)) / extendedChannels
                }
                9 -> {
                    if (size < 12) return null
                    val b = data.u8(p + 4); val codec = data.le16(p + 6)
                    if (!((b == 8 && codec == 0) || (b == 16 && codec == 4))) return null
                    if (!format(data.le32(p), b, data.u8(p + 5))) return null
                    pcm.write(data, p + 12, size - 12)
                }
                4, 5, 6, 7 -> Unit // markers, text, loop boundaries: preview one pass
                else -> return null
            }
            if (pcm.size() > MAX_PCM) return null
            p += size
        }
        if (rate == 0 || pcm.size() == 0 || pcm.size() % (channels * bits / 8) != 0) return null
        return SoundData(pcm.toByteArray(), rate, bits, channels, bits == 16)
    }

    private fun wave(data: ByteArray): SoundData? = AudioSystem.getAudioInputStream(data.inputStream()).use { input ->
        val f = input.format
        val target = AudioFormat(f.sampleRate, 16, f.channels, true, false)
        AudioSystem.getAudioInputStream(target, input).use { decoded ->
            val pcm = decoded.readNBytes(MAX_PCM + 1)
            if (pcm.isEmpty() || pcm.size > MAX_PCM) null
            else SoundData(pcm, target.sampleRate.toInt(), 16, target.channels, true)
        }
    }

    private fun mp3(data: ByteArray): SoundData? {
        val stream = Bitstream(data.inputStream())
        try {
            val decoder = Decoder()
            val pcm = ByteArrayOutputStream()
            var rate = 0; var channels = 0
            while (true) {
                val header = stream.readFrame() ?: break
                val frame = decoder.decodeFrame(header, stream) as SampleBuffer
                if (rate != 0 && (rate != frame.sampleFrequency || channels != frame.channelCount)) return null
                rate = frame.sampleFrequency; channels = frame.channelCount
                if (pcm.size().toLong() + frame.bufferLength * 2 > MAX_PCM) return null
                for (i in 0 until frame.bufferLength) {
                    val v = frame.buffer[i].toInt()
                    pcm.write(v and 255); pcm.write((v shr 8) and 255)
                }
                stream.closeFrame()
            }
            return if (pcm.size() == 0) null else SoundData(pcm.toByteArray(), rate, 16, channels, true)
        } finally { stream.close() }
    }
}

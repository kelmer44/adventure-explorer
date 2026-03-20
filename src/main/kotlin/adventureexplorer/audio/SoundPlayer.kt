package adventureexplorer.audio

import adventureexplorer.model.SoundData
import java.io.ByteArrayInputStream
import javax.sound.sampled.*

/**
 * Plays PCM audio using javax.sound.sampled.
 * Wraps a Clip for short sounds with play/pause/stop controls.
 */
class SoundPlayer {

    private var clip: Clip? = null
    private var pausePosition: Long = 0

    val isPlaying: Boolean
        get() = clip?.isRunning == true

    val isPaused: Boolean
        get() = clip != null && !clip!!.isRunning && pausePosition > 0

    val positionMs: Long
        get() = (clip?.microsecondPosition ?: 0) / 1000

    val durationMs: Long
        get() = (clip?.microsecondLength ?: 0) / 1000

    fun load(sound: SoundData) {
        stop()
        val format = AudioFormat(
            if (sound.bitsPerSample == 16) AudioFormat.Encoding.PCM_SIGNED else
                if (sound.signed) AudioFormat.Encoding.PCM_SIGNED else AudioFormat.Encoding.PCM_UNSIGNED,
            sound.sampleRate.toFloat(),
            sound.bitsPerSample,
            sound.channels,
            (sound.bitsPerSample / 8) * sound.channels,
            sound.sampleRate.toFloat(),
            false  // little-endian
        )
        val stream = AudioInputStream(
            ByteArrayInputStream(sound.samples),
            format,
            sound.samples.size.toLong() / format.frameSize
        )
        val newClip = AudioSystem.getClip()
        newClip.open(stream)
        clip = newClip
        pausePosition = 0
    }

    fun play() {
        val c = clip ?: return
        if (c.isRunning) return
        if (pausePosition > 0) {
            c.microsecondPosition = pausePosition
        }
        pausePosition = 0
        c.start()
    }

    fun pause() {
        val c = clip ?: return
        if (c.isRunning) {
            pausePosition = c.microsecondPosition
            c.stop()
        }
    }

    fun stop() {
        clip?.stop()
        clip?.close()
        clip = null
        pausePosition = 0
    }

    fun seekTo(positionMs: Long) {
        val c = clip ?: return
        val wasPlaying = c.isRunning
        c.microsecondPosition = positionMs * 1000
        pausePosition = if (wasPlaying) 0 else positionMs * 1000
    }

    fun cleanup() {
        stop()
    }
}

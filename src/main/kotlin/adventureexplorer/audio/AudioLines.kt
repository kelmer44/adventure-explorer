package adventureexplorer.audio

import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioSystem
import javax.sound.sampled.Clip
import javax.sound.sampled.DataLine
import javax.sound.sampled.SourceDataLine

/**
 * Opens audio output lines. The default lookup walks every mixer, and on macOS
 * a port mixer can fail to initialise (NullPointerException in `PortMixer`)
 * while devices change; then the mixers that offer the line are tried one by one.
 */
object AudioLines {
    fun clip(): Clip = runCatching { AudioSystem.getClip() }.getOrElse { failure ->
        fromMixers(DataLine.Info(Clip::class.java, null)) as? Clip ?: throw failure
    }

    fun sourceLine(format: AudioFormat): SourceDataLine = runCatching { AudioSystem.getSourceDataLine(format) }.getOrElse { failure ->
        fromMixers(DataLine.Info(SourceDataLine::class.java, format)) as? SourceDataLine ?: throw failure
    }

    private fun fromMixers(info: DataLine.Info): javax.sound.sampled.Line? {
        for (mixerInfo in AudioSystem.getMixerInfo()) {
            val line = runCatching {
                val mixer = AudioSystem.getMixer(mixerInfo)
                if (mixer.isLineSupported(info)) mixer.getLine(info) else null
            }.getOrNull()
            if (line != null) return line
        }
        return null
    }
}

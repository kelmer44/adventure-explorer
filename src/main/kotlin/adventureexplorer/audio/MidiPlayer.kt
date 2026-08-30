package adventureexplorer.audio

import adventureexplorer.model.MidiData
import java.io.ByteArrayInputStream
import javax.sound.midi.MidiSystem
import javax.sound.midi.Sequencer

/**
 * Plays standard MIDI data using javax.sound.midi's default sequencer, which is
 * auto-connected to the system's own synthesizer/soundbank - no bespoke synth.
 */
class MidiPlayer {

    private var sequencer: Sequencer? = null

    val isPlaying: Boolean
        get() = sequencer?.isRunning == true

    val positionMs: Long
        get() = (sequencer?.microsecondPosition ?: 0) / 1000

    val durationMs: Long
        get() = (sequencer?.microsecondLength ?: 0) / 1000

    fun load(midi: MidiData) {
        stop()
        val seq = MidiSystem.getSequencer(true) ?: return
        seq.open()
        seq.sequence = MidiSystem.getSequence(ByteArrayInputStream(midi.bytes))
        sequencer = seq
    }

    fun play() {
        sequencer?.start()
    }

    fun pause() {
        sequencer?.stop()
    }

    fun stop() {
        sequencer?.let {
            it.stop()
            it.microsecondPosition = 0
            it.close()
        }
        sequencer = null
    }

    fun seekTo(positionMs: Long) {
        sequencer?.microsecondPosition = positionMs * 1000
    }

    fun cleanup() {
        stop()
    }
}

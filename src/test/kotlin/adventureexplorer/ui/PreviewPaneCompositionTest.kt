package adventureexplorer.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import adventureexplorer.audio.AdlibPlayback
import adventureexplorer.model.MidiData
import adventureexplorer.model.SoundData
import org.junit.Test

/**
 * Early returns from inline composable lambdas unbalance this Compose version's
 * group stack ("Index -1 out of bounds" in Stack.pop on recomposition). Switch
 * the preview between plain and AdLib-choice resources to recompose every branch.
 */
class PreviewPaneCompositionTest {
    private val sound = SoundData(ByteArray(44_100), 44_100, 16, 1, true)
    private val midi = MidiData(
        byteArrayOf(0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96,
            0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 4, 0, 0xFF.toByte(), 0x2F, 0)
    )

    private data class Shown(val text: String? = null, val sound: SoundData? = null, val midi: MidiData? = null, val choice: Boolean = false)

    @Test fun `switching between AdLib choice and plain resources recomposes cleanly`() {
        var shown by mutableStateOf(Shown(sound = sound, choice = true))
        val scene = ImageComposeScene(900, 600, Density(1f)) {
            PreviewPane(
                image = null, onExportPng = {}, paletteImage = null, paletteOptions = emptyList(),
                selectedPaletteIndex = -1, onPaletteSelected = {}, description = "test",
                textContent = shown.text, canExportPalette = false, onExportPaletteBin = {}, frames = null,
                frameDelayMs = 100, onExportFrame = {}, onExportAllFrames = {},
                soundData = shown.sound, onExportSoundWav = {}, midiData = shown.midi, onExportMidi = {},
                playbackChoice = shown.choice,
                adlibPlayback = if (shown.midi != null) AdlibPlayback.MIDI else AdlibPlayback.OPL,
            )
        }
        try {
            var time = 0L
            val states = listOf(
                Shown(sound = sound, choice = true), Shown(text = "plain"), Shown(midi = midi, choice = true),
                Shown(sound = sound, choice = true), Shown(sound = sound), Shown(midi = midi), Shown(text = "end"),
            )
            for (state in states) {
                shown = state
                scene.render(time); time += 50_000_000
                scene.render(time); time += 50_000_000
            }
        } finally { scene.close() }
    }
}

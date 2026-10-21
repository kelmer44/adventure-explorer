package adventureexplorer.model

import java.awt.image.BufferedImage

/**
 * Data returned when loading a specific resource from a Lua engine script.
 */
data class ResourceData(
    val type: String,               // "image", "composite", "sound", "text", "animation", etc.
    val image: BufferedImage?,       // non-null for image resources
    val description: String?,        // human-readable description
    val textContent: String? = null, // non-null for text resources
    val paletteImage: BufferedImage? = null, // companion 256×256 palette swatch
    val paletteColors: Int = 256,    // number of meaningful colors in palette (16 or 256)
    val frames: List<BufferedImage>? = null, // non-null for animation resources
    val frameDelayMs: Int = 100,     // milliseconds per frame for animation playback
    val soundData: SoundData? = null, // non-null for sound resources
    val midiData: MidiData? = null,  // non-null for midi resources
    val modelData: ModelData? = null, // static 3D geometry
    val layers: List<CompositeLayer>? = null // non-null for composite resources; image is the flattened default
)

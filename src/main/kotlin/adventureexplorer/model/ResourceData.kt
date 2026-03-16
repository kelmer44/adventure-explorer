package adventureexplorer.model

import java.awt.image.BufferedImage

/**
 * Data returned when loading a specific resource from a Lua engine script.
 */
data class ResourceData(
    val type: String,               // "image", "sound", "text", etc.
    val image: BufferedImage?,       // non-null for image resources
    val description: String?,        // human-readable description
    val textContent: String? = null, // non-null for text resources
    val paletteImage: BufferedImage? = null, // companion 256×256 palette swatch
    val paletteColors: Int = 256     // number of meaningful colors in palette (16 or 256)
)

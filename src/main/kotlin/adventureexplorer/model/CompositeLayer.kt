package adventureexplorer.model

import java.awt.image.BufferedImage

/**
 * One positioned image in a composite resource (e.g. a room background plus its
 * object images). Layers are drawn in list order, so later layers sit on top.
 */
data class CompositeLayer(
    val name: String,
    val image: BufferedImage,
    val x: Int = 0,
    val y: Int = 0,
    val group: String = "Layers",
    val visible: Boolean = true
) {
    fun contains(px: Int, py: Int): Boolean =
        px >= x && py >= y && px < x + image.width && py < y + image.height
}

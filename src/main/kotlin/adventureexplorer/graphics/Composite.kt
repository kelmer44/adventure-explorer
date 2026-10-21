package adventureexplorer.graphics

import adventureexplorer.model.CompositeLayer
import java.awt.image.BufferedImage

object Composite {
    /** Canvas size covering every layer, or the explicit size when one is given. */
    fun canvasSize(layers: List<CompositeLayer>, width: Int? = null, height: Int? = null): Pair<Int, Int> {
        val w = width ?: layers.maxOfOrNull { it.x + it.image.width } ?: 1
        val h = height ?: layers.maxOfOrNull { it.y + it.image.height } ?: 1
        return w.coerceAtLeast(1) to h.coerceAtLeast(1)
    }

    /** Draw the layers where [isVisible] holds, in order, onto a transparent canvas. */
    fun flatten(
        layers: List<CompositeLayer>,
        width: Int,
        height: Int,
        isVisible: (Int) -> Boolean = { layers[it].visible }
    ): BufferedImage {
        val out = BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB)
        val g = out.createGraphics()
        try {
            layers.forEachIndexed { i, layer -> if (isVisible(i)) g.drawImage(layer.image, layer.x, layer.y, null) }
        } finally {
            g.dispose()
        }
        return out
    }
}

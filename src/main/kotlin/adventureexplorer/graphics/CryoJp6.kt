package adventureexplorer.graphics

import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import javax.imageio.ImageIO
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.sin

/**
 * Aztec: The Curse in the Heart of the City of Gold `.JP6` panoramas: a cube map stored as six
 * 512x512 JPEGs. ScummVM has no Aztec support, so the layout was recovered from the data:
 *
 * ```
 * u8[16] "JPEG6   CRYO99XG"
 * u32le  size[8]            six JPEG sizes, then two zeros
 * jpeg   face[6]            back to back from byte 48
 * ```
 *
 * Faces 0, 5, 1 and 4 are the four walls in turn left to right (turning clockwise seen from
 * above), 2 is the sky and 3 is the floor. The order and the sky/floor rotations were found by
 * matching the colours along shared edges: face 0's right edge continues into face 5's left edge,
 * 5 into 1, 1 into 4 and 4 into 0; face 0's top edge meets the bottom of the sky, and its bottom
 * edge the top of the floor, all without mirroring.
 */
object CryoJp6 {
    private const val HEADER = 48
    private val MAGIC = "JPEG6   CRYO99XG".toByteArray(Charsets.ISO_8859_1)

    /** Wall order used for the panorama: front, right, back, left. */
    private val WALLS = intArrayOf(0, 5, 1, 4)

    fun isJp6(data: ByteArray): Boolean =
        data.size > HEADER && MAGIC.indices.all { data[it] == MAGIC[it] }

    fun faces(data: ByteArray): List<BufferedImage>? {
        if (!isJp6(data)) return null
        var pos = HEADER
        val out = ArrayList<BufferedImage>(6)
        for (i in 0 until 6) {
            val size = (data[16 + i * 4].toLong() and 255) or ((data[17 + i * 4].toLong() and 255) shl 8) or
                ((data[18 + i * 4].toLong() and 255) shl 16) or ((data[19 + i * 4].toLong() and 255) shl 24)
            if (size <= 0 || pos + size > data.size) return null
            val face = try {
                ImageIO.read(ByteArrayInputStream(data, pos, size.toInt()))
            } catch (e: Exception) { null } ?: return null
            out += toRgb(face)
            pos += size.toInt()
        }
        return out
    }

    private fun toRgb(src: BufferedImage): BufferedImage {
        if (src.type == BufferedImage.TYPE_INT_RGB) return src
        val out = BufferedImage(src.width, src.height, BufferedImage.TYPE_INT_RGB)
        val g = out.createGraphics()
        g.drawImage(src, 0, 0, null)
        g.dispose()
        return out
    }

    /** Cross layout: sky above the front wall, floor below it, the other walls to either side. */
    fun net(faces: List<BufferedImage>): BufferedImage {
        val n = faces[0].width
        val out = BufferedImage(n * 4, n * 3, BufferedImage.TYPE_INT_RGB)
        val g = out.createGraphics()
        g.drawImage(faces[4], 0, n, null)
        g.drawImage(faces[0], n, n, null)
        g.drawImage(faces[5], 2 * n, n, null)
        g.drawImage(faces[1], 3 * n, n, null)
        g.drawImage(faces[2], n, 0, null)
        g.drawImage(faces[3], n, 2 * n, null)
        g.dispose()
        return out
    }

    private class Basis(val f: DoubleArray, val r: DoubleArray, val u: DoubleArray)

    private val BASES: Array<Basis> = run {
        val wallYaw = mapOf(0 to 0.0, 5 to PI / 2, 1 to PI, 4 to 3 * PI / 2)
        Array(6) { face ->
            when (face) {
                2 -> Basis(doubleArrayOf(0.0, 1.0, 0.0), doubleArrayOf(1.0, 0.0, 0.0), doubleArrayOf(0.0, 0.0, -1.0))
                3 -> Basis(doubleArrayOf(0.0, -1.0, 0.0), doubleArrayOf(1.0, 0.0, 0.0), doubleArrayOf(0.0, 0.0, 1.0))
                else -> {
                    val t = wallYaw.getValue(face)
                    Basis(doubleArrayOf(sin(t), 0.0, cos(t)), doubleArrayOf(cos(t), 0.0, -sin(t)), doubleArrayOf(0.0, 1.0, 0.0))
                }
            }
        }
    }

    /**
     * Equirectangular panorama, [width] x [height] (2:1). The centre column looks along the front
     * wall (face 0) and longitude grows towards face 5, so the picture reads left to right as
     * walls 1, 4, 0, 5, 1.
     */
    fun panorama(faces: List<BufferedImage>, width: Int = 2048, height: Int = 1024): BufferedImage {
        val n = faces[0].width
        val src = faces.map { f -> IntArray(n * n).also { f.getRGB(0, 0, n, n, it, 0, n) } }
        val out = IntArray(width * height)
        for (y in 0 until height) {
            val lat = (0.5 - (y + 0.5) / height) * PI
            val cl = cos(lat)
            val dy = sin(lat)
            for (x in 0 until width) {
                val lon = ((x + 0.5) / width - 0.5) * 2 * PI
                val dx = cl * sin(lon)
                val dz = cl * cos(lon)
                var best = 0
                var bestDot = -2.0
                for (f in 0 until 6) {
                    val b = BASES[f].f
                    val dot = dx * b[0] + dy * b[1] + dz * b[2]
                    if (dot > bestDot) { bestDot = dot; best = f }
                }
                val b = BASES[best]
                val s = (dx * b.r[0] + dy * b.r[1] + dz * b.r[2]) / bestDot
                val t = (dx * b.u[0] + dy * b.u[1] + dz * b.u[2]) / bestDot
                out[y * width + x] = sample(src[best], n, (s + 1) / 2 * n - 0.5, (1 - t) / 2 * n - 0.5)
            }
        }
        val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
        image.setRGB(0, 0, width, height, out, 0, width)
        return image
    }

    private fun sample(px: IntArray, n: Int, fx: Double, fy: Double): Int {
        val x0 = floor(fx).toInt()
        val y0 = floor(fy).toInt()
        val ax = fx - x0
        val ay = fy - y0
        fun at(x: Int, y: Int) = px[y.coerceIn(0, n - 1) * n + x.coerceIn(0, n - 1)]
        val c00 = at(x0, y0); val c10 = at(x0 + 1, y0); val c01 = at(x0, y0 + 1); val c11 = at(x0 + 1, y0 + 1)
        var rgb = 0
        for (shift in intArrayOf(16, 8, 0)) {
            val top = ((c00 shr shift) and 255) * (1 - ax) + ((c10 shr shift) and 255) * ax
            val bottom = ((c01 shr shift) and 255) * (1 - ax) + ((c11 shr shift) and 255) * ax
            rgb = rgb or ((top * (1 - ay) + bottom * ay + 0.5).toInt().coerceIn(0, 255) shl shift)
        }
        return rgb
    }

    /**
     * Renders a Lua-facing view: "panorama" (equirectangular), "net" (cube cross) or "0".."5"
     * for one face. Returns null for unreadable data or an unknown mode.
     */
    fun render(data: ByteArray, mode: String): BufferedImage? {
        val faces = faces(data) ?: return null
        return when (mode) {
            "panorama" -> panorama(faces)
            "net" -> net(faces)
            else -> mode.toIntOrNull()?.takeIf { it in 0..5 }?.let { faces[it] }
        }
    }
}

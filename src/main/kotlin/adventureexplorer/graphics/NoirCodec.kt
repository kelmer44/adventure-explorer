package adventureexplorer.graphics

import java.awt.image.BufferedImage

/** Tinsel 3 MSB-first LZSS and little-endian RGB565 images. */
object NoirCodec {
    fun unpack(input: ByteArray, size: Int): ByteArray {
        require(size in 1..(32 * 1024 * 1024))
        val output = ByteArray(size)
        val dictionary = ByteArray(4096)
        var bit = 0
        var written = 0
        var cursor = 1
        fun bits(count: Int): Int {
            require(bit.toLong() + count <= input.size.toLong() * 8) { "Truncated Noir LZSS" }
            var value = 0
            repeat(count) {
                value = (value shl 1) or ((input[bit / 8].toInt() ushr (7 - bit % 8)) and 1)
                bit++
            }
            return value
        }
        fun emit(value: Byte) {
            require(written < size) { "Noir LZSS exceeds index size" }
            output[written++] = value
            dictionary[cursor] = value
            cursor = (cursor + 1) and 4095
        }
        while (true) {
            if (bits(1) == 1) emit(bits(8).toByte()) else {
                val offset = bits(12)
                if (offset == 0) break
                val length = bits(4) + 2
                repeat(length) { emit(dictionary[(offset + it) and 4095]) }
            }
        }
        require(written == size) { "Noir LZSS size mismatch: $written / $size" }
        return output
    }

    fun image(data: ByteArray, offset: Int, width: Int, height: Int, rle: Boolean): BufferedImage {
        require(width in 1..4096 && height in 1..4096 && width.toLong() * height <= 4_194_304)
        require(offset in data.indices)
        var cursor = offset
        fun word(): Int {
            require(cursor <= data.size - 2) { "Truncated Noir image" }
            val value = (data[cursor].toInt() and 255) or ((data[cursor + 1].toInt() and 255) shl 8)
            cursor += 2
            return value
        }
        fun color(value: Int): Int {
            if (value == 0xF81F) return 0
            val r = value ushr 11
            val g = (value ushr 5) and 63
            val b = value and 31
            return (0xFF shl 24) or (((r shl 3) or (r ushr 2)) shl 16) or
                (((g shl 2) or (g ushr 4)) shl 8) or ((b shl 3) or (b ushr 2))
        }
        val pixels = IntArray(width * height)
        for (y in 0 until height) {
            var x = 0
            while (x < width) {
                val code = if (rle) word() else 1
                val length = if (rle) code and 0x7FFF else 1
                require(length > 0 && length <= width - x) { "Invalid Noir RLE row" }
                if (rle && code and 0x8000 != 0) {
                    val c = color(word())
                    repeat(length) { pixels[y * width + x++] = c }
                } else repeat(length) { pixels[y * width + x++] = color(word()) }
            }
        }
        return BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB).apply {
            setRGB(0, 0, width, height, pixels, 0, width)
        }
    }
}

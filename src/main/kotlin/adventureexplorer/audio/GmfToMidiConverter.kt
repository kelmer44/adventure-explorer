package adventureexplorer.audio

/** Simon 1 DOS GMF: seven-byte header, SMF events, and operandless pitch bends.
 * Reference: ScummVM engines/agos/midiparser_gmf.cpp.
 */
object GmfToMidiConverter {
    fun convert(data: ByteArray): ByteArray? = runCatching {
        require(data.size > 7 && String(data, 0, 3, Charsets.US_ASCII) == "GMF")
        var p = 7
        fun byte(): Int { require(p < data.size); return data[p++].toInt() and 255 }
        fun vlq(): Int {
            var value = 0
            repeat(4) {
                val b = byte(); value = (value shl 7) or (b and 127)
                if (b < 128) return value
            }
            error("Invalid GMF delta")
        }
        val speed = data[5].toInt() and 255
        val tempo = if (speed < 6) 330000 + (speed - 2) * 105000 else 750000 + (speed - 6) * 125000
        require(tempo in 1..0xFFFFFF)
        val events = mutableListOf(StandardMidiWriter.TimedEvent(0, -1,
            byteArrayOf(0xFF.toByte(), 0x51, 3, (tempo shr 16).toByte(), (tempo shr 8).toByte(), tempo.toByte())))
        var tick = 0L; var running = 0
        while (p < data.size) {
            if (data.size - p <= 5 && (p until data.size).all { data[it] == 0.toByte() }) break
            require(events.size < 200000)
            tick += vlq()
            var status = byte()
            if (status < 128) { require(running in 0x80..0xEF); p--; status = running }
            if (status in 0x80..0xEF) running = status
            when {
                status and 0xF0 == 0xE0 -> Unit // Original files omit both pitch bend operands.
                status in 0x80..0xDF -> {
                    val n = if (status and 0xE0 == 0xC0) 1 else 2
                    val body = ByteArray(n + 1); body[0] = status.toByte()
                    for (i in 1..n) { val b = byte(); require(b < 128); body[i] = b.toByte() }
                    events += StandardMidiWriter.TimedEvent(tick, 0, body)
                }
                status == 0xFF -> {
                    val type = byte(); val lengthStart = p; val size = vlq()
                    require(size <= data.size - p)
                    if (type == 0x2F) break
                    events += StandardMidiWriter.TimedEvent(tick, 0,
                        byteArrayOf(0xFF.toByte(), type.toByte()) + data.copyOfRange(lengthStart, p + size))
                    p += size; running = 0
                }
                status == 0xF0 || status == 0xF7 -> {
                    val lengthStart = p; val size = vlq(); require(size <= data.size - p)
                    events += StandardMidiWriter.TimedEvent(tick, 0,
                        byteArrayOf(status.toByte()) + data.copyOfRange(lengthStart, p + size))
                    p += size; running = 0
                }
                else -> error("Unsupported GMF event")
            }
        }
        StandardMidiWriter.build(192, events)
    }.getOrNull()
}

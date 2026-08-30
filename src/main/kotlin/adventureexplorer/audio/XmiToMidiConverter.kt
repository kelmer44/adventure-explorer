package adventureexplorer.audio

/**
 * Converts an XMIDI (.xmi) resource - the ID/AIL/Miles Sound System MIDI variant
 * used by many DOS-era games - into a standard MIDI file. XMI note-on events embed
 * their own duration instead of a separate note-off, and delays are encoded as a
 * sum of 7-bit values rather than standard MIDI's concatenated VLQ; both quirks
 * are unwound here so the result is playable standard MIDI.
 */
object XmiToMidiConverter {
    // Miles Sound System's fixed clock: 120 ticks/second at the default 120 BPM
    // tempo (500000 us/quarter), i.e. 60 ticks per quarter note. XMI ticks map
    // 1:1 onto ticks at this division, so no time rescaling is required.
    private const val DIVISION = 60
    private const val MAX_EVENTS = 200_000

    fun convert(data: ByteArray): ByteArray? {
        val evnt = findEvntChunk(data) ?: return null
        val events = parseEvnt(data, evnt.first, evnt.second) ?: return null
        if (events.isEmpty()) return null
        return StandardMidiWriter.build(DIVISION, events)
    }

    // ── IFF chunk scanning ──────────────────────────────────────────────

    /** Returns (start, size) of the first EVNT chunk's payload found anywhere in [data]. */
    private fun findEvntChunk(data: ByteArray): Pair<Int, Int>? {
        val direct = scanChunks(data, 0, data.size)
        if (direct != null) return direct
        // Fall back to treating the whole buffer as an already-unwrapped EVNT stream.
        return if (data.size > 8) 0 to data.size else null
    }

    private fun scanChunks(data: ByteArray, start: Int, end: Int): Pair<Int, Int>? {
        var pos = start
        while (pos + 8 <= end) {
            val id = idAt(data, pos)
            val size = u32be(data, pos + 4)
            val payloadStart = pos + 8
            if (size < 0 || payloadStart + size > end) return null
            when (id) {
                "EVNT" -> return payloadStart to size
                "FORM", "CAT " -> {
                    // Payload starts with a 4-char type tag, then nested chunks.
                    val nested = scanChunks(data, payloadStart + 4, payloadStart + size)
                    if (nested != null) return nested
                }
            }
            pos = payloadStart + size + (size and 1) // chunks are word-aligned
        }
        return null
    }

    private fun idAt(data: ByteArray, pos: Int): String =
        String(data, pos, 4, Charsets.US_ASCII)

    // ── EVNT event stream parsing ─────────────────────────────────────────

    private fun parseEvnt(data: ByteArray, start: Int, size: Int): List<StandardMidiWriter.TimedEvent>? {
        val end = start + size
        var pos = start
        var tick = 0L
        val events = mutableListOf<StandardMidiWriter.TimedEvent>()

        while (pos < end && events.size < MAX_EVENTS) {
            val delay = readXmiDelay(data, pos, end)
            tick += delay.first
            pos = delay.second
            if (pos >= end) break

            val status = u8(data, pos)
            if (status < 0x80) break // desynced: running status is not valid in XMI
            pos++
            val channel = status and 0x0F

            when (status and 0xF0) {
                0x80 -> {
                    if (pos + 1 >= end) break
                    val note = u8(data, pos); val vel = u8(data, pos + 1); pos += 2
                    events += noteEvent(tick, 0x80, channel, note, vel)
                }
                0x90 -> {
                    if (pos + 1 >= end) break
                    val note = u8(data, pos)
                    val velocity = u8(data, pos + 1)
                    pos += 2
                    if (velocity == 0) {
                        events += noteEvent(tick, 0x80, channel, note, 0)
                    } else {
                        val duration = readStandardVlq(data, pos, end) ?: break
                        pos = duration.second
                        events += noteEvent(tick, 0x90, channel, note, velocity)
                        events += noteEvent(tick + duration.first, 0x80, channel, note, 0)
                    }
                }
                0xA0 -> { if (pos + 1 >= end) break; val n = u8(data, pos); val v = u8(data, pos + 1); pos += 2
                    events += StandardMidiWriter.TimedEvent(tick, 1, byteArrayOf((0xA0 or channel).toByte(), n.toByte(), v.toByte())) }
                0xB0 -> { if (pos + 1 >= end) break; val c = u8(data, pos); val v = u8(data, pos + 1); pos += 2
                    events += StandardMidiWriter.TimedEvent(tick, 1, byteArrayOf((0xB0 or channel).toByte(), c.toByte(), v.toByte())) }
                0xC0 -> { if (pos >= end) break; val p = u8(data, pos); pos++
                    events += StandardMidiWriter.TimedEvent(tick, 1, byteArrayOf((0xC0 or channel).toByte(), p.toByte())) }
                0xD0 -> { if (pos >= end) break; val p = u8(data, pos); pos++
                    events += StandardMidiWriter.TimedEvent(tick, 1, byteArrayOf((0xD0 or channel).toByte(), p.toByte())) }
                0xE0 -> { if (pos + 1 >= end) break; val lo = u8(data, pos); val hi = u8(data, pos + 1); pos += 2
                    events += StandardMidiWriter.TimedEvent(tick, 1, byteArrayOf((0xE0 or channel).toByte(), lo.toByte(), hi.toByte())) }
                0xF0 -> {
                    if (status == 0xFF) {
                        if (pos >= end) break
                        val metaType = u8(data, pos); pos++
                        val len = readStandardVlq(data, pos, end) ?: break
                        pos = len.second
                        val metaData = data.copyOfRange(pos, (pos + len.first).coerceAtMost(end))
                        pos += len.first
                        if (metaType == 0x2F) break // end of track
                        val bytes = byteArrayOf(0xFF.toByte(), metaType.toByte()) + varLenPrefix(metaData.size) + metaData
                        events += StandardMidiWriter.TimedEvent(tick, 1, bytes)
                    } else {
                        // Sysex (0xF0/0xF7): length-prefixed data, drop for this preview.
                        val len = readStandardVlq(data, pos, end) ?: break
                        pos = len.second
                        pos = (pos + len.first).coerceAtMost(end)
                    }
                }
                else -> break
            }
        }

        return events
    }

    private fun noteEvent(tick: Long, statusHi: Int, channel: Int, note: Int, velocity: Int) =
        StandardMidiWriter.TimedEvent(
            tick, if (statusHi == 0x90) 2 else 0,
            byteArrayOf((statusHi or channel).toByte(), note.toByte(), velocity.coerceIn(0, 127).toByte())
        )

    /** XMI's own delay encoding: a sum of 7-bit values, terminated by any byte != 0x7F. */
    private fun readXmiDelay(data: ByteArray, start: Int, end: Int): Pair<Long, Int> {
        var pos = start
        var delay = 0L
        while (pos < end) {
            val b = u8(data, pos)
            if (b >= 0x80) break
            delay += b
            pos++
            if (b != 0x7F) break
        }
        return delay to pos
    }

    /** Standard MIDI-style variable length quantity (concatenated 7-bit groups). */
    private fun readStandardVlq(data: ByteArray, start: Int, end: Int): Pair<Int, Int>? {
        var pos = start
        var value = 0
        var count = 0
        while (pos < end && count < 4) {
            val b = u8(data, pos); pos++
            value = (value shl 7) or (b and 0x7F)
            count++
            if (b and 0x80 == 0) return value to pos
        }
        return null
    }

    private fun varLenPrefix(length: Int): ByteArray {
        var v = length
        val groups = mutableListOf(v and 0x7F)
        v = v shr 7
        while (v > 0) {
            groups.add((v and 0x7F) or 0x80)
            v = v shr 7
        }
        return groups.asReversed().map { it.toByte() }.toByteArray()
    }

    private fun u8(data: ByteArray, offset: Int): Int = data[offset].toInt() and 0xFF
    private fun u32be(data: ByteArray, offset: Int): Int =
        (u8(data, offset) shl 24) or (u8(data, offset + 1) shl 16) or (u8(data, offset + 2) shl 8) or u8(data, offset + 3)
}

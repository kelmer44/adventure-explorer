package adventureexplorer.audio

/**
 * Converts a Creative Music Format ("CTMF"/CMF) resource into a standard MIDI
 * file. CMF instrument data describes OPL2 register values with no relation to
 * General MIDI patches, so rather than emulating the original AdLib sound we
 * simply forward CMF program changes/notes as standard MIDI events and let the
 * playback system (its own synth/soundbank) decide how to render them.
 */
object CmfToMidiConverter {
    private const val INSTRUMENT_SIZE = 16
    private const val PERCUSSION_FIRST_CHANNEL = 11 // MIDI channel 12 (0-based 11) starts rhythm instruments
    private const val DRUM_MIDI_CHANNEL = 9          // GM percussion channel (channel 10)
    private const val SPARE_MELODIC_CHANNEL = 15     // reroute source channel 9 to avoid the GM drum channel

    // CMF rhythm channel -> a plausible General MIDI percussion key (channel 10).
    private val DRUM_NOTE = mapOf(
        11 to 36, // Bass Drum 1
        12 to 38, // Acoustic Snare
        13 to 45, // Low Tom
        14 to 49, // Crash Cymbal 1
        15 to 42, // Closed Hi-Hat
    )

    fun convert(data: ByteArray): ByteArray? {
        if (data.size < 40 || data[0] != 'C'.code.toByte() || data[1] != 'T'.code.toByte() ||
            data[2] != 'M'.code.toByte() || data[3] != 'F'.code.toByte()
        ) return null

        val version = u16le(data, 4)
        val instOffset = u16le(data, 6)
        val musicOffset = u16le(data, 8)
        val ticksPerQuarter = u16le(data, 10).coerceAtLeast(1)
        val instrumentCount = if (version >= 0x0101) u16le(data, 36) else u8(data, 36)
        if (instOffset <= 0 || instOffset >= data.size) return null
        if (musicOffset <= 0 || musicOffset >= data.size) return null
        if (instrumentCount !in 1..256) return null
        if (instOffset + instrumentCount * INSTRUMENT_SIZE > data.size) return null

        val events = parseEvents(data, musicOffset) ?: return null
        if (events.isEmpty()) return null
        return StandardMidiWriter.build(ticksPerQuarter, events)
    }

    private fun parseEvents(data: ByteArray, musicOffset: Int): List<StandardMidiWriter.TimedEvent>? {
        var pos = musicOffset
        val size = data.size
        val events = mutableListOf<StandardMidiWriter.TimedEvent>()
        var ticks = 0L
        var runningStatus = 0
        var percussion = false
        var ended = false

        while (pos < size && !ended) {
            val vlq = readVlq(data, pos) ?: break
            ticks += vlq.first
            pos = vlq.second
            if (pos >= size) break

            var status = u8(data, pos)
            if (status >= 0x80) {
                pos++
                runningStatus = status
            } else {
                status = runningStatus
                if (status == 0) break
            }
            val channel = status and 0x0F

            when (status and 0xF0) {
                0x80 -> {
                    if (pos + 1 >= size) break
                    val note = u8(data, pos); pos += 2
                    emitNoteEvent(events, ticks, channel, note, 0, percussion, isOn = false)
                }
                0x90 -> {
                    if (pos + 1 >= size) break
                    val note = u8(data, pos)
                    val velocity = u8(data, pos + 1)
                    pos += 2
                    emitNoteEvent(events, ticks, channel, note, velocity, percussion, isOn = velocity != 0)
                }
                0xA0 -> { if (pos + 1 >= size) break; pos += 2 } // aftertouch, ignored
                0xB0 -> {
                    if (pos + 1 >= size) break
                    val controller = u8(data, pos)
                    val value = u8(data, pos + 1)
                    pos += 2
                    if (controller == 0x67) percussion = value != 0
                    // Other CMF-only controllers (0x63 depth, 0x66 marker, 0x68/0x69 transpose)
                    // have no standard MIDI meaning and are dropped.
                }
                0xC0 -> {
                    if (pos >= size) break
                    val program = u8(data, pos); pos++
                    if (channel < PERCUSSION_FIRST_CHANNEL) {
                        val outChannel = remapChannel(channel)
                        events += StandardMidiWriter.TimedEvent(
                            ticks, 0, byteArrayOf((0xC0 or outChannel).toByte(), program.toByte())
                        )
                    }
                }
                0xD0 -> { if (pos >= size) break; pos++ } // channel pressure, ignored
                0xE0 -> { if (pos + 1 >= size) break; pos += 2 } // pitch bend - real CMF players ignore it too
                0xF0 -> {
                    if (status == 0xFF) {
                        if (pos >= size) break
                        val metaType = u8(data, pos); pos++
                        val len = readVlq(data, pos) ?: break
                        pos = len.second
                        if (metaType == 0x2F) ended = true
                        pos = (pos + len.first.toInt()).coerceAtMost(size)
                    } else {
                        val len = readVlq(data, pos) ?: break
                        pos = len.second
                        pos = (pos + len.first.toInt()).coerceAtMost(size)
                    }
                }
                else -> break
            }
        }

        return events
    }

    private fun emitNoteEvent(
        events: MutableList<StandardMidiWriter.TimedEvent>,
        tick: Long, channel: Int, note: Int, velocity: Int, percussion: Boolean, isOn: Boolean
    ) {
        val isDrum = percussion && channel >= PERCUSSION_FIRST_CHANNEL
        val outChannel = if (isDrum) DRUM_MIDI_CHANNEL else remapChannel(channel)
        val outNote = if (isDrum) (DRUM_NOTE[channel] ?: 38) else note
        val status = (if (isOn) 0x90 else 0x80) or outChannel
        val priority = if (isOn) 1 else 0
        events += StandardMidiWriter.TimedEvent(
            tick, priority, byteArrayOf(status.toByte(), outNote.toByte(), velocity.coerceIn(0, 127).toByte())
        )
    }

    // MIDI channel 10 (index 9) is reserved for percussion in General MIDI; CMF has
    // no such reservation outside rhythm mode, so give that channel a spare slot.
    private fun remapChannel(channel: Int): Int = if (channel == DRUM_MIDI_CHANNEL) SPARE_MELODIC_CHANNEL else channel

    private fun readVlq(data: ByteArray, start: Int): Pair<Long, Int>? {
        var pos = start
        var value = 0L
        var count = 0
        while (pos < data.size && count < 4) {
            val b = u8(data, pos); pos++
            value = (value shl 7) or (b and 0x7F).toLong()
            count++
            if (b and 0x80 == 0) return value to pos
        }
        return null
    }

    private fun u8(data: ByteArray, offset: Int): Int = data[offset].toInt() and 0xFF
    private fun u16le(data: ByteArray, offset: Int): Int = u8(data, offset) or (u8(data, offset + 1) shl 8)
}

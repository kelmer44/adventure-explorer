package adventureexplorer.audio.imuse

/**
 * One iMUSE MIDI song: the payload of a SCUMM V5/V6 `SOU ` device chunk
 * (`ROL `, `ADL `, `GMD `, `SPK `, `MIDI`): an optional `MDhd` start-parameter
 * header, then a standard MIDI file whose tracks carry iMUSE SysEx
 * (manufacturer 0x7D) for loops, hooks, markers and instruments.
 *
 * Layout and semantics follow ScummVM (`engines/scumm/imuse/imuse_player.cpp`,
 * `sysex_scumm.cpp`; GPLv2+).
 */
class ImuseSong private constructor(
    /** Device chunk tag, e.g. "ADL ". */
    val tag: String,
    val ppqn: Int,
    val tracks: List<List<Event>>,
    /** MDhd start parameters (priority, volume, pan, transpose, detune, speed) or null. */
    val start: StartParameters?,
    /** Every hook, marker and loop found in the song, in track/time order. */
    val catalogue: List<CatalogueEntry>,
    /** The standard MIDI file, for export and plain sequencer playback. */
    val smf: ByteArray,
) {
    /** Roland tracks use MT-32 program numbers. */
    val isMt32: Boolean get() = tag == "ROL "
    /** MIDI devices take program changes; AdLib and PC speaker load instrument definitions. */
    val isMidi: Boolean get() = tag != "ADL " && tag != "SPK "
    val supportsPercussion: Boolean get() = tag == "ROL " || tag == "GMD " || tag == "MIDI"
    val isAdlib: Boolean get() = tag == "ADL "

    sealed class Event(val tick: Long) {
        class Channel(tick: Long, val status: Int, val data1: Int, val data2: Int) : Event(tick)
        class SysEx(tick: Long, val bytes: ByteArray) : Event(tick)
        class Meta(tick: Long, val type: Int, val bytes: ByteArray) : Event(tick)
    }

    data class StartParameters(
        val priority: Int, val volume: Int, val pan: Int, val transpose: Int, val detune: Int, val speed: Int,
    )

    enum class HookKind(val label: String, val sysex: Int) {
        JUMP("Jump", 48),
        TRANSPOSE("Transpose", 49),
        PART_ON_OFF("Part on/off", 50),
        PART_VOLUME("Part volume", 51),
        PART_PROGRAM("Part instrument", 52),
        PART_TRANSPOSE("Part transpose", 53),
    }

    /** A position in iMUSE terms: track index, beat (from 1) and tick within the beat (480 per beat). */
    data class Position(val track: Int, val beat: Int, val tick: Int) {
        override fun toString() = if (tick == 0) "track $track beat $beat" else "track $track beat $beat.$tick"
    }

    sealed class CatalogueEntry(val at: Position) {
        /** [id] 0 fires every time; other ids fire only once armed (ids below 0x80 disarm after firing). */
        class Hook(at: Position, val kind: HookKind, val id: Int, val channel: Int, val detail: String, val target: Position? = null) : CatalogueEntry(at)
        class Marker(at: Position, val id: Int) : CatalogueEntry(at)
        class Loop(at: Position, val count: Int, val from: Position, val to: Position) : CatalogueEntry(at)
    }

    /** Distinct armable hooks: kind, channel (or -1) and id, with every place they occur. */
    val armableHooks: Map<Triple<HookKind, Int, Int>, List<CatalogueEntry.Hook>> by lazy {
        catalogue.filterIsInstance<CatalogueEntry.Hook>().filter { it.id != 0 }
            .groupBy { Triple(it.kind, if (it.kind.isPartHook) it.channel else -1, it.id) }
    }

    companion object {
        const val TICKS_PER_BEAT = 480
        const val IMUSE_SYSEX_ID = 0x7D
        const val ROLAND_SYSEX_ID = 0x41

        val HookKind.isPartHook: Boolean get() = this != HookKind.JUMP && this != HookKind.TRANSPOSE

        /** Nibble pairs to bytes, as `Player::decode_sysex_bytes`. */
        fun decodeSysexBytes(src: ByteArray, from: Int, length: Int): ByteArray {
            val out = ByteArray(maxOf(0, length / 2 + 1))
            var s = from
            var len = length
            var d = 0
            while (len >= 0 && d < out.size) {
                val hi = if (s < src.size) src[s].toInt() else 0
                val lo = if (s + 1 < src.size) src[s + 1].toInt() else 0
                out[d++] = (((hi shl 4) and 0xFF) or (lo and 0x0F)).toByte()
                s += 2
                len -= 2
            }
            return out
        }

        fun parse(tag: String, payload: ByteArray): ImuseSong? = runCatching {
            val mthd = indexOf(payload, "MThd")
            require(mthd >= 0)
            val start = indexOf(payload, "MDhd").takeIf { it in 0 until mthd }?.let { md ->
                val size = be32(payload, md + 4)
                val p = md + 8
                // MDhd chunks in MI1 hold only zeroes; priority/volume/speed of zero mean "unset".
                if (size >= 8 && p + 8 <= payload.size) {
                    val b = { i: Int -> payload[p + i].toInt() and 0xFF }
                    if ((b(2) or b(3) or b(7)) != 0) StartParameters(b(2), b(3), b(4).toByte().toInt(), b(5).toByte().toInt(), b(6).toByte().toInt(), b(7)) else null
                } else null
            }
            val smf = payload.copyOfRange(mthd, payload.size)
            val ppqn = be16(smf, 12).let { if (it <= 0 || it and 0x8000 != 0) TICKS_PER_BEAT else it }
            val trackCount = be16(smf, 10)
            val tracks = mutableListOf<List<Event>>()
            var pos = 8 + be32(smf, 4)
            while (tracks.size < trackCount && pos + 8 <= smf.size) {
                val len = be32(smf, pos + 4)
                if (String(smf, pos, 4, Charsets.ISO_8859_1) == "MTrk") {
                    tracks += parseTrack(smf, pos + 8, minOf(smf.size, pos + 8 + len))
                }
                pos += 8 + len
            }
            require(tracks.isNotEmpty())
            ImuseSong(tag, ppqn, tracks, start, catalogue(tracks, ppqn), normalizedSmf(smf, tracks.size))
        }.getOrNull()

        private fun parseTrack(d: ByteArray, from: Int, end: Int): List<Event> {
            val events = mutableListOf<Event>()
            var p = from
            var tick = 0L
            var running = 0
            fun u8(i: Int) = if (i < end) d[i].toInt() and 0xFF else throw IndexOutOfBoundsException()
            fun vlq(): Int {
                var v = 0
                repeat(4) {
                    val b = u8(p++)
                    v = (v shl 7) or (b and 0x7F)
                    if (b and 0x80 == 0) return v
                }
                return v
            }
            while (p < end) {
                tick += vlq()
                var status = u8(p)
                if (status >= 0x80) p++ else status = running
                when {
                    status == 0xF0 || status == 0xF7 -> {
                        val len = vlq()
                        events += Event.SysEx(tick, d.copyOfRange(p, minOf(end, p + len)))
                        p += len
                    }
                    status == 0xFF -> {
                        val type = u8(p++)
                        val len = vlq()
                        events += Event.Meta(tick, type, d.copyOfRange(p, minOf(end, p + len)))
                        p += len
                        if (type == 0x2F) break
                    }
                    status >= 0x80 -> {
                        running = status
                        val one = (status shr 4) == 0xC || (status shr 4) == 0xD
                        val a = u8(p++)
                        val b = if (one) 0 else u8(p++)
                        events += Event.Channel(tick, status, a, b)
                    }
                    else -> break // data byte without running status: the track is corrupt from here
                }
            }
            return events
        }

        private fun catalogue(tracks: List<List<Event>>, ppqn: Int): List<CatalogueEntry> {
            val out = mutableListOf<CatalogueEntry>()
            for ((index, track) in tracks.withIndex()) {
                for (e in track) {
                    if (e !is Event.SysEx || e.bytes.size < 2 || (e.bytes[0].toInt() and 0xFF) != IMUSE_SYSEX_ID) continue
                    val b = e.bytes
                    val at = position(index, e.tick, ppqn)
                    val code = b[1].toInt() and 0xFF
                    // Message after the manufacturer: code at 0, data from 1; the trailing F7 is not stored.
                    val msg = b.copyOfRange(1, b.size).let { if (it.isNotEmpty() && (it.last().toInt() and 0xFF) == 0xF7) it.copyOf(it.size - 1) else it }
                    val len = msg.size
                    when (code) {
                        48 -> {
                            val buf = decodeSysexBytes(msg, 2, len - 2)
                            val target = Position(be16(buf, 1), be16(buf, 3), be16(buf, 5))
                            out += CatalogueEntry.Hook(at, HookKind.JUMP, buf[0].toInt() and 0xFF, -1, "→ $target", target)
                        }
                        49 -> {
                            val buf = decodeSysexBytes(msg, 2, len - 2)
                            val rel = buf[1].toInt() and 0xFF
                            out += CatalogueEntry.Hook(at, HookKind.TRANSPOSE, buf[0].toInt() and 0xFF, -1,
                                (if (rel != 0) "by " else "to ") + "${buf[2].toInt()} semitones")
                        }
                        50, 51, 52, 53 -> {
                            val chan = msg[1].toInt() and 0x0F
                            val buf = decodeSysexBytes(msg, 2, len - 2)
                            val kind = HookKind.entries.first { it.sysex == code }
                            val detail = when (kind) {
                                HookKind.PART_ON_OFF -> "part ${chan} " + if (buf[1].toInt() != 0) "on" else "off"
                                HookKind.PART_VOLUME -> "part $chan volume ${buf[1].toInt() and 0xFF}"
                                HookKind.PART_PROGRAM -> "part $chan instrument ${buf[1].toInt() and 0xFF}"
                                else -> "part $chan " + (if ((buf[1].toInt() and 0xFF) != 0) "by " else "to ") + "${buf[2].toInt()} semitones"
                            }
                            out += CatalogueEntry.Hook(at, kind, buf[0].toInt() and 0xFF, chan, detail)
                        }
                        64 -> for (i in 2 until len) out += CatalogueEntry.Marker(at, msg[i].toInt() and 0xFF)
                        80 -> {
                            val buf = decodeSysexBytes(msg, 2, len - 2)
                            out += CatalogueEntry.Loop(at, be16(buf, 0),
                                from = Position(index, be16(buf, 6), be16(buf, 8)), to = Position(index, be16(buf, 2), be16(buf, 4)))
                        }
                    }
                }
            }
            return out
        }

        fun position(track: Int, tick: Long, ppqn: Int): Position {
            val t = tick * TICKS_PER_BEAT / ppqn
            return Position(track, (t / TICKS_PER_BEAT + 1).toInt(), (t % TICKS_PER_BEAT).toInt())
        }

        /** Present several-track (format 2) files as format 1, as the current MIDI export does. */
        private fun normalizedSmf(smf: ByteArray, tracks: Int): ByteArray =
            smf.copyOf().also { it[8] = 0; it[9] = if (tracks <= 1) 0 else 1 }

        private fun indexOf(d: ByteArray, tag: String): Int {
            val t = tag.toByteArray(Charsets.ISO_8859_1)
            outer@ for (i in 0..d.size - t.size) {
                for (j in t.indices) if (d[i + j] != t[j]) continue@outer
                return i
            }
            return -1
        }

        internal fun be16(d: ByteArray, p: Int) = if (p + 1 < d.size) ((d[p].toInt() and 0xFF) shl 8) or (d[p + 1].toInt() and 0xFF) else 0
        private fun be32(d: ByteArray, p: Int) = (be16(d, p) shl 16) or be16(d, p + 2)
    }
}

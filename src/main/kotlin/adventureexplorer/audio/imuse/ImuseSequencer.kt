package adventureexplorer.audio.imuse

import adventureexplorer.audio.imuse.ImuseSong.CatalogueEntry
import adventureexplorer.audio.imuse.ImuseSong.Event
import adventureexplorer.audio.imuse.ImuseSong.HookKind
import adventureexplorer.audio.imuse.ImuseSong.Position

/** Something the sequencer did that the preview reports. */
sealed class ImuseEvent {
    data class Marker(val id: Int, val at: Position) : ImuseEvent()
    data class Jumped(val hookId: Int, val from: Position, val to: Position) : ImuseEvent()
    data class HookFired(val kind: HookKind, val id: Int, val channel: Int, val at: Position, val detail: String) : ImuseEvent()
    data class LoopRepeated(val from: Position, val to: Position, val remaining: Int) : ImuseEvent()
    object Ended : ImuseEvent()
}

/**
 * Plays one [ImuseSong] on an [ImuseDevice]: a port of ScummVM's iMUSE `Player`,
 * `Part` and SysEx handler (engines/scumm/imuse/imuse_player.cpp, imuse_part.cpp,
 * sysex_scumm.cpp; GPLv2+) together with the parts of `MidiParser` they rely on
 * (timing, jumps). Only one song plays, so each part keeps the device channel it
 * is given; the old (MI2/FOA/DOTT) iMUSE system is modelled.
 *
 * Call [onTimer] at [TIMER_HZ]; the caller provides the clock (real time or a
 * sample counter), so playback is deterministic.
 */
class ImuseSequencer(
    val song: ImuseSong,
    private val device: ImuseDevice,
    private val listener: (ImuseEvent) -> Unit = {},
) {
    // ── Player state ─────────────────────────────────────────
    private var priority = 0x80
    private var volume = 0x7F
    private var pan = 0
    private var transpose = 0
    private var detune = 0
    private var speed = 128
    private val volEff = 127
    private var noteOffset = 0
    var active = true
        private set

    private var trackIndex = 0
    private var loopToBeat = 1
    private var loopFromBeat = 1
    private var loopCounter = 0
    private var loopToTick = 0
    private var loopFromTick = 0

    // Hook state (HookDatas)
    private val jumpHook = IntArray(2)
    private var transposeHook = 0
    private val partOnOffHook = IntArray(16)
    private val partVolumeHook = IntArray(16)
    private val partProgramHook = IntArray(16)
    private val partTransposeHook = IntArray(16)

    private val globalInstruments = arrayOfNulls<ByteArray>(32)
    private val parts = arrayOfNulls<Part>(16)

    // ── Parser state (MidiParser) ────────────────────────────
    private var events: List<Event> = song.tracks[0]
    private var next = 0
    private var lastEventTick = 0L
    private var lastEventTime = 0L
    private var playTime = 0L
    private var playTick = 0L
    private var psecPerTick = 0L
    private var timerRate = 0L
    private var abortParse = false
    private var tracking = true

    init {
        setTempo(500_000)
        song.start?.let {
            priority = it.priority
            volume = it.volume
            pan = it.pan
            transpose = it.transpose
            detune = it.detune
            if (it.speed != 0) speed = it.speed
        }
        setSpeed(speed)
    }

    /** Current position as iMUSE reports it. */
    val position: Position get() = ImuseSong.position(trackIndex, playTick, song.ppqn)

    /** Hooks currently armed: kind to (channel or -1, id). */
    fun armedHooks(): List<Triple<HookKind, Int, Int>> = buildList {
        if (jumpHook[0] != 0) add(Triple(HookKind.JUMP, -1, jumpHook[0]))
        if (jumpHook[1] != 0) add(Triple(HookKind.JUMP, -1, jumpHook[1]))
        if (transposeHook != 0) add(Triple(HookKind.TRANSPOSE, -1, transposeHook))
        for (c in 0 until 16) {
            if (partOnOffHook[c] != 0) add(Triple(HookKind.PART_ON_OFF, c, partOnOffHook[c]))
            if (partVolumeHook[c] != 0) add(Triple(HookKind.PART_VOLUME, c, partVolumeHook[c]))
            if (partProgramHook[c] != 0) add(Triple(HookKind.PART_PROGRAM, c, partProgramHook[c]))
            if (partTransposeHook[c] != 0) add(Triple(HookKind.PART_TRANSPOSE, c, partTransposeHook[c]))
        }
    }

    /** The scripts' "set hook" command (`HookDatas::set`); channel 16 means every part. */
    fun armHook(kind: HookKind, id: Int, channel: Int = 16) {
        fun setPart(a: IntArray) = if (channel < 16) a[channel] = id else a.fill(id)
        when (kind) {
            HookKind.JUMP -> if (id != jumpHook[0]) { jumpHook[1] = jumpHook[0]; jumpHook[0] = id }
            HookKind.TRANSPOSE -> transposeHook = id
            HookKind.PART_ON_OFF -> setPart(partOnOffHook)
            HookKind.PART_VOLUME -> setPart(partVolumeHook)
            HookKind.PART_PROGRAM -> setPart(partProgramHook)
            HookKind.PART_TRANSPOSE -> setPart(partTransposeHook)
        }
    }

    fun clearHooks() {
        jumpHook.fill(0); transposeHook = 0
        partOnOffHook.fill(0); partVolumeHook.fill(0); partProgramHook.fill(0); partTransposeHook.fill(0)
    }

    /** One timer tick (`Player::onTimer`): loop check, then parse up to the new time. */
    fun onTimer() {
        if (!active) return
        val tick = playTick * TICKS_PER_BEAT / song.ppqn
        val beat = (tick / TICKS_PER_BEAT + 1).toInt()
        val tickIndex = (tick % TICKS_PER_BEAT).toInt()
        if (loopCounter != 0 && (beat > loopFromBeat || (beat == loopFromBeat && tickIndex >= loopFromTick))) {
            loopCounter--
            listener(ImuseEvent.LoopRepeated(position, Position(trackIndex, loopToBeat, loopToTick), loopCounter))
            jump(trackIndex, loopToBeat, loopToTick)
        }
        parserOnTimer()
    }

    fun stop() {
        if (!active) return
        for (p in parts) p?.uninit()
        active = false
    }

    // ── Timing ───────────────────────────────────────────────

    private fun setTempo(tempo: Int) {
        if (tempo <= 0) return
        psecPerTick = ((tempo + (song.ppqn shr 2)) / song.ppqn).toLong()
    }

    private fun setSpeed(value: Int) {
        speed = value
        timerRate = ((BASE_TEMPO_US * speed) shr 7).toLong()
    }

    private fun parserOnTimer() {
        if (!tracking) return
        abortParse = false
        val endTime = playTime + timerRate
        while (!abortParse) {
            if (next >= events.size) { endOfTrack(); return }
            val e = events[next]
            val eventTime = lastEventTime + (e.tick - lastEventTick) * psecPerTick
            if (eventTime > endTime) break
            next++
            lastEventTime = eventTime
            lastEventTick = e.tick
            playTime = eventTime
            playTick = e.tick
            if (!processEvent(e, fire = true)) return
        }
        if (!abortParse) {
            playTime = endTime
            playTick = if (psecPerTick > 0) (endTime - lastEventTime) / psecPerTick + lastEventTick else lastEventTick
        }
    }

    /** Returns false when parsing must stop (end of song). */
    private fun processEvent(e: Event, fire: Boolean): Boolean {
        when (e) {
            is Event.Meta -> when (e.type) {
                0x2F -> { endOfTrack(); return false }
                0x51 -> if (e.bytes.size >= 3) setTempo(((e.bytes[0].toInt() and 0xFF) shl 16) or ((e.bytes[1].toInt() and 0xFF) shl 8) or (e.bytes[2].toInt() and 0xFF))
            }
            is Event.SysEx -> if (fire) sysEx(e.bytes)
            is Event.Channel -> if (fire) send(e.status, e.data1, e.data2)
        }
        return true
    }

    private fun endOfTrack() {
        tracking = false
        // Player::metaEvent: End of Track clears the player.
        stop()
        listener(ImuseEvent.Ended)
    }

    /** `MidiParser::jumpToTick` without firing skipped events, then notes off. */
    private fun jumpToTick(target: Long): Boolean {
        val saved = Snapshot(next, lastEventTick, lastEventTime, playTime, playTick, psecPerTick)
        next = 0; lastEventTick = 0; lastEventTime = 0; playTime = 0; playTick = 0
        if (target > 0) {
            while (true) {
                if (next >= events.size || (events[next] is Event.Meta && (events[next] as Event.Meta).type == 0x2F)) {
                    saved.restore()
                    return false
                }
                val e = events[next]
                if (e.tick >= target) {
                    playTime += (target - lastEventTick) * psecPerTick
                    playTick = target
                    break
                }
                processEvent(e, fire = false)
                val eventTime = lastEventTime + (e.tick - lastEventTick) * psecPerTick
                playTime = eventTime; lastEventTime = eventTime
                playTick = e.tick; lastEventTick = e.tick
                next++
            }
        }
        for (p in parts) p?.allNotesOff()
        abortParse = true
        tracking = true
        return true
    }

    private inner class Snapshot(val next: Int, val lastTick: Long, val lastTime: Long, val time: Long, val tick: Long, val psec: Long) {
        fun restore() {
            this@ImuseSequencer.next = next
            lastEventTick = lastTick; lastEventTime = lastTime; playTime = time; playTick = tick; psecPerTick = psec
        }
    }

    private fun jump(track: Int, beat: Int, tick: Int): Boolean {
        if (track in song.tracks.indices && track != trackIndex) {
            trackIndex = track
            events = song.tracks[track]
        }
        val target = (((beat - 1).toLong() * TICKS_PER_BEAT + tick) * song.ppqn) / TICKS_PER_BEAT
        if (!jumpToTick(target)) return false
        for (p in parts) if (p != null && p.pedal) p.sustain(false)
        return true
    }

    // ── Channel messages (Player::send) ──────────────────────

    private fun send(status: Int, param1In: Int, param2In: Int) {
        val chan = status and 0x0F
        var param1 = param1In
        var param2 = param2In
        when (status shr 4) {
            0x8 -> getPart(chan)?.noteOff(param1)
            0x9 -> {
                param1 += noteOffset
                if (song.isMt32) param2 = (((param2 * 3) shr 2) + 32) and 0x7F
                getPart(chan)?.noteOn(param1, param2)
            }
            0xB -> {
                val part = (if (param1 == 123) parts[chan] else getPart(chan)) ?: return
                when (param1) {
                    1 -> part.modulationWheel(param2)
                    7 -> part.volume(param2)
                    10 -> part.setPan(param2 - 0x40)
                    16 -> part.pitchBendFactor(param2)
                    17 -> part.setDetune(param2 - 0x40)
                    18 -> part.setPriority(param2 - 0x40)
                    64 -> part.sustain(param2 != 0)
                    91 -> part.effectLevel(param2)
                    93 -> part.chorusLevel(param2)
                    123 -> part.allNotesOff()
                }
            }
            0xC -> getPart(chan)?.let { part ->
                if (song.isMidi) { if (param1 < 128) part.programChange(param1) }
                else if (param1 < 32) part.loadGlobalInstrument(param1)
            }
            0xE -> getPart(chan)?.pitchBend(((param2 shl 7) or param1) - 0x2000)
        }
    }

    private fun getPart(chan: Int): Part? = parts[chan] ?: Part(chan).also { parts[chan] = it }

    // ── SysEx (Player::sysEx + sysexHandler_Scumm) ───────────

    private fun sysEx(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        // Data after the manufacturer byte, without the trailing F7.
        val raw = bytes.copyOfRange(1, bytes.size).let { if (it.isNotEmpty() && (it.last().toInt() and 0xFF) == 0xF7) it.copyOf(it.size - 1) else it }
        when (bytes[0].toInt() and 0xFF) {
            ImuseSong.IMUSE_SYSEX_ID -> imuseSysEx(raw)
            // Roland custom timbres only matter on a real MT-32; GM output keeps the program.
            else -> {}
        }
    }

    private fun imuseSysEx(msg: ByteArray) {
        if (msg.isEmpty()) return
        val code = msg[0].toInt() and 0xFF
        val len = msg.size - 1 // bytes after the code
        fun u(i: Int) = if (i < msg.size) msg[i].toInt() and 0xFF else 0
        fun decode(from: Int, length: Int) = ImuseSong.decodeSysexBytes(msg, from, length)
        val at = position
        when (code) {
            0 -> { // allocate part
                val part = getPart(u(1) and 0x0F) ?: return
                val buf = ByteArray(1) + decode(2, len - 1)
                fun b(i: Int) = if (i < buf.size) buf[i].toInt() and 0xFF else 0
                part.setOnOff(b(1) and 0x01 != 0)
                part.effectLevel(if (b(1) and 0x02 != 0) 127 else 0)
                part.setPriority(b(2).toByte().toInt())
                part.volume(b(3))
                part.setPan(b(4).toByte().toInt())
                part.percussion = song.supportsPercussion && (b(5) and 0x80) != 0
                part.setTranspose(b(5).toByte().toInt(), -12, 12)
                part.setDetune(b(6).toByte().toInt())
                part.pitchBendFactor(b(7))
                if (part.percussion) {
                    part.releaseChannel()
                } else {
                    if (song.isMidi) part.instrument = Instrument.Program(b(8), song.isMt32)
                    else part.instrument = globalInstrument(b(8))
                    part.ensureChannel()
                    part.sendAll()
                }
            }
            1 -> parts[u(1) and 0x0F]?.uninit()
            2 -> {} // start of song
            16 -> { // AdLib instrument (part)
                val part = getPart(u(1) and 0x0F) ?: return
                if (len == 62 || len == 48) part.setAdlibInstrument(decode(3, len - 2))
                else part.programChange(254)
            }
            17 -> { // AdLib instrument (global)
                val slot = u(3)
                if ((len == 63 || len == 49) && slot < 32) globalInstruments[slot] = decode(4, len - 3).copyOf(30)
            }
            33 -> {} // parameter adjust: no-op in ScummVM's parts
            48 -> {
                val buf = decode(2, len - 1)
                val id = buf[0].toInt() and 0xFF
                val target = Position(ImuseSong.be16(buf, 1), ImuseSong.be16(buf, 3), ImuseSong.be16(buf, 5))
                if (id != 0 && jumpHook[0] != id) return
                if (id != 0 && id < 0x80) { jumpHook[0] = jumpHook[1]; jumpHook[1] = 0 }
                if (id != 0) listener(ImuseEvent.HookFired(HookKind.JUMP, id, -1, at, "→ $target"))
                if (jump(target.track, target.beat, target.tick)) listener(ImuseEvent.Jumped(id, at, target))
            }
            49 -> {
                val buf = decode(2, len - 1)
                val id = buf[0].toInt() and 0xFF
                if (id != 0 && transposeHook != id) return
                if (id != 0 && id < 0x80) transposeHook = 0
                if (id != 0) listener(ImuseEvent.HookFired(HookKind.TRANSPOSE, id, -1, at, "transpose ${buf[2].toInt()}"))
                setTranspose(buf[1].toInt() and 0xFF, buf[2].toInt())
            }
            50, 51, 52, 53 -> {
                val chan = u(1) and 0x0F
                val buf = decode(2, len - 1)
                val id = buf[0].toInt() and 0xFF
                val kind = HookKind.entries.first { it.sysex == code }
                val hooks = when (kind) {
                    HookKind.PART_ON_OFF -> partOnOffHook
                    HookKind.PART_VOLUME -> partVolumeHook
                    HookKind.PART_PROGRAM -> partProgramHook
                    else -> partTransposeHook
                }
                if (id != 0 && hooks[chan] != id) return
                if (id != 0 && id < 0x80) hooks[chan] = 0
                val value = buf[1].toInt() and 0xFF
                if (id != 0) listener(ImuseEvent.HookFired(kind, id, chan, at, "part $chan → $value"))
                val part = getPart(chan) ?: return
                when (kind) {
                    HookKind.PART_ON_OFF -> part.setOnOff(value != 0)
                    HookKind.PART_VOLUME -> part.volume(value)
                    HookKind.PART_PROGRAM -> part.programChange(value)
                    else -> partSetTranspose(chan, value, buf[2].toInt())
                }
            }
            64 -> for (i in 2 until msg.size) listener(ImuseEvent.Marker(u(i), at))
            80 -> {
                val buf = decode(2, len - 1)
                setLoop(ImuseSong.be16(buf, 0), ImuseSong.be16(buf, 2), ImuseSong.be16(buf, 4), ImuseSong.be16(buf, 6), ImuseSong.be16(buf, 8))
            }
            81 -> loopCounter = 0
            96 -> {
                val part = getPart(u(1) and 0x0F) ?: return
                val value = ((u(2) and 0x0F) shl 12) or ((u(3) and 0x0F) shl 8) or ((u(4) and 0x0F) shl 4) or (u(5) and 0x0F)
                part.instrument = Instrument.Program(value and 0xFF, song.isMt32)
                part.transmitInstrument()
            }
        }
    }

    private fun globalInstrument(slot: Int): Instrument =
        Instrument.Adlib(globalInstruments.getOrNull(slot) ?: ByteArray(30))

    private fun setLoop(count: Int, toBeat: Int, toTick: Int, fromBeat: Int, fromTick: Int) {
        if (toBeat + 1 >= fromBeat) return
        loopCounter = 0
        loopToBeat = if (toBeat == 0) 1 else toBeat
        loopToTick = toTick
        loopFromBeat = fromBeat
        loopFromTick = fromTick
        loopCounter = count
    }

    private fun setTranspose(relative: Int, value: Int) {
        if (value > 24 || value < -24 || relative > 1) return
        transpose = if (relative != 0) transposeClamp(transpose + value, -7, 7) else value
        val lim = transposeLimit()
        for (p in parts) p?.setTranspose(p.transposeRaw, -lim, lim)
    }

    private fun partSetTranspose(chan: Int, relative: Int, value: Int) {
        if (value > 24 || value < -24) return
        val part = getPart(chan) ?: return
        val b = if (relative != 0) transposeClamp(value + part.transposeRaw, -7, 7) else value
        val lim = transposeLimit()
        part.setTranspose(b, -lim, lim)
    }

    // MI2 and INDY4 use -24/24 on AdLib and PC speaker; MT-32 and DOTT use -12/12.
    private fun transposeLimit() = if (song.isAdlib || song.tag == "SPK ") 24 else 12

    // ── Instruments ──────────────────────────────────────────

    private sealed class Instrument {
        abstract val valid: Boolean
        abstract fun send(mc: ImuseChannel)
        class Program(val program: Int, val mt32: Boolean) : Instrument() {
            // MT-32 songs on a GM device go through ScummVM's MT-32 to GM table.
            private val mapped = if (program > 127) 255 else if (mt32) MT32_TO_GM[program] else program
            override val valid get() = mapped < 128
            override fun send(mc: ImuseChannel) { if (mapped < 128) mc.programChange(mapped) }
        }
        class Adlib(val data: ByteArray) : Instrument() {
            override val valid get() = true
            override fun send(mc: ImuseChannel) = mc.adlibInstrument(data)
        }
    }

    // ── Part (imuse_part.cpp) ────────────────────────────────

    private inner class Part(val chan: Int) {
        var mc: ImuseChannel? = null
        var on = true
        var percussion = song.isMidi && chan == 9 && song.supportsPercussion
        var pri = 0
        var priEff = priority
        var vol = 127
        var volEffPart = volEff
        var panRaw = pan.coerceIn(-64, 63)
        var panEff = panRaw
        var transposeRaw = 0
        var transposeEff = transpose
        var detuneRaw = 0
        var detuneEff = detune
        var pitchBendValue = 0
        var pitchBendFactorValue = 2
        var modWheel = 0
        var pedal = false
        var effect = 64
        var chorus = 0
        var instrument: Instrument? = null
        var unassignedInstrument = true

        fun ensureChannel() {
            if (mc == null && !percussion) mc = device.allocateChannel()
        }

        fun releaseChannel() {
            mc?.let { it.sustain(false); it.allNotesOff(); it.release() }
            mc = null
        }

        /** `Part::clearToTransmit`: a channel is assigned once the part has a usable instrument. */
        fun clearToTransmit(): Boolean {
            if (mc != null) return true
            if (instrument?.valid == true && !percussion) {
                ensureChannel()
                if (mc != null) { sendAll(); return false }
            }
            return false
        }

        fun transmitInstrument() {
            if (clearToTransmit()) instrument?.send(mc!!)
        }

        fun setAdlibInstrument(data: ByteArray) {
            instrument = Instrument.Adlib(data.copyOf(30))
            transmitInstrument()
        }

        fun loadGlobalInstrument(slot: Int) {
            instrument = globalInstrument(slot)
            transmitInstrument()
        }

        fun programChange(value: Int) {
            instrument = Instrument.Program(value, song.isMt32)
            transmitInstrument()
        }

        fun noteOn(note: Int, velocity: Int) {
            if (!on) return
            if (unassignedInstrument && !percussion) {
                unassignedInstrument = false
                if (instrument?.valid != true) return
            }
            val channel = mc ?: if (instrument?.valid == true && !percussion) { clearToTransmit(); mc } else null
            if (channel != null && instrument?.valid == true) {
                channel.noteOn(note and 0x7F, velocity)
            } else if (percussion) {
                val pc = device.percussionChannel() ?: return
                pc.volume(volEffPart)
                pc.noteOn(if (note < 35) GM_RHYTHM_MAP[note] else note, velocity)
            }
        }

        fun noteOff(note: Int) {
            if (!on) return
            val channel = mc
            if (channel != null) channel.noteOff(note and 0x7F)
            else if (percussion) device.percussionChannel()?.noteOff(if (note < 35) GM_RHYTHM_MAP[note] else note)
        }

        fun setOnOff(value: Boolean) {
            if (on == value) return
            on = value
            if (!value) mc?.let { it.sustain(false); it.allNotesOff() }
        }

        fun setDetune(value: Int) {
            detuneRaw = value
            detuneEff = (value + detune).coerceIn(-128, 127)
            mc?.detune(detuneEff)
        }

        fun pitchBend(value: Int) {
            pitchBendValue = value
            mc?.pitchBend(value)
        }

        fun volume(value: Int) {
            vol = value
            volEffPart = ((vol + 1) * volEff) shr 7
            mc?.volume(volEffPart)
        }

        fun setPriority(value: Int) {
            pri = value
            priEff = (value + priority).coerceIn(0, 255)
            mc?.priority(priEff)
        }

        fun setPan(value: Int) {
            panRaw = value
            panEff = (value + pan).coerceIn(-64, 63)
            mc?.panPosition(panEff + 0x40)
        }

        fun setTranspose(value: Int, low: Int, high: Int) {
            transposeRaw = value
            transposeEff = if (value == -128) 0 else transposeClamp(value + transpose, low, high)
            mc?.transpose(transposeEff)
        }

        fun sustain(value: Boolean) { pedal = value; mc?.sustain(value) }
        fun modulationWheel(value: Int) { modWheel = value; mc?.modulationWheel(value) }
        fun chorusLevel(value: Int) { chorus = value; mc?.chorusLevel(value) }
        fun effectLevel(value: Int) { effect = value; mc?.effectLevel(value) }

        fun pitchBendFactor(value: Int) {
            if (value > 12) return
            pitchBend(0)
            pitchBendFactorValue = value
            mc?.pitchBendFactor(value)
        }

        fun allNotesOff() { mc?.allNotesOff() }

        fun sendAll() {
            val c = mc ?: return
            c.pitchBendFactor(pitchBendFactorValue)
            c.transpose(transposeEff)
            c.detune(detuneEff)
            c.pitchBend(pitchBendValue)
            c.volume(volEffPart)
            c.sustain(pedal)
            c.modulationWheel(modWheel)
            c.panPosition(panEff + 0x40)
            instrument?.takeIf { it.valid }?.send(c)
            c.effectLevel(effect)
            c.chorusLevel(chorus)
            c.priority(priEff)
        }

        fun uninit() {
            releaseChannel()
            parts[chan] = null
        }
    }

    companion object {
        const val TIMER_HZ = 250
        /** ScummVM drivers' base tempo: one timer period in microseconds. */
        const val BASE_TEMPO_US = 1_000_000 / TIMER_HZ
        private const val TICKS_PER_BEAT = ImuseSong.TICKS_PER_BEAT

        private fun transposeClamp(value: Int, low: Int, high: Int): Int {
            var a = value
            if (low > a) a += (low - a + 11) / 12 * 12
            if (high < a) a -= (a - high + 11) / 12 * 12
            return a
        }

        /** ScummVM `Instrument::_gmRhythmMap`: MT-32 rhythm keys below 35 on GM. */
        private val GM_RHYTHM_MAP = intArrayOf(
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 36, 37, 38, 39, 40, 41, 66, 47,
            65, 48, 56,
        )

        /** ScummVM `MidiDriver::_mt32ToGm`. */
        val MT32_TO_GM = intArrayOf(
            0, 1, 0, 2, 4, 4, 5, 3, 16, 17, 18, 16, 16, 19, 20, 21,
            6, 6, 6, 7, 7, 7, 8, 112, 62, 62, 63, 63, 38, 38, 39, 39,
            88, 95, 52, 98, 97, 99, 14, 54, 102, 96, 53, 102, 81, 100, 14, 80,
            48, 48, 49, 45, 41, 40, 42, 42, 43, 46, 45, 24, 25, 28, 27, 104,
            32, 32, 34, 33, 36, 37, 35, 35, 79, 73, 72, 72, 74, 75, 64, 65,
            66, 67, 71, 71, 68, 69, 70, 22, 56, 59, 57, 57, 60, 60, 58, 61,
            61, 11, 11, 98, 14, 9, 14, 13, 12, 107, 107, 77, 78, 78, 76, 76,
            47, 117, 127, 118, 118, 116, 115, 119, 115, 112, 55, 124, 123, 0, 14, 117,
        )
    }
}

package adventureexplorer.audio.imuse

import adventureexplorer.audio.Opl3

/**
 * iMUSE AdLib output: a port of ScummVM's `MidiDriver_ADLIB` (audio/adlib.cpp,
 * GPLv2+) in its OPL2 mode, driving the [Opl3] emulator. Nine voices are shared
 * by up to 32 parts; each part plays its iMUSE AdLib instrument (30 bytes:
 * operator registers, feedback and two software envelopes "Struct10/11"
 * that modulate volume, pitch or other parameters while a note sounds).
 *
 * Call [onTimer] at [ImuseSequencer.TIMER_HZ] alongside the sequencer.
 */
class AdlibOplDevice(private val chip: Opl3, enablePercussion: Boolean = false) : ImuseDevice {
    private class Struct10 {
        var active = 0
        var curVal = 0
        var count = 0
        var maxValue = 0
        var startValue = 0
        var loop = 0
        val tableA = IntArray(4)
        val tableB = IntArray(4)
        var unk3 = 0
        var modWheel = 0
        var modWheelLast = 0
        var speedLoMax = 0
        var numSteps = 0
        var speedHi = 0
        var direction = 0
        var speedLo = 0
        var speedLoCounter = 0
    }

    private class Struct11(val s10: Struct10) {
        var modifyVal = 0
        var param = 0
        var flag0x40 = 0
        var flag0x10 = 0
    }

    private class Voice(val channel: Int) {
        var part: Part? = null
        var next: Voice? = null
        var prev: Voice? = null
        var waitForPedal = false
        var note = 0
        var twoChan = 0
        var vol1 = 0
        var vol2 = 0
        var duration = 0
        val s10a = Struct10()
        val s10b = Struct10()
        val s11a = Struct11(s10b)
        val s11b = Struct11(s10a)
    }

    private val regCache = IntArray(256)
    private val voices = Array(9) { Voice(it) }
    private val parts = Array(32) { Part() }
    private val percussion = if (enablePercussion) Part(isPercussion = true) else null
    private val channelTable2 = IntArray(9)
    private val curNotTable = IntArray(9)
    private var voiceIndex = -1
    private var timerCounter = 0
    private var randSeed = 1

    init {
        write(8, 0x40)
        write(0xBD, 0x00)
        write(1, 0x20)
    }

    override fun allocateChannel(): ImuseChannel? = parts.firstOrNull { !it.allocated }?.also { it.allocated = true }
    override fun percussionChannel(): ImuseChannel? = percussion
    override fun allNotesOff() { for (p in parts) p.allNotesOff(); percussion?.allNotesOff() }

    override fun onTimer() {
        timerCounter += TIMER_INCREASE
        while (timerCounter >= TIMER_THRESHOLD) {
            timerCounter -= TIMER_THRESHOLD
            for (voice in voices) {
                if (voice.part == null) continue
                if (voice.duration != 0) {
                    voice.duration = (voice.duration - 0x11).toShort().toInt()
                    if (voice.duration <= 0) {
                        mcOff(voice)
                        return
                    }
                }
                if (voice.s10a.active != 0) mcIncStuff(voice, voice.s10a, voice.s11a)
                if (voice.s10b.active != 0) mcIncStuff(voice, voice.s10b, voice.s11b)
            }
        }
    }

    // ── Part (AdLibPart) ─────────────────────────────────────

    private inner class Part(private val isPercussion: Boolean = false) : ImuseChannel {
        var allocated = false
        var voice: Voice? = null
        var pitchBendValue = 0
        var pitchBendFactorValue = 2
        var transposeEff = 0
        var volEff = 0
        var detuneEff = 0
        var modWheel = 0
        var pedal = false
        var priEff = 127
        var pan = 64
        val instr = ByteArray(30)

        init { programChange(0) }

        private fun voices(): List<Voice> = generateSequence(voice) { it.next }.toList()
        private fun bend() = (pitchBendValue * pitchBendFactorValue shr 6) + detuneEff
        private fun retune() { for (v in voices()) adlibNoteOn(v.channel, (v.note + transposeEff) and 0xFF, bend()) }

        override fun noteOff(note: Int) = partKeyOff(this, note)
        override fun noteOn(note: Int, velocity: Int) {
            if (velocity == 0) { noteOff(note); return }
            val instrument = if (isPercussion) {
                val index = GM_PERCUSSION_MAP.getOrElse(note) { 255 }
                if (index == 255) return
                ByteArray(30) { GM_PERCUSSION[index * 30 + it].toByte() }
            } else instr
            partKeyOn(this, instrument, note, velocity)
        }
        override fun programChange(program: Int) {
            if (program !in 0..127 || isPercussion) return
            for (i in 0 until 30) instr[i] = GM_INSTRUMENTS[program * 30 + i].toByte()
        }
        override fun pitchBend(bend: Int) { pitchBendValue = bend; retune() }
        override fun pitchBendFactor(semitones: Int) { pitchBendFactorValue = semitones; retune() }
        override fun detune(value: Int) { detuneEff = value; retune() }
        override fun transpose(semitones: Int) { transposeEff = semitones; retune() }
        override fun modulationWheel(value: Int) {
            modWheel = value
            for (v in voices()) {
                if (v.s10a.active != 0 && v.s11a.flag0x40 != 0) v.s10a.modWheel = modWheel shr 2
                if (v.s10b.active != 0 && v.s11b.flag0x40 != 0) v.s10b.modWheel = modWheel shr 2
            }
        }
        override fun volume(value: Int) {
            volEff = value
            for (v in voices()) {
                adlibSetParam(v.channel, 0, VOLUME_TABLE[lookup(v.vol2, volEff shr 2)])
                if (v.twoChan != 0) adlibSetParam(v.channel, 13, VOLUME_TABLE[lookup(v.vol1, volEff shr 2)])
            }
        }
        override fun panPosition(value: Int) { pan = value }
        override fun priority(value: Int) { priEff = value }
        override fun sustain(on: Boolean) {
            pedal = on
            if (!on) for (v in voices()) if (v.waitForPedal) mcOff(v)
        }
        override fun effectLevel(value: Int) {}
        override fun chorusLevel(value: Int) {}
        override fun allNotesOff() { while (true) mcOff(voice ?: break) }
        override fun adlibInstrument(data: ByteArray) {
            if (data.size >= 30) data.copyInto(instr, 0, 0, 30)
        }
        override fun release() { allocated = false }
    }

    // ── Voices ───────────────────────────────────────────────

    private fun mcOff(voice: Voice) {
        adlibKeyOff(voice.channel)
        val prev = voice.prev
        voice.next?.prev = prev
        if (prev != null) prev.next = voice.next else voice.part?.voice = voice.next
        voice.part = null
    }

    private fun partKeyOff(part: Part, note: Int) {
        var v = part.voice
        while (v != null) {
            val next = v.next
            if (v.note == note) {
                if (part.pedal) v.waitForPedal = true else mcOff(v)
            }
            v = next
        }
    }

    private fun partKeyOn(part: Part, instr: ByteArray, note: Int, velocity: Int) {
        val voice = allocateVoice(part.priEff) ?: return
        voice.part = part
        voice.next = part.voice
        part.voice = voice
        voice.prev = null
        voice.next?.prev = voice
        mcKeyOn(voice, instr, note, velocity)
    }

    private fun allocateVoice(priIn: Int): Voice? {
        var pri = priIn
        var best: Voice? = null
        repeat(9) {
            if (++voiceIndex >= 9) voiceIndex = 0
            val ac = voices[voiceIndex]
            val owner = ac.part ?: return ac
            if (ac.next == null && owner.priEff <= pri) {
                pri = owner.priEff
                best = ac
            }
        }
        best?.let { mcOff(it) }
        return best
    }

    private fun i(instr: ByteArray, index: Int) = instr[index].toInt() and 0xFF

    private fun mcKeyOn(voice: Voice, instr: ByteArray, note: Int, velocity: Int) {
        val part = voice.part!!
        voice.twoChan = i(instr, 10) and 1
        voice.note = note
        voice.waitForPedal = false
        voice.duration = i(instr, 29)
        if (voice.duration != 0) voice.duration *= 63
        var vol1 = minOf(0x3F, ((i(instr, 1) and 0x3F) + lookup(velocity shr 1, i(instr, 4) shr 2)) and 0xFF)
        var vol2 = minOf(0x3F, ((i(instr, 6) and 0x3F) + lookup(velocity shr 1, i(instr, 9) shr 2)) and 0xFF)
        voice.vol1 = vol1
        voice.vol2 = vol2
        val c = part.volEff shr 2
        vol2 = VOLUME_TABLE[lookup(vol2, c)]
        if (voice.twoChan != 0) vol1 = VOLUME_TABLE[lookup(vol1, c)]
        adlibSetupChannel(voice.channel, instr, vol1, vol2)
        adlibNoteOnEx(voice.channel, (note + part.transposeEff) and 0xFF, part.detuneEff + (part.pitchBendValue * part.pitchBendFactorValue shr 6))
        val flagsA = i(instr, 11)
        if (flagsA and 0x80 != 0) mcInitStuff(voice, voice.s10a, voice.s11a, flagsA, instr, 12) else voice.s10a.active = 0
        val flagsB = i(instr, 20)
        if (flagsB and 0x80 != 0) mcInitStuff(voice, voice.s10b, voice.s11b, flagsB, instr, 21) else voice.s10b.active = 0
    }

    private fun adlibSetupChannel(chan: Int, instr: ByteArray, vol1: Int, vol2: Int) {
        var op = OPERATOR1_OFFSETS[chan]
        write(op + 0x20, i(instr, 0))
        write(op + 0x40, ((i(instr, 1) or 0x3F) - vol1) and 0xFF)
        write(op + 0x60, i(instr, 2).inv() and 0xFF)
        write(op + 0x80, i(instr, 3).inv() and 0xFF)
        write(op + 0xE0, i(instr, 4))
        op = OPERATOR2_OFFSETS[chan]
        write(op + 0x20, i(instr, 5))
        write(op + 0x40, ((i(instr, 6) or 0x3F) - vol2) and 0xFF)
        write(op + 0x60, i(instr, 7).inv() and 0xFF)
        write(op + 0x80, i(instr, 8).inv() and 0xFF)
        write(op + 0xE0, i(instr, 9))
        write(chan + 0xC0, i(instr, 10))
    }

    private fun mcInitStuff(voice: Voice, s10: Struct10, s11: Struct11, flags: Int, instr: ByteArray, extra: Int) {
        val part = voice.part!!
        s11.modifyVal = 0
        s11.flag0x40 = flags and 0x40
        s10.loop = flags and 0x20
        s11.flag0x10 = flags and 0x10
        s11.param = PARAM_TABLE1[flags and 0xF]
        s10.maxValue = MAX_VAL_TABLE[flags and 0xF]
        s10.unk3 = 31
        s10.modWheel = if (s11.flag0x40 != 0) part.modWheel shr 2 else 31
        when (s11.param) {
            0 -> s10.startValue = voice.vol2
            13 -> s10.startValue = voice.vol1
            30 -> { s10.startValue = 31; s11.s10.modWheel = 0 }
            31 -> { s10.startValue = 0; s11.s10.unk3 = 0 }
            else -> s10.startValue = adlibGetRegValueParam(voice.channel, s11.param)
        }
        // struct10Init
        s10.active = 1
        s10.curVal = 0
        s10.modWheelLast = 31
        s10.count = i(instr, extra)
        if (s10.count != 0) s10.count *= 63
        s10.tableA[0] = i(instr, extra + 1); s10.tableA[1] = i(instr, extra + 3)
        s10.tableA[2] = i(instr, extra + 5); s10.tableA[3] = i(instr, extra + 6)
        s10.tableB[0] = i(instr, extra + 2); s10.tableB[1] = i(instr, extra + 4)
        s10.tableB[2] = 0; s10.tableB[3] = i(instr, extra + 7)
        struct10Setup(s10)
    }

    private fun mcIncStuff(voice: Voice, s10: Struct10, s11: Struct11) {
        val part = voice.part ?: return
        val code = struct10OnTimer(s10, s11)
        if (code and 1 != 0) {
            when (s11.param) {
                0 -> {
                    voice.vol2 = (s10.startValue + s11.modifyVal) and 0xFF
                    adlibSetParam(voice.channel, 0, VOLUME_TABLE[lookup(voice.vol2, part.volEff shr 2)])
                }
                13 -> {
                    voice.vol1 = (s10.startValue + s11.modifyVal) and 0xFF
                    if (voice.twoChan != 0) adlibSetParam(voice.channel, 13, VOLUME_TABLE[lookup(voice.vol1, part.volEff shr 2)])
                    else adlibSetParam(voice.channel, 13, voice.vol1)
                }
                30 -> s11.s10.modWheel = s11.modifyVal.toByte().toInt()
                31 -> s11.s10.unk3 = s11.modifyVal.toByte().toInt()
                else -> adlibSetParam(voice.channel, s11.param, s10.startValue + s11.modifyVal)
            }
        }
        if (code and 2 != 0 && s11.flag0x10 != 0) adlibKeyOnOff(voice.channel)
    }

    private fun struct10OnTimer(s10: Struct10, s11: Struct11): Int {
        var result = 0
        if (s10.count != 0) {
            s10.count = (s10.count - 17).toShort().toInt()
            if (s10.count <= 0) {
                s10.active = 0
                return 0
            }
        }
        var i = s10.curVal + s10.speedHi
        s10.speedLoCounter = (s10.speedLoCounter + s10.speedLo) and 0xFFFF
        if (s10.speedLoCounter >= s10.speedLoMax) {
            s10.speedLoCounter = (s10.speedLoCounter - s10.speedLoMax) and 0xFFFF
            i += s10.direction
        }
        if (s10.curVal != i || s10.modWheel != s10.modWheelLast) {
            s10.curVal = i.toShort().toInt()
            s10.modWheelLast = s10.modWheel
            i = lookupVolume(i, s10.modWheelLast)
            if (i != s11.modifyVal) {
                s11.modifyVal = i.toShort().toInt()
                result = 1
            }
        }
        s10.numSteps = (s10.numSteps - 1) and 0xFFFF
        if (s10.numSteps == 0) {
            s10.active = (s10.active + 1) and 0xFF
            if (s10.active > 4) {
                if (s10.loop != 0) {
                    s10.active = 1
                    result = result or 2
                    struct10Setup(s10)
                } else {
                    s10.active = 0
                }
            } else {
                struct10Setup(s10)
            }
        }
        return result
    }

    private fun struct10Setup(s10: Struct10) {
        val b = s10.unk3
        val f = s10.active - 1
        var t = s10.tableA[f]
        var e = NUM_STEPS_TABLE.getOrElse(lookup(t and 0x7F, b)) { 0 }
        if (t and 0x80 != 0) e = randomNr(e)
        if (e == 0) e++
        s10.numSteps = e
        s10.speedLoMax = e
        var h: Int
        if (f != 2) {
            val c = s10.maxValue
            val g = s10.startValue
            t = s10.tableB[f]
            var d = lookupVolume(c, (t and 0x7F) - 31)
            if (t and 0x80 != 0) d = randomNr(d)
            h = if (d + g > c) c - g else if (d + g < 0) -g else d
            h -= s10.curVal
        } else {
            h = 0
        }
        s10.speedHi = (h / e).toShort().toInt()
        if (h < 0) { h = -h; s10.direction = -1 } else s10.direction = 1
        s10.speedLo = (h % e) and 0xFFFF
        s10.speedLoCounter = 0
    }

    private fun randomNr(a: Int): Int {
        randSeed = if (randSeed and 1 != 0) (randSeed shr 1) xor 0xB8 else randSeed shr 1
        return randSeed * a shr 8
    }

    // ── Registers ────────────────────────────────────────────

    private fun write(reg: Int, value: Int) {
        val v = value and 0xFF
        if (regCache[reg] == v) return
        regCache[reg] = v
        chip.writeReg(reg, v)
    }

    private fun adlibKeyOff(chan: Int) {
        val reg = chan + 0xB0
        write(reg, regCache[reg] and 0x20.inv())
    }

    private fun adlibKeyOnOff(chan: Int) {
        val reg = chan + 0xB0
        val v = regCache[reg]
        write(reg, v and 0x20.inv())
        write(reg, v or 0x20)
    }

    private fun adlibSetParam(channel: Int, paramIn: Int, valueIn: Int) {
        var param = paramIn
        var value = valueIn
        var reg: Int
        when {
            param <= 12 -> reg = OPERATOR2_OFFSETS[channel]
            param <= 25 -> { param -= 13; reg = OPERATOR1_OFFSETS[channel] }
            param <= 27 -> { param -= 13; reg = channel }
            param == 28 || param == 29 -> {
                value = if (param == 28) value - 15 else value - 383
                value *= 16
                channelTable2[channel] = value and 0xFFFF
                adlibPlayNote(channel, curNotTable[channel] + value)
                return
            }
            else -> return
        }
        val base = SET_PARAM_TABLE[param * 4]
        val shift = SET_PARAM_TABLE[param * 4 + 1]
        val mask = SET_PARAM_TABLE[param * 4 + 2]
        val inversion = SET_PARAM_TABLE[param * 4 + 3]
        if (inversion != 0) value = inversion - value
        reg += base
        write(reg, (regCache[reg] and mask.inv()) or (((value and 0xFF) shl shift) and 0xFF))
    }

    private fun adlibGetRegValueParam(chan: Int, paramIn: Int): Int {
        var param = paramIn
        val channel: Int
        when {
            param <= 12 -> channel = OPERATOR2_OFFSETS[chan]
            param <= 25 -> { param -= 13; channel = OPERATOR1_OFFSETS[chan] }
            param <= 27 -> { param -= 13; channel = chan }
            param == 28 -> return 0xF
            param == 29 -> return 0x17F
            else -> return 0
        }
        val base = SET_PARAM_TABLE[param * 4]
        val shift = SET_PARAM_TABLE[param * 4 + 1]
        val mask = SET_PARAM_TABLE[param * 4 + 2]
        val inversion = SET_PARAM_TABLE[param * 4 + 3]
        var v = (regCache[channel + base] and mask) shr shift
        if (inversion != 0) v = (inversion - v) and 0xFF
        return v
    }

    private fun adlibNoteOn(chan: Int, note: Int, mod: Int) {
        val code = (note shl 7) + mod
        curNotTable[chan] = code and 0xFFFF
        adlibPlayNote(chan, channelTable2[chan].toShort().toInt() + code)
    }

    private fun adlibNoteOnEx(chan: Int, note: Int, mod: Int) {
        val code = (note shl 7) + mod
        curNotTable[chan] = code and 0xFFFF
        channelTable2[chan] = 0
        adlibPlayNote(chan, code)
    }

    private fun adlibPlayNote(channel: Int, note: Int) {
        var note2 = ((note shr 7) - 4) and 0xFF
        if (note2 >= 128) note2 = 0
        var oct = note2 / 12
        oct = if (oct > 7) 7 shl 2 else oct shl 2
        var notex = note2 % 12 + 3
        var old = regCache[channel + 0xB0]
        if (old and 0x20 != 0) {
            old = old and 0x20.inv()
            if (oct > old) {
                if (notex < 6) { notex += 12; oct -= 4 }
            } else if (oct < old) {
                if (notex > 11) { notex -= 12; oct += 4 }
            }
        }
        val index = ((notex shl 3) + ((note shr 4) and 0x7)).coerceIn(0, NOTE_FREQUENCIES.size - 1)
        write(channel + 0xA0, NOTE_FREQUENCIES[index])
        write(channel + 0xB0, (oct and 0xFF) or 0x20)
    }

    companion object {
        private const val TIMER_INCREASE = 0xD69
        private const val TIMER_THRESHOLD = 0x411B

        private val OPERATOR1_OFFSETS = intArrayOf(0, 1, 2, 8, 9, 10, 16, 17, 18)
        private val OPERATOR2_OFFSETS = intArrayOf(3, 4, 5, 11, 12, 13, 19, 20, 21)

        /** registerBase, shift, mask, inversion per parameter (g_setParamTable). */
        private val SET_PARAM_TABLE = intArrayOf(
            0x40, 0, 63, 63, 0xE0, 2, 0, 0, 0x40, 6, 192, 0, 0x20, 0, 15, 0, 0x60, 4, 240, 15,
            0x60, 0, 15, 15, 0x80, 4, 240, 15, 0x80, 0, 15, 15, 0xE0, 0, 3, 0, 0x20, 7, 128, 0,
            0x20, 6, 64, 0, 0x20, 5, 32, 0, 0x20, 4, 16, 0, 0xC0, 0, 1, 0, 0xC0, 1, 14, 0,
        )
        private val PARAM_TABLE1 = intArrayOf(29, 28, 27, 0, 3, 4, 7, 8, 13, 16, 17, 20, 21, 30, 31, 0)
        private val MAX_VAL_TABLE = intArrayOf(0x2FF, 0x1F, 0x7, 0x3F, 0x0F, 0x0F, 0x0F, 0x3, 0x3F, 0x0F, 0x0F, 0x0F, 0x3, 0x3E, 0x1F, 0)
        private val NUM_STEPS_TABLE = intArrayOf(
            1, 2, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 21, 24, 30,
            36, 50, 64, 82, 100, 136, 160, 192, 240, 276, 340, 460, 600, 860, 1200, 1600,
        )
        private val NOTE_FREQUENCIES = intArrayOf(
            90, 91, 92, 92, 93, 94, 94, 95, 96, 96, 97, 98, 98, 99, 100, 101,
            101, 102, 103, 104, 104, 105, 106, 107, 107, 108, 109, 110, 111, 111, 112, 113,
            114, 115, 115, 116, 117, 118, 119, 120, 121, 121, 122, 123, 124, 125, 126, 127,
            128, 129, 130, 131, 132, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142,
            143, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 157, 158, 159, 160,
            161, 162, 163, 165, 166, 167, 168, 169, 171, 172, 173, 174, 176, 177, 178, 180,
            181, 182, 184, 185, 186, 188, 189, 190, 192, 193, 194, 196, 197, 199, 200, 202,
            203, 205, 206, 208, 209, 211, 212, 214, 215, 217, 218, 220, 222, 223, 225, 226,
            228, 230, 231, 233, 235, 236, 238, 240, 242, 243, 245, 247, 249, 251, 252, 254,
        )
        private val VOLUME_TABLE = intArrayOf(
            0, 4, 7, 11, 13, 16, 18, 20, 22, 24, 26, 27, 29, 30, 31, 33,
            34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 44, 45, 46, 47, 47,
            48, 49, 49, 50, 51, 51, 52, 53, 53, 54, 54, 55, 55, 56, 56, 57,
            57, 58, 58, 59, 59, 60, 60, 60, 61, 61, 62, 62, 62, 63, 63, 63,
        )

        /** g_volumeLookupTable[i][j] = i * (j + 1) >> 5 (column 0 is 0); out-of-range rows read as 0. */
        private fun lookup(row: Int, col: Int): Int {
            if (row !in 0 until 64 || col !in 0 until 32 || col == 0) return 0
            return (row * (col + 1)) shr 5
        }

        private fun lookupVolume(a: Int, b: Int): Int {
            if (b == 0) return 0
            if (b == 31) return a
            if (a < -63 || a > 63) return b * (a + 1) shr 5
            return if (b < 0) {
                if (a < 0) lookup(-a, -b) else -lookup(a, -b)
            } else {
                if (a < 0) -lookup(-a, b) else lookup(a, b)
            }
        }

        /** ScummVM audio/adlib.cpp g_gmPercussionInstruments (GPLv2+). */
        private val GM_PERCUSSION = intArrayOf(
            26, 63, 21, 5, 124, 2, 33, 43, 228, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6,
            17, 18, 4, 7, 124, 2, 35, 11, 229, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5,
            10, 63, 11, 1, 124, 31, 28, 70, 208, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
            0, 63, 15, 0, 124, 16, 18, 7, 0, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            15, 63, 11, 0, 124, 31, 15, 25, 208, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            0, 63, 31, 0, 126, 31, 22, 7, 0, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
            18, 63, 5, 6, 124, 3, 31, 74, 217, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
            207, 127, 8, 255, 126, 0, 199, 45, 247, 115, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            18, 63, 5, 6, 124, 67, 33, 12, 233, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
            207, 127, 8, 207, 126, 0, 69, 42, 248, 75, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12,
            18, 63, 6, 23, 124, 3, 39, 11, 233, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
            207, 127, 8, 205, 126, 0, 64, 26, 105, 99, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12,
            19, 63, 5, 6, 124, 3, 23, 10, 217, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
            21, 63, 5, 6, 124, 3, 33, 12, 233, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
            207, 63, 43, 251, 126, 192, 30, 26, 202, 127, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16,
            23, 63, 4, 9, 124, 3, 34, 13, 233, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
            207, 63, 15, 94, 124, 198, 19, 0, 202, 127, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
            207, 63, 126, 157, 124, 200, 192, 10, 186, 116, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6,
            207, 63, 77, 159, 124, 198, 0, 8, 218, 91, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4,
            207, 63, 93, 170, 122, 192, 164, 103, 153, 124, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            207, 63, 74, 253, 124, 207, 0, 89, 234, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            15, 24, 10, 250, 87, 6, 7, 6, 57, 124, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            207, 63, 43, 252, 124, 204, 198, 11, 234, 127, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16,
            5, 26, 4, 0, 124, 18, 16, 12, 234, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7,
            4, 25, 4, 0, 124, 18, 16, 44, 234, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4,
            4, 10, 4, 0, 108, 1, 7, 13, 250, 116, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7,
            21, 20, 5, 0, 125, 1, 7, 92, 233, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5,
            16, 16, 5, 8, 124, 1, 8, 13, 234, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5,
            17, 0, 6, 135, 127, 2, 64, 9, 89, 104, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8,
            19, 38, 4, 106, 127, 1, 0, 8, 90, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8,
            207, 78, 12, 170, 80, 196, 0, 24, 249, 84, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            207, 78, 12, 170, 80, 195, 0, 24, 248, 84, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            203, 63, 143, 0, 126, 197, 0, 152, 214, 95, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 13,
            12, 24, 135, 179, 127, 25, 16, 85, 117, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            5, 17, 21, 0, 100, 2, 8, 8, 0, 92, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            4, 8, 21, 0, 72, 1, 8, 8, 0, 96, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            218, 0, 83, 48, 104, 7, 30, 73, 196, 126, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            28, 0, 7, 188, 108, 12, 20, 11, 106, 126, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
            10, 14, 127, 0, 125, 19, 32, 40, 3, 124, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        )

        /** ScummVM audio/adlib.cpp g_gmPercussionInstrumentMap (GPLv2+). */
        private val GM_PERCUSSION_MAP = intArrayOf(
            255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
            255, 255, 255, 255, 255, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 255, 255,
            23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 255, 255, 255, 255, 255, 33, 34, 35, 255, 255, 36, 37, 255, 255, 255, 38, 255, 255, 255, 255,
            255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
            255, 255, 255, 255, 255, 255, 255, 255,
        )

        /** ScummVM g_gmInstruments: AdLib instruments for General MIDI programs, 30 bytes each. */
        private val GM_INSTRUMENTS = intArrayOf(
            194, 197, 43, 153, 88, 194, 31, 30, 200, 124, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 35,
            34, 83, 14, 138, 48, 20, 6, 29, 122, 92, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            6, 0, 28, 121, 64, 2, 0, 75, 121, 88, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            194, 137, 42, 137, 73, 194, 22, 28, 184, 124, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 35,
            194, 23, 61, 106, 0, 196, 46, 45, 201, 32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            6, 30, 28, 153, 0, 2, 58, 76, 121, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            132, 64, 59, 90, 111, 129, 14, 59, 90, 127, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            132, 64, 59, 90, 99, 129, 0, 59, 90, 127, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            140, 128, 5, 234, 89, 130, 10, 60, 170, 100, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            133, 64, 13, 236, 113, 132, 88, 62, 203, 124, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            138, 192, 12, 220, 80, 136, 88, 61, 218, 124, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            201, 64, 43, 120, 66, 194, 4, 76, 138, 124, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 26,
            42, 14, 23, 137, 40, 34, 12, 27, 9, 112, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            231, 155, 8, 8, 38, 226, 6, 10, 8, 112, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            197, 5, 0, 252, 64, 132, 0, 0, 220, 80, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            134, 64, 93, 90, 65, 129, 0, 11, 90, 127, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            237, 0, 123, 200, 64, 225, 153, 74, 233, 126, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            232, 79, 58, 215, 124, 226, 151, 73, 249, 125, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            225, 16, 47, 247, 125, 243, 69, 143, 199, 98, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            1, 140, 159, 218, 112, 228, 80, 159, 218, 106, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            8, 213, 157, 165, 69, 226, 63, 159, 214, 73, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            229, 15, 125, 184, 46, 162, 15, 124, 199, 97, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            242, 42, 159, 219, 1, 225, 4, 143, 215, 98, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 136, 156, 80, 100, 226, 24, 112, 196, 124, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            2, 163, 13, 218, 1, 194, 53, 93, 88, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 24,
            66, 85, 62, 235, 36, 212, 8, 13, 169, 113, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 24,
            194, 0, 43, 23, 81, 194, 30, 77, 151, 124, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 25,
            198, 1, 45, 167, 68, 194, 6, 14, 167, 121, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            194, 12, 6, 6, 85, 194, 63, 9, 134, 125, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10,
            194, 46, 79, 119, 0, 196, 8, 14, 152, 89, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            194, 48, 79, 202, 1, 196, 13, 14, 184, 127, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            196, 41, 79, 202, 3, 200, 13, 12, 183, 125, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11,
            194, 64, 60, 150, 88, 196, 222, 14, 199, 124, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32,
            49, 19, 45, 215, 60, 226, 24, 46, 184, 124, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            34, 134, 13, 215, 80, 228, 24, 94, 184, 124, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 40,
            242, 10, 13, 215, 64, 228, 31, 94, 184, 124, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            242, 9, 75, 214, 72, 228, 31, 28, 184, 124, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 40,
            98, 17, 12, 230, 60, 228, 31, 12, 200, 124, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 18, 61, 230, 52, 228, 31, 125, 184, 124, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 19, 61, 230, 52, 228, 31, 93, 184, 125, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            162, 64, 93, 186, 63, 226, 0, 143, 216, 121, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 64, 61, 218, 59, 225, 0, 126, 216, 122, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            98, 0, 109, 250, 93, 226, 0, 143, 200, 121, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            225, 0, 78, 219, 74, 227, 24, 111, 233, 126, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            225, 0, 78, 219, 102, 226, 0, 127, 233, 126, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            2, 15, 102, 170, 81, 2, 100, 41, 249, 124, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4,
            22, 74, 4, 186, 57, 194, 88, 45, 202, 124, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
            2, 0, 1, 122, 121, 2, 63, 40, 234, 124, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            98, 83, 156, 186, 49, 98, 91, 173, 201, 85, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            242, 64, 110, 218, 73, 226, 19, 143, 249, 125, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 64, 143, 250, 80, 242, 4, 127, 250, 125, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 160, 206, 91, 2, 226, 50, 127, 251, 61, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            230, 128, 156, 153, 66, 226, 4, 125, 120, 96, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            234, 160, 172, 103, 2, 226, 0, 124, 122, 124, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            231, 148, 173, 183, 3, 226, 0, 124, 186, 124, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            195, 63, 75, 233, 126, 193, 63, 155, 249, 127, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6,
            178, 32, 173, 233, 0, 98, 5, 143, 200, 104, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            242, 0, 143, 251, 80, 246, 71, 143, 233, 104, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            242, 0, 175, 136, 88, 242, 84, 110, 201, 124, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            242, 42, 159, 152, 1, 226, 132, 78, 120, 108, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 2, 159, 184, 72, 34, 137, 159, 232, 124, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 42, 127, 184, 1, 228, 0, 13, 197, 124, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 40, 142, 232, 1, 242, 0, 77, 214, 125, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            98, 35, 143, 234, 0, 242, 0, 94, 217, 124, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            180, 38, 110, 152, 1, 98, 0, 125, 200, 125, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 46, 32, 217, 1, 242, 15, 144, 248, 120, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 40, 126, 248, 1, 226, 35, 142, 232, 125, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            184, 40, 158, 152, 1, 98, 0, 61, 200, 125, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            98, 0, 142, 201, 61, 230, 0, 126, 216, 104, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 0, 95, 249, 72, 230, 152, 143, 248, 125, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            98, 12, 110, 216, 61, 42, 6, 125, 216, 88, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 0, 126, 137, 56, 230, 132, 128, 248, 104, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 128, 108, 217, 48, 226, 0, 141, 200, 124, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 128, 136, 72, 64, 226, 10, 125, 168, 124, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 0, 119, 197, 84, 226, 0, 158, 215, 112, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 128, 134, 185, 100, 226, 5, 159, 215, 120, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 0, 104, 104, 86, 226, 8, 155, 179, 124, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 0, 166, 135, 65, 226, 10, 126, 201, 124, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 128, 154, 184, 72, 226, 0, 158, 249, 96, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 128, 142, 100, 104, 226, 40, 111, 115, 124, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            232, 0, 125, 153, 84, 230, 128, 128, 248, 124, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            230, 0, 159, 185, 109, 225, 0, 143, 200, 125, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 0, 9, 104, 74, 226, 43, 158, 243, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            196, 0, 153, 232, 59, 226, 37, 111, 147, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            230, 0, 111, 218, 105, 226, 5, 47, 216, 106, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            236, 96, 157, 199, 0, 226, 33, 127, 201, 124, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            227, 0, 15, 247, 125, 225, 63, 15, 167, 1, 13, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 169, 15, 168, 2, 226, 60, 95, 218, 60, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            232, 64, 13, 137, 125, 226, 23, 126, 217, 124, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            225, 0, 223, 138, 86, 226, 94, 207, 186, 126, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            226, 0, 11, 104, 96, 226, 1, 158, 184, 124, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            234, 0, 174, 171, 73, 226, 0, 174, 186, 108, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            235, 128, 140, 203, 58, 226, 134, 175, 202, 124, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            229, 64, 219, 59, 60, 226, 128, 190, 202, 113, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            228, 0, 158, 170, 61, 225, 67, 15, 186, 126, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            231, 64, 236, 202, 68, 226, 3, 191, 186, 102, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            234, 0, 104, 184, 72, 226, 10, 142, 184, 124, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            97, 0, 190, 153, 126, 227, 64, 207, 202, 125, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            205, 0, 11, 0, 72, 194, 88, 12, 0, 124, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 28,
            226, 0, 14, 0, 82, 226, 88, 95, 208, 125, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            204, 0, 125, 218, 64, 194, 0, 94, 155, 88, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            233, 192, 238, 216, 67, 226, 5, 221, 170, 112, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            218, 0, 143, 172, 74, 34, 5, 141, 138, 117, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            98, 138, 203, 122, 116, 230, 86, 175, 219, 112, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            194, 65, 172, 91, 91, 194, 128, 13, 203, 125, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 18,
            117, 0, 14, 203, 90, 226, 30, 10, 201, 125, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16,
            65, 0, 14, 234, 83, 194, 0, 8, 202, 124, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7,
            193, 64, 12, 89, 106, 194, 128, 60, 171, 124, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 13,
            75, 0, 10, 245, 97, 194, 25, 12, 233, 124, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7,
            98, 0, 127, 216, 84, 234, 0, 143, 216, 125, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            225, 0, 127, 217, 86, 225, 0, 143, 216, 126, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            225, 0, 127, 217, 86, 225, 0, 143, 216, 126, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            207, 64, 9, 234, 84, 196, 0, 12, 219, 100, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            207, 64, 12, 170, 84, 196, 0, 24, 249, 100, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            201, 14, 136, 217, 62, 194, 8, 26, 234, 108, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5,
            3, 0, 21, 0, 100, 2, 0, 8, 0, 124, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            1, 0, 71, 215, 108, 1, 63, 12, 251, 124, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4,
            0, 0, 54, 103, 124, 1, 63, 14, 250, 124, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5,
            2, 0, 54, 104, 124, 1, 63, 14, 250, 124, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5,
            203, 0, 175, 0, 126, 192, 0, 192, 6, 127, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 15,
            5, 13, 128, 166, 127, 11, 56, 169, 216, 0, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4,
            15, 0, 144, 250, 104, 6, 0, 167, 57, 84, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6,
            201, 21, 221, 255, 124, 0, 0, 231, 252, 108, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 56,
            72, 60, 48, 246, 3, 10, 56, 151, 232, 0, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4,
            7, 128, 11, 200, 101, 2, 63, 12, 234, 124, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5,
            0, 33, 102, 64, 3, 0, 63, 71, 0, 0, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            8, 0, 11, 60, 124, 8, 63, 6, 243, 0, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
            0, 63, 76, 251, 0, 0, 63, 10, 233, 124, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5
        )
    }
}

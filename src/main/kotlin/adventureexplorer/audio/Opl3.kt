package adventureexplorer.audio

/*
 * Kotlin port of the Nuked OPL3 emulator, version 1.8.
 * Copyright (C) 2013-2018 Alexey Khokholov (Nuke.YKT)
 *
 * This file is free software; you can redistribute it and/or modify it under
 * the terms of the GNU Lesser General Public License as published by the Free
 * Software Foundation; either version 2.1 of the License, or (at your option)
 * any later version.
 *
 * Thanks (from the original):
 *     MAME Development Team (Jarek Burczynski, Tatsuyuki Satoh):
 *         Feedback and Rhythm part calculation information.
 *     forums.submarine.org.uk (carbon14, opl3):
 *         Tremolo and phase generator calculation information.
 *     OPLx decapsulated (Matthew Gambrell, Olli Niemitalo):
 *         OPL2 ROMs.
 *     siliconpr0n.org (John McMaster, digshadow):
 *         YMF262 and VRC VII decaps and die shots.
 *
 * Port notes: the C pointers between slots and channels (modulation inputs,
 * channel outputs, tremolo) become small source objects. The stereo extension
 * is left out, so the original's one-sample channel delay quirk is always on.
 * Writes go through the original's write buffer (two samples apart), which
 * keeps quick key-off/key-on pairs audible as a retrigger.
 */
class Opl3(sampleRate: Int) {
    private fun interface Source { fun get(): Int }

    private class Slot(val chip: Opl3, val num: Int) {
        lateinit var channel: Channel
        var out = 0
        var fbmod = 0
        var mod: Source = chip.zero
        var prout = 0
        var egRout = 0x1FF
        var egOut = 0x1FF
        var egGen = EG_RELEASE
        var egKsl = 0
        var tremOn = false
        var regVib = 0
        var regType = 0
        var regKsr = 0
        var regMult = 0
        var regKsl = 0
        var regTl = 0
        var regAr = 0
        var regDr = 0
        var regSl = 0
        var regRr = 0
        var regWf = 0
        var key = 0
        var pgReset = 0
        var pgPhase = 0
        var pgPhaseOut = 0
        val outSrc = Source { out }
        val fbSrc = Source { fbmod }
    }

    private class Channel(val chip: Opl3, val num: Int) {
        lateinit var slot0: Slot
        lateinit var slot1: Slot
        var pair: Channel? = null
        val out = arrayOf(chip.zero, chip.zero, chip.zero, chip.zero)
        var chtype = CH_2OP
        var fNum = 0
        var block = 0
        var fb = 0
        var con = 0
        var alg = 0
        var ksv = 0
        var cha = 0xFFFF
        var chb = 0xFFFF
        var chc = 0
        var chd = 0
    }

    private val zero = Source { 0 }
    private val slots = Array(36) { Slot(this, it) }
    private val channels = Array(18) { Channel(this, it) }

    private var timer = 0
    private var egTimer = 0L
    private var egTimerRem = 0
    private var egState = 0
    private var egAdd = 0
    private var egTimerLo = 0
    private var newm = 0
    private var nts = 0
    private var rhy = 0
    private var vibPos = 0
    private var vibShift = 1
    private var tremolo = 0
    private var tremoloPos = 0
    private var tremoloShift = 4
    private var noise = 1
    private var rmHhBit2 = 0
    private var rmHhBit3 = 0
    private var rmHhBit7 = 0
    private var rmHhBit8 = 0
    private var rmTcBit3 = 0
    private var rmTcBit5 = 0
    private val mixBuff = IntArray(4)

    private val rateRatio = (sampleRate shl RSM_FRAC) / NATIVE_RATE
    private var sampleCnt = 0
    private val oldSamples = IntArray(4)
    private val samples = IntArray(4)

    private val writeBufReg = IntArray(WRITEBUF_SIZE)
    private val writeBufData = IntArray(WRITEBUF_SIZE)
    private val writeBufTime = LongArray(WRITEBUF_SIZE)
    private var writeBufCur = 0
    private var writeBufLast = 0
    private var writeBufLastTime = 0L
    private var writeBufSampleCnt = 0L

    init {
        for (ch in channels) {
            val s = CH_SLOT[ch.num]
            ch.slot0 = slots[s]
            ch.slot1 = slots[s + 3]
            slots[s].channel = ch
            slots[s + 3].channel = ch
            ch.pair = when (ch.num % 9) {
                in 0..2 -> channels[ch.num + 3]
                in 3..5 -> channels[ch.num - 3]
                else -> null
            }
            setupAlg(ch)
        }
    }

    /** Queues a register write; it reaches the chip two samples after the previous one. */
    fun writeReg(reg: Int, value: Int) {
        val last = writeBufLast
        if (writeBufReg[last] and 0x200 != 0) {
            writeRegNow(writeBufReg[last] and 0x1FF, writeBufData[last])
            writeBufCur = (last + 1) % WRITEBUF_SIZE
            writeBufSampleCnt = writeBufTime[last]
        }
        writeBufReg[last] = (reg and 0x1FF) or 0x200
        writeBufData[last] = value and 0xFF
        val time = maxOf(writeBufLastTime + WRITEBUF_DELAY, writeBufSampleCnt)
        writeBufTime[last] = time
        writeBufLastTime = time
        writeBufLast = (last + 1) % WRITEBUF_SIZE
    }

    /** One stereo frame at the rate given to the constructor: [left, right]. */
    fun generate(out: IntArray) {
        while (sampleCnt >= rateRatio) {
            for (i in 0..3) oldSamples[i] = samples[i]
            generate4Ch(samples)
            sampleCnt -= rateRatio
        }
        out[0] = (oldSamples[0] * (rateRatio - sampleCnt) + samples[0] * sampleCnt) / rateRatio
        out[1] = (oldSamples[1] * (rateRatio - sampleCnt) + samples[1] * sampleCnt) / rateRatio
        sampleCnt += 1 shl RSM_FRAC
    }

    // ── Envelope generator ───────────────────────────────────────

    private fun envelopeCalcExp(level: Int): Int {
        val l = if (level > 0x1FFF) 0x1FFF else level
        return (EXP_ROM[l and 0xFF] shl 1) shr (l shr 8)
    }

    private fun envelopeSin(wf: Int, phaseIn: Int, envelope: Int): Int {
        var phase = phaseIn and 0x3FF
        val env = envelope shl 3
        var neg = 0
        val out: Int
        when (wf) {
            0 -> {
                if (phase and 0x200 != 0) neg = 0xFFFF
                out = if (phase and 0x100 != 0) LOGSIN_ROM[(phase and 0xFF) xor 0xFF] else LOGSIN_ROM[phase and 0xFF]
            }
            1 -> out = when {
                phase and 0x200 != 0 -> 0x1000
                phase and 0x100 != 0 -> LOGSIN_ROM[(phase and 0xFF) xor 0xFF]
                else -> LOGSIN_ROM[phase and 0xFF]
            }
            2 -> out = if (phase and 0x100 != 0) LOGSIN_ROM[(phase and 0xFF) xor 0xFF] else LOGSIN_ROM[phase and 0xFF]
            3 -> out = if (phase and 0x100 != 0) 0x1000 else LOGSIN_ROM[phase and 0xFF]
            4 -> {
                if (phase and 0x300 == 0x100) neg = 0xFFFF
                out = when {
                    phase and 0x200 != 0 -> 0x1000
                    phase and 0x80 != 0 -> LOGSIN_ROM[((phase xor 0xFF) shl 1) and 0xFF]
                    else -> LOGSIN_ROM[(phase shl 1) and 0xFF]
                }
            }
            5 -> out = when {
                phase and 0x200 != 0 -> 0x1000
                phase and 0x80 != 0 -> LOGSIN_ROM[((phase xor 0xFF) shl 1) and 0xFF]
                else -> LOGSIN_ROM[(phase shl 1) and 0xFF]
            }
            6 -> {
                if (phase and 0x200 != 0) neg = 0xFFFF
                out = 0
            }
            else -> {
                if (phase and 0x200 != 0) {
                    neg = 0xFFFF
                    phase = (phase and 0x1FF) xor 0x1FF
                }
                out = phase shl 3
            }
        }
        return (envelopeCalcExp(out + env) xor neg).toShort().toInt()
    }

    private fun updateKsl(slot: Slot) {
        val ksl = (KSL_ROM[slot.channel.fNum shr 6] shl 2) - ((0x08 - slot.channel.block) shl 5)
        slot.egKsl = if (ksl < 0) 0 else ksl and 0xFF
    }

    private fun envelopeCalc(slot: Slot) {
        var regRate = 0
        var reset = 0
        slot.egOut = (slot.egRout + (slot.regTl shl 2) + (slot.egKsl shr KSL_SHIFT[slot.regKsl]) +
            (if (slot.tremOn) tremolo else 0)) and 0xFFFF
        if (slot.key != 0 && slot.egGen == EG_RELEASE) {
            reset = 1
            regRate = slot.regAr
        } else {
            when (slot.egGen) {
                EG_ATTACK -> regRate = slot.regAr
                EG_DECAY -> regRate = slot.regDr
                EG_SUSTAIN -> if (slot.regType == 0) regRate = slot.regRr
                EG_RELEASE -> regRate = slot.regRr
            }
        }
        slot.pgReset = reset
        val ks = slot.channel.ksv shr ((slot.regKsr xor 1) shl 1)
        val nonzero = regRate != 0
        val rate = (ks + (regRate shl 2)) and 0xFF
        var rateHi = rate shr 2
        val rateLo = rate and 0x03
        if (rateHi and 0x10 != 0) rateHi = 0x0F
        val egShift = rateHi + egAdd
        var shift = 0
        if (nonzero) {
            if (rateHi < 12) {
                if (egState != 0) {
                    shift = when (egShift) {
                        12 -> 1
                        13 -> (rateLo shr 1) and 0x01
                        14 -> rateLo and 0x01
                        else -> 0
                    }
                }
            } else {
                shift = (rateHi and 0x03) + EG_INCSTEP[rateLo][egTimerLo]
                if (shift and 0x04 != 0) shift = 0x03
                if (shift == 0) shift = egState
            }
        }
        var egRout = slot.egRout
        var egInc = 0
        var egOff = false
        // Instant attack
        if (reset != 0 && rateHi == 0x0F) egRout = 0x00
        // Envelope off
        if (slot.egRout and 0x1F8 == 0x1F8) egOff = true
        if (slot.egGen != EG_ATTACK && reset == 0 && egOff) egRout = 0x1FF
        when (slot.egGen) {
            EG_ATTACK -> if (slot.egRout == 0) {
                slot.egGen = EG_DECAY
            } else if (slot.key != 0 && shift > 0 && rateHi != 0x0F) {
                egInc = slot.egRout.inv() shr (4 - shift)
            }
            EG_DECAY -> if ((slot.egRout shr 4) == slot.regSl) {
                slot.egGen = EG_SUSTAIN
            } else if (!egOff && reset == 0 && shift > 0) {
                egInc = 1 shl (shift - 1)
            }
            EG_SUSTAIN, EG_RELEASE -> if (!egOff && reset == 0 && shift > 0) egInc = 1 shl (shift - 1)
        }
        slot.egRout = (egRout + egInc) and 0x1FF
        // Key off
        if (reset != 0) slot.egGen = EG_ATTACK
        if (slot.key == 0) slot.egGen = EG_RELEASE
    }

    // ── Phase generator ──────────────────────────────────────────

    private fun phaseGenerate(slot: Slot) {
        var fNum = slot.channel.fNum
        if (slot.regVib != 0) {
            var range = (fNum shr 7) and 7
            if (vibPos and 3 == 0) range = 0 else if (vibPos and 1 != 0) range = range shr 1
            range = range shr vibShift
            if (vibPos and 4 != 0) range = -range
            fNum = (fNum + range) and 0xFFFF
        }
        val baseFreq = (fNum shl slot.channel.block) ushr 1
        val phase = (slot.pgPhase ushr 9) and 0xFFFF
        if (slot.pgReset != 0) slot.pgPhase = 0
        slot.pgPhase += (baseFreq * MT[slot.regMult]) ushr 1
        // Rhythm mode
        val n = noise
        slot.pgPhaseOut = phase
        if (slot.num == 13) { // hh
            rmHhBit2 = (phase shr 2) and 1
            rmHhBit3 = (phase shr 3) and 1
            rmHhBit7 = (phase shr 7) and 1
            rmHhBit8 = (phase shr 8) and 1
        }
        if (slot.num == 17 && rhy and 0x20 != 0) { // tc
            rmTcBit3 = (phase shr 3) and 1
            rmTcBit5 = (phase shr 5) and 1
        }
        if (rhy and 0x20 != 0) {
            val rmXor = (rmHhBit2 xor rmHhBit7) or (rmHhBit3 xor rmTcBit5) or (rmTcBit3 xor rmTcBit5)
            when (slot.num) {
                13 -> slot.pgPhaseOut = (rmXor shl 9) or (if (rmXor xor (n and 1) != 0) 0xD0 else 0x34)
                16 -> slot.pgPhaseOut = (rmHhBit8 shl 9) or ((rmHhBit8 xor (n and 1)) shl 8)
                17 -> slot.pgPhaseOut = (rmXor shl 9) or 0x80
            }
        }
        val nBit = ((n shr 14) xor n) and 0x01
        noise = (n ushr 1) or (nBit shl 22)
    }

    // ── Slot ─────────────────────────────────────────────────────

    private fun slotWrite20(slot: Slot, data: Int) {
        slot.tremOn = (data shr 7) and 1 != 0
        slot.regVib = (data shr 6) and 1
        slot.regType = (data shr 5) and 1
        slot.regKsr = (data shr 4) and 1
        slot.regMult = data and 0x0F
    }

    private fun slotWrite40(slot: Slot, data: Int) {
        slot.regKsl = (data shr 6) and 0x03
        slot.regTl = data and 0x3F
        updateKsl(slot)
    }

    private fun slotWrite60(slot: Slot, data: Int) {
        slot.regAr = (data shr 4) and 0x0F
        slot.regDr = data and 0x0F
    }

    private fun slotWrite80(slot: Slot, data: Int) {
        slot.regSl = (data shr 4) and 0x0F
        if (slot.regSl == 0x0F) slot.regSl = 0x1F
        slot.regRr = data and 0x0F
    }

    private fun slotWriteE0(slot: Slot, data: Int) {
        slot.regWf = data and 0x07
        if (newm == 0) slot.regWf = slot.regWf and 0x03
    }

    private fun processSlot(slot: Slot) {
        // Feedback
        slot.fbmod = if (slot.channel.fb != 0) (slot.prout + slot.out) shr (0x09 - slot.channel.fb) else 0
        slot.prout = slot.out
        envelopeCalc(slot)
        phaseGenerate(slot)
        slot.out = envelopeSin(slot.regWf, slot.pgPhaseOut + slot.mod.get(), slot.egOut)
    }

    // ── Channel ──────────────────────────────────────────────────

    private fun keyOn(slot: Slot, type: Int) { slot.key = slot.key or type }
    private fun keyOff(slot: Slot, type: Int) { slot.key = slot.key and type.inv() }

    private fun updateRhythm(data: Int) {
        rhy = data and 0x3F
        if (rhy and 0x20 != 0) {
            val c6 = channels[6]
            val c7 = channels[7]
            val c8 = channels[8]
            c6.out[0] = c6.slot1.outSrc; c6.out[1] = c6.slot1.outSrc; c6.out[2] = zero; c6.out[3] = zero
            c7.out[0] = c7.slot0.outSrc; c7.out[1] = c7.slot0.outSrc; c7.out[2] = c7.slot1.outSrc; c7.out[3] = c7.slot1.outSrc
            c8.out[0] = c8.slot0.outSrc; c8.out[1] = c8.slot0.outSrc; c8.out[2] = c8.slot1.outSrc; c8.out[3] = c8.slot1.outSrc
            for (n in 6..8) channels[n].chtype = CH_DRUM
            setupAlg(c6); setupAlg(c7); setupAlg(c8)
            if (rhy and 0x01 != 0) keyOn(c7.slot0, EGK_DRUM) else keyOff(c7.slot0, EGK_DRUM) // hh
            if (rhy and 0x02 != 0) keyOn(c8.slot1, EGK_DRUM) else keyOff(c8.slot1, EGK_DRUM) // tc
            if (rhy and 0x04 != 0) keyOn(c8.slot0, EGK_DRUM) else keyOff(c8.slot0, EGK_DRUM) // tom
            if (rhy and 0x08 != 0) keyOn(c7.slot1, EGK_DRUM) else keyOff(c7.slot1, EGK_DRUM) // sd
            if (rhy and 0x10 != 0) { // bd
                keyOn(c6.slot0, EGK_DRUM); keyOn(c6.slot1, EGK_DRUM)
            } else {
                keyOff(c6.slot0, EGK_DRUM); keyOff(c6.slot1, EGK_DRUM)
            }
        } else {
            for (n in 6..8) {
                val ch = channels[n]
                ch.chtype = CH_2OP
                setupAlg(ch)
                keyOff(ch.slot0, EGK_DRUM)
                keyOff(ch.slot1, EGK_DRUM)
            }
        }
    }

    /** Register A0 copies only the frequency to a 4-op pair; B0 copies the block too. */
    private fun updateFrequencyKsl(ch: Channel, withBlock: Boolean) {
        ch.ksv = (ch.block shl 1) or ((ch.fNum shr (0x09 - nts)) and 0x01)
        updateKsl(ch.slot0)
        updateKsl(ch.slot1)
        val pair = ch.pair
        if (newm != 0 && ch.chtype == CH_4OP && pair != null) {
            pair.fNum = ch.fNum
            if (withBlock) pair.block = ch.block
            pair.ksv = ch.ksv
            updateKsl(pair.slot0)
            updateKsl(pair.slot1)
        }
    }

    private fun channelWriteA0(ch: Channel, data: Int) {
        if (newm != 0 && ch.chtype == CH_4OP2) return
        ch.fNum = (ch.fNum and 0x300) or data
        updateFrequencyKsl(ch, withBlock = false)
    }

    private fun channelWriteB0(ch: Channel, data: Int) {
        if (newm != 0 && ch.chtype == CH_4OP2) return
        ch.fNum = (ch.fNum and 0xFF) or ((data and 0x03) shl 8)
        ch.block = (data shr 2) and 0x07
        updateFrequencyKsl(ch, withBlock = true)
    }

    private fun setupAlg(ch: Channel) {
        if (ch.chtype == CH_DRUM) {
            if (ch.num == 7 || ch.num == 8) {
                ch.slot0.mod = zero
                ch.slot1.mod = zero
                return
            }
            ch.slot0.mod = ch.slot0.fbSrc
            ch.slot1.mod = if (ch.alg and 0x01 == 0) ch.slot0.outSrc else zero
            return
        }
        if (ch.alg and 0x08 != 0) return
        val pair = ch.pair
        if (ch.alg and 0x04 != 0 && pair != null) {
            for (i in 0..3) pair.out[i] = zero
            pair.slot0.mod = pair.slot0.fbSrc
            when (ch.alg and 0x03) {
                0x00 -> {
                    pair.slot1.mod = pair.slot0.outSrc
                    ch.slot0.mod = pair.slot1.outSrc
                    ch.slot1.mod = ch.slot0.outSrc
                    setOut(ch, ch.slot1.outSrc, zero, zero)
                }
                0x01 -> {
                    pair.slot1.mod = pair.slot0.outSrc
                    ch.slot0.mod = zero
                    ch.slot1.mod = ch.slot0.outSrc
                    setOut(ch, pair.slot1.outSrc, ch.slot1.outSrc, zero)
                }
                0x02 -> {
                    pair.slot1.mod = zero
                    ch.slot0.mod = pair.slot1.outSrc
                    ch.slot1.mod = ch.slot0.outSrc
                    setOut(ch, pair.slot0.outSrc, ch.slot1.outSrc, zero)
                }
                else -> {
                    pair.slot1.mod = zero
                    ch.slot0.mod = pair.slot1.outSrc
                    ch.slot1.mod = zero
                    setOut(ch, pair.slot0.outSrc, ch.slot0.outSrc, ch.slot1.outSrc)
                }
            }
        } else {
            ch.slot0.mod = ch.slot0.fbSrc
            if (ch.alg and 0x01 == 0) {
                ch.slot1.mod = ch.slot0.outSrc
                setOut(ch, ch.slot1.outSrc, zero, zero)
            } else {
                ch.slot1.mod = zero
                setOut(ch, ch.slot0.outSrc, ch.slot1.outSrc, zero)
            }
        }
    }

    private fun setOut(ch: Channel, a: Source, b: Source, c: Source) {
        ch.out[0] = a; ch.out[1] = b; ch.out[2] = c; ch.out[3] = zero
    }

    private fun updateAlg(ch: Channel) {
        ch.alg = ch.con
        val pair = ch.pair
        if (newm != 0 && pair != null && ch.chtype == CH_4OP) {
            pair.alg = 0x04 or (ch.con shl 1) or pair.con
            ch.alg = 0x08
            setupAlg(pair)
        } else if (newm != 0 && pair != null && ch.chtype == CH_4OP2) {
            ch.alg = 0x04 or (pair.con shl 1) or ch.con
            pair.alg = 0x08
            setupAlg(ch)
        } else {
            setupAlg(ch)
        }
    }

    private fun channelWriteC0(ch: Channel, data: Int) {
        ch.fb = (data and 0x0E) shr 1
        ch.con = data and 0x01
        updateAlg(ch)
        if (newm != 0) {
            ch.cha = if ((data shr 4) and 1 != 0) 0xFFFF else 0
            ch.chb = if ((data shr 5) and 1 != 0) 0xFFFF else 0
            ch.chc = if ((data shr 6) and 1 != 0) 0xFFFF else 0
            ch.chd = if ((data shr 7) and 1 != 0) 0xFFFF else 0
        } else {
            ch.cha = 0xFFFF; ch.chb = 0xFFFF
            ch.chc = 0; ch.chd = 0
        }
    }

    private fun channelKey(ch: Channel, on: Boolean) {
        val set: (Slot) -> Unit = if (on) { s -> keyOn(s, EGK_NORM) } else { s -> keyOff(s, EGK_NORM) }
        val pair = ch.pair
        if (newm != 0) {
            if (ch.chtype == CH_4OP && pair != null) {
                set(ch.slot0); set(ch.slot1); set(pair.slot0); set(pair.slot1)
            } else if (ch.chtype == CH_2OP || ch.chtype == CH_DRUM) {
                set(ch.slot0); set(ch.slot1)
            }
        } else {
            set(ch.slot0); set(ch.slot1)
        }
    }

    private fun set4Op(data: Int) {
        for (bit in 0 until 6) {
            val n = if (bit >= 3) bit + 9 - 3 else bit
            if ((data shr bit) and 1 != 0) {
                channels[n].chtype = CH_4OP
                channels[n + 3].chtype = CH_4OP2
                updateAlg(channels[n])
            } else {
                channels[n].chtype = CH_2OP
                channels[n + 3].chtype = CH_2OP
                updateAlg(channels[n])
                updateAlg(channels[n + 3])
            }
        }
    }

    // ── Sample generation ────────────────────────────────────────

    private fun clip(sample: Int): Int = sample.coerceIn(-32768, 32767)

    private fun mix(left: Boolean): Int {
        var a = 0
        var b = 0
        for (ch in channels) {
            val accm = (ch.out[0].get() + ch.out[1].get() + ch.out[2].get() + ch.out[3].get()).toShort().toInt()
            a += (accm and (if (left) ch.cha else ch.chb)).toShort().toInt()
            b += (accm and (if (left) ch.chc else ch.chd)).toShort().toInt()
        }
        if (left) { mixBuff[0] = a; mixBuff[2] = b } else { mixBuff[1] = a; mixBuff[3] = b }
        return a
    }

    private fun generate4Ch(buf: IntArray) {
        buf[1] = clip(mixBuff[1])
        buf[3] = clip(mixBuff[3])
        for (i in 0 until 15) processSlot(slots[i])
        mix(left = true)
        for (i in 15 until 18) processSlot(slots[i])
        buf[0] = clip(mixBuff[0])
        buf[2] = clip(mixBuff[2])
        for (i in 18 until 33) processSlot(slots[i])
        mix(left = false)
        for (i in 33 until 36) processSlot(slots[i])

        if (timer and 0x3F == 0x3F) tremoloPos = (tremoloPos + 1) % 210
        tremolo = (if (tremoloPos < 105) tremoloPos else 210 - tremoloPos) shr tremoloShift
        if (timer and 0x3FF == 0x3FF) vibPos = (vibPos + 1) and 7
        timer = (timer + 1) and 0xFFFF

        if (egState != 0) {
            var shift = 0
            while (shift < 13 && ((egTimer shr shift) and 1L) == 0L) shift++
            egAdd = if (shift > 12) 0 else shift + 1
            egTimerLo = (egTimer and 0x3L).toInt()
        }
        if (egTimerRem != 0 || egState != 0) {
            if (egTimer == 0xFFFFFFFFFL) {
                egTimer = 0
                egTimerRem = 1
            } else {
                egTimer++
                egTimerRem = 0
            }
        }
        egState = egState xor 1

        while (writeBufTime[writeBufCur] <= writeBufSampleCnt) {
            if (writeBufReg[writeBufCur] and 0x200 == 0) break
            writeBufReg[writeBufCur] = writeBufReg[writeBufCur] and 0x1FF
            writeRegNow(writeBufReg[writeBufCur], writeBufData[writeBufCur])
            writeBufCur = (writeBufCur + 1) % WRITEBUF_SIZE
        }
        writeBufSampleCnt++
    }

    private fun writeRegNow(reg: Int, v: Int) {
        val high = (reg shr 8) and 0x01
        val regm = reg and 0xFF
        val slotIndex = AD_SLOT[regm and 0x1F]
        val chIndex = 9 * high + (regm and 0x0F)
        when (regm and 0xF0) {
            0x00 -> if (high != 0) {
                when (regm and 0x0F) {
                    0x04 -> set4Op(v)
                    0x05 -> newm = v and 0x01
                }
            } else if (regm and 0x0F == 0x08) {
                nts = (v shr 6) and 0x01
            }
            0x20, 0x30 -> if (slotIndex >= 0) slotWrite20(slots[18 * high + slotIndex], v)
            0x40, 0x50 -> if (slotIndex >= 0) slotWrite40(slots[18 * high + slotIndex], v)
            0x60, 0x70 -> if (slotIndex >= 0) slotWrite60(slots[18 * high + slotIndex], v)
            0x80, 0x90 -> if (slotIndex >= 0) slotWrite80(slots[18 * high + slotIndex], v)
            0xE0, 0xF0 -> if (slotIndex >= 0) slotWriteE0(slots[18 * high + slotIndex], v)
            0xA0 -> if (regm and 0x0F < 9) channelWriteA0(channels[chIndex], v)
            0xB0 -> if (regm == 0xBD && high == 0) {
                tremoloShift = (((v shr 7) xor 1) shl 1) + 2
                vibShift = ((v shr 6) and 0x01) xor 1
                updateRhythm(v)
            } else if (regm and 0x0F < 9) {
                channelWriteB0(channels[chIndex], v)
                channelKey(channels[chIndex], v and 0x20 != 0)
            }
            0xC0 -> if (regm and 0x0F < 9) channelWriteC0(channels[chIndex], v)
        }
    }

    companion object {
        const val NATIVE_RATE = 49716
        private const val RSM_FRAC = 10
        private const val WRITEBUF_SIZE = 1024
        private const val WRITEBUF_DELAY = 2L

        private const val CH_2OP = 0
        private const val CH_4OP = 1
        private const val CH_4OP2 = 2
        private const val CH_DRUM = 3
        private const val EGK_NORM = 0x01
        private const val EGK_DRUM = 0x02
        private const val EG_ATTACK = 0
        private const val EG_DECAY = 1
        private const val EG_SUSTAIN = 2
        private const val EG_RELEASE = 3

        private val LOGSIN_ROM = intArrayOf(
            0x859, 0x6c3, 0x607, 0x58b, 0x52e, 0x4e4, 0x4a6, 0x471, 0x443, 0x41a, 0x3f5, 0x3d3, 0x3b5, 0x398, 0x37e, 0x365,
            0x34e, 0x339, 0x324, 0x311, 0x2ff, 0x2ed, 0x2dc, 0x2cd, 0x2bd, 0x2af, 0x2a0, 0x293, 0x286, 0x279, 0x26d, 0x261,
            0x256, 0x24b, 0x240, 0x236, 0x22c, 0x222, 0x218, 0x20f, 0x206, 0x1fd, 0x1f5, 0x1ec, 0x1e4, 0x1dc, 0x1d4, 0x1cd,
            0x1c5, 0x1be, 0x1b7, 0x1b0, 0x1a9, 0x1a2, 0x19b, 0x195, 0x18f, 0x188, 0x182, 0x17c, 0x177, 0x171, 0x16b, 0x166,
            0x160, 0x15b, 0x155, 0x150, 0x14b, 0x146, 0x141, 0x13c, 0x137, 0x133, 0x12e, 0x129, 0x125, 0x121, 0x11c, 0x118,
            0x114, 0x10f, 0x10b, 0x107, 0x103, 0x0ff, 0x0fb, 0x0f8, 0x0f4, 0x0f0, 0x0ec, 0x0e9, 0x0e5, 0x0e2, 0x0de, 0x0db,
            0x0d7, 0x0d4, 0x0d1, 0x0cd, 0x0ca, 0x0c7, 0x0c4, 0x0c1, 0x0be, 0x0bb, 0x0b8, 0x0b5, 0x0b2, 0x0af, 0x0ac, 0x0a9,
            0x0a7, 0x0a4, 0x0a1, 0x09f, 0x09c, 0x099, 0x097, 0x094, 0x092, 0x08f, 0x08d, 0x08a, 0x088, 0x086, 0x083, 0x081,
            0x07f, 0x07d, 0x07a, 0x078, 0x076, 0x074, 0x072, 0x070, 0x06e, 0x06c, 0x06a, 0x068, 0x066, 0x064, 0x062, 0x060,
            0x05e, 0x05c, 0x05b, 0x059, 0x057, 0x055, 0x053, 0x052, 0x050, 0x04e, 0x04d, 0x04b, 0x04a, 0x048, 0x046, 0x045,
            0x043, 0x042, 0x040, 0x03f, 0x03e, 0x03c, 0x03b, 0x039, 0x038, 0x037, 0x035, 0x034, 0x033, 0x031, 0x030, 0x02f,
            0x02e, 0x02d, 0x02b, 0x02a, 0x029, 0x028, 0x027, 0x026, 0x025, 0x024, 0x023, 0x022, 0x021, 0x020, 0x01f, 0x01e,
            0x01d, 0x01c, 0x01b, 0x01a, 0x019, 0x018, 0x017, 0x017, 0x016, 0x015, 0x014, 0x014, 0x013, 0x012, 0x011, 0x011,
            0x010, 0x00f, 0x00f, 0x00e, 0x00d, 0x00d, 0x00c, 0x00c, 0x00b, 0x00a, 0x00a, 0x009, 0x009, 0x008, 0x008, 0x007,
            0x007, 0x007, 0x006, 0x006, 0x005, 0x005, 0x005, 0x004, 0x004, 0x004, 0x003, 0x003, 0x003, 0x002, 0x002, 0x002,
            0x002, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000
        )

        private val EXP_ROM = intArrayOf(
            0x7fa, 0x7f5, 0x7ef, 0x7ea, 0x7e4, 0x7df, 0x7da, 0x7d4, 0x7cf, 0x7c9, 0x7c4, 0x7bf, 0x7b9, 0x7b4, 0x7ae, 0x7a9,
            0x7a4, 0x79f, 0x799, 0x794, 0x78f, 0x78a, 0x784, 0x77f, 0x77a, 0x775, 0x770, 0x76a, 0x765, 0x760, 0x75b, 0x756,
            0x751, 0x74c, 0x747, 0x742, 0x73d, 0x738, 0x733, 0x72e, 0x729, 0x724, 0x71f, 0x71a, 0x715, 0x710, 0x70b, 0x706,
            0x702, 0x6fd, 0x6f8, 0x6f3, 0x6ee, 0x6e9, 0x6e5, 0x6e0, 0x6db, 0x6d6, 0x6d2, 0x6cd, 0x6c8, 0x6c4, 0x6bf, 0x6ba,
            0x6b5, 0x6b1, 0x6ac, 0x6a8, 0x6a3, 0x69e, 0x69a, 0x695, 0x691, 0x68c, 0x688, 0x683, 0x67f, 0x67a, 0x676, 0x671,
            0x66d, 0x668, 0x664, 0x65f, 0x65b, 0x657, 0x652, 0x64e, 0x649, 0x645, 0x641, 0x63c, 0x638, 0x634, 0x630, 0x62b,
            0x627, 0x623, 0x61e, 0x61a, 0x616, 0x612, 0x60e, 0x609, 0x605, 0x601, 0x5fd, 0x5f9, 0x5f5, 0x5f0, 0x5ec, 0x5e8,
            0x5e4, 0x5e0, 0x5dc, 0x5d8, 0x5d4, 0x5d0, 0x5cc, 0x5c8, 0x5c4, 0x5c0, 0x5bc, 0x5b8, 0x5b4, 0x5b0, 0x5ac, 0x5a8,
            0x5a4, 0x5a0, 0x59c, 0x599, 0x595, 0x591, 0x58d, 0x589, 0x585, 0x581, 0x57e, 0x57a, 0x576, 0x572, 0x56f, 0x56b,
            0x567, 0x563, 0x560, 0x55c, 0x558, 0x554, 0x551, 0x54d, 0x549, 0x546, 0x542, 0x53e, 0x53b, 0x537, 0x534, 0x530,
            0x52c, 0x529, 0x525, 0x522, 0x51e, 0x51b, 0x517, 0x514, 0x510, 0x50c, 0x509, 0x506, 0x502, 0x4ff, 0x4fb, 0x4f8,
            0x4f4, 0x4f1, 0x4ed, 0x4ea, 0x4e7, 0x4e3, 0x4e0, 0x4dc, 0x4d9, 0x4d6, 0x4d2, 0x4cf, 0x4cc, 0x4c8, 0x4c5, 0x4c2,
            0x4be, 0x4bb, 0x4b8, 0x4b5, 0x4b1, 0x4ae, 0x4ab, 0x4a8, 0x4a4, 0x4a1, 0x49e, 0x49b, 0x498, 0x494, 0x491, 0x48e,
            0x48b, 0x488, 0x485, 0x482, 0x47e, 0x47b, 0x478, 0x475, 0x472, 0x46f, 0x46c, 0x469, 0x466, 0x463, 0x460, 0x45d,
            0x45a, 0x457, 0x454, 0x451, 0x44e, 0x44b, 0x448, 0x445, 0x442, 0x43f, 0x43c, 0x439, 0x436, 0x433, 0x430, 0x42d,
            0x42a, 0x428, 0x425, 0x422, 0x41f, 0x41c, 0x419, 0x416, 0x414, 0x411, 0x40e, 0x40b, 0x408, 0x406, 0x403, 0x400
        )

        /** Frequency multipliers times two: 1/2, 1, 2, ... 10, 10, 12, 12, 15, 15. */
        private val MT = intArrayOf(1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30)
        private val KSL_ROM = intArrayOf(0, 32, 40, 45, 48, 51, 53, 55, 56, 58, 59, 60, 61, 62, 63, 64)
        private val KSL_SHIFT = intArrayOf(8, 1, 2, 0)
        private val EG_INCSTEP = arrayOf(
            intArrayOf(0, 0, 0, 0), intArrayOf(1, 0, 0, 0), intArrayOf(1, 0, 1, 0), intArrayOf(1, 1, 1, 0)
        )
        private val AD_SLOT = intArrayOf(
            0, 1, 2, 3, 4, 5, -1, -1, 6, 7, 8, 9, 10, 11, -1, -1,
            12, 13, 14, 15, 16, 17, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1
        )
        private val CH_SLOT = intArrayOf(0, 1, 2, 6, 7, 8, 12, 13, 14, 18, 19, 20, 24, 25, 26, 30, 31, 32)
    }
}

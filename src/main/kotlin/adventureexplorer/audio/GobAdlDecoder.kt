package adventureexplorer.audio

import adventureexplorer.model.SoundData

/**
 * Renders Coktel Vision's ADL songs and AdLib Visual Composer MUS/SND (MDY/TBR)
 * songs to PCM for preview/export.
 *
 * The songs drive an emulated OPL2 ([Opl3] in OPL2 mode) through a port of
 * ScummVM's Gob AdLib driver (`engines/gob/sound/adlib.cpp`): instrument
 * parameters, volume scaling, pitch-bend tables and the percussion voices are
 * written to the chip registers the way the games do. Game execution still
 * belongs to a full Gob interpreter; this only plays the music.
 */
object GobAdlDecoder {
    private const val SAMPLE_RATE = 44_100
    private const val MAX_DURATION_MS = 10 * 60 * 1000
    private const val RELEASE_TAIL_MS = 250
    private const val PARAM_COUNT = 14
    private const val TIMBRE_WORDS = PARAM_COUNT * 2
    private const val VOICE_COUNT = 11
    private const val MELODY_VOICES = 9

    private sealed interface Command {
        data class NoteOn(val voice: Int, val note: Int, val volume: Int?) : Command
        data class NoteOff(val voice: Int) : Command
        data class Volume(val voice: Int, val value: Int) : Command
        data class Instrument(val voice: Int, val value: Int) : Command
        data class Pitch(val voice: Int, val value: Int) : Command
        data class ModifyInstrument(val instrument: Int, val param: Int, val value: Int) : Command
    }

    private data class Event(val timeMs: Double, val command: Command)

    private class Song(
        val timbres: Array<IntArray>,
        val percussion: Boolean,
        val pitchRange: Int,
        val events: List<Event>,
        val durationMs: Double,
        /** ADL resets every voice to instrument 0 at full volume before playing. */
        val adlVoiceSetup: Boolean,
    )

    fun decode(data: ByteArray): SoundData? {
        if (data.size < 60) return null

        val percussionMode = u8(data, 0) != 0
        val timbreCount = u8(data, 1) + 1
        val songOffset = 3 + timbreCount * TIMBRE_WORDS * 2
        if (timbreCount !in 1..256 || songOffset >= data.size) return null

        val timbres = Array(timbreCount) { instrument ->
            IntArray(TIMBRE_WORDS) { param -> u16le(data, 3 + (instrument * TIMBRE_WORDS + param) * 2) }
        }
        val parsed = parseEvents(data, songOffset) ?: return null
        return render(Song(timbres, percussionMode, 1, parsed.first, parsed.second, adlVoiceSetup = true))
    }

    /** AdLib Visual Composer MUS/SND, named MDY/TBR in Fascination. */
    fun decodeMdy(data: ByteArray, instruments: ByteArray): SoundData? = runCatching {
        require(data.size >= 71 && instruments.size >= 6)
        require(u8(data, 0) == 1 && u8(instruments, 0) == 1)
        val timbreCount = u16le(instruments, 2)
        val timbreOffset = u16le(instruments, 4)
        require(timbreCount in 1..256 && timbreOffset >= 6 + timbreCount * 9)
        require(timbreOffset + timbreCount * TIMBRE_WORDS * 2 == instruments.size)
        val timbres = Array(timbreCount) { i -> IntArray(TIMBRE_WORDS) { p -> u16le(instruments, timbreOffset + (i * TIMBRE_WORDS + p) * 2) } }
        val ticksPerBeat = u8(data, 36)
        val length = u16le(data, 42).toLong() or (u16le(data, 44).toLong() shl 16)
        require(length in 1..(data.size - 70).toLong() && ticksPerBeat > 0)
        val end = 70 + length.toInt()
        val baseTempo = u16le(data, 60)
        require(baseTempo > 0)
        // The player's timer runs at ticksPerBeat * tempo / 60 Hz (integer division).
        var tickMs = 0.0
        fun setTempo(tempo: Int) {
            val hz = ticksPerBeat * tempo / 60
            require(hz > 0)
            tickMs = 1000.0 / hz
        }
        setTempo(baseTempo)
        var pos = 70
        fun byte(): Int { require(pos < end); return u8(data, pos++) }
        var time = 0.0
        fun delay(n: Int) {
            var ticks = n
            if (ticks == 0xF8) { ticks = 240; if (pos < end && u8(data, pos) != 0xF8) ticks += byte() }
            time += ticks * tickMs
            require(time <= MAX_DURATION_MS)
        }
        delay(byte())
        val events = mutableListOf<Event>()
        var last = 0
        var ended = false
        while (pos < end && events.size < 100000) {
            var cmd = byte()
            if (cmd == 0xFC) { ended = true; break }
            if (cmd == 0xF8) { delay(cmd); continue }
            if (cmd == 0xF0) {
                val a = byte(); val b = byte()
                if (a == 0x7F && b == 0) { setTempo(baseTempo * byte() + ((baseTempo * byte()) shr 7)); require(byte() == 0xF7) }
                else { while (byte() != 0xF7) { /* bounded by the song data */ } }
                delay(byte()); continue
            }
            if (cmd >= 0x80) last = cmd else { pos--; cmd = last }
            val voice = cmd and 15
            require(voice < VOICE_COUNT && cmd >= 0x80)
            val event = when (cmd and 0xF0) {
                0x80 -> { byte(); byte(); Command.NoteOff(voice) }
                0x90 -> { val note = byte(); val volume = byte(); if (volume == 0) Command.NoteOff(voice) else Command.NoteOn(voice, note, volume) }
                0xA0 -> Command.Volume(voice, byte())
                0xB0 -> { byte(); byte(); null }
                0xC0 -> Command.Instrument(voice, byte())
                0xD0 -> { byte(); null }
                0xE0 -> Command.Pitch(voice, byte() + (byte() shl 7))
                else -> error("Invalid MUS command")
            }
            if (event != null) events += Event(time, event)
            delay(byte())
        }
        require(ended && events.isNotEmpty())
        render(Song(timbres, u8(data, 58) != 0, u8(data, 59), events, time + RELEASE_TAIL_MS, adlVoiceSetup = false))
    }.getOrNull()

    private fun render(song: Song): SoundData? {
        val durationMs = song.durationMs.coerceIn(1.0, MAX_DURATION_MS.toDouble())
        val totalSamples = (durationMs * SAMPLE_RATE / 1000.0).toInt()
        if (totalSamples <= 0) return null

        val timbres = Array(song.timbres.size) { song.timbres[it].copyOf() }
        val chip = Opl3(SAMPLE_RATE)
        val driver = GobOplDriver(chip)
        driver.setPercussionMode(song.percussion)
        driver.setPitchRange(song.pitchRange)
        val currentInstrument = IntArray(VOICE_COUNT)
        fun setInstrument(voice: Int, instrument: Int) {
            if (voice >= VOICE_COUNT || instrument !in timbres.indices) return
            currentInstrument[voice] = instrument
            driver.setVoiceTimbre(voice, timbres[instrument])
        }
        if (song.adlVoiceSetup) {
            val voices = minOf(timbres.size, if (song.percussion) VOICE_COUNT else MELODY_VOICES)
            for (voice in 0 until voices) {
                setInstrument(voice, 0)
                driver.setVoiceVolume(voice, GobOplDriver.MAX_VOLUME)
            }
        }

        val pcm = ByteArray(totalSamples * 2)
        val frame = IntArray(2)
        var eventIndex = 0
        for (sampleIndex in 0 until totalSamples) {
            val timeMs = sampleIndex * 1000.0 / SAMPLE_RATE
            while (eventIndex < song.events.size && song.events[eventIndex].timeMs <= timeMs) {
                when (val c = song.events[eventIndex].command) {
                    is Command.NoteOn -> {
                        c.volume?.let { driver.setVoiceVolume(c.voice, it) }
                        driver.noteOn(c.voice, c.note)
                    }
                    is Command.NoteOff -> driver.noteOff(c.voice)
                    is Command.Volume -> driver.setVoiceVolume(c.voice, c.value)
                    is Command.Instrument -> setInstrument(c.voice, c.value)
                    is Command.Pitch -> driver.bendVoicePitch(c.voice, c.value)
                    is Command.ModifyInstrument -> if (c.instrument in timbres.indices && c.param in 0 until TIMBRE_WORDS) {
                        timbres[c.instrument][c.param] = c.value
                        // Voices playing that instrument pick up the change at once.
                        for (voice in 0 until VOICE_COUNT) if (currentInstrument[voice] == c.instrument) setInstrument(voice, c.instrument)
                    }
                }
                eventIndex++
            }
            chip.generate(frame)
            val value = ((frame[0] + frame[1]) / 2).coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            pcm[sampleIndex * 2] = value.toByte()
            pcm[sampleIndex * 2 + 1] = (value shr 8).toByte()
        }

        return SoundData(pcm, SAMPLE_RATE, 16, 1, true)
    }

    private fun parseEvents(data: ByteArray, songOffset: Int): Pair<List<Event>, Double>? {
        var position = songOffset
        if (position >= data.size) return null
        position += if ((u8(data, position) and 0x80) != 0) 2 else 1 // The player ignores the initial delay.
        if (position > data.size) return null

        val events = mutableListOf<Event>()
        var timeMs = 0
        var modifyInstrument = -1
        var ended = false

        while (position < data.size && timeMs < MAX_DURATION_MS) {
            val commandByte = u8(data, position++)
            if (commandByte == 0xFF) {
                ended = true
                break
            }

            if (commandByte == 0xFE) {
                if (position >= data.size) return null
                modifyInstrument = u8(data, position++)
            }

            val command: Command = if (commandByte >= 0xD0) {
                if (position + 1 >= data.size || modifyInstrument < 0) return null
                Command.ModifyInstrument(modifyInstrument, u8(data, position++), u8(data, position++))
            } else {
                val voice = commandByte and 0x0F
                if (voice >= VOICE_COUNT) return null
                when (commandByte and 0xF0) {
                    0x00 -> {
                        if (position + 1 >= data.size) return null
                        Command.NoteOn(voice, u8(data, position++), u8(data, position++))
                    }
                    0x80 -> Command.NoteOff(voice)
                    0x90 -> {
                        if (position >= data.size) return null
                        Command.NoteOn(voice, u8(data, position++), null)
                    }
                    0xA0 -> {
                        if (position >= data.size) return null
                        Command.Pitch(voice, u8(data, position++) shl 7)
                    }
                    0xB0 -> {
                        if (position >= data.size) return null
                        Command.Volume(voice, u8(data, position++))
                    }
                    0xC0 -> {
                        if (position >= data.size) return null
                        Command.Instrument(voice, u8(data, position++))
                    }
                    else -> return null
                }
            }

            if (position >= data.size) return null
            var delay = u8(data, position++)
            if ((delay and 0x80) != 0) {
                if (position >= data.size) return null
                delay = ((delay and 3) shl 8) or u8(data, position++)
            }
            events += Event(timeMs.toDouble(), command)
            timeMs += delay // the ADL player's timer runs at 1000 Hz
        }

        if (!ended || events.size < 8 || timeMs < 500) return null
        return events to (timeMs + RELEASE_TAIL_MS).toDouble()
    }

    private fun u8(data: ByteArray, offset: Int): Int = data[offset].toInt() and 0xFF
    private fun u16le(data: ByteArray, offset: Int): Int = u8(data, offset) or (u8(data, offset + 1) shl 8)
}

/**
 * Port of ScummVM's Gob `AdLib` class (engines/gob/sound/adlib.cpp, GPLv2+):
 * the OPL2 register logic shared by the ADL and MUS players. The original
 * engine has no music volume control, so carriers get no extra attenuation.
 */
private class GobOplDriver(private val chip: Opl3) {
    private val operatorParams = Array(OPERATOR_COUNT) { IntArray(PARAM_COUNT) }
    private val operatorVolume = IntArray(OPERATOR_COUNT) { MAX_VOLUME }
    private val voiceNote = IntArray(MAX_VOICE_COUNT)
    private val voiceOn = BooleanArray(MAX_VOICE_COUNT)
    private val freqs = Array(PITCH_STEP_COUNT) { IntArray(HALF_TONE_COUNT) }
    private val freqPtr = IntArray(MAX_VOICE_COUNT)
    private val halfToneOffset = IntArray(MAX_VOICE_COUNT)
    private var percussionMode = false
    private var percussionBits = 0
    private var tremoloDepth = false
    private var vibratoDepth = false
    private var keySplit = false
    private var enableWaveSelect = true
    private var pitchRangeStep = PITCH_STEP_COUNT

    init {
        val numStep = 100 / PITCH_STEP_COUNT
        for (i in 0 until PITCH_STEP_COUNT) setFreqs(freqs[i], i * numStep, 100)
        // AdLib::reset(): all voices off, then initOPL().
        for (voice in 0 until MELODY_VOICE_COUNT) noteOff(voice)
        resetFreqs()
        setPercussionMode(false)
        writeTremoloVibratoDepthPercMode()
        writeKeySplit()
        for (voice in 0 until MELODY_VOICE_COUNT) voiceOff(voice)
        setPitchRange(1)
        enableWaveSelect(true)
    }

    fun setPercussionMode(percussion: Boolean) {
        if (percussion) {
            voiceOff(VOICE_BASE_DRUM)
            voiceOff(VOICE_SNARE_DRUM)
            voiceOff(VOICE_TOM)
            setFreq(VOICE_TOM, PITCH_TOM, false)
            setFreq(VOICE_SNARE_DRUM, PITCH_SNARE_DRUM, false)
        }
        percussionMode = percussion
        percussionBits = 0
        initOperatorParams()
        writeTremoloVibratoDepthPercMode()
    }

    fun setPitchRange(range: Int) {
        pitchRangeStep = range.coerceIn(0, 12) * PITCH_STEP_COUNT
    }

    /** `params`: 13 modulator values, 13 carrier values, then the two wave selects. */
    fun setVoiceTimbre(voice: Int, params: IntArray) {
        val waves = 2 * (PARAM_COUNT - 1)
        if (!percussionMode || voice < VOICE_BASE_DRUM) {
            if (voice < MELODY_VOICE_COUNT) {
                setOperatorParams(MELODY_OPERATOR[0][voice], params, 0, params[waves])
                setOperatorParams(MELODY_OPERATOR[1][voice], params, PARAM_COUNT - 1, params[waves + 1])
            }
        } else if (voice == VOICE_BASE_DRUM) {
            setOperatorParams(PERCUSSION_OPERATOR[0][0], params, 0, params[waves])
            setOperatorParams(PERCUSSION_OPERATOR[1][0], params, PARAM_COUNT - 1, params[waves + 1])
        } else if (voice < MAX_VOICE_COUNT) {
            setOperatorParams(PERCUSSION_OPERATOR[0][voice - VOICE_BASE_DRUM], params, 0, params[waves])
        }
    }

    fun setVoiceVolume(voice: Int, volume: Int) {
        if (voice >= MAX_VOICE_COUNT) return
        val oper = if (!percussionMode || voice < VOICE_BASE_DRUM) {
            if (voice >= MELODY_VOICE_COUNT) return
            MELODY_OPERATOR[1][voice]
        } else {
            PERCUSSION_OPERATOR[if (voice == VOICE_BASE_DRUM) 1 else 0][voice - VOICE_BASE_DRUM]
        }
        operatorVolume[oper] = minOf(volume, MAX_VOLUME)
        writeKeyScaleLevelVolume(oper)
    }

    fun bendVoicePitch(voice: Int, pitchBend: Int) {
        if (voice >= MAX_VOICE_COUNT || (percussionMode && voice > VOICE_BASE_DRUM)) return
        changePitch(voice, minOf(pitchBend, MAX_PITCH))
        setFreq(voice, voiceNote[voice], voiceOn[voice])
    }

    fun noteOn(voice: Int, noteIn: Int) {
        if (voice >= MAX_VOICE_COUNT) return
        val note = maxOf(0, noteIn - (STANDARD_MID_C - OPL_MID_C))
        if (percussionMode && voice >= VOICE_BASE_DRUM) {
            if (voice == VOICE_BASE_DRUM) {
                setFreq(VOICE_BASE_DRUM, note, false)
            } else if (voice == VOICE_TOM) {
                setFreq(VOICE_TOM, note, false)
                setFreq(VOICE_SNARE_DRUM, note + PITCH_TOM_TO_SNARE, false)
            }
            percussionBits = percussionBits or PERCUSSION_MASKS[voice - VOICE_BASE_DRUM]
            writeTremoloVibratoDepthPercMode()
        } else {
            setFreq(voice, note, true)
        }
    }

    fun noteOff(voice: Int) {
        if (voice >= MAX_VOICE_COUNT) return
        if (percussionMode && voice >= VOICE_BASE_DRUM) {
            percussionBits = percussionBits and PERCUSSION_MASKS[voice - VOICE_BASE_DRUM].inv()
            writeTremoloVibratoDepthPercMode()
        } else {
            setFreq(voice, voiceNote[voice], false)
        }
    }

    private fun write(reg: Int, value: Int) = chip.writeReg(reg, value and 0xFF)

    private fun enableWaveSelect(enable: Boolean) {
        enableWaveSelect = enable
        for (i in 0 until OPERATOR_COUNT) write(0xE0 + OPERATOR_OFFSET[i], 0)
        write(0x01, if (enable) 0x20 else 0)
    }

    private fun writeKeyScaleLevelVolume(oper: Int) {
        var volume = (63 - (operatorParams[oper][PARAM_LEVEL] and 0x3F)) * operatorVolume[oper]
        volume = 63 - ((2 * volume + MAX_VOLUME) / (2 * MAX_VOLUME))
        val keyScale = operatorParams[oper][PARAM_KEY_SCALE_LEVEL] shl 6
        write(0x40 + OPERATOR_OFFSET[oper], volume or keyScale)
    }

    private fun writeKeySplit() = write(0x08, if (keySplit) 0x40 else 0)

    private fun writeFeedbackFM(oper: Int) {
        if (OPERATOR_TYPE[oper] == 1) return
        val value = (operatorParams[oper][PARAM_FEEDBACK] shl 1) or (if (operatorParams[oper][PARAM_FM] != 0) 0 else 1)
        write(0xC0 + OPERATOR_VOICE[oper], value)
    }

    private fun writeAttackDecay(oper: Int) =
        write(0x60 + OPERATOR_OFFSET[oper], (operatorParams[oper][PARAM_ATTACK] shl 4) or (operatorParams[oper][PARAM_DECAY] and 0x0F))

    private fun writeSustainRelease(oper: Int) =
        write(0x80 + OPERATOR_OFFSET[oper], (operatorParams[oper][PARAM_SUSTAIN] shl 4) or (operatorParams[oper][PARAM_RELEASE] and 0x0F))

    private fun writeTremoloVibratoSustainingKeyScaleRateFreqMulti(oper: Int) {
        val p = operatorParams[oper]
        var value = 0
        if (p[PARAM_AM] != 0) value = value or 0x80
        if (p[PARAM_VIB] != 0) value = value or 0x40
        if (p[PARAM_SUSTAINING] != 0) value = value or 0x20
        if (p[PARAM_KEY_SCALE_RATE] != 0) value = value or 0x10
        write(0x20 + OPERATOR_OFFSET[oper], value or (p[PARAM_FREQ_MULTI] and 0x0F))
    }

    private fun writeTremoloVibratoDepthPercMode() {
        var value = percussionBits
        if (tremoloDepth) value = value or 0x80
        if (vibratoDepth) value = value or 0x40
        if (percussionMode) value = value or 0x20
        write(0xBD, value)
    }

    private fun writeWaveSelect(oper: Int) =
        write(0xE0 + OPERATOR_OFFSET[oper], if (enableWaveSelect) operatorParams[oper][PARAM_WAVE_SELECT] and 0x03 else 0)

    private fun writeAllParams(oper: Int) {
        writeTremoloVibratoDepthPercMode()
        writeKeySplit()
        writeKeyScaleLevelVolume(oper)
        writeFeedbackFM(oper)
        writeAttackDecay(oper)
        writeSustainRelease(oper)
        writeTremoloVibratoSustainingKeyScaleRateFreqMulti(oper)
        writeWaveSelect(oper)
    }

    private fun initOperatorParams() {
        for (i in 0 until OPERATOR_COUNT) {
            val piano = PIANO_PARAMS[OPERATOR_TYPE[i]]
            setOperatorParams(i, piano, 0, piano[PARAM_COUNT - 1])
        }
        if (percussionMode) {
            setOperatorParams(12, BASE_DRUM_PARAMS[0], 0, BASE_DRUM_PARAMS[0][PARAM_COUNT - 1])
            setOperatorParams(15, BASE_DRUM_PARAMS[1], 0, BASE_DRUM_PARAMS[1][PARAM_COUNT - 1])
            setOperatorParams(16, SNARE_DRUM_PARAMS, 0, SNARE_DRUM_PARAMS[PARAM_COUNT - 1])
            setOperatorParams(14, TOM_PARAMS, 0, TOM_PARAMS[PARAM_COUNT - 1])
            setOperatorParams(17, CYMBAL_PARAMS, 0, CYMBAL_PARAMS[PARAM_COUNT - 1])
            setOperatorParams(13, HIHAT_PARAMS, 0, HIHAT_PARAMS[PARAM_COUNT - 1])
        }
    }

    private fun setOperatorParams(oper: Int, params: IntArray, offset: Int, wave: Int) {
        val p = operatorParams[oper]
        for (i in 0 until PARAM_COUNT - 1) p[i] = params[offset + i] and 0xFF
        p[PARAM_COUNT - 1] = wave and 0x03
        writeAllParams(oper)
    }

    private fun voiceOff(voice: Int) {
        write(0xA0 + voice, 0)
        write(0xB0 + voice, 0)
    }

    private fun calcFreq(num: Int, denom: Int): Int {
        var freq = ((denom * 100) + 6 * num) * 52088
        freq /= denom * 2500
        return ((freq.toLong() * 147456) / 111875).toInt()
    }

    private fun setFreqs(out: IntArray, num: Int, denom: Int) {
        var value = calcFreq(num, denom)
        out[0] = (4 + value) shr 3
        for (i in 1 until HALF_TONE_COUNT) {
            value = (value * 106) / 100
            out[i] = (4 + value) shr 3
        }
    }

    private fun resetFreqs() {
        freqPtr.fill(0)
        halfToneOffset.fill(0)
    }

    private fun changePitch(voice: Int, pitchBend: Int) {
        var amount = ((pitchBend - MID_PITCH) * pitchRangeStep) / MID_PITCH
        val full: Int
        var frac: Int
        if (amount >= 0) {
            full = amount / PITCH_STEP_COUNT
            frac = amount % PITCH_STEP_COUNT
        } else {
            amount = PITCH_STEP_COUNT - 1 - amount
            full = -(amount / PITCH_STEP_COUNT)
            frac = (amount - PITCH_STEP_COUNT + 1) % PITCH_STEP_COUNT
            if (frac != 0) frac = PITCH_STEP_COUNT - frac
        }
        halfToneOffset[voice] = full
        freqPtr[voice] = frac
    }

    private fun setFreq(voice: Int, noteIn: Int, on: Boolean) {
        voiceOn[voice] = on
        voiceNote[voice] = noteIn
        val note = (noteIn + halfToneOffset[voice]).coerceIn(0, NOTE_COUNT - 1)
        val freq = freqs[freqPtr[voice]][note % HALF_TONE_COUNT]
        var value = ((note / HALF_TONE_COUNT) shl 2) or ((freq shr 8) and 0x03)
        if (on) value = value or 0x20
        write(0xA0 + voice, freq)
        write(0xB0 + voice, value)
    }

    companion object {
        const val MAX_VOLUME = 0x7F
        private const val MAX_PITCH = 0x3FFF
        private const val MID_PITCH = 0x2000
        private const val STANDARD_MID_C = 60
        private const val OPL_MID_C = 48
        private const val OPERATOR_COUNT = 18
        private const val PARAM_COUNT = 14
        private const val PITCH_STEP_COUNT = 25
        private const val HALF_TONE_COUNT = 12
        private const val NOTE_COUNT = HALF_TONE_COUNT * 8
        private const val MELODY_VOICE_COUNT = 9
        private const val MAX_VOICE_COUNT = 11
        private const val VOICE_BASE_DRUM = 6
        private const val VOICE_SNARE_DRUM = 7
        private const val VOICE_TOM = 8
        private const val PITCH_TOM = 24
        private const val PITCH_TOM_TO_SNARE = 7
        private const val PITCH_SNARE_DRUM = PITCH_TOM + PITCH_TOM_TO_SNARE

        private const val PARAM_KEY_SCALE_LEVEL = 0
        private const val PARAM_FREQ_MULTI = 1
        private const val PARAM_FEEDBACK = 2
        private const val PARAM_ATTACK = 3
        private const val PARAM_SUSTAIN = 4
        private const val PARAM_SUSTAINING = 5
        private const val PARAM_DECAY = 6
        private const val PARAM_RELEASE = 7
        private const val PARAM_LEVEL = 8
        private const val PARAM_AM = 9
        private const val PARAM_VIB = 10
        private const val PARAM_KEY_SCALE_RATE = 11
        private const val PARAM_FM = 12
        private const val PARAM_WAVE_SELECT = 13

        /** 0 = modulator, 1 = carrier. */
        private val OPERATOR_TYPE = intArrayOf(0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1)
        private val OPERATOR_OFFSET = intArrayOf(0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 16, 17, 18, 19, 20, 21)
        private val OPERATOR_VOICE = intArrayOf(0, 1, 2, 0, 1, 2, 3, 4, 5, 3, 4, 5, 6, 7, 8, 6, 7, 8)
        private val MELODY_OPERATOR = arrayOf(
            intArrayOf(0, 1, 2, 6, 7, 8, 12, 13, 14),
            intArrayOf(3, 4, 5, 9, 10, 11, 15, 16, 17),
        )
        private val PERCUSSION_OPERATOR = arrayOf(
            intArrayOf(12, 16, 14, 17, 13),
            intArrayOf(15, 0, 0, 0, 0),
        )
        private val PERCUSSION_MASKS = intArrayOf(0x10, 0x08, 0x04, 0x02, 0x01)

        private val PIANO_PARAMS = arrayOf(
            intArrayOf(1, 1, 3, 15, 5, 0, 1, 3, 15, 0, 0, 0, 1, 0),
            intArrayOf(0, 1, 1, 15, 7, 0, 2, 4, 0, 0, 0, 1, 0, 0),
        )
        private val BASE_DRUM_PARAMS = arrayOf(
            intArrayOf(0, 0, 0, 10, 4, 0, 8, 12, 11, 0, 0, 0, 1, 0),
            intArrayOf(0, 0, 0, 13, 4, 0, 6, 15, 0, 0, 0, 0, 1, 0),
        )
        private val SNARE_DRUM_PARAMS = intArrayOf(0, 12, 0, 15, 11, 0, 8, 5, 0, 0, 0, 0, 0, 0)
        private val TOM_PARAMS = intArrayOf(0, 4, 0, 15, 11, 0, 7, 5, 0, 0, 0, 0, 0, 0)
        private val CYMBAL_PARAMS = intArrayOf(0, 1, 0, 15, 11, 0, 5, 5, 0, 0, 0, 0, 0, 0)
        private val HIHAT_PARAMS = intArrayOf(0, 1, 0, 15, 11, 0, 7, 5, 0, 0, 0, 0, 0, 0)
    }
}

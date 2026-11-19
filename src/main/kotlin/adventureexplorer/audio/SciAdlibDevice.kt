package adventureexplorer.audio

import javax.sound.midi.ShortMessage

/** Sound driver generation of a Sierra SCI game; the AdLib driver behaves differently in each. */
enum class SciSoundVersion { SCI0_EARLY, SCI0_LATE, SCI1 }

/**
 * Sierra SCI AdLib music driver (`ADL.DRV`), for songs whose AdLib track was prepared by the converter
 * (channels already mapped to device channels, voice counts sent as controller 0x4B).
 *
 * A port of ScummVM's `MidiDriver_AdLib` (engines/sci/sound/drivers/adlib.cpp,
 * Copyright (C) the ScummVM Team, GPLv3+), itself a reimplementation of Sierra's driver. Nine FM voices
 * are shared by 16 MIDI channels: each channel owns a number of voices (controller 0x4B), notes play
 * Sierra's instruments from `patch.003`, velocity runs through the driver's own volume tables, and the
 * pitch wheel moves in steps of 1/4 semitone. A mono OPL2 is driven like the original card; the stereo
 * panning of ScummVM's dual-OPL2 mode is not used.
 *
 * [write] receives OPL2 register writes; call [onTimer] at 250 Hz alongside the song.
 */
internal class SciAdlibDevice(
    private val version: SciSoundVersion,
    patchData: ByteArray,
    private val write: (reg: Int, value: Int) -> Unit,
) : OplMidiOutput {
    constructor(chip: Opl3, version: SciSoundVersion, patchData: ByteArray) :
        this(version, patchData, { reg, value -> chip.writeReg(reg, value) })

    private class Operator(
        val amplitudeMod: Int, val vibrato: Int, val envelopeType: Int, val kbScaleRate: Int,
        val frequencyMult: Int, val kbScaleLevel: Int, val totalLevel: Int, val attackRate: Int,
        val decayRate: Int, val sustainLevel: Int, val releaseRate: Int, var waveForm: Int = 0,
    )

    private class Patch(val op0: Operator, val op1: Operator, val feedback: Int, val algorithm: Boolean) {
        fun op(index: Int) = if (index == 0) op0 else op1
    }

    private class Channel {
        var patch = 0
        var volume = 63
        var pan = 64
        var holdPedal = 0
        var extraVoices = 0
        var pitchWheel = 8192
        var lastVoice = 0
        var enableVelocity = false
        var voices = 0
        var mappedVoices = 0
    }

    private class Voice {
        var channel = -1
        var mappedChannel = -1
        var note = -1
        var patch = -1
        var velocity = 0
        var isSustained = false
        var age = 0
    }

    private val isSci0 = version != SciSoundVersion.SCI1
    private val numVoiceMax = if (version == SciSoundVersion.SCI0_EARLY) 8 else VOICES
    private val channels = Array(MIDI_CHANNELS) { Channel() }
    private val voices = Array(VOICES) { Voice() }
    private val voiceQueue = ArrayDeque<Int>((0 until VOICES).toList())
    private val patches = ArrayList<Patch>()
    private var rhythmKeyMap: ByteArray? = null
    private var masterVolume = 15
    private var playSwitch = true

    init {
        loadPatches(patchData)
        setRegister(0xBD, 0)
        setRegister(0x08, 0)
        setRegister(0x01, 0x20)
    }

    // ── Patch bank ──────────────────────────────────────────

    private fun loadPatches(data: ByteArray) {
        require(data.size == 1344 || data.size == 2690 || data.size == 5382) { "Unsupported SCI AdLib patch size ${data.size}" }
        for (i in 0 until 48) loadInstrument(data, 28 * i)
        when (data.size) {
            1344 -> repeat(48) { loadInstrument(ByteArray(28), 0) } // only 48 instruments: dummies
            2690 -> for (i in 48 until 96) loadInstrument(data, 2 + 28 * i)
            else -> {
                for (i in 48 until 190) loadInstrument(data, 28 * i)
                rhythmKeyMap = data.copyOfRange(5320, 5320 + RHYTHM_KEYS)
            }
        }
    }

    private fun loadInstrument(data: ByteArray, offset: Int) {
        fun b(i: Int) = data[offset + i].toInt() and 0xFF
        fun operator(base: Int) = Operator(
            amplitudeMod = if (b(base + 9) != 0) 1 else 0,
            vibrato = if (b(base + 10) != 0) 1 else 0,
            envelopeType = if (b(base + 5) != 0) 1 else 0,
            kbScaleRate = if (b(base + 11) != 0) 1 else 0,
            frequencyMult = b(base + 1) and 0xF,
            kbScaleLevel = b(base) and 3,
            totalLevel = b(base + 8) and 0x3F,
            attackRate = b(base + 3) and 0xF,
            decayRate = b(base + 6) and 0xF,
            sustainLevel = b(base + 4) and 0xF,
            releaseRate = b(base + 7) and 0xF,
        )
        val op0 = operator(0).also { it.waveForm = b(26) and 3 }
        val op1 = operator(13).also { it.waveForm = b(27) and 3 }
        patches.add(Patch(op0, op1, feedback = b(2) and 7, algorithm = b(12) == 0)) // the flag is inverted
    }

    private val useRhythmChannel get() = rhythmKeyMap != null

    // ── MIDI ────────────────────────────────────────────────

    /** SCI0 sounds carry a header (device flags and voice counts per channel) that sets up the voices. */
    fun initTrack(header: ByteArray) {
        if (!isSci0) return
        var pos = 0
        fun next() = header.getOrElse(pos++) { 0 }.toInt() and 0xFF
        val caps = next()
        if (caps != 0 && (version == SciSoundVersion.SCI0_EARLY || caps != 2)) return
        for (voice in voices) {
            voice.channel = -1; voice.mappedChannel = -1; voice.note = -1
            voice.isSustained = false; voice.patch = 13; voice.velocity = 0; voice.age = 0
        }
        var numVoices = 0
        for (i in 0 until MIDI_CHANNELS) {
            channels[i].patch = 13
            channels[i].extraVoices = 0
            channels[i].mappedVoices = 0
            if (version == SciSoundVersion.SCI0_LATE) {
                val num = next() and 0x7F
                val flags = next()
                if (flags and 0x04 != 0 && num != 0) assignVoices(i, num)
            } else {
                val value = next()
                if (value and 0x01 != 0) {
                    var num = value shr 4
                    if (value and 0x08 == 0 && num != 0 && num != 0x0F) {
                        while (num-- > 0) {
                            if (numVoices >= numVoiceMax) continue
                            voices[numVoices++].mappedChannel = i
                            channels[i].mappedVoices++
                        }
                    }
                }
            }
        }
    }

    override fun send(message: ShortMessage) {
        val channel = message.channel
        val op1 = message.data1
        val op2 = message.data2
        when (message.command) {
            ShortMessage.NOTE_OFF -> noteOff(channel, op1)
            ShortMessage.NOTE_ON -> noteOn(channel, op1, op2)
            ShortMessage.CONTROL_CHANGE -> when (op1) {
                0x07 -> { channels[channel].volume = op2 shr 1; renewNotes(channel, true) }
                0x0A -> { channels[channel].pan = op2; renewNotes(channel, true) }
                0x40 -> {
                    channels[channel].holdPedal = op2
                    if (op2 == 0) for (i in 0 until VOICES) if (voices[i].channel == channel && voices[i].isSustained) voiceOff(i)
                }
                0x4B -> voiceMapping(channel, op2)
                0x4E -> channels[channel].enableVelocity = op2 != 0
                NOTES_OFF -> for (i in 0 until VOICES) if (voices[i].channel == channel && voices[i].note != -1) voiceOff(i)
            }
            ShortMessage.PROGRAM_CHANGE -> channels[channel].patch = op1
            ShortMessage.PITCH_BEND -> {
                channels[channel].pitchWheel = (op1 and 0x7F) or ((op2 and 0x7F) shl 7)
                renewNotes(channel, true)
            }
            // The original driver ignores aftertouch.
        }
    }

    override fun onTimer() {
        for (voice in voices) if (voice.note != -1) voice.age++
    }

    override fun allNotesOff() {
        for (i in 0 until VOICES) if (voices[i].note != -1) voiceOff(i)
    }

    // ── Voice allocation ────────────────────────────────────

    private fun voiceMapping(channel: Int, wanted: Int) {
        var current = 0
        for (i in 0 until numVoiceMax) if (voices[i].mappedChannel == channel) current++
        current += channels[channel].extraVoices
        if (current < wanted) {
            assignVoices(channel, wanted - current)
        } else if (current > wanted) {
            releaseVoices(channel, current - wanted)
            donateVoices()
        }
    }

    private fun assignVoices(channel: Int, count: Int) {
        var left = count
        for (i in 0 until numVoiceMax) {
            if (voices[i].mappedChannel == -1) {
                if (voices[i].note != -1) voiceOff(i) // late SCI1.1: stop a note on an unmapped channel
                voices[i].mappedChannel = channel
                channels[channel].mappedVoices++
                if (--left == 0) return
            }
        }
        if (!isSci0) channels[channel].extraVoices += left
    }

    private fun releaseVoices(channel: Int, count: Int) {
        var left = count
        if (channels[channel].extraVoices >= left) {
            channels[channel].extraVoices -= left
            return
        }
        left -= channels[channel].extraVoices
        channels[channel].extraVoices = 0
        for (i in 0 until numVoiceMax) {
            if (voices[i].mappedChannel == channel && voices[i].note == -1) {
                voices[i].mappedChannel = -1
                channels[channel].mappedVoices--
                if (--left == 0) return
            }
        }
        for (i in 0 until numVoiceMax) {
            if (voices[i].mappedChannel == channel) {
                voiceOff(i)
                voices[i].mappedChannel = -1
                channels[channel].mappedVoices--
                if (--left == 0) return
            }
        }
    }

    private fun donateVoices() {
        if (isSci0) return
        var free = voices.count { it.mappedChannel == -1 }
        if (free == 0) return
        for (i in 0 until MIDI_CHANNELS) {
            if (channels[i].extraVoices >= free) {
                assignVoices(i, free)
                channels[i].extraVoices -= free
                return
            } else if (channels[i].extraVoices > 0) {
                assignVoices(i, channels[i].extraVoices)
                free -= channels[i].extraVoices
                channels[i].extraVoices = 0
            }
        }
    }

    private fun renewNotes(channel: Int, key: Boolean) {
        for (i in 0 until VOICES) {
            if ((channel == -1 || voices[i].channel == channel) && voices[i].note != -1) setNote(i, voices[i].note, key)
        }
    }

    private fun noteOn(channel: Int, note: Int, velocityIn: Int) {
        if (velocityIn == 0) return noteOff(channel, note)
        val velocity = velocityIn shr 1
        if (note < 12 || note > 107) return // not a playable note
        for (i in 0 until VOICES) {
            if (voices[i].channel == channel && voices[i].note == note) {
                voiceOff(i)
                voiceOn(i, note, velocity)
                return
            }
        }
        val voice = if (useRhythmChannel) findVoiceLateSci11(channel) else findVoice(channel)
        if (voice == -1) return // no free voice assigned to this channel
        voiceOn(voice, note, velocity)
    }

    private fun findVoice(channel: Int): Int {
        var voice = -1
        var oldestVoice = -1
        var oldestAge = 0
        // A free voice assigned to this channel, round-robin
        for (i in 0 until VOICES) {
            val v = (channels[channel].lastVoice + i + 1) % VOICES
            if (voices[v].mappedChannel == channel) {
                if (voices[v].note == -1) {
                    voice = v
                    voices[voice].channel = channel
                    break
                }
                // Otherwise the oldest note; those started in this time slice are not eligible
                if (voices[v].age >= oldestAge) {
                    oldestAge = voices[v].age
                    oldestVoice = v
                }
            }
        }
        if (voice == -1) {
            if (oldestAge == 0) return -1
            voiceOff(oldestVoice)
            voice = oldestVoice
            voices[voice].channel = channel
        }
        channels[channel].lastVoice = voice
        return voice
    }

    private fun findVoiceLateSci11(channel: Int): Int {
        // An unused voice already holding this program
        for (voice in voiceQueue) {
            if (voices[voice].note == -1 && voices[voice].patch == channels[channel].patch) {
                voices[voice].channel = channel
                return voice
            }
        }
        for (voice in voiceQueue) {
            if (voices[voice].note == -1) {
                voices[voice].channel = channel
                return voice
            }
        }
        // The channel with the highest excess of voices loses one, otherwise this channel does
        var maxExceed = 0
        var maxExceedChannel = 0
        for (i in 0 until MIDI_CHANNELS) {
            if (channels[i].voices > channels[i].mappedVoices) {
                val exceed = channels[i].voices - channels[i].mappedVoices
                if (exceed > maxExceed) { maxExceed = exceed; maxExceedChannel = i }
            }
        }
        val stop = if (maxExceed > 0) maxExceedChannel else channel
        for (voice in voiceQueue.toList()) {
            if (voices[voice].channel == stop) {
                voiceOff(voice)
                voices[voice].channel = channel
                return voice
            }
        }
        return -1
    }

    private fun queueMoveToBack(voice: Int) {
        voiceQueue.remove(voice)
        voiceQueue.addLast(voice)
    }

    private fun noteOff(channel: Int, note: Int) {
        for (i in 0 until VOICES) {
            if (voices[i].channel == channel && voices[i].note == note) {
                if (channels[channel].holdPedal != 0) voices[i].isSustained = true else voiceOff(i)
                return
            }
        }
    }

    private fun voiceOn(voice: Int, note: Int, velocity: Int) {
        val channel = voices[voice].channel
        var patch = channels[channel].patch
        voices[voice].age = 0
        channels[channel].voices++
        queueMoveToBack(voice)
        if (channel == 9 && useRhythmChannel) patch = note.coerceIn(27, 88) + 101
        if (patch != voices[voice].patch && playSwitch) setPatch(voice, patch)
        voices[voice].velocity = velocity
        setNote(voice, note, true)
    }

    private fun voiceOff(voice: Int) {
        val channel = voices[voice].channel
        voices[voice].isSustained = false
        setNote(voice, voices[voice].note, false)
        voices[voice].note = -1
        voices[voice].age = 0
        queueMoveToBack(voice)
        channels[channel].voices--
    }

    // ── Chip ────────────────────────────────────────────────

    private fun setNote(voice: Int, noteIn: Int, key: Boolean) {
        val channel = voices[voice].channel
        var note = noteIn
        val rhythm = rhythmKeyMap
        if (channel == 9 && rhythm != null) note = rhythm[note.coerceIn(27, 88) - 27].toInt() and 0xFF
        voices[voice].note = note

        var index = note shl 2
        var pitchWheel = channels[channel].pitchWheel
        val sign: Int
        if (pitchWheel == 0x2000) {
            pitchWheel = 0; sign = 0
        } else if (pitchWheel > 0x2000) {
            pitchWheel -= 0x2000; sign = 1
        } else {
            pitchWheel = 0x2000 - pitchWheel; sign = -1
        }
        pitchWheel /= 171
        if (sign == 1) index += pitchWheel else index -= pitchWheel
        if (index > 0x1FC) index = 0x1FC // highest MIDI note (<< 2)
        if (index < 0) index = 0

        val freq = ADLIB_FREQ[index % 48]
        setRegister(0xA0 + voice, freq and 0xFF)
        var octave = index / 48
        if (octave > 0) octave--
        if (octave > 7) octave = 7
        setRegister(0xB0 + voice, ((if (key) 1 else 0) shl 5) or (octave shl 2) or (freq shr 8))
        setVelocity(voice)
    }

    private fun setVelocity(voice: Int) {
        val patch = patches[voices[voice].patch]
        setVelocityReg(REGISTER_OFFSET[voice] + 3, calcVelocity(voice, 1), patch.op1.kbScaleLevel)
        // In AM mode both operators carry sound
        if (patch.algorithm) setVelocityReg(REGISTER_OFFSET[voice], calcVelocity(voice, 0), patch.op0.kbScaleLevel)
    }

    private fun calcVelocity(voice: Int, op: Int): Int {
        val patch = patches[voices[voice].patch]
        if (isSci0) {
            var velocity = masterVolume
            if (velocity > 0) velocity += 3
            if (velocity > 15) velocity = 15
            val insVelocity = if (channels[voices[voice].channel].enableVelocity) voices[voice].velocity
                else 63 - patch.op(op).totalLevel
            return velocity * insVelocity / 15
        }
        var velocity = channels[voices[voice].channel].volume + 1
        velocity = velocity * (VELOCITY_MAP1[voices[voice].velocity] + 1) / 64
        velocity = velocity * (masterVolume + 1) / 16
        if (--velocity < 0) velocity = 0
        return VELOCITY_MAP2[velocity] * (63 - patch.op(op).totalLevel) / 63
    }

    private fun setVelocityReg(regOffset: Int, velocityIn: Int, kbScaleLevel: Int) {
        val velocity = if (playSwitch) velocityIn else 0
        setRegister(0x40 + regOffset, (kbScaleLevel shl 6) or (63 - velocity))
    }

    private fun setPatch(voice: Int, patchIn: Int) {
        val patch = if (patchIn < 0 || patchIn >= patches.size) 0 else patchIn // unknown program: instrument 0
        voices[voice].patch = patch
        val p = patches[patch]
        setOperator(REGISTER_OFFSET[voice], p.op0)
        setOperator(REGISTER_OFFSET[voice] + 3, p.op1)
        setRegister(0xC0 + voice, (p.feedback shl 1) or (if (p.algorithm) 1 else 0))
    }

    private fun setOperator(reg: Int, op: Operator) {
        setRegister(0x40 + reg, (op.kbScaleLevel shl 6) or op.totalLevel)
        setRegister(0x60 + reg, (op.attackRate shl 4) or op.decayRate)
        setRegister(0x80 + reg, (op.sustainLevel shl 4) or op.releaseRate)
        setRegister(0x20 + reg, (op.amplitudeMod shl 7) or (op.vibrato shl 6) or (op.envelopeType shl 5) or
            (op.kbScaleRate shl 4) or op.frequencyMult)
        setRegister(0xE0 + reg, op.waveForm)
    }

    private fun setRegister(reg: Int, value: Int) = write(reg, value)

    companion object {
        const val VOICES = 9
        const val RHYTHM_KEYS = 62
        private const val MIDI_CHANNELS = 16
        private const val NOTES_OFF = 0x7B

        /** Operator register offsets of the nine voices. */
        private val REGISTER_OFFSET = intArrayOf(0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x10, 0x11, 0x12)

        private val VELOCITY_MAP1 = intArrayOf(
            0x00, 0x0c, 0x0d, 0x0e, 0x0f, 0x11, 0x12, 0x13, 0x14, 0x16, 0x17, 0x18, 0x1a, 0x1b, 0x1c, 0x1d,
            0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2d, 0x2d, 0x2e,
            0x2f, 0x30, 0x31, 0x32, 0x32, 0x33, 0x34, 0x34, 0x35, 0x36, 0x36, 0x37, 0x38, 0x38, 0x39, 0x3a,
            0x3b, 0x3b, 0x3b, 0x3c, 0x3c, 0x3c, 0x3d, 0x3d, 0x3d, 0x3e, 0x3e, 0x3e, 0x3e, 0x3f, 0x3f, 0x3f,
        )

        private val VELOCITY_MAP2 = intArrayOf(
            0x00, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x21,
            0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x2f, 0x30,
            0x31, 0x32, 0x32, 0x33, 0x34, 0x34, 0x35, 0x36, 0x36, 0x37, 0x38, 0x38, 0x39, 0x39, 0x3a, 0x3a,
            0x3b, 0x3b, 0x3b, 0x3c, 0x3c, 0x3c, 0x3d, 0x3d, 0x3d, 0x3e, 0x3e, 0x3e, 0x3e, 0x3f, 0x3f, 0x3f,
        )

        /** One octave with three pitch wheel positions after each note. */
        private val ADLIB_FREQ = intArrayOf(
            0x157, 0x15c, 0x161, 0x166, 0x16b, 0x171, 0x176, 0x17b, 0x181, 0x186, 0x18c, 0x192,
            0x198, 0x19e, 0x1a4, 0x1aa, 0x1b0, 0x1b6, 0x1bd, 0x1c3, 0x1ca, 0x1d0, 0x1d7, 0x1de,
            0x1e5, 0x1ec, 0x1f3, 0x1fa, 0x202, 0x209, 0x211, 0x218, 0x220, 0x228, 0x230, 0x238,
            0x241, 0x249, 0x252, 0x25a, 0x263, 0x26c, 0x275, 0x27e, 0x287, 0x290, 0x29a, 0x2a4,
        )
    }
}

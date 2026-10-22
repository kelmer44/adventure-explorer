package adventureexplorer.audio

import adventureexplorer.model.SoundData
import kotlin.math.abs

/**
 * Renders SCUMM `AD` sound resources (Loom, Indiana Jones 3 and Monkey Island 1
 * EGA/VGA floppy, DOS AdLib) to PCM through an emulated OPL2.
 *
 * A port of ScummVM's `Player_AD` (engines/scumm/players/player_ad.cpp, GPLv3+),
 * itself a reimplementation of the games' own AdLib player: music resources
 * carry their instruments and a MIDI-like event track that drives the chip
 * registers directly; sound-effect resources are small envelope programs for up
 * to three channels. One resource is rendered on its own, at full volume.
 *
 * `resource` is the AD block payload after its chunk header; byte 2 is 0x80 for
 * music. Looping music is rendered for one pass.
 */
object ScummAdPlayer {
    private const val SAMPLE_RATE = 44_100
    private const val CALLBACK_HZ = 472
    private const val MAX_MUSIC_MS = 10 * 60 * 1000
    private const val MAX_SFX_MS = 8_000
    private const val TAIL_MS = 1_000

    fun render(resource: ByteArray, loom: Boolean): SoundData? = runCatching {
        if (resource.size < 4) return null
        val player = Player(resource, loom)
        val music = player.isMusic
        if (music && resource.size < 0x94) return null
        if (music) player.startMusic() else if (!player.startSfx()) return null

        val pcm = java.io.ByteArrayOutputStream()
        val frame = IntArray(2)
        val samplesPerTick = SAMPLE_RATE.toDouble() / CALLBACK_HZ
        val maxSamples = (if (music) MAX_MUSIC_MS else MAX_SFX_MS).toLong() * SAMPLE_RATE / 1000
        var due = 0.0
        var written = 0L
        var tailSamples = -1L
        fun emit(count: Int) {
            repeat(count) {
                player.chip.generate(frame)
                val v = ((frame[0] + frame[1]) / 2).coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                pcm.write(v and 0xFF); pcm.write((v shr 8) and 0xFF)
            }
            written += count
        }
        while (written < maxSamples) {
            if (tailSamples < 0) {
                player.onTimer()
                if (!player.isPlaying) {
                    player.stopAll()
                    tailSamples = TAIL_MS.toLong() * SAMPLE_RATE / 1000
                }
            }
            due += samplesPerTick
            val n = due.toInt()
            due -= n
            emit(n)
            if (tailSamples >= 0) {
                tailSamples -= n
                if (tailSamples <= 0) break
            }
        }
        if (written == 0L) return null
        SoundData(pcm.toByteArray(), SAMPLE_RATE, 16, 1, true)
    }.getOrNull()

    private class Note {
        var state = 0
        var playTime = 0
        var sustainTimer = 0
        var instrumentValue = 0
        var bias = 0
        var preIncrease = 0
        var adjust = 0
        var stepIncrease = 0
        var step = 0
        var stepCounter = 0
        var timer = 0
    }

    private class Channel {
        var state = CHANNEL_OFF
        var currentOffset = 0
        var startOffset = 0
        val instrumentData = IntArray(7)
        val notes = arrayOf(Note(), Note())
        var hardwareChannel = -1
    }

    private class Player(private val data: ByteArray, private val loom: Boolean) {
        val chip = Opl3(SAMPLE_RATE)
        val isMusic = u8(2) == 0x80
        private val registers = IntArray(256)

        // Hardware channels: music always outranks effects (priority 256).
        private val hwAllocated = BooleanArray(9)
        private val hwPriority = IntArray(9)
        private val hwSfx = BooleanArray(9)
        private var numHwChannels = 9

        // Music state
        private var musicPlaying = false
        private var looped = false
        private var timerLimit = 256
        private var musicTicks = 0
        private var musicTimer = 0
        private var loopFlag = false
        private var musicLoopStart = 0
        private val instrumentOffset = IntArray(16)
        private val voiceLastEvent = IntArray(9)
        private val voiceFrequency = IntArray(9)
        private val voiceB0 = IntArray(9)
        private var mdvdrState = 0
        private var curOffset = 0
        private var nextEventTimer = 0

        // Sound-effect state (one effect, up to three channels)
        private var sfxActive = false
        private val sfxChannels = Array(3) { Channel() }
        private var sfxTimer = 4
        private var rndSeed = 1

        init {
            writeReg(0x01, 0x00)
            writeReg(0xBD, 0x00)
            writeReg(0x08, 0x00)
            writeReg(0x01, 0x20)
        }

        val isPlaying: Boolean get() = if (isMusic) musicPlaying && !looped else sfxActive

        private fun u8(p: Int) = if (p in data.indices) data[p].toInt() and 0xFF else 0

        fun onTimer() {
            if (curOffset != 0) updateMusic()
            updateSfx()
        }

        fun stopAll() {
            stopMusic()
            stopSfx()
        }

        // ── Registers and channels ───────────────────────────────

        private fun writeReg(r: Int, v: Int) {
            val value = v and 0xFF
            if (r in 0..255) registers[r] = value
            chip.writeReg(r, value)
        }

        private fun readReg(r: Int) = if (r in 0..255) registers[r] else 0

        private fun allocateHwChannel(priority: Int, sfx: Boolean): Int {
            var channel = -1
            var minPrio = priority
            for (i in 0 until numHwChannels) {
                if (!hwAllocated[i]) { channel = i; break }
                // Neither music nor an effect may take back its own channels.
                if (hwPriority[i] <= minPrio && hwSfx[i] != sfx) {
                    minPrio = hwPriority[i]
                    channel = i
                }
            }
            if (channel != -1) {
                if (hwAllocated[channel] && hwSfx[channel]) stopSfx()
                hwAllocated[channel] = true
                hwPriority[channel] = priority
                hwSfx[channel] = sfx
            }
            return channel
        }

        private fun freeHwChannel(channel: Int) {
            hwAllocated[channel] = false
            hwSfx[channel] = false
        }

        private fun limitHwChannels(count: Int) {
            for (i in count until 9) if (hwAllocated[i]) freeHwChannel(i)
            numHwChannels = count
        }

        private fun setupChannel(channel: Int, instr: Int) {
            writeReg(0xC0 + channel, u8(instr + 2))
            setupOperator(OPERATOR_OFFSET[channel * 2], instr + 3)
            setupOperator(OPERATOR_OFFSET[channel * 2 + 1], instr + 8)
        }

        private fun setupOperator(opr: Int, at: Int) {
            writeReg(0x20 + opr, u8(at))
            writeReg(0x40 + opr, u8(at + 1))
            writeReg(0x60 + opr, u8(at + 2))
            writeReg(0x80 + opr, u8(at + 3))
            writeReg(0xE0 + opr, u8(at + 4))
        }

        // ── Music ────────────────────────────────────────────────

        fun startMusic() {
            var hasRhythm = false
            val instruments = u8(10)
            for (i in 0 until instruments) {
                val index = u8(11 + i) - 1
                if (index in 0 until 16) {
                    instrumentOffset[index] = i * 16 + 16 + 3
                    hasRhythm = hasRhythm || u8(instrumentOffset[index] + 13) != 0
                }
            }
            if (hasRhythm) {
                mdvdrState = 0x20
                limitHwChannels(6)
            } else {
                mdvdrState = 0
                limitHwChannels(9)
            }
            curOffset = 0x93
            nextEventTimer = 40
            musicTimer = 0
            writeReg(0xBD, mdvdrState)
            timerLimit = if (loom) 473 else 256
            musicTicks = u8(3) * (if (loom) 2 else 1)
            loopFlag = u8(4) == 0
            musicLoopStart = curOffset + (u8(5) or (u8(6) shl 8))
            musicPlaying = true
        }

        private fun stopMusic() {
            if (!musicPlaying) return
            musicPlaying = false
            curOffset = 0
            for (i in 0 until 9) if (voiceLastEvent[i] != 0) noteOff(i)
            writeReg(0xBD, 0x00)
            limitHwChannels(9)
        }

        private fun updateMusic() {
            musicTimer += musicTicks
            if (musicTimer < timerLimit) return
            musicTimer -= timerLimit
            if (--nextEventTimer != 0) return

            while (true) {
                if (curOffset >= data.size) { stopMusic(); return }
                if (parseCommand()) {
                    // End of track: stop, or continue parsing at the loop start.
                    if (!musicPlaying || looped) return
                    continue
                }
                if (u8(curOffset) != 0) break
                curOffset++
            }
            nextEventTimer = parseVlq() shr (if (loom) 2 else 1)
            if (nextEventTimer == 0) nextEventTimer = 1
        }

        private fun parseCommand(): Boolean {
            var command = u8(curOffset++)
            if (command == 0xFF) {
                command = u8(curOffset++)
                when (command) {
                    47 -> { // end of track
                        if (loopFlag) {
                            curOffset = musicLoopStart
                            nextEventTimer = 0
                            looped = true // the preview stops after one pass
                        } else {
                            stopMusic()
                        }
                        return true
                    }
                    88 -> curOffset += 5
                    81 -> { // tempo change (Loom)
                        val timing = u8(curOffset + 2) or (u8(curOffset + 1) shl 8)
                        if (timing != 0) musicTicks = 0x73000 / timing
                        curOffset += 1 + u8(curOffset)
                    }
                    else -> curOffset += 1 + u8(curOffset)
                }
            } else {
                if (command >= 0x90) {
                    val ch = command - 0x90
                    val instr = if (ch < 16) instrumentOffset[ch] else 0
                    if (instr != 0) {
                        if (u8(instr + 13) != 0) {
                            setupRhythm(u8(instr + 13), instr)
                        } else {
                            val hw = allocateHwChannel(256, sfx = false)
                            if (hw != -1) {
                                setupChannel(hw, instr)
                                voiceLastEvent[hw] = command
                                voiceFrequency[hw] = u8(curOffset)
                                setupFrequency(hw, u8(curOffset).toByte().toInt())
                            }
                        }
                    }
                } else {
                    val note = u8(curOffset)
                    val event = command + 0x10
                    val hw = (0 until 9).firstOrNull { voiceFrequency[it] == note && voiceLastEvent[it] == event }
                    if (hw != null) {
                        noteOff(hw)
                    } else {
                        // No voice plays the note: switch off the channel's rhythm instrument.
                        val ch = event - 0x90
                        val instr = if (ch in 0 until 16) instrumentOffset[ch] else 0
                        if (instr != 0 && u8(instr + 13) != 0) {
                            val rhythm = u8(instr + 13)
                            if (rhythm < 6) {
                                mdvdrState = mdvdrState and (MDVDR[rhythm] xor 0xFF)
                                writeReg(0xBD, mdvdrState)
                            }
                        }
                    }
                }
                curOffset += 2
            }
            return false
        }

        private fun parseVlq(): Int {
            var vlq = u8(curOffset++)
            if (vlq and 0x80 != 0) vlq = ((vlq - 0x80) shl 7) or u8(curOffset++)
            return vlq
        }

        private fun noteOff(channel: Int) {
            writeReg(0xB0 + channel, voiceB0[channel] and 0xDF)
            freeHwChannel(channel)
            voiceLastEvent[channel] = 0
            voiceB0[channel] = 0
            voiceFrequency[channel] = 0
        }

        private fun setupFrequency(channel: Int, freqIn: Int) {
            var frequency = (freqIn - 31).toByte().toInt() // int8 arithmetic, as in the original
            if (frequency < 0) frequency = 0
            var octave = 0
            while (frequency >= 12) { frequency -= 12; octave++ }
            val noteFrequency = NOTE_FREQUENCIES[frequency]
            val b0 = (octave shl 2) or (noteFrequency shr 8) or 0x20
            writeReg(0xA0 + channel, noteFrequency and 0xFF)
            voiceB0[channel] = b0
            writeReg(0xB0 + channel, b0)
        }

        private fun setupRhythm(rhythm: Int, instr: Int) {
            if (rhythm == 1) {
                setupChannel(6, instr)
                writeReg(0xA6, u8(instr))
                writeReg(0xB6, u8(instr + 1) and 0xDF)
                mdvdrState = mdvdrState or 0x10
                writeReg(0xBD, mdvdrState)
            } else if (rhythm < 6) {
                setupOperator(RHYTHM_OPERATOR[rhythm], instr + 8)
                writeReg(0xA0 + RHYTHM_CHANNEL[rhythm], u8(instr))
                writeReg(0xB0 + RHYTHM_CHANNEL[rhythm], u8(instr + 1) and 0xDF)
                writeReg(0xC0 + RHYTHM_CHANNEL[rhythm], u8(instr + 2))
                mdvdrState = mdvdrState or MDVDR[rhythm]
                writeReg(0xBD, mdvdrState)
            }
        }

        // ── Sound effects ────────────────────────────────────────

        fun startSfx(): Boolean {
            val priority = u8(0)
            writeReg(0xBD, 0x00)
            sfxActive = true
            val first = sfxChannels[0]
            first.hardwareChannel = allocateHwChannel(priority, sfx = true)
            if (first.hardwareChannel == -1) return false
            first.startOffset = 2
            first.currentOffset = 2
            first.state = CHANNEL_PARSE
            var next = 1
            var p = 2
            while (p < data.size && u8(p) != 0xFF) {
                when (u8(p)) {
                    1 -> p += 15   // instrument definition
                    2 -> p += 11   // note definition
                    0x80 -> p += 1 // loop
                    else -> {      // start of the next channel
                        p += 1
                        if (next >= 3) return false
                        val ch = sfxChannels[next++]
                        ch.hardwareChannel = allocateHwChannel(priority, sfx = true)
                        if (ch.hardwareChannel == -1) return false
                        ch.startOffset = p
                        ch.currentOffset = p
                        ch.state = CHANNEL_PARSE
                    }
                }
            }
            return true
        }

        private fun stopSfx() {
            if (!sfxActive) return
            sfxActive = false
            for (ch in sfxChannels) {
                if (ch.state != CHANNEL_OFF) {
                    clearChannel(ch)
                    ch.state = CHANNEL_OFF
                }
                if (ch.hardwareChannel != -1) {
                    freeHwChannel(ch.hardwareChannel)
                    ch.hardwareChannel = -1
                }
            }
        }

        private fun updateSfx() {
            if (--sfxTimer != 0) return
            sfxTimer = 4
            if (!sfxActive) return
            var active = false
            for (ch in sfxChannels) {
                if (ch.state != CHANNEL_OFF) {
                    active = true
                    if (ch.state == CHANNEL_PARSE) parseSlot(ch) else updateSlot(ch)
                }
            }
            if (!active) stopSfx()
        }

        private fun clearChannel(ch: Channel) {
            writeReg(0xA0 + ch.hardwareChannel, 0x00)
            writeReg(0xB0 + ch.hardwareChannel, 0x00)
        }

        private fun parseSlot(ch: Channel) {
            var guard = 0
            while (guard++ < 1000) {
                val at = ch.currentOffset
                if (at >= data.size) { clearChannel(ch); ch.state = CHANNEL_OFF; return }
                when (u8(at)) {
                    1 -> { // instrument definition
                        val p = at + 1
                        ch.instrumentData[0] = u8(p)
                        ch.instrumentData[1] = u8(p + 2)
                        ch.instrumentData[2] = u8(p + 9)
                        ch.instrumentData[3] = u8(p + 8)
                        ch.instrumentData[4] = u8(p + 4)
                        ch.instrumentData[5] = u8(p + 3)
                        ch.instrumentData[6] = 0
                        setupChannel(ch.hardwareChannel, p)
                        writeReg(0xA0 + ch.hardwareChannel, u8(p))
                        writeReg(0xB0 + ch.hardwareChannel, u8(p + 1) and 0xDF)
                        ch.currentOffset += 15
                    }
                    2 -> { // note definition
                        val p = at + 1
                        ch.state = CHANNEL_PLAY
                        noteOffOn(ch.hardwareChannel)
                        parseNote(ch.notes[0], ch, p)
                        parseNote(ch.notes[1], ch, p + 5)
                        return
                    }
                    0x80 -> ch.currentOffset = ch.startOffset // loop
                    else -> { // the next channel starts: this one is finished
                        clearChannel(ch)
                        ch.state = CHANNEL_OFF
                        return
                    }
                }
            }
            clearChannel(ch)
            ch.state = CHANNEL_OFF
        }

        private fun updateSlot(ch: Channel) {
            var p = ch.currentOffset + 1
            for (num in 0..1) {
                val flags = u8(p)
                if (flags and 0x80 != 0) {
                    val note = ch.notes[num]
                    var update = false
                    if (note.state == NOTE_SUSTAIN) {
                        if (--note.sustainTimer == 0) update = true
                    } else {
                        update = processNoteEnvelope(note)
                        val value = if (note.bias != 0) note.bias - note.instrumentValue else note.instrumentValue
                        writeRegisterSpecial(ch.hardwareChannel, value, flags and 0x07)
                    }
                    var skipPlayTime = false
                    if (update && processNote(note, ch, p)) {
                        if (flags and 0x08 == 0) {
                            ch.currentOffset += 11
                            ch.state = CHANNEL_PARSE
                            skipPlayTime = true
                        } else {
                            if (flags and 0x10 != 0) noteOffOn(ch.hardwareChannel)
                            note.state = NOTE_PRE_INIT
                            processNote(note, ch, p)
                        }
                    }
                    if (!skipPlayTime && flags and 0x20 != 0 && --note.playTime == 0) {
                        ch.currentOffset += 11
                        ch.state = CHANNEL_PARSE
                    }
                }
                p += 5
            }
        }

        private fun parseNote(note: Note, ch: Channel, at: Int) {
            if (u8(at) and 0x80 != 0) {
                note.state = NOTE_PRE_INIT
                processNote(note, ch, at)
                note.playTime = 0
                if (u8(at) and 0x20 != 0) {
                    note.playTime = (u8(at + 4) shr 4) * 118 + (u8(at + 4) and 0x0F) * 8
                }
            }
        }

        private fun processNote(note: Note, ch: Channel, at: Int): Boolean {
            if (++note.state == NOTE_OFF) return true
            val dataOffset = u8(at) and 0x07
            note.bias = NOTE_BIAS[dataOffset]
            val defaultValue = if (note.state == NOTE_ATTACK) ch.instrumentData[dataOffset] else 0
            var value = readRegisterSpecial(ch.hardwareChannel, defaultValue, dataOffset)
            if (note.bias != 0) value = (note.bias - value) and 0xFF
            note.instrumentValue = value
            if (note.state == NOTE_SUSTAIN) {
                note.sustainTimer = NUM_STEPS[u8(at + 3) shr 4]
                if (u8(at) and 0x40 != 0) note.sustainTimer = (((rnd() shl 8) * note.sustainTimer) shr 16) + 1
            } else {
                val timer1: Int
                val timer2: Int
                if (note.state == NOTE_RELEASE) {
                    timer1 = u8(at + 3) and 0x0F
                    timer2 = 0
                } else {
                    timer1 = u8(at + note.state + 1) shr 4
                    timer2 = u8(at + note.state + 1) and 0x0F
                }
                val adjust = ((NOTE_ADJUST[timer2] * NOTE_ADJUST_SCALE[dataOffset]) shr 16) - value
                setupNoteEnvelopeState(note, NUM_STEPS[timer1], adjust)
            }
            return false
        }

        private fun noteOffOn(channel: Int) {
            val value = readReg(0xB0 or channel)
            writeReg(0xB0 or channel, value and 0xDF)
            writeReg(0xB0 or channel, value or 0x20)
        }

        private fun specialRegister(channel: Int, offset: Int): Int {
            val base = if (USE_OPERATOR[offset]) OPERATOR_OFFSET[CHANNEL_OPERATOR_OFFSET[offset] + channel * 2]
            else CHANNEL_OFFSET[channel]
            return base + BASE_REGISTER[offset]
        }

        private fun writeRegisterSpecial(channel: Int, value: Int, offset: Int) {
            if (offset == 6) return
            val reg = specialRegister(channel, offset)
            var regValue = readReg(reg) and REGISTER_MASK[offset].inv() and 0xFF
            regValue = regValue or (((value and 0xFF) shl REGISTER_SHIFT[offset]) and 0xFF)
            writeReg(reg, regValue)
        }

        private fun readRegisterSpecial(channel: Int, defaultValue: Int, offset: Int): Int {
            if (offset == 6) return 0
            val reg = specialRegister(channel, offset)
            val regValue = if (defaultValue != 0) defaultValue else readReg(reg)
            return (regValue and REGISTER_MASK[offset]) shr REGISTER_SHIFT[offset]
        }

        private fun setupNoteEnvelopeState(note: Note, steps: Int, adjust: Int) {
            note.preIncrease = 0
            if (abs(adjust) > steps) {
                note.preIncrease = 1
                note.adjust = adjust / steps
                note.stepIncrease = abs(adjust % steps)
            } else {
                note.adjust = adjust
                note.stepIncrease = abs(adjust)
            }
            note.step = steps
            note.stepCounter = 0
            note.timer = steps
        }

        private fun processNoteEnvelope(note: Note): Boolean {
            if (note.preIncrease != 0) note.instrumentValue += note.adjust
            note.stepCounter += note.stepIncrease
            if (note.stepCounter >= note.step) {
                note.stepCounter -= note.step
                if (note.adjust < 0) note.instrumentValue-- else note.instrumentValue++
            }
            return --note.timer == 0
        }

        private fun rnd(): Int {
            rndSeed = if (rndSeed and 1 != 0) (rndSeed shr 1) xor 0xB8 else rndSeed shr 1
            return rndSeed
        }
    }

    private const val CHANNEL_OFF = 0
    private const val CHANNEL_PARSE = 1
    private const val CHANNEL_PLAY = 2
    private const val NOTE_PRE_INIT = -1
    private const val NOTE_ATTACK = 0
    private const val NOTE_SUSTAIN = 2
    private const val NOTE_RELEASE = 3
    private const val NOTE_OFF = 4

    private val OPERATOR_OFFSET = intArrayOf(0, 3, 1, 4, 2, 5, 8, 11, 9, 12, 10, 13, 16, 19, 17, 20, 18, 21)
    private val NOTE_FREQUENCIES = intArrayOf(0x200, 0x21E, 0x23F, 0x261, 0x285, 0x2AB, 0x2D4, 0x300, 0x32E, 0x35E, 0x390, 0x3C7)
    private val MDVDR = intArrayOf(0x00, 0x10, 0x08, 0x04, 0x02, 0x01)
    private val RHYTHM_OPERATOR = intArrayOf(0x00, 0x00, 0x14, 0x12, 0x15, 0x11)
    private val RHYTHM_CHANNEL = intArrayOf(0x00, 0x00, 0x07, 0x08, 0x08, 0x07)
    private val NOTE_BIAS = intArrayOf(0x00, 0x00, 0x3F, 0x00, 0x3F, 0x00, 0x00)
    private val NUM_STEPS = intArrayOf(1, 4, 6, 8, 10, 14, 18, 24, 36, 64, 100, 160, 240, 340, 600, 1200)
    private val NOTE_ADJUST_SCALE = intArrayOf(255, 7, 63, 15, 63, 15, 63)
    private val NOTE_ADJUST = intArrayOf(
        0, 4369, 8738, 13107, 17476, 21845, 26214, 30583,
        34952, 39321, 43690, 48059, 52428, 56797, 61166, 65535,
    )
    private val USE_OPERATOR = booleanArrayOf(false, false, true, true, true, true, false)
    private val CHANNEL_OFFSET = intArrayOf(0, 1, 2, 3, 4, 5, 6, 7, 8, 8, 7)
    private val CHANNEL_OPERATOR_OFFSET = intArrayOf(0, 0, 1, 1, 0, 0, 0)
    private val BASE_REGISTER = intArrayOf(0xA0, 0xC0, 0x40, 0x20, 0x40, 0x20, 0x00)
    private val REGISTER_MASK = intArrayOf(0xFF, 0x0E, 0x3F, 0x0F, 0x3F, 0x0F, 0x00)
    private val REGISTER_SHIFT = intArrayOf(0, 1, 0, 0, 0, 0, 0)
}

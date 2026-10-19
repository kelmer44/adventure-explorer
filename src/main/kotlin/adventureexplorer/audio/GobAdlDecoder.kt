package adventureexplorer.audio

import adventureexplorer.model.SoundData
import java.lang.Math.PI
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.sin

/**
 * Renders Coktel Vision's ADL event format to PCM for preview/export.
 *
 * The original games send these events to an OPL2. This renderer keeps the
 * original timing, notes, volume, pitch and instrument changes and uses a
 * lightweight two-operator FM approximation. It deliberately lives in the
 * preview layer: game execution still belongs to a full Gob interpreter.
 */
object GobAdlDecoder {
    private const val SAMPLE_RATE = 22_050
    private const val MAX_DURATION_MS = 10 * 60 * 1000
    private const val PARAM_COUNT = 14
    private const val TIMBRE_WORDS = PARAM_COUNT * 2
    private const val VOICE_COUNT = 11

    private sealed interface Command {
        data class NoteOn(val voice: Int, val note: Int, val volume: Int?) : Command
        data class NoteOff(val voice: Int) : Command
        data class Volume(val voice: Int, val value: Int) : Command
        data class Instrument(val voice: Int, val value: Int) : Command
        data class Pitch(val voice: Int, val value: Int) : Command
        data class ModifyInstrument(val instrument: Int, val param: Int, val value: Int) : Command
    }

    private data class Event(val timeMs: Int, val command: Command)

    private data class Voice(
        var on: Boolean = false,
        var note: Int = 60,
        var volume: Int = 127,
        var instrument: Int = 0,
        var pitch: Int = 0x2000,
        var carrierPhase: Double = 0.0,
        var modulatorPhase: Double = 0.0,
        var ageSamples: Int = 0
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
        val events = parsed.first
        return render(timbres, percussionMode, events, parsed.second)
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
        var tempo = baseTempo
        var pos = 70
        fun byte(): Int { require(pos < end); return u8(data, pos++) }
        var time = 0.0
        fun delay(n: Int) {
            var ticks = n
            if (ticks == 0xF8) { ticks = 240; if (pos < end && u8(data, pos) != 0xF8) ticks += byte() }
            time += ticks * 60000.0 / (ticksPerBeat * tempo)
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
                if (a == 0x7F && b == 0) { tempo = baseTempo * byte() + ((baseTempo * byte()) shr 7); require(tempo > 0); require(byte() == 0xF7) }
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
                0xE0 -> { val value = byte() + (byte() shl 7); Command.Pitch(voice, 8192 + ((value - 8192) * u8(data, 59) / 2)) }
                else -> error("Invalid MUS command")
            }
            if (event != null) events += Event(time.toInt(), event)
            delay(byte())
        }
        require(ended && events.isNotEmpty())
        render(timbres, u8(data, 58) != 0, events, time.toInt() + 250)
    }.getOrNull()

    private fun render(timbres: Array<IntArray>, percussionMode: Boolean, events: List<Event>, duration: Int): SoundData? {
        val durationMs = duration.coerceIn(1, MAX_DURATION_MS)
        val totalSamples = ((durationMs.toLong() * SAMPLE_RATE) / 1000L).toInt()
        if (totalSamples <= 0) return null

        val pcm = ByteArray(totalSamples * 2)
        val voices = Array(VOICE_COUNT) { Voice() }
        var eventIndex = 0

        for (sampleIndex in 0 until totalSamples) {
            val timeMs = (sampleIndex.toLong() * 1000L / SAMPLE_RATE).toInt()
            while (eventIndex < events.size && events[eventIndex].timeMs <= timeMs) {
                apply(events[eventIndex].command, voices, timbres)
                eventIndex++
            }

            var mixed = 0.0
            var active = 0
            for (voiceIndex in voices.indices) {
                val voice = voices[voiceIndex]
                if (!voice.on) continue
                if (percussionMode && voiceIndex >= 6) {
                    // OPL rhythm voices are noise-rich; deterministic noise is
                    // a closer preview than treating them as pure melody notes.
                    val noise = (((sampleIndex * 1103515245L + voiceIndex * 12345L) ushr 16) and 0xFFFF) / 32767.5 - 1.0
                    mixed += noise * voice.volume / 127.0 * 0.32
                    active++
                    continue
                }

                val instrument = timbres[voice.instrument.coerceIn(timbres.indices)]
                val bendSemitones = ((voice.pitch - 0x2000) / 8192.0) * 2.0
                val frequency = 440.0 * 2.0.pow((voice.note + bendSemitones - 69.0) / 12.0)
                val modMulti = oplMultiplier(instrument[1])
                val carrierMulti = oplMultiplier(instrument[PARAM_COUNT + 1])
                val modLevel = (63 - (instrument[8] and 0x3F)) / 63.0
                val carrierLevel = (63 - (instrument[PARAM_COUNT + 8] and 0x3F)) / 63.0
                val feedback = (instrument[2] and 7) / 7.0
                val fm = instrument[12] == 0
                val attack = (0.32 - (instrument[3].coerceIn(0, 15) / 15.0) * 0.31).coerceAtLeast(0.005)
                val envelope = (voice.ageSamples / (attack * SAMPLE_RATE)).coerceIn(0.0, 1.0)
                val modulator = sin(voice.modulatorPhase) * modLevel * (1.5 + feedback * 5.0)
                val wave = instrument[PARAM_COUNT + 13] and 3
                val carrier = waveform(voice.carrierPhase + if (fm) modulator else 0.0, wave)
                val additive = if (fm) 0.0 else sin(voice.modulatorPhase) * modLevel * 0.45
                mixed += (carrier * carrierLevel + additive) * envelope * voice.volume / 127.0
                active++

                voice.carrierPhase = wrap(voice.carrierPhase + 2.0 * PI * frequency * carrierMulti / SAMPLE_RATE)
                voice.modulatorPhase = wrap(voice.modulatorPhase + 2.0 * PI * frequency * modMulti / SAMPLE_RATE)
                voice.ageSamples++
            }

            if (active > 0) mixed /= maxOf(2.0, active * 0.72)
            // Soft limiting avoids harsh clipping on dense passages.
            val limited = mixed / (1.0 + abs(mixed))
            val value = (limited * 28_000.0).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            pcm[sampleIndex * 2] = value.toByte()
            pcm[sampleIndex * 2 + 1] = (value shr 8).toByte()
        }

        return SoundData(pcm, SAMPLE_RATE, 16, 1, true)
    }

    private fun parseEvents(data: ByteArray, songOffset: Int): Pair<List<Event>, Int>? {
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
            events += Event(timeMs, command)
            timeMs += delay
        }

        if (!ended || events.size < 8 || timeMs < 500) return null
        return events to (timeMs + 250)
    }

    private fun apply(command: Command, voices: Array<Voice>, timbres: Array<IntArray>) {
        when (command) {
            is Command.NoteOn -> voices[command.voice].apply {
                on = true
                note = command.note
                command.volume?.let { volume = it.coerceIn(0, 127) }
                carrierPhase = 0.0
                modulatorPhase = 0.0
                ageSamples = 0
            }
            is Command.NoteOff -> voices[command.voice].on = false
            is Command.Volume -> voices[command.voice].volume = command.value.coerceIn(0, 127)
            is Command.Instrument -> voices[command.voice].instrument = command.value.coerceIn(timbres.indices)
            is Command.Pitch -> voices[command.voice].pitch = command.value.coerceIn(0, 0x3FFF)
            is Command.ModifyInstrument -> if (command.instrument in timbres.indices && command.param in 0 until TIMBRE_WORDS) {
                timbres[command.instrument][command.param] = command.value
            }
        }
    }

    private fun waveform(phase: Double, wave: Int): Double {
        val sine = sin(phase)
        return when (wave) {
            1 -> if (sine > 0.0) sine else 0.0
            2 -> abs(sine) * 2.0 - 1.0
            3 -> if (sine > 0.0) abs(sin(phase * 0.5)) else 0.0
            else -> sine
        }
    }

    private fun oplMultiplier(value: Int): Double = when (value and 0x0F) {
        0 -> 0.5
        11 -> 10.0
        13 -> 12.0
        14, 15 -> 15.0
        else -> (value and 0x0F).toDouble()
    }

    private fun wrap(value: Double): Double = if (value >= 2.0 * PI) value % (2.0 * PI) else value
    private fun u8(data: ByteArray, offset: Int): Int = data[offset].toInt() and 0xFF
    private fun u16le(data: ByteArray, offset: Int): Int = u8(data, offset) or (u8(data, offset + 1) shl 8)
}

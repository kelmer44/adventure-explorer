package adventureexplorer.audio.imuse

import adventureexplorer.audio.Opl3
import adventureexplorer.audio.imuse.ImuseSong.HookKind
import adventureexplorer.model.SoundData
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.locks.LockSupport
import javax.sound.midi.MidiSystem
import javax.sound.midi.Synthesizer
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.SourceDataLine

/**
 * Real-time iMUSE playback for the preview: runs an [ImuseSequencer] at 250 Hz
 * on its own thread, either into the Nuked OPL emulator through
 * [AdlibOplDevice] (AdLib tracks) and a [SourceDataLine], or into Java's MIDI
 * synthesizer through [JavaMidiDevice]. Hooks are armed from the UI thread and
 * applied between timer ticks.
 */
class ImusePlayback(private val song: ImuseSong, private val useOpl: Boolean) {
    data class Snapshot(
        val playing: Boolean,
        val position: ImuseSong.Position,
        val armed: List<Triple<HookKind, Int, Int>>,
        val log: List<String>,
    )

    @Volatile private var snapshot = Snapshot(false, ImuseSong.Position(0, 1, 0), emptyList(), emptyList())
    private val commands = ConcurrentLinkedQueue<(ImuseSequencer) -> Unit>()
    private val log = ArrayDeque<String>()
    @Volatile private var running = false
    private var thread: Thread? = null

    val state: Snapshot get() = snapshot

    fun armHook(kind: HookKind, id: Int, channel: Int) {
        commands += { it.armHook(kind, id, if (channel < 0) 16 else channel) }
        if (!running) pending += Triple(kind, channel, id)
    }

    fun clearHooks() { commands += { it.clearHooks() }; pending.clear() }

    // Hooks armed before Play is pressed are applied when playback starts.
    private val pending = mutableListOf<Triple<HookKind, Int, Int>>()

    fun start() {
        if (running) return
        running = true
        log.clear()
        thread = Thread({
            runCatching { if (useOpl) runOpl() else runMidi() }
                .onFailure { e -> synchronized(log) { log.addLast("Playback failed: ${e.message ?: e.javaClass.simpleName}") } }
            running = false
            publish(null)
        }, "imuse-playback").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        running = false
        thread?.join(1000)
        thread = null
    }

    private fun record(event: ImuseEvent) {
        val text = when (event) {
            is ImuseEvent.Marker -> "Marker ${event.id} at ${event.at}"
            is ImuseEvent.Jumped -> if (event.hookId == 0) "Jump ${event.from} → ${event.to}" else "Hook ${event.hookId}: jump ${event.from} → ${event.to}"
            is ImuseEvent.HookFired -> if (event.kind == HookKind.JUMP) null else "Hook ${event.id} (${event.kind.label}) at ${event.at}: ${event.detail}"
            is ImuseEvent.LoopRepeated -> "Loop ${event.from} → ${event.to} (${event.remaining} left)"
            ImuseEvent.Ended -> "End of song"
        } ?: return
        synchronized(log) {
            log.addLast(text)
            while (log.size > 200) log.removeFirst()
        }
    }

    private fun publish(seq: ImuseSequencer?) {
        val entries = synchronized(log) { log.toList() }
        snapshot = Snapshot(running && seq?.active == true, seq?.position ?: snapshot.position, seq?.armedHooks() ?: emptyList(), entries)
    }

    private fun drain(seq: ImuseSequencer) {
        while (true) (commands.poll() ?: break)(seq)
    }

    private fun newSequencer(device: ImuseDevice): ImuseSequencer {
        commands.clear()
        val seq = ImuseSequencer(song, device, ::record)
        for ((kind, channel, id) in pending) seq.armHook(kind, id, if (channel < 0) 16 else channel)
        pending.clear()
        return seq
    }

    private fun runOpl() {
        val chip = Opl3(SAMPLE_RATE)
        val device = AdlibOplDevice(chip)
        val seq = newSequencer(device)
        val format = AudioFormat(SAMPLE_RATE.toFloat(), 16, 1, true, false)
        val line: SourceDataLine = adventureexplorer.audio.AudioLines.sourceLine(format)
        line.open(format, SAMPLE_RATE / 5 * 2)
        line.start()
        val buffer = ByteArray(4096)
        var filled = 0
        val frame = IntArray(2)
        var due = 0.0
        var tail = SAMPLE_RATE
        var ticks = 0
        try {
            while (running && tail > 0) {
                drain(seq)
                if (seq.active) { seq.onTimer() }
                device.onTimer()
                due += SAMPLE_RATE.toDouble() / ImuseSequencer.TIMER_HZ
                val n = due.toInt()
                due -= n
                repeat(n) {
                    chip.generate(frame)
                    val v = ((frame[0] + frame[1]) / 2).coerceIn(-32768, 32767)
                    buffer[filled++] = v.toByte(); buffer[filled++] = (v shr 8).toByte()
                    if (filled == buffer.size) { line.write(buffer, 0, filled); filled = 0 }
                }
                if (!seq.active) tail -= n
                if (++ticks % 25 == 0) publish(seq)
            }
            if (filled > 0) line.write(buffer, 0, filled)
            if (running) line.drain()
        } finally {
            line.stop(); line.close()
            seq.stop()
        }
    }

    private fun runMidi() {
        val synth: Synthesizer = MidiSystem.getSynthesizer()
        synth.open()
        val device = JavaMidiDevice(synth.receiver)
        val seq = newSequencer(device)
        val period = 1_000_000_000L / ImuseSequencer.TIMER_HZ
        var next = System.nanoTime()
        var ticks = 0
        try {
            while (running && seq.active) {
                drain(seq)
                seq.onTimer()
                if (++ticks % 25 == 0) publish(seq)
                next += period
                val wait = next - System.nanoTime()
                if (wait > 0) LockSupport.parkNanos(wait) else if (wait < -100_000_000L) next = System.nanoTime()
            }
        } finally {
            seq.stop()
            device.allNotesOff()
            Thread.sleep(300)
            synth.close()
        }
    }

    companion object {
        const val SAMPLE_RATE = 44_100
        private const val MAX_RENDER_MS = 10 * 60 * 1000

        /**
         * Render an AdLib song straight through on the OPL emulator, for export:
         * no hooks armed, stopping at the end of the song or the first
         * unconditional jump back (the song's own loop), plus one second of tail.
         */
        fun renderOpl(song: ImuseSong): SoundData? {
            val chip = Opl3(SAMPLE_RATE)
            val device = AdlibOplDevice(chip)
            var looped = false
            val seq = ImuseSequencer(song, device) { e ->
                // The song's own loop is an unconditional jump back (a forward one skips an intro).
                if (e is ImuseEvent.Jumped && e.hookId == 0 && e.to.track == e.from.track &&
                    (e.to.beat < e.from.beat || (e.to.beat == e.from.beat && e.to.tick <= e.from.tick))) looped = true
                if (e is ImuseEvent.LoopRepeated) looped = true
            }
            val out = java.io.ByteArrayOutputStream()
            val frame = IntArray(2)
            var due = 0.0
            var tail = -1
            val max = MAX_RENDER_MS.toLong() * SAMPLE_RATE / 1000
            var written = 0L
            while (written < max) {
                if (tail < 0) {
                    seq.onTimer()
                    if (!seq.active || looped) { seq.stop(); tail = SAMPLE_RATE }
                }
                device.onTimer()
                due += SAMPLE_RATE.toDouble() / ImuseSequencer.TIMER_HZ
                val n = due.toInt()
                due -= n
                repeat(n) {
                    chip.generate(frame)
                    val v = ((frame[0] + frame[1]) / 2).coerceIn(-32768, 32767)
                    out.write(v and 0xFF); out.write((v shr 8) and 0xFF)
                }
                written += n
                if (tail >= 0) { tail -= n; if (tail <= 0) break }
            }
            if (written == 0L) return null
            return SoundData(out.toByteArray(), SAMPLE_RATE, 16, 1, true)
        }
    }
}

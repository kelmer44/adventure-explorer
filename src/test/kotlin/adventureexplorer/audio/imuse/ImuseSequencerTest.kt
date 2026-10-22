package adventureexplorer.audio.imuse

import adventureexplorer.audio.imuse.ImuseSong.HookKind
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream

class ImuseSequencerTest {
    /** Records what the sequencer sends to the device. */
    private class Capture : ImuseDevice {
        val log = mutableListOf<String>()
        val instruments = mutableListOf<ByteArray>()
        private var next = 0
        override fun allocateChannel(): ImuseChannel = Ch(next++)
        override fun percussionChannel(): ImuseChannel = Ch(9)
        override fun allNotesOff() {}
        inner class Ch(val n: Int) : ImuseChannel {
            override fun noteOn(note: Int, velocity: Int) { log += "on $note" }
            override fun noteOff(note: Int) { log += "off $note" }
            override fun programChange(program: Int) { log += "program $program" }
            override fun pitchBend(bend: Int) {}
            override fun pitchBendFactor(semitones: Int) {}
            override fun volume(value: Int) {}
            override fun panPosition(value: Int) {}
            override fun transpose(semitones: Int) {}
            override fun detune(value: Int) {}
            override fun priority(value: Int) {}
            override fun sustain(on: Boolean) {}
            override fun modulationWheel(value: Int) {}
            override fun effectLevel(value: Int) {}
            override fun chorusLevel(value: Int) {}
            override fun allNotesOff() {}
            override fun adlibInstrument(data: ByteArray) { instruments += data }
            override fun release() {}
        }
    }

    // ── Building songs ───────────────────────────────────────

    private class Track {
        val out = ByteArrayOutputStream()
        private var lastTick = 0
        private var timed = false
        /** Delta time for the next event; events without one follow at the same tick. */
        fun at(beat: Int, tick: Int = 0): Track {
            val t = (beat - 1) * 480 + tick
            vlq(t - lastTick); lastTick = t; timed = true; return this
        }
        private fun delta() { if (!timed) vlq(0); timed = false }
        private fun vlq(v: Int) {
            val bytes = mutableListOf(v and 0x7F)
            var x = v shr 7
            while (x > 0) { bytes.add(0, (x and 0x7F) or 0x80); x = x shr 7 }
            bytes.forEach { out.write(it) }
        }
        fun raw(vararg b: Int) = apply { delta(); b.forEach { out.write(it) } }
        fun imuse(vararg msg: Int) = apply { delta(); out.write(0xF0); vlq(msg.size + 2); out.write(0x7D); msg.forEach { out.write(it) }; out.write(0xF7) }
        fun end() = apply { raw(0xFF, 0x2F, 0) }
    }

    private fun nibbles(vararg bytes: Int) = bytes.flatMap { listOf((it shr 4) and 0x0F, it and 0x0F) }.toIntArray()
    private fun be16(v: Int) = intArrayOf((v shr 8) and 0xFF, v and 0xFF)

    private fun jump(id: Int, track: Int, beat: Int, tick: Int = 0) =
        intArrayOf(48, 0) + nibbles(id, *be16(track), *be16(beat), *be16(tick))

    private fun song(tag: String, vararg tracks: Track): ImuseSong {
        val smf = ByteArrayOutputStream()
        smf.write("MThd".toByteArray()); smf.write(byteArrayOf(0, 0, 0, 6, 0, 2, 0, tracks.size.toByte(), 1, 0xE0.toByte()))
        for (t in tracks) {
            val body = t.out.toByteArray()
            smf.write("MTrk".toByteArray())
            smf.write(byteArrayOf((body.size shr 24).toByte(), (body.size shr 16).toByte(), (body.size shr 8).toByte(), body.size.toByte()))
            smf.write(body)
        }
        return ImuseSong.parse(tag, smf.toByteArray())!!
    }

    /** Part 0 on, volume 127, program [program] (sysex 0). */
    private fun Track.allocatePart(program: Int) = imuse(0, 0, *nibbles(1, 0, 127, 0, 0, 0, 2, program))

    private fun run(song: ImuseSong, device: ImuseDevice, seconds: Double, arm: (ImuseSequencer) -> Unit = {}): List<ImuseEvent> {
        val events = mutableListOf<ImuseEvent>()
        val seq = ImuseSequencer(song, device) { events += it }
        arm(seq)
        repeat((seconds * ImuseSequencer.TIMER_HZ).toInt()) { if (seq.active) seq.onTimer() }
        return events
    }

    // ── Tests ────────────────────────────────────────────────

    @Test fun `sysex nibbles decode like ScummVM`() {
        val msg = byteArrayOf(0, 0, 1, 2, 0x0F, 0x0F)
        assertArrayEquals(byteArrayOf(0x12, 0xFF.toByte(), 0), ImuseSong.decodeSysexBytes(msg, 2, 4))
    }

    @Test fun `catalogue lists hooks, markers and loops with positions`() {
        val s = song("GMD ", Track().at(1).imuse(*jump(5, 0, 1)).at(2).imuse(64, 0, 7)
            .at(3).imuse(50, 2, *nibbles(9, 0)).at(4).imuse(80, 0, *nibbles(*be16(2), *be16(1), *be16(0), *be16(3), *be16(0))).at(5).end())
        val hooks = s.catalogue.filterIsInstance<ImuseSong.CatalogueEntry.Hook>()
        assertEquals(listOf(HookKind.JUMP to 5, HookKind.PART_ON_OFF to 9), hooks.map { it.kind to it.id })
        assertEquals(ImuseSong.Position(0, 1, 0), hooks[0].target)
        assertEquals(2, hooks[1].channel)
        assertEquals(7, s.catalogue.filterIsInstance<ImuseSong.CatalogueEntry.Marker>().single().id)
        assertEquals(2, s.catalogue.filterIsInstance<ImuseSong.CatalogueEntry.Loop>().single().count)
        assertEquals(setOf(Triple(HookKind.JUMP, -1, 5), Triple(HookKind.PART_ON_OFF, 2, 9)), s.armableHooks.keys)
    }

    @Test fun `a jump hook fires only once armed and a low id disarms after firing`() {
        // Beat 2 has a hook-5 jump to track 1; the song otherwise ends at beat 4.
        val s = song("GMD ",
            Track().at(1).allocatePart(0).at(2).imuse(*jump(5, 1, 1)).at(4).end(),
            Track().at(1).raw(0x90, 60, 100).at(2).raw(0x80, 60, 0).at(3).end())
        val plain = run(s, Capture(), 3.0)
        assertTrue(plain.none { it is ImuseEvent.Jumped })
        assertTrue(plain.last() is ImuseEvent.Ended)

        val device = Capture()
        var seq: ImuseSequencer? = null
        val armed = run(s, device, 3.0) { it.armHook(HookKind.JUMP, 5); seq = it }
        val jumped = armed.filterIsInstance<ImuseEvent.Jumped>().single()
        assertEquals(5, jumped.hookId)
        assertEquals(ImuseSong.Position(1, 1, 0), jumped.to)
        assertTrue("track 1's note plays", device.log.contains("on 60"))
        assertTrue("hook 5 is one-shot", seq!!.armedHooks().isEmpty())
    }

    @Test fun `hook 0 jumps every time and loops count down`() {
        val looping = song("GMD ", Track().at(1).allocatePart(0).at(2).imuse(*jump(0, 0, 1)).at(3).end())
        val events = run(looping, Capture(), 2.0)
        assertTrue(events.count { it is ImuseEvent.Jumped } >= 3)
        assertTrue(events.none { it is ImuseEvent.Ended })

        // Loop twice from beat 4 back to beat 2 (the loop is set before its target, as in the games).
        val loop = song("GMD ", Track().at(1).imuse(80, 0, *nibbles(*be16(2), *be16(2), *be16(0), *be16(4), *be16(0))).at(6).end())
        val loopEvents = run(loop, Capture(), 8.0)
        assertEquals(listOf(1, 0), loopEvents.filterIsInstance<ImuseEvent.LoopRepeated>().map { it.remaining })
        assertTrue(loopEvents.last() is ImuseEvent.Ended)
    }

    @Test fun `part on off hook silences a part only when armed`() {
        fun build() = song("GMD ", Track().at(1).allocatePart(0).imuse(50, 0, *nibbles(3, 0))
            .at(2).raw(0x90, 64, 100).at(3).raw(0x80, 64, 0).end())
        val plain = Capture(); run(build(), plain, 2.0)
        assertTrue(plain.log.contains("on 64"))
        val muted = Capture(); run(build(), muted, 2.0) { it.armHook(HookKind.PART_ON_OFF, 3, 0) }
        assertFalse(muted.log.contains("on 64"))
    }

    @Test fun `markers are reported`() {
        val events = run(song("GMD ", Track().at(1).imuse(64, 0, 4, 5).at(2).end()), Capture(), 1.0)
        assertEquals(listOf(4, 5), events.filterIsInstance<ImuseEvent.Marker>().map { it.id })
    }

    @Test fun `AdLib part instruments reach the device`() {
        val instrument = IntArray(30) { it + 1 }
        val s = song("ADL ", Track().at(1).imuse(16, 0, 0, *nibbles(*instrument)).raw(0x90, 60, 100).at(2).raw(0x80, 60, 0).end())
        val device = Capture()
        run(s, device, 1.0)
        assertArrayEquals(ByteArray(30) { (it + 1).toByte() }, device.instruments.single())
        assertTrue(device.log.contains("on 60"))
    }

    @Test fun `Roland songs map MT-32 programs to General MIDI`() {
        val s = song("ROL ", Track().at(1).allocatePart(0).raw(0xC0, 0x30).at(2).end())
        val device = Capture()
        run(s, device, 1.0)
        assertEquals(listOf("program 0", "program ${ImuseSequencer.MT32_TO_GM[0x30]}"), device.log.filter { it.startsWith("program") })
    }

    @Test fun `AdLib songs render through the OPL emulator`() {
        // A simple two-operator sine: modulator silent, carrier full level, fast attack, sustained.
        val instrument = intArrayOf(0x01, 0x3F, 0x0F, 0x0F, 0, 0x01, 0x00, 0x0F, 0x0F, 0, 0x01) + IntArray(19)
        val s = song("ADL ", Track().at(1).imuse(16, 0, 0, *nibbles(*instrument)).raw(0x90, 60, 127).at(3).raw(0x80, 60, 0).at(4).end())
        val sound = ImusePlayback.renderOpl(s)!!
        val pcm = java.nio.ByteBuffer.wrap(sound.samples).order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val loud = (4410 until 40000).count { kotlin.math.abs(pcm.get(it).toInt()) > 500 }
        assertTrue("note is audible ($loud loud samples)", loud > 10_000)
    }
}

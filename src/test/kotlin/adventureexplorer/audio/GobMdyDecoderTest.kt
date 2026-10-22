package adventureexplorer.audio

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class GobMdyDecoderTest {
    private fun fixture(): Pair<ByteArray, ByteArray> {
        // 60 bpm, 10 ticks/beat; running status note-off at 500ms and end at 1000ms.
        val events = byteArrayOf(0, 0xC0.toByte(), 0, 0, 0x90.toByte(), 60, 127, 5, 60, 0, 5, 0xFC.toByte())
        val song = ByteBuffer.allocate(70 + events.size).order(ByteOrder.LITTLE_ENDIAN)
        song.put(1); song.position(36); song.put(10); song.put(4)
        song.position(42); song.putInt(events.size)
        song.position(59); song.put(2); song.putShort(60)
        song.position(70); song.put(events)
        val bank = ByteBuffer.allocate(15 + 56).order(ByteOrder.LITTLE_ENDIAN)
        bank.put(1); bank.put(0); bank.putShort(1); bank.putShort(15)
        bank.position(15)
        // ScummVM's Gob piano preset: modulator, carrier, then the two wave selects.
        val piano = intArrayOf(1, 1, 3, 15, 5, 0, 1, 3, 15, 0, 0, 0, 1, 0, 1, 1, 15, 7, 0, 2, 4, 0, 0, 0, 1, 0, 0, 0)
        piano.forEach { bank.putShort(it.toShort()) }
        return song.array() to bank.array()
    }
    @Test fun `MDY running status and tick timing render with TBR instruments`() {
        val (song, bank) = fixture()
        val sound = GobAdlDecoder.decodeMdy(song, bank)!!
        assertEquals(44_100, sound.sampleRate)
        assertEquals(1250L, sound.durationMs)
        // The note sounds until the note-off at 500 ms, then the OPL envelope releases.
        fun energy(fromMs: Int, toMs: Int): Double {
            val samples = java.nio.ByteBuffer.wrap(sound.samples).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            return (fromMs * 441 / 10 until toMs * 441 / 10).sumOf { val v = samples.get(it).toDouble(); v * v }
        }
        assertTrue(energy(100, 400) > 0)
        assertTrue(energy(1050, 1250) < energy(100, 400) / 100)
    }
    @Test fun `malformed timbre banks and truncated events fail safely`() {
        val (song, bank) = fixture()
        assertNull(GobAdlDecoder.decodeMdy(song, bank.copyOf(20)))
        assertNull(GobAdlDecoder.decodeMdy(song.copyOf(song.size - 1), bank))
    }
}

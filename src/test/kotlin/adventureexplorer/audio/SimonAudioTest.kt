package adventureexplorer.audio

import org.junit.Assert.*
import org.junit.Test
import javax.sound.midi.MidiSystem

class SimonAudioTest {
    private fun voc(vararg blocks: Int): ByteArray {
        val header = "Creative Voice File".toByteArray() + byteArrayOf(26,26,0,20,1,31,17)
        return header + blocks.map { it.toByte() }.toByteArray()
    }
    @Test fun `VOC joins continuation blocks and preserves unsigned samples`() {
        val sound = EncodedAudioDecoder.decode(voc(1,4,0,0, 156,0,10,20, 2,2,0,0,30,40, 0))!!
        assertEquals(10000, sound.sampleRate)
        assertEquals(8, sound.bitsPerSample)
        assertFalse(sound.signed)
        assertArrayEquals(byteArrayOf(10,20,30,40), sound.samples)
    }
    @Test fun `truncated and unsupported VOC blocks are rejected`() {
        assertNull(EncodedAudioDecoder.decode(voc(1,20,0,0,156,0,10)))
        assertNull(EncodedAudioDecoder.decode(voc(1,3,0,0,156,1,10,0)))
        assertNull(EncodedAudioDecoder.decode(byteArrayOf(1,2,3,4)))
    }
    @Test fun `GMF omits broken pitch bends and retains note timing`() {
        val data = "GMF".toByteArray() + byteArrayOf(1,0,4,1, 0,0x90.toByte(),60,100,
            12,0xE0.toByte(), 12,0x80.toByte(),60,0, 0,0,0)
        val sequence = MidiSystem.getSequence(GmfToMidiConverter.convert(data)!!.inputStream())
        assertEquals(192, sequence.resolution)
        assertEquals(24L, sequence.tickLength)
        assertEquals(0x90, sequence.tracks[0].get(1).message.status)
        assertEquals(0x80, sequence.tracks[0].get(2).message.status)
        assertNull(GmfToMidiConverter.convert("GMF".toByteArray()))
    }
}

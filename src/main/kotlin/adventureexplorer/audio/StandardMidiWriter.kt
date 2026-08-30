package adventureexplorer.audio

import java.io.ByteArrayOutputStream

/**
 * Assembles a standard Format-0 MIDI file (MThd + single MTrk) from a flat list
 * of absolute-tick events. Shared by the CMF and XMI converters.
 */
internal object StandardMidiWriter {

    data class TimedEvent(val tick: Long, val priority: Int, val bytes: ByteArray)

    fun build(division: Int, events: List<TimedEvent>): ByteArray {
        val sorted = events.sortedWith(compareBy({ it.tick }, { it.priority }))

        val track = ByteArrayOutputStream()
        var prevTick = 0L
        for (event in sorted) {
            track.write(vlq(event.tick - prevTick))
            track.write(event.bytes)
            prevTick = event.tick
        }
        // Always terminate with an explicit End of Track meta event.
        track.write(vlq(0))
        track.write(byteArrayOf(0xFF.toByte(), 0x2F, 0x00))
        val trackBytes = track.toByteArray()

        val out = ByteArrayOutputStream()
        out.write("MThd".toByteArray(Charsets.US_ASCII))
        out.write(u32be(6))
        out.write(u16be(0))          // format 0: single track
        out.write(u16be(1))          // ntrks
        out.write(u16be(division))
        out.write("MTrk".toByteArray(Charsets.US_ASCII))
        out.write(u32be(trackBytes.size))
        out.write(trackBytes)
        return out.toByteArray()
    }

    private fun vlq(value: Long): ByteArray {
        var v = value.coerceAtLeast(0)
        val groups = mutableListOf((v and 0x7F).toInt())
        v = v shr 7
        while (v > 0) {
            groups.add(((v and 0x7F) or 0x80).toInt())
            v = v shr 7
        }
        return groups.asReversed().map { it.toByte() }.toByteArray()
    }

    private fun u16be(value: Int): ByteArray = byteArrayOf((value shr 8).toByte(), value.toByte())
    private fun u32be(value: Int): ByteArray = byteArrayOf(
        (value shr 24).toByte(), (value shr 16).toByte(), (value shr 8).toByte(), value.toByte()
    )
}

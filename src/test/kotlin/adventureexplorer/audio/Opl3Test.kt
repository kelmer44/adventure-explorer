package adventureexplorer.audio

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.zip.CRC32

class Opl3Test {
    /**
     * `opl3/script.txt` drives every register group: OPL2 melody voices with
     * random instruments, a same-frame key-off/key-on retrigger, rhythm mode,
     * then OPL3 mode with 4-operator pairs, waveforms 4-7 and both banks.
     * The CRC is of the 16-bit stereo output of the original C emulator
     * (Nuked OPL3 1.8, OPL3_WriteRegBuffered + OPL3_GenerateResampled at 44.1 kHz).
     */
    @Test fun `output matches the C reference sample for sample`() {
        val script = javaClass.getResource("/opl3/script.txt")!!.readText().lines().filter { it.isNotBlank() }.map { line ->
            val (at, reg, value) = line.split(" ")
            Triple(at.toLong(), reg.toInt(16), value.toInt(16))
        }
        val chip = Opl3(44_100)
        val crc = CRC32()
        val frame = IntArray(2)
        val bytes = ByteArray(4)
        var next = 0
        for (i in 0 until 210_000L) {
            while (next < script.size && script[next].first <= i) {
                chip.writeReg(script[next].second, script[next].third)
                next++
            }
            chip.generate(frame)
            for (c in 0..1) {
                bytes[c * 2] = frame[c].toByte()
                bytes[c * 2 + 1] = (frame[c] shr 8).toByte()
            }
            crc.update(bytes)
        }
        assertEquals(0x85dbc509L, crc.value)
    }
}

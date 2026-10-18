package adventureexplorer.app

import adventureexplorer.model.ResourceNode
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.file.Files

class Lgop2PaletteTest {
    // 547 valid FLEX resources: the shared palette must be found beyond slot 300.
    private fun archive(): ByteArray {
        fun word(n: Int) = byteArrayOf(n.toByte(), (n ushr 8).toByte())
        fun dword(n: Int) = word(n) + word(n ushr 16)
        val entries = ByteArrayOutputStream()
        val body = ByteArrayOutputStream()
        var offset = 50 + 22 + 547 * 8
        repeat(547) { i ->
            val palette = if (i == 546) ByteArray(768).apply {
                this[3] = 200.toByte(); this[4] = 10; this[5] = 20
            } else byteArrayOf()
            val cmd = 18 + palette.size
            val raw = byteArrayOf(if (palette.isNotEmpty()) 1 else 0, 0, 0, 0) +
                word(cmd) + word(cmd + 2) + word(cmd + 3) + word(2) + word(0) +
                word(4) + word(4) + palette + byteArrayOf(0, 0, 1)
            entries.write(dword(offset) + dword(62 + raw.size))
            body.write(ByteArray(62) + raw)
            offset += 62 + raw.size
        }
        return ByteArray(24) + word(1) + "FLEX".toByteArray() + dword(50) + ByteArray(16) +
            ByteArray(16) + word(547) + word(547) + word(0) + entries.toByteArray() + body.toByteArray()
    }

    @Test fun `LGOP2 automatic and selected palettes agree in the preview`() = runBlocking {
        val folder = Files.createTempDirectory("lgop2-preview").toFile()
        try {
            folder.resolve("LGOP2.DAT").writeBytes(byteArrayOf())
            folder.resolve("LGOP2.PRJ").writeBytes(archive())
            val state = AppState()
            suspend fun idle() = withTimeout(15000) {
                while (withContext(Dispatchers.Main) { state.isLoading }) delay(10)
            }
            withContext(Dispatchers.Main) { state.openGameFolder(folder.absolutePath) }
            idle()
            assertEquals("Leather Goddesses of Phobos 2", state.engineName)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
                if (it.isCategory) leaves(it.children) else listOf(it)
            }
            val pic = leaves(state.resourceTree).single { it.id.startsWith("res_464C4558_1_") }
            withContext(Dispatchers.Main) { state.selectResource(pic) }
            idle()
            fun checkColors() {
                assertEquals(0xC80A14, state.previewImage!!.getRGB(0, 0) and 0xFFFFFF)
                assertEquals(0xC80A14, state.previewPaletteImage!!.getRGB(1, 0) and 0xFFFFFF)
                assertEquals(256, state.previewPaletteColors)
            }
            checkColors()
            assertEquals(0, state.selectedPaletteIndex)
            assertEquals(1, state.previewPaletteOptions.size)
            withContext(Dispatchers.Main) { state.applyPalette(0) }
            idle()
            checkColors()
            withContext(Dispatchers.Main) { state.applyPalette(-1) }
            idle()
            checkColors()
        } finally { folder.deleteRecursively() }
    }
}

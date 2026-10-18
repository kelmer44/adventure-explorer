package adventureexplorer.app

import adventureexplorer.model.ExportCategory
import adventureexplorer.model.ResourceNode
import adventureexplorer.scripting.writeToonstruckPaletteGame
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import javax.imageio.ImageIO

class PalettePreviewTest {
    @Test fun `automatic preview keeps stored colors and swatches and export does not pick unrelated palette`() = runBlocking {
        val folder = Files.createTempDirectory("toon-palette-preview").toFile()
        val output = Files.createTempDirectory("toon-palette-export").toFile()
        try {
            writeToonstruckPaletteGame(folder)
            val state = AppState()
            suspend fun idle() = withTimeout(15000) {
                while (withContext(Dispatchers.Main) { state.isLoading || state.isExporting }) delay(10)
            }
            withContext(Dispatchers.Main) { state.openGameFolder(folder.absolutePath) }
            idle()
            assertEquals("Toonstruck",state.engineName)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap {
                if (it.isCategory) leaves(it.children) else listOf(it)
            }
            val nodes = leaves(state.resourceTree)
            suspend fun preview(id: String) {
                withContext(Dispatchers.Main) { state.selectResource(nodes.single { it.id == id }) }
                idle()
            }
            preview("pak:LOCAL.PAK:TEST.CPS")
            assertEquals(-1,state.selectedPaletteIndex)
            assertEquals(0xFC0000,state.previewImage!!.getRGB(0,0) and 0xFFFFFF)
            assertEquals(0x00FC00,state.previewImage!!.getRGB(640,0) and 0xFFFFFF)
            assertNull("A double room uses two palettes",state.previewPaletteImage)
            preview("view:LOCAL.PAK:TEST.CPS:closeup")
            assertEquals(-1,state.selectedPaletteIndex)
            assertEquals(0x00FC00,state.previewImage!!.getRGB(0,0) and 0xFFFFFF)
            assertEquals(0x00FC00,state.previewPaletteImage!!.getRGB(16,0) and 0xFFFFFF)
            val normal = state.previewPaletteOptions.indexOfFirst { it.id == "palette:LOCAL.PAK:TEST.CPS" }
            withContext(Dispatchers.Main) { state.applyPalette(normal) }
            idle()
            assertEquals(normal,state.selectedPaletteIndex)
            assertEquals(0xFC0000,state.previewImage!!.getRGB(0,0) and 0xFFFFFF)
            assertEquals(0xFC0000,state.previewPaletteImage!!.getRGB(16,0) and 0xFFFFFF)
            withContext(Dispatchers.Main) { state.applyPalette(-1) }
            idle()
            assertEquals(-1,state.selectedPaletteIndex)
            assertEquals(0x00FC00,state.previewImage!!.getRGB(0,0) and 0xFFFFFF)
            withContext(Dispatchers.Main) { state.exportCategory(output.absolutePath,ExportCategory.IMAGES) }
            idle()
            val images = output.walkTopDown().filter { it.extension == "png" }.map { ImageIO.read(it) }.toList()
            val combined = images.single { it.width == 1280 }
            assertEquals(0xFC0000,combined.getRGB(0,0) and 0xFFFFFF)
            assertEquals(0x00FC00,combined.getRGB(640,0) and 0xFFFFFF)
        } finally { folder.deleteRecursively(); output.deleteRecursively() }
    }
}

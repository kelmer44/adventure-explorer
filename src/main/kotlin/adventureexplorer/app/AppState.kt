package adventureexplorer.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import adventureexplorer.model.DetectionResult
import adventureexplorer.model.ResourceData
import adventureexplorer.model.ResourceNode
import adventureexplorer.scripting.ScriptManager
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO

/**
 * Central application state, observable by Compose.
 */
class AppState {

    var gamePath         by mutableStateOf<String?>(null)
    var engineName       by mutableStateOf<String?>(null)
    var engineDesc       by mutableStateOf<String?>(null)
    var resourceTree     by mutableStateOf<List<ResourceNode>>(emptyList())
    var selectedNode     by mutableStateOf<ResourceNode?>(null)
    var previewImage     by mutableStateOf<BufferedImage?>(null)
    var previewPaletteImage by mutableStateOf<BufferedImage?>(null)
    var previewPaletteColors by mutableStateOf(256)
    var previewDesc      by mutableStateOf<String?>(null)
    var previewText      by mutableStateOf<String?>(null)
    var statusMessage    by mutableStateOf("Ready \u2014 Open a game folder to begin")
    var isLoading        by mutableStateOf(false)

    /** When non-null, the detection dialog should be shown with this game name. */
    var detectedGameName by mutableStateOf<String?>(null)

    private val scriptManager = ScriptManager()

    /** Flat map of all nodes (id → node) for fast companion lookup. */
    private val nodeById = mutableMapOf<String, ResourceNode>()
    /** Maps bg node id → companion pal node id within the same category. */
    private val paletteCompanionOf = mutableMapOf<String, String>()

    // ── Actions ─────────────────────────────────────────────────────

    fun openGameFolder(path: String) {
        gamePath = path
        statusMessage = "Detecting game\u2026"
        isLoading = true
        previewImage = null
        previewPaletteImage = null
        previewDesc = null
        previewText = null
        selectedNode = null
        nodeById.clear()
        paletteCompanionOf.clear()

        try {
            val result: DetectionResult? = scriptManager.detectGame(path)
            if (result != null) {
                engineName = result.engineName
                engineDesc = result.engineDescription
                resourceTree = result.resources
                // Build companion maps
                indexNodes(result.resources)
                val count = result.resources.sumOf { it.countAll() }
                statusMessage = "${result.engineName} \u2014 $count resources found"
                detectedGameName = result.engineName
            } else {
                engineName = null
                engineDesc = null
                resourceTree = emptyList()
                statusMessage = "No supported game detected in ${File(path).name}"
            }
        } catch (e: Exception) {
            statusMessage = "Error: ${e.message}"
            e.printStackTrace()
        } finally {
            isLoading = false
        }
    }

    fun selectResource(node: ResourceNode) {
        selectedNode = node
        if (node.isCategory) return

        val path = gamePath ?: return
        statusMessage = "Loading ${node.name}\u2026"
        isLoading = true

        try {
            val data: ResourceData? = scriptManager.loadResource(path, node.id)
            if (data != null) {
                previewImage = data.image
                previewDesc = data.description
                previewText = data.textContent

                // Try to load a companion palette
                val palId = paletteCompanionOf[node.id]
                    ?: derivePaletteId(node.id)
                val palData = if (palId != null) {
                    runCatching { scriptManager.loadResource(path, palId) }.getOrNull()
                } else null

                previewPaletteImage = palData?.image ?: data.paletteImage
                previewPaletteColors = palData?.paletteColors ?: data.paletteColors

                statusMessage = "Loaded: ${node.name}"
            } else {
                previewImage = null
                previewPaletteImage = null
                previewDesc = null
                previewText = null
                statusMessage = "Failed to load ${node.name}"
            }
        } catch (e: Exception) {
            statusMessage = "Error loading ${node.name}: ${e.message}"
            e.printStackTrace()
        } finally {
            isLoading = false
        }
    }

    fun exportCurrentAsPng(outputPath: String) {
        val image = previewImage ?: return
        try {
            val file = File(outputPath)
            file.parentFile?.mkdirs()
            ImageIO.write(image, "PNG", file)
            statusMessage = "Exported to ${file.name}"
        } catch (e: Exception) {
            statusMessage = "Export failed: ${e.message}"
        }
    }

    fun exportPaletteBin(outputPath: String) {
        val pal = previewPaletteImage ?: return
        try {
            val file = File(outputPath)
            file.parentFile?.mkdirs()
            val numColors = previewPaletteColors.coerceIn(1, 256)
            val cellSize = 256 / 16  // 16 cells per row — should be 16
            val bytes = ByteArray(numColors * 3)
            var i = 0
            outer@ for (row in 0 until 16) {
                for (col in 0 until 16) {
                    val colorIdx = row * 16 + col
                    if (colorIdx >= numColors) break@outer
                    val rgb = pal.getRGB(col * cellSize, row * cellSize)
                    bytes[i++] = ((rgb shr 16) and 0xFF).toByte()
                    bytes[i++] = ((rgb shr 8)  and 0xFF).toByte()
                    bytes[i++] = (rgb           and 0xFF).toByte()
                }
            }
            file.writeBytes(bytes)
            statusMessage = "Exported palette to ${file.name} (${numColors} colors, ${bytes.size} bytes)"
        } catch (e: Exception) {
            statusMessage = "Palette export failed: ${e.message}"
        }
    }

    val canExport: Boolean
        get() = previewImage != null

    val canExportPalette: Boolean
        get() = previewPaletteImage != null

    // ── Internal helpers ────────────────────────────────────────────

    private fun indexNodes(nodes: List<ResourceNode>) {
        nodes.forEach { node ->
            nodeById[node.id] = node
            if (node.isCategory) {
                // Find bg/pal sibling pairs within this category
                val images   = node.children.filter { it.type == "image" }
                val palettes = node.children.filter { it.type == "palette" }
                if (palettes.isNotEmpty()) {
                    // Match by common suffix after the first underscore
                    for (img in images) {
                        val suffix = img.id.substringAfter('_')
                        val companion = palettes.find { it.id.substringAfter('_') == suffix }
                        if (companion != null) paletteCompanionOf[img.id] = companion.id
                    }
                }
                indexNodes(node.children)
            }
        }
    }

    /** Derive a companion palette ID from a background resource ID by convention. */
    private fun derivePaletteId(bgId: String): String? {
        return when {
            bgId.startsWith("bg_") -> "pal_" + bgId.removePrefix("bg_")
            else -> null
        }
    }
}

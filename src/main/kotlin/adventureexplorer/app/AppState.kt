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

    var gamePath      by mutableStateOf<String?>(null)
    var engineName    by mutableStateOf<String?>(null)
    var engineDesc    by mutableStateOf<String?>(null)
    var resourceTree  by mutableStateOf<List<ResourceNode>>(emptyList())
    var selectedNode  by mutableStateOf<ResourceNode?>(null)
    var previewImage  by mutableStateOf<BufferedImage?>(null)
    var previewDesc   by mutableStateOf<String?>(null)
    var previewText   by mutableStateOf<String?>(null)
    var statusMessage by mutableStateOf("Ready \u2014 Open a game folder to begin")
    var isLoading     by mutableStateOf(false)

    /** When non-null, the detection dialog should be shown with this game name. */
    var detectedGameName by mutableStateOf<String?>(null)

    private val scriptManager = ScriptManager()

    // ── Actions ─────────────────────────────────────────────────────

    fun openGameFolder(path: String) {
        gamePath = path
        statusMessage = "Detecting game\u2026"
        isLoading = true
        previewImage = null
        previewDesc = null
        previewText = null
        selectedNode = null

        try {
            val result: DetectionResult? = scriptManager.detectGame(path)
            if (result != null) {
                engineName = result.engineName
                engineDesc = result.engineDescription
                resourceTree = result.resources
                val count = result.resources.sumOf { it.countAll() }
                statusMessage = "${result.engineName} \u2014 $count resources found"
                // Trigger detection dialog
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
                statusMessage = "Loaded: ${node.name}"
            } else {
                previewImage = null
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

    val canExport: Boolean
        get() = previewImage != null
}

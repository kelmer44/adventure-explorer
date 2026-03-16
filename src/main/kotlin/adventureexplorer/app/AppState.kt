package adventureexplorer.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import adventureexplorer.model.DetectionResult
import adventureexplorer.model.ResourceData
import adventureexplorer.model.ResourceNode
import adventureexplorer.scripting.ScriptManager
import kotlinx.coroutines.*
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

    // ── Palette dropdown state ────────────────────────────────────
    /** All palette options for the currently selected background (same category). */
    var previewPaletteOptions  by mutableStateOf<List<ResourceNode>>(emptyList())
    /** Index into previewPaletteOptions of the currently applied palette, or -1. */
    var selectedPaletteIndex   by mutableStateOf(-1)
    /** ID of the last loaded background node (for palette re-renders). */
    private var currentBgNodeId: String? = null

    /** When non-null, the detection dialog should be shown with this game name. */
    var detectedGameName by mutableStateOf<String?>(null)

    private val scriptManager = ScriptManager()

    /** Coroutine scope for background I/O work, with Main dispatcher for state updates. */
    private val ioScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    /** Guard against concurrent loads: cancel previous before starting next. */
    private var loadJob: Job? = null

    /** id → node */
    private val nodeById = mutableMapOf<String, ResourceNode>()
    /** bg node id → companion pal node id (same category, same suffix) */
    private val paletteCompanionOf = mutableMapOf<String, String>()
    /** categoryId → palette nodes inside that category */
    private val categoryPaletteMap = mutableMapOf<String, List<ResourceNode>>()
    /** nodeId → parent category id */
    private val nodeCategoryId = mutableMapOf<String, String>()
    /** ALL palette nodes across the entire game */
    private val allPalettes = mutableListOf<ResourceNode>()

    // ── Actions ─────────────────────────────────────────────────────

    fun openGameFolder(path: String) {
        loadJob?.cancel()
        gamePath = path
        statusMessage = "Detecting game\u2026"
        isLoading = true
        previewImage = null
        previewPaletteImage = null
        previewPaletteOptions = emptyList()
        selectedPaletteIndex = -1
        currentBgNodeId = null
        previewDesc = null
        previewText = null
        selectedNode = null
        nodeById.clear()
        paletteCompanionOf.clear()
        categoryPaletteMap.clear()
        nodeCategoryId.clear()
        allPalettes.clear()

        loadJob = ioScope.launch {
            try {
                val result: DetectionResult? = scriptManager.detectGame(path)
                withContext(Dispatchers.Main) {
                    if (result != null) {
                        engineName = result.engineName
                        engineDesc = result.engineDescription
                        resourceTree = result.resources
                        indexNodes(result.resources, parentCategoryId = null)
                        val count = result.resources.sumOf { it.countAll() }
                        statusMessage = "${result.engineName} \u2014 $count resources found"
                        detectedGameName = result.engineName
                    } else {
                        engineName = null
                        engineDesc = null
                        resourceTree = emptyList()
                        statusMessage = "No supported game detected in ${File(path).name}"
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    statusMessage = "Error: ${e.message}"
                }
                e.printStackTrace()
            } finally {
                withContext(Dispatchers.Main) { isLoading = false }
            }
        }
    }

    fun selectResource(node: ResourceNode) {
        selectedNode = node

        // If a category is selected, auto-load the first leaf (non-palette) child
        if (node.isCategory) {
            val firstLeaf = findFirstLeaf(node)
            if (firstLeaf != null) {
                selectResource(firstLeaf)
            }
            return
        }

        // Only load non-palette resources as primary view
        if (node.type == "palette") return

        val path = gamePath ?: return
        currentBgNodeId = node.id
        statusMessage = "Loading ${node.name}\u2026"
        isLoading = true

        // Cancel any previous ongoing load
        loadJob?.cancel()
        loadJob = ioScope.launch {
            try {
                val data: ResourceData? = scriptManager.loadResource(path, node.id)

                // Determine default palette companion on IO thread
                val allPalsCopy = withContext(Dispatchers.Main) { allPalettes.toList() }
                val companionId = paletteCompanionOf[node.id] ?: derivePaletteId(node.id)
                val defaultIdx = if (companionId != null)
                    allPalsCopy.indexOfFirst { it.id == companionId } else -1
                val useIdx = if (defaultIdx >= 0) defaultIdx else if (allPalsCopy.isNotEmpty()) 0 else -1

                // Optionally load palette and re-render BG on IO thread
                val palData: ResourceData? = if (useIdx >= 0)
                    runCatching { scriptManager.loadResource(path, allPalsCopy[useIdx].id) }.getOrNull()
                else null

                val bgWithPal: ResourceData? = if (useIdx >= 0 && data?.image != null) {
                    val palNode = allPalsCopy[useIdx]
                    runCatching { scriptManager.loadResource(path, node.id, palNode.id) }.getOrNull()
                        ?.takeIf { it.image != null }
                } else null

                withContext(Dispatchers.Main) {
                    if (data != null) {
                        previewImage = bgWithPal?.image ?: data.image
                        previewDesc = bgWithPal?.description ?: data.description
                        previewText = data.textContent
                        previewPaletteOptions = allPalsCopy
                        if (useIdx >= 0) {
                            selectedPaletteIndex = useIdx
                            previewPaletteImage = palData?.image
                            previewPaletteColors = palData?.paletteColors ?: 256
                        } else {
                            previewPaletteImage = data.paletteImage
                            previewPaletteColors = data.paletteColors
                            selectedPaletteIndex = -1
                        }
                        statusMessage = "Loaded: ${node.name}"
                    } else {
                        previewImage = null
                        previewPaletteImage = null
                        previewPaletteOptions = emptyList()
                        selectedPaletteIndex = -1
                        previewDesc = null
                        previewText = null
                        statusMessage = "Failed to load ${node.name}"
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    statusMessage = "Error loading ${node.name}: ${e.message}"
                }
                e.printStackTrace()
            } finally {
                withContext(Dispatchers.Main) { isLoading = false }
            }
        }
    }

    /**
     * Apply the palette at [index] in [previewPaletteOptions] to the current background.
     * Re-renders the background image with the new palette when the Lua script supports it.
     */
    fun applyPalette(index: Int) {
        if (index < 0 || index >= previewPaletteOptions.size) return
        val path = gamePath ?: return
        val bgId = currentBgNodeId ?: return
        isLoading = true
        statusMessage = "Applying palette\u2026"
        val palNode = previewPaletteOptions.getOrNull(index) ?: return
        loadJob?.cancel()
        loadJob = ioScope.launch {
            try {
                // Load palette swatch and re-render background on IO thread
                val palData = runCatching { scriptManager.loadResource(path, palNode.id) }.getOrNull()
                val bgData  = runCatching { scriptManager.loadResource(path, bgId, palNode.id) }.getOrNull()
                withContext(Dispatchers.Main) {
                    selectedPaletteIndex = index
                    previewPaletteImage = palData?.image
                    previewPaletteColors = palData?.paletteColors ?: 256
                    if (bgData?.image != null) {
                        previewImage = bgData.image
                        previewDesc = bgData.description ?: previewDesc
                    }
                    statusMessage = "Palette: ${palNode.name}"
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                withContext(Dispatchers.Main) { statusMessage = "Palette error: ${e.message}" }
            } finally {
                withContext(Dispatchers.Main) { isLoading = false }
            }
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
            val cellSize = 256 / 16
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
            statusMessage = "Exported palette to ${file.name} ($numColors colors, ${bytes.size} bytes)"
        } catch (e: Exception) {
            statusMessage = "Palette export failed: ${e.message}"
        }
    }

    val canExport: Boolean
        get() = previewImage != null

    val canExportPalette: Boolean
        get() = previewPaletteImage != null

    // ── Internal helpers ────────────────────────────────────────────

    private fun indexNodes(nodes: List<ResourceNode>, parentCategoryId: String?) {
        nodes.forEach { node ->
            nodeById[node.id] = node
            if (parentCategoryId != null) nodeCategoryId[node.id] = parentCategoryId

            // Collect palette-type nodes into the global list
            if (node.type == "palette") {
                allPalettes.add(node)
            }

            if (node.isCategory) {
                val images   = node.children.filter { it.type == "image" }
                val palettes = node.children.filter { it.type == "palette" }

                // Build companion map: match by suffix after first underscore
                if (palettes.isNotEmpty()) {
                    for (img in images) {
                        val suffix = img.id.substringAfter('_', img.id)
                        val companion = palettes.find { it.id.substringAfter('_', it.id) == suffix }
                        if (companion != null) paletteCompanionOf[img.id] = companion.id
                    }
                    categoryPaletteMap[node.id] = palettes
                }

                indexNodes(node.children, parentCategoryId = node.id)
            }
        }
    }

    /** Find the first non-palette, non-category leaf in a category's subtree. */
    private fun findFirstLeaf(node: ResourceNode): ResourceNode? {
        for (child in node.children) {
            if (child.type == "palette") continue
            if (child.isLeaf) return child
            if (child.isCategory) {
                val found = findFirstLeaf(child)
                if (found != null) return found
            }
        }
        return null
    }

    private fun derivePaletteId(bgId: String): String? {
        return when {
            bgId.startsWith("bg_")  -> "pal_" + bgId.removePrefix("bg_")
            bgId.startsWith("cd_")  -> "pal_" + bgId.removePrefix("cd_")
                                            .substringBeforeLast('.')
            else -> null
        }
    }
}

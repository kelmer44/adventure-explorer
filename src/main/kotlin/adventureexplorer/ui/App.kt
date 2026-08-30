package adventureexplorer.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import adventureexplorer.app.AppState
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.awt.FileDialog
import java.awt.Frame
import java.util.prefs.Preferences
import javax.swing.JFileChooser
import javax.swing.SwingUtilities

// Dark color scheme
private val DarkColors = darkColors(
    primary = Color(0xFF90CAF9),
    primaryVariant = Color(0xFF42A5F5),
    secondary = Color(0xFFCE93D8),
    background = Color(0xFF1E1E1E),
    surface = Color(0xFF2D2D2D),
    onPrimary = Color(0xFF000000),
    onSecondary = Color(0xFF000000),
    onBackground = Color(0xFFE0E0E0),
    onSurface = Color(0xFFE0E0E0),
)

@Composable
fun App() {
    val appState = remember { AppState() }
    val scope = rememberCoroutineScope()

    MaterialTheme(colors = DarkColors) {
        Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colors.background) {
            Column(modifier = Modifier.fillMaxSize()) {

                // ── Toolbar ─────────────────────────────────────
                TopAppBar(
                    backgroundColor = MaterialTheme.colors.surface,
                    elevation = 4.dp
                ) {
                    Spacer(Modifier.width(16.dp))

                    // Title
                    Text(
                        text = buildString {
                            append("Adventure Explorer")
                            appState.engineName?.let { append("  \u2014  $it") }
                        },
                        style = MaterialTheme.typography.h6,
                        color = MaterialTheme.colors.onSurface
                    )

                    Spacer(Modifier.weight(1f))

                    // Open Folder button — launched on IO to avoid blocking the
                    // Compose main thread while the file dialog is open.
                    Button(
                        onClick = {
                            scope.launch(Dispatchers.IO) {
                                showOpenFolderDialog(appState)
                            }
                        },
                        colors = ButtonDefaults.buttonColors(
                            backgroundColor = MaterialTheme.colors.primary
                        )
                    ) {
                        Text("\uD83D\uDCC2  Open Folder")
                    }

                    Spacer(Modifier.width(8.dp))

                    // Export PNG button
                    Button(
                        onClick = { scope.launch(Dispatchers.IO) { showExportDialog(appState) } },
                        enabled = appState.canExport,
                        colors = ButtonDefaults.buttonColors(
                            backgroundColor = MaterialTheme.colors.primary
                        )
                    ) {
                        Text("💾  Export PNG")
                    }

                    Spacer(Modifier.width(8.dp))

                    Spacer(Modifier.width(16.dp))
                }

                // ── Main content ────────────────────────────────
                Row(modifier = Modifier.weight(1f).fillMaxWidth()) {

                    // Left panel: resource tree
                    Surface(
                        modifier = Modifier.width(300.dp).fillMaxHeight(),
                        color = MaterialTheme.colors.surface,
                        elevation = 2.dp
                    ) {
                        ResourceTreeView(
                            resources = appState.resourceTree,
                            selectedNode = appState.selectedNode,
                            onNodeSelected = { appState.selectResource(it) }
                        )
                    }

                    // Divider
                    Divider(
                        modifier = Modifier.fillMaxHeight().width(1.dp),
                        color = Color(0xFF444444)
                    )

                    // Right panel: preview
                    PreviewPane(
                        image = appState.previewImage,
                        paletteImage = appState.previewPaletteImage,
                        paletteOptions = appState.previewPaletteOptions,
                        selectedPaletteIndex = appState.selectedPaletteIndex,
                        onPaletteSelected = { appState.applyPalette(it) },
                        description = appState.previewDesc,
                        textContent = appState.previewText,
                        canExportPalette = appState.canExportPalette,
                        onExportPaletteBin = { scope.launch(Dispatchers.IO) { showExportPaletteBinDialog(appState) } },
                        frames = appState.previewFrames,
                        frameDelayMs = appState.previewFrameDelayMs,
                        onExportFrame = { frame ->
                            scope.launch(Dispatchers.IO) { showExportFrameDialog(appState, frame) }
                        },
                        onExportAllFrames = {
                            scope.launch(Dispatchers.IO) { showExportAllFramesDialog(appState) }
                        },
                        soundData = appState.previewSoundData,
                        onExportSoundWav = {
                            scope.launch(Dispatchers.IO) { showExportSoundWavDialog(appState) }
                        },
                        midiData = appState.previewMidiData,
                        onExportMidi = {
                            scope.launch(Dispatchers.IO) { showExportMidiDialog(appState) }
                        },
                        modifier = Modifier.weight(1f).fillMaxHeight()
                    )
                }

                // ── Status bar ──────────────────────────────────
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = Color(0xFF252525),
                    elevation = 4.dp
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        if (appState.isLoading) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(14.dp),
                                strokeWidth = 2.dp,
                                color = MaterialTheme.colors.primary
                            )
                            Spacer(Modifier.width(8.dp))
                        }
                        Text(
                            text = appState.statusMessage,
                            fontSize = 12.sp,
                            color = MaterialTheme.colors.onSurface.copy(alpha = 0.7f)
                        )
                    }
                }
            }

            // ── Detection dialog ────────────────────────────────
            val detectedName = appState.detectedGameName
            if (detectedName != null) {
                AlertDialog(
                    onDismissRequest = { appState.detectedGameName = null },
                    title = {
                        Text(
                            text = "\uD83C\uDFAE  Game Detected!",
                            fontWeight = FontWeight.Bold,
                            fontSize = 18.sp,
                            color = MaterialTheme.colors.primary
                        )
                    },
                    text = {
                        Text(
                            text = "Game \"$detectedName\" has been detected!",
                            fontSize = 14.sp,
                            color = MaterialTheme.colors.onSurface
                        )
                    },
                    confirmButton = {
                        Button(
                            onClick = { appState.detectedGameName = null },
                            colors = ButtonDefaults.buttonColors(
                                backgroundColor = MaterialTheme.colors.primary
                            )
                        ) {
                            Text("OK")
                        }
                    },
                    shape = RoundedCornerShape(12.dp),
                    backgroundColor = MaterialTheme.colors.surface
                )
            }
        }
    }
}

// ── File dialogs (Swing) ──────────────────────────────────────

private val prefs: Preferences = Preferences.userRoot().node("adventureexplorer")

// Run a block on the AWT EDT and wait for it to complete.
// Must only be called from a non-EDT thread (i.e. Dispatchers.IO).
private fun <T> onEdt(block: () -> T): T {
    var result: T? = null
    SwingUtilities.invokeAndWait { result = block() }
    @Suppress("UNCHECKED_CAST")
    return result as T
}

// All dialog functions are suspend so they can switch to Main for any Compose-state
// mutations, while keeping the blocking EDT call on the IO thread.

private suspend fun showOpenFolderDialog(appState: AppState) {
    val lastPath = prefs.get("lastGamePath", null)
    val isMac = System.getProperty("os.name", "").lowercase().contains("mac")
    if (isMac) {
        val chosen = withContext(Dispatchers.IO) {
            onEdt {
                System.setProperty("apple.awt.fileDialogForDirectories", "true")
                val dialog = FileDialog(null as Frame?, "Open Game Folder", FileDialog.LOAD)
                dialog.directory = lastPath ?: "/Volumes"
                dialog.isVisible = true
                System.setProperty("apple.awt.fileDialogForDirectories", "false")
                val dir = dialog.directory ?: return@onEdt null
                val file = dialog.file ?: return@onEdt null
                "$dir$file"
            }
        } ?: return
        prefs.put("lastGamePath", chosen)
        withContext(Dispatchers.Main) { appState.openGameFolder(chosen) }
    } else {
        val chosen = withContext(Dispatchers.IO) {
            onEdt {
                val chooser = JFileChooser()
                chooser.fileSelectionMode = JFileChooser.DIRECTORIES_ONLY
                chooser.dialogTitle = "Open Game Folder"
                val startDir = lastPath?.let { java.io.File(it).parentFile }
                    ?: java.io.File("/Volumes").takeIf { it.exists() }
                if (startDir != null) chooser.currentDirectory = startDir
                if (chooser.showOpenDialog(null) == JFileChooser.APPROVE_OPTION)
                    chooser.selectedFile.absolutePath
                else null
            }
        } ?: return
        prefs.put("lastGamePath", chosen)
        withContext(Dispatchers.Main) { appState.openGameFolder(chosen) }
    }
}

private suspend fun showExportDialog(appState: AppState) {
    val chosen = withContext(Dispatchers.IO) {
        onEdt {
            val chooser = JFileChooser()
            chooser.dialogTitle = "Export as PNG"
            val defaultName = (appState.selectedNode?.name ?: "export")
                .replace(Regex("[^a-zA-Z0-9_\\- ]"), "")
                .replace(" ", "_")
            chooser.selectedFile = File("$defaultName.png")
            if (chooser.showSaveDialog(null) == JFileChooser.APPROVE_OPTION) {
                var path = chooser.selectedFile.absolutePath
                if (!path.lowercase().endsWith(".png")) path += ".png"
                path
            } else null
        }
    } ?: return
    withContext(Dispatchers.Main) { appState.exportCurrentAsPng(chosen) }
}

private suspend fun showExportPaletteBinDialog(appState: AppState) {
    val chosen = withContext(Dispatchers.IO) {
        onEdt {
            val chooser = JFileChooser()
            chooser.dialogTitle = "Export Palette as .bin"
            val defaultName = (appState.selectedNode?.name ?: "palette")
                .replace(Regex("[^a-zA-Z0-9_\\- ]"), "")
                .replace(" ", "_")
            chooser.selectedFile = File("${defaultName}_palette.bin")
            if (chooser.showSaveDialog(null) == JFileChooser.APPROVE_OPTION) {
                var path = chooser.selectedFile.absolutePath
                if (!path.lowercase().endsWith(".bin")) path += ".bin"
                path
            } else null
        }
    } ?: return
    withContext(Dispatchers.Main) { appState.exportPaletteBin(chosen) }
}

private suspend fun showExportFrameDialog(appState: AppState, frame: java.awt.image.BufferedImage) {
    val chosen = withContext(Dispatchers.IO) {
        onEdt {
            val chooser = JFileChooser()
            chooser.dialogTitle = "Export Frame as PNG"
            val defaultName = (appState.selectedNode?.name ?: "frame")
                .replace(Regex("[^a-zA-Z0-9_\\- ]"), "")
                .replace(" ", "_")
            chooser.selectedFile = File("${defaultName}_frame.png")
            if (chooser.showSaveDialog(null) == JFileChooser.APPROVE_OPTION) {
                var path = chooser.selectedFile.absolutePath
                if (!path.lowercase().endsWith(".png")) path += ".png"
                path
            } else null
        }
    } ?: return
    withContext(Dispatchers.Main) { appState.exportAnimationFrame(chosen, frame) }
}

private suspend fun showExportAllFramesDialog(appState: AppState) {
    val chosen = withContext(Dispatchers.IO) {
        onEdt {
            val chooser = JFileChooser()
            chooser.dialogTitle = "Choose folder for exported frames"
            chooser.fileSelectionMode = JFileChooser.DIRECTORIES_ONLY
            if (chooser.showSaveDialog(null) == JFileChooser.APPROVE_OPTION) {
                chooser.selectedFile.absolutePath
            } else null
        }
    } ?: return
    withContext(Dispatchers.Main) { appState.exportAllFrames(chosen) }
}

private suspend fun showExportSoundWavDialog(appState: AppState) {
    val chosen = withContext(Dispatchers.IO) {
        onEdt {
            val chooser = JFileChooser()
            chooser.dialogTitle = "Export Sound as WAV"
            chooser.selectedFile = java.io.File("sound.wav")
            chooser.fileFilter = javax.swing.filechooser.FileNameExtensionFilter("WAV files", "wav")
            if (chooser.showSaveDialog(null) == JFileChooser.APPROVE_OPTION) {
                var path = chooser.selectedFile.absolutePath
                if (!path.lowercase().endsWith(".wav")) path += ".wav"
                path
            } else null
        }
    } ?: return
    withContext(Dispatchers.Main) { appState.exportSoundWav(chosen) }
}

private suspend fun showExportMidiDialog(appState: AppState) {
    val chosen = withContext(Dispatchers.IO) {
        onEdt {
            val chooser = JFileChooser()
            chooser.dialogTitle = "Export as MIDI"
            chooser.selectedFile = java.io.File("track.mid")
            chooser.fileFilter = javax.swing.filechooser.FileNameExtensionFilter("MIDI files", "mid")
            if (chooser.showSaveDialog(null) == JFileChooser.APPROVE_OPTION) {
                var path = chooser.selectedFile.absolutePath
                if (!path.lowercase().endsWith(".mid")) path += ".mid"
                path
            } else null
        }
    } ?: return
    withContext(Dispatchers.Main) { appState.exportMidiFile(chosen) }
}

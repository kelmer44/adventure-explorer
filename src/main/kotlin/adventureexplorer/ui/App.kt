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
import java.io.File
import java.awt.FileDialog
import java.awt.Frame
import java.util.prefs.Preferences
import javax.swing.JFileChooser
import javax.swing.UIManager

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
    // Set native look and feel for file dialogs
    LaunchedEffect(Unit) {
        try { UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName()) }
        catch (_: Exception) {}
    }

    val appState = remember { AppState() }

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

                    // Open Folder button
                    Button(
                        onClick = { showOpenFolderDialog(appState) },
                        colors = ButtonDefaults.buttonColors(
                            backgroundColor = MaterialTheme.colors.primary
                        )
                    ) {
                        Text("\uD83D\uDCC2  Open Folder")
                    }

                    Spacer(Modifier.width(8.dp))

                    // Export PNG button
                    Button(
                        onClick = { showExportDialog(appState) },
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
                        description = appState.previewDesc,
                        textContent = appState.previewText,
                        canExportPalette = appState.canExportPalette,
                        onExportPaletteBin = { showExportPaletteBinDialog(appState) },
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

private fun showOpenFolderDialog(appState: AppState) {
    val lastPath = prefs.get("lastGamePath", null)
    val isMac = System.getProperty("os.name", "").lowercase().contains("mac")
    if (isMac) {
        System.setProperty("apple.awt.fileDialogForDirectories", "true")
        val dialog = FileDialog(null as Frame?, "Open Game Folder", FileDialog.LOAD)
        // Use last path if available, otherwise start at /Volumes for CD access
        dialog.directory = lastPath ?: "/Volumes"
        dialog.isVisible = true
        System.setProperty("apple.awt.fileDialogForDirectories", "false")
        val dir = dialog.directory ?: return
        val file = dialog.file ?: return
        val chosen = "$dir$file"
        prefs.put("lastGamePath", chosen)
        appState.openGameFolder(chosen)
    } else {
        val chooser = JFileChooser()
        chooser.fileSelectionMode = JFileChooser.DIRECTORIES_ONLY
        chooser.dialogTitle = "Open Game Folder"
        val startDir = lastPath?.let { java.io.File(it).parentFile }
            ?: java.io.File("/Volumes").takeIf { it.exists() }
        if (startDir != null) chooser.currentDirectory = startDir
        if (chooser.showOpenDialog(null) == JFileChooser.APPROVE_OPTION) {
            val chosen = chooser.selectedFile.absolutePath
            prefs.put("lastGamePath", chosen)
            appState.openGameFolder(chosen)
        }
    }
}

private fun showExportDialog(appState: AppState) {
    val chooser = JFileChooser()
    chooser.dialogTitle = "Export as PNG"
    val defaultName = (appState.selectedNode?.name ?: "export")
        .replace(Regex("[^a-zA-Z0-9_\\- ]"), "")
        .replace(" ", "_")
    chooser.selectedFile = File("$defaultName.png")
    if (chooser.showSaveDialog(null) == JFileChooser.APPROVE_OPTION) {
        var path = chooser.selectedFile.absolutePath
        if (!path.lowercase().endsWith(".png")) path += ".png"
        appState.exportCurrentAsPng(path)
    }
}

private fun showExportPaletteBinDialog(appState: AppState) {
    val chooser = JFileChooser()
    chooser.dialogTitle = "Export Palette as .bin"
    val defaultName = (appState.selectedNode?.name ?: "palette")
        .replace(Regex("[^a-zA-Z0-9_\\- ]"), "")
        .replace(" ", "_")
    chooser.selectedFile = File("${defaultName}_palette.bin")
    if (chooser.showSaveDialog(null) == JFileChooser.APPROVE_OPTION) {
        var path = chooser.selectedFile.absolutePath
        if (!path.lowercase().endsWith(".bin")) path += ".bin"
        appState.exportPaletteBin(path)
    }
}

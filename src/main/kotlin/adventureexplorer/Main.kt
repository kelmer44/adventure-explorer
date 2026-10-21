package adventureexplorer

import androidx.compose.runtime.remember
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.*
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import adventureexplorer.ui.App
import java.awt.Taskbar
import javax.imageio.ImageIO
import javax.swing.UIManager

fun main() {
    // Apply native L&F before any AWT component is created.
    try { UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName()) } catch (_: Exception) {}

    // A window icon does not update the macOS Dock icon during development runs.
    if (Taskbar.isTaskbarSupported()) {
        val taskbar = Taskbar.getTaskbar()
        if (taskbar.isSupported(Taskbar.Feature.ICON_IMAGE)) {
            Thread.currentThread().contextClassLoader.getResourceAsStream("icons/fedora.png")?.use {
                taskbar.iconImage = ImageIO.read(it)
            }
        }
    }

    application {
        val windowState = rememberWindowState(size = DpSize(1280.dp, 800.dp))
        val searchFocusRequester = remember { FocusRequester() }
        Window(
            onCloseRequest = ::exitApplication,
            // Cmd+F / Ctrl+F jumps to the resource search box
            onPreviewKeyEvent = { event ->
                if (event.type == KeyEventType.KeyDown && event.key == Key.F &&
                    (event.isMetaPressed || event.isCtrlPressed)) {
                    // Not attached until a game is loaded
                    runCatching { searchFocusRequester.requestFocus() }.isSuccess
                } else false
            },
            title = "Adventure Explorer",
            icon = painterResource("icons/fedora.png"),
            state = windowState
        ) {
            App(searchFocusRequester)
        }
    }
}

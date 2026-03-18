package adventureexplorer

import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import adventureexplorer.ui.App
import javax.swing.UIManager

fun main() {
    // Apply native L&F before any AWT component is created.
    try { UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName()) } catch (_: Exception) {}

    application {
        val windowState = rememberWindowState(size = DpSize(1280.dp, 800.dp))
        Window(
            onCloseRequest = ::exitApplication,
            title = "Adventure Explorer",
            state = windowState
        ) {
            App()
        }
    }
}

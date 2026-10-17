package adventureexplorer.app

import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Test

class AppStateTest {
    @Test fun `folder selection is retained when its first resource is previewed`() {
        val leaf = ResourceNode("leaf", "Leaf", "image")
        val folder = ResourceNode("folder", "Folder", "category", listOf(leaf))
        val state = AppState()
        // Without a game path preview loading is a no-op.
        state.selectResource(folder)
        assertSame(folder, state.selectedNode)
        state.gamePath = "/game"
        state.resourceTree = listOf(folder)
        assertTrue(state.canExportFolder)
        state.isLoading = true
        assertFalse(state.canExportFolder)
        state.isLoading = false
        state.isExporting = true
        assertFalse(state.canExportFolder)
        assertFalse(state.canExportAll)
        state.isExporting = false
        state.selectedNode = leaf
        assertFalse(state.canExportFolder)
        assertTrue(state.canExportAll)
    }
}

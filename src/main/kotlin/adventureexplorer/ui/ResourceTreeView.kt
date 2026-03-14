package adventureexplorer.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import adventureexplorer.model.ResourceNode

@Composable
fun ResourceTreeView(
    resources: List<ResourceNode>,
    selectedNode: ResourceNode?,
    onNodeSelected: (ResourceNode) -> Unit
) {
    val scrollState = rememberScrollState()

    if (resources.isEmpty()) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                "No game loaded\n\nClick \"Open Folder\" to load\na game directory",
                color = MaterialTheme.colors.onSurface.copy(alpha = 0.4f),
                fontSize = 13.sp,
                lineHeight = 20.sp
            )
        }
    } else {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(scrollState)
                .padding(vertical = 4.dp)
        ) {
            resources.forEach { node ->
                TreeNode(
                    node = node,
                    depth = 0,
                    selectedNode = selectedNode,
                    onNodeSelected = onNodeSelected
                )
            }
        }
    }
}

@Composable
private fun TreeNode(
    node: ResourceNode,
    depth: Int,
    selectedNode: ResourceNode?,
    onNodeSelected: (ResourceNode) -> Unit
) {
    var expanded by remember { mutableStateOf(true) }
    val isSelected = selectedNode?.id == node.id
    val bgColor = if (isSelected) MaterialTheme.colors.primary.copy(alpha = 0.15f)
                  else Color.Transparent

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(bgColor)
            .clickable {
                if (node.isCategory) {
                    expanded = !expanded
                }
                onNodeSelected(node)
            }
            .padding(
                start = (12 + depth * 20).dp,
                top = 3.dp,
                bottom = 3.dp,
                end = 8.dp
            ),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Expand/collapse indicator for categories
        if (node.isCategory) {
            Text(
                text = if (expanded) "\u25BC" else "\u25B6",
                fontSize = 10.sp,
                color = MaterialTheme.colors.onSurface.copy(alpha = 0.5f),
                modifier = Modifier.width(16.dp)
            )
        } else {
            Spacer(Modifier.width(16.dp))
        }

        // Icon
        Text(
            text = when (node.type) {
                "category" -> "\uD83D\uDCC1"
                "image"    -> "\uD83D\uDDBC"
                "sound"    -> "\uD83D\uDD0A"
                "text"     -> "\uD83D\uDCDD"
                "palette"  -> "\uD83C\uDFA8"
                else       -> "\uD83D\uDCC4"
            },
            fontSize = 14.sp,
            modifier = Modifier.padding(end = 6.dp)
        )

        // Name
        Text(
            text = node.name,
            fontSize = 13.sp,
            fontWeight = if (node.isCategory) FontWeight.SemiBold else FontWeight.Normal,
            color = if (isSelected) MaterialTheme.colors.primary
                    else MaterialTheme.colors.onSurface,
            modifier = Modifier.weight(1f)
        )

        // Child count badge for categories
        if (node.isCategory && node.children.isNotEmpty()) {
            Text(
                text = "${node.children.size}",
                fontSize = 11.sp,
                color = MaterialTheme.colors.onSurface.copy(alpha = 0.4f)
            )
        }
    }

    // Render children if expanded
    if (expanded && node.children.isNotEmpty()) {
        node.children.forEach { child ->
            TreeNode(
                node = child,
                depth = depth + 1,
                selectedNode = selectedNode,
                onNodeSelected = onNodeSelected
            )
        }
    }
}

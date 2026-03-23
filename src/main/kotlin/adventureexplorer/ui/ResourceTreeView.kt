package adventureexplorer.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusTarget
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.*
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
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
    if (resources.isEmpty()) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                "No game loaded\n\nClick \"Open Folder\" to load\na game directory",
                color = MaterialTheme.colors.onSurface.copy(alpha = 0.4f),
                fontSize = 13.sp,
                lineHeight = 20.sp
            )
        }
        return
    }

    // ── Build a flat, navigable list of visible rows ──────────────

    // Track which categories are expanded
    val expandedIds = remember { mutableStateMapOf<String, Boolean>() }

    // Build the flat visible rows (excluding palette-type nodes)
    val rows = remember(resources, expandedIds.toMap()) {
        buildFlatRows(resources, expandedIds)
    }

    // Track selection index within visible rows
    val selectedIdx = rows.indexOfFirst { it.node.id == selectedNode?.id }

    val listState = rememberLazyListState()
    val hScrollState = rememberScrollState()
    val focusRequester = remember { FocusRequester() }

    // Scroll to keep selected item visible when navigating
    LaunchedEffect(selectedIdx) {
        if (selectedIdx >= 0) listState.animateScrollToItem(selectedIdx)
    }

    Box(modifier = Modifier.fillMaxSize()) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(bottom = 10.dp)
            .pointerInput(hScrollState) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        if (event.type == PointerEventType.Scroll) {
                            val delta = event.changes.firstOrNull()?.scrollDelta ?: continue
                            if (delta.x != 0f) {
                                hScrollState.dispatchRawDelta(delta.x * 30f)
                            }
                        }
                    }
                }
            }
    ) {
    LazyColumn(
        state = listState,
        modifier = Modifier
            .fillMaxHeight()
            .focusRequester(focusRequester)
            .focusTarget()
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                when (event.key) {
                    Key.DirectionDown -> {
                        val next = rows.getOrNull(selectedIdx + 1)
                        if (next != null) onNodeSelected(next.node)
                        true
                    }
                    Key.DirectionUp -> {
                        val prev = rows.getOrNull((selectedIdx - 1).coerceAtLeast(0))
                        if (prev != null) onNodeSelected(prev.node)
                        true
                    }
                    Key.DirectionRight -> {
                        val cur = rows.getOrNull(selectedIdx)
                        if (cur != null && cur.node.isCategory && expandedIds[cur.node.id] != true) {
                            expandedIds[cur.node.id] = true
                        } else {
                            // Move to first child
                            val firstChild = rows.getOrNull(selectedIdx + 1)
                            if (firstChild != null && firstChild.depth > (cur?.depth ?: 0))
                                onNodeSelected(firstChild.node)
                        }
                        true
                    }
                    Key.DirectionLeft -> {
                        val cur = rows.getOrNull(selectedIdx)
                        if (cur != null && cur.node.isCategory && expandedIds[cur.node.id] == true) {
                            expandedIds[cur.node.id] = false
                        } else {
                            // Move to parent
                            val parentRow = rows.take(selectedIdx).lastOrNull { it.depth < (cur?.depth ?: 0) }
                            if (parentRow != null) onNodeSelected(parentRow.node)
                        }
                        true
                    }
                    Key.Enter, Key.Spacebar -> {
                        val cur = rows.getOrNull(selectedIdx)
                        if (cur != null && cur.node.isCategory) {
                            expandedIds[cur.node.id] = !(expandedIds[cur.node.id] ?: false)
                        }
                        true
                    }
                    else -> false
                }
            }
            .clickable(
                interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                indication = null
            ) { focusRequester.requestFocus() }
            .padding(vertical = 4.dp)
    ) {
        itemsIndexed(rows) { _, row ->
            TreeRowItem(
                row = row,
                isSelected = selectedNode?.id == row.node.id,
                isExpanded = expandedIds[row.node.id] ?: false,
                onClick = {
                    focusRequester.requestFocus()
                    if (row.node.isCategory) {
                        expandedIds[row.node.id] = !(expandedIds[row.node.id] ?: false)
                    }
                    onNodeSelected(row.node)
                }
            )
        }
    }
    } // close horizontalScroll Box
    HorizontalScrollbar(
        adapter = rememberScrollbarAdapter(hScrollState),
        modifier = Modifier
            .align(Alignment.BottomStart)
            .fillMaxWidth()
    )
    } // close outer Box
}

// ── Row model ────────────────────────────────────────────────────

private data class TreeRow(val node: ResourceNode, val depth: Int)

/** Recursively build the list of visible rows, skipping palette-type nodes. */
private fun buildFlatRows(
    nodes: List<ResourceNode>,
    expandedIds: Map<String, Boolean>,
    depth: Int = 0,
    into: MutableList<TreeRow> = mutableListOf()
): List<TreeRow> {
    for (node in nodes) {
        // Skip palette companion nodes — displayed in the preview pane instead
        if (node.type == "palette") continue

        into.add(TreeRow(node, depth))

        if (node.isCategory && expandedIds[node.id] == true) {
            buildFlatRows(node.children, expandedIds, depth + 1, into)
        }
    }
    return into
}

// ── Row item ─────────────────────────────────────────────────────

@Composable
private fun TreeRowItem(
    row: TreeRow,
    isSelected: Boolean,
    isExpanded: Boolean,
    onClick: () -> Unit
) {
    val node = row.node
    val bgColor = if (isSelected) MaterialTheme.colors.primary.copy(alpha = 0.15f)
                  else Color.Transparent

    Row(
        modifier = Modifier
            .background(bgColor)
            .clickable(onClick = onClick)
            .padding(
                start = (12 + row.depth * 20).dp,
                top = 3.dp, bottom = 3.dp, end = 8.dp
            ),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Expand / collapse indicator for categories
        if (node.isCategory) {
            Text(
                text = if (isExpanded) "\u25BC" else "\u25B6",
                fontSize = 8.sp,
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
                "animation" -> "\uD83C\uDFAC"
                "sound"    -> "\uD83D\uDD0A"
                "text"     -> "\uD83D\uDCDD"
                "palette"  -> "\uD83C\uDFA8"
                else       -> "\uD83D\uDCC4"
            },
            fontSize = 12.sp,
            modifier = Modifier.padding(end = 6.dp)
        )

        // Label
        Text(
            text = node.name,
            fontSize = 11.sp,
            fontWeight = if (node.isCategory) FontWeight.SemiBold else FontWeight.Normal,
            color = if (isSelected) MaterialTheme.colors.primary
                    else MaterialTheme.colors.onSurface,
            softWrap = false,
            modifier = Modifier.padding(end = 8.dp)
        )

        // Child count badge for categories
        if (node.isCategory && node.children.isNotEmpty()) {
            // Count only non-palette children for the badge
            val displayCount = node.children.count { it.type != "palette" }
            Text(
                text = "$displayCount",
                fontSize = 9.sp,
                color = MaterialTheme.colors.onSurface.copy(alpha = 0.4f)
            )
        }
    }
}


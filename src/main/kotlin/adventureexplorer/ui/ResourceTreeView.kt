package adventureexplorer.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.DropdownMenu
import androidx.compose.material.DropdownMenuItem
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusTarget
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.input.key.*
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import adventureexplorer.model.ExportCategory
import adventureexplorer.model.ResourceCategories
import adventureexplorer.model.ResourceNode

@Composable
fun ResourceTreeView(
    resources: List<ResourceNode>,
    selectedNode: ResourceNode?,
    onNodeSelected: (ResourceNode) -> Unit,
    searchFocusRequester: FocusRequester = remember { FocusRequester() }
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

    // ── Search and type filter ────────────────────────────────────

    var query by remember(resources) { mutableStateOf("") }
    var category by remember(resources) { mutableStateOf<ExportCategory?>(null) }
    val filtering = query.isNotBlank() || category != null
    val visibleTree = remember(resources, query, category) { ResourceCategories.filter(resources, category, query) }
    // Filtered folders are copies; hand the original nodes to the app so folder
    // exports and previews always see the full, unfiltered resource.
    val originals = remember(resources) { buildMap { indexById(resources, this) } }
    val categoryCounts = remember(resources) { ResourceCategories.counts(resources) }
    val totalCount = remember(resources) { countVisibleLeaves(resources) }
    val matchCount = remember(visibleTree) { countVisibleLeaves(visibleTree) }
    val select: (ResourceNode) -> Unit = { onNodeSelected(originals[it.id] ?: it) }

    // ── Build a flat, navigable list of visible rows ──────────────

    // Track which categories are expanded. While filtering, every matching folder
    // starts open and the user may collapse some; that state resets with the filter.
    val expandedIds = remember { mutableStateMapOf<String, Boolean>() }
    val collapsedWhileFiltering = remember(query, category) { mutableStateMapOf<String, Boolean>() }
    fun isExpanded(id: String) =
        if (filtering) collapsedWhileFiltering[id] != true else expandedIds[id] == true
    fun setExpanded(id: String, expanded: Boolean) {
        if (filtering) collapsedWhileFiltering[id] = !expanded else expandedIds[id] = expanded
    }

    // When the filter is cleared, reveal the selection in the full tree.
    LaunchedEffect(filtering) {
        if (!filtering) selectedNode?.let { node ->
            ancestorIds(resources, node.id)?.forEach { expandedIds[it] = true }
        }
    }

    // Build the flat visible rows (excluding palette-type nodes)
    val rows = remember(visibleTree, filtering, expandedIds.toMap(), collapsedWhileFiltering.toMap()) {
        buildFlatRows(visibleTree, ::isExpanded)
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

    Column(modifier = Modifier.fillMaxSize()) {
    SearchHeader(
        query = query,
        onQueryChange = { query = it },
        category = category,
        onCategoryChange = { category = it },
        categoryCounts = categoryCounts,
        matchCount = matchCount,
        totalCount = totalCount,
        filtering = filtering,
        focusRequester = searchFocusRequester,
        onSubmit = {
            rows.firstOrNull { !it.node.isCategory }?.let { select(it.node) }
            focusRequester.requestFocus()
        },
        onMoveToList = {
            if (selectedIdx < 0) rows.firstOrNull()?.let { select(it.node) }
            focusRequester.requestFocus()
        }
    )
    if (filtering && rows.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                "No resources match",
                color = MaterialTheme.colors.onSurface.copy(alpha = 0.4f),
                fontSize = 12.sp
            )
        }
        return@Column
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
                        if (next != null) select(next.node)
                        true
                    }
                    Key.DirectionUp -> {
                        val prev = rows.getOrNull((selectedIdx - 1).coerceAtLeast(0))
                        if (prev != null) select(prev.node)
                        true
                    }
                    Key.DirectionRight -> {
                        val cur = rows.getOrNull(selectedIdx)
                        if (cur != null && cur.node.isCategory && !isExpanded(cur.node.id)) {
                            setExpanded(cur.node.id, true)
                        } else {
                            // Move to first child
                            val firstChild = rows.getOrNull(selectedIdx + 1)
                            if (firstChild != null && firstChild.depth > (cur?.depth ?: 0))
                                select(firstChild.node)
                        }
                        true
                    }
                    Key.DirectionLeft -> {
                        val cur = rows.getOrNull(selectedIdx)
                        if (cur != null && cur.node.isCategory && isExpanded(cur.node.id)) {
                            setExpanded(cur.node.id, false)
                        } else {
                            // Move to parent
                            val parentRow = rows.take(selectedIdx).lastOrNull { it.depth < (cur?.depth ?: 0) }
                            if (parentRow != null) select(parentRow.node)
                        }
                        true
                    }
                    Key.Enter, Key.Spacebar -> {
                        val cur = rows.getOrNull(selectedIdx)
                        if (cur != null && cur.node.isCategory) {
                            setExpanded(cur.node.id, !isExpanded(cur.node.id))
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
                isExpanded = isExpanded(row.node.id),
                onClick = {
                    focusRequester.requestFocus()
                    if (row.node.isCategory) {
                        setExpanded(row.node.id, !isExpanded(row.node.id))
                    }
                    select(row.node)
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
    } // close Column
}

// ── Row model ────────────────────────────────────────────────────

private data class TreeRow(val node: ResourceNode, val depth: Int)

/** Recursively build the list of visible rows, skipping palette-type nodes. */
private fun buildFlatRows(
    nodes: List<ResourceNode>,
    isExpanded: (String) -> Boolean,
    depth: Int = 0,
    into: MutableList<TreeRow> = mutableListOf()
): List<TreeRow> {
    for (node in nodes) {
        // Skip palette companion nodes — displayed in the preview pane instead
        if (node.type == "palette") continue

        into.add(TreeRow(node, depth))

        if (node.isCategory && isExpanded(node.id)) {
            buildFlatRows(node.children, isExpanded, depth + 1, into)
        }
    }
    return into
}

private fun indexById(nodes: List<ResourceNode>, into: MutableMap<String, ResourceNode>) {
    for (node in nodes) {
        into.putIfAbsent(node.id, node)
        indexById(node.children, into)
    }
}

/** Leaves shown in the tree; palette companions are hidden there. */
private fun countVisibleLeaves(nodes: List<ResourceNode>): Int =
    nodes.sumOf { if (it.isCategory) countVisibleLeaves(it.children) else if (it.type == "palette") 0 else 1 }

/** IDs of the folders containing [id], outermost first, or null if it is not in the tree. */
private fun ancestorIds(nodes: List<ResourceNode>, id: String): List<String>? {
    for (node in nodes) {
        if (node.id == id) return emptyList()
        if (node.isCategory) ancestorIds(node.children, id)?.let { return listOf(node.id) + it }
    }
    return null
}

// ── Search header ────────────────────────────────────────────────

@Composable
private fun SearchHeader(
    query: String,
    onQueryChange: (String) -> Unit,
    category: ExportCategory?,
    onCategoryChange: (ExportCategory?) -> Unit,
    categoryCounts: Map<ExportCategory, Int>,
    matchCount: Int,
    totalCount: Int,
    filtering: Boolean,
    focusRequester: FocusRequester,
    onSubmit: () -> Unit,
    onMoveToList: () -> Unit
) {
    val dim = MaterialTheme.colors.onSurface.copy(alpha = 0.5f)
    var menuExpanded by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, top = 8.dp, bottom = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .background(MaterialTheme.colors.background, RoundedCornerShape(4.dp))
                    .padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) Text("Search resources", fontSize = 12.sp, color = dim)
                    BasicTextField(
                        value = query,
                        onValueChange = onQueryChange,
                        singleLine = true,
                        textStyle = TextStyle(fontSize = 12.sp, color = MaterialTheme.colors.onSurface),
                        cursorBrush = SolidColor(MaterialTheme.colors.primary),
                        modifier = Modifier
                            .fillMaxWidth()
                            .focusRequester(focusRequester)
                            .onPreviewKeyEvent { event ->
                                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                                when (event.key) {
                                    Key.Escape -> {
                                        if (query.isEmpty()) return@onPreviewKeyEvent false
                                        onQueryChange("")
                                        true
                                    }
                                    Key.Enter -> { onSubmit(); true }
                                    Key.DirectionDown -> { onMoveToList(); true }
                                    else -> false
                                }
                            }
                    )
                }
                if (query.isNotEmpty()) {
                    Text(
                        "\u2715",
                        fontSize = 11.sp,
                        color = dim,
                        modifier = Modifier.padding(start = 6.dp).clickable { onQueryChange("") }
                    )
                }
            }

            Spacer(Modifier.width(6.dp))

            // Type filter, using the same categories as the Export menu
            Box {
                Text(
                    text = (category?.label ?: "All types") + " \u25BE",
                    fontSize = 11.sp,
                    color = if (category != null) MaterialTheme.colors.primary else dim,
                    softWrap = false,
                    modifier = Modifier
                        .clickable { menuExpanded = true }
                        .padding(horizontal = 4.dp, vertical = 6.dp)
                )
                DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                    DropdownMenuItem(onClick = { menuExpanded = false; onCategoryChange(null) }) {
                        Text("All types", fontSize = 12.sp)
                    }
                    // Palettes are shown in the preview pane, not as tree rows
                    ExportCategory.values()
                        .filter { it != ExportCategory.PALETTES && (categoryCounts[it] ?: 0) > 0 }
                        .forEach { option ->
                            DropdownMenuItem(onClick = { menuExpanded = false; onCategoryChange(option) }) {
                                Text("${option.label} (${categoryCounts[option]})", fontSize = 12.sp)
                            }
                        }
                }
            }
        }

        if (filtering) {
            Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "%,d of %,d resources".format(matchCount, totalCount),
                    fontSize = 10.sp,
                    color = dim,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    "Clear",
                    fontSize = 10.sp,
                    color = MaterialTheme.colors.primary,
                    modifier = Modifier.clickable { onQueryChange(""); onCategoryChange(null) }
                )
            }
        }
    }
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
                "model"    -> "◇"
                "image"    -> "\uD83D\uDDBC"
                "animation" -> "\uD83C\uDFAC"
                "sound"    -> "\uD83D\uDD0A"
                "midi"     -> "\uD83C\uDFB9"
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


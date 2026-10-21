package adventureexplorer.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import adventureexplorer.graphics.Composite
import adventureexplorer.model.CompositeLayer
import adventureexplorer.model.ResourceNode
import java.awt.image.BufferedImage

private val HighlightColor = Color(0xFFFFD54F)
private val OutlineColor = Color(0x9990CAF9)

// ── Composite (layered) preview ───────────────────────────────

@Composable
internal fun CompositePreview(
    layers: List<CompositeLayer>,
    onExportImage: (BufferedImage) -> Unit,
    paletteImage: BufferedImage?,
    paletteOptions: List<ResourceNode>,
    selectedPaletteIndex: Int,
    onPaletteSelected: (Int) -> Unit,
    description: String?,
    canExportPalette: Boolean,
    onExportPaletteBin: () -> Unit
) {
    var zoomLevel by remember { mutableStateOf(1) }
    var showOutlines by remember { mutableStateOf(false) }
    // Visibility survives palette re-renders, which rebuild the same layers.
    val layerKey = layers.map { it.name to it.group }
    val visible = remember(layerKey) { layers.map { it.visible }.toMutableStateList() }
    var hoveredLayer by remember(layerKey) { mutableStateOf<Int?>(null) }
    var pointer by remember(layerKey) { mutableStateOf<Pair<Int, Int>?>(null) }

    val (canvasW, canvasH) = remember(layers) { Composite.canvasSize(layers) }
    val composed = remember(layers, visible.toList()) {
        Composite.flatten(layers, canvasW, canvasH) { visible.getOrElse(it) { false } }
    }
    val bitmap = remember(composed) { composed.toImageBitmap() }
    // Layer under the pointer: the topmost visible one whose bounds contain it.
    val pointedLayer = pointer?.let { (px, py) ->
        layers.indices.lastOrNull { visible[it] && layers[it].contains(px, py) }
    }
    val highlighted = hoveredLayer ?: pointedLayer

    Column(modifier = Modifier.fillMaxSize()) {

        // ── Header row ───────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = description ?: "$canvasW × $canvasH",
                fontSize = 12.sp,
                color = Color(0xFFAAAAAA),
                modifier = Modifier.weight(1f)
            )
            ZoomButtons(current = zoomLevel, options = listOf(1, 2, 3), onSelect = { zoomLevel = it })
            Spacer(Modifier.width(12.dp))
            ControlButton("💾  Export PNG") { onExportImage(composed) }
        }

        Divider(color = Color(0xFF333333))

        Row(modifier = Modifier.weight(1f).fillMaxWidth()) {

            // ── Canvas ───────────────────────────────────────
            val hScroll = rememberScrollState()
            val vScroll = rememberScrollState()
            val pxPerPixel = with(LocalDensity.current) { zoomLevel.dp.toPx() }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .horizontalScroll(hScroll)
                    .verticalScroll(vScroll)
                    .padding(8.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size((canvasW * zoomLevel).dp, (canvasH * zoomLevel).dp)
                        .pointerInput(pxPerPixel, canvasW, canvasH) {
                            awaitPointerEventScope {
                                while (true) {
                                    val event = awaitPointerEvent()
                                    val pos = event.changes.firstOrNull()?.position
                                    pointer = if (event.type == PointerEventType.Exit || pos == null) null else {
                                        val x = (pos.x / pxPerPixel).toInt()
                                        val y = (pos.y / pxPerPixel).toInt()
                                        if (x in 0 until canvasW && y in 0 until canvasH) x to y else null
                                    }
                                }
                            }
                        }
                ) {
                    Image(
                        bitmap = bitmap,
                        contentDescription = description ?: "Composite preview",
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.FillBounds,
                        filterQuality = FilterQuality.None
                    )
                    Canvas(Modifier.fillMaxSize()) {
                        fun outline(layer: CompositeLayer, color: Color, width: Float) = drawRect(
                            color = color,
                            topLeft = Offset(layer.x * pxPerPixel, layer.y * pxPerPixel),
                            size = Size(layer.image.width * pxPerPixel, layer.image.height * pxPerPixel),
                            style = Stroke(width)
                        )
                        if (showOutlines) layers.forEachIndexed { i, layer ->
                            if (visible[i] && !(layer.x == 0 && layer.y == 0 &&
                                    layer.image.width == canvasW && layer.image.height == canvasH)) {
                                outline(layer, OutlineColor, 1f)
                            }
                        }
                        highlighted?.let { outline(layers[it], HighlightColor, 2f) }
                    }
                }
            }

            Divider(modifier = Modifier.fillMaxHeight().width(1.dp), color = Color(0xFF333333))

            // ── Layer list ───────────────────────────────────
            LayerPane(
                layers = layers,
                visible = visible,
                highlighted = highlighted,
                onHover = { i, entered -> if (entered) hoveredLayer = i else if (hoveredLayer == i) hoveredLayer = null },
                showOutlines = showOutlines,
                onShowOutlines = { showOutlines = it },
                modifier = Modifier.width(240.dp).fillMaxHeight()
            )

            if (paletteImage != null || paletteOptions.isNotEmpty()) {
                Divider(modifier = Modifier.fillMaxHeight().width(1.dp), color = Color(0xFF333333))
                PalettePane(
                    paletteImage = paletteImage,
                    paletteOptions = paletteOptions,
                    selectedPaletteIndex = selectedPaletteIndex,
                    onPaletteSelected = onPaletteSelected,
                    canExport = canExportPalette,
                    onExportBin = onExportPaletteBin,
                    modifier = Modifier.width(220.dp).fillMaxHeight()
                )
            }
        }

        // ── Footer ───────────────────────────────────────────
        Divider(color = Color(0xFF333333))
        Text(
            text = buildString {
                append("$canvasW × $canvasH px  ·  zoom ×$zoomLevel  ·  ")
                append("${visible.count { it }} of ${layers.size} layers shown")
                pointer?.let { (x, y) -> append("  ·  ($x, $y)") }
                highlighted?.let { i ->
                    val l = layers[i]
                    append("  ·  ${l.name} at (${l.x}, ${l.y}), ${l.image.width} × ${l.image.height}")
                }
            },
            fontSize = 11.sp,
            color = Color(0xFF666666),
            maxLines = 1,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 3.dp)
        )
    }
}

@Composable
private fun LayerPane(
    layers: List<CompositeLayer>,
    visible: MutableList<Boolean>,
    highlighted: Int?,
    onHover: (Int, Boolean) -> Unit,
    showOutlines: Boolean,
    onShowOutlines: (Boolean) -> Unit,
    modifier: Modifier
) {
    val groups = remember(layers) { layers.indices.groupBy { layers[it].group } }
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()

    Column(modifier.background(Color(0xFF202020))) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Layers", fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                color = Color(0xFFCCCCCC), modifier = Modifier.weight(1f))
            Text("Outlines", fontSize = 11.sp, color = Color(0xFF999999))
            Checkbox(checked = showOutlines, onCheckedChange = onShowOutlines,
                modifier = Modifier.size(28.dp))
        }
        Divider(color = Color(0xFF333333))
        LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
            groups.forEach { (group, indices) ->
                item(key = "group:$group") {
                    val shown = indices.count { visible[it] }
                    Row(
                        Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 2.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("$group ($shown/${indices.size})", fontSize = 11.sp,
                            color = Color(0xFF999999), modifier = Modifier.weight(1f))
                        Text("All", fontSize = 11.sp, color = MaterialTheme.colors.primary,
                            modifier = Modifier.clickable { indices.forEach { visible[it] = true } }.padding(4.dp))
                        Text("None", fontSize = 11.sp, color = MaterialTheme.colors.primary,
                            modifier = Modifier.clickable { indices.forEach { visible[it] = false } }.padding(4.dp))
                    }
                }
                indices.forEach { i ->
                    item(key = i) {
                        val interaction = remember { MutableInteractionSource() }
                        val hovered by interaction.collectIsHoveredAsState()
                        LaunchedEffect(hovered) { onHover(i, hovered) }
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .background(if (highlighted == i) HighlightColor.copy(alpha = 0.12f) else Color.Transparent)
                                .hoverable(interaction)
                                .clickable { visible[i] = !visible[i] }
                                .padding(start = 4.dp, end = 10.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Checkbox(checked = visible[i], onCheckedChange = { visible[i] = it },
                                modifier = Modifier.size(28.dp))
                            Text(layers[i].name, fontSize = 11.sp, color = Color(0xFFDDDDDD),
                                maxLines = 1, softWrap = false)
                        }
                    }
                }
            }
        }
    }
}

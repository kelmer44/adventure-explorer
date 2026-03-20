package adventureexplorer.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import adventureexplorer.model.ResourceNode
import kotlinx.coroutines.delay
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import javax.imageio.ImageIO

@Composable
fun PreviewPane(
    image: BufferedImage?,
    paletteImage: BufferedImage?,
    paletteOptions: List<ResourceNode>,
    selectedPaletteIndex: Int,
    onPaletteSelected: (Int) -> Unit,
    description: String?,
    textContent: String?,
    canExportPalette: Boolean,
    onExportPaletteBin: () -> Unit,
    frames: List<BufferedImage>?,
    frameDelayMs: Int,
    onExportFrame: (BufferedImage) -> Unit,
    onExportAllFrames: () -> Unit,
    modifier: Modifier = Modifier
) {
    Box(modifier = modifier.background(Color(0xFF1A1A1A))) {
        when {
            frames != null && frames.isNotEmpty() -> AnimationPreview(
                frames = frames,
                frameDelayMs = frameDelayMs,
                description = description,
                onExportFrame = onExportFrame,
                onExportAllFrames = onExportAllFrames
            )
            image != null -> ImagePreview(
                image = image,
                paletteImage = paletteImage,
                paletteOptions = paletteOptions,
                selectedPaletteIndex = selectedPaletteIndex,
                onPaletteSelected = onPaletteSelected,
                description = description,
                canExportPalette = canExportPalette,
                onExportPaletteBin = onExportPaletteBin
            )
            textContent != null -> TextPreview(textContent, description)
            else -> EmptyPreview()
        }
    }
}

// ── Image preview ─────────────────────────────────────────────

@Composable
private fun ImagePreview(
    image: BufferedImage,
    paletteImage: BufferedImage?,
    paletteOptions: List<ResourceNode>,
    selectedPaletteIndex: Int,
    onPaletteSelected: (Int) -> Unit,
    description: String?,
    canExportPalette: Boolean,
    onExportPaletteBin: () -> Unit
) {
    var zoomLevel by remember { mutableStateOf(1) }

    Column(modifier = Modifier.fillMaxSize()) {

        // ── Header row: description + zoom buttons ───────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = description ?: "${image.width} \u00D7 ${image.height}",
                fontSize = 12.sp,
                color = Color(0xFFAAAAAA),
                modifier = Modifier.weight(1f)
            )
            ZoomButtons(current = zoomLevel, options = listOf(1, 2, 3), onSelect = { zoomLevel = it })
        }

        Divider(color = Color(0xFF333333))

        // ── Content row: image + optional palette pane ───────
        Row(modifier = Modifier.weight(1f).fillMaxWidth()) {

            // Scrollable image at exact pixel size × zoom
            val hScroll = rememberScrollState()
            val vScroll = rememberScrollState()
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .horizontalScroll(hScroll)
                    .verticalScroll(vScroll)
                    .padding(8.dp)
            ) {
                val bitmap = image.toImageBitmap()
                Image(
                    bitmap = bitmap,
                    contentDescription = description ?: "Preview",
                    modifier = Modifier.size(
                        (image.width * zoomLevel).dp,
                        (image.height * zoomLevel).dp
                    ),
                    contentScale = ContentScale.FillBounds,
                    filterQuality = FilterQuality.None   // nearest-neighbor
                )
            }

            // Palette side pane
            if (paletteImage != null || paletteOptions.isNotEmpty()) {
                Divider(
                    modifier = Modifier.fillMaxHeight().width(1.dp),
                    color = Color(0xFF333333)
                )
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
            text = "${image.width} \u00D7 ${image.height} px  \u00B7  zoom \u00D7$zoomLevel",
            fontSize = 11.sp,
            color = Color(0xFF666666),
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 3.dp)
        )
    }
}

// ── Zoom buttons ──────────────────────────────────────────────

@Composable
private fun ZoomButtons(current: Int, options: List<Int>, onSelect: (Int) -> Unit) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        options.forEach { z ->
            val selected = z == current
            val bg = if (selected) MaterialTheme.colors.primary.copy(alpha = 0.25f)
                     else Color(0xFF333333)
            val textColor = if (selected) MaterialTheme.colors.primary else Color(0xFFAAAAAA)
            Box(
                modifier = Modifier
                    .background(bg, RoundedCornerShape(4.dp))
                    .clickable { onSelect(z) }
                    .padding(horizontal = 8.dp, vertical = 3.dp),
                contentAlignment = Alignment.Center
            ) {
                Text("\u00D7$z", fontSize = 12.sp, color = textColor)
            }
        }
    }
}

// ── Palette side pane ─────────────────────────────────────────

@Composable
private fun PalettePane(
    paletteImage: BufferedImage?,
    paletteOptions: List<ResourceNode>,
    selectedPaletteIndex: Int,
    onPaletteSelected: (Int) -> Unit,
    canExport: Boolean,
    onExportBin: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .background(Color(0xFF222222))
            .padding(horizontal = 8.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            "Palette",
            fontSize = 11.sp,
            color = Color(0xFF888888),
            modifier = Modifier.padding(bottom = 4.dp)
        )

        // Dropdown to select palette (only shown if there are options)
        if (paletteOptions.isNotEmpty()) {
            var expanded by remember { mutableStateOf(false) }
            val currentName = paletteOptions.getOrNull(selectedPaletteIndex)?.name
                ?: paletteOptions.firstOrNull()?.name
                ?: "Default"

            Box(modifier = Modifier.fillMaxWidth().padding(bottom = 6.dp)) {
                OutlinedButton(
                    onClick = { expanded = true },
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = MaterialTheme.colors.primary
                    )
                ) {
                    Text(currentName, fontSize = 11.sp, maxLines = 1)
                }
                DropdownMenu(
                    expanded = expanded,
                    onDismissRequest = { expanded = false }
                ) {
                    paletteOptions.forEachIndexed { idx, palNode ->
                        DropdownMenuItem(onClick = {
                            expanded = false
                            onPaletteSelected(idx)
                        }) {
                            Text(
                                text = palNode.name,
                                fontSize = 12.sp,
                                color = if (idx == selectedPaletteIndex)
                                    MaterialTheme.colors.primary
                                else MaterialTheme.colors.onSurface
                            )
                        }
                    }
                }
            }
        }

        // Palette swatch
        if (paletteImage != null) {
            val bitmap = paletteImage.toImageBitmap()
            val vScroll = rememberScrollState()
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(vScroll),
                contentAlignment = Alignment.TopCenter
            ) {
                Image(
                    bitmap = bitmap,
                    contentDescription = "Palette swatch",
                    modifier = Modifier.fillMaxWidth().aspectRatio(1f),
                    contentScale = ContentScale.FillWidth,
                    filterQuality = FilterQuality.None   // nearest-neighbor
                )
            }
        } else {
            Spacer(Modifier.weight(1f))
        }

        Spacer(Modifier.height(8.dp))

        // Export .bin button
        Button(
            onClick = onExportBin,
            enabled = canExport,
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(
                backgroundColor = MaterialTheme.colors.primary
            ),
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp)
        ) {
            Text("\uD83D\uDCBE  Export .bin", fontSize = 12.sp)
        }
    }
}

// ── Animation preview ─────────────────────────────────────────

@Composable
private fun AnimationPreview(
    frames: List<BufferedImage>,
    frameDelayMs: Int,
    description: String?,
    onExportFrame: (BufferedImage) -> Unit,
    onExportAllFrames: () -> Unit
) {
    var currentFrame by remember(frames) { mutableStateOf(0) }
    var isPlaying by remember(frames) { mutableStateOf(false) }
    var zoomLevel by remember { mutableStateOf(1) }

    // Playback loop
    LaunchedEffect(isPlaying, frameDelayMs, frames) {
        if (isPlaying) {
            while (true) {
                delay(frameDelayMs.toLong())
                currentFrame = (currentFrame + 1) % frames.size
            }
        }
    }

    val frame = frames[currentFrame.coerceIn(0, frames.size - 1)]

    Column(modifier = Modifier.fillMaxSize()) {

        // ── Header row: description + zoom buttons ───────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = description ?: "Animation \u2014 ${frames.size} frames",
                fontSize = 12.sp,
                color = Color(0xFFAAAAAA),
                modifier = Modifier.weight(1f)
            )
            ZoomButtons(current = zoomLevel, options = listOf(1, 2, 3), onSelect = { zoomLevel = it })
        }

        Divider(color = Color(0xFF333333))

        // ── Image area ───────────────────────────────────────
        val hScroll = rememberScrollState()
        val vScroll = rememberScrollState()
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .horizontalScroll(hScroll)
                .verticalScroll(vScroll)
                .padding(8.dp)
        ) {
            val bitmap = frame.toImageBitmap()
            Image(
                bitmap = bitmap,
                contentDescription = "Frame $currentFrame",
                modifier = Modifier.size(
                    (frame.width * zoomLevel).dp,
                    (frame.height * zoomLevel).dp
                ),
                contentScale = ContentScale.FillBounds,
                filterQuality = FilterQuality.None
            )
        }

        Divider(color = Color(0xFF333333))

        // ── Playback controls ────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(Color(0xFF222222))
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            // First frame
            ControlButton("|<") { isPlaying = false; currentFrame = 0 }

            // Previous frame
            ControlButton("<") {
                isPlaying = false
                currentFrame = if (currentFrame > 0) currentFrame - 1 else frames.size - 1
            }

            // Play / Pause
            ControlButton(if (isPlaying) "\u23F8" else "\u25B6") {
                isPlaying = !isPlaying
            }

            // Next frame
            ControlButton(">") {
                isPlaying = false
                currentFrame = (currentFrame + 1) % frames.size
            }

            // Last frame
            ControlButton(">|") { isPlaying = false; currentFrame = frames.size - 1 }

            Spacer(Modifier.width(8.dp))

            // Frame counter
            Text(
                text = "Frame ${currentFrame + 1} / ${frames.size}",
                fontSize = 12.sp,
                color = Color(0xFFCCCCCC)
            )

            Spacer(Modifier.weight(1f))

            // Export current frame
            ControlButton("\uD83D\uDCBE 1") { onExportFrame(frame) }

            // Export all frames
            ControlButton("\uD83D\uDCBE All") { onExportAllFrames() }
        }

        // ── Footer ───────────────────────────────────────────
        Text(
            text = "${frame.width} \u00D7 ${frame.height} px  \u00B7  zoom \u00D7$zoomLevel  \u00B7  ${frames.size} frames @ ${frameDelayMs}ms",
            fontSize = 11.sp,
            color = Color(0xFF666666),
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 3.dp)
        )
    }
}

@Composable
private fun ControlButton(label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .background(Color(0xFF333333), RoundedCornerShape(4.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 4.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(label, fontSize = 13.sp, color = Color(0xFFDDDDDD))
    }
}

// ── Text preview ─────────────────────────────────────────────

@Composable
private fun TextPreview(text: String, description: String?) {
    val scrollState = rememberScrollState()
    Column(modifier = Modifier.fillMaxSize().padding(12.dp)) {
        if (description != null) {
            Text(
                text = description,
                fontSize = 12.sp,
                color = Color(0xFFAAAAAA),
                modifier = Modifier.padding(bottom = 8.dp)
            )
        }
        Text(
            text = text,
            fontSize = 13.sp,
            fontFamily = FontFamily.Monospace,
            color = Color(0xFFE0E0E0),
            modifier = Modifier.verticalScroll(scrollState)
        )
    }
}

// ── Empty preview ─────────────────────────────────────────────

@Composable
private fun EmptyPreview() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(text = "\uD83D\uDD0D", fontSize = 48.sp)
            Spacer(Modifier.height(12.dp))
            Text(
                text = "Select a resource to preview",
                fontSize = 14.sp,
                color = Color(0xFF666666)
            )
        }
    }
}

// ── Utility ──────────────────────────────────────────────────

private fun BufferedImage.toImageBitmap(): ImageBitmap {
    val baos = ByteArrayOutputStream()
    ImageIO.write(this, "png", baos)
    return org.jetbrains.skia.Image.makeFromEncoded(baos.toByteArray()).toComposeImageBitmap()
}

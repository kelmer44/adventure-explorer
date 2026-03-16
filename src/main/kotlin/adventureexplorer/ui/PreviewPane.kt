package adventureexplorer.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import javax.imageio.ImageIO

@Composable
fun PreviewPane(
    image: BufferedImage?,
    paletteImage: BufferedImage?,
    description: String?,
    textContent: String?,
    canExportPalette: Boolean,
    onExportPaletteBin: () -> Unit,
    modifier: Modifier = Modifier
) {
    Box(modifier = modifier.background(Color(0xFF1A1A1A))) {
        when {
            image != null -> ImagePreview(image, paletteImage, description, canExportPalette, onExportPaletteBin)
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
    description: String?,
    canExportPalette: Boolean,
    onExportPaletteBin: () -> Unit
) {
    var zoomLevel by remember { mutableStateOf(2) }

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

            // Zoom toggle buttons
            ZoomButtons(
                current = zoomLevel,
                options = listOf(1, 2, 3),
                onSelect = { zoomLevel = it }
            )
        }

        Divider(color = Color(0xFF333333))

        // ── Content row: image + optional palette pane ───────
        Row(modifier = Modifier.weight(1f).fillMaxWidth()) {

            // Scrollable image
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
                    contentScale = ContentScale.FillBounds
                )
            }

            // Palette side pane (only when palette is available)
            if (paletteImage != null) {
                Divider(
                    modifier = Modifier.fillMaxHeight().width(1.dp),
                    color = Color(0xFF333333)
                )
                PalettePane(
                    paletteImage = paletteImage,
                    canExport = canExportPalette,
                    onExportBin = onExportPaletteBin,
                    modifier = Modifier.width(220.dp).fillMaxHeight()
                )
            }
        }

        // ── Footer: pixel dimensions ─────────────────────────
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
    paletteImage: BufferedImage,
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
            modifier = Modifier.padding(bottom = 6.dp)
        )

        // Palette swatch image — displayed at its natural size or scaled to fit
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
                contentDescription = "Palette",
                modifier = Modifier.fillMaxWidth().aspectRatio(1f),
                contentScale = ContentScale.FillWidth
            )
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

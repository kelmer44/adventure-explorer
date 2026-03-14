package adventureexplorer.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
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
    description: String?,
    textContent: String?,
    modifier: Modifier = Modifier
) {
    Box(modifier = modifier.background(Color(0xFF1A1A1A))) {
        when {
            image != null -> ImagePreview(image, description)
            textContent != null -> TextPreview(textContent, description)
            else -> EmptyPreview()
        }
    }
}

@Composable
private fun ImagePreview(image: BufferedImage, description: String?) {
    Column(modifier = Modifier.fillMaxSize()) {
        // Description header
        if (description != null) {
            Text(
                text = description,
                fontSize = 12.sp,
                color = Color(0xFFAAAAAA),
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
            )
        }

        // Image with scroll support for zooming later
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .padding(8.dp),
            contentAlignment = Alignment.Center
        ) {
            val bitmap = image.toImageBitmap()
            Image(
                bitmap = bitmap,
                contentDescription = description ?: "Preview",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Fit
            )
        }

        // Image info footer
        Text(
            text = "${image.width} \u00D7 ${image.height} pixels",
            fontSize = 11.sp,
            color = Color(0xFF777777),
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)
        )
    }
}

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

@Composable
private fun EmptyPreview() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = "\uD83D\uDD0D",
                fontSize = 48.sp
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = "Select a resource to preview",
                fontSize = 14.sp,
                color = Color(0xFF666666)
            )
        }
    }
}

// ── Utility ─────────────────────────────────────────────────────

/**
 * Convert a BufferedImage to a Compose ImageBitmap via PNG encoding.
 * This works reliably across all Compose Desktop versions.
 */
private fun BufferedImage.toImageBitmap(): ImageBitmap {
    val baos = ByteArrayOutputStream()
    ImageIO.write(this, "png", baos)
    val bytes = baos.toByteArray()
    return org.jetbrains.skia.Image.makeFromEncoded(bytes).toComposeImageBitmap()
}

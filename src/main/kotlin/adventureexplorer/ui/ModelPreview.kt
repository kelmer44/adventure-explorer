package adventureexplorer.ui

import adventureexplorer.model.ModelData
import adventureexplorer.models.ModelRenderer
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.input.pointer.*
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.awt.image.BufferedImage

@Composable
fun ModelPreview(model: ModelData, description: String?, onExport: (BufferedImage) -> Unit,
                 paletteOptions: List<adventureexplorer.model.ResourceNode> = emptyList(), selectedPalette: Int = -1,
                 onPalette: (Int) -> Unit = {}, onTexture: (String?) -> Unit = {}) {
    key(model.vertices, model.faces) {
        var yaw by remember { mutableStateOf(25.0) }
        var pitch by remember { mutableStateOf(10.0) }
        var zoom by remember { mutableStateOf(1.0) }
        var wireframe by remember { mutableStateOf(false) }
        val rendered by produceState<BufferedImage?>(null, model, listOf(yaw,pitch,zoom,wireframe)) {
            value = withContext(Dispatchers.Default) { ModelRenderer.render(model, yaw=yaw, pitch=pitch, zoom=zoom, wireframe=wireframe) }
        }
        val bitmap = remember(rendered) { rendered?.toComposeImageBitmap() }
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Text(description ?: "3D Model", color=Color.White)
            Text("${model.meshCount} meshes · ${model.vertices.size} vertices · ${model.faces.size} polygons · ${model.lines.size} lines",
                color=Color.LightGray)
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), verticalAlignment=Alignment.CenterVertically) {
                Checkbox(wireframe, { wireframe=it }); Text("Wireframe", color=Color.White)
                TextButton(onClick={ zoom=(zoom/1.2).coerceAtLeast(0.1) }) { Text("−") }
                Text("${(zoom*100).toInt()}%", color=Color.White)
                TextButton(onClick={ zoom=(zoom*1.2).coerceAtMost(5.0) }) { Text("+") }
                TextButton(onClick={ yaw=25.0; pitch=10.0; zoom=1.0 }) { Text("Reset view") }
                TextButton(onClick={ rendered?.let(onExport) }, enabled=rendered!=null) { Text("Export PNG") }
            }
            if (model.textureOptions.isNotEmpty()) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
                val textureChoices=listOf("" to "Automatic textures", "__none__" to "Untextured") + model.textureOptions.map { it.id to it.name }
                ModelChoice("Texture", textureChoices, model.selectedTextureId ?: "") { onTexture(it.ifEmpty { null }) }
                if (paletteOptions.isNotEmpty()) ModelChoice("Palette", paletteOptions.mapIndexed { i,n -> i.toString() to n.name }, selectedPalette.toString()) { onPalette(it.toInt()) }
            }
            Box(Modifier.weight(1f).fillMaxWidth()
                .pointerInput(model) {
                    detectDragGestures { change, drag ->
                        change.consume()
                        yaw=(yaw+drag.x*0.5)%360.0
                        pitch=(pitch+drag.y*0.5).coerceIn(-89.0,89.0)
                    }
                }
                .pointerInput(model) {
                    awaitPointerEventScope {
                        while (true) {
                            val event=awaitPointerEvent()
                            if (event.type==PointerEventType.Scroll) {
                                val delta=event.changes.firstOrNull()?.scrollDelta?.y ?: continue
                                zoom=(zoom*kotlin.math.exp(-delta*0.1)).coerceIn(0.1,5.0)
                                event.changes.forEach { it.consume() }
                            }
                        }
                    }
                }, contentAlignment=Alignment.Center) {
                if (bitmap!=null) Image(bitmap, "3D model", Modifier.fillMaxSize(), contentScale=ContentScale.Fit)
                else CircularProgressIndicator()
            }
            Text("Drag to rotate · Scroll or use +/− to zoom", color=Color.LightGray)
        }
    }
}

@Composable
private fun ModelChoice(label: String, choices: List<Pair<String,String>>, selected: String, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    Box {
        TextButton(onClick={ expanded=true;search="" }) {
            Text("$label: ${choices.firstOrNull { it.first==selected }?.second ?: "Automatic"}")
        }
        DropdownMenu(expanded, { expanded=false }, Modifier.heightIn(max=360.dp).widthIn(max=500.dp)) {
            OutlinedTextField(search,{search=it},label={ Text("Find $label") },singleLine=true,modifier=Modifier.padding(8.dp))
            if (choices.size>100 && search.isBlank()) Text("Type to find more options", Modifier.padding(8.dp))
            choices.filter { it.second.contains(search,ignoreCase=true) }.take(100).forEach { (id,name) ->
                DropdownMenuItem(onClick={expanded=false;onSelect(id)}) { Text(name) }
            }
        }
    }
}

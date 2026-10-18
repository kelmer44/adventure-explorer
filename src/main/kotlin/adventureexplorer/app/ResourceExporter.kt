package adventureexplorer.app

import adventureexplorer.model.ResourceData
import adventureexplorer.model.ResourceNode
import adventureexplorer.model.ExportLayout
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.File
import java.util.Locale
import javax.imageio.ImageIO
import javax.sound.sampled.AudioFileFormat
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioInputStream
import javax.sound.sampled.AudioSystem

/** Writes decoded resources one at a time using the selected folder layout. */
class ResourceExporter(
    private val load: (ResourceNode) -> ResourceData?,
    private val release: () -> Unit = {}
) {
    data class Result(val exported: Int, val failures: List<String>, val errorLog: File?)
    private val usedNames = mutableMapOf<File, MutableSet<String>>()

    suspend fun export(
        nodes: List<ResourceNode>,
        directory: File,
        layout: ExportLayout = ExportLayout.RESOURCE_TREE,
        onProgress: suspend (Int, Int, ResourceNode) -> Unit = { _, _, _ -> }
    ): Result {
        require(directory.isDirectory || directory.mkdirs()) { "Cannot create ${directory.path}" }
        usedNames.clear()
        val failures = mutableListOf<String>()
        var completed = 0
        var exported = 0
        val total = nodes.sumOf { it.countAll() }

        suspend fun walk(node: ResourceNode, parent: File, treePath: String) {
            currentCoroutineContext().ensureActive()
            val label = "$treePath/${node.name}"
            if (node.isCategory) {
                if (layout == ExportLayout.SAME_FOLDER) {
                    node.children.forEach { walk(it, parent, label) }
                    return
                }
                val folder = availableFile(parent, safeName(node.name))
                // Creating the category here also preserves empty categories.
                check(folder.mkdir()) { "Cannot create ${folder.path}" }
                node.children.forEach { walk(it, folder, label) }
                return
            }
            onProgress(completed + 1, total, node)
            currentCoroutineContext().ensureActive()
            try {
                val data = load(node) ?: error("Could not decode resource")
                currentCoroutineContext().ensureActive()
                writeResource(node, data, parent)
                exported++
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                failures += "$label [${node.id}]: ${e.message ?: e.javaClass.simpleName}"
            } finally {
                release()
            }
            completed++
        }

        nodes.forEach { walk(it, directory, "") }
        val errorLog = if (failures.isNotEmpty()) {
            availableFile(directory, "export-errors", ".txt").also {
                it.writeText(failures.joinToString("\n", postfix = "\n"))
            }
        } else null
        return Result(exported, failures, errorLog)
    }

    private suspend fun writeResource(node: ResourceNode, data: ResourceData, parent: File) {
        val name = safeName(node.name)
        when {
            data.modelData != null -> check(ImageIO.write(adventureexplorer.models.ModelRenderer.render(data.modelData),
                "PNG", availableFile(parent, name, ".png")))
            !data.frames.isNullOrEmpty() -> {
                val folder = availableFile(parent, name)
                check(folder.mkdir()) { "Cannot create ${folder.path}" }
                data.frames.forEachIndexed { i, frame ->
                    currentCoroutineContext().ensureActive()
                    check(ImageIO.write(frame, "PNG", File(folder, "frame_%04d.png".format(Locale.ROOT, i))))
                }
                File(folder, "animation.txt").writeText("Frames: ${data.frames.size}\nFrame delay: ${data.frameDelayMs} ms\n")
            }
            data.image != null -> {
                check(ImageIO.write(data.image, "PNG", availableFile(parent, name, ".png")))
                if (node.type == "palette") {
                    val image = data.image
                    val colors = data.paletteColors.coerceIn(1, 256)
                    val bytes = ByteArray(colors * 3)
                    repeat(colors) { i ->
                        val rgb = image.getRGB((i % 16) * image.width / 16, (i / 16) * image.height / 16)
                        bytes[i * 3] = (rgb shr 16).toByte()
                        bytes[i * 3 + 1] = (rgb shr 8).toByte()
                        bytes[i * 3 + 2] = rgb.toByte()
                    }
                    availableFile(parent, name, ".bin").writeBytes(bytes)
                }
            }
            data.soundData != null -> {
                val sound = data.soundData
                val format = AudioFormat(sound.sampleRate.toFloat(), sound.bitsPerSample, sound.channels,
                    sound.signed || sound.bitsPerSample == 16, false)
                AudioInputStream(sound.samples.inputStream(), format, sound.samples.size.toLong() / format.frameSize).use {
                    AudioSystem.write(it, AudioFileFormat.Type.WAVE, availableFile(parent, name, ".wav"))
                }
            }
            data.midiData != null -> availableFile(parent, name, ".mid").writeBytes(data.midiData.bytes)
            data.textContent != null -> availableFile(parent, name, ".txt").writeText(data.textContent)
            data.description != null -> availableFile(parent, name, ".txt").writeText(data.description)
            else -> error("No decoded content available (${data.type})")
        }
    }

    private fun safeName(name: String): String = name
        .replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_")
        .trim().trimEnd('.').take(160)
        .ifBlank { "resource" }
        .let { if (it.substringBefore('.').uppercase(Locale.ROOT) in reservedNames) "_$it" else it }

    /** Never overwrite existing entries, including symlinks and case-only duplicates. */
    private fun availableFile(parent: File, name: String, extension: String = ""): File {
        val existing = usedNames.getOrPut(parent) {
            parent.list()?.map { it.lowercase(Locale.ROOT) }?.toMutableSet() ?: mutableSetOf()
        }
        var candidate = "$name$extension"
        var suffix = 2
        while (candidate.lowercase(Locale.ROOT) in existing) candidate = "$name (${suffix++})$extension"
        existing.add(candidate.lowercase(Locale.ROOT))
        return File(parent, candidate)
    }

    companion object {
        private val reservedNames = setOf("CON", "PRN", "AUX", "NUL") +
            (1..9).flatMap { listOf("COM$it", "LPT$it") }
    }
}

package adventureexplorer

import adventureexplorer.model.ResourceNode
import adventureexplorer.scripting.ScriptManager
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO
import javax.sound.sampled.AudioFileFormat
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioInputStream
import javax.sound.sampled.AudioSystem

/**
 * Headless developer tool for exercising engine scripts without the UI.
 *
 *   tree <gamePath> [idPrefix] [maxDepth]   print the resource tree
 *   scan <gamePath> <idPrefix> [max]        load every leaf under the prefix, report failures/sizes
 *   load <gamePath> <resourceId> <outFile> [paletteId]
 *                                           decode one resource to PNG / WAV / MID / TXT
 */
fun main(args: Array<String>) {
    if (args.size < 2) {
        println("usage: tree <game> [prefix] [depth] | scan <game> <prefix> [max] | load <game> <id> <out> [paletteId]")
        return
    }
    val mgr = ScriptManager()
    val det = mgr.detectGame(args[1]) ?: run { println("no engine detected"); return }
    println("engine: ${det.engineId} (${det.engineName})")
    when (args[0]) {
        "tree" -> {
            val prefix = args.getOrNull(2) ?: ""
            val depth = args.getOrNull(3)?.toInt() ?: 3
            fun walk(n: ResourceNode, d: Int, show: Boolean) {
                val s = show || prefix.isEmpty() || n.id.startsWith(prefix)
                if (s && d <= depth) println("  ".repeat(d) + "${n.id}  [${n.type}]  ${n.name}")
                n.children.forEach { walk(it, d + 1, s) }
            }
            det.resources.forEach { walk(it, 0, false) }
        }
        "scan" -> {
            val prefix = args.getOrNull(2) ?: ""
            val max = args.getOrNull(3)?.toInt() ?: 50
            var n = 0
            fun walk(node: ResourceNode) {
                if (n >= max) return
                if (node.isLeaf && node.id.startsWith(prefix)) {
                    n++
                    val t0 = System.currentTimeMillis()
                    val r = mgr.loadResource(args[1], node.id, null)
                    val ms = System.currentTimeMillis() - t0
                    val info = when {
                        r == null -> "FAILED"
                        r.frames != null -> "${r.frames!!.size} frames ${r.frames!![0].width}x${r.frames!![0].height}"
                        r.image != null -> "image ${r.image!!.width}x${r.image!!.height}"
                        r.soundData != null -> "sound ${r.soundData!!.durationMs}ms"
                        r.midiData != null -> {
                            val seq = runCatching {
                                javax.sound.midi.MidiSystem.getSequence(r.midiData!!.bytes.inputStream())
                            }
                            if (seq.isSuccess) "midi ${r.midiData!!.bytes.size}B ${seq.getOrNull()!!.microsecondLength / 1000000}s"
                            else "MIDI PARSE ERROR: ${seq.exceptionOrNull()?.message}"
                        }
                        else -> "text: ${r.textContent?.take(60)}"
                    }
                    println("${node.id}  ->  $info  (${ms}ms)")
                }
                node.children.forEach { walk(it) }
            }
            det.resources.forEach { walk(it) }
        }
        "load" -> {
            val r = mgr.loadResource(args[1], args[2], args.getOrNull(4))
            if (r == null) { println("load failed"); return }
            println("type=${r.type} desc=${r.description}")
            val out = File(args[3])
            when {
                r.frames != null -> {
                    val fr = r.frames!!
                    val w = fr.sumOf { it.width }; val h = fr.maxOf { it.height }
                    val img = BufferedImage(w, h, BufferedImage.TYPE_INT_RGB)
                    var x = 0
                    fr.forEach { img.graphics.drawImage(it, x, 0, null); x += it.width }
                    ImageIO.write(img, "png", out); println("frames=${fr.size} ${w}x$h")
                }
                r.image != null -> { ImageIO.write(r.image, "png", out); println("${r.image!!.width}x${r.image!!.height}") }
                r.soundData != null -> {
                    val s = r.soundData!!
                    val fmt = AudioFormat(s.sampleRate.toFloat(), s.bitsPerSample, s.channels, s.signed, false)
                    val ais = AudioInputStream(s.samples.inputStream(), fmt, (s.samples.size / fmt.frameSize).toLong())
                    AudioSystem.write(ais, AudioFileFormat.Type.WAVE, out); println("sound ${s.durationMs} ms")
                }
                r.midiData != null -> { out.writeBytes(r.midiData!!.bytes); println("midi ${r.midiData!!.bytes.size} bytes") }
                else -> { out.writeText(r.textContent ?: ""); println(r.textContent?.take(2000)) }
            }
        }
    }
}

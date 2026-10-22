package adventureexplorer.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Divider
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import adventureexplorer.audio.AdlibPlayback
import adventureexplorer.audio.imuse.ImusePlayback
import adventureexplorer.audio.imuse.ImuseSong
import adventureexplorer.audio.imuse.ImuseSong.CatalogueEntry
import adventureexplorer.audio.imuse.ImuseSong.HookKind
import kotlinx.coroutines.delay

/**
 * Interactive iMUSE player: plays the song with its loops and lets you arm the
 * hooks the game scripts would set; the transition happens at the next point
 * in the song that carries that hook.
 */
@Composable
internal fun ImusePreview(
    song: ImuseSong,
    description: String?,
    playbackChoice: Boolean,
    adlibPlayback: AdlibPlayback,
    onAdlibPlaybackChange: (AdlibPlayback) -> Unit,
    onExportMidi: () -> Unit,
    onExportWav: () -> Unit,
) {
    val useOpl = song.isAdlib && adlibPlayback == AdlibPlayback.OPL
    val playback = remember(song, useOpl) { ImusePlayback(song, useOpl) }
    DisposableEffect(playback) { onDispose { playback.stop() } }

    var state by remember(playback) { mutableStateOf(playback.state) }
    var started by remember(playback) { mutableStateOf(false) }
    LaunchedEffect(playback) {
        while (true) {
            state = playback.state
            delay(100)
        }
    }
    val playing = started && state.playing
    val armed = state.armed.toSet()

    Column(Modifier.fillMaxSize()) {
        Text(
            description ?: "iMUSE song",
            fontSize = 12.sp, color = Color(0xFFAAAAAA),
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
        )
        if (playbackChoice) {
            Divider(color = Color(0xFF333333))
            PlaybackSelector(adlibPlayback, onAdlibPlaybackChange)
        }
        Divider(color = Color(0xFF333333))
        Row(
            modifier = Modifier.fillMaxWidth().background(Color(0xFF222222)).padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            ControlButton(if (playing) "⏹ Stop" else "▶ Play") {
                if (playing) { playback.stop(); started = false } else { playback.start(); started = true }
            }
            Spacer(Modifier.width(8.dp))
            Text(
                if (playing) "Playing · ${state.position}" else "Stopped",
                fontSize = 12.sp, color = Color(0xFFCCCCCC)
            )
            Spacer(Modifier.weight(1f))
            ControlButton("💾 MIDI") { onExportMidi() }
            if (useOpl) ControlButton("💾 WAV") { onExportWav() }
        }
        Text(
            (if (useOpl) "AdLib instruments on Nuked OPL3 emulation (OPL2)" else "Java MIDI synthesizer" +
                if (song.isMt32) " · MT-32 programs mapped to General MIDI" else "") +
                " · ${song.tracks.size} track(s) · arm a hook, then play: it fires at its next occurrence",
            fontSize = 11.sp, color = Color(0xFF666666),
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 3.dp)
        )
        Divider(color = Color(0xFF333333))

        Row(Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(Modifier.weight(3f).fillMaxHeight().padding(horizontal = 12.dp, vertical = 6.dp)) {
                val groups = song.armableHooks.entries.groupBy { it.key.first }
                if (groups.isEmpty()) {
                    item { SectionTitle("No armable hooks: this song plays the same every time") }
                }
                for (kind in HookKind.entries) {
                    val entries = groups[kind] ?: continue
                    item { SectionTitle("${kind.label} hooks") }
                    items(entries.sortedWith(compareBy({ it.key.second }, { it.key.third })), key = { "${it.key}" }) { (key, places) ->
                        HookRow(key, places, key in armed) { playback.armHook(key.first, key.third, key.second) }
                    }
                }
                val fixed = song.catalogue.filter { (it is CatalogueEntry.Hook && it.id == 0) || it is CatalogueEntry.Loop }
                if (fixed.isNotEmpty()) {
                    item { SectionTitle("Built-in jumps and loops (always taken)") }
                    items(fixed.take(200)) { e -> InfoLine(describe(e)) }
                }
                val markers = song.catalogue.filterIsInstance<CatalogueEntry.Marker>()
                if (markers.isNotEmpty()) {
                    item { SectionTitle("Markers (signal the game scripts)") }
                    items(markers.take(200)) { e -> InfoLine("Marker ${e.id} at ${e.at}") }
                }
            }
            Box(Modifier.width(1.dp).fillMaxHeight().background(Color(0xFF333333)))
            Column(Modifier.weight(2f).fillMaxHeight().padding(horizontal = 12.dp, vertical = 6.dp)) {
                SectionTitle("Events")
                LazyColumn(Modifier.weight(1f)) {
                    items(state.log.asReversed()) { line -> InfoLine(line) }
                }
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color(0xFFDDDDDD), modifier = Modifier.padding(top = 8.dp, bottom = 4.dp))
}

@Composable
private fun InfoLine(text: String) {
    Text(text, fontSize = 11.sp, color = Color(0xFF999999), modifier = Modifier.padding(vertical = 1.dp))
}

@Composable
private fun HookRow(key: Triple<HookKind, Int, Int>, places: List<CatalogueEntry.Hook>, armed: Boolean, onArm: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth()
            .background(if (armed) Color(0xFF2E4466) else Color.Transparent, RoundedCornerShape(4.dp))
            .padding(horizontal = 6.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .background(if (armed) Color(0xFF3A5A8C) else Color(0xFF333333), RoundedCornerShape(4.dp))
                .clickable(enabled = !armed) { onArm() }
                .padding(horizontal = 8.dp, vertical = 2.dp)
        ) {
            Text(if (armed) "Armed" else "Arm", fontSize = 11.sp, color = Color.White)
        }
        Spacer(Modifier.width(8.dp))
        val part = if (key.second >= 0) " · part ${key.second}" else ""
        val first = places.take(3).joinToString("; ") { "${it.at} ${it.detail}" }
        val more = if (places.size > 3) " (+${places.size - 3} more)" else ""
        Text("Hook ${key.third}$part · $first$more", fontSize = 11.sp, color = Color(0xFFCCCCCC))
    }
}

private fun describe(e: CatalogueEntry): String = when (e) {
    is CatalogueEntry.Hook -> "${e.kind.label} at ${e.at} ${e.detail}"
    is CatalogueEntry.Loop -> "Loop ×${e.count}: ${e.from} → ${e.to} (set at ${e.at})"
    is CatalogueEntry.Marker -> "Marker ${e.id} at ${e.at}"
}

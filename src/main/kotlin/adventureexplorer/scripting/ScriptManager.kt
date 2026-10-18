package adventureexplorer.scripting

import adventureexplorer.model.*
import org.luaj.vm2.LuaTable
import org.luaj.vm2.LuaValue
import java.io.File

/**
 * Discovers engine scripts from the scripts/engines/ directory,
 * detects games, and delegates resource loading to the matched engine.
 */
class ScriptManager {

    @Synchronized
    fun releaseDecodedResources() { engine?.releaseDecodedResources() }

    @Synchronized
    fun close() { engine?.cleanup() }

    private var engine: LuaEngine? = null
    private var currentScript: LuaValue? = null
    private var scriptsDir: File = resolveScriptsDir()

    /**
     * Try to detect a game from the given folder path.
     * Iterates through all engine scripts and calls detect(path) on each.
     */
    @Synchronized
    fun detectGame(gamePath: String): DetectionResult? {
        // Clean up any previous engine
        engine?.cleanup()
        engine = null
        currentScript = null

        if (!scriptsDir.exists()) {
            println("Scripts directory not found: ${scriptsDir.absolutePath}")
            println("  Searched from working dir: ${File(".").absolutePath}")
            return null
        }

        val engineDirs = scriptsDir.listFiles()?.filter { it.isDirectory }?.sorted() ?: return null

        for (engineDir in engineDirs) {
            val scriptFile = File(engineDir, "engine.lua")
            if (!scriptFile.exists()) continue

            try {
                val lua = LuaEngine()
                val script = lua.loadScript(scriptFile.absolutePath)

                val detectFunc = script.get("detect")
                if (detectFunc.isnil()) continue

                val detected = detectFunc.call(LuaValue.valueOf(gamePath))
                if (!detected.toboolean()) {
                    lua.cleanup()
                    continue
                }

                // Game detected!
                engine = lua
                currentScript = script

                val name = script.get("name").optjstring("Unknown Engine")
                val desc = script.get("description").optjstring("")
                val id = script.get("id").optjstring(engineDir.name)

                // Get resource tree
                val resFunc = script.get("get_resources")
                if (resFunc.isnil()) {
                    return DetectionResult(id, name, desc, emptyList())
                }

                val resTable = resFunc.call(LuaValue.valueOf(gamePath))
                val resources = parseLuaResourceTable(resTable.checktable())

                println("Detected engine: $name ($id)")
                println("  Resources: ${resources.sumOf { it.countAll() }} items in ${resources.size} categories")

                return DetectionResult(id, name, desc, resources)

            } catch (e: Exception) {
                println("Error loading engine script ${engineDir.name}: ${e.message}")
                e.printStackTrace()
            }
        }

        return null
    }

    /**
     * Load a specific resource by ID using the currently active engine script.
     * @param paletteId optional palette resource ID to override the default palette when rendering
     */
    @Synchronized
    fun loadResource(gamePath: String, resourceId: String, paletteId: String? = null, textureId: String? = null): ResourceData? {
        val script = currentScript ?: return null
        val lua = engine ?: return null

        try {
            val loadFunc = script.get("load_resource")
            if (loadFunc.isnil()) return null

            val arguments=mutableListOf<LuaValue>(LuaValue.valueOf(gamePath),LuaValue.valueOf(resourceId))
            if (paletteId!=null || textureId!=null) arguments += paletteId?.let { LuaValue.valueOf(it) } ?: LuaValue.NIL
            if (textureId!=null) arguments += LuaValue.valueOf(textureId)
            val result=loadFunc.invoke(LuaValue.varargsOf(arguments.toTypedArray())).arg1()

            if (result.isnil()) return null

            val table = result.checktable()
            val type = table.get("type").optjstring("unknown")
            val description = table.get("description").optjstring(null)

            val resource = when (type) {
                "model" -> ResourceData(type, null, description,
                    modelData = lua.getModel(table.get("model").checkint())?.copy(
                        textureOptions = table.get("texture_options").takeIf { it.istable() }?.let { parseLuaResourceTable(it.checktable()) } ?: emptyList(),
                        selectedTextureId = table.get("texture_id").optjstring(null)))
                "image" -> {
                    val imgHandle = table.get("image").checkint()
                    val image = lua.getImage(imgHandle)
                    ResourceData(type, image, description)
                }
                "animation" -> {
                    val animHandle = table.get("animation").checkint()
                    val anim = lua.getAnimation(animHandle)
                    val delayMs = table.get("delay_ms").optint(anim?.second ?: 100)
                    ResourceData(
                        type = type,
                        image = anim?.first?.firstOrNull(),
                        description = description,
                        frames = anim?.first,
                        frameDelayMs = delayMs
                    )
                }
                "text" -> {
                    val text = table.get("text").optjstring("")
                    ResourceData(type, null, description, textContent = text)
                }
                "sound" -> {
                    val sndHandle = table.get("sound").checkint()
                    val sound = lua.getSound(sndHandle)
                    ResourceData(type, null, description, soundData = sound)
                }
                "midi" -> {
                    val midiHandle = table.get("midi").checkint()
                    val midi = lua.getMidi(midiHandle)
                    ResourceData(type, null, description, midiData = midi)
                }
                else -> ResourceData(type, null, description)
            }
            val paletteHandle = table.get("palette_image")
            return resource.copy(
                paletteImage = if (paletteHandle.isnil()) null else lua.getImage(paletteHandle.checkint()),
                paletteColors = table.get("palette_colors").optint(256).coerceIn(1, 256)
            )
        } catch (e: Exception) {
            println("Error loading resource '$resourceId': ${e.message}")
            e.printStackTrace()
            return null
        }
    }

    /**
     * Ask the active engine script which palette node a resource should be shown with by
     * default (optional `default_palette(game_path, resource_id)` hook). Returns null when the
     * script has no opinion.
     */
    @Synchronized
    fun defaultPaletteFor(gamePath: String, resourceId: String): String? {
        val script = currentScript ?: return null
        return try {
            val fn = script.get("default_palette")
            if (fn.isnil()) return null
            val r = fn.call(LuaValue.valueOf(gamePath), LuaValue.valueOf(resourceId))
            if (r.isnil()) null else r.tojstring()
        } catch (e: Exception) {
            null
        }
    }

    // ── Internal helpers ────────────────────────────────────────────

    private fun parseLuaResourceTable(table: LuaTable): List<ResourceNode> {
        val result = mutableListOf<ResourceNode>()
        var i = 1
        while (true) {
            val entry = table.get(i)
            if (entry.isnil()) break

            val t = entry.checktable()
            val id = t.get("id").optjstring("node_$i")
            val name = t.get("name").optjstring("Unknown")
            val type = t.get("type").optjstring("category")

            val children = if (!t.get("children").isnil()) {
                parseLuaResourceTable(t.get("children").checktable())
            } else {
                emptyList()
            }

            result.add(ResourceNode(id, name, type, children))
            i++
        }
        return result
    }

    companion object {
        /**
         * Resolve the scripts directory. Checks multiple locations:
         * 1. ./scripts/engines/ (development)
         * 2. Relative to JAR location (distribution)
         */
        private fun resolveScriptsDir(): File {
            // Check working directory first (development mode)
            val devDir = File("scripts/engines")
            if (devDir.exists()) return devDir

            // Check relative to class location (packaged)
            val classUrl = ScriptManager::class.java.protectionDomain?.codeSource?.location
            if (classUrl != null) {
                val jarDir = File(classUrl.toURI()).parentFile
                val pkgDir = File(jarDir, "scripts/engines")
                if (pkgDir.exists()) return pkgDir
            }

            // Fallback to working directory
            return devDir
        }
    }
}

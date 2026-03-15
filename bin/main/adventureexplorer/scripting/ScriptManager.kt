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

    private var engine: LuaEngine? = null
    private var currentScript: LuaValue? = null
    private var scriptsDir: File = resolveScriptsDir()

    /**
     * Try to detect a game from the given folder path.
     * Iterates through all engine scripts and calls detect(path) on each.
     */
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
     */
    fun loadResource(gamePath: String, resourceId: String): ResourceData? {
        val script = currentScript ?: return null
        val lua = engine ?: return null

        try {
            val loadFunc = script.get("load_resource")
            if (loadFunc.isnil()) return null

            val result = loadFunc.call(
                LuaValue.valueOf(gamePath),
                LuaValue.valueOf(resourceId)
            )

            if (result.isnil()) return null

            val table = result.checktable()
            val type = table.get("type").optjstring("unknown")
            val description = table.get("description").optjstring(null)

            return when (type) {
                "image" -> {
                    val imgHandle = table.get("image").checkint()
                    val image = lua.getImage(imgHandle)
                    ResourceData(type, image, description)
                }
                "text" -> {
                    val text = table.get("text").optjstring("")
                    ResourceData(type, null, description, textContent = text)
                }
                else -> ResourceData(type, null, description)
            }
        } catch (e: Exception) {
            println("Error loading resource '$resourceId': ${e.message}")
            e.printStackTrace()
            return null
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

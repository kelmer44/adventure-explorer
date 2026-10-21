package adventureexplorer.model

/** Background/sprite roles come from engine labels; decoded types are explicit. */
enum class ExportCategory(val label: String) {
    BACKGROUNDS("Backgrounds"),
    SPRITES("Sprites"),
    UI("UI"),
    ANIMATIONS("Animations"),
    IMAGES("Images (all)"),
    MODELS("3D Models"),
    SOUNDS("Sounds"),
    MUSIC("Music / MIDI"),
    PALETTES("Palettes"),
    TEXT("Text"),
    DATA("Other data")
}

object ResourceCategories {
    private val backgroundWords = Regex("\\b(?:backgrounds?|backdrops?|bg)\\b")
    private val spriteWords = Regex("\\b(?:sprites?|costumes?|actors?|spr|ss)\\b")

    private val uiWords = Regex("\\b(?:ui|user interface)\\b")

    private fun roles(node: ResourceNode): Set<ExportCategory> {
        val label = "${node.id} ${node.name}".lowercase().replace('_', ' ')
        return buildSet {
            if (backgroundWords.containsMatchIn(label)) add(ExportCategory.BACKGROUNDS)
            if (spriteWords.containsMatchIn(label)) add(ExportCategory.SPRITES)
            if (uiWords.containsMatchIn(label)) add(ExportCategory.UI)
        }
    }

    private fun categories(node: ResourceNode, roles: Set<ExportCategory>): Set<ExportCategory> = buildSet {
        when (node.type) {
            "image" -> {
                add(ExportCategory.IMAGES)
                addAll(roles)
            }
            "animation" -> {
                add(ExportCategory.ANIMATIONS)
                addAll(roles)
            }
            "model" -> add(ExportCategory.MODELS)
            "sound" -> add(ExportCategory.SOUNDS)
            "midi" -> add(ExportCategory.MUSIC)
            "palette" -> add(ExportCategory.PALETTES)
            "text" -> add(ExportCategory.TEXT)
            else -> add(ExportCategory.DATA)
        }
    }

    fun counts(nodes: List<ResourceNode>): Map<ExportCategory, Int> {
        val counts = mutableMapOf<ExportCategory, Int>()
        fun walk(node: ResourceNode, inherited: Set<ExportCategory>) {
            val context = inherited + roles(node)
            if (node.isCategory) node.children.forEach { walk(it, context) }
            else categories(node, context).forEach { counts[it] = (counts[it] ?: 0) + 1 }
        }
        nodes.forEach { walk(it, emptySet()) }
        return counts
    }

    /**
     * Keep ancestors of matching resources, pruning all unrelated and empty folders.
     * A null [category] accepts every type. Every whitespace-separated [query] term must
     * appear in the resource's name, its ID or one of its ancestor folder names.
     */
    fun filter(nodes: List<ResourceNode>, category: ExportCategory?, query: String = ""): List<ResourceNode> {
        val terms = query.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (category == null && terms.isEmpty()) return nodes
        fun keep(node: ResourceNode, inherited: Set<ExportCategory>, path: String): ResourceNode? {
            val context = inherited + roles(node)
            return if (node.isCategory) {
                val childPath = "$path ${node.name.lowercase()}"
                val children = node.children.mapNotNull { keep(it, context, childPath) }
                if (children.isEmpty()) null else node.copy(children = children)
            } else node.takeIf {
                val text = "$path ${it.name.lowercase()} ${it.id.lowercase()}"
                (category == null || category in categories(it, context)) && terms.all { term -> term in text }
            }
        }
        return nodes.mapNotNull { keep(it, emptySet(), "") }
    }
}

package adventureexplorer.model

/**
 * A node in the resource tree. Can be a category (folder) or a leaf resource.
 */
data class ResourceNode(
    val id: String,
    val name: String,
    val type: String, // "category", "image", "sound", "text", "palette", "animation", "data"
    val children: List<ResourceNode> = emptyList()
) {
    val isLeaf: Boolean get() = children.isEmpty() && type != "category"
    val isCategory: Boolean get() = type == "category"

    fun countAll(): Int =
        if (isLeaf) 1 else children.sumOf { it.countAll() }
}

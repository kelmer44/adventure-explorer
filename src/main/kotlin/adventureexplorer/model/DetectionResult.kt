package adventureexplorer.model

/**
 * Result of game detection: which engine matched and what resources are available.
 */
data class DetectionResult(
    val engineId: String,
    val engineName: String,
    val engineDescription: String,
    val resources: List<ResourceNode>
)

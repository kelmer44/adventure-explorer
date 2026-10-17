package adventureexplorer.model

/** Static geometry in world coordinates (Z up). Faces retain their polygon boundaries. */
data class ModelVertex(val x: Double, val y: Double, val z: Double)
data class ModelFace(val indices: List<Int>, val material: Int = 0)
data class ModelData(val vertices: List<ModelVertex>, val faces: List<ModelFace>, val meshCount: Int)

package adventureexplorer.model

/** Static geometry in world coordinates (Z up). Faces retain their polygon boundaries. */
data class ModelUv(val u: Double, val v: Double)
data class ModelVertex(val x: Double, val y: Double, val z: Double)
data class ModelFace(val indices: List<Int>, val material: Int = 0, val rgb: Int? = null,
                     val uvs: List<ModelUv> = emptyList())
data class ModelLine(val start: Int, val end: Int, val rgb: Int)
data class ModelData(val vertices: List<ModelVertex>, val faces: List<ModelFace>, val meshCount: Int,
                     val lines: List<ModelLine> = emptyList(),
                     val materialNames: List<String> = emptyList(),
                     val textures: Map<Int, java.awt.image.BufferedImage> = emptyMap(),
                     val textureOptions: List<ResourceNode> = emptyList(),
                     val selectedTextureId: String? = null)

package adventureexplorer.models

import adventureexplorer.model.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*

/** Original PC 3DO layouts, checked against engines/grim/model.cpp in ScummVM.
 * Only the first geoset is assembled, using the stored hierarchy's default pose.
 */
object GrimModelDecoder {
    private const val LIMIT = 100_000
    private data class Mesh(val vertices: List<ModelVertex>, val faces: List<ModelFace>)
    private data class Node(val mesh: Int, val parent: Int, val pos: ModelVertex,
                            val pivot: ModelVertex, val pitch: Double, val yaw: Double, val roll: Double)
    private data class Parsed(val meshes: List<Mesh>, val nodes: List<Node>, val materials: List<String>)

    fun decode(bytes: ByteArray): ModelData {
        require(bytes.size <= 16_000_000) { "Model exceeds preview limit" }
        val (meshes, nodes, materials) = if (bytes.take(4).toByteArray().toString(Charsets.US_ASCII) == "LDOM")
            binary(bytes) else text(bytes.toString(Charsets.ISO_8859_1))
        require(nodes.size <= 4096) { "Too many hierarchy nodes" }
        require(nodes.all { it.mesh in -1 until meshes.size && it.parent in -1 until nodes.size }) { "Invalid hierarchy index" }
        val vertices = mutableListOf<ModelVertex>()
        val faces = mutableListOf<ModelFace>()
        var count = 0
        for ((index, node) in nodes.withIndex()) {
            if (node.mesh < 0) continue
            val chain = mutableListOf<Node>()
            val visited = mutableSetOf<Int>()
            var current = index
            while (current >= 0) {
                require(visited.add(current)) { "Cyclic model hierarchy" }
                chain += nodes[current]
                current = nodes[current].parent
            }
            val mesh = meshes[node.mesh]
            val offset = vertices.size
            require(offset + mesh.vertices.size <= LIMIT && faces.size + mesh.faces.size <= LIMIT) { "Model exceeds geometry limit" }
            vertices += mesh.vertices.map { v ->
                var p = add(v, node.pivot)
                for (n in chain) p = add(rotate(p, n), n.pos)
                require(listOf(p.x, p.y, p.z).all { it.isFinite() && abs(it) < 1e12 }) { "Invalid transformed vertex" }
                p
            }
            faces += mesh.faces.map { f -> f.copy(indices = f.indices.map { it + offset }) }
            count++
        }
        require(vertices.isNotEmpty() && faces.isNotEmpty()) { "Model has no visible geometry" }
        return ModelData(vertices, faces, count, materialNames = materials)
    }

    private fun add(a: ModelVertex, b: ModelVertex) = ModelVertex(a.x+b.x, a.y+b.y, a.z+b.z)
    // Euler ZXY: yaw about Z, pitch about X, roll about Y; Rz * Rx * Ry.
    private fun rotate(v: ModelVertex, n: Node): ModelVertex {
        val p = Math.toRadians(n.pitch); val y = Math.toRadians(n.yaw); val r = Math.toRadians(n.roll)
        val x1 = cos(r)*v.x + sin(r)*v.z; val z1 = -sin(r)*v.x + cos(r)*v.z
        val y2 = cos(p)*v.y - sin(p)*z1; val z2 = sin(p)*v.y + cos(p)*z1
        return ModelVertex(cos(y)*x1 - sin(y)*y2, sin(y)*x1 + cos(y)*y2, z2)
    }

    private class Reader(bytes: ByteArray) {
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun skip(n: Int) { require(n >= 0 && n <= b.remaining()) { "Truncated 3DO" }; b.position(b.position()+n) }
        fun int(): Int { require(b.remaining() >= 4) { "Truncated 3DO" }; return b.int }
        fun count(max: Int = LIMIT): Int = int().also { require(it in 0..max) { "Invalid 3DO count" } }
        fun float(): Double { require(b.remaining() >= 4) { "Truncated 3DO" }; return b.float.toDouble().also { require(it.isFinite()) { "Invalid 3DO float" } } }
        fun vec() = ModelVertex(float(), float(), float())
    }
    private fun binary(bytes: ByteArray): Parsed {
        val r = Reader(bytes); r.skip(4)
        val materials = List(r.count(4096)) {
            val name = ByteArray(32); r.b.get(name)
            name.toString(Charsets.ISO_8859_1).substringBefore('\u0000').lowercase()
        }
        r.skip(36)
        val geosets = r.count(64)
        require(geosets > 0) { "No geosets" }
        var first = emptyList<Mesh>()
        repeat(geosets) { gi ->
            val meshes = List(r.count(4096)) {
                r.skip(48)
                val nv = r.count(); val nt = r.count(); val nf = r.count()
                val vertices = List(nv) { r.vec() }
                val uvs = List(nt) { ModelUv(r.float(), r.float()) }
                r.skip(nv*8) // intensities, reserved
                val faces = List(nf) {
                    r.skip(20); val n = r.count(4096); r.skip(4)
                    val tex = r.int(); val mat = r.int()
                    r.skip(40)
                    val indices = List(n) { r.int().also { require(it in vertices.indices) { "Invalid vertex index" } } }
                    val faceUvs = if (tex != 0) List(n) {
                        val uv = r.int(); require(uv in uvs.indices) { "Invalid texture vertex index" }; uvs[uv]
                    } else emptyList()
                    val material = if (mat != 0) r.int() else 0
                    require(n >= 3) { "Invalid polygon" }
                    ModelFace(indices, material, uvs = faceUvs)
                }
                r.skip(nv*12 + 36)
                Mesh(vertices, faces)
            }
            if (gi == 0) first = meshes
        }
        r.skip(4)
        val nodes = List(r.count(4096)) {
            r.skip(76); val mesh = r.int(); r.skip(4)
            val parentPtr = r.int(); r.skip(4); val childPtr = r.int(); val siblingPtr = r.int()
            val pivot = r.vec(); val pos = r.vec()
            val pitch = r.float(); val yaw = r.float(); val roll = r.float()
            r.skip(48)
            val parent = if (parentPtr != 0) r.int() else -1
            if (childPtr != 0) r.int()
            if (siblingPtr != 0) r.int()
            Node(mesh, parent, pos, pivot, pitch, yaw, roll)
        }
        r.skip(40); r.vec() // radius, reserved, insertion offset
        return Parsed(first, nodes, materials)
    }

    private fun text(source: String): Parsed {
        val lines = source.lineSequence().map { it.substringBefore('#').trim().lowercase().replace(Regex("\\s+"), " ") }.filter { it.isNotEmpty() }.toList()
        var cursor = 0
        fun line(): String { require(cursor < lines.size) { "Truncated text 3DO" }; return lines[cursor++] }
        fun expect(prefix: String): List<String> {
            val s = line(); require(s == prefix || s.startsWith("$prefix ")) { "Expected $prefix" }
            return s.removePrefix(prefix).trim().split(Regex("\\s+"))
        }
        fun count(prefix: String, max: Int = LIMIT) = expect(prefix)[0].toInt().also { require(it in 0..max) { "Invalid $prefix count" } }
        fun record(i: Int): List<String> {
            val s = line(); require(s.substringBefore(':').trim().toInt() == i) { "Unexpected record index" }
            return s.substringAfter(':').replace(',', ' ').trim().split(Regex("\\s+"))
        }
        fun number(s: String) = s.toDouble().also { require(it.isFinite()) { "Invalid 3DO number" } }
        fun vec(t: List<String>, start: Int = 0) = ModelVertex(number(t[start]), number(t[start+1]), number(t[start+2]))
        expect("section: header"); expect("3do")
        expect("section: modelresource")
        val materials = List(count("materials", 4096)) { record(it)[0] }
        expect("section: geometrydef"); expect("radius"); expect("insert offset")
        val geosets = count("geosets", 64); require(geosets > 0)
        var first = emptyList<Mesh>()
        repeat(geosets) { gi ->
            expect("geoset")
            val meshes = List(count("meshes", 4096)) {
                expect("mesh"); expect("name"); expect("radius")
                if (lines.getOrNull(cursor)?.startsWith("shadow ") == true) line()
                expect("geometrymode"); expect("lightingmode"); expect("texturemode")
                val nv = count("vertices")
                val vertices = List(nv) { vec(record(it)) }
                val uvs = List(count("texture vertices")) { val t=record(it); ModelUv(number(t[0]),number(t[1])) }
                expect("vertex normals"); repeat(nv) { record(it) }
                val nf = count("faces")
                val faces = List(nf) {
                    val t = record(it); val n = t[6].toInt()
                    require(n in 3..4096 && t.size >= 7+n*2) { "Invalid face" }
                    val indices = List(n) { j -> t[7+j*2].toInt().also { require(it in vertices.indices) { "Invalid vertex index" } } }
                    val faceUvs = if (uvs.isEmpty()) emptyList() else List(n) { j ->
                        val uv=t[8+j*2].toInt(); require(uv in uvs.indices) { "Invalid texture vertex index" }; uvs[uv]
                    }
                    ModelFace(indices, t[0].toInt(), uvs=faceUvs)
                }
                expect("face normals"); repeat(nf) { record(it) }
                Mesh(vertices, faces)
            }
            if (gi == 0) first = meshes
        }
        expect("section: hierarchydef")
        val nodes = List(count("hierarchy nodes", 4096)) {
            val t = record(it)
            Node(t[2].toInt(), t[3].toInt(), vec(t,7), vec(t,13), number(t[10]), number(t[11]), number(t[12]))
        }
        return Parsed(first, nodes, materials)
    }
}

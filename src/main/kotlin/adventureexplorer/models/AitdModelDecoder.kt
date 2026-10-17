package adventureexplorer.models

import adventureexplorer.model.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*

/** PAK body member layout checked against FITD createBodyFromPtr / AnimNuage.
 * Assembles the body's stored pose, without selecting an animation from LISTANIM.
 */
object AitdModelDecoder {
    private data class Bone(val start: Int, val count: Int, val base: Int, val parent: Int,
                            val id: Int, val type: Int, val delta: ModelVertex, val rotation: ModelVertex)
    private data class Marker(val index: Int, val radius: Double, val color: Int)

    fun decode(bytes: ByteArray, palette: IntArray? = null): ModelData {
        require(bytes.size in 18..4_000_000) { "Invalid AITD body size" }
        require(palette == null || palette.size == 256) { "Invalid model palette" }
        val b=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun skip(n: Int) { require(n >= 0 && n <= b.remaining()) { "Truncated AITD body" }; b.position(b.position()+n) }
        fun u8(): Int { require(b.remaining() >= 1) { "Truncated AITD body" }; return b.get().toInt() and 255 }
        fun u16(): Int { require(b.remaining() >= 2) { "Truncated AITD body" }; return b.short.toInt() and 65535 }
        fun s16(): Int = u16().toShort().toInt()
        fun vec() = ModelVertex(s16().toDouble(),s16().toDouble(),s16().toDouble())
        val flags=u16(); require(flags and 4 == 0) { "Unsupported tortue body layout" }
        skip(12); skip(u16())
        val nv=u16(); require(nv in 1..10000) { "Invalid body vertex count" }
        val vertices=MutableList(nv) { vec() }
        fun vertexOffset(offset: Int): Int {
            require(offset % 6 == 0 && offset/6 in 0 until nv) { "Invalid body vertex reference" }
            return offset/6
        }
        val optimized=flags and 8 != 0
        if (flags and 2 != 0) {
            val nb=u16(); require(nb in 1..256) { "Invalid bone count" }
            val stride=if (optimized) 24 else 16
            val order=List(nb) {
                val offset=u16(); require(offset%stride == 0 && offset/stride in 0 until nb) { "Invalid bone order" }; offset/stride
            }
            require(order.toSet().size==nb) { "Duplicate bone order" }
            val bones=List(nb) {
                val start=vertexOffset(u16()); val count=u16(); val base=vertexOffset(u16())
                require(count<=nv-start) { "Invalid bone vertex range" }
                val parent=u8().toByte().toInt(); val id=u8().toByte().toInt(); val type=s16(); val delta=vec()
                val rotation=if (optimized) vec().also { skip(2) } else delta
                Bone(start,count,base,parent,id,type,delta,rotation)
            }
            val byId=bones.associateBy { it.id }
            fun descendant(child: Bone, ancestor: Bone): Boolean {
                var current=child
                val visited=mutableSetOf<Int>()
                while (true) {
                    if (current==ancestor) return true
                    require(visited.add(current.id)) { "Cyclic body skeleton" }
                    if (current.parent==current.id) return false
                    current=byId[current.parent] ?: return false
                }
            }
            fun apply(bone: Bone, transform: (ModelVertex) -> ModelVertex) {
                for (i in bone.start until bone.start+bone.count) vertices[i]=transform(vertices[i])
            }
            for (index in order) {
                val bone=bones[index]
                // Original renderer uses group zero for the preview's global rotation.
                if (optimized || index!=0) when (bone.type) {
                    0 -> if (!optimized) for (child in bones) {
                        if (descendant(child,bone)) apply(child) { rotate(it,bone.delta) }
                    }
                    1 -> apply(bone) { add(it,bone.delta) }
                    2 -> apply(bone) { ModelVertex(it.x*(bone.delta.x+256)/256,
                        it.y*(bone.delta.y+256)/256,it.z*(bone.delta.z+256)/256) }
                }
                if (optimized && bone.id!=0) apply(bone) { rotate(it,bone.rotation) }
            }
            for (bone in bones) for (i in bone.start until bone.start+bone.count) vertices[i]=add(vertices[i],vertices[bone.base])
        }
        // Game Y points down; shared viewer uses Z up.
        for (i in vertices.indices) { val v=vertices[i]; vertices[i]=ModelVertex(v.x,v.z,-v.y) }
        val faces=mutableListOf<ModelFace>(); val lines=mutableListOf<ModelLine>(); val markers=mutableListOf<Marker>()
        fun color(index: Int) = palette?.get(index) ?: ((index shl 16) or (index shl 8) or index)
        val np=u16(); require(np<=10000) { "Too many body primitives" }
        repeat(np) {
            val type=u8()
            if (type in listOf(1,8,9,10)) {
                val n=u8(); u8(); val rgb=color(u8())
                require(n in 3..64) { "Invalid body polygon" }
                val indices=List(n) { vertexOffset(u16()) }
                if (type==9 || type==10) skip(n*2)
                faces += ModelFace(indices, rgb=rgb)
            } else {
                require(type in listOf(0,2,3,6,7)) { "Unsupported body primitive $type" }
                u8(); val rgb=color(u8()); u8()
                when (type) {
                    0 -> lines += ModelLine(vertexOffset(u16()),vertexOffset(u16()),rgb)
                    3 -> { val radius=u16().toDouble(); markers += Marker(vertexOffset(u16()),radius,rgb) }
                    else -> markers += Marker(vertexOffset(u16()),if (type==6) 3.0 else 1.0,rgb)
                }
            }
        }
        // Sphere/point primitives become small surface meshes so orbit and depth work consistently.
        for (marker in markers) {
            require(vertices.size+70 <= 100_000) { "Body exceeds preview geometry limit" }
            val center=vertices[marker.index]; val offset=vertices.size
            val radius=marker.radius.coerceAtLeast(1.0)
            for (ring in 0..6) for (j in 0 until 10) {
                val lat=PI*ring/6; val lon=2*PI*j/10
                vertices += ModelVertex(center.x+radius*sin(lat)*cos(lon),center.y+radius*sin(lat)*sin(lon),center.z+radius*cos(lat))
            }
            for (ring in 0 until 6) for (j in 0 until 10) {
                val a=offset+ring*10+j; val c=offset+ring*10+(j+1)%10
                faces += ModelFace(listOf(a,c,c+10,a+10),rgb=marker.color)
            }
        }
        require(faces.isNotEmpty() || lines.isNotEmpty()) { "Model has no visible geometry" }
        require(vertices.all { it.x.isFinite() && it.y.isFinite() && it.z.isFinite() }) { "Invalid body pose" }
        return ModelData(vertices,faces,1,lines)
    }

    private fun add(a: ModelVertex,b: ModelVertex)=ModelVertex(a.x+b.x,a.y+b.y,a.z+b.z)
    private fun rotate(v: ModelVertex,angles: ModelVertex): ModelVertex {
        val x=angles.x*2*PI/1024; val y=angles.y*2*PI/1024; val z=angles.z*2*PI/1024
        val xx=cos(y)*v.x-sin(y)*v.z; val zz=sin(y)*v.x+cos(y)*v.z
        val yy=cos(x)*v.y-sin(x)*zz; val z2=sin(x)*v.y+cos(x)*zz
        return ModelVertex(cos(z)*xx-sin(z)*yy,sin(z)*xx+cos(z)*yy,z2)
    }
}

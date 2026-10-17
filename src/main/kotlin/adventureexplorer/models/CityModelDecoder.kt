package adventureexplorer.models

import adventureexplorer.model.*
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** City's PC .TMM assets use the relative-pointer Sony TMD layout (ID 0x41).
 * Character vertices are in bone space; CityModelPose assembles their SKL/ENV/ANI pose.
 */
object CityModelDecoder {
    fun decode(bytes: ByteArray): ModelData {
        require(bytes.size in 40..16_000_000) { "Invalid TMM size" }
        val b=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun range(offset: Int, size: Int) { require(offset >= 0 && size >= 0 && offset.toLong()+size<=bytes.size) { "Truncated TMM" } }
        fun int(p: Int): Int { range(p,4); return b.getInt(p) }
        fun short(p: Int): Int { range(p,2); return b.getShort(p).toInt() and 65535 }
        fun pointer(p: Int): Int { val v=int(p); require(v in 0..bytes.size-12) { "Invalid TMM pointer" }; return v+12 }
        fun count(p: Int): Int = int(p).also { require(it in 0..100_000) { "Invalid TMM count" } }
        require(int(0)==0x41 && int(4)==0) { "Unsupported TMM header" }
        val objects=count(8); require(objects in 1..4096); range(12,objects*28)
        val vertices=mutableListOf<ModelVertex>(); val faces=mutableListOf<ModelFace>()
        repeat(objects) { obj ->
            val h=12+obj*28; val vo=pointer(h); val nv=count(h+4)
            val no=pointer(h+8); val nn=count(h+12)
            var p=pointer(h+16); val nf=count(h+20)
            require(int(h+24)==0) { "Unsupported TMM scale" }
            range(vo,nv*8); range(no,nn*8)
            require(vertices.size+nv<=100_000 && faces.size+nf<=100_000) { "TMM exceeds geometry limit" }
            val base=vertices.size
            repeat(nv) { i ->
                val v=vo+i*8
                // City uses Z up, including its skeleton offsets and camera projection.
                vertices += ModelVertex(b.getShort(v).toDouble(),b.getShort(v+2).toDouble(),b.getShort(v+4).toDouble())
            }
            repeat(nf) {
                range(p,4)
                val words=bytes[p+1].toInt() and 255; val flag=bytes[p+2].toInt() and 255
                val mode=bytes[p+3].toInt() and 255
                range(p+4,words*4)
                val indices = when {
                    mode==0x34 && flag==0 && words==6 -> List(3) { short(p+18+it*4) }
                    mode==0x35 && flag==1 && words==8 -> List(3) { short(p+28+it*2) }
                    mode==0x24 && flag==0 && words==5 -> listOf(short(p+18),short(p+20),short(p+22))
                    mode==0x30 && flag==0 && words==4 -> List(3) { short(p+10+it*4) }
                    else -> error("Unsupported TMM primitive 0x${mode.toString(16)}")
                }
                require(indices.all { it in 0 until nv }) { "Invalid TMM vertex index" }
                val uvs=if (mode and 4 != 0) List(3) { j ->
                    val u=bytes[p+4+j*4].toInt() and 255
                    val v=(bytes[p+5+j*4].toInt() and 255) + ((short(p+10) shr 4) and 1)*256
                    ModelUv(u.toDouble(),v.toDouble())
                } else emptyList()
                faces += ModelFace(indices.map { it+base },obj,uvs=uvs)
                p+=4+words*4
            }
        }
        require(vertices.isNotEmpty() && faces.isNotEmpty()) { "Empty TMM geometry" }
        return ModelData(vertices,faces,objects)
    }
}

package adventureexplorer.models

import adventureexplorer.model.*
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** First stored ANI pose. Layout and transforms checked in CITE.EXE (PC release). */
object CityModelPose {
    fun apply(model: ModelData, skeleton: ByteArray, envelope: ByteArray, animation: ByteArray): ModelData {
        fun buffer(bytes: ByteArray)=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val s=buffer(skeleton); val e=buffer(envelope); val a=buffer(animation)
        fun range(b: ByteBuffer,p: Int,n: Int) { require(p>=0 && n>=0 && p.toLong()+n<=b.limit()) { "Truncated City skeleton/pose" } }
        fun u16(b: ByteBuffer,p: Int): Int { range(b,p,2);return b.getShort(p).toInt() and 65535 }
        fun i32(b: ByteBuffer,p: Int): Int { range(b,p,4);return b.getInt(p) }
        val n=u16(s,2);require(n in 1..256 && i32(e,4)==n) { "Invalid skeleton count" }
        range(s,4,n*8);range(e,12,n*12)
        range(a,0,8);require(animation.copyOfRange(0,4).toString(Charsets.US_ASCII)=="ANI0")
        val clips=i32(a,4);require(clips in 1..4096)
        val start=8+clips*4;range(a,start,12)
        require(u16(a,start+4)==n) { "Pose and skeleton bone counts differ" }
        val frames=u16(a,start+6);require(frames>0)
        val matrices=start+12+(frames+1)*8;range(a,matrices,n*20)
        val vertices=model.vertices.toMutableList();val assigned=BooleanArray(vertices.size);val visited=BooleanArray(n)
        fun mul(m: DoubleArray,v: DoubleArray)=DoubleArray(3) { r -> (0..2).sumOf { c -> m[r*3+c]*v[c] } }
        fun walk(index: Int,parent: DoubleArray,origin: DoubleArray) {
            require(index in 0 until n && !visited[index]) { "Invalid City bone hierarchy" };visited[index]=true
            val p=4+index*8
            val local=DoubleArray(9) { a.getShort(matrices+index*20+it*2).toDouble()/4096 }
            val world=DoubleArray(9) { k -> (0..2).sumOf { c -> parent[(k/3)*3+c]*local[c*3+k%3] } }
            val offset=if (index==0) DoubleArray(3) else mul(parent,DoubleArray(3) { s.getShort(p+it*2).toDouble() })
            val pos=DoubleArray(3) { origin[it]+offset[it] }
            val count=u16(e,12+index*12);val first=u16(e,14+index*12)
            require(first<=vertices.size && count<=vertices.size-first) { "Invalid City envelope range" }
            for (i in first until first+count) {
                require(!assigned[i]) { "Overlapping City envelope ranges" };assigned[i]=true
                val v=model.vertices[i];val transformed=mul(world,doubleArrayOf(v.x,v.y,v.z))
                vertices[i]=ModelVertex(transformed[0]+pos[0],transformed[1]+pos[1],transformed[2]+pos[2])
            }
            val children=s.get(p+6).toInt() and 255;val child=s.get(p+7).toInt() and 255
            require(children<=n && child+children<=n) { "Invalid City child range" }
            repeat(children) { walk(child+it,world,pos) }
        }
        walk(0,doubleArrayOf(1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0),DoubleArray(3))
        require(assigned.all { it }) { "City pose does not cover all vertices" }
        return model.copy(vertices=vertices,meshCount=n)
    }
}

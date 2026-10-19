package adventureexplorer.models

import adventureexplorer.model.*
import java.awt.image.BufferedImage
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*

/** LBA2 v0x10 grouped polygons, direct vertex indices and hierarchical local bone coordinates. */
object Lba2ModelDecoder {
    fun decode(bytes: ByteArray, palette: IntArray, atlas: ByteArray? = null): ModelData {
        require(bytes.size in 96..8_000_000 && palette.size==256) { "Invalid LBA2 body" }
        require(atlas==null || atlas.size==65536) { "Invalid LBA2 texture atlas" }
        val b=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun u8(p: Int) = b.get(p).toInt() and 255
        fun u16(p: Int) = b.getShort(p).toInt() and 65535
        fun s16(p: Int) = b.getShort(p).toInt()
        fun range(p: Int,n: Int) { require(p>=0 && n>=0 && p<=bytes.size-n) { "Truncated LBA2 body section" } }
        fun section(p: Int,stride: Int): Pair<Int,Int> {
            val count=b.getInt(p);val offset=b.getInt(p+4)
            require(count in 0..100000 && offset>=96) { "Invalid LBA2 section" }
            range(offset,Math.multiplyExact(count,stride));return count to offset
        }
        require(u8(0)==0x10 && u16(4)==96) { "Unsupported LBA2 model version" }
        val (nb,ob)=section(32,8);val (nv,ov)=section(40,8)
        require(nv in 1..30000 && nb in 1..1024) { "Invalid LBA2 vertex/bone count" }
        val raw=List(nv) { i -> val p=ov+i*8;ModelVertex(s16(p).toDouble(),s16(p+2).toDouble(),s16(p+4).toDouble()) }
        val parents=IntArray(nb) { u16(ob+it*8) };val anchors=IntArray(nb) { u16(ob+it*8+2) }
        val offsets=arrayOfNulls<ModelVertex>(nb);val active=BooleanArray(nb)
        fun add(a: ModelVertex,c: ModelVertex) = ModelVertex(a.x+c.x,a.y+c.y,a.z+c.z)
        fun bone(i: Int): ModelVertex {
            require(i in 0 until nb && !active[i]) { "Invalid or cyclic LBA2 skeleton" }
            offsets[i]?.let { return it };active[i]=true
            val result=if (parents[i]==65535) ModelVertex(0.0,0.0,0.0) else {
                require(anchors[i] in raw.indices) { "Invalid bone anchor" };add(bone(parents[i]),raw[anchors[i]])
            }
            active[i]=false;offsets[i]=result;return result
        }
        val vertices=MutableList(nv) { i ->
            val v=add(raw[i],bone(u16(ov+i*8+6)));ModelVertex(v.x,v.z,v.y)
        }
        fun vertex(i: Int): Int { require(i in 0 until nv) { "Invalid LBA2 vertex index" };return i }
        val (np,op)=section(64,0);val (nl,ol)=section(72,8);val (ns,os)=section(80,8)
        val (nt,ot)=section(88,4)
        require(ol>=op) { "Invalid polygon section end" }
        range(op,ol-op)
        val textures=mutableMapOf<Int,BufferedImage>()
        fun texture(group: Int): Int {
            require(group in 0 until nt) { "Invalid LBA2 UV group" }
            if (atlas!=null && group !in textures) {
                val p=ot+group*4;val x=u8(p);val y=u8(p+1);val w=u8(p+2)+1;val h=u8(p+3)+1
                require(x+w<=256 && y+h<=256) { "Invalid LBA2 texture rectangle" }
                val image=BufferedImage(w,h,BufferedImage.TYPE_INT_ARGB)
                for (yy in 0 until h) for (xx in 0 until w) {
                    val c=atlas[(y+yy)*256+x+xx].toInt() and 255
                    image.setRGB(xx,yy,if(c==0) 0 else 0xff000000.toInt() or palette[c])
                }
                textures[group]=image
            }
            return group
        }
        val faces=mutableListOf<ModelFace>();var p=op
        while (p<ol) {
            range(p,8);val type=u16(p);val count=u16(p+2);val size=u16(p+4)
            require(count>0 && size>=8 && (size-8)%count==0 && size<=ol-p) { "Invalid LBA2 polygon group" }
            val stride=(size-8)/count;val n=if(type and 0x8000!=0) 4 else 3
            require(stride>=12) { "Short LBA2 polygon" }
            val textured=(type and 255)>7 && stride>16
            if(textured) require(stride>=if(n==4) 32 else 24) { "Short textured polygon" }
            for (j in 0 until count) {
                val q=p+8+j*stride
                val indices=List(n) { vertex(u16(q+it*2)) }
                val group=if(textured) texture(u8(q+if(n==3) 6 else 28)) else -1
                val uvs=if(textured) List(n) { ModelUv(u8(q+13+it*4).toDouble(),u8(q+15+it*4).toDouble()) } else emptyList()
                faces+=ModelFace(indices,group,palette[u8(q+8)],uvs)
            }
            p+=size
        }
        require(faces.size==np) { "LBA2 polygon count mismatch" }
        val lines=List(nl) { i -> val q=ol+i*8;ModelLine(vertex(u16(q+4)),vertex(u16(q+6)),palette[u8(q+2)]) }
        repeat(ns) { i ->
            val q=os+i*8;val center=vertices[vertex(u16(q+4))];val radius=u16(q+6).toDouble();val rgb=palette[u8(q+2)]
            if(radius>0) {
                require(vertices.size+70<=100000) { "Too many sphere vertices" }
                val start=vertices.size
                for(ring in 0..6) for(j in 0 until 10) {
                    val lat=PI*ring/6;val lon=2*PI*j/10
                    vertices+=ModelVertex(center.x+radius*sin(lat)*cos(lon),center.y+radius*sin(lat)*sin(lon),center.z+radius*cos(lat))
                }
                for(ring in 0 until 6) for(j in 0 until 10) {
                    val a=start+ring*10+j;val c=start+ring*10+(j+1)%10
                    faces+=ModelFace(listOf(a,c,c+10,a+10),-1,rgb)
                }
            }
        }
        require(faces.isNotEmpty() || lines.isNotEmpty()) { "Model has no visible geometry" }
        return ModelData(vertices,faces,1,lines,textures=textures)
    }
}

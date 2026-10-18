package adventureexplorer.models

import adventureexplorer.model.*

/** Cruise type-0 SET entries are ordered 2D vector poses, including mirrored references. */
object CruiseModelDecoder {
    fun decode(bytes: ByteArray, frame: Int, palette: IntArray? = null): ModelData {
        require(bytes.size in 6..16_777_216) { "Invalid Cruise SET size" }
        fun range(p: Int, n: Int) { require(p >= 0 && n >= 0 && p.toLong()+n <= bytes.size) { "Truncated Cruise SET" } }
        fun u8(p: Int): Int { range(p,1); return bytes[p].toInt() and 255 }
        fun u16(p: Int) = u8(p)*256+u8(p+1)
        fun s16(p: Int) = u16(p).toShort().toInt()
        fun u32(p: Int): Long = u16(p).toLong()*65536+u16(p+2)
        require(String(bytes,0,3,Charsets.US_ASCII) in listOf("SET","SEC")) { "Missing Cruise SET signature" }
        val count=u16(4)
        require(count in 1..4096 && frame in 0 until count) { "Invalid Cruise frame index" }
        val start=6+count*16; range(6,count*16)
        fun entry(index: Int): Pair<Int,Int> {
            require(index in 0 until count) { "Invalid Cruise mirrored frame reference" }
            val p=6+index*16
            require(u16(p+8)==0) { "Cruise frame is not a polygon pose" }
            val offset=u32(p)
            require(offset<=bytes.size-start) { "Invalid Cruise polygon offset" }
            val size=u16(p+4).toLong()*u16(p+6)
            require(size in 2..(bytes.size-start-offset)) { "Invalid Cruise polygon size" }
            return (start+offset.toInt()) to size.toInt()
        }
        var (base,size)=entry(frame)
        var mirror=false; var dx=0; var dy=0
        if (u16(base)==0) {
            require(size>=8) { "Truncated Cruise mirrored pose" }
            val target=frame+s16(base+2)
            dx=s16(base+4); dy=s16(base+6)
            val resolved=entry(target); base=resolved.first;size=resolved.second
            require(u16(base)!=0) { "Cyclic or nested Cruise mirrored pose" }
            mirror=true
        }
        val end=base+size
        fun poseRange(p: Int,n: Int) { require(p>=base && n>=0 && p.toLong()+n<=end) { "Truncated Cruise polygon pose" } }
        poseRange(base,6)
        val points=u8(base+5)
        require(points in 2..255) { "Invalid Cruise point count" }
        poseRange(base+6,points*2)
        val anchorX=u8(base+3);val anchorY=u8(base+4)
        val vertices=List(points) { i ->
            val x=u8(base+6+i*2)-anchorX
            val y=u8(base+7+i*2)-anchorY
            ModelVertex((if(mirror) -x-dx else x).toDouble(),0.0,(-y+dy).toDouble())
        }
        val faces=mutableListOf<ModelFace>()
        var p=base+6+points*2
        var commands=0
        while (true) {
            poseRange(p,1)
            val n=u8(p)
            if (n==255) break
            require(++commands<=4096) { "Too many Cruise polygon commands" }
            poseRange(p,5)
            val color=u8(p+1);val minimumScale=u16(p+3)
            p+=5
            if (n>1) {
                poseRange(p,n)
                val indices=List(n) { u8(p+it) }
                require(indices.all { it<points }) { "Invalid Cruise polygon vertex index" }
                if (minimumScale<=512) {
                    val rgb=palette?.getOrNull(color) ?: (color*0x010101)
                    // Two-point commands are lines; preserving their place in this list
                    // also preserves interleaving with filled and concave polygons.
                    faces += ModelFace(indices,material=color,rgb=rgb)
                }
                p+=n
            }
        }
        return ModelData(vertices,faces,1,planar=true)
    }
}

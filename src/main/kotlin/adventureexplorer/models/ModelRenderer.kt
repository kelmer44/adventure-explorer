package adventureexplorer.models

import adventureexplorer.model.ModelData
import java.awt.image.BufferedImage
import kotlin.math.*

/** Small orthographic software renderer: no GPU/native dependency, usable in headless exports. */
object ModelRenderer {
    fun render(model: ModelData, width: Int = 800, height: Int = 600,
               yaw: Double = if (model.planar) 0.0 else 25.0, pitch: Double = if (model.planar) 0.0 else 10.0, zoom: Double = 1.0,
               wireframe: Boolean = false): BufferedImage {
        require(width in 1..2048 && height in 1..2048)
        require(yaw.isFinite() && pitch.isFinite() && zoom.isFinite() && zoom > 0)
        val vertices = model.vertices
        require(vertices.isNotEmpty())
        val cx = (vertices.minOf { it.x } + vertices.maxOf { it.x })/2
        val cy = (vertices.minOf { it.y } + vertices.maxOf { it.y })/2
        val cz = (vertices.minOf { it.z } + vertices.maxOf { it.z })/2
        val radius = vertices.maxOf { sqrt((it.x-cx).pow(2)+(it.y-cy).pow(2)+(it.z-cz).pow(2)) }.coerceAtLeast(1e-9)
        val scale = min(width,height)*0.43/radius*zoom.coerceIn(0.1,5.0)
        val a = Math.toRadians(yaw); val b = Math.toRadians(pitch)
        val points = vertices.map {
            val x = (it.x-cx)/radius; val y = (it.y-cy)/radius; val z = (it.z-cz)/radius
            val xx = cos(a)*x-sin(a)*y; val yy = sin(a)*x+cos(a)*y
            doubleArrayOf(width/2.0+xx*scale*radius,
                height/2.0-(cos(b)*z-sin(b)*yy)*scale*radius, cos(b)*yy+sin(b)*z)
        }
        if (model.planar) {
            // Cruise poses are painter-ordered vector artwork. Java2D preserves
            // concave boundaries, exact colours and line/polygon interleaving.
            val image=BufferedImage(width,height,BufferedImage.TYPE_INT_RGB)
            val g=image.createGraphics()
            try {
                g.color=java.awt.Color(0x1A1D24);g.fillRect(0,0,width,height)
                for (face in model.faces) {
                    val xs=face.indices.map { points[it][0].roundToInt() }.toIntArray()
                    val ys=face.indices.map { points[it][1].roundToInt() }.toIntArray()
                    g.color=java.awt.Color(if (wireframe) 0xA6D8F5 else face.rgb ?: 0xFFFFFF)
                    if (xs.size==2) g.drawLine(xs[0],ys[0],xs[1],ys[1])
                    else if (wireframe) g.drawPolygon(xs,ys,xs.size)
                    else g.fillPolygon(xs,ys,xs.size)
                }
            } finally { g.dispose() }
            return image
        }
        val pixels = IntArray(width*height) { 0xFF1A1D24.toInt() }
        val depth = DoubleArray(pixels.size) { Double.POSITIVE_INFINITY }
        val colors = intArrayOf(0x86B5D9,0xDBAE82,0x95C3AE,0xB4A1D8,0xD38E95,0xC1C78C)
        fun triangle(p: DoubleArray, q: DoubleArray, r: DoubleArray, color: Int, texture: BufferedImage? = null, uv: List<adventureexplorer.model.ModelUv> = emptyList()) {
            val area = (q[0]-p[0])*(r[1]-p[1])-(q[1]-p[1])*(r[0]-p[0])
            if (abs(area)<1e-8) return
            val x0 = floor(minOf(p[0],q[0],r[0])).toInt().coerceIn(0,width-1)
            val x1 = ceil(maxOf(p[0],q[0],r[0])).toInt().coerceIn(0,width-1)
            val y0 = floor(minOf(p[1],q[1],r[1])).toInt().coerceIn(0,height-1)
            val y1 = ceil(maxOf(p[1],q[1],r[1])).toInt().coerceIn(0,height-1)
            val ux=q[0]-p[0]; val uy=q[1]-p[1]; val uz=(q[2]-p[2])*scale*radius
            val vx=r[0]-p[0]; val vy=r[1]-p[1]; val vz=(r[2]-p[2])*scale*radius
            val nx=uy*vz-uz*vy; val ny=uz*vx-ux*vz; val nz=ux*vy-uy*vx
            val light = 0.35+0.65*abs((nx*0.3-ny*0.5+nz*0.8)/sqrt(nx*nx+ny*ny+nz*nz).coerceAtLeast(1e-10))
            val shade = (0xFF shl 24) or (((color shr 16 and 255)*light).toInt().coerceIn(0,255) shl 16) or
                (((color shr 8 and 255)*light).toInt().coerceIn(0,255) shl 8) or ((color and 255)*light).toInt().coerceIn(0,255)
            for (y in y0..y1) for (x in x0..x1) {
                val px=x+0.5; val py=y+0.5
                val v=((px-p[0])*(r[1]-p[1])-(py-p[1])*(r[0]-p[0]))/area
                val w=((q[0]-p[0])*(py-p[1])-(q[1]-p[1])*(px-p[0]))/area
                if (v>=-1e-8 && w>=-1e-8 && v+w<=1.00000001) {
                    val z=p[2]+v*(q[2]-p[2])+w*(r[2]-p[2]); val i=y*width+x
                    if (z<depth[i]) {
                        var pixel=shade
                        if (texture!=null && uv.size==3) {
                            val tu=uv[0].u+v*(uv[1].u-uv[0].u)+w*(uv[2].u-uv[0].u)
                            val tv=uv[0].v+v*(uv[1].v-uv[0].v)+w*(uv[2].v-uv[0].v)
                            val tx=Math.floorMod(floor(tu).toInt(),texture.width)
                            val ty=Math.floorMod(floor(tv).toInt(),texture.height)
                            pixel=texture.getRGB(tx,ty)
                            if ((pixel ushr 24)<128) continue
                        }
                        depth[i]=z; pixels[i]=pixel
                    }
                }
            }
        }
        if (!wireframe) for (face in model.faces) {
            val p=points[face.indices[0]]
            for (j in 1 until face.indices.size-1)
                triangle(p,points[face.indices[j]],points[face.indices[j+1]],face.rgb ?: colors[Math.floorMod(face.material,colors.size)],
                    model.textures[face.material],if (face.uvs.size==face.indices.size) listOf(face.uvs[0],face.uvs[j],face.uvs[j+1]) else emptyList())
        }
        for (line in model.lines) {
            val p=points[line.start]; val q=points[line.end]
            val steps=ceil(max(abs(q[0]-p[0]),abs(q[1]-p[1]))).toInt().coerceIn(1,20000)
            for (step in 0..steps) {
                val t=step.toDouble()/steps
                val x=(p[0]+(q[0]-p[0])*t).roundToInt(); val y=(p[1]+(q[1]-p[1])*t).roundToInt()
                if (x in 0 until width && y in 0 until height) {
                    val z=p[2]+(q[2]-p[2])*t; val i=y*width+x
                    if (wireframe || z<=depth[i]+0.002) { depth[i]=z; pixels[i]=0xFF000000.toInt() or line.rgb }
                }
            }
        }
        val image=BufferedImage(width,height,BufferedImage.TYPE_INT_RGB)
        image.setRGB(0,0,width,height,pixels,0,width)
        if (wireframe) {
            val g=image.createGraphics()
            g.color=java.awt.Color(0xA6D8F5)
            for (face in model.faces) for (j in face.indices.indices) {
                val p=points[face.indices[j]]; val q=points[face.indices[(j+1)%face.indices.size]]
                g.drawLine(p[0].roundToInt(),p[1].roundToInt(),q[0].roundToInt(),q[1].roundToInt())
            }
            g.dispose()
        }
        return image
    }
}

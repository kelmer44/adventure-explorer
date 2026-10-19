package adventureexplorer.audio

import adventureexplorer.model.SoundData
import java.io.ByteArrayOutputStream

/** Microsoft IMA ADPCM WAV blocks, including the mono speech/music used by LBA2. */
internal object ImaWaveDecoder {
    private val steps = intArrayOf(7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,
        88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,
        963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,
        5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767)
    private val changes = intArrayOf(-1,-1,-1,-1,2,4,6,8)
    private fun ByteArray.u8(p: Int) = this[p].toInt() and 255
    private fun ByteArray.u16(p: Int) = u8(p) or (u8(p+1) shl 8)
    private fun ByteArray.u32(p: Int) = u16(p).toLong() or (u16(p+2).toLong() shl 16)
    private fun ByteArray.tag(p: Int) = String(this, p, 4, Charsets.US_ASCII)

    fun decode(data: ByteArray): SoundData? = runCatching {
        require(data.size >= 12 && data.tag(0) == "RIFF" && data.tag(8) == "WAVE")
        val end = data.u32(4) + 8
        require(end in 12..data.size.toLong())
        var pos = 12; var fmt = -1; var fmtSize = 0; var start = -1; var length = 0; var fact: Long? = null
        while (pos.toLong() + 8 <= end) {
            val size = data.u32(pos+4); val body = pos+8
            require(size <= end-body)
            when (data.tag(pos)) {
                "fmt " -> { fmt=body; fmtSize=size.toInt() }
                "data" -> { start=body; length=size.toInt() }
                "fact" -> if (size>=4) fact=data.u32(body)
            }
            val next = body.toLong()+size+(size%2)
            require(next <= Int.MAX_VALUE)
            pos=next.toInt()
        }
        require(fmt>=0 && fmtSize>=20 && start>=0 && length>0)
        require(data.u16(fmt)==17 && data.u16(fmt+14)==4 && data.u16(fmt+16)>=2)
        val channels=data.u16(fmt+2); val rate=data.u32(fmt+4); val align=data.u16(fmt+12)
        require(channels in 1..2 && rate in 1..192000 && align>4*channels)
        require((align-4*channels)%(4*channels)==0)
        val samplesPerBlock=data.u16(fmt+18)
        require(samplesPerBlock==1+(align-4*channels)*2/channels)
        val estimate=((length.toLong()+align-1)/align)*samplesPerBlock*channels*2
        require(estimate<=64*1024*1024)
        val out=ByteArrayOutputStream(); var frames=0L
        val predictors=IntArray(channels); val indices=IntArray(channels)
        fun sample(n: Int) { out.write(n and 255); out.write((n shr 8) and 255) }
        fun frame(values: IntArray) { if (fact==null || frames<fact!!) values.forEach { sample(it) };frames++ }
        fun nibble(c: Int, n: Int): Int {
            val step=steps[indices[c]]
            var delta=step shr 3
            if (n and 1!=0) delta+=step shr 2
            if (n and 2!=0) delta+=step shr 1
            if (n and 4!=0) delta+=step
            predictors[c]=(predictors[c]+if (n and 8!=0) -delta else delta).coerceIn(-32768,32767)
            indices[c]=(indices[c]+changes[n and 7]).coerceIn(0,88)
            return predictors[c]
        }
        var block=start
        while (block<start+length) {
            val stop=minOf(block+align,start+length)
            require(stop-block>=4*channels && (stop-block-4*channels)%(4*channels)==0)
            for (c in 0 until channels) {
                val p=block+c*4
                predictors[c]=data.u16(p).toShort().toInt();indices[c]=data.u8(p+2)
                require(indices[c]<=88 && data.u8(p+3)==0)
            }
            frame(predictors)
            var p=block+4*channels
            while (p<stop) {
                val group=Array(channels) { IntArray(8) }
                for (c in 0 until channels) for (i in 0..3) {
                    val b=data.u8(p++);group[c][i*2]=nibble(c,b and 15);group[c][i*2+1]=nibble(c,b shr 4)
                }
                for (i in 0..7) frame(IntArray(channels) { group[it][i] })
            }
            block=stop
        }
        require(fact==null || fact!!<=frames)
        require(out.size()>0)
        SoundData(out.toByteArray(),rate.toInt(),16,channels,true)
    }.getOrNull()
}

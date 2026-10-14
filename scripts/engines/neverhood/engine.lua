-- ============================================================================
-- Adventure Explorer - Engine Script: The Neverhood (DreamWorks, 1996)
-- ============================================================================
-- Reference: ScummVM engines/neverhood + common/compression/dcl.cpp
--
-- Data layout: all resources live in a set of .BLB archives in DATA/:
--   a.blb  c.blb  hd.blb  i.blb  m.blb  s.blb  t.blb
-- Resources are addressed only by a 32-bit hash, so leaves are labelled
-- "0xHASH". Missing name strings are hashed with the game's calcHash.
--
-- BLB archive (blbarchive.cpp):
--   header 16 bytes:
--     0x00 u32 id1       (0x02004940)
--     0x04 u16 id2       (7)
--     0x06 u16 extDataSize
--     0x08 u32 fileSize
--     0x0C u32 fileCount
--   then fileCount u32 hashes, then fileCount entries of 20 bytes:
--     u8 type, u8 comprType, u16 extDataOffset, u32 timeStamp,
--     u32 offset, u32 diskSize, u32 size
--   then the extData blob (extDataSize bytes).
--   comprType: 1 = stored, 3 = DCL compressed, 0x65 = redirect/alias whose
--   diskSize field is the hash of the target entry. ResourceMan::findEntry
--   follows the chain; queryResource reads extData from the first (alias)
--   entry while loadResource decodes the resolved entry.
--
-- Resource types: 2 bitmap, 3 palette, 4 animation, 5 data, 6 text,
--   7 sound, 8 music, 10 video(Smacker).
--
-- DCL (fixed-tree "blast" variant): stream header = mode byte (0 binary,
--   1 ascii), dictionary-type byte (4/5/6 -> 1024/2048/4096). All Neverhood
--   streams are binary mode with dictionary type 6. Bit packing is LSB-first.
--
-- Bitmap: u16 flags = BF_RLE(1)|BF_DIM(2)|BF_POS(4)|BF_PAL(8)|BF_IMG(16),
--   then optional w,h, optional x,y, optional 1024-byte palette (R,G,B,X),
--   then image. RLE: u16 rows, u16 chunks; chunks==0 -> skip rows; else per
--   row chunks*(u16 skip,u16 copy, copy bytes). Normal: pitch=(w+3)&~3.
--
-- Animation: u16 animListCount, u16 animInfoStartOfs, u32 spriteDataOfs,
--   u32 paletteDataOfs, then animList entries (u32 hash, u16 frameCount,
--   u16 frameListStartOfs). Frames are 32 bytes: u32 frameHash, u16 counter,
--   u16 x,y,w,h, u16 deltaX,deltaY, u16 collision x,y,w,h, u32 spriteDataOffs
--   at +28. Frame pixels are always RLE at spriteDataOfs+spriteDataOffs.
--
-- Text: u32 count, then offsets; string i = data[4+count*4+off(i+1)] ..
--   off(i+2) (last string runs to end). Embedded \0 are line breaks.
--
-- Sound: extData[0] = shift value. 0xFF = uncompressed s16le PCM @22050.
--   else 8-bit signed delta: prev += int8(byte); sample = int16(prev<<shift).
-- ============================================================================

local engine = {}
engine.name        = "The Neverhood"
engine.id          = "neverhood"
engine.description = "The Neverhood (1996, DreamWorks) - BLB archives"
engine.version     = "1.0"

-- ── numeric helpers (Lua 5.2, no bitwise ops) ──────────────────────────────

local POW2 = {}
for i = 0, 31 do POW2[i] = 2 ^ i end

local CHARS = {}
for i = 0, 255 do CHARS[i] = string.char(i) end

local HEXDIG = "0123456789abcdef"
local function hex8(n)
    n = n % 4294967296
    local s = ""
    for _ = 1, 8 do
        local d = n % 16
        s = HEXDIG:sub(d + 1, d + 1) .. s
        n = math.floor(n / 16)
    end
    return s
end

local function u16le(data, pos)
    local a, b = data:byte(pos), data:byte(pos + 1)
    if not a or not b then return 0 end
    return a + b * 256
end

local function s16le(data, pos)
    local v = u16le(data, pos)
    if v >= 32768 then v = v - 65536 end
    return v
end

local function u32le(data, pos)
    local a, b, c, d = data:byte(pos), data:byte(pos + 1), data:byte(pos + 2), data:byte(pos + 3)
    if not a or not b or not c or not d then return 0 end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- ── DCL fixed-tree decompressor (common/compression/dcl.cpp) ───────────────
-- BN(pos,l,r) = (l<<12)|r ; LN(pos,v) = v | 0x40000000

local length_tree = {
    4098, 12292, 20486, 28680, 36874, 45068, 1073741825, 53262, 61456, 69650,
    1073741827, 1073741826, 1073741824, 77844, 86038, 94232, 1073741830,
    1073741829, 1073741828, 102426, 110620, 1073741834, 1073741833,
    1073741832, 1073741831, 118814, 1073741837, 1073741836, 1073741835,
    1073741839, 1073741838
}

local distance_tree = {
    4098, 12292, 20486, 28680, 36874, 45068, 1073741824, 53262, 61456, 69650,
    77844, 86038, 94232, 102426, 110620, 118814, 127008, 135202, 143396,
    151590, 159784, 167978, 176172, 1073741826, 1073741825, 184366, 192560,
    200754, 208948, 217142, 225336, 233530, 241724, 249918, 258112, 266306,
    274500, 282694, 290888, 299082, 307276, 1073741830, 1073741829,
    1073741828, 1073741827, 315470, 323664, 331858, 340052, 348246, 356440,
    364634, 372828, 381022, 389216, 397410, 405604, 413798, 421992, 430186,
    438380, 446574, 1073741845, 1073741844, 1073741843, 1073741842,
    1073741841, 1073741840, 1073741839, 1073741838, 1073741837, 1073741836,
    1073741835, 1073741834, 1073741833, 1073741832, 1073741831, 454768,
    462962, 471156, 479350, 487544, 495738, 503932, 512126, 1073741871,
    1073741870, 1073741869, 1073741868, 1073741867, 1073741866, 1073741865,
    1073741864, 1073741863, 1073741862, 1073741861, 1073741860, 1073741859,
    1073741858, 1073741857, 1073741856, 1073741855, 1073741854, 1073741853,
    1073741852, 1073741851, 1073741850, 1073741849, 1073741848, 1073741847,
    1073741846, 1073741887, 1073741886, 1073741885, 1073741884, 1073741883,
    1073741882, 1073741881, 1073741880, 1073741879, 1073741878, 1073741877,
    1073741876, 1073741875, 1073741874, 1073741873, 1073741872
}

local function dcl_decompress(src, outsize, limit)
    local target = outsize
    local cap = limit or outsize
    local sp = 1
    local srcLen = #src
    local mode = src:byte(sp) or 0
    local dictType = src:byte(sp + 1) or 6
    sp = sp + 2
    if dictType < 4 then dictType = 4 end
    if dictType > 6 then dictType = 6 end
    local dictionarySize
    if dictType == 4 then dictionarySize = 1024
    elseif dictType == 5 then dictionarySize = 2048
    else dictionarySize = 4096 end

    local bitbuf = 0
    local nbits = 0
    local function fetch()
        while nbits <= 24 do
            local b = src:byte(sp)
            if not b then b = 0 end
            bitbuf = bitbuf + b * POW2[nbits]
            nbits = nbits + 8
            sp = sp + 1
        end
    end
    local function getBits(n)
        if nbits < n then fetch() end
        local ret = bitbuf % POW2[n]
        bitbuf = math.floor(bitbuf / POW2[n])
        nbits = nbits - n
        return ret
    end
    local function huff(tree)
        local pos = 0
        local v = tree[1]
        while v < 1073741824 do
            if getBits(1) == 1 then pos = v % 4096 else pos = math.floor(v / 4096) end
            v = tree[pos + 1]
        end
        return v % 65536
    end

    local dictionary = {}
    local dictPos = 0
    local out = {}
    local outPos = 0

    while outPos < target do
        if getBits(1) == 1 then
            local value = huff(length_tree)
            local tokenLength
            if value < 8 then
                tokenLength = value + 2
            else
                tokenLength = 8 + POW2[value - 7] + getBits(value - 7)
            end
            if tokenLength == 519 then break end

            value = huff(distance_tree)
            local tokenOffset
            if tokenLength == 2 then
                tokenOffset = value * 4 + getBits(2)
            else
                tokenOffset = value * POW2[dictType] + getBits(dictType)
            end
            tokenOffset = tokenOffset + 1

            if outPos < tokenOffset then return nil end

            local baseIndex = (dictPos - tokenOffset) % dictionarySize
            if baseIndex < 0 then baseIndex = baseIndex + dictionarySize end
            local idx = baseIndex
            local nextIdx = dictPos
            while tokenLength > 0 do
                local b = dictionary[idx]
                if not b then b = 0 end
                outPos = outPos + 1
                out[outPos] = CHARS[b]
                dictionary[nextIdx] = b
                nextIdx = nextIdx + 1
                if nextIdx >= dictionarySize then nextIdx = 0 end
                idx = idx + 1
                if idx >= dictionarySize then idx = 0 end
                if idx == dictPos then idx = baseIndex end
                tokenLength = tokenLength - 1
            end
            dictPos = nextIdx
        else
            local value
            if mode == 1 then return nil else value = getBits(8) end
            outPos = outPos + 1
            out[outPos] = CHARS[value]
            dictionary[dictPos] = value
            dictPos = dictPos + 1
            if dictPos >= dictionarySize then dictPos = 0 end
        end
        if outPos >= cap then break end
    end

    return table.concat(out)
end

-- ── archive access + merged index ──────────────────────────────────────────

local ARCHIVES = { "a", "c", "hd", "i", "m", "s", "t" }
local ARCH_LABEL = { a = "A", c = "C", hd = "HD", i = "I", m = "M", s = "S", t = "T" }

local function open_blb(dir, name)
    local fh = file_open(dir .. "/" .. name .. ".blb")
    if fh then return fh end
    fh = file_open(dir .. "/" .. name:upper() .. ".BLB")
    if fh then return fh end
    return nil
end

local function has_blb(dir, name)
    local fh = open_blb(dir, name)
    if fh then file_close(fh) return true end
    return false
end

local function find_data_dir(game_path)
    local cands = { game_path .. "/DATA", game_path .. "/data", game_path }
    for _, d in ipairs(cands) do
        if has_blb(d, "hd") or has_blb(d, "a") then return d end
    end
    return nil
end

local function parse_blb(path)
    local fh = file_open(path)
    if not fh then return nil end
    local hdr = file_read(fh, 0, 16)
    if not hdr or #hdr < 16 then file_close(fh) return nil end
    if u32le(hdr, 1) ~= 0x02004940 or u16le(hdr, 5) ~= 7 then
        file_close(fh)
        return nil
    end
    local extDataSize = u16le(hdr, 7)
    local fileCount = u32le(hdr, 13)
    if fileCount > 100000 then file_close(fh) return nil end

    local rawH = file_read(fh, 16, fileCount * 4)
    local entOfs = 16 + fileCount * 4
    local rawE = file_read(fh, entOfs, fileCount * 20)
    local extOfs = entOfs + fileCount * 20
    local extData = ""
    if extDataSize > 0 then extData = file_read(fh, extOfs, extDataSize) or "" end
    file_close(fh)
    if not rawH or not rawE then return nil end

    local hashes = {}
    for i = 0, fileCount - 1 do hashes[i] = u32le(rawH, i * 4 + 1) end
    return { hashes = hashes, rawE = rawE, extData = extData, count = fileCount }
end

local function entry_at(blb, i)
    local base = i * 20 + 1
    local raw = blb.rawE
    local ht = blb.hashes[i]
    local compr = raw:byte(base + 1) or 0
    local extOff = u16le(raw, base + 2)
    local ts = u32le(raw, base + 4)
    local off = u32le(raw, base + 8)
    local disk = u32le(raw, base + 12)
    local size = u32le(raw, base + 16)
    return {
        hash = ht, type = raw:byte(base) or 0, compr = compr,
        extOff = extOff, ts = ts, off = off, disk = disk, size = size,
    }
end

local _cache = {}

local function get_index(game_path)
    local cached = _cache[game_path]
    if cached then return cached end

    local dir = find_data_dir(game_path)
    if not dir then return nil end

    local idx = { dir = dir, map = {} }
    for _, name in ipairs(ARCHIVES) do
        local blb = parse_blb(dir .. "/" .. name .. ".blb")
        if not blb then
            blb = parse_blb(dir .. "/" .. name:upper() .. ".BLB")
        end
        if blb then
            for i = 0, blb.count - 1 do
                local e = entry_at(blb, i)
                if e.hash ~= 0 then
                    local existing = idx.map[e.hash]
                    if not existing or e.ts > existing.entry.ts then
                        idx.map[e.hash] = { entry = e, arch = name, extData = blb.extData }
                    end
                end
            end
        end
    end
    _cache[game_path] = idx
    return idx
end

local function resolve_entry(idx, hash)
    local e = idx.map[hash]
    local guard = 0
    while e and e.entry.compr == 0x65 do
        hash = e.entry.disk
        e = idx.map[hash]
        guard = guard + 1
        if guard > 64 then return nil end
    end
    return e
end

local function load_entry_bytes(dir, arch, e, limit)
    local fh = open_blb(dir, arch)
    if not fh then return nil end
    local raw = file_read(fh, e.off, e.disk)
    file_close(fh)
    if not raw then return nil end
    if e.compr == 1 then return raw end
    if e.compr == 3 then return dcl_decompress(raw, e.size, limit) end
    return nil
end

local function read_resource(idx, hash, limit)
    local e = resolve_entry(idx, hash)
    if not e then return nil end
    return load_entry_bytes(idx.dir, e.arch, e.entry, limit)
end

-- ── decoders ───────────────────────────────────────────────────────────────

local function palette_from_1024(s)
    local pal = {}
    for i = 0, 255 do
        local b = i * 4
        pal[i * 3 + 1] = s:byte(b + 1) or 0
        pal[i * 3 + 2] = s:byte(b + 2) or 0
        pal[i * 3 + 3] = s:byte(b + 3) or 0
    end
    return pal
end

local function grayscale_palette()
    local pal = {}
    for i = 0, 255 do
        pal[i * 3 + 1] = i
        pal[i * 3 + 2] = i
        pal[i * 3 + 3] = i
    end
    return pal
end

local function load_override_palette(idx, palette_id)
    if not palette_id or palette_id == "" then return nil end
    local h = palette_id:match("^pal_(%x+)$")
    if not h then return nil end
    local bytes = read_resource(idx, tonumber(h, 16), nil)
    if bytes and #bytes >= 1024 then return palette_from_1024(bytes) end
    return nil
end

local function parse_bitmap(d)
    if #d < 2 then return nil end
    local flags = u16le(d, 1)
    local hasdim = math.floor(flags / 2) % 2 == 1
    local haspos = math.floor(flags / 4) % 2 == 1
    local haspal = math.floor(flags / 8) % 2 == 1
    local hasimg = math.floor(flags / 16) % 2 == 1
    local p = 3
    local w, h = 1, 1
    if hasdim then w = u16le(d, p) h = u16le(d, p + 2) p = p + 4 end
    if haspos then p = p + 4 end
    local pal = nil
    if haspal then pal = d:sub(p, p + 1023) p = p + 1024 end
    return {
        flags = flags, rle = (flags % 2) == 1, w = w, h = h,
        palette = pal, pixofs = hasimg and p or nil,
    }
end

local function unpack_normal(d, base, w, h)
    local pitch = w + ((4 - (w % 4)) % 4)
    local out = {}
    for y = 0, h - 1 do
        local rowbase = base + y * pitch
        for x = 0, w - 1 do
            out[y * w + x + 1] = d:byte(rowbase + x) or 0
        end
    end
    return out
end

local function unpack_rle(d, base, w, h)
    local out = {}
    local total = w * h
    for i = 1, total do out[i] = 0 end
    local len = #d
    if base + 3 > len then return out end
    local pos = base
    local y = 0
    local rows = u16le(d, pos)
    local chunks = u16le(d, pos + 2)
    pos = pos + 4
    while true do
        if chunks == 0 then
            y = y + rows
        else
            for _ = 1, rows do
                for _ = 1, chunks do
                    local skip = u16le(d, pos)
                    local copy = u16le(d, pos + 2)
                    pos = pos + 4
                    if y < h then
                        local rowbase = y * w + 1
                        for k = 0, copy - 1 do
                            local px = skip + k
                            if px < w then
                                out[rowbase + px] = d:byte(pos + k) or 0
                            end
                        end
                    end
                    pos = pos + copy
                end
                y = y + 1
            end
        end
        if rows == 0 then break end
        if pos + 3 > len then break end
        rows = u16le(d, pos)
        chunks = u16le(d, pos + 2)
        pos = pos + 4
    end
    return out
end

local function load_bitmap(idx, hash, palette_id)
    local d = read_resource(idx, hash, nil)
    if not d or #d < 2 then
        return { type = "text", text = string.format("Bitmap 0x%s: failed to load", hex8(hash)) }
    end
    local b = parse_bitmap(d)
    if not b then
        return { type = "text", text = string.format("Bitmap 0x%s: bad header", hex8(hash)) }
    end
    if b.w <= 0 or b.h <= 0 or b.w > 4096 or b.h > 4096 then
        return { type = "text", text = string.format("Bitmap 0x%s: bad dimensions %dx%d", hex8(hash), b.w, b.h) }
    end
    if not b.pixofs then
        return { type = "text", text = string.format("Bitmap 0x%s: no image data (flags 0x%02x)", hex8(hash), b.flags) }
    end
    local pixels
    if b.rle then pixels = unpack_rle(d, b.pixofs, b.w, b.h)
    else pixels = unpack_normal(d, b.pixofs, b.w, b.h) end

    local pal, palnote
    if b.palette then
        pal = palette_from_1024(b.palette)
        palnote = "embedded palette"
    else
        pal = load_override_palette(idx, palette_id)
        if pal then palnote = "external palette" else pal = grayscale_palette() palnote = "grayscale" end
    end
    local img = image_create_indexed(b.w, b.h, pixels, pal)
    return {
        type = "image", image = img, width = b.w, height = b.h,
        description = string.format("Bitmap 0x%s - %dx%d, %s (%s)", hex8(hash), b.w, b.h,
            b.rle and "RLE" or "raw", palnote),
    }
end

local function load_palette_res(idx, hash)
    local d = read_resource(idx, hash, nil)
    if not d or #d < 1024 then
        return { type = "text", text = string.format("Palette 0x%s: too small", hex8(hash)) }
    end
    local pal = palette_from_1024(d)
    local px = {}
    for y = 0, 255 do
        for x = 0, 255 do
            px[y * 256 + x + 1] = math.floor(y / 16) * 16 + math.floor(x / 16)
        end
    end
    local img = image_create_indexed(256, 256, px, pal)
    return {
        type = "image", image = img, width = 256, height = 256,
        description = string.format("Palette 0x%s - 256 colours", hex8(hash)),
    }
end

local MAX_ANIM_FRAMES = 150

local function load_animation(idx, hash, palette_id)
    local d = read_resource(idx, hash, nil)
    if not d or #d < 12 then
        return { type = "text", text = string.format("Animation 0x%s: failed to load", hex8(hash)) }
    end
    local animListCount = u16le(d, 1)
    local animInfoStartOfs = u16le(d, 3)
    local spriteDataOfs = u32le(d, 5)
    local paletteDataOfs = u32le(d, 9)

    local frameCount, frameListStartOfs, found = 0, 0, false
    for i = 0, animListCount - 1 do
        local base = 13 + i * 8
        if base + 3 <= #d then
            if u32le(d, base) == hash then
                frameCount = u16le(d, base + 4)
                frameListStartOfs = u16le(d, base + 6)
                found = true
                break
            end
        end
    end
    if not found then
        if animListCount > 0 then
            frameCount = u16le(d, 17)
            frameListStartOfs = u16le(d, 19)
        else
            return { type = "text", text = string.format("Animation 0x%s: empty", hex8(hash)) }
        end
    end
    if frameCount <= 0 then
        return { type = "text", text = string.format("Animation 0x%s: no frames", hex8(hash)) }
    end
    local truncated = false
    if frameCount > MAX_ANIM_FRAMES then frameCount = MAX_ANIM_FRAMES truncated = true end

    local pal, palnote
    if paletteDataOfs > 0 and paletteDataOfs + 1024 <= #d then
        pal = palette_from_1024(d:sub(paletteDataOfs + 1, paletteDataOfs + 1024))
        palnote = "embedded palette"
    else
        pal = load_override_palette(idx, palette_id)
        if pal then palnote = "external palette" else pal = grayscale_palette() palnote = "grayscale" end
    end

    local frames = {}
    local sumCounter = 0
    local fw, fh = 0, 0
    local fl = animInfoStartOfs + frameListStartOfs + 1
    for i = 0, frameCount - 1 do
        local off = fl + i * 32
        if off + 31 > #d then break end
        local counter = u16le(d, off + 4)
        local w = u16le(d, off + 10)
        local h = u16le(d, off + 12)
        local sdoff = u32le(d, off + 28)
        if counter > 0 then sumCounter = sumCounter + counter else sumCounter = sumCounter + 1 end
        if w > 0 and h > 0 and w <= 4096 and h <= 4096 then
            local pixels = unpack_rle(d, spriteDataOfs + sdoff + 1, w, h)
            frames[#frames + 1] = image_create_indexed(w, h, pixels, pal)
            if fw == 0 then fw, fh = w, h end
        end
    end
    if #frames == 0 then
        return { type = "text", text = string.format("Animation 0x%s: no decodable frames", hex8(hash)) }
    end

    local delay = math.floor((sumCounter / frameCount) * 1000 / 24 + 0.5)
    if delay < 20 then delay = 20 end
    if delay > 2000 then delay = 2000 end
    local anim = animation_create(frames, delay)
    return {
        type = "animation", animation = anim, frames = frames,
        image = frames[1], delay_ms = delay, width = fw, height = fh,
        description = string.format("Animation 0x%s - %d frame%s%s (%s)", hex8(hash),
            #frames, #frames == 1 and "" or "s", truncated and "+" or "", palnote),
    }
end

local function load_sound_res(idx, hash)
    local e = resolve_entry(idx, hash)
    if not e then
        return { type = "text", text = string.format("Sound 0x%s: not found", hex8(hash)) }
    end
    local d = load_entry_bytes(idx.dir, e.arch, e.entry, nil)
    if not d or #d == 0 then
        return { type = "text", text = string.format("Sound 0x%s: failed to load", hex8(hash)) }
    end
    local shift = 0
    if e.extData and e.extData ~= "" and e.entry.extOff > 0 then
        shift = e.extData:byte(e.entry.extOff) or 0
    end

    local pcm
    if shift == 0xFF then
        pcm = d
    else
        if shift > 12 then shift = 12 end
        local out = {}
        local prev = 0
        local len = #d
        for i = 1, len do
            local b = d:byte(i)
            if b >= 128 then b = b - 256 end
            prev = (prev + b) % 65536
            local s = (prev * POW2[shift]) % 65536
            out[i] = CHARS[s % 256] .. CHARS[math.floor(s / 256)]
        end
        pcm = table.concat(out)
    end
    local snd = sound_create_pcm(22050, 16, 1, true, pcm)
    if not snd then
        return { type = "text", text = string.format("Sound 0x%s: could not create PCM", hex8(hash)) }
    end
    return {
        type = "sound", sound = snd,
        description = string.format("Sound 0x%s - %d bytes, %s", hex8(hash), #d,
            shift == 0xFF and "16-bit PCM" or ("delta shift " .. shift)),
    }
end

local function load_text_res(idx, hash)
    local d = read_resource(idx, hash, nil)
    if not d or #d < 4 then
        return { type = "text", text = string.format("Text 0x%s: too small", hex8(hash)) }
    end
    local count = u32le(d, 1)
    local base = 4 + count * 4
    local parts = {}
    for i = 0, count - 1 do
        local o1 = u32le(d, (i + 1) * 4 + 1)
        local o2
        if i < count - 1 then o2 = u32le(d, (i + 2) * 4 + 1) else o2 = #d - base end
        local s = d:sub(base + o1 + 1, base + o2)
        s = s:gsub("%z", "\n")
        parts[#parts + 1] = s
    end
    return {
        type = "text", text = table.concat(parts, "\n\n"),
        description = string.format("Text 0x%s - %d string%s", hex8(hash), count, count == 1 and "" or "s"),
    }
end

local function load_data_res(idx, hash)
    local d = read_resource(idx, hash, nil)
    if not d then
        return { type = "text", text = string.format("Data 0x%s: failed to load", hex8(hash)) }
    end
    local preview = {}
    local n = math.min(#d, 256)
    for i = 1, n do preview[#preview + 1] = string.format("%02x", d:byte(i)) end
    return {
        type = "text",
        text = string.format("Data resource 0x%s (%d bytes)\n\n%s", hex8(hash), #d, table.concat(preview, " ")),
        description = string.format("Data 0x%s - %d bytes", hex8(hash), #d),
    }
end

local function load_video_res(idx, hash)
    local d = read_resource(idx, hash, nil)
    local size = d and #d or 0
    return {
        type = "text",
        text = string.format("Smacker video 0x%s (%d bytes).\nVideo playback is not supported in this viewer.", hex8(hash), size),
        description = string.format("Video 0x%s - %d bytes", hex8(hash), size),
    }
end

-- ── tree ───────────────────────────────────────────────────────────────────

local KIND = { [2] = "bmp", [3] = "pal", [4] = "anim", [5] = "dat", [6] = "txt", [7] = "snd", [8] = "mus", [10] = "vid" }
local CATS = {
    { 2, "bitmaps", "Bitmaps", "image" },
    { 4, "animations", "Animations", "animation" },
    { 3, "palettes", "Palettes", "palette" },
    { 7, "sounds", "Sounds", "sound" },
    { 8, "music", "Music", "sound" },
    { 6, "text", "Text", "text" },
    { 5, "data", "Data", "data" },
    { 10, "videos", "Videos", "text" },
}

local function build_children(list, kind, node_type)
    table.sort(list, function(a, b) return a.hash < b.hash end)
    local children = {}
    for _, e in ipairs(list) do
        children[#children + 1] = {
            id = kind .. "_" .. hex8(e.hash),
            name = string.format("%s 0x%s", ARCH_LABEL[e.arch] or e.arch:upper(), hex8(e.hash)),
            type = node_type,
        }
    end
    return children
end

function engine.detect(game_path)
    if type(game_path) ~= "string" then return false end
    return find_data_dir(game_path) ~= nil
end

function engine.get_resources(game_path)
    local idx = get_index(game_path)
    if not idx then return {} end

    local groups = {}
    for hash, e in pairs(idx.map) do
        if e.entry.compr ~= 0x65 then
            local t = e.entry.type
            if KIND[t] then
                local g = groups[t]
                if not g then g = {} groups[t] = g end
                g[#g + 1] = { hash = hash, arch = e.arch }
            end
        end
    end

    -- Animations: a resource can bundle several animations in its animList.
    -- Enumerate every animList hash from each animation container.
    local animlist = {}
    local containers = groups[4] or {}
    for _, c in ipairs(containers) do
        local d = read_resource(idx, c.hash, 4096)
        if d and #d >= 12 then
            local alc = u16le(d, 1)
            for i = 0, alc - 1 do
                local base = 13 + i * 8
                if base + 3 <= #d then
                    local ah = u32le(d, base)
                    if ah ~= 0 and not animlist[ah] then
                        animlist[ah] = { hash = ah, arch = c.arch }
                    end
                end
            end
        end
    end
    groups[4] = nil

    local resources = {}
    for _, cat in ipairs(CATS) do
        local t, cid, cname, ntype = cat[1], cat[2], cat[3], cat[4]
        local list
        if t == 4 then
            list = {}
            for _, e in pairs(animlist) do list[#list + 1] = e end
        else
            list = groups[t] or {}
        end
        if #list > 0 then
            local children = build_children(list, KIND[t], ntype)
            resources[#resources + 1] = {
                id = cid,
                name = string.format("%s (%d)", cname, #children),
                type = "category",
                children = children,
            }
        end
    end
    return resources
end

function engine.load_resource(game_path, resource_id, palette_id)
    if type(resource_id) ~= "string" then return nil end
    local kind, hex = resource_id:match("^(%a+)_(%x%x%x%x%x%x%x%x)$")
    if not kind then return nil end
    local idx = get_index(game_path)
    if not idx then return { type = "text", text = "Neverhood data directory not found." } end
    local hash = tonumber(hex, 16)
    if kind == "bmp" then return load_bitmap(idx, hash, palette_id)
    elseif kind == "anim" then return load_animation(idx, hash, palette_id)
    elseif kind == "pal" then return load_palette_res(idx, hash)
    elseif kind == "snd" or kind == "mus" then return load_sound_res(idx, hash)
    elseif kind == "txt" then return load_text_res(idx, hash)
    elseif kind == "dat" then return load_data_res(idx, hash)
    elseif kind == "vid" then return load_video_res(idx, hash)
    end
    return nil
end

return engine

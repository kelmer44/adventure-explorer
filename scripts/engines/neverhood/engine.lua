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

-- Per-scene palette hints for surfaces that carry no embedded palette.
-- Derived offline by cross-referencing the ScummVM Neverhood module sources:
-- each no-palette surface is associated with the background palette of the
-- scene(s) that reference it. Entries are flat hash pairs (surface, palette);
-- the palette value is either a bitmap with an embedded palette (type 2) or a
-- palette resource (type 3).
local SCENE_PALETTE_DATA = {
  0x00006321,0x41024202,0x00006322,0x41024202,0x00006324,0x41024202,0x00006328,0x41024202,0x0001264c,0x11e00684,0x00018344,0x20010002,
  0x00026027,0x40008208,0x00028006,0x20010002,0x000408a8,0x8a000044,0x00042313,0x05303114,0x0010eb46,0xa651f246,0x0020001e,0x01600204,
  0x00208084,0x08c0020c,0x00212062,0x4019a2c4,0x00214089,0x08100210,0x00245884,0x88c00241,0x0028d089,0x091406c9,0x00306321,0x41024202,
  0x00306322,0x41024202,0x00412692,0x12c23307,0x0043b038,0x88c00241,0x00502330,0x44242305,0x0060203e,0x03600606,0x0066201c,0x11e00684,
  0x00680116,0x11e00684,0x0068c607,0x20010002,0x006e2038,0x11e00684,0x00802920,0x8c030206,0x00806031,0xd000420c,0x008261e7,0x08021e04,
  0x0086bf09,0xa651f246,0x00911068,0x8c030206,0x0092916a,0x8c030206,0x00a05290,0x29800a01,0x00a08089,0x08100a0c,0x00a3621c,0xa8006200,
  0x00a3641c,0xa8006200,0x00a3681c,0xa8006200,0x00a3701c,0xa8006200,0x00a840e3,0x4019a2c4,0x0100a425,0x20010002,0x0101a624,0x41024202,
  0x010c22f2,0xb22116c5,0x010d7748,0xa651f246,0x01102a33,0x2110a234,0x01142428,0x11e00684,0x012ae033,0x062c0214,0x01410014,0x01c01414,
  0x01600988,0x10080e01,0x01612a22,0xb22116c5,0x01636002,0xd000420c,0x01860450,0xa651f246,0x01b60280,0x28801b64,0x02002920,0x8c030206,
  0x0201410a,0xc1b22110,0x020462e0,0x41983216,0x020ce421,0x08021e04,0x02138002,0x51409a16,0x02363852,0x03118226,0x023b002b,0xa651f246,
  0x02622800,0x80802626,0x02780936,0x26508804,0x02788cf0,0xa651f246,0x02840064,0x01303227,0x02842920,0x8c030206,0x02882920,0x8c030206,
  0x02902920,0x8c030206,0x02a02920,0x8c030206,0x02a41e09,0x41983216,0x02a51054,0x88c00241,0x02a56064,0xd000420c,0x02c02920,0x8c030206,
  0x03001504,0x50c03005,0x03001a15,0x01c01414,0x030326a0,0x40008208,0x03080900,0x0c05060c,0x0311005b,0x05303114,0x03136246,0xa651f246,
  0x0322301b,0x01303227,0x03615227,0x26508804,0x036a1ee0,0x05303114,0x037321b2,0xb22116c5,0x03802920,0x8c030206,0x03842920,0x8c030206,
  0x03a22092,0x4019a2c4,0x03a93831,0x4019a2c4,0x03c82530,0x4019a2c4,0x0400e004,0x20010002,0x04063110,0x4019a2c4,0x04208d08,0xd000420c,
  0x04442520,0x2110a234,0x0450336a,0xa651f246,0x052960a8,0xd000420c,0x0562e621,0x062c0214,0x060000a0,0x12c23307,0x06149428,0x12c23307,
  0x061601c8,0x11e00684,0x06204a88,0xa8006200,0x063039a8,0xa651f246,0x0644a6ec,0xa651f246,0x06802920,0x8c030206,0x0724c09d,0x09507248,
  0x0786a320,0xa651f246,0x07a01080,0x4019a2c4,0x08006320,0x41024202,0x08017029,0xd000420c,0x08030029,0xa651f246,0x080811a0,0x41024202,
  0x081a60a8,0x81660220,0x0820c408,0x40008208,0x082100c4,0x20010002,0x08217029,0xd000420c,0x08306320,0x41024202,0x08478078,0x03600606,
  0x08592134,0x03600606,0x085e25e0,0x41983216,0x08742271,0x2110a234,0x0880026d,0x26508804,0x08862b02,0xa651f246,0x08b04180,0x18808b00,
  0x08b8c180,0x18808b88,0x08c0ac24,0x043692c4,0x090af033,0x062c0214,0x09236252,0xb22116c5,0x0925b82c,0xa651f246,0x09a1251c,0x51409a16,
  0x0a042060,0x41024202,0x0a116130,0xd000420c,0x0a116c60,0x08221fa5,0x0a230219,0x2110a234,0x0a290291,0x08100a0c,0x0a2b8390,0x08100a0c,
  0x0a2ba398,0x08100a0c,0x0a2c0432,0x82c80334,0x0a316130,0xd000420c,0x0a54288f,0x8870a546,0x0a69a098,0x08100a0c,0x0aad8080,0x08100a0c,
  0x0ac33a00,0xa651f246,0x0c03aa23,0x412a423e,0x0c04502a,0x0220c041,0x0c06c860,0x03600606,0x0c24c0ee,0x08c0020c,0x0d411130,0x40008208,
  0x0d641724,0xa6417244,0x0e002004,0x50c03005,0x0e015288,0x8870a546,0x0e038022,0x41983216,0x0e2d84d8,0x08100a0c,0x10002ed8,0x4019a2c4,
  0x10006208,0x20010002,0x10006320,0x41024202,0x10014032,0xd000420c,0x10098138,0xa651f246,0x10098414,0x20010002,0x100ca0a8,0x11e00684,
  0x100ea801,0x03118226,0x10203880,0xa651f246,0x1020a0a0,0x80802626,0x10214032,0xd000420c,0x10283839,0x83110287,0x102ce6e1,0x29800a01,
  0x103021e2,0x3e049a95,0x103022e2,0x3e049a95,0x103024e2,0x3e049a95,0x10306320,0x41024202,0x108012c1,0x29800a01,0x10914448,0x4019a2c4,
  0x10a02120,0x231482f0,0x10ed160a,0x60210ed5,0x110b2202,0xa651f246,0x110ea801,0x03118226,0x11122829,0x01c01414,0x11180022,0x40008208,
  0x1119a363,0xa651f246,0x1120008e,0x08611204,0x116c1b2a,0xb22116c5,0x12006600,0x00442225,0x12192892,0x08221fa5,0x124404c4,0x01303227,
  0x1284e048,0x4019a2c4,0x1288c049,0x4019a2c4,0x12b9983c,0x83412b9d,0x1391e12e,0x88c00241,0x13b1e12e,0x88c00241,0x14016200,0xd000420c,
  0x140b60be,0x12c23307,0x14216200,0xd000420c,0x14320138,0x071963e5,0x14611904,0xa651f246,0x149c00a6,0x8870a546,0x15086623,0xd000420c,
  0x15288120,0x4086520e,0x152c1313,0x12c23307,0x15402d64,0x231482f0,0x1600437e,0x4019a2c4,0x16202200,0x29800a01,0x16882608,0x41983216,
  0x16a31921,0xa651f246,0x16c62100,0x08c0020c,0x16c62121,0x08c0020c,0x16c62122,0x08c0020c,0x16c62124,0x08c0020c,0x16c62128,0x08c0020c,
  0x16c62130,0x08c0020c,0x16e01e20,0x420643c4,0x1712112a,0x1a0b0304,0x17240a6c,0xa6417244,0x18032204,0x29800a01,0x18222039,0x03118226,
  0x18600300,0xa651f246,0x1900a1f8,0xac0b006f,0x19625293,0x1a0b0304,0x1a032204,0x29800a01,0x1a1830f6,0x4019a2c4,0x1a4d4120,0xd542022e,
  0x1b2de860,0xa651f246,0x1c1106b8,0x41983216,0x1ca02160,0x26508804,0x1f242a6d,0xa651f246,0x1fa2eb82,0xb22116c5,0x20006320,0x41024202,
  0x20012004,0xd000420c,0x20212004,0xd000420c,0x2022ad5c,0xd542022e,0x20280580,0x80802626,0x20306320,0x41024202,0x205018c8,0x8c020505,
  0x20649c01,0xa651f246,0x20716010,0xa651f246,0x2080a3a8,0x4086520e,0x2098212d,0x4019a2c4,0x20c24220,0x0c05060c,0x21008080,0x08100a0c,
  0x2106216e,0xa651f246,0x21216221,0xd000420c,0x212323ac,0xa651f246,0x214c8a11,0xa651f246,0x21816927,0xa651f246,0x2182910c,0x08100a0c,
  0x21e00088,0x08021e04,0x21fa108a,0x08221fa5,0x2201266a,0x41983216,0x2203b821,0x03600606,0x22114c13,0xc1b22110,0x22212c64,0xa651f246,
  0x22226001,0x01c01414,0x22300924,0x1a0b0304,0x225124a6,0xa651f246,0x225ba090,0xa651f246,0x22742664,0xa651f246,0x2303900c,0x08100a0c,
  0x23049084,0x08100a0c,0x2311326a,0xa651f246,0x2321c81d,0x81523218,0x2323980c,0x08100a0c,0x23303124,0x12c23307,0x238028aa,0xa651f246,
  0x2391e12e,0x88c00241,0x23a52a68,0xa651f246,0x23b1e12e,0x88c00241,0x24016060,0xd000420c,0x24206418,0x41024202,0x24320220,0x412a423e,
  0x2452a7c4,0xa651f246,0x2491e648,0xa651f246,0x24a00929,0x92124a04,0x24a10929,0x92124a14,0x24a223a2,0x41983216,0x2504d808,0x08100a0c,
  0x25213167,0xa651f246,0x25547028,0x08100a0c,0x2603a202,0x412a423e,0x26133023,0x41983216,0x26737a21,0xa651f246,0x26e33850,0xa651f246,
  0x273801ce,0x11e00684,0x28001120,0x8c030206,0x28416460,0xd000420c,0x28616460,0xd000420c,0x287c21a4,0x11e00684,0x28e0120e,0x20628e05,
  0x28e82e45,0xa651f246,0x2a822e2e,0x412a423e,0x2c4061c4,0x88c00241,0x2d309030,0x0008028d,0x2d339030,0x0008028d,0x2e068a23,0x8c030206,
  0x2e4a22a2,0x412a423e,0x30022689,0x29800a01,0x301024c2,0x80802626,0x30200452,0x80802626,0x302028c8,0x8c030206,0x30303822,0x03118226,
  0x3040c676,0x4019a2c4,0x304890e6,0x4019a2c4,0x3060222e,0x50c03005,0x3081bd3a,0xa651f246,0x3098d05a,0x4019a2c4,0x31203400,0x3e049a95,
  0x31203430,0x3e049a95,0x31203460,0x3e049a95,0x312c8774,0x12c23307,0x3130b0eb,0x0c05060c,0x31313a22,0x03118226,0x316c4bb4,0x12c23307,
  0x316e0772,0x12c23307,0x317831a0,0x41983216,0x3182220e,0xc1b22110,0x3191e12e,0x88c00241,0x3192c059,0x4019a2c4,0x3208348e,0x48632087,
  0x32423010,0x44242305,0x3281e760,0xa651f246,0x3291e12e,0x88c00241,0x32923922,0x1a0b0304,0x3311e12e,0x88c00241,0x33b1e12e,0x88c00241,
  0x33d1e12e,0x88c00241,0x3406a333,0x41983216,0x341a0237,0x412a423e,0x34400150,0xa651f246,0x34422912,0x29800a01,0x3448a066,0x4019a2c4,
  0x351a2f43,0xa651f246,0x36c62120,0x08c0020c,0x3791e12e,0x88c00241,0x384010b6,0x4019a2c4,0x38ea100c,0x08221fa5,0x3941040b,0x071963e5,
  0x39464212,0xa651f246,0x3a01a020,0x81660220,0x3a233939,0xa651f246,0x3b91e12e,0x88c00241,0x3bb1e12e,0x88c00241,0x3c42022f,0x412a423e,
  0x3cc24258,0xa651f246,0x40006320,0x41024202,0x40043120,0x41024202,0x40092024,0xd000420c,0x400b04b0,0x4019a2c4,0x4011018c,0xd000420c,
  0x401410a6,0x8c030206,0x4025a13a,0xa651f246,0x40295462,0x4019a2c4,0x40306320,0x41024202,0x404a36a0,0x05303114,0x406c0ae0,0x81660220,
  0x40a40168,0x01303227,0x40d1e0a9,0x8870a546,0x40e20110,0x11840e24,0x41083ca6,0xa651f246,0x41108c00,0xc084110c,0x41137051,0x08c0020c,
  0x42213133,0x01303227,0x42216422,0xd000420c,0x4222100c,0x00442225,0x42242538,0xa651f246,0x4230144a,0x44242305,0x425848e2,0xa651f246,
  0x426e20bc,0xa651f246,0x430001c4,0x26508804,0x43003100,0x41024202,0x435427ab,0x7a343546,0x4360b02e,0xa651f246,0x442090e4,0x20010002,
  0x4444a362,0x01c01414,0x448138e5,0xa651f246,0x464006b4,0xa651f246,0x476014e0,0x4019a2c4,0x4800a02a,0x3e049a95,0x4800a52a,0x3e049a95,
  0x4800a62a,0x3e049a95,0x482f4239,0x231482f0,0x4830a402,0x01303227,0x486160a0,0xd000420c,0x48e20250,0x11840e24,0x491f38a8,0x10080e01,
  0x492d5ad7,0x8870a546,0x49a913e8,0x3e049a95,0x4a2000ae,0xa651f246,0x4b18f868,0x10080e01,0x5000a7e8,0x80802626,0x5008292b,0x01c01414,
  0x5020a054,0x20010002,0x50266b10,0xa651f246,0x5034ea71,0xa651f246,0x506080c8,0x0c05060c,0x5088a068,0x4019a2c4,0x50c025a8,0x80802626,
  0x50c22c48,0x0220c041,0x50e61019,0xa651f246,0x51286c60,0xa651f246,0x52032563,0x41983216,0x53002104,0xa651f246,0x534a2480,0xa651f246,
  0x542cc072,0x82c80334,0x544822a8,0x41983216,0x55c043b8,0x08100a0c,0x56c62120,0x08c0020c,0x58652c04,0xa651f246,0x58e68412,0xa651f246,
  0x59c600f0,0xa651f246,0x5c2918a4,0xa651f246,0x5e00e262,0x41983216,0x600cef01,0x8449e02f,0x6022481e,0x81660220,0x60882be0,0x231482f0,
  0x6120980c,0x08100a0c,0x61611814,0xa651f246,0x618827a0,0xd000420c,0x62a84060,0xa651f246,0x63090415,0x20010002,0x63d400bc,0x4019a2c4,
  0x64330236,0x412a423e,0x643c0428,0x420643c4,0x64402020,0x50c03005,0x6520a400,0x4086520e,0x66121222,0x412a423e,0x6824a864,0xa651f246,
  0x688f62a5,0x88c00241,0x692c004b,0x043692c4,0x6a012021,0x01c01414,0x700c2e30,0x29800a01,0x70430830,0x420643c4,0x708072e0,0x29800a01,
  0x71718024,0xa651f246,0x72090342,0xc1b22110,0x72427010,0x44242305,0x72875f42,0xc1b22110,0x74882084,0x08c74886,0x74c4c866,0x4019a2c4,
  0x780c2e30,0x29800a01,0x78492010,0x44242305,0x78c0e026,0x4019a2c4,0x7d0404e8,0x10080e01,0x800034a0,0x50c03005,0x80006320,0x41024202,
  0x80098414,0x20010002,0x800ea801,0x03118226,0x80289008,0x0008028d,0x80292014,0xa651f246,0x80306320,0x41024202,0x80330824,0x82c80334,
  0x8071e028,0xd000420c,0x809861a6,0x4086520e,0x80e05108,0x10080e01,0x811da061,0x40008208,0x81a9801d,0x01581a9c,0x82022e11,0xb22116c5,
  0x822b8490,0x08100a0c,0x825e2827,0x51409a16,0x82653808,0x26508804,0x83212411,0x41983216,0x84216824,0xd000420c,0x8540252c,0xd000420c,
  0x85500158,0x08100a0c,0x855820a3,0x412a423e,0x86298080,0x08100a0c,0x877f6252,0xb22116c5,0x88182069,0x4019a2c4,0x888925a4,0x01c01414,
  0x89c03848,0x4086520e,0x8c066150,0x4086520e,0x8e8419c1,0x60210ed5,0x8e8a1981,0x4019a2c4,0x900626a2,0x41983216,0x900ea800,0x03118226,
  0x90312400,0x043692c4,0x90582ea4,0x29800a01,0x90898414,0x20010002,0x90a16120,0xd000420c,0x90c0a4b4,0x8c030206,0x91098414,0x20010002,
  0x910ea800,0x03118226,0x910ea801,0x03118226,0x911101b0,0x01c01414,0x91b8490f,0x90791b80,0x92035301,0xc1b22110,0x92098414,0x20010002,
  0x920ea801,0x03118226,0x94098414,0x20010002,0x940ea801,0x03118226,0x942fc224,0x420643c4,0x94452612,0xa651f246,0x94c22a22,0x043692c4,
  0x96c62120,0x08c0020c,0x98098414,0x20010002,0x980e46a4,0x88c00241,0x980ea801,0x03118226,0x980f3124,0x08221fa5,0x98682705,0xa651f246,
  0x98d0223c,0x08221fa5,0x9a2c0409,0x4019a2c4,0x9d02019a,0xa651f246,0x9e02b84c,0x8449e02f,0xa014216b,0x01581a9c,0xa0232748,0xa651f246,
  0xa0289d08,0x0008028d,0xa048ab42,0xa651f246,0xa0641c6a,0xc62a0645,0xa1361863,0x03600606,0xa21f82cb,0xc1b22110,0xa2733024,0xa651f246,
  0xa29223fa,0x4019a2c4,0xa4062212,0x40008208,0xa40ef2fb,0x412a423e,0xa423a41a,0x412a423e,0xa500800c,0x08100a0c,0xa8042525,0x01c01414,
  0xa82ba811,0x08221fa5,0xb006bac8,0xac0b006f,0xb0098414,0x20010002,0xb00ea801,0x03118226,0xb0196098,0x090b0392,0xb03001a8,0x1a0b0304,
  0xb0396098,0x090b0392,0xb0420130,0x420643c4,0xb059afc4,0xa651f246,0xb140a1e6,0x4019a2c4,0xb14a891e,0x20010002,0xb1a92322,0xd000420c,
  0xb2a423b0,0x12c23307,0xb3242310,0x12c23307,0xb47026b0,0x10080e01,0xb500a1a0,0x01c01414,0xb650a890,0xa651f246,0xb84b1100,0x08221fa5,
  0xc00790c8,0x0c0c007d,0xc021006a,0x062c0214,0xc0693cb4,0xa651f246,0xc10b2015,0x08c0020c,0xc3007ea0,0x26508804,0xc42ac521,0x1b8e8115,
  0xc6440008,0x000c6444,0xc82210a4,0xa651f246,0xcc0522b2,0xa651f246,0xcf08a04e,0xa651f246,0xd0098414,0x20010002,0xd00ea801,0x03118226,
  0xd0802ea0,0x29800a01,0xd10ea801,0x03118226,0xd2012c02,0xc1b22110,0xd2284920,0xa651f246,0xd3443003,0xa651f246,0xd4022322,0x01c01414,
  0xd48077a0,0x29800a01,0xd80c2837,0x4019a2c4,0xd8802cb6,0x4019a2c4,0xda460476,0x4019a2c4,0xdac86e84,0x0008028d,0xe059a224,0x26508804,
  0xe093a741,0xa651f246,0xe20a28a0,0x88c00241,0xe3a22029,0xa651f246,0xe4a43e29,0x40008208,0xe81111b0,0x1b8e8115,
}

local SCENE_PALETTE = {}
for i = 1, #SCENE_PALETTE_DATA, 2 do
    SCENE_PALETTE[SCENE_PALETTE_DATA[i]] = SCENE_PALETTE_DATA[i + 1]
end

local scene_pal_cache = {}

local function load_mapped_palette(idx, hash)
    local m = SCENE_PALETTE[hash]
    if not m then return nil end
    local cached = scene_pal_cache[m]
    if cached ~= nil then return cached or nil end
    local pal = nil
    local e = idx.map[m]
    if e then
        local d = read_resource(idx, m, nil)
        if d then
            if e.entry.type == 3 then
                if #d >= 1024 then pal = palette_from_1024(d) end
            else
                local b = parse_bitmap(d)
                if b and b.palette then pal = palette_from_1024(b.palette) end
            end
        end
    end
    scene_pal_cache[m] = pal or false
    return pal
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
        pal = load_mapped_palette(idx, hash)
        if pal then palnote = "scene palette" else pal = grayscale_palette() palnote = "grayscale" end
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

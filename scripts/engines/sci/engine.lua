-- ============================================================================
-- Adventure Explorer - Engine Script: Sierra SCI
-- ============================================================================
-- Sierra On-Line, 1988-1996. DOS. SCI resource system.
--
-- Supports the DOS resource formats of SCI0 (EGA), SCI1 (EGA/VGA) and SCI1.1:
--   SCI0:   RESOURCE.MAP with 6-byte entries; LZW (LSB) / Huffman compression
--   SCI1:   directory + 6-byte entries; Huffman / LZW1 (MSB) / view+pic LZW
--   SCI1.1: directory + 5-byte entries; DCL (implode) compression
--   SCI2.1: RESMAP.000 + RESSCI.000, 32-bit sizes, LZS compression, 640x480
--           cels with per-row RLE and "hunk" palettes (Larry 7, ...)
--
-- Graphics: SCI0/SCI1 EGA + VGA views (sprites), vector pictures (EGA dithered
-- and VGA), SCI1.1 bitmap pictures and views, fonts, cursors, palettes, texts.
-- The decompressors and renderers are ports of the ScummVM SCI engine.
-- ============================================================================

local engine = {}
engine.name        = "Sierra SCI"
engine.id          = "sci"
engine.description = "Sierra SCI games (1988-1996)"
engine.version     = "5.0"

-- ============================================================================
-- Binary helpers
-- ============================================================================

local floor = math.floor

local function u8(data, pos)  return data:byte(pos) end
local function i8(data, pos)
    local v = data:byte(pos)
    return v < 128 and v or v - 256
end
local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end
local function i16le(data, pos)
    local v = u16le(data, pos)
    return v < 32768 and v or v - 65536
end
local function u32le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536 + data:byte(pos + 3) * 16777216
end

local POW2 = {}
for i = 0, 31 do POW2[i] = 2 ^ i end

-- 4-bit XOR lookup (the engine has no bit operators on LuaJ 5.2)
local XOR4 = {}
for a = 0, 15 do
    for b = 0, 15 do
        local r, m, x, y = 0, 1, a, b
        for _ = 1, 4 do
            if (x % 2) ~= (y % 2) then r = r + m end
            x = floor(x / 2); y = floor(y / 2); m = m * 2
        end
        XOR4[a * 16 + b] = r
    end
end

-- Byte-array helpers: 0-based tables are used by the reorder / render code
local CHR = {}
for i = 0, 255 do CHR[i] = string.char(i) end

local function to_bytes(s)
    local t = {}
    for i = 1, #s do t[i - 1] = s:byte(i) end
    return t
end

local function from_bytes(t, n)
    local parts = {}
    for i = 0, n - 1 do parts[i + 1] = CHR[t[i] or 0] end
    return table.concat(parts)
end

-- ============================================================================
-- Standard EGA 16-color palette
-- ============================================================================

local function ega_palette()
    local c = {
        {0,0,0},{0,0,170},{0,170,0},{0,170,170},
        {170,0,0},{170,0,170},{170,85,0},{170,170,170},
        {85,85,85},{85,85,255},{85,255,85},{85,255,255},
        {255,85,85},{255,85,255},{255,255,85},{255,255,255},
    }
    local pal = {}
    for i = 0, 15 do
        pal[i*3+1] = c[i+1][1]; pal[i*3+2] = c[i+1][2]; pal[i*3+3] = c[i+1][3]
    end
    for i = 16, 255 do pal[i*3+1]=0; pal[i*3+2]=0; pal[i*3+3]=0 end
    return pal
end

local function copy_palette(pal)
    local t = {}
    for i = 1, 768 do t[i] = pal[i] or 0 end
    return t
end

-- ============================================================================
-- LZW decompressor
--   SCI0:    LSB-first, code size grows when the table reaches 512 entries
--   SCI1/01: MSB-first, code size grows one code early ("early change")
-- Port of ScummVM DecompressorLZW::unpackLZW.
-- ============================================================================

local function lzw_unpack(data, expected, msb)
    local out, n = {}, 0
    local soff, slen = {}, {}
    local bitlen, tsize = 9, 258
    local limit = msb and 511 or 512
    local spos, nd = 1, #data
    local bbuf, bcount = 0, 0

    while n < expected do
        while bcount < bitlen and spos <= nd do
            if msb then
                bbuf = bbuf * 256 + data:byte(spos)
            else
                bbuf = bbuf + data:byte(spos) * POW2[bcount]
            end
            bcount = bcount + 8
            spos = spos + 1
        end
        if bcount < bitlen then break end

        local code
        if msb then
            bcount = bcount - bitlen
            code = floor(bbuf / POW2[bcount])
            bbuf = bbuf - code * POW2[bcount]
        else
            code = bbuf % POW2[bitlen]
            bbuf = (bbuf - code) / POW2[bitlen]
            bcount = bcount - bitlen
        end

        if code >= tsize or code == 257 then break end

        if code == 256 then
            bitlen, tsize = 9, 258
            limit = msb and 511 or 512
        else
            local newoff = n
            if code <= 255 then
                out[n] = code
                n = n + 1
            else
                local o = soff[code]
                for i = 0, slen[code] - 1 do
                    if n >= expected then break end
                    out[n] = out[o + i] or 0
                    n = n + 1
                end
            end

            if tsize < 4096 then
                if tsize == limit and bitlen < 12 then
                    bitlen = bitlen + 1
                    limit = POW2[bitlen] - (msb and 1 or 0)
                end
                soff[tsize] = newoff
                slen[tsize] = n - newoff + 1
                tsize = tsize + 1
            end
        end
    end

    return from_bytes(out, math.min(n, expected))
end

-- ============================================================================
-- Huffman decompressor (SCI0 method 2 / SCI1 method 1), MSB-first
-- Port of ScummVM DecompressorHuffman.
-- ============================================================================

local function huffman_unpack(data, expected)
    if #data < 2 then return nil end
    local numnodes = data:byte(1)
    local term = data:byte(2) + 256
    local nodes_base = 3                       -- 1-based position of node 0
    local spos = nodes_base + numnodes * 2
    local nd = #data
    local bbuf, bcount = 0, 0

    local function bits(n)
        while bcount < n do
            if spos > nd then return nil end
            bbuf = bbuf * 256 + data:byte(spos)
            spos = spos + 1
            bcount = bcount + 8
        end
        bcount = bcount - n
        local v = floor(bbuf / POW2[bcount])
        bbuf = bbuf - v * POW2[bcount]
        return v
    end

    local out, n = {}, 0
    while n < expected do
        local p = 0                            -- byte offset of current node
        local c
        while true do
            local b1 = data:byte(nodes_base + p + 1)
            if not b1 then c = nil; break end
            if b1 == 0 then c = data:byte(nodes_base + p); break end
            local bit = bits(1)
            if bit == nil then c = nil; break end
            local nxt
            if bit == 1 then
                nxt = b1 % 16
                if nxt == 0 then
                    local v = bits(8)
                    c = v and (v + 256) or nil
                    break
                end
            else
                nxt = floor(b1 / 16)
            end
            p = p + nxt * 2
        end
        if c == nil or c == term then break end
        out[n] = c % 256
        n = n + 1
    end

    return from_bytes(out, n)
end

-- ============================================================================
-- LZS (STACpack) decompressor (SCI2.1+), MSB-first
-- Port of ScummVM DecompressorLZS.
-- ============================================================================

local function lzs_unpack(data, expected)
    local spos, nd = 1, #data
    local bbuf, bcount = 0, 0
    local function bits(k)
        while bcount < k do
            if spos > nd then return nil end
            bbuf = bbuf * 256 + data:byte(spos)
            spos = spos + 1
            bcount = bcount + 8
        end
        bcount = bcount - k
        local v = floor(bbuf / POW2[bcount])
        bbuf = bbuf - v * POW2[bcount]
        return v
    end
    local function comp_len()
        local v = bits(2)
        if v == 0 then return 2 elseif v == 1 then return 3 elseif v == 2 then return 4 end
        v = bits(2)
        if v == 0 then return 5 elseif v == 1 then return 6 elseif v == 2 then return 7 end
        local clen = 8
        while true do
            local nib = bits(4)
            if not nib then return clen end
            clen = clen + nib
            if nib ~= 15 then break end
        end
        return clen
    end

    local out, n = {}, 0
    while n < expected do
        local b = bits(1)
        if b == nil then break end
        if b == 1 then
            local offs
            if bits(1) == 1 then
                offs = bits(7)
                if not offs or offs == 0 then break end
            else
                offs = bits(11)
                if not offs then break end
            end
            local clen = comp_len()
            local h = n - offs
            for _ = 1, clen do
                out[n] = out[h] or 0
                n = n + 1; h = h + 1
            end
        else
            local v = bits(8)
            if not v then break end
            out[n] = v
            n = n + 1
        end
    end
    return from_bytes(out, math.min(n, expected))
end

-- ============================================================================
-- DCL / Implode decompressor (method 18, LSB-first)
-- ============================================================================

-- DCL Shannon-Fano Huffman trees (ported from ScummVM common/compression/dcl.cpp)
-- Encoding: Branch nodes = left_child*4096 + right_child (0-indexed positions)
--           Leaf nodes   = value + 1000000
local DCL_LEN_TREE = {
    [0]=4098, 12292, 20486, 28680, 36874, 45068, 1000001,
    53262, 61456, 69650, 1000003, 1000002, 1000000,
    77844, 86038, 94232, 1000006, 1000005, 1000004,
    102426, 110620, 1000010, 1000009, 1000008, 1000007,
    118814, 1000013, 1000012, 1000011, 1000015, 1000014
}
local DCL_DIST_TREE = {
    [0]=4098, 12292, 20486, 28680, 36874, 45068, 1000000,
    53262, 61456, 69650, 77844, 86038, 94232,
    102426, 110620, 118814, 127008, 135202, 143396, 151590, 159784, 167978, 176172,
    1000002, 1000001,
    184366, 192560, 200754, 208948, 217142, 225336, 233530, 241724,
    249918, 258112, 266306, 274500, 282694, 290888, 299082, 307276,
    1000006, 1000005, 1000004, 1000003,
    315470, 323664, 331858, 340052, 348246, 356440, 364634, 372828,
    381022, 389216, 397410, 405604, 413798, 421992, 430186, 438380, 446574,
    1000021, 1000020, 1000019, 1000018, 1000017, 1000016, 1000015,
    1000014, 1000013, 1000012, 1000011, 1000010, 1000009, 1000008, 1000007,
    454768, 462962, 471156, 479350, 487544, 495738, 503932, 512126,
    1000047, 1000046, 1000045, 1000044, 1000043, 1000042, 1000041, 1000040,
    1000039, 1000038, 1000037, 1000036, 1000035, 1000034, 1000033, 1000032,
    1000031, 1000030, 1000029, 1000028, 1000027, 1000026, 1000025, 1000024,
    1000023, 1000022,
    1000063, 1000062, 1000061, 1000060, 1000059, 1000058, 1000057, 1000056,
    1000055, 1000054, 1000053, 1000052, 1000051, 1000050, 1000049, 1000048
}

local function dcl_decompress(data, expected_size)
    if #data < 2 then return nil end
    local spos = 1
    local bbuf = 0
    local bcount = 0

    local function read_bits_lsb(n)
        while bcount < n do
            if spos > #data then return 0 end
            bbuf = bbuf + data:byte(spos) * POW2[bcount]
            bcount = bcount + 8
            spos = spos + 1
        end
        local val = bbuf % POW2[n]
        bbuf = math.floor(bbuf / POW2[n])
        bcount = bcount - n
        return val
    end

    local function read_byte_lsb()
        return read_bits_lsb(8)
    end

    local function huffman_lookup(tree)
        local pos = 0
        while tree[pos] < 1000000 do
            local node = tree[pos]
            if read_bits_lsb(1) == 1 then
                pos = node % 4096       -- right child
            else
                pos = math.floor(node / 4096) -- left child
            end
        end
        return tree[pos] - 1000000
    end

    local mode = read_byte_lsb()       -- 0=binary, 1=ASCII
    local dict_type = read_byte_lsb()  -- 4,5,6

    local dict_size
    if dict_type == 4 then dict_size = 1024
    elseif dict_type == 5 then dict_size = 2048
    elseif dict_type == 6 then dict_size = 4096
    else return nil end

    local dict = {}
    local dict_pos = 0
    local out = {}
    local out_n = 0

    while out_n < expected_size do
        if read_bits_lsb(1) == 1 then
            -- Match: (length, distance)
            local len_val = huffman_lookup(DCL_LEN_TREE)
            local token_len
            if len_val < 8 then
                token_len = len_val + 2
            else
                token_len = 8 + POW2[len_val - 7] + read_bits_lsb(len_val - 7)
            end
            if token_len == 519 then break end  -- end of stream

            local dist_val = huffman_lookup(DCL_DIST_TREE)
            local token_off
            if token_len == 2 then
                token_off = dist_val * 4 + read_bits_lsb(2)
            else
                token_off = dist_val * POW2[dict_type] + read_bits_lsb(dict_type)
            end
            token_off = token_off + 1

            -- Copy from dictionary (matches ScummVM's copy loop)
            local base_idx = (dict_pos - token_off) % dict_size
            local didx = base_idx
            local orig_dict_pos = dict_pos
            local next_idx = dict_pos
            for _ = 1, token_len do
                local byte_val = dict[didx] or 0
                out_n = out_n + 1
                out[out_n] = byte_val
                dict[next_idx] = byte_val
                next_idx = (next_idx + 1) % dict_size
                didx = (didx + 1) % dict_size
                if didx == orig_dict_pos then
                    didx = base_idx
                end
            end
            dict_pos = next_idx
        else
            -- Literal byte
            local byte_val = read_byte_lsb()
            out_n = out_n + 1
            out[out_n] = byte_val
            dict[dict_pos] = byte_val
            dict_pos = (dict_pos + 1) % dict_size
        end
    end

    local t = {}
    local limit = math.min(out_n, expected_size)
    for i = 1, limit do t[i] = string.char(out[i]) end
    return table.concat(t)
end

-- ============================================================================
-- SCI1 "LZW1" view / pic reordering (compression methods 3 and 4)
-- Ports of ScummVM DecompressorLZW::reorderView / reorderPic.
-- The packer splits the RLE command stream from the literal pixel data; the
-- reorder step rebuilds the regular (interleaved) resource layout.
-- ============================================================================

local function rle_size(s, p, dsize)
    local pos, size = 0, 0
    while pos < dsize do
        local b = s[p] or 0
        p = p + 1
        pos = pos + 1
        size = size + 1
        local k = floor(b / 64)
        if k <= 1 then pos = pos + b
        elseif k == 2 then pos = pos + 1 end
    end
    return size
end

-- Copies RLE commands from s[rp..] and literal bytes from s[pp..] into
-- dest[w..] in interleaved form. Returns the new rp, pp.
local function decode_rle(s, rp, pp, dest, w, size)
    local pos = 0
    while pos < size do
        local b = s[rp] or 0
        rp = rp + 1
        dest[w] = b; w = w + 1
        pos = pos + 1
        local k = floor(b / 64)
        if k <= 1 then
            for _ = 1, b do
                dest[w] = s[pp] or 0; w = w + 1; pp = pp + 1
            end
            pos = pos + b
        elseif k == 2 then
            dest[w] = s[pp] or 0; w = w + 1; pp = pp + 1
            pos = pos + 1
        end
    end
    return rp, pp
end

local function reorder_pic(src, dsize)
    local PAL_SIZE = 1284
    local s = to_bytes(src)
    local function u16(p) return (s[p] or 0) + (s[p + 1] or 0) * 256 end

    local dest = {}
    for i = 0, dsize - 1 do dest[i] = 0 end
    local w = 0
    dest[w] = 0xFE; w = w + 1             -- OPX
    dest[w] = 2; w = w + 1                -- SET_PALETTE
    for i = 0, 255 do dest[w] = i; w = w + 1 end   -- translation map
    for _ = 1, 4 do dest[w] = 0; w = w + 1 end      -- stamp

    local view_size  = u16(0)
    local view_start = u16(2)
    local cdata_size = u16(4)
    local sp = 6

    local viewdata = {}
    for i = 0, 6 do viewdata[i] = s[sp + i] or 0 end
    sp = sp + 7

    for i = 0, 1023 do dest[w] = s[sp + i] or 0; w = w + 1 end
    sp = sp + 1024

    if view_start ~= PAL_SIZE + 2 then
        local n = view_start - PAL_SIZE - 2
        for i = 0, n - 1 do dest[w] = s[sp + i] or 0; w = w + 1 end
        sp = sp + n
    end

    if dsize ~= view_start + 15 + view_size then
        local tail = dsize - view_size - view_start - 15
        local base = view_size + view_start + 15
        for i = 0, tail - 1 do dest[base + i] = s[sp + i] or 0 end
        sp = sp + tail
    end

    local cdata = sp                       -- literal pixel bytes
    sp = sp + cdata_size

    w = view_start
    dest[w] = 0xFE; dest[w + 1] = 1       -- OPX EMBEDDED_VIEW
    dest[w + 2] = 0; dest[w + 3] = 0; dest[w + 4] = 0
    w = w + 5
    local vs = view_size + 8
    dest[w] = vs % 256; dest[w + 1] = floor(vs / 256) % 256
    w = w + 2
    for i = 0, 6 do dest[w + i] = viewdata[i] end
    w = w + 7
    dest[w] = 0; w = w + 1

    decode_rle(s, sp, cdata, dest, w, view_size)
    return from_bytes(dest, dsize)
end

local function reorder_view(src)
    local s = to_bytes(src)
    local function u16(p) return (s[p] or 0) + (s[p + 1] or 0) * 256 end

    local dest, w = {}, 0
    local function put(v) dest[w] = v; w = w + 1 end
    local function put16(v) put(v % 256); put(floor(v / 256) % 256) end

    local cellengths = u16(0) + 2
    local sp = 2
    local loopheaders = s[sp]; sp = sp + 1
    local lh_present  = s[sp]; sp = sp + 1
    local lh_mask     = u16(sp); sp = sp + 2
    local unknown     = u16(sp); sp = sp + 2
    local pal_offset  = u16(sp); sp = sp + 2
    local cel_total   = u16(sp); sp = sp + 2

    local cc_lengths = {}
    for c = 0, cel_total - 1 do cc_lengths[c] = u16(cellengths + 2 * c) end

    put(loopheaders); put(0x80)
    put16(lh_mask); put16(unknown); put16(pal_offset)

    local lh_ptr = w
    for _ = 1, 2 * loopheaders do put(0) end

    local celcounts = {}
    for i = 0, lh_present - 1 do celcounts[i] = s[sp + i] or 0 end
    sp = sp + lh_present

    local lb, celindex, lh_last, wi = 1, 0, -1, 0
    local cc_pos = {}

    for _ = 0, loopheaders - 1 do
        local entry
        if floor(lh_mask / lb) % 2 == 1 then
            -- loop not present: reuse the previous loop
            if lh_last == -1 then lh_last = 0 end
            entry = lh_last
        else
            lh_last = w
            entry = w
            local cnt = celcounts[wi] or 0
            put16(cnt); put16(0)
            local chptr = w + 2 * cnt
            for c = 0, cnt - 1 do
                put16(chptr)
                cc_pos[celindex + c] = chptr
                chptr = chptr + 8 + (cc_lengths[celindex + c] or 0)
            end
            for c = 0, cnt - 1 do
                for i = 0, 5 do put(s[sp + i] or 0) end
                sp = sp + 6
                put16(s[sp] or 0); sp = sp + 1
                for _ = 1, (cc_lengths[celindex + c] or 0) do put(0) end
            end
            celindex = celindex + cnt
            wi = wi + 1
        end
        dest[lh_ptr] = entry % 256
        dest[lh_ptr + 1] = floor(entry / 256) % 256
        lh_ptr = lh_ptr + 2
        lb = lb * 2
    end

    if celindex < cel_total then return nil end

    local rle_ptr = cellengths + 2 * cel_total
    local pix_ptr = rle_ptr
    for c = 0, cel_total - 1 do
        pix_ptr = pix_ptr + rle_size(s, pix_ptr, cc_lengths[c])
    end
    for c = 0, cel_total - 1 do
        rle_ptr, pix_ptr = decode_rle(s, rle_ptr, pix_ptr, dest, cc_pos[c] + 8, cc_lengths[c])
    end

    if pal_offset ~= 0 then
        put(0x50); put(0x41); put(0x4C)    -- "PAL"
        for c = 0, 255 do put(c) end
        sp = sp - 4                         -- "the missing four"
        for i = 0, 1027 do put(s[sp + i] or 0) end
    end

    return from_bytes(dest, w)
end

-- ============================================================================
-- Resource type names
-- ============================================================================

local RES_NAMES = {
    [0] = "Views", [1] = "Pics", [2] = "Scripts", [3] = "Texts",
    [4] = "Sounds", [5] = "Memory", [6] = "Vocab", [7] = "Fonts",
    [8] = "Cursors", [9] = "Patches", [10] = "Bitmaps",
    [11] = "Palettes", [15] = "Messages", [17] = "Heaps",
}

-- SCI2.1 uses a different type table
local RES_NAMES21 = {
    [0] = "Views", [1] = "Pics", [2] = "Scripts", [3] = "Animations",
    [4] = "Sounds", [5] = "Etc", [6] = "Vocab", [7] = "Fonts",
    [8] = "Cursors", [9] = "Patches", [10] = "Bitmaps",
    [11] = "Palettes", [12] = "Audio", [13] = "Audio", [14] = "Sync",
    [15] = "Messages", [16] = "Maps", [17] = "Heaps", [18] = "Chunks",
    [19] = "Audio36", [20] = "Sync36", [21] = "Translations",
    [22] = "Robots", [23] = "VMDs", [24] = "Ducks", [25] = "Cluts",
    [26] = "TGAs", [27] = "ZZZ",
}

local function res_names(info)
    return info.ver == "sci2" and RES_NAMES21 or RES_NAMES
end

-- ============================================================================
-- Map parsers: SCI0, SCI1, SCI1.1, SCI2.1
-- ============================================================================

-- Detect SCI version from the map data
local function detect_sci_version(data)
    local first = data:byte(1)
    if first >= 0x80 then
        -- SCI1/SCI1.1 directory format; detect sub-version from entry size
        local pos = 1
        local offsets = {}
        while pos + 2 <= #data do
            local t = data:byte(pos)
            if t >= 0xFF then break end
            local off = u16le(data, pos + 1)
            table.insert(offsets, off)
            pos = pos + 3
        end
        if #offsets >= 2 then
            -- Check ALL consecutive spans for consistent entry size
            local all_mod5 = true
            local all_mod6 = true
            for i = 2, #offsets do
                local span = offsets[i] - offsets[i-1]
                if span > 0 then
                    if span % 5 ~= 0 then all_mod5 = false end
                    if span % 6 ~= 0 then all_mod6 = false end
                end
            end
            if all_mod5 and not all_mod6 then return "sci11" end
            if not all_mod5 and all_mod6 then return "sci1" end
            -- Both divide evenly: validate first entries as 5-byte
            if all_mod5 then
                local p = offsets[1] + 1
                local valid5 = true
                local n5 = math.min(3, floor((offsets[2] - offsets[1]) / 5))
                for _ = 1, n5 do
                    if p + 4 <= #data then
                        local rnum = u16le(data, p)
                        if rnum > 2048 and rnum ~= 0xFFFF then valid5 = false end
                        p = p + 5
                    end
                end
                if valid5 then return "sci11" end
            end
        end
        return "sci1"
    end
    return "sci0"
end

local function parse_map_sci0(data)
    local resources = {}
    local pos = 1
    while pos + 5 <= #data do
        local type_id = u16le(data, pos)
        if type_id == 0xFFFF then break end
        local rtype = floor(type_id / 2048)
        local rnum = type_id % 2048
        local off_data = u32le(data, pos + 2)
        local vol = floor(off_data / POW2[26])
        local offset = off_data % POW2[26]
        table.insert(resources, {
            type = rtype, number = rnum,
            volume = vol, offset = offset,
        })
        pos = pos + 6
    end
    return resources
end

local function read_directory(data)
    -- Directory: 3-byte entries (u8 type, u16le offset), terminated by 0xFF
    local dir = {}
    local pos = 1
    while pos + 2 <= #data do
        local t = data:byte(pos)
        if t >= 0xFF then break end
        local off = u16le(data, pos + 1)
        table.insert(dir, { type = t - 0x80, offset = off })
        pos = pos + 3
    end
    -- the terminator carries the end offset of the last block
    local last_end = (pos + 2 <= #data) and u16le(data, pos + 1) or #data
    return dir, last_end
end

local function parse_map_sci1(data)
    local dir, last_end = read_directory(data)
    local resources = {}
    for di = 1, #dir do
        local rtype = dir[di].type
        local p = dir[di].offset + 1  -- 1-indexed
        local stop = (di < #dir) and dir[di + 1].offset or last_end
        while p + 5 <= #data and p <= stop do
            local rnum = u16le(data, p)
            if rnum == 0xFFFF then break end
            local off_data = u32le(data, p + 2)
            local vol = floor(off_data / POW2[28])
            local offset = off_data % POW2[28]
            table.insert(resources, {
                type = rtype, number = rnum,
                volume = vol, offset = offset,
            })
            p = p + 6
        end
    end
    return resources
end

local function parse_map_sci11(data)
    local dir, last_end = read_directory(data)
    local resources = {}
    for di = 1, #dir do
        local rtype = dir[di].type
        local p = dir[di].offset + 1  -- 1-indexed
        local stop = (di < #dir) and dir[di + 1].offset or last_end
        while p + 4 <= #data and p <= stop do
            local rnum = u16le(data, p)
            if rnum == 0xFFFF then break end
            -- 3-byte offset: actual_offset = raw * 2
            local raw_off = data:byte(p + 2)
                          + data:byte(p + 3) * 256
                          + data:byte(p + 4) * 65536
            table.insert(resources, {
                type = rtype, number = rnum,
                volume = 0, offset = raw_off * 2,
            })
            p = p + 5
        end
    end
    return resources
end

-- SCI2.1 RESMAP.000: directory of (u8 type, u16 offset) ended by 0xFF, then
-- per type u16 number + u32 plain offset into RESSCI.000.
local function parse_map_sci2(data)
    local dir = {}
    local pos = 1
    while pos + 2 <= #data do
        local t = data:byte(pos)
        local off = u16le(data, pos + 1)
        if t == 0xFF then dir[#dir + 1] = { type = -1, offset = off }; break end
        dir[#dir + 1] = { type = t % 32, offset = off }
        pos = pos + 3
    end
    local resources = {}
    for di = 1, #dir - 1 do
        local p = dir[di].offset + 1
        local stop = dir[di + 1].offset
        while p + 5 <= #data and p <= stop - 5 do
            table.insert(resources, {
                type = dir[di].type, number = u16le(data, p),
                volume = 0, offset = u32le(data, p + 2),
            })
            p = p + 6
        end
    end
    return resources
end

-- ============================================================================
-- Resource volume readers
-- ============================================================================

-- Resource header layouts:
--   SCI0:   u16 id, u16 packed(+4), u16 unpacked, u16 method           (8 bytes)
--   SCI1:   u8 type, u16 num, u16 packed(+4), u16 unpacked, u16 method (9 bytes)
--   SCI1.1: u8 type, u16 num, u16 packed,     u16 unpacked, u16 method (9 bytes)
local function read_resource_header(fh, ver, offset)
    if ver == "sci0" then
        local hdr = file_read(fh, offset, 8)
        if not hdr or #hdr < 8 then return nil end
        return { packed = u16le(hdr, 3) - 4, unpacked = u16le(hdr, 5),
                 method = u16le(hdr, 7), skip = 8 }
    end
    if ver == "sci2" then
        local hdr = file_read(fh, offset, 13)
        if not hdr or #hdr < 13 then return nil end
        local packed, unpacked = u32le(hdr, 4), u32le(hdr, 8)
        -- the stored compression field is unreliable: LZS whenever sizes differ
        return { packed = packed, unpacked = unpacked,
                 method = packed ~= unpacked and 32 or 0, skip = 13 }
    end
    local hdr = file_read(fh, offset, 9)
    if not hdr or #hdr < 9 then return nil end
    local packed = u16le(hdr, 4)
    if ver == "sci1" then packed = packed - 4 end
    return { packed = packed, unpacked = u16le(hdr, 6),
             method = u16le(hdr, 8), skip = 9 }
end

-- Compression method ids differ between SCI generations:
--   "old" (SCI0/SCI01): 1 = LZW (LSB), 2 = Huffman
--   "new" (SCI1+):      1 = Huffman, 2 = LZW1 (MSB), 3 = view LZW1, 4 = pic LZW1
--   18/19/20 = DCL implode (SCI1 late / SCI1.1)
local function decompress_resource(raw, method, unpack_sz, numbering)
    if method == 0 then
        return raw
    end
    if method == 18 or method == 19 or method == 20 then
        return dcl_decompress(raw, unpack_sz)
    end
    if method == 32 then
        return lzs_unpack(raw, unpack_sz)
    end
    if numbering == "old" then
        if method == 1 then return lzw_unpack(raw, unpack_sz, false) end
        if method == 2 then return huffman_unpack(raw, unpack_sz) end
    else
        if method == 1 then return huffman_unpack(raw, unpack_sz) end
        if method == 2 then return lzw_unpack(raw, unpack_sz, true) end
        if method == 3 then
            local data = lzw_unpack(raw, unpack_sz, true)
            return reorder_view(data)
        end
        if method == 4 then
            local data = lzw_unpack(raw, unpack_sz, true)
            return reorder_pic(data, unpack_sz)
        end
    end
    log_warn("SCI: unsupported compression method " .. method)
    return nil
end

local function read_resource(game_path, info, res)
    local vol_name = info.ver == "sci2" and "RESSCI.000"
        or string.format("RESOURCE.%03d", res.volume)
    local fh = file_open(game_path .. "/" .. vol_name)
    if not fh then return nil end
    local h = read_resource_header(fh, info.ver, res.offset)
    if not h then file_close(fh); return nil end
    local raw = h.packed > 0 and file_read(fh, res.offset + h.skip, h.packed) or ""
    file_close(fh)
    if not raw then return nil end
    return decompress_resource(raw, h.method, h.unpacked, info.numbering)
end

-- Parsed map + per-game facts, cached per game folder
local info_cache = {}
-- SCI2.1 games store palettes in the "hunk palette" layout
local use_hunk = false

local function get_info(game_path)
    local cached = info_cache[game_path]
    if cached then use_hunk = (cached.ver == "sci2"); return cached end

    local is_sci2 = not file_exists(game_path .. "/RESOURCE.MAP")
        and file_exists(game_path .. "/RESMAP.000")
    local fh = file_open(game_path .. (is_sci2 and "/RESMAP.000" or "/RESOURCE.MAP"))
    if not fh then return nil end
    local data = file_read(fh, 0, file_size(fh))
    file_close(fh)
    if not data or #data < 6 then return nil end

    local ver = is_sci2 and "sci2" or detect_sci_version(data)
    local resources
    if ver == "sci2" then
        resources = parse_map_sci2(data)
    elseif ver == "sci11" then
        resources = parse_map_sci11(data)
    elseif ver == "sci1" then
        resources = parse_map_sci1(data)
    else
        resources = parse_map_sci0(data)
    end

    -- Some maps list a resource once per disk volume; like the interpreter,
    -- keep the first entry only.
    local info = { ver = ver, resources = {}, numbering = "new", vga = true,
                   index = {} }
    for _, r in ipairs(resources) do
        local key = r.type * 65536 + r.number
        if not info.index[key] then
            info.index[key] = r
            table.insert(info.resources, r)
        end
    end
    resources = info.resources

    if ver == "sci0" then
        -- SCI0 and SCI01/early-SCI1 share this map layout; method ids 3/4
        -- (view / pic LZW1) only exist in the SCI1 numbering.
        info.numbering = "old"
        info.vga = false
        local handles = {}
        for _, r in ipairs(resources) do
            local fhv = handles[r.volume]
            if fhv == nil then
                fhv = file_open(game_path .. "/" .. string.format("RESOURCE.%03d", r.volume)) or false
                handles[r.volume] = fhv
            end
            if fhv then
                local h = read_resource_header(fhv, "sci0", r.offset)
                if h and (h.method == 3 or h.method == 4) then
                    info.numbering = "new"
                    info.vga = true
                    break
                end
            end
        end
        for _, fhv in pairs(handles) do
            if fhv then file_close(fhv) end
        end
    elseif ver == "sci1" then
        -- SCI1 can still be an EGA game; sample a view to tell
        info.vga = false
        local tried = 0
        for _, r in ipairs(resources) do
            if r.type == 0 then
                local d = read_resource(game_path, info, r)
                if d and #d > 10 then
                    if d:byte(2) == 0x80 or d:byte(2) == 0xC0 then info.vga = true end
                    tried = tried + 1
                    if info.vga or tried >= 3 then break end
                end
            end
        end
    end

    info_cache[game_path] = info
    use_hunk = (info.ver == "sci2")
    return info
end

local function find_resource(info, rtype, rnum)
    return info.index[rtype * 65536 + rnum]
end

-- ============================================================================
-- VGA Palette Parser (type 11 resources, embedded palettes)
-- ============================================================================

-- SCI2.1 palette: 13 byte header (palette count at 10), u16 offsets, then an
-- entry with a 22 byte header followed by [used,]r,g,b per color
local function parse_hunk_palette(data)
    if not data or #data < 14 or u8(data, 11) == 0 then return nil end
    local pal = {}
    for i = 0, 255 do pal[i*3+1]=0; pal[i*3+2]=0; pal[i*3+3]=0 end
    local entry = 13 + 2 * u8(data, 11) -- entries follow the header and offset table
    local e = entry + 1
    if e + 22 > #data then return nil end
    local start = u8(data, e + 10)
    local count = u16le(data, e + 14)
    local shared = u8(data, e + 17) ~= 0
    local pos = e + 22
    for i = 0, count - 1 do
        local ci = start + i
        if ci > 255 then break end
        if not shared then pos = pos + 1 end
        if pos + 2 > #data then break end
        pal[ci*3+1] = u8(data, pos)
        pal[ci*3+2] = u8(data, pos + 1)
        pal[ci*3+3] = u8(data, pos + 2)
        pos = pos + 3
    end
    return pal
end

local function parse_vga_palette(data)
    if use_hunk then return parse_hunk_palette(data) end
    if not data or #data < 37 then return nil end

    local pal = {}
    for i = 0, 255 do pal[i*3+1]=0; pal[i*3+2]=0; pal[i*3+3]=0 end

    if (u8(data, 1) == 0 and u8(data, 2) == 1)
       or (u8(data, 1) == 0 and u8(data, 2) == 0 and u16le(data, 30) == 0) then
        -- SCI0/SCI1 format: 256-byte mapping + 4-byte timestamp + 256x4 palette
        -- Each entry is 4 bytes: [used, R, G, B]
        if #data < 260 + 1024 then return nil end
        for i = 0, 255 do
            local ep = 261 + i * 4   -- skip 'used' flag at ep, read R,G,B
            pal[i*3+1] = u8(data, ep + 1)
            pal[i*3+2] = u8(data, ep + 2)
            pal[i*3+3] = u8(data, ep + 3)
        end
    else
        -- SCI1.1 format
        local color_start = u8(data, 26)       -- offset 25 (0-based)
        local color_count = u16le(data, 30)    -- offset 29
        local fmt = u8(data, 33)               -- offset 32
        local pos = 38                         -- offset 37

        for i = 0, color_count - 1 do
            local ci = color_start + i
            if ci > 255 then break end
            if fmt == 0 then
                -- Variable: 4 bytes (used, R, G, B)
                if pos + 3 > #data then break end
                pos = pos + 1  -- skip 'used' flag
                pal[ci*3+1] = u8(data, pos)
                pal[ci*3+2] = u8(data, pos + 1)
                pal[ci*3+3] = u8(data, pos + 2)
                pos = pos + 3
            else
                -- Constant: 3 bytes (R, G, B)
                if pos + 2 > #data then break end
                pal[ci*3+1] = u8(data, pos)
                pal[ci*3+2] = u8(data, pos + 1)
                pal[ci*3+3] = u8(data, pos + 2)
                pos = pos + 3
            end
        end
    end

    return pal
end

local function grayscale_palette()
    local pal = {}
    for i = 0, 255 do pal[i*3+1]=i; pal[i*3+2]=i; pal[i*3+3]=i end
    return pal
end

-- The palette the game boots with: 999, else 0 / 1, else the first palette
local function default_palette_res(info)
    if info.default_pal == nil then
        info.default_pal = false
        for _, pnum in ipairs({999, 0, 1}) do
            local r = find_resource(info, 11, pnum)
            if r then info.default_pal = r; break end
        end
        if not info.default_pal then
            for _, r in ipairs(info.resources) do
                if r.type == 11 then info.default_pal = r; break end
            end
        end
    end
    return info.default_pal or nil
end

local function load_game_palette(game_path, info)
    local r = default_palette_res(info)
    if r then
        local data = read_resource(game_path, info, r)
        local pal = data and parse_vga_palette(data)
        if pal then return pal end
    end
    return grayscale_palette()
end

-- ============================================================================
-- Cel decoding (shared by views and embedded pic cels)
-- Offsets inside cel descriptors are 0-based file offsets.
-- ============================================================================

-- VGA RLE: XXYYYYYY, 00/01 = copy, 10 = fill, 11 = skip (transparent).
-- rle == nil -> uncompressed pixels at lit; lit == nil -> literals are inline.
local function decode_cel_vga(data, w, h, ck, rle, lit)
    local n = w * h
    local pix = {}
    for i = 1, n do pix[i] = ck end

    if not rle then
        if not lit then return nil end
        local lp = lit + 1
        for i = 1, n do pix[i] = data:byte(lp + i - 1) or ck end
        return pix
    end

    local rp = rle + 1
    local lp = lit and (lit + 1) or nil
    local pn = 0
    while pn < n do
        local b = data:byte(rp)
        if not b then break end
        rp = rp + 1
        local run = b % 64
        local k = floor(b / 64)
        if k == 1 then run = run + 64 end
        if k <= 1 then
            local cnt = math.min(run, n - pn)
            for i = 1, cnt do
                local v
                if lp then v = data:byte(lp); lp = lp + 1
                else v = data:byte(rp); rp = rp + 1 end
                pix[pn + i] = v or ck
            end
            if cnt < run then
                if lp then lp = lp + (run - cnt) else rp = rp + (run - cnt) end
            end
        elseif k == 2 then
            local v
            if lp then v = data:byte(lp); lp = lp + 1
            else v = data:byte(rp); rp = rp + 1 end
            v = v or ck
            for i = 1, math.min(run, n - pn) do pix[pn + i] = v end
        end
        pn = pn + run
    end
    return pix
end

-- EGA RLE: each byte is (run << 4) | color
local function decode_cel_ega(data, w, h, ck, off)
    local n = w * h
    local pix = {}
    for i = 1, n do pix[i] = ck end
    local rp = off + 1
    local pn = 0
    while pn < n do
        local b = data:byte(rp)
        if not b then break end
        rp = rp + 1
        local run = floor(b / 16)
        local col = b % 16
        for i = 1, math.min(run, n - pn) do pix[pn + i] = col end
        pn = pn + run
    end
    return pix
end

-- SCI2.1 cels: uncompressed pixels at `data`, or per-row RLE (ctrl table of
-- row offsets into `data`, then row offsets into the literal block `lit`)
local function decode_cel_sci32(data, cel)
    local w, h, ck = cel.width, cel.height, cel.clear_key
    local s = cel.sci32
    local pix = {}
    for i = 1, w * h do pix[i] = ck end
    if s.comp == 0 then
        local p = s.data + 1
        for i = 1, w * h do pix[i] = data:byte(p + i - 1) or ck end
        return pix
    end
    if s.comp ~= 138 then return nil end
    if s.ctrl + h * 8 > #data then return nil end
    for y = 0, h - 1 do
        local rp = s.data + u32le(data, s.ctrl + 1 + y * 4) + 1
        local lp = s.lit + u32le(data, s.ctrl + 1 + h * 4 + y * 4) + 1
        local i, base = 0, y * w + 1
        while i < w do
            local c = data:byte(rp)
            if not c then break end
            rp = rp + 1
            local len = c
            if c >= 128 then
                len = c % 64
                if floor(c / 64) % 2 == 1 then
                    -- skip color: already filled
                else
                    local v = data:byte(lp) or ck
                    lp = lp + 1
                    for k = 0, math.min(len, w - i) - 1 do pix[base + i + k] = v end
                end
            else
                for k = 0, math.min(len, w - i) - 1 do
                    pix[base + i + k] = data:byte(lp + k) or ck
                end
                lp = lp + len
            end
            if len == 0 then break end
            i = i + len
        end
    end
    return pix
end

local function decode_cel(data, cel)
    local pix
    if cel.sci32 then
        pix = decode_cel_sci32(data, cel)
    elseif cel.ega then
        pix = decode_cel_ega(data, cel.width, cel.height, cel.clear_key, cel.ega)
    else
        pix = decode_cel_vga(data, cel.width, cel.height, cel.clear_key, cel.rle, cel.lit)
    end
    if pix and cel.mirror then
        local w = cel.width
        for y = 0, cel.height - 1 do
            local a, b = y * w + 1, y * w + w
            while a < b do
                pix[a], pix[b] = pix[b], pix[a]
                a = a + 1; b = b - 1
            end
        end
    end
    return pix
end

-- ============================================================================
-- View parsers
-- ============================================================================

-- SCI0 / SCI01 / SCI1 views (EGA or VGA cels).
-- Header: loops:u8 flags:u8 mirrorMask:u16 version:u16 palOffset:u16 loopOffsets:u16*
-- Loop:   celCount:u16 unknown:u16 celOffsets:u16*
-- Cel:    w:u16 h:u16 dx:i8 dy:u8 clearKey:u8 data...
local function parse_view_old(data, vga)
    if #data < 10 then return nil end
    local loop_count = u8(data, 1)
    local flags = u8(data, 2)
    local mirror_bits = u16le(data, 3)
    local pal_off = u16le(data, 7)
    if loop_count < 1 then return nil end

    -- flag 0x80 marks a VGA view even in a game otherwise detected as EGA
    local use_vga = vga or flags == 0x80
    local compressed = (floor(flags / 64) % 2) == 0

    local loops = {}
    for lno = 0, loop_count - 1 do
        local lp = 9 + lno * 2
        if lp + 1 > #data then break end
        local loop_off = u16le(data, lp)
        local mirror = lno < 16 and (floor(mirror_bits / POW2[lno]) % 2 == 1)
        local cels = {}
        if loop_off + 4 <= #data then
            local cel_count = u16le(data, loop_off + 1)
            for cno = 0, cel_count - 1 do
                local cp = loop_off + 5 + cno * 2
                if cp + 1 > #data then break end
                local co = u16le(data, cp)
                if co + 8 > #data then break end
                local w = u16le(data, co + 1)
                local h = u16le(data, co + 3)
                local dx = i8(data, co + 5)
                local dy = u8(data, co + 6)
                local ck = u8(data, co + 7)
                if w < 1 or w > 1024 or h < 1 or h > 1024 then break end
                local cel = {
                    width = w, height = h, clear_key = ck,
                    displace_x = mirror and -dx or dx, displace_y = dy,
                    mirror = mirror,
                }
                if not use_vga then
                    cel.ega = co + 7
                elseif compressed then
                    cel.rle = co + 8
                else
                    cel.lit = co + 8
                end
                cels[#cels + 1] = cel
            end
        end
        loops[#loops + 1] = cels
    end

    local pal_ptr = (use_vga and pal_off > 0 and pal_off ~= 0x100) and (pal_off + 1) or 0
    return loops, pal_ptr, use_vga
end

-- SCI1.1 views.
-- Header: headerSize:u16 loops:u8 flags:u8 version:u16 unk:u16 palOffset:u32
--         (byte 12 = loop header size, byte 13 = cel header size)
-- Loop:   seekEntry:u8 (255 = own cels) mirror:u8 celCount:u8 ... celOffset:u32@12
-- Cel:    w:u16 h:u16 dx:i16 dy:i16 clearKey:u8 ... rle:u32@24 literal:u32@28
local function parse_view_sci11(data, sci32)
    if #data < 14 then return nil end

    local header_size = u16le(data, 1) + 2
    local loop_count = u8(data, 3)
    local pal_offset_raw = u32le(data, 9)
    local loop_hdr_size = u8(data, 13)
    local cel_hdr_size = u8(data, 14)
    if loop_hdr_size < 16 then loop_hdr_size = 16 end
    if cel_hdr_size < 32 then cel_hdr_size = 32 end

    if loop_count < 1 then return nil end

    local loops = {}
    for lno = 0, loop_count - 1 do
        local src = header_size + 1 + lno * loop_hdr_size  -- 1-based
        local mirror = false
        local seek = (src + 1 <= #data) and u8(data, src) or 255
        local guard = 0
        while seek ~= 255 and guard < 8 do
            mirror = true
            if seek >= loop_count then break end
            src = header_size + 1 + seek * loop_hdr_size
            seek = (src <= #data) and u8(data, src) or 255
            guard = guard + 1
        end

        local cels = {}
        if src + loop_hdr_size - 1 <= #data then
            local cel_count = u8(data, src + 2)
            local cel_base = u32le(data, src + 12)
            for cno = 0, cel_count - 1 do
                local cp = cel_base + 1 + cno * cel_hdr_size  -- 1-based
                if cp + cel_hdr_size - 1 > #data then break end

                local w = u16le(data, cp)
                local h = u16le(data, cp + 2)
                local dx = i16le(data, cp + 4)
                local dy = i16le(data, cp + 6)
                if dy < 0 and not sci32 then dy = dy + 255 end
                local ck = u8(data, cp + 8)
                local rle = u32le(data, cp + 24)
                local lit = u32le(data, cp + 28)
                if w < 1 or w > 2048 or h < 1 or h > 2048 then break end

                if sci32 then
                    cels[#cels + 1] = {
                        width = w, height = h, clear_key = ck,
                        displace_x = mirror and -dx or dx, displace_y = dy,
                        mirror = mirror,
                        sci32 = { comp = u8(data, cp + 9), data = rle, lit = lit,
                                  ctrl = u32le(data, cp + 32) },
                    }
                    goto next_cel
                end

                -- only an RLE offset means plain uncompressed pixels
                if rle > 0 and lit == 0 then rle, lit = 0, rle end

                cels[#cels + 1] = {
                    width = w, height = h, clear_key = ck,
                    displace_x = mirror and -dx or dx, displace_y = dy,
                    mirror = mirror,
                    rle = rle > 0 and rle or nil,
                    lit = lit > 0 and lit or nil,
                }
                ::next_cel::
            end
        end
        loops[#loops + 1] = cels
    end

    return loops, pal_offset_raw > 0 and (pal_offset_raw + 1) or 0, true
end

-- Builds one image per cel. Sprites with more than one cel are placed on a
-- common canvas, aligned on their origin point, so that stepping through the
-- frames shows the real animation. Transparent pixels are drawn magenta.
local function build_view_frames(data, loops, pal)
    local cels = {}
    for lno, loop in ipairs(loops) do
        for cno, cel in ipairs(loop) do
            local pix = decode_cel(data, cel)
            if pix then
                cels[#cels + 1] = { cel = cel, pix = pix, loop = lno - 1, idx = cno - 1 }
            end
        end
    end
    if #cels == 0 then return {} end

    -- origin of each cel: SCI places a cel at x - (w >> 1) + dx, bottom = y + dy
    local min_x, min_y, max_x, max_y = 1e9, 1e9, -1e9, -1e9
    local max_w, max_h = 0, 0
    for _, c in ipairs(cels) do
        local w, h = c.cel.width, c.cel.height
        c.ax = floor(w / 2) - c.cel.displace_x
        c.ay = h - 1 - c.cel.displace_y
        min_x = math.min(min_x, -c.ax); max_x = math.max(max_x, w - c.ax)
        min_y = math.min(min_y, -c.ay); max_y = math.max(max_y, h - c.ay)
        max_w = math.max(max_w, w); max_h = math.max(max_h, h)
    end

    local cw, ch = max_x - min_x, max_y - min_y
    local aligned = #cels > 1 and cw <= 1024 and ch <= 1024
    if not aligned then cw, ch = max_w, max_h end
    if #cels == 1 then cw, ch = cels[1].cel.width, cels[1].cel.height end

    local frames = {}
    for _, c in ipairs(cels) do
        local w, h, ck = c.cel.width, c.cel.height, c.cel.clear_key
        local px, py = 0, 0
        if #cels > 1 then
            if aligned then px, py = -c.ax - min_x, -c.ay - min_y
            else px, py = floor((cw - w) / 2), ch - h end
        end

        local pix = c.pix
        if cw ~= w or ch ~= h then
            local canvas = {}
            for i = 1, cw * ch do canvas[i] = ck end
            for y = 0, h - 1 do
                local dy = y + py
                if dy >= 0 and dy < ch then
                    for x = 0, w - 1 do
                        local dx = x + px
                        if dx >= 0 and dx < cw then
                            canvas[dy * cw + dx + 1] = pix[y * w + x + 1]
                        end
                    end
                end
            end
            pix = canvas
        end

        local tpal = copy_palette(pal)
        tpal[ck*3+1] = 255; tpal[ck*3+2] = 0; tpal[ck*3+3] = 255
        frames[#frames + 1] = {
            img = image_create_indexed(cw, ch, pix, tpal),
            loop = c.loop, cel = c.idx,
        }
    end
    return frames
end

-- ============================================================================
-- SCI vector pictures (EGA and VGA), SCI1.1 bitmap pictures
-- Port of ScummVM GfxPicture::drawVectorData and the GfxScreen primitives.
-- The picture is drawn on a 320x200 screen with a 10 pixel menu bar on top,
-- exactly as the interpreter does; only the visual screen is returned.
-- ============================================================================

local PIC_W, PIC_H, PIC_TOP = 320, 200, 10

-- Pen patterns (ScummVM vectorPatternCircles / vectorPatternTextures)
local PAT_CIRCLES = {
    [0] = { 0x01 },
    { 0x72, 0x02 },
    { 0xCE, 0xF7, 0x7D, 0x0E },
    { 0x1C, 0x3E, 0x7F, 0x7F, 0x7F, 0x3E, 0x1C, 0x00 },
    { 0x38, 0xF8, 0xF3, 0xDF, 0x7F, 0xFF, 0xFD, 0xF7, 0x9F, 0x3F, 0x38 },
    { 0x70, 0xC0, 0x1F, 0xFE, 0xE3, 0x3F, 0xFF, 0xF7, 0x7F, 0xFF, 0xE7, 0x3F, 0xFE, 0xC3, 0x1F, 0xF8, 0x00 },
    { 0xF0, 0x01, 0xFF, 0xE1, 0xFF, 0xF8, 0x3F, 0xFF, 0xDF, 0xFF, 0xF7, 0xFF, 0xFD, 0x7F, 0xFF, 0x9F, 0xFF,
      0xE3, 0xFF, 0xF0, 0x1F, 0xF0, 0x01 },
    { 0xE0, 0x03, 0xF8, 0x0F, 0xFC, 0x1F, 0xFE, 0x3F, 0xFE, 0x3F, 0xFF, 0x7F, 0xFF, 0x7F, 0xFF, 0x7F, 0xFF,
      0x7F, 0xFF, 0x7F, 0xFE, 0x3F, 0xFE, 0x3F, 0xFC, 0x1F, 0xF8, 0x0F, 0xE0, 0x03 },
}

local PAT_BYTES = {
    0x04, 0x29, 0x40, 0x24, 0x09, 0x41, 0x25, 0x45, 0x41, 0x90, 0x50, 0x44, 0x48, 0x08, 0x42, 0x28,
    0x89, 0x52, 0x89, 0x88, 0x10, 0x48, 0xA4, 0x08, 0x44, 0x15, 0x28, 0x24, 0x00, 0x0A, 0x24, 0x20,
}
local PAT_TEX = {}   -- bit table, 0-based, duplicated so it never needs to wrap
do
    local pn = 0
    for _ = 1, 2 do
        for i = 1, 32 do
            local v = PAT_BYTES[i]
            local nb = (i == 32) and 7 or 8   -- the last bit is ignored by the original
            for b = 0, nb - 1 do
                PAT_TEX[pn] = (floor(v / POW2[b]) % 2) == 1
                pn = pn + 1
            end
        end
    end
end

local PAT_TEX_OFFSET = {
    [0]=0x00, 0x18, 0x30, 0xc4, 0xdc, 0x65, 0xeb, 0x48,
    0x60, 0xbd, 0x89, 0x04, 0x0a, 0xf4, 0x7d, 0x6d,
    0x85, 0xb0, 0x8e, 0x95, 0x1f, 0x22, 0x0d, 0xdf,
    0x2a, 0x78, 0xd5, 0x73, 0x1c, 0xb4, 0x40, 0xa1,
    0xb9, 0x3c, 0xca, 0x58, 0x92, 0x34, 0xcc, 0xce,
    0xd7, 0x42, 0x90, 0x0f, 0x8b, 0x7f, 0x32, 0xed,
    0x5c, 0x9d, 0xc8, 0x99, 0xad, 0x4e, 0x56, 0xa6,
    0xf7, 0x68, 0xb7, 0x25, 0x82, 0x37, 0x3a, 0x51,
    0x69, 0x26, 0x38, 0x52, 0x9e, 0x9a, 0x4f, 0xa7,
    0x43, 0x10, 0x80, 0xee, 0x3d, 0x59, 0x35, 0xcf,
    0x79, 0x74, 0xb5, 0xa2, 0xb1, 0x96, 0x23, 0xe0,
    0xbe, 0x05, 0xf5, 0x6e, 0x19, 0xc5, 0x66, 0x49,
    0xf0, 0xd1, 0x54, 0xa9, 0x70, 0x4b, 0xa4, 0xe2,
    0xe6, 0xe5, 0xab, 0xe4, 0xd2, 0xaa, 0x4c, 0xe3,
    0x06, 0x6f, 0xc6, 0x4a, 0x75, 0xa3, 0x97, 0xe1,
}
for i = 120, 127 do PAT_TEX_OFFSET[i] = 0 end

local EGA_DEFAULT_PALETTE = {
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
    0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0x88,
    0x88, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x88,
    0x88, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
    0x08, 0x19, 0x2a, 0x3b, 0x4c, 0x5d, 0x6e, 0x88,
}

-- Draws the vector stream `vdata` onto a fresh screen.
--   is_ega     : EGA picture (dithered colors, 16 color palette)
--   vga_pal    : palette used until the stream sets one (VGA only)
-- Returns pixels (1-based, 320x190), palette, error message (or nil)
local function draw_vector_pic(vdata, is_ega, vga_pal, default_color)
    local N = PIC_W * PIC_H
    local vis, pri, ctl = {}, {}, {}
    local white = is_ega and 15 or 255
    for i = 0, N - 1 do vis[i] = white; pri[i] = 0; ctl[i] = 0 end

    local pal = vga_pal
    local d = to_bytes(vdata)
    local size = #vdata
    local err = nil

    local function B(p) return d[p] or 0xFF end
    local function nonop(p) return B(p) < 0xF0 end

    -- ---------------------------------------------------------------- pixels
    local function mask_of(color, prio, cont)
        return color ~= 255, prio ~= 255, cont ~= 255
    end

    local function put(x, y, mv, mp, mc, color, prio, cont)
        if x < 0 or x >= PIC_W or y < 0 or y >= PIC_H then return end
        local i = y * PIC_W + x
        if mv then vis[i] = color end
        if mp then pri[i] = prio end
        if mc then ctl[i] = cont end
    end

    local function draw_line(x1, y1, x2, y2, color, prio, cont)
        y1 = y1 + PIC_TOP; y2 = y2 + PIC_TOP
        local left   = math.max(0, math.min(x1, PIC_W - 1))
        local top    = math.max(0, math.min(y1, PIC_H - 1))
        local right  = math.max(0, math.min(x2, PIC_W - 1))
        local bottom = math.max(0, math.min(y2, PIC_H - 1))
        local mv, mp, mc = mask_of(color, prio, cont)

        if top == bottom then
            if right < left then left, right = right, left end
            for x = left, right do put(x, top, mv, mp, mc, color, prio, cont) end
            return
        end
        if left == right then
            if top > bottom then top, bottom = bottom, top end
            for y = top, bottom do put(left, y, mv, mp, mc, color, prio, cont) end
            return
        end

        local dy = bottom - top
        local dx = right - left
        local stepy = dy < 0 and -1 or 1
        local stepx = dx < 0 and -1 or 1
        dy = math.abs(dy) * 2
        dx = math.abs(dx) * 2

        put(left, top, mv, mp, mc, color, prio, cont)
        put(right, bottom, mv, mp, mc, color, prio, cont)
        if dx > dy then
            local fraction = dy - floor(dx / 2)
            while left ~= right do
                if fraction >= 0 then top = top + stepy; fraction = fraction - dx end
                left = left + stepx
                fraction = fraction + dy
                put(left, top, mv, mp, mc, color, prio, cont)
            end
        else
            local fraction = dx - floor(dy / 2)
            while top ~= bottom do
                if fraction >= 0 then left = left + stepx; fraction = fraction - dy end
                top = top + stepy
                fraction = fraction + dx
                put(left, top, mv, mp, mc, color, prio, cont)
            end
        end
    end

    -- ------------------------------------------------------------ flood fill
    local function flood_fill(x, y, color, prio, cont)
        local px, py = x, y + PIC_TOP
        if px < 0 or px >= PIC_W or py < 0 or py >= PIC_H then return end
        local mv, mp, mc = mask_of(color, prio, cont)

        local i0 = py * PIC_W + px
        local sc, sp, scn = vis[i0], pri[i0], ctl[i0]
        if is_ega then
            if (px + py) % 2 == 1 then
                sc = XOR4[(sc % 16) * 16 + floor(sc / 16) % 16]
            else
                sc = sc % 16
            end
        end

        -- the original aborts fills in these situations
        if mv then
            if color == white or sc ~= white then return end
        elseif mp then
            if prio == 0 or sp ~= 0 then return end
        elseif mc then
            if cont == 0 or scn ~= 0 then return end
        end

        if mv and sc == color then mv = false end
        if mp and sp == prio then mp = false end
        if mc and scn == cont then mc = false end
        if not (mv or mp or mc) then return end

        local match_kind = mv and 1 or (mp and 2 or 3)
        local function matches(mx, my)
            local o = my * PIC_W + mx
            if match_kind == 1 then
                local v = vis[o]
                if is_ega then
                    if (mx + my) % 2 == 1 then
                        v = XOR4[(v % 16) * 16 + floor(v / 16) % 16]
                    else
                        v = v % 16
                    end
                end
                return v == sc
            elseif match_kind == 2 then
                return pri[o] == sp
            end
            return ctl[o] == scn
        end

        local border_left, border_top = 0, PIC_TOP
        local border_right, border_bottom = PIC_W - 1, PIC_H - 1

        local stack, sn = { { px, py } }, 1
        while sn > 0 do
            local p = stack[sn]; stack[sn] = nil; sn = sn - 1
            local cx, cy = p[1], p[2]
            if matches(cx, cy) then
                put(cx, cy, mv, mp, mc, color, prio, cont)
                local to_left, to_right = cx, cx
                while to_left > border_left and matches(to_left - 1, cy) do
                    to_left = to_left - 1
                    put(to_left, cy, mv, mp, mc, color, prio, cont)
                end
                while to_right < border_right and matches(to_right + 1, cy) do
                    to_right = to_right + 1
                    put(to_right, cy, mv, mp, mc, color, prio, cont)
                end

                local a_set, b_set = false, false
                while to_left <= to_right do
                    if cy > border_top and matches(to_left, cy - 1) then
                        if not a_set then
                            sn = sn + 1; stack[sn] = { to_left, cy - 1 }
                            a_set = true
                        end
                    else
                        a_set = false
                    end
                    if cy < border_bottom and matches(to_left, cy + 1) then
                        if not b_set then
                            sn = sn + 1; stack[sn] = { to_left, cy + 1 }
                            b_set = true
                        end
                    else
                        b_set = false
                    end
                    to_left = to_left + 1
                end
            end
        end
    end

    -- --------------------------------------------------------------- patterns
    local function box_pixel(x, y, color, prio, cont, mv, mp, mc)
        if not (0 <= x and 0 <= y and y < PIC_H) then return end
        if x < PIC_W then
            put(x, y, mv, mp, mc, color, prio, cont)
        elseif y < PIC_H - 1 then
            -- wraps around to the next row with the opposite dither color
            local c = color
            if c >= 16 then
                local hi, lo = floor(c / 16) % 16, c % 16
                local dec_hi = XOR4[hi * 16 + lo]
                -- decode (hi', lo), swap nibbles, re-encode
                local nh, nl = lo, dec_hi
                c = XOR4[nh * 16 + nl] * 16 + nl
            end
            put(0, y + 1, mv, mp, mc, c, prio, cont)
        end
    end

    local function pattern(x, y, color, prio, cont, code, texture)
        local psize = code % 8
        local bl, bt = x - psize, y - psize
        local bw, bh = psize * 2 + 2, psize * 2 + 1
        if bl < 0 then bl = 0 end
        if bt < 0 then bt = 0 end
        bt = bt + PIC_TOP
        if bl + bw > PIC_W + 1 then bl = PIC_W + 1 - bw end
        if bt + bh > PIC_H then bt = PIC_H - bh end

        local mv, mp, mc = mask_of(color, prio, cont)
        local rect = floor(code / 16) % 2 == 1
        local textured = floor(code / 32) % 2 == 1
        local ti = textured and PAT_TEX_OFFSET[texture] or 0

        if rect then
            for yy = bt, bt + bh - 1 do
                for xx = bl, bl + bw - 1 do
                    if not textured or PAT_TEX[ti] then
                        box_pixel(xx, yy, color, prio, cont, mv, mp, mc)
                    end
                    if textured then ti = ti + 1 end
                end
            end
        else
            local circle = PAT_CIRCLES[psize]
            local ci, bit_no = 1, 0
            local bitmap = circle[1]
            for yy = bt, bt + bh - 1 do
                for xx = bl, bl + bw - 1 do
                    if bit_no == 8 then
                        ci = ci + 1
                        bitmap = circle[ci] or 0
                        bit_no = 0
                    end
                    if bitmap % 2 == 1 then
                        if not textured or PAT_TEX[ti] then
                            if xx >= 0 and xx < PIC_W and yy >= 0 and yy < PIC_H then
                                put(xx, yy, mv, mp, mc, color, prio, cont)
                            end
                        end
                        if textured then ti = ti + 1 end
                    end
                    bit_no = bit_no + 1
                    bitmap = floor(bitmap / 2)
                end
            end
        end
    end

    -- ------------------------------------------------------------ coordinates
    local pos = 0
    local cx, cy = 0, 0

    local function abs_coords()
        local p = B(pos)
        cx = B(pos + 1) + floor(p / 16) * 256
        cy = B(pos + 2) + (p % 16) * 256
        pos = pos + 3
    end
    local function rel_coords()
        local p = B(pos); pos = pos + 1
        if p >= 128 then cx = cx - (floor(p / 16) % 8) else cx = cx + floor(p / 16) end
        if floor(p / 8) % 2 == 1 then cy = cy - (p % 8) else cy = cy + (p % 8) end
    end
    local function rel_coords_med()
        local p = B(pos); pos = pos + 1
        if p >= 128 then cy = cy - (p % 128) else cy = cy + p end
        p = B(pos); pos = pos + 1
        if p >= 128 then cx = cx - (128 - (p % 128)) else cx = cx + p end
    end

    -- ----------------------------------------------------------- EGA palettes
    local ega_pals = {}
    for k = 0, 3 do
        for i = 1, 40 do ega_pals[k * 40 + i - 1] = EGA_DEFAULT_PALETTE[i] end
    end
    local function ega_color(c)
        local e = ega_pals[c] or 0
        return XOR4[floor(e / 16) * 16 + e % 16] * 16 + e % 16
    end

    local pic_color = default_color or 0
    local pic_priority, pic_control = 255, 255
    local pat_code, pat_texture = 0, 0

    -- draws an embedded cel at (x, y) given the descriptor offset (0-based)
    local function draw_cel(x, y, hdr_pos, rle_pos, ega_cel)
        local w = d[hdr_pos] and (d[hdr_pos] + (d[hdr_pos + 1] or 0) * 256) or 0
        local h = d[hdr_pos + 2] and (d[hdr_pos + 2] + (d[hdr_pos + 3] or 0) * 256) or 0
        local ck = d[hdr_pos + 6] or 255
        if w < 1 or h < 1 or w > 1024 or h > 1024 then return end
        -- cel bytes live in `d`; decode them through a temporary string view
        local chunk = vdata
        local pix
        if ega_cel then
            pix = decode_cel_ega(chunk, w, h, ck, rle_pos)
        else
            pix = decode_cel_vga(chunk, w, h, ck, rle_pos, nil)
        end
        if not pix then return end
        -- a non-overlay picture paints everything but white
        local clear = white
        local ox, oy = x, y + PIC_TOP
        for yy = 0, h - 1 do
            local sy = oy + yy
            if sy >= 0 and sy < PIC_H then
                for xx = 0, w - 1 do
                    local sx = ox + xx
                    if sx >= 0 and sx < PIC_W then
                        local v = pix[yy * w + xx + 1]
                        if v ~= clear then
                            local i = sy * PIC_W + sx
                            if ega_cel then
                                vis[i] = v
                            elseif pri[i] <= 0 then
                                vis[i] = v; pri[i] = 0
                            end
                        end
                    end
                end
            end
        end
    end

    -- ------------------------------------------------------------- main loop
    local terminated = false
    while pos < size do
        local op = d[pos]; pos = pos + 1

        if op == 0xF0 then                      -- set color
            pic_color = B(pos); pos = pos + 1
            if is_ega then pic_color = ega_color(pic_color) end
        elseif op == 0xF1 then                  -- disable visual
            pic_color = 0xFF
        elseif op == 0xF2 then                  -- set priority
            pic_priority = B(pos) % 16; pos = pos + 1
        elseif op == 0xF3 then
            pic_priority = 255
        elseif op == 0xFB then                  -- set control
            pic_control = B(pos) % 16; pos = pos + 1
        elseif op == 0xFC then
            pic_control = 255
        elseif op == 0xF7 or op == 0xF5 or op == 0xF6 then    -- lines
            abs_coords()
            while nonop(pos) do
                local ox, oy = cx, cy
                if op == 0xF7 then rel_coords()
                elseif op == 0xF5 then rel_coords_med()
                else abs_coords() end
                draw_line(ox, oy, cx, cy, pic_color, pic_priority, pic_control)
            end
        elseif op == 0xF8 then                  -- fill
            while nonop(pos) do
                abs_coords()
                flood_fill(cx, cy, pic_color, pic_priority, pic_control)
            end
        elseif op == 0xF9 then                  -- set pattern
            pat_code = B(pos); pos = pos + 1
        elseif op == 0xF4 or op == 0xFD or op == 0xFA then    -- pattern draws
            local function texture()
                if floor(pat_code / 32) % 2 == 1 then
                    pat_texture = floor(B(pos) / 2) % 128
                    pos = pos + 1
                end
            end
            if op == 0xFA then
                while nonop(pos) do
                    texture(); abs_coords()
                    pattern(cx, cy, pic_color, pic_priority, pic_control, pat_code, pat_texture)
                end
            else
                texture(); abs_coords()
                pattern(cx, cy, pic_color, pic_priority, pic_control, pat_code, pat_texture)
                while nonop(pos) do
                    texture()
                    if op == 0xF4 then rel_coords() else rel_coords_med() end
                    pattern(cx, cy, pic_color, pic_priority, pic_control, pat_code, pat_texture)
                end
            end
        elseif op == 0xFE then                  -- extended opcodes
            local sub = B(pos); pos = pos + 1
            if is_ega then
                if sub == 0 then                -- set palette entries
                    while nonop(pos) do
                        local idx = B(pos); local val = B(pos + 1); pos = pos + 2
                        if idx < 160 then ega_pals[idx] = val end
                    end
                elseif sub == 1 then            -- set palette
                    local num = B(pos); pos = pos + 1
                    if num < 4 then
                        for i = 0, 39 do ega_pals[num * 40 + i] = B(pos + i) end
                    end
                    pos = pos + 40
                elseif sub == 2 then pos = pos + 41
                elseif sub == 3 or sub == 5 then pos = pos + 1   -- MONO1 / MONO3
                elseif sub == 4 or sub == 6 then
                    -- MONO2 / MONO4: nothing to skip
                elseif sub == 7 then            -- embedded view
                    local x = B(pos + 1) + floor(B(pos) / 16) * 256
                    local y = B(pos + 2) + (B(pos) % 16) * 256
                    pos = pos + 3
                    local csize = B(pos) + B(pos + 1) * 256; pos = pos + 2
                    draw_cel(x, y, pos, pos + 8, true)
                    pos = pos + csize
                elseif sub == 8 then pos = pos + 14   -- priority table
                else
                    err = string.format("unsupported EGA extended op %d", sub); break
                end
            else
                if sub == 0 then                -- set palette entries (ignored)
                    while nonop(pos) do pos = pos + 1 end
                elseif sub == 2 then            -- set palette
                    pos = pos + 256 + 4
                    local np = {}
                    for i = 0, 255 do
                        np[i*3+1] = B(pos + 1); np[i*3+2] = B(pos + 2); np[i*3+3] = B(pos + 3)
                        pos = pos + 4
                    end
                    pal = np
                elseif sub == 1 then            -- embedded view
                    local x = B(pos + 1) + floor(B(pos) / 16) * 256
                    local y = B(pos + 2) + (B(pos) % 16) * 256
                    pos = pos + 3
                    local csize = B(pos) + B(pos + 1) * 256; pos = pos + 2
                    draw_cel(x, y, pos, pos + 8, false)
                    pos = pos + csize
                elseif sub == 3 then pos = pos + 4     -- priority table (eqdist)
                elseif sub == 4 then pos = pos + 14    -- priority table (explicit)
                else
                    err = string.format("unsupported VGA extended op %d", sub); break
                end
            end
        elseif op == 0xFF then
            terminated = true
            break
        else
            err = string.format("unsupported pic opcode %02X at %d", op, pos - 1)
            break
        end
    end
    if not terminated and not err then err = "no terminator" end

    -- EGA pictures are dithered once drawing is done
    if is_ega then
        for y = 0, PIC_H - 1 do
            for x = 0, PIC_W - 1 do
                local i = y * PIC_W + x
                local c = vis[i]
                if c >= 16 then
                    local hi, lo = XOR4[(c % 16) * 16 + floor(c / 16) % 16], c % 16
                    vis[i] = ((x + y) % 2 == 1) and hi or lo
                end
            end
        end
    end

    local pix = {}
    local h = PIC_H - PIC_TOP
    for y = 0, h - 1 do
        local row = (y + PIC_TOP) * PIC_W
        local o = y * PIC_W
        for x = 0, PIC_W - 1 do pix[o + x + 1] = vis[row + x] end
    end
    return pix, PIC_W, h, (is_ega and ega_palette() or (pal or grayscale_palette())), err
end

-- SCI1.1 picture: a bitmap cel with its own palette
local function render_pic_sci11(data, game_pal, force_pal)
    if #data < 38 then return nil, "data too short" end

    local has_cel = u8(data, 5)
    if has_cel == 0 then return nil, "no embedded cel" end

    local palette_off = u32le(data, 29)
    local cel_hdr_off = u32le(data, 33)
    if cel_hdr_off + 32 > #data then return nil, "cel header out of bounds" end

    local pic_pal = game_pal
    if palette_off > 0 and palette_off < #data then
        local ep = parse_vga_palette(data:sub(palette_off + 1))
        if ep then pic_pal = ep end
    end
    if force_pal then pic_pal = force_pal end

    local chp = cel_hdr_off + 1
    local width  = u16le(data, chp)
    local height = u16le(data, chp + 2)
    local rle_off = u32le(data, chp + 24)
    local lit_off = u32le(data, chp + 28)
    if width < 1 or width > 640 or height < 1 or height > 400 then
        return nil, "invalid dimensions"
    end
    if rle_off > 0 and lit_off == 0 then rle_off, lit_off = 0, rle_off end

    local pix = decode_cel_vga(data, width, height, 255,
        rle_off > 0 and rle_off or nil, lit_off > 0 and lit_off or nil)
    if not pix then return nil, "no pixel data" end
    return image_create_indexed(width, height, pix, pic_pal), nil
end

-- SCI2.1 picture: header (size u16, cel count u8, cel header size u16 @4,
-- palette u32 @6, resolution flags @10/@12) + cels placed at relative positions
local function render_pic_sci32(data, game_pal, force_pal)
    if #data < 16 then return nil, "data too short" end
    local hdr = u16le(data, 1)
    local count = u8(data, 3)
    local csize = u16le(data, 5)
    local pal_off = u32le(data, 7)
    local f1, f2 = u16le(data, 11), u16le(data, 13)
    local xres, yres = 320, 200
    if f2 ~= 0 then xres, yres = f1, f2
    elseif f1 == 1 then xres, yres = 640, 480
    elseif f1 == 2 then xres, yres = 640, 400 end

    local pal = game_pal
    if pal_off > 0 and pal_off < #data then
        pal = parse_hunk_palette(data:sub(pal_off + 1)) or pal
    end
    if force_pal then pal = force_pal end

    local cels = {}
    local cw, ch = xres, yres
    for k = 0, count - 1 do
        local cp = hdr + k * csize + 1
        if cp + 42 > #data then break end
        local cel = {
            width = u16le(data, cp), height = u16le(data, cp + 2),
            clear_key = u8(data, cp + 8),
            sci32 = { comp = u8(data, cp + 9), data = u32le(data, cp + 24),
                      lit = u32le(data, cp + 28), ctrl = u32le(data, cp + 32) },
        }
        local rx, ry = i16le(data, cp + 38), i16le(data, cp + 40)
        if cel.width >= 1 and cel.height >= 1 and cel.width <= 4096 and cel.height <= 4096 then
            cels[#cels + 1] = { cel = cel, x = rx, y = ry }
            cw = math.max(cw, rx + cel.width)
            ch = math.max(ch, ry + cel.height)
        end
    end
    if #cels == 0 then return nil, "no cels" end

    local canvas = {}
    local first_ck = cels[1].cel.clear_key
    for i = 1, cw * ch do canvas[i] = first_ck end
    for _, c in ipairs(cels) do
        local pix = decode_cel(data, c.cel)
        if pix then
            local w, h, ck = c.cel.width, c.cel.height, c.cel.clear_key
            for y = 0, h - 1 do
                local dy = y + c.y
                if dy >= 0 and dy < ch then
                    for x = 0, w - 1 do
                        local dx = x + c.x
                        local v = pix[y * w + x + 1]
                        if dx >= 0 and dx < cw and v ~= ck then
                            canvas[dy * cw + dx + 1] = v
                        end
                    end
                end
            end
        end
    end
    return image_create_indexed(cw, ch, canvas, pal), nil, cw, ch, #cels
end

-- ============================================================================
-- Fonts, cursors, texts
-- ============================================================================

-- SCI font: lowPage:u16 numChars:u16 height:u16 charOffsets:u16*  (glyph: w, h, rows)
local function render_font(data, rnum)
    if #data < 8 then return nil end
    local num_chars = u16le(data, 3)
    local font_h = u16le(data, 5)
    if num_chars < 1 or num_chars > 256 or font_h < 1 or font_h > 64 then return nil end

    local cols = 16
    local rows = math.ceil(num_chars / cols)
    local cell_w, cell_h = 0, font_h
    local glyphs = {}
    for c = 0, num_chars - 1 do
        local off = u16le(data, 7 + c * 2)
        if off + 2 <= #data then
            local gw, gh = u8(data, off + 1), u8(data, off + 2)
            glyphs[c] = { off = off, w = gw, h = gh }
            if gw > cell_w then cell_w = gw end
            if gh > cell_h then cell_h = gh end
        end
    end
    if cell_w < 1 then return nil end

    local pad = 2
    local cw, ch = cell_w + pad, cell_h + pad
    local W, H = cols * cw, rows * ch
    local pix = {}
    for i = 1, W * H do pix[i] = 0 end
    for c, g in pairs(glyphs) do
        local bytes_per_row = floor((g.w + 7) / 8)
        local ox, oy = (c % cols) * cw + 1, floor(c / cols) * ch + 1
        for y = 0, g.h - 1 do
            for x = 0, g.w - 1 do
                local bp = g.off + 3 + y * bytes_per_row + floor(x / 8)
                local b = data:byte(bp)
                if b and floor(b / POW2[7 - (x % 8)]) % 2 == 1 then
                    pix[(oy + y) * W + ox + x + 1] = 1
                end
            end
        end
    end
    local pal = {}
    for i = 0, 255 do pal[i*3+1] = 0; pal[i*3+2] = 0; pal[i*3+3] = 0 end
    pal[4] = 255; pal[5] = 255; pal[6] = 255
    local img = image_create_indexed(W, H, pix, pal)
    return {
        type = "image", image = img,
        description = string.format("Font %d (%d chars, height %d)", rnum, num_chars, font_h),
    }
end

-- 16x16 cursor: two 32-byte bit planes (maskA, maskB)
local function render_cursor(data, rnum, sci0)
    if #data < 68 then return nil end
    local pal = {}
    for i = 0, 255 do pal[i*3+1] = 0; pal[i*3+2] = 0; pal[i*3+3] = 0 end
    -- 0 black, 1 white, 2 transparent (magenta), 3 white (SCI0) / gray (SCI1)
    pal[4] = 255; pal[5] = 255; pal[6] = 255
    pal[7] = 255; pal[8] = 0;   pal[9] = 255
    if sci0 then pal[10] = 255; pal[11] = 255; pal[12] = 255
    else pal[10] = 170; pal[11] = 170; pal[12] = 170 end

    local pix = {}
    for y = 0, 15 do
        local ma = u16le(data, 5 + y * 2)
        local mb = u16le(data, 5 + 32 + y * 2)
        for x = 0, 15 do
            local a = floor(ma / POW2[15 - x]) % 2
            local b = floor(mb / POW2[15 - x]) % 2
            pix[y * 16 + x + 1] = a * 2 + b
        end
    end
    return {
        type = "image", image = image_create_indexed(16, 16, pix, pal),
        description = string.format("Cursor %d (16x16)", rnum),
    }
end

-- Text resources: NUL separated strings
local function render_text(data, rnum)
    local lines = {}
    local pos = 1
    local n = 0
    while pos <= #data do
        local e = data:find("\0", pos, true) or (#data + 1)
        local s = data:sub(pos, e - 1)
        s = s:gsub("[^\32-\126]", "?")
        n = n + 1
        lines[#lines + 1] = string.format("[%d] %s", n, s)
        pos = e + 1
    end
    return {
        type = "text",
        text = table.concat(lines, "\n"),
        description = string.format("Text %d (%d strings)", rnum, n),
    }
end

-- ============================================================================
-- Public engine API
-- ============================================================================

function engine.detect(game_path)
    if file_exists(game_path .. "/RESMAP.000") and file_exists(game_path .. "/RESSCI.000")
       and not file_exists(game_path .. "/RESOURCE.MAP") then
        return true
    end
    if not file_exists(game_path .. "/RESOURCE.MAP") then return false end
    for i = 0, 9 do
        if file_exists(game_path .. string.format("/RESOURCE.%03d", i)) then
            return true
        end
    end
    return false
end

function engine.get_resources(game_path)
    info_cache[game_path] = nil
    local info = get_info(game_path)
    if not info then return {} end

    -- Group by type
    local by_type = {}
    for _, r in ipairs(info.resources) do
        if not by_type[r.type] then by_type[r.type] = {} end
        table.insert(by_type[r.type], r)
    end

    local tree = {}
    -- Sorted type order: views first, then pics, then others
    local type_order = {0, 1, 11, 7, 8, 2, 3, 4, 6, 9, 10, 15, 17}
    if info.ver == "sci2" then
        type_order = {0, 1, 11, 7, 8, 2, 3, 4, 5, 6, 9, 10, 15, 17, 16, 18, 19, 20, 21, 22}
    end
    local default_pal = default_palette_res(info)
    local pic_palettes
    for _, t in ipairs(type_order) do
        local items = by_type[t]
        if items then
            local type_name = res_names(info)[t] or ("Type " .. t)
            local kids = {}
            table.sort(items, function(a, b)
                -- the game's default palette goes first: the app preselects
                -- the first palette of the list
                if t == 11 and a ~= b then
                    if a == default_pal then return true end
                    if b == default_pal then return false end
                end
                return a.number < b.number
            end)
            for _, r in ipairs(items) do
                -- palettes are offered through the preview pane's palette list
                local res_type = (t == 0 or t == 1 or t == 7 or t == 8) and "image" or "text"
                if t == 11 then res_type = "palette" end
                table.insert(kids, {
                    id = string.format("r_%d_%d", t, r.number),
                    name = string.format("%s %d", type_name:sub(1, -2), r.number),
                    type = res_type,
                })
            end
            table.insert(tree, {
                id = "type_" .. t,
                name = type_name .. " (" .. #items .. ")",
                type = "category",
                children = kids,
            })

            -- Every VGA picture carries its own palette; offer them as well so
            -- sprites can be previewed with the colors of a given room. The
            -- category goes last: the app preselects the first palette it finds.
            if t == 1 and info.vga then
                local pkids = {}
                for _, r in ipairs(items) do
                    table.insert(pkids, {
                        id = string.format("p_1_%d", r.number),
                        name = string.format("Palette of Pic %d", r.number),
                        type = "palette",
                    })
                end
                pic_palettes = {
                    id = "type_pic_palettes",
                    name = "Pic Palettes (" .. #items .. ")",
                    type = "category",
                    children = pkids,
                }
            end
        end
    end
    if pic_palettes then table.insert(tree, pic_palettes) end

    return tree
end

local function palette_swatches(pal, rnum, size, label)
    -- 16x16 grid of 16x16 color swatches
    local sw, sh = 256, 256
    local pix = {}
    for y = 0, 15 do
        for x = 0, 15 do
            local ci = y * 16 + x
            for py = 0, 15 do
                for px = 0, 15 do
                    pix[(y * 16 + py) * sw + x * 16 + px + 1] = ci
                end
            end
        end
    end
    return {
        type = "image", image = image_create_indexed(sw, sh, pix, pal),
        description = string.format("%s %d (%d bytes)", label or "Palette", rnum, size),
    }
end

-- Palette of a vector / SCI1.1 picture
local function pic_palette(data, game_pal, info)
    if info and info.ver == "sci2" then
        local off = u32le(data, 7)
        if off > 0 and off < #data then
            return parse_hunk_palette(data:sub(off + 1)) or game_pal
        end
        return game_pal
    end
    if #data >= 38 and u16le(data, 1) == 0x26 then
        local off = u32le(data, 29)
        if off > 0 and off < #data then
            local ep = parse_vga_palette(data:sub(off + 1))
            if ep then return ep end
        end
        return game_pal
    end
    local ok, _, _, _, pal = pcall(draw_vector_pic, data, false, game_pal)
    if ok and pal then return pal end
    return nil
end

-- Resolves the palette passed by the app's palette list (nil = no override).
-- The game's default palette is what the app preselects, so it counts as
-- "no override" and the resource keeps its own (embedded) palette.
local function resolve_palette_override(game_path, info, palette_id, game_pal)
    if not palette_id or palette_id == "" then return nil end

    local pt, pn = palette_id:match("^r_(%d+)_(%d+)$")
    if pt then
        local r = find_resource(info, tonumber(pt), tonumber(pn))
        if not r or r == default_palette_res(info) then return nil end
        local data = read_resource(game_path, info, r)
        return data and parse_vga_palette(data) or nil
    end

    local qt, qn = palette_id:match("^p_(%d+)_(%d+)$")
    if qt then
        local r = find_resource(info, tonumber(qt), tonumber(qn))
        local data = r and read_resource(game_path, info, r)
        return data and pic_palette(data, game_pal(), info) or nil
    end
    return nil
end

local function load_view(data, rnum, info, game_pal, override)
    local loops, pal_ptr, vga
    if info.ver == "sci2" then
        loops, pal_ptr, vga = parse_view_sci11(data, true)
    elseif info.ver == "sci11" and #data >= 14 and u16le(data, 5) == 1 then
        loops, pal_ptr, vga = parse_view_sci11(data)
    else
        loops, pal_ptr, vga = parse_view_old(data, info.vga)
        if not loops and info.ver == "sci11" then
            loops, pal_ptr, vga = parse_view_sci11(data)
        end
    end

    if not loops or #loops == 0 then
        return { type = "text", text = string.format("View %d: %d bytes (parse failed)", rnum, #data) }
    end

    local pal
    if not vga then
        pal = ega_palette()
    elseif override then
        pal = override
    else
        pal = game_pal()
        if pal_ptr and pal_ptr > 0 and pal_ptr <= #data then
            local emb = parse_vga_palette(data:sub(pal_ptr))
            if emb then pal = emb end
        end
    end

    local frames = build_view_frames(data, loops, pal)
    if #frames == 0 then
        return { type = "text", text = string.format("View %d: no renderable cels", rnum) }
    end

    local cel_total = #frames
    local desc = string.format("View %d (%d loops, %d cels)", rnum, #loops, cel_total)
    if cel_total == 1 then
        return { type = "image", image = frames[1].img, description = desc }
    end

    local imgs = {}
    for i, f in ipairs(frames) do imgs[i] = f.img end
    return {
        type = "animation", animation = animation_create(imgs, 150),
        image = imgs[1], frames = imgs, description = desc .. " - frames ordered by loop",
    }
end

local function load_pic(data, rnum, info, game_pal, override)
    if info.ver == "sci2" then
        local img, err, w, h, n = render_pic_sci32(data, game_pal(), override)
        if img then
            return {
                type = "image", image = img,
                description = string.format("Pic %d (SCI2.1, %dx%d, %d cels)", rnum, w, h, n),
            }
        end
        return { type = "text", text = string.format("Pic %d: %d bytes (%s)", rnum, #data, err or "render failed") }
    end
    -- SCI1.1 bitmap picture
    if #data >= 38 and u16le(data, 1) == 0x26 then
        local img, err = render_pic_sci11(data, game_pal(), override)
        if img then
            return {
                type = "image", image = img,
                description = string.format("Pic %d (SCI1.1 VGA, %d bytes)", rnum, #data),
            }
        end
        -- pictures without a bitmap cel are drawn by their vector data only
        local vec = u32le(data, 17)
        if vec > 0 and vec < #data then
            local pal = game_pal()
            local po = u32le(data, 29)
            if po > 0 and po < #data then pal = parse_vga_palette(data:sub(po + 1)) or pal end
            local ok, pix, w, h, vpal = pcall(draw_vector_pic, data:sub(vec + 1), false, pal, 255)
            if ok and pix then
                return {
                    type = "image", image = image_create_indexed(w, h, pix, override or vpal),
                    description = string.format("Pic %d (SCI1.1 vector only, %d bytes)", rnum, #data),
                }
            end
        end
        return { type = "text", text = string.format("Pic %d: %d bytes (SCI1.1 - %s)", rnum, #data, err or "render failed") }
    end

    -- Vector picture (EGA or VGA)
    local ok, pix, w, h, pal, err = pcall(draw_vector_pic, data, not info.vga, info.vga and game_pal() or nil)
    if not ok then
        return { type = "text", text = string.format("Pic %d: %d bytes (render error: %s)", rnum, #data, tostring(pix)) }
    end
    if override and info.vga then pal = override end
    local img = image_create_indexed(w, h, pix, pal)
    local desc = string.format("Pic %d (%s vector, %d bytes)", rnum, info.vga and "VGA" or "EGA", #data)
    if err then desc = desc .. " [" .. err .. "]" end
    return { type = "image", image = img, description = desc }
end

function engine.load_resource(game_path, resource_id, palette_id)
    local game_pal_cache
    local info = get_info(game_path)
    if not info then
        return { type = "text", text = "Failed to parse RESOURCE.MAP" }
    end
    local function game_pal()
        if not game_pal_cache then game_pal_cache = load_game_palette(game_path, info) end
        return game_pal_cache
    end

    -- Palette of a picture, shown as a swatch grid (palette list entries)
    local ptype_s, pnum_s = resource_id:match("^p_(%d+)_(%d+)$")
    if ptype_s then
        local pn = tonumber(pnum_s)
        local r = find_resource(info, tonumber(ptype_s), pn)
        local data = r and read_resource(game_path, info, r)
        local pal = data and pic_palette(data, game_pal(), info)
        if pal then return palette_swatches(pal, pn, #data, "Palette of Pic") end
        return { type = "text", text = string.format("Pic %d has no palette", pn) }
    end

    local rtype_s, rnum_s = resource_id:match("^r_(%d+)_(%d+)$")
    if not rtype_s then
        return { type = "text", text = "Unknown resource: " .. resource_id }
    end

    local rtype = tonumber(rtype_s)
    local rnum = tonumber(rnum_s)

    local res = find_resource(info, rtype, rnum)
    if not res then
        return { type = "text", text = "Resource not found in map" }
    end

    local data = read_resource(game_path, info, res)
    if not data then
        return { type = "text", text = string.format("Failed to load %s %d (vol=%d)",
            res_names(info)[rtype] or "resource", rnum, res.volume) }
    end

    -- PALETTE resource (type 11)
    if rtype == 11 then
        local vpal = parse_vga_palette(data)
        if vpal then return palette_swatches(vpal, rnum, #data, "Palette") end
        return { type = "text", text = string.format("Palette %d: %d bytes", rnum, #data) }
    end

    -- VIEW resource (type 0)
    if rtype == 0 then
        local override = resolve_palette_override(game_path, info, palette_id, game_pal)
        return load_view(data, rnum, info, game_pal, override)
    end

    -- PIC resource (type 1)
    if rtype == 1 then
        local override = resolve_palette_override(game_path, info, palette_id, game_pal)
        return load_pic(data, rnum, info, game_pal, override)
    end

    -- FONT resource (type 7)
    if rtype == 7 then
        local r = render_font(data, rnum)
        if r then return r end
        return { type = "text", text = string.format("Font %d: %d bytes", rnum, #data) }
    end

    -- CURSOR resource (type 8)
    if rtype == 8 then
        local r = render_cursor(data, rnum, info.numbering == "old")
        if r then return r end
        return { type = "text", text = string.format("Cursor %d: %d bytes", rnum, #data) }
    end

    -- TEXT resource (type 3)
    if rtype == 3 and info.ver ~= "sci2" then
        return render_text(data, rnum)
    end

    -- Other resource types: show metadata
    local type_name = res_names(info)[rtype] or ("Type " .. rtype)
    return {
        type = "text",
        text = string.format("%s %d: %d bytes", type_name, rnum, #data),
    }
end

return engine

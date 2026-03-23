-- ============================================================================
-- Adventure Explorer - Engine Script: Sierra SCI
-- ============================================================================
-- Sierra On-Line, 1988-1996. DOS. SCI resource system.
--
-- Supports SCI0 (EGA) and SCI1/SCI1.1 (VGA) resource formats.
--   SCI0: 6-byte map entries, LZW_SCI0 (LSB) compression
--   SCI1: Directory+6-byte entries, LZW_SCI1 (MSB) compression
--   SCI1.1: Directory+5-byte entries, STACpack/LZS compression
-- ============================================================================

local engine = {}
engine.name        = "Sierra SCI"
engine.id          = "sci"
engine.description = "Sierra SCI games (1988-1996)"
engine.version     = "4.0"

-- ============================================================================
-- Binary helpers
-- ============================================================================

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
local function u16be(data, pos)
    return data:byte(pos) * 256 + data:byte(pos + 1)
end
local function i16be(data, pos)
    local v = u16be(data, pos)
    return v < 32768 and v or v - 65536
end
local function u32be(data, pos)
    return data:byte(pos) * 16777216 + data:byte(pos + 1) * 65536
         + data:byte(pos + 2) * 256 + data:byte(pos + 3)
end

local POW2 = {}
for i = 0, 31 do POW2[i] = 2 ^ i end

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

-- ============================================================================
-- LZW decompressor (SCI0 variant, LSB-first)
-- ============================================================================

local function lzw_sci0(data, expected_size)
    local spos = 1
    local bbuf = 0
    local bcount = 0

    local function read_code(w)
        while bcount < w do
            if spos > #data then return nil end
            bbuf = bbuf + data:byte(spos) * POW2[bcount]
            bcount = bcount + 8
            spos = spos + 1
        end
        local code = bbuf % POW2[w]
        bbuf = math.floor(bbuf / POW2[w])
        bcount = bcount - w
        return code
    end

    -- Dictionary: linked list (parent, char, first_byte, length)
    local dp, dc, df, dl = {}, {}, {}, {}
    for i = 0, 255 do dp[i]=-1; dc[i]=i; df[i]=i; dl[i]=1 end

    local function init()
        for k = 258, 4095 do dp[k]=nil; dc[k]=nil; df[k]=nil; dl[k]=nil end
        return 258, 9, 512
    end

    local next_code, cw, max_code = init()

    local function decode(code)
        local len = dl[code]
        if not len then return nil end
        local bytes = {}
        local c = code
        for i = len, 1, -1 do bytes[i] = dc[c]; c = dp[c] end
        return bytes
    end

    local out = {}
    local out_n = 0
    local prev = nil

    while true do
        local code = read_code(cw)
        if not code or code == 257 then break end

        if code == 256 then
            next_code, cw, max_code = init()
            prev = nil
        else
            local bytes
            if dl[code] then
                bytes = decode(code)
            elseif code == next_code and prev then
                bytes = decode(prev)
                if bytes then bytes[#bytes + 1] = df[prev] end
            else
                break
            end
            if not bytes then break end

            for i = 1, #bytes do
                out_n = out_n + 1
                out[out_n] = bytes[i]
            end

            if prev then
                dp[next_code] = prev
                dc[next_code] = bytes[1]
                df[next_code] = df[prev]
                dl[next_code] = dl[prev] + 1
                next_code = next_code + 1
                if next_code >= max_code and cw < 12 then
                    cw = cw + 1
                    max_code = max_code * 2
                end
            end
            prev = code
        end

        if expected_size > 0 and out_n >= expected_size then break end
    end

    local t = {}
    local limit = (expected_size > 0) and math.min(out_n, expected_size) or out_n
    for i = 1, limit do t[i] = string.char(out[i]) end
    return table.concat(t)
end

-- ============================================================================
-- LZW decompressor (SCI1 variant, MSB-first, "early change")
-- ============================================================================

local function lzw_sci1(data, expected_size)
    local spos = 1
    local bbuf = 0
    local bcount = 0

    local function read_code_msb(w)
        while bcount < w do
            if spos > #data then return nil end
            bbuf = bbuf * 256 + data:byte(spos)
            bcount = bcount + 8
            spos = spos + 1
        end
        bcount = bcount - w
        local code = math.floor(bbuf / POW2[bcount]) % POW2[w]
        return code
    end

    -- Output buffer (use string for indexed lookback)
    local out = {}
    local out_n = 0

    -- String table: offsets and lengths into output buffer
    local soff, slen = {}, {}
    for i = 0, 255 do soff[i] = -1; slen[i] = 1 end

    local function init()
        for k = 258, 4095 do soff[k] = nil; slen[k] = nil end
        return 258, 9, 511  -- early change: limit = 511 not 512
    end

    local next_code, cw, max_code = init()
    local prev = nil

    while out_n < expected_size do
        local code = read_code_msb(cw)
        if not code or code == 257 then break end

        if code == 256 then
            next_code, cw, max_code = init()
            prev = nil
        else
            local new_off = out_n + 1

            if code <= 255 then
                out_n = out_n + 1
                out[out_n] = code
            elseif slen[code] then
                local off = soff[code]
                local len = slen[code]
                for i = 0, len - 1 do
                    out_n = out_n + 1
                    out[out_n] = out[off + i]
                end
            elseif code == next_code and prev then
                -- Special case: code not yet in table
                local off = soff[prev] or (prev + 1)
                local len = slen[prev] or 1
                for i = 0, len - 1 do
                    out_n = out_n + 1
                    out[out_n] = out[off + i]
                end
                out_n = out_n + 1
                out[out_n] = out[new_off]
            else
                break
            end

            if next_code < 4096 then
                -- Increase code size at early-change boundary
                if next_code == max_code and cw < 12 then
                    cw = cw + 1
                    max_code = POW2[cw] - 1  -- early change
                end

                soff[next_code] = new_off
                slen[next_code] = out_n - new_off + 1
                next_code = next_code + 1
            end

            prev = code
        end
    end

    local t = {}
    local limit = math.min(out_n, expected_size)
    for i = 1, limit do t[i] = string.char(out[i]) end
    return table.concat(t)
end

-- ============================================================================
-- STACpack / LZS decompressor (SCI1.1, MSB-first)
-- ============================================================================

local function stacpack_decompress(data, expected_size)
    local spos = 1
    local bbuf = 0
    local bcount = 0

    local function read_bits_msb(n)
        while bcount < n do
            if spos > #data then return 0 end
            bbuf = bbuf * 256 + data:byte(spos)
            bcount = bcount + 8
            spos = spos + 1
        end
        bcount = bcount - n
        return math.floor(bbuf / POW2[bcount]) % POW2[n]
    end

    local function read_byte_msb()
        return read_bits_msb(8)
    end

    local function get_comp_len()
        local v = read_bits_msb(2)
        if v == 0 then return 2
        elseif v == 1 then return 3
        elseif v == 2 then return 4
        else
            v = read_bits_msb(2)
            if v == 0 then return 5
            elseif v == 1 then return 6
            elseif v == 2 then return 7
            else
                local clen = 8
                while true do
                    local nibble = read_bits_msb(4)
                    clen = clen + nibble
                    if nibble ~= 0xF then break end
                end
                return clen
            end
        end
    end

    local out = {}
    local out_n = 0

    while out_n < expected_size do
        if read_bits_msb(1) == 1 then
            -- Compressed: match
            local offs, clen
            if read_bits_msb(1) == 1 then
                -- 7-bit offset
                offs = read_bits_msb(7)
                if offs == 0 then break end  -- end marker
                clen = get_comp_len()
            else
                -- 11-bit offset
                offs = read_bits_msb(11)
                clen = get_comp_len()
            end
            -- Copy from history
            local hpos = out_n - offs + 1
            for i = 1, clen do
                out_n = out_n + 1
                out[out_n] = out[hpos] or 0
                hpos = hpos + 1
            end
        else
            -- Literal byte
            out_n = out_n + 1
            out[out_n] = read_byte_msb()
        end
    end

    local t = {}
    local limit = math.min(out_n, expected_size)
    for i = 1, limit do t[i] = string.char(out[i]) end
    return table.concat(t)
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
-- Resource type names
-- ============================================================================

local RES_NAMES = {
    [0] = "Views", [1] = "Pics", [2] = "Scripts", [3] = "Texts",
    [4] = "Sounds", [5] = "Memory", [6] = "Vocab", [7] = "Fonts",
    [8] = "Cursors", [9] = "Patches", [10] = "Bitmaps",
    [11] = "Palettes", [15] = "Messages", [17] = "Heaps",
}

-- ============================================================================
-- Map parsers: SCI0, SCI1, SCI1.1
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
                local n5 = math.min(3, math.floor((offsets[2] - offsets[1]) / 5))
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
        local rtype = math.floor(type_id / 2048)
        local rnum = type_id % 2048
        local off_data = u32le(data, pos + 2)
        local vol = math.floor(off_data / POW2[26])
        local offset = off_data % POW2[26]
        table.insert(resources, {
            type = rtype, number = rnum,
            volume = vol, offset = offset,
        })
        pos = pos + 6
    end
    return resources
end

local function parse_map_sci1(data)
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

    local resources = {}
    for di = 1, #dir do
        local rtype = dir[di].type
        local start = dir[di].offset + 1  -- 1-indexed
        local stop = (di < #dir) and dir[di + 1].offset or (#data - 5)
        local p = start
        while p + 5 <= #data do
            if p > stop then break end
            local rnum = u16le(data, p)
            if rnum == 0xFFFF then break end
            local off_data = u32le(data, p + 2)
            local vol = math.floor(off_data / POW2[28])
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
    -- Directory: 3-byte entries, same as SCI1
    local dir = {}
    local pos = 1
    while pos + 2 <= #data do
        local t = data:byte(pos)
        if t >= 0xFF then break end
        local off = u16le(data, pos + 1)
        table.insert(dir, { type = t - 0x80, offset = off })
        pos = pos + 3
    end

    local resources = {}
    for di = 1, #dir do
        local rtype = dir[di].type
        local start = dir[di].offset + 1  -- 1-indexed
        local stop = (di < #dir) and dir[di + 1].offset or (#data - 4)
        local p = start
        while p + 4 <= #data do
            if p > stop then break end
            local rnum = u16le(data, p)
            if rnum == 0xFFFF then break end
            -- 3-byte offset: actual_offset = raw * 2
            local raw_off = data:byte(p + 2)
                          + data:byte(p + 3) * 256
                          + data:byte(p + 4) * 65536
            local offset = raw_off * 2
            table.insert(resources, {
                type = rtype, number = rnum,
                volume = 0, offset = offset,
            })
            p = p + 5
        end
    end
    return resources
end

local function parse_map(game_path)
    local fh = file_open(game_path .. "/RESOURCE.MAP")
    if not fh then return nil, nil end
    local sz = file_size(fh)
    local data = file_read(fh, 0, sz)
    file_close(fh)
    if not data or #data < 6 then return nil, nil end

    local ver = detect_sci_version(data)
    local resources
    if ver == "sci11" then
        resources = parse_map_sci11(data)
    elseif ver == "sci1" then
        resources = parse_map_sci1(data)
    else
        resources = parse_map_sci0(data)
    end
    return resources, ver
end

-- ============================================================================
-- Resource Volume Readers
-- ============================================================================

local function decompress_resource(raw, comp_method, unpack_sz)
    if comp_method == 0 then
        return raw
    elseif comp_method == 1 then
        return lzw_sci0(raw, unpack_sz)
    elseif comp_method == 2 then
        -- Huffman: try zlib as fallback
        local result = zlib_decompress(raw, unpack_sz)
        if result then return result end
        log_warn("SCI: Huffman compression not fully supported")
        return nil
    elseif comp_method == 3 or comp_method == 4 or comp_method == 5 then
        return lzw_sci1(raw, unpack_sz)
    elseif comp_method == 18 or comp_method == 19 or comp_method == 20 then
        return dcl_decompress(raw, unpack_sz)
    else
        log_warn("SCI: unsupported compression method " .. comp_method)
        return nil
    end
end

local function read_resource_sci0(game_path, vol, offset)
    local vol_name = string.format("RESOURCE.%03d", vol)
    local fh = file_open(game_path .. "/" .. vol_name)
    if not fh then return nil end

    local hdr = file_read(fh, offset, 8)
    if not hdr or #hdr < 8 then file_close(fh); return nil end

    local comp_size = u16le(hdr, 3)
    local decomp_size = u16le(hdr, 5)
    local comp_method = u16le(hdr, 7)

    local raw = file_read(fh, offset + 8, comp_size)
    file_close(fh)
    if not raw then return nil end

    return decompress_resource(raw, comp_method, decomp_size)
end

local function read_resource_sci1(game_path, vol, offset)
    local vol_name = string.format("RESOURCE.%03d", vol)
    local fh = file_open(game_path .. "/" .. vol_name)
    if not fh then return nil end

    local hdr = file_read(fh, offset, 9)
    if not hdr or #hdr < 9 then file_close(fh); return nil end

    -- SCI1: packedSz includes the 4-byte sub-header (unpackedSz + method)
    local packed_sz = u16le(hdr, 4)
    local unpack_sz = u16le(hdr, 6)
    local comp_method = u16le(hdr, 8)
    local data_sz = packed_sz - 4
    if data_sz < 0 then data_sz = 0 end

    local raw = file_read(fh, offset + 9, data_sz)
    file_close(fh)
    if not raw then return nil end

    return decompress_resource(raw, comp_method, unpack_sz)
end

local function read_resource_sci11(game_path, vol, offset)
    local vol_name = string.format("RESOURCE.%03d", vol)
    local fh = file_open(game_path .. "/" .. vol_name)
    if not fh then return nil end

    local hdr = file_read(fh, offset, 9)
    if not hdr or #hdr < 9 then file_close(fh); return nil end

    -- SCI1.1: packedSz is the actual compressed data size (no sub-header)
    local packed_sz = u16le(hdr, 4)
    local unpack_sz = u16le(hdr, 6)
    local comp_method = u16le(hdr, 8)
    local data_sz = packed_sz
    if data_sz < 0 then data_sz = 0 end

    local raw = file_read(fh, offset + 9, data_sz)
    file_close(fh)
    if not raw then return nil end

    return decompress_resource(raw, comp_method, unpack_sz)
end

local function read_resource(game_path, vol, offset, ver)
    if ver == "sci11" then
        return read_resource_sci11(game_path, vol, offset)
    elseif ver == "sci1" then
        return read_resource_sci1(game_path, vol, offset)
    else
        return read_resource_sci0(game_path, vol, offset)
    end
end

-- ============================================================================
-- SCI0 View Parser and Cel Renderer
-- ============================================================================

local function parse_view_loops(data)
    if #data < 5 then return nil end
    local loop_count = u8(data, 3) -- byte 2 (0-based)
    if loop_count < 1 or loop_count > 128 then return nil end

    local loops = {}
    for lno = 0, loop_count - 1 do
        local loff_pos = 5 + lno * 2 -- byte 4+lno*2 (0-based) -> 1-based
        if loff_pos + 1 > #data then break end
        local loop_off = u16le(data, loff_pos) -- 0-based offset

        if loop_off + 1 > #data then break end
        local cel_count = u8(data, loop_off + 1) -- byte loop_off (0-based)
        if cel_count < 1 or cel_count > 200 then
            table.insert(loops, {})
            goto next_loop
        end

        local cels = {}
        for cno = 0, cel_count - 1 do
            local coff_pos = loop_off + 5 + cno * 2 -- loopData+4+cno*2 (0-based) -> +1
            if coff_pos + 1 > #data then break end
            local cel_off = u16le(data, coff_pos) -- 0-based offset

            if cel_off + 7 > #data then break end
            local w = u16le(data, cel_off + 1)
            local h = u16le(data, cel_off + 3)
            local clear_key = u8(data, cel_off + 7)

            if w < 1 or w > 1024 or h < 1 or h > 1024 then break end
            table.insert(cels, {
                width = w, height = h,
                clear_key = clear_key,
                data_pos = cel_off + 8, -- pixel data at 1-based position
            })
        end
        table.insert(loops, cels)
        ::next_loop::
    end
    return loops
end

local function render_cel(data, cel, pal)
    local w, h, ck = cel.width, cel.height, cel.clear_key
    local pix = {}
    for i = 1, w * h do pix[i] = ck end

    local pos = cel.data_pos
    for y = 0, h - 1 do
        local x = 0
        while x < w and pos <= #data do
            local b = u8(data, pos)
            pos = pos + 1
            if b >= 128 then
                x = x + (b - 128) -- skip transparent
            else
                pix[y * w + x + 1] = b
                x = x + 1
            end
        end
    end

    return image_create_indexed(w, h, pix, pal)
end

-- ============================================================================
-- VGA Palette Parser (type 11 resources)
-- ============================================================================

local function parse_vga_palette(data)
    if not data or #data < 37 then return nil end

    local pal = {}
    for i = 0, 255 do pal[i*3+1]=0; pal[i*3+2]=0; pal[i*3+3]=0 end

    if u8(data, 1) == 0 and u8(data, 2) == 1 then
        -- Old SCI1 format: 256-byte mapping + 4-byte timestamp + 256×4 palette
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

local function load_game_palette(game_path, resources, ver)
    -- Try palette 999 first (default game palette), then 0
    for _, pnum in ipairs({999, 0, 1}) do
        for _, r in ipairs(resources) do
            if r.type == 11 and r.number == pnum then
                local data = read_resource(game_path, r.volume, r.offset, ver)
                if data then
                    local pal = parse_vga_palette(data)
                    if pal then return pal end
                end
            end
        end
    end
    -- Fallback: grayscale
    local pal = {}
    for i = 0, 255 do pal[i*3+1]=i; pal[i*3+2]=i; pal[i*3+3]=i end
    return pal
end

-- ============================================================================
-- VGA RLE Cel Renderer (SCI1 / SCI1.1)
-- ============================================================================

local function render_cel_vga(data, cel, pal)
    local w, h, ck = cel.width, cel.height, cel.clear_key
    local pix = {}
    for i = 1, w * h do pix[i] = ck end

    local rle_pos = cel.offsetRLE
    local lit_pos = cel.offsetLiteral > 0 and cel.offsetLiteral or nil

    if rle_pos == 0 then
        -- Uncompressed: direct copy from literal data
        if not lit_pos then return nil end  -- no data for this cel
        for i = 1, w * h do
            if lit_pos <= #data then
                pix[i] = u8(data, lit_pos)
                lit_pos = lit_pos + 1
            end
        end
        return image_create_indexed(w, h, pix, pal)
    end

    for y = 0, h - 1 do
        local x = 0
        while x < w and rle_pos <= #data do
            local b = u8(data, rle_pos)
            rle_pos = rle_pos + 1
            local cmd = math.floor(b / 64)
            local run_len = b % 64
            if cmd == 1 then run_len = run_len + 64 end

            if cmd == 0 or cmd == 1 then
                -- Copy literal pixels
                for i = 1, run_len do
                    if x < w then
                        if lit_pos then
                            if lit_pos <= #data then
                                pix[y * w + x + 1] = u8(data, lit_pos)
                                lit_pos = lit_pos + 1
                            end
                        else
                            if rle_pos <= #data then
                                pix[y * w + x + 1] = u8(data, rle_pos)
                                rle_pos = rle_pos + 1
                            end
                        end
                        x = x + 1
                    end
                end
            elseif cmd == 2 then
                -- Fill with single color
                local fill
                if lit_pos then
                    fill = lit_pos <= #data and u8(data, lit_pos) or 0
                    lit_pos = lit_pos + 1
                else
                    fill = rle_pos <= #data and u8(data, rle_pos) or 0
                    rle_pos = rle_pos + 1
                end
                for i = 1, run_len do
                    if x < w then
                        pix[y * w + x + 1] = fill
                        x = x + 1
                    end
                end
            else -- cmd == 3
                -- Skip (transparent)
                x = x + run_len
            end
        end
    end

    return image_create_indexed(w, h, pix, pal)
end

-- ============================================================================
-- SCI Pic Renderer
-- ============================================================================

-- SCI1.1 VGA Pic: header_size == 0x26, embedded cel + palette at fixed offsets
local function render_pic_sci11(data, game_pal)
    if #data < 38 then return nil, "data too short" end

    local has_cel = u8(data, 5)  -- byte 4 (0-based)
    if has_cel == 0 then return nil, "no embedded cel" end

    local palette_off = u32le(data, 29)   -- byte 28 in 0-based
    local cel_hdr_off = u32le(data, 33)   -- byte 32 in 0-based

    if cel_hdr_off + 32 > #data then return nil, "cel header out of bounds" end

    -- Parse embedded palette
    local pic_pal = game_pal
    if palette_off > 0 and palette_off < #data then
        local ep = parse_vga_palette(data:sub(palette_off + 1))
        if ep then pic_pal = ep end
    end

    -- Parse cel header (all offsets 0-based, convert to 1-based for Lua)
    local chp = cel_hdr_off + 1  -- 1-based position in data
    local width  = u16le(data, chp)
    local height = u16le(data, chp + 2)
    local rle_off = u32le(data, chp + 24)   -- absolute offset in resource
    local lit_off = u32le(data, chp + 28)   -- absolute offset in resource

    if width < 1 or width > 640 or height < 1 or height > 400 then
        return nil, "invalid dimensions"
    end

    local cel = {
        width = width,
        height = height,
        clear_key = 255,  -- SCI1.1 hardcodes white
        offsetRLE = rle_off + 1,         -- convert to 1-based
        offsetLiteral = lit_off > 0 and (lit_off + 1) or 0,
    }

    local img = render_cel_vga(data, cel, pic_pal)
    return img, nil
end

-- SCI1 VGA vector Pic: parse opcodes to find embedded view and palette
local function render_pic_vector_vga(data, game_pal)
    local pic_pal = game_pal
    local cel_img = nil

    -- Skip data bytes until next opcode (bytes >= 0xF0 are opcodes)
    local function skip_data(p)
        while p <= #data and u8(data, p) < 0xF0 do p = p + 1 end
        return p
    end

    local pos = 1
    while pos <= #data do
        local op = u8(data, pos)
        pos = pos + 1
        if op == 0xF0 or op == 0xF2 or op == 0xF9 or op == 0xFB then
            -- SET_COLOR / SET_PRIORITY / SET_PATTERN / SET_CONTROL: 1 param
            pos = pos + 1
        elseif op == 0xF1 or op == 0xF3 or op == 0xFC then
            -- DISABLE_VISUAL / DISABLE_PRIORITY / DISABLE_CONTROL: no params
        elseif op >= 0xF4 and op <= 0xF8 or op == 0xFA or op == 0xFD then
            -- Lines / Fill / Patterns: variable data bytes, all < 0xF0
            pos = skip_data(pos)
        elseif op == 0xFE then
            -- Extended opcode
            if pos > #data then break end
            local sub = u8(data, pos)
            pos = pos + 1
            if sub == 0x00 then
                -- SET_PALETTE_ENTRIES: variable data
                pos = skip_data(pos)
            elseif sub == 0x02 then
                -- VGA_SET_PALETTE: 260 bytes (mapping+timestamp) + 256×4 palette
                if pos + 1284 <= #data + 1 then
                    local pal_start = pos + 260
                    local pal = {}
                    for i = 0, 255 do pal[i*3+1]=0; pal[i*3+2]=0; pal[i*3+3]=0 end
                    for i = 0, 255 do
                        local ep = pal_start + i * 4
                        pal[i*3+1] = u8(data, ep + 1)
                        pal[i*3+2] = u8(data, ep + 2)
                        pal[i*3+3] = u8(data, ep + 3)
                    end
                    pic_pal = pal
                end
                pos = pos + 1284
            elseif sub == 0x01 then
                -- VGA_EMBEDDED_VIEW: 3 bytes coords + 2 bytes size + cel data
                if pos + 5 <= #data then
                    pos = pos + 3  -- skip packed coordinates
                    local size = u16le(data, pos)
                    pos = pos + 2
                    local chp = pos  -- cel header (1-based)
                    if chp + 8 <= #data then
                        local width  = u16le(data, chp)
                        local height = u16le(data, chp + 2)
                        local clear_color = u8(data, chp + 6)
                        if width >= 1 and width <= 640 and height >= 1 and height <= 400 then
                            local cel = {
                                width = width,
                                height = height,
                                clear_key = clear_color,
                                offsetRLE = chp + 8,
                                offsetLiteral = 0,
                            }
                            cel_img = render_cel_vga(data, cel, pic_pal)
                        end
                    end
                    pos = pos + size
                end
            elseif sub == 0x03 then pos = pos + 4   -- PRIORITY_TABLE_EQDIST
            elseif sub == 0x04 then pos = pos + 14  -- PRIORITY_TABLE_EXPLICIT
            end
        elseif op == 0xFF then
            break
        end
    end

    return cel_img, nil
end

-- ============================================================================
-- SCI1 VGA View Parser
-- ============================================================================

local function parse_view_sci1(data)
    if #data < 10 then return nil end

    local loop_count = u8(data, 1)        -- offset 0
    local pal_offset = u16le(data, 7)     -- offset 6

    if loop_count < 1 or loop_count > 128 then return nil end

    -- Loop offsets at offset 8, each u16le
    local loops = {}
    for lno = 0, loop_count - 1 do
        local loff_pos = 9 + lno * 2      -- offset 8+lno*2 → pos 9+lno*2
        if loff_pos + 1 > #data then break end
        local loop_off = u16le(data, loff_pos)  -- 0-based offset

        if loop_off + 3 > #data then
            table.insert(loops, {})
            goto next_sci1_loop
        end

        local mirror_flag = u8(data, loop_off + 1)   -- byte 0 of loop
        local cel_count = u8(data, loop_off + 3)      -- byte 2 of loop

        if mirror_flag ~= 255 then
            table.insert(loops, { mirror_of = mirror_flag })
            goto next_sci1_loop
        end

        if cel_count < 1 or cel_count > 200 then
            table.insert(loops, {})
            goto next_sci1_loop
        end

        local cels = {}
        for cno = 0, cel_count - 1 do
            local co_pos = loop_off + 5 + cno * 2  -- byte 4+cno*2 → pos +1
            if co_pos + 1 > #data then break end
            local cel_off = u16le(data, co_pos)     -- 0-based offset

            if cel_off + 8 > #data then break end
            local w = u16le(data, cel_off + 1)      -- byte 0
            local h = u16le(data, cel_off + 3)      -- byte 2
            local clear_key = u8(data, cel_off + 7) -- byte 6

            if w < 1 or w > 1024 or h < 1 or h > 1024 then break end

            -- SCI1: always interleaved (RLE commands + inline pixel data)
            local rle_off = cel_off + 9   -- byte 8 → +1 for 1-based
            local lit_off = 0

            table.insert(cels, {
                width = w, height = h,
                clear_key = clear_key,
                offsetRLE = rle_off,
                offsetLiteral = lit_off,
            })
        end
        table.insert(loops, cels)
        ::next_sci1_loop::
    end

    -- Resolve mirrored loops
    for i, loop in ipairs(loops) do
        if loop.mirror_of then
            local src = loops[loop.mirror_of + 1]
            if src and not src.mirror_of then
                loops[i] = src
            else
                loops[i] = {}
            end
        end
    end

    return loops, pal_offset > 0 and (pal_offset + 1) or 0
end

-- ============================================================================
-- SCI1.1 VGA View Parser (Big-Endian headers)
-- ============================================================================

local function parse_view_sci11(data)
    if #data < 14 then return nil end

    local header_size = u16be(data, 1) + 2   -- offset 0 (u16be) + 2
    local loop_count = u8(data, 3)            -- offset 2
    local pal_offset_raw = u32be(data, 9)     -- offset 8 (u32be)
    local loop_hdr_size = u8(data, 13)        -- offset 12
    local cel_hdr_size = u8(data, 14)         -- offset 13
    if cel_hdr_size < 32 then cel_hdr_size = 32 end

    if loop_count < 1 or loop_count > 128 then return nil end

    local pal_offset = pal_offset_raw > 0 and (pal_offset_raw + 1) or 0

    local loops = {}
    for lno = 0, loop_count - 1 do
        local lp = header_size + 1 + lno * loop_hdr_size  -- 1-based
        if lp + loop_hdr_size - 1 > #data then break end

        local seek = u8(data, lp)       -- byte 0: mirror source (255=none)
        local cel_count = u8(data, lp + 2)   -- byte 2

        if seek ~= 255 then
            table.insert(loops, { mirror_of = seek })
            goto next_sci11_loop
        end
        if cel_count < 1 or cel_count > 200 then
            table.insert(loops, {})
            goto next_sci11_loop
        end

        -- Cel data offset: u32be at loop header + 12
        local cel_base_raw = u32be(data, lp + 12)

        local cels = {}
        for cno = 0, cel_count - 1 do
            local cp = cel_base_raw + 1 + cno * cel_hdr_size  -- 1-based
            if cp + cel_hdr_size - 1 > #data then break end

            local w = i16be(data, cp)            -- byte 0
            local h = i16be(data, cp + 2)        -- byte 2
            local clear_key = u8(data, cp + 8)   -- byte 8
            local rle_raw = u32be(data, cp + 24)  -- byte 24
            local lit_raw = u32be(data, cp + 28)  -- byte 28

            if w < 1 or w > 1024 or h < 1 or h > 1024 then break end

            table.insert(cels, {
                width = w, height = h,
                clear_key = clear_key,
                offsetRLE = rle_raw > 0 and (rle_raw + 1) or 0,
                offsetLiteral = lit_raw > 0 and (lit_raw + 1) or 0,
            })
        end
        table.insert(loops, cels)
        ::next_sci11_loop::
    end

    -- Resolve mirrored loops
    for i, loop in ipairs(loops) do
        if loop.mirror_of then
            local src = loops[loop.mirror_of + 1]
            if src and not src.mirror_of then
                loops[i] = src
            else
                loops[i] = {}
            end
        end
    end

    return loops, pal_offset
end

-- ============================================================================
-- Public engine API
-- ============================================================================

function engine.detect(game_path)
    if not file_exists(game_path .. "/RESOURCE.MAP") then return false end
    for i = 0, 9 do
        if file_exists(game_path .. string.format("/RESOURCE.%03d", i)) then
            return true
        end
    end
    return false
end

function engine.get_resources(game_path)
    local resources, ver = parse_map(game_path)
    if not resources then return {} end

    -- Group by type
    local by_type = {}
    for _, r in ipairs(resources) do
        if not by_type[r.type] then by_type[r.type] = {} end
        table.insert(by_type[r.type], r)
    end

    local tree = {}
    -- Sorted type order: views first, then pics, then others
    local type_order = {0, 1, 11, 7, 8, 2, 3, 4, 6, 9, 10, 15, 17}
    for _, t in ipairs(type_order) do
        local items = by_type[t]
        if items then
            local type_name = RES_NAMES[t] or ("Type " .. t)
            local kids = {}
            for _, r in ipairs(items) do
                local res_type = (t == 0 or t == 1 or t == 7 or t == 8) and "image" or "text"
                table.insert(kids, {
                    id = string.format("r_%d_%d", t, r.number),
                    name = string.format("%s %d", type_name:sub(1, -2), r.number),
                    type = res_type,
                })
            end
            table.sort(kids, function(a, b) return a.name < b.name end)
            table.insert(tree, {
                id = "type_" .. t,
                name = type_name .. " (" .. #items .. ")",
                type = "category",
                children = kids,
            })
        end
    end

    return tree
end

function engine.load_resource(game_path, resource_id)
    local rtype_s, rnum_s = resource_id:match("^r_(%d+)_(%d+)$")
    if not rtype_s then
        return { type = "text", text = "Unknown resource: " .. resource_id }
    end

    local rtype = tonumber(rtype_s)
    local rnum = tonumber(rnum_s)

    -- Find the resource in the map
    local resources, ver = parse_map(game_path)
    if not resources then
        return { type = "text", text = "Failed to parse RESOURCE.MAP" }
    end

    local res
    for _, r in ipairs(resources) do
        if r.type == rtype and r.number == rnum then res = r; break end
    end
    if not res then
        return { type = "text", text = "Resource not found in map" }
    end

    local data = read_resource(game_path, res.volume, res.offset, ver)
    if not data then
        return { type = "text", text = string.format("Failed to load %s %d (vol=%d, comp?)",
            RES_NAMES[rtype] or "resource", rnum, res.volume) }
    end

    -- Determine palette based on SCI version
    local pal
    local is_vga = (ver == "sci1" or ver == "sci11")
    if is_vga then
        pal = load_game_palette(game_path, resources, ver)
    else
        pal = ega_palette()
    end

    -- PALETTE resource (type 11)
    if rtype == 11 then
        local vpal = parse_vga_palette(data)
        if vpal then
            -- Show a 16x16 color swatch grid
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
            local img = image_create_indexed(sw, sh, pix, vpal)
            return {
                type = "image", image = img,
                description = string.format("Palette %d (%d bytes)", rnum, #data),
            }
        end
        return { type = "text", text = string.format("Palette %d: %d bytes", rnum, #data) }
    end

    -- VIEW resource (type 0)
    if rtype == 0 then
        local loops, emb_pal_off
        local render_fn

        if ver == "sci11" then
            loops, emb_pal_off = parse_view_sci11(data)
            render_fn = render_cel_vga
        elseif ver == "sci1" then
            loops, emb_pal_off = parse_view_sci1(data)
            render_fn = render_cel_vga
        else
            loops = parse_view_loops(data)
            render_fn = render_cel
        end

        -- If view has embedded palette, parse and use it
        if emb_pal_off and emb_pal_off > 0 and emb_pal_off <= #data then
            local emb_pal = parse_vga_palette(data:sub(emb_pal_off))
            if emb_pal then pal = emb_pal end
        end
        if not loops or #loops == 0 then
            return { type = "text", text = string.format("View %d: %d bytes (parse failed)", rnum, #data) }
        end

        -- Collect all renderable cels
        local frames = {}
        for lno, cels in ipairs(loops) do
            for cno, cel in ipairs(cels) do
                local img = render_fn(data, cel, pal)
                if img then table.insert(frames, { img = img, loop = lno - 1, cel = cno - 1 }) end
            end
        end

        if #frames == 0 then
            return { type = "text", text = string.format("View %d: no renderable cels", rnum) }
        end

        if #frames == 1 then
            return {
                type = "image", image = frames[1].img,
                description = string.format("View %d (Loop %d, Cel %d)", rnum, frames[1].loop, frames[1].cel),
            }
        end

        -- Multiple cels: show first loop as animation (or all cels)
        local first_loop_cels = loops[1]
        if first_loop_cels and #first_loop_cels > 1 then
            local anim_frames = {}
            for _, cel in ipairs(first_loop_cels) do
                local img = render_fn(data, cel, pal)
                if img then table.insert(anim_frames, img) end
            end
            if #anim_frames > 1 then
                local anim = animation_create(anim_frames, 150)
                return {
                    type = "animation", animation = anim,
                    image = anim_frames[1], frames = anim_frames,
                    description = string.format("View %d (%d loops, %d total cels)", rnum, #loops, #frames),
                }
            end
        end

        return {
            type = "image", image = frames[1].img,
            description = string.format("View %d (Loop %d, Cel %d) [%d total cels]",
                rnum, frames[1].loop, frames[1].cel, #frames),
        }
    end

    -- PIC resource (type 1)
    if rtype == 1 then
        if is_vga and #data >= 38 and u16le(data, 1) == 0x26 then
            -- SCI1.1 VGA pic with embedded cel
            local img, err = render_pic_sci11(data, pal)
            if img then
                return {
                    type = "image", image = img,
                    description = string.format("Pic %d (SCI1.1 VGA, %d bytes)", rnum, #data),
                }
            end
            return { type = "text", text = string.format("Pic %d: %d bytes (SCI1.1 - %s)", rnum, #data, err or "render failed") }
        elseif is_vga then
            -- SCI1 VGA vector pic - try to extract embedded view
            local img, err = render_pic_vector_vga(data, pal)
            if img then
                return {
                    type = "image", image = img,
                    description = string.format("Pic %d (SCI1 VGA embedded view, %d bytes)", rnum, #data),
                }
            end
            return { type = "text", text = string.format("Pic %d: %d bytes (SCI1 VGA vector - no embedded view found)", rnum, #data) }
        else
            return { type = "text", text = string.format("Pic %d: %d bytes (SCI0 EGA vector - rendering not supported)", rnum, #data) }
        end
    end

    -- FONT resource (type 7)
    if rtype == 7 then
        -- SCI0 font: simple bitmap font, could render a preview
        return {
            type = "text",
            text = string.format("Font %d: %d bytes", rnum, #data),
        }
    end

    -- CURSOR resource (type 8)
    if rtype == 8 then
        -- SCI0 cursor: 16x16 monochrome, 2bpp? Or similar to a small view cel
        if #data >= 68 then
            -- Try: 4-byte header + 16x16 data (2 bytes per row = 32 bytes cursor + 32 bytes mask)
            -- Actually: SCI0 cursor = 2x(16x16 bits) = 2x32 bytes = 64 bytes + small header
            local w, h = 16, 16
            local pix = {}
            for i = 1, w * h do pix[i] = 15 end -- white default
            -- Assume: 4 bytes header, then 32 bytes mask, then 32 bytes pixels
            -- Each row is 2 bytes (16 bits)
            for y = 0, 15 do
                local mask_hi = u8(data, 5 + y * 2)
                local mask_lo = u8(data, 6 + y * 2)
                local pix_hi = u8(data, 37 + y * 2)
                local pix_lo = u8(data, 38 + y * 2)
                for x = 0, 7 do
                    local bp = 7 - x
                    local m = math.floor(mask_hi / POW2[bp]) % 2
                    local p = math.floor(pix_hi / POW2[bp]) % 2
                    if m == 0 then
                        pix[y * 16 + x + 1] = p == 1 and 15 or 0
                    else
                        pix[y * 16 + x + 1] = 0 -- transparent = black
                    end
                end
                for x = 0, 7 do
                    local bp = 7 - x
                    local m = math.floor(mask_lo / POW2[bp]) % 2
                    local p = math.floor(pix_lo / POW2[bp]) % 2
                    if m == 0 then
                        pix[y * 16 + x + 8 + 1] = p == 1 and 15 or 0
                    else
                        pix[y * 16 + x + 8 + 1] = 0
                    end
                end
            end
            local img = image_create_indexed(w, h, pix, pal)
            return {
                type = "image", image = img,
                description = string.format("Cursor %d (16x16)", rnum),
            }
        end
        return { type = "text", text = string.format("Cursor %d: %d bytes", rnum, #data) }
    end

    -- Other resource types: show metadata
    local type_name = RES_NAMES[rtype] or ("Type " .. rtype)
    return {
        type = "text",
        text = string.format("%s %d: %d bytes", type_name, rnum, #data),
    }
end

return engine

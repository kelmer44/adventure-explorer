-- ============================================================================
-- Adventure Explorer - Engine Script: Alone in the Dark (AITD Engine)
-- ============================================================================
-- Infogrames, 1992-1995. DOS. PAK archive format.
--
-- Supports all five AITD games:
--   AITD1    - Alone in the Dark (1992)           detect: LISTBOD2.PAK
--   JACK     - Jack in the Dark (1993)            detect: PERE.PAK
--   AITD2    - Alone in the Dark 2 (1993)         detect: MER.PAK
--   AITD3    - Alone in the Dark 3 (1994)         detect: AN1.PAK
--   TIMEGATE - TimeGate: Knight's Chase (1995)    detect: PURSUIT.PAK
--
-- Resources:
--   ITD_RESS.PAK  - Title/intro screens (palette+skip+pixels format):
--                     bytes 0-767   : 256-entry 6-bit VGA palette
--                     bytes 768-769 : 2 unknown bytes (skipped)
--                     bytes 770-64769: 64000 raw 8-bit indexed pixels (320x200)
--   CAMERA00.PAK  - Camera backgrounds for floor 0
--   CAMERA01.PAK  - Camera backgrounds for floor 1  ... etc.
--                   AITD1: bytes 0-63999 = pixels only (palette from ITD_RESS[3])
--                   JACK+: bytes 0-63999 = pixels, bytes 64000-64767 = 6-bit palette
--
-- PAK format (source: FITD / pak.cpp):
--   The file begins with an offset table:
--     u32le[0]        : header value (skipped, carries no entry reference)
--     u32le[1]        : file offset of entry 0   (= (numEntries+2)*4)
--     u32le[2]        : file offset of entry 1
--     ...
--     u32le[numEntries]: file offset of entry numEntries-1
--     u32le[numEntries+1]: terminator
--   numEntries = u32le[1] / 4 - 2
--
--   Each entry at its file offset:
--     u32le additionalDescSize  -- if != 0, skip (additionalDescSize-4) more bytes
--     s32le diskSize
--     s32le uncompressedSize
--     u8    compressionFlag     -- 0=raw, 1=PAK_explode (DCL implode), 4=deflate
--     u8    info5               -- unused
--     s16le nameOffset          -- bytes to skip (name string), often 0
--     [nameOffset bytes]        -- entry name (skipped)
--     [diskSize bytes]          -- compressed or raw data
-- ============================================================================

local engine = {}
engine.name        = "Alone in the Dark (AITD)"
engine.id          = "aitd"
engine.description = "Alone in the Dark series (Infogrames, 1992-1995)"
engine.version     = "1.0"

-- ============================================================================
-- Binary helpers (no bit32 in LuaJ 3.0.1)
-- ============================================================================

local function u8(data, pos)
    return data:byte(pos)
end

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end

-- ============================================================================
-- PAK_explode decompressor (PKWare DCL implode, FITD variant)
-- Based on FITD/unpack.cpp by Cyril Voila (Mark Adler's explode algorithm)
-- ============================================================================

local POW2 = {}
for i = 0, 24 do POW2[i] = 2 ^ i end

-- Base lengths: no literal tree (min match = 2)
local cplen2 = {}
for i = 0, 63 do cplen2[i] = i + 2 end
-- Base lengths: with literal tree (min match = 3)
local cplen3 = {}
for i = 0, 63 do cplen3[i] = i + 3 end
-- Extra bits per length symbol (all 0 except last = 8)
local extra_len = {}
for i = 0, 62 do extra_len[i] = 0 end
extra_len[63] = 8
-- Base distances: 4K window (bdl=6)
local cpdist4 = {}
for i = 0, 63 do cpdist4[i] = 1 + i * 64 end
-- Base distances: 8K window (bdl=7)
local cpdist8 = {}
for i = 0, 63 do cpdist8[i] = 1 + i * 128 end

-- Reverse `n` bits of integer `x`
local function bit_reverse(x, n)
    local r = 0
    for _ = 1, n do
        r = r * 2 + x % 2
        x = math.floor(x / 2)
    end
    return r
end

-- Read packed tree definitions (PAK_get_tree format)
local function pak_get_tree(data, pos, n)
    if pos > #data then return nil, pos end
    local num_groups = data:byte(pos) + 1
    pos = pos + 1
    local lengths = {}
    local k = 0
    for _ = 1, num_groups do
        if pos > #data then return nil, pos end
        local b = data:byte(pos)
        pos = pos + 1
        local bit_len = b % 16 + 1
        local count = math.floor(b / 16) + 1
        for _ = 1, count do
            k = k + 1
            if k > n then return nil, pos end
            lengths[k] = bit_len
        end
    end
    if k ~= n then return nil, pos end
    return lengths, pos
end

-- Build flat Huffman decode table from bit lengths.
-- Returns table indexed [0..2^max_len-1] -> packed (sym*256 + code_len), and max_len.
-- Lookup uses (~b) & mask to find the entry.
local function pak_build_table(lengths, n)
    local max_len = 0
    local bl_count = {}
    for i = 0, 16 do bl_count[i] = 0 end
    for i = 1, n do
        local l = lengths[i]
        if l > max_len then max_len = l end
        bl_count[l] = bl_count[l] + 1
    end
    if max_len == 0 then return nil, 0 end
    bl_count[0] = 0

    -- Canonical code assignment
    local next_code = {}
    local code = 0
    for bits = 1, max_len do
        code = (code + bl_count[bits - 1]) * 2
        next_code[bits] = code
    end

    local tsize = math.floor(POW2[max_len])
    local tbl = {}
    for sym = 0, n - 1 do
        local len = lengths[sym + 1]
        if len > 0 then
            local c = next_code[len]
            next_code[len] = c + 1
            -- Table index = complement of bit-reversed code
            local rev = bit_reverse(c, len)
            local comp = math.floor(POW2[len]) - 1 - rev
            local step = math.floor(POW2[len])
            local packed = sym * 256 + len
            for idx = comp, tsize - 1, step do
                tbl[idx] = packed
            end
        end
    end
    return tbl, max_len
end

-- Main PAK_explode decompressor.
-- data:       compressed bytes as string
-- comp_size:  compressed size
-- uncomp_size: expected decompressed size
-- flags:      info5 from PAK header (bit2=lit tree, bit1=8K window)
local function pak_explode(data, comp_size, uncomp_size, flags)
    local WSIZE = 0x8000

    -- Byte reader (consumes bytes for tree definitions before bit-reading starts)
    local rpos = 1
    local function next_byte()
        if rpos > comp_size then return 0 end
        local b = data:byte(rpos)
        rpos = rpos + 1
        return b
    end

    -- Read Huffman trees from the byte stream
    local tb, tl, td, tb_max, tl_max, td_max
    local cplen, cpdist, bdl

    if flags % 8 >= 4 then
        -- Literal tree present (min match = 3)
        local lit_len
        lit_len, rpos = pak_get_tree(data, rpos, 256)
        if not lit_len then return nil end
        tb, tb_max = pak_build_table(lit_len, 256)

        local len_len
        len_len, rpos = pak_get_tree(data, rpos, 64)
        if not len_len then return nil end
        tl, tl_max = pak_build_table(len_len, 64)
        cplen = cplen3
    else
        -- No literal tree (raw 8-bit literals, min match = 2)
        tb = nil
        local len_len
        len_len, rpos = pak_get_tree(data, rpos, 64)
        if not len_len then return nil end
        tl, tl_max = pak_build_table(len_len, 64)
        cplen = cplen2
    end

    local dist_len
    dist_len, rpos = pak_get_tree(data, rpos, 64)
    if not dist_len then return nil end

    if flags % 4 >= 2 then
        bdl = 7; cpdist = cpdist8
    else
        bdl = 6; cpdist = cpdist4
    end
    td, td_max = pak_build_table(dist_len, 64)

    if not tl or not td then return nil end

    -- Bit buffer (LSB-first, matching the C macros)
    local bb = 0
    local bk = 0

    local function need_bits(n)
        while bk < n do
            bb = bb + next_byte() * POW2[bk]
            bk = bk + 8
        end
    end

    local function dump_bits(n)
        bb = math.floor(bb / POW2[n])
        bk = bk - n
    end

    -- Decode one symbol from a Huffman table (flat lookup with ~b masking)
    local function decode_sym(tbl, max_bits)
        need_bits(max_bits)
        local mask = POW2[max_bits] - 1
        local idx = mask - math.floor(bb % (mask + 1))
        local entry = tbl[idx]
        if not entry then return 0 end
        local sym = math.floor(entry / 256)
        local clen = entry % 256
        dump_bits(clen)
        return sym
    end

    -- Sliding window
    local slide = {}
    for i = 1, WSIZE do slide[i] = 0 end
    local w = 0
    local first_fill = true

    -- Output accumulator
    local out = {}
    local out_n = 0

    local function flush(size)
        for i = 1, size do
            out_n = out_n + 1
            out[out_n] = slide[i]
        end
    end

    local s = uncomp_size
    while s > 0 do
        need_bits(1)
        if bb % 2 == 1 then
            -- Literal
            dump_bits(1)
            s = s - 1
            local val
            if tb then
                val = decode_sym(tb, tb_max)
            else
                need_bits(8)
                val = bb % 256
                dump_bits(8)
            end
            w = w + 1
            slide[w] = val
            if w == WSIZE then flush(w); w = 0; first_fill = false end
        else
            -- Back-reference
            dump_bits(1)

            need_bits(bdl)
            local d = bb % POW2[bdl]
            dump_bits(bdl)

            local dist_sym = decode_sym(td, td_max)
            d = (w - d - cpdist[dist_sym]) % WSIZE

            local len_sym = decode_sym(tl, tl_max)
            local n = cplen[len_sym]
            if extra_len[len_sym] > 0 then
                need_bits(8)
                n = n + bb % 256
                dump_bits(8)
            end

            s = (s > n) and (s - n) or 0

            repeat
                d = d % WSIZE
                local e = WSIZE - (d > w and d or w)
                if e > n then e = n end
                n = n - e

                if first_fill and w <= d then
                    for _ = 1, e do
                        w = w + 1
                        slide[w] = 0
                    end
                    d = d + e
                else
                    for _ = 1, e do
                        slide[w + 1] = slide[d + 1]
                        w = w + 1
                        d = d + 1
                    end
                end

                if w == WSIZE then flush(w); w = 0; first_fill = false end
            until n == 0
        end
    end

    if w > 0 then flush(w) end

    local t = {}
    for i = 1, out_n do t[i] = string.char(out[i]) end
    return table.concat(t)
end

-- ============================================================================
-- Game variant detection
-- ============================================================================

local VARIANT_NAMES = {
    AITD1    = "Alone in the Dark (1992)",
    JACK     = "Jack in the Dark (1993)",
    AITD2    = "Alone in the Dark 2 (1993)",
    AITD3    = "Alone in the Dark 3 (1994)",
    TIMEGATE = "TimeGate: Knight's Chase (1995)",
    UNKNOWN  = "Unknown AITD game",
}

local function detect_variant(game_path)
    if file_exists(game_path .. "/LISTBOD2.PAK") then return "AITD1"    end
    if file_exists(game_path .. "/PERE.PAK")     then return "JACK"     end
    if file_exists(game_path .. "/MER.PAK")      then return "AITD2"    end
    if file_exists(game_path .. "/AN1.PAK")      then return "AITD3"    end
    if file_exists(game_path .. "/PURSUIT.PAK")  then return "TIMEGATE" end
    return "UNKNOWN"
end

-- ============================================================================
-- PAK archive reader
-- ============================================================================

-- Count entries in an open PAK file handle.
local function pak_count(fh)
    if file_size(fh) < 8 then return 0 end
    local d    = file_read(fh, 4, 4)   -- read u32 at file position 4 = entry-0 offset
    local off0 = u32le(d, 1)
    if off0 < 8 then return 0 end
    local n = math.floor(off0 / 4) - 2
    if n < 0 or n > 4096 then return 0 end
    return n
end

-- Read and decompress PAK entry `index` (0-based) from `base_name`.PAK.
-- Returns decompressed binary string, or nil on failure.
local function pak_entry(game_path, base_name, index)
    local path = game_path .. "/" .. base_name .. ".PAK"
    local fh   = file_open(path)
    if not fh then return nil end

    -- Locate entry in the offset table: entry N is at table slot (N+1)
    local tbl_data = file_read(fh, (index + 1) * 4, 4)
    if not tbl_data or #tbl_data < 4 then file_close(fh); return nil end
    local file_off = u32le(tbl_data, 1)

    -- Read additional descriptor size (4 bytes at file_off)
    local addl_data = file_read(fh, file_off, 4)
    if not addl_data or #addl_data < 4 then file_close(fh); return nil end
    local addl_size = u32le(addl_data, 1)

    -- pakInfo starts right after the 4-byte additionalDescSize field (addl_size==0)
    -- or at file_off + additionalDescSize (skip the whole additional descriptor block)
    local pak_info_pos
    if addl_size ~= 0 then
        pak_info_pos = file_off + addl_size
    else
        pak_info_pos = file_off + 4
    end

    -- Read pakInfo: 12 bytes
    --   s32le diskSize          (pos 1-4)
    --   s32le uncompressedSize  (pos 5-8)
    --   u8    compressionFlag   (pos 9)
    --   u8    info5             (pos 10)
    --   s16le nameOffset        (pos 11-12)
    local info = file_read(fh, pak_info_pos, 12)
    if not info or #info < 12 then file_close(fh); return nil end

    local disk_sz   = u32le(info, 1)
    local unpack_sz = u32le(info, 5)
    local comp_flag = u8(info, 9)
    local info5     = u8(info, 10)
    local name_off  = u16le(info, 11)   -- skip this many bytes (embedded name string)

    -- Data begins after pakInfo + optional name bytes
    local data_pos = pak_info_pos + 12 + name_off
    local raw      = file_read(fh, data_pos, disk_sz)
    file_close(fh)

    if not raw then return nil end

    if comp_flag == 0 then
        -- Uncompressed
        return raw
    elseif comp_flag == 4 then
        -- Deflate (zlib)
        local result = zlib_decompress(raw, unpack_sz)
        if not result then
            log_warn("AITD: zlib_decompress failed for " .. base_name .. "[" .. index .. "]")
        end
        return result
    elseif comp_flag == 1 then
        -- PAK_explode (PKWare DCL implode, tree definitions in stream)
        local result = pak_explode(raw, disk_sz, unpack_sz, info5)
        if not result then
            log_warn("AITD: pak_explode failed for " .. base_name .. "[" .. index .. "]")
        end
        return result
    else
        log_warn("AITD: unsupported compression flag " .. comp_flag
                 .. " in " .. base_name .. "[" .. index .. "]")
        return nil
    end
end

-- ============================================================================
-- Palette and pixel helpers
-- ============================================================================

-- Convert 6-bit VGA palette (256 entries * 3 bytes) to 8-bit.
-- `data`  : binary string containing the palette
-- `base`  : 1-based Lua string position of the first palette byte
-- Returns a 768-entry 1-indexed Lua table (R,G,B, R,G,B, ...)
local function pal6_to_8(data, base)
    local pal = {}
    for i = 0, 255 do
        pal[i * 3 + 1] = u8(data, base + i * 3)     * 4
        pal[i * 3 + 2] = u8(data, base + i * 3 + 1) * 4
        pal[i * 3 + 3] = u8(data, base + i * 3 + 2) * 4
    end
    return pal
end

-- Grayscale fallback palette (used when the real palette cannot be loaded)
local function gray_pal()
    local pal = {}
    for i = 0, 255 do
        pal[i * 3 + 1] = i
        pal[i * 3 + 2] = i
        pal[i * 3 + 3] = i
    end
    return pal
end

-- Build a 1-indexed pixel table from `count` bytes starting at `base` (1-based) in `data`
local function pix_table(data, base, count)
    local pix = {}
    for i = 1, count do
        pix[i] = u8(data, base + i - 1)
    end
    return pix
end

-- ============================================================================
-- Public engine API
-- ============================================================================

function engine.detect(game_path)
    -- Require at least one game-specific marker file AND CAMERA00.PAK
    local has_game =
        file_exists(game_path .. "/LISTBOD2.PAK") or
        file_exists(game_path .. "/PERE.PAK")     or
        file_exists(game_path .. "/MER.PAK")      or
        file_exists(game_path .. "/AN1.PAK")      or
        file_exists(game_path .. "/PURSUIT.PAK")
    return has_game and file_exists(game_path .. "/CAMERA00.PAK")
end

function engine.get_resources(game_path)
    local tree = {}

    -- ---- ITD_RESS.PAK : title/intro screens --------------------------------
    do
        local fh = file_open(game_path .. "/ITD_RESS.PAK")
        if fh then
            local n = pak_count(fh)
            file_close(fh)
            if n > 0 then
                local kids = {}
                for i = 0, n - 1 do
                    table.insert(kids, {
                        id   = "ress_" .. i,
                        name = "Entry " .. i,
                        type = "image",
                    })
                end
                table.insert(tree, {
                    id       = "ress",
                    name     = "ITD_RESS Screens",
                    type     = "category",
                    children = kids,
                })
            end
        end
    end

    -- ---- CAMERA*.PAK : in-game camera backgrounds --------------------------
    do
        local floor_cats = {}
        for floor = 0, 19 do
            local pak_name = string.format("CAMERA%02d", floor)
            local fh = file_open(game_path .. "/" .. pak_name .. ".PAK")
            if fh then
                local n = pak_count(fh)
                file_close(fh)
                if n > 0 then
                    local kids = {}
                    for i = 0, n - 1 do
                        table.insert(kids, {
                            id   = string.format("cam_%d_%d", floor, i),
                            name = "Camera " .. i,
                            type = "image",
                        })
                    end
                    table.insert(floor_cats, {
                        id       = "floor_" .. floor,
                        name     = "Floor " .. floor,
                        type     = "category",
                        children = kids,
                    })
                end
            end
        end
        if #floor_cats > 0 then
            table.insert(tree, {
                id       = "cameras",
                name     = "Camera Backgrounds",
                type     = "category",
                children = floor_cats,
            })
        end
    end

    return tree
end

function engine.load_resource(game_path, resource_id)
    local variant      = detect_variant(game_path)
    local variant_name = VARIANT_NAMES[variant] or variant

    -- ---- ITD_RESS entry ----------------------------------------------------
    -- Resource ID format: "ress_N"
    local ress_idx_s = resource_id:match("^ress_(%d+)$")
    if ress_idx_s then
        local idx  = tonumber(ress_idx_s)
        local data = pak_entry(game_path, "ITD_RESS", idx)
        if not data then
            return { type = "text", text = "Failed to load ITD_RESS entry " .. idx }
        end

        -- Screens have: palette(768) + 2 skip bytes + pixels(64000) = 64770 bytes minimum
        if #data < 64770 then
            return {
                type = "text",
                text = string.format("ITD_RESS[%d]: %d bytes (not a full-screen image)", idx, #data),
            }
        end

        -- Bytes 1-768 (1-based): 6-bit VGA palette
        -- Bytes 769-770: skipped
        -- Bytes 771-64770: 64000 raw indexed pixels
        local pal = pal6_to_8(data, 1)
        local pix = pix_table(data, 771, 64000)
        local img = image_create_indexed(320, 200, pix, pal)
        return {
            type        = "image",
            image       = img,
            description = string.format("ITD_RESS[%d] - %s", idx, variant_name),
        }
    end

    -- ---- Camera background -------------------------------------------------
    -- Resource ID format: "cam_F_N"  (F = floor index, N = camera index)
    local floor_s, cam_s = resource_id:match("^cam_(%d+)_(%d+)$")
    if floor_s then
        local floor    = tonumber(floor_s)
        local cam_idx  = tonumber(cam_s)
        local pak_name = string.format("CAMERA%02d", floor)

        local data = pak_entry(game_path, pak_name, cam_idx)
        if not data then
            return {
                type = "text",
                text = string.format("Failed to load %s entry %d", pak_name, cam_idx),
            }
        end

        if #data < 64000 then
            return {
                type = "text",
                text = string.format("%s[%d]: %d bytes (expected >= 64000)", pak_name, cam_idx, #data),
            }
        end

        -- Determine palette source based on game variant:
        --   AITD1: no embedded palette; use ITD_RESS.PAK entry 3 (raw 768-byte 6-bit palette)
        --   JACK, AITD2, AITD3, TIMEGATE: 768-byte 6-bit palette appended after the 64000 pixels
        local pal
        if variant == "AITD1" then
            local ress = pak_entry(game_path, "ITD_RESS", 3)
            if ress and #ress >= 768 then
                pal = pal6_to_8(ress, 1)
            end
        else
            -- Palette at 1-based position 64001 (= 0-based byte 64000, right after pixels)
            if #data >= 64768 then
                pal = pal6_to_8(data, 64001)
            end
        end

        if not pal then
            log_warn("AITD: palette unavailable for " .. pak_name .. "[" .. cam_idx .. "], using grayscale")
            pal = gray_pal()
        end

        -- Pixels occupy bytes 1-64000 (1-based)
        local pix = pix_table(data, 1, 64000)
        local img = image_create_indexed(320, 200, pix, pal)
        return {
            type        = "image",
            image       = img,
            description = string.format("Floor %d, Camera %d - %s", floor, cam_idx, variant_name),
        }
    end

    return { type = "text", text = "Unknown resource id: " .. resource_id }
end

return engine

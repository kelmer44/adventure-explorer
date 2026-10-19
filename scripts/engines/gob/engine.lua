-- ============================================================================
-- Adventure Explorer - Engine Script: GOB / Coktel Vision
-- ============================================================================
-- STK/ITK directories, TOT/EXT sprites, shared IM/EX data, palettes,
-- SND/WAV/ADL/MDY audio and IMD/VMD video. File positions are 1-based.
-- ============================================================================

local engine = {}
engine.name        = "GOB"
engine.id          = "gob"
engine.description = "Coktel Vision: Gobliiins, Fascination, Woodruff and related games"
engine.version     = "5.0"

-- ============================================================================
-- Binary helpers (all positions are 1-based string indices)
-- ============================================================================

local band   = bit32.band
local bor    = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

local function u8(d, p)    return d:byte(p) end
local function u16le(d, p) return d:byte(p) + d:byte(p+1)*256 end
local function i16le(d, p)
    local v = u16le(d, p)
    return v < 32768 and v or v - 65536
end
local function u32le(d, p)
    return d:byte(p) + d:byte(p+1)*256 + d:byte(p+2)*65536 + d:byte(p+3)*16777216
end
local function u16be(d, p) return d:byte(p)*256 + d:byte(p+1) end
local function i32le(d, p)
    local v = u32le(d, p)
    return v < 2147483648 and v or v - 4294967296
end

-- ============================================================================
-- File helper: read entire file into a Lua string
-- ============================================================================

local function read_file_all(path)
    local fh = file_open(path)
    if not fh then return nil end
    local sz = file_size(fh)
    if not sz or sz <= 0 then file_close(fh); return nil end
    local data = file_read(fh, 0, math.floor(sz))
    file_close(fh)
    return data
end

-- ============================================================================
-- STK archive parser
-- Header: u16le fileCount
-- Per entry 22 bytes: 13-byte name + u32le size + u32le offset + u8 compression
-- ============================================================================

local function parse_stk(raw)
    if type(raw) == "table" then return raw.entries end
    if not raw or #raw < 2 then return nil end
    local file_count = u16le(raw, 1)
    if file_count == 0 or file_count > 5000 or 2 + file_count * 22 > #raw then return nil end
    local entries = {}
    for i = 0, file_count - 1 do
        local base = 3 + i * 22  -- 1-based
        local name = ""
        for c = 0, 12 do
            local b = raw:byte(base + c)
            if not b or b == 0 then break end
            name = name .. string.char(b)
        end
        if #name > 0 then
            entries[name:upper()] = {
                name        = name:upper(),
                index       = i,
                size        = u32le(raw, base + 13),
                offset      = u32le(raw, base + 17),
                compression = u8(raw, base + 21)
            }
        end
    end
    return entries
end

-- ============================================================================
-- Coktel LZSS decompressor
-- Window=4096, initial fill=0x20, initial wpos=4078
-- ============================================================================

local function lzss_decompress(data, start_pos, output_size)
    if output_size <= 0 or output_size > 64 * 1024 * 1024 then return nil end
    local out      = {}
    local n        = 0
    local pos      = start_pos
    local len      = #data
    local window   = {}
    for i = 0, 4095 do window[i] = 0x20 end
    local wpos     = 4078
    local extended_len_cmd = -1
    if start_pos + 3 <= len and u16le(data, start_pos) == 0x1234
            and u16le(data, start_pos + 2) == 0x5678 then
        start_pos = start_pos + 4
        pos = start_pos
        wpos = 273
        extended_len_cmd = 18
    end
    local cmd_val  = 0
    local cmd_bits = 0

    while n < output_size and pos <= len do
        if cmd_bits == 0 then
            if pos > len then break end
            cmd_val = data:byte(pos); pos = pos + 1; cmd_bits = 8
        end
        if band(cmd_val, 1) ~= 0 then
            if pos > len then break end
            local b = data:byte(pos); pos = pos + 1
            n = n + 1; out[n] = b
            window[wpos] = b; wpos = band(wpos + 1, 0xFFF)
        else
            if pos + 1 > len then break end
            local lo = data:byte(pos); local hi = data:byte(pos+1); pos = pos + 2
            local src  = bor(lo, lshift(band(hi, 0xF0), 4))
            local rlen = band(hi, 0x0F) + 3
            if rlen == extended_len_cmd then
                if pos > len then break end
                rlen = data:byte(pos) + 18
                pos = pos + 1
            end
            for _ = 1, rlen do
                local b = window[band(src, 0xFFF)]
                n = n + 1; out[n] = b
                window[wpos] = b; wpos = band(wpos + 1, 0xFFF)
                src = src + 1; if n >= output_size then break end
            end
        end
        cmd_val = rshift(cmd_val, 1); cmd_bits = cmd_bits - 1
    end
    if n ~= output_size then return nil end
    -- LuaJ cannot pass a full high-resolution image as function arguments.
    local chunks = {}
    for i = 1, n, 4096 do
        chunks[#chunks + 1] = string.char(table.unpack(out, i, math.min(i + 4095, n)))
    end
    return table.concat(chunks)
end

-- Extract a named file from pre-loaded STK bytes. Compression type 1 is the
-- same Coktel LZSS stream used by packed EXT resources: u32le output size,
-- followed by a standard or extended LZSS chunk.
local function stk_extract(stk_raw, file_name)
    local entries = parse_stk(stk_raw)
    if not entries then return nil end
    local info = entries[file_name:upper()]
    if not info then return nil end
    local data
    if type(stk_raw) == "table" then
        local fh = file_open(stk_raw.path)
        if not fh then return nil end
        data = file_read(fh, info.offset, info.size)
        file_close(fh)
    else
        data = stk_raw:sub(info.offset + 1, info.offset + info.size)
    end
    if not data or #data ~= info.size then return nil end
    if info.compression == 1 then
        if #data < 5 then return nil end
        local unpacked_size = u32le(data, 1)
        if unpacked_size <= 0 or unpacked_size > 64 * 1024 * 1024 then return nil end
        data = lzss_decompress(data, 5, unpacked_size)
    elseif info.compression ~= 0 then
        -- Chunked compression (type 2) is not used by Gob1/2/3 assets.
        return nil
    end
    return data
end

-- ============================================================================
-- Sprite decoders
-- ============================================================================

-- drawPacked: 4-bit RLE
-- byte b: val=rshift(b,4) band 0xF, flags=b band 0xF
-- band(flags,0x08)==0 -> long repeat  = bor(lshift(band(flags,7),8), next_byte) + 1
-- else                -> short repeat = band(flags,7) + 1
local function draw_packed(data, w, h, start_pos)
    local pixels = {}
    local n      = 0
    local needed = w * h
    local pos    = start_pos
    local len    = #data
    while n < needed and pos <= len do
        local b     = data:byte(pos); pos = pos + 1
        local val   = band(rshift(b, 4), 0x0F)
        local flags = band(b, 0x0F)
        local rep
        if band(flags, 0x08) == 0 then
            if pos > len then break end
            rep = bor(lshift(band(flags, 0x07), 8), data:byte(pos)) + 1; pos = pos + 1
        else
            rep = band(flags, 0x07) + 1
        end
        for _ = 1, math.min(rep, needed - n) do
            n = n + 1; pixels[n] = val
        end
    end
    return pixels
end

-- Decode a sprite blob; returns flat pixel index table (1-based, values 0-15+)
local function decode_sprite(data, w, h, is_packed, wide_count)
    local sd = data
    if is_packed then
        if #data < 4 then return nil end
        local unpacked = u32le(data, 1)
        sd = lzss_decompress(data, 5, unpacked)
        if not sd or #sd < 1 then return nil end
    end
    if #sd < 1 then return nil end
    local b0, b1, b2 = sd:byte(1), sd:byte(2), sd:byte(3)
    if b0 == 0x01 and b1 == 0x02 then
        if b2 == 0x02 then
            -- raw pixels at position 4 (1-based), one byte per pixel
            local pixels = {}
            local needed = w * h
            if #sd < needed + 3 then return nil end
            for i = 1, needed do
                pixels[i] = sd:byte(3 + i)
            end
            return pixels
        else
            -- Inner LZSS: v1 u16 or later u32 pixel count, stream at byte 8.
            if #sd < 8 then return nil end
            local pcnt  = wide_count and u32le(sd, 4) or u16le(sd, 4)
            local ldata = lzss_decompress(sd, 8, pcnt)
            if not ldata then return nil end
            local pixels = {}
            for i = 1, math.min(pcnt, w * h) do
                pixels[i] = ldata:byte(i) or 0
            end
            return pixels
        end
    else
        return draw_packed(sd, w, h, 1)
    end
end

-- ============================================================================
-- Parse EXT resource table
-- Header: s16le itemsCount, u8 unknown  (3 bytes)
-- Per entry 10 bytes: s32le rawOffset, u16le size, u16le width_raw, u16le height
-- ============================================================================

local function parse_ext_table(data)
    if not data or #data < 3 then return nil end
    local count      = i16le(data, 1)
    if count <= 0 or count > 5000 or 3 + count * 10 > #data then return nil end
    local data_start = 3 + count * 10
    local items = {}
    for i = 0, count - 1 do
        local base      = 3 + i * 10 + 1   -- 1-based Lua index
        local raw_off   = i32le(data, base)
        local size      = u16le(data, base + 4)
        local width_raw = u16le(data, base + 6)
        local height    = u16le(data, base + 8)
        local packed    = band(width_raw, 0x8000) ~= 0
        local w         = band(width_raw, 0x0FFF)
        if band(width_raw, 0x4000) ~= 0 then size = size + 65536 end
        if band(width_raw, 0x2000) ~= 0 then size = size + 131072 end
        if band(width_raw, 0x1000) ~= 0 then size = size + 262144 end
        local h = height
        if h == 0 then size = size + (band(width_raw, 0x0FFF) * 65536) end
        local ex_type  = raw_off < 0
        local data_off = ex_type and (-raw_off - 1) or (data_start + raw_off)
        items[i + 1] = {
            idx      = i,
            ex_type  = ex_type,
            data_off = data_off,   -- byte offset (0-based)
            size     = size,
            w        = w,
            h        = h,
            packed   = packed,
        }
    end
    return items
end

-- ============================================================================
-- EGA 16-colour palette (fallback when no VGA palette found)
-- ============================================================================

local function build_ega_palette()
    local EGA = {
        {0,0,0},{0,0,168},{0,168,0},{0,168,168},
        {168,0,0},{168,0,168},{168,84,0},{168,168,168},
        {84,84,84},{84,84,252},{84,252,84},{84,252,252},
        {252,84,84},{252,84,252},{252,252,84},{252,252,252},
    }
    local pal = {}
    for i = 0, 255 do
        local r, g, b
        if EGA[i+1] then
            r = EGA[i+1][1]; g = EGA[i+1][2]; b = EGA[i+1][3]
        else
            local v = math.floor((i - 16) / 240.0 * 255)
            r = v; g = v; b = v
        end
        pal[i*3 + 1] = r
        pal[i*3 + 2] = g
        pal[i*3 + 3] = b
    end
    return pal
end

-- ============================================================================
-- STK file list (must be defined before functions that reference it)
-- ============================================================================

-- Discover actual archive names, including DISK0.STK and Woodruff's ITK.
-- Cache only the directory. Large video/speech archives are read by member.
local _archives, _archive_cache = {}, {}
local function archives_for(game_path)
    if _archives[game_path] then return _archives[game_path] end
    local names = {}
    for _, name in ipairs(list_files(game_path)) do
        local upper = name:upper()
        if upper:match("%.STK$") or upper:match("%.ITK$") then names[#names + 1] = name end
    end
    table.sort(names, function(a, b) return a:upper() < b:upper() end)
    _archives[game_path] = names
    return names
end

local function read_stk(game_path, stk_file)
    local path = game_path .. "/" .. stk_file
    if _archive_cache[path] ~= nil then return _archive_cache[path] or nil end
    local fh = file_open(path)
    if not fh then return nil end
    local size = file_size(fh)
    local head = file_read(fh, 0, 2)
    local count = head and #head == 2 and u16le(head, 1) or 0
    local directory
    if count > 0 and count <= 5000 and 2 + count * 22 <= size then
        directory = file_read(fh, 0, 2 + count * 22)
    end
    file_close(fh)
    local entries = directory and parse_stk(directory)
    if entries then
        for _, e in pairs(entries) do
            if e.offset < 2 + count * 22 or e.offset + e.size > size then entries = nil; break end
        end
    end
    local archive = entries and { path = path, entries = entries } or nil
    _archive_cache[path] = archive or false
    return archive
end

local function sorted_entry_names(entries)
    local names = {}
    for name, _ in pairs(entries or {}) do names[#names + 1] = name end
    table.sort(names)
    return names
end

-- Read a loose file or the first matching member in one of the known STKs.
local function read_game_file(game_path, file_name)
    local loose = read_file_all(game_path .. "/" .. file_name)
        or read_file_all(game_path .. "/" .. file_name:lower())
    if loose then return loose end
    for _, stk_file in ipairs(archives_for(game_path)) do
        local raw = read_stk(game_path, stk_file)
        if raw then
            local data = stk_extract(raw, file_name)
            if data then return data end
        end
    end
    return nil
end

-- ============================================================================
-- Scene palettes
--
-- Scripts install the active palette with the palLoad function opcode (0xF3)
-- found in the TOT script section:
--   sub 52: 16 inline EGA colours (48 bytes, 6-bit DAC) - 16-colour modes
--   sub 53: s16 resource id of a 768-byte 256-colour palette (6-bit DAC)
-- The referenced palette is a resource of the scene's own TOT (id < 30000) or
-- of its EXT (id >= 30000). The TOT header is NOT palette data: offset 0x30
-- holds textsOffset and 0x34 holds resourcesOffset, so reading colours from a
-- fixed header offset yields version/offset bytes instead of real colours.
-- ============================================================================

local PALLOAD_OPCODE = 0xF3
local PALETTE_SIZE    = 768

-- Convert a 768-byte DAC block (6-bit 0-63, or 8-bit in some releases) into
-- a 256-colour palette table of 768 entries holding 0-255 values.
local function scale_palette(blob)
    local raw8 = false
    for i = 1, PALETTE_SIZE do
        if blob:byte(i) > 63 then raw8 = true; break end
    end
    local pal = {}
    for i = 0, 255 do
        for c = 1, 3 do
            local v = blob:byte(i * 3 + c) or 0
            if raw8 then
                pal[i * 3 + c] = v
            else
                pal[i * 3 + c] = math.min(math.floor(v * 255 / 63 + 0.5), 255)
            end
        end
    end
    return pal
end

-- Header + resource table of a TOT file. Returns nil when this is not a TOT.
local function parse_tot(tot)
    if not tot or #tot < 128 then return nil end
    if tot:byte(41) ~= 46 then return nil end   -- '.' of the "M.m" version

    local texts_offset = u32le(tot, 49)   -- 0x30
    local res_offset    = u32le(tot, 53)   -- 0x34
    if texts_offset == 0xFFFFFFFF then texts_offset = 0 end
    if res_offset    == 0xFFFFFFFF then res_offset    = 0 end

    -- Script section runs from the header to the texts/resources tables.
    local script_end = #tot
    if texts_offset > 0 then script_end = math.min(script_end, texts_offset) end
    if res_offset    > 0 then script_end = math.min(script_end, res_offset)    end

    local parsed = { script_end = script_end, resources = {}, data_offset = 0 }
    if res_offset <= 0 or res_offset + 3 > #tot then return parsed end

    local count = i16le(tot, res_offset + 1)
    if count <= 0 or count > 2000 then return parsed end
    local data_offset = res_offset + 3 + count * 10
    if data_offset > #tot then return parsed end

    parsed.data_offset = data_offset
    for i = 0, count - 1 do
        local base = res_offset + 4 + i * 10   -- 1-based
        if base + 9 > #tot then return nil end
        parsed.resources[i] = {
            offset = i32le(tot, base),
            size   = u16le(tot, base + 4),
            w      = i16le(tot, base + 6),
            h      = i16le(tot, base + 8),
            idx    = i,
        }
    end
    return parsed
end

-- Read a palette resource out of the TOT's own resource table.
local function tot_palette_blob(tot, parsed, id)
    local res = parsed.resources[id]
    if not res or res.size ~= PALETTE_SIZE or res.w ~= 0 or res.h ~= 0 then return nil end
    if res.offset < 0 then return nil end   -- negative = IM sprite, not a palette
    local start = parsed.data_offset + res.offset + 1
    if start < 1 or start + PALETTE_SIZE - 1 > #tot then return nil end
    return tot:sub(start, start + PALETTE_SIZE - 1)
end

-- Read a palette resource out of the scene's EXT resource table (id >= 30000).
local function ext_palette_blob(ext_data, commun_raw, id)
    if not ext_data then return nil end
    local items = parse_ext_table(ext_data)
    local item = items and items[id + 1]
    if not item or item.ex_type or item.packed then return nil end
    if item.size < PALETTE_SIZE then return nil end
    local start = item.data_off + 1
    if start + PALETTE_SIZE - 1 > #ext_data then return nil end
    return ext_data:sub(start, start + PALETTE_SIZE - 1)
end

-- Collect every palLoad reference in the script section, in file order:
-- resource ids used by sub 53 (VGA) and inline sub 52 blocks (EGA).
local function scan_palette_refs(tot, parsed)
    local vga_ids, ega_blocks = {}, {}
    for pos = 129, parsed.script_end - 1 do
        if tot:byte(pos) == PALLOAD_OPCODE then
            local sub = band(tot:byte(pos + 1) or 0, 0x7F)
            if sub == 53 and pos + 3 <= parsed.script_end then
                vga_ids[#vga_ids + 1] = i16le(tot, pos + 2)
            elseif sub == 61 and pos + 5 <= parsed.script_end
                    and tot:byte(pos + 2) <= tot:byte(pos + 3) then
                vga_ids[#vga_ids + 1] = i16le(tot, pos + 4)
            elseif sub == 52 and pos + 49 <= parsed.script_end then
                ega_blocks[#ega_blocks + 1] = tot:sub(pos + 2, pos + 49)
            end
        end
    end
    return vga_ids, ega_blocks
end

-- Turn a 48-byte inline EGA block into a full palette. Blocks that are not
-- 16 valid 6-bit colours are skipped (they are operand bytes, not palettes).
local function ega_block_palette(block)
    local nonzero = 0
    for i = 1, 48 do
        local v = block:byte(i)
        if v > 63 then return nil end
        if v > 0 then nonzero = nonzero + 1 end
    end
    if nonzero < 6 then return nil end
    local pal = build_ega_palette()
    for i = 0, 15 do
        for c = 1, 3 do
            local v = block:byte(i * 3 + c)
            pal[i * 3 + c] = math.min(math.floor(v * 255 / 63 + 0.5), 255)
        end
    end
    return pal
end

-- Palette a single TOT installs: VGA resources first (256-colour art needs
-- all 256 entries), then any standalone palette resource, then inline EGA.
local function tot_palette(tot, ext_data, commun_raw)
    local parsed = parse_tot(tot)
    if not parsed then return nil end

    local vga_ids, ega_blocks = scan_palette_refs(tot, parsed)
    if tot:byte(42) and tot:byte(42) >= string.byte("3") then
        local reversed = {}
        for i = #vga_ids, 1, -1 do reversed[#reversed + 1] = vga_ids[i] end
        vga_ids = reversed
    end
    for _, id in ipairs(vga_ids) do
        local blob
        if id >= 30000 then
            blob = ext_palette_blob(ext_data, commun_raw, id - 30000)
        elseif id >= 0 then
            blob = tot_palette_blob(tot, parsed, id)
        end
        if blob then return scale_palette(blob) end
    end

    local bare = {}
    for id, res in pairs(parsed.resources) do
        if res.size == PALETTE_SIZE and res.w == 0 and res.h == 0 and res.offset >= 0 then
            bare[#bare + 1] = id
        end
    end
    table.sort(bare)
    for _, id in ipairs(bare) do
        local blob = tot_palette_blob(tot, parsed, id)
        if blob then return scale_palette(blob) end
    end

    for _, block in ipairs(ega_blocks) do
        local pal = ega_block_palette(block)
        if pal then return pal end
    end
    return nil
end

-- Some scenes (GOB3's INTER* interfaces, GOB2's menu) install no palette at
-- all and inherit one at runtime. Fall back to the first palette any of the
-- game's TOT files provides so 256-colour art is never drawn with the
-- generic EGA ramp.
local function first_game_palette(game_path)
    local seen = {}
    for _, stk_file in ipairs(archives_for(game_path)) do
        local raw = read_stk(game_path, stk_file)
        local entries = raw and parse_stk(raw) or nil
        if entries then
            for _, name in ipairs(sorted_entry_names(entries)) do
                if name:match("%.TOT$") and not seen[name] then
                    seen[name] = true
                    local tot = stk_extract(raw, name)
                    local pal = tot and tot_palette(tot, nil, nil) or nil
                    if pal then return pal end
                end
            end
        end
    end
    return nil
end

local _palette_cache  = {}
local _game_pal_cache = {}

local function build_palette_table(game_path, scene_id, ext_data, commun_raw)
    if not game_path or not scene_id then return build_ega_palette() end

    local key = game_path .. "|" .. scene_id
    local hit = _palette_cache[key]
    if hit ~= nil then
        return hit or build_ega_palette()
    end

    local pal = nil
    local tot = read_game_file(game_path, scene_id .. ".TOT")
    if tot then pal = tot_palette(tot, ext_data, commun_raw) end
    if not pal then
        local intro = read_game_file(game_path, "INTRO.TOT")
        if intro then pal = tot_palette(intro, nil, nil) end
    end
    if not pal then
        if _game_pal_cache[game_path] == nil then
            _game_pal_cache[game_path] = first_game_palette(game_path) or false
        end
        pal = _game_pal_cache[game_path] or nil
    end

    _palette_cache[key] = pal or false
    return pal or build_ega_palette()
end

-- ============================================================================
-- Render pixel index table → image handle (via image_create_indexed)
-- ============================================================================

local function render_sprite(pixels, w, h, pal)
    if not pixels or w <= 0 or h <= 0 then return nil end
    if not pal then pal = build_ega_palette() end
    local img = image_create_indexed(w, h, pixels, pal)
    return img
end

-- Return the decoded bytes for any EXT resource, including non-image data.
local function load_entry_blob(entry, ext_raw, commun_raw)
    local source = entry.ex_type and commun_raw or ext_raw
    if not source then return nil end
    local off = entry.data_off + 1
    if entry.size <= 0 or off < 1 or off + entry.size - 1 > #source then return nil end
    local blob = source:sub(off, off + entry.size - 1)
    if entry.packed then
        if #blob < 5 then return nil end
        local unpacked_size = u32le(blob, 1)
        if unpacked_size <= 0 or unpacked_size > 64 * 1024 * 1024 then return nil end
        blob = lzss_decompress(blob, 5, unpacked_size)
    end
    return blob
end

-- Gob SND: byte 0 contains flags, bytes 0..3 become a BE sample count after
-- the flags byte is cleared, bytes 4..5 are the BE playback rate, then signed
-- 8-bit mono PCM. This mirrors SoundDesc::loadSND in the Gob engine.
local function parse_snd(data)
    if not data or #data <= 6 then return nil end
    local sample_count = data:byte(2) * 65536 + data:byte(3) * 256 + data:byte(4)
    local sample_rate = math.max(u16be(data, 5), 4700)
    if sample_count <= 0 or (sample_count > #data - 6 or sample_count < #data - 14) then return nil end
    if sample_rate < 4700 or sample_rate > 65535 then return nil end
    return {
        pcm = data:sub(7, 6 + sample_count),
        sample_count = sample_count,
        sample_rate = sample_rate,
    }
end

-- Validate the structure of a Coktel ADL event stream. A structural check is
-- needed because Gob2/3 can store music in anonymous EXT resource slots.
local function parse_adl_info(data)
    if not data or #data < 60 then return nil end
    local timbre_count = data:byte(2) + 1
    if timbre_count < 1 or timbre_count > 256 then return nil end
    local pos = 4 + timbre_count * 56
    if pos > #data then return nil end

    local first_delay = data:byte(pos)
    pos = pos + (band(first_delay, 0x80) ~= 0 and 2 or 1)
    local events, duration = 0, 0
    local modify_instrument = -1
    while pos <= #data and events < 100000 do
        local cmd = data:byte(pos); pos = pos + 1
        if cmd == 0xFF then
            if events < 8 or duration < 500 then return nil end
            return { events = events, duration_ms = duration, timbres = timbre_count }
        end
        if cmd == 0xFE then
            if pos > #data then return nil end
            modify_instrument = data:byte(pos); pos = pos + 1
        end
        if cmd >= 0xD0 then
            if modify_instrument < 0 or pos + 1 > #data then return nil end
            pos = pos + 2
        else
            local voice = band(cmd, 0x0F)
            local op = band(cmd, 0xF0)
            if voice > 10 then return nil end
            if op == 0x00 then pos = pos + 2
            elseif op == 0x90 or op == 0xA0 or op == 0xB0 or op == 0xC0 then pos = pos + 1
            elseif op ~= 0x80 then return nil end
            if pos > #data + 1 then return nil end
        end
        if pos > #data then return nil end
        local delay = data:byte(pos); pos = pos + 1
        if band(delay, 0x80) ~= 0 then
            if pos > #data then return nil end
            delay = lshift(band(delay, 3), 8) + data:byte(pos)
            pos = pos + 1
        end
        duration = duration + delay
        events = events + 1
        if duration > 10 * 60 * 1000 then return nil end
    end
    return nil
end

local function decode_wav_pcm(data)
    if not data or #data < 44 or data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then return nil end
    local pos, fmt, pcm = 13, nil, nil
    while pos + 7 <= #data do
        local tag = data:sub(pos, pos + 3)
        local size = u32le(data, pos + 4)
        local body = pos + 8
        if size < 0 or body + size - 1 > #data then return nil end
        if tag == "fmt " and size >= 16 then
            fmt = {
                format = u16le(data, body), channels = u16le(data, body + 2),
                rate = u32le(data, body + 4), bits = u16le(data, body + 14),
            }
        elseif tag == "data" then
            pcm = data:sub(body, body + size - 1)
        end
        pos = body + size + (size % 2)
    end
    if not fmt or not pcm or fmt.format ~= 1 then return nil end
    if (fmt.bits ~= 8 and fmt.bits ~= 16) or (fmt.channels ~= 1 and fmt.channels ~= 2) then return nil end
    return { pcm = pcm, sample_rate = fmt.rate, bits = fmt.bits,
        channels = fmt.channels, signed = fmt.bits == 16 }
end

local function make_sound_resource(data, label)
    local snd = parse_snd(data)
    if snd then
        local handle = sound_create_pcm(snd.sample_rate, 8, 1, true, snd.pcm)
        if not handle then return nil end
        return {
            type = "sound", sound = handle,
            description = string.format("%s - Gob SND, %d samples @ %d Hz",
                label, snd.sample_count, snd.sample_rate),
        }
    end
    local wav = decode_wav_pcm(data)
    if wav then
        local handle = sound_create_pcm(wav.sample_rate, wav.bits, wav.channels, wav.signed, wav.pcm)
        if not handle then return nil end
        return {
            type = "sound", sound = handle,
            description = string.format("%s - PCM WAV, %d Hz, %d-bit, %d channel(s)",
                label, wav.sample_rate, wav.bits, wav.channels),
        }
    end
    return nil
end

local function make_adl_resource(data, label)
    local info = parse_adl_info(data)
    if not info then return nil end
    local handle = sound_create_gob_adl(data)
    if not handle then return nil end
    return {
        type = "sound", sound = handle,
        description = string.format("%s - Coktel ADL music, %d timbres, %d events, %.1f s",
            label, info.timbres, info.events, info.duration_ms / 1000),
    }
end

-- ============================================================================
-- Resource IDs below 30000 address the TOT, the rest address its EXT.
local _scenes, _nodes, _defaults = {}, {}, {}
local _shared_files = {}
local function shared_file(game_path, name)
    local key = game_path .. "/" .. name
    if _shared_files[key] == nil then _shared_files[key] = read_game_file(game_path, name) or false end
    return _shared_files[key] or nil
end
local function get_scene(game_path, name)
    local key = game_path .. "|" .. name
    if _scenes[key] then return _scenes[key] end
    local tot = read_game_file(game_path, name .. ".TOT")
    local ext = read_game_file(game_path, name .. ".EXT")
    local parsed = parse_tot(tot)
    local scene = { name = name, tot = tot, parsed = parsed, ext = ext,
        items = parse_ext_table(ext) or {}, wide_count = tot and tot:sub(40, 42) >= "1.2" }
    local ex_num = tot and tot:byte(61) or 1
    if ex_num == 0 then ex_num = 1 end
    scene.ex = shared_file(game_path, "COMMUN.EX" .. ex_num)
    if tot and (tot:byte(60) ~= 0 or tot:byte(62) == 0) then
        local num = tot:byte(60)
        scene.im = shared_file(game_path, "COMMUN.IM" .. (num == 0 and 1 or num))
    end
    _scenes[key] = scene
    return scene
end

local function scene_item(scene, id)
    if id >= 30000 then return scene.items[id - 30000 + 1] end
    return scene.parsed and scene.parsed.resources[id]
end

local function scene_blob(scene, id)
    local item = scene_item(scene, id)
    if not item or item.size <= 0 then return nil end
    if id >= 30000 then return load_entry_blob(item, scene.ext, scene.ex) end
    local source, offset = scene.tot, scene.parsed.data_offset + item.offset
    if item.offset < 0 then
        source = scene.im
        local index = (-item.offset - 1) * 4 + 1
        if not source or index + 3 > #source then return nil end
        offset = u32le(source, index)
    end
    if offset < 0 or offset + item.size > #source then return nil end
    return source:sub(offset + 1, offset + item.size)
end

local function is_image(item)
    return item and item.size > 0 and item.w > 0 and item.h > 0
        and item.w <= 4096 and item.h <= 4096 and item.w * item.h <= 4 * 1024 * 1024
end

local function scene_pixels(scene, id)
    local item = scene_item(scene, id)
    if not is_image(item) then return nil end
    local blob = scene_blob(scene, id)
    return blob and decode_sprite(blob, item.w, item.h, false, scene.wide_count) or nil
end

local function palette_node(scene, id)
    return "pal_" .. scene.name .. "_" .. id
end

-- Fascination puts a sprite's palette immediately after its data. Shared
-- palettes precede later sprites. Expose all alternatives for scene changes.
local function sprite_palette_id(scene, id)
    local next_id, prev_id
    for pal_id, res in pairs(scene.parsed and scene.parsed.resources or {}) do
        if res.size == 768 and res.w == 0 and res.h == 0 then
            if pal_id > id and (not next_id or pal_id < next_id) then next_id = pal_id end
            if pal_id < id and (not prev_id or pal_id > prev_id) then prev_id = pal_id end
        end
    end
    if id < 30000 and not scene.wide_count then return next_id or prev_id end
    if scene.parsed then
        local refs = scan_palette_refs(scene.tot, scene.parsed)
        for i = #refs, 1, -1 do
            local item = scene_item(scene, refs[i])
            if item and item.size == 768 and item.w == 0 and item.h == 0 then return refs[i] end
        end
    end
    return prev_id or next_id
end

local function scene_palette(game_path, scene, id, override)
    local node = override and _nodes[override]
    local pal_id = node and node.palette or sprite_palette_id(scene, id)
    local pal_scene = node and node.scene and get_scene(game_path, node.scene) or scene
    local blob = pal_id and scene_blob(pal_scene, pal_id)
    if blob and #blob == 768 then return scale_palette(blob) end
    return build_palette_table(game_path, scene.name, scene.ext, scene.ex)
end

-- Constant o1_loadSpriteToPos calls describe the room's strips and their
-- positions. Decode only literal expressions; dynamic actor draws are omitted.
local function constant_expr(data, pos, limit)
    local token, value = data:byte(pos), nil
    if token == 21 and pos + 2 <= limit then
        value = data:byte(pos + 1); if value >= 128 then value = value - 256 end
        pos = pos + 2
    elseif token == 20 and pos + 3 <= limit then
        value = i16le(data, pos + 1); pos = pos + 3
    else return nil end
    if data:byte(pos) ~= 99 then return nil end
    return value, pos + 1
end

local function background_placements(scene)
    local out = {}
    if not scene.parsed then return out end
    for pos = 129, scene.parsed.script_end - 8 do
        if scene.tot:byte(pos) == 0xA0 then
            local id = u16le(scene.tot, pos + 1)
            local item = scene_item(scene, id)
            if is_image(item) and item.w >= 240 and item.h >= 80 then
                local x, p = constant_expr(scene.tot, pos + 3, scene.parsed.script_end)
                if x then
                    local y, q = constant_expr(scene.tot, p, scene.parsed.script_end)
                    if y and q + 1 <= scene.parsed.script_end and scene.tot:byte(q) == 0
                            and scene.tot:byte(q + 1) == 0
                            and x >= 0 and y >= 0 and x + item.w <= 2048 and y + item.h <= 1024 then
                        out[#out + 1] = { id = id, x = x, y = y }
                    end
                end
            end
        end
    end
    return out
end

local function make_background(game_path, scene, palette_id)
    local placements = background_placements(scene)
    if #placements > 0 then
        local w, h, decoded = 0, 0, {}
        for _, place in ipairs(placements) do
            local item = scene_item(scene, place.id)
            local pixels = scene_pixels(scene, place.id)
            if pixels then
                decoded[#decoded + 1] = { place = place, item = item, pixels = pixels }
                w = math.max(w, place.x + item.w); h = math.max(h, place.y + item.h)
            end
        end
        if #decoded > 0 then
            local pixels = {}
            for i = 1, w * h do pixels[i] = 0 end
            for _, d in ipairs(decoded) do
                for y = 0, d.item.h - 1 do
                    for x = 0, d.item.w - 1 do
                        pixels[(y + d.place.y) * w + x + d.place.x + 1] = d.pixels[y * d.item.w + x + 1] or 0
                    end
                end
            end
            return render_sprite(pixels, w, h, scene_palette(game_path, scene, decoded[#decoded].place.id, palette_id)), w, h
        end
    end
    -- Scenes without literal placement calls still expose every sprite below.
    local candidates = {}
    for id, item in pairs(scene.parsed and scene.parsed.resources or {}) do
        if is_image(item) then candidates[#candidates + 1] = { id = id, item = item } end
    end
    for i, item in ipairs(scene.items) do
        if is_image(item) then candidates[#candidates + 1] = { id = 29999 + i, item = item } end
    end
    table.sort(candidates, function(a, b)
        local aa, bb = a.item.w * a.item.h, b.item.w * b.item.h
        return aa > bb or (aa == bb and a.id < b.id)
    end)
    for _, c in ipairs(candidates) do
        local px = scene_pixels(scene, c.id)
        if px then
            return render_sprite(px, c.item.w, c.item.h, scene_palette(game_path, scene, c.id, palette_id)), c.item.w, c.item.h
        end
    end
end

function engine.detect(game_path)
    for _, file in ipairs(archives_for(game_path)) do
        local archive = read_stk(game_path, file)
        for name, _ in pairs(archive and archive.entries or {}) do
            if name:match("%.TOT$") then return true end
        end
    end
    return false
end

-- Some VMDs declare an audio format but contain no audio parts.
local function video_has_audio(game_path, name, archive, header)
    local count, parts = u16le(header, 7), u16le(header, 19)
    local offset = u32le(header, 813) + count * 6
    local size = count * parts * 16
    local entry = archive and archive.entries[name]
    local fh = file_open(archive and archive.path or (game_path .. "/" .. name))
    if not fh then return false end
    local available = entry and entry.size or file_size(fh)
    local data
    if offset + size <= available then data = file_read(fh, (entry and entry.offset or 0) + offset, size) end
    file_close(fh)
    if not data or #data ~= size then return false end
    for pos = 1, size, 16 do
        if data:byte(pos) == 1 and u32le(data, pos + 2) > 0
                and (data:byte(pos + 6) == 1 or data:byte(pos + 6) == 2) then return true end
    end
    return false
end

function engine.get_resources(game_path)
    local scenes, sounds, music, videos, categories = {}, {}, {}, {}, {}
    local seen = {}
    _nodes, _defaults = {}, {}
    local function named(name, archive)
        if seen[name] then return end
        seen[name] = true
        local id = "file_" .. name
        if name:match("%.SND$") or name:match("%.WAV$") then
            local is_music = name:match("^MUS") ~= nil
            local list = is_music and music or sounds
            list[#list + 1] = { id = id, name = name, type = "sound" }
            _nodes[id] = { file = name, archive = archive }
        elseif name:match("%.MDY$") then
            music[#music + 1] = { id = id, name = name, type = "sound" }
            _nodes[id] = { file = name, archive = archive, mdy = true }
        elseif name:match("%.ADL$") then
            music[#music + 1] = { id = id, name = name, type = "sound" }
            _nodes[id] = { file = name, archive = archive, adl = true }
        elseif name:match("%.VMD$") or name:match("%.IMD$") then
            -- Index dimensions/frame counts without reading a whole movie.
            local entry = archive and archive.entries[name]
            local fh = file_open(archive and archive.path or (game_path .. "/" .. name))
            local header
            if fh then header = file_read(fh, entry and entry.offset or 0, 816); file_close(fh) end
            if not header or #header < 786 then return end
            local vmd = u16le(header, 1) == 814
            local pre = name == "TIRA.IMD" or name == "TIRB.IMD"
            if not vmd and not pre and (u16le(header, 1) ~= 0 or header:byte(3) < 2) then return end
            local count = u16le(header, vmd and 7 or 5)
            local w = u16le(header, vmd and 13 or 11)
            local h = u16le(header, vmd and 15 or 13)
            local pre_scene, pre_palette
            if pre then
                w, h = 128, 80
                -- These early movies have no dimensions and inherit the palette
                -- installed immediately before their Goblin function call.
                pre_scene = name == "TIRB.IMD" and "INTRO1" or "INTRO2"
                local scene = get_scene(game_path, pre_scene)
                local cmd = name == "TIRB.IMD" and 1 or 2
                local last_pal
                for pos = 129, scene.parsed and scene.parsed.script_end - 5 or 128 do
                    local d = scene.tot
                    if d:byte(pos) == 0xF3 and band(d:byte(pos + 1), 127) == 53 then last_pal = u16le(d, pos + 2) end
                    if d:byte(pos) == 0xE5 and u16le(d, pos + 1) == cmd then pre_palette = last_pal; break end
                end
                local bytes = archive and stk_extract(archive, name) or read_game_file(game_path, name)
                local pos, actual = 3, 0
                while bytes and pos + 1 <= #bytes do
                    local size = u16le(bytes, pos)
                    local next_pos = pos + (size > 0 and size + 4 or 2)
                    if next_pos > #bytes + 1 then break end
                    actual = actual + 1; pos = next_pos
                end
                count = math.min(u16le(header, 1), actual)
            end
            if w == 0 or h == 0 or count == 0 then return end
            if vmd and #header >= 816 and u16le(header, 805) > 0
                    and video_has_audio(game_path, name, archive, header) then
                local aid = "audio_" .. name
                sounds[#sounds + 1] = { id = aid, name = name .. " soundtrack", type = "sound" }
                _nodes[aid] = { file = name, archive = archive, video_audio = true }
            end
            local per_clip = math.max(1, math.min(128, math.floor(48 * 1024 * 1024 / (w * h * 4))))
            local clips = {}
            for first = 0, count - 1, per_clip do
                local cid = first == 0 and id or (id .. "_frame_" .. first)
                local n = math.min(per_clip, count - first)
                clips[#clips + 1] = { id = cid,
                    name = count <= per_clip and name or string.format("Frames %d–%d", first + 1, first + n), type = "animation" }
                _nodes[cid] = { file = name, archive = archive, video = true, first = first, count = n,
                    pre = pre, pre_scene = pre_scene, pre_palette = pre_palette }
                if pre_palette then _defaults[cid] = "pal_" .. pre_scene .. "_" .. pre_palette end
            end
            videos[#videos + 1] = #clips == 1 and clips[1] or
                { id = "movie_" .. name, name = name, type = "category", children = clips }
        elseif name:match("%.TOT$") or name:match("%.EXT$") then
            scenes[name:sub(1, -5)] = true
        end
    end
    for _, filename in ipairs(archives_for(game_path)) do
        local archive = read_stk(game_path, filename)
        for _, name in ipairs(sorted_entry_names(archive and archive.entries)) do named(name, archive) end
    end
    for _, name in ipairs(list_files(game_path)) do named(name:upper(), nil) end
    for _, name in ipairs(sorted_entry_names(scenes)) do
        local scene = get_scene(game_path, name)
        local images, palettes = {}, {}
        local function resource(id, item)
            local rid = "img_" .. name .. "_" .. id
            if is_image(item) and scene_blob(scene, id) then
                images[#images + 1] = { id = rid, name = string.format("Sprite %s %d (%dx%d)", id < 30000 and "TOT" or "EXT", id, item.w, item.h), type = "image" }
                _nodes[rid] = { scene = name, resource = id }
                local pal = sprite_palette_id(scene, id)
                if pal then _defaults[rid] = palette_node(scene, pal) end
            elseif item.w == 0 and item.h == 0 and item.size == 768 and scene_blob(scene, id) then
                local pid = palette_node(scene, id)
                palettes[#palettes + 1] = { id = pid, name = "Palette " .. id, type = "palette" }
                _nodes[pid] = { scene = name, palette = id }
            elseif item.h == 0 then
                local blob = scene_blob(scene, id)
                if blob and (parse_snd(blob) or decode_wav_pcm(blob) or parse_adl_info(blob)) then
                    local adl = parse_adl_info(blob) ~= nil
                    local list = adl and music or sounds
                    local aid = (adl and "music_" or "snd_") .. name .. "_" .. id
                    list[#list + 1] = { id = aid, name = name .. " resource " .. id, type = "sound" }
                    _nodes[aid] = { scene = name, resource = id, audio = true, adl = adl }
                end
            end
        end
        local ids = {}
        for id in pairs(scene.parsed and scene.parsed.resources or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do resource(id, scene.parsed.resources[id]) end
        for i, item in ipairs(scene.items) do resource(29999 + i, item) end
        if #images > 0 then
            local children = { { id = "bg_" .. name, name = name .. " background", type = "image" } }
            _nodes["bg_" .. name] = { scene = name, background = true }
            for _, node in ipairs(images) do children[#children + 1] = node end
            if #palettes > 0 then children[#children + 1] = { id = "palettes_" .. name, name = "Palettes", type = "category", children = palettes } end
            categories[#categories + 1] = { id = "scene_" .. name, name = name, type = "category", children = children }
        end
    end
    for _, group in ipairs({ { sounds, "sounds", "Sound Effects" }, { music, "music", "Music" }, { videos, "videos", "Animations and Movies" } }) do
        local list, id, title = group[1], group[2], group[3]
        if #list > 0 then
            table.sort(list, function(a, b) return a.name < b.name end)
            categories[#categories + 1] = { id = "cat_" .. id, name = string.format("%s (%d)", title, #list), type = "category", children = list }
        end
    end
    return categories
end

function engine.default_palette(game_path, resource_id)
    return _defaults[resource_id]
end

function engine.load_resource(game_path, resource_id, palette_id)
    resource_release_decoded()
    local node = _nodes[resource_id]
    if not node then return nil end
    if node.file then
        local data = node.archive and stk_extract(node.archive, node.file) or read_game_file(game_path, node.file)
        if not data then return nil end
        if node.video_audio then
            local sound = sound_create_coktel_video(data)
            if not sound then return nil end
            return { type = "sound", sound = sound, description = node.file .. " - VMD soundtrack" }
        end
        if node.video then
            local anim
            if node.pre then
                local scene = get_scene(game_path, node.pre_scene)
                local pal = scene_palette(game_path, scene, 0, palette_id or
                    (node.pre_palette and ("pal_" .. node.pre_scene .. "_" .. node.pre_palette)))
                anim = animation_create_coktel(data, node.first, node.count, 128, 80, pal)
            else
                anim = animation_create_coktel(data, node.first, node.count)
            end
            if not anim then return nil end
            return { type = "animation", animation = anim, description = string.format("%s - Coktel video, frames %d–%d", node.file, node.first + 1, node.first + node.count) }
        end
        if node.mdy then
            local tbr = read_game_file(game_path, node.file:gsub("%.MDY$", ".TBR"))
            local sound = tbr and sound_create_gob_mdy(data, tbr)
            if not sound then return nil end
            return { type = "sound", sound = sound, description = node.file .. " - MDY/TBR AdLib music (FM preview)" }
        end
        if node.adl then return make_adl_resource(data, node.file) end
        return make_sound_resource(data, node.file)
    end
    local scene = get_scene(game_path, node.scene)
    if node.audio then
        local blob = scene_blob(scene, node.resource)
        if node.adl then return blob and make_adl_resource(blob, resource_id) end
        return blob and make_sound_resource(blob, resource_id)
    end
    if node.palette then
        local blob = scene_blob(scene, node.palette)
        if not blob or #blob ~= 768 then return nil end
        local pal, px = scale_palette(blob), {}
        for y = 0, 127 do for x = 0, 127 do px[y * 128 + x + 1] = math.floor(y / 8) * 16 + math.floor(x / 8) end end
        return { type = "image", image = render_sprite(px, 128, 128, pal), description = resource_id }
    end
    if node.background then
        local img, w, h = make_background(game_path, scene, palette_id)
        if not img then return nil end
        return { type = "image", image = img, description = string.format("%s (%dx%d)", scene.name, w, h) }
    end
    local item = scene_item(scene, node.resource)
    local pixels = scene_pixels(scene, node.resource)
    if not pixels then return nil end
    local pal = scene_palette(game_path, scene, node.resource, palette_id)
    return { type = "image", image = render_sprite(pixels, item.w, item.h, pal), description = string.format("%s resource %d (%dx%d)", scene.name, node.resource, item.w, item.h) }
end

engine._debug = { parse_stk = parse_stk, lzss_decompress = lzss_decompress,
    parse_ext_table = parse_ext_table, parse_tot = parse_tot, decode_sprite = decode_sprite,
    scan_palette_refs = scan_palette_refs, parse_snd = parse_snd }
return engine

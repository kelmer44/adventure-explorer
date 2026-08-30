-- ============================================================================
-- Adventure Explorer - Engine Script: Gobliiins Series (REWRITE v2)
-- ============================================================================
-- Coktel Vision / Sierra. Resources are in .EXT files inside .STK archives.
-- Sprite data may be inline (EXT-type) or in COMMUN.EX1 (EX-type).
-- Gob1/2/3: 320x200, EGA indexed colour.
-- ============================================================================

local engine = {}
engine.name        = "Gobliiins Series"
engine.id          = "gob"
engine.description = "Gobliiins / Gobliins 2 / Goblins Quest 3 (Coktel Vision)"
engine.version     = "4.0"

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
    if not raw or #raw < 2 then return nil end
    local file_count = u16le(raw, 1)
    if file_count == 0 or file_count > 5000 then return nil end
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
    return string.char(table.unpack(out))
end

-- Extract a named file from pre-loaded STK bytes. Compression type 1 is the
-- same Coktel LZSS stream used by packed EXT resources: u32le output size,
-- followed by a standard or extended LZSS chunk.
local function stk_extract(stk_raw, file_name)
    local entries = parse_stk(stk_raw)
    if not entries then return nil end
    local info = entries[file_name:upper()]
    if not info then return nil end
    local data = stk_raw:sub(info.offset + 1, info.offset + info.size)
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
local function decode_sprite(data, w, h, is_packed)
    local sd = data
    if is_packed then
        if #data < 4 then return nil end
        local unpacked = u32le(data, 1)
        sd = lzss_decompress(data, 5, unpacked)
        if not sd or #sd < 3 then return nil end
    end
    if #sd < 3 then return nil end
    local b0, b1, b2 = sd:byte(1), sd:byte(2), sd:byte(3)
    if b0 == 0x01 and b1 == 0x02 then
        if b2 == 0x02 then
            -- raw pixels at position 4 (1-based), one byte per pixel
            local pixels = {}
            local needed = w * h
            for i = 1, needed do
                pixels[i] = sd:byte(3 + i) or 0
            end
            return pixels
        else
            -- inner LZSS: u16le pixelCount at bytes 4-5, compressed at byte 8
            if #sd < 8 then return nil end
            local pcnt  = u16le(sd, 4)
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
    if count <= 0 or count > 2000 then return nil end
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

local STK_FILES = {
    "DISK1.STK","DISK2.STK","DISK3.STK","DISK4.STK","DISK5.STK",
    "INTRO.STK","MUSIC.STK","EXT.STK","TOT.STK",
    "GOBLINS2.STK","GOB2.STK","GOB2CD.STK","GOBLIN2.STK",
    "COMMUN03.STK","GOB3.STK","GOB3CD.STK","GOBLIN3.STK",
    "PLAYTOON.STK","ADIBOU.STK",
}

local function read_stk(game_path, stk_file)
    return read_file_all(game_path .. "/" .. stk_file)
        or read_file_all(game_path .. "/" .. stk_file:lower())
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
    for _, stk_file in ipairs(STK_FILES) do
        local raw = read_stk(game_path, stk_file)
        if raw then
            local data = stk_extract(raw, file_name)
            if data then return data end
        end
    end
    return nil
end

-- Try to load VGA palette from a .TOT file within an STK archive
-- TOT files have palette data at known offsets
local function try_load_tot_palette(game_path, scene_id)
    -- Look for a matching .TOT file in STK archives
    local tot_names = { scene_id .. ".TOT", "INTRO.TOT" }
    for _, stk_file in ipairs(STK_FILES) do
        local raw = read_file_all(game_path .. "/" .. stk_file)
              or   read_file_all(game_path .. "/" .. stk_file:lower())
        if raw then
            for _, tot_name in ipairs(tot_names) do
                local tot_data = stk_extract(raw, tot_name)
                if tot_data and #tot_data > 0x34 then
                    -- TOT header: palette offset hint at byte 0x30 (u16le)
                    -- Try to find 768-byte palette block (values 0-63)
                    -- Common positions: near the start, after script code

                    -- Method 1: Check if data at offset 0x34 looks like a VGA palette
                    -- (all bytes should be <= 63 for 6-bit VGA)
                    local try_offsets = { 0x34, 0x38, 0x50, 0x100 }
                    for _, off in ipairs(try_offsets) do
                        local base = off + 1  -- 1-based
                        if base + 767 <= #tot_data then
                            local is_vga = true
                            local nonzero = 0
                            for test = 0, 47 do  -- check first 16 colors
                                local v = tot_data:byte(base + test)
                                if v > 63 then is_vga = false; break end
                                if v > 0 then nonzero = nonzero + 1 end
                            end
                            if is_vga and nonzero >= 6 then
                                -- Found a valid VGA palette
                                local pal = {}
                                for i = 0, 255 do
                                    local r = (tot_data:byte(base + i * 3) or 0) % 64
                                    local g = (tot_data:byte(base + i * 3 + 1) or 0) % 64
                                    local b = (tot_data:byte(base + i * 3 + 2) or 0) % 64
                                    pal[i * 3 + 1] = math.min(math.floor(r * 255 / 63 + 0.5), 255)
                                    pal[i * 3 + 2] = math.min(math.floor(g * 255 / 63 + 0.5), 255)
                                    pal[i * 3 + 3] = math.min(math.floor(b * 255 / 63 + 0.5), 255)
                                end
                                return pal
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function build_palette_table(game_path, scene_id)
    -- Try to load VGA palette from TOT files first
    if game_path and scene_id then
        local vga_pal = try_load_tot_palette(game_path, scene_id)
        if vga_pal then return vga_pal end
    end
    return build_ega_palette()
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

-- Find and return the STK raw bytes that contains ext_name_upper
local function find_stk_with(game_path, ext_name_upper)
    for _, stk in ipairs(STK_FILES) do
        local raw = read_file_all(game_path .. "/" .. stk)
              or   read_file_all(game_path .. "/" .. stk:lower())
        if raw then
            local entries = parse_stk(raw)
            if entries and entries[ext_name_upper] then
                return raw, stk
            end
        end
    end
    return nil, nil
end

-- ============================================================================
-- Load COMMUN.EX1 (with simple cache)
-- ============================================================================

local _commun_cache = {}

local function commun_name_for_stk(stk_file)
    local disk = stk_file:upper():match("^DISK(%d+)%.STK$")
    if disk == "2" or disk == "3" then return "COMMUN.EX" .. disk end
    return "COMMUN.EX1"
end

local function load_commun(game_path, stk_file)
    local name = commun_name_for_stk(stk_file or "INTRO.STK")
    local key = game_path .. "/" .. name
    if _commun_cache[key] ~= nil then
        return _commun_cache[key] ~= false and _commun_cache[key] or nil
    end
    local raw = read_game_file(game_path, name)
    _commun_cache[key] = raw or false
    return raw
end

-- ============================================================================
-- Load pixels from a single EXT entry
-- ============================================================================

local function load_entry_pixels(entry, ext_raw, commun_raw)
    local blob = nil
    local off = entry.data_off + 1   -- convert to 1-based
    local sz  = entry.size
    if entry.ex_type then
        if not commun_raw then return nil end
        if off + sz - 1 > #commun_raw then return nil end
        blob = commun_raw:sub(off, off + sz - 1)
    else
        if off + sz - 1 > #ext_raw then return nil end
        blob = ext_raw:sub(off, off + sz - 1)
    end
    return decode_sprite(blob, entry.w, entry.h, entry.packed)
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
    if sample_count <= 0 or sample_count ~= #data - 6 then return nil end
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
-- engine.detect
-- ============================================================================

function engine.detect(game_path)
    for _, stk in ipairs(STK_FILES) do
        local raw = read_file_all(game_path .. "/" .. stk)
              or   read_file_all(game_path .. "/" .. stk:lower())
        if raw then
            local entries = parse_stk(raw)
            if entries then
                for name, _ in pairs(entries) do
                    -- Gob1: AVTxx.EXT; Gob2/3: *.TOT
                    if (name:match("^AVT") and name:match("%.EXT$"))
                        or name:match("%.TOT$") then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- ============================================================================
-- engine.get_resources  (called by ScriptManager.detectGame)
-- ============================================================================

function engine.get_resources(game_path)
    local scenes = {}
    local sounds = {}
    local music = {}
    local seen   = {}
    local seen_named_audio = {}

    for stk_index, stk_file in ipairs(STK_FILES) do
        local raw = read_stk(game_path, stk_file)
        if raw then
            local entries = parse_stk(raw)
            if entries then
                for _, name_upper in ipairs(sorted_entry_names(entries)) do
                    if name_upper:match("%.EXT$") and not seen[name_upper] then
                        seen[name_upper] = true
                        local scene_id = name_upper:sub(1, #name_upper - 4)  -- strip ".EXT"
                        scenes[#scenes + 1] = {
                            scene_id = scene_id,
                            ext_name = name_upper,
                            stk_file = stk_file,
                        }
                    end
                    if (name_upper:match("%.SND$") or name_upper:match("%.WAV$"))
                            and not seen_named_audio[name_upper] then
                        seen_named_audio[name_upper] = true
                        sounds[#sounds + 1] = {
                            id = string.format("snd_stk_%d_%s", stk_index, name_upper),
                            name = name_upper,
                            type = "sound",
                        }
                    elseif name_upper:match("%.ADL$") and not seen_named_audio[name_upper] then
                        seen_named_audio[name_upper] = true
                        music[#music + 1] = {
                            id = string.format("music_stk_%d_%s", stk_index, name_upper),
                            name = name_upper,
                            type = "sound",
                        }
                    end
                end
            end
        end
    end

    table.sort(scenes, function(a, b) return a.scene_id < b.scene_id end)

    -- Gob2 and Gob3 load many samples by numeric resource ID. Find those
    -- anonymous SND/ADL blobs in each EXT/COMMUN resource table.
    for stk_index, stk_file in ipairs(STK_FILES) do
        local stk_raw = read_stk(game_path, stk_file)
        local entries = stk_raw and parse_stk(stk_raw) or nil
        if entries then
            local commun_raw = nil
            for _, ext_name in ipairs(sorted_entry_names(entries)) do
                if ext_name:match("%.EXT$") then
                    local ext_data = stk_extract(stk_raw, ext_name)
                    local items = ext_data and parse_ext_table(ext_data) or nil
                    if items then
                        local scene_id = ext_name:sub(1, #ext_name - 4)
                        for item_index, item in ipairs(items) do
                            if item.ex_type and not commun_raw then
                                commun_raw = load_commun(game_path, stk_file)
                            end
                            local blob = load_entry_blob(item, ext_data, commun_raw)
                            if blob then
                                if parse_snd(blob) or decode_wav_pcm(blob) then
                                    sounds[#sounds + 1] = {
                                        id = string.format("snd_ext_%d_%s_%d", stk_index, scene_id, item_index),
                                        name = string.format("%s resource %d", scene_id, item.idx),
                                        type = "sound",
                                    }
                                elseif parse_adl_info(blob) then
                                    music[#music + 1] = {
                                        id = string.format("music_ext_%d_%s_%d", stk_index, scene_id, item_index),
                                        name = string.format("%s resource %d", scene_id, item.idx),
                                        type = "sound",
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(sounds, function(a, b) return a.name < b.name end)
    table.sort(music, function(a, b) return a.name < b.name end)

    local categories = {}
    for _, scene in ipairs(scenes) do
        categories[#categories + 1] = {
            id       = "scene_" .. scene.scene_id,
            name     = scene.scene_id,
            type     = "category",
            children = {
                {
                    id   = "bg_" .. scene.scene_id,
                    name = scene.scene_id,
                    type = "image",
                }
            }
        }
    end

    if #sounds > 0 then
        categories[#categories + 1] = {
            id = "cat_sounds", name = string.format("Sound Effects (%d)", #sounds),
            type = "category", children = sounds,
        }
    end
    if #music > 0 then
        categories[#categories + 1] = {
            id = "cat_music", name = string.format("Music (%d)", #music),
            type = "category", children = music,
        }
    end

    return categories
end

-- ============================================================================
-- engine.load_resource  (called by ScriptManager.loadResource)
-- ============================================================================

function engine.load_resource(game_path, resource_id, palette_id)
    -- Named SND/WAV members from an STK.
    local stk_index, audio_name = resource_id:match("^snd_stk_(%d+)_(.+)$")
    if stk_index then
        local stk_file = STK_FILES[tonumber(stk_index)]
        local stk_raw = stk_file and read_stk(game_path, stk_file) or nil
        local data = stk_raw and stk_extract(stk_raw, audio_name) or nil
        return data and make_sound_resource(data, audio_name) or nil
    end

    -- Named Coktel ADL music members from an STK.
    stk_index, audio_name = resource_id:match("^music_stk_(%d+)_(.+)$")
    if stk_index then
        local stk_file = STK_FILES[tonumber(stk_index)]
        local stk_raw = stk_file and read_stk(game_path, stk_file) or nil
        local data = stk_raw and stk_extract(stk_raw, audio_name) or nil
        return data and make_adl_resource(data, audio_name) or nil
    end

    -- Anonymous EXT/COMMUN sound and music resources.
    local kind, ext_stk_index, scene_id, item_index =
        resource_id:match("^(snd)_ext_(%d+)_(.+)_(%d+)$")
    if not kind then
        kind, ext_stk_index, scene_id, item_index =
            resource_id:match("^(music)_ext_(%d+)_(.+)_(%d+)$")
    end
    if kind then
        local stk_file = STK_FILES[tonumber(ext_stk_index)]
        local stk_raw = stk_file and read_stk(game_path, stk_file) or nil
        local ext_data = stk_raw and stk_extract(stk_raw, scene_id .. ".EXT") or nil
        local items = ext_data and parse_ext_table(ext_data) or nil
        local item = items and items[tonumber(item_index)] or nil
        if not item then return nil end
        local commun_raw = item.ex_type and load_commun(game_path, stk_file) or nil
        local data = load_entry_blob(item, ext_data, commun_raw)
        if kind == "snd" then return data and make_sound_resource(data, scene_id .. " resource " .. item.idx) or nil end
        return data and make_adl_resource(data, scene_id .. " resource " .. item.idx) or nil
    end

    -- resource_id = "bg_SCENENAME"  e.g. "bg_AVT00"
    if not resource_id:match("^bg_") then return nil end
    local scene_id = resource_id:sub(4)    -- strip "bg_"
    local ext_name = scene_id .. ".EXT"

    -- Find the STK containing this EXT
    local stk_raw, stk_file = find_stk_with(game_path, ext_name)
    if not stk_raw then return nil end

    -- Extract EXT bytes
    local ext_data = stk_extract(stk_raw, ext_name)
    if not ext_data then return nil end

    -- Parse EXT table
    local items = parse_ext_table(ext_data)
    if not items or #items == 0 then return nil end

    -- Load COMMUN.EX1
    local commun_raw = load_commun(game_path, stk_file)

    -- Pick best background: prefer largest 320×200, fallback to biggest area
    local best
    for _, item in ipairs(items) do
        if item.w == 320 and item.h == 200 then
            if not best or item.size > best.size then best = item end
        end
    end
    if not best then
        for _, item in ipairs(items) do
            if item.w > 60 and item.h > 60 then
                if not best or (item.w * item.h > best.w * best.h) then best = item end
            end
        end
    end
    if not best then return nil end

    -- Decode sprite pixels
    local pixels = load_entry_pixels(best, ext_data, commun_raw)
    if not pixels then return nil end

    -- Build palette (try VGA from TOT file, fall back to EGA)
    local pal = build_palette_table(game_path, scene_id)

    -- Render image
    local img = render_sprite(pixels, best.w, best.h, pal)
    if not img then return nil end

    return {
        type        = "image",
        image       = img,
        description = scene_id .. " (" .. best.w .. "x" .. best.h .. ")",
    }
end

return engine

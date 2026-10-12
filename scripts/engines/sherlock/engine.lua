-- ============================================================================
-- Adventure Explorer - Engine Script: Sherlock Holmes 1 & 2
-- ============================================================================
-- Sherlock Holmes 1: The Case of the Serrated Scalpel (320x200, bg=320x138)
-- Sherlock Holmes 2: The Case of the Rose Tattoo (640x480, scrollable)
--
-- Resource layout:
--   Scalpel: RRM files are standalone (resNN.rrm) or inside vgs.lib (CD).
--            Background (320x138) and palette (768 bytes) at END of RRM.
--            Object sprites and cAnimations are embedded in each RRM;
--            global sprites live in vgs.lib / portrait.lib.
--   Tattoo:  RRM files are standalone (resNN.rrm).
--            BgFileHeader (17 bytes) → palette (768) → background (LZSS).
--
-- Both can use LZV wrapping (LZV\x1A + u32le outSize + LZSS data).
-- ============================================================================

local engine = {}
engine.name        = "The Lost Files of Sherlock Holmes"
engine.id          = "sherlock"
engine.description = "The Lost Files of Sherlock Holmes (1992/1996, Electronic Arts)"
engine.version     = "2.1"

-- Binary helpers
local function u8(data, pos)   return data:byte(pos) end
local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end
local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end
local function u16be(data, pos)
    return data:byte(pos) * 256 + data:byte(pos + 1)
end
local function u32be(data, pos)
    return data:byte(pos) * 16777216
         + data:byte(pos + 1) * 65536
         + data:byte(pos + 2) * 256
         + data:byte(pos + 3)
end

-- ============================================================================
-- Case-insensitive file helpers
-- ============================================================================

local function find_file(game_path, name)
    local path = game_path .. "/" .. name:upper()
    if file_exists(path) then return path end
    path = game_path .. "/" .. name:lower()
    if file_exists(path) then return path end
    path = game_path .. "/" .. name
    if file_exists(path) then return path end
    return nil
end

local function open_file(game_path, name)
    local path = find_file(game_path, name)
    if path then return file_open(path) end
    return nil
end

-- ============================================================================
-- LZSS Decompression
-- Window size 4096, filled with 0xFF, initial pos 0xFEE
-- Control byte: LSB-first; bit=1 → literal, bit=0 → back-reference
-- Returns: (output_table, bytes_consumed)
-- ============================================================================

local function lzss_decompress(data, start_pos, output_size)
    local output = {}
    local n = 0
    local pos = start_pos

    -- Initialize 4096-byte window with 0xFF
    local window = {}
    for i = 0, 4095 do window[i] = 0xFF end
    local wpos = 0x0FEE

    local cmd = 0
    local len = #data

    while n < output_size and pos <= len do
        cmd = math.floor(cmd / 2)
        if cmd < 256 then
            if pos > len then break end
            cmd = u8(data, pos) + 0xFF00
            pos = pos + 1
        end

        if cmd % 2 == 1 then
            -- Literal byte
            if pos > len then break end
            local b = u8(data, pos); pos = pos + 1
            n = n + 1; output[n] = b
            window[wpos] = b
            wpos = (wpos + 1) % 4096
        else
            -- Back-reference
            if pos + 1 > len then break end
            local b1 = u8(data, pos); pos = pos + 1
            local b2 = u8(data, pos); pos = pos + 1
            local copy_pos = b1 + math.floor(b2 / 16) * 256
            local copy_len = (b2 % 16) + 3

            for _ = 1, copy_len do
                if n >= output_size then break end
                local b = window[copy_pos]
                copy_pos = (copy_pos + 1) % 4096
                n = n + 1; output[n] = b
                window[wpos] = b
                wpos = (wpos + 1) % 4096
            end
        end
    end

    while n < output_size do n = n + 1; output[n] = 0 end

    return output, (pos - start_pos)
end

-- ============================================================================
-- LZV decompression wrapper (LZV\x1A + u32le outSize + LZSS data)
-- ============================================================================

local function decompress_lzv(data)
    if not data or #data < 8 then return data end
    if data:byte(1) == 0x4C and data:byte(2) == 0x5A and
       data:byte(3) == 0x56 and data:byte(4) == 0x1A then
        local output_size = u32le(data, 5)
        local result = lzss_decompress(data, 9, output_size)
        local chars = {}
        for i = 1, #result do chars[i] = string.char(result[i]) end
        return table.concat(chars)
    end
    return data
end

-- ============================================================================
-- LIB file parser
-- Signature: LIB\x1A (4 bytes), then u16le count, then count x 17-byte entries
-- Each entry: 13-byte name (null-term) + u32le offset
-- LIC\x1A variant has extra (count+1)×8 bytes index before entries
-- ============================================================================

local function parse_lib(f)
    local sig = file_read(f, 0, 4)
    if not sig or #sig < 4 then return nil end
    if sig:byte(1) ~= 0x4C or sig:byte(2) ~= 0x49 then return nil end
    local is_new = (sig:byte(3) == 0x43)  -- 'C' = LIC variant

    local count_data = file_read(f, 4, 2)
    if not count_data or #count_data < 2 then return nil end
    local count = u16le(count_data, 1)

    local entry_start = 6
    if is_new then
        entry_start = 6 + (count + 1) * 8
    end

    local entry_data = file_read(f, entry_start, count * 17)
    if not entry_data or #entry_data < count * 17 then return nil end

    local fsize = file_size(f)
    local entries = {}
    for i = 0, count - 1 do
        local base = i * 17 + 1
        local name = ""
        for c = 0, 12 do
            local b = entry_data:byte(base + c)
            if not b or b == 0 then break end
            name = name .. string.char(b)
        end
        local offset = u32le(entry_data, base + 13)
        entries[#entries + 1] = { name = name, offset = offset }
    end

    for i = 1, #entries do
        if i < #entries then
            entries[i].size = entries[i + 1].offset - entries[i].offset
        else
            entries[i].size = fsize - entries[i].offset
        end
    end

    return entries
end

-- ============================================================================
-- Detection
-- ============================================================================

local function is_tattoo(game_path)
    return find_file(game_path, "walk.lib") ~= nil
end

local function is_scalpel(game_path)
    return find_file(game_path, "portrait.lib") ~= nil
end

function engine.detect(game_path)
    local has_vgs  = find_file(game_path, "vgs.lib") ~= nil
    local has_talk = find_file(game_path, "talk.lib") ~= nil
    return has_vgs and has_talk
end

-- ============================================================================
-- Read an RRM file: try standalone first, then VGS.LIB
-- ============================================================================

local function read_rrm(game_path, rrm_name)
    -- Try standalone file first (both casings)
    local rrm_path = find_file(game_path, rrm_name)
    if rrm_path then
        local f = file_open(rrm_path)
        if f then
            local sz = file_size(f)
            local data = file_read(f, 0, sz)
            file_close(f)
            if data then
                return decompress_lzv(data)
            end
        end
    end

    -- Fallback: try extracting from VGS.LIB
    local f = open_file(game_path, "vgs.lib")
    if not f then return nil end

    local entries = parse_lib(f)
    if not entries then file_close(f); return nil end

    for _, entry in ipairs(entries) do
        if entry.name:lower() == rrm_name:lower() then
            local data = file_read(f, entry.offset, entry.size)
            file_close(f)
            if data then
                return decompress_lzv(data)
            end
            return nil
        end
    end

    file_close(f)
    return nil
end

-- ============================================================================
-- ImageFile decoding (PC Sherlock image/sprite blobs)
-- Header per frame: u16le (w-1), u16le (h-1), u8 paletteBase,
--                   u8 rleFlag, u8 offsetX, u8 offsetY
--   paletteBase != 0 : nibble-packed, size = w*h/2
--   rleFlag != 0     : u16le (frameSize) + u8 rleMarker, data = frameSize - 11
--   otherwise        : raw, size = w*h
-- An optional palette block (390x2 frames + "VGA " signature + 768 bytes)
-- may precede the first frame.
-- The RLE payload itself differs per game: Serrated Scalpel uses a marker byte
-- followed by (colour, count) runs, while Rose Tattoo uses per-scanline
-- (skip, runLength, pixels...) pairs with no marker.
-- Returns: palette (768 entries, 1-based) or nil, list of
--          { w, h, x, y, pixels = { indices (0-based) } }
-- ============================================================================

local function decode_image(data, is_tattoo)
    local pal, frames = nil, {}
    local has_transparency = false
    if not data or #data < 8 then return nil, frames, has_transparency end

    local pos = 1
    local w = u16le(data, pos) + 1
    local h = u16le(data, pos + 2) + 1

    -- Optional embedded VGA palette
    if w == 390 and h == 2 and u8(data, pos + 4) == 0 and u8(data, pos + 5) == 0
       and u8(data, pos + 6) == 0 and u8(data, pos + 7) == 0
       and data:sub(9, 12) == "VGA " then
        pal = {}
        local p = 21
        for i = 0, 255 do
            local r = (u8(data, p + i * 3 + 0) or 0) * 255
            local g = (u8(data, p + i * 3 + 1) or 0) * 255
            local b = (u8(data, p + i * 3 + 2) or 0) * 255
            pal[i * 3 + 1] = math.floor(r / 63 + 0.5)
            pal[i * 3 + 2] = math.floor(g / 63 + 0.5)
            pal[i * 3 + 3] = math.floor(b / 63 + 0.5)
        end
        pos = 789
    end

    while pos + 7 <= #data do
        local fw = u16le(data, pos) + 1
        local fh = u16le(data, pos + 2) + 1
        local pb = u8(data, pos + 4)
        local rle = u8(data, pos + 5)
        local ox = u8(data, pos + 6)
        local oy = u8(data, pos + 7)
        pos = pos + 8

        -- Sentinel frames (title screens) use inverted (-320)x(-200) sizes
        if fw > 32768 or fh > 32768 then break end

        local count = fw * fh
        local pixels = {}
        local ok = true

        if pb ~= 0 then
            -- Nibble-packed (4bpp)
            local size = math.floor(count / 2)
            if pos + size - 1 > #data then
                ok = false
            else
                local k = 0
                for i = 0, size - 1 do
                    local b = u8(data, pos + i)
                    k = k + 1; pixels[k] = b % 16
                    k = k + 1; pixels[k] = math.floor(b / 16)
                end
                pos = pos + size
            end
        elseif rle ~= 0 then
            -- RLE: u16le frame size + marker byte, then the compressed data
            local raw = u16le(data, pos)
            local marker = u8(data, pos + 2)
            pos = pos + 3
            local size = raw - 11
            if size < 0 or pos + size - 1 > #data then
                ok = false
            elseif is_tattoo then
                -- Rose Tattoo: per-scanline (skip, runLength, colours...) with
                -- no marker byte and a write pointer that runs continuously
                -- across the whole image (skips are not clamped to the row).
                -- Skipped pixels stay transparent (0xFF).
                has_transparency = true
                for i = 1, count do pixels[i] = 0xFF end
                local d = pos
                local dp = 1
                for _ = 1, fh do
                    local xsize = fw
                    while xsize > 0 do
                        local skip = u8(data, d); d = d + 1
                        if not skip then ok = false; break end
                        dp = dp + skip
                        xsize = xsize - skip
                        if xsize == 0 then break end
                        local run = u8(data, d); d = d + 1
                        if not run then ok = false; break end
                        xsize = xsize - run
                        for _ = 1, run do
                            if dp >= 1 and dp <= count then
                                pixels[dp] = u8(data, d)
                            end
                            dp = dp + 1
                            d = d + 1
                        end
                    end
                    if not ok then break end
                end
                pos = d
            else
                local i = 0
                local rem = count
                while rem > 0 and i < size do
                    local b = u8(data, pos + i)
                    if b == marker and i + 2 < size then
                        local c = u8(data, pos + i + 1)
                        local run = math.min(u8(data, pos + i + 2), rem)
                        i = i + 3
                        for _ = 1, run do pixels[#pixels + 1] = c end
                        rem = rem - run
                    else
                        pixels[#pixels + 1] = b
                        i = i + 1
                        rem = rem - 1
                    end
                end
                pos = pos + size
            end
        else
            -- Raw
            if pos + count - 1 > #data then
                ok = false
            else
                for i = 0, count - 1 do pixels[i + 1] = u8(data, pos + i) end
                pos = pos + count
            end
        end

        if not ok then break end
        frames[#frames + 1] = { w = fw, h = fh, x = ox, y = oy, pixels = pixels }
    end

    return pal, frames, has_transparency
end

-- ============================================================================
-- Scalpel RRM object sprites (uncompressed, version != 10)
-- ============================================================================

local function scalpel_room_image_names(data)
    if not data or #data < 44 or u8(data, 40) == 10 then return nil end
    local bg_off = u32le(data, 41)
    if bg_off + 12 > #data then return nil end
    local bh = bg_off + 1
    local num_structs = u16le(data, bh)
    local num_images = u16le(data, bh + 2)
    if num_structs < 1 or num_images < 1 then return nil end
    if bh + 12 + num_structs * 14 > #data then return nil end

    local list = {}
    for i = 0, num_images - 1 do
        local p = bh + 12 + i * 14 + 5
        local name = ""
        for c = 0, 8 do
            local b = u8(data, p + c)
            if not b or b == 0 then break end
            name = name .. string.char(b)
        end
        list[#list + 1] = { name = name, index = i }
    end
    return list
end

local function scalpel_room_image_blob(data, index)
    if not data or #data < 44 or u8(data, 40) == 10 then return nil end
    local bg_off = u32le(data, 41)
    if bg_off + 12 > #data then return nil end
    local bh = bg_off + 1
    local num_structs = u16le(data, bh)
    local num_images = u16le(data, bh + 2)
    local desc_size = u16le(data, bh + 6)
    local seq_size = u16le(data, bh + 8)
    if index < 0 or index >= num_images then return nil end
    if bh + 12 + num_structs * 14 > #data then return nil end

    local info = bh + 12
    local start = info + num_structs * 14 + num_structs * 569 + desc_size + seq_size
    for i = 0, index - 1 do
        start = start + u32le(data, info + i * 14)
    end
    local size = u32le(data, info + index * 14)
    if size < 1 or start + size - 1 > #data then return nil end
    return data:sub(start, start + size - 1)
end

-- ============================================================================
-- Room palette (Scalpel uncompressed: 768 bytes before the 320x138 background)
-- ============================================================================

local function scalpel_palette(data)
    if not data or #data < 768 then return nil end
    local pal_start = #data - (320 * 138) - 768 + 1
    if pal_start < 1 then return nil end
    local palette = {}
    for i = 0, 255 do
        local r = u8(data, pal_start + i * 3 + 0) or 0
        local g = u8(data, pal_start + i * 3 + 1) or 0
        local b = u8(data, pal_start + i * 3 + 2) or 0
        palette[i * 3 + 1] = math.min(math.floor(r * 255 / 63 + 0.5), 255)
        palette[i * 3 + 2] = math.min(math.floor(g * 255 / 63 + 0.5), 255)
        palette[i * 3 + 3] = math.min(math.floor(b * 255 / 63 + 0.5), 255)
    end
    return palette
end

-- Rose Tattoo room palette (768 bytes at the start of the background header)
local function tattoo_palette(data)
    if not data or #data < 44 then return nil end
    local bg_off = u32le(data, 41)
    local pal_start = bg_off + 17 + 1
    if pal_start + 768 - 1 > #data then return nil end
    local palette = {}
    for i = 0, 255 do
        local r = u8(data, pal_start + i * 3 + 0) or 0
        local g = u8(data, pal_start + i * 3 + 1) or 0
        local b = u8(data, pal_start + i * 3 + 2) or 0
        palette[i * 3 + 1] = math.min(math.floor(r * 255 / 63 + 0.5), 255)
        palette[i * 3 + 2] = math.min(math.floor(g * 255 / 63 + 0.5), 255)
        palette[i * 3 + 3] = math.min(math.floor(b * 255 / 63 + 0.5), 255)
    end
    return palette
end

local function room_palette(game_path, base)
    local data = read_rrm(game_path, base .. ".rrm")
    if not data then return nil end
    if is_tattoo(game_path) then return tattoo_palette(data) end
    return scalpel_palette(data)
end

-- Standalone 16-bit VGA palettes bundled inside the LIB archives. Rose Tattoo
-- pairs each of these with a specific screen rather than with a room, so they
-- are not reachable through RES*.RRM.
local LIB_PALETTES = {
    map     = { lib = "walk.lib", entry = "MAP.PAL" },
    journal = { lib = "vgs.lib",  entry = "JOURNAL.PAL" },
    dartbd  = { lib = "vgs.lib",  entry = "DARTBD.PAL" },
    room    = { lib = "vgs.lib",  entry = "ROOM.PAL" },
}

local function convert_vga_palette(raw)
    if not raw or #raw < 768 then return nil end
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = math.min(math.floor((u8(raw, i * 3 + 1) or 0) * 255 / 63 + 0.5), 255)
        palette[i * 3 + 2] = math.min(math.floor((u8(raw, i * 3 + 2) or 0) * 255 / 63 + 0.5), 255)
        palette[i * 3 + 3] = math.min(math.floor((u8(raw, i * 3 + 3) or 0) * 255 / 63 + 0.5), 255)
    end
    return palette
end

local function lib_palette(game_path, base)
    local def = LIB_PALETTES[base]
    if not def then return nil end
    local f = open_file(game_path, def.lib)
    if not f then return nil end
    local entries = parse_lib(f)
    if not entries then file_close(f); return nil end
    for _, e in ipairs(entries) do
        if e.name:upper() == def.entry then
            local raw = file_read(f, e.offset, e.size)
            file_close(f)
            return convert_vga_palette(raw)
        end
    end
    file_close(f)
    return nil
end

local function first_room_base(game_path)
    local best, best_num = nil, nil
    local function consider(nm)
        local base = nm:lower():match("^(res%d+)%.rrm$")
        if base then
            local n = tonumber(base:match("(%d+)")) or 0
            if not best_num or n < best_num then best, best_num = base, n end
        end
    end
    local files = list_files(game_path)
    if files then for _, fn in ipairs(files) do consider(fn) end end
    local f = open_file(game_path, "vgs.lib")
    if f then
        local entries = parse_lib(f)
        file_close(f)
        if entries then for _, e in ipairs(entries) do consider(e.name) end end
    end
    return best
end

local function first_palette_id(game_path)
    local base = first_room_base(game_path)
    if base then return "pal_" .. base end
    return nil
end

local function resolve_palette(game_path, palette_id)
    if palette_id then
        local prefix, base = palette_id:match("^(%a+)_(.+)$")
        if prefix == "pal" and base then
            local palette = lib_palette(game_path, base) or room_palette(game_path, base)
            if palette then return palette end
        end
    end
    local base = first_room_base(game_path)
    if base then return room_palette(game_path, base) end
    return nil
end

local function build_sprite_resource(game_path, palette_id, embedded, frames, label, transparent_index)
    if not frames or #frames == 0 then return nil end

    local palette = embedded or resolve_palette(game_path, palette_id)
    if not palette then
        palette = {}
        for i = 1, 768 do palette[i] = 0 end
    end

    -- Indexed previews cannot represent alpha; follow the project convention of
    -- painting the transparent index magenta so masked pixels read as a backdrop
    -- instead of an opaque chunk of the underlying room colour.
    if transparent_index then
        palette[transparent_index * 3 + 1] = 255
        palette[transparent_index * 3 + 2] = 0
        palette[transparent_index * 3 + 3] = 255
    end

    local handles = {}
    for i, fr in ipairs(frames) do
        handles[i] = image_create_indexed(fr.w, fr.h, fr.pixels, palette)
    end
    if #handles == 0 then return nil end

    local first = frames[1]
    local desc = string.format("%s - %dx%d, %d frame%s",
        label or "sprite", first.w, first.h, #handles,
        #handles == 1 and "" or "s")

    if #handles == 1 then
        return { type = "image", image = handles[1], description = desc }
    end
    local anim = animation_create(handles, 150)
    if not anim then
        return { type = "image", image = handles[1], description = desc }
    end
    return { type = "animation", animation = anim, delay_ms = 150, description = desc }
end

-- Global interface sprites, in display order
local UI_SPRITES = {
    { key = "controls", file = "CONTROLS.VGS", name = "Controls Bar" },
    { key = "darts",    file = "DARTS.VGS",    name = "Darts Board" },
    { key = "bigmap",   file = "BIGMAP.VGS",   name = "Big Map" },
    { key = "mapicon",  file = "MAPICON.VGS",  name = "Map Icon" },
    { key = "overicon", file = "OVERICON.VGS", name = "Overview Icon" },
    { key = "omouse",   file = "OMOUSE.VGS",   name = "Mouse (Alt)" },
    { key = "rmouse",   file = "RMOUSE.VGS",   name = "Mouse" },
    { key = "menu",     file = "MENU.ALL",     name = "Menu" },
    { key = "install",  file = "INSTALL.LBV",  name = "Install Screen" },
}

local function load_vgs_sprite(game_path, lib_name, entry_name, palette_id, label)
    local f = open_file(game_path, lib_name)
    if not f then return nil end
    local entries = parse_lib(f)
    if not entries then file_close(f); return nil end
    for _, e in ipairs(entries) do
        if e.name:upper() == entry_name:upper() then
            local raw = file_read(f, e.offset, e.size)
            file_close(f)
            -- Rose Tattoo uses a different RLE payload than Serrated Scalpel, so
            -- global sprites must be decoded with the matching variant.
            local tattoo = is_tattoo(game_path)
            local pal, frames, transp = decode_image(decompress_lzv(raw), tattoo)
            local ti = (tattoo and transp) and 0xFF or nil
            return build_sprite_resource(game_path, palette_id, pal, frames, label, ti)
        end
    end
    file_close(f)
    return nil
end

local function load_sprite(game_path, basename, palette_id)
    -- Per-room object sprite: <room>_<index>
    local room, index = basename:match("^(res%d+)_(%d+)$")
    if room and index then
        local data = read_rrm(game_path, room .. ".rrm")
        local blob = scalpel_room_image_blob(data, tonumber(index))
        if not blob then return nil end
        local pal, frames = decode_image(blob)
        return build_sprite_resource(game_path, palette_id or ("pal_" .. room), pal, frames, room .. " sprite")
    end

    if basename == "walk" then
        return load_vgs_sprite(game_path, "vgs.lib", "WALK.VGS", palette_id, "Walk cycle")
    end

    local portrait = basename:match("^portrait_(.+)$")
    if portrait then
        return load_vgs_sprite(game_path, "portrait.lib", portrait .. ".VGS", palette_id, portrait)
    end

    local item = basename:match("^item(%d+)$")
    if item then
        return load_vgs_sprite(game_path, "vgs.lib", "ITEM" .. item .. ".VGS", palette_id, "Item " .. item)
    end

    local ui = basename:match("^ui_(.+)$")
    if ui then
        for _, def in ipairs(UI_SPRITES) do
            if def.key == ui then
                return load_vgs_sprite(game_path, "vgs.lib", def.file, palette_id, def.name)
            end
        end
    end

    return nil
end

-- ============================================================================
-- Scalpel speech / sound effects (.SND): Creative ADPCM 4-bit
-- ============================================================================

local ADPCM_SCALE = {
    0,  1,  2,  3,  4,  5,  6,  7,  0,  -1,  -2,  -3,  -4,  -5,  -6,  -7,
    1,  3,  5,  7,  9, 11, 13, 15, -1,  -3,  -5,  -7,  -9, -11, -13, -15,
    2,  6, 10, 14, 18, 22, 26, 30, -2,  -6, -10, -14, -18, -22, -26, -30,
    4, 12, 20, 28, 36, 44, 52, 60, -4, -12, -20, -28, -36, -44, -52, -60
}

local ADPCM_ADJUST = {
    0, 0, 0, 0, 0, 16, 16, 16,
    0, 0, 0, 0, 0, 16, 16, 16,
    240, 0, 0, 0, 0, 16, 16, 16,
    240, 0, 0, 0, 0, 16, 16, 16,
    240, 0, 0, 0, 0, 16, 16, 16,
    240, 0, 0, 0, 0, 16, 16, 16,
    240, 0, 0, 0, 0,  0,  0,  0,
    240, 0, 0, 0, 0,  0,  0,  0
}

local SOUND_LIBS = {
    { key = "snd",   file = "snd.snd",      label = "Sound Effects (SND.SND)" },
    { key = "title", file = "title.snd",    label = "Title (TITLE.SND)" },
    { key = "epi",   file = "epilogue.snd", label = "Epilogue (EPILOGUE.SND)" },
}

local function decode_adpcm_sample(sample, reference, scale)
    local samp = sample + scale
    if samp < 0 then samp = 0 elseif samp > 63 then samp = 63 end

    local ref = reference + ADPCM_SCALE[samp + 1]
    if ref < 0 then ref = 0 elseif ref > 255 then ref = 255 end

    scale = (scale + ADPCM_ADJUST[samp + 1]) % 256
    return ref, scale
end

local function decode_snd(data, name)
    if not data or #data < 9 then return nil end
    local size = u32be(data, 3)
    local rate = u16be(data, 7)
    local available = #data - 8
    if size > available then size = available end
    if size < 2 then return nil end

    -- The doorbell and fog horn at Lord Brumwell's are stored at 1100 Hz
    if (name == "JFCHIME.SND" or name == "JFFOG.SND") and rate == 1100 then
        rate = 11000
    end

    local reference = u8(data, 9)
    local scale = 0
    local out = {}
    local n = 0
    for i = 10, 9 + size - 1 do
        local b = u8(data, i)
        reference, scale = decode_adpcm_sample(math.floor(b / 16), reference, scale)
        n = n + 1; out[n] = string.char(reference)
        reference, scale = decode_adpcm_sample(b % 16, reference, scale)
        n = n + 1; out[n] = string.char(reference)
    end
    if n == 0 then return nil end

    local pcm = table.concat(out)
    local handle = sound_create_pcm(rate, 8, 1, false, pcm)
    if not handle then return nil end
    return {
        type = "sound", sound = handle,
        description = string.format("%s - %d Hz, %.2f s", name or "sound", rate, n / rate)
    }
end

local function load_sound(game_path, basename)
    local key, idx = basename:match("^(%a+)_(%d+)$")
    if not key then return nil end
    local lib = nil
    for _, l in ipairs(SOUND_LIBS) do
        if l.key == key then lib = l end
    end
    if not lib then return nil end

    local f = open_file(game_path, lib.file)
    if not f then return nil end
    local entries = parse_lib(f)
    if not entries then file_close(f); return nil end
    local entry = entries[tonumber(idx) + 1]
    if not entry then file_close(f); return nil end
    local data = file_read(f, entry.offset, entry.size)
    file_close(f)
    return decode_snd(data, entry.name)
end

-- ============================================================================
-- Rose Tattoo sprites / speech / sound effects
--
-- Room object sprites live inside the compressed RES*.RRM files. To avoid
-- reading multi-megabyte rooms just to enumerate them, only the room header
-- (bgInfo table + section sizes) is read; the full compressed image blobs are
-- read lazily when a sprite is actually selected.
--
-- Global sprites are stored uncompressed in VGS.LIB (interface, costumes,
-- full screen images) and WALK.LIB (characters, inventory items, map).
--
-- SFX are RIFF WAVE files inside SOUND.LIB; speech clips are header-less
-- 8-bit unsigned PCM at 11025 Hz inside the SPEECH*.LIB archives.
-- ============================================================================

-- RIFF/WAVE parser, returns rate, bits, channels, signed, pcm
local function decode_wav(data)
    if not data or #data < 12 then return nil end
    if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then return nil end
    local pos = 13
    local rate, bits, channels, signed
    while pos + 8 - 1 <= #data do
        local id = data:sub(pos, pos + 3)
        local size = u32le(data, pos + 4)
        local body = pos + 8
        if id == "fmt " and size >= 16 then
            channels = u16le(data, body + 2)
            rate = u32le(data, body + 4)
            bits = u16le(data, body + 14)
            signed = (bits == 16)
        elseif id == "data" then
            if body + size - 1 > #data then size = #data - body + 1 end
            return rate, bits, channels, signed, data:sub(body, body + size - 1)
        end
        pos = body + size + (size % 2)
    end
    return nil
end

-- Read only the header data of a Rose Tattoo room: num images, the bgInfo
-- table (filename/size/maxFrames) and the file offset where the compressed
-- image blobs begin. Also returns the room palette.
local function tattoo_room_info(game_path, rrm_name)
    local path = find_file(game_path, rrm_name)
    if not path then return nil end
    local f = file_open(path)
    if not f then return nil end
    local function fail() file_close(f); return nil end

    local head = file_read(f, 0, 44)
    if not head or #head < 44 then return fail() end
    if u8(head, 40) == 0 then return fail() end
    local bg_off = u32le(head, 41)

    local bgh = file_read(f, bg_off, 17)
    if not bgh or #bgh < 17 then return fail() end
    local num_structs = u16le(bgh, 1)
    local num_images  = u16le(bgh, 3)
    local desc_size   = u16le(bgh, 7)
    local seq_size    = u16le(bgh, 9)
    local scroll      = u16le(bgh, 11)
    if num_images < 1 or num_structs < 1 then return fail() end

    local pal_raw = file_read(f, bg_off + 17, 768)
    local palette = nil
    if pal_raw and #pal_raw >= 768 then
        palette = {}
        for i = 0, 255 do
            palette[i * 3 + 1] = math.min(math.floor((u8(pal_raw, i * 3 + 1) or 0) * 255 / 63 + 0.5), 255)
            palette[i * 3 + 2] = math.min(math.floor((u8(pal_raw, i * 3 + 2) or 0) * 255 / 63 + 0.5), 255)
            palette[i * 3 + 3] = math.min(math.floor((u8(pal_raw, i * 3 + 3) or 0) * 255 / 63 + 0.5), 255)
        end
    end

    -- Skip the (compressed) background image
    local pos = bg_off + 17 + 768
    local b = file_read(f, pos, 4)
    if not b or #b < 4 then return fail() end
    pos = pos + 4 + u32le(b, 1)

    local info = file_read(f, pos, num_structs * 14)
    if not info or #info < num_structs * 14 then return fail() end
    local images = {}
    for i = 0, num_structs - 1 do
        local base = i * 14
        local name = ""
        for c = 0, 8 do
            local ch = u8(info, base + 6 + c)
            if not ch or ch == 0 then break end
            name = name .. string.char(ch)
        end
        images[#images + 1] = {
            name = name,
            filesize = u32le(info, base + 1),
            maxframes = u8(info, base + 5),
        }
    end
    pos = pos + num_structs * 14

    -- Skip the shape, description and sequence tables to reach the images
    for _ = 1, 3 do
        local s = file_read(f, pos, 4)
        if not s or #s < 4 then return fail() end
        pos = pos + 4 + u32le(s, 1)
    end

    file_close(f)
    return {
        path = path, images = images, images_start = pos,
        palette = palette, num_images = num_images, num_structs = num_structs,
    }
end

local function tattoo_room_image_list(game_path, rrm_name)
    local info = tattoo_room_info(game_path, rrm_name)
    if not info then return nil end
    local list = {}
    for i = 0, info.num_images - 1 do
        local im = info.images[i + 1]
        if im then list[#list + 1] = { name = im.name, index = i } end
    end
    return list
end

local function load_tattoo_room_sprite(game_path, basename, palette_id)
    local room, index = basename:match("^(res%d+)_(%d+)$")
    if not room or not index then return nil end
    local info = tattoo_room_info(game_path, room .. ".rrm")
    if not info then return nil end
    local idx = tonumber(index)
    local im = info.images[idx + 1]
    if not im then return nil end

    local f = file_open(info.path)
    if not f then return nil end
    local pos = info.images_start
    for _ = 1, idx do
        local b = file_read(f, pos, 4)
        if not b or #b < 4 then file_close(f); return nil end
        pos = pos + 4 + u32le(b, 1)
    end
    local b = file_read(f, pos, 4)
    if not b or #b < 4 then file_close(f); return nil end
    local in_size = u32le(b, 1)
    local raw = file_read(f, pos + 4, in_size)
    file_close(f)
    if not raw or #raw < in_size then return nil end

    local bytes = lzss_decompress(raw, 1, im.filesize)
    local chars = {}
    for i = 1, #bytes do chars[i] = string.char(bytes[i]) end
    local pal, frames, transp = decode_image(table.concat(chars), true)
    local label = (im.name ~= "" and im.name) or ("Sprite " .. (idx + 1))
    local ti = transp and 0xFF or nil
    return build_sprite_resource(game_path, palette_id or ("pal_" .. room), pal, frames, label, ti)
end

-- Interface images inside VGS.LIB
local TATTOO_INTERFACE = {
    { key = "rmouse",    file = "RMOUSE.VGS",  name = "Mouse" },
    { key = "omouse",    file = "OMOUSE.VGS",  name = "Mouse (Alt)" },
    { key = "hand1",     file = "HAND1.VGS",   name = "Hand 1" },
    { key = "hand2",     file = "HAND2.VGS",   name = "Hand 2" },
    { key = "intrface",  file = "INTRFACE.VGS", name = "Interface" },
    { key = "darts",     file = "DARTS.VGS",   name = "Darts Board" },
    { key = "dartslft",  file = "DARTSLFT.VGS", name = "Darts (Left)" },
    { key = "dartmap",   file = "DARTMAP.VGS", name = "Darts Map" },
    { key = "dartbd",    file = "DARTBD.VGS",  name = "Darts Background" },
}

-- Named costumes stored in VGS.LIB rather than WALK.LIB
local TATTOO_COSTUMES = {
    "TUX.VGS", "GREEN.VGS", "MYCROFT.VGS", "OPIUM.VGS",
    "WIGGINS.VGS", "TOBY.VGS", "COAT3.VGS",
}

local TATTOO_MAP = { "MAP.VGS", "MAPICONS.VGS" }

local function load_tattoo_global_sprite(game_path, basename, palette_id)
    local lib, key = basename:match("^(%a+)_(.+)$")
    if not lib or not key then return nil end
    local lib_file = (lib == "vgs") and "vgs.lib" or "walk.lib"
    return load_vgs_sprite(game_path, lib_file, key:upper() .. ".VGS", palette_id, key)
end

local function load_tattoo_effect(game_path, basename)
    local idx = tonumber(basename)
    if not idx then return nil end
    local f = open_file(game_path, "sound.lib")
    if not f then return nil end
    local entries = parse_lib(f)
    if not entries then file_close(f); return nil end
    local entry = entries[idx + 1]
    if not entry then file_close(f); return nil end
    local data = file_read(f, entry.offset, entry.size)
    file_close(f)
    if not data then return nil end

    local rate, bits, channels, signed, pcm = decode_wav(data)
    if not rate or not pcm or #pcm == 0 then return nil end
    local handle = sound_create_pcm(rate, bits, channels, signed, pcm)
    if not handle then return nil end
    local secs = #pcm / (rate * channels * (bits / 8))
    return {
        type = "sound", sound = handle,
        description = string.format("%s - %d Hz, %d-bit, %.2f s", entry.name, rate, bits, secs),
    }
end

local function load_tattoo_speech(game_path, basename)
    local libnum, idx = basename:match("^(%d+)_(%d+)$")
    if not libnum then return nil end
    local f = open_file(game_path, string.format("SPEECH%02d.LIB", tonumber(libnum)))
    if not f then return nil end
    local entries = parse_lib(f)
    if not entries then file_close(f); return nil end
    local entry = entries[tonumber(idx) + 1]
    if not entry then file_close(f); return nil end
    local data = file_read(f, entry.offset, entry.size)
    file_close(f)
    if not data or #data == 0 then return nil end

    local handle = sound_create_pcm(11025, 8, 1, false, data)
    if not handle then return nil end
    return {
        type = "sound", sound = handle,
        description = string.format("%s - 11025 Hz, %.2f s", entry.name, #data / 11025),
    }
end

local function lib_entry_names(game_path, lib_name)
    local names = {}
    local f = open_file(game_path, lib_name)
    if not f then return names end
    local entries = parse_lib(f)
    file_close(f)
    if entries then
        for _, e in ipairs(entries) do names[e.name:upper()] = e.size end
    end
    return names
end

local function build_global_sprites_tattoo(game_path)
    local cat = { id = "sprites", name = "Sprites", type = "category", children = {} }
    local walk = lib_entry_names(game_path, "walk.lib")
    local vgs  = lib_entry_names(game_path, "vgs.lib")

    -- Characters: walk cycles / directional sets from WALK.LIB plus costumes
    local chars = {}
    for name in pairs(walk) do
        if name:match("%.VGS$") and not name:match("^ITEM%d") and not name:match("^MAP") then
            chars[#chars + 1] = name
        end
    end
    for _, name in ipairs(TATTOO_COSTUMES) do
        if vgs[name] and not walk[name] then chars[#chars + 1] = name end
    end
    if #chars > 0 then
        table.sort(chars)
        local sub = { id = "sprchar", name = string.format("Characters (%d)", #chars), type = "category", children = {} }
        for _, name in ipairs(chars) do
            local key = name:match("^(.+)%.VGS$")
            local lib = walk[name] and "walk" or "vgs"
            sub.children[#sub.children + 1] = { id = "spr_" .. lib .. "_" .. key:lower(), name = key, type = "image" }
        end
        cat.children[#cat.children + 1] = sub
    end

    -- Inventory items: ITEMnn.VGS in WALK.LIB
    local items = {}
    for name in pairs(walk) do
        local n = name:match("^ITEM(%d+)%.VGS$")
        if n then items[#items + 1] = tonumber(n) end
    end
    if #items > 0 then
        table.sort(items)
        local sub = { id = "spritem", name = string.format("Inventory Items (%d)", #items), type = "category", children = {} }
        for _, n in ipairs(items) do
            sub.children[#sub.children + 1] = {
                id = string.format("spr_walk_item%02d", n),
                name = string.format("Item %02d", n), type = "image",
            }
        end
        cat.children[#cat.children + 1] = sub
    end

    -- Interface images from VGS.LIB
    local sub = nil
    for _, def in ipairs(TATTOO_INTERFACE) do
        if vgs[def.file] then
            if not sub then
                sub = { id = "sprui", name = "Interface", type = "category", children = {} }
                cat.children[#cat.children + 1] = sub
            end
            sub.children[#sub.children + 1] = { id = "spr_vgs_" .. def.key, name = def.name, type = "image" }
        end
    end

    -- Map screens from WALK.LIB
    sub = nil
    for _, name in ipairs(TATTOO_MAP) do
        if walk[name] then
            if not sub then
                sub = { id = "sprmap", name = "Map", type = "category", children = {} }
                cat.children[#cat.children + 1] = sub
            end
            local key = name:match("^(.+)%.VGS$")
            sub.children[#sub.children + 1] = { id = "spr_walk_" .. key:lower(), name = key, type = "image" }
        end
    end

    -- Full-screen images (640x480 single-frame) from VGS.LIB
    local screens = {}
    for name, size in pairs(vgs) do
        if name:match("%.VGS$") and size == 307208 then
            local is_ui = false
            for _, def in ipairs(TATTOO_INTERFACE) do
                if def.file == name then is_ui = true end
            end
            if not is_ui then screens[#screens + 1] = name end
        end
    end
    if #screens > 0 then
        table.sort(screens)
        local scsub = { id = "sprscreen", name = string.format("Screens (%d)", #screens), type = "category", children = {} }
        for _, name in ipairs(screens) do
            local key = name:match("^(.+)%.VGS$")
            scsub.children[#scsub.children + 1] = { id = "spr_vgs_" .. key:lower(), name = key, type = "image" }
        end
        cat.children[#cat.children + 1] = scsub
    end

    -- Standalone LIB palettes, so the map/journal/darts screens can be paired
    -- with the palette they were authored against.
    sub = nil
    for _, base in ipairs({ "map", "journal", "dartbd" }) do
        if lib_palette(game_path, base) then
            if not sub then
                sub = { id = "sprpal", name = "Palettes", type = "category", children = {} }
                cat.children[#cat.children + 1] = sub
            end
            sub.children[#sub.children + 1] = {
                id = "pal_" .. base, name = base:upper() .. " palette", type = "palette",
            }
        end
    end

    if #cat.children == 0 then return nil end
    return cat
end

local function build_sound_category_tattoo(game_path)
    local cat = { id = "sounds", name = "Sounds", type = "category", children = {} }

    -- Sound effects: RIFF WAVE entries in SOUND.LIB
    local f = open_file(game_path, "sound.lib")
    if f then
        local entries = parse_lib(f)
        file_close(f)
        if entries then
            local sub = nil
            for i, e in ipairs(entries) do
                if e.name:upper():match("%.WAV$") then
                    if not sub then
                        sub = { id = "sndcat_sfx", name = "Sound Effects", type = "category", children = {} }
                        cat.children[#cat.children + 1] = sub
                    end
                    sub.children[#sub.children + 1] = {
                        id = "sfx_" .. (i - 1),
                        name = (e.name:gsub("%.[Ww][Aa][Vv]$", "")), type = "sound",
                    }
                end
            end
            if sub then sub.name = string.format("Sound Effects (%d)", #sub.children) end
        end
    end

    -- Speech: one subcategory per SPEECHnn.LIB archive
    local speech = { id = "sndcat_speech", name = "Speech", type = "category", children = {} }
    local libs = {}
    local files = list_files(game_path)
    if files then
        for _, fn in ipairs(files) do
            local num = fn:lower():match("^speech(%d+)%.lib$")
            if num then libs[#libs + 1] = { num = tonumber(num), file = fn } end
        end
    end
    table.sort(libs, function(a, b) return a.num < b.num end)
    for _, lib in ipairs(libs) do
        local sf = open_file(game_path, lib.file)
        if sf then
            local entries = parse_lib(sf)
            file_close(sf)
            if entries and #entries > 0 then
                local sub = {
                    id = string.format("spccat_%02d", lib.num),
                    name = string.format("Scene %02d (%d)", lib.num, #entries),
                    type = "category", children = {},
                }
                for i, e in ipairs(entries) do
                    sub.children[#sub.children + 1] = {
                        id = string.format("spc_%02d_%d", lib.num, i - 1),
                        name = e.name, type = "sound",
                    }
                end
                speech.children[#speech.children + 1] = sub
            end
        end
    end
    if #speech.children > 0 then cat.children[#cat.children + 1] = speech end

    if #cat.children == 0 then return nil end
    return cat
end

-- Global sprite + sound resource tree helpers
local function build_global_sprites(game_path)
    local cat = { id = "sprites", name = "Sprites", type = "category", children = {} }

    local vgs, port = {}, {}
    local function load_names(lib_name, dest)
        local f = open_file(game_path, lib_name)
        if not f then return end
        local entries = parse_lib(f)
        file_close(f)
        if entries then
            for _, e in ipairs(entries) do dest[e.name:upper()] = e.size end
        end
    end
    load_names("vgs.lib", vgs)
    load_names("portrait.lib", port)

    if vgs["WALK.VGS"] then
        cat.children[#cat.children + 1] = {
            id = "sprchar", name = "Characters", type = "category",
            children = { { id = "spr_walk", name = "Walk Cycles", type = "image" } }
        }
    end

    local portraits = {}
    for name, size in pairs(port) do
        if size and size > 32 then portraits[#portraits + 1] = name end
    end
    if #portraits > 0 then
        table.sort(portraits)
        local sub = { id = "sprport", name = string.format("Portraits (%d)", #portraits), type = "category", children = {} }
        for _, name in ipairs(portraits) do
            local key = name:match("^(.+)%.VGS$") or name
            sub.children[#sub.children + 1] = { id = "spr_portrait_" .. key, name = key, type = "image" }
        end
        cat.children[#cat.children + 1] = sub
    end

    local items = {}
    for i = 1, 99 do
        if vgs[string.format("ITEM%02d.VGS", i)] then items[#items + 1] = i end
    end
    if #items > 0 then
        local sub = { id = "spritem", name = string.format("Inventory Items (%d)", #items), type = "category", children = {} }
        for _, i in ipairs(items) do
            sub.children[#sub.children + 1] = {
                id = string.format("spr_item%02d", i),
                name = string.format("Item %02d", i), type = "image"
            }
        end
        cat.children[#cat.children + 1] = sub
    end

    local sub = nil
    for _, def in ipairs(UI_SPRITES) do
        if vgs[def.file] then
            if not sub then
                sub = { id = "sprui", name = "Interface", type = "category", children = {} }
                cat.children[#cat.children + 1] = sub
            end
            sub.children[#sub.children + 1] = { id = "spr_ui_" .. def.key, name = def.name, type = "image" }
        end
    end

    return cat
end

local function build_sound_category(game_path)
    local cat = { id = "sounds", name = "Sounds", type = "category", children = {} }
    for _, lib in ipairs(SOUND_LIBS) do
        local f = open_file(game_path, lib.file)
        if f then
            local entries = parse_lib(f)
            file_close(f)
            if entries and #entries > 0 then
                local sub = {
                    id = "sndcat_" .. lib.key,
                    name = string.format("%s (%d)", lib.label, #entries),
                    type = "category", children = {}
                }
                for i, e in ipairs(entries) do
                    sub.children[#sub.children + 1] = {
                        id = string.format("snd_%s_%d", lib.key, i - 1),
                        name = (e.name:gsub("%.SND$", "")), type = "sound"
                    }
                end
                cat.children[#cat.children + 1] = sub
            end
        end
    end
    if #cat.children == 0 then return nil end
    return cat
end

-- ============================================================================
-- Resource tree: enumerate resNN.rrm files
-- Scan game directory for standalone RRMs, also check VGS.LIB
-- ============================================================================

function engine.get_resources(game_path)
    local resources = {}
    local tattoo = is_tattoo(game_path)
    local game_label = tattoo and "Rose Tattoo" or "Serrated Scalpel"

    -- Collect RRM names from standalone files in the game directory
    local rrm_names = {}
    local seen = {}

    local files = list_files(game_path)
    if files then
        for _, fname in ipairs(files) do
            local lower = fname:lower()
            if lower:match("^res%d+%.rrm$") then
                if not seen[lower] then
                    seen[lower] = true
                    rrm_names[#rrm_names + 1] = fname
                end
            end
        end
    end

    -- Also check VGS.LIB for any RRM entries not already found
    local f = open_file(game_path, "vgs.lib")
    if f then
        local entries = parse_lib(f)
        file_close(f)
        if entries then
            for _, entry in ipairs(entries) do
                local lower = entry.name:lower()
                if lower:match("%.rrm$") and not seen[lower] then
                    seen[lower] = true
                    rrm_names[#rrm_names + 1] = entry.name
                end
            end
        end
    end

    -- Sort by room number
    table.sort(rrm_names, function(a, b)
        local na = tonumber(a:lower():match("(%d+)")) or 0
        local nb = tonumber(b:lower():match("(%d+)")) or 0
        return na < nb
    end)

    -- Build resource tree
    local rooms_cat = {
        id       = "rooms",
        name     = string.format("%s Rooms (%d)", game_label, #rrm_names),
        type     = "category",
        children = {}
    }

    for _, rrm_name in ipairs(rrm_names) do
        local basename = rrm_name:match("^(.+)%.") or rrm_name
        local room_node = {
            id       = "room_" .. basename:lower(),
            name     = basename,
            type     = "category",
            children = {}
        }
        room_node.children[#room_node.children + 1] = {
            id   = "bg_" .. basename:lower(),
            name = "Background",
            type = "image"
        }
        room_node.children[#room_node.children + 1] = {
            id   = "pal_" .. basename:lower(),
            name = "Palette",
            type = "palette"
        }

        -- Per-room object sprites (header read only, blobs loaded lazily)
        local images
        if tattoo then
            images = tattoo_room_image_list(game_path, rrm_name)
        else
            images = scalpel_room_image_names(read_rrm(game_path, rrm_name))
        end
        if images and #images > 0 then
            local sprites = {
                id       = "sprcat_" .. basename:lower(),
                name     = string.format("Sprites (%d)", #images),
                type     = "category",
                children = {}
            }
            for _, img in ipairs(images) do
                sprites.children[#sprites.children + 1] = {
                    id   = string.format("sp_%s_%d", basename:lower(), img.index),
                    name = img.name ~= "" and img.name or string.format("Sprite %d", img.index + 1),
                    type = "image"
                }
            end
            room_node.children[#room_node.children + 1] = sprites
        end

        rooms_cat.children[#rooms_cat.children + 1] = room_node
    end

    if #rooms_cat.children > 0 then
        resources[#resources + 1] = rooms_cat
    end

    -- Global sprites and sounds
    local sprites, sounds
    if tattoo then
        sprites = build_global_sprites_tattoo(game_path)
        sounds  = build_sound_category_tattoo(game_path)
    else
        sprites = build_global_sprites(game_path)
        sounds  = build_sound_category(game_path)
    end
    if sprites and #sprites.children > 0 then
        resources[#resources + 1] = sprites
    end
    if sounds then
        resources[#resources + 1] = sounds
    end

    return resources
end

-- ============================================================================
-- Resource loading dispatch
-- ============================================================================

function engine.load_resource(game_path, resource_id, palette_id)
    local prefix, basename = resource_id:match("^(%a+)_(.+)$")
    if not prefix or not basename then return nil end
    if prefix == "bg"  then return load_background(game_path, basename) end
    if prefix == "pal" then return load_palette_swatch(game_path, basename) end
    if prefix == "sp"  then
        if is_tattoo(game_path) then return load_tattoo_room_sprite(game_path, basename, palette_id) end
        return load_sprite(game_path, basename, palette_id)
    end
    if prefix == "spr" then
        if is_tattoo(game_path) then return load_tattoo_global_sprite(game_path, basename, palette_id) end
        return load_sprite(game_path, basename, palette_id)
    end
    if prefix == "snd" then return load_sound(game_path, basename) end
    if prefix == "sfx" then return load_tattoo_effect(game_path, basename) end
    if prefix == "spc" then return load_tattoo_speech(game_path, basename) end
    return nil
end

-- ============================================================================
-- Default palette pairing for sprites
-- ============================================================================

function engine.default_palette(game_path, resource_id)
    local room = resource_id:match("^sp_(res%d+)_%d+$")
    if room then return "pal_" .. room end

    if is_tattoo(game_path) then
        -- The main map (MAP/MAPICONS) and the RES*.VGS map close-ups all use
        -- MAP.PAL; the journal and dartboard bring their own palettes.
        if resource_id == "spr_walk_map" or resource_id == "spr_walk_mapicons" then
            return "pal_map"
        end
        local vgs = resource_id:match("^spr_vgs_(.+)$")
        if vgs then
            if vgs == "journal" then return "pal_journal" end
            if vgs == "dartbd"  then return "pal_dartbd" end
            if vgs:match("^res") then return "pal_map" end
        end
    end

    if resource_id:match("^spr_") then return first_palette_id(game_path) end
    return nil
end

-- ============================================================================
-- Rose Tattoo background loader
-- BgFileHeader (17 bytes) → palette (768 bytes) → background pixels (LZSS)
-- ============================================================================

local function load_tattoo_bg(data)
    if #data < 44 then return nil end

    local compressed = (u8(data, 40) > 0)  -- byte 39 (0-based)
    local bg_header_off = u32le(data, 41)   -- byte 40 (0-based)

    if bg_header_off + 17 > #data then return nil end
    local bh_pos = bg_header_off + 1        -- 1-based

    -- BgFileHeader (17 bytes for Tattoo)
    local scrollSize = u16le(data, bh_pos + 10)

    -- Palette immediately after BgFileHeader
    local pal_pos = bh_pos + 17
    if pal_pos + 767 > #data then return nil end

    local palette = {}
    for i = 0, 255 do
        local r = u8(data, pal_pos + i * 3 + 0)
        local g = u8(data, pal_pos + i * 3 + 1)
        local b = u8(data, pal_pos + i * 3 + 2)
        palette[i * 3 + 1] = math.min(math.floor(r * 255 / 63 + 0.5), 255)
        palette[i * 3 + 2] = math.min(math.floor(g * 255 / 63 + 0.5), 255)
        palette[i * 3 + 3] = math.min(math.floor(b * 255 / 63 + 0.5), 255)
    end

    -- Background pixels after palette
    local pix_pos = pal_pos + 768
    local w = 640 + scrollSize
    local h = 480
    local total = w * h
    local pixels

    if compressed and pix_pos + 3 <= #data then
        -- Rose Tattoo compressed: i32le input size prefix, then LZSS data
        -- (We don't need input_size; decompress by output_size)
        pixels = lzss_decompress(data, pix_pos + 4, total)
    else
        -- Uncompressed: raw pixel bytes
        pixels = {}
        local avail = math.min(total, #data - pix_pos + 1)
        for i = 1, avail do
            pixels[i] = u8(data, pix_pos + i - 1)
        end
        for i = avail + 1, total do pixels[i] = 0 end
    end

    return pixels, palette, w, h, scrollSize
end

-- ============================================================================
-- Scalpel background loader
-- Palette (768 bytes) and background (320×138) are at the END of the RRM.
-- For uncompressed (version != 10): palette at EOF-44928, bg at EOF-44160
-- For compressed (version == 10): sequential parsing needed
-- ============================================================================

local function load_scalpel_bg(data)
    if #data < 44 then return nil end

    local version = u8(data, 40)            -- byte 39 (0-based)
    local compressed = (version == 10)
    local bg_header_off = u32le(data, 41)

    if bg_header_off + 12 > #data then return nil end
    local bh_pos = bg_header_off + 1

    -- BgFileHeader (12 bytes for Scalpel)
    local numStructs = u16le(data, bh_pos + 0)
    local numImages  = u16le(data, bh_pos + 2)
    local numcAnims  = u16le(data, bh_pos + 4)
    local descSize   = u16le(data, bh_pos + 6)
    local seqSize    = u16le(data, bh_pos + 8)

    local w, h = 320, 138
    local total = w * h  -- 44160

    if not compressed then
        -- ================================================================
        -- UNCOMPRESSED: palette and bg are at the end of the file
        -- Layout: ... | palette (768 bytes) | background (44160 bytes) | EOF
        -- ================================================================
        local pal_start = #data - total - 768 + 1  -- 1-based
        if pal_start < 1 then return nil end

        local palette = {}
        for i = 0, 255 do
            local r = u8(data, pal_start + i * 3 + 0)
            local g = u8(data, pal_start + i * 3 + 1)
            local b = u8(data, pal_start + i * 3 + 2)
            palette[i * 3 + 1] = math.min(math.floor(r * 255 / 63 + 0.5), 255)
            palette[i * 3 + 2] = math.min(math.floor(g * 255 / 63 + 0.5), 255)
            palette[i * 3 + 3] = math.min(math.floor(b * 255 / 63 + 0.5), 255)
        end

        local pix_start = pal_start + 768
        local pixels = {}
        for i = 0, total - 1 do
            pixels[i + 1] = u8(data, pix_start + i)
        end

        return pixels, palette, w, h, 0
    end

    -- ================================================================
    -- COMPRESSED (version == 10): parse sections sequentially
    -- Scalpel compressed has NO input-size prefix on sections.
    -- We must decompress each section to track consumed input bytes.
    -- ================================================================

    local pos = bh_pos + 12  -- after BgFileHeader

    -- Read BgFileHeaderInfo entries (always uncompressed, 14 bytes each)
    local struct_filesizes = {}
    for i = 1, numStructs do
        if pos + 13 > #data then return nil end
        struct_filesizes[i] = u32le(data, pos)
        pos = pos + 14
    end

    -- Shapes: each separately compressed, output = struct_filesizes[i] bytes
    for i = 1, numStructs do
        local fsize = struct_filesizes[i]
        if fsize > 0 and pos <= #data then
            local _, consumed = lzss_decompress(data, pos, fsize)
            pos = pos + consumed
        end
    end

    -- Description text
    if descSize > 0 and pos <= #data then
        local _, consumed = lzss_decompress(data, pos, descSize)
        pos = pos + consumed
    end

    -- Sequence data
    if seqSize > 0 and pos <= #data then
        local _, consumed = lzss_decompress(data, pos, seqSize)
        pos = pos + consumed
    end

    -- Images (numImages entries)
    -- Each image entry: u32le filesize + image data compressed to that size
    for i = 1, numImages do
        if pos + 3 > #data then break end
        local img_fsize = u32le(data, pos)
        pos = pos + 4
        if img_fsize > 0 and pos <= #data then
            local _, consumed = lzss_decompress(data, pos, img_fsize)
            pos = pos + consumed
        end
    end

    -- cAnimations (numcAnims entries, 65 bytes each when decompressed)
    for i = 1, numcAnims do
        if pos <= #data then
            local _, consumed = lzss_decompress(data, pos, 65)
            pos = pos + consumed
        end
    end

    -- Bounding areas: u16le size + data
    if pos + 1 <= #data then
        local bnd_size = u16le(data, pos)
        pos = pos + 2 + bnd_size
    end

    -- Path data: version byte
    if pos <= #data then
        pos = pos + 1  -- path version byte (254)
    end

    -- Walk directory: numStructs × numStructs matrix
    pos = pos + numStructs * numStructs

    -- Walk data: u16le size + data
    if pos + 1 <= #data then
        local walk_size = u16le(data, pos)
        pos = pos + 2 + walk_size
    end

    -- Exits: u8 count + count × 20 bytes (rough estimate)
    if pos <= #data then
        local exit_count = u8(data, pos)
        pos = pos + 1 + exit_count * 20
    end

    -- Entrance: 8 bytes (x, y, start_dir, start_cAnimNum)
    pos = pos + 8

    -- Sounds: u8 count + count × 9 bytes
    if pos <= #data then
        local snd_count = u8(data, pos)
        pos = pos + 1 + snd_count * 9
    end

    -- PALETTE (768 bytes, not compressed)
    if pos + 767 > #data then
        -- Fallback: try end-of-file calculation
        pos = #data - total - 768 + 1
        if pos < 1 then return nil end
    end

    local palette = {}
    for i = 0, 255 do
        local r = u8(data, pos + i * 3 + 0) or 0
        local g = u8(data, pos + i * 3 + 1) or 0
        local b = u8(data, pos + i * 3 + 2) or 0
        palette[i * 3 + 1] = math.min(math.floor(r * 255 / 63 + 0.5), 255)
        palette[i * 3 + 2] = math.min(math.floor(g * 255 / 63 + 0.5), 255)
        palette[i * 3 + 3] = math.min(math.floor(b * 255 / 63 + 0.5), 255)
    end
    pos = pos + 768

    -- BACKGROUND (320×138 pixels, LZSS compressed)
    local pixels
    if pos <= #data then
        pixels = lzss_decompress(data, pos, total)
    end

    if not pixels then return nil end
    return pixels, palette, w, h, 0
end

-- ============================================================================
-- Main background loader
-- ============================================================================

function load_background(game_path, basename)
    -- Reconstruct RRM filename from basename (e.g., "res01" → "res01.rrm")
    local rrm_name = basename .. ".rrm"
    local data = read_rrm(game_path, rrm_name)
    if not data then return nil end

    local tattoo = is_tattoo(game_path)
    local pixels, palette, w, h, scroll

    if tattoo then
        pixels, palette, w, h, scroll = load_tattoo_bg(data)
    else
        pixels, palette, w, h, scroll = load_scalpel_bg(data)
    end

    if not pixels or not palette then return nil end

    local img = image_create_indexed(w, h, pixels, palette)
    local game_label = tattoo and "Rose Tattoo" or "Serrated Scalpel"
    return {
        type = "image", image = img,
        description = string.format("%s - %s - %dx%d, 256 colors%s",
            game_label, basename, w, h,
            scroll and scroll > 0 and string.format(" (scroll: %d)", scroll) or "")
    }
end

function load_palette_swatch(game_path, basename)
    local tattoo = is_tattoo(game_path)
    local palette

    -- Standalone LIB palettes (map/journal/dartbd/room) take precedence
    if tattoo then palette = lib_palette(game_path, basename) end

    if not palette then
        local data = read_rrm(game_path, basename .. ".rrm")
        if not data then return nil end
        if tattoo then
            _, palette = load_tattoo_bg(data)
        else
            _, palette = load_scalpel_bg(data)
        end
    end
    if not palette then return nil end

    -- Render 16x16 grid
    local CELL, GRID = 16, 16
    local SIZE = CELL * GRID
    local rgb = {}; local n = 0

    for py = 0, SIZE - 1 do
        for px = 0, SIZE - 1 do
            local ci = math.floor(py / CELL) * GRID + math.floor(px / CELL)
            n = n + 1; rgb[n] = palette[ci * 3 + 1] or 0
            n = n + 1; rgb[n] = palette[ci * 3 + 2] or 0
            n = n + 1; rgb[n] = palette[ci * 3 + 3] or 0
        end
    end

    local img = image_create_rgb(SIZE, SIZE, rgb)
    return {
        type = "image", image = img,
        description = string.format("%s palette - 256 colors", basename)
    }
end

return engine

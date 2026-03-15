-- ============================================================================
-- Adventure Explorer - Engine Script: Sherlock Holmes 1 & 2
-- ============================================================================
-- Sherlock Holmes 1: The Case of the Serrated Scalpel (320x200, bg=320x138)
-- Sherlock Holmes 2: The Case of the Rose Tattoo (640x480, scrollable)
--
-- Resource layout:
--   Scalpel: RRM files are standalone (resNN.rrm) or inside vgs.lib (CD).
--            Background (320x138) and palette (768 bytes) at END of RRM.
--   Tattoo:  RRM files are standalone (resNN.rrm).
--            BgFileHeader (17 bytes) → palette (768) → background (LZSS).
--
-- Both can use LZV wrapping (LZV\x1A + u32le outSize + LZSS data).
-- ============================================================================

local engine = {}
engine.name        = "The Lost Files of Sherlock Holmes"
engine.id          = "sherlock"
engine.description = "The Lost Files of Sherlock Holmes (1992/1996, Electronic Arts)"
engine.version     = "2.0"

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
            type = "image"
        }
        rooms_cat.children[#rooms_cat.children + 1] = room_node
    end

    if #rooms_cat.children > 0 then
        resources[#resources + 1] = rooms_cat
    end

    return resources
end

-- ============================================================================
-- Resource loading dispatch
-- ============================================================================

function engine.load_resource(game_path, resource_id)
    local prefix, basename = resource_id:match("^(%a+)_(.+)$")
    if not prefix or not basename then return nil end
    if prefix == "bg"  then return load_background(game_path, basename) end
    if prefix == "pal" then return load_palette_swatch(game_path, basename) end
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
    local rrm_name = basename .. ".rrm"
    local data = read_rrm(game_path, rrm_name)
    if not data then return nil end

    local tattoo = is_tattoo(game_path)
    local _, palette

    if tattoo then
        _, palette = load_tattoo_bg(data)
    else
        _, palette = load_scalpel_bg(data)
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

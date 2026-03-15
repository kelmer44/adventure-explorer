-- ============================================================================
-- Adventure Explorer - Engine Script: Alfred Pelrock (1997, DOS)
-- ============================================================================
-- ALFRED.1 structure: 56 rooms x 104 bytes directory (13 data pairs each)
--   Pairs 0-7:  Background blocks (RLE or raw)
--   Pair  8:    Sprite pixel data (RLE, all frames concatenated)
--   Pair  9:    Room objects
--   Pair  10:   Room data: sprite headers + hotspots + walkboxes + exits
--   Pair  11:   Palette (768 bytes, VGA 6-bit)
--   Pair  12:   Text data
--
-- Sprite header structure (44 bytes each, starting at pair10[0x06]):
--   pair10[0x05]: sprite count (includes 2 system sprites; game sprites start at idx 2)
--   +0x0A: x (u16le)           +0x0C: y (u16le)
--   +0x0E: width (u8)          +0x0F: height (u8)
--   +0x10: stride (u16le)      +0x12: total_frames (u8)
--   +0x13: current_seq (u8)    +0x14..+0x1F: seq_frame_counts[12]
--   +0x21: z_index (i8)        +0x2C: type_flags  +0x30: interactive
-- ============================================================================

local engine = {}
engine.name        = "Alfred Pelrock"
engine.id          = "pelrock"
engine.description = "Alfred Pelrock (1997, DOS point-and-click adventure)"
engine.version     = "1.1"

-- ── Binary helpers ───────────────────────────────────────────────

local function u8(data, pos)   return data:byte(pos) end

local function s8(data, pos)
    local v = data:byte(pos)
    return v >= 128 and v - 256 or v
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

-- ── RLE decompressor ─────────────────────────────────────────────
-- Format: pairs of (count, value). BUDA marker ends block + 1 extra pixel.

local function decompress_rle(data)
    local result = {}
    local n = 0
    local pos = 1
    local len = #data
    local last_value = 0
    while pos + 1 <= len do
        local count = data:byte(pos)
        local value = data:byte(pos + 1)
        last_value = value
        for _ = 1, count do n = n + 1; result[n] = value end
        pos = pos + 2
        if pos + 3 <= len then
            if data:byte(pos) == 0x42 and data:byte(pos+1) == 0x55
               and data:byte(pos+2) == 0x44 and data:byte(pos+3) == 0x41 then
                n = n + 1; result[n] = last_value
                break
            end
        end
    end
    return result, n
end

-- ── Palette helper ───────────────────────────────────────────────

local function read_room_palette(f, dir_data)
    local pal_off = u32le(dir_data, 11 * 8 + 1)
    local pal_raw = file_read(f, pal_off, 768)
    local palette = {}
    for i = 0, 255 do
        palette[i*3+1] = math.min((pal_raw and pal_raw:byte(i*3+1) or 0) * 4, 255)
        palette[i*3+2] = math.min((pal_raw and pal_raw:byte(i*3+2) or 0) * 4, 255)
        palette[i*3+3] = math.min((pal_raw and pal_raw:byte(i*3+3) or 0) * 4, 255)
    end
    return palette
end

-- ── Parse sprite headers from pair10 data ───────────────────────
-- Returns list (index >= 2 only) of {idx, x, y, w, h, total, seqs={...}}

local function parse_sprite_headers(pair10_data)
    if not pair10_data or #pair10_data < 7 then return {} end
    local sprite_count = u8(pair10_data, 6)   -- offset 0x05, 1-indexed = 6
    if sprite_count < 3 then return {} end

    local sprites = {}
    local HEADER_SIZE = 44
    local base_off = 7   -- pair10 byte 0x06 is Lua index 7

    for i = 0, sprite_count - 1 do
        local b = base_off + i * HEADER_SIZE
        if b + HEADER_SIZE > #pair10_data + 1 then break end

        local w = u8(pair10_data, b + 0x0E)
        local h = u8(pair10_data, b + 0x0F)
        if w == 0 or h == 0 or w > 320 or h > 200 then goto next_sprite end

        -- Per-sequence frame counts (12 possible sequences at +0x14)
        local seqs = {}
        for s = 0, 11 do
            local cnt = u8(pair10_data, b + 0x14 + s)
            if cnt > 0 then seqs[#seqs + 1] = cnt else break end
        end

        local total = u8(pair10_data, b + 0x12)
        -- Fallback: if no seq breakdown found, treat as single sequence
        if #seqs == 0 and total > 0 then seqs = { total } end

        local actual_total = 0
        for _, c in ipairs(seqs) do actual_total = actual_total + c end
        if actual_total == 0 then actual_total = total end
        if actual_total == 0 or actual_total > 100 then goto next_sprite end

        sprites[#sprites + 1] = {
            idx   = i,
            x     = u16le(pair10_data, b + 0x0A),
            y     = u16le(pair10_data, b + 0x0C),
            w     = w,
            h     = h,
            total = actual_total,
            seqs  = seqs,
        }
        ::next_sprite::
    end
    return sprites
end

-- ── Room name table ──────────────────────────────────────────────

local ROOM_NAMES = {
    [0]  = "Intro/Title",
    [1]  = "Alfred's House - Exterior",
    [2]  = "Alfred's House - Interior",
    [3]  = "Street",
    [4]  = "Park",
    [5]  = "Library - Exterior",
    [6]  = "Library - Interior",
    [7]  = "Museum - Exterior",
}

-- ── Detection ────────────────────────────────────────────────────

function engine.detect(game_path)
    return file_exists(game_path .. "/ALFRED.1")
       and file_exists(game_path .. "/JUEGO.EXE")
end

-- ── Resource tree ────────────────────────────────────────────────
-- Room-centric: each room node contains Background, Palette, Text, Sprites

function engine.get_resources(game_path)
    local resources = {}
    local f = file_open(game_path .. "/ALFRED.1")

    for room = 0, 55 do
        local dir_data = file_read(f, room * 104, 104)
        if not dir_data or #dir_data < 104 then break end

        -- Validate palette (pair 11 must be exactly 768 bytes)
        local pal_off  = u32le(dir_data, 11 * 8 + 1)
        local pal_size = u32le(dir_data, 11 * 8 + 5)
        if pal_off == 0 or pal_size ~= 0x300 then goto continue end

        local label = ROOM_NAMES[room] or ("Room " .. room)
        local room_node = {
            id       = "room_" .. room,
            name     = string.format("Room %02d - %s", room, label),
            type     = "category",
            children = {}
        }

        -- Background (pair 0 offset)
        local bg_off  = u32le(dir_data, 1)
        local bg_size = u32le(dir_data, 5)
        if bg_off > 0 and bg_size > 0 then
            room_node.children[#room_node.children + 1] = {
                id = "bg_" .. room, name = "Background", type = "image"
            }
        end

        -- Palette
        room_node.children[#room_node.children + 1] = {
            id = "pal_" .. room, name = "Palette", type = "image"
        }

        -- Text (pair 12)
        local txt_off  = u32le(dir_data, 12 * 8 + 1)
        local txt_size = u32le(dir_data, 12 * 8 + 5)
        if txt_off > 0 and txt_size > 0 then
            room_node.children[#room_node.children + 1] = {
                id = "txt_" .. room, name = "Text", type = "text"
            }
        end

        -- Sprites (pair 10 headers + pair 8 pixels)
        local p10_off  = u32le(dir_data, 10 * 8 + 1)
        local p10_size = u32le(dir_data, 10 * 8 + 5)
        local p8_off   = u32le(dir_data, 8 * 8 + 1)
        local p8_size  = u32le(dir_data, 8 * 8 + 5)

        if p10_off > 0 and p10_size > 0 and p8_off > 0 and p8_size > 100 then
            local p10_head = file_read(f, p10_off, math.min(p10_size, 6 + 56 * 44))
            local all_sprites = parse_sprite_headers(p10_head)

            -- Filter to game sprites (skip system sprites 0 and 1)
            local game_sprites = {}
            for _, spr in ipairs(all_sprites) do
                if spr.idx >= 2 then game_sprites[#game_sprites + 1] = spr end
            end

            if #game_sprites > 0 then
                local anim_cat = {
                    id       = "anims_" .. room,
                    name     = string.format("Sprites (%d)", #game_sprites),
                    type     = "category",
                    children = {}
                }

                for _, spr in ipairs(game_sprites) do
                    local spr_node = {
                        id       = string.format("sprgrp_%d_%d", room, spr.idx),
                        name     = string.format("Spr %d  %dx%d", spr.idx, spr.w, spr.h),
                        type     = "category",
                        children = {}
                    }

                    if #spr.seqs > 0 then
                        for qi, qcount in ipairs(spr.seqs) do
                            spr_node.children[#spr_node.children + 1] = {
                                id   = string.format("spr_%d_%d_%d", room, spr.idx, qi - 1),
                                name = string.format("Anim %d (%d frame%s)", qi, qcount, qcount == 1 and "" or "s"),
                                type = "image"
                            }
                        end
                    else
                        spr_node.children[#spr_node.children + 1] = {
                            id   = string.format("spr_%d_%d_0", room, spr.idx),
                            name = string.format("Frames (%d)", spr.total),
                            type = "image"
                        }
                    end

                    anim_cat.children[#anim_cat.children + 1] = spr_node
                end

                room_node.children[#room_node.children + 1] = anim_cat
            end
        end

        resources[#resources + 1] = room_node
        ::continue::
    end

    file_close(f)
    return resources
end

-- ── Resource dispatcher ──────────────────────────────────────────

function engine.load_resource(game_path, resource_id)
    -- spr_ROOM_SPRIDX_SEQIDX
    local r, s, q = resource_id:match("^spr_(%d+)_(%d+)_(%d+)$")
    if r then
        return load_sprite_anim(game_path, tonumber(r), tonumber(s), tonumber(q))
    end

    local prefix, num_str = resource_id:match("^(%a+)_(%d+)$")
    local num = tonumber(num_str)
    if not prefix or not num then return nil end

    if prefix == "bg"  then return load_background(game_path, num)
    elseif prefix == "pal" then return load_palette_swatch(game_path, num)
    elseif prefix == "txt" then return load_room_text(game_path, num)
    end
    return nil
end

-- ── Background loader ─────────────────────────────────────────────

function load_background(game_path, room_num)
    local WIDTH, HEIGHT = 640, 400
    local f = file_open(game_path .. "/ALFRED.1")
    local dir_data = file_read(f, room_num * 104, 104)

    local pixels = {}
    local pixel_count = 0

    for pair = 0, 7 do
        local base = pair * 8 + 1
        local off  = u32le(dir_data, base)
        local size = u32le(dir_data, base + 4)
        if off > 0 and size > 0 then
            local block = file_read(f, off, size)
            if block then
                if size == 0x8000 or size == 0x6800 then
                    for i = 1, #block do
                        pixel_count = pixel_count + 1
                        pixels[pixel_count] = block:byte(i)
                    end
                else
                    local decoded, n = decompress_rle(block)
                    for i = 1, n do
                        pixel_count = pixel_count + 1
                        pixels[pixel_count] = decoded[i]
                    end
                end
            end
        end
    end

    local palette = read_room_palette(f, dir_data)
    file_close(f)

    local expected = WIDTH * HEIGHT
    while pixel_count < expected do
        pixel_count = pixel_count + 1; pixels[pixel_count] = 0
    end

    local img = image_create_indexed(WIDTH, HEIGHT, pixels, palette)
    return {
        type = "image", image = img,
        description = string.format("Room %d background - %dx%d, 256 colors", room_num, WIDTH, HEIGHT)
    }
end

-- ── Palette swatch ────────────────────────────────────────────────

function load_palette_swatch(game_path, room_num)
    local CELL, GRID = 16, 16
    local SIZE = CELL * GRID

    local f = file_open(game_path .. "/ALFRED.1")
    local dir_data = file_read(f, room_num * 104, 104)
    local palette = read_room_palette(f, dir_data)
    file_close(f)

    local rgb = {}; local n = 0
    for py = 0, SIZE - 1 do
        for px = 0, SIZE - 1 do
            local ci = math.floor(py / CELL) * GRID + math.floor(px / CELL)
            n=n+1; rgb[n] = palette[ci*3+1]
            n=n+1; rgb[n] = palette[ci*3+2]
            n=n+1; rgb[n] = palette[ci*3+3]
        end
    end
    local img = image_create_rgb(SIZE, SIZE, rgb)
    return {
        type = "image", image = img,
        description = string.format("Room %d palette - 256 colors (VGA 6-bit x4)", room_num)
    }
end

-- ── Room text loader ──────────────────────────────────────────────

function load_room_text(game_path, room_num)
    local f = file_open(game_path .. "/ALFRED.1")
    local dir_data = file_read(f, room_num * 104, 104)
    local txt_off  = u32le(dir_data, 12 * 8 + 1)
    local txt_size = u32le(dir_data, 12 * 8 + 5)
    if txt_off == 0 or txt_size == 0 then file_close(f); return nil end
    local raw = file_read(f, txt_off, txt_size)
    file_close(f)
    if not raw then return nil end

    local strings = {}; local current = {}; local str_idx = 1
    for i = 1, #raw do
        local b = raw:byte(i)
        if b == 0xFF or b == 0x00 then
            if #current > 0 then
                local s = table.concat(current)
                if #s > 0 then
                    strings[#strings + 1] = string.format("[%03d] %s", str_idx, s)
                    str_idx = str_idx + 1
                end
                current = {}
            end
        elseif b >= 0x20 and b < 0x80 then
            current[#current + 1] = string.char(b)
        elseif b >= 0x80 then
            current[#current + 1] = string.char(b)
        else
            current[#current + 1] = string.format("{0x%02X}", b)
        end
    end
    if #current > 0 then
        local s = table.concat(current)
        if #s > 0 then
            strings[#strings + 1] = string.format("[%03d] %s", str_idx, s)
        end
    end
    return {
        type = "text",
        text = table.concat(strings, "\n"),
        description = string.format("Room %d text - %d strings, %d bytes", room_num, #strings, txt_size)
    }
end

-- ── Sprite animation sheet ────────────────────────────────────────
-- Renders one animation sequence for a sprite as a horizontal sprite sheet.
-- resource_id = spr_ROOM_SPRIDX_SEQIDX

function load_sprite_anim(game_path, room_num, sprite_idx, seq_idx)
    local f = file_open(game_path .. "/ALFRED.1")
    local dir_data = file_read(f, room_num * 104, 104)

    local p10_off  = u32le(dir_data, 10 * 8 + 1)
    local p10_size = u32le(dir_data, 10 * 8 + 5)
    local p8_off   = u32le(dir_data, 8  * 8 + 1)
    local p8_size  = u32le(dir_data, 8  * 8 + 5)
    local palette  = read_room_palette(f, dir_data)

    if p10_off == 0 or p10_size == 0 or p8_off == 0 or p8_size == 0 then
        file_close(f); return nil
    end

    local p10_data = file_read(f, p10_off, p10_size)
    local p8_raw   = file_read(f, p8_off,  p8_size)
    file_close(f)
    if not p10_data or not p8_raw then return nil end

    -- Parse all sprite headers; collect only game sprites (idx >= 2)
    local all_sprites = parse_sprite_headers(p10_data)
    local sprites = {}
    for _, spr in ipairs(all_sprites) do
        if spr.idx >= 2 then sprites[#sprites + 1] = spr end
    end

    -- Decompress pair 8 pixel blob
    local pixel_data, _ = decompress_rle(p8_raw)

    -- Find target sprite; accumulate pixel offset for all preceding sprites
    local target_spr  = nil
    local pix_cursor  = 0
    for _, spr in ipairs(sprites) do
        if spr.idx == sprite_idx then target_spr = spr; break end
        pix_cursor = pix_cursor + spr.w * spr.h * spr.total
    end
    if not target_spr then return nil end

    -- Find frame start for requested sequence
    local frame_start = 0
    for s = 0, seq_idx - 1 do
        frame_start = frame_start + (target_spr.seqs[s + 1] or 0)
    end
    local num_frames = target_spr.seqs[seq_idx + 1] or target_spr.total
    if num_frames == 0 then num_frames = 1 end

    local w, h = target_spr.w, target_spr.h
    local sheet_w = w * num_frames
    local sheet_h = h

    -- Build row-interleaved sprite sheet (standard horizontal layout)
    local final_pixels = {}
    for row = 0, h - 1 do
        for frame = 0, num_frames - 1 do
            local frame_abs = frame_start + frame
            local src_base  = pix_cursor + frame_abs * w * h
            for col = 0, w - 1 do
                local dst = row * sheet_w + frame * w + col + 1
                local src = src_base + row * w + col + 1
                final_pixels[dst] = pixel_data[src] or 0
            end
        end
    end

    local img = image_create_indexed(sheet_w, sheet_h, final_pixels, palette)
    return {
        type = "image", image = img,
        description = string.format(
            "Room %d Spr%d Anim%d - %d frame%s @ %dx%d, sheet %dx%d",
            room_num, sprite_idx, seq_idx + 1,
            num_frames, num_frames == 1 and "" or "s",
            w, h, sheet_w, sheet_h
        )
    }
end

return engine

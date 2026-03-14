-- ============================================================================
-- Adventure Explorer - Engine Script: Alfred Pelrock (1997, DOS)
-- ============================================================================
-- Reads ALFRED.1 (room backgrounds, palettes, text)
-- Format: 56 rooms × 13 data pairs (offset+size), each pair is 8 bytes
--   Pairs 0-7:  Background blocks (RLE compressed or raw)
--   Pair  8:    Sprite pixel data
--   Pair  9:    Room objects
--   Pair  10:   Room data (hotspots, walkboxes, exits, sprites)
--   Pair  11:   Palette (768 bytes, VGA 6-bit)
--   Pair  12:   Text data
-- ============================================================================

local engine = {}

engine.name = "Alfred Pelrock"
engine.id = "pelrock"
engine.description = "Alfred Pelrock (1997, DOS point-and-click adventure)"
engine.version = "1.0"

-- ── Binary helpers (1-indexed positions) ────────────────────────

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

-- ── RLE decompression ───────────────────────────────────────────
-- Format: pairs of (count, value) as bytes
-- Special: BUDA marker (0x42 0x55 0x44 0x41) signals end + one extra pixel

local function decompress_rle_block(data)
    local result = {}
    local n = 0
    local pos = 1
    local len = #data
    local last_value = 0

    while pos + 1 <= len do
        local count = data:byte(pos)
        local value = data:byte(pos + 1)
        last_value = value

        for i = 1, count do
            n = n + 1
            result[n] = value
        end

        pos = pos + 2

        -- Check for BUDA end marker
        if pos + 3 <= len then
            if data:byte(pos) == 0x42 and data:byte(pos+1) == 0x55
               and data:byte(pos+2) == 0x44 and data:byte(pos+3) == 0x41 then
                -- Game writes one final pixel after BUDA
                n = n + 1
                result[n] = last_value
                break
            end
        end
    end

    return result, n
end

-- ── Game detection ──────────────────────────────────────────────

function engine.detect(game_path)
    return file_exists(game_path .. "/ALFRED.1")
       and file_exists(game_path .. "/JUEGO.EXE")
end

-- ── Resource tree ───────────────────────────────────────────────

function engine.get_resources(game_path)
    local resources = {}

    -- Category: Room Backgrounds
    local backgrounds = {
        id = "backgrounds",
        name = "Room Backgrounds",
        type = "category",
        children = {}
    }

    -- Category: Room Palettes
    local palettes = {
        id = "palettes",
        name = "Room Palettes",
        type = "category",
        children = {}
    }

    -- Category: Room Text
    local texts = {
        id = "texts",
        name = "Room Text",
        type = "category",
        children = {}
    }

    local f = file_open(game_path .. "/ALFRED.1")

    -- Room names (known rooms in Alfred Pelrock)
    local room_names = {
        [0]  = "Intro/Title",
        [1]  = "Alfred's House - Exterior",
        [2]  = "Alfred's House - Interior",
        [3]  = "Street",
        [4]  = "Park",
        [5]  = "Library - Exterior",
        [6]  = "Library - Interior",
        [7]  = "Museum - Exterior",
    }

    for room = 0, 55 do
        local dir_offset = room * 104  -- 13 pairs × 8 bytes
        local dir_data = file_read(f, dir_offset, 104)

        if dir_data and #dir_data == 104 then
            -- Check first background block (pair 0)
            local bg_offset = u32le(dir_data, 1)
            local bg_size   = u32le(dir_data, 5)

            -- Check palette (pair 11)
            local pal_offset = u32le(dir_data, 11 * 8 + 1)
            local pal_size   = u32le(dir_data, 11 * 8 + 5)

            -- Check text (pair 12)
            local txt_offset = u32le(dir_data, 12 * 8 + 1)
            local txt_size   = u32le(dir_data, 12 * 8 + 5)

            local label = room_names[room] or ("Room " .. room)
            local display = string.format("Room %02d - %s", room, label)

            -- Add background if valid
            if bg_offset > 0 and bg_size > 0 and pal_size == 0x300 then
                backgrounds.children[#backgrounds.children + 1] = {
                    id = "bg_" .. room,
                    name = display,
                    type = "image"
                }
            end

            -- Add palette if valid
            if pal_offset > 0 and pal_size == 0x300 then
                palettes.children[#palettes.children + 1] = {
                    id = "pal_" .. room,
                    name = display,
                    type = "image"
                }
            end

            -- Add text if valid
            if txt_offset > 0 and txt_size > 0 then
                texts.children[#texts.children + 1] = {
                    id = "txt_" .. room,
                    name = display,
                    type = "text"
                }
            end
        end
    end

    file_close(f)

    resources[#resources + 1] = backgrounds
    resources[#resources + 1] = palettes
    resources[#resources + 1] = texts

    return resources
end

-- ── Resource loading ────────────────────────────────────────────

function engine.load_resource(game_path, resource_id)
    local prefix, num = resource_id:match("^(%a+)_(%d+)$")
    num = tonumber(num)

    if not prefix or not num then
        log_warn("Unknown resource ID: " .. resource_id)
        return nil
    end

    if prefix == "bg" then
        return load_background(game_path, num)
    elseif prefix == "pal" then
        return load_palette_swatch(game_path, num)
    elseif prefix == "txt" then
        return load_room_text(game_path, num)
    end

    return nil
end

-- ── Background loader ───────────────────────────────────────────

function load_background(game_path, room_num)
    local WIDTH = 640
    local HEIGHT = 400
    local EXPECTED = WIDTH * HEIGHT

    local f = file_open(game_path .. "/ALFRED.1")
    local dir_data = file_read(f, room_num * 104, 104)

    -- Decompress and combine 8 background blocks
    local pixels = {}
    local pixel_count = 0

    for pair = 0, 7 do
        local base = pair * 8 + 1  -- 1-indexed into dir_data
        local offset = u32le(dir_data, base)
        local size   = u32le(dir_data, base + 4)

        if offset > 0 and size > 0 then
            local block_data = file_read(f, offset, size)

            if block_data then
                if size == 0x8000 or size == 0x6800 then
                    -- Uncompressed block: copy bytes directly
                    for i = 1, #block_data do
                        pixel_count = pixel_count + 1
                        pixels[pixel_count] = block_data:byte(i)
                    end
                else
                    -- RLE compressed block
                    local decoded, count = decompress_rle_block(block_data)
                    for i = 1, count do
                        pixel_count = pixel_count + 1
                        pixels[pixel_count] = decoded[i]
                    end
                end
            end
        end
    end

    -- Read palette (pair 11): 768 bytes, VGA 6-bit (0-63)
    local pal_offset = u32le(dir_data, 11 * 8 + 1)
    local pal_raw = file_read(f, pal_offset, 768)

    file_close(f)

    -- Convert VGA 6-bit palette to 8-bit (multiply by 4)
    local palette = {}
    for i = 0, 255 do
        local r = math.min(pal_raw:byte(i * 3 + 1) * 4, 255)
        local g = math.min(pal_raw:byte(i * 3 + 2) * 4, 255)
        local b = math.min(pal_raw:byte(i * 3 + 3) * 4, 255)
        palette[i * 3 + 1] = r
        palette[i * 3 + 2] = g
        palette[i * 3 + 3] = b
    end

    -- Pad pixel data to expected size
    while pixel_count < EXPECTED do
        pixel_count = pixel_count + 1
        pixels[pixel_count] = 0
    end

    -- Create indexed image via the API
    local img = image_create_indexed(WIDTH, HEIGHT, pixels, palette)

    return {
        type = "image",
        image = img,
        width = WIDTH,
        height = HEIGHT,
        description = string.format(
            "Room %d background — %dx%d, 256 colors, %d bytes decoded",
            room_num, WIDTH, HEIGHT, pixel_count
        )
    }
end

-- ── Palette swatch renderer ─────────────────────────────────────
-- Renders the 256-color palette as a 16×16 grid of colored squares

function load_palette_swatch(game_path, room_num)
    local SWATCH_SIZE = 16   -- pixels per color cell
    local GRID = 16          -- 16×16 grid = 256 colors
    local IMG_SIZE = SWATCH_SIZE * GRID  -- 256×256 px

    local f = file_open(game_path .. "/ALFRED.1")
    local dir_data = file_read(f, room_num * 104, 104)

    local pal_offset = u32le(dir_data, 11 * 8 + 1)
    local pal_raw = file_read(f, pal_offset, 768)
    file_close(f)

    if not pal_raw or #pal_raw < 768 then
        return nil
    end

    -- Build RGB table for a swatch image
    local rgb = {}
    local n = 0
    for py = 0, IMG_SIZE - 1 do
        for px = 0, IMG_SIZE - 1 do
            local cx = math.floor(px / SWATCH_SIZE)
            local cy = math.floor(py / SWATCH_SIZE)
            local color_idx = cy * GRID + cx

            local r = math.min(pal_raw:byte(color_idx * 3 + 1) * 4, 255)
            local g = math.min(pal_raw:byte(color_idx * 3 + 2) * 4, 255)
            local b = math.min(pal_raw:byte(color_idx * 3 + 3) * 4, 255)

            n = n + 1; rgb[n] = r
            n = n + 1; rgb[n] = g
            n = n + 1; rgb[n] = b
        end
    end

    local img = image_create_rgb(IMG_SIZE, IMG_SIZE, rgb)

    return {
        type = "image",
        image = img,
        width = IMG_SIZE,
        height = IMG_SIZE,
        description = string.format(
            "Room %d palette — 256 colors (VGA 6-bit, scaled ×4)",
            room_num
        )
    }
end

-- ── Room text loader ────────────────────────────────────────────
-- Reads the text data from pair 12 and formats it as readable text.
-- Text uses 0xFF as string separator and may contain control codes.

function load_room_text(game_path, room_num)
    local f = file_open(game_path .. "/ALFRED.1")
    local dir_data = file_read(f, room_num * 104, 104)

    local txt_offset = u32le(dir_data, 12 * 8 + 1)
    local txt_size   = u32le(dir_data, 12 * 8 + 5)

    if txt_offset == 0 or txt_size == 0 then
        file_close(f)
        return nil
    end

    local raw = file_read(f, txt_offset, txt_size)
    file_close(f)

    if not raw then return nil end

    -- Parse text: split on 0xFF separators, filter control codes
    local strings = {}
    local current = {}
    local str_idx = 1

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
            -- Printable ASCII
            current[#current + 1] = string.char(b)
        elseif b >= 0x80 and b <= 0xFF then
            -- Extended ASCII (CP437 / Latin-1 range) - pass through
            current[#current + 1] = string.char(b)
        else
            -- Control code - show as placeholder
            current[#current + 1] = string.format("{0x%02X}", b)
        end
    end

    -- Flush last string
    if #current > 0 then
        local s = table.concat(current)
        if #s > 0 then
            strings[#strings + 1] = string.format("[%03d] %s", str_idx, s)
        end
    end

    local text = table.concat(strings, "\n")

    return {
        type = "text",
        text = text,
        description = string.format(
            "Room %d text — %d strings, %d bytes raw",
            room_num, #strings, txt_size
        )
    }
end

return engine

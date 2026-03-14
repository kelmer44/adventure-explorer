-- ============================================================================
-- Adventure Explorer - Engine Script: Trick or Treat (TOT engine, 1997, DOS)
-- ============================================================================
-- Reads flat DAT files: BITMAPS.DAT, PANTALLA.DAT, PALETAS.DAT, OBJETOS.DAT,
-- CONVERSA.TXT
--
-- Image format: uint16le width-1, uint16le height-1, then raw 8-bit pixels
-- Palette: 768 bytes (256 x RGB), 6-bit VGA values (shift left 2)
-- Room record: 10856 bytes per room in PANTALLA.DAT (8 save variants; use 1st)
-- Object record: 279 bytes per object in OBJETOS.DAT
-- ============================================================================

local engine = {}

engine.name = "Trick or Treat"
engine.id = "tot"
engine.description = "Trick or Treat (1997, DOS point-and-click adventure)"
engine.version = "1.0"

-- ── Binary helpers ──────────────────────────────────────────────

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

-- Read a Pascal string: first byte = length, then chars
local function pascal_string(data, pos, max_len)
    local len = u8(data, pos)
    if len > max_len then len = max_len end
    local chars = {}
    for i = 1, len do
        local b = data:byte(pos + i)
        if b and b >= 0x20 and b < 0x80 then
            chars[#chars + 1] = string.char(b)
        end
    end
    return table.concat(chars)
end

-- ── Constants ───────────────────────────────────────────────────

local ROOM_RECORD_SIZE = 10856     -- bytes per room in PANTALLA.DAT
local ROOM_VARIANTS = 8           -- save-game variants per room
local OBJECT_RECORD_SIZE = 279    -- bytes per object in OBJETOS.DAT
local PALETTE_SIZE = 768          -- 256 colors x 3 bytes

-- ── Detection ───────────────────────────────────────────────────

function engine.detect(game_path)
    -- Trick or Treat requires BITMAPS.DAT and PANTALLA.DAT at minimum
    return file_exists(game_path .. "/BITMAPS.DAT")
       and file_exists(game_path .. "/PANTALLA.DAT")
       and file_exists(game_path .. "/PALETAS.DAT")
       and (file_exists(game_path .. "/TOT.EXE")
            or file_exists(game_path .. "/ANIMA.EXE")
            or file_exists(game_path .. "/OBJETOS.DAT"))
end

-- ── Resource tree ───────────────────────────────────────────────

function engine.get_resources(game_path)
    local resources = {}

    -- Count rooms from PANTALLA.DAT file size
    local f = file_open(game_path .. "/PANTALLA.DAT")
    local total_size = file_size(f)
    local total_rooms = math.floor(total_size / ROOM_RECORD_SIZE)
    file_close(f)

    -- Count objects from OBJETOS.DAT
    local num_objects = 0
    if file_exists(game_path .. "/OBJETOS.DAT") then
        local fo = file_open(game_path .. "/OBJETOS.DAT")
        local obj_size = file_size(fo)
        num_objects = math.floor(obj_size / OBJECT_RECORD_SIZE)
        file_close(fo)
    end

    log_info(string.format("TOT: Found %d rooms, %d objects", total_rooms, num_objects))

    -- ── Room Backgrounds category ──
    local backgrounds = {
        id = "backgrounds",
        name = "Room Backgrounds",
        type = "category",
        children = {}
    }

    -- Scan all rooms for valid backgrounds
    local f_pant = file_open(game_path .. "/PANTALLA.DAT")
    for room = 0, total_rooms - 1 do
        local room_offset = room * ROOM_RECORD_SIZE
        local header = file_read(f_pant, room_offset, 10)
        if header and #header >= 8 then
            local room_code = u16le(header, 1)
            local img_ptr = u32le(header, 3)
            local img_size = u16le(header, 7)

            if img_ptr > 0 and img_size > 4 then
                backgrounds.children[#backgrounds.children + 1] = {
                    id = "bg_" .. room,
                    name = string.format("Room %02d (code %d)", room, room_code),
                    type = "image"
                }
            end
        end
    end
    file_close(f_pant)

    -- ── Room Palettes category ──
    local palettes = {
        id = "palettes",
        name = "Room Palettes",
        type = "category",
        children = {}
    }

    local f_pant2 = file_open(game_path .. "/PANTALLA.DAT")
    local seen_pals = {}
    for room = 0, total_rooms - 1 do
        local room_offset = room * ROOM_RECORD_SIZE
        -- palettePointer is at offset +9022 within each room record
        local pal_area = file_read(f_pant2, room_offset + 9022, 2)
        if pal_area and #pal_area >= 2 then
            local pal_idx = u16le(pal_area, 1)
            local key = tostring(pal_idx)
            if not seen_pals[key] then
                seen_pals[key] = true
                palettes.children[#palettes.children + 1] = {
                    id = "pal_" .. room,
                    name = string.format("Room %02d Palette (index %d)", room, pal_idx),
                    type = "image"
                }
            else
                palettes.children[#palettes.children + 1] = {
                    id = "pal_" .. room,
                    name = string.format("Room %02d Palette (index %d, shared)", room, pal_idx),
                    type = "image"
                }
            end
        end
    end
    file_close(f_pant2)

    -- ── Objects category ──
    local objects = {
        id = "objects",
        name = "Objects",
        type = "category",
        children = {}
    }

    if num_objects > 0 then
        local fo = file_open(game_path .. "/OBJETOS.DAT")
        for obj = 0, num_objects - 1 do
            local obj_offset = obj * OBJECT_RECORD_SIZE
            local obj_data = file_read(fo, obj_offset, 57)
            if obj_data and #obj_data >= 57 then
                local code = u16le(obj_data, 1)
                local name = pascal_string(obj_data, 4, 20)
                local bmp_ptr = u32le(obj_data, 52)
                local bmp_size = u16le(obj_data, 56)

                if bmp_ptr > 0 and bmp_size > 4 and #name > 0 then
                    objects.children[#objects.children + 1] = {
                        id = "obj_" .. obj,
                        name = string.format("%s (code %d)", name, code),
                        type = "image"
                    }
                end
            end
        end
        file_close(fo)
    end

    -- ── Conversation Text category ──
    local texts = {
        id = "texts",
        name = "Conversation Text",
        type = "category",
        children = {}
    }

    if file_exists(game_path .. "/CONVERSA.TXT") then
        local ft = file_open(game_path .. "/CONVERSA.TXT")
        local txt_total = file_size(ft)
        local num_entries = math.floor(txt_total / 263)
        file_close(ft)

        -- Group text in batches of 50
        local batch_size = 50
        for batch_start = 0, num_entries - 1, batch_size do
            local batch_end = math.min(batch_start + batch_size - 1, num_entries - 1)
            texts.children[#texts.children + 1] = {
                id = "txt_" .. batch_start .. "_" .. batch_end,
                name = string.format("Text entries %d-%d", batch_start, batch_end),
                type = "text"
            }
        end

        log_info(string.format("TOT: Found %d conversation entries", num_entries))
    end

    resources[#resources + 1] = backgrounds
    resources[#resources + 1] = palettes
    resources[#resources + 1] = objects
    resources[#resources + 1] = texts

    return resources
end

-- ── Resource loading ────────────────────────────────────────────

function engine.load_resource(game_path, resource_id)
    -- Parse resource ID
    local prefix, arg1, arg2 = resource_id:match("^(%a+)_(.+)$")

    if prefix == "bg" then
        return load_room_background(game_path, tonumber(arg1))
    elseif prefix == "pal" then
        return load_room_palette(game_path, tonumber(arg1))
    elseif prefix == "obj" then
        return load_object_image(game_path, tonumber(arg1))
    elseif prefix == "txt" then
        local start, finish = arg1:match("^(%d+)_(%d+)$")
        if start and finish then
            return load_conversation_text(game_path, tonumber(start), tonumber(finish))
        end
    end

    return nil
end

-- ── Load room background ────────────────────────────────────────

function load_room_background(game_path, room_num)
    -- Read room record from PANTALLA.DAT
    local f_pant = file_open(game_path .. "/PANTALLA.DAT")
    local room_offset = room_num * ROOM_RECORD_SIZE
    local header = file_read(f_pant, room_offset, 10)

    local room_code = u16le(header, 1)
    local img_ptr = u32le(header, 3)
    local img_size = u16le(header, 7)

    -- Read palette index
    local pal_area = file_read(f_pant, room_offset + 9022, 2)
    local pal_idx = u16le(pal_area, 1)
    file_close(f_pant)

    -- Read bitmap from BITMAPS.DAT
    local f_bmp = file_open(game_path .. "/BITMAPS.DAT")
    local bmp_data = file_read(f_bmp, img_ptr, img_size)
    file_close(f_bmp)

    if not bmp_data or #bmp_data < 5 then
        return nil
    end

    -- Decode image: width-1, height-1, then pixels
    local w = u16le(bmp_data, 1) + 1
    local h = u16le(bmp_data, 3) + 1

    local pixels = {}
    local pixel_count = 0
    for i = 5, math.min(#bmp_data, 4 + w * h) do
        pixel_count = pixel_count + 1
        pixels[pixel_count] = bmp_data:byte(i)
    end

    -- Pad if needed
    while pixel_count < w * h do
        pixel_count = pixel_count + 1
        pixels[pixel_count] = 0
    end

    -- Read palette from PALETAS.DAT
    local palette = load_vga_palette(game_path, pal_idx)
    if not palette then
        -- Fallback: greyscale palette
        palette = {}
        for i = 0, 255 do
            palette[i * 3 + 1] = i
            palette[i * 3 + 2] = i
            palette[i * 3 + 3] = i
        end
    end

    local img = image_create_indexed(w, h, pixels, palette)

    return {
        type = "image",
        image = img,
        width = w,
        height = h,
        description = string.format(
            "Room %d (code %d) — %dx%d, palette index %d",
            room_num, room_code, w, h, pal_idx
        )
    }
end

-- ── Load room palette as swatch ─────────────────────────────────

function load_room_palette(game_path, room_num)
    local f_pant = file_open(game_path .. "/PANTALLA.DAT")
    local pal_area = file_read(f_pant, room_num * ROOM_RECORD_SIZE + 9022, 2)
    local pal_idx = u16le(pal_area, 1)
    file_close(f_pant)

    local palette = load_vga_palette(game_path, pal_idx)
    if not palette then return nil end

    -- Render 16x16 swatch grid (256 colors), 16px per cell = 256x256
    local CELL = 16
    local GRID = 16
    local SIZE = CELL * GRID

    local rgb = {}
    local n = 0
    for py = 0, SIZE - 1 do
        for px = 0, SIZE - 1 do
            local cx = math.floor(px / CELL)
            local cy = math.floor(py / CELL)
            local ci = cy * GRID + cx

            n = n + 1; rgb[n] = palette[ci * 3 + 1]
            n = n + 1; rgb[n] = palette[ci * 3 + 2]
            n = n + 1; rgb[n] = palette[ci * 3 + 3]
        end
    end

    local img = image_create_rgb(SIZE, SIZE, rgb)

    return {
        type = "image",
        image = img,
        width = SIZE,
        height = SIZE,
        description = string.format("Room %d palette (index %d) — 256 colors, VGA 6-bit", room_num, pal_idx)
    }
end

-- ── Load object image ───────────────────────────────────────────

function load_object_image(game_path, obj_num)
    local fo = file_open(game_path .. "/OBJETOS.DAT")
    local obj_data = file_read(fo, obj_num * OBJECT_RECORD_SIZE, 279)
    file_close(fo)

    if not obj_data or #obj_data < 57 then return nil end

    local code = u16le(obj_data, 1)
    local name = pascal_string(obj_data, 4, 20)
    local bmp_ptr = u32le(obj_data, 52)
    local bmp_size = u16le(obj_data, 56)

    if bmp_ptr == 0 or bmp_size <= 4 then return nil end

    -- Read bitmap
    local f_bmp = file_open(game_path .. "/BITMAPS.DAT")
    local bmp_data = file_read(f_bmp, bmp_ptr, bmp_size)
    file_close(f_bmp)

    if not bmp_data or #bmp_data < 5 then return nil end

    local w = u16le(bmp_data, 1) + 1
    local h = u16le(bmp_data, 3) + 1

    local pixels = {}
    local pixel_count = 0
    for i = 5, math.min(#bmp_data, 4 + w * h) do
        pixel_count = pixel_count + 1
        pixels[pixel_count] = bmp_data:byte(i)
    end
    while pixel_count < w * h do
        pixel_count = pixel_count + 1
        pixels[pixel_count] = 0
    end

    -- For objects, we don't know which room palette to use
    -- Use a default palette (greyscale) or try palette index 0
    local palette = load_vga_palette(game_path, 0)
    if not palette then
        palette = {}
        for i = 0, 255 do
            palette[i * 3 + 1] = i
            palette[i * 3 + 2] = i
            palette[i * 3 + 3] = i
        end
    end

    local img = image_create_indexed(w, h, pixels, palette)

    return {
        type = "image",
        image = img,
        width = w,
        height = h,
        description = string.format(
            "%s (code %d) — %dx%d pixels, bitmap at 0x%X",
            name, code, w, h, bmp_ptr
        )
    }
end

-- ── Load conversation text ──────────────────────────────────────

function load_conversation_text(game_path, start_idx, end_idx)
    local ft = file_open(game_path .. "/CONVERSA.TXT")
    local lines = {}

    for entry = start_idx, end_idx do
        local entry_data = file_read(ft, entry * 263, 263)
        if entry_data and #entry_data >= 256 then
            -- Pascal string: byte[0] = length, then up to 255 chars
            local len = u8(entry_data, 1)
            if len > 255 then len = 255 end
            local chars = {}
            for i = 1, len do
                local b = entry_data:byte(1 + i)
                if b and b >= 0x20 then
                    chars[#chars + 1] = string.char(b)
                end
            end
            local text = table.concat(chars)
            if #text > 0 then
                lines[#lines + 1] = string.format("[%03d] %s", entry, text)
            end
        end
    end

    file_close(ft)

    return {
        type = "text",
        text = table.concat(lines, "\n"),
        description = string.format(
            "Conversation entries %d-%d (%d entries)",
            start_idx, end_idx, #lines
        )
    }
end

-- ── Palette helper ──────────────────────────────────────────────

function load_vga_palette(game_path, pal_index)
    if not file_exists(game_path .. "/PALETAS.DAT") then return nil end

    local fp = file_open(game_path .. "/PALETAS.DAT")
    local pal_raw = file_read(fp, pal_index * PALETTE_SIZE, PALETTE_SIZE)
    file_close(fp)

    if not pal_raw or #pal_raw < PALETTE_SIZE then return nil end

    local palette = {}
    for i = 0, 255 do
        local r = math.min(pal_raw:byte(i * 3 + 1) * 4, 255)
        local g = math.min(pal_raw:byte(i * 3 + 2) * 4, 255)
        local b = math.min(pal_raw:byte(i * 3 + 3) * 4, 255)
        palette[i * 3 + 1] = r
        palette[i * 3 + 2] = g
        palette[i * 3 + 3] = b
    end

    return palette
end

return engine

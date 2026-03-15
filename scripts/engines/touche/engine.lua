-- ============================================================================
-- Adventure Explorer - Engine Script: Touche: Adventures of the Fifth Musketeer
-- ============================================================================
-- Single data file: touche.dat
-- Header offset tables at fixed positions for rooms, sprites, sounds, etc.
-- Background: per-scanline RLE (PCX-style)
-- Palette: 768 bytes embedded in RoomInfo resource
-- ============================================================================

local engine = {}
engine.name        = "Touche: Adventures of the Fifth Musketeer"
engine.id          = "touche"
engine.description = "Touche: Adventures of the Fifth Musketeer (1995, Clipper Multimedia)"
engine.version     = "1.0"

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end

-- Header offset table positions in touche.dat
local OFF_ROOM_IMAGE = 0x048   -- 100 entries
local OFF_ROOM_INFO  = 0x6B0   -- 80 entries
local NUM_ROOMS      = 80

-- PCX-style RLE: 0xC0+ = run, else literal
local function decompress_rle_scanline(data, pos, width)
    local pixels = {}
    local n = 0
    local len = #data
    while n < width and pos <= len do
        local code = data:byte(pos)
        pos = pos + 1
        if (code >= 0xC0) then
            local count = code - 0xC0
            if count == 0 then count = 1 end
            local color = 0
            if pos <= len then color = data:byte(pos); pos = pos + 1 end
            for _ = 1, count do
                if n >= width then break end
                n = n + 1
                pixels[n] = color
            end
        else
            n = n + 1
            pixels[n] = code
        end
    end
    -- Pad remainder with 0 if scanline incomplete
    while n < width do n = n + 1; pixels[n] = 0 end
    return pixels, pos
end

function engine.detect(game_path)
    return file_exists(game_path .. "/TOUCHE.DAT")
        or file_exists(game_path .. "/touche.dat")
end

function engine.get_resources(game_path)
    local resources = {}
    local f = file_open(game_path .. "/TOUCHE.DAT")

    local rooms_cat = {
        id       = "rooms",
        name     = "Rooms",
        type     = "category",
        children = {}
    }

    for room = 0, NUM_ROOMS - 1 do
        -- Read room info offset
        local info_ptr_data = file_read(f, OFF_ROOM_INFO + room * 4, 4)
        if not info_ptr_data or #info_ptr_data < 4 then goto continue end
        local info_off = u32le(info_ptr_data, 1)
        if info_off == 0 then goto continue end

        -- Read room info: skip 2, read roomImageNum
        local info_head = file_read(f, info_off, 4)
        if not info_head or #info_head < 4 then goto continue end
        local img_num = u16le(info_head, 3)

        -- Read room image offset to verify it exists
        local img_ptr_data = file_read(f, OFF_ROOM_IMAGE + img_num * 4, 4)
        if not img_ptr_data or #img_ptr_data < 4 then goto continue end
        local img_off = u32le(img_ptr_data, 1)
        if img_off == 0 then goto continue end

        local room_node = {
            id       = "room_" .. room,
            name     = string.format("Room %d (img %d)", room, img_num),
            type     = "category",
            children = {}
        }

        room_node.children[#room_node.children + 1] = {
            id = "bg_" .. room, name = "Background", type = "image"
        }
        room_node.children[#room_node.children + 1] = {
            id = "pal_" .. room, name = "Palette", type = "image"
        }

        rooms_cat.children[#rooms_cat.children + 1] = room_node
        ::continue::
    end

    rooms_cat.name = string.format("Rooms (%d)", #rooms_cat.children)
    resources[#resources + 1] = rooms_cat

    file_close(f)
    return resources
end

function engine.load_resource(game_path, resource_id)
    local prefix, num_str = resource_id:match("^(%a+)_(%d+)$")
    local num = tonumber(num_str)
    if not prefix or not num then return nil end

    if prefix == "bg"  then return load_background(game_path, num) end
    if prefix == "pal" then return load_palette_swatch(game_path, num) end
    return nil
end

function load_background(game_path, room_num)
    local f = file_open(game_path .. "/TOUCHE.DAT")

    -- Read room info
    local info_ptr_data = file_read(f, OFF_ROOM_INFO + room_num * 4, 4)
    local info_off = u32le(info_ptr_data, 1)

    local info_head = file_read(f, info_off, 4)
    local img_num = u16le(info_head, 3)

    -- Read palette from room info: skip 2 + 2(imgnum) + 2 = 6 bytes, then 768
    local pal_raw = file_read(f, info_off + 6, 768)

    -- Read room image offset
    local img_ptr_data = file_read(f, OFF_ROOM_IMAGE + img_num * 4, 4)
    local img_off = u32le(img_ptr_data, 1)

    -- Read image header
    local img_head = file_read(f, img_off, 4)
    local w = u16le(img_head, 1)
    local h = u16le(img_head, 3)

    if w == 0 or h == 0 or w > 2000 or h > 1000 then
        file_close(f)
        return nil
    end

    -- Read image data (estimate: at most w*h + some overhead for RLE)
    local max_read = w * h + 16384
    local img_data = file_read(f, img_off + 4, max_read)
    file_close(f)

    if not img_data then return nil end

    -- Decompress RLE scanlines
    local pixels = {}
    local pix_count = 0
    local data_pos = 1

    for row = 0, h - 1 do
        local scanline
        scanline, data_pos = decompress_rle_scanline(img_data, data_pos, w)
        for _, px in ipairs(scanline) do
            pix_count = pix_count + 1
            pixels[pix_count] = px
        end
    end

    -- Build palette
    local palette = {}
    for i = 0, 255 do
        palette[i*3+1] = pal_raw and pal_raw:byte(i*3+1) or 0
        palette[i*3+2] = pal_raw and pal_raw:byte(i*3+2) or 0
        palette[i*3+3] = pal_raw and pal_raw:byte(i*3+3) or 0
    end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image", image = img,
        description = string.format("Room %d - %dx%d, 256 colors", room_num, w, h)
    }
end

function load_palette_swatch(game_path, room_num)
    local f = file_open(game_path .. "/TOUCHE.DAT")
    local info_ptr_data = file_read(f, OFF_ROOM_INFO + room_num * 4, 4)
    local info_off = u32le(info_ptr_data, 1)
    local pal_raw = file_read(f, info_off + 6, 768)
    file_close(f)

    if not pal_raw or #pal_raw < 768 then return nil end

    local CELL, GRID = 16, 16
    local SIZE = CELL * GRID
    local rgb = {}; local n = 0

    for py = 0, SIZE - 1 do
        for px = 0, SIZE - 1 do
            local ci = math.floor(py / CELL) * GRID + math.floor(px / CELL)
            n=n+1; rgb[n] = pal_raw:byte(ci*3+1) or 0
            n=n+1; rgb[n] = pal_raw:byte(ci*3+2) or 0
            n=n+1; rgb[n] = pal_raw:byte(ci*3+3) or 0
        end
    end

    local img = image_create_rgb(SIZE, SIZE, rgb)
    return {
        type = "image", image = img,
        description = string.format("Room %d palette - 256 colors", room_num)
    }
end

return engine

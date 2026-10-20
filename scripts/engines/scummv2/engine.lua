-- SCUMM enhanced V2: Maniac Mansion / Zak McKracken (DOS EGA).
-- Layouts verified against local ScummVM resource_v2.cpp, object.cpp, gfx.cpp.
-- Room images and objects are whole column-RLE bitmaps, followed by mask RLE.
local engine = { name = "SCUMM V2", id = "scummv2", version = "1.1",
    description = "SCUMM V2 (Maniac Mansion, Zak McKracken, 1988-1989)" }

local function u16le(data, pos)
    if not data or pos < 1 or pos + 1 > #data then return nil end
    return data:byte(pos) + data:byte(pos + 1) * 256
end
local function read_file(path)
    local f = file_open(path)
    if not f then return nil end
    local data = file_read(f, 0, file_size(f))
    file_close(f)
    if not data then return nil end
    return (data:gsub(".", function(c) return string.char(255 - c:byte()) end))
end
local function is_v2_lfl(game_path)
    local data = read_file(game_path .. "/00.LFL")
    if not data or u16le(data, 1) ~= 0x0100 then return false end
    if not file_exists(game_path .. "/01.LFL") then return false end
    -- Unlike V3 old bundles, the global object table is one byte per object.
    local p = 5 + u16le(data, 3)
    for _ = 1, 4 do
        local n = data:byte(p)
        if not n or n == 255 or p + n * 3 > #data then return false end
        p = p + 1 + n * 3
    end
    return p == #data + 1
end

local EGA_PALETTE = {
    -- R    G    B
       0,   0,   0,    -- 0  Black
       0,   0, 170,    -- 1  Blue
       0, 170,   0,    -- 2  Green
       0, 170, 170,    -- 3  Cyan
     170,   0,   0,    -- 4  Red
     170,   0, 170,    -- 5  Magenta
     170,  85,   0,    -- 6  Brown
     170, 170, 170,    -- 7  Light Gray
      85,  85,  85,    -- 8  Dark Gray
      85,  85, 255,    -- 9  Bright Blue
      85, 255,  85,    -- 10 Bright Green
      85, 255, 255,    -- 11 Bright Cyan
     255,  85,  85,    -- 12 Bright Red
     255,  85, 255,    -- 13 Bright Magenta
     255, 255,  85,    -- 14 Yellow
     255, 255, 255,    -- 15 White
}

-- Build a 256-entry palette table (entries 0-15 are EGA, rest black)
local function make_ega_palette()
    local pal = {}
    for i = 0, 255 do
        pal[i * 3 + 1] = 0
        pal[i * 3 + 2] = 0
        pal[i * 3 + 3] = 0
    end
    for i = 0, 15 do
        pal[i * 3 + 1] = EGA_PALETTE[i * 3 + 1]
        pal[i * 3 + 2] = EGA_PALETTE[i * 3 + 2]
        pal[i * 3 + 3] = EGA_PALETTE[i * 3 + 3]
    end
    return pal
end

local function parse_v2_room(data)
    if not data or #data < 28 then return nil end
    local size, width, height, offset = u16le(data, 1), u16le(data, 5), u16le(data, 7), u16le(data, 11)
    local count = data:byte(21)
    if size < 28 + count * 4 or size > #data or width < 8 or width > 2048
        or width % 8 ~= 0 or height < 1 or height > 128
        or offset < 28 + count * 4 or offset >= size then return nil end
    return { width = width, height = height, im00_offs = offset, total_size = size, count = count }
end

-- Returns the position immediately after the bitmap, where mask RLE starts.
-- Runs persist across columns; dither copies the previous column at the same y.
local function decode_v2_bitmap(data, pos, width, height)
    if width < 1 or width > 2048 or height < 1 or height > 128 or pos < 1 then return nil end
    local pixels, previous = {}, {}
    for y = 0, height - 1 do previous[y] = 0 end
    local run, color, dither = 0, 0, false
    for x = 0, width - 1 do
        for y = 0, height - 1 do
            if run == 0 then
                local b = data:byte(pos); pos = pos + 1
                if not b then return nil end
                dither = b >= 128
                run = dither and b % 128 or math.floor(b / 16)
                color = b % 16
                if run == 0 then run = data:byte(pos); pos = pos + 1 end
                if not run or run == 0 then return nil end
            end
            if not dither then previous[y] = color end
            pixels[y * width + x + 1] = previous[y]
            run = run - 1
        end
    end
    return pixels, pos
end

-- One mask byte covers eight horizontal pixels, high bit on the left; the
-- stream walks down each eight-pixel column before advancing to the next.
local function decode_v2_mask(data, pos, width, height)
    if width < 8 or width > 2048 or width % 8 ~= 0 or height < 1 or height > 128 then return nil end
    local pixels, written, target = {}, 0, width / 8 * height
    while written < target do
        local b = data:byte(pos); pos = pos + 1
        if not b or b % 128 == 0 then return nil end
        local run, repeated = b % 128, b >= 128
        local value
        if repeated then value = data:byte(pos); pos = pos + 1 end
        for _ = 1, math.min(run, target - written) do
            if not repeated then value = data:byte(pos); pos = pos + 1 end
            if not value then return nil end
            local x, y = math.floor(written / height) * 8, written % height
            for bit = 0, 7 do
                pixels[y * width + x + bit + 1] = math.floor(value / 2^(7 - bit)) % 2
            end
            written = written + 1
        end
    end
    return pixels, pos
end

local CP850 = { "Ç", "ü", "é", "â", "ä", "à", "å", "ç", "ê", "ë", "è", "ï", "î", "ì", "Ä", "Å", "É", "æ", "Æ", "ô", "ö", "ò", "û", "ù", "ÿ", "Ö", "Ü", "ø", "£", "Ø", "×", "ƒ", "á", "í", "ó", "ú", "ñ", "Ñ", "ª", "º", "¿", "®", "¬", "½", "¼", "¡", "«", "»", "░", "▒", "▓", "│", "┤", "Á", "Â", "À", "©", "╣", "║", "╗", "╝", "¢", "¥", "┐", "└", "┴", "┬", "├", "─", "┼", "ã", "Ã", "╚", "╔", "╩", "╦", "╠", "═", "╬", "¤", "ð", "Ð", "Ê", "Ë", "È", "ı", "Í", "Î", "Ï", "┘", "┌", "█", "▄", "¦", "Ì", "▀", "Ó", "ß", "Ô", "Ò", "õ", "Õ", "µ", "þ", "Þ", "Ú", "Û", "Ù", "ý", "Ý", "¯", "´", "­", "±", "‗", "¾", "¶", "§", "÷", "¸", "°", "¨", "·", "¹", "³", "²", "■", " " }
local function dos_text(data)
    return (data:gsub("[\128-\255]", function(c) return CP850[c:byte() - 127] end))
end
local function room_objects(data, room)
    local result, image_end = {}, room.total_size
    for i = 0, room.count - 1 do
        local code = u16le(data, 29 + room.count * 2 + i * 2)
        if not code or code < 28 + room.count * 4 or code + 15 > room.total_size then return nil end
        image_end = math.min(image_end, code)
    end
    for i = 0, room.count - 1 do
        local image = u16le(data, 29 + i * 2)
        local code = u16le(data, 29 + room.count * 2 + i * 2)
        local size = u16le(data, code + 1)
        if size < 15 or code + size > room.total_size then return nil end
        local name_offset = data:byte(code + 15)
        local name = ""
        if name_offset >= 15 and name_offset < size then
            name = data:sub(code + name_offset + 1, code + size):match("^([^%z]*)")
        end
        result[#result + 1] = { index = i, id = u16le(data, code + 5), name = dos_text(name),
            x = data:byte(code + 8) * 8, y = data:byte(code + 9) % 128 * 8,
            width = data:byte(code + 10) * 8, height = math.floor(data:byte(code + 14) / 8) * 8,
            parent = data:byte(code + 11), walk_x = data:byte(code + 12) * 8,
            walk_y = data:byte(code + 13) % 32 * 8, direction = data:byte(code + 14) % 8,
            image = image, image_end = image_end }
    end
    return result
end

local function object_pixels(data, obj)
    if obj.image < 1 or obj.image >= obj.image_end then return nil end
    local block = data:sub(obj.image + 1, obj.image_end)
    local pixels, pos = decode_v2_bitmap(block, 1, obj.width, obj.height)
    if not pixels then return nil end
    -- Non-drawing hotspots can share arbitrary offsets. Only offer pictures
    -- whose bitmap AND accompanying mask decode within the image section.
    local mask = decode_v2_mask(block, pos, obj.width, obj.height)
    if not mask then return nil end
    return pixels, mask
end

local function load_room(game_path, id)
    local raw = read_file(string.format("%s/%02d.LFL", game_path, id))
    local room = parse_v2_room(raw)
    if not room then return nil end
    -- An LFL may append global scripts/costumes/sounds after its room block.
    return raw:sub(1, room.total_size), room
end
local function room_files(game_path)
    local result, seen = {}, {}
    for _, name in ipairs(list_files(game_path) or {}) do
        local id = tonumber(name:upper():match("^(%d+)%.LFL$"))
        if id and id > 0 and not seen[id] then result[#result + 1] = id; seen[id] = true end
    end
    table.sort(result)
    return result
end
local function object_label(obj)
    return string.format("#%d %s (%dx%d)", obj.id, obj.name ~= "" and obj.name or "unnamed", obj.width, obj.height)
end
local function mask_palette()
    local pal = {}; for i = 1, 768 do pal[i] = 0 end
    pal[4], pal[5], pal[6] = 255, 255, 255
    return pal
end
local function swatch()
    local pixels = {}
    for y = 0, 255 do for x = 0, 255 do
        pixels[y * 256 + x + 1] = math.floor(y / 16) * 16 + math.floor(x / 16)
    end end
    return image_create_indexed(256, 256, pixels, make_ega_palette())
end
local function image_result(pixels, width, height, description, mask)
    if not pixels then return { type = "text", text = "Invalid or truncated " .. description } end
    return { type = "image", image = image_create_indexed(width, height, pixels,
        mask and mask_palette() or make_ega_palette()),
        palette_image = not mask and swatch() or nil, palette_colors = mask and 2 or 16,
        description = description }
end

function engine.detect(game_path) return is_v2_lfl(game_path) end
function engine.get_resources(game_path)
    if not engine.detect(game_path) then return {} end
    local rooms = { id = "rooms", name = "Room Backgrounds", type = "category", children = {} }
    local objects = { id = "objects", name = "Object Sprites", type = "category", children = {} }
    local masks = { id = "masks", name = "Occlusion Masks", type = "category", children = {} }
    local text = { id = "room_info", name = "Room and Object Data", type = "category", children = {} }
    for _, id in ipairs(room_files(game_path)) do
        local data, room = load_room(game_path, id)
        local entries = room and room_objects(data, room)
        if entries then
            rooms.children[#rooms.children + 1] = { id = "room_" .. id, type = "image",
                name = string.format("Room %d (%dx%d)", id, room.width, room.height) }
            text.children[#text.children + 1] = { id = "info_" .. id, type = "text", name = "Room " .. id }
            local bank = { id = "objects_" .. id, name = "Room " .. id, type = "category", children = {} }
            local mask_bank = { id = "masks_" .. id, name = "Room " .. id, type = "category", children = {
                { id = "mask_" .. id, name = "Room mask", type = "image" } } }
            for _, obj in ipairs(entries) do
                if object_pixels(data, obj) then
                    bank.children[#bank.children + 1] = { id = "obj_" .. id .. "_" .. obj.index,
                        name = object_label(obj), type = "image" }
                    mask_bank.children[#mask_bank.children + 1] = { id = "objmask_" .. id .. "_" .. obj.index,
                        name = object_label(obj), type = "image" }
                end
            end
            if #bank.children > 0 then objects.children[#objects.children + 1] = bank end
            masks.children[#masks.children + 1] = mask_bank
        end
    end
    local result = {}
    for _, cat in ipairs({rooms, objects, masks, text}) do
        if #cat.children > 0 then result[#result + 1] = cat end
    end
    result[#result + 1] = { id = "palettes", name = "Palettes", type = "category", children = {
        { id = "pal_ega", name = "IBM EGA (16 colours)", type = "palette" } } }
    return result
end

function engine.load_resource(game_path, resource_id, palette_id)
    if resource_id == "pal_ega" then return { type = "image", image = swatch(), palette_colors = 16, description = "IBM EGA palette" } end
    if palette_id and palette_id ~= "pal_ega" then return { type = "text", text = "Unknown palette: " .. palette_id } end
    local kind, id, index = resource_id:match("^(%a+)_(%d+)_(%d+)$")
    if not kind then kind, id = resource_id:match("^(%a+)_(%d+)$") end
    if not id or (kind ~= "room" and kind ~= "mask" and kind ~= "info" and kind ~= "obj" and kind ~= "objmask") then return nil end
    local data, room = load_room(game_path, tonumber(id))
    if not room then return { type = "text", text = "Invalid or missing room " .. id } end
    local objects = room_objects(data, room)
    if not objects then return { type = "text", text = "Invalid room object table " .. id } end
    if kind == "info" then
        local lines = { string.format("Room %s: %dx%d, %d bytes, %d object records", id, room.width,
            room.height, room.total_size, #objects), "Coordinates are room pixels. Image-less hotspots are included.", "" }
        for _, obj in ipairs(objects) do
            lines[#lines + 1] = string.format("%s\n  position=%d,%d walk=%d,%d direction=%d parentIndex=%d imageOffset=0x%04X",
                object_label(obj), obj.x, obj.y, obj.walk_x, obj.walk_y, obj.direction, obj.parent, obj.image)
        end
        return { type = "text", text = table.concat(lines, "\n"), description = "Room " .. id .. " object names and geometry" }
    end
    if kind == "obj" or kind == "objmask" then
        local obj = index and objects[tonumber(index) + 1]
        if not obj then return nil end
        local px, mask = object_pixels(data, obj)
        return image_result(kind == "objmask" and mask or px, obj.width, obj.height,
            "Room " .. id .. " " .. object_label(obj) .. (kind == "objmask" and " occlusion mask" or ""), kind == "objmask")
    end
    if index then return nil end
    local pixels, pos = decode_v2_bitmap(data, room.im00_offs + 1, room.width, room.height)
    if kind == "mask" then pixels = pos and decode_v2_mask(data, pos, room.width, room.height) end
    return image_result(pixels, room.width, room.height,
        "Room " .. id .. (kind == "mask" and " occlusion mask" or " - EGA 16-colour, SCUMM V2"), kind == "mask")
end

return engine

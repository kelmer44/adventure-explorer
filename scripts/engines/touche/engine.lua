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
            id = "pal_" .. room, name = "Palette", type = "palette"
        }

        rooms_cat.children[#rooms_cat.children + 1] = room_node
        ::continue::
    end

    rooms_cat.name = string.format("Rooms (%d)", #rooms_cat.children)
    resources[#resources + 1] = rooms_cat

    file_close(f)
    for _, node in ipairs(engine.extra_resources(game_path)) do resources[#resources + 1] = node end
    return resources
end

function engine.load_resource(game_path, resource_id, palette_id)
    if resource_id:match("^tx_") then return engine.load_extra(game_path, resource_id, palette_id) end
    local prefix, num_str = resource_id:match("^(%a+)_(%d+)$")
    local num = tonumber(num_str)
    if not prefix or not num then return nil end

    if prefix == "bg"  then
        local pal_room = num  -- default: own palette
        if palette_id and palette_id ~= "" then
            local _, pnum_str = palette_id:match("^(%a+)_(%d+)$")
            if pnum_str then pal_room = tonumber(pnum_str) end
        end
        return load_background(game_path, num, pal_room)
    end
    if prefix == "pal" then return load_palette_swatch(game_path, num) end
    return nil
end

function load_background(game_path, room_num, pal_room_num)
    local f = file_open(game_path .. "/TOUCHE.DAT")

    -- Read room info
    local info_ptr_data = file_read(f, OFF_ROOM_INFO + room_num * 4, 4)
    local info_off = u32le(info_ptr_data, 1)

    local info_head = file_read(f, info_off, 4)
    local img_num = u16le(info_head, 3)

    -- Read palette from the palette room (may differ from the bg room)
    local pal_info_off = info_off
    if pal_room_num and pal_room_num ~= room_num then
        local pal_ptr = file_read(f, OFF_ROOM_INFO + pal_room_num * 4, 4)
        if pal_ptr then pal_info_off = u32le(pal_ptr, 1) end
    end
    local pal_raw = file_read(f, pal_info_off + 6, 768)

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

-- ============================================================================
-- Sprites, icons, sounds, music, text and speech
-- References (ScummVM engines/touche): resource.cpp (resource table offsets,
-- res_loadSprite, res_loadImage, res_loadImageHelper, res_loadSound,
-- res_loadSpeechSegment, res_decodeProgramData), touche.cpp (getString,
-- startMusic).
-- ============================================================================

local TABLES = {
    sprite = { base = 0x2A0, count = 50 }, icon = { base = 0x390, count = 100 },
    program = { base = 0x908, count = 150 }, music = { base = 0xB60, count = 50 },
    sound = { base = 0xC28, count = 120 },
}

local function dat_path(game_path)
    for _, n in ipairs({ "TOUCHE.DAT", "touche.dat" }) do
        if file_exists(game_path .. "/" .. n) then return game_path .. "/" .. n end
    end
end

-- Offsets of every resource of a type: entry n's data runs to entry n + 1.
-- Entries past the end of the file (the music table starts with one) are empty.
local function entries(f, kind)
    local t = TABLES[kind]
    local raw = file_read(f, t.base, (t.count + 1) * 4)
    local size = file_size(f)
    local out = {}
    for n = 0, t.count - 1 do
        local a, b = u32le(raw, 1 + n * 4), u32le(raw, 5 + n * 4)
        if a > 0 and a < size and b > a and b <= size then out[#out + 1] = { num = n, offset = a, size = b - a } end
    end
    return out
end

local function read_entry(game_path, kind, num)
    local f = file_open(dat_path(game_path) or "")
    if not f then return nil end
    local data
    for _, e in ipairs(entries(f, kind)) do
        if e.num == num then data = file_read(f, e.offset, e.size); break end
    end
    file_close(f)
    return data
end

local CP437 = { 0xC7, 0xFC, 0xE9, 0xE2, 0xE4, 0xE0, 0xE5, 0xE7, 0xEA, 0xEB, 0xE8, 0xEF, 0xEE, 0xEC, 0xC4, 0xC5,
    0xC9, 0xE6, 0xC6, 0xF4, 0xF6, 0xF2, 0xFB, 0xF9, 0xFF, 0xD6, 0xDC, 0xA2, 0xA3, 0xA5, 0x20A7, 0x192,
    0xE1, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xAA, 0xBA, 0xBF, 0x2310, 0xAC, 0xBD, 0xBC, 0xA1, 0xAB, 0xBB }
local function to_utf8(str)
    return (str:gsub("[\128-\255]", function(c)
        local cp = CP437[c:byte() - 0x7F] or 0xFFFD
        if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end))
end

-- Program text: u32 at +4 points at a table of u32 string offsets (relative to
-- the table); the table ends where the first string starts.
local function program_strings(prog)
    if not prog or #prog < 8 then return nil end
    local tp = u32le(prog, 5)
    if tp + 4 > #prog then return nil end
    local first = #prog - tp
    local i = 0
    while i * 4 < first do
        local o = u32le(prog, tp + 1 + i * 4)
        if o > 0 and o < first then first = o end
        i = i + 1
    end
    local out = {}
    for n = 0, math.floor(first / 4) - 1 do
        local o = u32le(prog, tp + 1 + n * 4)
        out[n] = (o > 0 and tp + o < #prog) and to_utf8(prog:match("^[^%z]*", tp + o + 1)) or ""
    end
    return out, math.floor(first / 4)
end

-- Speech files V<n>: (offset, size) pairs up to the first clip, each clip a VOC.
local function speech_clips(path)
    local f = file_open(path)
    if not f then return nil end
    local head = file_read(f, 0, 8)
    local first = head and u32le(head, 1) or 0
    local clips = {}
    if first >= 8 and first <= 0x10000 then
        local t = file_read(f, 0, first)
        for i = 0, first / 8 - 1 do
            local o, n = u32le(t, 1 + i * 8), u32le(t, 5 + i * 8)
            if n > 0 then clips[#clips + 1] = { index = i, offset = o, size = n } end
        end
    end
    file_close(f)
    return clips
end

local function speech_files(game_path)
    local out = {}
    for _, name in ipairs(list_files(game_path) or {}) do
        local n = tonumber(name:match("^[Vv](%d+)$") or "")
        if n then out[#out + 1] = { num = n, name = name } end
    end
    table.sort(out, function(a, b) return a.num < b.num end)
    return out
end

function engine.extra_resources(game_path)
    local out = {}
    local f = file_open(dat_path(game_path) or "")
    if f then
        local function cat(kind, title, leaf_type, label)
            local leaves = {}
            for _, e in ipairs(entries(f, kind)) do
                leaves[#leaves + 1] = { id = string.format("tx_%s_%d", kind, e.num), name = string.format("%s %d", label, e.num), type = leaf_type }
            end
            if #leaves > 0 then out[#out + 1] = { id = "tx_cat_" .. kind, name = string.format("%s (%d)", title, #leaves), type = "category", children = leaves } end
        end
        cat("sprite", "Sprite sheets", "image", "Sprite")
        cat("icon", "Icons and objects", "image", "Icon")
        cat("sound", "Sound effects", "sound", "Sound")
        cat("music", "Music (MIDI)", "midi", "Track")
        cat("program", "Text (room programs)", "text", "Program")
        file_close(f)
    end
    local voices = {}
    for _, sf in ipairs(speech_files(game_path)) do
        local clips = speech_clips(game_path .. "/" .. sf.name) or {}
        local leaves = {}
        for _, c in ipairs(clips) do
            leaves[#leaves + 1] = { id = string.format("tx_speech_%s_%d", sf.name, c.index), name = string.format("Line %d", c.index), type = "sound" }
        end
        if #leaves > 0 then voices[#voices + 1] = { id = "tx_speechfile_" .. sf.name, name = string.format("%s (%d)", sf.name, #leaves), type = "category", children = leaves } end
    end
    if #voices > 0 then out[#out + 1] = { id = "tx_cat_speech", name = "Speech", type = "category", children = voices } end
    return out
end

local function room_palette(game_path, palette_id)
    local room = tonumber((palette_id or ""):match("^pal_(%d+)$") or "")
    local f = file_open(dat_path(game_path) or "")
    if not f then return nil end
    local pal
    for r = room or 0, room or (NUM_ROOMS - 1) do
        local ptr = file_read(f, OFF_ROOM_INFO + r * 4, 4)
        local off = ptr and u32le(ptr, 1) or 0
        if off > 0 then
            local raw = file_read(f, off + 6, 768)
            if raw and #raw == 768 then
                pal = {}
                for i = 1, 768 do pal[i] = raw:byte(i) end
                break
            end
        end
    end
    file_close(f)
    return pal
end

-- Sprites and icons: u16 width, u16 height, RLE rows. res_loadImageHelper
-- takes the frame size from the first 64/255 marker in the top row and left
-- column, and moves colours 1-63 to 193-255 (the character part of the room
-- palette); everything else, including the markers, is transparent. The whole
-- sheet is returned with the frame size.
local function decode_image(data)
    if not data or #data < 4 then return nil end
    local w, h = u16le(data, 1), u16le(data, 3)
    if w == 0 or h == 0 or w > 2000 or h > 1000 then return nil end
    local px, pos = {}, 5
    for _ = 1, h do
        local row
        row, pos = decompress_rle_scanline(data, pos, w)
        for x = 1, w do px[#px + 1] = row[x] or 0 end
    end
    local fh, fw = h, w
    for y = 0, h - 1 do local c = px[y * w + 1]; if c == 64 or c == 255 then fh = y; break end end
    for x = 0, w - 1 do local c = px[x + 1]; if c == 64 or c == 255 then fw = x; break end end
    for i = 1, w * h do
        local c = px[i]
        px[i] = (c ~= 0 and c < 64) and c + 192 or 256
    end
    return px, w, h, fw, fh
end

function engine.load_extra(game_path, resource_id, palette_id)
    local file, clip = resource_id:match("^tx_speech_(.+)_(%d+)$")
    if file then
        for _, c in ipairs(speech_clips(game_path .. "/" .. file) or {}) do
            if c.index == tonumber(clip) then
                local f = file_open(game_path .. "/" .. file)
                local d = f and file_read(f, c.offset, c.size)
                if f then file_close(f) end
                local snd = d and sound_create_encoded(d)
                return snd and { type = "sound", sound = snd, description = string.format("%s line %s — VOC speech", file, clip) }
            end
        end
        return nil
    end
    local kind, num = resource_id:match("^tx_(%a+)_(%d+)$")
    num = tonumber(num)
    local data = kind and read_entry(game_path, kind, num)
    if not data then return nil end
    if kind == "sound" then
        local snd = sound_create_encoded(data)
        return snd and { type = "sound", sound = snd, description = string.format("Sound %d — VOC", num) }
    elseif kind == "music" then
        return { type = "midi", midi = midi_create_raw(data), description = string.format("Track %d — MIDI", num) }
    elseif kind == "program" then
        local strings, count = program_strings(data)
        if not strings then return nil end
        local lines = {}
        for n = 0, count - 1 do if strings[n] ~= "" then lines[#lines + 1] = string.format("%4d  %s", n, strings[n]) end end
        return { type = "text", text = table.concat(lines, "\n"), description = string.format("Program %d — %d strings", num, #lines) }
    elseif kind == "sprite" or kind == "icon" then
        local px, w, h, fw, fh = decode_image(data)
        if not px then return nil end
        local pal = room_palette(game_path, palette_id) or {}
        return { type = "image", image = image_create_indexed(w, h, px, pal, 256),
            description = string.format("%s %d — %dx%d, %dx%d frames (colours from the selected room palette)",
                kind == "sprite" and "Sprite sheet" or "Icon", num, w, h, fw, fh) }
    end
end

return engine

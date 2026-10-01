-- ============================================================================
-- Adventure Explorer - Engine Script: Drascula (1996, DOS)
-- ============================================================================
-- Drascula: The Vampire Strikes Back (DRE computing / Digital Dreams).
-- Supported by ScummVM's `drascula` engine (engines/drascula).
--
-- Data files (unpacked release):
--   NN.ALG   320x200 indexed picture: 128-byte header, RLE body, 256*3 palette
--   NN.ALD   room description, one ASCII value per line, whole file inverted
--   NN.ALS   sound
--   NN.CAL   screenplay
--   *.ALG    named surfaces (character sheets, cutscene art)
--   *.BIN    engine data / script tables
--
-- A room's background is NN.ALG where NN is the room number declared on the
-- first line of NN.ALD. Interactive objects are rectangles of that background,
-- listed in the .ALD; there are no separate sprite files.
-- ============================================================================

local engine = {}
engine.name        = "Drascula"
engine.id          = "drascula"
engine.description = "Drascula: The Vampire Strikes Back (1996)"
engine.version     = "1.0"

local band = bit32.band

local SCREEN_W, SCREEN_H = 320, 200
local PIC_HEADER  = 128        -- zero bytes at the head of every .ALG
local PAL_BYTES   = 768        -- 256 * 3, at the tail of every .ALG
local MIN_ROOMS   = 3          -- .ALD files needed to accept a folder

-- ── File listing (case-insensitive) ────────────────────────────────────────

local function list_dir(game_path)
    local names = {}
    for _, n in ipairs(list_files(game_path)) do names[#names + 1] = n end
    table.sort(names)
    return names
end

-- Map "UPPERCASE" -> real filename, mirroring the host's case-insensitive
-- lookup so scripts can spell names as the game does ("14.ald", "AUX1.ALG").
local function name_map(game_path)
    local map = {}
    for _, n in ipairs(list_dir(game_path)) do
        map[n:upper()] = n
    end
    return map
end

local function read_all(path)
    local f = file_open(path)
    if not f then return nil end
    local sz = file_size(f)
    local data = sz and sz > 0 and file_read(f, 0, sz) or nil
    file_close(f)
    return data
end

-- ── .ALG pictures ──────────────────────────────────────────────────────────

-- run-length body: a byte with both top bits set is a run header whose low
-- six bits count the pixels and whose colour is the following byte; any other
-- byte is a literal pixel. Pixels fill the screen row by row.
local function decode_rle(src, w, h)
    local total = w * h
    local px = {}
    local si, di = 1, 0
    local n = #src

    while di < total and si <= n do
        local control = src:byte(si)
        si = si + 1

        local pixel, run
        if band(control, 192) == 192 then
            run = band(control, 63)
            if si > n then break end
            pixel = src:byte(si)
            si = si + 1
        else
            pixel = control
            run = 1
        end

        for _ = 1, run do
            di = di + 1
            if di > total then break end
            px[di] = pixel
        end
    end

    return px
end

-- .ALG: [0,128) header | [128, size-768) RLE | tail 256*3 RGB palette
local function decode_alg(path)
    local data = read_all(path)
    if not data then return nil end
    local size = #data
    if size < PIC_HEADER + PAL_BYTES + 1 then return nil end

    local body_end = size - PAL_BYTES
    if body_end <= PIC_HEADER then return nil end

    local px = decode_rle(data:sub(PIC_HEADER + 1, body_end), SCREEN_W, SCREEN_H)
    if #px < SCREEN_W * SCREEN_H then return nil end

    local palette = {}
    for i = 0, 255 do
        local p = body_end + 1 + i * 3
        local r = data:byte(p) or 0
        local g = data:byte(p + 1) or 0
        local b = data:byte(p + 2) or 0
        palette[i * 3 + 1] = r
        palette[i * 3 + 2] = g
        palette[i * 3 + 3] = b
    end

    return { width = SCREEN_W, height = SCREEN_H, pixels = px, palette = palette }
end

-- ── .ALD room descriptions ────────────────────────────────────────────────
-- The whole file is bit-inverted; TextResourceParser::getLine reads ~byte,
-- drops CR, and ends a line on LF.

local function invert(str)
    local bytes = {}
    for i = 1, #str do
        bytes[i] = string.char(band(255 - str:byte(i), 255))
    end
    return table.concat(bytes)
end

local function read_ald_lines(path)
    local data = read_all(path)
    if not data then return nil end
    local lines = {}
    for raw in (invert(data) .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw:gsub("\r", "")
        -- getLine skips lines that hold nothing but terminators
        if line:find("%S") then lines[#lines + 1] = line end
    end
    return lines
end

-- Read one room description. The layout differs by chapter:
--   header 4  roomNumber, music, surface, paletteLevel       (plain rooms)
--   header 5  + overriddenWidth == 0                          (chapter 2)
--   header 13 + overriddenWidth, curHeight, feetHeight, stepX, stepY,
--             front surface, extra surface, unused, back surface
-- ... followed by the object list, the walk rectangle, and — outside chapter
-- 2 — upperLimit/lowerLimit. Rather than hard-code a chapter table we try each
-- layout and keep the one that consumes the file exactly.
local function parse_ald(lines)
    local best

    for _, hdr in ipairs({ 4, 5, 13 }) do
        for _, trail in ipairs({ 0, 2 }) do
            local i = 0
            local bad = false
            local function int()
                if bad then return nil end
                i = i + 1
                local v = tonumber(lines[i])
                if not v then bad = true; return nil end
                return v
            end
            local function str()
                if bad then return nil end
                i = i + 1
                local v = lines[i]
                if not v then bad = true; return nil end
                return v
            end

            local room = int()
            int()                       -- music
            local surface = str()       -- aux surface layered over the room
            int()                       -- palette level

            if hdr == 5 then
                if int() ~= 0 then bad = true end
            elseif hdr == 13 then
                if int() == 0 then
                    bad = true
                else
                    for _ = 1, 4 do int() end
                    for _ = 1, 4 do str() end
                end
            end

            local nobj = 0
            if not bad then
                nobj = int()
                if not nobj or nobj < 0 or nobj > 200 then bad = true end
            end

            local objects = {}
            if not bad then
                for k = 1, nobj do
                    local num = int()
                    local name = str()
                    local x1, y1, x2, y2 = int(), int(), int(), int()
                    local px, py = int(), int()
                    int()               -- track
                    local visible = int()
                    local is_door = int()
                    if is_door == 1 then
                        for _ = 1, 5 do int() end
                    end
                    if bad then break end
                    objects[k] = {
                        num = num, name = name, visible = (visible == 1),
                        rect = { x1, y1, x2 - x1, y2 - y1 },
                        pos  = { px, py }
                    }
                end
            end

            if not bad then
                for _ = 1, 4 do int() end      -- walk rectangle
                for _ = 1, trail do int() end
            end

            if not bad and i == #lines then
                if best then return nil end   -- two layouts fit: stay honest
                best = {
                    room = room, surface = surface,
                    objects = objects, chapter2 = (hdr ~= 4)
                }
            end
        end
    end

    return best
end

-- ── Index ─────────────────────────────────────────────────────────────────

local index_cache = {}

local function build_index(game_path)
    local cached = index_cache[game_path]
    if cached then return cached end

    local map = name_map(game_path)
    local idx = { rooms = {}, sheets = {} }

    local ald_names, alg_ids = {}, {}
    for upper, real in pairs(map) do
        local id, ext = upper:match("^(%d+)%.ALG$")
        if id then
            alg_ids[tonumber(id)] = real
        else
            id = upper:match("^(%d+)%.ALD$")
            if id then ald_names[#ald_names + 1] = real end
        end
    end

    for _, name in ipairs(ald_names) do
        local lines = read_ald_lines(game_path .. "/" .. name)
        if lines then
            local room = parse_ald(lines)
            if room and alg_ids[room.room] then
                idx.rooms[#idx.rooms + 1] = room
            end
        end
    end
    table.sort(idx.rooms, function(a, b) return a.room < b.room end)

    -- Every other numbered .ALG is a standalone surface (character animation
    -- strips, cutscene art) rather than a navigable room background.
    local is_room = {}
    for _, r in ipairs(idx.rooms) do is_room[r.room] = true end
    for id, real in pairs(alg_ids) do
        if not is_room[id] then
            idx.sheets[#idx.sheets + 1] = { id = id, name = real }
        end
    end
    table.sort(idx.sheets, function(a, b) return a.id < b.id end)

    index_cache[game_path] = idx
    return idx
end

local function sheet_path(game_path, sheet)
    return game_path .. "/" .. sheet.name
end

-- Crop a rectangle out of a decoded 320x200 picture.
local function crop(src, x, y, w, h)
    if w <= 0 or h <= 0 then return nil end
    if x < 0 then w, x = w + x, 0 end
    if y < 0 then h, y = h + y, 0 end
    if x + w > src.width then w = src.width - x end
    if y + h > src.height then h = src.height - y end
    if w <= 0 or h <= 0 then return nil end

    local px = {}
    for row = 0, h - 1 do
        local base = y + row
        for col = 0, w - 1 do
            px[row * w + col + 1] = src.pixels[base * SCREEN_W + x + col + 1]
        end
    end
    return { width = w, height = h, pixels = px, palette = src.palette }
end

local function make_image(pic, description)
    return {
        type = "image",
        image = image_create_indexed(pic.width, pic.height, pic.pixels, pic.palette),
        width = pic.width,
        height = pic.height,
        description = description
    }
end

-- ── Detection ─────────────────────────────────────────────────────────────

local function detect(game_path)
    local map = name_map(game_path)
    local alds, algs = 0, 0
    for upper in pairs(map) do
        if upper:match("^%d+%.ALD$") then alds = alds + 1 end
        if upper:match("^%d+%.ALG$") then algs = algs + 1 end
    end
    if alds < MIN_ROOMS or algs < MIN_ROOMS then return false end

    -- The first room description inverts to a number, a number, a surface
    -- filename, then more numbers.
    local lines = read_ald_lines(game_path .. "/" .. map["14.ALD"])
    if not lines or #lines < 5 then return false end
    if not tonumber(lines[1]) or not tonumber(lines[2]) then return false end
    if not lines[3]:upper():match("%.ALG$") then return false end
    if not tonumber(lines[4]) or not tonumber(lines[5]) then return false end

    -- and a picture carries a zero header plus a trailing palette
    for upper, real in pairs(map) do
        if upper:match("^%d+%.ALG$") then
            return decode_alg(game_path .. "/" .. real) ~= nil
        end
    end
    return false
end

function engine.detect(game_path)
    return detect(game_path)
end

-- ── Resource tree ─────────────────────────────────────────────────────────

function engine.get_resources(game_path)
    if not detect(game_path) then return {} end
    local idx = build_index(game_path)
    if #idx.rooms == 0 then return {} end

    local tree = {}

    local rooms_cat = {
        id = "rooms",
        name = string.format("Rooms (%d)", #idx.rooms),
        type = "category", children = {}
    }

    for _, room in ipairs(idx.rooms) do
        local node = {
            id = string.format("room_%d", room.room),
            name = string.format("Room %d", room.room),
            type = "category", children = {}
        }
        node.children[#node.children + 1] = {
            id = string.format("bg:DRASCULA:%d", room.room),
            name = "Background",
            type = "image"
        }
        for k, obj in ipairs(room.objects) do
            local r = obj.rect
            if r[3] > 0 and r[4] > 0 then
                node.children[#node.children + 1] = {
                    id = string.format("obj:DRASCULA:%d:%d", room.room, k),
                    name = string.format("Object %d — %s (%dx%d)",
                        obj.num, obj.name, r[3], r[4]),
                    type = "image"
                }
            end
        end
        rooms_cat.children[#rooms_cat.children + 1] = node
    end
    tree[#tree + 1] = rooms_cat

    if #idx.sheets > 0 then
        local sheets_cat = {
            id = "sheets",
            name = string.format("Sheets (%d)", #idx.sheets),
            type = "category", children = {}
        }
        for _, sheet in ipairs(idx.sheets) do
            sheets_cat.children[#sheets_cat.children + 1] = {
                id = string.format("bg:DRASCULA:%d", sheet.id),
                name = string.format("Sheet %d", sheet.id),
                type = "image"
            }
        end
        tree[#tree + 1] = sheets_cat
    end

    return tree
end

-- ── Resource loading ──────────────────────────────────────────────────────

function engine.load_resource(game_path, resource_id, palette_id)
    -- Lua patterns have no `?` quantifier, so match the two shapes separately.
    local kind, room_str, obj_str
    local bg_room = resource_id:match("^bg:DRASCULA:(%d+)$")
    if bg_room then
        kind, room_str = "bg", bg_room
    else
        local room, obj = resource_id:match("^obj:DRASCULA:(%d+):(%d+)$")
        kind, room_str, obj_str = "obj", room, obj
    end
    if not kind then
        log_warn("Unknown Drascula resource ID: " .. resource_id)
        return nil
    end

    local idx = build_index(game_path)
    local room_id = tonumber(room_str)
    local pic

    if kind == "bg" then
        local map = name_map(game_path)
        local file = map[string.format("%d.ALG", room_id)]
        if not file then
            log_warn(string.format("No %d.ALG in Drascula folder", room_id))
            return nil
        end
        pic = decode_alg(game_path .. "/" .. file)
        if not pic then
            log_warn(string.format("Failed to decode %s", file))
            return nil
        end
        return make_image(pic, string.format(
            "%s — %dx%d, indexed, Drascula",
            file, pic.width, pic.height))
    end

    -- object sprite: the rectangle this object occupies in its room picture
    local obj_index = tonumber(obj_str)
    local room = nil
    for _, r in ipairs(idx.rooms) do
        if r.room == room_id then room = r end
    end
    if not room or not room.objects[obj_index] then
        log_warn(string.format("Room %d has no object %d", room_id, obj_index or -1))
        return nil
    end

    local bg = decode_alg(game_path .. "/" .. string.format("%d.ALG", room_id))
    if not bg then return nil end

    local obj = room.objects[obj_index]
    local r = obj.rect
    local sprite = crop(bg, r[1], r[2], r[3], r[4])
    if not sprite then return nil end

    return make_image(sprite, string.format(
        "Room %d object %d — %s (%dx%d), indexed, Drascula",
        room_id, obj.num, obj.name, sprite.width, sprite.height))
end

return engine
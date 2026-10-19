-- DOS SCUMM V4 EGA (Monkey Island): plaintext 000.LFL directory and
-- XOR-0x69 DISKnn.LEC archives. Sizes include the six-byte small header.
-- References: ScummVM resource_v4.cpp, resource.cpp, object.cpp, costume.cpp.
local U = require("scumm_util")
local EGA = require("scumm_v3")
local Cost = require("scumm_cost")
local V = {}
local W, D = U.u16le, U.u32le

local function read(path)
    local f = file_open(path)
    if not f then return nil end
    local d = file_read(f, 0, file_size(f))
    file_close(f)
    return d
end

-- Positions here are one-based string indices; archive offsets are zero-based.
local function blocks(d, first, last)
    local out, p = {}, first or 1
    last = last or #d
    while p <= last do
        if p + 5 > last then return nil end
        local size = D(d, p)
        if size < 6 or p + size - 1 > last then return nil end
        out[#out + 1] = { tag = d:sub(p + 4, p + 5), pos = p, size = size }
        p = p + size
    end
    return out
end

local function index(d)
    if not d then return nil end
    local bs = blocks(d)
    if not bs then return nil end
    local idx = { names = {} }
    local kinds = { ["0R"] = "rooms", ["0C"] = "costumes", ["0S"] = "scripts", ["0N"] = "sounds" }
    for _, b in ipairs(bs) do
        local kind = kinds[b.tag]
        if kind then
            local n = W(d, b.pos + 6)
            if idx[kind] or b.size ~= 8 + n * 5 or (kind == "rooms" and n > 256) then return nil end
            local entries = {}
            for id = 0, n - 1 do
                local p = b.pos + 8 + id * 5
                local room, offset = d:byte(p), D(d, p + 1)
                if room ~= 0 and offset ~= 0xffffffff then
                    entries[id] = { room = room, offset = offset }
                end
            end
            idx[kind] = entries
            if kind == "costumes" then idx.costume_count = n end
        elseif b.tag == "RN" then
            local p, last = b.pos + 6, b.pos + b.size - 1
            while p <= last and d:byte(p) ~= 0 do
                if p + 9 > last then return nil end
                idx.names[d:byte(p)] = xor_bytes(d:sub(p + 1, p + 9), "\255"):match("^[^%z]*")
                p = p + 10
            end
            if p ~= last or d:byte(p) ~= 0 then return nil end
        elseif b.tag == "0O" then
            if b.size ~= 8 + W(d, b.pos + 6) * 4 then return nil end
        else
            return nil
        end
    end
    if not idx.rooms or not idx.costumes or not idx.scripts or not idx.sounds then return nil end
    return idx
end

local cache
local function state(path)
    local raw = read(path .. "/000.LFL")
    if not raw then return nil end
    if cache and cache.path == path and cache.raw == raw then return cache end
    local idx = index(raw)
    if not idx then return nil end
    local s = { path = path, raw = raw, idx = idx, disks = {}, room_cache = {}, costume_cache = {} }
    cache = s
    return s
end

local function disk(s, number)
    if s.disks[number] ~= nil then return s.disks[number] or nil end
    s.disks[number] = false
    local raw = read(string.format("%s/DISK%02d.LEC", s.path, number))
    if not raw then return nil end
    local d = xor_bytes(raw, string.char(0x69))
    if #d < 13 or D(d, 1) ~= #d or d:sub(5, 6) ~= "LE" or d:sub(11, 12) ~= "FO"
        or D(d, 7) ~= 7 + d:byte(13) * 5 then return nil end
    local n, rooms = d:byte(13), {}
    if 13 + n * 5 > #d then return nil end
    for i = 0, n - 1 do
        local p = 14 + i * 5
        local id, offset = d:byte(p), D(d, p + 1)
        if offset + 8 > #d or d:sub(offset + 5, offset + 6) ~= "LF" then return nil end
        local size = D(d, offset + 1)
        if size < 8 or offset + size > #d then return nil end
        rooms[id] = { offset = offset, size = size }
    end
    local out = { data = d, rooms = rooms }
    s.disks[number] = out
    return out
end

local function resource(s, room, offset, tag)
    local entry = s.idx.rooms[room]
    local archive = entry and disk(s, entry.room)
    local r = archive and archive.rooms[room]
    if not r then return nil end
    -- V4 directory offsets include an eight-byte LF wrapper before the resource.
    local p = r.offset + (offset or 0) + 9
    local size = D(archive.data, p)
    if size < 6 or p + size - 1 > r.offset + r.size or archive.data:sub(p + 4, p + 5) ~= tag then return nil end
    return archive.data:sub(p, p + size - 1)
end

local function room(s, id)
    if s.room_cache[id] ~= nil then return s.room_cache[id] or nil end
    s.room_cache[id] = false
    local d = resource(s, id, 0, "RO")
    local bs = d and blocks(d, 7)
    if not bs then return nil end
    local hd, bm, objects, images = nil, nil, {}, {}
    for _, b in ipairs(bs) do
        if b.tag == "HD" and b.size >= 12 then hd = b
        elseif b.tag == "BM" then bm = b
        elseif b.tag == "PA" then return nil -- VGA palettes/strips need a different decoder.
        elseif b.tag == "OC" and b.size >= 19 then
            objects[W(d, b.pos + 6)] = { w = d:byte(b.pos + 11) * 8,
                h = math.floor(d:byte(b.pos + 17) / 8) * 8 }
        elseif b.tag == "OI" and b.size >= 12 then images[#images + 1] = b end
    end
    if not hd or not bm then return nil end
    local w, h = W(d, hd.pos + 6), W(d, hd.pos + 8)
    if w == 0 or w % 8 ~= 0 or w > 2048 or h == 0 or h > 512 then return nil end
    local start = bm.pos + 5 -- zero-based offset of the BM payload
    local size, first = W(d, start + 1), W(d, start + 3)
    if bm.size < 10 or first ~= 2 + w / 4 or size <= first or size > bm.size - 6 then return nil end
    local sprites = {}
    for _, b in ipairs(images) do
        local oid = W(d, b.pos + 6)
        local obj = objects[oid]
        local image = b.pos + 7 -- OI header includes the object ID before the bitmap.
        if obj and obj.w > 0 and obj.h > 0 and W(d, image + 3) == 2 + obj.w / 4
            and W(d, image + 1) > W(d, image + 3) and W(d, image + 1) <= b.size - 8 then
            sprites[#sprites + 1] = { id = oid, w = obj.w, h = obj.h, image = image }
        end
    end
    local r = { data = d, w = w, h = h, image = start, objects = sprites }
    s.room_cache[id] = r
    return r
end

local function costume(s, id)
    if s.costume_cache[id] ~= nil then return s.costume_cache[id] or nil end
    local entry = s.idx.costumes[id]
    local d = entry and resource(s, entry.room, entry.offset, "CO")
    local c = d and Cost.parse(d, 4)
    s.costume_cache[id] = c or false
    return c
end

function V.detect(path)
    local s = state(path)
    if not s then return false end
    for id = 1, 255 do
        if s.idx.rooms[id] and room(s, id) then return true end
    end
    return false
end

function V.get_resources(path)
    local s = state(path)
    if not s then return {} end
    local rooms, costumes = {}, {}
    for id = 1, 255 do
        local r = s.idx.rooms[id] and room(s, id)
        if r then
            local children = { { id = "v4:bg:" .. id, name = "Background", type = "image" } }
            local sprites = {}
            for _, o in ipairs(r.objects) do
                sprites[#sprites + 1] = { id = "v4:obj:" .. id .. ":" .. o.id,
                    name = "Object " .. o.id, type = "image" }
            end
            if #sprites > 0 then children[#children + 1] = { id = "v4:objects:" .. id,
                name = "Object sprites", type = "category", children = sprites } end
            rooms[#rooms + 1] = { id = "v4:room:" .. id,
                name = string.format("Room %d%s (%dx%d)", id, s.idx.names[id] and " - " .. s.idx.names[id] or "", r.w, r.h),
                type = "category", children = children }
        end
    end
    for id = 0, s.idx.costume_count - 1 do
        if s.idx.costumes[id] then
            local c = costume(s, id)
            if c then
                local children = { { id = "v4:sheet:" .. id, name = "All cels", type = "image" } }
                for _, a in ipairs(c:animations()) do
                    children[#children + 1] = { id = "v4:anim:" .. id .. ":" .. a.id, name = a.name, type = "animation" }
                end
                costumes[#costumes + 1] = { id = "v4:costume:" .. id, name = "Costume " .. id,
                    type = "category", children = children }
            end
        end
    end
    local out = { { id = "v4:rooms", name = "Rooms", type = "category", children = rooms },
        { id = "v4:pal", name = "EGA palette", type = "palette" } }
    if #costumes > 0 then out[#out + 1] = { id = "v4:costumes", name = "Costumes / actor sprites",
        type = "category", children = costumes } end
    return out
end

function V.load_resource(path, id, palette_id)
    local pal = EGA.ega_palette()
    if id == "v4:pal" then
        local pixels = {}
        for y = 0, 31 do for x = 0, 255 do pixels[#pixels + 1] = math.floor(x / 16) end end
        return { type = "image", image = image_create_indexed(256, 32, pixels, pal), palette = pal }
    end
    local kind, number, extra = id:match("^v4:(%a+):(%d+):?(%d*)$")
    number = tonumber(number)
    local s = number and state(path)
    if not s then return nil end
    if palette_id and palette_id ~= "v4:pal" then log_warn("V4 EGA resources use the fixed EGA palette") end
    if kind == "bg" or kind == "obj" then
        local r = room(s, number)
        if not r then return nil end
        local w, h, start = r.w, r.h, r.image
        if kind == "obj" then
            local found
            for _, o in ipairs(r.objects) do if o.id == tonumber(extra) then found = o; break end end
            if not found then return nil end
            w, h, start = found.w, found.h, found.image
        end
        return { type = "image", image = image_create_indexed(w, h, EGA.decode_ega(r.data, start, w, h), pal),
            description = string.format("SCUMM V4 EGA %s, room %d, %dx%d", kind, number, w, h) }
    elseif kind == "sheet" or kind == "anim" then
        local c = costume(s, number)
        if not c then return nil end
        if kind == "sheet" then
            local img = c:render_sheet(pal)
            if img then return { type = "image", image = img } end
        else
            local a = tonumber(extra)
            if not a then return nil end
            local anim, _, _, _, animated = c:render_animation(a, pal)
            if anim then
                if animated then return { type = "animation", animation = anim, delay_ms = 120 } end
                return { type = "image", image = anim }
            end
        end
        return { type = "text", text = "Costume has no visible cels" }
    end
    return nil
end

return V

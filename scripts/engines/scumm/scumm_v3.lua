-- SCUMM V3 old-bundle EGA resources (Loom / Indy3).
-- References: ScummVM resource_v3.cpp, room.cpp, object.cpp, gfx.cpp,
-- costume.cpp. VGA/small-header V3 releases use a different layout.
local U = require("scumm_util")
local Cost = require("scumm_cost")
local V = {}
local W = U.u16le

local function read(path)
    local f = file_open(path)
    if not f then return nil end
    local data = file_read(f, 0, file_size(f))
    file_close(f)
    return data
end

local function decrypt(data)
    return data and xor_bytes(data, string.char(255))
end

local function index(path)
    local d = decrypt(read(path .. "/00.LFL"))
    if not d or #d < 4 or W(d, 1) ~= 0x0100 then return nil end
    local p = 5 + W(d, 3) * 4
    local out = {}
    for _, kind in ipairs({ "rooms", "costumes", "scripts", "sounds" }) do
        local n = d:byte(p)
        if not n or n == 255 or p + n * 3 > #d then return nil end
        p = p + 1
        local entries = {}
        for id = 0, n - 1 do
            local offset = W(d, p + n + id * 2)
            if offset ~= 65535 then
                entries[id] = { room = kind == "rooms" and id or d:byte(p + id), offset = offset }
            end
        end
        out[kind] = entries
        p = p + n * 3
    end
    if p ~= #d + 1 then return nil end
    return out
end

function V.detect(path)
    return index(path) ~= nil
end

local EGA = {
    0,0,0, 0,0,170, 0,170,0, 0,170,170,
    170,0,0, 170,0,170, 170,85,0, 170,170,170,
    85,85,85, 85,85,255, 85,255,85, 85,255,255,
    255,85,85, 255,85,255, 255,255,85, 255,255,255
}
local function palette()
    local pal = {}
    for i = 1, 768 do pal[i] = EGA[i] or 0 end
    return pal
end

local function room_file(path, id)
    return decrypt(read(string.format("%s/%02d.LFL", path, id)))
end

local function room_info(d)
    if not d or #d < 29 then return nil end
    local size, w, h, image = W(d, 1), W(d, 5), W(d, 7), W(d, 11)
    if size < 29 or size > #d or w == 0 or w % 8 ~= 0 or w > 2048 or h == 0 or h > 512
        or image < 29 or image + 2 > size then return nil end
    return { size = size, w = w, h = h, image = image }
end

-- EGA strips have a u16 size and u16 relative strip offsets. Runs walk down
-- columns; repeat-previous-column and alternating-nibble runs differ from V2.
local function bitmap(d, start, w, h)
    local size = W(d, start + 1)
    assert(size >= 2 + w / 8 * 2 and start + size <= #d, "Invalid V3 bitmap size")
    local pixels = {}
    for i = 1, w * h do pixels[i] = 0 end
    for strip = 0, w / 8 - 1 do
        local offset = W(d, start + 3 + strip * 2)
        assert(offset >= 2 + w / 8 * 2 and offset < size, "Invalid V3 strip offset")
        local p, drawn = start + offset + 1, 0
        local function byte()
            assert(p <= start + size, "Truncated V3 strip")
            local b = d:byte(p); p = p + 1; return b
        end
        while drawn < 8 * h do
            local b = byte()
            local run, pair, previous
            if b >= 128 then
                run = b % 64
                if b >= 192 then pair = byte() else previous = true end
            else run = math.floor(b / 16) end
            if run == 0 then run = byte() end
            assert(run > 0 and drawn + run <= 8 * h, "Invalid V3 strip run")
            for z = 0, run - 1 do
                local x, y = strip * 8 + math.floor(drawn / h), drawn % h
                local color = b % 16
                if pair then color = z % 2 == 0 and math.floor(pair / 16) or pair % 16
                elseif previous then
                    -- Object overlays can copy the scene just outside their
                    -- left edge. Standalone previews have a black backdrop.
                    color = x > 0 and pixels[y * w + x] or 0
                end
                pixels[y * w + x + 1] = color
                drawn = drawn + 1
            end
        end
    end
    return pixels
end

local function strip_height(d, image, width, size, first)
    local finish = image + (width > 8 and W(d, image + 5) or size)
    local p, count = image + first + 1, 0
    if finish > image + size then return nil end
    while p <= finish do
        local b = d:byte(p); p = p + 1
        local run
        if b >= 128 then
            run = b % 64
            if b >= 192 then p = p + 1 end
        else run = math.floor(b / 16) end
        if run == 0 then run = d:byte(p); p = p + 1 end
        if not run or run == 0 or p > finish + 1 then return nil end
        count = count + run
    end
    return count / 8
end

local function objects(d, info)
    local n, out = d:byte(21), {}
    assert(29 + n * 4 <= info.size, "Truncated V3 object table")
    for i = 0, n - 1 do
        local image = W(d, 30 + i * 2)
        local code = W(d, 30 + n * 2 + i * 2)
        if code >= 2 and code + 16 <= info.size and image > 0 and image + 2 <= info.size then
            local w, h = d:byte(code + 10) * 8, math.floor(d:byte(code + 16) / 8) * 8
            -- Objects without art reuse the next object's image pointer; their
            -- interaction rectangle is not an image size. Only expose owners
            -- whose width agrees with the actual strip table.
            local size, first = W(d, image + 1), W(d, image + 3)
            if w > 0 and h > 0 and size > first and image + size <= info.size
                and first == 2 + w / 4 and strip_height(d, image, w, size, first) == h then
                out[#out + 1] = { slot = i, id = W(d, code + 5), w = w, h = h, image = image }
            end
        end
    end
    return out
end

local function costume(path, entry)
    local d = room_file(path, entry.room)
    if not d or entry.offset + 2 > #d then return nil end
    local size = W(d, entry.offset + 1)
    if size < 16 or entry.offset + size > #d then return nil end
    return Cost.parse(d:sub(entry.offset + 1, entry.offset + size), 3)
end

-- Old-bundle sounds: a u16-sized PC-speaker (WA) block, then a u16-sized
-- AdLib block whose payload starts 4 bytes in (ScummVM
-- readSoundResourceSmallHeader). Payload byte 2 is 0x80 for music; effects
-- start with an instrument (1) or note (2) definition.
local function adlib_sound(path, entry)
    local d = room_file(path, entry.room)
    if not d or entry.offset + 2 > #d then return nil end
    local wa = W(d, entry.offset + 1)
    local ad_at = entry.offset + wa
    if wa < 2 or ad_at + 4 > #d then return nil end
    local ad = W(d, ad_at + 1)
    if ad < 8 or ad_at + ad > #d then return nil end
    local payload = d:sub(ad_at + 5, ad_at + ad)
    local kind = payload:byte(3)
    if kind == 0x80 then return payload, "music" end
    if kind == 1 or kind == 2 then return payload, "effect" end
    return nil
end

local function is_loom(path)
    for _, f in ipairs(list_files(path) or {}) do
        if f:upper() == "LOOM.EXE" then return true end
    end
    return false
end

function V.get_resources(path)
    local idx = index(path)
    if not idx then return {} end
    local rooms, costumes = {}, {}
    for id = 1, 254 do
        if idx.rooms[id] then
            local d = room_file(path, id)
            local info = room_info(d)
            if info then
                local children = { { id = "v3:bg:" .. id, name = "Background", type = "image" } }
                local sprites = {}
                for _, obj in ipairs(objects(d, info)) do
                    sprites[#sprites + 1] = { id = "v3:obj:" .. id .. ":" .. obj.slot,
                        name = "Object " .. obj.id, type = "image" }
                end
                if #sprites > 0 then children[#children + 1] = { id = "v3:objects:" .. id,
                    name = "Object sprites", type = "category", children = sprites } end
                rooms[#rooms + 1] = { id = "v3:room:" .. id,
                    name = string.format("Room %d (%dx%d)", id, info.w, info.h),
                    type = "category", children = children }
            end
        end
    end
    for id = 0, 254 do
        local entry = idx.costumes[id]
        local c = entry and costume(path, entry)
        if c then
            local children = { { id = "v3:sheet:" .. id, name = "All cels", type = "image" } }
            for _, a in ipairs(c:animations()) do
                children[#children + 1] = { id = "v3:anim:" .. id .. ":" .. a.id, name = a.name, type = "animation" }
            end
            costumes[#costumes + 1] = { id = "v3:costume:" .. id, name = "Costume " .. id,
                type = "category", children = children }
        end
    end
    local out = { { id = "v3:rooms", name = "Rooms", type = "category", children = rooms },
        { id = "v3:pal", name = "EGA palette", type = "palette" } }
    if #costumes > 0 then out[#out + 1] = { id = "v3:costumes", name = "Costumes / actor sprites",
        type = "category", children = costumes } end
    local music, effects = {}, {}
    for id = 0, 254 do
        local entry = idx.sounds[id]
        local payload, kind = nil, nil
        if entry then payload, kind = adlib_sound(path, entry) end
        if kind == "music" then
            music[#music + 1] = { id = "v3:snd:" .. id, name = string.format("Sound %d — AdLib music", id), type = "sound" }
        elseif kind == "effect" then
            effects[#effects + 1] = { id = "v3:snd:" .. id, name = string.format("Sound %d — AdLib effect", id), type = "sound" }
        end
    end
    if #music > 0 then out[#out + 1] = { id = "v3:music", name = string.format("AdLib music (%d)", #music),
        type = "category", children = music } end
    if #effects > 0 then out[#out + 1] = { id = "v3:effects", name = string.format("AdLib sound effects (%d)", #effects),
        type = "category", children = effects } end
    return out
end

function V.load_resource(path, id, palette_id)
    local pal = palette()
    if id == "v3:pal" then
        local pixels = {}
        for y = 0, 31 do for x = 0, 255 do pixels[#pixels + 1] = math.floor(x / 16) end end
        return { type = "image", image = image_create_indexed(256, 32, pixels, pal), palette = pal }
    end
    local kind, number, extra = id:match("^v3:(%a+):(%d+):?(%d*)$")
    number = tonumber(number)
    if not number then return nil end
    if palette_id and palette_id ~= "v3:pal" then
        log_warn("V3 EGA resources use the fixed EGA palette")
    end
    if kind == "snd" then
        local idx = index(path)
        local entry = idx and idx.sounds[number]
        local payload, what = nil, nil
        if entry then payload, what = adlib_sound(path, entry) end
        if not payload then return nil end
        if what == "music" then
            -- Loaded at call time: scumm_v4 requires this module.
            return require("scumm_v4").load_ad(payload, is_loom(path), string.format("SCUMM V3 sound %d — AdLib music", number))
        end
        local snd = sound_create_scumm_ad(payload, is_loom(path))
        return snd and { type = "sound", sound = snd, description = string.format(
            "SCUMM V3 sound %d — AdLib effect (Nuked OPL3 emulation)", number) }
    end
    if kind == "bg" or kind == "obj" then
        local idx = index(path)
        if not idx or not idx.rooms[number] then return nil end
        local d = room_file(path, number)
        local info = room_info(d)
        if not info then return nil end
        local w, h, start = info.w, info.h, info.image
        if kind == "obj" then
            local found
            for _, o in ipairs(objects(d, info)) do if o.slot == tonumber(extra) then found = o; break end end
            if not found then return nil end
            w, h, start = found.w, found.h, found.image
        end
        return { type = "image", image = image_create_indexed(w, h, bitmap(d, start, w, h), pal),
            description = string.format("SCUMM V3 EGA %s, room %d, %dx%d", kind, number, w, h) }
    elseif kind == "sheet" or kind == "anim" then
        local idx = index(path)
        local c = idx and idx.costumes[number] and costume(path, idx.costumes[number])
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
        return { type = "text", text = "Costume " .. number .. ": no drawable cels in this sequence" }
    end
    return nil
end

-- V4 EGA uses the same strip codec and hardware palette.
V.decode_ega = bitmap
V.ega_palette = palette
return V

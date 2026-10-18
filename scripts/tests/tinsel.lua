-- lua scripts/tests/tinsel.lua [Discworld game directory] [animation limit]
local engine = dofile('scripts/engines/tinsel/engine.lua')
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n) return le16(n % 65536) .. le16(math.floor(n / 65536) % 65536) end
local images, animations = {}, {}
function image_create_indexed(w, h, p, pal, alpha)
    assert(w > 0 and h > 0 and #pal == 768)
    local pixels = {}
    for i = 1, w * h do pixels[i] = p[i] or 0 end
    images[#images + 1] = { w = w, h = h, pixels = pixels, palette = pal, alpha = alpha }
    return #images
end
function animation_create(frames, delay)
    assert(#frames > 1 and delay > 0)
    animations[#animations + 1] = { frames = frames, delay = delay }
    return #animations
end
local fs = {}
function file_exists(p) return fs[p] ~= nil end
function file_open(p) return fs[p] end
function file_read(f, o, n) return f:sub(o + 1, o + n) end
function file_size(f) return #f end
function file_close() end
local function fixture(v2, script)
    local bytes = {}
    for i = 1, 512 do bytes[i] = '\0' end
    local function put(o, s) for i = 1, #s do bytes[o + i] = s:sub(i, i) end end
    local function words(o, list) for i, n in ipairs(list) do put(o + (i - 1) * 4, le32(n)) end end
    words(0, { 0x33340002, 64 })
    words(16, { 24, 0 })
    put(24, string.rep('\1', 16) .. string.rep('\2', 16))
    put(56, le16(0) .. le16(1))
    if v2 then put(56, '\2\1\2\2\2\1') end
    words(64, { 0x33340006, 104 })
    local w, h = v2 and 2 or 4, v2 and 1 or 4
    put(72, le16(w) .. le16(h) .. le16(0) .. le16(0) .. le32(56) .. le32(400))
    put(88, le16(w) .. le16(h) .. le16(1) .. le16(0) .. le32(v2 and 59 or 58) .. le32(400))
    words(104, { 0x33340007, 160 })
    words(112, { 72, 0, 88, 0, 72, 88, 0 })
    words(160, { 0x33340008, 0 })
    words(168, { 112, 1, 1, 0, 0, 0, 0 })
    words(200, script or { 112, 120, 1, 4294967293 })
    words(300, { 8, 1, 168, 200 })
    words(400, { 2, 0x000000ff, 0x0000ff00 })
    local name = v2 and 'dw2.scn' or 'dw.scn'
    fs = { ['fixture/' .. name] = table.concat(bytes),
        ['fixture/index'] = name .. string.rep('\0', 12 - #name) .. le32(512)
            .. string.rep('\0', v2 and 8 or 4) }
    images, animations = {}, {}
    return 'anim_' .. name .. '_300_1', 'img_' .. name .. '_72'
end
for _, v2 in ipairs({ false, true }) do
    local id, still = fixture(v2)
    assert(engine.detect('fixture') and not engine.detect('missing'))
    local found, count = false, 0
    local function walk(nodes)
        for _, n in ipairs(nodes) do
            if n.children then walk(n.children)
            elseif n.type == 'animation' then assert(n.id == id); found = true; count = count + 1 end
        end
    end
    walk(engine.get_resources('fixture')); assert(found and count == 1)
    local r = engine.load_resource('fixture', id)
    assert(r.type == 'animation' and r.delay_ms == 125)
    local a = animations[r.animation]; assert(#a.frames == 2)
    local first, second = images[a.frames[1]], images[a.frames[2]]
    assert(first.w == (v2 and 3 or 5) and first.w == second.w and first.h == second.h)
    assert(first.alpha == 0 and first.pixels[1] == 0 and second.pixels[second.w] == 0)
    assert(engine.load_resource('fixture', still).type == 'image')
    -- Multipart frames, flips, both-axis adjustment, hide, and finite ending.
    id = fixture(v2, { 128, 2, 7, 2, 1, 120, 10, 0 })
    r = engine.load_resource('fixture', id); assert(r.type == 'animation')
    a = animations[r.animation]; assert(#a.frames == 3)
    local hidden = images[a.frames[3]]
    for _, p in ipairs(hidden.pixels) do assert(p == 0) end
    -- A flip on each loop must produce both orientations, even with one shape.
    id = fixture(v2, { 112, 2, 1, 4294967293 })
    r = engine.load_resource('fixture', id); assert(r.type == 'animation')
    assert(#animations[r.animation].frames == 2)
    if v2 then
        local a = animations[r.animation]
        local f1, f2 = images[a.frames[1]], images[a.frames[2]]
        local function rgb(f, i)
            local p = f.pixels[i] * 3 + 1
            return f.palette[p] * 65536 + f.palette[p + 1] * 256 + f.palette[p + 2]
        end
        assert(rgb(f1, 2) == rgb(f2, 2)) -- red mirrors around the animation origin
        assert(rgb(f1, 3) == rgb(f2, 1))
    end
    -- Static reels and malformed/control-only scripts do not become animations.
    for _, script in ipairs({ { 112, 0 }, { 1, 4294967295 }, { 112, 999999, 0 },
        { 112, 9, 0 }, { 112, 11, 0 } }) do
        id = fixture(v2, script)
        assert(engine.load_resource('fixture', id).type == 'text')
    end
end
print('Tinsel DW1/DW2 discovery, frame ordering, origins, multipart, flip, hide, loops and malformed scripts passed')
if not arg[1] then return end
function file_open(p)
    local f = io.open(p, 'rb')
    if f then return f end
    local dir, name = p:match('^(.*)/([^/]+)$')
    return io.open(dir .. '/' .. name:upper(), 'rb')
end
function file_exists(p) local f = file_open(p); if f then f:close(); return true end; return false end
function file_read(f, o, n) assert(f:seek('set', o)); return f:read(n) end
function file_size(f) return f:seek('end') end
function file_close(f) f:close() end
-- Validate all selected output pixels without retaining whole-game image data.
function image_create_indexed(w, h, p, pal, alpha)
    assert(w > 0 and h > 0 and #pal == 768)
    for i = 1, w * h do local v = p[i] or 0; assert(v >= 0 and v <= 255) end
    return 1
end
local count, loaded, failures = 0, 0, 0
local ids = {}
local limit = tonumber(arg[2]) or math.huge
local function scan(nodes)
    for _, n in ipairs(nodes) do
        if n.children then scan(n.children)
        elseif n.type == 'animation' then
            count = count + 1
            ids[#ids + 1] = n.id
        end
    end
end
scan(engine.get_resources(arg[1]))
for sample = 1, math.min(limit, #ids) do
    local index = limit >= #ids and sample or math.floor((sample - 1) * (#ids - 1) / math.max(1, limit - 1)) + 1
    local id = ids[index]
    loaded = loaded + 1
    local r = engine.load_resource(arg[1], id)
    if not r or r.type ~= 'animation' then
        failures = failures + 1; print('FAILED', id, r and r.text)
    end
    animations = {}
    if loaded % 50 == 0 then print('Loaded', loaded) end
end
print('Tinsel real data: ' .. count .. ' animations, ' .. loaded .. ' loaded, ' .. failures .. ' failures')
assert(failures == 0)

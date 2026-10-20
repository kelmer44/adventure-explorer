-- lua scripts/tests/curseofenchantia.lua [game directory]
local engine = dofile('scripts/engines/curseofenchantia/engine.lua')
local function up(fn, key)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if name == key then return value end
        if not name then break end
    end
    error('Missing helper ' .. key)
end
local function w(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local spr = up(up(engine.load_resource, 'load_spr'), 'spr_decode')
local entries = up(up(engine.load_resource, 'load_spr'), 'spr_entries')
local sfx = up(up(engine.load_resource, 'load_sfx'), 'sfx_entries')
-- Odd width, transparent gaps, four-plane interleaving and plane boundaries.
local plane0 = string.char(2, 192, 193, 0)
local plane = string.char(255, 1, 194, 0)
local fixture = w(5) .. w(1) .. w(12) .. w(8) .. w(4) .. plane0 .. plane .. plane .. plane
local wi, he, pixels = spr(fixture, 1, #fixture + 1)
assert(wi == 5 and he == 1 and pixels[1] == 192 and pixels[2] == 0 and pixels[5] == 193)
assert(not spr(fixture:sub(1, -2), 1, #fixture - 1))
assert(not spr(w(65535) .. fixture:sub(3), 1, #fixture + 1))
assert(not spr(fixture:sub(1, 4) .. w(3) .. fixture:sub(7), 1, #fixture + 1))
assert(not entries(w(65535)))
local offsets = w(1) .. w(65535) .. string.rep('\0', 12) .. fixture
local es, n = entries(offsets)
assert(n == 8 and es[0] == 1 and es[1] == 0)
local audio = w(4) .. w(9) .. w(3) .. string.char(0, 128, 255) .. w(1) .. 'X'
local clips = sfx(audio)
assert(#clips == 2 and clips[1].offset == 7 and clips[1].size == 3)
for _, bad in ipairs({ '', w(3) .. 'ABC', audio:sub(1, -2), w(4) .. w(8) .. audio:sub(5) }) do
    assert(not sfx(bad))
end
print('Curse sprite and PCM bounds regressions passed')
if not arg or not arg[1] then return end
function file_open(path) return io.open(path, 'rb') end
function file_close(f) f:close() end
function file_size(f) return f:seek('end') end
function file_read(f, p, n) assert(f:seek('set', p)); return f:read(n) end
function file_exists(path) local f = file_open(path); if f then f:close(); return true end; return false end
function list_files(path)
    local p = assert(io.popen('ls -1 "' .. path .. '"'))
    local files = {}; for name in p:lines() do files[#files + 1] = name end
    p:close(); return files
end
function image_create_indexed(wi, he, px, pal, transparent)
    assert(wi > 0 and he > 0 and #px == wi * he and #pal == 768)
    assert(transparent == nil or transparent == 0)
    for _, v in ipairs(px) do assert(v >= 0 and v <= 255) end
    return 1
end
function sound_create_pcm(rate, bits, channels, signed, data)
    assert(rate == 8000 and bits == 8 and channels == 1 and not signed and #data > 0)
    return 1
end
function animation_create(frames, delay) assert(#frames > 1 and delay == 100); return 1 end
local counts, seen = {}, {}
local function walk(nodes)
    for _, node in ipairs(nodes) do
        assert(not seen[node.id], node.id); seen[node.id] = true
        if node.children then walk(node.children)
        else
            local r = assert(engine.load_resource(arg[1], node.id), node.id)
            assert(r.type == node.type or node.type == 'palette' and r.type == 'image', node.id .. ': ' .. tostring(r.text))
            counts[node.type] = (counts[node.type] or 0) + 1
        end
    end
end
assert(engine.detect(arg[1])); walk(engine.get_resources(arg[1]))
assert(counts.image == 2770 and counts.sound == 109 and counts.animation == 3 and counts.palette == 62)
assert(engine.load_resource(arg[1], 'spr_CAVE_0', 'pal:TITLE').type == 'image')
assert(engine.load_resource(arg[1], 'spr_CAVE_0', 'pal:missing').type == 'text')
print(string.format('Curse: %d images, %d PCM sounds, %d animations, %d palettes', counts.image, counts.sound, counts.animation, counts.palette))

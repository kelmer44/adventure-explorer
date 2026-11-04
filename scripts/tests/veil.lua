-- lua scripts/tests/veil.lua [Veil of Darkness directory]
-- Asset-free regressions for the LZSS/PackBits/image-header decoders, then an
-- optional sweep of every image, sound and text resource in a real install.
local engine = dofile('scripts/engines/veil/engine.lua')
local function find(fn, key, depth)
    depth = depth or 0
    if depth > 4 then return nil end
    for i = 1, 200 do
        local n, v = debug.getupvalue(fn, i)
        if not n then break end
        if n == key then return v end
        if type(v) == 'function' then
            local r = find(v, key, depth + 1)
            if r then return r end
        end
    end
end
local function up(fn, key) return assert(find(fn, key), 'Missing upvalue ' .. key) end
local lzss = up(engine.load_resource, 'lzss')
local packbits = up(engine.load_resource, 'packbits')
local image_header = up(engine.get_resources, 'image_header')
local decode_image = up(engine.load_resource, 'decode_image')

-- PackBits: literal run of 3, then 4 copies of 7, must land on 7 bytes exactly.
local px = packbits('\2abc\253\7', 7)
assert(px and #px == 7 and px[1] == 97 and px[4] == 7 and px[7] == 7)
assert(not packbits('\2abc\253\7', 8))
assert(not packbits('\5ab', 6))

-- LZSS: flag 0xFF = 8 literals; flag 0x00 then a reference into the 0xFE fill.
local lit = lzss('\255ABCDEFGH', 8)
assert(lit and #lit == 8 and lit[1] == 65 and lit[8] == 72)
local fill = lzss('\0\0\0', 3)          -- position 0, length 3 -> window fill 0xFE
assert(fill and fill[1] == 254 and fill[3] == 254)
assert(not lzss('\255ABC', 8))
-- Reference back into freshly written output (position 0xFEE, length 3).
local back = lzss('\3AB\238\240', 5)
assert(back and #back == 5 and back[3] == 65 and back[4] == 66 and back[5] == 65)

-- Header: 2 frames of 16x4, transparent colour 254, PackBits (method 1).
local function hdr(frames, rows, w8, trans, method)
    return 'EH\1\7\0' .. string.char(frames % 256, math.floor(frames / 256), rows, w8, trans, method, 0)
end
local h = image_header(hdr(2, 4, 2, 254, 1))
assert(h and h.animated and h.out_w == 16 and h.out_h == 4 and h.transparent == 254 and h.total == 128)
h = image_header(hdr(200, 1, 40, 255, 3))
assert(h and not h.animated and h.out_w == 320 and h.out_h == 200 and h.transparent == nil)
assert(not image_header(hdr(0, 4, 2, 255, 1)))
assert(not image_header(hdr(1, 4, 0, 255, 1)))
assert(not image_header('EH\2\7\0\1\0\1\1\255\1\0'))
assert(not image_header('XX\1\7\0\1\0\1\1\255\1\0'))
local d, pix = decode_image(hdr(1, 1, 1, 255, 1) .. '\7abcdefgh')
assert(d and #pix == 8 and pix[8] == 104)
assert(not decode_image(hdr(1, 1, 1, 255, 2) .. 'xxxxxxxx'))
local music_to_midi = up(engine.load_resource, 'music_to_midi')
local function le32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, 0) end
-- One instrument (GM program 40), events: initial delta 0, program change,
-- note on, F8 + 5 tick delta, note off, tempo x2.0, end.
local events = '\0' .. '\192\0\0' .. '\144\60\100\248\5' .. '\128\60\0\0' .. '\240\127\0\2\0\247\0' .. '\252'
local rec = string.char(40, 0) .. string.rep('\0', 56)
local song = 'EH\3\24\0' .. string.char(240, 4, 0, 0, 0, 0) .. le32(#events) .. le32(0)
    .. string.char(0, 0, 1, 0, 0, 0) .. string.char(120, 0) .. string.char(0, 1, 0, 0, 0, 1) .. rec .. events
song = song:sub(1, 5) .. song:sub(6, 28) .. string.char(1) .. rec .. events
local smf = music_to_midi(song)
assert(smf and smf:sub(1, 4) == 'MThd' and smf:sub(13, 14) == '\0\240')
assert(smf:find('\192\40', 1, true) and smf:find('\144\60\100', 1, true))
assert(smf:find('\128\60\0', 1, true))
assert(not music_to_midi(song:sub(1, -2)))
assert(not music_to_midi('EH\1' .. song:sub(4)))
print('Veil of Darkness format regressions passed')
if not arg[1] then return end

function list_files(path)
    local f = assert(io.popen("ls -1 '" .. path:gsub("'", "'\\''") .. "'"))
    local out = {}
    for n in f:lines() do out[#out + 1] = n end
    f:close()
    return out
end
function file_open(p) return io.open(p, 'rb') end
function file_read(f, o, n) assert(f:seek('set', o)); return f:read(n) end
function file_close(f) f:close() end
function file_size(f) return f:seek('end') end
local nimage, nanim, nsound, nmidi = 0, 0, 0, 0
function image_create_indexed(w, hh, pixels, pal, trans)
    assert(#pixels == w * hh, 'pixel count ' .. #pixels .. ' vs ' .. w * hh)
    assert(#pal == 768)
    for i = 1, #pixels do assert(pixels[i] >= 0 and pixels[i] <= 255) end
    nimage = nimage + 1
    return nimage
end
function animation_create(handles, delay) assert(#handles > 1); nanim = nanim + 1; return nanim end
function midi_create_raw(data)
    assert(data:sub(1, 4) == 'MThd' and data:find('MTrk', 1, true) == 15 and data:sub(-3) == '\255\47\0')
    nmidi = nmidi + 1; return nmidi
end
function sound_create_encoded(data) assert(data:sub(1, 19) == 'Creative Voice File'); nsound = nsound + 1; return nsound end

assert(engine.detect(arg[1]), 'detect failed')
local tree = engine.get_resources(arg[1])
local ids, counts = {}, {}
local function walk(nodes)
    for _, node in ipairs(nodes) do
        assert(not ids[node.id], 'Duplicate ID ' .. node.id)
        ids[node.id] = true
        if node.children then walk(node.children)
        else
            counts[node.type] = (counts[node.type] or 0) + 1
            local r = engine.load_resource(arg[1], node.id, engine.default_palette(arg[1], node.id))
            assert(r, 'Failed ' .. node.id)
            assert(not (r.type == 'text' and node.type ~= 'text' and node.type ~= 'data'),
                'Error result for ' .. node.id .. ': ' .. tostring(r.text))
        end
    end
end
walk(tree)
for typ, n in pairs(counts) do print(typ .. ': ' .. n) end
print('midi ' .. nmidi .. ' images ' .. nimage .. ' animations ' .. nanim .. ' sounds ' .. nsound)
assert(counts.midi == 30 and counts.data == 38 and nmidi == 30)
assert(counts.sound == 72 and counts.palette == 31 and counts.text == 3)
assert((counts.image or 0) + (counts.animation or 0) == 1369)
local text = engine.load_resource(arg[1], 'text:dialogue').text
assert(text:find('Seth', 1, true) and select(2, text:gsub('\n', '\n')) == 1367)
print('Veil of Darkness full resource sweep passed')

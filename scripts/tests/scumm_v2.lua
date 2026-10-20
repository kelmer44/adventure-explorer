-- lua scripts/tests/scumm_v2.lua [enhanced V2 game directory]
local engine = dofile('scripts/engines/scummv2/engine.lua')
local function up(fn, key)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if name == key then return value end
        if not name then break end
    end
    error('Missing helper ' .. key)
end
local bitmap = up(engine.load_resource, 'decode_v2_bitmap')
local mask = up(engine.load_resource, 'decode_v2_mask')
local objects = up(engine.load_resource, 'room_objects')
local parse = up(up(engine.load_resource, 'load_room'), 'parse_v2_room')
local function w(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local px, pos = bitmap(string.char(0x11, 0x12, 0x82), 1, 2, 2)
assert(pos == 4 and px[1] == 1 and px[2] == 1 and px[3] == 2 and px[4] == 2)
px, pos = bitmap(string.char(3, 8), 1, 8, 1)
assert(pos == 3 and px[8] == 3)
assert(not bitmap(string.char(0), 1, 8, 1))
assert(not bitmap('', 1, 8, 1))
assert(not bitmap(string.char(0x11), 1, 8, 1))
local m = mask(string.char(2, 0xA5, 0x5A), 1, 8, 2)
assert(m[1] == 1 and m[2] == 0 and m[8] == 1 and m[9] == 0 and m[10] == 1)
assert(mask(string.char(0x82, 0x80), 1, 8, 2)[9] == 1)
assert(not mask(string.char(0x82), 1, 8, 2))
assert(not mask(string.char(0), 1, 8, 2))
assert(not mask(string.char(1, 255), 1, 7, 1))
local header = w(32) .. w(0) .. w(8) .. w(1) .. w(0) .. w(28) .. string.rep('\0', 16)
local room = header .. string.char(0x80, 8, 0x81, 0)
local info = assert(parse(room))
assert(info.total_size == 32 and #objects(room, info) == 0)
assert(not parse(room:sub(1, -2)))
assert(not parse(room:sub(1, 20) .. string.char(255) .. room:sub(22)))
-- One named object with a complete 8x8 bitmap/mask, then malformed code/table bounds.
local object_header = w(56) .. w(0) .. w(8) .. w(8) .. w(0) .. w(32)
    .. string.rep('\0', 8) .. string.char(1) .. string.rep('\0', 7)
local code = w(20) .. w(0) .. w(61) .. string.char(0, 2, 1, 1, 0, 3, 2, 8, 15) .. 'door\0'
local object_room = object_header .. w(32) .. w(36) .. string.char(0, 64, 0x88, 0) .. code
local object_info = assert(parse(object_room))
local records = assert(objects(object_room, object_info))
assert(#records == 1 and records[1].id == 61 and records[1].name == 'door')
assert(records[1].width == 8 and records[1].height == 8 and records[1].x == 16 and records[1].walk_y == 16)
assert(up(engine.get_resources, 'object_pixels')(object_room, records[1]))
assert(not objects(object_room:sub(1, 36) .. w(65535) .. object_room:sub(39), object_info))
assert(not objects(object_room:sub(1, 30) .. w(65535) .. object_room:sub(33), object_info))
assert(up(objects, 'dos_text')(string.char(164)) == 'ñ')
print('SCUMM V2 bitmap, mask, room bounds and dither regressions passed')
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
function image_create_indexed(wi, he, pixels, palette)
    assert(wi > 0 and he > 0 and #pixels == wi * he and #palette == 768)
    for _, value in ipairs(pixels) do assert(value >= 0 and value < 16) end
    return 1
end
local counts, seen = {}, {}
local function walk(nodes)
    for _, node in ipairs(nodes) do
        assert(not seen[node.id], node.id); seen[node.id] = true
        if node.children then walk(node.children)
        else
            local result = assert(engine.load_resource(arg[1], node.id), node.id)
            assert(result.type == node.type or node.type == 'palette' and result.type == 'image', node.id .. ': ' .. tostring(result.text))
            counts[node.type] = (counts[node.type] or 0) + 1
            if node.type == 'text' then assert(#result.text > 0) end
        end
    end
end
assert(engine.detect(arg[1])); walk(engine.get_resources(arg[1]))
print(string.format('V2 game: %d images, %d text resources, %d palettes', counts.image, counts.text, counts.palette))
assert(not engine.load_resource(arg[1], 'obj_1_9999'))
assert(engine.load_resource(arg[1], 'room_1', 'invalid').type == 'text')

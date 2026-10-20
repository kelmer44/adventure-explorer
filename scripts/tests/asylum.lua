-- lua scripts/tests/asylum.lua [game directory] [catalog]
local engine = dofile('scripts/engines/asylum/engine.lua')
local function up(fn, key)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if name == key then return value end
        if not name then break end
    end
    error('Missing helper ' .. key)
end
local function w(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function dw(n) return w(n % 65536) .. w(math.floor(n / 65536)) end
local index = up(engine.get_resources, 'build_index')
local graphic = up(index, 'graphic_header')
local frame_header = up(index, 'frame_header')
local bounds = up(index, 'animation_bounds')
local pixels = up(up(engine.load_resource, 'load_frame'), 'frame_pixels')
local palette = up(index, 'palette_data')
local mask_header = up(index, 'mask_header')
local mask_pixels = up(engine.load_resource, 'mask_pixels')
local text = up(index, 'text_data')
local scene = up(index, 'scene_header')
local directory = up(index, 'directory')
local header = 'D3GR' .. dw(2) .. dw(36) .. dw(0) .. dw(0) .. dw(0) .. w(2) .. w(2) .. dw(0) .. dw(18)
local first = dw(18) .. dw(0) .. w(65535) .. w(1) .. w(1) .. w(2) .. string.char(1, 2)
local second = dw(18) .. dw(0) .. w(1) .. w(0) .. w(2) .. w(1) .. string.char(3, 0)
local data = header .. first .. second
local frames = assert(graphic(data, #data))
assert(#frames == 2 and frames[1].offset == 36 and frames[2].offset == 54)
for _, f in ipairs(frames) do assert(frame_header(data:sub(f.offset + 1, f.offset + 16), f)) end
local box = assert(bounds(frames))
assert(box.x == -1 and box.y == 0 and box.width == 3 and box.height == 2)
local px, width, height = pixels(string.char(1, 2), frames[1], box)
assert(width == 3 and height == 2 and table.concat(px, ',') == '0,0,0,1,2,0')
assert(not pixels('', frames[1], box))
assert(not graphic(data:sub(1, 32), #data))
assert(not graphic(data:sub(1, 8) .. dw(0) .. data:sub(13), #data))
assert(not frame_header(first:sub(1, 14) .. w(8193), frames[1]))
assert(not frame_header(first:sub(1, 16), { offset = 0, stop = 16 }))
assert(not bounds({{x=0,y=0,width=8192,height=8192}}))
local pal = 'D3GR' .. dw(8192) .. dw(0) .. dw(28) .. string.rep('\0', 12)
    .. w(2) .. string.char(254, 0, 63, 0, 0, 0, 63, 0)
local rgb, count, start = palette(pal)
assert(rgb and #rgb == 768 and count == 2 and start == 254 and rgb[763] == 252 and rgb[767] == 252)
assert(not palette(pal:sub(1, -2)))
assert(not palette(pal:sub(1, 28) .. w(3) .. pal:sub(31)))
assert(not palette(pal:sub(1, -7) .. string.char(64) .. pal:sub(-5)))
local mask = dw(1) .. dw(8) .. string.char(5) .. dw(0)
local mh = assert(mask_header(mask, #mask))
assert(table.concat(mask_pixels(mask, mh), ',') == '1,0,1,0,0,0,0,0')
assert(not mask_header(mask, #mask - 1))
assert(not mask_pixels('', mh))
assert(text('{N} Caf' .. string.char(233) .. '\1\0') == '{N} Café')
assert(not text('\1\0'))
assert(not text(' \0'))
assert(not text('binary\2data\0'))
local scn = 'DFISCN' .. dw(160) .. dw(1) .. dw(3) .. string.rep('\0', 148)
assert(scene(scn).chapter == 3)
assert(not scene('invalid' .. scn))
-- Virtual archives test bounds and sparse entries without game data.
local claimed_size
local archive = dw(2) .. dw(12) .. dw(14) .. 'ABCD'
function file_open() return archive end
function file_size(f) return claimed_size or #f end
function file_read(f, o, n) return f:sub(o + 1, o + n) end
function file_close() end
local entries, n = directory('fixture')
assert(n == 2 and #entries == 2 and entries[1].offset == 12 and entries[2].size == 2)
archive = dw(2) .. dw(14) .. dw(12) .. 'ABCD'; assert(not directory('fixture'))
archive = dw(2) .. dw(12) .. dw(999) .. 'ABCD'; assert(not directory('fixture'))
archive = dw(2) .. dw(0) .. dw(12) .. 'ABCD'; assert(#directory('fixture') == 1)
archive = dw(65537); assert(not directory('fixture'))
-- Retail combined-speech offsets are repaired only for the exact known file size.
local count = 0x2B2
local offsets = {}; for i=0,count-1 do offsets[#offsets+1]=dw(i==0x2B0 and 20000 or i==0x2B1 and 16000 or 0) end
archive = dw(count) .. table.concat(offsets)
claimed_size = 299872422
local repaired = assert(directory('RES.104'))
assert(repaired[1].index==0x2B0 and repaired[1].size==40146626)
assert(not directory('RES.204')) -- no disc-2 patch for this index
assert(not directory('RES.999'))
-- The known-size exception must still reject ranges extending beyond EOF.
archive = dw(count) .. table.concat(offsets):sub(1, 0x2B0 * 4) .. dw(290000000) .. dw(16000)
assert(not directory('RES.104'))
archive = dw(count) .. table.concat(offsets)

claimed_size = claimed_size - 1; assert(not directory('RES.104'))
claimed_size = nil
print('Sanitarium archive, palette, frame, animation alignment, mask, scene and text regressions passed')
if not arg or not arg[1] then return end
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
function file_open(path)
    return io.open(path, 'rb') or io.open(path:gsub('SNTRM.DAT$', 'sntrm.dat'), 'rb')
end
function file_exists(path) local f=file_open(path);if f then f:close();return true end;return false end
function file_size(f) return assert(f:seek('end')) end
function file_read(f,o,len) assert(f:seek('set',o));return len==0 and '' or f:read(len) end
function file_close(f) f:close() end
function list_files(path)
    local p=assert(io.popen('ls -1 '..quote(path)));local t={};for name in p:lines() do t[#t+1]=name end;p:close();return t
end
function image_create_indexed(wi,he,px,pal,transparent)
    assert(wi>0 and he>0 and #px==wi*he and #pal==768)
    assert(transparent==nil or transparent==0)
    return 1
end
function animation_create(fs,delay) assert(#fs>1 and delay==100);return 1 end
function sound_create_encoded(d) assert(d:sub(1,4)=='RIFF' and d:sub(9,12)=='WAVE');return 1 end
assert(engine.detect(arg[1]))
local counts, seen = {}, {}
local function walk(nodes)
    for _, node in ipairs(nodes) do
        assert(not seen[node.id],node.id);seen[node.id]=true
        if node.children then walk(node.children)
        else
            counts[node.type]=(counts[node.type] or 0)+1
            if arg[2]~='catalog' then
                local result=assert(engine.load_resource(arg[1],node.id),node.id)
                assert(result.type==node.type or node.type=='palette' and result.type=='image',node.id..': '..tostring(result.text))
            end
        end
    end
end
walk(engine.get_resources(arg[1]))
for kind,num in pairs(counts) do print(kind..': '..num) end
assert(engine.default_palette(arg[1],'frame:RES.005:0:0')=='pal:RES.005:20')
assert(not engine.load_resource(arg[1],'frame:RES.005:0'))
assert(engine.load_resource(arg[1],'frame:RES.005:0:0','invalid').type=='text')
print('Sanitarium real-data sweep passed')

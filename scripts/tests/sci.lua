-- lua scripts/tests/sci.lua [game folder] [all|sample]
local engine = dofile('scripts/engines/sci/engine.lua')
local function up(fn, key)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if name == key then return value end
        if not name then break end
    end
    error('Missing upvalue ' .. key)
end
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n) return le16(n % 65536) .. le16(math.floor(n / 65536)) end
local function map(entries, five)
    local out, offset = {}, (#entries + 1) * 3
    for _, e in ipairs(entries) do
        out[#out + 1] = string.char(e[1] + 128) .. le16(offset)
        offset = offset + #e[2] * (five and 5 or 6)
    end
    out[#out + 1] = '\255' .. le16(offset)
    for _, e in ipairs(entries) do
        for _, r in ipairs(e[2]) do
            out[#out + 1] = le16(r[1]) .. (five and le32(r[2] / 2):sub(1, 3) or le32(r[2]))
        end
    end
    return table.concat(out)
end
local fs = {}
function file_exists(p) return fs[p] ~= nil end
function file_open(p) return fs[p] end
function file_size(f) return #f end
function file_read(f, o, n) return f:sub(o + 1, o + n) end
function file_close() end
function log_warn(s) error(s) end
function image_create_indexed(w, h, pixels, palette)
    assert(w > 0 and h > 0 and #pixels == w * h)
    assert(#palette == 768)
    for _, v in ipairs(pixels) do assert(v >= 0 and v <= 255) end
    return {width = w, height = h, pixels = pixels, palette = palette}
end
function animation_create(frames) return frames end

-- Adjacent map blocks must not leak their first entry into the previous type.
local parse1 = up(up(engine.get_resources, 'get_info'), 'parse_map_sci1')
local parse11 = up(up(engine.get_resources, 'get_info'), 'parse_map_sci11')
for _, five in ipairs({false, true}) do
    local entries = (five and parse11 or parse1)(map({{0, {{1, 0}, {2, 20}}}, {1, {{3, 40}}}}, five))
    assert(#entries == 3 and entries[2].type == 0 and entries[3].type == 1)
    assert(entries[3].number == 3 and entries[3].offset == 40)
end

-- SCI1 and SCI2 can have identical six-byte map entries. Only the volume
-- header distinguishes the sizes and compression; the filenames do not.
local entries, old, new = {}, {}, {}
for i = 0, 2 do
    entries[#entries + 1] = {i, i * 20}
    old[#old + 1] = string.char(132) .. le16(i) .. le16(5) .. le16(1) .. le16(0) .. 'A' .. string.rep('\0', 10)
    new[#new + 1] = string.char(132) .. le16(i) .. le32(1) .. le32(1) .. le16(0) .. 'B' .. string.rep('\0', 6)
end
for _, name in ipairs({'old', 'new'}) do
    fs[name .. '/RESOURCE.MAP'] = map({{4, entries}})
    fs[name .. '/RESOURCE.000'] = table.concat(name == 'old' and old or new)
    assert(engine.detect(name))
    local tree = engine.get_resources(name)
    assert(#tree == 1 and #tree[1].children == 3)
end
local get_info = up(engine.get_resources, 'get_info')
local read_resource = up(engine.load_resource, 'read_resource')
assert(get_info('old').ver == 'sci1')
assert(get_info('new').ver == 'sci2' and not get_info('new').resmap)
assert(read_resource('old', get_info('old'), get_info('old').resources[1]) == 'A')
assert(read_resource('new', get_info('new'), get_info('new').resources[1]) == 'B')
fs['resmap/RESMAP.000'] = fs['new/RESOURCE.MAP']
fs['resmap/RESSCI.000'] = fs['new/RESOURCE.000']
assert(engine.detect('resmap'))
engine.get_resources('resmap')
assert(get_info('resmap').resmap)
assert(read_resource('resmap', get_info('resmap'), get_info('resmap').resources[1]) == 'B')
-- A misleading 13-byte prefix must not override an ordinary SCI1 header.
fs['bad/RESOURCE.MAP'] = fs['new/RESOURCE.MAP']
fs['bad/RESOURCE.000'] = string.char(129) .. fs['new/RESOURCE.000']:sub(2)
engine.get_resources('bad')
assert(get_info('bad').ver == 'sci1')
print('SCI synthetic format/map regressions passed')

if not arg[1] then return end
function file_exists(p) local f = io.open(p, 'rb'); if f then f:close(); return true end; return false end
function file_open(p) return io.open(p, 'rb') end
function file_size(f) local pos = f:seek(); local n = f:seek('end'); f:seek('set', pos); return n end
function file_read(f, o, n) f:seek('set', o); return f:read(n) end
function file_close(f) f:close() end
local path, sample = arg[1], arg[2] == 'sample'
assert(engine.detect(path), 'Game not detected')
local tree = engine.get_resources(path)
local info = get_info(path)
local counts, failures, seen = {}, {}, {}
local read_header = up(read_resource, 'read_resource_header')
for _, r in ipairs(info.resources) do
    local id = 'r_' .. r.type .. '_' .. r.number
    local graphics = r.type == 0 or r.type == 1 or r.type == 7 or r.type == 8 or r.type == 11
    if not sample or (graphics and (seen[r.type] or 0) < 3) then
        seen[r.type] = (seen[r.type] or 0) + 1
        local ok, err = pcall(function()
            local d = assert(read_resource(path, info, r), 'Read failed')
            local vol = assert(file_open(path .. (info.resmap and '/RESSCI.000' or string.format('/RESOURCE.%03d', r.volume))))
            local h = assert(read_header(vol, info.ver, r.offset)); file_close(vol)
            assert(#d == h.unpacked, 'Decompressed size mismatch')
            if graphics then
                local result = engine.load_resource(path, id)
                assert(result and result.image, result and result.text or 'No image')
                counts[r.type] = (counts[r.type] or 0) + 1
            end
        end)
        if not ok then failures[#failures + 1] = id .. ': ' .. tostring(err) end
    end
end
for _, t in ipairs({0, 1, 7, 8, 11}) do print('Type ' .. t .. ': ' .. (counts[t] or 0) .. ' previews') end
for _, err in ipairs(failures) do print(err) end
assert(#failures == 0, #failures .. ' resource failures')
print(path .. ': ' .. #info.resources .. ' resources, ' .. info.ver .. ', validation passed')

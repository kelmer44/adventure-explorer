-- Run: lua scripts/tests/darkseed2.lua [Dark Seed II game folder]
-- Synthetic regressions require no commercial game data.
local engine = dofile("scripts/engines/darkseed2/engine.lua")
local function up(fn, key)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if name == key then return value end
        if not name then break end
    end
    error("Missing local " .. key)
end
local decode = up(engine.load_resource, "decode_bmp")
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n) return le16(n % 65536) .. le16(math.floor(n / 65536) % 65536) end
local function bmp(w, h, bpp, comp, pal, data, used)
    local offset = 54 + #pal
    return "BM" .. le32(offset + #data) .. le32(0) .. le32(offset)
        .. le32(40) .. le32(w) .. le32(h) .. le16(1) .. le16(bpp)
        .. le32(comp) .. le32(#data) .. le32(0) .. le32(0)
        .. le32(used or 0) .. le32(0) .. pal .. data
end
local created = 0
function image_create_indexed(w, h, pixels, palette)
    assert(#pixels == w * h and #palette == 768, "Incomplete pixels/palette")
    for i = 1, w * h do assert(pixels[i] and pixels[i] >= 0 and pixels[i] <= 255) end
    for i = 1, 768 do assert(palette[i] and palette[i] >= 0 and palette[i] <= 255) end
    created = created + 1
    return { w = w, h = h, pixels = pixels, palette = palette }
end
local function read(b, palette)
    return decode(function(i) return b:byte(i) end, #b, "fixture", palette, "test")
end
-- Cropped, empty and full scanlines follow BMP orientation and fill gaps with 0.
local rows = le16(1) .. le16(2) .. string.char(7, 8)
    .. le16(4) .. le16(0) .. le16(0) .. le16(4) .. string.char(9, 10, 11, 12)
local cropped = bmp(4, 3, 8, 2, "", rows)
local override = {}; for i = 1, 768 do override[i] = i % 256 end
local r = assert(read(cropped, override))
assert(table.concat(r.image.pixels, ",") == "9,10,11,12,0,0,0,0,0,7,8,0")
local top = assert(read(bmp(4, -3, 8, 2, "", rows), override))
assert(table.concat(top.image.pixels, ",") == "0,7,8,0,0,0,0,0,9,10,11,12")
assert(r.image.palette[1] == 1 and r.description:find("palette: test", 1, true))
assert(read(cropped:sub(1, -2), override) == nil)
assert(read(bmp(4, 1, 8, 2, "", le16(3) .. le16(2) .. "ab")) == nil)
assert(read(bmp(4, 1, 8, 2, "", "a")) == nil)
-- Embedded BGR0 colours; padded bottom-up and negative-height top-down rows.
local pal = string.char(3, 2, 1, 0, 6, 5, 4, 0)
r = assert(read(bmp(2, 2, 8, 0, pal, string.char(1, 0, 0, 0, 0, 1, 0, 0), 2)))
assert(table.concat(r.image.pixels, ",") == "0,1,1,0")
assert(r.image.palette[1] == 1 and r.image.palette[3] == 3 and r.image.palette[4] == 4)
r = assert(read(bmp(2, -2, 8, 0, pal, string.char(1, 0, 0, 0, 0, 1, 0, 0), 2)))
assert(table.concat(r.image.pixels, ",") == "1,0,0,1")
-- The 4-bit inventory icon keeps its grayscale palette and high-nibble-first pixels.
r = assert(read(bmp(3, 1, 4, 0, string.rep("\0", 64), string.char(0x12, 0x30, 0, 0))))
assert(table.concat(r.image.pixels, ",") == "1,2,3")
assert(read(bmp(3, 1, 4, 0, "", "x")) == nil)
assert(read("BM") == nil)
print("Dark Seed II BMP/scanline regressions passed")
if not arg[1] then return end

function file_open(path) return io.open(path, "rb") end
-- Archives are named lowercase in GFILE.HDR, uppercase on the supplied media.
local plain_open = file_open
function file_open(path)
    local f = plain_open(path)
    if f then return f end
    local dir, name = path:match("^(.*)/([^/]+)$")
    return plain_open(dir .. "/" .. name:upper())
end
function file_exists(path) local f = file_open(path); if f then f:close(); return true end; return false end
function file_size(f) return f:seek("end") end
function file_read(f, offset, length) f:seek("set", offset); return f:read(length) end
function file_close(f) f:close() end
local root, ids, counts = arg[1], {}, {}
assert(engine.detect(root))
local tree = engine.get_resources(root)
local function walk(nodes, category)
    for _, node in ipairs(nodes) do
        assert(not ids[node.id], "Duplicate resource: " .. node.id); ids[node.id] = true
        if node.children then walk(node.children, category or node.id)
        else
            local pal = engine.default_palette(root, node.id)
            local result = engine.load_resource(root, node.id, pal)
            assert(result and result.type == "image", node.id .. ": " .. tostring(result and result.text))
            counts[category] = (counts[category] or 0) + 1
        end
    end
end
walk(tree)
assert(counts.backgrounds == 83 and counts.sprites == 3660 and counts.thumbnails == 83 and counts.palettes == 84)
assert(engine.default_palette(root, "spr_101CHR01") == "pal_RM0101.BMP")
assert(engine.default_palette(root, "spr_N00") == "pal_FIX.PAL")
assert(engine.default_palette(root, "spr_IBCARD") == nil)
local a = engine.load_resource(root, "spr_101CHR01")
local b = engine.load_resource(root, "img_101CHR01", "pal_RM0101.BMP")
assert(table.concat(a.image.palette, ",") == table.concat(b.image.palette, ","))
assert(a.image.palette[209 * 3 + 1] > 0, "Room sprite palette must carry colours")
local c = engine.load_resource(root, "spr_N00")
local fixed = engine.load_resource(root, "pal_FIX.PAL")
assert(table.concat(c.image.palette, ",") == table.concat(fixed.image.palette, ","), "Shared sprite must use FIX.PAL")
local icon = engine.load_resource(root, "spr_IBCARD")
assert(icon.image.palette[4] == 17 and icon.image.palette[5] == 17 and icon.image.palette[6] == 17)
assert(engine.load_resource(root, "bg_RM0101").type == "image")
assert(engine.load_resource(root, "spr_101CHR01", "pal_MISSING.PAL").type == "text")
for _, key in ipairs({"backgrounds", "sprites", "thumbnails", "palettes"}) do print(key .. ": " .. counts[key] .. " decoded") end

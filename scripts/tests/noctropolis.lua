-- Run from repository root: lua scripts/tests/noctropolis.lua [Noctropolis data folder]
-- Pure-format regressions run without commercial data. The optional scan decodes
-- every background, screen and sprite resource in a real game folder.
local engine = dofile("scripts/engines/noctropolis/engine.lua")
local function up(fn, key)
    for i = 1, 200 do
        local name, value = debug.getupvalue(fn, i)
        if name == key then return value end
        if not name then break end
    end
    error("Missing local " .. key)
end

local maybe_dbe = up(engine.load_resource, "maybe_dbe")
local load_playfield = up(engine.load_resource, "load_playfield")
local sprite_frames = up(engine.load_resource, "sprite_frames")
local load_ap = up(engine.load_resource, "load_ap")
local dbe_decompress = up(maybe_dbe, "dbe_decompress")

local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n) return le16(n % 65536) .. le16(math.floor(n / 65536)) end

function image_create_indexed() return 0 end

-- DBE: bad magic / too short are rejected; plain data passes through unchanged.
assert(dbe_decompress("short") == nil)
assert(dbe_decompress("NOPE" .. string.rep("\0", 32)) == nil)
assert(maybe_dbe("plain data") == "plain data")

-- .AP container bounds.
assert(load_ap(le16(3)) == nil)                                   -- truncated offset table
assert(load_ap(le16(1) .. le32(99)) == nil)                       -- offset past end
assert(load_ap(le16(0)) == nil)                                   -- zero entries
local ap = assert(load_ap(le16(1) .. le32(6) .. "payload"))
assert(#ap == 1 and ap[1] == "payload")

-- Playfield: short input rejected; minimal 1x1-tile playfield decodes.
assert(load_playfield(string.rep("\0", 10)) == nil)
local pf = string.char(1, 1) .. le16(1) .. string.char(1, 1, 0) .. le16(0) .. le16(0)
pf = pf .. string.rep("\0", 8) .. string.rep("\0", 768) .. string.rep("\0", 256) .. le16(0)
assert(#pf == 19 + 768 + 256 + 2)
local _, pw, ph = load_playfield(pf)
assert(pw == 16 and ph == 16)
assert(load_playfield(pf:sub(1, -2)) == nil)                      -- truncated matrix

-- Sprite frames: bad container rejected; a 2x3 frame decodes.
assert(sprite_frames(le16(1) .. le32(99)) == nil)
local frame = le16(2) .. le16(3)
    .. string.char(0, 2, 1, 2) .. string.char(1, 1, 9) .. string.char(2, 1, 9)
local blob = le16(1) .. le32(6) .. frame
local fr = assert(sprite_frames(blob))
assert(#fr == 1 and fr[1].w == 2 and fr[1].h == 3)
assert(fr[1].pixels[1] == 1 and fr[1].pixels[2] == 2)
assert(fr[1].pixels[2 * 1 + 1 + 1] == 9)                          -- row 1, x=1
print("Noctropolis format regressions passed")

if not arg[1] then return end

local opens = {}
function file_exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end; return false end
function file_open(p) local f = io.open(p, "rb"); if not f then return nil end; opens[#opens + 1] = f; return #opens end
function file_size(h) local f = opens[h]; local c = f:seek(); local s = f:seek("end"); f:seek("set", c); return s end
function file_read(h, o, n) local f = opens[h]; f:seek("set", o); return f:read(n) end
function file_close(h) local f = opens[h]; if f then f:close(); opens[h] = nil end end
function list_files(dir)
    local p = assert(io.popen("ls -1 '" .. dir .. "' 2>/dev/null"))
    local names = {}; for n in p:lines() do names[#names + 1] = n end; p:close(); return names
end
local nimage = 0
function image_create_indexed(w, h, px, pal)
    assert(w > 0 and h > 0 and #px == w * h and #pal == 768)
    for _, i in ipairs({ 1, math.floor(#px / 2), #px }) do
        assert(px[i] >= 0 and px[i] <= 255 and px[i] % 1 == 0)
    end
    nimage = nimage + 1; return nimage
end
function animation_create(images, delay) assert(#images >= 1 and delay == 150); return 1 end
function log_info() end
function log_warn(m) error(m) end
function log_error(m) error(m) end

assert(engine.detect(arg[1]), "Noctropolis detection failed")
local tree = engine.get_resources(arg[1])
local counts, ids = {}, {}
for _, cat in ipairs(tree) do
    for _, node in ipairs(cat.children or {}) do
        assert(not ids[node.id], "Duplicate resource ID " .. node.id)
        ids[node.id] = true
        counts[cat.id] = (counts[cat.id] or 0) + 1
        local r = engine.load_resource(arg[1], node.id)
        assert(r and (r.type == "image" or r.type == "animation"), "Failed resource " .. node.id)
    end
end
assert(counts.backgrounds and counts.backgrounds >= 70, "Too few backgrounds")
assert(counts.screens and counts.screens >= 20, "Too few screens")
assert(counts.sprites and counts.sprites >= 10, "Too few sprites")
print(string.format("Noctropolis real-data scan passed: %d backgrounds, %d screens, %d sprites, %d images",
    counts.backgrounds, counts.screens, counts.sprites, nimage))

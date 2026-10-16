-- ============================================================================
-- Adventure Explorer - Engine Script: Noctropolis (Electronic Arts, 1994)
-- ============================================================================
-- Built on the Access engine (same family as Martian Memorandum / Amazon).
-- Game data lives in DARK/ (CD root) with comic pages in COMDATA/.
--
-- .AP container: u16le count, then count x u32le offsets; subfiles follow.
--   Either the whole file or an individual subfile may be DBE compressed
--   ("DBE\x01" magic, u32le unpacked size at offset 4, stream from offset 16).
-- DBE is an LZW variant (9..12 bit codes, 256 = clear, 257 = end).
--
-- Playfield (scene subfile 0, see ScummVM access/room.cpp loadPlayField):
--   u8   tilesWidth
--   u8   tilesHeight
--   u16  tilesCount
--   u8   tilesDisplayWidth
--   u8   tilesDisplayHeight
--   u8   unused
--   u16  wallCount
--   u16  blockCount
--   skip 8
--   then 768 byte palette (6-bit VGA), tilesCount * 256 byte tiles (16x16),
--   tilesWidth * tilesHeight u16 tile indices, then wall/block rectangles.
--
-- Full screen (.SCN, see access/files.cpp handleScreen):
--   768 byte palette followed by a DBE compressed 640x400 pixel buffer.
--
-- Sprite frame (see access/asurface.cpp SpriteFrame):
--   u16le width, u16le height, then per row: u8 xOffset, u8 length, length
--   bytes. Index 0 is transparent.
-- ============================================================================

local engine = {}
engine.name        = "Noctropolis"
engine.id          = "noctropolis"
engine.description = "Noctropolis (1994, Electronic Arts)"
engine.version     = "1.0"

-- Binary helpers
local function u8(s, p) return s:byte(p) end
local function u16le(s, p) return s:byte(p) + s:byte(p + 1) * 256 end
local function u32le(s, p)
    return s:byte(p) + s:byte(p + 1) * 256 + s:byte(p + 2) * 65536
         + s:byte(p + 3) * 16777216
end

local function expand6(v) return math.floor(v * 255 / 63) end

-- ── DBE (LZW variant) decompression ─────────────────────────────────
local function bytes_to_string(t, n)
    local parts = {}
    local char = string.char
    local unpackfn = table.unpack or unpack
    local i = 1
    while i <= n do
        local j = i + 4095
        if j > n then j = n end
        parts[#parts + 1] = char(unpackfn(t, i, j))
        i = j + 1
    end
    return table.concat(parts)
end

local function dbe_decompress(src)
    if #src < 16 or src:sub(1, 3) ~= "DBE" then return nil end
    local pos = 17                       -- stream starts at 0-based offset 16
    local len = #src
    local bitsLeft = 8
    local codeLength = 9
    local nextCode = 258
    local maxCode = 512
    local copyBuf, codeTableCode, codeTableVal = {}, {}, {}
    local oldCode, litByte, copyLength = 0, 0, 0
    local out, outLen = {}, 0

    local function get_code()
        if pos > len then return 257 end
        local resultBitsLeft = codeLength
        local resultBitsPos = 0
        local result = 0
        local currentByte = src:byte(pos) or 0
        while resultBitsLeft > 0 do
            if resultBitsLeft < bitsLeft then
                local cur = math.floor(currentByte / 2 ^ (8 - bitsLeft)) % 2 ^ resultBitsLeft
                result = result + cur * 2 ^ resultBitsPos
                bitsLeft = bitsLeft - resultBitsLeft
                resultBitsLeft = 0
            else
                resultBitsLeft = resultBitsLeft - bitsLeft
                local cur = math.floor(currentByte / 2 ^ (8 - bitsLeft))
                result = result + cur * 2 ^ resultBitsPos
                resultBitsPos = resultBitsPos + bitsLeft
                pos = pos + 1
                bitsLeft = 8
                if resultBitsLeft > 0 then currentByte = src:byte(pos) or 0 end
            end
        end
        return result
    end

    while pos <= len + 1 do
        local code = get_code()
        if code == 257 then break end
        if code == 256 then
            codeLength = 9; nextCode = 258; maxCode = 512
            local last = get_code()
            oldCode = last; litByte = last
            outLen = outLen + 1; out[outLen] = last
        else
            local lastCode = code
            if code >= nextCode then
                lastCode = oldCode
                copyBuf[copyLength] = litByte; copyLength = copyLength + 1
            end
            while lastCode > 255 do
                copyBuf[copyLength] = codeTableVal[lastCode]; copyLength = copyLength + 1
                lastCode = codeTableCode[lastCode]
            end
            litByte = lastCode
            copyBuf[copyLength] = lastCode; copyLength = copyLength + 1
            while copyLength > 0 do
                copyLength = copyLength - 1
                outLen = outLen + 1; out[outLen] = copyBuf[copyLength]
            end
            codeTableVal[nextCode] = lastCode
            codeTableCode[nextCode] = oldCode
            nextCode = nextCode + 1
            oldCode = code
            if nextCode >= maxCode and codeLength <= 12 then
                codeLength = codeLength + 1
                maxCode = maxCode * 2
            end
        end
    end

    if outLen == 0 then return nil end
    return bytes_to_string(out, outLen)
end

local function maybe_dbe(data)
    if #data >= 3 and data:sub(1, 3) == "DBE" then
        return dbe_decompress(data) or data
    end
    return data
end

-- Parse an .AP container into its (possibly decompressed) subfiles.
local function load_ap(data)
    local body = maybe_dbe(data)
    local count = u16le(body, 1)
    if count == 0 or count > 4096 then return nil end
    local idx_size = 2 + count * 4
    if #body < idx_size then return nil end
    local offs = {}
    for i = 0, count - 1 do
        local off = u32le(body, 3 + i * 4)
        if off > #body then return nil end
        offs[i] = off
    end
    if offs[0] ~= idx_size then return nil end
    local subs = {}
    for i = 0, count - 1 do
        local s = offs[i] + 1
        local e = (i + 1 < count) and offs[i + 1] or #body
        subs[i + 1] = maybe_dbe(body:sub(s, e))
    end
    return subs
end

local function read_file(path)
    local fp = file_open(path)
    if not fp then return nil end
    local size = file_size(fp)
    local data = file_read(fp, 0, size)
    file_close(fp)
    return data
end

-- ── Playfield (room background) ─────────────────────────────────────
local function load_playfield(data)
    if #data < 19 + 768 then return nil end
    local tw = u8(data, 1)
    local th = u8(data, 2)
    local tilesCount = u16le(data, 3)
    if tw == 0 or th == 0 or tilesCount == 0 then return nil end

    local palPos = 20                     -- 0-based offset 19
    local tilePos = 20 + 768              -- 0-based offset 787
    local matrixPos = tilePos + tilesCount * 256
    if #data < matrixPos + tw * th * 2 - 1 then return nil end

    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = expand6(u8(data, palPos + i * 3))
        palette[i * 3 + 2] = expand6(u8(data, palPos + i * 3 + 1))
        palette[i * 3 + 3] = expand6(u8(data, palPos + i * 3 + 2))
    end

    local W, H = tw * 16, th * 16
    local pixels = {}
    for i = 1, W * H do pixels[i] = 0 end

    for cy = 0, th - 1 do
        for cx = 0, tw - 1 do
            local tileNum = u16le(data, matrixPos + (cy * tw + cx) * 2)
            if tileNum < tilesCount then
                local base = tilePos + tileNum * 256
                for py = 0, 15 do
                    local src = base + py * 16
                    local dst = (cy * 16 + py) * W + cx * 16 + 1
                    for px = 0, 15 do
                        pixels[dst + px] = u8(data, src + px)
                    end
                end
            end
        end
    end

    return image_create_indexed(W, H, pixels, palette), W, H
end

-- ── Full screen image (.SCN) ────────────────────────────────────────
local function load_screen(data)
    if #data < 768 + 4 then return nil end
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = expand6(u8(data, 1 + i * 3))
        palette[i * 3 + 2] = expand6(u8(data, 2 + i * 3))
        palette[i * 3 + 3] = expand6(u8(data, 3 + i * 3))
    end
    local pixels_raw = maybe_dbe(data:sub(769))
    if #pixels_raw < 640 * 400 then return nil end
    local pixels = {}
    for i = 1, 640 * 400 do pixels[i] = pixels_raw:byte(i) end
    return image_create_indexed(640, 400, pixels, palette)
end

-- ── Sprite frames ───────────────────────────────────────────────────
local function sprite_frames(blob)
    local count = u16le(blob, 1)
    if count == 0 or count > 4096 then return nil end
    local idx_size = 2 + count * 4
    if #blob < idx_size then return nil end
    local offs = {}
    for i = 0, count - 1 do
        local off = u32le(blob, 3 + i * 4)
        if off > #blob then return nil end
        offs[i] = off
    end
    if offs[0] ~= idx_size then return nil end

    local result = {}
    for i = 0, count - 1 do
        local s = offs[i] + 1
        local e = (i + 1 < count) and offs[i + 1] or #blob
        local frame = blob:sub(s, e)
        if #frame >= 4 then
            local w = u16le(frame, 1)
            local h = u16le(frame, 3)
            if w > 0 and h > 0 and w <= 2048 and h <= 2048 then
                local pixels = {}
                for k = 1, w * h do pixels[k] = 0 end
                local p = 5
                for y = 0, h - 1 do
                    if p + 1 > #frame then break end
                    local xoff = u8(frame, p)
                    local length = u8(frame, p + 1)
                    p = p + 2
                    for x = 0, length - 1 do
                        local col = xoff + x
                        if col < w then pixels[y * w + col + 1] = u8(frame, p + x) end
                    end
                    p = p + length
                end
                result[#result + 1] = { w = w, h = h, pixels = pixels }
            end
        end
    end
    if #result == 0 then return nil end
    return result
end

-- Icon palette (colors 236..255), hardcoded in the executable.
local ICON_PALETTE = {
    79, 36, 0, 193, 100, 2, 255, 193, 0, 0,
    70, 255, 0, 17, 193, 0, 0, 130, 0, 186,
    0, 0, 96, 0, 255, 0, 0, 140, 0, 0,
    0, 0, 0, 35, 35, 35, 61, 61, 61, 87,
    87, 87, 113, 113, 113, 139, 139, 139, 165, 165,
    165, 191, 191, 191, 217, 217, 217, 252, 252, 252,
}

local function icon_palette()
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
    end
    for i = 0, 19 do
        palette[(236 + i) * 3 + 1] = ICON_PALETTE[i * 3 + 1]
        palette[(236 + i) * 3 + 2] = ICON_PALETTE[i * 3 + 2]
        palette[(236 + i) * 3 + 3] = ICON_PALETTE[i * 3 + 3]
    end
    return palette
end

local function palette_from_blob(blob)
    if #blob < 768 then return nil end
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = expand6(u8(blob, 1 + i * 3))
        palette[i * 3 + 2] = expand6(u8(blob, 2 + i * 3))
        palette[i * 3 + 3] = expand6(u8(blob, 3 + i * 3))
    end
    return palette
end

-- ── Directory resolution ────────────────────────────────────────────
local function join(a, b) return a .. "/" .. b end

-- Returns the DARK data directory and the CD root, or nil.
local function locate(game_path)
    local candidates = {
        { data = join(game_path, "DARK"), root = game_path },
        { data = join(game_path, "dark"), root = game_path },
        { data = join(game_path, "DEMO"), root = game_path },
        { data = join(game_path, "demo"), root = game_path },
    }
    for _, c in ipairs(candidates) do
        if file_exists(join(c.data, "SCENE01.AP")) or file_exists(join(c.data, "scene01.ap")) then
            return c.data, c.root
        end
    end
    if file_exists(join(game_path, "SCENE01.AP")) or file_exists(join(game_path, "scene01.ap")) then
        return game_path, game_path
    end
    return nil, nil
end

local function find_in_dir(dir, name)
    if file_exists(join(dir, name)) then return join(dir, name) end
    local lower = name:lower()
    if file_exists(join(dir, lower)) then return join(dir, lower) end
    if not file_exists(dir) then return nil end
    local files = list_files(dir)
    if not files then return nil end
    for _, f in ipairs(files) do
        if f:lower() == lower then return join(dir, f) end
    end
    return nil
end

-- ── Numbered scene files ────────────────────────────────────────────
local function scene_files(data_dir)
    local scenes = {}
    for n = 1, 99 do
        local name = string.format("SCENE%02d.AP", n)
        if find_in_dir(data_dir, name) then scenes[#scenes + 1] = n end
    end
    return scenes
end

-- ── Resource tree ───────────────────────────────────────────────────
function engine.detect(game_path)
    local data_dir = locate(game_path)
    if not data_dir then return false end
    -- Original release ships SCENE01 + SCENE13; the demo ships SCENE01 + SCENE04.
    return find_in_dir(data_dir, "SCENE13.AP") ~= nil
        or find_in_dir(data_dir, "SCENE04.AP") ~= nil
end

local CHAR_FILES = {
    { name = "PLAYER.AP",   label = "Dark (player)",   icon = false },
    { name = "DARKSHR.AP",  label = "Dark (alt)",      icon = false },
    { name = "STILETTO.AP", label = "Stiletto",        icon = false },
    { name = "TOP.AP",      label = "Top",             icon = false },
    { name = "ICONS.AP",    label = "Interface icons", icon = true },
}

function engine.get_resources(game_path)
    local resources = {}
    local data_dir, root = locate(game_path)
    if not data_dir then return resources end
    local comdata = join(root, "COMDATA")

    -- Backgrounds (scene playfields)
    local bg = { id = "backgrounds", name = "Backgrounds", type = "category", children = {} }
    local scenes = scene_files(data_dir)
    for _, n in ipairs(scenes) do
        bg.children[#bg.children + 1] = {
            id = "bg_scene" .. string.format("%02d", n),
            name = "Scene " .. n,
            type = "image",
        }
    end
    if find_in_dir(data_dir, "MAP.AP") then
        bg.children[#bg.children + 1] = { id = "bg_map", name = "Map", type = "image" }
    end
    if #bg.children > 0 then
        bg.name = string.format("Backgrounds (%d)", #bg.children)
        resources[#resources + 1] = bg
    end

    -- Full screen images (SCN)
    local screens = { id = "screens", name = "Screens", type = "category", children = {} }
    local function add_screens(dir)
        local files = list_files(dir)
        if not files then return end
        local list = {}
        for _, f in ipairs(files) do
            if f:upper():match("%.SCN$") then list[#list + 1] = f end
        end
        table.sort(list)
        for _, f in ipairs(list) do
            screens.children[#screens.children + 1] = {
                id = "scn_" .. f:lower(),
                name = f:gsub("(%.[^%.]+)$", ""),
                type = "image",
            }
        end
    end
    add_screens(data_dir)
    add_screens(comdata)
    if #screens.children > 0 then
        screens.name = string.format("Screens (%d)", #screens.children)
        resources[#resources + 1] = screens
    end

    -- Character / interface sprites
    local spr = { id = "sprites", name = "Sprites", type = "category", children = {} }
    for _, cf in ipairs(CHAR_FILES) do
        local path = find_in_dir(data_dir, cf.name)
        if path then
            local base = cf.name:lower():gsub("%.ap$", "")
            if cf.icon then
                spr.children[#spr.children + 1] = {
                    id = "spr_" .. base, name = cf.label, type = "image",
                }
            else
                local subs = load_ap(read_file(path))
                if subs then
                    for si = 2, #subs do
                        if #subs[si] ~= 768 then
                            spr.children[#spr.children + 1] = {
                                id = "spr_" .. base .. "_" .. si,
                                name = cf.label .. " " .. (si - 1),
                                type = "image",
                            }
                        end
                    end
                end
            end
        end
    end
    if #spr.children > 0 then
        spr.name = string.format("Sprites (%d)", #spr.children)
        resources[#resources + 1] = spr
    end

    return resources
end

-- ── Resource loader ─────────────────────────────────────────────────
function engine.load_resource(game_path, resource_id)
    local data_dir, root = locate(game_path)
    if not data_dir then return nil end

    local scene = resource_id:match("^bg_scene(%d+)$")
    if scene then
        local path = find_in_dir(data_dir, string.format("SCENE%02d.AP", tonumber(scene)))
        if not path then return { type = "text", text = "Missing scene file" } end
        local subs = load_ap(read_file(path))
        if not subs or not subs[1] then return { type = "text", text = "Empty scene file" } end
        local img, w, h = load_playfield(subs[1])
        if not img then return { type = "text", text = "Invalid playfield data" } end
        return {
            type = "image", image = img,
            description = string.format("Scene %s - %dx%d", scene, w, h),
        }
    end

    if resource_id == "bg_map" then
        local path = find_in_dir(data_dir, "MAP.AP")
        if not path then return { type = "text", text = "Missing MAP.AP" } end
        local subs = load_ap(read_file(path))
        if not subs or not subs[1] then return { type = "text", text = "Empty MAP.AP" } end
        local img, w, h = load_playfield(subs[1])
        if not img then return { type = "text", text = "Invalid playfield data" } end
        return { type = "image", image = img, description = string.format("Map - %dx%d", w, h) }
    end

    local scn = resource_id:match("^scn_(.+)$")
    if scn then
        for _, dir in ipairs({ data_dir, join(root, "COMDATA") }) do
            local target = find_in_dir(dir, scn)
            if target then
                local img = load_screen(read_file(target))
                if not img then return { type = "text", text = "Invalid screen data" } end
                return { type = "image", image = img, description = scn }
            end
        end
        return { type = "text", text = "Screen not found: " .. scn }
    end

    local spr = resource_id:match("^spr_(.+)$")
    if spr then
        -- spr_<file>_<sub> (character sets) or spr_<file> (icons)
        local fname, sub = spr:match("^([a-z0-9]+)_(%d+)$")
        if not fname then fname = spr end
        local actual = nil
        for _, cf in ipairs(CHAR_FILES) do
            if cf.name:lower():gsub("%.ap$", "") == fname then actual = cf end
        end
        if not actual then return { type = "text", text = "Unknown sprite file" } end
        local path = find_in_dir(data_dir, actual.name)
        if not path then return { type = "text", text = "Missing " .. actual.name } end
        local data = read_file(path)

        local blob, palette
        if actual.icon then
            -- Whole-file DBE sprite set; palette is built into the executable.
            blob = maybe_dbe(data)
            palette = icon_palette()
        else
            local subs = load_ap(data)
            if not subs then return { type = "text", text = "Invalid container" } end
            sub = tonumber(sub) or 2
            blob = subs[sub]
            for i = #subs, 1, -1 do
                if #subs[i] == 768 then palette = palette_from_blob(subs[i]); break end
            end
            if not palette then palette = icon_palette() end
        end
        if not blob then return { type = "text", text = "Empty sprite data" } end

        local frames = sprite_frames(blob)
        if not frames then return { type = "text", text = "No sprite frames" } end

        local handles = {}
        for i = 1, #frames do
            local fr = frames[i]
            handles[i] = image_create_indexed(fr.w, fr.h, fr.pixels, palette)
        end
        if #handles == 1 then
            return { type = "image", image = handles[1], description = actual.label }
        end
        local anim = animation_create(handles, 150)
        return {
            type = "animation", animation = anim,
            image = handles[1], frames = handles,
            description = string.format("%s - %d frames", actual.label, #handles),
        }
    end

    return nil
end

return engine

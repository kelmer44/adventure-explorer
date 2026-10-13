-- ============================================================================
-- Adventure Explorer - Engine Script: Ringworld & Blue Force (TsAGE Engine)
-- ============================================================================
-- Tsunami Media "RLB" resource library files (ScummVM engines/tsage).
--
-- Data model (verified against ScummVM engines/tsage/resources.cpp):
--   * Every .RLB is a sequence of "TMI-" sections. The root section at file
--     offset 0 holds a single resource (id 0) containing the section index:
--         u16 resNum, u16 configId, u16 fileOffset   (repeat until 0xFFFF)
--         resType    = configId & 0x1F
--         fileOffset = ((configId >> 5) & 0x7FF) << 16 | fileOffset
--   * Each section is itself a "TMI-" block:
--         "TMI-" magic, u8 unknown1, u8 numEntries
--         entry (12 bytes): u16 id, u16 size, u16 uncSize, u8 sizeHi, u8 t, u32 offset
--         storedSize  = size   | ((sizeHi & 0x0F) << 16)
--         uncSize     = uncSize| ((sizeHi & 0xF0) << 12)
--         compressed  = (t >> 5) != 0
--   * Compressed resources use a 9 -> 12 bit LSB-first LZW stream terminated
--     by code 0x101 (code 0x100 resets the table); see lzw_decompress.
--   * Scenes: RES_BITMAP section resNum = scene number. Resource 9999 holds
--     u16 width / u16 height. Background tiles are resources
--     id = xSection*yHalfCount + ySection (xHalfCount=ceil(w/160),
--     yHalfCount=ceil(h/100)); each tile is raw 8bpp 160x100.
--   * Palettes: RES_PALETTE section, resource 0. Data after decompression:
--     u16 palStart, u16 palCount, then palCount*3 RGB bytes (8-bit channels).
--   * Sprites: RES_VISAGE sections, resource 9999 is a frame-set index. Each
--     other resource is a frame set: u16 numFrames + u32 offset table, then
--     numFrames surfaceFromRes records (u16 w, u16 h, u16 cx, u16 cy,
--     u8 transColor, u8 flags, then raw or per-row RLE pixel data at +10).
--   * Text: RES_MESSAGE sections, resource 0, NUL separated strings (CP850).
--   * Sound resources are scored Adlib/MIDI tracker data that require the
--     game's sound driver to play; only header metadata is exposed here.
--
-- Categories exposed: Backgrounds, Palettes, Sprites (animated frame sets),
-- Messages (text). Sounds and other sections are listed but not decoded.
-- ============================================================================

local engine = {}
engine.name        = "TsAGE"
engine.id          = "tsage"
engine.description = "Ringworld & Blue Force (1992-1994, Tsunami Media)"
engine.version     = "1.0"

-- ============================================================================
-- Binary helpers (positions are 1 based, matching Lua string indexing)
-- ============================================================================

local function u8(data, pos) return data:byte(pos) or 0 end

local function u16le(data, pos)
    return (data:byte(pos) or 0) + (data:byte(pos + 1) or 0) * 256
end

local function u32le(data, pos)
    return (data:byte(pos) or 0) + (data:byte(pos + 1) or 0) * 256
         + (data:byte(pos + 2) or 0) * 65536 + (data:byte(pos + 3) or 0) * 16777216
end

-- ============================================================================
-- Resource type constants (ResourceType enum in resources.h)
-- ============================================================================

local RES_STRIP, RES_IMAGE = 1, 2
local RES_PALETTE, RES_VISAGE, RES_SOUND, RES_MESSAGE, RES_FONT = 3, 4, 5, 6, 7
local RES_PRIORITY, RES_BITMAP, RES_SEQUENCE = 11, 14, 16

-- ============================================================================
-- Detection
-- ============================================================================

local GAME_DIRS = {
    { name = "Ringworld", marker = { "RING.RLB", "ring.rlb" }, defPal = { 0, 0 } },
    { name = "Blue Force", marker = { "BLUE.RLB", "blue.rlb" }, defPal = { 1, 0 } },
}

local function file_exists_any(game_path, names)
    for _, n in ipairs(names) do
        if file_exists(game_path .. "/" .. n) then return true end
    end
    return false
end

local function detect_game(game_path)
    if not file_exists_any(game_path, { "TSAGE.CFG", "tsage.cfg" }) then return nil end
    for _, g in ipairs(GAME_DIRS) do
        if file_exists_any(game_path, g.marker) then return g end
    end
    return nil
end

function engine.detect(game_path)
    return detect_game(game_path) ~= nil
end

-- ============================================================================
-- LZW decompression (resources.cpp getResource)
-- 9 -> 12 bit codes, LSB-first. 0x100 = dictionary reset, 0x101 = end marker.
-- ============================================================================

local function lzw_decompress(data, uncSize)
    if uncSize < 0 then uncSize = 0 end

    local pos, cur, bitsLeft = 1, 0, 0
    local numBits = 9

    local function readByte()
        local b = data:byte(pos)
        pos = pos + 1
        return b or 0
    end

    local function readToken()
        local got, result = 0, 0
        while got < numBits do
            if bitsLeft == 0 then
                cur = readByte()
                bitsLeft = 8
            end
            local take = numBits - got
            if take > bitsLeft then take = bitsLeft end
            local part = cur % (2 ^ take)
            cur = math.floor(cur / (2 ^ take))
            bitsLeft = bitsLeft - take
            result = result + part * (2 ^ got)
            got = got + take
        end
        return result
    end

    local vWord, vByte = {}, {}
    for i = 0, 0xFFF do vWord[i] = 0; vByte[i] = 0 end

    local ctrCurrent, ctrMax = 0x102, 0x200
    local curToken, prevWord, prevByte, nextByte = 0, 0, 0, 0
    local out, written = {}, 0
    local tokenLimit = uncSize * 2 + 32
    local tokens = 0

    while true do
        tokens = tokens + 1
        if tokens > tokenLimit then break end

        local token = readToken()
        if token == 0x101 then
            break
        elseif token == 0x100 then
            numBits = 9
            ctrMax = 0x200
            ctrCurrent = 0x102
            curToken = readToken()
            nextByte = curToken % 256
            prevByte = nextByte
            out[written + 1] = string.char(nextByte)
            written = written + 1
        else
            prevWord = token
            local tl, tln = {}, 0
            if token >= ctrCurrent and ctrCurrent <= 0xFFF then
                prevWord = curToken
                tln = tln + 1
                tl[tln] = prevByte
            end
            while prevWord >= 0x100 do
                if prevWord >= 0x1000 then break end
                tln = tln + 1
                tl[tln] = vByte[prevWord]
                prevWord = vWord[prevWord]
                if tln > 0x4000 then break end
            end
            nextByte = prevWord % 256
            prevByte = nextByte
            tln = tln + 1
            tl[tln] = prevWord % 256

            for i = tln, 1, -1 do
                out[written + 1] = string.char(tl[i])
                written = written + 1
            end

            if ctrCurrent <= 0xFFF then
                vByte[ctrCurrent] = nextByte
                vWord[ctrCurrent] = curToken
                ctrCurrent = ctrCurrent + 1
            end
            curToken = token

            if ctrCurrent >= ctrMax and numBits ~= 12 then
                numBits = numBits + 1
                ctrMax = ctrMax * 2
            end
        end
    end

    local result = table.concat(out)
    if #result > uncSize then result = string.sub(result, 1, uncSize) end
    return result
end

-- ============================================================================
-- RLB file access
-- ============================================================================

local lib_cache = {}
local sec_cache = {}

local function open_lib_file(game_path, name)
    local path = game_path .. "/" .. name
    if not file_exists(path) then return nil end
    local handle = file_open(path)
    if not handle then return nil end
    local size = file_size(handle)
    if not size then
        file_close(handle)
        return nil
    end
    return { handle = handle, size = math.floor(size), path = path }
end

local function close_lib_file(f)
    if f and f.handle then file_close(f.handle) end
end

local function read_at(f, offset, length)
    if not f or length <= 0 or offset < 0 then return nil end
    if offset + length > f.size then length = f.size - offset end
    if length <= 0 then return nil end
    return file_read(f.handle, offset, length)
end

-- Parse a "TMI-" section header at a file offset into entry records.
local function parse_section_entries(f, offset)
    local hdr = read_at(f, offset, 6)
    if not hdr or #hdr < 6 then return nil end
    if hdr:byte(1) ~= 0x54 or hdr:byte(2) ~= 0x4D or hdr:byte(3) ~= 0x49 or hdr:byte(4) ~= 0x2D then
        return nil
    end
    local num = hdr:byte(6)
    if num == 0 then return {} end

    local raw = read_at(f, offset + 6, num * 12)
    if not raw or #raw < num * 12 then return nil end

    local out = {}
    for i = 0, num - 1 do
        local p = i * 12 + 1
        local sizeHi = raw:byte(p + 6)
        local typeWord = raw:byte(p + 7)
        out[#out + 1] = {
            id   = u16le(raw, p),
            size = u16le(raw, p + 2) + (sizeHi % 16) * 65536,
            unc  = u16le(raw, p + 4) + math.floor(sizeHi / 16) * 4096,
            comp = math.floor(typeWord / 32) % 2,
            off  = u32le(raw, p + 8),
        }
    end
    return out
end

-- Parse the root section index into {rType, rNum, offset} records.
local function parse_section_index(raw)
    local out = {}
    local p = 1
    while p + 5 <= #raw do
        local rn = u16le(raw, p)
        if rn == 0xFFFF then break end
        local cfg = u16le(raw, p + 2)
        local fo = u16le(raw, p + 4)
        out[#out + 1] = {
            rType = cfg % 32,
            rNum  = rn,
            offset = math.floor(cfg / 32 % 2048) * 65536 + fo,
        }
        p = p + 6
    end
    return out
end

-- A library record: name, game path, ordered section list and per-type index.
local function load_lib(game_path, name)
    local key = game_path .. "|" .. name
    local cached = lib_cache[key]
    if cached then return cached end

    local f = open_lib_file(game_path, name)
    if not f then return nil end

    local sections = {}
    local root = parse_section_entries(f, 0)
    if root then
        for _, re in ipairs(root) do
            if re.id == 0 then
                local raw = read_at(f, re.off, re.size)
                if raw then
                    if re.comp ~= 0 then raw = lzw_decompress(raw, re.unc) end
                    sections = parse_section_index(raw)
                end
                break
            end
        end
    end
    close_lib_file(f)

    local byType = {}
    for _, s in ipairs(sections) do
        local t = byType[s.rType]
        if not t then t = {}; byType[s.rType] = t end
        t[s.rNum] = s.offset
    end

    cached = { game_path = game_path, name = name, sections = sections, byType = byType }
    lib_cache[key] = cached
    return cached
end

-- Resources living in a loaded section behind a logical lib handle.
local function section_entries(lib, offset)
    local key = lib.game_path .. "|" .. lib.name .. "@" .. offset
    local cached = sec_cache[key]
    if cached then return cached end

    local f = open_lib_file(lib.game_path, lib.name)
    local entries = f and parse_section_entries(f, offset) or {}
    close_lib_file(f)

    sec_cache[key] = entries
    return entries
end

local function section_resource(lib, offset, rlbNum)
    for _, re in ipairs(section_entries(lib, offset)) do
        if re.id == rlbNum then return re end
    end
    return nil
end

-- Read (and decompress) a resource body from a section.
local function read_resource(lib, offset, re)
    local f = open_lib_file(lib.game_path, lib.name)
    if not f then return nil end
    local raw = read_at(f, offset + re.off, re.size)
    close_lib_file(f)
    if not raw then return nil end
    if re.comp ~= 0 then
        return lzw_decompress(raw, re.unc)
    end
    return raw
end

-- Find a section of a given type/number across the library list.
local function locate(libs, rType, rNum)
    for _, lib in ipairs(libs) do
        local t = lib.byType[rType]
        local off = t and t[rNum]
        if off then return lib, off end
    end
    return nil, nil
end

-- ============================================================================
-- Palettes
-- 8-bit RGB components (0-255). Data: u16 start, u16 count, then count*3 RGB.
-- ============================================================================

local function palette_entries(libs, sectionNum, rlbNum)
    local lib, sec = locate(libs, RES_PALETTE, sectionNum)
    if not lib then return nil end
    local re = section_resource(lib, sec, rlbNum)
    if not re then return nil end
    local data = read_resource(lib, sec, re)
    if not data or #data < 6 then return nil end
    local start = u16le(data, 1)
    local count = u16le(data, 3)
    if start >= 256 then return nil end
    count = math.min(count, 256 - start)
    local rgb = {}
    for i = 0, count - 1 do
        local p = 6 + i * 3 + 1
        rgb[start + i] = { data:byte(p) or 0, data:byte(p + 1) or 0, data:byte(p + 2) or 0 }
    end
    return rgb
end

-- 768 entry RGB table for image_create_indexed (indexes 0-255).
local function palette_table(rgb)
    local t = {}
    for i = 0, 255 do
        local c = rgb and rgb[i]
        t[i * 3 + 1] = c and c[1] or 0
        t[i * 3 + 2] = c and c[2] or 0
        t[i * 3 + 3] = c and c[3] or 0
    end
    return t
end

local function grayscale_table()
    local t = {}
    for i = 0, 255 do
        t[i * 3 + 1] = i
        t[i * 3 + 2] = i
        t[i * 3 + 3] = i
    end
    return t
end

-- Preferred palette for a sprite section: same-numbered scene palette when one
-- exists, otherwise the game's dialog/interface palette.
local function sprite_palette(libs, resNum, game)
    local rgb = palette_entries(libs, resNum, 0)
    if not rgb then
        rgb = palette_entries(libs, game.defPal[1], game.defPal[2])
    end
    return rgb and palette_table(rgb) or grayscale_table()
end

-- ============================================================================
-- Image decoders
-- All return 1 based tables of colour indexes.
-- ============================================================================

-- surfaceFromRes record (graphics.cpp surfaceFromRes).
local function decode_surface(data, pos)
    local w = u16le(data, pos)
    local h = u16le(data, pos + 2)
    if w <= 0 or h <= 0 or w > 2048 or h > 2048 then return nil end
    local transColor = u8(data, pos + 8)
    local flags = u8(data, pos + 9)
    local len = w * h
    local pixels = {}
    local src = pos + 10

    if flags % 2 == 0 then
        for i = 0, len - 1 do
            pixels[i + 1] = u8(data, src + i)
        end
    else
        for i = 1, len do pixels[i] = transColor end
        for y = 0, h - 1 do
            local x = 0
            while x < w do
                local ctrl = u8(data, src)
                src = src + 1
                if ctrl < 128 then
                    if src + ctrl - 1 > #data then return nil end
                    for j = 0, ctrl - 1 do
                        pixels[y * w + x + 1] = u8(data, src)
                        src = src + 1
                        x = x + 1
                    end
                elseif ctrl < 192 then
                    x = x + ctrl % 64
                else
                    local run = ctrl % 64
                    local col = u8(data, src)
                    src = src + 1
                    for j = 0, run - 1 do
                        if x < w then pixels[y * w + x + 1] = col end
                        x = x + 1
                    end
                end
            end
        end
    end

    return pixels, w, h
end

-- ============================================================================
-- Resource tree
-- ============================================================================

local function get_libs(game_path)
    local files = list_files(game_path) or {}
    local names = {}
    for _, fn in ipairs(files) do
        local up = string.upper(fn)
        if string.sub(up, -4) == ".RLB" and up ~= "INSTALL.RLB" then
            names[#names + 1] = fn
        end
    end
    table.sort(names)

    local libs = {}
    for _, name in ipairs(names) do
        local lib = load_lib(game_path, name)
        if lib and #lib.sections > 0 then libs[#libs + 1] = lib end
    end
    return libs
end

local function sorted_sections(lib, rType)
    local out = {}
    for rNum in pairs(lib.byType[rType] or {}) do
        out[#out + 1] = rNum
    end
    table.sort(out)
    return out
end

function engine.get_resources(game_path)
    local game = detect_game(game_path)
    if not game then return {} end

    local libs = get_libs(game_path)
    if #libs == 0 then return {} end

    local backgrounds, palettes, sprites, messages, sounds = {}, {}, {}, {}, {}

    for _, lib in ipairs(libs) do
        for _, sec in ipairs(lib.sections) do
            local rType, rNum = sec.rType, sec.rNum

            if rType == RES_BITMAP then
                local dim = section_resource(lib, sec.offset, 9999)
                local d = dim and read_resource(lib, sec.offset, dim)
                if d and #d >= 4 then
                    local w, h = u16le(d, 1), u16le(d, 3)
                    local tileCount = 0
                    for _, e in ipairs(section_entries(lib, sec.offset)) do
                        if e.id ~= 9999 then tileCount = tileCount + 1 end
                    end
                    backgrounds[#backgrounds + 1] = {
                        id   = "bg_" .. rNum,
                        name = string.format("Scene %d - %dx%d (%d blocks)", rNum, w, h, tileCount),
                        type = "image",
                    }
                end
            elseif rType == RES_PALETTE then
                if section_resource(lib, sec.offset, 0) then
                    palettes[#palettes + 1] = {
                        id   = "pal_" .. rNum,
                        name = "Palette " .. rNum,
                        type = "image",
                    }
                end
            elseif rType == RES_VISAGE then
                local sets = {}
                for _, e in ipairs(section_entries(lib, sec.offset)) do
                    if e.id ~= 9999 then
                        sets[#sets + 1] = {
                            id   = string.format("spr_%d_%d", rNum, e.id),
                            name = "Set " .. e.id,
                            type = "image",
                        }
                    end
                end
                table.sort(sets, function(a, b) return a.name < b.name end)
                if #sets > 0 then
                    sprites[#sprites + 1] = {
                        id       = string.format("cat_vis_%d", rNum),
                        name     = string.format("Visage %d (%d)", rNum, #sets),
                        type     = "category",
                        children = sets,
                    }
                end
            elseif rType == RES_MESSAGE then
                if section_resource(lib, sec.offset, 0) then
                    messages[#messages + 1] = {
                        id   = "msg_" .. rNum,
                        name = "Message " .. rNum,
                        type = "text",
                    }
                end
            elseif rType == RES_SOUND then
                if section_resource(lib, sec.offset, 0) then
                    sounds[#sounds + 1] = {
                        id   = "snd_" .. rNum,
                        name = "Sound " .. rNum,
                        type = "text",
                    }
                end
            end
        end
    end

    -- De-duplicate palette / visage / message / sound sections that exist in
    -- more than one library (the shared TSAGE.RLB and FILES.RLB overlap).
    local function dedupe(items)
        local seen, out = {}, {}
        for _, it in ipairs(items) do
            if not seen[it.id] then
                seen[it.id] = true
                out[#out + 1] = it
            end
        end
        return out
    end

    backgrounds = dedupe(backgrounds)
    palettes = dedupe(palettes)
    messages = dedupe(messages)
    sounds = dedupe(sounds)

    local label = game.name
    local resources = {}

    if #backgrounds > 0 then
        resources[#resources + 1] = {
            id       = "cat_backgrounds",
            name     = string.format("%s - Backgrounds (%d)", label, #backgrounds),
            type     = "category",
            children = backgrounds,
        }
    end
    if #sprites > 0 then
        resources[#resources + 1] = {
            id       = "cat_sprites",
            name     = string.format("%s - Sprites (%d visages)", label, #sprites),
            type     = "category",
            children = sprites,
        }
    end
    if #palettes > 0 then
        resources[#resources + 1] = {
            id       = "cat_palettes",
            name     = string.format("%s - Palettes (%d)", label, #palettes),
            type     = "category",
            children = palettes,
        }
    end
    if #messages > 0 then
        resources[#resources + 1] = {
            id       = "cat_messages",
            name     = string.format("%s - Messages (%d)", label, #messages),
            type     = "category",
            children = messages,
        }
    end
    if #sounds > 0 then
        resources[#resources + 1] = {
            id       = "cat_sounds",
            name     = string.format("%s - Sound metadata (%d)", label, #sounds),
            type     = "category",
            children = sounds,
        }
    end

    return resources
end

-- ============================================================================
-- CP850 -> UTF-8 (message text and sound names use the DOS codepage)
-- ============================================================================

local CP850 = {
    0x00C7,0x00FC,0x00E9,0x00E2,0x00E4,0x00E0,0x00E5,0x00E7,0x00EA,0x00EB,0x00E8,0x00EF,0x00EE,0x00EC,0x00C4,0x00C5,
    0x00C9,0x00E6,0x00C6,0x00F4,0x00F6,0x00F2,0x00FB,0x00F9,0x00FF,0x00D6,0x00DC,0x00F8,0x00A3,0x00D8,0x00D7,0x0192,
    0x00E1,0x00ED,0x00F3,0x00FA,0x00F1,0x00D1,0x00AA,0x00BA,0x00BF,0x00AE,0x00AC,0x00BD,0x00BC,0x00A1,0x00AB,0x00BB,
    0x2591,0x2592,0x2593,0x2502,0x2524,0x00C1,0x00C2,0x00C0,0x00A9,0x2563,0x2551,0x2557,0x255D,0x00A2,0x00A5,0x2510,
    0x2514,0x2534,0x252C,0x251C,0x2500,0x253C,0x00E3,0x00C3,0x255A,0x2554,0x2569,0x2566,0x2560,0x2550,0x256C,0x00A4,
    0x00F0,0x00D0,0x00CA,0x00CB,0x00C8,0x0131,0x00CD,0x00CE,0x00CF,0x2518,0x250C,0x2588,0x2584,0x00A6,0x00CC,0x2580,
    0x00D3,0x00DF,0x00D4,0x00D2,0x00F5,0x00D5,0x00B5,0x00FE,0x00DE,0x00DA,0x00DB,0x00D9,0x00FD,0x00DD,0x00AF,0x00B4,
    0x00AD,0x00B1,0x2017,0x00BE,0x00B6,0x00A7,0x00F7,0x00B8,0x00B0,0x00A8,0x00B7,0x00B9,0x00B3,0x00B2,0x25A0,0x00A0,
}

local function utf8_char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    else
        return string.char(0xE0 + math.floor(cp / 4096),
            0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
end

local function cp850_bytes(bytes)
    local out = {}
    for _, b in ipairs(bytes) do
        if b < 0x80 then
            out[#out + 1] = string.char(b)
        else
            out[#out + 1] = utf8_char(CP850[b - 0x7F])
        end
    end
    return table.concat(out)
end

-- ============================================================================
-- Resource loading
-- ============================================================================

local function load_background(libs, lib, sec, resNum)
    local dim = section_resource(lib, sec, 9999)
    if not dim then return nil end
    local d = read_resource(lib, sec, dim)
    if not d or #d < 4 then return nil end
    local w, h = u16le(d, 1), u16le(d, 3)
    if w <= 0 or h <= 0 or w > 4096 or h > 4096 then return nil end

    local xc = math.ceil(w / 160)
    local yc = math.ceil(h / 100)
    local total = w * h
    local pixels = {}
    for i = 1, total do pixels[i] = 0 end

    for _, e in ipairs(section_entries(lib, sec)) do
        if e.id ~= 9999 then
            local xs = math.floor(e.id / yc)
            local ys = e.id % yc
            if xs < xc and ys < yc then
                local block = read_resource(lib, sec, e)
                if block and #block >= 16000 then
                    local bx, by = xs * 160, ys * 100
                    for yy = 0, 99 do
                        local dst = (by + yy) * w + bx
                        local src = yy * 160
                        for xx = 0, 159 do
                            pixels[dst + xx + 1] = block:byte(src + xx + 1)
                        end
                    end
                end
            end
        end
    end

    return pixels, w, h
end

local function load_sprite(libs, game, resNum, rlbNum)
    local lib, sec = locate(libs, RES_VISAGE, resNum)
    if not lib then return nil end
    local re = section_resource(lib, sec, rlbNum)
    if not re then return nil end
    local d = read_resource(lib, sec, re)
    if not d or #d < 4 then return nil end

    local numFrames = u16le(d, 1)
    if numFrames < 1 or numFrames > 64 then return nil end
    if 2 + numFrames * 4 > #d then return nil end

    local frames = {}
    for i = 0, numFrames - 1 do
        local start = u32le(d, 3 + i * 4)
        local stop = (i == numFrames - 1) and #d or u32le(d, 3 + (i + 1) * 4)
        if start < 0 or stop <= start or stop > #d or stop - start < 10 then return nil end
        local pixels, w, h = decode_surface(d, start + 1)
        if not pixels then return nil end
        local img = image_create_indexed(w, h, pixels, sprite_palette(libs, resNum, game))
        if not img then return nil end
        frames[#frames + 1] = img
    end

    return frames
end

local function load_palette_image(libs, resNum)
    local rgb = palette_entries(libs, resNum, 0)
    if not rgb then return nil end
    local pal = palette_table(rgb)

    local t = {}
    for y = 0, 15 do
        for x = 0, 15 do
            local idx = y * 16 + x
            for cy = 0, 7 do
                local row = (y * 8 + cy) * 128
                for cx = 0, 7 do
                    t[row + x * 8 + cx + 1] = idx
                end
            end
        end
    end

    return image_create_indexed(128, 128, t, pal), pal
end

local function load_message(libs, resNum)
    local lib, sec = locate(libs, RES_MESSAGE, resNum)
    if not lib then return nil end
    local re = section_resource(lib, sec, 0)
    if not re then return nil end
    local d = read_resource(lib, sec, re)
    if not d then return nil end

    local lines, cur = {}, {}
    for i = 1, #d do
        local b = d:byte(i)
        if b == 0 then
            if #cur > 0 then
                lines[#lines + 1] = cp850_bytes(cur)
                cur = {}
            end
        else
            cur[#cur + 1] = b
        end
    end
    if #cur > 0 then lines[#lines + 1] = cp850_bytes(cur) end

    if #lines == 0 then return nil end
    return string.format("Message %d (%d strings):\n\n%s", resNum, #lines, table.concat(lines, "\n"))
end

local function load_sound_meta(libs, resNum)
    local lib, sec = locate(libs, RES_SOUND, resNum)
    if not lib then return nil end
    local re = section_resource(lib, sec, 0)
    if not re then return nil end
    local d = read_resource(lib, sec, re)
    if not d or #d < 16 then return nil end

    return string.format(
        "Sound %d - Adlib/MIDI tracker data (not playable in explorer).\n\n" ..
        "Format version range: %d..%d (driver expects 0x102)\n" ..
        "Group table offset: %d\nPriority: %d\nLoop: %s\n" ..
        "Data size: %d bytes",
        resNum, u16le(d, 7), u16le(d, 5), u16le(d, 9), u16le(d, 13),
        u16le(d, 15) ~= 0 and "yes" or "no", #d)
end

function engine.load_resource(game_path, resource_id)
    local game = detect_game(game_path)
    if not game then return nil end

    local libs = get_libs(game_path)
    if #libs == 0 then return nil end

    local id = tostring(resource_id)
    local kind, arg1, arg2 = id:match("^(%a+)_(%d+)_(%d+)$")
    if not kind then
        kind, arg1 = id:match("^(%a+)_(%d+)$")
    end
    if not kind or not arg1 then
        return { type = "text", text = "Unknown resource: " .. id }
    end
    arg1, arg2 = tonumber(arg1), arg2 and tonumber(arg2)

    -- Backgrounds
    if kind == "bg" then
        local lib, sec = locate(libs, RES_BITMAP, arg1)
        if not lib then return nil end
        local ok, pixels, w, h = pcall(load_background, libs, lib, sec, arg1)
        if not ok or not pixels then
            return { type = "text", text = "Cannot decode background " .. arg1 }
        end
        local rgb = palette_entries(libs, arg1, 0)
        local img = image_create_indexed(w, h, pixels,
            rgb and palette_table(rgb) or grayscale_table())
        if not img then return nil end
        return {
            type        = "image",
            image       = img,
            description = string.format("%s - Scene %d (%dx%d)",
                game.name, arg1, w, h),
        }
    end

    -- Sprites / animations
    if kind == "spr" then
        local ok, frames = pcall(load_sprite, libs, game, arg1, arg2)
        if not ok or not frames or #frames == 0 then
            return { type = "text", text = "Cannot decode sprite " .. id }
        end
        if #frames == 1 then
            return {
                type        = "image",
                image       = frames[1],
                description = string.format("%s - Visage %d set %d", game.name, arg1, arg2),
            }
        end
        local anim = animation_create(frames, 100)
        if not anim then return nil end
        return {
            type        = "animation",
            animation   = anim,
            image       = frames[1],
            frames      = frames,
            delay_ms    = 100,
            description = string.format("%s - Visage %d set %d (%d frames)",
                game.name, arg1, arg2, #frames),
        }
    end

    -- Palettes
    if kind == "pal" then
        local ok, img, pal = pcall(load_palette_image, libs, arg1)
        if not ok or not img then
            return { type = "text", text = "Cannot decode palette " .. arg1 }
        end
        local rgb = palette_entries(libs, arg1, 0)
        local count = 0
        if rgb then
            for _ in pairs(rgb) do count = count + 1 end
        end
        return {
            type        = "image",
            image       = img,
            description = string.format("%s - Palette %d (%d colours)",
                game.name, arg1, count),
        }
    end

    -- Messages
    if kind == "msg" then
        local ok, text = pcall(load_message, libs, arg1)
        if not ok or not text then
            return { type = "text", text = "Cannot decode message " .. arg1 }
        end
        return { type = "text", text = text }
    end

    -- Sound metadata
    if kind == "snd" then
        local ok, text = pcall(load_sound_meta, libs, arg1)
        if not ok or not text then
            return { type = "text", text = "Cannot read sound " .. arg1 }
        end
        return { type = "text", text = text }
    end

    return { type = "text", text = "Unknown resource: " .. id }
end

return engine
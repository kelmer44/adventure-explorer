-- DOS SCUMM V4 (Monkey Island EGA and VGA): plaintext 000.LFL directory and
-- XOR-0x69 DISKnn.LEC archives. Sizes include the six-byte small header.
-- VGA rooms carry a PA palette and small-header strip bitmaps that use the V5
-- codecs; engine.lua sets V.decode_smap to its decoder.
-- References: ScummVM resource_v4.cpp, resource.cpp, object.cpp, costume.cpp,
-- gfx.cpp (Gdi::getStripPtr small header), sound.cpp (readSoundResourceSmallHeader,
-- convertADResource), midiparser_ro.cpp, charset.cpp (CharsetRendererClassic).
local U = require("scumm_util")
local EGA = require("scumm_v3")
local Cost = require("scumm_cost")
local V = {}
local TRANSPARENT = 255 -- ScummVM default when a room has no TRNS colour
local W, D = U.u16le, U.u32le

local function read(path)
    local f = file_open(path)
    if not f then return nil end
    local d = file_read(f, 0, file_size(f))
    file_close(f)
    return d
end

-- Positions here are one-based string indices; archive offsets are zero-based.
local function blocks(d, first, last)
    local out, p = {}, first or 1
    last = last or #d
    while p <= last do
        if p + 5 > last then return nil end
        local size = D(d, p)
        if size < 6 or p + size - 1 > last then return nil end
        out[#out + 1] = { tag = d:sub(p + 4, p + 5), pos = p, size = size }
        p = p + size
    end
    return out
end

local function index(d)
    if not d then return nil end
    local bs = blocks(d)
    if not bs then return nil end
    local idx = { names = {} }
    local kinds = { ["0R"] = "rooms", ["0C"] = "costumes", ["0S"] = "scripts", ["0N"] = "sounds" }
    for _, b in ipairs(bs) do
        local kind = kinds[b.tag]
        if kind then
            local n = W(d, b.pos + 6)
            if idx[kind] or b.size ~= 8 + n * 5 or (kind == "rooms" and n > 256) then return nil end
            local entries = {}
            for id = 0, n - 1 do
                local p = b.pos + 8 + id * 5
                local room, offset = d:byte(p), D(d, p + 1)
                if room ~= 0 and offset ~= 0xffffffff then
                    entries[id] = { room = room, offset = offset }
                end
            end
            idx[kind] = entries
            if kind == "costumes" then idx.costume_count = n end
        elseif b.tag == "RN" then
            local p, last = b.pos + 6, b.pos + b.size - 1
            while p <= last and d:byte(p) ~= 0 do
                if p + 9 > last then return nil end
                idx.names[d:byte(p)] = xor_bytes(d:sub(p + 1, p + 9), "\255"):match("^[^%z]*")
                p = p + 10
            end
            if p ~= last or d:byte(p) ~= 0 then return nil end
        elseif b.tag == "0O" then
            if b.size ~= 8 + W(d, b.pos + 6) * 4 then return nil end
        else
            return nil
        end
    end
    if not idx.rooms or not idx.costumes or not idx.scripts or not idx.sounds then return nil end
    return idx
end

local cache
local function state(path)
    local raw = read(path .. "/000.LFL")
    if not raw then return nil end
    if cache and cache.path == path and cache.raw == raw then return cache end
    local idx = index(raw)
    if not idx then return nil end
    local s = { path = path, raw = raw, idx = idx, disks = {}, room_cache = {}, costume_cache = {} }
    cache = s
    return s
end

local function disk(s, number)
    if s.disks[number] ~= nil then return s.disks[number] or nil end
    s.disks[number] = false
    local raw = read(string.format("%s/DISK%02d.LEC", s.path, number))
    if not raw then return nil end
    local d = xor_bytes(raw, string.char(0x69))
    if #d < 13 or D(d, 1) ~= #d or d:sub(5, 6) ~= "LE" or d:sub(11, 12) ~= "FO"
        or D(d, 7) ~= 7 + d:byte(13) * 5 then return nil end
    local n, rooms = d:byte(13), {}
    if 13 + n * 5 > #d then return nil end
    for i = 0, n - 1 do
        local p = 14 + i * 5
        local id, offset = d:byte(p), D(d, p + 1)
        if offset + 8 > #d or d:sub(offset + 5, offset + 6) ~= "LF" then return nil end
        local size = D(d, offset + 1)
        if size < 8 or offset + size > #d then return nil end
        rooms[id] = { offset = offset, size = size }
    end
    local out = { data = d, rooms = rooms }
    s.disks[number] = out
    return out
end

local function resource(s, room, offset, tag)
    local entry = s.idx.rooms[room]
    local archive = entry and disk(s, entry.room)
    local r = archive and archive.rooms[room]
    if not r then return nil end
    -- V4 directory offsets include an eight-byte LF wrapper before the resource.
    local p = r.offset + (offset or 0) + 9
    local size = D(archive.data, p)
    if size < 6 or p + size - 1 > r.offset + r.size or archive.data:sub(p + 4, p + 5) ~= tag then return nil end
    return archive.data:sub(p, p + size - 1)
end

local function room(s, id)
    if s.room_cache[id] ~= nil then return s.room_cache[id] or nil end
    s.room_cache[id] = false
    local d = resource(s, id, 0, "RO")
    local bs = d and blocks(d, 7)
    if not bs then return nil end
    local hd, bm, pa, objects, images = nil, nil, nil, {}, {}
    for _, b in ipairs(bs) do
        if b.tag == "HD" and b.size >= 12 then hd = b
        elseif b.tag == "BM" then bm = b
        elseif b.tag == "PA" and b.size >= 8 + 768 and W(d, b.pos + 6) == 768 then pa = b
        elseif b.tag == "OC" and b.size >= 19 then
            -- ScummVM resetRoomObject (V4): x/8 at +9, y/8 (low 7 bits) at +10,
            -- w/8 at +11, height in the top five bits of +17 (zero-based offsets).
            objects[W(d, b.pos + 6)] = { w = d:byte(b.pos + 11) * 8,
                h = math.floor(d:byte(b.pos + 17) / 8) * 8,
                x = d:byte(b.pos + 9) * 8, y = d:byte(b.pos + 10) % 128 * 8 }
        elseif b.tag == "OI" and b.size >= 12 then images[#images + 1] = b end
    end
    if not hd or not bm then return nil end
    local w, h = W(d, hd.pos + 6), W(d, hd.pos + 8)
    if w == 0 or w % 8 ~= 0 or w > 2048 or h == 0 or h > 512 then return nil end
    -- VGA bitmaps: u32 length, then one u32 offset per 8-pixel strip, all relative
    -- to the bitmap start. EGA bitmaps use u16 fields (zero-based start below).
    local function vga_ok(p, size, width)
        local len, first = D(d, p), D(d, p + 4)
        return len <= size and first == 4 + width / 8 * 4 and len > first
    end
    local start, palette
    if pa then
        start = bm.pos + 6
        if bm.size < 14 or not vga_ok(start, bm.size - 6, w) then return nil end
        palette = {}
        for i = 1, 768 do palette[i] = d:byte(pa.pos + 7 + i) end
    else
        start = bm.pos + 5 -- zero-based offset of the BM payload
        local size, first = W(d, start + 1), W(d, start + 3)
        if bm.size < 10 or first ~= 2 + w / 4 or size <= first or size > bm.size - 6 then return nil end
    end
    local sprites = {}
    for _, b in ipairs(images) do
        local oid = W(d, b.pos + 6)
        local obj = objects[oid]
        if obj and obj.w > 0 and obj.h > 0 then
            local image, ok
            if pa then
                image = b.pos + 8 -- OI payload: u16 object ID, then the bitmap.
                ok = b.size >= 16 and vga_ok(image, b.size - 8, obj.w)
            else
                image = b.pos + 7 -- OI header includes the object ID before the bitmap.
                ok = W(d, image + 3) == 2 + obj.w / 4
                    and W(d, image + 1) > W(d, image + 3) and W(d, image + 1) <= b.size - 8
            end
            if ok then
                sprites[#sprites + 1] = { id = oid, w = obj.w, h = obj.h, x = obj.x, y = obj.y,
                    image = image, size = b.size - 8 }
            end
        end
    end
    local r = { data = d, w = w, h = h, image = start, size = bm.size - 6,
        objects = sprites, palette = palette }
    s.room_cache[id] = r
    return r
end

local function costume(s, id)
    if s.costume_cache[id] ~= nil then return s.costume_cache[id] or nil end
    local entry = s.idx.costumes[id]
    local d = entry and resource(s, entry.room, entry.offset, "CO")
    local c = d and Cost.parse(d, 4)
    s.costume_cache[id] = c or false
    return c
end

-- ── Sounds ─────────────────────────────────────────────────────────────────
-- V4 sounds are either a bare RO (Roland) stream or an SO container whose AD
-- (AdLib) and WA (PC speaker) children may be nested in further SO blocks.

local function sound_parts(s, id)
    local entry = s.idx.sounds[id]
    if not entry then return nil end
    local d = resource(s, entry.room, entry.offset, "RO") or resource(s, entry.room, entry.offset, "SO")
    if not d then return nil end
    if d:sub(5, 6) == "RO" then return { ro = d } end
    local parts = {}
    local function walk(first, last)
        local bs = blocks(d, first, last)
        for _, b in ipairs(bs or {}) do
            if b.tag == "SO" then walk(b.pos + 6, b.pos + b.size - 1)
            elseif (b.tag == "AD" or b.tag == "WA") and not parts[b.tag] then
                parts[b.tag] = d:sub(b.pos + 6, b.pos + b.size - 1)
            end
        end
    end
    walk(7, #d)
    return parts
end

local function be32(n) return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) end
local function vlq(n)
    local bytes = { n % 128 }
    n = math.floor(n / 128)
    while n > 0 do table.insert(bytes, 1, n % 128 + 128); n = math.floor(n / 128) end
    return string.char(table.unpack(bytes))
end
local function smf(ppqn, events)
    if events:sub(-3) ~= "\255\47\0" then events = events .. "\0\255\47\0" end
    return "MThd" .. be32(6) .. "\0\0\0\1" .. string.char(math.floor(ppqn / 256), ppqn % 256)
        .. "MTrk" .. be32(#events) .. events
end

-- AdLib music (payload byte 2 = 0x80): a header with eight 16-byte instrument
-- definitions, then a MIDI event stream. Mirrors ScummVM convertADResource with
-- its fixed 480 PPQN, tempo 500000 * 256 / ticks and initial ppqn/3 delay.
-- The OPL instruments have no General MIDI equivalent and are dropped.
function V.ad_to_midi(ad, loom)
    if #ad < 2 + 0x11 + 128 + 1 or ad:byte(3) ~= 0x80 then return nil end
    local ticks = ad:byte(4)
    if ticks == 0 then return nil end
    -- ScummVM convertADResource: Loom (V3) reads the ticks value differently.
    local tempo = math.min(0xFFFFFF, math.floor(loom and 500000 * 480 / 4 / ticks or 500000 * 256 / ticks))
    local track = ad:sub(2 + 0x11 + 128 + 1)
    -- Cut after the track's own end-of-track; trailing bytes are not MIDI events.
    -- The stream starts with an event (ScummVM writes the first delay itself).
    local i, status, first = 1, nil, true
    while i <= #track do
        if not first then
            repeat local b = track:byte(i); i = i + 1 until not b or b < 128
        end
        first = false
        local ev = track:byte(i)
        if not ev then break end
        if ev == 0xFF then
            local kind, len = track:byte(i + 1), track:byte(i + 2) or 0
            i = i + 3 + len
            if kind == 0x2F then track = track:sub(1, i - 1); break end
        elseif ev == 0xF0 or ev == 0xF7 then
            local len, b = 0, nil
            i = i + 1
            repeat b = track:byte(i) or 0; i = i + 1; len = len * 128 + b % 128 until b < 128
            i = i + len
        else
            if ev >= 0x80 then status = ev; i = i + 1 end
            local cmd = status and math.floor(status / 16)
            i = i + ((cmd == 0xC or cmd == 0xD) and 1 or 2)
        end
    end
    return smf(480, "\0\255\81\3" .. be32(tempo):sub(2) .. vlq(160) .. track)
end

-- AdLib music in the user's chosen form: the game's instruments on the
-- emulated OPL2 chip, or the General MIDI conversion for Java's synthesizer.
function V.load_ad(ad, loom, label)
    if adlib_playback() == "midi" then
        local data = V.ad_to_midi(ad, loom)
        return data and { type = "midi", midi = midi_create_raw(data), playback_choice = true,
            description = label .. " (General MIDI conversion; AdLib instruments not converted)" }
    end
    local snd = sound_create_scumm_ad(ad, loom)
    return snd and { type = "sound", sound = snd, playback_choice = true,
        description = label .. " (Nuked OPL3 emulation)" }
end

-- Roland 'RO' stream (ScummVM MidiParser_RO): Fx delays (F1 adds 256), Ax
-- markers, 00 or FF end, and 8x/9x/Bx/Cx channel events. 120 PPQN, 120 BPM.
function V.ro_to_midi(ro)
    local out, delta, i = {}, 0, 7
    while i <= #ro do
        local ev = ro:byte(i); i = i + 1
        local cmd = math.floor(ev / 16)
        if ev == 0 or ev == 0xFF then break
        elseif ev == 0xF0 or ev == 0xF1 then
            delta = delta + (ro:byte(i) or 0) + (ev == 0xF1 and 256 or 0); i = i + 1
        elseif cmd == 0xC then
            out[#out + 1] = vlq(delta) .. string.char(ev, ro:byte(i) or 0); i = i + 1; delta = 0
        elseif cmd == 0x8 or cmd == 0x9 or cmd == 0xB then
            local a, b = ro:byte(i) or 0, ro:byte(i + 1) or 0
            out[#out + 1] = vlq(delta) .. string.char(ev, a % 128, b % 128); i = i + 2; delta = 0
        end -- Ax markers, data bytes and other commands carry no parameters
    end
    return smf(120, table.concat(out))
end

local function sound_kind(parts)
    if parts.ro then return "ro", "Roland MT-32 music" end
    if parts.AD and parts.AD:byte(3) == 0x80 then return "ad", "AdLib music" end
    -- AdLib effects start with an instrument or note definition after the
    -- priority and channel bytes.
    if parts.AD and (parts.AD:byte(3) == 1 or parts.AD:byte(3) == 2) then return "adsfx", "AdLib effect" end
    return nil
end

-- ── Charsets (901-904.LFL) ─────────────────────────────────────────────────
-- CharsetRendererClassic: V4 font data starts 17 bytes into the resource, which
-- begins after the file's u32 size: bpp, height, u16 count, u32 glyph offsets.
-- Each glyph: width, height, x/y offsets, then a continuous bpp-bit stream.

function V.parse_charset(d)
    local fp = 22
    if #d < fp + 4 then return nil end
    local bpp, height, count = d:byte(fp), d:byte(fp + 1), W(d, fp + 2)
    if not (bpp == 1 or bpp == 2 or bpp == 4 or bpp == 8) or height == 0 or count == 0 or count > 512 then return nil end
    local glyphs = {}
    for chr = 0, count - 1 do
        local offs = D(d, fp + 4 + chr * 4)
        local g = offs > 0 and fp + offs
        if g and g + 3 <= #d then
            local w, h = d:byte(g), d:byte(g + 1)
            if w > 0 and h > 0 and w <= 64 and h <= 64 then
                local px, src, bits, numbits = {}, g + 4, 0, 0
                local mask = 2 ^ bpp
                for n = 1, w * h do
                    if numbits == 0 then bits = d:byte(src) or 0; src = src + 1; numbits = 8 end
                    local color = math.floor(bits / 2 ^ (8 - bpp))
                    bits = (bits * mask) % 256
                    numbits = numbits - bpp
                    px[n] = color == 0 and -1 or color
                end
                glyphs[#glyphs + 1] = { w = w, h = h, pixels = px, code = chr, limb = 0,
                    relx = 0, rely = 0 }
            end
        end
    end
    if #glyphs == 0 then return nil end
    -- Colour 1 is the text colour; higher values are shading levels.
    local palette, top = {}, 2 ^ bpp - 1
    for i = 0, 255 do
        local v = i == 0 and 0 or math.floor(255 - (math.min(i, top) - 1) * 160 / math.max(1, top - 1))
        palette[i * 3 + 1], palette[i * 3 + 2], palette[i * 3 + 3] = v, v, v
    end
    return { bpp = bpp, height = height, glyphs = glyphs, palette = palette }
end

local function charset_files(path)
    local out = {}
    for n = 901, 904 do
        local f = string.format("%s/%d.LFL", path, n)
        local d = read(f)
        if d then out[#out + 1] = { number = n, data = d } end
    end
    return out
end

-- ── Palettes ───────────────────────────────────────────────────────────────

-- VGA costumes map their colours into the palette of the room they are stored in.
local function costume_palette(s, id)
    local entry = s.idx.costumes[id]
    local r = entry and room(s, entry.room)
    return r and r.palette
end

local function room_palette(r) return r.palette or EGA.ega_palette() end

local function decode_image(r, start, w, h, size, transparent_out)
    if r.palette then
        return V.decode_smap(r.data, start, size, w, h, nil, TRANSPARENT, transparent_out, false, 4)
    end
    return EGA.decode_ega(r.data, start, w, h)
end

function V.detect(path)
    local s = state(path)
    if not s then return false end
    for id = 1, 255 do
        if s.idx.rooms[id] and room(s, id) then return true end
    end
    return false
end

function V.get_resources(path)
    local s = state(path)
    if not s then return {} end
    local rooms, costumes, vga = {}, {}, false
    for id = 1, 255 do
        local r = s.idx.rooms[id] and room(s, id)
        if r then
            vga = vga or r.palette ~= nil
            local children = { { id = "v4:bg:" .. id, name = "Background", type = "image" } }
            local sprites = {}
            for _, o in ipairs(r.objects) do
                sprites[#sprites + 1] = { id = "v4:obj:" .. id .. ":" .. o.id,
                    name = "Object " .. o.id, type = "image" }
            end
            if #sprites > 0 then
                children[#children + 1] = { id = "v4:comp:" .. id, name = "Composite", type = "composite" }
                children[#children + 1] = { id = "v4:objects:" .. id,
                    name = "Object sprites", type = "category", children = sprites }
            end
            if r.palette then
                children[#children + 1] = { id = "v4:pal:" .. id, name = "Palette", type = "palette" }
            end
            rooms[#rooms + 1] = { id = "v4:room:" .. id,
                name = string.format("Room %d%s (%dx%d)", id, s.idx.names[id] and " - " .. s.idx.names[id] or "", r.w, r.h),
                type = "category", children = children }
        end
    end
    for id = 0, s.idx.costume_count - 1 do
        if s.idx.costumes[id] then
            local c = costume(s, id)
            if c then
                local children = { { id = "v4:sheet:" .. id, name = "All cels", type = "image" } }
                for _, a in ipairs(c:animations()) do
                    children[#children + 1] = { id = "v4:anim:" .. id .. ":" .. a.id, name = a.name, type = "animation" }
                end
                costumes[#costumes + 1] = { id = "v4:costume:" .. id, name = "Costume " .. id,
                    type = "category", children = children }
            end
        end
    end
    local out = { { id = "v4:rooms", name = "Rooms", type = "category", children = rooms } }
    if not vga then out[#out + 1] = { id = "v4:pal", name = "EGA palette", type = "palette" } end
    if #costumes > 0 then out[#out + 1] = { id = "v4:costumes", name = "Costumes / actor sprites",
        type = "category", children = costumes } end

    local music, effects, skipped = {}, {}, 0
    for id = 0, 255 do
        local parts = s.idx.sounds[id] and sound_parts(s, id)
        if parts then
            local kind, label = sound_kind(parts)
            if kind == "adsfx" then
                effects[#effects + 1] = { id = "v4:sfx:" .. id, name = string.format("Sound %d — %s", id, label), type = "sound" }
            elseif kind then
                -- AdLib music plays as OPL2 emulation or General MIDI (the user's
                -- choice); Roland converts to MIDI.
                music[#music + 1] = { id = "v4:snd:" .. id, name = string.format("Sound %d — %s", id, label),
                    type = kind == "ad" and "sound" or "midi" }
            else
                skipped = skipped + 1
            end
        end
    end
    if #music > 0 then
        local name = string.format("Music (%d)", #music)
        if skipped > 0 then name = name .. string.format(" — %d PC-speaker-only sounds not shown", skipped) end
        out[#out + 1] = { id = "v4:music", name = name, type = "category", children = music }
    end
    if #effects > 0 then
        out[#out + 1] = { id = "v4:effects", name = string.format("AdLib sound effects (%d)", #effects), type = "category", children = effects }
    end

    local fonts = {}
    for _, f in ipairs(charset_files(path)) do
        local c = V.parse_charset(f.data)
        if c then fonts[#fonts + 1] = { id = "v4:font:" .. f.number,
            name = string.format("%d.LFL (%d glyphs, %d px)", f.number, #c.glyphs, c.height), type = "image" } end
    end
    if #fonts > 0 then out[#out + 1] = { id = "v4:fonts", name = "Fonts", type = "category", children = fonts } end
    return out
end

-- EGA games share the fixed EGA palette; VGA images default to their room's PA.
function V.default_palette(path, id)
    local kind, number = id:match("^v4:(%a+):(%d+)")
    number = tonumber(number)
    if kind == "font" or kind == "snd" then return nil end
    local s = state(path)
    if not s then return nil end
    local r
    if kind == "sheet" or kind == "anim" then
        local entry = s.idx.costumes[number]
        r = entry and room(s, entry.room)
        number = entry and entry.room
    elseif number then
        r = room(s, number)
    end
    if r and r.palette then return "v4:pal:" .. number end
    return "v4:pal"
end

function V.load_resource(path, id, palette_id)
    if id == "v4:pal" then
        local pal = EGA.ega_palette()
        local pixels = {}
        for y = 0, 31 do for x = 0, 255 do pixels[#pixels + 1] = math.floor(x / 16) end end
        return { type = "image", image = image_create_indexed(256, 32, pixels, pal), palette = pal }
    end
    local kind, number, extra = id:match("^v4:(%a+):(%d+):?(%d*)$")
    number = tonumber(number)
    local s = number and state(path)
    if not s then return nil end

    if kind == "font" then
        for _, f in ipairs(charset_files(path)) do
            if f.number == number then
                local c = V.parse_charset(f.data)
                if not c then return nil end
                local img, w, h = Cost.render_sheet_of(c.glyphs, c.palette)
                return img and { type = "image", image = img, description = string.format(
                    "SCUMM V4 charset %d.LFL — %d glyphs, %d bpp, %d px high", number, #c.glyphs, c.bpp, c.height) }
            end
        end
        return nil
    elseif kind == "snd" or kind == "sfx" then
        local parts = sound_parts(s, number)
        if not parts then return nil end
        local which, label = sound_kind(parts)
        if which == "ad" then
            return V.load_ad(parts.AD, false, string.format("SCUMM V4 sound %d — AdLib music", number))
        elseif which == "adsfx" then
            local snd = sound_create_scumm_ad(parts.AD, false)
            return snd and { type = "sound", sound = snd, description = string.format(
                "SCUMM V4 sound %d — AdLib effect (Nuked OPL3 emulation)", number) }
        end
        local data = which == "ro" and V.ro_to_midi(parts.ro)
        if not data then return nil end
        return { type = "midi", midi = midi_create_raw(data), description = string.format(
            "SCUMM V4 sound %d — %s", number, label) }
    end

    -- A room palette selected in the dropdown recolours VGA images.
    local function chosen_palette(default)
        local pid = palette_id and tonumber(palette_id:match("^v4:pal:(%d+)$"))
        local pr = pid and room(s, pid)
        return pr and pr.palette or default
    end

    if kind == "pal" then
        local r = room(s, number)
        if not r or not r.palette then return nil end
        local pixels = {}
        for y = 0, 255 do for x = 0, 255 do pixels[#pixels + 1] = math.floor(y / 16) * 16 + math.floor(x / 16) end end
        return { type = "image", image = image_create_indexed(256, 256, pixels, r.palette),
            description = string.format("Room %d palette — 256 colours", number) }
    elseif kind == "bg" or kind == "obj" then
        local r = room(s, number)
        if not r then return nil end
        local w, h, start, size = r.w, r.h, r.image, r.size
        if kind == "obj" then
            local found
            for _, o in ipairs(r.objects) do if o.id == tonumber(extra) then found = o; break end end
            if not found then return nil end
            w, h, start, size = found.w, found.h, found.image, found.size
        end
        local pixels = decode_image(r, start, w, h, size)
        if not pixels then return nil end
        return { type = "image", image = image_create_indexed(w, h, pixels, chosen_palette(room_palette(r))),
            description = string.format("SCUMM V4 %s %s, room %d, %dx%d", r.palette and "VGA" or "EGA", kind, number, w, h) }
    elseif kind == "comp" then
        local r = room(s, number)
        if not r then return nil end
        local pal = chosen_palette(room_palette(r))
        local bg = decode_image(r, r.image, r.w, r.h, r.size)
        if not bg then return nil end
        local layers = { { name = "Background", group = "Background",
            image = image_create_indexed(r.w, r.h, bg, pal) } }
        for _, o in ipairs(r.objects) do
            -- VGA strips follow ScummVM's transparent codecs; EGA strips are opaque.
            local px = decode_image(r, o.image, o.w, o.h, o.size, r.palette and 256 or nil)
            if px then
                layers[#layers + 1] = { name = "Object " .. o.id, group = "Objects", x = o.x, y = o.y,
                    image = image_create_indexed(o.w, o.h, px, pal, r.palette and 256 or nil) }
            end
        end
        return { type = "composite", width = r.w, height = r.h, layers = layers,
            description = string.format("SCUMM V4 room %d composite — %d objects", number, #layers - 1) }
    elseif kind == "sheet" or kind == "anim" then
        local c = costume(s, number)
        if not c then return nil end
        local pal = chosen_palette(costume_palette(s, number) or EGA.ega_palette())
        if kind == "sheet" then
            local img = c:render_sheet(pal)
            if img then return { type = "image", image = img } end
        else
            local a = tonumber(extra)
            if not a then return nil end
            local anim, _, _, _, animated = c:render_animation(a, pal)
            if anim then
                if animated then return { type = "animation", animation = anim, delay_ms = 120 } end
                return { type = "image", image = anim }
            end
        end
        return { type = "text", text = "Costume has no visible cels" }
    end
    return nil
end

return V

-- Veil of Darkness / El Velo de la Sombra (Event Horizon Software / SSI, 1993).
--
-- Files (all little-endian):
--   RESOURCE  u32 offset table (first entry = table size), 'EH' resources.
--             Entry 0 is NOT a resource: it is u16 header + u32 offsets of 1133
--             more resources stored after the last table entry. Entry 376 ends
--             where the first of those begins.
--   COLORS    u8 colour count (144), then 16 palettes of 144 six-bit RGB triples.
--   TEXT      u32 offset table; strings are NUL-terminated and XOR 0xDA.
--             Entry 0 (u8 pad + u32 offsets) indexes 1368 more dialogue strings.
--   RES1      bitmap fonts (not decoded), ROOMS/INTERACT/NPC/OBJECTS: game data.
--
-- 'EH' resource: "EH", u8 type, then
--   type 1 image : u8 pad, u16 frames, u8 rows, u8 width/8, u8 transparent
--                  (0xFF = none), u8 method, u8 pad, data.
--                  Each frame is rows x width pixels, 8 bits per pixel; a frame
--                  of one row is simply a scanline of a taller picture.
--                  method 0 raw, 1 PackBits, 3 LZSS (4096 window, fill 0xFE,
--                  start 0xFEE, 12-bit position + 4-bit length + 3).
--   type 4 sound : u8 pad, u32 size, Creative Voice File.
--   types 2, 3, 5: tables/scripts, shown as hex.
-- VGA palette = COLORS set A (144 colours) at indices 0..143 + COLORS set B
-- (first 112 colours) at 144..255; scenes default to A = 0, B = 1.
local engine = {id = "veil", name = "Veil of Darkness", version = "1.0",
    description = "Veil of Darkness / El Velo de la Sombra (1993, Event Horizon / SSI)"}

local floor = math.floor

local function u16(s, p) return s:byte(p) + s:byte(p + 1) * 256 end
local function u32(s, p) return u16(s, p) + u16(s, p + 2) * 65536 end

local MAX_PIXELS = 1048576
local PALETTE_COUNT = 16
local PALETTE_COLORS = 144
local CODE_TEXT_KEY = 0xDA

local function resolve(path, name)
    for _, n in ipairs(list_files(path) or {}) do
        if n:upper() == name then return path .. "/" .. n end
    end
end

local function read(path, offset, size)
    local f = file_open(path)
    if not f then return nil end
    local n = file_size(f)
    if offset < 0 or size < 0 or offset + size > n then file_close(f); return nil end
    local d = file_read(f, offset, size)
    file_close(f)
    return d and #d == size and d or nil
end

local function read_all(path)
    local f = file_open(path)
    if not f then return nil end
    local d = file_read(f, 0, file_size(f))
    file_close(f)
    return d
end

local function file_length(path)
    local f = file_open(path)
    if not f then return nil end
    local n = file_size(f)
    file_close(f)
    return n
end

-- ---------------------------------------------------------------------------
-- decoders
-- ---------------------------------------------------------------------------

-- LZSS as used by the type-1 loader. Returns exactly `want` bytes or nil.
local function lzss(src, want)
    local buf = {}
    for i = 0, 4095 do buf[i] = i < 0xFEE and 0xFE or 0 end
    local out, n = {}, 0
    local r, i, flags, len = 0xFEE, 1, 0, #src
    while n < want do
        flags = floor(flags / 2)
        if flags % 512 < 256 then
            if i > len then break end
            flags = src:byte(i) + 0xFF00
            i = i + 1
        end
        if flags % 2 == 1 then
            if i > len then break end
            local c = src:byte(i)
            i = i + 1
            n = n + 1; out[n] = c
            buf[r] = c; r = (r + 1) % 4096
        else
            if i + 1 > len then break end
            local a, b = src:byte(i), src:byte(i + 1)
            i = i + 2
            local pos = a + floor(b / 16) * 256
            for k = 0, b % 16 + 2 do
                if n >= want then break end
                local c = buf[(pos + k) % 4096]
                n = n + 1; out[n] = c
                buf[r] = c; r = (r + 1) % 4096
            end
        end
    end
    if n ~= want then return nil end
    return out
end

local function packbits(src, want)
    local out, n, i, len = {}, 0, 1, #src
    while n < want do
        if i > len then return nil end
        local b = src:byte(i)
        i = i + 1
        if b < 128 then
            if i + b > len then return nil end
            for k = 0, b do n = n + 1; out[n] = src:byte(i + k) end
            i = i + b + 1
        else
            if i > len then return nil end
            local c = src:byte(i)
            i = i + 1
            for _ = 1, 257 - b do n = n + 1; out[n] = c end
        end
    end
    if n ~= want then return nil end
    return out
end

local function raw(src, want)
    if #src < want then return nil end
    local out = {}
    for i = 1, want do out[i] = src:byte(i) end
    return out
end

-- Parse the 12-byte type-1 header. Returns a table or nil.
local function image_header(e)
    if not e or #e < 12 or e:sub(1, 2) ~= "EH" or e:byte(3) ~= 1 then return nil end
    local h = {frames = u16(e, 6), rows = e:byte(8), width = e:byte(9) * 8,
        trans = e:byte(10), method = e:byte(11)}
    if h.frames < 1 or h.rows < 1 or h.width < 8 then return nil end
    h.frame_pixels = h.rows * h.width
    h.total = h.frame_pixels * h.frames
    if h.total > MAX_PIXELS then return nil end
    h.transparent = h.trans ~= 255 and h.trans or nil
    -- A single-row "frame" is a scanline: the whole resource is one picture.
    h.animated = h.rows > 1 and h.frames > 1
    if h.animated then
        h.out_w, h.out_h = h.width, h.rows
    else
        h.out_w, h.out_h = h.width, h.rows * h.frames
    end
    return h
end

local function decode_image(e)
    local h = image_header(e)
    if not h then return nil end
    local body = e:sub(13)
    local px
    if h.method == 3 then px = lzss(body, h.total)
    elseif h.method == 1 then px = packbits(body, h.total)
    elseif h.method == 0 then px = raw(body, h.total) end
    if not px then return nil end
    return h, px
end

-- ---------------------------------------------------------------------------
-- palettes
-- ---------------------------------------------------------------------------

local function load_color_sets(game_path)
    local path = resolve(game_path, "COLORS")
    local d = path and read_all(path)
    if not d or #d < 1 then return nil end
    local n = d:byte(1)
    if n < 112 or n > 255 or #d < 1 + PALETTE_COUNT * n * 3 then return nil end
    local sets = {}
    for p = 0, PALETTE_COUNT - 1 do
        local base = 1 + p * n * 3
        local set = {}
        for i = 1, n * 3 do set[i] = floor(d:byte(base + i) * 255 / 63 + 0.5) end
        sets[p] = {colors = n, rgb = set}
    end
    return sets
end

-- 256-entry VGA palette (verified against a DOSBox-X capture): indices 0..143
-- are set `a` slot for slot, indices 144..255 are set `b` slots 0..111. The
-- game fills both halves from COLORS; scenes use set 0 + set 1 by default.
local function build_palette(sets, a, b)
    local sa, sb = sets[a], sets[b or 1] or sets[a]
    if not sa or not sb then return nil end
    local pal = {}
    for i = 0, 255 do
        local s, j = sa, i
        if i >= 144 then s, j = sb, i - 144 end
        for c = 1, 3 do
            pal[i * 3 + c] = j < s.colors and s.rgb[j * 3 + c] or 0
        end
    end
    return pal
end

local function palette_swatch(pal)
    local pixels = {}
    for y = 0, 127 do
        for x = 0, 127 do
            pixels[y * 128 + x + 1] = floor(y / 8) * 16 + floor(x / 8)
        end
    end
    return image_create_indexed(128, 128, pixels, pal)
end

-- "pal:A" = set A for colours 0-143 with set 1 for 144-255; "pal:A:B" picks both.
local function palette_pair(palette_id)
    local a, b = palette_id and palette_id:match("^pal:(%d+):?(%d*)$")
    if not a then return nil end
    a = tonumber(a)
    b = b ~= "" and tonumber(b) or 1
    if a >= PALETTE_COUNT or b >= PALETTE_COUNT then return nil end
    return a, b
end

-- ---------------------------------------------------------------------------
-- resource table
-- ---------------------------------------------------------------------------

local catalog_cache = {}

-- Returns list of {id=, offset=, size=} (id = table entry number, 377+ for the
-- secondary list) and the RESOURCE path.
local function catalog(game_path)
    local cached = catalog_cache[game_path]
    if cached then return cached end
    local path = resolve(game_path, "RESOURCE")
    if not path then return nil end
    local total = file_length(path)
    local head = read(path, 0, 4)
    if not head then return nil end
    local table_size = u32(head, 1)
    if table_size < 8 or table_size > 65536 then return nil end
    local count = floor(table_size / 4)
    local t = read(path, 0, count * 4)
    if not t then return nil end
    local offs = {}
    for i = 0, count - 1 do offs[i] = u32(t, i * 4 + 1) end
    for i = 1, count - 1 do
        if offs[i] < offs[i - 1] or offs[i] > total then return nil end
    end
    local list = {}
    -- Entry 0 lists further resources placed after the last table entry.
    local e0size = (count > 1 and offs[1] or total) - offs[0]
    local e0 = read(path, offs[0], e0size)
    local extra = {}
    if e0 and #e0 >= 6 then
        for p = 3, #e0 - 3, 4 do
            local o = u32(e0, p)
            if o > total or (#extra > 0 and o < extra[#extra]) then break end
            extra[#extra + 1] = o
        end
    end
    for i = 1, count - 1 do
        local first = offs[i]
        local last = (i + 1 < count) and offs[i + 1] or (extra[1] or total)
        if last > first then list[#list + 1] = {id = i, offset = first, size = last - first} end
    end
    for k = 1, #extra do
        local first = extra[k]
        local last = extra[k + 1] or total
        if last > first then list[#list + 1] = {id = count - 1 + k, offset = first, size = last - first} end
    end
    local by_id = {}
    for _, r in ipairs(list) do by_id[r.id] = r end
    local cat = {path = path, list = list, by_id = by_id}
    catalog_cache[game_path] = cat
    return cat
end

local function load_entry(cat, id)
    local r = cat.by_id[id]
    if not r then return nil end
    return read(cat.path, r.offset, r.size)
end

-- ---------------------------------------------------------------------------
-- text
-- ---------------------------------------------------------------------------

-- The game font maps a few control codes to Spanish punctuation.
local TEXT_MAP = {
    [24] = "\194\191", -- inverted question mark
    [25] = "\194\161", -- inverted exclamation mark
    [26] = "\195\177", -- n with tilde
    [127] = "",
    [254] = "\226\150\160",
}

local function xor_byte(b)
    local r, bit, a, k = 0, 1, b, CODE_TEXT_KEY
    for _ = 1, 8 do
        if a % 2 ~= k % 2 then r = r + bit end
        a = floor(a / 2); k = floor(k / 2); bit = bit * 2
    end
    return r
end

local XOR_TABLE = {}
for b = 1, 255 do XOR_TABLE[string.char(b)] = xor_byte(b) end

local function text_string(s)
    local out = s:gsub("[\1-\255]", function(c)
        local v = XOR_TABLE[c]
        if v >= 32 and v < 127 then return string.char(v) end
        if TEXT_MAP[v] then return TEXT_MAP[v] end
        if v == 10 or v == 13 then return "\n" end
        return ""
    end)
    return out
end

local text_cache = {}

-- Returns interface strings (list) and dialogue strings (list).
local function load_text(game_path)
    local cached = text_cache[game_path]
    if cached then return cached end
    local path = resolve(game_path, "TEXT")
    local d = path and read_all(path)
    if not d or #d < 8 then return nil end
    local table_size = u32(d, 1)
    if table_size < 8 or table_size > #d then return nil end
    local count = floor(table_size / 4)
    local offs = {}
    for i = 0, count - 1 do offs[i] = u32(d, i * 4 + 1) end
    local ui = {}
    for i = 1, count - 1 do
        local first = offs[i]
        local last = (i + 1 < count) and offs[i + 1] or #d
        if first >= #d or last < first then break end
        if i + 1 < count or last - first < 4096 then
            local s = d:sub(first + 1, last):match("^[^%z]*")
            ui[#ui + 1] = text_string(s)
        end
    end
    -- Entry 0: u8 pad + u32 absolute offsets of the dialogue strings.
    local dialogue = {}
    local e0end = count > 1 and offs[1] or #d
    local p = offs[0] + 2
    while p + 3 <= e0end do
        local o = u32(d, p)
        if o >= #d then break end
        local s = d:sub(o + 1):match("^[^%z]*")
        dialogue[#dialogue + 1] = text_string(s)
        p = p + 4
    end
    cached = {ui = ui, dialogue = dialogue}
    text_cache[game_path] = cached
    return cached
end

local function numbered(lines)
    local out = {}
    for i, l in ipairs(lines) do out[#out + 1] = string.format("%04d  %s", i, l) end
    return table.concat(out, "\n")
end

-- Printable runs of CODE.1 hold the opening narration.
local function intro_text(game_path)
    local path = resolve(game_path, "CODE.1")
    local d = path and read_all(path)
    if not d then return nil end
    local out = {}
    for run in d:gmatch("[%w%p ]+") do
        if #run >= 30 and run:find(" ", 1, true) and run:find("%a%a%a") then
            out[#out + 1] = run
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- tree
-- ---------------------------------------------------------------------------

local function hexdump(e, limit)
    local out = {}
    local n = math.min(#e, limit or 512)
    for p = 1, n, 16 do
        local hex, asc = {}, {}
        for i = p, math.min(p + 15, n) do
            local b = e:byte(i)
            hex[#hex + 1] = string.format("%02x", b)
            asc[#asc + 1] = (b >= 32 and b < 127) and string.char(b) or "."
        end
        out[#out + 1] = string.format("%06x  %-47s  %s", p - 1, table.concat(hex, " "), table.concat(asc))
    end
    if #e > n then out[#out + 1] = string.format("... %d more bytes", #e - n) end
    return table.concat(out, "\n")
end

local function chunk_node(prefix, label, items, per)
    local parent = {id = prefix, name = label, type = "category", children = {}}
    if #items <= per then
        parent.children = items
        return parent
    end
    for s = 1, #items, per do
        local e = math.min(s + per - 1, #items)
        local group = {id = prefix .. ":" .. s, name = string.format("%s %d-%d", label, s, e),
            type = "category", children = {}}
        for i = s, e do group.children[#group.children + 1] = items[i] end
        parent.children[#parent.children + 1] = group
    end
    return parent
end

function engine.detect(game_path)
    if not (resolve(game_path, "RESOURCE") and resolve(game_path, "COLORS")
        and resolve(game_path, "ROOMS") and resolve(game_path, "TEXT")
        and resolve(game_path, "INTERACT")) then
        return false
    end
    local head = read(resolve(game_path, "RESOURCE"), 0, 8)
    if not head then return false end
    -- Entry 0 is the secondary index; the first real resource is entry 1.
    local first, second = u32(head, 1), u32(head, 5)
    if first < 8 or first > 65536 or second <= first then return false end
    return read(resolve(game_path, "RESOURCE"), second, 2) == "EH"
end

function engine.get_resources(game_path)
    local cat = catalog(game_path)
    if not cat then return {} end
    local backgrounds, sprites, anims, sounds, data = {}, {}, {}, {}, {}
    for _, r in ipairs(cat.list) do
        local head = read(cat.path, r.offset, math.min(r.size, 12))
        if head and #head >= 4 and head:sub(1, 2) == "EH" then
            local typ = head:byte(3)
            if typ == 1 then
                local h = image_header(head)
                if h then
                    local node
                    if h.animated then
                        node = {id = string.format("anim:%04d", r.id), type = "animation",
                            name = string.format("Animation %04d (%dx%d, %d frames)", r.id, h.width, h.rows, h.frames)}
                        anims[#anims + 1] = node
                    else
                        node = {id = string.format("img:%04d", r.id), type = "image",
                            name = string.format("Image %04d (%dx%d)", r.id, h.out_w, h.out_h)}
                        if h.out_w * h.out_h >= 30000 then backgrounds[#backgrounds + 1] = node
                        else sprites[#sprites + 1] = node end
                    end
                end
            elseif typ == 4 then
                sounds[#sounds + 1] = {id = string.format("snd:%04d", r.id), type = "sound",
                    name = string.format("Sound %04d (%d bytes)", r.id, r.size)}
            else
                data[#data + 1] = {id = string.format("data:%04d", r.id), type = "data",
                    name = string.format("Type %d data %04d (%d bytes)", typ, r.id, r.size)}
            end
        end
    end

    local resources = {}
    if #backgrounds > 0 then
        resources[#resources + 1] = chunk_node("backgrounds", "Backgrounds", backgrounds, 100)
    end
    if #anims > 0 then
        resources[#resources + 1] = chunk_node("anims", "Sprites & Animations", anims, 100)
    end
    if #sprites > 0 then
        resources[#resources + 1] = chunk_node("sprites", "Sprites", sprites, 100)
    end
    local pals = {id = "palettes", name = "Palettes", type = "category", children = {}}
    if load_color_sets(game_path) then
        for p = 0, PALETTE_COUNT - 1 do
            pals.children[#pals.children + 1] = {id = "pal:" .. p, type = "palette",
                name = string.format("Set %d + character set 1", p)}
        end
        for p = 0, PALETTE_COUNT - 1 do
            if p ~= 1 then
                pals.children[#pals.children + 1] = {id = "pal:" .. p .. ":" .. p, type = "palette",
                    name = string.format("Set %d only", p)}
            end
        end
        resources[#resources + 1] = pals
    end
    if #sounds > 0 then
        resources[#resources + 1] = {id = "sounds", name = "Sounds", type = "category", children = sounds}
    end
    local texts = {id = "text", name = "Text", type = "category", children = {}}
    if load_text(game_path) then
        texts.children[#texts.children + 1] = {id = "text:ui", name = "Interface strings", type = "text"}
        texts.children[#texts.children + 1] = {id = "text:dialogue", name = "Dialogue", type = "text"}
    end
    if intro_text(game_path) then
        texts.children[#texts.children + 1] = {id = "text:intro", name = "Introduction (CODE.1)", type = "text"}
    end
    if #texts.children > 0 then resources[#resources + 1] = texts end
    if #data > 0 then
        resources[#resources + 1] = chunk_node("data", "Other data", data, 100)
    end
    return resources
end

function engine.default_palette(game_path, resource_id)
    if resource_id:match("^img:") or resource_id:match("^anim:") then return "pal:0" end
end

local function load_picture(game_path, cat, id, kind, pal)
    local e = load_entry(cat, id)
    local h, px = decode_image(e)
    if not h then return {type = "text", text = "Image " .. id .. " could not be decoded"} end
    if kind == "anim" then
        if not h.animated then return nil end
        local handles = {}
        for f = 0, h.frames - 1 do
            local frame = {}
            local base = f * h.frame_pixels
            for i = 1, h.frame_pixels do frame[i] = px[base + i] end
            handles[#handles + 1] = image_create_indexed(h.width, h.rows, frame, pal, h.transparent)
        end
        local anim = animation_create(handles, 120)
        return {type = "animation", animation = anim, image = handles[1], frames = handles,
            delay_ms = 120, palette_image = palette_swatch(pal), palette_colors = 256,
            description = string.format("Resource %d: %d frames of %dx%d", id, h.frames, h.width, h.rows)}
    end
    if h.animated then return nil end
    local img = image_create_indexed(h.out_w, h.out_h, px, pal, h.transparent)
    return {type = "image", image = img, palette_image = palette_swatch(pal), palette_colors = 256,
        description = string.format("Resource %d: %dx%d", id, h.out_w, h.out_h)}
end

function engine.load_resource(game_path, resource_id, palette_id)
    if resource_id:match("^pal:") then
        local sets = load_color_sets(game_path)
        local a, b = palette_pair(resource_id)
        local pal = sets and a and build_palette(sets, a, b)
        if not pal then return {type = "text", text = "Missing palette: " .. resource_id} end
        return {type = "image", image = palette_swatch(pal), palette_colors = 256,
            description = string.format("Colours 0-143 from set %d, 144-255 from set %d (6-bit VGA)", a, b)}
    end
    if resource_id:match("^text:") then
        local which = resource_id:sub(6)
        if which == "intro" then
            local t = intro_text(game_path)
            if t then return {type = "text", text = t} end
            return nil
        end
        local t = load_text(game_path)
        if not t then return nil end
        if which == "ui" then return {type = "text", text = numbered(t.ui)} end
        if which == "dialogue" then return {type = "text", text = numbered(t.dialogue)} end
        return nil
    end
    local cat = catalog(game_path)
    if not cat then return nil end
    local kind, num = resource_id:match("^(%a+):(%d+)$")
    num = num and tonumber(num)
    if not kind or not num then return nil end
    if kind == "img" or kind == "anim" then
        local sets = load_color_sets(game_path)
        if not sets then return {type = "text", text = "COLORS is missing or invalid"} end
        local a, b = palette_pair(palette_id)
        return load_picture(game_path, cat, num, kind, build_palette(sets, a or 0, b or 1))
    elseif kind == "snd" then
        local e = load_entry(cat, num)
        if not e or #e < 30 or e:byte(3) ~= 4 then return nil end
        local voc = e:sub(10)
        if voc:sub(1, 19) ~= "Creative Voice File" then return {type = "text", text = "Unexpected sound payload"} end
        local snd = sound_create_encoded(voc)
        if not snd then return {type = "text", text = "Unsupported VOC data"} end
        return {type = "sound", sound = snd, description = string.format("Resource %d: %d bytes VOC", num, #voc)}
    elseif kind == "data" then
        local e = load_entry(cat, num)
        if not e then return nil end
        return {type = "text", text = string.format("Resource %d, type %d, %d bytes\n\n%s",
            num, e:byte(3), #e, hexdump(e, 2048))}
    end
    return nil
end

return engine

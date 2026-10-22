-- Westwood (Legend of Kyrandia series) helpers shared by the kyra1 and kyra2
-- engine scripts: fonts, shapes, text tables and script TEXT chunks.
-- References (ScummVM engines/kyra): graphics/screen.cpp (DOSFont::load/drawChar,
-- drawShape), graphics/screen_v2.cpp (getPtrToShape), engine/util.cpp
-- (decodeString1/2), engine/kyra_hof.cpp (getTableString), script/script.cpp
-- and script.h (TEXT chunk, stackPosString).
local W = {}

local function u8(d, p) return d:byte(p) or 0 end
local function u16(d, p) return u8(d, p) + u8(d, p + 1) * 256 end
local function u16be(d, p) return u8(d, p) * 256 + u8(d, p + 1) end
local function u32(d, p) return u16(d, p) + u16(d, p + 2) * 65536 end
local function u32be(d, p) return u16be(d, p) * 65536 + u16be(d, p + 2) end

-- ── Text ───────────────────────────────────────────────────────────────────
local T1 = { 0x20, 0x65, 0x74, 0x61, 0x69, 0x6E, 0x6F, 0x73, 0x72, 0x6C, 0x68, 0x63, 0x64, 0x75, 0x70, 0x6D }
local T2 = { 0x74, 0x61, 0x73, 0x69, 0x6F, 0x20, 0x77, 0x62, 0x20, 0x72, 0x6E, 0x73, 0x64, 0x61, 0x6C, 0x6D,
    0x68, 0x20, 0x69, 0x65, 0x6F, 0x72, 0x61, 0x73, 0x6E, 0x72, 0x74, 0x6C, 0x63, 0x20, 0x73, 0x79, 0x6E, 0x73,
    0x74, 0x63, 0x6C, 0x6F, 0x65, 0x72, 0x20, 0x64, 0x74, 0x67, 0x65, 0x73, 0x69, 0x6F, 0x6E, 0x72, 0x20, 0x75,
    0x66, 0x6D, 0x73, 0x77, 0x20, 0x74, 0x65, 0x70, 0x2E, 0x69, 0x63, 0x61, 0x65, 0x20, 0x6F, 0x69, 0x61, 0x64,
    0x75, 0x72, 0x20, 0x6C, 0x61, 0x65, 0x69, 0x79, 0x6F, 0x64, 0x65, 0x69, 0x61, 0x20, 0x6F, 0x74, 0x72, 0x75,
    0x65, 0x74, 0x6F, 0x61, 0x6B, 0x68, 0x6C, 0x72, 0x20, 0x65, 0x69, 0x75, 0x2C, 0x2E, 0x6F, 0x61, 0x6E, 0x73,
    0x72, 0x63, 0x74, 0x6C, 0x61, 0x69, 0x6C, 0x65, 0x6F, 0x69, 0x72, 0x61, 0x74, 0x70, 0x65, 0x61, 0x6F, 0x69,
    0x70, 0x20, 0x62, 0x6D }

-- Util::decodeString1 (bytes >= 0x80 expand to two common letters) then
-- decodeString2 (0x1B escapes characters above 0x7F).
function W.decode_string(s)
    local out = {}
    for i = 1, #s do
        local c = s:byte(i)
        if c >= 0x80 then
            c = c % 0x80
            out[#out + 1] = string.char(T1[math.floor(c / 8) % 16 + 1])
            c = T2[c + 1] or 0x3F
        end
        out[#out + 1] = string.char(c)
    end
    s = table.concat(out)
    return (s:gsub("\27(.)", function(ch) return string.char((ch:byte() + 0x7F) % 256) end))
end

-- Code page 437/850 letters for the upper half (Kyra's DOS fonts).
local CP = require("cp437")
function W.to_unicode(s)
    s = s:gsub("[\1-\8\11\12\14-\31]", function(c) return string.format("\\x%02X", c:byte()) end)
    return CP.to_utf8(s)
end

-- HoF string tables (.ENG/.FRE/.GER): u16 LE offsets, the first one also
-- giving the count; strings are zero-terminated and coded (decode_string).
function W.table_strings(d)
    if not d or #d < 4 then return nil end
    local first = u16(d, 1)
    if first < 2 or first > #d or first % 2 ~= 0 then return nil end
    local out = {}
    for i = 0, first / 2 - 1 do
        local off = u16(d, 1 + i * 2)
        local s = off < #d and d:match("^[^%z]*", off + 1) or ""
        out[#out + 1] = W.to_unicode(W.decode_string(s))
    end
    return out
end

-- EMC2 scripts: FORM <size> "EMC2" with TEXT/ORDR/DATA chunks. TEXT holds u16
-- big-endian offsets (the first one also giving the count) and plain strings.
function W.emc_text(d)
    if not d or #d < 12 or d:sub(1, 4) ~= "FORM" or d:sub(9, 12) ~= "EMC2" then return nil end
    local p, last = 13, math.min(#d, 8 + u32be(d, 5))
    while p + 7 <= last do
        local tag, size = d:sub(p, p + 3), u32be(d, p + 4)
        if tag == "TEXT" then
            local t = d:sub(p + 8, p + 7 + size)
            local first = u16be(t, 1)
            if first < 2 or first > #t then return {} end
            local out = {}
            for i = 0, math.floor(first / 2) - 1 do
                local off = u16be(t, 1 + i * 2)
                out[#out + 1] = off < #t and W.to_unicode(t:match("^[^%z]*", off + 1)) or ""
            end
            return out
        end
        p = p + 8 + size + size % 2
    end
    return {}
end

-- ── Fonts (DOSFont) ────────────────────────────────────────────────────────
-- u16 size, u16 0x0500, u16 descriptor offset (glyph count - 1 at +3, height +4,
-- width +5), u16 bitmap offsets table, u16 width table, u16 height table (pairs
-- of top padding and bitmap rows). Rows hold 4-bit pixels, low nibble first.
function W.font_sheet(d)
    if not d or #d < 16 or u16(d, 3) ~= 0x0500 then return nil end
    local desc = u16(d, 5)
    local count, height = u8(d, desc + 4) + 1, u8(d, desc + 5)
    local bitmaps, widths, heights = u16(d, 7), u16(d, 9), u16(d, 13)
    if height == 0 or count > 256 then return nil end
    local cols, cellw, cellh = 16, 0, height + 2
    for c = 0, count - 1 do cellw = math.max(cellw, u8(d, widths + c + 1)) end
    cellw = cellw + 2
    local rows = math.ceil(count / cols)
    local w, h = cols * cellw, rows * cellh
    local px = {}
    for i = 1, w * h do px[i] = 0 end
    for c = 0, count - 1 do
        local cw = u8(d, widths + c + 1)
        local top, n = u8(d, heights + c * 2 + 1), u8(d, heights + c * 2 + 2)
        local src = u16(d, bitmaps + c * 2 + 1)
        if src > 0 and cw > 0 then
            local gx, gy = (c % cols) * cellw + 1, math.floor(c / cols) * cellh + 1 + top
            local p, b = src + 1, 0
            for y = 0, n - 1 do
                for x = 0, cw - 1 do
                    local v
                    if x % 2 == 1 then v = math.floor(b / 16) else b = u8(d, p); p = p + 1; v = b % 16 end
                    if v ~= 0 and gy + y < h then px[(gy + y) * w + gx + x + 1] = v end
                end
            end
        end
    end
    -- 1 is the letter colour; 2 and up are shading and outline levels (3 is the
    -- dark outline of the outlined fonts), drawn on a mid-tone background
    local pal = { 96, 104, 140, 255, 255, 255, 170, 170, 190 }
    for i = 3, 15 do
        local g = math.floor((i - 3) * 6)
        pal[#pal + 1], pal[#pal + 2], pal[#pal + 3] = g, g, g + 8
    end
    for i = #pal + 1, 768 do pal[i] = 0 end
    return image_create_indexed(w, h, px, pal), w, h, count
end

-- ── Shapes (Screen_v2 .SHP files) ──────────────────────────────────────────
function W.shape_count(d)
    return d and #d >= 6 and u16(d, 1) or 0
end

-- One shape: u16 flags, u8 height, u16 width, 3 bytes, u16 unpacked size, an
-- optional colour count (flags & 4) and colour table (flags & 1, 16 entries by
-- default; such shapes are drawn through the table), then LCW data unless
-- flags & 2. Rows are runs: a non-zero byte is a pixel, 0 + n skips n
-- transparent pixels. `lcw(data, pos, size)` returns a 1-based byte table.
-- Returns pixels (256 = transparent), width, height.
function W.decode_shape(d, index, lcw)
    if index >= W.shape_count(d) then return nil end
    local p = u32(d, 3 + index * 4) + 2 + 1
    if p + 9 > #d then return nil end
    local flags, height, width = u16(d, p), u8(d, p + 2), u16(d, p + 3)
    local size = u16(d, p + 8)
    p = p + 10
    if width == 0 or height == 0 or width > 640 or height > 400 then return nil end
    local ncolors = 16
    if flags % 8 >= 4 then ncolors = u8(d, p); p = p + 1 end
    local ctable
    if flags % 2 == 1 then
        ctable = {}
        for i = 0, ncolors - 1 do ctable[i] = u8(d, p + i) end
        p = p + ncolors
    end
    local src
    if math.floor(flags / 2) % 2 == 1 then
        src = {}
        for i = 1, math.min(size, #d - p + 1) do src[i] = d:byte(p + i - 1) end
    else
        src = lcw(d, p, size)
    end
    local px, s = {}, 1
    for y = 0, height - 1 do
        local x = 0
        while x < width do
            local c = src[s] or 0; s = s + 1
            if c ~= 0 then
                px[y * width + x + 1] = ctable and (ctable[c] or c) or c
                x = x + 1
            else
                local n = src[s] or 0; s = s + 1
                if n == 0 then n = width - x end
                for _ = 1, n do if x < width then px[y * width + x + 1] = 256; x = x + 1 end end
            end
        end
    end
    for i = 1, width * height do if px[i] == nil then px[i] = 256 end end
    return px, width, height
end

-- ── Resource tree and loading for the engines ──────────────────────────────
-- `files` lists { name =, archive = } (archive nil for loose files). Ids are
-- "ww_<kind>|<archive>|<name>|<index>".
local LANG_EXT = { ENG = "English", FRE = "French", GER = "German", ITA = "Italian", SPA = "Spanish", JPN = "Japanese" }

local function make_id(kind, f, index) return string.format("ww_%s|%s|%s|%d", kind, f.archive or "", f.name, index or 0) end

function W.extra_resources(files, read)
    local music, sounds, fonts, texts, shapes = {}, {}, {}, {}, {}
    table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
    local seen = {}
    for _, f in ipairs(files) do
        local key = f.name:upper()
        local ext = key:match("%.(%w+)$") or ""
        if not seen[key] then
            seen[key] = true
            local label = f.archive and (f.name .. " (" .. f.archive .. ")") or f.name
            if ext == "XMI" then
                -- Sequences without notes are unused slots; list the others.
                local notes = xmi_sequence_notes(read(f.archive, f.name) or "")
                local songs = {}
                for i = 1, #notes do
                    if notes[i] > 0 then
                        songs[#songs + 1] = { id = make_id("xmi", f, i - 1), name = string.format("Sequence %d (%d notes)", i - 1, notes[i]), type = "midi" }
                    end
                end
                if #songs > 1 then
                    music[#music + 1] = { id = make_id("xmidir", f), name = string.format("%s (%d)", label, #songs), type = "category", children = songs }
                elseif #songs == 1 then
                    songs[1].name = label
                    music[#music + 1] = songs[1]
                end
            elseif ext == "VOC" then
                sounds[#sounds + 1] = { id = make_id("voc", f), name = label, type = "sound" }
            elseif ext == "FNT" then
                fonts[#fonts + 1] = { id = make_id("fnt", f), name = label, type = "image" }
            elseif ext == "SHP" then
                local n = W.shape_count(read(f.archive, f.name))
                if n > 0 and n < 1000 then shapes[#shapes + 1] = { id = make_id("shp", f), name = string.format("%s (%d)", label, n), type = "image" } end
            elseif ext == "EMC" then
                local t = W.emc_text(read(f.archive, f.name))
                if t and #t > 0 then texts[#texts + 1] = { id = make_id("emc", f), name = string.format("%s (%d strings)", label, #t), type = "text" } end
            elseif LANG_EXT[ext] then
                local t = W.table_strings(read(f.archive, f.name))
                if t and #t > 0 then texts[#texts + 1] = { id = make_id("tbl", f), name = string.format("%s — %s (%d strings)", label, LANG_EXT[ext], #t), type = "text" } end
            end
        end
    end
    local out = {}
    local function add(id, name, list) if #list > 0 then out[#out + 1] = { id = id, name = string.format("%s (%d)", name, #list), type = "category", children = list } end end
    add("ww_shapes", "Shapes", shapes)
    add("ww_music", "Music (XMIDI)", music)
    add("ww_sounds", "Sounds (VOC)", sounds)
    add("ww_text", "Text", texts)
    add("ww_fonts", "Fonts", fonts)
    return out
end

-- `palette(used)` returns a 768-entry 8-bit RGB table suited to the set of
-- colour indices a shape sheet uses.
function W.load_extra(id, read, lcw, palette)
    local kind, archive, name, index = id:match("^ww_(%a+)|([^|]*)|([^|]+)|(%d+)$")
    if not kind then return nil end
    local data = read(archive ~= "" and archive or nil, name)
    if not data then return nil end
    index = tonumber(index)
    if kind == "xmi" then
        local midi = midi_create_from_xmi(data, index)
        return midi and { type = "midi", midi = midi, description = string.format("%s sequence %d — XMIDI", name, index) }
    elseif kind == "voc" then
        local snd = sound_create_encoded(data)
        return snd and { type = "sound", sound = snd, description = name .. " — Creative VOC" }
    elseif kind == "fnt" then
        local img, w, h, n = W.font_sheet(data)
        return img and { type = "image", image = img, description = string.format("%s — %d glyphs", name, n) }
    elseif kind == "emc" or kind == "tbl" then
        local t = kind == "emc" and W.emc_text(data) or W.table_strings(data)
        if not t then return nil end
        local lines = {}
        for i, str in ipairs(t) do lines[#lines + 1] = string.format("%4d  %s", i - 1, str) end
        return { type = "text", text = table.concat(lines, "\n"), description = string.format("%s — %d strings", name, #t) }
    elseif kind == "shp" then
        -- All shapes of the file side by side on one sheet.
        local list, total_w, max_h = {}, 2, 0
        for i = 0, W.shape_count(data) - 1 do
            local px, w, h = W.decode_shape(data, i, lcw)
            if px then list[#list + 1] = { px = px, w = w, h = h }; total_w = total_w + w + 2; max_h = math.max(max_h, h) end
        end
        if #list == 0 then return nil end
        local cols = math.max(1, math.floor(math.sqrt(#list) * 1.5))
        local rows, x, y, rowh, sheetw = {}, 2, 2, 0, 0
        local placed = {}
        for i, s in ipairs(list) do
            if (i - 1) % cols == 0 and i > 1 then x = 2; y = y + rowh + 2; rowh = 0 end
            placed[#placed + 1] = { s = s, x = x, y = y }
            x = x + s.w + 2; rowh = math.max(rowh, s.h); sheetw = math.max(sheetw, x)
        end
        local sheeth = y + rowh + 2
        local used = {}
        for _, s in ipairs(list) do for _, c in ipairs(s.px) do if c < 256 then used[c] = true end end end
        local px = {}
        for i = 1, sheetw * sheeth do px[i] = 256 end
        for _, pl in ipairs(placed) do
            for yy = 0, pl.s.h - 1 do
                for xx = 0, pl.s.w - 1 do
                    px[(pl.y + yy) * sheetw + pl.x + xx + 1] = pl.s.px[yy * pl.s.w + xx + 1]
                end
            end
        end
        return { type = "image", image = image_create_indexed(sheetw, sheeth, px, palette(used), 256),
            description = string.format("%s — %d shapes", name, #list) }
    end
end

return W

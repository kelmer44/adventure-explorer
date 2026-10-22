-- ============================================================================
-- Adventure Explorer - Engine Script: Genus GXL (Capstone, 1992-1993)
-- ============================================================================
-- Handles Capstone games whose graphics are stored in Genus Microprogramming
-- GXL containers:
--   * Wayne's World (1993, Capstone / Gray Matter) -- R00-R39, E00/E01,
--     M00-M06, OA2/OA3/OAN .GXL (plus *.MSK 1bpp masks, *.SND, *.TXT, *.GFT)
--   * The Dark Half (1993, Capstone) -- K*.GXL (e.g. KEA00.GXL)
--
-- GXL container layout
--   +0x00  u8   0x01
--   +0x01  u8   0xCA
--   +0x02  ASCII "Copyright (c) Genus Microprogramming, Inc. 1988-90"
--   +0x80  directory of 26-byte entries, terminated by the first data offset:
--            +0  u8   flag (0x00 for graphics)
--            +1  char[12] entry name, space padded (e.g. "BACKG   .PCX")
--            +13 u8   NUL
--            +14 u32le data offset (absolute file offset)
--            +18 u32le data size (bytes)
--            +22 u32le unknown (unused)
--          number of entries = (firstDataOffset - 0x80) / 26
--   Each entry payload is a standard version-5 PCX (8bpp, single plane, RLE)
--   with its 256-colour palette in the trailing 768 bytes (after a 0x0C
--   marker).  A few entries in the E00/M0x files are raw (non-PCX) data and
--   are skipped.
-- ============================================================================

local engine = {}

engine.name        = "Genus GXL"
engine.id          = "gxl"
engine.description = "Capstone games using Genus GXL graphics (Wayne's World, The Dark Half)"
engine.version     = "1.0"

-- ── Binary helpers ───────────────────────────────────────────────

local function u8(data, pos)
    return data:byte(pos)
end

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end

local GXL_DIR_START = 0x80
local GXL_ENTRY_SIZE = 26
local GENUS_SIG = "Genus Microprogramming"

-- Return the prefix of s up to the first NUL, with trailing spaces removed.
local function clean_name(s)
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        if b == 0 then break end
        out[#out + 1] = string.char(b)
    end
    return (string.gsub(table.concat(out), "%s+$", ""))
end

local function has_gxl_signature(path)
    local f = file_open(path)
    if not f then return false end
    local hdr = file_read(f, 0, 64)
    file_close(f)
    if not hdr or #hdr < 3 then return false end
    if u8(hdr, 1) ~= 0x01 or u8(hdr, 2) ~= 0xCA then return false end
    return hdr:find(GENUS_SIG, 1, true) ~= nil
end

-- Return the sorted list of *.GXL file names in game_path.
local function gxl_files(game_path)
    local out = {}
    local files = list_files(game_path)
    if not files then return out end
    for _, name in ipairs(files) do
        local upper = name:upper()
        if upper:sub(-4) == ".GXL" then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end

-- Parse the directory of one GXL file.  Returns { {name=, offset=, size=}, ... }
-- and the file size, or nil on failure.
local function parse_gxl(f)
    local size = file_size(f)
    if size < GXL_DIR_START + GXL_ENTRY_SIZE then return nil end

    local entries = {}
    local off = GXL_DIR_START
    local guard = 0
    while off + GXL_ENTRY_SIZE <= size and guard < 4096 do
        guard = guard + 1
        local rec = file_read(f, off, GXL_ENTRY_SIZE)
        if not rec or #rec < GXL_ENTRY_SIZE then break end

        local flag = u8(rec, 1)
        local name = clean_name(rec:sub(2, 13))
        local data_off = u32le(rec, 15)
        local data_sz  = u32le(rec, 19)

        -- The directory terminates when we reach the first data block
        if data_off == 0 or data_off < off + GXL_ENTRY_SIZE or data_off > size then
            break
        end

        entries[#entries + 1] = { flag = flag, name = name, offset = data_off, size = data_sz }
        off = off + GXL_ENTRY_SIZE
        if off >= data_off then break end
    end

    if #entries == 0 then return nil end
    return entries
end

-- ── Detection ────────────────────────────────────────────────────

function engine.detect(game_path)
    local files = gxl_files(game_path)
    -- Require at least two GXL files sharing the Genus signature so we do not
    -- misfire on an unrelated file that merely ends in ".GXL".
    local hits = 0
    for i = 1, math.min(#files, 4) do
        if has_gxl_signature(game_path .. "/" .. files[i]) then
            hits = hits + 1
        end
    end
    return hits >= 2
end

-- ── Resource tree ────────────────────────────────────────────────

-- ── Loose sound, music, text, font and mask files ────────────────
-- *.SND  raw unsigned 8-bit mono PCM, no header (DigPak); the rate is not
--        stored, 11025 Hz is assumed.
-- *.XMI  XMIDI (MidPak).
-- *.TXT  one line per message, each byte with bit 7 set is ASCII | 0x80
--        (0x8A ends a line); bytes below 0x80 are the font's extra glyphs
--        for Spanish letters, laid out differently in each game; 0x7F ends
--        the file.
-- *.GFT  Genus bitmap font: u16 first/last character at +0x24/+0x26,
--        u32 x-offset table and bitmap offsets at +0x48/+0x4C, u16 bytes per
--        row and height at +0x50; the glyphs sit side by side in one 1bpp
--        strip and glyph c spans x[c]..x[c+1].
-- *.MSK  1bpp 320x150 walk masks (Wayne's World).

local SND_RATE = 11025
local MASK_W, MASK_H = 320, 150

-- Extra glyph codes per game (identified by its data files).
local SPANISH = {
    wayne = { [0x01] = "ü", [0x02] = "é", [0x20] = "á", [0x21] = "í", [0x22] = "ó", [0x23] = "ú",
              [0x24] = "ñ", [0x25] = "Ñ", [0x26] = "ª", [0x28] = "¿", [0x2D] = "¡" },
    darkhalf = { [0x02] = "É", [0x03] = "Ó", [0x05] = "Ú", [0x20] = "á", [0x21] = "í", [0x22] = "é",
                 [0x23] = "ó", [0x24] = "ñ", [0x25] = "ú", [0x28] = "¿", [0x2D] = "¡" },
}

local function read_file(path)
    local f = file_open(path)
    if not f then return nil end
    local data = file_read(f, 0, file_size(f)) or ""
    file_close(f)
    return data
end

local function files_with_ext(game_path, ext)
    local out = {}
    for _, name in ipairs(list_files(game_path) or {}) do
        if name:upper():match("%." .. ext .. "$") then out[#out + 1] = name end
    end
    table.sort(out, function(a, b) return a:upper() < b:upper() end)
    return out
end

local function game_variant(game_path)
    for _, name in ipairs(gxl_files(game_path)) do
        if name:upper():match("^K") then return "darkhalf" end
    end
    return "wayne"
end

local function decode_txt(data, variant)
    local map = SPANISH[variant] or {}
    local out = {}
    for i = 1, #data do
        local b = data:byte(i)
        if b == 0x7F then break end
        if b >= 0x80 then
            out[#out + 1] = string.char(b - 0x80)
        else
            out[#out + 1] = map[b] or string.char(b)
        end
    end
    local lines = {}
    for line in (table.concat(out) .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("%s+$", ""))
    end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    return table.concat(lines, "\n")
end

local function decode_gft(data)
    if #data < 0x54 then return nil end
    local first, last = u16le(data, 0x25), u16le(data, 0x27)
    local xtab, bmp = u32le(data, 0x49), u32le(data, 0x4D)
    local row, h = u16le(data, 0x51), u16le(data, 0x53)
    local count = last - first + 1
    if count <= 0 or h == 0 or xtab + (count + 1) * 2 > #data or bmp + row * h > #data then return nil end
    local xs, cell_w = {}, 1
    for i = 0, count do xs[i] = u16le(data, xtab + 1 + i * 2) end
    for i = 0, count - 1 do cell_w = math.max(cell_w, xs[i + 1] - xs[i]) end
    -- Grid of 16 glyphs per row, printable characters only.
    local glyphs = {}
    for c = math.max(first, 32), last do glyphs[#glyphs + 1] = c end
    local cols = 16
    local cw, ch = cell_w + 2, h + 2
    local w, rows = cols * cw, math.ceil(#glyphs / cols)
    local px = {}
    for i = 1, w * rows * ch do px[i] = 0 end
    for gi, c in ipairs(glyphs) do
        local x0, x1 = xs[c - first], xs[c - first + 1]
        local ox = ((gi - 1) % cols) * cw + 1
        local oy = math.floor((gi - 1) / cols) * ch + 1
        for y = 0, h - 1 do
            for x = x0, x1 - 1 do
                local byte = data:byte(bmp + 1 + y * row + math.floor(x / 8)) or 0
                if math.floor(byte / 2 ^ (7 - x % 8)) % 2 == 1 then
                    px[(oy + y) * w + ox + (x - x0) + 1] = 1
                end
            end
        end
    end
    local pal = { 0, 0, 0, 255, 255, 255 }
    for i = 7, 768 do pal[i] = 0 end
    return image_create_indexed(w, rows * ch, px, pal), #glyphs, first, last
end

local function extra_resources(game_path)
    local cats = {}
    local function add(id, title, ext, kind, prefix)
        local kids = {}
        for _, name in ipairs(files_with_ext(game_path, ext)) do
            kids[#kids + 1] = { id = prefix .. name, name = name, type = kind }
        end
        if #kids > 0 then
            cats[#cats + 1] = { id = id, name = string.format("%s (%d)", title, #kids), type = "category", children = kids }
        end
    end
    add("gx_sounds", "Sound", "SND", "sound", "gx_snd_")
    local music = {}
    for _, name in ipairs(files_with_ext(game_path, "XMI")) do
        local notes = xmi_sequence_notes(read_file(game_path .. "/" .. name) or "")
        for i = 1, #notes do
            if notes[i] > 0 then
                local label = #notes > 1 and string.format("%s sequence %d", name, i - 1) or name
                music[#music + 1] = { id = string.format("gx_xmi_%d_%s", i - 1, name), name = label, type = "midi" }
            end
        end
    end
    if #music > 0 then
        cats[#cats + 1] = { id = "gx_music", name = string.format("Music (%d)", #music), type = "category", children = music }
    end
    add("gx_texts", "Text", "TXT", "text", "gx_txt_")
    add("gx_fonts", "Fonts", "GFT", "image", "gx_gft_")
    add("gx_masks", "Masks", "MSK", "image", "gx_msk_")
    return cats
end

local function load_extra(game_path, resource_id)
    local kind, rest = resource_id:match("^gx_(%a+)_(.+)$")
    if kind == "xmi" then
        local idx, name = rest:match("^(%d+)_(.+)$")
        local data = read_file(game_path .. "/" .. name)
        local midi = data and midi_create_from_xmi(data, tonumber(idx))
        return midi and { type = "midi", midi = midi, description = name .. " — XMIDI" }
    end
    local data = read_file(game_path .. "/" .. rest)
    if not data then return nil end
    if kind == "snd" then
        local snd = sound_create_pcm(SND_RATE, 8, 1, false, data)
        return snd and { type = "sound", sound = snd,
            description = string.format("%s — 8-bit PCM, %d Hz assumed", rest, SND_RATE) }
    elseif kind == "txt" then
        return { type = "text", text = decode_txt(data, game_variant(game_path)), description = rest }
    elseif kind == "gft" then
        local img, n, first, last = decode_gft(data)
        return img and { type = "image", image = img,
            description = string.format("%s — %d glyphs (characters %d-%d)", rest, n, first, last) }
    elseif kind == "msk" then
        if #data < MASK_W * MASK_H / 8 then return nil end
        local px = {}
        for i = 0, MASK_W * MASK_H - 1 do
            local byte = data:byte(math.floor(i / 8) + 1)
            px[i + 1] = math.floor(byte / 2 ^ (7 - i % 8)) % 2
        end
        local pal = { 0, 0, 0, 255, 255, 255 }
        for i = 7, 768 do pal[i] = 0 end
        return { type = "image", image = image_create_indexed(MASK_W, MASK_H, px, pal),
            description = string.format("%s — %dx%d walk mask", rest, MASK_W, MASK_H) }
    end
    return nil
end

function engine.get_resources(game_path)
    local resources = {}
    local files = gxl_files(game_path)

    for _, fname in ipairs(files) do
        local path = game_path .. "/" .. fname
        local f = file_open(path)
        if f then
            local entries = parse_gxl(f)
            local fsize = file_size(f)
            file_close(f)

            if entries then
                local base = fname:sub(1, -5)  -- strip ".GXL"
                local cat = {
                    id       = "file_" .. base,
                    name     = string.format("%s (%d entries)", fname, #entries),
                    type     = "category",
                    children = {}
                }
                for idx, e in ipairs(entries) do
                    local nice = e.name
                    if nice == "" or nice:sub(1, 1) == "\0" then
                        nice = string.format("Entry %d", idx - 1)
                    end
                    cat.children[#cat.children + 1] = {
                        id   = string.format("img_%s_%d", base, idx - 1),
                        name = string.format("%s  [%d B]", nice, e.size),
                        type = "image"
                    }
                end
                resources[#resources + 1] = cat
            end
        end
    end

    for _, cat in ipairs(extra_resources(game_path)) do
        resources[#resources + 1] = cat
    end

    log_info(string.format("GXL: %d GXL files", #files))
    return resources
end

-- ── PCX decoder (8-bit, single plane, RLE) ───────────────────────

local function decode_pcx(data)
    if not data or #data < 129 then return nil end
    if u8(data, 1) ~= 0x0A then return nil end  -- PCX manufacturer

    local bpp     = u8(data, 4)
    local xmin    = u16le(data, 5)
    local ymin    = u16le(data, 7)
    local xmax    = u16le(data, 9)
    local ymax    = u16le(data, 11)
    local nplanes = u8(data, 66)
    local bytespl = u16le(data, 67)

    local width  = xmax - xmin + 1
    local height = ymax - ymin + 1
    if width <= 0 or height <= 0 or width > 1024 or height > 1024 then return nil end
    if bpp ~= 8 or nplanes ~= 1 then return nil end

    local total = bytespl * height
    local pixels = {}
    local pos = 129
    local n = 0
    while n < total and pos <= #data do
        local b = u8(data, pos)
        pos = pos + 1
        if b >= 192 then
            local count = b - 192
            local value = (pos <= #data) and u8(data, pos) or 0
            pos = pos + 1
            for _ = 1, count do
                if n >= total then break end
                n = n + 1; pixels[n] = value
            end
        else
            n = n + 1; pixels[n] = b
        end
    end

    -- Trim row padding to the real width.
    if bytespl > width then
        local trimmed = {}
        local idx = 0
        for row = 0, height - 1 do
            for col = 0, width - 1 do
                idx = idx + 1
                trimmed[idx] = pixels[row * bytespl + col + 1] or 0
            end
        end
        pixels = trimmed
    elseif n < width * height then
        for i = n + 1, width * height do pixels[i] = 0 end
    end

    -- Trailing 256-colour palette (preceded by 0x0C marker).
    local palette = {}
    if #data >= 769 then
        local pal_off = #data - 768
        if u8(data, pal_off) == 0x0C then
            for i = 0, 255 do
                palette[i * 3 + 1] = u8(data, pal_off + 1 + i * 3)
                palette[i * 3 + 2] = u8(data, pal_off + 2 + i * 3)
                palette[i * 3 + 3] = u8(data, pal_off + 3 + i * 3)
            end
        end
    end
    if #palette == 0 then
        for i = 0, 255 do
            palette[i * 3 + 1] = i; palette[i * 3 + 2] = i; palette[i * 3 + 3] = i
        end
    end

    return { width = width, height = height, pixels = pixels, palette = palette }
end

-- ── Resource dispatcher ──────────────────────────────────────────

function engine.load_resource(game_path, resource_id, palette_id)
    if resource_id:match("^gx_") then return load_extra(game_path, resource_id) end

    local base, idx_s = resource_id:match("^img_(.+)_(%d+)$")
    if not base or not idx_s then return nil end
    local idx = tonumber(idx_s)

    local path = game_path .. "/" .. base .. ".GXL"
    if not file_exists(path) then
        -- Try to match case-insensitively against the directory listing.
        for _, fname in ipairs(gxl_files(game_path)) do
            if fname:sub(1, -5):lower() == base:lower() then
                path = game_path .. "/" .. fname
                break
            end
        end
    end

    local f = file_open(path)
    if not f then return nil end
    local entries = parse_gxl(f)
    local fsize = file_size(f)
    if not entries or not entries[idx + 1] then file_close(f); return nil end

    local e = entries[idx + 1]
    local blob = file_read(f, e.offset, e.size)
    file_close(f)
    if not blob or #blob < 129 then return nil end

    local pcx = decode_pcx(blob)
    if not pcx then
        return {
            type = "text",
            text = string.format(
                "Not a decodable PCX image.\n\nEntry: %s\nOffset: 0x%X\nSize: %d bytes\nMagic: %s",
                e.name, e.offset, e.size,
                blob:sub(1, 4):gsub(".", function(c) return string.format("%02X ", c:byte()) end)
            )
        }
    end

    local img = image_create_indexed(pcx.width, pcx.height, pcx.pixels, pcx.palette)
    return {
        type = "image", image = img, width = pcx.width, height = pcx.height,
        description = string.format("%s - %dx%d PCX @0x%X (%d B)",
            e.name, pcx.width, pcx.height, e.offset, e.size)
    }
end

return engine

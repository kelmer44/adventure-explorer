-- ============================================================================
-- Adventure Explorer - Engine Script: Interspective (La Abadia/Alcachofa Soft)
-- ============================================================================
-- Supports 4 games using the Interspective engine:
--   GENE / Genesis: Hijos del Crepusculo (VIC_ prefix)
--   IUC / IUC: La linea de la vida (IUC_ prefix)
--   GUILTY / GBG (GBG_ prefix)
--   ORION / Orion: A Sci Fi Visual Novel (CER_ prefix)
--
-- Background image format:
--   u16le width + u16le height + PCX-RLE compressed 8-bit pixels
--   Palette at end of file: 0x0C marker + 768 bytes (256 * RGB)
--
-- PCX-RLE: if byte >= 0xC0, count = byte & 0x3F, next = value; else literal
--
-- Background file locations vary by game:
--   GENE: *_NNNS.DAT files (e.g., VIC_000S.DAT)
--   IUC:  *_NNN.DAT files (IUC_001-015), all start with valid w/h
--   GBG:  *_NNN.DAT files where first 4 bytes give valid w/h
--   ORION: *_NNN[A-Z].DAT files where first 4 bytes give valid w/h
--
-- GRAF.DAT: groups of u32le offsets (separated by 0), pointing to sub-images
--   within numbered DAT files. For IUC, these are scene overlays.
--
-- ORION sprite banks (partial support, no renderable sprites):
--   ORION has no MAIN file. CER_GRAF.DAT groups map 1:1 to the alphabetically
--   sorted CER_*.DAT files; each offset is a per-file sprite bank:
--   u32 size + u32le `count*4` offset table + sprite data + 8-byte ASCII name.
--   Banks are self-describing, but sprite dimensions live in the game EXE, so
--   banks are listed as info resources. ORION.RNC is a Pro-Pack archive whose
--   plain filename index is also exposed as an info resource.
-- ============================================================================

local engine = {}
engine.name        = "Interspective"
engine.id          = "interspective"
engine.description = "Interspective engine (La Abadia / Alcachofa Soft)"
engine.version     = "1.0"

-- ============================================================================
-- Binary helpers
-- ============================================================================

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function u32le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536 + data:byte(pos + 3) * 16777216
end

-- ============================================================================
-- PCX-RLE decoder
-- ============================================================================

local function decode_rle(data, start_pos, total_pixels)
    local pixels = {}
    local n = 0
    local pos = start_pos
    local len = #data

    while n < total_pixels and pos <= len do
        local b = data:byte(pos)
        pos = pos + 1
        if b >= 192 then
            local count = b - 192
            local value = (pos <= len) and data:byte(pos) or 0
            pos = pos + 1
            for _ = 1, count do
                if n >= total_pixels then break end
                n = n + 1
                pixels[n] = value
            end
        else
            n = n + 1
            pixels[n] = b
        end
    end

    -- Fill remaining with 0
    while n < total_pixels do
        n = n + 1
        pixels[n] = 0
    end

    return pixels, pos
end

-- ============================================================================
-- Read palette: tries position after pixel data first, then scans for 0x0C
-- marker near that position, then falls back to EOF palette.
-- ============================================================================

local function read_palette_at_pos(data, marker_pos)
    local palette = {}
    if marker_pos >= 1 and marker_pos + 768 <= #data then
        local marker = data:byte(marker_pos)
        if marker == 0x0C then
            for i = 0, 255 do
                palette[i * 3 + 1] = data:byte(marker_pos + 1 + i * 3) or 0
                palette[i * 3 + 2] = data:byte(marker_pos + 2 + i * 3) or 0
                palette[i * 3 + 3] = data:byte(marker_pos + 3 + i * 3) or 0
            end
            return palette
        end
    end
    return nil
end

local function read_palette_from_data(data, after_pixels_pos)
    -- Try reading palette right after the pixel data
    if after_pixels_pos then
        local pal = read_palette_at_pos(data, after_pixels_pos)
        if pal then return pal end
    end

    -- Fallback: palette at end of file (0x0C + 768 bytes)
    if #data >= 769 then
        local pal = read_palette_at_pos(data, #data - 768)
        if pal then return pal end
    end

    -- Last resort: grayscale palette
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = i
        palette[i * 3 + 2] = i
        palette[i * 3 + 3] = i
    end
    return palette
end

-- ============================================================================
-- Decode a background image from raw file data
-- ============================================================================

local function decode_background(data)
    if not data or #data < 5 then return nil end

    local w = u16le(data, 1)
    local h = u16le(data, 3)

    if w < 16 or w > 2000 or h < 16 or h > 1200 then
        return nil
    end

    local total = w * h
    local pixels, end_pos = decode_rle(data, 5, total)
    local palette = read_palette_from_data(data, end_pos)

    return {
        width   = w,
        height  = h,
        pixels  = pixels,
        palette = palette
    }
end

-- ============================================================================
-- Decode a sub-image at a given offset within file data
-- ============================================================================

local function decode_subimage(data, offset, palette)
    local pos = offset + 1  -- Lua 1-indexed
    if pos + 4 > #data then return nil end

    local w = u16le(data, pos)
    local h = u16le(data, pos + 2)

    if w < 1 or w > 2000 or h < 1 or h > 1200 then
        return nil
    end

    local total = w * h
    local pixels, end_pos = decode_rle(data, pos + 4, total)

    -- Use palette passed in, or try to read from after pixel data
    if not palette then
        palette = read_palette_from_data(data, end_pos)
    end

    return {
        width   = w,
        height  = h,
        pixels  = pixels,
        palette = palette
    }
end

-- ============================================================================
-- Game detection and prefix helpers
-- ============================================================================

local KNOWN_PREFIXES = {"VIC_", "IUC_", "GBG_", "CER_", "JTL_", "YSA_"}
local GAME_NAMES = {
    VIC_ = "Genesis: Hijos del Crepusculo",
    IUC_ = "IUC: La linea de la vida",
    GBG_ = "Guilty",
    CER_ = "Orion: A Sci-Fi Visual Novel",
    JTL_ = "JTL",
    YSA_ = "YSA"
}

local function detect_prefix(game_path)
    local files = list_files(game_path)
    if not files then return nil end

    for _, f in ipairs(files) do
        for _, prefix in ipairs(KNOWN_PREFIXES) do
            if f:sub(1, #prefix):upper() == prefix then
                local graf = prefix .. "GRAF.DAT"
                local main = prefix .. "MAIN.DAT"
                if file_exists(game_path .. "/" .. graf)
                or file_exists(game_path .. "/" .. main) then
                    return prefix
                end
            end
        end
    end
    return nil
end

function engine.detect(game_path)
    return detect_prefix(game_path) ~= nil
end

-- ============================================================================
-- Parse GRAF.DAT offset table into groups
-- ============================================================================

local function parse_graf(game_path, prefix)
    local path = game_path .. "/" .. prefix .. "GRAF.DAT"
    if not file_exists(path) then return nil end

    local fh = file_open(path)
    if not fh then return nil end
    local sz = file_size(fh)
    local data = file_read(fh, 0, sz)
    file_close(fh)
    if not data then return nil end

    local count = math.floor(#data / 4)
    local groups = {}
    local current = {}

    for i = 0, count - 1 do
        local v = u32le(data, i * 4 + 1)
        if v == 0 then
            if #current > 0 then
                groups[#groups + 1] = current
                current = {}
            end
        else
            current[#current + 1] = v
        end
    end
    if #current > 0 then
        groups[#groups + 1] = current
    end

    return groups
end

-- ============================================================================
-- Scan for background files based on game prefix
-- ============================================================================

local function scan_backgrounds(game_path, prefix)
    local files = list_files(game_path)
    if not files then return {} end

    local backgrounds = {}
    local prefix_upper = prefix:upper()

    -- Scan all DAT files with matching prefix and check first 4 bytes for valid w/h
    for _, f in ipairs(files) do
        local fu = f:upper()
        if fu:sub(1, #prefix_upper) == prefix_upper and fu:match("%.DAT$") then
            -- Skip non-scene files (GRAF, MAIN, F*, S*, A*, SDFX, TUNE)
            local suffix = fu:sub(#prefix_upper + 1)
            if not suffix:match("^GRAF") and not suffix:match("^MAIN")
               and not suffix:match("^F%d") and not suffix:match("^S%d")
               and not suffix:match("^SDFX") and not suffix:match("^TUNE")
               and not suffix:match("^A%d") then
                -- Read first 4 bytes to check dimensions
                local path = game_path .. "/" .. f
                local fh = file_open(path)
                if fh then
                    local hdr = file_read(fh, 0, 4)
                    file_close(fh)
                    if hdr and #hdr >= 4 then
                        local w = u16le(hdr, 1)
                        local h = u16le(hdr, 3)
                        if w >= 16 and w <= 2000 and h >= 16 and h <= 1200 then
                            -- Extract scene number and optional letter suffix
                            local num = suffix:match("^(%d%d%d)")
                            local letter = suffix:match("^%d%d%d(%a)") or ""
                            local scene = num or suffix:match("^(.-)%.DAT$") or ""
                            backgrounds[#backgrounds + 1] = {
                                filename = f,
                                scene    = scene .. letter,
                                label    = "Scene " .. scene .. (letter ~= "" and (" (" .. letter .. ")") or ""),
                                width    = w,
                                height   = h
                            }
                        end
                    end
                end
            end
        end
    end

    -- Sort by scene
    table.sort(backgrounds, function(a, b) return a.scene < b.scene end)
    return backgrounds
end

-- ============================================================================
-- Scan for multiple backgrounds embedded in a single DAT file (Guilty).
-- Each GBG_NNN.DAT / GBG_FNN.DAT holds several images back to back, each laid
-- out as: u16 width (320) + u16 height + PCX-RLE pixels + 0x0C + 768 palette.
-- They are interleaved with sprite data and offset tables, so the file is
-- searched for the 320-wide header and validated by decoding the RLE stream
-- and checking that it ends exactly on the 0x0C palette marker.
-- ============================================================================

local EMBEDDED_WIDTH = 320

local function rle_pixel_count(data, pos, total)
    local n, len = 0, #data
    local byte = string.byte
    while n < total and pos <= len do
        local b = byte(data, pos)
        if b >= 192 then
            n = n + (b - 192)
            pos = pos + 2
        else
            n = n + 1
            pos = pos + 1
        end
    end
    return n, pos
end

local function find_embedded_images(data)
    local found = {}
    local len = #data
    local pos = 1
    local needle = string.char(EMBEDDED_WIDTH % 256, math.floor(EMBEDDED_WIDTH / 256))
    while true do
        local s = data:find(needle, pos, true)
        if not s or s + 4 > len then break end
        local h = u16le(data, s + 2)
        local next_pos = s + 1
        if h >= 16 and h <= 480 then
            local total = EMBEDDED_WIDTH * h
            local count, p = rle_pixel_count(data, s + 4, total)
            if count == total and p + 768 <= len and data:byte(p) == 0x0C then
                found[#found + 1] = { offset = s - 1, width = EMBEDDED_WIDTH, height = h }
                next_pos = p + 769
            end
        end
        pos = next_pos
    end
    return found
end

local function scan_embedded_backgrounds(game_path, prefix)
    local files = list_files(game_path)
    if not files then return {} end

    local prefix_upper = prefix:upper()
    local names = {}
    for _, f in ipairs(files) do
        local suffix = f:upper():match("^" .. prefix_upper .. "(.-)%.DAT$")
        if suffix and (suffix:match("^%d%d%d$") or suffix:match("^F%d%d$")) then
            names[#names + 1] = { filename = f, suffix = suffix }
        end
    end
    table.sort(names, function(a, b) return a.suffix < b.suffix end)

    local backgrounds = {}
    for _, entry in ipairs(names) do
        local fh = file_open(game_path .. "/" .. entry.filename)
        if fh then
            local data = file_read(fh, 0, file_size(fh))
            file_close(fh)
            if data then
                local images = find_embedded_images(data)
                for i, img in ipairs(images) do
                    backgrounds[#backgrounds + 1] = {
                        filename = entry.filename,
                        offset   = img.offset,
                        label    = string.format("%s #%d (%dx%d)", entry.suffix, i, img.width, img.height),
                        width    = img.width,
                        height   = img.height
                    }
                end
            end
        end
    end
    return backgrounds
end

-- ============================================================================
-- Sprite banks (Guilty / GBG)
-- ----------------------------------------------------------------------------
-- GBG_MAIN.DAT is XOR-0x6F obfuscated after the first 2 bytes and ends with a
-- 0xB6-byte footer of u16le offsets into the descrambled data:
--   0x18 spriteCount   0x1A spriteMap      0x1C imagesCount
--   0x1E imageDirectory 0x20 graphicFileCount 0x22 graphicFileNames
--
-- GRAF.DAT is a flat table of u32le offsets (one per image, 1-based) into the
-- numbered graphic files.  The sprite map holds fixed 10-byte records:
--   u16 image, u16 index, u16 width, u16 height, u16 extra
-- Records are grouped by image.  Each referenced image is a "sprite bank":
--   u32 size, then `count` u32le offsets (relative to the table start), then
--   the raw uncompressed 8-bit sprite pixels, followed by an 8-byte name
--   ("font", "gen_graf", "statanim", ...).  Sprites share the palette of the
-- graphic file they live in (taken from that file's first embedded image).
-- ============================================================================

local xor6f = {}
do
    for i = 0, 255 do
        local v = 0
        for b = 0, 7 do
            local xb = math.floor(i / 2 ^ b) % 2
            local kb = math.floor(0x6f / 2 ^ b) % 2
            if xb ~= kb then v = v + 2 ^ b end
        end
        xor6f[i] = v
    end
end

local function descramble_main(raw)
    local len = u16le(raw, 1)
    if len <= 2 or len > #raw then return nil end
    local parts = { raw:sub(1, 2) }
    for i = 3, len do
        parts[#parts + 1] = string.char(xor6f[raw:byte(i)])
    end
    return table.concat(parts), len
end

local function read_graf_table(game_path, prefix)
    local path = game_path .. "/" .. prefix .. "GRAF.DAT"
    if not file_exists(path) then return nil end
    local fh = file_open(path)
    if not fh then return nil end
    local data = file_read(fh, 0, file_size(fh))
    file_close(fh)
    return data
end

local function graf_offset(graf, index)
    local pos = (index - 1) * 4 + 1
    if pos + 3 > #graf then return nil end
    return u32le(graf, pos)
end

local function find_file_palette(data)
    local imgs = find_embedded_images(data)
    if #imgs == 0 then return nil end
    local img = imgs[1]
    local s = img.offset + 1
    local _, p = rle_pixel_count(data, s + 4, img.width * img.height)
    if p + 768 <= #data and data:byte(p) == 0x0C then
        local palette = {}
        for i = 0, 255 do
            palette[i * 3 + 1] = data:byte(p + 1 + i * 3)
            palette[i * 3 + 2] = data:byte(p + 2 + i * 3)
            palette[i * 3 + 3] = data:byte(p + 3 + i * 3)
        end
        return palette
    end
    return nil
end

local function grayscale_palette()
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = i
        palette[i * 3 + 2] = i
        palette[i * 3 + 3] = i
    end
    return palette
end

local bank_cache = {}

local function resolve_file(game_path, name)
    if not name or name == "" then return nil end
    local direct = game_path .. "/" .. name
    if file_exists(direct) then return direct end
    local files = list_files(game_path)
    if files then
        local lower = name:lower()
        for _, f in ipairs(files) do
            if f:lower() == lower then return game_path .. "/" .. f end
        end
    end
    return nil
end

-- GBG graphic file names are NUL-terminated, each preceded by 2 bytes.
local function build_names_gbg(d, graphic_names, graphic_count)
    local files = {}
    local p = graphic_names + 1
    for i = 1, graphic_count do
        p = p + 2
        local s = p
        while p <= #d and d:byte(p) ~= 0 do p = p + 1 end
        files[i] = d:sub(s, p - 1)
        while p <= #d and d:byte(p) == 0 do p = p + 1 end
    end
    return files
end

-- GENE graphic file names are stored as [attrs...][0xFF][name NUL][attrs...],
-- so a valid name must start immediately after the 0xFF marker.
local function build_names_gene(d, graphic_names, graphic_count)
    local files = {}
    local len = #d
    local pos = graphic_names + 1
    while #files < graphic_count and pos <= len do
        while pos <= len and d:byte(pos) ~= 0xFF do pos = pos + 1 end
        pos = pos + 1
        local nm = pos <= len and d:sub(pos):match("^([%w_]+%.dat)%z")
        if nm then
            files[#files + 1] = nm
            pos = pos + #nm
        end
    end
    return files
end

-- GENE GRAF.DAT is a concatenation of per-file offset lists separated by a
-- zero.  The first image of every file has offset 0 (the separator itself).
local function graf_groups(graf)
    local groups = {}
    local current = nil
    local count = math.floor(#graf / 4)
    for i = 0, count - 1 do
        local v = u32le(graf, i * 4 + 1)
        if v == 0 then
            if current then groups[#groups + 1] = current end
            current = { 0 }
        else
            if not current then current = { 0 } end
            current[#current + 1] = v
        end
    end
    if current then groups[#groups + 1] = current end
    return groups
end

-- GENE sprites live in the palette of the room backdrop, so sprites have no
-- palette of their own.  Use the palette of a scene backdrop as the default.
local gene_pal_cache = {}
local function gene_default_palette(game_path)
    if gene_pal_cache[game_path] ~= nil then return gene_pal_cache[game_path] end
    local pal = nil
    local files = list_files(game_path)
    if files then
        local scenes = {}
        for _, f in ipairs(files) do
            if f:upper():match("^VIC_%d%d%dS%.DAT$") then scenes[#scenes + 1] = f end
        end
        table.sort(scenes)
        for _, f in ipairs(scenes) do
            local fh = file_open(game_path .. "/" .. f)
            if fh then
                local data = file_read(fh, 0, file_size(fh))
                file_close(fh)
                if data then
                    local w = u16le(data, 1)
                    local h = u16le(data, 3)
                    if w >= 16 and h >= 16 then
                        local _, p = decode_rle(data, 5, w * h)
                        pal = read_palette_at_pos(data, p)
                    end
                end
            end
            if pal then break end
        end
    end
    gene_pal_cache[game_path] = pal
    return pal
end

-- ============================================================================
-- ORION sprite banks (CER_ prefix, partial support)
-- ----------------------------------------------------------------------------
-- CER_GRAF.DAT is a concatenation of per-file offset lists separated by zeros
-- (same zero-grouped layout as GENE).  Group index g (1-based) maps to the
-- g-th alphabetically sorted CER_*.DAT scene file, and each offset in the
-- group is a per-file sprite bank: u32 size, u32le `count*4` offset table,
-- sprite data, 8-byte ASCII name.  Offsets that are not banks are background
-- images (w/h header) and are skipped.  Sprite dimensions are not stored, so
-- banks are exposed as info (text) resources rather than images.
-- ============================================================================

local orion_cache = {}

local function orion_bank_files(game_path, prefix)
    local names = {}
    local files = list_files(game_path)
    if not files then return names end
    local prefix_upper = prefix:upper()
    for _, f in ipairs(files) do
        local fu = f:upper()
        if fu:sub(1, #prefix_upper) == prefix_upper
           and fu:match("%.DAT$")
           and not fu:match("^" .. prefix_upper .. "GRAF%.DAT$") then
            names[#names + 1] = f
        end
    end
    table.sort(names)
    return names
end

local function orion_bank_info(data, base)
    if base + 8 > #data then return nil end
    local size = u32le(data, base + 1)
    local off0 = u32le(data, base + 5)
    if off0 == 0 or off0 > size or off0 % 4 ~= 0 then return nil end
    local count = math.floor(off0 / 4)
    if count < 1 or count > 2048 then return nil end
    local prev = 0
    for k = 0, count - 1 do
        local pos = base + 4 + k * 4 + 1
        if pos + 3 > #data then return nil end
        local v = u32le(data, pos)
        if v < prev or v >= size then return nil end
        prev = v
    end
    local name_end = math.min(base + 4 + size + 8, #data)
    for i = base + 4 + size + 1, name_end do
        local b = data:byte(i)
        if b < 32 or b > 126 then return nil end
    end
    local name = data:sub(base + 4 + size + 1, name_end)
    name = name:gsub("%s+$", "")
    return { size = size, count = count, name = name }
end

local function scan_orion_banks(game_path, prefix)
    local key = game_path .. "|" .. prefix
    if orion_cache[key] then return orion_cache[key] end

    local banks = {}
    local graf = read_graf_table(game_path, prefix)
    if graf then
        local files = orion_bank_files(game_path, prefix)
        local groups = graf_groups(graf)
        for gi, group in ipairs(groups) do
            local file = files[gi]
            if file then
                local fh = file_open(game_path .. "/" .. file)
                if fh then
                    local data = file_read(fh, 0, file_size(fh))
                    file_close(fh)
                    if data then
                        for _, base in ipairs(group) do
                            local info = orion_bank_info(data, base)
                            if info then
                                info.file = file
                                info.base = base
                                banks[#banks + 1] = info
                            end
                        end
                    end
                end
            end
        end
    end

    orion_cache[key] = banks
    return banks
end

local function orion_bank_text(game_path, bank)
    local text = {
        string.format("ORION sprite bank: %s", bank.name),
        string.format("File:    %s", bank.file),
        string.format("Offset:  0x%X (%d)", bank.base, bank.base),
        string.format("Sprites: %d", bank.count),
        ""
    }
    local fh = file_open(game_path .. "/" .. bank.file)
    if fh then
        local data = file_read(fh, 0, file_size(fh))
        file_close(fh)
        if data then
            local prev = 0
            for k = 1, bank.count do
                local off = u32le(data, bank.base + 4 + (k - 1) * 4 + 1)
                -- Fall back to bank-end if this is the last sprite
                local next_off = bank.size
                if k < bank.count then
                    next_off = u32le(data, bank.base + 4 + k * 4 + 1)
                end
                text[#text + 1] = string.format("  #%d offset 0x%X (%d bytes)", k - 1, off, next_off - off)
                prev = off
            end
        end
    end
    return table.concat(text, "\n")
end

local function orion_archive_index(game_path)
    local path = resolve_file(game_path, "ORION.RNC")
    if not path then return nil end
    local fh = file_open(path)
    if not fh then return nil end
    local data = file_read(fh, 0, math.min(300000, file_size(fh)))
    file_close(fh)
    if not data then return nil end

    local names = {}
    local entry_pat = "[A-Z][A-Z0-9_]*%.[A-Z0-9][A-Z0-9][A-Z0-9]%z"
    local pos = 1
    while #names < 300 do
        local s, e = data:find(entry_pat, pos)
        if not s or s > 260000 then break end
        names[#names + 1] = data:sub(s, e - 1)
        pos = e + 1
    end
    if #names == 0 then return nil end
    return table.concat(names, "\n")
end

local function get_sprite_banks(game_path, prefix)
    local key = game_path .. "|" .. prefix
    if bank_cache[key] then return bank_cache[key] end
    bank_cache[key] = {}

    local prefix_upper = prefix:upper()
    local is_gene = (prefix_upper == "VIC_")

    local main_path = game_path .. "/" .. prefix .. "MAIN.DAT"
    if not file_exists(main_path) then return {} end
    local fh = file_open(main_path)
    if not fh then return {} end
    local raw = file_read(fh, 0, file_size(fh))
    file_close(fh)
    if not raw then return {} end

    local d, len = descramble_main(raw)
    if not d then return {} end
    local footer = len + 1
    local function F(o) return u16le(raw, footer + o) end

    local sprite_count     = F(0x18)
    local sprite_map       = F(0x1a)
    local image_directory  = F(0x1e)
    local graphic_count    = F(0x20)
    local graphic_names    = F(0x22)

    local files
    if is_gene then
        files = build_names_gene(d, graphic_names, graphic_count)
    else
        files = build_names_gbg(d, graphic_names, graphic_count)
    end

    local graf = read_graf_table(game_path, prefix)
    if not graf then return {} end

    -- Group the sprite map records by source image.
    local groups = {}
    local order = {}
    if is_gene then
        -- GENE: 9-byte records - image u16, index u8, width u16, height u16, hot u8,u8
        for i = 0, sprite_count - 1 do
            local b = sprite_map + i * 9 + 1
            if b + 8 > #d then break end
            local image = u16le(d, b)
            local idx   = d:byte(b + 2)
            local w     = u16le(d, b + 3)
            local h     = u16le(d, b + 5)
            local group = groups[image]
            if not group then group = {}; groups[image] = group; order[#order + 1] = image end
            group[#group + 1] = { index = idx, width = w, height = h }
        end
    else
        -- GBG: 10-byte records - image u16, index u16, width u16, height u16, extra u16
        for i = 0, sprite_count - 1 do
            local b = sprite_map + i * 10 + 1
            if b + 9 > #d then break end
            local image = u16le(d, b)
            local idx   = u16le(d, b + 2)
            local w     = u16le(d, b + 4)
            local h     = u16le(d, b + 6)
            local group = groups[image]
            if not group then group = {}; groups[image] = group; order[#order + 1] = image end
            group[#group + 1] = { index = idx, width = w, height = h }
        end
    end

    -- GENE images are addressed by (file, offset) through the grouped GRAF.
    local image_file, image_off = {}, {}
    if is_gene then
        local ggroups = graf_groups(graf)
        local im = 0
        for fi, grp in ipairs(ggroups) do
            for _, off in ipairs(grp) do
                im = im + 1
                image_file[im] = fi - 1
                image_off[im] = off
            end
        end
    end

    table.sort(order)

    local banks = {}
    for _, image in ipairs(order) do
        if image >= 1 then
            local fi, base, encoding
            if is_gene then
                fi = image_file[image]
                base = image_off[image]
                encoding = "rle"
            else
                fi = u16le(d, image_directory + (image - 1) * 4 + 3)
                base = graf_offset(graf, image)
                encoding = "raw"
            end
            local fname = files[fi + 1]
            local path = resolve_file(game_path, fname)
            if not path and fname then
                local num = fname:match("(%d%d%d)")
                if num then path = resolve_file(game_path, prefix .. num .. ".DAT") end
            end
            if base and path then
                local bf = file_open(path)
                if bf then
                    local bdata = file_read(bf, 0, file_size(bf))
                    file_close(bf)
                    if bdata and base + 8 <= #bdata then
                        local count = #groups[image]
                        local off0 = u32le(bdata, base + 4 + 1)
                        if off0 == count * 4 then
                            local size = u32le(bdata, base + 1)
                            local name = bdata:sub(base + 4 + size + 1, base + 4 + size + 8)
                            name = name:gsub("%z", ""):gsub("%s+$", "")
                            if name == "" then name = "bank" .. image end

                            local offsets = {}
                            local valid = true
                            for k = 0, count - 1 do
                                local oo = u32le(bdata, base + 4 + k * 4 + 1)
                                offsets[k] = oo
                                if encoding == "raw" then
                                    local sz = groups[image][k + 1].width * groups[image][k + 1].height
                                    if oo + sz > size then valid = false end
                                end
                            end
                            if valid then
                                banks[image] = {
                                    image    = image,
                                    file     = path,
                                    base     = base,
                                    name     = name,
                                    sprites  = groups[image],
                                    offsets  = offsets,
                                    encoding = encoding
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    bank_cache[key] = banks
    return banks
end

-- ============================================================================
-- Scan for overlays in numbered DAT files using GRAF offsets (IUC only)
-- ============================================================================

local function scan_overlays(game_path, prefix, graf_groups)
    if not graf_groups then return {} end

    local prefix_upper = prefix:upper()
    local files = list_files(game_path)
    if not files then return {} end

    -- Build mapping from scene index to numbered file
    local numbered_files = {}
    for _, f in ipairs(files) do
        local fu = f:upper()
        local num = fu:match("^" .. prefix_upper .. "(%d%d%d)%.DAT$")
        if num then
            numbered_files[tonumber(num)] = f
        end
    end

    local overlays_by_scene = {}

    for gi, group in ipairs(graf_groups) do
        -- Scene index mapping depends on game
        local scene_idx
        if prefix_upper == "IUC_" then
            scene_idx = gi  -- IUC groups 1-15 map to files 001-015
        else
            scene_idx = gi - 1  -- Other games: group 0-based maps to file 000-based
        end

        local dat_file = numbered_files[scene_idx]
        if dat_file then
            local path = game_path .. "/" .. dat_file
            local fh = file_open(path)
            if fh then
                -- Check each offset for valid sub-images
                local overlay_list = {}
                for oi, offset in ipairs(group) do
                    local hdr = file_read(fh, offset, 4)
                    if hdr and #hdr >= 4 then
                        local w = u16le(hdr, 1)
                        local h = u16le(hdr, 3)
                        if w >= 1 and w <= 2000 and h >= 1 and h <= 1200 then
                            overlay_list[#overlay_list + 1] = {
                                dat_file = dat_file,
                                offset   = offset,
                                index    = oi - 1,
                                width    = w,
                                height   = h
                            }
                        end
                    end
                end
                file_close(fh)

                if #overlay_list > 0 then
                    local scene_label = string.format("%03d", scene_idx)
                    overlays_by_scene[scene_label] = overlay_list
                end
            end
        end
    end

    return overlays_by_scene
end

-- ============================================================================
-- Resource tree
-- ============================================================================

-- ============================================================================
-- Sound, music and text
-- ============================================================================
-- Sound files (`*_Snn.DAT`, GENE's `VIC_S99/S999` and `VIC_VBn/VSn` speech)
-- are back-to-back RIFF WAVE files (GENE), Creative VOC files (GUILTY, ORION)
-- or bare VOC block chains with a zero terminator after each clip (IUC).
-- `*_Ann.DAT` files are XMIDI (FORM XDIR + CAT XMID); IUC's hold AdLib
-- instruments instead and are not listed.
-- `*_PROG.*` and `*_MAIN.*` are XOR 0x6F; dialogue strings sit inside the
-- script bytecode as zero-terminated CP437 text, 0x0F separating lines.

local cp437 = require("cp437").to_utf8
local VOC_HEADER = "Creative Voice File\26\26\0\10\1\41\17"

local function read_all(path)
    local fh = file_open(path)
    if not fh then return nil end
    local data = file_read(fh, 0, file_size(fh)) or ""
    file_close(fh)
    return data
end

local function read_at(path, offset, len)
    local fh = file_open(path)
    if not fh then return nil end
    local data = file_read(fh, offset, len)
    file_close(fh)
    return data
end

-- Returns { kind, offset, size } clips; kind is "wav", "voc" or "raw".
local function sound_clips(path)
    local fh = file_open(path)
    if not fh then return {} end
    local size = file_size(fh)
    local head = file_read(fh, 0, 20) or ""
    local clips = {}
    if head:sub(1, 4) == "RIFF" then
        local pos = 0
        while pos + 8 <= size do
            local h = file_read(fh, pos, 8)
            if not h or h:sub(1, 4) ~= "RIFF" then break end
            local len = u32le(h, 5) + 8
            clips[#clips + 1] = { kind = "wav", offset = pos, size = math.min(len, size - pos) }
            pos = pos + len
        end
    elseif head:sub(1, 19) == "Creative Voice File" then
        local data = file_read(fh, 0, size)
        local starts, pos = {}, 1
        while true do
            local i = data:find("Creative Voice File", pos, true)
            if not i then break end
            starts[#starts + 1] = i - 1
            pos = i + 19
        end
        for i, start in ipairs(starts) do
            clips[#clips + 1] = { kind = "voc", offset = start, size = (starts[i + 1] or size) - start }
        end
    elseif head:byte(1) == 1 then
        local pos, start = 0, 0
        while pos < size do
            local h = file_read(fh, pos, 4)
            if not h then break end
            local t = h:byte(1)
            if t == 0 then
                clips[#clips + 1] = { kind = "raw", offset = start, size = pos + 1 - start }
                pos = pos + 1
                start = pos
            elseif t <= 9 and #h == 4 then
                pos = pos + 4 + h:byte(2) + h:byte(3) * 256 + h:byte(4) * 65536
            else
                break
            end
        end
    end
    file_close(fh)
    return clips
end

local function is_sound_file(name)
    local u = name:upper()
    return u:match("^%u%u%u_S%d+%.DAT$") or u:match("^%u%u%u_V[BS]%d+%.DAT$")
end

local function is_text_file(name)
    local u = name:upper()
    return u:match("^%u%u%u_PROG%.%u+$") or u:match("^%u%u%u_MAIN%.%u+$")
end

local function dialogue_strings(data)
    local key = {}
    for i = 0, 255 do key[i] = string.char(bit32.bxor(i, 0x6F)) end
    data = data:gsub(".", function(c) return key[c:byte()] end)
    local out = {}
    for s in data:gmatch("([\32-\126\128-\168\15][\32-\126\128-\168\15][\32-\126\128-\168\15]+)%z") do
        local letters = select(2, s:gsub("[A-Za-z\128-\168]", ""))
        if letters * 10 >= #s * 6 and s:find("[a-z\128-\168][a-z\128-\168]")
            and not s:find("[%[%]\\%^_{|}~]") and not s:lower():find("%.dat$") then
            out[#out + 1] = cp437((s:gsub("\15", " / ")))
        end
    end
    return out
end

local function sorted_files(game_path, pred)
    local out = {}
    for _, f in ipairs(list_files(game_path) or {}) do
        if pred(f) then out[#out + 1] = f end
    end
    table.sort(out, function(a, b)
        local pa, na = a:upper():match("^(.-)(%d+)%.")
        local pb, nb = b:upper():match("^(.-)(%d+)%.")
        if pa and pb and pa == pb then return tonumber(na) < tonumber(nb) end
        return a:upper() < b:upper()
    end)
    return out
end

local function extra_resources(game_path)
    local cats = {}

    local sound_groups, total = {}, 0
    for _, f in ipairs(sorted_files(game_path, is_sound_file)) do
        local clips = sound_clips(game_path .. "/" .. f)
        local kids = {}
        for i, c in ipairs(clips) do
            kids[#kids + 1] = {
                id = string.format("ix_%s|%s|%d|%d", c.kind, f, c.offset, c.size),
                name = string.format("%s #%d", f, i), type = "sound",
            }
        end
        if #kids == 1 then
            kids[1].name = f
            sound_groups[#sound_groups + 1] = kids[1]
        elseif #kids > 1 then
            sound_groups[#sound_groups + 1] = { id = "ixs_" .. f, name = string.format("%s (%d)", f, #kids), type = "category", children = kids }
        end
        total = total + #kids
    end
    if total > 0 then
        cats[#cats + 1] = { id = "ix_sounds", name = string.format("Sound (%d)", total), type = "category", children = sound_groups }
    end

    local music = {}
    for _, f in ipairs(sorted_files(game_path, function(n) return n:upper():match("^%u%u%u_A%d+%.DAT$") end)) do
        local data = read_all(game_path .. "/" .. f)
        if data and data:sub(1, 4) == "FORM" then
            local notes = xmi_sequence_notes(data)
            local songs = {}
            for i = 1, #notes do
                if notes[i] > 0 then
                    songs[#songs + 1] = { id = string.format("ix_xmi|%s|%d", f, i - 1), name = string.format("%s sequence %d (%d notes)", f, i - 1, notes[i]), type = "midi" }
                end
            end
            if #songs == 1 then songs[1].name = f end
            for _, s in ipairs(songs) do music[#music + 1] = s end
        end
    end
    if #music > 0 then
        cats[#cats + 1] = { id = "ix_music", name = string.format("Music (%d)", #music), type = "category", children = music }
    end

    local texts = {}
    for _, f in ipairs(sorted_files(game_path, is_text_file)) do
        -- Most MAIN files hold only file names; list the ones with dialogue.
        local n = #dialogue_strings(read_all(game_path .. "/" .. f) or "")
        if n >= 3 then
            texts[#texts + 1] = { id = "ix_text|" .. f, name = string.format("%s (%d strings)", f, n), type = "text" }
        end
    end
    if #texts > 0 then
        cats[#cats + 1] = { id = "ix_texts", name = string.format("Text (%d)", #texts), type = "category", children = texts }
    end
    return cats
end

local function load_extra(game_path, resource_id)
    local kind, rest = resource_id:match("^ix_(%a+)|(.+)$")
    if kind == "text" then
        local data = read_all(game_path .. "/" .. rest)
        if not data then return nil end
        local lines = dialogue_strings(data)
        for i, s in ipairs(lines) do lines[i] = string.format("%4d  %s", i - 1, s) end
        return { type = "text", text = table.concat(lines, "\n"), description = string.format("%s — %d strings", rest, #lines) }
    elseif kind == "xmi" then
        local f, idx = rest:match("^(.+)|(%d+)$")
        local data = read_all(game_path .. "/" .. f)
        local midi = data and midi_create_from_xmi(data, tonumber(idx))
        return midi and { type = "midi", midi = midi, description = string.format("%s sequence %s — XMIDI", f, idx) }
    elseif kind == "wav" or kind == "voc" or kind == "raw" then
        local f, off, len = rest:match("^(.+)|(%d+)|(%d+)$")
        local data = read_at(game_path .. "/" .. f, tonumber(off), tonumber(len))
        if not data then return nil end
        if kind == "raw" then data = VOC_HEADER .. data end
        local snd = sound_create_encoded(data)
        local label = kind == "wav" and "WAV" or "Creative VOC"
        return snd and { type = "sound", sound = snd, description = string.format("%s @%s — %s", f, off, label) }
    end
    return nil
end

function engine.get_resources(game_path)
    local prefix = detect_prefix(game_path)
    if not prefix then return {} end

    local game_name = GAME_NAMES[prefix] or prefix
    local resources = {}

    -- Backgrounds
    local backgrounds
    if prefix:upper() == "GBG_" then
        backgrounds = scan_embedded_backgrounds(game_path, prefix)
    else
        backgrounds = scan_backgrounds(game_path, prefix)
    end
    if #backgrounds > 0 then
        local bg_children = {}
        for _, bg in ipairs(backgrounds) do
            bg_children[#bg_children + 1] = {
                id   = "bg_" .. bg.filename .. (bg.offset and ("@" .. bg.offset) or ""),
                name = bg.label,
                type = "image"
            }
        end
        resources[#resources + 1] = {
            id       = "backgrounds",
            name     = "Backgrounds (" .. #backgrounds .. ")",
            type     = "category",
            children = bg_children
        }
    end

    -- Overlays from GRAF (for games with embedded scene data)
    local graf_groups = parse_graf(game_path, prefix)
    local prefix_upper = prefix:upper()

    if graf_groups and (prefix_upper == "IUC_") then
        local overlays = scan_overlays(game_path, prefix, graf_groups)
        local sorted_scenes = {}
        for scene, _ in pairs(overlays) do
            sorted_scenes[#sorted_scenes + 1] = scene
        end
        table.sort(sorted_scenes)

        if #sorted_scenes > 0 then
            local overlay_children = {}
            for _, scene in ipairs(sorted_scenes) do
                local scene_overlays = overlays[scene]
                local scene_children = {}
                for _, ov in ipairs(scene_overlays) do
                    scene_children[#scene_children + 1] = {
                        id   = "ov_" .. ov.dat_file .. "_" .. ov.index,
                        name = string.format("Overlay %d (%dx%d)", ov.index, ov.width, ov.height),
                        type = "image"
                    }
                end
                overlay_children[#overlay_children + 1] = {
                    id       = "scene_ov_" .. scene,
                    name     = "Scene " .. scene .. " (" .. #scene_overlays .. " overlays)",
                    type     = "category",
                    children = scene_children
                }
            end
            resources[#resources + 1] = {
                id       = "overlays",
                name     = "Scene Overlays (" .. #sorted_scenes .. " scenes)",
                type     = "category",
                children = overlay_children
            }
        end
    end

    -- Sprites (Guilty / GBG and Genesis / GENE sprite banks)
    if prefix_upper == "GBG_" or prefix_upper == "VIC_" then
        local banks = get_sprite_banks(game_path, prefix)
        local bank_ids = {}
        for image, _ in pairs(banks) do bank_ids[#bank_ids + 1] = image end
        table.sort(bank_ids)

        if #bank_ids > 0 then
            local total = 0
            local bank_children = {}
            for _, image in ipairs(bank_ids) do
                local bank = banks[image]
                local spr_children = {}
                for i, sp in ipairs(bank.sprites) do
                    spr_children[#spr_children + 1] = {
                        id   = "spr_" .. image .. "_" .. i,
                        name = string.format("#%d (%dx%d)", sp.index, sp.width, sp.height),
                        type = "image"
                    }
                end
                total = total + #bank.sprites
                bank_children[#bank_children + 1] = {
                    id       = "sprbank_" .. image,
                    name     = string.format("%s (%d)", bank.name, #bank.sprites),
                    type     = "category",
                    children = spr_children
                }
            end
            resources[#resources + 1] = {
                id       = "sprites",
                name     = "Sprites (" .. total .. ")",
                type     = "category",
                children = bank_children
            }
        end
    end

    -- ORION: no MAIN file, so sprite banks are exposed as info resources.
    if prefix_upper == "CER_" then
        local banks = scan_orion_banks(game_path, prefix)
        if #banks > 0 then
            local by_file = {}
            local file_order = {}
            for _, b in ipairs(banks) do
                if not by_file[b.file] then
                    by_file[b.file] = {}
                    file_order[#file_order + 1] = b.file
                end
            end
            table.sort(file_order)

            local total = 0
            local bank_children = {}
            for _, f in ipairs(file_order) do
                local bank_list = by_file[f]
                for _, b in ipairs(banks) do
                    if b.file == f then bank_list[#bank_list + 1] = b end
                end
                local file_children = {}
                for _, b in ipairs(bank_list) do
                    file_children[#file_children + 1] = {
                        id   = "obank_" .. f .. "_" .. b.base,
                        name = string.format("%s (%d sprites)", b.name, b.count),
                        type = "text"
                    }
                    total = total + b.count
                end
                bank_children[#bank_children + 1] = {
                    id       = "obanks_" .. f,
                    name     = string.format("%s (%d banks)", f, #bank_list),
                    type     = "category",
                    children = file_children
                }
            end
            resources[#resources + 1] = {
                id       = "sprites_orion",
                name     = "Sprite Banks (" .. total .. " sprites)",
                type     = "category",
                children = bank_children
            }
        end

        local archive_text = orion_archive_index(game_path)
        if archive_text then
            resources[#resources + 1] = {
                id       = "orion_archive",
                name     = "Game Archive (ORION.RNC)",
                type     = "category",
                children = {
                    {
                        id   = "oarch",
                        name = "Archive Index",
                        type = "text"
                    }
                }
            }
        end
    end

    for _, cat in ipairs(extra_resources(game_path)) do
        resources[#resources + 1] = cat
    end

    return resources
end

-- ============================================================================
-- Resource loader
-- ============================================================================

function engine.load_resource(game_path, resource_id, palette_id)
    if resource_id:match("^ix_") then return load_extra(game_path, resource_id) end

    local prefix = detect_prefix(game_path)
    if not prefix then return nil end

    -- Background image
    local bg_filename = resource_id:match("^bg_(.+)$")
    if bg_filename then
        local bg_offset = 0
        local name, off = bg_filename:match("^(.-)@(%d+)$")
        if name then
            bg_filename = name
            bg_offset = tonumber(off)
        end

        local path = game_path .. "/" .. bg_filename
        local fh = file_open(path)
        if not fh then return nil end
        local sz = file_size(fh)
        local data = file_read(fh, 0, sz)
        file_close(fh)

        local bg
        if bg_offset > 0 then
            bg = decode_subimage(data, bg_offset, nil)
        else
            bg = decode_background(data)
        end
        if not bg then return nil end

        local img = image_create_indexed(bg.width, bg.height, bg.pixels, bg.palette)
        local scene = bg_filename:match("(%d%d%d)")  or bg_filename:match("_(F%d%d)") or bg_filename
        return {
            type        = "image",
            image       = img,
            description = string.format("Scene %s%s (%dx%d)", scene,
                bg_offset > 0 and (" @" .. bg_offset) or "", bg.width, bg.height)
        }
    end

    -- Overlay image
    local ov_file, ov_idx_str = resource_id:match("^ov_(.-)_(%d+)$")
    if ov_file and ov_idx_str then
        local ov_idx = tonumber(ov_idx_str)
        local graf_groups = parse_graf(game_path, prefix)
        if not graf_groups then return nil end

        -- Determine scene idx from filename
        local prefix_upper = prefix:upper()
        local num_str = ov_file:upper():match("^" .. prefix_upper .. "(%d%d%d)%.DAT$")
        if not num_str then return nil end
        local scene_idx = tonumber(num_str)

        -- Find the matching GRAF group
        local group_idx
        if prefix_upper == "IUC_" then
            group_idx = scene_idx  -- groups are 1-indexed for IUC
        else
            group_idx = scene_idx + 1
        end

        if group_idx < 1 or group_idx > #graf_groups then return nil end
        local group = graf_groups[group_idx]
        if ov_idx + 1 > #group then return nil end
        local offset = group[ov_idx + 1]

        -- Read the file data to get the palette from the background image
        local path = game_path .. "/" .. ov_file
        local fh = file_open(path)
        if not fh then return nil end
        local sz = file_size(fh)
        local data = file_read(fh, 0, sz)
        file_close(fh)

        -- Get palette from the background (offset 0) if it has valid dims
        local bg_palette = nil
        if #data >= 4 then
            local bw = u16le(data, 1)
            local bh = u16le(data, 3)
            if bw >= 16 and bw <= 2000 and bh >= 16 and bh <= 1200 then
                local _, bg_end = decode_rle(data, 5, bw * bh)
                bg_palette = read_palette_from_data(data, bg_end)
            end
        end
        if not bg_palette then
            bg_palette = read_palette_from_data(data, nil)
        end

        local sub = decode_subimage(data, offset, bg_palette)
        if not sub then return nil end

        local img = image_create_indexed(sub.width, sub.height, sub.pixels, sub.palette)
        return {
            type        = "image",
            image       = img,
            description = string.format("Overlay %d in %s (%dx%d)", ov_idx, ov_file, sub.width, sub.height)
        }
    end

    -- Sprite from a Guilty (GBG) sprite bank
    local spr_image, spr_index = resource_id:match("^spr_(%d+)_(%d+)$")
    if spr_image then
        local banks = get_sprite_banks(game_path, prefix)
        local bank = banks[tonumber(spr_image)]
        if not bank then return nil end

        local i = tonumber(spr_index)
        local sp = bank.sprites[i]
        local off = bank.offsets[i - 1]
        if not sp or not off then return nil end

        local fh = file_open(bank.file)
        if not fh then return nil end
        local bdata = file_read(fh, 0, file_size(fh))
        file_close(fh)
        if not bdata then return nil end

        local w, h = sp.width, sp.height
        if w <= 0 or h <= 0 then return nil end
        local start = bank.base + 4 + off + 1

        local pixels
        if bank.encoding == "rle" then
            pixels = decode_rle(bdata, start, w * h)
        else
            if start + w * h - 1 > #bdata then return nil end
            pixels = {}
            for k = 0, w * h - 1 do
                pixels[k + 1] = bdata:byte(start + k)
            end
        end

        local palette = find_file_palette(bdata) or grayscale_palette()
        if bank.encoding == "rle" then
            palette = gene_default_palette(game_path) or find_file_palette(bdata) or grayscale_palette()
        end
        local img = image_create_indexed(w, h, pixels, palette)
        return {
            type        = "image",
            image       = img,
            description = string.format("%s #%d (%dx%d)", bank.name, sp.index, w, h)
        }
    end

    -- ORION: sprite bank info resource (from the zero-grouped CER_GRAF.DAT)
    local ob_file, ob_base = resource_id:match("^obank_(.-)_(%d+)$")
    if ob_file and ob_base then
        local banks = scan_orion_banks(game_path, prefix)
        local base = tonumber(ob_base)
        local bank
        for _, b in ipairs(banks) do
            if b.file == ob_file and b.base == base then bank = b break end
        end
        if not bank then return nil end
        return {
            type        = "text",
            description = string.format("ORION sprite bank %s in %s", bank.name, bank.file),
            text        = orion_bank_text(game_path, bank)
        }
    end

    -- ORION: package archive index (ORION.RNC, a Pro-Pack archive)
    if resource_id == "oarch" then
        local archive_text = orion_archive_index(game_path)
        if not archive_text then return nil end
        local count = 0
        for line in archive_text:gmatch("[^\n]+") do count = count + 1 end
        return {
            type        = "text",
            description = "ORION.RNC contents (" .. count .. " files)",
            text        = archive_text
        }
    end

    return nil
end

return engine

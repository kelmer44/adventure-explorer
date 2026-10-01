-- ============================================================================
-- Adventure Explorer - Engine Script: Prisoner of Ice
-- ============================================================================
-- Infogrames / Tom Mix Software, 1995. DOS.
--
-- Asset containers are Burp archives (Infogrames' own packer):
--   "Burp" | u32le entry_count | entry_count * 20-byte entries
--   entry = u32le dec_size, u32le comp_size, u32le reserved,
--           u32le file_offset, u32le flags
--   flags bit 2 (value 4) => payload is a raw DEFLATE stream,
--   otherwise the payload is stored verbatim.
--
-- Verified content of the retail archives:
--   KVGA.KRO    1335 entries: 748 scene scripts, 130 indexed images,
--               126 256-colour palettes, 160 "dummy" stubs, 171 misc
--   KSVGA.KRO   1338 entries: 748 scene scripts, 122 indexed images,
--               126 256-colour palettes, 175 "dummy" stubs, 167 misc
--   S_KLANG.KRO  722 entries: 603 RIFF/WAVE, 43 "EDITLS" + RIFF/WAVE,
--               67 dialogue tables, 9 empty
--   KSOUND.KRO  353 entries: 307 RIFF/WAVE, 46 "HMIMIDIP0131" Miles MIDI
--
-- Indexed image: u16le width, u16le height, then width*height palette indices.
-- Palette:       768 bytes, 256 RGB triplets.
-- Scene script:  24-byte header
--                  [0] u32le 24                 (header size)
--                  [4] u32le record table end
--                  [8] u32le pixel data start
--                 [12] u32le 0
--                 [16] u32le palette offset (0 = none, else len-768)
--                 [20] u32le total size
--                followed by an undocumented record/opcode stream, so scenes
--                are reported as metadata only.
--
-- Dialogue table: no count field. Records start at byte 0 with an 11-byte
--                stride: name[7] NUL padded, u16le absolute string offset,
--                u16le padding. A string offset points at 4 metadata bytes,
--                a control byte (1..10) and a NUL terminated CP850 string.
--
-- Not yet decoded: the scene opcode stream, the Miles MIDI payloads,
-- S_VIDEO/*.MUX and __ICE__.PAR.
-- ============================================================================

local engine = {}
engine.name        = "Prisoner of Ice"
engine.id          = "ice"
engine.description = "Prisoner of Ice (Infogrames, 1995)"
engine.version     = "2.0"

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

local function hex(v)
    return string.format("%X", v)
end

-- ============================================================================
-- CP850 high range (0x80..0xFF). 0xAD is used by the game as a line break.
-- ============================================================================
local CP850_HIGH = {
    "Ç", "ü", "é", "â", "ä", "à", "å", "ç",
    "ê", "ë", "è", "ï", "î", "ì", "Ä", "Å",
    "É", "æ", "Æ", "ô", "ö", "ò", "û", "ù",
    "ÿ", "Ö", "Ü", "ø", "£", "Ø", "×", "ƒ",
    "á", "í", "ó", "ú", "ñ", "Ñ", "ª", "º",
    "¿", "®", "¬", "½", "¼", "\n", "«", "»",
    "░", "▒", "▓", "│", "┤", "Á", "Â", "À",
    "©", "╣", "║", "╗", "╝", "¢", "¥", "┐",
    "└", "┴", "┬", "├", "─", "┼", "ã", "Ã",
    "╚", "╔", "╩", "╦", "╠", "═", "╬", "¤",
    "ð", "Ð", "Ê", "Ë", "È", "ı", "Í", "Î",
    "Ï", "┘", "┌", "█", "▄", "¦", "Ì", "▀",
    "Ó", "ß", "Ô", "Ò", "õ", "Õ", "µ", "þ",
    "Þ", "Ú", "Û", "Ù", "ý", "Ý", "¯", "´",
    "­", "±", "‗", "¾", "¶", "§", "÷", "¸",
    "°", "¨", "·", "¹", "³", "²", "■", " ",
}

local function decode_cp850(s)
    local out = {}
    for i = 1, #s do
        local c = s:byte(i)
        out[#out + 1] = (c < 128) and string.char(c) or CP850_HIGH[c - 127]
    end
    return table.concat(out)
end

-- ============================================================================
-- Burp archive access
-- ============================================================================
local dir_cache = {}

local function burp_dir(file_path)
    local cached = dir_cache[file_path]
    if cached then return cached end
    local fh = file_open(file_path)
    if not fh then return nil end
    local head = file_read(fh, 0, 8)
    if not head or head:sub(1, 4) ~= "Burp" then
        file_close(fh)
        return nil
    end
    local count = u32le(head, 5)
    local raw = file_read(fh, 8, count * 20)
    file_close(fh)
    if not raw then return nil end
    local entries = {}
    for i = 1, count do
        local b = (i - 1) * 20
        entries[i] = {
            dec_size  = u32le(raw, b + 1),
            comp_size = u32le(raw, b + 5),
            offset    = u32le(raw, b + 13),
            flags     = u32le(raw, b + 17),
            compressed = math.floor(u32le(raw, b + 17) / 4) % 2 == 1,
        }
    end
    dir_cache[file_path] = entries
    return entries
end

local function burp_raw(file_path, entry, want)
    if not entry then return nil end
    local len = entry.comp_size
    if want and want < len then len = want end
    if len <= 0 then return "" end
    local fh = file_open(file_path)
    if not fh then return nil end
    local raw = file_read(fh, entry.offset, len)
    file_close(fh)
    return raw
end

-- Full decompressed entry.
local function burp_read(file_path, entry)
    local raw = burp_raw(file_path, entry)
    if not raw then return nil end
    if entry.compressed then
        local dec = zlib_decompress(raw, entry.dec_size)
        if dec then return dec end
    end
    return raw
end

-- Decompressed prefix - enough to classify without unpacking the whole blob.
local function burp_prefix(file_path, entry, want)
    if entry.dec_size <= want then
        return burp_read(file_path, entry)
    end
    local raw = burp_raw(file_path, entry, want * 16)
    if not raw then return nil end
    if entry.compressed then
        local dec = zlib_decompress(raw, want)
        if dec and #dec >= want then return dec end
        -- Fall back to a complete read when a short prefix could not be produced.
        return burp_read(file_path, entry)
    end
    return raw:sub(1, want)
end

-- ============================================================================
-- Classification
-- ============================================================================
local PREFIX = 1024

local function printable_name(s)
    if #s < 1 then return false end
    for i = 1, #s do
        local c = s:byte(i)
        if not ((c >= 32 and c < 127) or c == 0) then return false end
    end
    return s:byte(1) ~= 0
end

-- Candidate dialogue name records at the head of a blob.
local function text_records(pfx, count)
    local offs, k = {}, 0
    while 11 * k + 9 <= #pfx do
        if not printable_name(pfx:sub(11 * k + 1, 11 * k + 7)) then break end
        offs[k + 1] = u16le(pfx, 11 * k + 8)
        k = k + 1
    end
    if k < 2 then return nil end
    local good = 0
    for i = 1, k do
        local o = offs[i]
        if o and o > 0 and o < count then good = good + 1 end
    end
    if good >= 1 and good * 2 >= k then return offs, k end
    return nil
end

local function classify(pfx, dec_size)
    if dec_size == 0 then return "empty" end
    if #pfx >= 12 and pfx:sub(1, 4) == "RIFF" and pfx:sub(9, 12) == "WAVE" then
        return "sound"
    end
    if #pfx >= 28 and pfx:sub(1, 6) == "EDITLS" and pfx:sub(25, 28) == "RIFF" then
        return "sound"
    end
    if pfx:sub(1, 4) == "HMIM" then return "music" end
    if #pfx >= 24 then
        if u32le(pfx, 1) == 24 and u32le(pfx, 21) == dec_size then return "scene" end
    end
    if dec_size == 768 then return "palette" end
    if #pfx >= 4 then
        local w, h = u16le(pfx, 1), u16le(pfx, 3)
        if w > 0 and h > 0 and w <= 1024 and h <= 1024 and w * h + 4 == dec_size then
            return "image"
        end
    end
    if text_records(pfx, dec_size) then return "text" end
    return "other"
end

-- Kind for every entry of an archive, computed once per file.
local kind_cache = {}

local function burp_kinds(game_path, fname)
    local key = game_path .. "/" .. fname
    local cached = kind_cache[key]
    if cached then return cached end
    local entries = burp_dir(key)
    if not entries then return nil end
    local kinds, meta = {}, {}
    for i = 1, #entries do
        local e = entries[i]
        local pfx = burp_prefix(key, e, PREFIX) or ""
        local kind = classify(pfx, e.dec_size)
        kinds[i] = kind
        if kind == "image" then
            meta[i] = { w = u16le(pfx, 1), h = u16le(pfx, 3) }
        end
    end
    kind_cache[key] = { kinds = kinds, meta = meta, count = #entries }
    return kind_cache[key]
end

-- ============================================================================
-- Decoders
-- ============================================================================
local function read_palette(data)
    local pal = {}
    for i = 1, 768 do pal[i] = data:byte(i) or 0 end
    return pal
end

local function grayscale_palette()
    local pal = {}
    for i = 0, 255 do
        pal[i * 3 + 1] = i
        pal[i * 3 + 2] = i
        pal[i * 3 + 3] = i
    end
    return pal
end

local function palette_swatch(pal)
    local cell, grid = 16, 16
    local size = cell * grid
    local rgb = {}
    local n = 0
    for py = 0, size - 1 do
        for px = 0, size - 1 do
            local ci = math.floor(py / cell) * grid + math.floor(px / cell)
            n = n + 1; rgb[n] = pal[ci * 3 + 1]
            n = n + 1; rgb[n] = pal[ci * 3 + 2]
            n = n + 1; rgb[n] = pal[ci * 3 + 3]
        end
    end
    return image_create_rgb(size, size, rgb)
end

local function decode_indexed(data)
    local w, h = u16le(data, 1), u16le(data, 3)
    local total = w * h
    local pixels = {}
    for i = 1, total do
        local c = data:byte(i + 4)
        pixels[i] = c or 0
    end
    return w, h, pixels
end

-- Collect the strings that belong to one record. Strings live in a string pool
-- as "<control:u8><NUL terminated text>" blocks; long text is split over
-- several blocks, and a block with no control byte continues the previous one.
-- A record offset points a few metadata bytes before the first block, so scan a
-- short window for the start. `limit` is the next record offset, which stops a
-- record from swallowing its neighbour.
local function text_runs(data, off, limit)
    if not off or off <= 0 or off + 1 >= #data then return nil end
    local function starts_block(p)
        if p + 1 > #data then return false end
        local ctrl = data:byte(p + 1)
        return ctrl ~= nil and ctrl >= 1 and ctrl <= 10 and data:byte(p + 2) >= 32
    end
    local p
    for j = 0, 15 do
        if off + j + 2 > #data then break end
        if starts_block(off + j) then p = off + j break end
    end
    if not p then return nil end
    local runs, ctrl = {}, nil
    while p < limit and p + 1 <= #data do
        local q
        if starts_block(p) then
            ctrl = data:byte(p + 1)
            q = p + 1
        elseif ctrl and data:byte(p + 1) >= 32 then
            q = p
        else
            break
        end
        local body = data:sub(q + 1)
        local z = body:find("\0", 1, true)
        if not z then break end
        runs[#runs + 1] = { ctrl = ctrl, text = decode_cp850(body:sub(1, z - 1)) }
        p = q + z
    end
    if #runs == 0 then return nil end
    return runs
end

local function dialogue_lines(data)
    local offs, k = text_records(data, #data)
    local lines, shown = {}, 0
    if not offs then return lines, shown, 0 end
    local sorted = {}
    for i = 1, k do
        if offs[i] and offs[i] > 0 then sorted[#sorted + 1] = offs[i] end
    end
    table.sort(sorted)
    for i = 1, k do
        local off = offs[i]
        if not off or off <= 0 then goto continue end
        local limit = #data
        for j = 1, #sorted do
            if sorted[j] > off then limit = sorted[j] break end
        end
        do
            local runs = text_runs(data, off, limit)
            if not runs then goto continue end
            shown = shown + #runs
            local name = data:sub(11 * (i - 1) + 1, 11 * (i - 1) + 7):gsub("%z.*", "")
            local first = true
            for _, run in ipairs(runs) do
                if first then
                    lines[#lines + 1] = string.format("%-8s [%d] %s", name, run.ctrl, run.text)
                    first = false
                else
                    lines[#lines + 1] = string.format("%-8s [%d] %s", "", run.ctrl, run.text)
                end
            end
        end
        ::continue::
    end
    return lines, shown, k
end

-- Tolerant RIFF reader. Some EDITLS entries carry instrument data past the
-- last real chunk, so stop as soon as a chunk id is not four letters/space.
local function read_wav(data)
    local base = 0
    if data:sub(1, 6) == "EDITLS" then base = 24 end
    if data:sub(base + 1, base + 4) ~= "RIFF" then return nil end
    local fmt, doff, dlen
    -- Byte 1..4 "RIFF", 5..8 chunk size, 9..12 "WAVE"; chunks start at 13.
    local p = base + 13
    while p + 8 <= #data do
        local id = data:sub(p, p + 3)
        local sz = u32le(data, p + 4)
        local valid = true
        for j = 1, 4 do
            local c = id:byte(j)
            if not (c == 32 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)) then
                valid = false
                break
            end
        end
        -- Last payload byte of the chunk sits at p + 8 + sz - 1 (1-based).
        if not valid or p + 7 + sz > #data then break end
        if id == "fmt " and sz >= 16 then
            fmt = {
                format   = u16le(data, p + 8),
                channels = u16le(data, p + 10),
                rate     = u32le(data, p + 12),
                bits     = u16le(data, p + 22),
            }
        elseif id == "data" then
            doff, dlen = p + 8, sz
        end
        p = p + 8 + sz + (sz % 2)
    end
    if not fmt or not doff or fmt.format ~= 1 or fmt.bits ~= 8 and fmt.bits ~= 16 then
        return nil
    end
    return fmt, doff, dlen
end

-- ============================================================================
-- Graphics archives
-- ============================================================================
local GRAPHICS = {
    { file = "KVGA.KRO",  label = "KVGA",  res = "kvga" },
    { file = "KSVGA.KRO", label = "KSVGA", res = "ksvga" },
}

local function graphics_categories(game_path)
    local out = {}
    for _, g in ipairs(GRAPHICS) do
        local info = burp_kinds(game_path, g.file)
        if info then
            local imgs, pals, scenes = {}, {}, {}
            for i = 1, info.count do
                local kind = info.kinds[i]
                if kind == "image" then
                    local m = info.meta[i]
                    imgs[#imgs + 1] = i
                elseif kind == "palette" then
                    pals[#pals + 1] = i
                elseif kind == "scene" then
                    scenes[#scenes + 1] = i
                end
            end

            local kids = {}
            for _, i in ipairs(imgs) do
                local m = info.meta[i]
                kids[#kids + 1] = {
                    id = "bg_" .. g.res .. "_" .. i,
                    name = string.format("Image %d (%dx%d)", i, m.w, m.h),
                    type = "image",
                }
                local pk = info.kinds[i + 1]
                if pk == "palette" then
                    kids[#kids + 1] = {
                        id = "pal_" .. g.res .. "_" .. i,
                        name = string.format("Palette %d (for image %d)", i + 1, i),
                        type = "palette",
                    }
                end
            end
            out[#out + 1] = {
                id = "gfx_" .. g.res,
                name = "Graphics (" .. g.label .. ".KRO)",
                type = "category",
                children = kids,
            }

            local skids = {}
            for _, i in ipairs(scenes) do
                skids[#skids + 1] = {
                    id = "scn_" .. g.res .. "_" .. i,
                    name = string.format("Scene %d", i),
                    type = "text",
                }
            end
            out[#out + 1] = {
                id = "scncat_" .. g.res,
                name = "Scene Scripts (" .. g.label .. ".KRO)",
                type = "category",
                children = skids,
            }

            local pkids = {}
            for _, i in ipairs(pals) do
                pkids[#pkids + 1] = {
                    id = "allpal_" .. g.res .. "_" .. i,
                    name = string.format("Palette %d", i),
                    type = "palette",
                }
            end
            out[#out + 1] = {
                id = "palcat_" .. g.res,
                name = "Palettes (" .. g.label .. ".KRO)",
                type = "category",
                children = pkids,
            }
        end
    end
    return out
end

-- ============================================================================
-- Resource dispatcher (declared last, helpers above)
-- ============================================================================
local function load_image(game_path, arch, index, override_pal)
    local path = game_path .. "/" .. arch
    local entries = burp_dir(path)
    if not entries or not entries[index] then return nil end
    local data = burp_read(path, entries[index])
    if not data or #data < 6 then return nil end
    local w, h, pixels = decode_indexed(data)
    local pal
    if override_pal then
        local sibling = override_pal:match("^pal_") ~= nil
        local pi = tonumber(override_pal:match("^%a+_%a+_(%d+)$"))
        if pi and sibling then pi = pi + 1 end
        local pdata = pi and entries[pi] and burp_read(path, entries[pi]) or nil
        pal = (pdata and #pdata >= 768) and read_palette(pdata) or nil
    end
    if not pal then
        local pdata = burp_read(path, entries[index + 1])
        pal = (pdata and #pdata >= 768) and read_palette(pdata) or grayscale_palette()
    end
    local img = image_create_indexed(w, h, pixels, pal)
    return {
        type = "image", image = img, width = w, height = h,
        description = string.format("%s entry %d - %dx%d indexed", arch, index, w, h),
    }
end

-- `index` is the IMAGE entry; the sibling palette always sits at index + 1.
-- Allpal IDs use "allpal_" instead and point straight at the palette entry.
local function load_palette(game_path, arch, index, sibling)
    local path = game_path .. "/" .. arch
    local entries = burp_dir(path)
    local entry_index = sibling and (index + 1) or index
    if not entries or not entries[entry_index] then return nil end
    local data = burp_read(path, entries[entry_index])
    if not data or #data < 768 then return nil end
    local pal = read_palette(data)
    return {
        type = "image", image = palette_swatch(pal), width = 256, height = 256,
        description = string.format("%s entry %d - 256 colour palette", arch, entry_index),
    }
end

local function load_scene(game_path, arch, index)
    local path = game_path .. "/" .. arch
    local entries = burp_dir(path)
    if not entries or not entries[index] then return nil end
    local data = burp_read(path, entries[index])
    if not data or #data < 24 then return nil end
    local table_end = u32le(data, 5)
    local pix_start = u32le(data, 9)
    local pal_off = u32le(data, 17)
    local total = u32le(data, 21)
    local lines = {
        string.format("Scene script %s entry %d", arch, index),
        "",
        string.format("header size      %d", u32le(data, 1)),
        string.format("record table end 0x%s (%d)", hex(table_end), table_end),
        string.format("pixel data start 0x%s (%d)", hex(pix_start), pix_start),
        string.format("palette offset   0x%s", hex(pal_off)),
        string.format("total size       %d", total),
        "",
        "The pixel/opcode stream of this scene format is still undocumented, so",
        "only the header and the palette are decoded here.",
    }
    if pal_off ~= 0 and pal_off + 768 <= #data then
        lines[#lines + 1] = ""
        lines[#lines + 1] = string.format("palette at 0x%s (%d bytes available)",
            hex(pal_off), #data - pal_off)
    end
    return {
        type = "text", text = table.concat(lines, "\n"),
        description = string.format("%s entry %d - scene script, %d bytes", arch, index, total),
    }
end

local function load_text_table(game_path, arch, index)
    local path = game_path .. "/" .. arch
    local entries = burp_dir(path)
    if not entries or not entries[index] then return nil end
    local data = burp_read(path, entries[index])
    if not data then return nil end
    local lines, shown, total = dialogue_lines(data)
    if shown == 0 then return nil end
    return {
        type = "text", text = table.concat(lines, "\n"),
        description = string.format(
            "%s entry %d - dialogue table, %d strings from %d records",
            arch, index, shown, total),
    }
end

local function load_sound(game_path, arch, index)
    local path = game_path .. "/" .. arch
    local entries = burp_dir(path)
    if not entries or not entries[index] then return nil end
    local data = burp_read(path, entries[index])
    if not data then return nil end
    local fmt, doff, dlen = read_wav(data)
    if not fmt then return nil end
    local pcm = data:sub(doff, doff + dlen - 1)
    if #pcm == 0 then return nil end
    local snd = sound_create_pcm(fmt.rate, fmt.bits, fmt.channels, fmt.bits == 16, pcm)
    return {
        type = "sound", sound = snd,
        description = string.format("%s entry %d - %d Hz, %d-bit, %d channel(s)",
            arch, index, fmt.rate, fmt.bits, fmt.channels),
    }
end

local function load_music(game_path, arch, index)
    local path = game_path .. "/" .. arch
    local entries = burp_dir(path)
    if not entries or not entries[index] then return nil end
    local data = burp_read(path, entries[index])
    if not data then return nil end
    local lines = {
        string.format("Music resource %s entry %d", arch, index),
        "",
        string.format("format tag  %s", data:sub(1, 16)),
        string.format("size        %d bytes", #data),
        "",
        "These are Miles HMIMIDIP0131 modules. The patch/instrument stream is",
        "not decoded, so no playable audio can be produced for this resource.",
    }
    return {
        type = "text", text = table.concat(lines, "\n"),
        description = string.format("%s entry %d - Miles MIDI, %d bytes", arch, index, #data),
    }
end

function engine.detect(game_path)
    if file_exists(game_path .. "/ICE320.EXE") or file_exists(game_path .. "/ICE640.EXE") then
        return true
    end
    return (file_exists(game_path .. "/KVGA.KRO") or file_exists(game_path .. "/KSVGA.KRO"))
       and file_exists(game_path .. "/S_KLANG.KRO")
end

function engine.get_resources(game_path)
    local tree = {}

    for _, cat in ipairs(graphics_categories(game_path)) do
        tree[#tree + 1] = cat
    end

    local sounds, texts, music = {}, {}, {}

    local kl = burp_kinds(game_path, "S_KLANG.KRO")
    if kl then
        for i = 1, kl.count do
            local kind = kl.kinds[i]
            if kind == "sound" then
                sounds[#sounds + 1] = {
                    id = "wav_klang_" .. i,
                    name = string.format("Effect %d", i),
                    type = "sound",
                }
            elseif kind == "text" then
                texts[#texts + 1] = {
                    id = "txt_klang_" .. i,
                    name = string.format("Dialogue %d", i),
                    type = "text",
                }
            end
        end
    end

    local ks = burp_kinds(game_path, "KSOUND.KRO")
    if ks then
        for i = 1, ks.count do
            local kind = ks.kinds[i]
            if kind == "sound" then
                sounds[#sounds + 1] = {
                    id = "wav_ksound_" .. i,
                    name = string.format("Effect K%d", i),
                    type = "sound",
                }
            elseif kind == "music" then
                music[#music + 1] = {
                    id = "mus_ksound_" .. i,
                    name = string.format("Music %d", i),
                    type = "text",
                }
            end
        end
    end

    if #sounds > 0 then
        tree[#tree + 1] = {
            id = "cat_sounds", name = "Sound Effects",
            type = "category", children = sounds,
        }
    end
    if #texts > 0 then
        tree[#tree + 1] = {
            id = "cat_text", name = "Dialogue (S_KLANG.KRO)",
            type = "category", children = texts,
        }
    end
    if #music > 0 then
        tree[#tree + 1] = {
            id = "cat_music", name = "Music (KSOUND.KRO)",
            type = "category", children = music,
        }
    end

    return tree
end

function engine.load_resource(game_path, resource_id, palette_id)
    if not resource_id then return nil end
    local kind, res, index = resource_id:match("^(%a+)_(%a+)_(%d+)$")
    if not kind or not res or not index then return nil end
    index = tonumber(index)

    if kind == "bg" then
        local arch = (res == "kvga") and "KVGA.KRO" or "KSVGA.KRO"
        return load_image(game_path, arch, index, palette_id)
    elseif kind == "pal" then
        local arch = (res == "kvga") and "KVGA.KRO" or "KSVGA.KRO"
        return load_palette(game_path, arch, index, true)
    elseif kind == "allpal" then
        local arch = (res == "kvga") and "KVGA.KRO" or "KSVGA.KRO"
        return load_palette(game_path, arch, index, false)
    elseif kind == "scn" then
        local arch = (res == "kvga") and "KVGA.KRO" or "KSVGA.KRO"
        return load_scene(game_path, arch, index)
    elseif kind == "txt" then
        return load_text_table(game_path, "S_KLANG.KRO", index)
    elseif kind == "wav" then
        local arch = (res == "klang") and "S_KLANG.KRO" or "KSOUND.KRO"
        return load_sound(game_path, arch, index)
    elseif kind == "mus" then
        return load_music(game_path, "KSOUND.KRO", index)
    end
    return nil
end

return engine

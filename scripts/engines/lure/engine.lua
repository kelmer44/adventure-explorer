-- ============================================================================
-- Adventure Explorer - Engine Script: Lure of the Temptress (Revolution, 1992)
-- ============================================================================
-- Files: DISK1.VGA..DISK4.VGA (or .EGA)
--
-- Each disk is a raw volume with a fixed header:
--   "heywow"        6-byte ident
--   uint16 BE       disk/file number
--   0xBF (191)      FileEntry records, 8 bytes each:
--       uint16 LE id
--       uint8     unused
--       uint8     sizeExtension  (adds 0x10000 to the size when set)
--       uint16 LE size
--       uint16 LE offset         (units of 0x20 bytes)
--
-- Resource ids encode the disk in their top two bits:
--   id >> 14 : 0 -> disk1, 1 -> disk2, 2 -> disk3, 3 -> disk4
--   (0x3fxx ids live in lure.dat, which is not part of this game data)
--
-- Screens are RLE/bitstream compressed (PictureDecoder::vgaDecode) and decode
-- to a 320x192 playfield (or 320x200 full screen). Each room's palette lives
-- at (screenId & 0xffe0) - 1 as a 660-byte RGB64 (6-bit) resource.
--
-- Validated against ScummVM's engines/lure (disk.cpp, decode.cpp, room.cpp).
-- ============================================================================

local engine = {}
local Extra = require("lure_extra")
engine.name        = "Lure of the Temptress"
engine.id          = "lure"
engine.description = "Lure of the Temptress (Revolution Software, 1992)"
engine.version     = "1.0"

-- ============================================================================
-- Binary helpers
-- ============================================================================

local function u8(s, i) return s:byte(i) or 0 end
local function u16le(s, i)
    local a, b = s:byte(i, i + 1)
    if not a then return 0 end
    return a + (b or 0) * 256
end
local function u16be(s, i)
    local a, b = s:byte(i, i + 1)
    if not a then return 0 end
    return a * 256 + (b or 0)
end
local function u32le(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not a then return 0 end
    return a + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216
end

local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

local NUM_ENTRIES = 0xBF
local HEADER_SIZE = 8 + NUM_ENTRIES * 8   -- "heywow"(6) + fileNum(2) + entries

-- Returns the 1-based disk number (1-4) for a resource id, or 0 for lure.dat.
local function disk_of(id)
    if rshift(id, 8) == 0x3f then return 0 end
    return band(rshift(id, 14), 3) + 1
end

-- ============================================================================
-- Disk loading + entry table
-- ============================================================================

local function read_all(path)
    local fh = file_open(path)
    if not fh then return nil end
    local sz = file_size(fh)
    if not sz or sz <= 0 then file_close(fh); return nil end
    local data = file_read(fh, 0, math.floor(sz))
    file_close(fh)
    return data
end

local function disk_path(game_path, num)
    for _, name in ipairs({ "DISK" .. num .. ".VGA", "disk" .. num .. ".vga",
                            "DISK" .. num .. ".EGA", "disk" .. num .. ".ega" }) do
        local p = game_path .. "/" .. name
        if file_exists(p) then return p end
    end
    return nil
end

-- Parse one disk's header into a map: id -> { size, offset }
local function parse_disk(data)
    if not data or #data < HEADER_SIZE then return nil end
    if data:sub(1, 6) ~= "heywow" then return nil end
    local map = {}
    local count = 0
    for i = 0, NUM_ENTRIES - 1 do
        local base = 9 + i * 8     -- 1-based; header is 8 bytes before entries
        local id = u16le(data, base)
        if id == 0xffff then break end
        local ext = u8(data, base + 3)
        local size = u16le(data, base + 4)
        if ext ~= 0 then size = size + 0x10000 end
        local offset = u16le(data, base + 6) * 0x20
        map[id] = { size = size, offset = offset }
        count = count + 1
    end
    return map
end

local cache = {}

local function build(game_path)
    local cached = cache[game_path]
    if cached then return cached end

    local disks = {}
    local entries = {}          -- id -> { disk, size, offset }
    local raw = {}              -- disk -> string
    for num = 1, 4 do
        local p = disk_path(game_path, num)
        if p then
            local data = read_all(p)
            if data then
                raw[num] = data
                local map = parse_disk(data)
                if map then
                    for id, e in pairs(map) do
                        entries[id] = { disk = num, size = e.size, offset = e.offset }
                    end
                end
            end
        end
    end

    cached = { raw = raw, entries = entries }
    cache[game_path] = cached
    return cached
end

local function get_bytes(ctx, id)
    local e = ctx.entries[id]
    if not e then return nil end
    local data = ctx.raw[e.disk]
    if not data then return nil end
    return data:sub(e.offset + 1, e.offset + e.size)
end

-- ============================================================================
-- PictureDecoder::vgaDecode  (returns pixel table + length, or nil)
-- ============================================================================

local function vga_decode(src)
    local n = #src
    if n < 0x408 then return nil end

    local dataPos = u32le(src, 0x401) + 1   -- stored as 0-based offset, used 1-based
    local dataPos2 = 0x405
    local out = {}
    local olen = 0

    local function DSSI()
        local r = (dataPos <= n) and u8(src, dataPos) or 0
        dataPos = dataPos + 1
        return r
    end
    local function ESBX()
        if dataPos2 > n then error("out of range") end
        local r = u8(src, dataPos2)
        dataPos2 = dataPos2 + 1
        return r
    end

    local CH = ESBX()
    local CL = 9
    local function decrCtr()
        CL = CL - 1
        if CL == 0 then CH = ESBX(); CL = 8 end
    end
    local function shlCarry()
        local r = band(CH, 0x80) ~= 0
        CH = band(lshift(CH, 1), 0xff)
        return r
    end

    local loopFlag = true
    local guard = 0
    while loopFlag do
        local AL = DSSI()
        olen = olen + 1; out[olen] = AL
        local BP = lshift(AL, 2)
        while true do
            guard = guard + 1
            if guard > 4000000 then error("runaway") end
            local cont = false
            decrCtr()
            if shlCarry() then
                decrCtr()
                if shlCarry() then
                    decrCtr()
                    if shlCarry() then break end
                    AL = u8(src, BP + 4)
                else
                    decrCtr()
                    if shlCarry() then AL = u8(src, BP + 3)
                    else AL = u8(src, BP + 2) end
                end
            else
                decrCtr()
                if shlCarry() then
                    AL = rshift(BP, 2)
                    local AH = DSSI()
                    if AH == 0 then
                        AL = DSSI()
                        if AL == 0 then
                            loopFlag = false
                            break
                        else
                            cont = true
                        end
                    else
                        for _ = 1, AH do
                            olen = olen + 1; out[olen] = AL
                        end
                        cont = true
                    end
                else
                    AL = u8(src, BP + 1)
                end
            end
            if not cont then
                olen = olen + 1; out[olen] = AL
                BP = lshift(AL, 2)
            end
        end
    end
    return out, olen
end

-- ============================================================================
-- Palette helpers (RGB64: 6-bit components expanded to 8-bit)
-- ============================================================================

local function palette_from_rgb64(bytes)
    if not bytes or #bytes < 3 then return nil end
    local pal = {}
    local entries = math.floor(#bytes / 3)
    if entries > 256 then entries = 256 end
    for i = 0, entries - 1 do
        local r = u8(bytes, i * 3 + 1)
        local g = u8(bytes, i * 3 + 2)
        local b = u8(bytes, i * 3 + 3)
        pal[i * 3 + 1] = lshift(r, 2) + rshift(r, 4)
        pal[i * 3 + 2] = lshift(g, 2) + rshift(g, 4)
        pal[i * 3 + 3] = lshift(b, 2) + rshift(b, 4)
    end
    for i = entries, 255 do
        pal[i * 3 + 1] = 0; pal[i * 3 + 2] = 0; pal[i * 3 + 3] = 0
    end
    return pal
end

-- Determine the palette resource id for a screen id (with fallbacks).
local function palette_id_for(ctx, id)
    local candidates = { band(id, 0xffe0) - 1, id + 1, id - 1,
                         bor(band(id, 0xff00), 0xff), band(id, 0xff00) }
    for _, pid in ipairs(candidates) do
        if pid >= 0 and pid <= 0xffff then
            local e = ctx.entries[pid]
            if e and e.size == 660 then return pid end
        end
    end
    return nil
end

-- ============================================================================
-- Detection
-- ============================================================================

local function has_disks(game_path)
    return disk_path(game_path, 1) ~= nil
end

function engine.detect(game_path)
    if not has_disks(game_path) then return false end
    -- Make sure a real Lure volume is present
    local p = disk_path(game_path, 1)
    local fh = file_open(p)
    if not fh then return false end
    local sig = file_read(fh, 0, 6)
    file_close(fh)
    return sig == "heywow"
end

-- ============================================================================
-- Resource tree
-- ============================================================================

local function parse_id(resource_id, prefix)
    local h = resource_id and resource_id:match("^" .. prefix .. "(%x+)$")
    return h and tonumber(h, 16) or nil
end

local function hex4(v) return string.format("%04x", v) end

local function classify(ctx)
    local screens, palettes = {}, {}
    local ids = {}
    for id in pairs(ctx.entries) do ids[#ids + 1] = id end
    table.sort(ids)

    for _, id in ipairs(ids) do
        local e = ctx.entries[id]
        if e.size == 660 then
            palettes[#palettes + 1] = id
        elseif e.size >= 0x408 then
            local bytes = get_bytes(ctx, id)
            if bytes and #bytes >= 0x408 then
                local dp = u32le(bytes, 0x401)
                -- Cheap pre-filter: the byte stream offset must point inside the file
                if dp >= 0x408 and dp <= #bytes then
                    local ok, _, olen = pcall(vga_decode, bytes)
                    -- Genuine screens are a 320x192 playfield (61440 bytes); accept the
                    -- 61408 variant and 320x200 full screens (64000/64001), but reject
                    -- animation fragments (e.g. 0x4051 -> 70166).
                    if ok and olen and ((olen >= 61408 and olen <= 61441) or (olen >= 63999 and olen <= 64001)) then
                        screens[#screens + 1] = { id = id, height = math.floor(olen / 320) }
                    end
                end
            end
        end
    end
    return screens, palettes
end

function engine.get_resources(game_path)
    if not engine.detect(game_path) then return {} end
    local ctx = build(game_path)
    local screens, palettes = classify(ctx)
    ctx.screens = screens
    ctx.palettes = palettes

    local screenNodes, paletteNodes = {}, {}
    for _, s in ipairs(screens) do
        screenNodes[#screenNodes + 1] = {
            id = "lure_scr_" .. hex4(s.id),
            name = string.format("Screen %s  (320x%d)", hex4(s.id), s.height),
            type = "file",
        }
    end
    for _, p in ipairs(palettes) do
        paletteNodes[#paletteNodes + 1] = {
            id = "lure_pal_" .. hex4(p),
            name = string.format("Palette %s", hex4(p)),
            type = "file",
        }
    end

    local resources = {}
    if #screenNodes > 0 then
        resources[#resources + 1] = { id = "lure_screens", name = "Screens (" .. #screenNodes .. ")", type = "category", children = screenNodes }
    end
    if #paletteNodes > 0 then
        resources[#resources + 1] = { id = "lure_palettes", name = "Palettes (" .. #paletteNodes .. ")", type = "category", children = paletteNodes }
    end
    for _, node in ipairs(engine.extra_resources(game_path, ctx)) do resources[#resources + 1] = node end
    return resources
end

-- ============================================================================
-- Support file (lure.dat), music and strings
-- ============================================================================

-- ScummVM's lure.dat (dists/engine-data), copied into the game folder: "lure"
-- plus version, then (language, u32 offset) records ending in 0xFF; each block
-- is a volume like the disks, with entry offsets relative to the block.
local function support(game_path, ctx)
    if ctx.support ~= nil then return ctx.support or nil end
    ctx.support = false
    local path
    for _, name in ipairs({ "lure.dat", "LURE.DAT", "Lure.dat" }) do
        if file_exists(game_path .. "/" .. name) then path = game_path .. "/" .. name; break end
    end
    local data = path and read_all(path)
    if not data or data:sub(1, 4) ~= "lure" then return nil end
    local blocks, p = {}, 7
    while p + 4 <= #data and data:byte(p) ~= 0xFF do
        local lang, off = data:byte(p), u32le(data, p + 1)
        local map = parse_disk(data:sub(off + 1))
        if map then blocks[#blocks + 1] = { lang = lang, base = off, map = map } end
        p = p + 5
    end
    local function entry(block, id)
        local e = block.map[id]
        return e and data:sub(block.base + e.offset + 1, block.base + e.offset + e.size)
    end
    -- Pick the block whose string decoder fits this copy's text: every block
    -- decodes the bit stream, but a wrong code table rarely reaches the string
    -- terminator, so its strings run long (Spanish averages 14 characters in the
    -- tested copy, the other tables 33 to 246). Names are left unexpanded here.
    local tables = { [0] = get_bytes(ctx, 0x10), get_bytes(ctx, 0x11), get_bytes(ctx, 0x12) }
    local names = get_bytes(ctx, 9)
    local best, best_ok, best_len = nil, -1, math.huge
    for _, b in ipairs(blocks) do
        local codes = Extra.parse_decoder(entry(b, 0x3F19))
        local ok, len = 0, 0
        if codes then
            for id = 1, 64 do
                local t = Extra.decode(tables, codes, nil, id)
                if t then ok = ok + 1; len = len + #t end
            end
        end
        local avg = ok > 0 and len / ok or math.huge
        if ok > best_ok or (ok == best_ok and avg < best_len) then
            best, best_ok, best_len = { block = b, codes = codes }, ok, avg
        end
    end
    if best and best_ok > 32 then
        local chosen = best.block
        ctx.support = { lang = chosen.lang, codes = best.codes, tables = tables, names = names,
            entry = function(id) return entry(chosen, id) end }
    end
    return ctx.support or nil
end

function engine.extra_resources(game_path, ctx)
    local out = {}
    local banks = {}
    for _, bank in ipairs(Extra.BANKS) do
        local list = Extra.bank_entries(get_bytes(ctx, bank.id))
        if list and #list > 0 then
            local leaves = {}
            for _, e in ipairs(list) do
                leaves[#leaves + 1] = { id = string.format("lure_snd_%04x_%d", bank.id, e.index),
                    name = string.format("Sound %d", e.index), type = "midi" }
            end
            banks[#banks + 1] = { id = string.format("lure_bank_%04x", bank.id),
                name = string.format("%s (%d)", bank.name, #leaves), type = "category", children = leaves }
        end
    end
    if #banks > 0 then out[#out + 1] = { id = "lure_music", name = "Music and sound effects", type = "category", children = banks } end

    local sup = support(game_path, ctx)
    if sup then
        -- One entry per animation record used by a hotspot (characters, animals,
        -- animated objects), named after the first hotspot that uses it.
        local anims = Extra.parse_anims(sup.entry(0x3F0B))
        local seen, sprites = {}, {}
        for _, h in ipairs(Extra.parse_hotspots(sup.entry(0x3F07))) do
            local a = anims[h.anim]
            if h.anim ~= 0 and a and not seen[h.anim] and ctx.entries[a.anim_id] and h.width > 0 and h.height > 0
                    and h.width <= 320 and h.height <= 200 -- e.g. 0x753C is a 384x2 strip, not a sprite
                    and h.id ~= 0x411 then -- RACK_SERF_ID frames vary in size
                seen[h.anim] = true
                local name = h.name_id ~= 0 and Extra.decode(sup.tables, sup.codes, sup.names, h.name_id)
                name = name and name ~= "" and Extra.to_unicode(name) or string.format("Hotspot %04x", h.id)
                sprites[#sprites + 1] = { id = string.format("lure_anim_%04x", h.id),
                    name = string.format("%s (%dx%d)", name, h.width, h.height), type = "animation" }
            end
        end
        if #sprites > 0 then
            out[#out + 1] = { id = "lure_sprites", name = string.format("Sprites and animations (%d)", #sprites),
                type = "category", children = sprites }
        end
        local parts = {}
        for t = 0, 2 do
            local n = Extra.table_size(sup.tables[t])
            if n > 0 then
                parts[#parts + 1] = { id = "lure_txt_" .. t, name = string.format("Strings %d-%d", t * 0x7D0, t * 0x7D0 + n - 1), type = "text" }
            end
        end
        if #parts > 0 then
            out[#out + 1] = { id = "lure_text", name = "Text (" .. (Extra.LANGUAGES[sup.lang] or ("language " .. sup.lang)) .. ")",
                type = "category", children = parts }
        end
    end
    return out
end

local function load_extra(game_path, resource_id)
    local ctx = build(game_path)
    local bank, index = resource_id:match("^lure_snd_(%x+)_(%d+)$")
    if bank then
        for _, e in ipairs(Extra.bank_entries(get_bytes(ctx, tonumber(bank, 16))) or {}) do
            if e.index == tonumber(index) then
                local raw = get_bytes(ctx, tonumber(bank, 16)):sub(e.offset + 1, e.offset + e.size)
                local midi = Extra.unpack_midi(raw)
                return midi and { type = "midi", midi = midi_create_raw(midi),
                    description = string.format("Sound bank %s entry %s — MIDI%s", bank, index, raw:sub(1, 1):lower() == "c" and " (packed)" or "") }
            end
        end
        return nil
    end
    local hid = resource_id:match("^lure_anim_(%x+)$")
    if hid then
        local sup = support(game_path, ctx)
        if not sup then return nil end
        hid = tonumber(hid, 16)
        local anims = Extra.parse_anims(sup.entry(0x3F0B))
        for _, h in ipairs(Extra.parse_hotspots(sup.entry(0x3F07))) do
            if h.id == hid and anims[h.anim] then
                local a = anims[h.anim]
                local frames, count = Extra.anim_frames(get_bytes(ctx, a.anim_id), h.width, h.height, h.color, a.flags)
                if not frames then return nil end
                local palette = palette_from_rgb64(sup.entry(0x3F01)) or {}
                local images = {}
                for _, px in ipairs(frames) do
                    images[#images + 1] = image_create_indexed(h.width, h.height, px, palette, h.color)
                end
                local desc = string.format("Hotspot %04x — animation %04x, %d frame(s), %dx%d, colour offset %d (game palette)",
                    hid, a.anim_id, count, h.width, h.height, h.color)
                if #images == 1 then return { type = "image", image = images[1], description = desc } end
                return { type = "animation", animation = animation_create(images, 120), delay_ms = 120, description = desc }
            end
        end
        return nil
    end
    local t = tonumber(resource_id:match("^lure_txt_(%d)$") or "")
    if t then
        local sup = support(game_path, ctx)
        if not sup then return nil end
        local lines, ok = {}, 0
        for i = 0, Extra.table_size(sup.tables[t]) - 1 do
            local id = t * 0x7D0 + i
            local text = Extra.decode(sup.tables, sup.codes, sup.names, id)
            if text and text ~= "" then
                ok = ok + 1
                lines[#lines + 1] = string.format("%4d  %s", id, Extra.to_unicode(text))
            end
        end
        return { type = "text", text = table.concat(lines, "\n"), description = string.format(
            "%d strings (%s decoder from lure.dat); %%1/%%2 are object and character names",
            ok, Extra.LANGUAGES[sup.lang] or ("language " .. sup.lang)) }
    end
end

-- ============================================================================
-- Resource loading
-- ============================================================================

local function load_palette_bytes(ctx, id)
    local e = ctx.entries[id]
    if not e or e.size < 3 then return nil end
    return get_bytes(ctx, id)
end

function engine.load_resource(game_path, resource_id, palette_id)
    if resource_id:match("^lure_snd_") or resource_id:match("^lure_txt_") or resource_id:match("^lure_anim_") then
        return load_extra(game_path, resource_id)
    end
    local scrId = parse_id(resource_id, "lure_scr_")
    if scrId then
        local ctx = build(game_path)
        local bytes = get_bytes(ctx, scrId)
        if not bytes then return nil end
        local ok, pixels, olen = pcall(vga_decode, bytes)
        if not ok or not pixels or not olen or olen < 61408 or olen > 64001 then return nil end

        local w = 320
        local h = math.floor(olen / 320)
        if h > 200 then h = 200 end

        -- Resolve palette
        local palBytes
        if palette_id then
            local pid = parse_id(palette_id, "lure_pal_")
            if pid then palBytes = load_palette_bytes(ctx, pid) end
        end
        if not palBytes then
            local pid = palette_id_for(ctx, scrId)
            if pid then palBytes = load_palette_bytes(ctx, pid) end
        end
        local palette = palette_from_rgb64(palBytes) or {}

        local pix = {}
        for i = 1, w * h do pix[i] = pixels[i] or 0 end
        local handle = image_create_indexed(w, h, pix, palette)
        if not handle then return nil end
        return {
            type = "image",
            image = handle,
            description = string.format("Screen %s (%dx%d)", string.format("%04x", scrId), w, h),
        }
    end

    local palId = parse_id(resource_id, "lure_pal_")
    if palId then
        local ctx = build(game_path)
        local bytes = load_palette_bytes(ctx, palId)
        if not bytes then return nil end
        local pix = {}
        for y = 0, 127 do
            for x = 0, 127 do
                pix[y * 128 + x + 1] = math.floor(y / 8) * 16 + math.floor(x / 8)
            end
        end
        local handle = image_create_indexed(128, 128, pix, palette_from_rgb64(bytes) or {})
        if not handle then return nil end
        return {
            type = "image",
            image = handle,
            description = string.format("Palette %s (%d entries)", string.format("%04x", palId), math.floor(#bytes / 3)),
        }
    end

    return nil
end

-- ============================================================================
-- Default palette
-- ============================================================================

function engine.default_palette(game_path, resource_id)
    local scrId = parse_id(resource_id, "lure_scr_")
    if not scrId then return nil end
    local ctx = build(game_path)
    local pid = palette_id_for(ctx, scrId)
    if pid then return "lure_pal_" .. string.format("%04x", pid) end
    return nil
end

return engine

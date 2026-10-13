-- ============================================================================
-- Adventure Explorer - Engine Script: MicroProse Adventure Development System
--   Return of the Phantom (1991), Rex Nebular and the Cosmic Gender Bender
--   (1992), Dragonsphere (1994)  -  MicroProse Software, DOS
-- ============================================================================
-- Verified against ScummVM engines/mads (nebular / dragonsphere / phantom).
--
-- Containers:
--   *.HAG      concatenated resource archive (GLOBAL.HAG, SECTION0..9.HAG,
--              SPEECH.HAG). Header is 16 bytes ("MADSCONCAT" + padding) then
--              u16le entryCount, then per entry: u32le offset, u32le size,
--              14-byte resource name (fixed, NUL padded).
--
--   MADSPACK   generic data packing used by most resources (.SS, .ART, .MM,
--              .TT, .FF, .AA, .INT, .DAT ...). 14-byte id string
--              ("MADSPACK 2.0\x1a"), u16le itemCount at offset 14,
--              0xA0 bytes of 16 x 10-byte item headers
--              { u8 type, u8 priority, u32le size, u32le compressedSize },
--              then item data sequentially (compressedSize bytes each).
--              type 0 = none, type 1 = FAB (LZ-ish bitstream).
--
-- Resource types:
--   .SS    sprite series: MADSPACK items 0 (info: mode,type1,type2,frameCount),
--          1 (per-frame offset,size,bounds), 2 (RGB6 palette), 3 (frame pixel
--          data). mode 0: raw MSprite RLE; mode != 0: item 3 is FAB-packed and
--          per-frame chunks (offset-split) are MSprite RLE.
--   .ART   V1 (Rex) scene background. item 0: palette stream (u16 w,u16 h,
--          u16 palCount, RGB6 colours, pad 6*(256-n), u16 cycleCount, cycles);
--          item 1: raw w*h background pixels.
--   .MM    V2 (Dragonsphere/Phantom) tile map. item 0: u32 skip, u16 tcx,
--          u16 tcy, u16 tw, u16 th, u16 sw, u16 sh; item 1: tcx*tcy u16 tiles.
--   .TT    V2 tile data. items 0/1 (tile count/size + tile offsets), item 2 =
--          palette stream (no w/h here), then raw FAB-compressed tiles appended
--          after the pack at dataOffset + offset.
--   .FF    font. MADSPACK item 0: u8 maxHeight, u8 maxWidth, 127 char widths,
--          pad, 128 u16 char offsets (relative to 386), then glyph data.
--   .DSR   digital sound resource: u16le entryCount then 18-byte entries
--          { u16 freq, u32 channels, u32 compSize, u32 uncompSize, u32 offset }
--          and each sound is a FAB-compressed unsigned 8-bit PCM chunk.
--   .RGB6  palette entries are 6 bytes { r, g, b (6-bit), palIndex, u2, flags };
--          6-bit channels are converted to 8-bit via << 2.
--   .AA    animation: MADSPACK item 0 = header (sprite set names, messages,
--          frame/misc entries follow as later pack items). Exposed as info text.
-- ============================================================================

local engine = {}
engine.name        = "MicroProse MADS games"
engine.id          = "mads"
engine.description = "Return of the Phantom, Rex Nebular and the Cosmic Gender Bender, Dragonsphere (1991-94, MicroProse, DOS)"
engine.version     = "1.0"

-- ── Binary helpers ───────────────────────────────────────────────

-- All data offsets below are 0-based into a Lua string.
local function u8(d, p)  return d:byte(p + 1) end
local function u16(d, p)
    local a, b = d:byte(p + 1, p + 2)
    return a + b * 256
end
local function u32(d, p)
    local a, b, c, e = d:byte(p + 1, p + 4)
    return a + b * 256 + c * 65536 + e * 16777216
end
local function s16(d, p)
    local v = u16(d, p)
    return v >= 32768 and v - 65536 or v
end
local function upper(s) return s:upper() end

local function ext_of(name)
    return (name:match("%.([^%.%s/]+)$") or ""):upper()
end

local TRANSPARENT = { 255, 0, 255 }

-- ── FAB decompressor (Linear LZ with a 16-bit bitstream) ─────────

-- src: compressed Lua string, dest_size: expected output byte count.
-- Returns decoded Lua string (or nil on error).
local function fab_decompress(src, dest_size)
    if not src or #src < 6 or src:sub(1, 3) ~= "FAB" then return nil end
    local shift = u8(src, 3)
    if shift < 10 or shift > 13 then return nil end

    -- All bit operations below use plain arithmetic (LuaJ has no 5.3 bit ops).
    local copyOfsShift = 16 - shift
    local copyOfsMask = 0xFF * (2 ^ (shift - 8))          -- 0xFF << (shift - 8)
    -- copyLenMask = (1 << copyOfsShift) - 1  (used as modulus 2^copyOfsShift)

    local sp = 6
    local bitsLeft = 16
    local bitBuffer = u16(src, 4)

    local out = {}
    local n = 0
    local function getBit()
        bitsLeft = bitsLeft - 1
        if bitsLeft == 0 then
            local lo = u8(src, sp) or 0
            local hi = u8(src, sp + 1) or 0
            sp = sp + 2
            bitBuffer = ((lo + hi * 256) * 2) + (bitBuffer % 2)
            bitsLeft = 16
        end
        local b = bitBuffer % 2
        bitBuffer = math.floor(bitBuffer / 2)
        return b
    end

    while n < dest_size do
        if getBit() == 0 then
            local copyOfs
            local copyLen
            local do_copy = false
            if getBit() == 0 then
                -- 2-bit length + 1 direct byte back-offset
                copyLen = (getBit() * 2 + getBit()) + 2
                local b = u8(src, sp) or 0
                sp = sp + 1
                copyOfs = b - 256
                do_copy = true
            else
                -- offset formed from (b1 >> copyOfsShift) | copyOfsMask : b0,
                -- sign-extended to a negative back-offset via the 0xFFFF high bits.
                local b0 = u8(src, sp) or 0
                local b1 = u8(src, sp + 1) or 0
                sp = sp + 2
                local hi = math.floor(b1 / (2 ^ copyOfsShift)) + copyOfsMask
                copyOfs = ((hi * 256 + b0) % 65536) - 65536
                copyLen = b1 % (2 ^ copyOfsShift)           -- b1 & copyLenMask
                if copyLen == 0 then
                    copyLen = u8(src, sp) or 0
                    sp = sp + 1
                    if copyLen == 0 then
                        break
                    elseif copyLen == 1 then
                        -- special: skip this run without emitting anything
                        do_copy = false
                        copyLen = 0
                    else
                        copyLen = copyLen + 1
                        do_copy = true
                    end
                else
                    copyLen = copyLen + 2
                    do_copy = true
                end
            end
            if do_copy then
                for _ = 1, copyLen do
                    n = n + 1
                    out[n] = out[n + copyOfs]
                end
            end
        else
            local b = u8(src, sp)
            sp = sp + 1
            if not b then break end
            n = n + 1
            out[n] = string.char(b)
        end
    end

    if n ~= dest_size then return nil end
    return table.concat(out)
end

-- ── MADSPACK container ───────────────────────────────────────────

-- data: Lua string. Returns { {type,size,data}, ... } or nil.
local function mads_pack_items(data)
    if not data or #data < 176 or data:sub(1, 8) ~= "MADSPACK" then return nil end
    local count = u16(data, 14)
    if count == 0 or count > 16 then return nil end

    local entries = {}
    for i = 0, count - 1 do
        local e = 16 + i * 10
        entries[i + 1] = {
            type  = u8(data, e),
            size  = u32(data, e + 2),
            csize = u32(data, e + 6),
        }
    end

    local p = 16 + 0xA0
    local items = {}
    for i = 1, count do
        local en = entries[i]
        local raw = data:sub(p + 1, p + en.csize)
        p = p + en.csize
        if en.type == 1 then
            items[i] = fab_decompress(raw, en.size) or raw
        else
            items[i] = raw
        end
    end
    return items, p
end

-- ── MSprite RLE sprite-frame decoder ─────────────────────────────
-- data: frame pixel stream (not FAB compressed at this level).
-- Returns 1-based pixel table (w*h) of palette indices (0xFF = transparent).
local function msprite_decode(data, w, h)
    local n = w * h
    local px = {}
    for i = 1, n do px[i] = 0xFF end
    local len = #data
    if len == 0 then return px, true end

    local pos = 1
    local outp = 0          -- 0-based position within sprite
    local lineStart = 0
    local newLine = false
    local done = false

    while pos <= len do
        if newLine then
            outp = lineStart + w
            lineStart = outp
            newLine = false
        end
        local cmd1 = data:byte(pos)
        pos = pos + 1
        if cmd1 == 0xFC then
            done = true
            break
        elseif cmd1 == 0xFF then
            newLine = true
        elseif cmd1 == 0xFD then
            while not newLine and pos <= len do
                local count = data:byte(pos)
                pos = pos + 1
                if count == 0xFF then
                    newLine = true
                else
                    local pixel = data:byte(pos)
                    pos = pos + 1
                    while count > 0 do
                        outp = outp + 1
                        if outp <= n then px[outp] = (pixel == 0xFD) and 0xFF or pixel end
                        count = count - 1
                    end
                end
            end
        else
            while not newLine and pos <= len do
                local cmd2 = data:byte(pos)
                pos = pos + 1
                if cmd2 == 0xFF then
                    newLine = true
                elseif cmd2 == 0xFE then
                    local count = data:byte(pos)
                    pos = pos + 1
                    local pixel = data:byte(pos)
                    pos = pos + 1
                    while count > 0 do
                        outp = outp + 1
                        if outp <= n then px[outp] = (pixel == 0xFD) and 0xFF or pixel end
                        count = count - 1
                    end
                else
                    outp = outp + 1
                    if outp <= n then px[outp] = (cmd2 == 0xFD) and 0xFF or cmd2 end
                end
            end
        end
        if done then break end
    end

    return px, done
end

-- ── HAG archive index ────────────────────────────────────────────

local DIRS = { "", "/RESOURCE", "/DEMO" }
local cache = {}

local function first_existing(game_path, name)
    for _, d in ipairs(DIRS) do
        local p = game_path .. d .. "/" .. name
        if file_exists(p) then return p end
    end
    return nil
end

local function find_hag_paths(game_path)
    local list = {}
    local global = first_existing(game_path, "GLOBAL.HAG")
    if not global then return nil end
    list[#list + 1] = { name = "GLOBAL.HAG", path = global }
    for i = 0, 9 do
        local n = string.format("SECTION%d.HAG", i)
        local p = first_existing(game_path, n)
        if p then list[#list + 1] = { name = n, path = p } end
    end
    local sp = first_existing(game_path, "SPEECH.HAG")
    if sp then list[#list + 1] = { name = "SPEECH.HAG", path = sp } end
    return list
end

local function load_index(game_path)
    local c = cache[game_path]
    if c then return c end

    local hags = find_hag_paths(game_path)
    if not hags then return nil end

    local by_name = {}
    local list = {}
    local has_mm = false

    for _, hg in ipairs(hags) do
        local f = file_open(hg.path)
        if not f then return nil end
        local size = file_size(f)
        local data = file_read(f, 0, size)
        file_close(f)
        if not data or #data < 18 or data:sub(1, 10) ~= "MADSCONCAT" then
            return nil
        end

        local n = u16(data, 16)
        local p = 18
        for _ = 1, n do
            local off = u32(data, p)
            local rsize = u32(data, p + 4)
            p = p + 8
            local nm = data:sub(p + 1, p + 14)
            local z = nm:find("\0", 1, true)
            if z then nm = nm:sub(1, z - 1) end
            p = p + 14
            if nm ~= "" then
                local key = upper(nm)
                local rec = { name = nm, hag = hg.path, off = off, size = rsize }
                if not by_name[key] then
                    by_name[key] = rec
                    list[#list + 1] = rec
                end
                if ext_of(nm) == "MM" then has_mm = true end
            end
        end
    end

    c = { hags = hags, by_name = by_name, list = list, v1 = not has_mm }
    cache[game_path] = c
    return c
end

local function read_res(c, name, len)
    local rec = c.by_name[upper(name)]
    if not rec then return nil end
    local f = file_open(rec.hag)
    if not f then return nil end
    local avail = file_size(f)
    local rlen = len or rec.size
    if rec.off >= avail then rlen = 0 end
    if rlen > avail - rec.off then rlen = avail - rec.off end
    if rlen <= 0 then
        file_close(f)
        return nil
    end
    local d = file_read(f, rec.off, rlen)
    file_close(f)
    return d
end

local function find_rec(c, name)
    return c.by_name[upper(name)]
end

-- ── Palettes ─────────────────────────────────────────────────────

local function gray_palette()
    local pal = {}
    for i = 0, 255 do
        pal[i * 3 + 1] = i; pal[i * 3 + 2] = i; pal[i * 3 + 3] = i
    end
    return pal
end

-- RGB6 stream -> { ncol, pal768 } where pal is 1-based 768 RGB entries.
-- `lead` is the 0-based byte offset of the first colour entry:
--   v2 .TT palette item:   lead 2  (u16 palCount, then RGB6 entries)
--   v1 .ART palette item:  lead 6  (u16 w, u16 h, u16 palCount, then entries)
local function palette_from_rgb6(rgb6_data, ncol, lead)
    lead = lead or 2
    local pal = {}
    for i = 0, 255 do pal[i * 3 + 1] = 0; pal[i * 3 + 2] = 0; pal[i * 3 + 3] = 0 end
    for i = 0, ncol - 1 do
        local p = lead + i * 6
        local r = u8(rgb6_data, p)
        local g = u8(rgb6_data, p + 1)
        local b = u8(rgb6_data, p + 2)
        pal[i * 3 + 1] = math.min(255, r * 4)
        pal[i * 3 + 2] = math.min(255, g * 4)
        pal[i * 3 + 3] = math.min(255, b * 4)
    end
    return pal
end

local function palette_swatch(pal, desc)
    local CELL, GRID = 16, 16
    local SIZE = CELL * GRID
    local rgb, n = {}, 0
    for py = 0, SIZE - 1 do
        for px = 0, SIZE - 1 do
            local ci = math.floor(py / CELL) * GRID + math.floor(px / CELL)
            rgb[n + 1] = pal[ci * 3 + 1]
            rgb[n + 2] = pal[ci * 3 + 2]
            rgb[n + 3] = pal[ci * 3 + 3]
            n = n + 3
        end
    end
    return { type = "image", image = image_create_rgb(SIZE, SIZE, rgb), description = desc }
end

-- ── Background decoders ──────────────────────────────────────────

-- V1 (Rex Nebular): .ART -> { w, h, pixels, palette }
local function decode_v1_art(c, name, artdata)
    if not artdata then return nil end
    local items = mads_pack_items(artdata)
    if not items or #items < 2 then return nil end
    local pstream = items[1]
    local pixels_bin = items[2]
    if not pstream or not pixels_bin then return nil end
    local w = u16(pstream, 0)
    local h = u16(pstream, 2)
    local ncol = u16(pstream, 4)
    if w == 0 or h == 0 or w > 2048 or h > 2048 then return nil end
    if ncol > 256 then return nil end
    local pal = palette_from_rgb6(pstream, ncol, 6)

    local expect = w * h
    if #pixels_bin < expect then return nil end
    local pixels = {}
    for i = 1, expect do pixels[i] = pixels_bin:byte(i) end
    return { w = w, h = h, pixels = pixels, palette = pal, colors = ncol }
end

-- V2 (Dragonsphere/Phantom): .MM + .TT -> { w, h, pixels, palette }
local function decode_v2_bg(c, name, mmdata, ttdata)
    if not mmdata or not ttdata then return nil end
    local mmi = mads_pack_items(mmdata)
    local tti, dataOffset = mads_pack_items(ttdata)
    if not mmi or not tti or #mmi < 2 or #tti < 3 then return nil end

    local tcx = u16(mmi[1], 4)
    local tcy = u16(mmi[1], 6)
    local tw = u16(mmi[1], 8)
    local th = u16(mmi[1], 10)
    if tcx == 0 or tcy == 0 or tw == 0 or th == 0 then return nil end
    if tcx * tcy > 16384 then return nil end

    local tcount = u16(tti[1], 0)
    local tilew = u16(tti[1], 2)
    local tileh = u16(tti[1], 4)
    local ncol = u16(tti[3], 0)
    local pal = palette_from_rgb6(tti[3], ncol)
    if tcount == 0 then return nil end

    -- tile map
    local tmap = {}
    for i = 1, tcx * tcy do tmap[i] = u16(mmi[2], (i - 1) * 2) end

    -- tile data appended after the pack: dataOffset of the .TT file
    if tti[2] == nil then return nil end
    local offsets = {}
    for i = 1, tcount do offsets[i] = u32(tti[2], (i - 1) * 4) end

    -- decode the tiles actually referenced by the map
    local tiles = {}
    local w = tw * tcx
    local h = th * tcy
    local MAX = 4096
    if w > MAX or h > MAX then return nil end

    local pixels = {}
    for i = 1, w * h do pixels[i] = 0 end

    for cy = 0, tcy - 1 do
        for cx = 0, tcx - 1 do
            local idx = tmap[cy * tcx + cx + 1]
            if idx < tcount then
                local tile = tiles[idx + 1]
                if not tile then
                    local start = dataOffset + offsets[idx + 1]
                    local nxt = (idx + 1 < tcount) and (dataOffset + offsets[idx + 2]) or #ttdata
                    local chunk = ttdata:sub(start + 1, nxt)
                    local raw = fab_decompress(chunk, tilew * tileh)
                    if raw then
                        local px = {}
                        for k = 1, tilew * tileh do px[k] = raw:byte(k) end
                        tile = px
                    end
                    tiles[idx + 1] = tile
                end
                if tile then
                    local x0 = cx * tw
                    local y0 = cy * th
                    for ty = 0, th - 1 do
                        local dy = y0 + ty
                        if dy < h then
                            local dst = dy * w + x0 + 1
                            local src = ty * tw + 1
                            for tx = 0, tw - 1 do
                                if x0 + tx < w then pixels[dst + tx] = tile[src + tx] end
                            end
                        end
                    end
                end
            end
        end
    end

    return { w = w, h = h, pixels = pixels, palette = pal, colors = ncol }
end

local function load_background(c, name)
    local artname = name
    local ext = ext_of(name)
    local artdata = read_res(c, artname)
    if not artdata then return nil end

    local bg
    if ext == "ART" then
        bg = decode_v1_art(c, artname, artdata)
    elseif ext == "MM" then
        local ttname = name:gsub("%.MM$", "") .. ".TT"
        local ttdata = read_res(c, ttname)
        bg = decode_v2_bg(c, artname, artdata, ttdata)
    end
    if not bg then return nil end

    local img = image_create_indexed(bg.w, bg.h, bg.pixels, bg.palette)
    return {
        type = "image", image = img,
        description = string.format("%s - %dx%d background, %d colors",
            name, bg.w, bg.h, bg.colors)
    }
end

-- ── Palette loader (companion swatches) ──────────────────────────

local function load_palette(c, name)
    local d = read_res(c, name)
    if not d then return nil end
    local items = mads_pack_items(d)
    if not items then return nil end
    local ext = ext_of(name)
    local pstream
    if ext == "ART" then
        pstream = items[1]
        if not pstream or #pstream < 6 then return nil end
        local ncol = u16(pstream, 4)
        local pal = palette_from_rgb6(pstream, ncol, 6)
        return palette_swatch(pal, name .. " palette - " .. ncol .. " colors")
    elseif ext == "TT" then
        pstream = items[3]
        if not pstream or #pstream < 2 then return nil end
        local ncol = u16(pstream, 0)
        local pal = palette_from_rgb6(pstream, ncol)
        return palette_swatch(pal, name .. " palette - " .. ncol .. " colors")
    end
    return nil
end

-- ── Tile set montage (.TT) ───────────────────────────────────────

local function load_tiles(c, name)
    local ttdata = read_res(c, name)
    if not ttdata then return nil end
    local items, dataOffset = mads_pack_items(ttdata)
    if not items or #items < 2 then return nil end
    local tcount = u16(items[1], 0)
    local tilew = u16(items[1], 2)
    local tileh = u16(items[1], 4)
    if tcount == 0 or tilew == 0 or tileh == 0 then return nil end

    local pal = gray_palette()
    if items[3] then
        local ncol = u16(items[3], 0)
        pal = palette_from_rgb6(items[3], ncol)
    end

    local offsets = {}
    for i = 1, tcount do offsets[i] = u32(items[2], (i - 1) * 4) end

    -- decode each unique tile
    local tiles = {}
    for i = 1, tcount do
        if not tiles[i] then
            local start = dataOffset + offsets[i]
            local nxt = (i < tcount) and (dataOffset + offsets[i + 1]) or #ttdata
            local chunk = ttdata:sub(start + 1, nxt)
            local raw = fab_decompress(chunk, tilew * tileh)
            if raw then
                local px = {}
                for k = 1, tilew * tileh do px[k] = raw:byte(k) end
                -- share tile pixels for identical tiles to save memory
                local found
                for j = 1, i - 1 do
                    if tiles[j] and tiles[j].data == raw then found = j break end
                end
                if found then
                    tiles[i] = { data = raw, pixels = tiles[found].pixels }
                else
                    tiles[i] = { data = raw, pixels = px }
                end
            end
        end
    end

    local cols = math.min(32, tcount)
    local rows = math.ceil(tcount / cols)
    local cellw = tilew + 1
    local cellh = tileh + 1
    local W = cols * cellw + 1
    local H = rows * cellh + 1
    if W > 2048 or H > 2048 then
        cols = 16
        rows = math.ceil(tcount / cols)
        cellw = tilew
        cellh = tileh
        W = cols * cellw
        H = rows * cellh
    end

    local pixels = {}
    for i = 1, W * H do pixels[i] = 0 end
    for i = 1, tcount do
        local t = tiles[i]
        if t then
            local cx = (i - 1) % cols
            local cy = math.floor((i - 1) / cols)
            local x0 = cx * cellw
            local y0 = cy * cellh
            for ty = 0, tileh - 1 do
                local dy = y0 + ty
                if dy < H then
                    local dst = dy * W + x0 + 1
                    local src = ty * tilew + 1
                    for tx = 0, tilew - 1 do
                        if x0 + tx < W then pixels[dst + tx] = t.pixels[src + tx] end
                    end
                end
            end
        end
    end

    local img = image_create_indexed(W, H, pixels, pal)
    return {
        type = "image", image = img,
        description = string.format("%s - %d tile(s) of %dx%d", name, tcount, tilew, tileh)
    }
end

-- ── Sprite series (.SS) ──────────────────────────────────────────

local function decode_ss_palette(palstream, ncol)
    if ncol > 256 then ncol = 256 end
    local pal = {}
    for i = 0, 255 do pal[i * 3 + 1] = 0; pal[i * 3 + 2] = 0; pal[i * 3 + 3] = 0 end
    local p = 2
    for i = 0, ncol - 1 do
        local r = u8(palstream, p)
        local g = u8(palstream, p + 1)
        local b = u8(palstream, p + 2)
        pal[i * 3 + 1] = math.min(255, r * 4)
        pal[i * 3 + 2] = math.min(255, g * 4)
        pal[i * 3 + 3] = math.min(255, b * 4)
        p = p + 6
    end
    -- make index 255 a visible transparent marker when used
    pal[255 * 3 + 1] = TRANSPARENT[1]
    pal[255 * 3 + 2] = TRANSPARENT[2]
    pal[255 * 3 + 3] = TRANSPARENT[3]
    return pal
end

local function render_ss_series(c, name)
    local d = read_res(c, name)
    if not d then return nil end
    local items = mads_pack_items(d)
    if not items or #items < 4 then return nil end

    local misc = items[1]
    local mode = u8(misc, 0)
    local frameCount = u16(misc, 38)
    local type1 = u16(misc, 2)
    local type2 = u16(misc, 4)
    local is_bg = (type1 ~= 0) and (type2 < 4)
    if frameCount == 0 or frameCount > 4096 then return nil end

    local palstream = items[3]
    local ncol = u16(palstream, 0)
    local pal = decode_ss_palette(palstream, ncol)

    local finfo = items[2]
    local offsets = {}
    local sizes = {}
    local bounds = {}
    for i = 0, frameCount - 1 do
        local e8 = i * 16
        offsets[i + 1] = u32(finfo, e8)
        sizes[i + 1] = u32(finfo, e8 + 4)
        bounds[i + 1] = { l = s16(finfo, e8 + 8), t = s16(finfo, e8 + 10),
                          w = u16(finfo, e8 + 12), h = u16(finfo, e8 + 14) }
    end

    local pixeldata = items[4]

    -- frame pixel rows are either raw RLE (mode 0) or RLE chunks inside a
    -- FAB-unpacked blob (mode != 0), split by the frame offsets.
    local function frame_chunk(i)
        if mode == 0 then
            local from = 1
            for k = 1, i - 1 do from = from + sizes[k] end
            return pixeldata:sub(from, from + sizes[i] - 1)
        else
            local o = offsets[i]
            local nxt = (i < frameCount) and offsets[i + 1] or (#pixeldata)
            return pixeldata:sub(o + 1, nxt)
        end
    end

    -- common canvas aligned on hot-spot offsets (falls back to per-frame)
    local minl, mint, maxr, maxb = 0, 0, 0, 0
    local any = false
    for _, b in ipairs(bounds) do
        if b.w > 0 and b.h > 0 and b.w < 4096 and b.h < 4096 then
            local r = b.l + b.w
            local bb = b.t + b.h
            if not any then
                minl, mint, maxr, maxb = b.l, b.t, r, bb
                any = true
            else
                if b.l < minl then minl = b.l end
                if b.t < mint then mint = b.t end
                if r > maxr then maxr = r end
                if bb > maxb then maxb = bb end
            end
        end
    end
    local aligned = any
    local cw, ch = 0, 0
    if aligned then
        cw = maxr - minl
        ch = maxb - mint
        if cw <= 0 or ch <= 0 or cw * ch > 4000000 or cw > 3000 or ch > 3000 then
            aligned = false
        end
    end

    local handles = {}
    local maxfw, maxfh = 0, 0
    local count = 0
    for i = 1, frameCount do
        local b = bounds[i]
        if b.w > 0 and b.h > 0 and b.w < 4096 and b.h < 4096 then
            local chunk = frame_chunk(i)
            local px, ok = msprite_decode(chunk, b.w, b.h)
            if not ok then
                local dec = fab_decompress(chunk, b.w * b.h)
                if dec then px, ok = msprite_decode(dec, b.w, b.h) end
            end
            if not ok then
                for k = 1, #px do if px[k] ~= 0xFF then px[k] = 0 end end
            end

            local out, ow, oh
            if aligned then
                ow, oh = cw, ch
                out = {}
                for k = 1, ow * oh do out[k] = 0xFF end
                local ox = b.l - minl + 1
                local oy = b.t - mint + 1
                for y = 0, b.h - 1 do
                    local sof = y * b.w
                    local dof = (y + oy - 1) * ow + ox
                    for x = 0, b.w - 1 do
                        local v = px[sof + x + 1]
                        if dof + x <= ow * oh then out[dof + x] = v end
                    end
                end
            else
                ow, oh = b.w, b.h
                out = px
            end

            -- index 0 is transparent in game rendering
            if is_bg then
                for k = 1, #out do if out[k] == 0 then out[k] = 0xFF end end
            end

            handles[#handles + 1] = image_create_indexed(ow, oh, out, pal)
            count = count + 1
            if ow > maxfw then maxfw = ow end
            if oh > maxfh then maxfh = oh end
            if count >= 512 then break end
        end
    end
    if #handles == 0 then return nil end

    local desc = string.format("%s - %d frame(s), up to %dx%d, %d colors",
        name, count, maxfw, maxfh, ncol)
    local delay = 100
    if #handles == 1 then
        return { type = "image", image = handles[1], description = desc }
    end
    return {
        type = "animation", animation = animation_create(handles, delay),
        delay_ms = delay, description = desc
    }
end

-- ── Fonts (.FF) ──────────────────────────────────────────────────

local function load_font(c, name)
    local d = read_res(c, name)
    if not d then return nil end
    local items = mads_pack_items(d)
    if not items then return nil end
    local f = items[1]
    if not f or #f < 386 then
        return { type = "text", text = name .. "\n\nUnrecognised font resource." }
    end

    local maxH = u8(f, 0)
    local maxW = u8(f, 1)
    if maxH == 0 or maxH > 64 then return nil end

    local widths = {}
    local offs = {}
    -- glyph data is shifted by 1: char 0 has zero width/offset
    widths[0] = 0
    offs[0] = 0
    for i = 1, 127 do
        widths[i] = u8(f, 2 + (i - 1))
        offs[i] = u16(f, 130 + (i - 1) * 2) - 386
    end
    local dataSize = #f - 386

    local function bpp(w2)
        if w2 > 12 then return 4
        elseif w2 > 8 then return 3
        elseif w2 > 4 then return 2
        else return 1 end
    end

    local cellW = maxW + 3
    local cellH = maxH + 3
    local cols, rows = 32, 4
    local W, H = cols * cellW, rows * cellH
    local pixels = {}
    for i = 1, W * H do pixels[i] = 0 end

    for ch = 0, 127 do
        local w2 = widths[ch]
        if w2 > 0 then
            local bp = bpp(w2)
            local gp = offs[ch]
            local cx = (ch % cols) * cellW + 1
            local cy = math.floor(ch / cols) * cellH + 1
            for y = 0, maxH - 1 do
                for j = 0, bp - 1 do
                    local g = gp + y * bp + j
                    if g >= 0 and g < dataSize then
                        local b = u8(f, 386 + g)
                        local col = j * 4
                        for t = 0, 3 do
                            local v = math.floor(b / (4 ^ (3 - t)) % 4)
                            if v ~= 0 and col + t < w2 and cy + y <= H then
                                pixels[(cy + y) * W + cx + col + t] = v
                            end
                        end
                    end
                end
            end
        end
    end

    local pal = {}
    for i = 0, 255 do pal[i * 3 + 1] = 0; pal[i * 3 + 2] = 0; pal[i * 3 + 3] = 0 end
    pal[1], pal[2], pal[3] = 40, 40, 56
    pal[4], pal[5], pal[6] = 235, 235, 235
    pal[7], pal[8], pal[9] = 160, 160, 160
    pal[10], pal[11], pal[12] = 90, 90, 90
    return {
        type = "image", image = image_create_indexed(W, H, pixels, pal),
        description = string.format("%s - font, max %dx%d, 128 chars", name, maxW, maxH)
    }
end

-- ── Sound (.DSR) ─────────────────────────────────────────────────

local function dsr_entries(data)
    if not data or #data < 2 then return nil end
    local stream = data
    if data:sub(1, 8) == "MADSPACK" then
        local items = mads_pack_items(data)
        if not items then return nil end
        stream = items[1]
        if not stream then return nil end
    end
    local n = u16(stream, 0)
    if n == 0 or n > 1000 then return nil end
    local ents = {}
    for i = 0, n - 1 do
        local p = 2 + i * 18
        if p + 18 > #stream then break end
        ents[i + 1] = {
            freq = u16(stream, p),
            channels = u32(stream, p + 2),
            csize = u32(stream, p + 6),
            usize = u32(stream, p + 10),
            off = u32(stream, p + 14),
            stream = stream,
        }
    end
    return ents
end

local function load_sound_entry(c, dsrname, index)
    local d = read_res(c, dsrname)
    local ents = dsr_entries(d)
    if not ents or index < 0 or index >= #ents then return nil end
    local e = ents[index + 1]
    if e.csize == 0 or #e.stream < e.off + e.csize then return nil end
    local chunk = e.stream:sub(e.off + 1, e.off + e.csize)
    local pcm = chunk
    if chunk:sub(1, 3) == "FAB" then
        pcm = fab_decompress(chunk, e.usize)
        if not pcm then return nil end
    end
    if #pcm == 0 then return nil end

    local snd = sound_create_pcm(e.freq, 8, e.channels, false, pcm)
    if not snd then return nil end
    return {
        type = "sound", sound = snd,
        description = string.format("%s #%d - %d ms, %d Hz, %d-bit %s",
            dsrname, index + 1,
            math.floor(#pcm * 1000 / e.freq), e.freq,
            8, e.channels > 1 and "stereo" or "mono")
    }
end

-- ── Text ─────────────────────────────────────────────────────────

local function clean_text(d)
    if not d then return nil end
    return (d:gsub("\r\n", "\n"):gsub("%z", ""))
end

local function load_text(c, name)
    local d = read_res(c, name, 262144)
    if not d then return nil end
    local t = clean_text(d)
    return { type = "text", text = t, description = name }
end

-- ── Scene info (.DAT), hex views, animation info ─────────────────

local function load_scene(c, name)
    local d = read_res(c, name)
    if not d then return nil end
    local items = mads_pack_items(d)
    if not items or #items < 1 then return nil end
    local s = items[1]
    local lines = {}
    lines[#lines + 1] = name .. " - scene info"
    lines[#lines + 1] = string.format("MADSPACK item 0: %d bytes", #s)

    if c.v1 then
        local sceneId = u16(s, 0)
        local art = u16(s, 2)
        local depthStyle = u16(s, 4)
        local w = u16(s, 6)
        local h = u16(s, 8)
        lines[#lines + 1] = string.format("sceneId=%d, artFile=RM%03d.ART, depthStyle=%d", sceneId, art, depthStyle)
        lines[#lines + 1] = string.format("size=%dx%d", w, h)
        local nodeCount = u16(s, 34)
        local yBandsEnd = u16(s, 36)
        local yBandsStart = u16(s, 38)
        local maxScale = u16(s, 40)
        local minScale = u16(s, 42)
        lines[#lines + 1] = string.format("walk nodes=%d, yBands=%d..%d, scale=%d..%d",
            nodeCount, yBandsStart, yBandsEnd, minScale, maxScale)
        local p = 44 + 40
        local spritesCount = u16(s, p)
        local sprInfoCount = u16(s, p + 2)
        lines[#lines + 1] = string.format("sprite sets=%d, sprite infos=%d", spritesCount, sprInfoCount)
        local pn = p + 4
        for i = 1, spritesCount do
            local nm = s:sub(pn + 1, pn + 64)
            local z = nm:find("\0", 1, true)
            if z then nm = nm:sub(1, z - 1) end
            lines[#lines + 1] = string.format("  set %d: %s", i - 1, nm)
            pn = pn + 64
        end
    else
        local sceneIdStr = clean_text(s:sub(1, 6))
        lines[#lines + 1] = string.format("scene id string: %s", sceneIdStr)
        local nodeCount = u16(s, 104)
        local yBandsEnd = u16(s, 106)
        local yBandsStart = u16(s, 108)
        lines[#lines + 1] = string.format("walk nodes=%d, yBands=%d..%d", nodeCount, yBandsStart, yBandsEnd)
        local shadowColors = u16(s, 130)
        lines[#lines + 1] = string.format("shadow colors=%d", shadowColors)
    end

    return { type = "text", text = table.concat(lines, "\n"), description = name }
end

local function hexdump(d, limit)
    local n = math.min(#d, limit or 4096)
    local out = {}
    local off = 0
    while off < n do
        local cnt = math.min(16, n - off)
        local hexs = {}
        local asci = {}
        for i = 0, cnt - 1 do
            local b = d:byte(off + i + 1)
            hexs[#hexs + 1] = string.format("%02x", b)
            if b >= 32 and b < 127 then asci[#asci + 1] = string.char(b) else asci[#asci + 1] = "." end
        end
        out[#out + 1] = string.format("%06x  %-47s  %s", off,
            table.concat(hexs, " "), table.concat(asci))
        off = off + 16
    end
    return table.concat(out, "\n")
end

local function load_hex(c, name)
    local d = read_res(c, name, 8192)
    if not d then return nil end
    local txt = name .. " - " .. #d .. " bytes\n\n" .. hexdump(d, 4096)
    return { type = "text", text = txt, description = name }
end

local function load_anim_info(c, name)
    local d = read_res(c, name)
    if not d then return nil end
    local items = mads_pack_items(d)
    if not items or #items < 1 then return nil end
    local hdr = items[1]
    local lines = {}
    lines[#lines + 1] = name .. " - animation / interface"
    local spritesCount = u16(hdr, 0)
    local miscCount = u16(hdr, 2)
    local frameCount = u16(hdr, 4)
    local msgCount = u16(hdr, 6)
    local loadFlags = u16(hdr, 8)
    local bgType = u16(hdr, 12)
    local roomNr = u16(hdr, 14)
    lines[#lines + 1] = string.format("sprite sets=%d, misc entries=%d, frame entries=%d, messages=%d",
        spritesCount, miscCount, frameCount, msgCount)
    lines[#lines + 1] = string.format("load flags=0x%04x, bgType=%d, room=%d", loadFlags, bgType, roomNr)
    lines[#lines + 1] = string.format("MADSPACK items: %d", #items)
    return { type = "text", text = table.concat(lines, "\n"), description = name }
end

-- ── Loader dispatch ──────────────────────────────────────────────

function engine.detect(game_path)
    local global = first_existing(game_path, "GLOBAL.HAG")
    if not global then return false end
    local f = file_open(global)
    if not f then return false end
    local head = file_read(f, 0, 10)
    file_close(f)
    if head ~= "MADSCONCAT" then return false end
    for i = 0, 9 do
        if first_existing(game_path, string.format("SECTION%d.HAG", i)) then
            return true
        end
    end
    return first_existing(game_path, "SPEECH.HAG") ~= nil
end

local function subcat(parent, index, id, name)
    local node = index[id]
    if not node then
        node = { id = id, name = name, type = "category", children = {} }
        index[id] = node
        parent.children[#parent.children + 1] = node
    end
    return node
end

local function finish_counts(node)
    if node.type == "category" and node.children then
        table.sort(node.children, function(a, b)
            if a.type == "category" and b.type ~= "category" then return true end
            if a.type ~= "category" and b.type == "category" then return false end
            return upper(a.name) < upper(b.name)
        end)
        local total = 0
        for _, ch in ipairs(node.children) do
            total = total + finish_counts(ch)
        end
        node.name = string.format("%s (%d)", node.name, total)
        return total
    end
    return 1
end

local function size_str(n)
    if n >= 1048576 then
        local t = math.floor(n * 10 / 1048576 + 0.5)
        return math.floor(t / 10) .. "." .. (t % 10) .. " MB"
    end
    if n >= 1024 then
        local t = math.floor(n * 10 / 1024 + 0.5)
        return math.floor(t / 10) .. "." .. (t % 10) .. " KB"
    end
    return n .. " B"
end

local function sort_by_name(a, b) return upper(a.name) < upper(b.name) end

function engine.get_resources(game_path)
    local c = load_index(game_path)
    if not c then return {} end

    local sorted = {}
    for i, r in ipairs(c.list) do sorted[i] = r end
    table.sort(sorted, sort_by_name)

    local backgrounds = { id = "backgrounds", name = "Backgrounds", type = "category", children = {} }
    local tiles      = { id = "tiles",      name = "Tiles",         type = "category", children = {} }
    local sprites    = { id = "sprites",    name = "Sprites & Animations", type = "category", children = {} }
    local sounds     = { id = "sounds",     name = "Sound & Speech", type = "category", children = {} }
    local fonts      = { id = "fonts",      name = "Fonts",         type = "category", children = {} }
    local scenes     = { id = "scenes",     name = "Scene Data & Hex", type = "category", children = {} }
    local texts      = { id = "texts",      name = "Text",          type = "category", children = {} }
    local palettes   = { id = "palettes",   name = "Palettes",      type = "category", children = {} }
    local sidx = {}
    local snd_cache = {}

    local function room_parent(cat, name, base)
        local room = base:match("^(%d%d%d?)")
        if room then
            local sec = room:sub(1, 1)
            local sp = subcat(cat, sidx, "cat_sc_" .. cat.id .. "_s" .. sec, "Section " .. sec .. "xx")
            return subcat(sp, sidx, "cat_sc_" .. cat.id .. "_r" .. room, "Room " .. room)
        end
        return cat
    end

    for _, r in ipairs(sorted) do
        local name = r.name
        local ext = ext_of(name)
        local label = string.format("%s (%s)", name, size_str(r.size))
        local base = name:gsub("(%.[^%.]*)$", "")

        if ext == "ART" then
            -- V1 background (Rex Nebular)
            local room = name:match("^(%d%d%d)")
            local parent = room and room_parent(backgrounds, name, room) or backgrounds
            parent.children[#parent.children + 1] =
                { id = "bg_" .. name, name = label, type = "image" }
            palettes.children[#palettes.children + 1] =
                { id = "pal_" .. name, name = name, type = "image" }

        elseif ext == "MM" then
            -- V2 scene background (map + tile data)
            local parent = room_parent(backgrounds, name, base)
            parent.children[#parent.children + 1] =
                { id = "bg_" .. name, name = label, type = "image" }

        elseif ext == "TT" then
            tiles.children[#tiles.children + 1] =
                { id = "tile_" .. name, name = label, type = "image" }
            palettes.children[#palettes.children + 1] =
                { id = "pal_" .. name, name = name, type = "image" }

        elseif ext == "SS" then
            local parent = room_parent(sprites, name, base)
            parent.children[#parent.children + 1] =
                { id = "ss_" .. name, name = label, type = "animation" }

        elseif ext == "FF" then
            fonts.children[#fonts.children + 1] =
                { id = "fnt_" .. name, name = label, type = "image" }

        elseif ext == "DSR" then
            -- split into individual sounds (read the entry table, not the audio)
            local parent = sounds
            local room = name:match("^SPCHC(%d+)")
            if room then
                parent = subcat(sounds, sidx, "cat_snd_speech", "Speech")
            end
            local n = 0
            local hdr = read_res(c, name, 2)
            if hdr then n = u16(hdr, 0) end
            local ents = nil
            if n > 0 and n <= 5000 then
                local need = math.min(2 + n * 18, 65536)
                ents = dsr_entries(read_res(c, name, need))
            end
            if ents and #ents > 0 then
                for i = 1, #ents do
                    local e = ents[i]
                    local lbl = string.format("%s #%d (%d Hz, %s)",
                        name, i, e.freq, e.channels > 1 and "stereo" or "mono")
                    parent.children[#parent.children + 1] =
                        { id = "snd_" .. name .. "_" .. (i - 1), name = lbl, type = "sound" }
                end
            else
                parent.children[#parent.children + 1] =
                    { id = "snd_" .. name .. "_0", name = label, type = "sound" }
            end

        elseif ext == "DAT" then
            if name:match("^RM%d+%.[Dd][Aa][Tt]$") then
                local parent = room_parent(scenes, name, base)
                parent.children[#parent.children + 1] =
                    { id = "scn_" .. name, name = label, type = "text" }
            else
                -- data / text files (VOCAB, OBJECTS, MESSAGES, QUOTES, ...)
                texts.children[#texts.children + 1] =
                    { id = "txt_" .. name, name = label, type = "text" }
            end

        elseif ext == "TXR" or ext == "CNV" or ext == "CND" or ext == "DB" then
            texts.children[#texts.children + 1] =
                { id = "txt_" .. name, name = label, type = "text" }

        elseif ext == "AA" or ext == "INT" then
            scenes.children[#scenes.children + 1] =
                { id = "an_" .. name, name = label, type = "text" }

        elseif ext == "HH" or ext == "WW0" or ext == "WW1" or ext == "WW2" or
               ext == "WW3" or ext == "WW4" or ext == "PP0" or ext == "TTZ" or
               ext == "CYC" then
            scenes.children[#scenes.children + 1] =
                { id = "hex_" .. name, name = label, type = "text" }
        end
    end

    local out = {}
    for _, cat in ipairs({ backgrounds, tiles, sprites, sounds, fonts, palettes, scenes, texts }) do
        if #cat.children > 0 then
            finish_counts(cat)
            out[#out + 1] = cat
        end
    end
    return out
end

function engine.load_resource(game_path, resource_id, palette_id)
    local c = load_index(game_path)
    if not c then return nil end

    local prefix, name = resource_id:match("^(%a+)_(.+)$")
    if not prefix then return nil end

    if prefix == "bg"   then return load_background(c, name) end
    if prefix == "pal"  then return load_palette(c, name) end
    if prefix == "tile" then return load_tiles(c, name) end
    if prefix == "ss"   then return render_ss_series(c, name) end
    if prefix == "fnt"  then return load_font(c, name) end
    if prefix == "txt"  then return load_text(c, name) end
    if prefix == "scn"  then return load_scene(c, name) end
    if prefix == "hex"  then return load_hex(c, name) end
    if prefix == "an"   then return load_anim_info(c, name) end
    if prefix == "snd" then
        local dsrname, idx = name:match("^(.-)_(%d+)$")
        if not dsrname then return nil end
        return load_sound_entry(c, dsrname, tonumber(idx))
    end
    return nil
end

return engine
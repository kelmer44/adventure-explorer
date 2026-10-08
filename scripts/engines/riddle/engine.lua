-- ============================================================================
-- Adventure Explorer - Engine Script: Ripley's Believe It or Not!:
--                                      The Riddle of Master Lu (Sanctuary Woods, 1995)
-- ============================================================================
-- Verified against ScummVM engines/m4 (M4/MADS "riddle" game type).
--
-- Container ("hag mode"):
--   RIPLEY.HAS   hash index (found in the game root, OPTION1/ or RESOURCE/)
--                  u32le hashTableSize
--                  hashTableSize x 47-byte records:
--                    char name[33]; u8 hagfile; u8 disks; u32le offset;
--                    u32le size; u32le nextRecord      (empty slot: name[0] == 0)
--                  then 34-byte records { char name[33]; u8 hagfile } that map
--                  the hagfile number to a data file (GLOBAL.IDX -> GLOBAL.HAG)
--   *.HAG        concatenated resources (GLOBAL, SECTION2..SECTION9), addressed
--                by absolute offset/size from the hash record.
--
-- Resource types (by extension, series have no extension):
--   .TT    background: "  TT" tag, u32 size, i32 width,height,tilesX,tilesY,
--          tileW,tileH, 256 x u32 (B,G,R,0; 6-bit) palette, then tilesX*tilesY
--          raw tiles of tileW*tileH bytes (row-major tile order).
--   (none)/.SS  sprite series "M4SS": u32 'M4SS', u32 format(101),
--          optional ' PAL' chunk (u32 size, u32 n, n x u32 {idx,r,g,b} 6-bit),
--          '  SS' chunk: dword[3]=frame rate (16.16, 60Hz ticks), dword[13]=
--          frame count, dword[14..] = frame offsets; each frame header is 15
--          dwords (stream,x,y,w,h,comp,...) followed by pixel data.
--          comp bit0 = RLE8, bit7 = shadow. Sprite hot spot: drawn at (x-hotX).
--   .COD   attribute/code buffer: i16 width, i16 height, raw bytes.
--   .RAW   unsigned 8-bit mono PCM @ 11025 Hz.
--   .HMP   HMI MIDI ("HMIMIDIP"), converted here to a standard MIDI file.
--   .FNT   'FONT' bitmap font, 2 bits per pixel.
--   .DEF   scene definition text.
-- ============================================================================

local engine = {}
engine.name        = "Ripley's Believe It or Not!: The Riddle of Master Lu"
engine.id          = "riddle"
engine.description = "The Riddle of Master Lu (1995, Sanctuary Woods, DOS CD)"
engine.version     = "1.0"

-- ── Binary helpers ───────────────────────────────────────────────

-- All offsets below are 0-based into a Lua string.
local function u8(s, p)  return s:byte(p + 1) end
local function u16(s, p)
    local a, b = s:byte(p + 1, p + 2)
    return a + b * 256
end
local function u32(s, p)
    local a, b, c, d = s:byte(p + 1, p + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function i32(s, p)
    local v = u32(s, p)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end
local function i16(s, p)
    local v = u16(s, p)
    if v >= 32768 then v = v - 65536 end
    return v
end

local function upper(s) return s:upper() end

local function ext_of(name)
    return (name:match("%.([^%.%s/]+)$") or ""):upper()
end

-- ── Index (RIPLEY.HAS + .HAG files) ──────────────────────────────

local SAMPLE_RATE = 11025
local TRANSPARENT = { 255, 0, 255 }

local cache = {}

local function first_existing(game_path, name, dirs)
    for _, d in ipairs(dirs) do
        local p = game_path .. d .. "/" .. name
        if file_exists(p) then return p end
    end
    return nil
end

local DIRS = { "", "/RESOURCE", "/OPTION1" }

local function find_has(game_path)
    return first_existing(game_path, "RIPLEY.HAS", DIRS)
end

local function load_index(game_path)
    local c = cache[game_path]
    if c then return c end

    local has_path = find_has(game_path)
    if not has_path then return nil end
    local f = file_open(has_path)
    if not f then return nil end
    local data = file_read(f, 0, file_size(f))
    file_close(f)
    if not data or #data < 4 then return nil end

    local n = u32(data, 0)
    local table_end = 4 + n * 47
    if n == 0 or table_end > #data then return nil end

    -- hagfile number -> .HAG path
    local hag_paths = {}
    local p = table_end
    while p + 34 <= #data do
        local nm = data:sub(p + 1, p + 33)
        local z = nm:find("\0", 1, true)
        if z then nm = nm:sub(1, z - 1) end
        local hf = u8(data, p + 33)
        local base = nm:gsub("%.[^%.]*$", "")
        local hp = first_existing(game_path, base .. ".HAG", DIRS)
        if hp then hag_paths[hf] = hp end
        p = p + 34
    end

    local by_name = {}   -- UPPER name -> record
    local list = {}
    for i = 0, n - 1 do
        local base = 4 + i * 47
        if data:byte(base + 1) ~= 0 then
            local nm = data:sub(base + 1, base + 33)
            local z = nm:find("\0", 1, true)
            if z then nm = nm:sub(1, z - 1) end
            local hf = u8(data, base + 33)
            local rec = {
                name = nm,
                hf   = hf,
                off  = u32(data, base + 35),
                size = u32(data, base + 39),
            }
            local key = upper(nm)
            if hag_paths[hf] and not by_name[key] then
                by_name[key] = rec
                list[#list + 1] = rec
            end
        end
    end

    c = { has_path = has_path, hag_paths = hag_paths, by_name = by_name, list = list }
    cache[game_path] = c
    return c
end

local function read_res(c, rec, len)
    local hp = c.hag_paths[rec.hf]
    if not hp then return nil end
    local f = file_open(hp)
    if not f then return nil end
    local d = file_read(f, rec.off, len or rec.size)
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

local function tt_palette(d)
    local pal = {}
    for i = 0, 255 do
        local p = 32 + i * 4
        local b, g, r = d:byte(p + 1, p + 3)
        pal[i * 3 + 1] = math.min(255, (r or 0) * 4)
        pal[i * 3 + 2] = math.min(255, (g or 0) * 4)
        pal[i * 3 + 3] = math.min(255, (b or 0) * 4)
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

-- ── Backgrounds (.TT) ────────────────────────────────────────────

local function decode_tt(d)
    if not d or #d < 1056 then return nil end
    local W, H   = i32(d, 8), i32(d, 12)
    local nx, ny = i32(d, 16), i32(d, 20)
    local tw, th = i32(d, 24), i32(d, 28)
    if W <= 0 or H <= 0 or W > 4096 or H > 2048 then return nil end
    if nx <= 0 or ny <= 0 or tw <= 0 or th <= 0 then return nil end

    local pixels = {}
    for i = 1, W * H do pixels[i] = 0 end

    local tile_size = tw * th
    local pos = 1056
    for tyi = 0, ny - 1 do
        for txi = 0, nx - 1 do
            local x0 = txi * tw
            local cnt = math.min(tw, W - x0)
            if cnt > 0 then
                for row = 0, th - 1 do
                    local y = tyi * th + row
                    if y < H then
                        local rp = pos + row * tw
                        local t = { d:byte(rp + 1, rp + cnt) }
                        local base = y * W + x0
                        for k = 1, #t do pixels[base + k] = t[k] end
                    end
                end
            end
            pos = pos + tile_size
        end
    end

    return { w = W, h = H, pixels = pixels, palette = tt_palette(d),
             tiles = nx .. "x" .. ny, tile = tw .. "x" .. th }
end

local function load_background(c, name, palette_name)
    local rec = find_rec(c, name)
    if not rec then return nil end
    local d = read_res(c, rec)
    local tt = decode_tt(d)
    if not tt then return nil end

    local pal = tt.palette
    if palette_name and palette_name ~= name then
        local prec = find_rec(c, palette_name)
        local pd = prec and read_res(c, prec, 32 + 1024)
        if pd and #pd >= 1056 then pal = tt_palette(pd) end
    end

    local img = image_create_indexed(tt.w, tt.h, tt.pixels, pal)
    return {
        type = "image", image = img,
        description = string.format("%s - %dx%d, 256 colors (%s tiles of %s)",
            name, tt.w, tt.h, tt.tiles, tt.tile)
    }
end

local function load_palette(c, name)
    local rec = find_rec(c, name)
    if not rec then return nil end
    local d = read_res(c, rec, 32 + 1024)
    if not d or #d < 1056 then return nil end
    return palette_swatch(tt_palette(d), name .. " palette - 256 colors")
end

-- ── Sprite series (SS) ───────────────────────────────────────────

local function rle8_decode(d, pos, w, h)
    -- pos: 0-based start of RLE data. Returns table of w*h indices (1-based).
    local n = w * h
    local px = {}
    for i = 1, n do px[i] = 0 end
    local len = #d
    local dest, line = 0, 0
    local p = pos + 1
    while p <= len do
        local cnt = d:byte(p); p = p + 1
        if cnt ~= 0 then
            local v = d:byte(p); p = p + 1
            if not v then break end
            for k = 0, cnt - 1 do
                local o = dest + k
                if o >= 0 and o < n then px[o + 1] = v end
            end
            dest = dest + cnt
        else
            local c2 = d:byte(p); p = p + 1
            if not c2 then break end
            if c2 >= 3 then
                for k = 0, c2 - 1 do
                    local o = dest + k
                    local v = d:byte(p + k)
                    if v and o >= 0 and o < n then px[o + 1] = v end
                end
                p = p + c2
                dest = dest + c2
            elseif c2 == 0 then
                line = line + 1
                dest = line * w
            elseif c2 == 1 then
                break
            else
                local dx = d:byte(p) or 0
                local dy = d:byte(p + 1) or 0
                p = p + 2
                dest = dest + dx
                line = line + dy
                dest = dest + dy * w
            end
        end
    end
    return px
end

local function parse_ss(d)
    if not d or #d < 20 or d:sub(1, 4) ~= "SS4M" then return nil end
    if u32(d, 4) < 101 then return nil end

    local p = 8
    local pal = {}   -- idx -> {r,g,b}
    local has_pal = false
    local t = u32(d, p)
    if t == 0x2050414C then   -- ' PAL'
        local ncol = u32(d, p + 8)
        if ncol > 256 then return nil end
        for i = 0, ncol - 1 do
            local v = u32(d, p + 12 + i * 4)
            local idx = math.floor(v / 16777216)
            pal[idx] = {
                (math.floor(v / 65536) % 256) * 4,
                (math.floor(v / 256) % 256) * 4,
                (v % 256) * 4,
            }
            has_pal = true
        end
        p = p + 12 + ncol * 4
        t = u32(d, p)
    end
    if t ~= 0x20205353 then return nil end   -- '  SS'

    local rate  = u32(d, p + 3 * 4)
    local count = u32(d, p + 13 * 4)
    if count == 0 or count > 2000 then return nil end
    local data_base = p + (14 + count) * 4

    local frames = {}
    for i = 0, count - 1 do
        local off = u32(d, p + (14 + i) * 4)
        local h0 = data_base + off
        if h0 + 60 > #d then break end
        frames[#frames + 1] = {
            xo = i32(d, h0 + 8), yo = i32(d, h0 + 12),
            w  = i32(d, h0 + 16), h  = i32(d, h0 + 20),
            comp = u32(d, h0 + 24),
            data = h0 + 60,
        }
    end
    if #frames == 0 then return nil end
    return { pal = pal, has_pal = has_pal, frames = frames, rate = rate }
end

local function render_ss(d, base_pal)
    local ss = parse_ss(d)
    if not ss then return nil end

    -- final palette: base palette overlaid with the series' own colours
    local pal = {}
    for i = 1, 768 do pal[i] = base_pal[i] end
    for idx, c in pairs(ss.pal) do
        pal[idx * 3 + 1] = math.min(255, c[1])
        pal[idx * 3 + 2] = math.min(255, c[2])
        pal[idx * 3 + 3] = math.min(255, c[3])
    end
    -- index 0 is transparent
    pal[1], pal[2], pal[3] = TRANSPARENT[1], TRANSPARENT[2], TRANSPARENT[3]

    -- common canvas across all frames (hot spot aligned)
    local minx, miny, maxx, maxy = 0, 0, 0, 0
    local first = true
    for _, fr in ipairs(ss.frames) do
        if fr.w > 0 and fr.h > 0 and fr.w < 4096 and fr.h < 4096 then
            local x1, y1 = -fr.xo, -fr.yo
            local x2, y2 = x1 + fr.w, y1 + fr.h
            if first then
                minx, miny, maxx, maxy = x1, y1, x2, y2; first = false
            else
                if x1 < minx then minx = x1 end
                if y1 < miny then miny = y1 end
                if x2 > maxx then maxx = x2 end
                if y2 > maxy then maxy = y2 end
            end
        end
    end
    if first then return nil end
    local cw, ch = maxx - minx, maxy - miny
    local aligned = true
    if cw * ch > 4000000 or cw > 3000 or ch > 3000 then
        -- offsets are unreasonable: fall back to unaligned frames
        aligned = false
    end

    local handles = {}
    local total_w, total_h = 0, 0
    for _, fr in ipairs(ss.frames) do
        if fr.w > 0 and fr.h > 0 and fr.w < 4096 and fr.h < 4096 then
            local px
            local shadow = (fr.comp >= 128)
            if fr.comp % 2 == 1 then
                px = rle8_decode(d, fr.data, fr.w, fr.h)
            else
                px = {}
                local len = fr.w * fr.h
                local raw = d:sub(fr.data + 1, fr.data + len)
                for i = 1, len do px[i] = raw:byte(i) or 0 end
            end
            if shadow then
                for i = 1, #px do if px[i] ~= 0 then px[i] = 1 end end
            end

            local out, ow, oh
            if aligned then
                ow, oh = cw, ch
                out = {}
                for i = 1, ow * oh do out[i] = 0 end
                local ox, oy = -fr.xo - minx, -fr.yo - miny
                for y = 0, fr.h - 1 do
                    local so = y * fr.w
                    local dof = (y + oy) * ow + ox
                    for x = 1, fr.w do out[dof + x] = px[so + x] end
                end
            else
                ow, oh, out = fr.w, fr.h, px
            end

            local fp = pal
            if shadow then
                fp = {}
                for i = 1, 768 do fp[i] = pal[i] end
                fp[4], fp[5], fp[6] = 24, 24, 24
            end
            handles[#handles + 1] = image_create_indexed(ow, oh, out, fp)
            if ow > total_w then total_w = ow end
            if oh > total_h then total_h = oh end
        end
    end
    if #handles == 0 then return nil end

    local ticks = ss.rate / 65536
    local delay = 100
    if ticks >= 1 and ticks <= 120 then delay = math.floor(ticks * 1000 / 60) end

    return { handles = handles, w = total_w, h = total_h, delay = delay,
             own_pal = ss.has_pal, count = #ss.frames }
end

local function load_series(c, name, palette_name)
    local rec = find_rec(c, name)
    if not rec then return nil end
    local d = read_res(c, rec)
    if not d then return nil end

    local base_pal = gray_palette()
    if palette_name then
        local prec = find_rec(c, palette_name)
        local pd = prec and read_res(c, prec, 32 + 1024)
        if pd and #pd >= 1056 then base_pal = tt_palette(pd) end
    end

    local r = render_ss(d, base_pal)
    if not r then
        return { type = "text", text = string.format(
            "%s\n\nSprite series could not be decoded (%d bytes).", name, #d) }
    end

    local desc = string.format("%s - %d frame(s), %dx%d%s", name, #r.handles, r.w, r.h,
        r.own_pal and ", embedded palette overlay" or ", no embedded palette")
    if #r.handles == 1 then
        return { type = "image", image = r.handles[1], description = desc }
    end
    return {
        type = "animation", animation = animation_create(r.handles, r.delay),
        delay_ms = r.delay, description = desc
    }
end

-- ── Attribute codes (.COD) ───────────────────────────────────────

local function load_code(c, name)
    local rec = find_rec(c, name)
    if not rec then return nil end
    local d = read_res(c, rec)
    if not d or #d < 4 then return nil end
    local w, h = u16(d, 0), u16(d, 2)
    if w == 0 or h == 0 or w > 4096 or h > 2048 or #d < 4 + w * h then return nil end

    local pixels = {}
    for i = 1, w * h do pixels[i] = d:byte(4 + i) end

    -- false-colour palette so the different attribute values are distinguishable
    local pal = {}
    for i = 0, 255 do
        if i == 0 then
            pal[1], pal[2], pal[3] = 0, 0, 0
        else
            pal[i * 3 + 1] = (i * 67 + 40) % 256
            pal[i * 3 + 2] = (i * 131 + 90) % 256
            pal[i * 3 + 3] = (i * 29 + 160) % 256
        end
    end
    return {
        type = "image", image = image_create_indexed(w, h, pixels, pal),
        description = string.format("%s - %dx%d attribute/code buffer (false colour)", name, w, h)
    }
end

-- ── Sound (.RAW) ─────────────────────────────────────────────────

local function load_sound(c, name)
    local rec = find_rec(c, name)
    if not rec then return nil end
    local d = read_res(c, rec)
    if not d or #d == 0 then return nil end
    local snd = sound_create_pcm(SAMPLE_RATE, 8, 1, false, d)
    if not snd then return nil end
    return {
        type = "sound", sound = snd,
        description = string.format("%s - %d samples, %d ms @ %d Hz, 8-bit unsigned mono",
            name, #d, math.floor(#d * 1000 / SAMPLE_RATE), SAMPLE_RATE)
    }
end

-- ── Music (.HMP -> standard MIDI) ────────────────────────────────

local function vlq(v)
    local bytes = { v % 128 }
    v = math.floor(v / 128)
    while v > 0 do
        table.insert(bytes, 1, (v % 128) + 128)
        v = math.floor(v / 128)
    end
    return string.char(table.unpack(bytes))
end

local function be32(v)
    return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
        math.floor(v / 256) % 256, v % 256)
end

local function hmp_to_smf(d)
    if #d < 776 or d:sub(1, 8) ~= "HMIMIDIP" then return nil end
    local version013195 = (d:sub(9, 14) == "013195")
    local ntracks = u32(d, 48)
    local bpm = u32(d, 56)
    if ntracks == 0 or ntracks > 64 or bpm == 0 then return nil end
    local pos = version013195 and 904 or 776

    local out = { "MThd", be32(6), "\0\1", string.char(0, ntracks), "\0\60" }
    for t = 0, ntracks - 1 do
        if pos + 12 > #d then return nil end
        local csize = u32(d, pos + 4)
        local body_start = pos + 12
        local body_end = pos + csize   -- exclusive, 0-based
        if csize < 12 or body_end > #d then return nil end

        local ev = {}
        if t == 0 then
            local tempo = math.floor(60000000 / bpm)
            ev[#ev + 1] = "\0\255\81\3" .. string.char(math.floor(tempo / 65536) % 256,
                math.floor(tempo / 256) % 256, tempo % 256)
        end

        local i = body_start
        local running = 0
        local ended = false
        while i < body_end do
            -- HMP delta: 7-bit groups, least significant first, last byte has bit 7 set
            local delta, shift = 0, 0
            repeat
                local b = u8(d, i); i = i + 1
                delta = delta + (b % 128) * (2 ^ shift)
                shift = shift + 7
            until b >= 128 or i >= body_end
            local status = u8(d, i)
            local s = status
            local ebytes
            if status >= 128 then
                i = i + 1
                running = status
                if status == 0xFF then
                    local mt = u8(d, i); i = i + 1
                    local len, m = 0, 0
                    repeat
                        local b = u8(d, i); i = i + 1
                        len = len * 128 + (b % 128)
                        m = b
                    until m < 128
                    ebytes = string.char(0xFF, mt) .. vlq(len) .. d:sub(i + 1, i + len)
                    i = i + len
                    if mt == 0x2F then ended = true end
                elseif status == 0xF0 then
                    local len, m = 0, 0
                    repeat
                        local b = u8(d, i); i = i + 1
                        len = len * 128 + (b % 128)
                        m = b
                    until m < 128
                    ebytes = string.char(0xF0) .. vlq(len) .. d:sub(i + 1, i + len)
                    i = i + len
                elseif status >= 0xC0 and status < 0xE0 then
                    ebytes = string.char(status, u8(d, i)); i = i + 1
                else
                    ebytes = string.char(status, u8(d, i), u8(d, i + 1)); i = i + 2
                end
            else
                -- running status
                s = running
                if s >= 0xC0 and s < 0xE0 then
                    ebytes = string.char(status); i = i + 1
                else
                    ebytes = string.char(status, u8(d, i + 1)); i = i + 2
                end
            end
            ev[#ev + 1] = vlq(math.floor(delta)) .. ebytes
            if ended then break end
        end
        if not ended then ev[#ev + 1] = "\0\255\47\0" end

        local body = table.concat(ev)
        out[#out + 1] = "MTrk"
        out[#out + 1] = be32(#body)
        out[#out + 1] = body
        pos = pos + csize
    end
    return table.concat(out)
end

local function load_music(c, name)
    local rec = find_rec(c, name)
    if not rec then return nil end
    local d = read_res(c, rec)
    if not d then return nil end
    local smf = hmp_to_smf(d)
    if not smf then
        return { type = "text", text = name .. "\n\nHMP music could not be converted." }
    end
    local h = midi_create_raw(smf)
    if not h then return nil end
    return {
        type = "midi", midi = h,
        description = string.format("%s - HMI MIDI (HMP), %d bytes (%d bytes as SMF)",
            name, #d, #smf)
    }
end

-- ── Fonts (.FNT) ─────────────────────────────────────────────────

local function load_font(c, name)
    local rec = find_rec(c, name)
    if not rec then return nil end
    local d = read_res(c, rec)
    if not d or #d < 790 or d:sub(1, 4) ~= "TNOF" then
        return { type = "text", text = name .. "\n\nUnrecognised font file." }
    end
    local max_y = u8(d, 4)
    if max_y == 0 or max_y > 64 then return nil end
    local widths, offs = {}, {}
    local max_w = 0
    for i = 0, 255 do
        widths[i] = u8(d, 14 + i)
        offs[i] = i16(d, 274 + i * 2)
        if i < 128 and widths[i] > max_w then max_w = widths[i] end
    end
    local pix_base = 790

    local cell_w, cell_h = max_w + 3, max_y + 3
    local cols, rows = 16, 8
    local W, H = cols * cell_w, rows * cell_h
    local pixels = {}
    for i = 1, W * H do pixels[i] = 0 end

    for ch = 0, 127 do
        local w = widths[ch]
        if w > 0 then
            local cx = (ch % cols) * cell_w + 1
            local cy = math.floor(ch / cols) * cell_h + 1
            local bpl = math.floor(w / 4) + 1
            local gp = pix_base + offs[ch]
            for y = 0, max_y - 1 do
                for bx = 0, bpl - 1 do
                    local b = d:byte(gp + y * bpl + bx + 1) or 0
                    for k = 0, 3 do
                        local v = math.floor(b / (4 ^ (3 - k))) % 4
                        local x = bx * 4 + k
                        if v ~= 0 and x < w then
                            pixels[(cy + y) * W + cx + x + 1] = (v == 3) and 2 or 1
                        end
                    end
                end
            end
        end
    end

    local pal = {}
    for i = 0, 255 do pal[i * 3 + 1] = 0; pal[i * 3 + 2] = 0; pal[i * 3 + 3] = 0 end
    pal[1], pal[2], pal[3] = 32, 32, 48
    pal[4], pal[5], pal[6] = 255, 255, 255
    pal[7], pal[8], pal[9] = 160, 160, 160
    return {
        type = "image", image = image_create_indexed(W, H, pixels, pal),
        description = string.format("%s - font, height %d, chars 0-127 (16 per row)", name, max_y)
    }
end

-- ── Scene definition text (.DEF) ─────────────────────────────────

local function load_text(c, name)
    local rec = find_rec(c, name)
    if not rec then return nil end
    local d = read_res(c, rec)
    if not d then return nil end
    d = d:gsub("\r\n", "\n"):gsub("%z", "")
    return { type = "text", text = d, description = name }
end

-- ── Resource tree ────────────────────────────────────────────────

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

local function by_upper(a, b) return upper(a.name) < upper(b.name) end

-- Get-or-create a child category inside `parent`.
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

function engine.detect(game_path)
    local has = find_has(game_path)
    if not has then return false end
    return first_existing(game_path, "GLOBAL.HAG", DIRS) ~= nil
end

function engine.get_resources(game_path)
    local c = load_index(game_path)
    if not c then return {} end

    local sorted = {}
    for i, r in ipairs(c.list) do sorted[i] = r end
    table.sort(sorted, by_upper)

    local backgrounds = { id = "backgrounds", name = "Backgrounds", type = "category", children = {} }
    local palettes    = { id = "palettes",    name = "Palettes",    type = "category", children = {} }
    local sprites     = { id = "sprites",     name = "Sprites & Animations", type = "category", children = {} }
    local sounds      = { id = "sounds",      name = "Sound & Speech", type = "category", children = {} }
    local music       = { id = "music",       name = "Music", type = "category", children = {} }
    local codes       = { id = "codes",       name = "Attribute Codes", type = "category", children = {} }
    local fonts       = { id = "fonts",       name = "Fonts", type = "category", children = {} }
    local texts       = { id = "texts",       name = "Scene Definitions", type = "category", children = {} }
    local sidx = {}

    -- open each HAG once to sniff the header of extension-less resources
    local handles = {}
    for hf, hp in pairs(c.hag_paths) do handles[hf] = file_open(hp) end

    for _, r in ipairs(sorted) do
        local name = r.name
        local ext = ext_of(name)
        local label = string.format("%s (%s)", name, size_str(r.size))

        if ext == "TT" then
            backgrounds.children[#backgrounds.children + 1] =
                { id = "bg_" .. name, name = label, type = "image" }
            palettes.children[#palettes.children + 1] =
                { id = "pal_" .. name, name = name, type = "palette" }

        elseif ext == "RAW" then
            local base = name:gsub("%.RAW$", ""):gsub("%.raw$", "")
            local parent
            local com = base:match("^[Cc][Oo][Mm]")
            local room = base:match("^(%d%d%d)")
            local conv = base:match("^(%d%d)_")
            if com then
                parent = subcat(sounds, sidx, "cat_snd_common", "Common")
            elseif room then
                local sec = room:sub(1, 1)
                local sp = subcat(sounds, sidx, "cat_snd_sec" .. sec, "Section " .. sec .. "xx")
                parent = subcat(sp, sidx, "cat_snd_room" .. room, "Room " .. room)
            elseif conv then
                parent = subcat(sounds, sidx, "cat_snd_conv" .. conv, "Conversation " .. conv)
            else
                parent = subcat(sounds, sidx, "cat_snd_other", "Other")
            end
            parent.children[#parent.children + 1] =
                { id = "snd_" .. name, name = label, type = "sound" }

        elseif ext == "HMP" then
            music.children[#music.children + 1] =
                { id = "mus_" .. name, name = label, type = "sound" }

        elseif ext == "COD" then
            codes.children[#codes.children + 1] =
                { id = "cod_" .. name, name = label, type = "image" }

        elseif ext == "FNT" then
            fonts.children[#fonts.children + 1] =
                { id = "fnt_" .. name, name = label, type = "image" }

        elseif ext == "DEF" then
            texts.children[#texts.children + 1] =
                { id = "def_" .. name, name = label, type = "text" }

        elseif ext == "SS" or ext == "" then
            -- sprite series (verify the "M4SS" header; skips scripts/machines)
            local ok = false
            local h = handles[r.hf]
            if h then
                local head = file_read(h, r.off, 4)
                ok = (head == "SS4M")
            end
            if ok then
                local room = name:match("^(%d%d%d)")
                local parent
                if room then
                    parent = subcat(sprites, sidx, "cat_ss_room" .. room, "Room " .. room)
                else
                    local word = (name:match("^(%a+)") or "Misc"):upper()
                    if #word > 12 then word = word:sub(1, 12) end
                    parent = subcat(sprites, sidx, "cat_ss_w" .. word, word)
                end
                parent.children[#parent.children + 1] =
                    { id = "ss_" .. name, name = label, type = "animation" }
            end
        end
    end

    for _, h in pairs(handles) do file_close(h) end

    local out = {}
    for _, cat in ipairs({ backgrounds, sprites, sounds, music, palettes, codes, fonts, texts }) do
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

    local pal_name
    if palette_id and palette_id ~= "" then
        pal_name = palette_id:match("^pal_(.+)$")
    end

    if prefix == "bg"  then return load_background(c, name, pal_name) end
    if prefix == "pal" then return load_palette(c, name) end
    if prefix == "ss"  then return load_series(c, name, pal_name) end
    if prefix == "snd" then return load_sound(c, name) end
    if prefix == "mus" then return load_music(c, name) end
    if prefix == "cod" then return load_code(c, name) end
    if prefix == "fnt" then return load_font(c, name) end
    if prefix == "def" then return load_text(c, name) end
    return nil
end

return engine

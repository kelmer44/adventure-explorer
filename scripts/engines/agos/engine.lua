-- ============================================================================
-- Adventure Explorer - Engine Script: Simon the Sorcerer 1
-- ============================================================================
-- Adventure Soft, 1993. 320x200 (view: 320x134), 32-color backgrounds.
-- VGA file pairs (file1=palettes, file2=images) packed in simon.gme archive.
--
-- Image formats (vgaFile2):
--   Background (w=320, h=134/135/200, flags=0x80):
--     5-bit packed rows: 8 pixels per 5 bytes, 200 bytes/row, values 0-31.
--   Sprite compressed (flags=0x80, not background):
--     Column-by-column signed-byte RLE; each decoded byte = 2 nibble pixels;
--     draw_width = w/2 columns; values 0-15.
--   Sprite uncompressed (flags=0x00):
--     w/2 bytes per row; each byte = 2 nibble pixels; values 0-15.
--
-- Palette (vgaFile1):
--   Offset 6 from start: 32 colors x 3 bytes (R,G,B), 6-bit VGA -> 8-bit via *4.
-- ============================================================================

local engine = {}
engine.name        = "Simon the Sorcerer"
engine.id          = "agos"
engine.description = "Simon the Sorcerer 1 (1993, Adventure Soft)"
engine.version     = "3.0"

-- ============================================================================
-- Binary helpers
-- ============================================================================

local function u8(data, pos)
    return data:byte(pos)
end
local function u16be(data, pos)
    return data:byte(pos) * 256 + data:byte(pos + 1)
end
local function u32be(data, pos)
    return data:byte(pos) * 16777216 + data:byte(pos + 1) * 65536
         + data:byte(pos + 2) * 256  + data:byte(pos + 3)
end
local function u32le(data, pos)
    return data:byte(pos)           + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536 + data:byte(pos + 3) * 16777216
end

-- ============================================================================
-- GME archive parser
-- Returns: offsets table (0-indexed), num_entries
-- ============================================================================

local function parse_gme(f)
    local fsize = file_size(f)
    if fsize < 8 then return nil end

    local header = file_read(f, 0, 4)
    if not header then return nil end
    local table_size = u32le(header, 1)
    if table_size < 8 or table_size > fsize then return nil end

    local num_entries = math.floor(table_size / 4)
    local raw = file_read(f, 0, table_size)
    if not raw or #raw < table_size then return nil end

    local offsets = {}
    for i = 0, num_entries - 1 do
        offsets[i] = u32le(raw, i * 4 + 1)
    end
    return offsets, num_entries
end

-- ============================================================================
-- VGA file2 image table parser
--
-- Layout: 8-byte entries (all big-endian)
--   [+0..+3] u32be: absolute data offset from start of vgaFile2
--   [+4]     u8:    flags (0x80 = compressed)
--   [+5]     u8:    height in pixels
--   [+6..+7] u16be: width in pixels (raw; backgrounds = 320)
--
-- Entry 0: sentinel (offset=0). Entry 1's data offset = total table size in bytes,
-- so num_entries = entry1_data_offset / 8.
-- ============================================================================

local function parse_image_table(data)
    if not data or #data < 16 then return nil end

    -- Entry 1 starts at byte offset 8 (0-based) = Lua position 9.
    -- Its data offset equals the total table size in bytes.
    local table_bytes = u32be(data, 9)
    if table_bytes < 8 or table_bytes > #data then
        table_bytes = math.min(500 * 8, #data)
    end
    local num_entries = math.floor(table_bytes / 8)

    local images = {}
    for i = 1, num_entries - 1 do  -- skip entry 0 (sentinel)
        local base = i * 8 + 1     -- 1-based Lua position
        if base + 7 > #data then break end

        local offset = u32be(data, base)
        local flags  = u8(data, base + 4)
        local height = u8(data, base + 5)
        local width  = u16be(data, base + 6)

        if offset == 0 then break end

        if offset < #data and width > 0 and width <= 2560
           and height > 0 and height <= 512 then

            local compressed    = (flags % 256 >= 128)
            local is_background = (width == 320
                and (height == 134 or height == 135 or height == 200))

            images[#images + 1] = {
                index         = i,
                offset        = offset,
                flags         = flags,
                width         = width,
                height        = height,
                compressed    = compressed,
                is_background = is_background,
            }
        end
    end

    return images
end

-- ============================================================================
-- Background decoder: 5-bit packed rows
--
-- Format: 8 pixels per 5 bytes (5-bit values 0-31).
-- Per row: (w/8) groups of 5 bytes -> w pixels.
-- Matches draw32ColorImage compressed path in ScummVM (drawImage_clip *4 factor).
-- ============================================================================

local function decode_background(data, offset, width, height)
    local pixels = {}
    local n = 0
    local pos = offset

    for _ = 1, height do
        local count = math.floor(width / 8)
        for _ = 1, count do
            if pos + 4 > #data then
                for _ = 1, 8 do n = n + 1; pixels[n] = 0 end
            else
                local a = u8(data, pos)
                local b = u8(data, pos + 1)
                local c = u8(data, pos + 2)
                local d = u8(data, pos + 3)
                local e = u8(data, pos + 4)

                local bits = a * 16777216 + b * 65536 + c * 256 + d

                n = n + 1; pixels[n] = math.floor(bits / 134217728) % 32  -- bits 31-27
                n = n + 1; pixels[n] = math.floor(bits / 4194304)   % 32  -- bits 26-22
                n = n + 1; pixels[n] = math.floor(bits / 131072)    % 32  -- bits 21-17
                n = n + 1; pixels[n] = math.floor(bits / 4096)      % 32  -- bits 16-12
                n = n + 1; pixels[n] = math.floor(bits / 128)       % 32  -- bits 11-7
                n = n + 1; pixels[n] = math.floor(bits / 4)         % 32  -- bits 6-2

                local bits2 = (bits % 4) * 256 + e
                n = n + 1; pixels[n] = math.floor(bits2 / 32) % 32        -- bits 9-5
                n = n + 1; pixels[n] = bits2 % 32                         -- bits 4-0
            end
            pos = pos + 5
        end
    end

    return pixels
end

-- ============================================================================
-- Sprite decoder: column-by-column signed-byte RLE (vc10_depackColumn)
--
-- Reads draw_width = w/2 columns. Each column = h bytes, each byte = 2 nibbles.
-- RLE encoding (signed count byte):
--   n >= 0: run of (n+1) copies of next color byte
--   n <  0: literal sequence of abs(n) bytes
-- State (a, pos) carries across column boundaries.
-- ============================================================================

local function decode_sprite_compressed(data, offset, w, h)
    local pixels = {}
    for i = 1, w * h do pixels[i] = 0 end

    if w < 2 or h < 1 then return pixels end

    local pos = offset
    local a   = -128  -- depack_cont: -0x80 = "read new count at start"
    local draw_width = math.floor(w / 2)
    local col_buf = {}

    for col = 0, draw_width - 1 do
        for i = 1, h do col_buf[i] = 0 end

        local dh       = h
        local di       = 0
        local col_done = false

        if a == -128 then
            if pos > #data then break end
            local bv = data:byte(pos); pos = pos + 1
            a = bv >= 128 and bv - 256 or bv
        end

        while di < h and not col_done do
            if a >= 0 then
                -- RLE run: (a+1) copies of the next color byte
                if pos > #data then col_done = true; a = -128; break end
                local color_pos = pos
                local color = data:byte(pos); pos = pos + 1

                while true do
                    di = di + 1
                    col_buf[di] = color
                    dh = dh - 1

                    if dh == 0 then
                        -- Column boundary inside a run; --a then check
                        a = a - 1
                        if a < 0 then
                            a = -128         -- run complete
                        else
                            pos = color_pos  -- src--: re-read color next column
                        end
                        col_done = true
                        break
                    end

                    a = a - 1
                    if a < 0 then break end  -- run exhausted
                end

                if not col_done then
                    if pos > #data then a = -128; col_done = true
                    else
                        local bv = data:byte(pos); pos = pos + 1
                        a = bv >= 128 and bv - 256 or bv
                    end
                end

            else
                -- Literal sequence: abs(a) bytes
                while true do
                    if pos > #data then a = -128; col_done = true; break end
                    di = di + 1
                    col_buf[di] = data:byte(pos); pos = pos + 1
                    dh = dh - 1

                    if dh == 0 then
                        a = a + 1
                        if a == 0 then a = -128 end
                        col_done = true
                        break
                    end

                    a = a + 1
                    if a == 0 then break end  -- sequence exhausted
                end

                if not col_done then
                    if pos > #data then a = -128; col_done = true
                    else
                        local bv = data:byte(pos); pos = pos + 1
                        a = bv >= 128 and bv - 256 or bv
                    end
                end
            end
        end

        if not col_done then a = -128 end

        -- Render decoded column into pixel array
        -- col pair covers pixel columns (col*2) and (col*2+1)
        for row = 0, h - 1 do
            local bv = col_buf[row + 1] or 0
            local base = row * w + col * 2
            pixels[base + 1] = math.floor(bv / 16)  -- high nibble
            pixels[base + 2] = bv % 16               -- low nibble
        end
    end

    return pixels
end

-- ============================================================================
-- Sprite decoder: uncompressed nibble-pair rows
--
-- Format: w/2 bytes per row; high nibble = left pixel, low nibble = right pixel.
-- ============================================================================

local function decode_sprite_uncompressed(data, offset, w, h)
    local pixels = {}
    for i = 1, w * h do pixels[i] = 0 end

    local row_bytes = math.floor(w / 2)
    local pos = offset
    for row = 0, h - 1 do
        for col = 0, row_bytes - 1 do
            local bv = (pos <= #data) and data:byte(pos) or 0
            pos = pos + 1
            pixels[row * w + col * 2 + 1] = math.floor(bv / 16)
            pixels[row * w + col * 2 + 2] = bv % 16
        end
    end
    return pixels
end

-- ============================================================================
-- Palette reader
--
-- vgaFile1: offset 6 from start = bank 0.
-- Each bank: 32 colors x 3 bytes (R,G,B), 6-bit VGA (0-63) -> 8-bit via *4.
-- ============================================================================

local function read_palette(file1_data, bank, num_colors)
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = 0
        palette[i * 3 + 2] = 0
        palette[i * 3 + 3] = 0
    end

    num_colors = num_colors or 32
    bank = bank or 0
    local pal_off = 7 + bank * 96  -- 1-based: offset 6 = position 7

    local colors_read = 0
    local pos = pal_off
    while colors_read < num_colors and pos + 2 <= #file1_data do
        local r = u8(file1_data, pos)
        local g = u8(file1_data, pos + 1)
        local b = u8(file1_data, pos + 2)
        palette[colors_read * 3 + 1] = math.min(255, r * 4)
        palette[colors_read * 3 + 2] = math.min(255, g * 4)
        palette[colors_read * 3 + 3] = math.min(255, b * 4)
        pos = pos + 3
        colors_read = colors_read + 1
    end

    return palette
end

-- ============================================================================
-- Detection
-- ============================================================================

local function is_simon1(game_path)
    return file_exists(game_path .. "/gamepc")
        or file_exists(game_path .. "/GAMEPC")
end

function engine.detect(game_path)
    return is_simon1(game_path)
end

-- ============================================================================
-- Zone data accessor
-- file_type: 1=file1 (scripts/palette), 2=file2 (images)
-- Slot = zone * 2 + (file_type - 1)
-- ============================================================================

local function get_zone_data(game_path, zone, file_type)
    local gme_names = { "simon.gme", "SIMON.GME" }
    local gme_f = nil
    for _, gme_name in ipairs(gme_names) do
        local path = game_path .. "/" .. gme_name
        if file_exists(path) then
            gme_f = file_open(path)
            if gme_f then break end
        end
    end

    if gme_f then
        local offsets, num = parse_gme(gme_f)
        if offsets then
            local slot = zone * 2 + (file_type - 1)
            if slot < num - 1 and offsets[slot] ~= nil and offsets[slot + 1] ~= nil then
                local off  = offsets[slot]
                local size = offsets[slot + 1] - off
                if size > 0 and size < 50000000 then
                    local data = file_read(gme_f, off, size)
                    file_close(gme_f)
                    return data
                end
            end
        end
        file_close(gme_f)
        return nil
    end

    -- Fallback: loose VGA files NNN1.VGA / NNN2.VGA
    local vga_name = string.format("%.3d%d.VGA", zone, file_type)
    local vf = file_open(game_path .. "/" .. vga_name)
    if not vf then vf = file_open(game_path .. "/" .. vga_name:lower()) end
    if vf then
        local sz   = file_size(vf)
        local data = file_read(vf, 0, sz)
        file_close(vf)
        return data
    end

    return nil
end

-- ============================================================================
-- Resource tree
-- ============================================================================

function engine.get_resources(game_path)
    local max_zone = 0
    local gme_names = { "simon.gme", "SIMON.GME" }
    local gme_f = nil
    for _, gme_name in ipairs(gme_names) do
        local path = game_path .. "/" .. gme_name
        if file_exists(path) then
            gme_f = file_open(path)
            if gme_f then break end
        end
    end

    if gme_f then
        local offsets, num = parse_gme(gme_f)
        file_close(gme_f)
        if offsets then
            max_zone = math.floor(num / 2) - 1
        end
    else
        max_zone = 200
    end

    local resources = {}
    local zones_cat = {
        id = "zones", name = "Simon 1 Zones",
        type = "category", children = {}
    }

    local total_bg = 0
    local total_sp = 0

    for zone = 0, math.min(max_zone, 500) do
        local file2 = get_zone_data(game_path, zone, 2)
        if file2 and #file2 >= 16 then
            local images = parse_image_table(file2)
            if images and #images > 0 then

                local bg_list = {}
                local sp_list = {}

                for _, img in ipairs(images) do
                    if img.is_background then
                        bg_list[#bg_list + 1] = img
                    elseif img.width >= 16 and img.height >= 8 then
                        sp_list[#sp_list + 1] = img
                    end
                end

                if #bg_list > 0 or #sp_list > 0 then
                    local zone_cat = {
                        id   = string.format("zone_%d", zone),
                        name = string.format("Zone %d (%d bg, %d sprites)",
                                    zone, #bg_list, #sp_list),
                        type = "category", children = {}
                    }

                    for _, bg in ipairs(bg_list) do
                        zone_cat.children[#zone_cat.children + 1] = {
                            id   = string.format("bg_%d_%d", zone, bg.index),
                            name = string.format("Background %d (%dx%d)",
                                        bg.index, bg.width, bg.height),
                            type = "image"
                        }
                        total_bg = total_bg + 1
                    end

                    for _, sp in ipairs(sp_list) do
                        local comp = sp.compressed and "RLE" or "raw"
                        zone_cat.children[#zone_cat.children + 1] = {
                            id   = string.format("sp_%d_%d", zone, sp.index),
                            name = string.format("Sprite %d (%dx%d, %s)",
                                        sp.index, sp.width, sp.height, comp),
                            type = "image"
                        }
                        total_sp = total_sp + 1
                    end

                    zones_cat.children[#zones_cat.children + 1] = zone_cat
                end
            end
        end
    end

    zones_cat.name = string.format(
        "Simon 1 Zones (%d backgrounds, %d sprites)", total_bg, total_sp)

    if #zones_cat.children > 0 then
        resources[#resources + 1] = zones_cat
    end

    return resources
end

-- ============================================================================
-- Resource loader
-- ============================================================================

function engine.load_resource(game_path, resource_id)
    local kind, zone_s, idx_s = resource_id:match("^([%a]+)_(%d+)_(%d+)$")
    if kind ~= "bg" and kind ~= "sp" then return nil end
    local zone    = tonumber(zone_s)
    local img_idx = tonumber(idx_s)

    local file2 = get_zone_data(game_path, zone, 2)
    if not file2 then return nil end

    local images = parse_image_table(file2)
    if not images then return nil end

    local target = nil
    for _, img in ipairs(images) do
        if img.index == img_idx then target = img; break end
    end
    if not target then return nil end

    local w = target.width
    local h = target.height

    local file1   = get_zone_data(game_path, zone, 1)
    local palette = file1 and read_palette(file1, 0, 32) or nil

    if not palette then
        palette = {}
        for i = 0, 255 do
            palette[i * 3 + 1] = 0
            palette[i * 3 + 2] = 0
            palette[i * 3 + 3] = 0
        end
        for i = 0, 31 do
            local v = math.floor(i * 255 / 31)
            palette[i * 3 + 1] = v
            palette[i * 3 + 2] = v
            palette[i * 3 + 3] = v
        end
    end

    local pixels
    local desc

    if target.is_background then
        pixels = decode_background(file2, target.offset + 1, w, h)
        desc = string.format("Zone %d background %d - %dx%d (5-bit packed)",
                             zone, img_idx, w, h)

    elseif target.compressed then
        pixels = decode_sprite_compressed(file2, target.offset + 1, w, h)
        desc = string.format("Zone %d sprite %d - %dx%d (column RLE)",
                             zone, img_idx, w, h)

    else
        pixels = decode_sprite_uncompressed(file2, target.offset + 1, w, h)
        desc = string.format("Zone %d sprite %d - %dx%d (uncompressed)",
                             zone, img_idx, w, h)
    end

    if not pixels then return nil end

    local img = image_create_indexed(w, h, pixels, palette)
    return { type = "image", image = img, description = desc }
end

return engine

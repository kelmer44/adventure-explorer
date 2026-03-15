-- ============================================================================
-- Adventure Explorer - Engine Script: Simon the Sorcerer 1 & 2
-- ============================================================================
-- Adventure Soft, 1993/1995. 320x200 (view: 320x134), 32-color backgrounds.
-- VGA file pairs (file1=scripts/palettes, file2=images) in GME archive or loose.
-- 5-bit packed pixel format for backgrounds.
-- ============================================================================

local engine = {}
engine.name        = "Simon the Sorcerer"
engine.id          = "agos"
engine.description = "Simon the Sorcerer 1 & 2 (1993/1995, Adventure Soft)"
engine.version     = "2.0"

-- Binary helpers
local function u8(data, pos) return data:byte(pos) end
local function u16be(data, pos) return data:byte(pos) * 256 + data:byte(pos + 1) end
local function u32be(data, pos)
    return data:byte(pos) * 16777216 + data:byte(pos + 1) * 65536
         + data:byte(pos + 2) * 256 + data:byte(pos + 3)
end
local function u32le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536 + data:byte(pos + 3) * 16777216
end

-- ============================================================================
-- GME archive: u32le offsets table, then zone data
-- ============================================================================

local function parse_gme(f)
    local fsize = file_size(f)
    if fsize < 8 then return nil end

    -- First 4 bytes = table size
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
-- VGA file2 image table: 8-byte entries (BE)
-- u32be dataOffset, u8 flags, u8 height, u16be width
-- ============================================================================

local function parse_image_table(data)
    if not data or #data < 16 then return nil end

    local first_offset = u32be(data, 1)
    -- Validate: first_offset must be divisible by 8, in range 8..file_size
    if first_offset < 8 or first_offset > #data then return nil end
    if first_offset % 8 ~= 0 then return nil end

    local num_images = math.floor(first_offset / 8)
    -- Reject unreasonable table sizes (should be 1-500)
    if num_images > 500 then return nil end

    local images = {}
    local valid_count = 0

    for i = 0, num_images - 1 do
        local base = i * 8 + 1  -- 1-based
        if base + 7 > #data then break end

        local offset = u32be(data, base)
        local flags  = u8(data, base + 4)
        local height = u8(data, base + 5)
        local width  = u16be(data, base + 6)

        -- Strict validation: offset within file, reasonable dimensions
        if offset < #data and width > 0 and width <= 2560
           and height > 0 and height <= 512 then
            valid_count = valid_count + 1
            images[#images + 1] = {
                index    = i,
                offset   = offset,
                flags    = flags,
                width    = width,
                height   = height,
                is_5bit  = (flags % 256 >= 128)  -- bit 7 = 0x80
            }
        end
    end

    -- Reject tables where less than half of entries are valid (probably not an image table)
    if num_images > 0 and valid_count < num_images / 2 then return nil end

    return images
end

-- ============================================================================
-- 5-bit packed decoder: 5 bytes -> 8 pixels (5 bits each, values 0-31)
-- ============================================================================

local function decode_5bit(data, offset, width, height)
    local pixels = {}
    local n = 0
    local pos = offset

    for _ = 1, height do
        for _ = 0, width - 1, 8 do
            if pos + 4 > #data then
                for _ = 1, 8 do n = n + 1; pixels[n] = 0 end
            else
                local a = u8(data, pos + 0)
                local b = u8(data, pos + 1)
                local c = u8(data, pos + 2)
                local d = u8(data, pos + 3)
                local e = u8(data, pos + 4)
                pos = pos + 5

                local bits = a * 16777216 + b * 65536 + c * 256 + d

                n = n + 1; pixels[n] = math.floor(bits / 134217728) % 32  -- >> 27
                n = n + 1; pixels[n] = math.floor(bits / 4194304) % 32    -- >> 22
                n = n + 1; pixels[n] = math.floor(bits / 131072) % 32     -- >> 17
                n = n + 1; pixels[n] = math.floor(bits / 4096) % 32       -- >> 12
                n = n + 1; pixels[n] = math.floor(bits / 128) % 32        -- >> 7
                n = n + 1; pixels[n] = math.floor(bits / 4) % 32          -- >> 2

                local bits2 = (bits % 4) * 256 + e
                n = n + 1; pixels[n] = math.floor(bits2 / 32) % 32        -- >> 5
                n = n + 1; pixels[n] = bits2 % 32                         -- & 0x1F
            end
        end
    end

    return pixels
end

-- ============================================================================
-- RLE column decoder (scrolling backgrounds, Simon 2, width > 320)
-- u32be self-relative offsets per 8px column strip
-- ============================================================================

local function decode_rle_columns(data, offset, width, height)
    local pixels = {}
    local total = width * height
    for i = 1, total do pixels[i] = 0 end

    local num_strips = math.floor(width / 8)

    for strip = 0, num_strips - 1 do
        local ptr_pos = offset + strip * 4
        if ptr_pos + 3 > #data then break end
        local rel_off = u32be(data, ptr_pos)
        local col_data_pos = ptr_pos + rel_off

        if col_data_pos < 1 or col_data_pos > #data then break end

        local pos = col_data_pos
        local dx = strip * 8
        local dy = 0
        local cols_left = 8

        while cols_left > 0 and pos <= #data do
            local reps = u8(data, pos); pos = pos + 1
            if reps > 127 then reps = reps - 256 end  -- signed

            if reps >= 0 then
                if pos > #data then break end
                local color = u8(data, pos); pos = pos + 1
                for _ = 0, reps do
                    if dy < height then
                        pixels[dy * width + dx + 1] = color
                    end
                    dy = dy + 1
                    if dy >= height then
                        dy = 0; dx = dx + 1
                        cols_left = cols_left - 1
                        if cols_left == 0 then break end
                    end
                end
            else
                for _ = 0, -reps - 1 do
                    if pos > #data then break end
                    local color = u8(data, pos); pos = pos + 1
                    if dy < height then
                        pixels[dy * width + dx + 1] = color
                    end
                    dy = dy + 1
                    if dy >= height then
                        dy = 0; dx = dx + 1
                        cols_left = cols_left - 1
                        if cols_left == 0 then break end
                    end
                end
            end
        end
    end

    return pixels
end

-- ============================================================================
-- Read palette from VGA file1: offset +6, 96-byte banks (32 colors x 3, 6-bit)
-- For 256-color (Simon 2 scrolling), read multiple banks to fill palette
-- ============================================================================

local function read_palette(file1_data, bank, num_colors)
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
    end

    num_colors = num_colors or 32
    local pal_off = 7 + (bank or 0) * 96  -- 1-based, offset 6 = byte 7

    -- Read as many colors as available from file1 starting at pal_off
    local colors_read = 0
    local pos = pal_off
    while colors_read < num_colors and pos + 2 <= #file1_data do
        local r = u8(file1_data, pos + 0)
        local g = u8(file1_data, pos + 1)
        local b = u8(file1_data, pos + 2)
        -- 6-bit VGA (0-63) to 8-bit: val * 255 / 63
        palette[colors_read * 3 + 1] = math.floor(r * 255 / 63 + 0.5)
        palette[colors_read * 3 + 2] = math.floor(g * 255 / 63 + 0.5)
        palette[colors_read * 3 + 3] = math.floor(b * 255 / 63 + 0.5)
        pos = pos + 3
        colors_read = colors_read + 1
    end

    return palette
end

-- ============================================================================
-- Detection
-- ============================================================================

local function is_simon1(game_path)
    return file_exists(game_path .. "/gamepc") or file_exists(game_path .. "/GAMEPC")
end

local function is_simon2(game_path)
    return (file_exists(game_path .. "/game32") or file_exists(game_path .. "/GAME32")
         or file_exists(game_path .. "/gsptr30") or file_exists(game_path .. "/GSPTR30"))
       and (file_exists(game_path .. "/simon2.gme") or file_exists(game_path .. "/SIMON2.GME"))
end

function engine.detect(game_path)
    return is_simon1(game_path) or is_simon2(game_path)
end

-- ============================================================================
-- Get zone data from GME or loose files
-- ============================================================================

local function get_zone_data(game_path, zone, file_type)
    -- file_type: 1=scripts/palettes, 2=images
    local is_s2 = is_simon2(game_path)
    local gme_name = is_s2 and "simon2.gme" or "simon.gme"

    local gme_f = file_open(game_path .. "/" .. gme_name)
    if gme_f then
        local offsets, num = parse_gme(gme_f)
        if offsets then
            local slot = zone * 2 + (file_type - 1)
            if slot < num - 1 and offsets[slot] and offsets[slot + 1] then
                local off = offsets[slot]
                local size = offsets[slot + 1] - off
                if size > 0 and size < 50000000 then
                    local data = file_read(gme_f, off, size)
                    file_close(gme_f)
                    return data
                end
            end
        end
        file_close(gme_f)
    end

    -- Try loose VGA files: NNN1.VGA / NNN2.VGA
    local vga_name = string.format("%.3d%d.VGA", zone, file_type)
    local vf = file_open(game_path .. "/" .. vga_name)
    if not vf then vf = file_open(game_path .. "/" .. vga_name:lower()) end
    if vf then
        local sz = file_size(vf)
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
    local is_s2 = is_simon2(game_path)
    local game_label = is_s2 and "Simon 2" or "Simon 1"

    -- Determine number of zones from GME or loose files
    local max_zone = 0
    local gme_name = is_s2 and "simon2.gme" or "simon.gme"
    local gme_f = file_open(game_path .. "/" .. gme_name)

    if gme_f then
        local offsets, num = parse_gme(gme_f)
        file_close(gme_f)
        if offsets then
            max_zone = math.floor(num / 2) - 1
        end
    else
        -- Count loose VGA files
        local files = list_files(game_path)
        if files then
            for _, fname in ipairs(files) do
                local z = fname:match("(%d+)2%.[Vv][Gg][Aa]$")
                if z then
                    local zn = tonumber(z)
                    if zn and zn > max_zone then max_zone = zn end
                end
            end
        end
    end

    if max_zone == 0 then
        -- No GME and no loose files found; probe zones directly up to 200
        max_zone = 200
    end

    -- Scan zones for backgrounds
    local resources = {}
    local zones_cat = {
        id = "zones", name = string.format("%s Zones", game_label),
        type = "category", children = {}
    }

    local found = 0
    for zone = 0, math.min(max_zone, 500) do
        local file2 = get_zone_data(game_path, zone, 2)
        if file2 and #file2 >= 8 then
            local images = parse_image_table(file2)
            if images and #images > 0 then
                -- Filter for likely backgrounds
                local bgs = {}
                for _, img in ipairs(images) do
                    if img.width >= 320 and img.height >= 100
                       and img.width <= 2560 and img.height <= 400 then
                        bgs[#bgs + 1] = img
                    end
                end

                if #bgs > 0 then
                    found = found + 1
                    local zone_cat = {
                        id = string.format("zone_%d", zone),
                        name = string.format("Zone %d (%d bg)", zone, #bgs),
                        type = "category", children = {}
                    }
                    for _, bg in ipairs(bgs) do
                        zone_cat.children[#zone_cat.children + 1] = {
                            id = string.format("bg_%d_%d", zone, bg.index),
                            name = string.format("Image %d (%dx%d)", bg.index, bg.width, bg.height),
                            type = "image"
                        }
                    end
                    zones_cat.children[#zones_cat.children + 1] = zone_cat
                end
            end
        end
    end

    zones_cat.name = string.format("%s Zones (%d with backgrounds)", game_label, found)
    if found > 0 then resources[#resources + 1] = zones_cat end

    return resources
end

-- ============================================================================
-- Resource loading
-- ============================================================================

function engine.load_resource(game_path, resource_id)
    local zone, img_idx = resource_id:match("^bg_(%d+)_(%d+)$")
    if not zone or not img_idx then return nil end
    zone = tonumber(zone); img_idx = tonumber(img_idx)

    -- Load file2 (images)
    local file2 = get_zone_data(game_path, zone, 2)
    if not file2 then return nil end

    local images = parse_image_table(file2)
    if not images then return nil end

    -- Find target image
    local target = nil
    for _, img in ipairs(images) do
        if img.index == img_idx then target = img; break end
    end
    if not target then return nil end

    -- Load file1 (palette)
    local file1 = get_zone_data(game_path, zone, 1)
    -- For scrolling (>320px) backgrounds, try to read 256 colors
    local num_colors = (target.width > 320 and not target.is_5bit) and 256 or 32
    local palette = file1 and read_palette(file1, 0, num_colors) or nil

    if not palette then
        -- Grayscale fallback for 32 colors
        palette = {}
        for i = 0, 255 do
            palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
        end
        for i = 0, 31 do
            local v = math.floor(i * 255 / 31)
            palette[i * 3 + 1] = v; palette[i * 3 + 2] = v; palette[i * 3 + 3] = v
        end
    end

    local w = target.width
    local h = target.height
    local pixels

    if target.is_5bit then
        if w > 320 then
            -- Scrolling background: RLE columns
            pixels = decode_rle_columns(file2, target.offset + 1, w, h)
        else
            -- Standard 5-bit packed
            pixels = decode_5bit(file2, target.offset + 1, w, h)
        end
    else
        -- Try raw 8-bit indexed
        pixels = {}
        local total = w * h
        for i = 1, total do
            local pos = target.offset + i
            pixels[i] = (pos >= 1 and pos <= #file2) and u8(file2, pos) or 0
        end
    end

    if not pixels then return nil end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image", image = img,
        description = string.format("Zone %d, Image %d - %dx%d, 32 colors (%s)",
            zone, img_idx, w, h,
            target.is_5bit and "5-bit packed" or "raw")
    }
end

return engine

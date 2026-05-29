-- ============================================================================
-- Adventure Explorer - Engine Script: Discworld 1 & 2 (Tinsel Engine)
-- ============================================================================
-- Psygnosis/Perfect Entertainment. Handle-based resource system.
-- DW1: 4x4 block-tiled backgrounds, index (20-byte records), shift 23.
-- DW2: raw 8bpp backgrounds, index (24-byte records), shift 25.
-- Both use an `index` file + data files (.scn/.gra).
-- Verified against ScummVM engines/tinsel/ source code.
-- ============================================================================

local engine = {}
engine.name        = "Discworld"
engine.id          = "tinsel"
engine.description = "Discworld 1 & 2 (1995/1996, Perfect Entertainment)"
engine.version     = "2.0"

-- Binary helpers
local function u8(data, pos)   return data:byte(pos) end
local function i16le(data, pos)
    local v = data:byte(pos) + data:byte(pos + 1) * 256
    return v < 32768 and v or v - 65536
end
local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end
local function u32le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536 + data:byte(pos + 3) * 16777216
end

-- ============================================================================
-- Constants
-- ============================================================================

local CHUNK_IMAGE = string.char(0x06, 0x00, 0x34, 0x33)  -- 0x33340006 LE
local C16_FLAG_MASK = 0xC000  -- upper 2 bits of imgHeight

-- ============================================================================
-- Detection
-- ============================================================================

local function is_dw2(game_path)
    return file_exists(game_path .. "/dw2.scn") or file_exists(game_path .. "/DW2.SCN")
end

local function is_dw1(game_path)
    return file_exists(game_path .. "/dw.scn") or file_exists(game_path .. "/DW.SCN")
        or file_exists(game_path .. "/dw.gra") or file_exists(game_path .. "/DW.GRA")
end

function engine.detect(game_path)
    if not (file_exists(game_path .. "/index") or file_exists(game_path .. "/INDEX")) then
        return false
    end
    return is_dw2(game_path) or is_dw1(game_path)
end

-- ============================================================================
-- Index file parser
-- DW1: 20-byte records, DW2: 24-byte records
-- Each record: 12-byte filename + u32le filesize (lower 24 bits)
-- ============================================================================

local function parse_index(game_path, dw2)
    local idx_path = game_path .. "/index"
    if not file_exists(idx_path) then
        idx_path = game_path .. "/INDEX"
    end
    local f = file_open(idx_path)
    if not f then return nil end

    local fsize = file_size(f)
    local record_size = dw2 and 24 or 20

    if fsize % record_size ~= 0 then
        record_size = (record_size == 24) and 20 or 24
        if fsize % record_size ~= 0 then
            file_close(f)
            return nil
        end
    end

    local num_handles = math.floor(fsize / record_size)
    local raw = file_read(f, 0, fsize)
    file_close(f)
    if not raw then return nil end

    local handles = {}
    for i = 0, num_handles - 1 do
        local base = i * record_size + 1

        local name = ""
        for c = 0, 11 do
            local b = raw:byte(base + c)
            if not b or b == 0 then break end
            name = name .. string.char(b)
        end

        local filesize_raw = u32le(raw, base + 12)
        local filesize = filesize_raw % 16777216

        handles[i] = {
            name     = name,
            filesize = filesize,
            index    = i
        }
    end

    return handles, num_handles
end

-- ============================================================================
-- SCNHANDLE resolver
-- Returns (file_data, byte_offset) for given scnhandle
-- ============================================================================

local file_cache = {}

local function resolve_handle(game_path, handles, scnhandle, dw2)
    if scnhandle == 0 then return nil, 0 end

    local shift = dw2 and 25 or 23
    local handle_idx = math.floor(scnhandle / (2 ^ shift))
    local byte_offset = scnhandle % (2 ^ shift)

    local entry = handles[handle_idx]
    if not entry or #entry.name == 0 then return nil, 0 end

    if not file_cache[entry.name] then
        local fpath = game_path .. "/" .. entry.name
        if not file_exists(fpath) then
            -- Try case variation
            local upper = entry.name:upper()
            local lower = entry.name:lower()
            if file_exists(game_path .. "/" .. upper) then
                fpath = game_path .. "/" .. upper
            elseif file_exists(game_path .. "/" .. lower) then
                fpath = game_path .. "/" .. lower
            else
                return nil, 0
            end
        end
        local f = file_open(fpath)
        if not f then return nil, 0 end
        local data = file_read(f, 0, file_size(f))
        file_close(f)
        file_cache[entry.name] = data
    end

    return file_cache[entry.name], byte_offset
end

-- ============================================================================
-- Scan data file for CHUNK_IMAGE (0x33340006) markers
-- Returns list of {pos_1based, width, height, anioffX, anioffY, hImgBits, hImgPal}
-- ============================================================================

local function scan_for_images(data)
    local results = {}
    local start = 1

    while true do
        local found = data:find(CHUNK_IMAGE, start, true)
        if not found then break end

        -- IMAGE struct starts 8 bytes after chunk marker (past {type, next_offset})
        local img_pos = found + 8  -- 1-based position of IMAGE struct

        if img_pos + 15 <= #data then
            local raw_w = i16le(data, img_pos)
            local raw_h = u16le(data, img_pos + 2)
            local w = raw_w
            local h = raw_h % 16384  -- strip C16 flags (& 0x3FFF)

            if w > 0 and h > 0 and w <= 1024 and h <= 768 then
                local hImgBits = u32le(data, img_pos + 8)
                local hImgPal  = u32le(data, img_pos + 12)

                results[#results + 1] = {
                    pos_1based = img_pos,
                    width      = w,
                    height     = h,
                    raw_height = raw_h,
                    anioffX    = i16le(data, img_pos + 4),
                    anioffY    = i16le(data, img_pos + 6),
                    hImgBits   = hImgBits,
                    hImgPal    = hImgPal
                }
            end
        end

        start = found + 4  -- advance past this match
    end

    return results
end

-- ============================================================================
-- Read PALETTE from resolved position
-- Format: int32le numColors, uint32le[numColors] COLORREF (0x00BBGGRR)
-- ============================================================================

local function read_palette(data, pos)
    if pos + 3 > #data then return nil end
    local num_colors = u32le(data, pos)
    if num_colors < 1 or num_colors > 256 then return nil end

    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
    end

    -- FGND_DAC_INDEX = 1: the first palette color is placed at DAC index 1.
    -- Pixel value 0 = DAC 0 = transparent background black (already zeroed).
    -- Pixel value 1 = DAC 1 = palette color 0, pixel value N = palette color N-1.
    -- So write color i at palette slot (i+1) to match DAC layout.
    for i = 0, num_colors - 1 do
        local p = pos + 4 + i * 4
        if p + 3 > #data then break end
        local colorref = u32le(data, p)
        palette[(i + 1) * 3 + 1] = colorref % 256                        -- R
        palette[(i + 1) * 3 + 2] = math.floor(colorref / 256) % 256      -- G
        palette[(i + 1) * 3 + 3] = math.floor(colorref / 65536) % 256    -- B
    end

    return palette
end

-- ============================================================================
-- Decode DW1 4×4 block-tiled background
-- hImgBits resolves to (file_data, tile_map_offset)
-- charBase offset is at file_data + 0x10 (relative to file base)
-- transOffset is at file_data + 0x14
-- Tile map is an array of int16le indices at tile_map_offset
-- Each tile = 16 bytes (4×4 pixels, 8bpp) in the charBase block
-- ============================================================================

local function decode_dw1_background(bits_data, bits_off, img_w, img_h)
    -- charBase and transOffset are at offset 0x10 and 0x14 from the file base
    -- (per ScummVM: p + READ_32(p + 0x10), p + READ_32(p + 0x14))
    if #bits_data < 0x18 then return nil end

    local char_base_offset = u32le(bits_data, 1 + 0x10)  -- position 17 (1-based)
    local trans_offset = u32le(bits_data, 1 + 0x14)       -- position 21 (1-based)

    -- Tile map starts at bits_off within the file
    local tile_map_pos = bits_off + 1  -- 1-based

    -- Use ceiling division (matches ScummVM: (width + 3) >> 2)
    -- so non-multiples-of-4 get the extra partial tile column/row
    local tiles_w = math.floor((img_w + 3) / 4)
    local tiles_h = math.floor((img_h + 3) / 4)
    local num_tiles = tiles_w * tiles_h

    if tile_map_pos + num_tiles * 2 - 1 > #bits_data then return nil end

    -- Build output pixels
    local pixels = {}
    local total = img_w * img_h
    for i = 1, total do pixels[i] = 0 end

    for t = 0, num_tiles - 1 do
        local tile_idx = i16le(bits_data, tile_map_pos + t * 2)
        local tx = t % tiles_w
        local ty = math.floor(t / tiles_w)

        if tile_idx >= 0 then
            -- Opaque tile: charBase + (indexVal << 4)
            local block_base = char_base_offset + tile_idx * 16 + 1  -- 1-based

            for py = 0, 3 do
                for px = 0, 3 do
                    local src = block_base + py * 4 + px
                    local dst = (ty * 4 + py) * img_w + (tx * 4 + px) + 1
                    if dst >= 1 and dst <= total and src >= 1 and src <= #bits_data then
                        pixels[dst] = u8(bits_data, src)
                    end
                end
            end
        else
            -- Transparent tile: indexVal &= 0x7FFF
            local unsigned_idx = (65536 + tile_idx) % 32768
            if unsigned_idx > 0 then
                -- charBase + ((transOffset + indexVal) << 4)
                local block_base = char_base_offset + (trans_offset + unsigned_idx) * 16 + 1

                for py = 0, 3 do
                    for px = 0, 3 do
                        local src = block_base + py * 4 + px
                        local dst = (ty * 4 + py) * img_w + (tx * 4 + px) + 1
                        if dst >= 1 and dst <= total and src >= 1 and src <= #bits_data then
                            local pixel = u8(bits_data, src)
                            if pixel ~= 0 then
                                pixels[dst] = pixel
                            end
                        end
                    end
                end
            end
            -- unsigned_idx == 0: fully transparent, pixels already 0
        end
    end

    return pixels
end

-- ============================================================================
-- Resource tree
-- ============================================================================

function engine.get_resources(game_path)
    file_cache = {}

    local dw2 = is_dw2(game_path)
    local game_label = dw2 and "Discworld 2" or "Discworld 1"

    local handles, num = parse_index(game_path, dw2)
    if not handles then return {} end

    -- Collect unique data files from index
    local data_files = {}
    local seen = {}
    for i = 0, num - 1 do
        local h = handles[i]
        if h and #h.name > 0 and not seen[h.name:lower()] then
            seen[h.name:lower()] = true
            data_files[#data_files + 1] = { name = h.name, index = i }
        end
    end

    -- For DW2: also scan .CDP files (not in INDEX but contain graphics data)
    if dw2 then
        local all_files = list_files(game_path)
        if all_files then
            for _, fname in ipairs(all_files) do
                if fname:upper():match("%.CDP$") and not seen[fname:lower()] then
                    seen[fname:lower()] = true
                    data_files[#data_files + 1] = { name = fname, index = -1 }
                end
            end
        end
    end

    -- Thresholds for classifying backgrounds vs sprites
    local bg_min_w = dw2 and 100 or 300
    local bg_min_h = dw2 and 80  or 100
    local sp_min_w = 8
    local sp_min_h = 8

    local resources = {}

    for _, df in ipairs(data_files) do
        local fpath = game_path .. "/" .. df.name
        if not file_exists(fpath) then
            fpath = game_path .. "/" .. df.name:upper()
            if not file_exists(fpath) then
                fpath = game_path .. "/" .. df.name:lower()
            end
        end

        local f = file_open(fpath)
        if f then
            local fsize = file_size(f)
            if fsize > 0 and fsize < 200000000 then
                local data = file_read(f, 0, fsize)
                file_close(f)

                if data then
                    file_cache[df.name] = data

                    -- Scan for IMAGE chunks
                    local images = scan_for_images(data)

                    local bg_images = {}
                    local sp_images = {}
                    for _, img in ipairs(images) do
                        if img.hImgBits ~= 0 then
                            if img.width >= bg_min_w and img.height >= bg_min_h then
                                bg_images[#bg_images + 1] = img
                            elseif img.width >= sp_min_w and img.height >= sp_min_h then
                                sp_images[#sp_images + 1] = img
                            end
                        end
                    end

                    if #bg_images > 0 then
                        local cat = {
                            id = "file_" .. df.name,
                            name = string.format("%s - %s (%d backgrounds)",
                                game_label, df.name, #bg_images),
                            type = "category", children = {}
                        }
                        for _, img in ipairs(bg_images) do
                            cat.children[#cat.children + 1] = {
                                id = string.format("img_%s_%d", df.name, img.pos_1based),
                                name = string.format("%dx%d (bits=0x%X, pal=0x%X)",
                                    img.width, img.height, img.hImgBits, img.hImgPal),
                                type = "image"
                            }
                        end
                        resources[#resources + 1] = cat
                    end

                    if #sp_images > 0 then
                        local cat = {
                            id = "sprites_" .. df.name,
                            name = string.format("%s - %s sprites (%d)",
                                game_label, df.name, #sp_images),
                            type = "category", children = {}
                        }
                        for _, img in ipairs(sp_images) do
                            cat.children[#cat.children + 1] = {
                                id = string.format("img_%s_%d", df.name, img.pos_1based),
                                name = string.format("%dx%d (bits=0x%X, pal=0x%X)",
                                    img.width, img.height, img.hImgBits, img.hImgPal),
                                type = "image"
                            }
                        end
                        resources[#resources + 1] = cat
                    end
                end
            else
                file_close(f)
            end
        end
    end

    return resources
end

-- ============================================================================
-- Resource loading
-- ============================================================================

function engine.load_resource(game_path, resource_id, palette_id)
    local file_name, pos_str = resource_id:match("^img_(.+)_(%d+)$")
    if not file_name or not pos_str then return nil end
    local img_pos = tonumber(pos_str)  -- 1-based position of IMAGE struct

    local dw2 = is_dw2(game_path)
    local handles, num = parse_index(game_path, dw2)
    if not handles then return nil end

    -- Load the data file
    if not file_cache[file_name] then
        local fpath = game_path .. "/" .. file_name
        if not file_exists(fpath) then
            fpath = game_path .. "/" .. file_name:upper()
            if not file_exists(fpath) then
                fpath = game_path .. "/" .. file_name:lower()
            end
        end
        local f = file_open(fpath)
        if not f then return nil end
        local data = file_read(f, 0, file_size(f))
        file_close(f)
        if not data then return nil end
        file_cache[file_name] = data
    end

    local data = file_cache[file_name]
    if img_pos + 15 > #data then return nil end

    -- Read IMAGE struct
    local w = i16le(data, img_pos)
    local raw_h = u16le(data, img_pos + 2)
    local h = raw_h % 16384  -- strip C16 flags
    local hImgBits = u32le(data, img_pos + 8)
    local hImgPal  = u32le(data, img_pos + 12)

    if w <= 0 or h <= 0 then
        return { type = "text", text = string.format("Invalid image dimensions: %dx%d", w, h) }
    end

    local total = w * h

    -- Resolve palette
    local palette
    if hImgPal ~= 0 then
        local pal_data, pal_off = resolve_handle(game_path, handles, hImgPal, dw2)
        if pal_data then
            palette = read_palette(pal_data, pal_off + 1)
        end
    end

    if not palette then
        -- Grayscale fallback
        palette = {}
        for i = 0, 255 do
            palette[i * 3 + 1] = i; palette[i * 3 + 2] = i; palette[i * 3 + 3] = i
        end
    end

    -- Resolve pixel data
    local pixels
    if hImgBits ~= 0 then
        local bits_data, bits_off = resolve_handle(game_path, handles, hImgBits, dw2)
        if bits_data then
            if dw2 then
                -- DW2: raw 8bpp pixels directly at resolved position
                pixels = {}
                local start = bits_off + 1
                for i = 1, total do
                    pixels[i] = (start + i - 1 <= #bits_data) and u8(bits_data, start + i - 1) or 0
                end
            else
                -- DW1: 4×4 block-tiled system
                -- charBase at file_base+0x10, transOffset at file_base+0x14
                -- tile map at bits_off
                pixels = decode_dw1_background(bits_data, bits_off, w, h)

                if not pixels then
                    -- Fallback: try as raw 8bpp (might work for some resources)
                    pixels = {}
                    local start = bits_off + 1
                    for i = 1, total do
                        pixels[i] = (start + i - 1 <= #bits_data) and u8(bits_data, start + i - 1) or 0
                    end
                end
            end
        end
    end

    if not pixels then
        return { type = "text", text = string.format("Cannot resolve bitmap data for %dx%d image", w, h) }
    end

    local result_img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image", image = result_img,
        description = string.format("%s - %dx%d, 256 colors",
            dw2 and "Discworld 2" or "Discworld 1", w, h)
    }
end

return engine

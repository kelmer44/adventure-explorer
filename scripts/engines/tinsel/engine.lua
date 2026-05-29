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

        -- Chunk header: type (4 bytes at found), next_chunk_abs_offset (4 bytes at found+4).
        -- next_chunk_abs_offset is a 0-based absolute file offset; the chunk data begins at
        -- found+8 (1-based). In Lua's 1-based indexing the last byte of this chunk's data
        -- is at position next_abs (since 0-based offset next_abs-1 = 1-based next_abs).
        local next_abs = u32le(data, found + 4)  -- 0-based absolute offset to next chunk
        local chunk_end = (next_abs > 0) and next_abs or #data  -- last data byte, 1-based

        -- Iterate ALL 16-byte IMAGE structs packed consecutively in this chunk block.
        local img_pos = found + 8  -- 1-based, start of first IMAGE struct
        while img_pos + 15 <= chunk_end do
            local w     = i16le(data, img_pos)
            local raw_h = u16le(data, img_pos + 2)
            local h     = raw_h % 16384  -- strip C16 flags (bits 14-15)

            if w > 0 and h > 0 and w <= 2000 and h <= 2000 then
                local hImgBits = u32le(data, img_pos + 8)
                local hImgPal  = u32le(data, img_pos + 12)
                if hImgBits ~= 0 then
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
            img_pos = img_pos + 16
        end

        -- Advance past this chunk to avoid re-scanning its data as a new marker
        start = (next_abs > 0) and (next_abs + 1) or (#data + 1)
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
-- Decode DW2 RLE sprite (t2WrtNonZero format)
-- Row-by-row RLE: opcode byte per run.
--   bit7=1 → run-length: count = opcode & 0x7F, next byte = color value
--   bit7=0 → raw dump: opcode = count, read 'count' raw pixel bytes
-- Pixel value 0 = transparent (left as 0). Non-zero = DAC index (matches
-- our 1-indexed palette after the FGND_DAC_INDEX fix).
-- ============================================================================

local function decode_dw2_sprite(data, offset, w, h)
    local pixels = {}
    local total = w * h
    for i = 1, total do pixels[i] = 0 end

    local src = offset + 1  -- convert to 1-based
    for y = 0, h - 1 do
        local x = 0
        while x < w do
            if src > #data then break end
            local opcode = u8(data, src); src = src + 1
            if opcode >= 128 then
                -- RLE run
                local count = opcode - 128
                if src > #data then break end
                local color = u8(data, src); src = src + 1
                for _ = 1, count do
                    if x >= w then break end
                    local dst = y * w + x + 1
                    if dst <= total then pixels[dst] = color end
                    x = x + 1
                end
            else
                -- Raw dump
                local count = opcode
                for _ = 1, count do
                    if src > #data then break end
                    local pixel = u8(data, src); src = src + 1
                    if x < w then
                        local dst = y * w + x + 1
                        if dst <= total then pixels[dst] = pixel end
                        x = x + 1
                    end
                end
            end
        end
    end

    return pixels
end

-- ============================================================================
-- Find palette from a named SCN file (used to supply palette to CDP sprites)
-- Returns a palette table (or nil). Tries each IMAGE in the SCN that has a
-- non-zero hImgPal resolvable via the INDEX.
-- ============================================================================

local function find_palette_in_scn(game_path, handles, dw2, scn_name)
    local canon = scn_name:upper()
    local scn_data = file_cache[canon] or file_cache[scn_name]
    if not scn_data then
        local fpath = game_path .. "/" .. canon
        if not file_exists(fpath) then
            fpath = game_path .. "/" .. scn_name:lower()
            if not file_exists(fpath) then return nil end
        end
        local f = file_open(fpath)
        if not f then return nil end
        scn_data = file_read(f, 0, file_size(f))
        file_close(f)
        if not scn_data then return nil end
        file_cache[canon] = scn_data
    end

    local images = scan_for_images(scn_data)
    for _, img in ipairs(images) do
        if img.hImgPal ~= 0 then
            local pal_data, pal_off = resolve_handle(game_path, handles, img.hImgPal, dw2)
            if pal_data then
                local pal = read_palette(pal_data, pal_off + 1)
                if pal then return pal end
            end
        end
    end
    return nil
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
-- Single-frame decoder (shared by load_resource and animation handler)
-- ============================================================================

local function load_file_to_cache(game_path, file_name)
    if file_cache[file_name] then return file_cache[file_name] end
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
    return data
end

local function decode_one_frame(game_path, handles, dw2, file_name, img_pos)
    local data = load_file_to_cache(game_path, file_name)
    if not data then return nil end
    if img_pos + 15 > #data then return nil end

    local w        = i16le(data, img_pos)
    local raw_h    = u16le(data, img_pos + 2)
    local h        = raw_h % 16384
    local c16      = math.floor(raw_h / 16384) % 4
    local hImgBits = u32le(data, img_pos + 8)
    local hImgPal  = u32le(data, img_pos + 12)

    if w <= 0 or h <= 0 or hImgBits == 0 then return nil end

    local is_cdp = dw2 and file_name:upper():match("%.CDP$") ~= nil
    local DW2_OFFSET_MOD = 2 ^ 25

    -- Resolve palette
    local palette
    if is_cdp then
        local scn_name = file_name:upper():sub(1, -4) .. "SCN"
        palette = find_palette_in_scn(game_path, handles, dw2, scn_name)
        if not palette then
            palette = find_palette_in_scn(game_path, handles, dw2, "OBJECTS.SCN")
        end
    elseif hImgPal ~= 0 then
        local pal_data, pal_off = resolve_handle(game_path, handles, hImgPal, dw2)
        if pal_data then
            palette = read_palette(pal_data, pal_off + 1)
        end
    end

    if not palette then
        palette = {}
        for i = 0, 255 do
            palette[i*3+1] = i; palette[i*3+2] = i; palette[i*3+3] = i
        end
    end

    -- Resolve pixel data
    local bits_data, bits_off
    if is_cdp then
        bits_data = data
        bits_off  = hImgBits % DW2_OFFSET_MOD
    else
        bits_data, bits_off = resolve_handle(game_path, handles, hImgBits, dw2)
    end
    if not bits_data then return nil end

    local pixels
    if dw2 then
        if c16 ~= 0 then
            pixels = decode_dw2_sprite(bits_data, bits_off, w, h)
        else
            pixels = {}
            local start = bits_off + 1
            local total = w * h
            for i = 1, total do
                pixels[i] = (start + i - 1 <= #bits_data) and u8(bits_data, start + i - 1) or 0
            end
        end
    else
        pixels = decode_dw1_background(bits_data, bits_off, w, h)
        if not pixels then
            pixels = {}
            local start = bits_off + 1
            local total = w * h
            for i = 1, total do
                pixels[i] = (start + i - 1 <= #bits_data) and u8(bits_data, start + i - 1) or 0
            end
        end
    end

    if not pixels then return nil end
    return image_create_indexed(w, h, pixels, palette)
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

    local resources = {}
    -- For DW1 (and DW2 SCN small images): collected cross-file for animation grouping
    local all_bg  = {}  -- { id, name } background image entries
    local all_scn_sp = {}  -- { fname, pos, w, h } for DW1 cross-file sprite grouping

    for _, df in ipairs(data_files) do
        local data = load_file_to_cache(game_path, df.name)
        if data then
            local images = scan_for_images(data)

            -- DW2 CDP: all images are character sprites; never backgrounds
            local is_cdp = dw2 and df.name:upper():match("%.CDP$") ~= nil

            local bg_images = {}
            local sp_images = {}
            for _, img in ipairs(images) do
                if img.hImgBits ~= 0 and img.width >= 4 and img.height >= 4 then
                    if is_cdp then
                        -- CDP files hold character sprites exclusively
                        sp_images[#sp_images + 1] = img
                    elseif dw2 then
                        -- DW2: c16==0 (raw 8bpp WrtAll) + wide → background;
                        -- c16!=0 (t2WrtNonZero RLE) → sprite
                        local c16 = math.floor(img.raw_height / 16384) % 4
                        if c16 == 0 and img.width >= 300 then
                            bg_images[#bg_images + 1] = img
                        elseif img.width >= 4 and img.height >= 4 then
                            sp_images[#sp_images + 1] = img
                        end
                    elseif img.width >= 300 and img.height >= 80 then
                        -- DW1: use size heuristic (no reliable c16 distinction)
                        bg_images[#bg_images + 1] = img
                    elseif img.width >= 4 and img.height >= 4 then
                        sp_images[#sp_images + 1] = img
                    end
                end
            end

            -- Backgrounds: group same-dimension images within the same file as animation frames.
            -- This handles wide scrolling backgrounds stored as multiple layers.
            if #bg_images > 0 then
                local bg_groups = {}
                local bg_order  = {}
                for _, img in ipairs(bg_images) do
                    local key = img.width .. "x" .. img.height
                    if not bg_groups[key] then
                        bg_groups[key] = {}
                        bg_order[#bg_order + 1] = key
                    end
                    bg_groups[key][#bg_groups[key] + 1] = img
                end
                for _, key in ipairs(bg_order) do
                    local group = bg_groups[key]
                    local first = group[1]
                    local entry
                    if #group == 1 then
                        entry = {
                            id   = string.format("img_%s_%d", df.name, first.pos_1based),
                            name = string.format("%s - %dx%d", df.name, first.width, first.height),
                        }
                    else
                        local parts = {}
                        for _, img in ipairs(group) do
                            parts[#parts + 1] = df.name .. ":" .. img.pos_1based
                        end
                        entry = {
                            id   = "anim_" .. table.concat(parts, "|"),
                            name = string.format("%s - %dx%d \xc3\x97 %d layers",
                                df.name, first.width, first.height, #group),
                        }
                    end
                    all_bg[#all_bg + 1] = entry
                end
            end

            if is_cdp then
                -- DW2 CDP: group images by (w×h) within the same file → animation frames
                local groups  = {}
                local order   = {}
                for _, img in ipairs(sp_images) do
                    local key = img.width .. "x" .. img.height
                    if not groups[key] then
                        groups[key] = {}
                        order[#order + 1] = key
                    end
                    groups[key][#groups[key] + 1] = img
                end

                local children = {}
                for _, key in ipairs(order) do
                    local group = groups[key]
                    local first = group[1]
                    if #group == 1 then
                        children[#children + 1] = {
                            id   = string.format("img_%s_%d", df.name, first.pos_1based),
                            name = string.format("%dx%d", first.width, first.height),
                            type = "image",
                        }
                    else
                        local parts = {}
                        for _, img in ipairs(group) do
                            parts[#parts + 1] = df.name .. ":" .. img.pos_1based
                        end
                        children[#children + 1] = {
                            id   = "anim_" .. table.concat(parts, "|"),
                            name = string.format("%dx%d \xc3\x97 %d frames",
                                first.width, first.height, #group),
                            type = "animation",
                        }
                    end
                end

                if #children > 0 then
                    resources[#resources + 1] = {
                        id       = "sprites_" .. df.name,
                        name     = string.format("DW2 - %s (%d sprites)", df.name, #sp_images),
                        type     = "category",
                        children = children,
                    }
                end
            else
                -- DW1 or DW2 SCN sprites: collect for cross-file animation grouping
                for _, img in ipairs(sp_images) do
                    all_scn_sp[#all_scn_sp + 1] = {
                        fname = df.name, pos = img.pos_1based,
                        w = img.width,   h   = img.height,
                    }
                end
            end
        end
    end

    -- Backgrounds category (DW1 and DW2 SCN backgrounds)
    if #all_bg > 0 then
        local bg_children = {}
        for _, bg in ipairs(all_bg) do
            local bg_type = bg.id:sub(1, 5) == "anim_" and "animation" or "image"
            bg_children[#bg_children + 1] = { id = bg.id, name = bg.name, type = bg_type }
        end
        table.insert(resources, 1, {
            id       = "cat_backgrounds",
            name     = string.format("%s - Backgrounds (%d)", game_label, #all_bg),
            type     = "category",
            children = bg_children,
        })
    end

    -- Sprites / animations category (DW1 cross-file grouping; DW2 SCN small objects)
    if #all_scn_sp > 0 then
        local groups = {}
        local order  = {}
        for _, sp in ipairs(all_scn_sp) do
            local key = sp.w .. "x" .. sp.h
            if not groups[key] then groups[key] = {}; order[#order + 1] = key end
            groups[key][#groups[key] + 1] = sp
        end

        local sp_children = {}
        for _, key in ipairs(order) do
            local group = groups[key]
            local first = group[1]
            if #group == 1 then
                sp_children[#sp_children + 1] = {
                    id   = string.format("img_%s_%d", first.fname, first.pos),
                    name = string.format("%dx%d  [%s]", first.w, first.h, first.fname),
                    type = "image",
                }
            else
                local parts = {}
                for _, sp in ipairs(group) do
                    parts[#parts + 1] = sp.fname .. ":" .. sp.pos
                end
                sp_children[#sp_children + 1] = {
                    id   = "anim_" .. table.concat(parts, "|"),
                    name = string.format("%dx%d \xc3\x97 %d frames", first.w, first.h, #group),
                    type = "animation",
                }
            end
        end

        table.insert(resources, 2, {
            id       = "cat_sprites",
            name     = string.format("%s - Sprites (%d sizes)", game_label, #sp_children),
            type     = "category",
            children = sp_children,
        })
    end

    return resources
end

-- ============================================================================
-- Resource loading
-- ============================================================================

function engine.load_resource(game_path, resource_id, palette_id)
    local dw2 = is_dw2(game_path)
    local handles, num = parse_index(game_path, dw2)
    if not handles then return nil end

    -- Animation: "anim_FNAME1:POS1|FNAME2:POS2|..."
    if resource_id:sub(1, 5) == "anim_" then
        local anim_str = resource_id:sub(6)
        local frames   = {}
        for part in (anim_str .. "|"):gmatch("([^|]+)|") do
            local fname, pos_s = part:match("^(.+):(%d+)$")
            if fname and pos_s then
                local img = decode_one_frame(game_path, handles, dw2, fname, tonumber(pos_s))
                if img then frames[#frames + 1] = img end
            end
        end
        if #frames > 0 then
            return {
                type        = "animation",
                frames      = frames,
                description = string.format("%s - %d frames",
                    dw2 and "Discworld 2" or "Discworld 1", #frames),
            }
        end
        return { type = "text", text = "No frames decoded: " .. resource_id }
    end

    -- Single image: "img_FILENAME_pos"
    local file_name, pos_str = resource_id:match("^img_(.+)_(%d+)$")
    if not file_name or not pos_str then return nil end
    local img = decode_one_frame(game_path, handles, dw2, file_name, tonumber(pos_str))
    if not img then
        return { type = "text", text = "Cannot decode: " .. resource_id }
    end
    return {
        type        = "image",
        image       = img,
        description = string.format("%s - %s",
            dw2 and "Discworld 2" or "Discworld 1", file_name),
    }
end

return engine

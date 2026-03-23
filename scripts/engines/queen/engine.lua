-- ============================================================================
-- Adventure Explorer - Engine Script: Flight of the Amazon Queen
-- ============================================================================
-- Interactive Binary Illusions / Renegade, 1995. DOS/Amiga.
--
-- All resources in a single bundle: queen.1 (original) or queen.1c (rebuilt).
-- queen.1c starts with a 13-byte QTBL header:
--   4 magic "QTBL" + 6 version string + 2 padding + 1 compression type
-- Then uint16 BE entry count, followed by entries (21 bytes each):
--   12 filename (null-padded) + 1 bundle + 4 BE offset + 4 BE size
--
-- Resource types by extension:
--   .PCX  Room backgrounds (standard PCX, 8-bit indexed, RLE)
--   .BBK  Sprite banks ("Bob Banks" - animation frames)
--   .ACT  Actor sprite banks (same format as BBK)
--   .SB   Speech/sound banks
--   .SAM  Sound samples
--   .DOG  Dialog data
--   .CUT  Cutaway scene data
--   .LUM  Dynamic lighting deltas
--   .MSK  Lighting masks
--   .CRD  Credits text
--   .JAS  Main game data
--
-- PCX format: standard 128-byte header, RLE compressed, 256-color palette
--   at end (0x0C marker + 768 bytes). Dimensions 320x200 or 640x200.
--
-- BBK/ACT format (DOS):
--   uint16 LE frame count
--   Per frame: uint16 LE width, height, xhotspot, yhotspot
--              then width*height raw 8-bit pixels (index 0 = transparent)
-- ============================================================================

local engine = {}
engine.name        = "Flight of the Amazon Queen"
engine.id          = "queen"
engine.description = "Flight of the Amazon Queen (1995, IBI/Renegade)"
engine.version     = "1.0"

-- ============================================================================
-- Binary helpers
-- ============================================================================

local function u8(data, pos)
    return data:byte(pos)
end

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function u16be(data, pos)
    return data:byte(pos) * 256 + data:byte(pos + 1)
end

local function u32be(data, pos)
    return data:byte(pos) * 16777216 + data:byte(pos + 1) * 65536
         + data:byte(pos + 2) * 256 + data:byte(pos + 3)
end

-- ============================================================================
-- Resource table parser
-- ============================================================================

local QTBL_HEADER_SIZE = 13    -- 4 magic + 6 version + 2 pad + 1 compression
local ENTRY_COUNT_SIZE = 2     -- uint16 BE
local ENTRY_SIZE       = 21    -- 12 name + 1 bundle + 4 offset + 4 size

local function find_datafile(game_path)
    for _, name in ipairs({"queen.1c", "queen.1", "QUEEN.1C", "QUEEN.1"}) do
        local path = game_path .. "/" .. name
        if file_exists(path) then return path end
    end
    return nil
end

local function parse_resource_table(game_path)
    local path = find_datafile(game_path)
    if not path then return nil end

    local fh = file_open(path)
    if not fh then return nil end

    -- Read header
    local header = file_read(fh, 0, QTBL_HEADER_SIZE)
    if not header or #header < QTBL_HEADER_SIZE then
        file_close(fh)
        return nil
    end

    local magic = header:sub(1, 4)
    if magic ~= "QTBL" then
        -- Original queen.1 without embedded table - not supported yet
        file_close(fh)
        log_warn("Original queen.1 format not supported (no QTBL header). Use queen.1c instead.")
        return nil
    end

    local version = header:sub(5, 10)
    local compression = u8(header, 13)

    -- Read entry count
    local count_data = file_read(fh, QTBL_HEADER_SIZE, ENTRY_COUNT_SIZE)
    if not count_data or #count_data < 2 then
        file_close(fh)
        return nil
    end
    local entry_count = u16be(count_data, 1)

    -- Read all entries
    local table_start = QTBL_HEADER_SIZE + ENTRY_COUNT_SIZE
    local table_size = entry_count * ENTRY_SIZE
    local table_data = file_read(fh, table_start, table_size)
    file_close(fh)

    if not table_data or #table_data < table_size then
        return nil
    end

    local entries = {}
    for i = 0, entry_count - 1 do
        local base = i * ENTRY_SIZE + 1
        -- Extract null-terminated filename from 12-byte field
        local raw_name = table_data:sub(base, base + 11)
        local null_pos = raw_name:find("\0")
        local name = null_pos and raw_name:sub(1, null_pos - 1) or raw_name
        local bundle = u8(table_data, base + 12)
        local offset = u32be(table_data, base + 13)
        local size   = u32be(table_data, base + 17)

        entries[#entries + 1] = {
            name   = name,
            bundle = bundle,
            offset = offset,
            size   = size
        }
    end

    return {
        path        = path,
        version     = version,
        compression = compression,
        entries     = entries
    }
end

-- ============================================================================
-- PCX decoder (8-bit, RLE)
-- ============================================================================

local function decode_pcx(data)
    if not data or #data < 129 then return nil end

    local bpp      = u8(data, 4)
    local xmin     = u16le(data, 5)
    local ymin     = u16le(data, 7)
    local xmax     = u16le(data, 9)
    local ymax     = u16le(data, 11)
    local nplanes  = u8(data, 66)
    local bytespl  = u16le(data, 67)

    local width  = xmax - xmin + 1
    local height = ymax - ymin + 1

    if width <= 0 or height <= 0 or width > 1024 or height > 512 then
        return nil
    end

    -- Decode RLE pixel data starting after 128-byte header
    local pixels = {}
    local pos = 129
    local total = bytespl * nplanes * height
    local n = 0

    while n < total and pos <= #data do
        local b = data:byte(pos)
        pos = pos + 1
        if b >= 192 then
            local count = b - 192
            local value = (pos <= #data) and data:byte(pos) or 0
            pos = pos + 1
            for _ = 1, count do
                n = n + 1
                pixels[n] = value
            end
        else
            n = n + 1
            pixels[n] = b
        end
    end

    -- For single-plane 8bpp, pixels are direct palette indices
    -- Trim to actual image dimensions (bytespl may be padded)
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
    end

    -- Read 256-color palette from end of data (0x0C marker + 768 bytes)
    local palette = {}
    for i = 0, 767 do palette[i + 1] = 0 end

    if #data >= 769 then
        local pal_offset = #data - 768
        local marker = data:byte(pal_offset)
        if marker == 0x0C then
            for i = 0, 255 do
                palette[i * 3 + 1] = data:byte(pal_offset + 1 + i * 3) or 0
                palette[i * 3 + 2] = data:byte(pal_offset + 2 + i * 3) or 0
                palette[i * 3 + 3] = data:byte(pal_offset + 3 + i * 3) or 0
            end
        end
    end

    return {
        width   = width,
        height  = height,
        pixels  = pixels,
        palette = palette
    }
end

-- ============================================================================
-- BBK/ACT sprite bank decoder
-- ============================================================================

local function decode_sprite_bank(data)
    if not data or #data < 2 then return nil end

    local frame_count = u16le(data, 1)
    if frame_count <= 0 or frame_count > 5000 then return nil end

    local frames = {}
    local pos = 3  -- after 2-byte frame count

    for i = 1, frame_count do
        if pos + 8 > #data + 1 then break end

        local w  = u16le(data, pos)
        local h  = u16le(data, pos + 2)
        local xh = u16le(data, pos + 4)
        local yh = u16le(data, pos + 6)
        pos = pos + 8

        local pixel_count = w * h
        if w > 0 and h > 0 and pos + pixel_count - 1 <= #data then
            local pixels = {}
            for p = 1, pixel_count do
                pixels[p] = data:byte(pos + p - 1)
            end
            frames[#frames + 1] = {
                index   = i - 1,
                width   = w,
                height  = h,
                xhotspot = xh,
                yhotspot = yh,
                pixels  = pixels
            }
        end
        pos = pos + pixel_count
    end

    return frames
end

-- ============================================================================
-- Detection
-- ============================================================================

function engine.detect(game_path)
    return find_datafile(game_path) ~= nil
end

-- ============================================================================
-- Resource tree
-- ============================================================================

function engine.get_resources(game_path)
    local rt = parse_resource_table(game_path)
    if not rt then return {} end

    -- Categorize entries by extension
    local backgrounds = {}
    local sprite_banks = {}
    local actor_banks = {}
    local cutaways = {}
    local dialogs = {}
    local sounds = {}
    local lighting = {}
    local other = {}

    for _, entry in ipairs(rt.entries) do
        local name_upper = entry.name:upper()
        local ext = ""
        local dot = name_upper:find("%.[^%.]*$")
        if dot then ext = name_upper:sub(dot) end

        if ext == ".PCX" or ext == ".LBM" then
            backgrounds[#backgrounds + 1] = entry
        elseif ext == ".BBK" then
            sprite_banks[#sprite_banks + 1] = entry
        elseif ext == ".ACT" then
            actor_banks[#actor_banks + 1] = entry
        elseif ext == ".CUT" then
            cutaways[#cutaways + 1] = entry
        elseif ext == ".DOG" then
            dialogs[#dialogs + 1] = entry
        elseif ext == ".SB" or ext == ".SAM" then
            sounds[#sounds + 1] = entry
        elseif ext == ".LUM" or ext == ".MSK" then
            lighting[#lighting + 1] = entry
        elseif ext == ".JAS" or ext == ".CRD" or ext == ".RAW" or ext == ".RL" or ext == ".MUS" then
            other[#other + 1] = entry
        end
    end

    local resources = {}

    -- Backgrounds
    if #backgrounds > 0 then
        local bg_children = {}
        for _, entry in ipairs(backgrounds) do
            local base = entry.name:match("^(.-)%.")  or entry.name
            bg_children[#bg_children + 1] = {
                id   = "bg_" .. entry.name,
                name = base,
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

    -- Sprite banks (BBK)
    if #sprite_banks > 0 then
        local bbk_children = {}
        for _, entry in ipairs(sprite_banks) do
            local base = entry.name:match("^(.-)%.") or entry.name
            -- Read frame count to create sub-entries
            bbk_children[#bbk_children + 1] = {
                id   = "bbk_" .. entry.name,
                name = base,
                type = "category",
                children = {}  -- filled on load
            }
        end
        resources[#resources + 1] = {
            id       = "sprite_banks",
            name     = "Sprite Banks (" .. #sprite_banks .. ")",
            type     = "category",
            children = bbk_children
        }
    end

    -- Actor banks (ACT)
    if #actor_banks > 0 then
        local act_children = {}
        for _, entry in ipairs(actor_banks) do
            local base = entry.name:match("^(.-)%.") or entry.name
            act_children[#act_children + 1] = {
                id   = "act_" .. entry.name,
                name = base,
                type = "category",
                children = {}
            }
        end
        resources[#resources + 1] = {
            id       = "actor_banks",
            name     = "Actor Banks (" .. #actor_banks .. ")",
            type     = "category",
            children = act_children
        }
    end

    -- Now populate sprite bank children by reading frame counts
    local fh = file_open(rt.path)
    if fh then
        for _, entry in ipairs(rt.entries) do
            local name_upper = entry.name:upper()
            local is_bbk = name_upper:match("%.BBK$")
            local is_act = name_upper:match("%.ACT$")
            if is_bbk or is_act then
                local prefix = is_bbk and "bbk_" or "act_"
                local header_data = file_read(fh, entry.offset, 2)
                if header_data and #header_data >= 2 then
                    local nframes = u16le(header_data, 1)
                    if nframes > 0 and nframes <= 5000 then
                        local frame_children = {}
                        for fr = 0, nframes - 1 do
                            frame_children[#frame_children + 1] = {
                                id   = prefix .. entry.name .. "_f" .. fr,
                                name = "Frame " .. fr,
                                type = "image"
                            }
                        end
                        -- Find the matching category node and set children
                        local cat_id = prefix .. entry.name
                        for _, cat in ipairs(resources) do
                            if cat.children then
                                for _, node in ipairs(cat.children) do
                                    if node.id == cat_id then
                                        node.children = frame_children
                                        node.name = node.name .. " (" .. nframes .. " frames)"
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        file_close(fh)
    end

    -- Cutaways
    if #cutaways > 0 then
        local cut_children = {}
        for _, entry in ipairs(cutaways) do
            local base = entry.name:match("^(.-)%.") or entry.name
            cut_children[#cut_children + 1] = {
                id   = "cut_" .. entry.name,
                name = base,
                type = "data"
            }
        end
        resources[#resources + 1] = {
            id       = "cutaways",
            name     = "Cutaway Scenes (" .. #cutaways .. ")",
            type     = "category",
            children = cut_children
        }
    end

    -- Dialogs
    if #dialogs > 0 then
        local dog_children = {}
        for _, entry in ipairs(dialogs) do
            local base = entry.name:match("^(.-)%.") or entry.name
            dog_children[#dog_children + 1] = {
                id   = "dog_" .. entry.name,
                name = base,
                type = "data"
            }
        end
        resources[#resources + 1] = {
            id       = "dialogs",
            name     = "Dialogs (" .. #dialogs .. ")",
            type     = "category",
            children = dog_children
        }
    end

    -- Lighting
    if #lighting > 0 then
        local light_children = {}
        for _, entry in ipairs(lighting) do
            light_children[#light_children + 1] = {
                id   = "light_" .. entry.name,
                name = entry.name,
                type = "data"
            }
        end
        resources[#resources + 1] = {
            id       = "lighting",
            name     = "Lighting (" .. #lighting .. ")",
            type     = "category",
            children = light_children
        }
    end

    return resources
end

-- ============================================================================
-- Resource loader
-- ============================================================================

-- Find a resource entry by name
local function find_entry(entries, name)
    for _, entry in ipairs(entries) do
        if entry.name == name then return entry end
    end
    return nil
end

-- Find entry for a resource from the table by resource_id pattern
local function resolve_entry(rt, resource_id)
    -- bg_FILENAME.PCX -> FILENAME.PCX
    -- bbk_FILENAME.BBK -> FILENAME.BBK
    -- act_FILENAME.ACT -> FILENAME.ACT
    -- bbk_FILENAME.BBK_fN -> FILENAME.BBK (frame N)
    -- act_FILENAME.ACT_fN -> FILENAME.ACT (frame N)
    local filename = resource_id:match("^bg_(.+)$")
                  or resource_id:match("^bbk_(.-)_f%d+$")
                  or resource_id:match("^act_(.-)_f%d+$")
                  or resource_id:match("^bbk_(.+)$")
                  or resource_id:match("^act_(.+)$")
    if not filename then return nil end
    return find_entry(rt.entries, filename)
end

function engine.load_resource(game_path, resource_id, palette_id)
    local rt = parse_resource_table(game_path)
    if not rt then return nil end

    -- Background image (PCX)
    if resource_id:match("^bg_") then
        local entry = resolve_entry(rt, resource_id)
        if not entry then return nil end

        local fh = file_open(rt.path)
        if not fh then return nil end
        local data = file_read(fh, entry.offset, entry.size)
        file_close(fh)

        local pcx = decode_pcx(data)
        if not pcx then return nil end

        local img = image_create_indexed(pcx.width, pcx.height, pcx.pixels, pcx.palette)
        local base = entry.name:match("^(.-)%.") or entry.name
        return {
            type        = "image",
            image       = img,
            description = base .. " (" .. pcx.width .. "x" .. pcx.height .. ")"
        }
    end

    -- Sprite frame from BBK or ACT bank
    local bank_file, frame_str = resource_id:match("^[ba][bc][kt]_(.-)_f(%d+)$")
    if bank_file then
        local frame_idx = tonumber(frame_str)
        local entry = find_entry(rt.entries, bank_file)
        if not entry then return nil end

        local fh = file_open(rt.path)
        if not fh then return nil end
        local data = file_read(fh, entry.offset, entry.size)
        file_close(fh)

        local frames = decode_sprite_bank(data)
        if not frames then return nil end

        -- Find the matching frame
        local frame = nil
        for _, f in ipairs(frames) do
            if f.index == frame_idx then
                frame = f
                break
            end
        end
        if not frame then return nil end

        -- Try to get palette from a background PCX
        -- Use palette_id if provided, otherwise find any PCX
        local palette = nil
        if palette_id and palette_id:match("^bg_") then
            local pal_entry = resolve_entry(rt, palette_id)
            if pal_entry then
                local pfh = file_open(rt.path)
                if pfh then
                    local pdata = file_read(pfh, pal_entry.offset, pal_entry.size)
                    file_close(pfh)
                    local ppcx = decode_pcx(pdata)
                    if ppcx then palette = ppcx.palette end
                end
            end
        end

        -- Try to find a room PCX with matching name prefix
        if not palette then
            local base = bank_file:match("^(.-)%.")
            if base then
                local pcx_name = base .. ".PCX"
                local pcx_entry = find_entry(rt.entries, pcx_name)
                if not pcx_entry then
                    pcx_name = base:sub(1, -2) .. ".PCX"
                    pcx_entry = find_entry(rt.entries, pcx_name)
                end
                if pcx_entry then
                    local pfh = file_open(rt.path)
                    if pfh then
                        local pdata = file_read(pfh, pcx_entry.offset, pcx_entry.size)
                        file_close(pfh)
                        local ppcx = decode_pcx(pdata)
                        if ppcx then palette = ppcx.palette end
                    end
                end
            end
        end

        -- Fallback: use first available PCX palette
        if not palette then
            for _, e in ipairs(rt.entries) do
                if e.name:upper():match("%.PCX$") then
                    local pfh = file_open(rt.path)
                    if pfh then
                        local pdata = file_read(pfh, e.offset, e.size)
                        file_close(pfh)
                        local ppcx = decode_pcx(pdata)
                        if ppcx then palette = ppcx.palette; break end
                    end
                end
            end
        end

        -- Last resort: grayscale palette
        if not palette then
            palette = {}
            for i = 0, 255 do
                palette[i * 3 + 1] = i
                palette[i * 3 + 2] = i
                palette[i * 3 + 3] = i
            end
        end

        local img = image_create_indexed(frame.width, frame.height, frame.pixels, palette)
        return {
            type        = "image",
            image       = img,
            description = string.format("Frame %d: %dx%d hotspot=(%d,%d)",
                frame_idx, frame.width, frame.height, frame.xhotspot, frame.yhotspot)
        }
    end

    -- Sprite bank overview (clicking the bank itself shows first frame)
    if resource_id:match("^bbk_") or resource_id:match("^act_") then
        local filename = resource_id:match("^[ba][bc][kt]_(.+)$")
        if filename then
            local entry = find_entry(rt.entries, filename)
            if not entry then return nil end

            local fh = file_open(rt.path)
            if not fh then return nil end
            local data = file_read(fh, entry.offset, entry.size)
            file_close(fh)

            local frames = decode_sprite_bank(data)
            if not frames or #frames == 0 then return nil end

            -- Show first frame as preview
            local frame = frames[1]
            local palette = {}
            for i = 0, 255 do
                palette[i * 3 + 1] = i
                palette[i * 3 + 2] = i
                palette[i * 3 + 3] = i
            end
            local img = image_create_indexed(frame.width, frame.height, frame.pixels, palette)
            return {
                type        = "image",
                image       = img,
                description = string.format("%s: %d frames (preview: %dx%d)",
                    filename, #frames, frame.width, frame.height)
            }
        end
    end

    return nil
end

return engine

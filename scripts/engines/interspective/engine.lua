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

function engine.get_resources(game_path)
    local prefix = detect_prefix(game_path)
    if not prefix then return {} end

    local game_name = GAME_NAMES[prefix] or prefix
    local resources = {}

    -- Backgrounds
    local backgrounds = scan_backgrounds(game_path, prefix)
    if #backgrounds > 0 then
        local bg_children = {}
        for _, bg in ipairs(backgrounds) do
            bg_children[#bg_children + 1] = {
                id   = "bg_" .. bg.filename,
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

    return resources
end

-- ============================================================================
-- Resource loader
-- ============================================================================

function engine.load_resource(game_path, resource_id, palette_id)
    local prefix = detect_prefix(game_path)
    if not prefix then return nil end

    -- Background image
    local bg_filename = resource_id:match("^bg_(.+)$")
    if bg_filename then
        local path = game_path .. "/" .. bg_filename
        local fh = file_open(path)
        if not fh then return nil end
        local sz = file_size(fh)
        local data = file_read(fh, 0, sz)
        file_close(fh)

        local bg = decode_background(data)
        if not bg then return nil end

        local img = image_create_indexed(bg.width, bg.height, bg.pixels, bg.palette)
        local scene = bg_filename:match("(%d%d%d)")  or bg_filename
        return {
            type        = "image",
            image       = img,
            description = string.format("Scene %s (%dx%d)", scene, bg.width, bg.height)
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

    return nil
end

return engine

-- ============================================================================
-- Adventure Explorer - Engine Script: Harvester
-- ============================================================================
-- DigiFX Interactive, 1996. DOS/Windows.
--
-- File formats:
--   *.BM   - Background images: u32le width, u32le height, then raw indexed pixels
--   *.ABM  - Animated sprites: multi-frame with optional RLE compression
--   *.PAL  - Palettes: 768 bytes (256 * RGB), 8-bit per component (no shift)
--
-- BM header: at least 8 bytes (width u32le, height u32le), possibly longer.
-- The loader probes header sizes 8-32 to find one where remaining = w*h.
--
-- ABM global header (8 bytes): u32le num_cells, u32le max_frame_size
-- ABM per-cell header (21 bytes):
--   u32le pad_x, u32le pad_y, u32le width, u32le height,
--   u8 compression (0=raw, 1=RLE), u32le payload_length
-- RLE: control byte bit7=0 → lower 7 bits literal count;
--      control byte bit7=1 → lower 7 bits repeat count of next byte
-- ============================================================================

local engine = {}
engine.name        = "Harvester"
engine.id          = "harvester"
engine.description = "Harvester (DigiFX Interactive, 1996)"
engine.version     = "1.0"

-- ============================================================================
-- Binary helpers
-- ============================================================================

local function u8(data, pos)  return data:byte(pos) end

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end

-- ============================================================================
-- PAL loader (768-byte, 8-bit RGB)
-- ============================================================================

local function load_pal(game_path, pal_name)
    local fh = file_open(game_path .. "/" .. pal_name)
    if not fh then return nil end
    local sz = file_size(fh)
    if sz < 768 then file_close(fh); return nil end
    local data = file_read(fh, 0, 768)
    file_close(fh)
    if not data or #data < 768 then return nil end
    local pal = {}
    for i = 0, 255 do
        pal[i * 3 + 1] = data:byte(i * 3 + 1)
        pal[i * 3 + 2] = data:byte(i * 3 + 2)
        pal[i * 3 + 3] = data:byte(i * 3 + 3)
    end
    return pal
end

-- Find a palette: try matching filename, then DEFAULT.PAL, then first available.
local function find_pal(game_path, filename, pal_list)
    local base = filename:match("^(.+)%.[^.]+$")
    if base then
        for _, p in ipairs(pal_list) do
            local pb = p:match("^(.+)%.[^.]+$")
            if pb and pb:upper() == base:upper() then
                local pal = load_pal(game_path, p)
                if pal then return pal end
            end
        end
    end
    local pal = load_pal(game_path, "DEFAULT.PAL")
    if pal then return pal end
    if #pal_list > 0 then
        pal = load_pal(game_path, pal_list[1])
        if pal then return pal end
    end
    -- Grayscale fallback
    local g = {}
    for i = 0, 255 do g[i*3+1] = i; g[i*3+2] = i; g[i*3+3] = i end
    return g
end

-- ============================================================================
-- BM loader
-- ============================================================================

local function load_bm(game_path, filename, pal)
    local fh = file_open(game_path .. "/" .. filename)
    if not fh then return nil end
    local sz = file_size(fh)
    if sz < 12 then file_close(fh); return nil end

    local hdr = file_read(fh, 0, math.min(sz, 32))
    if not hdr or #hdr < 8 then file_close(fh); return nil end

    local w = u32le(hdr, 1)
    local h = u32le(hdr, 5)
    local data_off

    if w >= 1 and w <= 4096 and h >= 1 and h <= 4096 then
        local px = w * h
        -- Probe header sizes 8..32 (step 4) for exact pixel fit
        for off = 8, 32, 4 do
            local rem = sz - off
            if rem == px or rem == px + 768 then
                data_off = off
                break
            end
        end
    end

    if not data_off then file_close(fh); return nil end

    -- Check for embedded palette appended after pixels
    if sz >= data_off + w * h + 768 then
        local pd = file_read(fh, data_off + w * h, 768)
        if pd and #pd >= 768 then
            pal = {}
            for i = 0, 255 do
                pal[i*3+1] = pd:byte(i*3+1)
                pal[i*3+2] = pd:byte(i*3+2)
                pal[i*3+3] = pd:byte(i*3+3)
            end
        end
    end

    local pix_data = file_read(fh, data_off, w * h)
    file_close(fh)
    if not pix_data or #pix_data < w * h then return nil end

    local pix = {}
    for i = 1, w * h do pix[i] = pix_data:byte(i) end
    return image_create_indexed(w, h, pix, pal)
end

-- ============================================================================
-- ABM loader
-- ============================================================================

local function decode_rle(data, pos, count)
    local pix = {}
    local n = 0
    while n < count and pos <= #data do
        local ctrl = u8(data, pos)
        pos = pos + 1
        if ctrl >= 128 then
            local run = ctrl - 128
            if pos > #data then break end
            local val = u8(data, pos)
            pos = pos + 1
            for _ = 1, run do
                n = n + 1
                if n > count then break end
                pix[n] = val
            end
        else
            for _ = 1, ctrl do
                if pos > #data or n >= count then break end
                n = n + 1
                pix[n] = u8(data, pos)
                pos = pos + 1
            end
        end
    end
    while n < count do n = n + 1; pix[n] = 0 end
    return pix
end

local function load_abm(game_path, filename, pal)
    local fh = file_open(game_path .. "/" .. filename)
    if not fh then return nil end
    local sz = file_size(fh)
    if sz < 8 then file_close(fh); return nil end
    local data = file_read(fh, 0, sz)
    file_close(fh)
    if not data then return nil end

    local num_cells = u32le(data, 1)
    if num_cells < 1 or num_cells > 1000 then return nil end

    local frames = {}
    local pos = 9  -- after 8-byte global header

    for _ = 1, num_cells do
        if pos + 20 > #data then break end
        local w      = u32le(data, pos + 8)
        local h      = u32le(data, pos + 12)
        local comp   = u8(data, pos + 16)
        local pay_sz = u32le(data, pos + 17)
        local pix_pos = pos + 21

        if w < 1 or w > 4096 or h < 1 or h > 4096 then break end
        if pix_pos + pay_sz - 1 > #data then break end

        local pix
        if comp == 0 then
            pix = {}
            for i = 1, w * h do
                pix[i] = (pix_pos + i - 1 <= #data) and u8(data, pix_pos + i - 1) or 0
            end
        else
            pix = decode_rle(data, pix_pos, w * h)
        end
        pos = pix_pos + pay_sz

        table.insert(frames, image_create_indexed(w, h, pix, pal))
    end

    if #frames == 0 then return nil end
    if #frames == 1 then
        return { type = "image", image = frames[1] }
    end
    local anim = animation_create(frames, 100)
    return { type = "animation", animation = anim, image = frames[1], frames = frames }
end

-- ============================================================================
-- Public engine API
-- ============================================================================

function engine.detect(game_path)
    return file_exists(game_path .. "/HARVEST.DAT")
        or file_exists(game_path .. "/HARVEST.EXE")
end

-- Scan a directory for files matching a pattern; return relative paths.
local function scan_dir(game_path, subdir, ext)
    local dir = subdir ~= "" and (game_path .. "/" .. subdir) or game_path
    local files = list_files(dir)
    if not files then return {} end
    local result = {}
    for _, f in ipairs(files) do
        if f:upper():match(ext) then
            local rel = subdir ~= "" and (subdir .. "/" .. f) or f
            table.insert(result, rel)
        end
    end
    return result
end

function engine.get_resources(game_path)
    local bm_all, abm_all = {}, {}

    -- Scan root + known GRAPHIC/ subdirectories for BM/ABM files
    local dirs = {
        "", "GRAPHIC/OTHER", "GRAPHIC/ROOMOBJ",
        "GRAPHIC/INVENTRY", "GRAPHIC/MASK",
    }
    for _, d in ipairs(dirs) do
        for _, rel in ipairs(scan_dir(game_path, d, "%.BM$")) do
            table.insert(bm_all, rel)
        end
        for _, rel in ipairs(scan_dir(game_path, d, "%.ABM$")) do
            table.insert(abm_all, rel)
        end
    end
    -- Also scan GRAPHIC/ROOMANIM for ABM
    for _, rel in ipairs(scan_dir(game_path, "GRAPHIC/ROOMANIM", "%.ABM$")) do
        table.insert(abm_all, rel)
    end

    table.sort(bm_all)
    table.sort(abm_all)

    local bm_kids, abm_kids = {}, {}
    for _, rel in ipairs(bm_all) do
        table.insert(bm_kids, { id = "bm:" .. rel, name = rel, type = "image" })
    end
    for _, rel in ipairs(abm_all) do
        table.insert(abm_kids, { id = "abm:" .. rel, name = rel, type = "image" })
    end

    local tree = {}
    if #bm_kids > 0 then
        table.insert(tree, {
            id = "backgrounds", name = "Backgrounds",
            type = "category", children = bm_kids,
        })
    end
    if #abm_kids > 0 then
        table.insert(tree, {
            id = "sprites", name = "Sprites",
            type = "category", children = abm_kids,
        })
    end
    return tree
end

function engine.load_resource(game_path, resource_id)
    -- Collect PAL files from root and GRAPHIC/PAL/
    local pal_list = {}
    local root_files = list_files(game_path)
    if root_files then
        for _, f in ipairs(root_files) do
            if f:upper():match("%.PAL$") then table.insert(pal_list, f) end
        end
    end
    local gpal_files = list_files(game_path .. "/GRAPHIC/PAL")
    if gpal_files then
        for _, f in ipairs(gpal_files) do
            if f:upper():match("%.PAL$") then
                table.insert(pal_list, "GRAPHIC/PAL/" .. f)
            end
        end
    end
    table.sort(pal_list)

    local bm_file = resource_id:match("^bm:(.+)$")
    if bm_file then
        local pal = find_pal(game_path, bm_file, pal_list)
        local img = load_bm(game_path, bm_file, pal)
        if not img then
            return { type = "text", text = "Failed to load BM: " .. bm_file }
        end
        return { type = "image", image = img, description = bm_file }
    end

    local abm_file = resource_id:match("^abm:(.+)$")
    if abm_file then
        local pal = find_pal(game_path, abm_file, pal_list)
        local result = load_abm(game_path, abm_file, pal)
        if not result then
            return { type = "text", text = "Failed to load ABM: " .. abm_file }
        end
        result.description = abm_file
        return result
    end

    return { type = "text", text = "Unknown resource: " .. resource_id }
end

return engine

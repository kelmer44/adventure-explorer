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
--
-- Archive format (HARVEST.DAT / INDEX.001):
--   INDEX.001: fixed 148-byte entries, each containing:
--     - Null-terminated path starting with "XFLEn:\" (e.g. "XFLE1:\GRAPHIC\HEADS\FOO.BM")
--     - u32le at byte offset 132: data offset in HARVEST.DAT
--     - u32le at byte offset 136: file data size
--   HARVEST.DAT: concatenated records, each preceded by a 148-byte XFLE header
-- ============================================================================

local engine = {}
engine.name        = "Harvester"
engine.id          = "harvester"
engine.description = "Harvester (DigiFX Interactive, 1996)"
engine.version     = "2.0"

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

local function pal_from_data(data)
    if not data or #data < 768 then return nil end
    local pal = {}
    for i = 0, 255 do
        pal[i * 3 + 1] = data:byte(i * 3 + 1)
        pal[i * 3 + 2] = data:byte(i * 3 + 2)
        pal[i * 3 + 3] = data:byte(i * 3 + 3)
    end
    return pal
end

local function load_pal(game_path, pal_name)
    local fh = file_open(game_path .. "/" .. pal_name)
    if not fh then return nil end
    local sz = file_size(fh)
    if sz < 768 then file_close(fh); return nil end
    local data = file_read(fh, 0, 768)
    file_close(fh)
    return pal_from_data(data)
end

-- Find a palette: try matching filename, then DEFAULT.PAL, then first available.
-- pal_entries: list of {name=, loader=function()} where loader returns pal table
local function find_pal(filename, pal_entries)
    local base = filename:match("([^/\\]+)$")  -- get filename part
    base = base and base:match("^(.+)%.[^.]+$")  -- strip extension
    if base then
        for _, p in ipairs(pal_entries) do
            local pb = p.name:match("([^/\\]+)$")
            pb = pb and pb:match("^(.+)%.[^.]+$")
            if pb and pb:upper() == base:upper() then
                local pal = p.loader()
                if pal then return pal end
            end
        end
    end
    -- Try DEFAULT.PAL
    for _, p in ipairs(pal_entries) do
        local pname = p.name:match("([^/\\]+)$") or p.name
        if pname:upper() == "DEFAULT.PAL" then
            local pal = p.loader()
            if pal then return pal end
        end
    end
    -- First available
    if #pal_entries > 0 then
        local pal = pal_entries[1].loader()
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

local function load_bm_data(data, pal)
    local sz = #data
    if sz < 12 then return nil end

    local w = u32le(data, 1)
    local h = u32le(data, 5)
    local data_off

    if w >= 1 and w <= 4096 and h >= 1 and h <= 4096 then
        local px = w * h
        for off = 8, 32, 4 do
            local rem = sz - off
            if rem == px or rem == px + 768 then
                data_off = off
                break
            end
        end
    end

    if not data_off then return nil end

    local px = w * h
    -- Check for embedded palette appended after pixels
    if sz >= data_off + px + 768 then
        local epal = {}
        local base = data_off + px
        for i = 0, 255 do
            epal[i*3+1] = data:byte(base + i*3 + 1)
            epal[i*3+2] = data:byte(base + i*3 + 2)
            epal[i*3+3] = data:byte(base + i*3 + 3)
        end
        pal = epal
    end

    local pix = {}
    for i = 1, px do pix[i] = data:byte(data_off + i) end
    return image_create_indexed(w, h, pix, pal)
end

local function load_bm(game_path, filename, pal)
    local fh = file_open(game_path .. "/" .. filename)
    if not fh then return nil end
    local sz = file_size(fh)
    local data = file_read(fh, 0, sz)
    file_close(fh)
    if not data then return nil end
    return load_bm_data(data, pal)
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

local function load_abm_data(data, pal)
    if not data or #data < 8 then return nil end

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

local function load_abm(game_path, filename, pal)
    local fh = file_open(game_path .. "/" .. filename)
    if not fh then return nil end
    local sz = file_size(fh)
    if sz < 8 then file_close(fh); return nil end
    local data = file_read(fh, 0, sz)
    file_close(fh)
    return load_abm_data(data, pal)
end

-- ============================================================================
-- XFLE archive index parser
-- ============================================================================

local XFLE_ENTRY_SIZE = 148

local function parse_xfle_index(game_path, index_name)
    local path = game_path .. "/" .. index_name
    if not file_exists(path) then return {} end
    local fh = file_open(path)
    if not fh then return {} end
    local total = file_size(fh)
    local n = math.floor(total / XFLE_ENTRY_SIZE)
    local entries = {}
    for i = 0, n - 1 do
        local raw = file_read(fh, i * XFLE_ENTRY_SIZE, XFLE_ENTRY_SIZE)
        if not raw or #raw < XFLE_ENTRY_SIZE then break end
        -- Extract null-terminated path
        local null_pos = raw:find("\0")
        if not null_pos then break end
        local xfle_path = raw:sub(1, null_pos - 1)
        -- Strip "XFLEn:\" prefix
        local clean = xfle_path:match("^XFLE%d:\\(.+)$") or xfle_path
        -- Backslash to slash
        clean = clean:gsub("\\", "/")
        -- Read offset and size (1-indexed: byte 132 → position 133)
        local dat_offset = u32le(raw, 133)
        local dat_size   = u32le(raw, 137)
        local ext = clean:match("%.(%w+)$")
        ext = ext and ext:upper() or ""
        table.insert(entries, {
            path = clean,
            offset = dat_offset,
            size = dat_size,
            ext = ext,
        })
    end
    file_close(fh)
    return entries
end

local function read_dat_data(game_path, dat_name, offset, size)
    local fh = file_open(game_path .. "/" .. dat_name)
    if not fh then return nil end
    local data = file_read(fh, offset, size)
    file_close(fh)
    return data
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
    -- Parse XFLE index for archive entries
    local idx_entries = parse_xfle_index(game_path, "INDEX.001")

    -- Organize archive entries by directory and type
    local arch_bm = {}    -- dir → list of entries
    local arch_abm = {}
    local arch_pal_names = {}  -- for palette lookup

    for _, e in ipairs(idx_entries) do
        local dir = e.path:match("^(.+)/[^/]+$") or ""
        local fname = e.path:match("([^/]+)$") or e.path
        if e.ext == "BM" then
            if not arch_bm[dir] then arch_bm[dir] = {} end
            table.insert(arch_bm[dir], { name = fname, entry = e })
        elseif e.ext == "ABM" then
            if not arch_abm[dir] then arch_abm[dir] = {} end
            table.insert(arch_abm[dir], { name = fname, entry = e })
        elseif e.ext == "PAL" then
            table.insert(arch_pal_names, e.path)
        end
    end

    -- Scan loose files
    local loose_bm, loose_abm = {}, {}
    local dirs = { "", "GRAPHIC/OTHER", "GRAPHIC/ROOMOBJ", "GRAPHIC/INVENTRY", "GRAPHIC/MASK" }
    for _, d in ipairs(dirs) do
        for _, rel in ipairs(scan_dir(game_path, d, "%.BM$")) do
            table.insert(loose_bm, rel)
        end
        for _, rel in ipairs(scan_dir(game_path, d, "%.ABM$")) do
            table.insert(loose_abm, rel)
        end
    end
    for _, rel in ipairs(scan_dir(game_path, "GRAPHIC/ROOMANIM", "%.ABM$")) do
        table.insert(loose_abm, rel)
    end

    -- Build tree
    local tree = {}

    -- Archive backgrounds: group by directory
    local bm_cats = {}
    local sorted_bm_dirs = {}
    for dir, _ in pairs(arch_bm) do table.insert(sorted_bm_dirs, dir) end
    table.sort(sorted_bm_dirs)
    for _, dir in ipairs(sorted_bm_dirs) do
        local items = arch_bm[dir]
        table.sort(items, function(a, b) return a.name < b.name end)
        local kids = {}
        for _, item in ipairs(items) do
            table.insert(kids, {
                id = "dat_bm:" .. item.entry.path,
                name = item.name,
                type = "image",
            })
        end
        table.insert(bm_cats, {
            id = "bm_dir:" .. dir,
            name = dir ~= "" and dir or "Root",
            type = "category",
            children = kids,
        })
    end

    -- Add loose BMs
    if #loose_bm > 0 then
        table.sort(loose_bm)
        local kids = {}
        for _, rel in ipairs(loose_bm) do
            table.insert(kids, { id = "bm:" .. rel, name = rel, type = "image" })
        end
        table.insert(bm_cats, {
            id = "bm_dir:loose",
            name = "Loose Files",
            type = "category",
            children = kids,
        })
    end

    if #bm_cats > 0 then
        table.insert(tree, {
            id = "backgrounds", name = "Backgrounds (" .. (#idx_entries > 0 and tostring(#sorted_bm_dirs) .. " dirs" or "loose") .. ")",
            type = "category", children = bm_cats,
        })
    end

    -- Archive sprites: group by directory
    local abm_cats = {}
    local sorted_abm_dirs = {}
    for dir, _ in pairs(arch_abm) do table.insert(sorted_abm_dirs, dir) end
    table.sort(sorted_abm_dirs)
    for _, dir in ipairs(sorted_abm_dirs) do
        local items = arch_abm[dir]
        table.sort(items, function(a, b) return a.name < b.name end)
        local kids = {}
        for _, item in ipairs(items) do
            table.insert(kids, {
                id = "dat_abm:" .. item.entry.path,
                name = item.name,
                type = "image",
            })
        end
        table.insert(abm_cats, {
            id = "abm_dir:" .. dir,
            name = dir ~= "" and dir or "Root",
            type = "category",
            children = kids,
        })
    end

    -- Add loose ABMs
    if #loose_abm > 0 then
        table.sort(loose_abm)
        local kids = {}
        for _, rel in ipairs(loose_abm) do
            table.insert(kids, { id = "abm:" .. rel, name = rel, type = "image" })
        end
        table.insert(abm_cats, {
            id = "abm_dir:loose",
            name = "Loose Files",
            type = "category",
            children = kids,
        })
    end

    if #abm_cats > 0 then
        table.insert(tree, {
            id = "sprites", name = "Sprites (" .. (#idx_entries > 0 and tostring(#sorted_abm_dirs) .. " dirs" or "loose") .. ")",
            type = "category", children = abm_cats,
        })
    end

    return tree
end

-- Build a combined palette lookup from loose files and archive entries
local function build_pal_entries(game_path)
    local pal_entries = {}

    -- Loose PAL files from root and GRAPHIC/PAL/
    local root_files = list_files(game_path)
    if root_files then
        for _, f in ipairs(root_files) do
            if f:upper():match("%.PAL$") then
                local name = f
                table.insert(pal_entries, {
                    name = name,
                    loader = function() return load_pal(game_path, name) end,
                })
            end
        end
    end
    local gpal_files = list_files(game_path .. "/GRAPHIC/PAL")
    if gpal_files then
        for _, f in ipairs(gpal_files) do
            if f:upper():match("%.PAL$") then
                local name = "GRAPHIC/PAL/" .. f
                table.insert(pal_entries, {
                    name = name,
                    loader = function() return load_pal(game_path, name) end,
                })
            end
        end
    end

    -- Archive PAL entries from INDEX.001
    local idx_entries = parse_xfle_index(game_path, "INDEX.001")
    for _, e in ipairs(idx_entries) do
        if e.ext == "PAL" then
            local entry = e
            table.insert(pal_entries, {
                name = entry.path,
                loader = function()
                    local data = read_dat_data(game_path, "HARVEST.DAT", entry.offset, entry.size)
                    return pal_from_data(data)
                end,
            })
        end
    end

    return pal_entries
end

function engine.load_resource(game_path, resource_id)
    local pal_entries = build_pal_entries(game_path)

    -- Archive BM from HARVEST.DAT
    local dat_bm_path = resource_id:match("^dat_bm:(.+)$")
    if dat_bm_path then
        local entries = parse_xfle_index(game_path, "INDEX.001")
        for _, e in ipairs(entries) do
            if e.path == dat_bm_path then
                local pal = find_pal(dat_bm_path, pal_entries)
                local data = read_dat_data(game_path, "HARVEST.DAT", e.offset, e.size)
                if not data then
                    return { type = "text", text = "Failed to read from HARVEST.DAT: " .. dat_bm_path }
                end
                local img = load_bm_data(data, pal)
                if not img then
                    return { type = "text", text = "Failed to decode BM: " .. dat_bm_path .. " (size=" .. e.size .. ")" }
                end
                return { type = "image", image = img, description = dat_bm_path }
            end
        end
        return { type = "text", text = "Entry not found: " .. dat_bm_path }
    end

    -- Archive ABM from HARVEST.DAT
    local dat_abm_path = resource_id:match("^dat_abm:(.+)$")
    if dat_abm_path then
        local entries = parse_xfle_index(game_path, "INDEX.001")
        for _, e in ipairs(entries) do
            if e.path == dat_abm_path then
                local pal = find_pal(dat_abm_path, pal_entries)
                local data = read_dat_data(game_path, "HARVEST.DAT", e.offset, e.size)
                if not data then
                    return { type = "text", text = "Failed to read from HARVEST.DAT: " .. dat_abm_path }
                end
                local result = load_abm_data(data, pal)
                if not result then
                    return { type = "text", text = "Failed to decode ABM: " .. dat_abm_path .. " (size=" .. e.size .. ")" }
                end
                result.description = dat_abm_path
                return result
            end
        end
        return { type = "text", text = "Entry not found: " .. dat_abm_path }
    end

    -- Loose BM file
    local bm_file = resource_id:match("^bm:(.+)$")
    if bm_file then
        local pal = find_pal(bm_file, pal_entries)
        local img = load_bm(game_path, bm_file, pal)
        if not img then
            return { type = "text", text = "Failed to load BM: " .. bm_file }
        end
        return { type = "image", image = img, description = bm_file }
    end

    -- Loose ABM file
    local abm_file = resource_id:match("^abm:(.+)$")
    if abm_file then
        local pal = find_pal(abm_file, pal_entries)
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

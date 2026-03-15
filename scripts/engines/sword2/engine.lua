-- ============================================================================
-- Adventure Explorer - Engine Script: Broken Sword 2 (The Smoking Mirror)
-- ============================================================================
-- Archive: CLU cluster files with embedded index table at end
-- Screen resources (fileType=2): ResHeader(44) + MultiScreenHeader(36)
-- Background: parallax-compressed scanlines (packets of skip/copy)
-- Palette: 1024 bytes (256 x RGBA), full 8-bit, at MSH palette offset
-- ============================================================================

local engine = {}
engine.name        = "Broken Sword II: The Smoking Mirror"
engine.id          = "sword2"
engine.description = "Broken Sword II: The Smoking Mirror (1997, Revolution)"
engine.version     = "1.0"

-- Binary helpers
local function u8(data, pos)   return data:byte(pos) end
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
-- CLU file reader: enumerate resources from a single CLU
-- Format: data at front, index table at end
--   offset 0: u32le table_offset
--   at table_offset: array of (u32le offset, u32le length) pairs
-- ============================================================================

local function read_clu_index(f)
    local fsize = file_size(f)
    if fsize < 8 then return nil end

    local head = file_read(f, 0, 4)
    if not head or #head < 4 then return nil end
    local table_offset = u32le(head, 1)

    if table_offset >= fsize or table_offset < 4 then return nil end

    local table_size = fsize - table_offset
    local num_entries = math.floor(table_size / 8)
    if num_entries == 0 then return nil end

    local tab_data = file_read(f, table_offset, table_size)
    if not tab_data or #tab_data < 8 then return nil end

    local entries = {}
    for i = 0, num_entries - 1 do
        local pos = i * 8 + 1  -- 1-based
        if pos + 7 > #tab_data then break end
        local off = u32le(tab_data, pos)
        local len = u32le(tab_data, pos + 4)
        if off > 0 and len > 0 and off + len <= fsize then
            entries[#entries + 1] = { index = i, offset = off, length = len }
        end
    end
    return entries
end

-- ============================================================================
-- Parallax decompressor
-- Each layer: 4-byte header (u16 w, u16 h), then h x u32 scanline offsets,
-- then packet-compressed scanline data.
-- ============================================================================

local function decompress_parallax(data, start_pos, expected_w, expected_h)
    -- Read parallax header
    local pw = u16le(data, start_pos)
    local ph = u16le(data, start_pos + 2)
    local w = expected_w or pw
    local h = expected_h or ph

    if w == 0 or h == 0 or w > 4096 or h > 4096 then return nil, 0, 0 end

    -- Read scanline offset table: h entries of u32le
    local line_offsets = {}
    for y = 0, h - 1 do
        local pos = start_pos + 4 + y * 4
        if pos + 3 > #data then break end
        line_offsets[y] = u32le(data, pos)
    end

    -- Initialize output buffer
    local pixels = {}
    local total = w * h
    for i = 1, total do pixels[i] = 0 end

    -- Decode each scanline
    for y = 0, h - 1 do
        local line_off = line_offsets[y]
        if line_off and line_off > 0 then
            -- Offset is relative to start of parallax data
            local abs_pos = start_pos + line_off
            if abs_pos + 3 <= #data then
                local packets = u16le(data, abs_pos)
                local x_off = u16le(data, abs_pos + 2)
                local pos = abs_pos + 4
                local dst = y * w + x_off

                if packets == 0 then
                    -- Uncompressed: copy w raw pixels
                    for x = 0, w - 1 do
                        if pos <= #data and x < w then
                            pixels[y * w + x + 1] = u8(data, pos)
                            pos = pos + 1
                        end
                    end
                else
                    -- Packet-compressed
                    local zeros = false
                    local j = 0
                    while j < packets and pos <= #data do
                        if zeros then
                            -- Skip count
                            local skip = u8(data, pos); pos = pos + 1
                            dst = dst + skip
                            zeros = false
                            j = j + 1
                        else
                            local b = u8(data, pos)
                            if b == 0 then
                                -- Switch to zeros mode
                                pos = pos + 1
                                zeros = true
                                j = j + 1
                            else
                                -- Copy count pixels
                                local count = b; pos = pos + 1
                                for k = 0, count - 1 do
                                    if dst >= 0 and dst < total and pos <= #data then
                                        pixels[dst + 1] = u8(data, pos)
                                    end
                                    dst = dst + 1
                                    pos = pos + 1
                                end
                                zeros = true
                                j = j + 1
                            end
                        end
                    end
                end
            end
        end
    end

    return pixels, w, h
end

-- ============================================================================
-- Detection
-- ============================================================================

function engine.detect(game_path)
    return file_exists(game_path .. "/general.clu")
        or file_exists(game_path .. "/GENERAL.CLU")
end

-- ============================================================================
-- Resource tree: scan all CLU files for screen resources (fileType == 2)
-- ============================================================================

function engine.get_resources(game_path)
    local resources = {}
    local rooms_cat = {
        id       = "rooms",
        name     = "Rooms",
        type     = "category",
        children = {}
    }

    -- Find all CLU files
    local all_files = list_files(game_path)
    local clu_files = {}
    for _, fname in ipairs(all_files) do
        if fname:lower():match("%.clu$") then
            clu_files[#clu_files + 1] = fname
        end
    end
    table.sort(clu_files)

    local screen_count = 0
    for _, clu_name in ipairs(clu_files) do
        local clu_path = game_path .. "/" .. clu_name
        local f = file_open(clu_path)
        if f then
            local entries = read_clu_index(f)
            if entries then
                local clu_screens = {}
                for _, entry in ipairs(entries) do
                    -- Read first byte to check fileType
                    local hdr = file_read(f, entry.offset, 1)
                    if hdr and #hdr >= 1 and u8(hdr, 1) == 2 then
                        -- It's a screen resource
                        clu_screens[#clu_screens + 1] = entry
                    end
                end

                if #clu_screens > 0 then
                    local clu_label = clu_name:match("^(.+)%.[cC][lL][uU]$") or clu_name
                    local clu_node = {
                        id       = "clu_" .. clu_label,
                        name     = string.format("%s (%d screens)", clu_label, #clu_screens),
                        type     = "category",
                        children = {}
                    }

                    for _, entry in ipairs(clu_screens) do
                        screen_count = screen_count + 1

                        -- Read the name from ResHeader
                        local name_data = file_read(f, entry.offset + 10, 34)
                        local name = "Screen"
                        if name_data then
                            name = ""
                            for c = 1, 34 do
                                local b = name_data:byte(c)
                                if not b or b == 0 then break end
                                name = name .. string.char(b)
                            end
                            if name == "" then name = "Screen" end
                        end

                        local screen_node = {
                            id       = "screen_" .. clu_label .. "_" .. entry.index,
                            name     = string.format("[%d] %s", entry.index, name),
                            type     = "category",
                            children = {}
                        }

                        screen_node.children[#screen_node.children + 1] = {
                            id   = "bg_" .. clu_label .. "_" .. entry.index,
                            name = "Background",
                            type = "image"
                        }
                        screen_node.children[#screen_node.children + 1] = {
                            id   = "pal_" .. clu_label .. "_" .. entry.index,
                            name = "Palette",
                            type = "image"
                        }

                        clu_node.children[#clu_node.children + 1] = screen_node
                    end

                    rooms_cat.children[#rooms_cat.children + 1] = clu_node
                end
            end
            file_close(f)
        end
    end

    rooms_cat.name = string.format("Screens (%d)", screen_count)
    resources[#resources + 1] = rooms_cat
    return resources
end

-- ============================================================================
-- Resource loading
-- ============================================================================

function engine.load_resource(game_path, resource_id)
    -- Format: bg_CLUNAME_INDEX or pal_CLUNAME_INDEX
    local prefix, clu_label, idx_str = resource_id:match("^(%a+)_(.+)_(%d+)$")
    local idx = tonumber(idx_str)
    if not prefix or not clu_label or not idx then return nil end

    if prefix == "bg"  then return load_screen_bg(game_path, clu_label, idx) end
    if prefix == "pal" then return load_screen_pal(game_path, clu_label, idx) end
    return nil
end

local function find_clu_file(game_path, label)
    local candidates = { label .. ".clu", label .. ".CLU",
                         string.upper(label) .. ".CLU", string.lower(label) .. ".clu" }
    for _, name in ipairs(candidates) do
        local path = game_path .. "/" .. name
        if file_exists(path) then return path end
    end
    return nil
end

local function read_screen_resource(game_path, clu_label, res_index)
    local clu_path = find_clu_file(game_path, clu_label)
    if not clu_path then return nil end

    local f = file_open(clu_path)
    if not f then return nil end

    local entries = read_clu_index(f)
    if not entries then file_close(f); return nil end

    -- Find the matching entry
    local target = nil
    for _, entry in ipairs(entries) do
        if entry.index == res_index then target = entry; break end
    end
    if not target then file_close(f); return nil end

    -- Read entire resource
    local data = file_read(f, target.offset, target.length)
    file_close(f)
    return data
end

function load_screen_bg(game_path, clu_label, res_index)
    local data = read_screen_resource(game_path, clu_label, res_index)
    if not data or #data < 80 then return nil end

    -- Verify fileType == 2
    if u8(data, 1) ~= 2 then return nil end

    -- ResHeader: 44 bytes (skip)
    -- MultiScreenHeader at +44 (36 bytes)
    local msh_base = 45  -- 1-based: byte 45 = offset 44
    local pal_off    = u32le(data, msh_base + 0)
    local bgpar0_off = u32le(data, msh_base + 4)
    local bgpar1_off = u32le(data, msh_base + 8)
    local screen_off = u32le(data, msh_base + 12)

    -- ScreenHeader at 44 + screen_off
    local sh_abs = 45 + screen_off  -- 1-based
    if sh_abs + 5 > #data then return nil end
    local scr_w = u16le(data, sh_abs)
    local scr_h = u16le(data, sh_abs + 2)
    -- local noLayers = u16le(data, sh_abs + 4)

    if scr_w == 0 or scr_h == 0 or scr_w > 4096 or scr_h > 4096 then return nil end

    -- Background data: try main screen first (at 44 + screen_off + 6)
    -- The background image is actually the bg_parallax[0], not after ScreenHeader
    -- But if bg_parallax[0] is 0, use screen_off + 6
    local bg_start
    if bgpar0_off > 0 then
        bg_start = 45 + bgpar0_off
    else
        bg_start = sh_abs + 6
    end

    -- Read parallax header to get actual dimensions
    if bg_start + 3 > #data then return nil end
    local pw = u16le(data, bg_start)
    local ph = u16le(data, bg_start + 2)

    -- Use parallax dimensions if they look valid
    local w, h
    if pw > 0 and pw <= 4096 and ph > 0 and ph <= 4096 then
        w, h = pw, ph
    else
        w, h = scr_w, scr_h
    end

    local pixels = decompress_parallax(data, bg_start, w, h)
    if not pixels then return nil end

    -- Read palette at 44 + pal_off (1024 bytes: 256 x [R,G,B,pad])
    local pal_abs = 45 + pal_off
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = 0
        palette[i * 3 + 2] = 0
        palette[i * 3 + 3] = 0
    end

    if pal_abs + 1023 <= #data then
        -- Skip color 0 (forced black), read from entry 1
        for i = 1, 255 do
            local p = pal_abs + i * 4
            if p + 2 <= #data then
                palette[i * 3 + 1] = u8(data, p + 0)
                palette[i * 3 + 2] = u8(data, p + 1)
                palette[i * 3 + 3] = u8(data, p + 2)
            end
        end
    end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image", image = img,
        description = string.format("Screen [%s:%d] - %dx%d, 256 colors", clu_label, res_index, w, h)
    }
end

function load_screen_pal(game_path, clu_label, res_index)
    local data = read_screen_resource(game_path, clu_label, res_index)
    if not data or #data < 80 then return nil end
    if u8(data, 1) ~= 2 then return nil end

    local msh_base = 45
    local pal_off = u32le(data, msh_base + 0)
    local pal_abs = 45 + pal_off

    if pal_abs + 1023 > #data then return nil end

    -- Build color array
    local colors = {}
    for i = 0, 255 do
        if i == 0 then
            colors[i] = { 0, 0, 0 }
        else
            local p = pal_abs + i * 4
            colors[i] = {
                u8(data, p + 0),
                u8(data, p + 1),
                u8(data, p + 2)
            }
        end
    end

    -- Render 16x16 grid
    local CELL, GRID = 16, 16
    local SIZE = CELL * GRID
    local rgb = {}; local n = 0

    for py = 0, SIZE - 1 do
        for px = 0, SIZE - 1 do
            local ci = math.floor(py / CELL) * GRID + math.floor(px / CELL)
            local c = colors[ci] or { 0, 0, 0 }
            n = n + 1; rgb[n] = c[1]
            n = n + 1; rgb[n] = c[2]
            n = n + 1; rgb[n] = c[3]
        end
    end

    local img = image_create_rgb(SIZE, SIZE, rgb)
    return {
        type = "image", image = img,
        description = string.format("Screen [%s:%d] palette - 256 colors", clu_label, res_index)
    }
end

return engine

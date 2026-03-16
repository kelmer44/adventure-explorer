-- ============================================================================
-- Adventure Explorer - Engine Script: Hand of Fate (Kyrandia 2)
-- ============================================================================
-- Westwood Studios, 1993. 320x200 8-bit indexed CPS images.
-- Resources in PAK archives. Palettes in .COL files (CPS format) or embedded.
-- Detection: FATE.PAK or YOURPAST.TLK/YOURPAST.CPS
-- ============================================================================

local engine = {}
engine.name        = "The Legend of Kyrandia: Hand of Fate"
engine.id          = "kyra2"
engine.description = "The Legend of Kyrandia: Hand of Fate (1993, Westwood Studios)"
engine.version     = "2.0"

-- Binary helpers
local function u8(data, pos)   return data:byte(pos) end
local function i8(data, pos)
    local v = data:byte(pos)
    return v < 128 and v or v - 256
end
local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end
local function u16be(data, pos)
    return data:byte(pos) * 256 + data:byte(pos + 1)
end
local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end

-- ============================================================================
-- PAK archive parser (same as Kyra1)
-- ============================================================================

local function parse_pak(data)
    if not data or #data < 4 then return nil end

    local first_offset = u32le(data, 1)
    local big_endian = false

    if first_offset > #data then
        first_offset = data:byte(1) * 16777216 + data:byte(2) * 65536
                     + data:byte(3) * 256 + data:byte(4)
        if first_offset > #data then return nil end
        big_endian = true
    end

    local entries = {}
    local pos = 5
    local start_offset = first_offset

    while pos < first_offset do
        local name_start = pos
        while pos <= #data and data:byte(pos) ~= 0 do pos = pos + 1 end
        if pos > #data then break end

        local name = data:sub(name_start, pos - 1)
        pos = pos + 1

        if #name == 0 then break end

        local end_offset
        if pos + 3 <= #data and pos < first_offset then
            if big_endian then
                end_offset = data:byte(pos) * 16777216 + data:byte(pos + 1) * 65536
                           + data:byte(pos + 2) * 256 + data:byte(pos + 3)
            else
                end_offset = u32le(data, pos)
            end
            pos = pos + 4
        end

        if not end_offset or end_offset == 0 then end_offset = #data end

        entries[#entries + 1] = {
            name = name, offset = start_offset, size = end_offset - start_offset
        }

        if end_offset >= #data then break end
        start_offset = end_offset
    end

    return entries
end

-- ============================================================================
-- CPS Decompressors (shared with Kyra1)
-- ============================================================================

local function decompress_type3(data, src_start, output_size)
    local output = {}; local n = 0; local pos = src_start

    while n < output_size and pos <= #data do
        local code = i8(data, pos); pos = pos + 1

        if code == 0 then
            if pos + 2 > #data then break end
            local sz = u16be(data, pos); pos = pos + 2
            local val = u8(data, pos); pos = pos + 1
            for _ = 1, sz do
                if n >= output_size then break end
                n = n + 1; output[n] = val
            end
        elseif code < 0 then
            if pos > #data then break end
            local val = u8(data, pos); pos = pos + 1
            for _ = 1, -code do
                if n >= output_size then break end
                n = n + 1; output[n] = val
            end
        else
            for _ = 1, code do
                if n >= output_size or pos > #data then break end
                n = n + 1; output[n] = u8(data, pos); pos = pos + 1
            end
        end
    end

    while n < output_size do n = n + 1; output[n] = 0 end
    return output
end

local function decompress_type4(data, src_start, output_size)
    local output = {}; local n = 0; local pos = src_start

    while n < output_size and pos <= #data do
        local code = u8(data, pos); pos = pos + 1

        -- End-of-stream marker (must check before bit tests)
        if code == 0x80 then
            break
        end

        local bit7 = math.floor(code / 128) % 2
        local bit6 = math.floor(code / 64) % 2

        if bit7 == 0 then
            local len = math.floor(code / 16) + 3
            if pos > #data then break end
            local b2 = u8(data, pos); pos = pos + 1
            local offs = (code % 16) * 256 + b2

            for _ = 1, len do
                if n >= output_size then break end
                local src_idx = n + 1 - offs
                local val = (src_idx >= 1 and src_idx <= n) and output[src_idx] or 0
                n = n + 1; output[n] = val
            end

        elseif bit6 == 1 then
            if code == 0xFE then
                if pos + 2 > #data then break end
                local len = u16le(data, pos); pos = pos + 2
                local val = u8(data, pos); pos = pos + 1
                for _ = 1, len do
                    if n >= output_size then break end
                    n = n + 1; output[n] = val
                end
            elseif code == 0xFF then
                if pos + 3 > #data then break end
                local len = u16le(data, pos); pos = pos + 2
                local offs = u16le(data, pos); pos = pos + 2
                for i = 1, len do
                    if n >= output_size then break end
                    local idx = offs + i
                    n = n + 1; output[n] = (idx >= 1 and idx <= #output) and output[idx] or 0
                end
            else
                local len = (code % 64) + 3
                if pos + 1 > #data then break end
                local offs = u16le(data, pos); pos = pos + 2
                for i = 1, len do
                    if n >= output_size then break end
                    local idx = offs + i
                    n = n + 1; output[n] = (idx >= 1 and idx <= #output) and output[idx] or 0
                end
            end
        else
            local len = code % 64
            for _ = 1, len do
                if n >= output_size or pos > #data then break end
                n = n + 1; output[n] = u8(data, pos); pos = pos + 1
            end
        end
    end

    while n < output_size do n = n + 1; output[n] = 0 end
    return output
end

-- ============================================================================
-- CPS image loader
-- ============================================================================

local function decode_cps(data)
    if not data or #data < 10 then return nil end

    local comp_type = u8(data, 3)
    local img_size  = u32le(data, 5)
    local pal_size  = u16le(data, 9)

    local pal_data = nil
    if pal_size > 0 and 10 + pal_size <= #data then
        pal_data = {}
        for i = 0, math.min(pal_size / 3, 256) - 1 do
            local r = u8(data, 11 + i * 3 + 0) % 64
            local g = u8(data, 11 + i * 3 + 1) % 64
            local b = u8(data, 11 + i * 3 + 2) % 64
            pal_data[i * 3 + 1] = math.min(math.floor(r * 255 / 63 + 0.5), 255)
            pal_data[i * 3 + 2] = math.min(math.floor(g * 255 / 63 + 0.5), 255)
            pal_data[i * 3 + 3] = math.min(math.floor(b * 255 / 63 + 0.5), 255)
        end
    end

    local pix_start = 11 + pal_size
    local output_size = 64000  -- 320x200

    local pixels
    if comp_type == 0 then
        pixels = {}
        for i = 1, output_size do
            pixels[i] = (pix_start + i - 1 <= #data) and u8(data, pix_start + i - 1) or 0
        end
    elseif comp_type == 3 then
        pixels = decompress_type3(data, pix_start, output_size)
    elseif comp_type == 4 then
        pixels = decompress_type4(data, pix_start, output_size)
    else
        pixels = {}
        for i = 1, output_size do
            pixels[i] = (pix_start + i - 1 <= #data) and u8(data, pix_start + i - 1) or 0
        end
    end

    return pixels, pal_data, 320, 200
end

-- ============================================================================
-- Load palette from COL file (CPS-format or raw 768 bytes)
-- ============================================================================

local function load_col_palette(data)
    if not data or #data < 768 then return nil end

    -- Try CPS format first
    if #data > 10 then
        local _, pal = decode_cps(data)
        if pal then return pal end
    end

    -- Raw palette
    local palette = {}
    for i = 0, 255 do
        local r = data:byte(i * 3 + 1) % 64
        local g = data:byte(i * 3 + 2) % 64
        local b = data:byte(i * 3 + 3) % 64
        palette[i * 3 + 1] = math.min(math.floor(r * 255 / 63 + 0.5), 255)
        palette[i * 3 + 2] = math.min(math.floor(g * 255 / 63 + 0.5), 255)
        palette[i * 3 + 3] = math.min(math.floor(b * 255 / 63 + 0.5), 255)
    end
    return palette
end

-- ============================================================================
-- Detection: FATE.PAK or YOURPAST.TLK/YOURPAST.CPS
-- ============================================================================

function engine.detect(game_path)
    if file_exists(game_path .. "/FATE.PAK") or file_exists(game_path .. "/fate.pak") then
        return true
    end
    if file_exists(game_path .. "/YOURPAST.TLK") or file_exists(game_path .. "/yourpast.tlk") then
        return true
    end
    if file_exists(game_path .. "/YOURPAST.CPS") or file_exists(game_path .. "/yourpast.cps") then
        -- Also check it's not Kyra1 (which has GEMCUT.EMC)
        if not file_exists(game_path .. "/GEMCUT.EMC") and not file_exists(game_path .. "/gemcut.emc") then
            return true
        end
    end
    return false
end

-- ============================================================================
-- Resource tree: scan PAK files for CPS/COL resources
-- ============================================================================

function engine.get_resources(game_path)
    local files = list_files(game_path)
    if not files then return {} end

    local archives = {}
    local loose_cps = {}
    local seen_cps = {}

    for _, fname in ipairs(files) do
        local lower = fname:lower()
        if lower:match("%.pak$") or lower:match("%.cmp$") then
            archives[#archives + 1] = fname
        elseif lower:match("%.cps$") then
            loose_cps[#loose_cps + 1] = fname
            seen_cps[lower] = true
        end
    end

    -- Scan PAK files
    local pak_cps = {}
    for _, ark_name in ipairs(archives) do
        local f = file_open(game_path .. "/" .. ark_name)
        if f then
            local fsize = file_size(f)
            local raw = file_read(f, 0, fsize)
            file_close(f)
            if raw then
                local entries = parse_pak(raw)
                if entries then
                    for _, e in ipairs(entries) do
                        if e.name:lower():match("%.cps$") and not seen_cps[e.name:lower()] then
                            pak_cps[#pak_cps + 1] = { name = e.name, archive = ark_name }
                            seen_cps[e.name:lower()] = true
                        end
                    end
                end
            end
        end
    end

    local resources = {}

    -- Loose CPS files
    if #loose_cps > 0 then
        table.sort(loose_cps, function(a, b) return a:lower() < b:lower() end)
        local cat = { id = "loose_cps", name = string.format("CPS Images (%d)", #loose_cps),
                      type = "category", children = {} }
        for _, fname in ipairs(loose_cps) do
            local base = fname:match("^(.+)%.") or fname
            cat.children[#cat.children + 1] = {
                id = "loose_" .. base, name = base, type = "image"
            }
        end
        resources[#resources + 1] = cat
    end

    -- PAK-contained CPS, grouped by archive
    if #pak_cps > 0 then
        local by_ark = {}
        for _, pc in ipairs(pak_cps) do
            if not by_ark[pc.archive] then by_ark[pc.archive] = {} end
            by_ark[pc.archive][#by_ark[pc.archive] + 1] = pc.name
        end
        local ark_names = {}
        for k, _ in pairs(by_ark) do ark_names[#ark_names + 1] = k end
        table.sort(ark_names, function(a, b) return a:lower() < b:lower() end)

        for _, ark in ipairs(ark_names) do
            local items = by_ark[ark]
            table.sort(items, function(a, b) return a:lower() < b:lower() end)
            local cat = { id = "pak_" .. ark, name = string.format("%s (%d images)", ark, #items),
                          type = "category", children = {} }
            for _, fname in ipairs(items) do
                local base = fname:match("^(.+)%.") or fname
                cat.children[#cat.children + 1] = {
                    id = "pak_" .. ark .. "_" .. base, name = base, type = "image"
                }
            end
            resources[#resources + 1] = cat
        end
    end

    return resources
end

-- ============================================================================
-- Resource loading
-- ============================================================================

local function extract_from_pak(game_path, ark_name, file_name)
    local f = file_open(game_path .. "/" .. ark_name)
    if not f then return nil end
    local fsize = file_size(f)
    local raw = file_read(f, 0, fsize)
    file_close(f)
    if not raw then return nil end

    local entries = parse_pak(raw)
    if not entries then return nil end

    for _, e in ipairs(entries) do
        if e.name:lower() == file_name:lower() then
            return raw:sub(e.offset + 1, e.offset + e.size)
        end
    end
    return nil
end

local function find_palette(game_path)
    -- Try PALETTE.COL (case-insensitive)
    local f = file_open(game_path .. "/PALETTE.COL")
    if not f then f = file_open(game_path .. "/palette.col") end
    if f then
        local sz = file_size(f)
        local data = file_read(f, 0, sz)
        file_close(f)
        if data then
            local pal = load_col_palette(data)
            if pal then return pal end
        end
    end
    return nil
end

-- Try to find a matching COL file for a CPS scene
local function find_scene_palette(game_path, base_name, archives)
    local col_name = base_name .. ".COL"
    local col_name_lower = base_name:lower() .. ".col"

    -- Check loose (both casings)
    local f = file_open(game_path .. "/" .. col_name)
    if not f then f = file_open(game_path .. "/" .. col_name_lower) end
    if f then
        local sz = file_size(f)
        local data = file_read(f, 0, sz)
        file_close(f)
        if data then
            local pal = load_col_palette(data)
            if pal then return pal end
        end
    end

    -- Check inside PAKs
    if archives then
        for _, ark in ipairs(archives) do
            local data = extract_from_pak(game_path, ark, col_name)
            if data then
                local pal = load_col_palette(data)
                if pal then return pal end
            end
        end
    end

    return nil
end

function engine.load_resource(game_path, resource_id)
    local prefix, rest = resource_id:match("^(%a+)_(.+)$")
    if not prefix then return nil end

    -- Gather archive list for palette search
    local files = list_files(game_path)
    local archives = {}
    if files then
        for _, fname in ipairs(files) do
            local lower = fname:lower()
            if lower:match("%.pak$") or lower:match("%.cmp$") then
                archives[#archives + 1] = fname
            end
        end
    end

    local cps_data
    local base_name

    if prefix == "loose" then
        base_name = rest
        local f = file_open(game_path .. "/" .. rest .. ".CPS")
        if not f then f = file_open(game_path .. "/" .. rest .. ".cps") end
        if not f then return nil end
        local sz = file_size(f)
        cps_data = file_read(f, 0, sz)
        file_close(f)

    elseif prefix == "pak" then
        local ark, base = rest:match("^(.+%..+)_([^_]+)$")
        if not ark or not base then return nil end
        base_name = base
        cps_data = extract_from_pak(game_path, ark, base .. ".CPS")
    end

    if not cps_data then return nil end

    local pixels, embedded_pal, w, h = decode_cps(cps_data)
    if not pixels then return nil end

    -- Palette priority: CPS embedded > scene .COL > PALETTE.COL > grayscale
    local palette = embedded_pal
    if not palette and base_name then
        palette = find_scene_palette(game_path, base_name, archives)
    end
    if not palette then palette = find_palette(game_path) end
    if not palette then
        palette = {}
        for i = 0, 255 do
            palette[i * 3 + 1] = i; palette[i * 3 + 2] = i; palette[i * 3 + 3] = i
        end
    end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image", image = img,
        description = string.format("%s - %dx%d, 256 colors", base_name or resource_id, w, h)
    }
end

return engine

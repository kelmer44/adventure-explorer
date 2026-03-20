-- ============================================================================
-- Adventure Explorer - Engine Script: Legend of Kyrandia (Kyrandia 1)
-- ============================================================================
-- Westwood Studios, 1992. 320x200 8-bit indexed CPS images.
-- Resources in PAK/VRM/APK archives. Palettes in PALETTE.COL or CPS embedded.
-- ============================================================================

local engine = {}
engine.name        = "The Legend of Kyrandia"
engine.id          = "kyra1"
engine.description = "The Legend of Kyrandia (1992, Westwood Studios)"
engine.version     = "3.0"

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
-- PAK archive parser
-- Format: first u32le = offset to first file data, then alternating
-- null-terminated filenames + u32le offsets. Empty string = end of table.
-- ============================================================================

local function parse_pak(data)
    if not data or #data < 4 then return nil end

    local first_offset = u32le(data, 1)
    local big_endian = false

    -- Endianness detection
    if first_offset > #data then
        -- Try big-endian
        first_offset = data:byte(1) * 16777216 + data:byte(2) * 65536
                     + data:byte(3) * 256 + data:byte(4)
        if first_offset > #data then return nil end
        big_endian = true
    end

    local entries = {}
    local pos = 1  -- 1-based
    local start_offset = first_offset

    -- Read first offset
    pos = 5  -- skip past first u32

    while pos < first_offset do
        -- Read null-terminated filename
        local name_start = pos
        while pos <= #data and data:byte(pos) ~= 0 do
            pos = pos + 1
        end
        if pos > #data then break end

        local name = data:sub(name_start, pos - 1)
        pos = pos + 1  -- skip null

        if #name == 0 then break end  -- end of directory

        -- Read next offset
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

        if not end_offset or end_offset == 0 then
            end_offset = #data
        end

        entries[#entries + 1] = {
            name   = name,
            offset = start_offset,  -- 0-based
            size   = end_offset - start_offset
        }

        if end_offset >= #data then break end
        start_offset = end_offset
    end

    return entries
end

-- ============================================================================
-- CPS Decompressor Type 3 (Byte-pair RLE)
-- ============================================================================

local function decompress_type3(data, src_start, output_size)
    local output = {}
    local n = 0
    local pos = src_start

    while n < output_size and pos <= #data do
        local code = i8(data, pos); pos = pos + 1

        if code == 0 then
            -- u16be length + fill byte
            if pos + 2 > #data then break end
            local sz = u16be(data, pos); pos = pos + 2
            local val = u8(data, pos); pos = pos + 1
            for _ = 1, sz do
                if n >= output_size then break end
                n = n + 1; output[n] = val
            end
        elseif code < 0 then
            -- Fill: -code bytes of next byte
            if pos > #data then break end
            local val = u8(data, pos); pos = pos + 1
            local cnt = -code
            for _ = 1, cnt do
                if n >= output_size then break end
                n = n + 1; output[n] = val
            end
        else
            -- Literal: copy code bytes
            for _ = 1, code do
                if n >= output_size or pos > #data then break end
                n = n + 1; output[n] = u8(data, pos); pos = pos + 1
            end
        end
    end

    while n < output_size do n = n + 1; output[n] = 0 end
    return output
end

-- ============================================================================
-- CPS Decompressor Type 4 (LZ77/LZSS variant)
-- ============================================================================

local function decompress_type4(data, src_start, output_size)
    local output = {}
    local n = 0
    local pos = src_start

    while n < output_size and pos <= #data do
        local code = u8(data, pos); pos = pos + 1

        -- End-of-stream marker (must check before bit tests)
        if code == 0x80 then
            break
        end

        local bit7 = math.floor(code / 128) % 2  -- (code >> 7) & 1
        local bit6 = math.floor(code / 64) % 2   -- (code >> 6) & 1

        if bit7 == 0 then
            -- Back-reference: upper nibble + 3 = length, 12-bit offset
            local len = math.floor(code / 16) + 3  -- (code >> 4) + 3
            if pos > #data then break end
            local b2 = u8(data, pos); pos = pos + 1
            local offs = (code % 16) * 256 + b2  -- ((code & 0x0F) << 8) | b2

            for _ = 1, len do
                if n >= output_size then break end
                local src_idx = n + 1 - offs
                local val = (src_idx >= 1 and src_idx <= n) and output[src_idx] or 0
                n = n + 1; output[n] = val
            end

        elseif bit6 == 1 then
            -- Bits 7+6 set
            local low6 = code % 64  -- code & 0x3F

            if code == 0xFE then
                -- RLE fill
                if pos + 2 > #data then break end
                local len = u16le(data, pos); pos = pos + 2
                local val = u8(data, pos); pos = pos + 1
                for _ = 1, len do
                    if n >= output_size then break end
                    n = n + 1; output[n] = val
                end
            elseif code == 0xFF then
                -- Long copy from output (absolute offset)
                if pos + 3 > #data then break end
                local len = u16le(data, pos); pos = pos + 2
                local offs = u16le(data, pos); pos = pos + 2
                for i = 1, len do
                    if n >= output_size then break end
                    local idx = offs + i  -- 1-based absolute offset
                    n = n + 1; output[n] = (idx >= 1 and idx <= #output) and output[idx] or 0
                end
            else
                -- Copy from output with offset
                local len = low6 + 3
                if pos + 1 > #data then break end
                local offs = u16le(data, pos); pos = pos + 2
                for i = 1, len do
                    if n >= output_size then break end
                    local idx = offs + i
                    n = n + 1; output[n] = (idx >= 1 and idx <= #output) and output[idx] or 0
                end
            end
        else
            -- Literal copy: code & 0x3F bytes
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
-- WSA Animation decoder
-- Header: u16le numFrames, u16le width, u16le height
-- Then offset table: (numFrames+2) x u32le offsets
-- All frames are Format 80 compressed. Frame 0 decompresses to raw pixels;
-- frames 1+ decompress to XOR deltas against the previous frame.
-- ============================================================================

local function decode_wsa(data)
    if not data or #data < 10 then return nil end

    local num_frames = u16le(data, 1)
    local width      = u16le(data, 3)
    local height     = u16le(data, 5)

    if num_frames < 1 or width < 1 or height < 1 then return nil end
    if width > 640 or height > 480 then return nil end

    local frame_size = width * height

    -- Read offset table: (numFrames + 2) entries starting at byte 7
    local offsets = {}
    local ot_start = 7
    for i = 0, num_frames + 1 do
        local pos = ot_start + i * 4
        if pos + 3 > #data then return nil end
        offsets[i] = u32le(data, pos)
    end

    -- Data starts after header + offset table
    local data_base = ot_start + (num_frames + 2) * 4

    -- Decode all frames
    local frames = {}
    local prev_frame = nil

    for f = 0, num_frames - 1 do
        local frame_off = offsets[f]
        local next_off  = offsets[f + 1]
        if frame_off == 0 and next_off == 0 then
            -- Empty frame: copy previous
            if prev_frame then
                local copy = {}
                for i = 1, frame_size do copy[i] = prev_frame[i] end
                frames[#frames + 1] = copy
                prev_frame = copy
            end
        else
            local src_start = data_base + frame_off
            if src_start > #data then break end

            -- Decompress using Format 80
            local decoded = decompress_type4(data, src_start, frame_size)

            if prev_frame then
                -- XOR delta: XOR decoded with previous frame
                for i = 1, frame_size do
                    local a = decoded[i] or 0
                    local b = prev_frame[i] or 0
                    -- XOR without bit32: a XOR b = a + b - 2*(a AND b)
                    -- Use the pattern: XOR via arithmetic
                    local xor_val = 0
                    local va, vb = a, b
                    local bit_val = 1
                    for _ = 1, 8 do
                        local ba = va % 2
                        local bb = vb % 2
                        if ba ~= bb then xor_val = xor_val + bit_val end
                        va = math.floor(va / 2)
                        vb = math.floor(vb / 2)
                        bit_val = bit_val * 2
                    end
                    decoded[i] = xor_val
                end
            end

            frames[#frames + 1] = decoded
            prev_frame = decoded
        end
    end

    return frames, width, height, num_frames
end

-- ============================================================================
-- CPS image loader
-- Header: u16le filesize, u8 compType, u8 pad, u32le imgSize, u16le palSize
-- Then palette (palSize bytes), then compressed/raw pixel data
-- Output: 320 x 200, 8-bit indexed
-- ============================================================================

local function decode_cps(data)
    if not data or #data < 10 then return nil end

    local comp_type = u8(data, 3)   -- offset 2 (0-based) = byte 3 (1-based)
    local img_size  = u32le(data, 5) -- offset 4 (0-based)
    local pal_size  = u16le(data, 9) -- offset 8 (0-based)

    -- Extract embedded palette if present
    local pal_data = nil
    if pal_size > 0 and 10 + pal_size <= #data then
        pal_data = {}
        for i = 0, math.min(pal_size / 3, 256) - 1 do
            local r = u8(data, 11 + i * 3 + 0) % 64  -- mask 6-bit
            local g = u8(data, 11 + i * 3 + 1) % 64
            local b = u8(data, 11 + i * 3 + 2) % 64
            pal_data[i * 3 + 1] = math.min(math.floor(r * 255 / 63 + 0.5), 255)
            pal_data[i * 3 + 2] = math.min(math.floor(g * 255 / 63 + 0.5), 255)
            pal_data[i * 3 + 3] = math.min(math.floor(b * 255 / 63 + 0.5), 255)
        end
    end

    local pix_start = 11 + pal_size  -- 1-based
    local output_size = 64000  -- 320 x 200

    local pixels
    if comp_type == 0 then
        -- Uncompressed
        pixels = {}
        for i = 1, output_size do
            if pix_start + i - 1 <= #data then
                pixels[i] = u8(data, pix_start + i - 1)
            else
                pixels[i] = 0
            end
        end
    elseif comp_type == 3 then
        pixels = decompress_type3(data, pix_start, output_size)
    elseif comp_type == 4 then
        pixels = decompress_type4(data, pix_start, output_size)
    else
        -- Unknown compression, try raw
        pixels = {}
        for i = 1, output_size do
            if pix_start + i - 1 <= #data then
                pixels[i] = u8(data, pix_start + i - 1)
            else
                pixels[i] = 0
            end
        end
    end

    return pixels, pal_data, 320, 200
end

-- ============================================================================
-- Load 6-bit VGA palette from raw .COL file (768 bytes)
-- ============================================================================

local function load_col_palette(data)
    if not data or #data < 768 then return nil end

    -- For files LARGER than raw palette, try CPS format first
    if #data > 780 then
        local pal_size = u16le(data, 9)
        if pal_size > 0 and pal_size <= 768 then
            local _, pal = decode_cps(data)
            if pal then return pal end
        end
    end

    -- Raw palette (768 bytes, 6-bit VGA)
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
-- Detection
-- ============================================================================

function engine.detect(game_path)
    return file_exists(game_path .. "/GEMCUT.EMC") or file_exists(game_path .. "/gemcut.emc")
end

-- ============================================================================
-- Resource tree: scan PAK/VRM/APK files for CPS backgrounds
-- ============================================================================

function engine.get_resources(game_path)
    local files = list_files(game_path)
    if not files then return {} end

    -- Gather PAK-type archives
    local archives = {}
    local cps_files = {}   -- direct CPS files
    local col_files = {}   -- COL palette files
    local wsa_files = {}   -- WSA animation files
    local seen_cps = {}
    local seen_wsa = {}

    for _, fname in ipairs(files) do
        local lower = fname:lower()
        if lower:match("%.pak$") or lower:match("%.vrm$") or lower:match("%.apk$") then
            archives[#archives + 1] = fname
        elseif lower:match("%.cps$") then
            cps_files[#cps_files + 1] = fname
            seen_cps[lower] = true
        elseif lower:match("%.col$") then
            col_files[#col_files + 1] = fname
        elseif lower:match("%.wsa$") then
            wsa_files[#wsa_files + 1] = fname
            seen_wsa[lower] = true
        end
    end

    -- Scan inside archives for CPS and WSA files
    local pak_cps = {}  -- {name, archive}
    local pak_wsa = {}  -- {name, archive}
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
                        local el = e.name:lower()
                        if el:match("%.cps$") and not seen_cps[el] then
                            pak_cps[#pak_cps + 1] = { name = e.name, archive = ark_name }
                            seen_cps[el] = true
                        elseif el:match("%.wsa$") and not seen_wsa[el] then
                            pak_wsa[#pak_wsa + 1] = { name = e.name, archive = ark_name }
                            seen_wsa[el] = true
                        end
                    end
                end
            end
        end
    end

    -- Build tree
    local resources = {}

    -- Loose CPS files
    if #cps_files > 0 then
        table.sort(cps_files, function(a, b) return a:lower() < b:lower() end)
        local cat = { id = "loose_cps", name = string.format("CPS Images (%d)", #cps_files),
                      type = "category", children = {} }
        for _, fname in ipairs(cps_files) do
            local base = fname:match("^(.+)%.")  or fname
            cat.children[#cat.children + 1] = {
                id = "loose_" .. base, name = base, type = "image"
            }
        end
        resources[#resources + 1] = cat
    end

    -- PAK-contained CPS files, grouped by archive
    if #pak_cps > 0 then
        -- Group by archive
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

    -- WSA animation files
    local all_wsa = {}
    for _, fname in ipairs(wsa_files) do
        local base = fname:match("^(.+)%.") or fname
        all_wsa[#all_wsa + 1] = { id = "wsa_" .. base, name = base, src = "loose" }
    end
    for _, w in ipairs(pak_wsa) do
        local base = w.name:match("^(.+)%.") or w.name
        all_wsa[#all_wsa + 1] = {
            id = "wpak_" .. w.archive .. "_" .. base,
            name = base .. " [" .. w.archive .. "]",
            src = "pak"
        }
    end
    if #all_wsa > 0 then
        table.sort(all_wsa, function(a, b) return a.name:lower() < b.name:lower() end)
        local cat = { id = "wsa", name = string.format("WSA Animations (%d)", #all_wsa),
                      type = "category", children = {} }
        for _, w in ipairs(all_wsa) do
            cat.children[#cat.children + 1] = { id = w.id, name = w.name, type = "animation" }
        end
        resources[#resources + 1] = cat
    end

    -- COL palette files
    if #col_files > 0 then
        table.sort(col_files, function(a, b) return a:lower() < b:lower() end)
        local cat = { id = "palettes", name = string.format("Palettes (%d)", #col_files),
                      type = "category", children = {} }
        for _, fname in ipairs(col_files) do
            local base = fname:match("^(.+)%.") or fname
            cat.children[#cat.children + 1] = { id = "col_" .. base, name = base, type = "palette" }
        end
        resources[#resources + 1] = cat
    end

    return resources
end

-- ============================================================================
-- Resource loading
-- ============================================================================

-- Find and load palette: try PALETTE.COL first (case-insensitive)
local function find_palette(game_path)
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

-- Extract file from a PAK archive
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

function engine.load_resource(game_path, resource_id, palette_id)
    -- Parse resource ID
    local prefix, rest = resource_id:match("^(%a+)_(.+)$")
    if not prefix then return nil end

    local cps_data

    if prefix == "loose" then
        -- Loose CPS file
        local fname = rest .. ".CPS"
        local f = file_open(game_path .. "/" .. fname)
        if not f then
            f = file_open(game_path .. "/" .. rest .. ".cps")
        end
        if not f then return nil end
        local sz = file_size(f)
        cps_data = file_read(f, 0, sz)
        file_close(f)

    elseif prefix == "pak" then
        -- Format: pak_ARCHIVE_BASENAME
        local ark, base = rest:match("^(.+%..+)_([^_]+)$")
        if not ark or not base then return nil end
        cps_data = extract_from_pak(game_path, ark, base .. ".CPS")

    elseif prefix == "wsa" then
        -- Loose WSA animation: decode and return as animation
        local f = file_open(game_path .. "/" .. rest .. ".WSA")
        if not f then
            f = file_open(game_path .. "/" .. rest .. ".wsa")
        end
        if not f then return nil end
        local sz = file_size(f)
        local wsa_data = file_read(f, 0, sz)
        file_close(f)
        if not wsa_data then return nil end

        local raw_frames, w, h, nf = decode_wsa(wsa_data)
        if not raw_frames or #raw_frames == 0 then return nil end

        local palette = find_palette(game_path)
        if not palette then
            palette = {}
            for i = 0, 255 do
                palette[i * 3 + 1] = i
                palette[i * 3 + 2] = i
                palette[i * 3 + 3] = i
            end
        end

        local handles = {}
        for i = 1, #raw_frames do
            handles[i] = image_create_indexed(w, h, raw_frames[i], palette)
        end
        local anim = animation_create(handles, 100)
        return {
            type = "animation",
            animation = anim,
            delay_ms = 100,
            description = string.format("%s.WSA - %dx%d, %d frames", rest, w, h, #raw_frames)
        }

    elseif prefix == "wpak" then
        -- PAK-contained WSA: decode and return as animation
        local ark, base = rest:match("^(.+%..+)_([^_]+)$")
        if not ark or not base then return nil end
        local wsa_data = extract_from_pak(game_path, ark, base .. ".WSA")
        if not wsa_data or #wsa_data < 10 then return nil end

        local raw_frames, w, h, nf = decode_wsa(wsa_data)
        if not raw_frames or #raw_frames == 0 then return nil end

        local palette = find_palette(game_path)
        if not palette then
            palette = {}
            for i = 0, 255 do
                palette[i * 3 + 1] = i
                palette[i * 3 + 2] = i
                palette[i * 3 + 3] = i
            end
        end

        local handles = {}
        for i = 1, #raw_frames do
            handles[i] = image_create_indexed(w, h, raw_frames[i], palette)
        end
        local anim = animation_create(handles, 100)
        return {
            type = "animation",
            animation = anim,
            delay_ms = 100,
            description = string.format("%s.WSA (in %s) - %dx%d, %d frames", base, ark, w, h, #raw_frames)
        }

    elseif prefix == "col" then
        -- COL palette: render as 16x16 color swatch grid
        local f = file_open(game_path .. "/" .. rest .. ".COL")
        if not f then return nil end
        local sz = file_size(f)
        local data = file_read(f, 0, sz)
        file_close(f)
        if not data then return nil end
        local pal = load_col_palette(data)
        if not pal then return nil end
        -- 16x16 grid of 16x16-pixel swatches = 256x256 image
        local W, H, sw = 256, 256, 16
        local rgb = {}
        local n = 1
        for y = 0, H - 1 do
            for x = 0, W - 1 do
                local ci = math.floor(y / sw) * 16 + math.floor(x / sw)
                rgb[n] = pal[ci * 3 + 1] or 0; n = n + 1
                rgb[n] = pal[ci * 3 + 2] or 0; n = n + 1
                rgb[n] = pal[ci * 3 + 3] or 0; n = n + 1
            end
        end
        local img = image_create_rgb(W, H, rgb)
        return { type = "image", image = img,
                 description = string.format("%s.COL - 256-color VGA palette", rest) }
    end

    if not cps_data then return nil end

    local pixels, embedded_pal, w, h = decode_cps(cps_data)
    if not pixels then return nil end

    -- Use embedded palette merged with PALETTE.COL fallback.
    -- Some CPS files only have partial palettes, so merge with global palette.
    local global_pal = find_palette(game_path)
    local palette

    if embedded_pal then
        palette = {}
        for i = 0, 255 do
            local r = embedded_pal[i * 3 + 1]
            local g = embedded_pal[i * 3 + 2]
            local b = embedded_pal[i * 3 + 3]
            if r and g and b then
                palette[i * 3 + 1] = r
                palette[i * 3 + 2] = g
                palette[i * 3 + 3] = b
            elseif global_pal then
                palette[i * 3 + 1] = global_pal[i * 3 + 1] or 0
                palette[i * 3 + 2] = global_pal[i * 3 + 2] or 0
                palette[i * 3 + 3] = global_pal[i * 3 + 3] or 0
            else
                palette[i * 3 + 1] = 0
                palette[i * 3 + 2] = 0
                palette[i * 3 + 3] = 0
            end
        end
    elseif global_pal then
        palette = global_pal
    else
        -- Generate grayscale fallback
        palette = {}
        for i = 0, 255 do
            palette[i * 3 + 1] = i
            palette[i * 3 + 2] = i
            palette[i * 3 + 3] = i
        end
    end

    local img = image_create_indexed(w, h, pixels, palette)
    local base_name = resource_id:match("([^_]+)$") or resource_id
    return {
        type = "image", image = img,
        description = string.format("%s - %dx%d, 256 colors", base_name, w, h)
    }
end

return engine

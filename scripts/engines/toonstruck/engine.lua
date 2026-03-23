-- ============================================================================
-- Adventure Explorer - Engine Script: Toonstruck (1996, DOS/Windows)
-- ============================================================================
-- Reads PAK archives: LOCAL.PAK and per-location .PAK files
-- PAK format: flat directory of [offset:u32le][null-term name]... empty name=end
-- Image formats: LZSS, SPCN, RNC1, RNC2 (4-byte magic, then compressed data)
-- Screen: 640x400 (or 1280x400 for scrolling bgs), 8-bit indexed color
-- Palette: 256 x 3 bytes, 6-bit VGA (multiply by 4)
-- ============================================================================

local engine = {}

engine.name = "Toonstruck"
engine.id = "toonstruck"
engine.description = "Toonstruck (1996, Burst Studios / Virgin Interactive)"
engine.version = "2.0"

-- ── Recursive file scanning ─────────────────────────────────────
-- list_files returns both files and dirs. We detect dirs by trying
-- list_files on each entry; a non-empty result means it's a dir.

local function scan_pak_svl_recursive(base_path, rel_prefix, results)
    local entries = list_files(base_path)
    for i = 1, #entries do
        local name  = entries[i]
        local upper = name:upper()
        local full  = base_path .. "/" .. name
        local rel   = (rel_prefix ~= "") and (rel_prefix .. "/" .. name) or name

        if upper:match("%.PAK$") or upper:match("%.SVL$") then
            results[#results + 1] = { rel_path = rel, full_path = full, name = name }
        else
            -- Try recursing: list_files returns empty table for non-dirs
            local sub = list_files(full)
            if #sub > 0 then
                scan_pak_svl_recursive(full, rel, results)
            end
        end
    end
end

-- ── Binary helpers ──────────────────────────────────────────────

local function u8(data, pos)
    return data:byte(pos)
end

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end

local function u32be(data, pos)
    return data:byte(pos) * 16777216
         + data:byte(pos + 1) * 65536
         + data:byte(pos + 2) * 256
         + data:byte(pos + 3)
end

-- ── PAK archive parser ─────────────────────────────────────────
-- Format: sequential entries of [u32le offset][null-term filename]
-- Last entry has empty filename (just a null byte after the offset)

local function parse_pak_directory(f)
    local files = {}
    local pos = 0

    -- Read a generous chunk of the directory (usually < 64KB)
    local dir_data = file_read(f, 0, 65536)
    if not dir_data then return files end

    local cursor = 1  -- 1-indexed into dir_data

    while cursor + 4 <= #dir_data do
        local offset = u32le(dir_data, cursor)
        cursor = cursor + 4

        -- Read null-terminated name
        local name_start = cursor
        while cursor <= #dir_data and dir_data:byte(cursor) ~= 0 do
            cursor = cursor + 1
        end

        if cursor > #dir_data then break end

        local name_len = cursor - name_start
        if name_len == 0 then break end  -- empty name = end of directory

        local name = dir_data:sub(name_start, cursor - 1)
        cursor = cursor + 1  -- skip null terminator

        -- Peek next entry's offset to compute size
        local next_offset = 0
        if cursor + 4 <= #dir_data then
            next_offset = u32le(dir_data, cursor)
        end

        local size = 0
        if next_offset > offset then
            size = next_offset - offset
        end

        files[#files + 1] = {
            name = name,
            offset = offset,
            size = size
        }
    end

    -- Fix up last entry's size if we couldn't peek
    if #files > 0 and files[#files].size == 0 then
        local total = file_size(f)
        files[#files].size = total - files[#files].offset
    end

    return files
end

-- ── LZSS decompression ─────────────────────────────────────────
-- Bit-flagged: byte of flags controls 8 ops
-- flag=1: back-reference (12-bit offset | 4-bit length+3)
-- flag=0: count consecutive 0-bits for literal run length

local function decompress_lzss(data, expected_size)
    local result = {}
    local n = 0
    local pos = 1
    local len = #data

    while n < expected_size and pos <= len do
        local flags = data:byte(pos)
        pos = pos + 1

        for bit = 0, 7 do
            if n >= expected_size or pos > len then break end

            if flags % 2 == 1 then
                -- flag bit 1: back-reference (u16le: top 4 bits = len-3, low 12 bits = offset)
                if pos + 1 > len then break end
                local raw = u16le(data, pos)
                pos = pos + 2

                local copy_len = math.floor(raw / 4096) + 3
                local back_dist = 4096 - (raw % 4096)

                for i = 1, copy_len do
                    if n >= expected_size then break end
                    local src_idx = n + 1 - back_dist
                    n = n + 1
                    if src_idx >= 1 and src_idx < n then
                        result[n] = result[src_idx]
                    else
                        result[n] = 0
                    end
                end
            else
                -- flag bit 0: literal byte
                if pos > len then break end
                n = n + 1
                result[n] = data:byte(pos)
                pos = pos + 1
            end

            flags = math.floor(flags / 2)
        end
    end

    return result, n
end

-- ── SPCN decompression ─────────────────────────────────────────

local function decompress_spcn(data, expected_size)
    local result = {}
    local n = 0
    local pos = 1
    local len = #data

    while n < expected_size and pos <= len do
        local val = data:byte(pos)
        pos = pos + 1

        if val < 0x80 then
            -- Back-reference: length in upper nibble, offset in lower nibble + next byte
            local copy_len = math.floor(val / 16) + 3
            if pos > len then break end
            local copy_offset = (val % 16) * 256 + data:byte(pos)
            pos = pos + 1

            for i = 1, copy_len do
                if n >= expected_size then break end
                local src_idx = n - copy_offset
                if src_idx >= 1 then
                    n = n + 1
                    result[n] = result[src_idx]
                else
                    n = n + 1
                    result[n] = 0
                end
            end

        elseif val < 0xC0 then
            -- Literal run: length = val & 0x3F
            local run_len = val % 64
            for i = 1, run_len do
                if n >= expected_size or pos > len then break end
                n = n + 1
                result[n] = data:byte(pos)
                pos = pos + 1
            end

        elseif val == 0xFE then
            -- RLE fill
            if pos + 2 > len then break end
            local fill_len = u16le(data, pos)
            pos = pos + 2
            local fill_byte = data:byte(pos)
            pos = pos + 1
            for i = 1, fill_len do
                if n >= expected_size then break end
                n = n + 1
                result[n] = fill_byte
            end

        elseif val == 0xFF then
            -- Long back-reference
            if pos + 3 > len then break end
            local copy_len = u16le(data, pos)
            pos = pos + 2
            local copy_offset = u16le(data, pos)
            pos = pos + 2

            for i = 1, copy_len do
                if n >= expected_size then break end
                local src_idx = n - copy_offset
                if src_idx >= 1 then
                    n = n + 1
                    result[n] = result[src_idx]
                else
                    n = n + 1
                    result[n] = 0
                end
            end

        else
            -- 0xC0-0xFD: back-reference, length = (val & 0x3F) + 3, offset = next 2 bytes
            local copy_len = (val % 64) + 3
            if pos + 1 > len then break end
            local copy_offset = u16le(data, pos)
            pos = pos + 2

            for i = 1, copy_len do
                if n >= expected_size then break end
                local src_idx = n - copy_offset
                if src_idx >= 1 then
                    n = n + 1
                    result[n] = result[src_idx]
                else
                    n = n + 1
                    result[n] = 0
                end
            end
        end
    end

    return result, n
end

-- ── Detection ───────────────────────────────────────────────────

function engine.detect(game_path)
    -- Toonstruck always has LOCAL.PAK (case-insensitive via file_exists)
    if not file_exists(game_path .. "/LOCAL.PAK") then
        return false
    end

    -- Must also have at least one SVL file or DREW.PAK somewhere
    local found = {}
    scan_pak_svl_recursive(game_path, "", found)
    for _, entry in ipairs(found) do
        local upper = entry.name:upper()
        if upper:match("%.SVL$") or upper == "DREW.PAK" then
            return true
        end
    end

    return false
end

-- ── Resource tree ───────────────────────────────────────────────

function engine.get_resources(game_path)
    local resources = {}

    -- Recursively find all PAK/SVL files
    local all_paks = {}
    scan_pak_svl_recursive(game_path, "", all_paks)

    -- Sort by relative path for consistent ordering
    table.sort(all_paks, function(a, b) return a.rel_path:upper() < b.rel_path:upper() end)

    for _, pak_info in ipairs(all_paks) do
        local f = file_open(pak_info.full_path)
        if f then
            local entries = parse_pak_directory(f)
            file_close(f)

            if #entries > 0 then
                local images = {}
                local others = {}

                for _, entry in ipairs(entries) do
                    local upper_name = entry.name:upper()
                    if upper_name:match("%.CPS$")
                        or upper_name:match("%.BMP$")
                        or upper_name:match("%.PIC$")
                        or upper_name:match("%.SCR$")
                        or upper_name:match("%.CAF$")
                        or upper_name:match("BACK") then
                        images[#images + 1] = entry
                    else
                        others[#others + 1] = entry
                    end
                end

                local children = {}

                if #images > 0 then
                    local img_children = {}
                    for _, entry in ipairs(images) do
                        img_children[#img_children + 1] = {
                            id = "pak:" .. pak_info.rel_path .. ":" .. entry.name,
                            name = string.format("%s (%d bytes)", entry.name, entry.size),
                            type = "image"
                        }
                    end
                    children[#children + 1] = {
                        id = "pakcat_img_" .. pak_info.rel_path,
                        name = "Images (" .. #images .. ")",
                        type = "category",
                        children = img_children
                    }
                end

                -- List all files for browsing
                local all_children = {}
                for _, entry in ipairs(entries) do
                    all_children[#all_children + 1] = {
                        id = "pak:" .. pak_info.rel_path .. ":" .. entry.name,
                        name = string.format("%s (%d bytes)", entry.name, entry.size),
                        type = "image"
                    }
                end

                children[#children + 1] = {
                    id = "pakcat_all_" .. pak_info.rel_path,
                    name = "All Files (" .. #entries .. ")",
                    type = "category",
                    children = all_children
                }

                resources[#resources + 1] = {
                    id = "pak_" .. pak_info.rel_path,
                    name = pak_info.rel_path .. " (" .. #entries .. " files)",
                    type = "category",
                    children = children
                }
            end
        end
    end

    return resources
end

-- ── Resource loading ────────────────────────────────────────────

function engine.load_resource(game_path, resource_id, palette_id)
    -- ID format: pak:<relative_pak_path>:<entry_name>
    local pak_rel, entry_name = resource_id:match("^pak:(.+):([^:]+)$")
    if not pak_rel or not entry_name then
        log_warn("Unknown resource ID format: " .. resource_id)
        return nil
    end

    -- Open the PAK and find the entry
    local pak_path = game_path .. "/" .. pak_rel
    local f = file_open(pak_path)
    local entries = parse_pak_directory(f)

    local target = nil
    for _, entry in ipairs(entries) do
        if entry.name == entry_name then
            target = entry
            break
        end
    end

    if not target then
        file_close(f)
        log_warn("Entry not found in PAK: " .. entry_name)
        return nil
    end

    -- Read raw entry data
    local raw = file_read(f, target.offset, target.size)
    file_close(f)

    if not raw or #raw < 8 then
        return nil
    end

    -- Detect format from magic bytes (big-endian)
    local magic = u32be(raw, 1)

    -- Check for CAF "KevinAguilar" magic (first 4 bytes = "Kevi")
    if magic == 0x4B657669 and #raw >= 68 then
        local magic12 = raw:sub(1, 12)
        if magic12 == "KevinAguilar" then
            return decode_caf_image(raw, entry_name)
        end
    end

    if magic == 0x4C5A5353 then
        -- "LZSS" format
        return decode_lzss_image(raw, entry_name)
    elseif magic == 0x5350434E then
        -- "SPCN" format
        return decode_spcn_image(raw, entry_name)
    elseif magic == 0x524E4301 or magic == 0x524E4302 then
        -- RNC compressed (we can report but not decompress without full RNC impl)
        return {
            type = "text",
            text = string.format(
                "RNC compressed data\n\nFile: %s\nMagic: %s\nCompressed size: %d bytes\n\n" ..
                "(RNC decompression not yet implemented)",
                entry_name,
                magic == 0x524E4301 and "RNC\\01" or "RNC\\02",
                #raw
            ),
            description = string.format("%s — RNC compressed (%d bytes)", entry_name, #raw)
        }
    else
        -- Unknown format — try to display as raw indexed image if reasonable size
        -- or show hex dump
        if #raw > 100 then
            local hex_lines = {}
            hex_lines[1] = string.format("Raw data: %d bytes", #raw)
            hex_lines[2] = string.format("First 4 bytes (BE): 0x%08X", magic)
            hex_lines[3] = ""

            local dump_bytes = math.min(#raw, 256)
            for row = 0, dump_bytes - 1, 16 do
                local hex = {}
                local ascii = {}
                for col = 0, 15 do
                    local idx = row + col + 1
                    if idx <= dump_bytes then
                        hex[#hex + 1] = string.format("%02X", raw:byte(idx))
                        local b = raw:byte(idx)
                        ascii[#ascii + 1] = (b >= 0x20 and b < 0x7F) and string.char(b) or "."
                    end
                end
                hex_lines[#hex_lines + 1] = string.format(
                    "%06X  %-48s  %s",
                    row, table.concat(hex, " "), table.concat(ascii)
                )
            end

            return {
                type = "text",
                text = table.concat(hex_lines, "\n"),
                description = string.format("%s — Unknown format (%d bytes)", entry_name, #raw)
            }
        end

        return nil
    end
end

-- ── LZSS image decoder ──────────────────────────────────────────
-- Format: [4B "LZSS"][4B LE decompressed_size][compressed data...]
-- After decompression: pixel data + palette at end

function decode_lzss_image(raw, name)
    local dst_size = u32le(raw, 5)

    if dst_size == 0 or dst_size > 10000000 then
        log_warn("LZSS: Invalid decompressed size: " .. tostring(dst_size))
        return nil
    end

    local compressed = raw:sub(9)
    local pixels, pixel_count = decompress_lzss(compressed, dst_size)

    if pixel_count < dst_size * 0.5 then
        log_warn(string.format("LZSS: Only decompressed %d of %d bytes", pixel_count, dst_size))
    end

    -- Palette location: last (dst_size % 2048) bytes of decompressed data (ScummVM convention)
    local pal_bytes = dst_size % 2048
    local pal_entries = math.floor(pal_bytes / 3)
    local pixel_bytes = dst_size - pal_bytes

    -- Determine width: 1280 for scrolling backgrounds, 640 for normal
    local width = 640
    if pixel_bytes > 640 * 400 then
        width = 1280
    end

    local height = math.floor(pixel_bytes / width)
    if height <= 0 or pixel_bytes < width then
        -- No room for palette — treat entire data as pixels (no embedded palette)
        pal_bytes = 0
        pal_entries = 0
        pixel_bytes = dst_size
        height = math.floor(pixel_bytes / width)
    end
    if height > 480 then height = 480 end
    if height < 1 then height = 1 end

    -- Build palette (8-bit RGB, at end of decompressed data)
    local palette = {}
    if pal_entries > 0 then
        local pal_start = pixel_bytes + 1
        -- Partial palette (< 256 entries): start at index 1
        -- Full palette (>= 256 entries): start at index 0
        local color_start = (pal_entries < 256) and 1 or 0
        -- Initialize all to black
        for i = 0, 255 do palette[i*3+1]=0; palette[i*3+2]=0; palette[i*3+3]=0 end
        for i = 0, math.min(pal_entries, 256) - 1 do
            local idx = pal_start + i * 3
            local ci = color_start + i
            if ci <= 255 and idx + 2 <= pixel_count then
                palette[ci * 3 + 1] = pixels[idx] * 4
                palette[ci * 3 + 2] = pixels[idx + 1] * 4
                palette[ci * 3 + 3] = pixels[idx + 2] * 4
            end
        end
    else
        -- No palette; use greyscale
        for i = 0, 255 do
            palette[i * 3 + 1] = i
            palette[i * 3 + 2] = i
            palette[i * 3 + 3] = i
        end
    end

    -- Extract pixel table (just the image portion)
    local img_pixels = {}
    local total = width * height
    for i = 1, total do
        img_pixels[i] = pixels[i] or 0
    end

    local img = image_create_indexed(width, height, img_pixels, palette)

    return {
        type = "image",
        image = img,
        width = width,
        height = height,
        description = string.format(
            "%s — LZSS, %dx%d, %d palette entries, %d bytes decompressed",
            name, width, height, pal_entries, dst_size
        )
    }
end

-- ── SPCN image decoder ──────────────────────────────────────────
-- Format: [4B "SPCN"][6B header][4B LE dst_size][2B LE pal_bytes]
--         [pal_bytes palette data][compressed pixel data]

function decode_spcn_image(raw, name)
    if #raw < 16 then return nil end

    local dst_size = u32le(raw, 11)
    local pal_byte_count = u16le(raw, 15)
    local pal_entries = math.floor(pal_byte_count / 3)

    -- Read palette (8-bit RGB, starts at offset 16)
    local palette = {}
    local pal_start = 17  -- 1-indexed, byte 16 in 0-indexed
    -- Partial palette: start at index 1; Full: start at 0
    local color_start = (pal_entries < 256) and 1 or 0
    for i = 0, 255 do palette[i*3+1]=0; palette[i*3+2]=0; palette[i*3+3]=0 end
    for i = 0, math.min(pal_entries, 256) - 1 do
        local idx = pal_start + i * 3
        local ci = color_start + i
        if ci <= 255 and idx + 2 <= #raw then
            palette[ci * 3 + 1] = raw:byte(idx)
            palette[ci * 3 + 2] = raw:byte(idx + 1)
            palette[ci * 3 + 3] = raw:byte(idx + 2)
        end
    end

    -- Compressed pixel data follows palette
    local pixel_data_start = pal_start + pal_byte_count
    local compressed = raw:sub(pixel_data_start)

    local pixels, pixel_count = decompress_spcn(compressed, dst_size)

    -- Determine dimensions
    local width, height
    if dst_size > 640 * 400 then
        width = 1280
    else
        width = 640
    end
    height = 400

    if dst_size ~= width * height and dst_size > 0 then
        height = math.floor(dst_size / width)
        if height == 0 then height = 1 end
    end

    local total = width * height
    local img_pixels = {}
    for i = 1, total do
        img_pixels[i] = pixels[i] or 0
    end

    local img = image_create_indexed(width, height, img_pixels, palette)

    return {
        type = "image",
        image = img,
        width = width,
        height = height,
        description = string.format(
            "%s — SPCN, %dx%d, %d palette entries, %d bytes decompressed",
            name, width, height, pal_entries, dst_size
        )
    }
end

-- ── CAF (Character Animation Format) decoder ───────────────────
-- Header: 68 bytes starting with "KevinAguilar"
-- All fields little-endian. Shows first frame of the animation.

function decode_caf_image(raw, name)
    -- Header fields (all u32le)
    local frame_header_size = u32le(raw, 17)   -- offset 16
    local uncomp_total      = u32le(raw, 21)   -- offset 20
    local comp_total        = u32le(raw, 25)   -- offset 24
    local num_frames        = u32le(raw, 29)   -- offset 28
    local glob_x1           = u32le(raw, 33)   -- offset 32
    local glob_y1           = u32le(raw, 37)   -- offset 36
    local glob_x2           = u32le(raw, 41)   -- offset 40
    local glob_y2           = u32le(raw, 45)   -- offset 44
    local pal_entries       = u32le(raw, 57)   -- offset 56
    local fps               = u32le(raw, 61)   -- offset 60
    local pal_size          = u32le(raw, 65)   -- offset 64

    if num_frames == 0 or frame_header_size < 32 then
        return { type = "text", text = string.format("CAF: %s\n%d frames (empty)", name, num_frames),
                 description = name .. " — CAF (empty)" }
    end

    -- Read palette (8-bit RGB, NOT 6-bit VGA) at offset 68
    local palette = {}
    local pal_off = 69  -- 1-based
    if pal_entries > 0 and pal_size > 0 then
        local n_colors = math.min(math.floor(pal_size / 3), 256)
        for i = 0, n_colors - 1 do
            local idx = pal_off + i * 3
            if idx + 2 <= #raw then
                palette[i * 3 + 1] = raw:byte(idx)
                palette[i * 3 + 2] = raw:byte(idx + 1)
                palette[i * 3 + 3] = raw:byte(idx + 2)
            else
                palette[i * 3 + 1] = i
                palette[i * 3 + 2] = i
                palette[i * 3 + 3] = i
            end
        end
        -- Fill remaining entries with greyscale
        for i = math.min(math.floor(pal_size / 3), 256), 255 do
            palette[i * 3 + 1] = i
            palette[i * 3 + 2] = i
            palette[i * 3 + 3] = i
        end
    else
        for i = 0, 255 do
            palette[i * 3 + 1] = i
            palette[i * 3 + 2] = i
            palette[i * 3 + 3] = i
        end
    end

    -- Frame data block starts after header + palette
    local frame_data_off = 69 + pal_size  -- 1-based

    -- Decompress the entire frame data block if needed
    local frame_data
    if comp_total < uncomp_total and frame_data_off <= #raw then
        local compressed = raw:sub(frame_data_off)
        frame_data, _ = decompress_lzss(compressed, uncomp_total)
    elseif frame_data_off <= #raw then
        -- Uncompressed: convert to table
        frame_data = {}
        local avail = math.min(uncomp_total, #raw - frame_data_off + 1)
        for i = 1, avail do
            frame_data[i] = raw:byte(frame_data_off + i - 1)
        end
    else
        return { type = "text", text = "CAF: frame data out of bounds",
                 description = name .. " — CAF (error)" }
    end

    -- Convert frame_data table to a string for u32le reads
    local fd_chars = {}
    for i = 1, #frame_data do
        fd_chars[i] = string.char(frame_data[i] or 0)
    end
    local fd_str = table.concat(fd_chars)

    -- Decode ALL frames for animation
    local fd_pos = 1  -- 1-based position in fd_str
    local decoded_frames = {}  -- table of {pixels, w, h, x1, y1}

    for fr = 0, num_frames - 1 do
        if fd_pos + frame_header_size > #fd_str then break end

        -- Frame header
        local sentinel = u32le(fd_str, fd_pos)
        if sentinel ~= 0x12345678 then break end

        local ref       = u32le(fd_str, fd_pos + 4)
        local comp_sz   = u32le(fd_str, fd_pos + 8)
        local decomp_sz = u32le(fd_str, fd_pos + 12)
        local fx1       = u32le(fd_str, fd_pos + 16)
        local fy1       = u32le(fd_str, fd_pos + 20)
        local fx2       = u32le(fd_str, fd_pos + 24)
        local fy2       = u32le(fd_str, fd_pos + 28)

        -- Treat as signed int32
        if fx1 >= 0x80000000 then fx1 = fx1 - 0x100000000 end
        if fy1 >= 0x80000000 then fy1 = fy1 - 0x100000000 end
        if fx2 >= 0x80000000 then fx2 = fx2 - 0x100000000 end
        if fy2 >= 0x80000000 then fy2 = fy2 - 0x100000000 end

        local fw = fx2 - fx1
        local fh = fy2 - fy1
        local pixel_off = fd_pos + frame_header_size

        if ref == 0xFFFFFFFF and decomp_sz > 0 and fw > 0 and fh > 0 then
            -- This frame has its own pixel data
            local pix_data
            if comp_sz < decomp_sz then
                local comp_str = fd_str:sub(pixel_off, pixel_off + comp_sz - 1)
                pix_data, _ = decompress_lzss(comp_str, decomp_sz)
            else
                pix_data = {}
                for i = 1, decomp_sz do
                    local p = pixel_off + i - 1
                    pix_data[i] = (p <= #fd_str) and fd_str:byte(p) or 0
                end
            end
            decoded_frames[#decoded_frames + 1] = { pixels = pix_data, w = fw, h = fh, x1 = fx1, y1 = fy1 }
        elseif ref ~= 0xFFFFFFFF then
            -- Reference frame: reuse an earlier decoded frame
            local ref_idx = ref + 1
            if ref_idx >= 1 and ref_idx <= #decoded_frames then
                decoded_frames[#decoded_frames + 1] = decoded_frames[ref_idx]
            end
        end

        -- Advance to next frame
        fd_pos = pixel_off + comp_sz
    end

    if #decoded_frames == 0 then
        return {
            type = "text",
            text = string.format("CAF: %s\n%d frames, no decodable frame found\nGlobal bbox: %d,%d - %d,%d",
                name, num_frames, glob_x1, glob_y1, glob_x2, glob_y2),
            description = string.format("%s - CAF (%d frames)", name, num_frames)
        }
    end

    -- Set palette index 0 to magenta for transparency
    palette[1] = 255
    palette[2] = 0
    palette[3] = 255

    -- Render all frames as images
    local frame_images = {}
    for i, frame in ipairs(decoded_frames) do
        local total = frame.w * frame.h
        local img_pixels = {}
        for j = 1, total do
            img_pixels[j] = frame.pixels[j] or 0
        end
        frame_images[i] = image_create_indexed(frame.w, frame.h, img_pixels, palette)
    end

    local delay_ms = (fps > 0) and math.floor(1000 / fps) or 100

    if #frame_images == 1 then
        return {
            type = "image",
            image = frame_images[1],
            width = decoded_frames[1].w,
            height = decoded_frames[1].h,
            description = string.format(
                "%s - CAF, 1 frame, %dx%d, %d palette entries",
                name, decoded_frames[1].w, decoded_frames[1].h, pal_entries
            )
        }
    end

    -- Multiple frames: create animation
    local anim = animation_create(frame_images, delay_ms)
    return {
        type = "animation",
        animation = anim,
        image = frame_images[1],
        frames = frame_images,
        description = string.format(
            "%s - CAF, %d frames, %dx%d, %d palette entries, %d fps",
            name, #frame_images, decoded_frames[1].w, decoded_frames[1].h, pal_entries, fps
        )
    }
end

return engine

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
                -- flag bit 1: back-reference
                if pos + 1 > len then break end
                local b1 = data:byte(pos)
                local b2 = data:byte(pos + 1)
                pos = pos + 2

                local copy_offset = b1 + (b2 % 16) * 256
                local copy_len = math.floor(b2 / 16) + 3

                for i = 1, copy_len do
                    if n >= expected_size then break end
                    local src_idx = n - copy_offset
                    if src_idx >= 1 and src_idx <= n then
                        n = n + 1
                        result[n] = result[src_idx]
                    else
                        n = n + 1
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

    -- Determine dimensions and palette location
    local width, height
    local pal_bytes = dst_size % 2048  -- lower bits indicate palette tail
    if pal_bytes == 0 then pal_bytes = 768 end

    local pal_entries = math.floor(pal_bytes / 3)
    local pixel_bytes = dst_size - pal_bytes

    if pixel_bytes > 640 * 400 then
        width = 1280
    else
        width = 640
    end
    height = 400

    -- Adjust if pixel data doesn't match 640x400 or 1280x400
    if pixel_bytes ~= width * height then
        -- Try to infer from actual data
        if pixel_bytes > 0 and pixel_bytes <= 1280 * 400 then
            height = math.floor(pixel_bytes / width)
            if height == 0 then height = 1 end
        end
    end

    -- Build palette (at end of decompressed data)
    local palette = {}
    if pal_entries >= 256 then
        local pal_start = pixel_bytes + 1
        for i = 0, 255 do
            local idx = pal_start + i * 3
            if idx + 2 <= pixel_count then
                palette[i * 3 + 1] = math.min((pixels[idx] or 0) * 4, 255)
                palette[i * 3 + 2] = math.min((pixels[idx + 1] or 0) * 4, 255)
                palette[i * 3 + 3] = math.min((pixels[idx + 2] or 0) * 4, 255)
            else
                palette[i * 3 + 1] = i
                palette[i * 3 + 2] = i
                palette[i * 3 + 3] = i
            end
        end
    else
        -- No full palette; use greyscale
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

    -- Read palette (starts at offset 16)
    local palette = {}
    local pal_start = 17  -- 1-indexed, byte 16 in 0-indexed
    for i = 0, 255 do
        if i < pal_entries then
            local idx = pal_start + i * 3
            if idx + 2 <= #raw then
                palette[i * 3 + 1] = math.min(raw:byte(idx) * 4, 255)
                palette[i * 3 + 2] = math.min(raw:byte(idx + 1) * 4, 255)
                palette[i * 3 + 3] = math.min(raw:byte(idx + 2) * 4, 255)
            else
                palette[i * 3 + 1] = i
                palette[i * 3 + 2] = i
                palette[i * 3 + 3] = i
            end
        else
            palette[i * 3 + 1] = i
            palette[i * 3 + 2] = i
            palette[i * 3 + 3] = i
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

return engine

-- ============================================================================
-- Adventure Explorer - Engine Script: Shadow of the Comet / Lovecraft Museum
-- ============================================================================
-- Infogrames (1993/1994). 320x200 256-color VGA.
-- Resources in .PAK files (PKWARE DCL Implode compression) and .CC4 files.
-- Based on ScummVM comet engine branch: github.com/sev-/scummvm/tree/comet
-- ============================================================================

local engine = {}
engine.name        = "Shadow of the Comet"
engine.id          = "comet"
engine.description = "Shadow of the Comet (1993) / Lovecraft Museum (1994) - Infogrames"
engine.version     = "1.0"

-- Binary helpers
local function u8(data, pos)   return data:byte(pos) end
local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end
local function u32le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536 + data:byte(pos + 3) * 16777216
end

-- ============================================================================
-- PKWARE DCL Implode decompressor
-- Based on ScummVM engines/comet/unpack.cpp (Pasi Ojala's gunzip.c)
-- ============================================================================

local function implode_decompress(src_data, flags, uncompressed_size)
    local src_pos = 1
    local bit_buf = 0
    local bit_buf_left = 0

    -- Sliding window buffer (32KB, 1-based)
    local buffer = {}
    for i = 1, 32768 do buffer[i] = 0 end
    local buf_pos = 1

    local output = {}
    local out_count = 0

    local function read_byte()
        if src_pos > #src_data then return 0 end
        local b = src_data:byte(src_pos)
        src_pos = src_pos + 1
        return b
    end

    local function read_bit()
        if bit_buf_left == 0 then
            bit_buf = read_byte()
            bit_buf_left = 8
        end
        local bit = bit_buf % 2
        bit_buf = math.floor(bit_buf / 2)
        bit_buf_left = bit_buf_left - 1
        return bit
    end

    local function read_bits(count)
        local res = 0
        for i = 0, count - 1 do
            res = res + read_bit() * (2 ^ i)
        end
        return res
    end

    local function put_byte(value)
        out_count = out_count + 1
        output[out_count] = value
        buffer[buf_pos] = value
        buf_pos = buf_pos + 1
        if buf_pos > 32768 then
            buf_pos = 1
        end
    end

    -- Huffman tree: array of nodes, each {b0, b1, jump}
    -- b0/b1 >= 0x8000 means "follow subtree", else it's a symbol value
    -- For b0 path (bit=1): subtree is at node_index+1
    -- For b1 path (bit=0): subtree is at node.jump
    local tree_nodes = {}
    -- Shared state for tree construction
    local tree_state = { next_idx = 0 }

    local function alloc_node()
        tree_state.next_idx = tree_state.next_idx + 1
        tree_nodes[tree_state.next_idx] = {b0 = 0, b1 = 0, jump = 0}
        return tree_state.next_idx
    end

    -- Recursive Huffman tree builder
    -- len_state = {val = current_len} (shared mutable reference)
    local function recreate_tree(cur_idx, len_state, fpos, flens, fmax)
        if len_state.val >= 17 then return end
        local cur_node = tree_nodes[cur_idx]
        len_state.val = len_state.val + 1

        -- b0 branch
        while true do
            if fpos[len_state.val] >= fmax then
                cur_node.b0 = 0x8000
                alloc_node()
                recreate_tree(tree_state.next_idx, len_state, fpos, flens, fmax)
                break
            end
            if flens[fpos[len_state.val]] == len_state.val then
                cur_node.b0 = fpos[len_state.val]
                fpos[len_state.val] = fpos[len_state.val] + 1
                break
            end
            fpos[len_state.val] = fpos[len_state.val] + 1
        end

        -- b1 branch
        while true do
            if fpos[len_state.val] >= fmax then
                cur_node.b1 = 0x8000
                local child_idx = alloc_node()
                cur_node.jump = child_idx
                recreate_tree(child_idx, len_state, fpos, flens, fmax)
                break
            end
            if flens[fpos[len_state.val]] == len_state.val then
                cur_node.b1 = fpos[len_state.val]
                fpos[len_state.val] = fpos[len_state.val] + 1
                cur_node.jump = 0
                break
            end
            fpos[len_state.val] = fpos[len_state.val] + 1
        end

        len_state.val = len_state.val - 1
    end

    -- Decode a value from a Huffman tree
    local function decode_value(root_idx)
        local node_idx = root_idx
        while true do
            local node = tree_nodes[node_idx]
            if read_bit() == 0 then
                -- b1 path
                if node.b1 < 0x8000 then
                    return node.b1
                end
                node_idx = node.jump
            else
                -- b0 path
                if node.b0 < 0x8000 then
                    return node.b0
                end
                node_idx = node_idx + 1
            end
        end
    end

    -- Build a Huffman tree from the bitstream, returns root index
    local function create_tree()
        local root = alloc_node()
        local fpos = {}
        for i = 0, 16 do fpos[i] = 0 end
        local lengths = {}
        local lengths_count = 0
        local tree_bytes = read_byte() + 1
        for i = 1, tree_bytes do
            local a = read_byte()
            local bit_values = math.floor(a / 16) + 1
            local bit_length = (a % 16) + 1
            for j = 1, bit_values do
                lengths[lengths_count] = bit_length
                lengths_count = lengths_count + 1
            end
        end
        local len_state = {val = 0}
        recreate_tree(root, len_state, fpos, lengths, lengths_count)
        return root
    end

    -- Determine parameters from flags
    local min_match_len = (math.floor(flags / 4) % 2 == 1) and 3 or 2
    local dist_bits = (math.floor(flags / 2) % 2 == 1) and 7 or 6
    local has_literal_tree = (math.floor(flags / 4) % 2 == 1)

    -- Build Huffman trees
    local literal_tree = nil
    if has_literal_tree then
        literal_tree = create_tree()
    end
    local length_tree = create_tree()
    local distance_tree = create_tree()

    -- Main decompression loop
    while out_count < uncompressed_size do
        if read_bit() == 1 then
            -- Literal byte
            if has_literal_tree then
                put_byte(decode_value(literal_tree))
            else
                put_byte(read_bits(8))
            end
        else
            -- Distance/length pair
            local distance = read_bits(dist_bits)
            distance = distance + decode_value(distance_tree) * (2 ^ dist_bits)
            distance = distance + 1
            local len = decode_value(length_tree)
            if len == 63 then
                len = len + read_bits(8)
            end
            len = len + min_match_len
            for i = 1, len do
                if out_count >= uncompressed_size then break end
                local src_idx = ((buf_pos - 1 - distance) % 32768) + 1
                put_byte(buffer[src_idx])
            end
        end
    end

    return output
end

-- ============================================================================
-- PAK file parser
-- PAK format: offset table (u32le[]) then entries with headers
-- Entry header: u32le unknown, u32le discSize, u32le uncompressedSize,
--               byte compressionType, byte flags, u16le nameLen, char[nameLen]
-- Resource index i has its offset at file position (i+1)*4
-- ============================================================================

-- Directly load a single PAK entry by index (like ScummVM does)
local function load_pak_entry_by_index(f, index)
    local fsize = file_size(f)
    local seek_pos = (index + 1) * 4
    if seek_pos + 4 > fsize then return nil end

    local pos_data = file_read(f, seek_pos, 4)
    if not pos_data or #pos_data < 4 then return nil end
    local offset = u32le(pos_data, 1)
    if offset + 16 > fsize then return nil end

    local hdr_data = file_read(f, offset, math.min(32, fsize - offset))
    if not hdr_data or #hdr_data < 16 then return nil end

    local disc_size   = u32le(hdr_data, 5)
    local uncomp_size = u32le(hdr_data, 9)
    local comp_type   = u8(hdr_data, 13)
    local comp_flags  = u8(hdr_data, 14)
    local name_len    = u16le(hdr_data, 15)

    if comp_type > 1 then return nil end

    local name = ""
    if name_len > 0 and name_len < 256 then
        local hdr_size = 16 + name_len
        local full_hdr = file_read(f, offset, math.min(hdr_size, fsize - offset))
        if full_hdr and #full_hdr >= hdr_size then
            for c = 17, 16 + name_len do
                local b = full_hdr:byte(c)
                if not b or b == 0 then break end
                name = name .. string.char(b)
            end
        end
    end

    return {
        index       = index,
        offset      = offset,
        data_offset = offset + 16 + name_len,
        disc_size   = disc_size,
        uncomp_size = uncomp_size,
        comp_type   = comp_type,
        comp_flags  = comp_flags,
        name        = name
    }
end

-- Determine how many resources a PAK file contains
local function pak_resource_count(f)
    local fsize = file_size(f)
    if fsize < 8 then return 0 end

    -- Find the smallest offset in the table to determine where data starts.
    -- Read the first few u32le values; the minimum tells us the table boundary.
    local scan_size = math.min(fsize, 4096)
    local scan_data = file_read(f, 0, scan_size)
    if not scan_data then return 0 end

    local min_offset = fsize
    local i = 0
    while true do
        local pos = i * 4 + 1  -- 1-based in scan_data
        if pos + 3 > #scan_data then break end
        local val = u32le(scan_data, pos)
        if val > 0 and val < min_offset then
            min_offset = val
        end
        -- Stop once we've scanned past the data boundary
        if (i + 1) * 4 >= min_offset then break end
        i = i + 1
    end

    -- Resources are at positions 4, 8, ..., min_offset-4
    -- (position 0 is a sentinel/unused in PakResourceLoader)
    local count = math.floor(min_offset / 4) - 1
    if count < 0 then count = 0 end
    return count
end

-- Parse all PAK entries (for resource tree building)
local function parse_pak_entries(f)
    local count = pak_resource_count(f)
    if count < 1 then return nil end

    local entries = {}
    for i = 0, count - 1 do
        local entry = load_pak_entry_by_index(f, i)
        if entry then
            entries[#entries + 1] = entry
        end
    end

    if #entries == 0 then return nil end
    return entries
end

-- Extract and optionally decompress a PAK entry
local function extract_pak_entry(f, entry)
    local fsize = file_size(f)
    if entry.data_offset + entry.disc_size > fsize then return nil end

    local raw = file_read(f, entry.data_offset, entry.disc_size)
    if not raw or #raw < entry.disc_size then return nil end

    if entry.comp_type == 0 then
        return raw
    elseif entry.comp_type == 1 then
        local result = implode_decompress(raw, entry.comp_flags, entry.uncomp_size)
        if not result then return nil end
        local chars = {}
        for i = 1, #result do
            chars[i] = string.char(result[i] % 256)
        end
        return table.concat(chars)
    end
    return nil
end

-- Load and extract a PAK resource by (file_handle, index)
local function extract_pak_by_index(f, index)
    local entry = load_pak_entry_by_index(f, index)
    if not entry then return nil end
    return extract_pak_entry(f, entry), entry
end

-- ============================================================================
-- CC4 file parser
-- CC4 format: flat offset table of u32le values, then raw data blocks
-- Resource i at offset[i], size = offset[i+1] - offset[i]
-- ============================================================================

local function parse_cc4_entries(f)
    local fsize = file_size(f)
    if fsize < 4 then return nil end

    local first4 = file_read(f, 0, 4)
    if not first4 or #first4 < 4 then return nil end
    local first_offset = u32le(first4, 1)

    if first_offset < 4 or first_offset >= fsize then return nil end

    local num_entries = math.floor(first_offset / 4)
    if num_entries < 1 or num_entries > 10000 then return nil end

    local offset_data = file_read(f, 0, first_offset)
    if not offset_data then return nil end

    local entries = {}
    for i = 0, num_entries - 1 do
        local pos = i * 4 + 1
        if pos + 3 > #offset_data then break end
        local offset = u32le(offset_data, pos)
        local next_offset
        if i < num_entries - 1 then
            next_offset = u32le(offset_data, pos + 4)
        else
            next_offset = fsize
        end
        local data_size = next_offset - offset
        if data_size > 0 and offset < fsize then
            entries[#entries + 1] = {
                index     = i,
                offset    = offset,
                data_size = data_size
            }
        end
    end

    return entries
end

-- ============================================================================
-- Sub-resource extraction from decompressed PAK blob (floppy format)
-- The decompressed blob has an internal offset table: array of u32le values.
-- Sub-resource i starts at offset[i], size = offset[i+1] - offset[i].
-- Based on ScummVM ResourceManager::loadRawFromRaw().
-- ============================================================================

local function extract_raw_sub_resource(raw_data, sub_index, max_count)
    if not raw_data or #raw_data < (sub_index + 1) * 4 then return nil end

    local offset = u32le(raw_data, sub_index * 4 + 1)
    local next_offset
    if sub_index < max_count then
        next_offset = u32le(raw_data, (sub_index + 1) * 4 + 1)
    else
        next_offset = #raw_data
    end

    local data_size = next_offset - offset
    if data_size <= 0 or offset + data_size > #raw_data then return nil end

    return raw_data:sub(offset + 1, offset + data_size)
end

-- ============================================================================
-- Palette loading
-- Floppy: RES.PAK entry 0 → decompress → sub-index 5 within blob
-- CD: RES.PAK entry 5 directly
-- VGA 6-bit palette (0-63 per component), 768 bytes
-- ============================================================================

local cached_palette = nil
local cached_palette_path = nil

local function raw_palette_to_8bit(pal_data)
    local palette = {}
    for i = 0, 255 do
        local r = u8(pal_data, i * 3 + 1)
        local g = u8(pal_data, i * 3 + 2)
        local b = u8(pal_data, i * 3 + 3)
        palette[i * 3 + 1] = math.min(r, 255)
        palette[i * 3 + 2] = math.min(g, 255)
        palette[i * 3 + 3] = math.min(b, 255)
    end
    return palette
end

local function load_game_palette(game_path)
    if cached_palette and cached_palette_path == game_path then
        return cached_palette
    end

    local f = file_open(game_path .. "/RES.PAK")
    if not f then
        log_warn("comet: cannot open RES.PAK for palette")
        return nil
    end

    local count = pak_resource_count(f)
    local pal_data = nil

    if count <= 1 then
        -- Floppy version: single compressed blob, sub-resources inside
        -- Load entry 0, decompress, then extract sub-index 5 (palette)
        local blob = extract_pak_by_index(f, 0)
        file_close(f)
        if blob and #blob > 24 then
            -- max_count = 6: sub-indices 0-6 (font, bubble, hero, icon, inv, palette, flashbak)
            pal_data = extract_raw_sub_resource(blob, 5, 6)
        end
    else
        -- CD version: palette is a separate PAK entry at index 5
        pal_data = extract_pak_by_index(f, 5)
        file_close(f)
    end

    if not pal_data or #pal_data < 768 then
        log_warn("comet: palette data invalid (got " ..
            (pal_data and tostring(#pal_data) or "nil") .. " bytes, need 768)")
        return nil
    end

    local palette = raw_palette_to_8bit(pal_data)
    cached_palette = palette
    cached_palette_path = game_path
    return palette
end

-- ============================================================================
-- Animation sprite decompression
-- Based on ScummVM engines/comet/graphics.cpp drawAnimationCelSprite
-- Each row: u8 chunks, per chunk: {skip, count_hi, count_lo} + pixels,
-- then 1 padding byte. Pixel count = count_hi*4 + count_lo.
-- AnimationCel header: u16le flags, u8 width/16, u8 height, then data.
-- ============================================================================

local function decompress_cel_sprite(data, data_pos, width, height)
    -- data_pos is 1-based position of the sprite row data
    local pixels = {}
    for i = 1, width * height do pixels[i] = 0 end

    local src = data_pos
    for y = 0, height - 1 do
        if src > #data then break end
        local chunks = u8(data, src); src = src + 1
        local x = 0
        for c = 1, chunks do
            if src + 2 > #data then break end
            local skip = u8(data, src)
            local count_hi = u8(data, src + 1)
            local count_lo = u8(data, src + 2)
            src = src + 3
            local count = count_hi * 4 + count_lo
            x = x + skip
            for p = 1, count do
                if src > #data then break end
                if x >= 0 and x < width then
                    pixels[y * width + x + 1] = u8(data, src)
                end
                src = src + 1
                x = x + 1
            end
        end
        src = src + 1  -- padding byte
    end

    return pixels
end

-- ============================================================================
-- Animation resource parser
-- Animations have 4 sections accessed via offset table:
--   Section 0: Elements (groups of draw commands)
--   Section 1: Cels (bitmap sprites)
--   Section 2: Frame lists (animation sequences)
--   Section 3: unused
-- Each section starts with its own sub-offset table (loadOffsets pattern).
-- ============================================================================

-- Read an offset table: first u32 = first offset, count = first/4
local function read_offsets(data, base_pos)
    -- base_pos is 1-based position in data
    if base_pos + 3 > #data then return nil end
    local first = u32le(data, base_pos)
    local count = math.floor(first / 4)
    if count < 1 or count > 10000 then return nil end

    local offsets = {}
    for i = 0, count - 1 do
        local pos = base_pos + i * 4
        if pos + 3 > #data then break end
        offsets[i] = u32le(data, pos)
    end
    return offsets, count
end

local function parse_animation(data)
    if #data < 16 then return nil end

    -- Read section offsets
    local section_offsets, section_count = read_offsets(data, 1)
    if not section_offsets or section_count < 3 then return nil end

    local result = { cels = {}, elements = {} }

    -- ---- Section 1: Cels ----
    local cels_base = section_offsets[1]
    if cels_base and cels_base + 4 <= #data then
        local cel_offsets, cel_count = read_offsets(data, cels_base + 1)
        if cel_offsets and cel_count > 0 then
            -- Determine section 2 start for sizing the last cel
            local section2_end = section_offsets[2] or #data
            -- Add a sentinel offset for computing last cel's data size
            cel_offsets[cel_count] = section2_end - cels_base

            for i = 0, cel_count - 1 do
                -- ScummVM: stream.seek(sectionOffsets[1] + offsets[i] - 2)
                -- celDataSize = offsets[i+1] - offsets[i] - 2
                local abs_pos = cels_base + cel_offsets[i] - 2 + 1  -- +1 for Lua 1-based
                local cel_data_size = cel_offsets[i + 1] - cel_offsets[i] - 2

                if abs_pos > 0 and abs_pos + 3 <= #data and cel_data_size > 0 then
                    local cel_flags = u16le(data, abs_pos)
                    local w = u8(data, abs_pos + 2) * 16
                    local h = u8(data, abs_pos + 3)

                    if w > 0 and w <= 320 and h > 0 and h <= 200 then
                        result.cels[#result.cels + 1] = {
                            index = i,
                            flags = cel_flags,
                            width = w,
                            height = h,
                            data_pos = abs_pos + 4,  -- sprite data starts after 4-byte header
                            data_size = cel_data_size
                        }
                    end
                end
            end
        end
    end

    -- ---- Section 0: Elements ----
    local elem_base = section_offsets[0]
    if elem_base and elem_base + 4 <= #data then
        local elem_offsets, elem_count = read_offsets(data, elem_base + 1)
        if elem_offsets and elem_count > 0 then
            for i = 0, elem_count - 1 do
                -- ScummVM: stream.seek(sectionOffsets[0] + offsets[i] - 2)
                local abs_pos = elem_base + elem_offsets[i] - 2 + 1
                if abs_pos > 0 and abs_pos + 3 <= #data then
                    local elem_width = u8(data, abs_pos)
                    local elem_height = u8(data, abs_pos + 1)
                    local elem_flags = u8(data, abs_pos + 2)
                    local cmd_count = u8(data, abs_pos + 3)

                    local commands = {}
                    local cmd_pos = abs_pos + 4
                    local pt_as_byte = (math.floor(elem_flags / 16) % 2 == 1) -- flags & 0x10

                    for j = 1, cmd_count do
                        if cmd_pos + 3 > #data then break end
                        local cmd_type = u8(data, cmd_pos)
                        local points_count = u8(data, cmd_pos + 1)
                        local arg1 = u8(data, cmd_pos + 2)
                        local arg2 = u8(data, cmd_pos + 3)
                        cmd_pos = cmd_pos + 4

                        local points = {}
                        for p = 1, points_count do
                            if pt_as_byte then
                                if cmd_pos + 1 > #data then break end
                                local px = u8(data, cmd_pos)
                                local py = u8(data, cmd_pos + 1)
                                if px >= 128 then px = px - 256 end
                                if py >= 128 then py = py - 256 end
                                points[p] = {x = px, y = py}
                                cmd_pos = cmd_pos + 2
                            else
                                if cmd_pos + 3 > #data then break end
                                local px = u16le(data, cmd_pos)
                                local py = u16le(data, cmd_pos + 2)
                                if px >= 32768 then px = px - 65536 end
                                if py >= 32768 then py = py - 65536 end
                                points[p] = {x = px, y = py}
                                cmd_pos = cmd_pos + 4
                            end
                        end

                        commands[#commands + 1] = {
                            cmd = cmd_type,
                            arg1 = arg1,
                            arg2 = arg2,
                            points = points
                        }
                    end

                    result.elements[#result.elements + 1] = {
                        index = i,
                        width = elem_width,
                        height = elem_height,
                        flags = elem_flags,
                        commands = commands
                    }
                end
            end
        end
    end

    return result
end

-- Render an animation element composited onto a canvas
-- Commands kActCelSprite(1) draw cel sprites at positions
local function render_element(anim, elem_index, canvas_w, canvas_h, palette)
    local elem = nil
    for _, e in ipairs(anim.elements) do
        if e.index == elem_index then elem = e; break end
    end
    if not elem then return nil end

    local pixels = {}
    for i = 1, canvas_w * canvas_h do pixels[i] = 0 end

    for _, cmd in ipairs(elem.commands) do
        -- kActCelSprite = 1, kActCelRle = 10, kActElement = 0
        if cmd.cmd == 1 and #cmd.points > 0 then
            -- arg1 + arg2*256 gives cel index (& 0x0FFF)
            local cel_index = (cmd.arg1 + cmd.arg2 * 256) % 4096
            local cel = nil
            for _, c in ipairs(anim.cels) do
                if c.index == cel_index then cel = c; break end
            end
            if cel then
                local cx = cmd.points[1].x
                local cy = cmd.points[1].y - cel.height + 1
                local cel_pixels = decompress_cel_sprite(
                    -- need the full data - passed via anim.raw_data
                    anim.raw_data, cel.data_pos, cel.width, cel.height)

                -- Blit cel onto canvas (skip color 0 = transparent)
                for sy = 0, cel.height - 1 do
                    local dy = cy + sy
                    if dy >= 0 and dy < canvas_h then
                        for sx = 0, cel.width - 1 do
                            local dx = cx + sx
                            if dx >= 0 and dx < canvas_w then
                                local pixel = cel_pixels[sy * cel.width + sx + 1]
                                if pixel ~= 0 then
                                    pixels[dy * canvas_w + dx + 1] = pixel
                                end
                            end
                        end
                    end
                end
            end
        elseif cmd.cmd == 0 and #cmd.points > 0 then
            -- kActElement: recursively draw sub-element
            local sub_index = (cmd.arg1 + cmd.arg2 * 256) % 4096
            local sub_elem = nil
            for _, e in ipairs(anim.elements) do
                if e.index == sub_index then sub_elem = e; break end
            end
            if sub_elem then
                local ox = cmd.points[1].x
                local oy = cmd.points[1].y
                for _, sub_cmd in ipairs(sub_elem.commands) do
                    if sub_cmd.cmd == 1 and #sub_cmd.points > 0 then
                        local cel_index = (sub_cmd.arg1 + sub_cmd.arg2 * 256) % 4096
                        local cel = nil
                        for _, c in ipairs(anim.cels) do
                            if c.index == cel_index then cel = c; break end
                        end
                        if cel then
                            local cx = ox + sub_cmd.points[1].x
                            local cy = oy + sub_cmd.points[1].y - cel.height + 1
                            local cel_pixels = decompress_cel_sprite(
                                anim.raw_data, cel.data_pos, cel.width, cel.height)
                            for sy = 0, cel.height - 1 do
                                local dy = cy + sy
                                if dy >= 0 and dy < canvas_h then
                                    for sx = 0, cel.width - 1 do
                                        local dx = cx + sx
                                        if dx >= 0 and dx < canvas_w then
                                            local pixel = cel_pixels[sy * cel.width + sx + 1]
                                            if pixel ~= 0 then
                                                pixels[dy * canvas_w + dx + 1] = pixel
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return pixels
end

-- ============================================================================
-- VOC header parser (Creative Voice File)
-- ============================================================================

local function parse_voc_info(data)
    -- VOC signature: "Creative Voice File\x1A" (20 bytes)
    -- First byte may be \0 instead of 'C' (game quirk)
    if #data < 26 then return nil end
    local sig_start = 2  -- skip first byte (may be \0)
    local expected = "reative Voice File"
    local found = data:sub(sig_start, sig_start + #expected - 1)
    if found ~= expected then return nil end

    local header_size = u16le(data, 21)
    local version = u16le(data, 23)
    local ver_major = math.floor(version / 256)
    local ver_minor = version % 256

    -- Parse data blocks to get total samples and sample rate
    local pos = header_size + 1  -- 1-based
    local total_samples = 0
    local sample_rate = 0

    while pos <= #data do
        local block_type = u8(data, pos)
        if block_type == 0 then break end  -- terminator

        if pos + 3 > #data then break end
        local block_size = u8(data, pos + 1)
            + u8(data, pos + 2) * 256
            + u8(data, pos + 3) * 65536
        pos = pos + 4

        if block_type == 1 then
            -- Sound data block
            if pos + 1 <= #data then
                local freq_div = u8(data, pos)
                local codec = u8(data, pos + 1)
                if sample_rate == 0 then
                    sample_rate = math.floor(1000000 / (256 - freq_div))
                end
                total_samples = total_samples + block_size - 2
            end
        elseif block_type == 9 then
            -- Extended sound data (VOC v1.20+)
            if pos + 11 <= #data then
                sample_rate = u32le(data, pos)
                local bits = u8(data, pos + 4)
                local channels = u8(data, pos + 5) + 1
                total_samples = total_samples + block_size - 12
            end
        end

        pos = pos + block_size
    end

    local duration = 0
    if sample_rate > 0 then
        duration = total_samples / sample_rate
    end

    return {
        version = string.format("%d.%02d", ver_major, ver_minor),
        sample_rate = sample_rate,
        total_samples = total_samples,
        duration = duration

    }
end

-- ============================================================================
-- Decode VOC to raw PCM bytes + sample rate
-- ============================================================================

local function decode_voc_pcm(data)
    if #data < 26 then return nil end
    local sig_start = 2
    local expected = "reative Voice File"
    local found = data:sub(sig_start, sig_start + #expected - 1)
    if found ~= expected then return nil end

    local header_size = u16le(data, 21)
    local pos = header_size + 1
    local sample_rate = 0
    local pcm_parts = {}

    while pos <= #data do
        local block_type = u8(data, pos)
        if block_type == 0 then break end
        if pos + 3 > #data then break end
        local block_size = u8(data, pos + 1)
            + u8(data, pos + 2) * 256
            + u8(data, pos + 3) * 65536
        pos = pos + 4

        if block_type == 1 then
            if pos + 1 <= #data then
                local freq_div = u8(data, pos)
                if sample_rate == 0 then
                    sample_rate = math.floor(1000000 / (256 - freq_div))
                end
                local pcm_len = block_size - 2
                if pcm_len > 0 and pos + 2 + pcm_len - 1 <= #data then
                    pcm_parts[#pcm_parts + 1] = data:sub(pos + 2, pos + 2 + pcm_len - 1)
                end
            end
        elseif block_type == 9 then
            if pos + 11 <= #data then
                sample_rate = u32le(data, pos)
                local pcm_len = block_size - 12
                if pcm_len > 0 and pos + 12 + pcm_len - 1 <= #data then
                    pcm_parts[#pcm_parts + 1] = data:sub(pos + 12, pos + 12 + pcm_len - 1)
                end
            end
        end
        pos = pos + block_size
    end

    if #pcm_parts == 0 or sample_rate == 0 then return nil end
    return table.concat(pcm_parts), sample_rate
end

-- ============================================================================
-- Hex dump helper
-- ============================================================================

local function hex_dump(data, max_bytes)
    max_bytes = max_bytes or 256
    local dump_len = math.min(#data, max_bytes)
    local lines = {}
    for row = 0, math.floor((dump_len - 1) / 16) do
        local line = string.format("%04X: ", row * 16)
        local ascii = ""
        for col = 0, 15 do
            local idx = row * 16 + col + 1
            if idx <= dump_len then
                line = line .. string.format("%02X ", u8(data, idx))
                local ch = u8(data, idx)
                if ch >= 32 and ch < 127 then
                    ascii = ascii .. string.char(ch)
                else
                    ascii = ascii .. "."
                end
            else
                line = line .. "   "
            end
        end
        lines[#lines + 1] = line .. " " .. ascii
    end
    return table.concat(lines, "\n")
end

-- ============================================================================
-- Detection
-- ============================================================================

local function is_comet(game_path)
    return file_exists(game_path .. "/r00.cc4") or file_exists(game_path .. "/R00.CC4")
end

function engine.detect(game_path)
    return is_comet(game_path)
end

-- ============================================================================
-- Resource tree
-- ============================================================================

function engine.get_resources(game_path)
    local files = list_files(game_path)
    if not files then return {} end

    local resources = {}
    local pak_files = {}
    local cc4_files = {}

    for _, fname in ipairs(files) do
        local lower = fname:lower()
        if lower:match("%.pak$") then
            pak_files[#pak_files + 1] = fname
        elseif lower:match("%.cc4$") then
            cc4_files[#cc4_files + 1] = fname
        end
    end

    table.sort(pak_files, function(a, b) return a:lower() < b:lower() end)
    table.sort(cc4_files, function(a, b) return a:lower() < b:lower() end)

    -- --- PAK files ---
    for _, pak_name in ipairs(pak_files) do
        local f = file_open(game_path .. "/" .. pak_name)
        if f then
            local entries = parse_pak_entries(f)
            local lower = pak_name:lower()
            local is_res = (lower == "res.pak")

            -- Floppy RES.PAK: single blob with sub-resources inside
            if is_res and entries and #entries == 1 then
                file_close(f)
                local res_names = {
                    [0] = "Font",
                    [1] = "Bubble Sprite",
                    [2] = "Hero Sprite",
                    [3] = "Icon Sprite",
                    [4] = "Inventory Sprites",
                    [5] = "Game Palette",
                    [6] = "Flashback Palette"
                }
                local cat = {
                    id = "pak_" .. pak_name,
                    name = pak_name .. " - Global Resources (7 sub-resources)",
                    type = "category",
                    children = {}
                }
                for si = 0, 6 do
                    local res_type = "image"
                    if si == 5 or si == 6 then res_type = "palette" end
                    cat.children[#cat.children + 1] = {
                        id   = string.format("respak_sub_%d", si),
                        name = string.format("[%d] %s", si, res_names[si]),
                        type = res_type
                    }
                end
                resources[#resources + 1] = cat

            elseif entries and #entries > 0 then
                file_close(f)
                local is_scene = lower:match("^d%d+%.pak$")
                local is_anim = lower:match("^a%d+%.pak$")
                local is_smp = (lower == "smp.pak")

                local cat = {
                    id = "pak_" .. pak_name,
                    name = pak_name,
                    type = "category",
                    children = {}
                }

                if is_scene then
                    local mod_num = lower:match("^d(%d+)")
                    cat.name = string.format("%s - Module %s Scenes (%d entries)",
                        pak_name, mod_num, #entries)
                elseif is_anim then
                    local mod_num = lower:match("^a(%d+)")
                    cat.name = string.format("%s - Module %s Animations (%d entries)",
                        pak_name, mod_num, #entries)
                elseif is_smp then
                    cat.name = string.format("%s - Sound Effects (%d entries)",
                        pak_name, #entries)
                else
                    cat.name = string.format("%s (%d entries)", pak_name, #entries)
                end

                for _, e in ipairs(entries) do
                    local label
                    if e.name and #e.name > 0 then
                        label = string.format("[%d] %s", e.index, e.name)
                    else
                        label = string.format("[%d]", e.index)
                    end

                    local size_str
                    if e.comp_type == 1 then
                        size_str = string.format("%dB->%dB", e.disc_size, e.uncomp_size)
                    else
                        size_str = string.format("%dB", e.disc_size)
                    end

                    local res_type = "image"
                    if is_scene then
                        if e.index % 2 == 0 then
                            label = label .. " (Background)"
                        else
                            label = label .. " (Decoration)"
                            res_type = "animation"
                        end
                    elseif is_anim then
                        res_type = "animation"
                    elseif is_smp then
                        res_type = "sound"
                        label = label .. " (Sound)"
                    end

                    cat.children[#cat.children + 1] = {
                        id   = string.format("pak_%s_%d", pak_name, e.index),
                        name = string.format("%s (%s)", label, size_str),
                        type = res_type
                    }
                end

                resources[#resources + 1] = cat
            else
                file_close(f)
            end
        end
    end

    -- --- CC4 files ---
    if #cc4_files > 0 then
        local cc4_cat = {
            id = "cc4_files",
            name = "CC4 Data Files",
            type = "category",
            children = {}
        }

        for _, cc4_name in ipairs(cc4_files) do
            local f = file_open(game_path .. "/" .. cc4_name)
            if f then
                local entries = parse_cc4_entries(f)
                file_close(f)
                if entries and #entries > 0 then
                    local sub_cat = {
                        id = "cc4_" .. cc4_name,
                        name = string.format("%s (%d entries)", cc4_name, #entries),
                        type = "category",
                        children = {}
                    }

                    for _, e in ipairs(entries) do
                        sub_cat.children[#sub_cat.children + 1] = {
                            id   = string.format("cc4_%s_%d", cc4_name, e.index),
                            name = string.format("[%d] (%dB)", e.index, e.data_size),
                            type = "image"
                        }
                    end

                    cc4_cat.children[#cc4_cat.children + 1] = sub_cat
                end
            end
        end

        if #cc4_cat.children > 0 then
            resources[#resources + 1] = cc4_cat
        end
    end

    return resources
end

-- ============================================================================
-- PAK resource loader helpers
-- ============================================================================

local function get_or_make_palette(game_path)
    local palette = load_game_palette(game_path)
    if palette then return palette end
    -- Grayscale fallback
    palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = i
        palette[i * 3 + 2] = i
        palette[i * 3 + 3] = i
    end
    return palette
end

-- Load a sub-resource from floppy RES.PAK (decompressed blob, internal offsets)
local function load_respak_sub_resource(game_path, sub_index)
    local f = file_open(game_path .. "/RES.PAK")
    if not f then
        return { type = "text", text = "Cannot open RES.PAK" }
    end

    local blob = extract_pak_by_index(f, 0)
    file_close(f)

    if not blob then
        return { type = "text", text = "Failed to decompress RES.PAK entry 0" }
    end

    local data = extract_raw_sub_resource(blob, sub_index, 6)
    if not data then
        return { type = "text", text = string.format(
            "Failed to extract sub-resource %d from RES.PAK", sub_index) }
    end

    local res_names = {
        [0] = "Font", [1] = "Bubble Sprite", [2] = "Hero Sprite",
        [3] = "Icon Sprite", [4] = "Inventory Sprites",
        [5] = "Game Palette", [6] = "Flashback Palette"
    }
    local name = res_names[sub_index] or string.format("Sub-resource %d", sub_index)

    -- Palette (768 bytes)
    if (sub_index == 5 or sub_index == 6) and #data >= 768 then
        local pal = raw_palette_to_8bit(data)
        local pw, ph = 256, 256
        local pixels = {}
        for y = 0, ph - 1 do
            local row = math.floor(y / 16)
            for x = 0, pw - 1 do
                local col = math.floor(x / 16)
                pixels[y * pw + x + 1] = row * 16 + col
            end
        end
        local img = image_create_indexed(pw, ph, pixels, pal)
        return {
            type = "image", image = img,
            description = string.format("%s (%d bytes) - 256 colors, 6-bit VGA", name, #data)
        }
    end

    -- Animation sub-resources (indices 1-4)
    if sub_index >= 1 and sub_index <= 4 and #data >= 16 then
        local anim = parse_animation(data)
        if anim and #anim.cels > 0 then
            anim.raw_data = data
            local palette = get_or_make_palette(game_path)

            -- Render all cels as sprite sheet
            local max_h = 0
            local total_w = 0
            local cel_images = {}
            for ci = 1, #anim.cels do
                local cel = anim.cels[ci]
                local pix = decompress_cel_sprite(data, cel.data_pos, cel.width, cel.height)
                cel_images[ci] = { pixels = pix, w = cel.width, h = cel.height }
                total_w = total_w + cel.width
                if cel.height > max_h then max_h = cel.height end
            end

            if total_w > 0 and max_h > 0 then
                local sheet = {}
                for i = 1, total_w * max_h do sheet[i] = 0 end
                local x_off = 0
                for ci = 1, #cel_images do
                    local ci_data = cel_images[ci]
                    local y_off = max_h - ci_data.h
                    for sy = 0, ci_data.h - 1 do
                        for sx = 0, ci_data.w - 1 do
                            local pixel = ci_data.pixels[sy * ci_data.w + sx + 1]
                            if pixel ~= 0 then
                                local dy = y_off + sy
                                local dx = x_off + sx
                                sheet[dy * total_w + dx + 1] = pixel
                            end
                        end
                    end
                    x_off = x_off + ci_data.w
                end
                local img = image_create_indexed(total_w, max_h, sheet, palette)
                return {
                    type = "image", image = img,
                    description = string.format("%s - %d cels, sheet %dx%d",
                        name, #anim.cels, total_w, max_h)
                }
            end
        end
    end

    -- Generic fallback
    local info = string.format("RES.PAK Sub-resource %d: %s\n", sub_index, name)
    info = info .. string.format("Size: %d bytes\n\n", #data)
    info = info .. hex_dump(data)
    return { type = "text", text = info }
end

-- ============================================================================
-- Resource loading
-- ============================================================================

function engine.load_resource(game_path, resource_id)
    -- Floppy RES.PAK sub-resource
    local sub_idx = resource_id:match("^respak_sub_(%d+)$")
    if sub_idx then
        return load_respak_sub_resource(game_path, tonumber(sub_idx))
    end

    local res_type, filename, index_str = resource_id:match("^(pak)_(.+)_(%d+)$")
    if not res_type then
        res_type, filename, index_str = resource_id:match("^(cc4)_(.+)_(%d+)$")
    end
    if not res_type or not filename or not index_str then
        return { type = "text", text = "Invalid resource ID: " .. resource_id }
    end

    local res_index = tonumber(index_str)

    if res_type == "pak" then
        return load_pak_resource(game_path, filename, res_index)
    elseif res_type == "cc4" then
        return load_cc4_resource(game_path, filename, res_index)
    end

    return nil
end

function load_pak_resource(game_path, pak_name, res_index)
    local f = file_open(game_path .. "/" .. pak_name)
    if not f then
        return { type = "text", text = "Cannot open " .. pak_name }
    end

    -- Direct extraction by index
    local data, entry = extract_pak_by_index(f, res_index)
    file_close(f)

    if not data then
        return { type = "text", text = string.format(
            "Failed to extract entry %d from %s", res_index, pak_name) }
    end

    local lower = pak_name:lower()
    local is_scene_pak = lower:match("^d%d+%.pak$")
    local is_anim_pak = lower:match("^a%d+%.pak$")
    local is_smp = (lower == "smp.pak")

    -- === Scene background (64000 bytes = 320x200 raw pixels) ===
    if #data == 64000 then
        local palette = get_or_make_palette(game_path)
        local pixels = {}
        for i = 1, 64000 do
            pixels[i] = u8(data, i)
        end
        local img = image_create_indexed(320, 200, pixels, palette)
        local mod_num = lower:match("^d(%d+)") or "?"
        return {
            type = "image", image = img,
            description = string.format("Module %s - Background %d (320x200, 256 colors)",
                mod_num, res_index)
        }
    end

    -- === Palette data (768 bytes) ===
    if #data == 768 then
        local pal = raw_palette_to_8bit(data)
        local pw, ph = 256, 256
        local pixels = {}
        for y = 0, ph - 1 do
            local row = math.floor(y / 16)
            for x = 0, pw - 1 do
                local col = math.floor(x / 16)
                pixels[y * pw + x + 1] = row * 16 + col
            end
        end
        local img = image_create_indexed(pw, ph, pixels, pal)
        return {
            type = "image", image = img,
            description = string.format("Palette (%d bytes) - 256 colors, 6-bit VGA", #data)
        }
    end

    -- === Sound effects (VOC format in SMP.PAK) ===
    if is_smp then
        -- Fix VOC header quirk: first byte \0 -> 'C'
        local fixed = "C" .. data:sub(2)
        local pcm_data, sr = decode_voc_pcm(fixed)
        if pcm_data and sr > 0 then
            local sound = sound_create_pcm(sr, 8, 1, false, pcm_data)
            if sound then
                local voc_info = parse_voc_info(fixed)
                local desc = string.format("VOC Sound - SMP.PAK[%d]", res_index)
                if voc_info then
                    desc = desc .. string.format(
                        "\nFormat: Creative Voice File v%s\nSample Rate: %d Hz\nDuration: %.2f seconds",
                        voc_info.version, voc_info.sample_rate, voc_info.duration)
                end
                return { type = "sound", sound = sound, description = desc }
            end
        end
        -- Fallback to text info
        local voc_info = parse_voc_info(fixed)
        if voc_info then
            local info = string.format("VOC Sound Effect - SMP.PAK[%d]\n\n", res_index)
            info = info .. string.format("Format: Creative Voice File v%s\n", voc_info.version)
            info = info .. string.format("Sample Rate: %d Hz\n", voc_info.sample_rate)
            info = info .. string.format("Samples: %d\n", voc_info.total_samples)
            info = info .. string.format("Duration: %.2f seconds\n", voc_info.duration)
            info = info .. string.format("Data Size: %d bytes\n", #data)
            return { type = "text", text = info }
        else
            local info = string.format("Sound Effect - SMP.PAK[%d]\n", res_index)
            info = info .. string.format("Data Size: %d bytes\n\n", #data)
            info = info .. hex_dump(data, 128)
            return { type = "text", text = info }
        end
    end

    -- === Animation / Decoration sprites ===
    -- Odd indices in dNN.pak are decorations, aNN.pak entries are animations
    local is_decoration = is_scene_pak and (res_index % 2 == 1)
    local try_animation = is_decoration or is_anim_pak

    if try_animation and #data >= 16 then
        local anim = parse_animation(data)
        if anim and #anim.cels > 0 then
            anim.raw_data = data  -- store for cel decompression

            if is_decoration and #anim.elements > 0 then
                -- Decoration: render each element as a frame
                local palette = get_or_make_palette(game_path)
                local handles = {}
                for ei = 0, #anim.elements - 1 do
                    local pixels = render_element(anim, ei, 320, 200, palette)
                    if pixels then
                        handles[#handles + 1] = image_create_indexed(320, 200, pixels, palette)
                    end
                end
                if #handles > 0 then
                    local mod_num = lower:match("^d(%d+)") or "?"
                    if #handles == 1 then
                        return {
                            type = "image", image = handles[1],
                            description = string.format(
                                "Module %s - Decoration %d (%d elements, %d cels)",
                                mod_num, res_index, #anim.elements, #anim.cels)
                        }
                    else
                        local anim_handle = animation_create(handles, 150)
                        return {
                            type = "animation",
                            animation = anim_handle,
                            delay_ms = 150,
                            description = string.format(
                                "Module %s - Decoration %d (%d elements, %d cels)",
                                mod_num, res_index, #anim.elements, #anim.cels)
                        }
                    end
                end
            end

            -- Render each cel as an individual animation frame
            local palette = get_or_make_palette(game_path)
            local handles = {}

            for ci = 1, #anim.cels do
                local cel = anim.cels[ci]
                local pix = decompress_cel_sprite(data, cel.data_pos, cel.width, cel.height)
                if pix then
                    local frame_pixels = {}
                    for i = 1, cel.width * cel.height do
                        frame_pixels[i] = pix[i] or 0
                    end
                    handles[#handles + 1] = image_create_indexed(cel.width, cel.height, frame_pixels, palette)
                end
            end

            if #handles > 0 then
                local desc = string.format(
                    "Animation - %s[%d]\n%d cels, %d elements",
                    pak_name, res_index, #anim.cels, #anim.elements)
                if #handles == 1 then
                    return { type = "image", image = handles[1], description = desc }
                else
                    local anim_handle = animation_create(handles, 150)
                    return {
                        type = "animation",
                        animation = anim_handle,
                        delay_ms = 150,
                        description = desc
                    }
                end
            end
        end
    end

    -- === Try as partial background (any 320xH raw data) ===
    if #data > 32000 and #data <= 64000 then
        local h = math.floor(#data / 320)
        if h > 0 and h <= 200 then
            local palette = get_or_make_palette(game_path)
            local pixels = {}
            for i = 1, 320 * h do
                pixels[i] = u8(data, i)
            end
            local img = image_create_indexed(320, h, pixels, palette)
            return {
                type = "image", image = img,
                description = string.format("Image data: 320x%d (%d bytes)", h, #data)
            }
        end
    end

    -- === Generic hex dump fallback ===
    local info = string.format("PAK Entry %d from %s\n", res_index, pak_name)
    if entry then
        info = info .. string.format("Compression: %s\n",
            entry.comp_type == 0 and "None" or "PKWARE Implode")
        info = info .. string.format("Disc size: %d bytes\n", entry.disc_size)
        info = info .. string.format("Uncompressed size: %d bytes\n", entry.uncomp_size)
        if entry.name and #entry.name > 0 then
            info = info .. string.format("Name: %s\n", entry.name)
        end
    end
    info = info .. string.format("Data size: %d bytes\n\n", #data)
    info = info .. hex_dump(data)
    return { type = "text", text = info }
end

-- ============================================================================
-- CC4 resource loader
-- ============================================================================

function load_cc4_resource(game_path, cc4_name, res_index)
    local f = file_open(game_path .. "/" .. cc4_name)
    if not f then
        return { type = "text", text = "Cannot open " .. cc4_name }
    end

    local fsize = file_size(f)
    local entries = parse_cc4_entries(f)
    if not entries then
        file_close(f)
        return { type = "text", text = "Cannot parse CC4: " .. cc4_name }
    end

    local target = nil
    for _, e in ipairs(entries) do
        if e.index == res_index then target = e; break end
    end
    if not target then
        file_close(f)
        return { type = "text", text = string.format("Entry %d not found in %s", res_index, cc4_name) }
    end

    local data = file_read(f, target.offset, target.data_size)
    file_close(f)

    if not data then
        return { type = "text", text = "Failed to read CC4 entry" }
    end

    local lower = cc4_name:lower()
    local is_text = lower:match("^[a-z]%.cc4$")
    local is_script = lower:match("^r%d+%.cc4$")

    -- === Text resource (ScummVM TextResource format) ===
    -- Structure: offset table (unencrypted), then text data (encrypted)
    -- Encryption only applies to text data after firstOffs
    if is_text and #data >= 8 then
        local first_offs = u32le(data, 1)
        local str_count = math.floor(first_offs / 4)

        if str_count > 0 and str_count < 10000 and first_offs < #data then
            -- Read string offsets (these are NOT encrypted)
            local str_offsets = {}
            str_offsets[0] = 0
            for i = 1, str_count - 1 do
                local pos = i * 4 + 1
                if pos + 3 <= #data then
                    str_offsets[i] = u32le(data, pos) - first_offs
                end
            end
            str_offsets[str_count] = #data - first_offs

            -- Read and decrypt text data (everything after first_offs)
            local text_size = #data - first_offs
            local text_start = first_offs + 1  -- 1-based position

            local decrypted = {}
            for i = 0, text_size - 1 do
                local src_pos = text_start + i
                if src_pos <= #data then
                    -- data[i] -= 0x54 * (i + 1), where i is 0-based within text block
                    decrypted[i] = (u8(data, src_pos) - 0x54 * (i + 1)) % 256
                end
            end

            local info = string.format("Text Resource from %s[%d]\n", cc4_name, res_index)
            info = info .. string.format("%d strings:\n\n", str_count)

            for i = 0, math.min(str_count - 1, 199) do
                local start_off = str_offsets[i]
                local end_off = str_offsets[i + 1]

                if start_off and end_off and start_off >= 0 and end_off <= text_size then
                    local str = ""
                    -- +1 to skip the '*' terminator of the previous string
                    for j = start_off + 1, end_off - 1 do
                        local b = decrypted[j]
                        if b and b >= 32 and b < 127 then
                            str = str .. string.char(b)
                        elseif b == 0 or b == nil then
                            break
                        else
                            str = str .. "."
                        end
                    end
                    if #str > 0 then
                        info = info .. string.format("[%d] %s\n", i, str)
                    end
                end
            end

            return { type = "text", text = info }
        end
    end

    -- === Generic hex dump ===
    local info = string.format("CC4 Entry %d from %s\n", res_index, cc4_name)
    info = info .. string.format("Offset: 0x%X, Size: %d bytes\n\n", target.offset, target.data_size)

    if is_script then
        info = info .. "Script data\n\n"
    end

    info = info .. hex_dump(data)

    return { type = "text", text = info }
end

return engine

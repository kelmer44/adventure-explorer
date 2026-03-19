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

local function parse_pak_entries(f)
    local fsize = file_size(f)
    if fsize < 8 then return nil end

    -- Read first two offsets to determine entry count
    local hdr = file_read(f, 0, 8)
    if not hdr or #hdr < 8 then return nil end

    local val0 = u32le(hdr, 1)  -- offset table entry 0 (not a resource)
    local val1 = u32le(hdr, 5)  -- offset for resource 0

    -- Validate: val1 should be a reasonable file offset
    if val1 < 8 or val1 >= fsize or val1 % 4 ~= 0 then return nil end

    -- Resource i's offset is at position (i+1)*4, so the table runs from
    -- position 0 to val1-4. Number of resources = val1/4 - 1.
    local num_resources = math.floor(val1 / 4) - 1

    if num_resources < 1 or num_resources > 10000 then
        -- Fallback: use val0 as count indicator
        num_resources = math.floor(val0 / 4) - 1
        if num_resources < 1 or num_resources > 10000 then
            return nil
        end
    end

    -- Read the full offset table
    local table_size = (num_resources + 1) * 4
    local offset_data = file_read(f, 0, math.min(table_size, fsize))
    if not offset_data then return nil end

    local entries = {}
    for i = 0, num_resources - 1 do
        local pos = (i + 1) * 4 + 1  -- 1-based position for resource i
        if pos + 3 > #offset_data then break end
        local offset = u32le(offset_data, pos)
        if offset >= fsize then break end

        -- Read the entry header at the offset
        local hdr_data = file_read(f, offset, math.min(32, fsize - offset))
        if not hdr_data or #hdr_data < 16 then break end

        local unknown      = u32le(hdr_data, 1)
        local disc_size    = u32le(hdr_data, 5)
        local uncomp_size  = u32le(hdr_data, 9)
        local comp_type    = u8(hdr_data, 13)
        local comp_flags   = u8(hdr_data, 14)
        local name_len     = u16le(hdr_data, 15)

        -- Validate
        if comp_type > 1 then break end
        if disc_size > fsize then break end

        -- Read name if present
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

        -- Data starts after the header
        local data_offset = offset + 16 + name_len

        entries[#entries + 1] = {
            index       = i,
            offset      = offset,
            data_offset = data_offset,
            disc_size   = disc_size,
            uncomp_size = uncomp_size,
            comp_type   = comp_type,
            comp_flags  = comp_flags,
            name        = name
        }
    end

    return entries
end

-- Extract and optionally decompress a PAK entry
local function extract_pak_entry(f, entry)
    local fsize = file_size(f)
    if entry.data_offset + entry.disc_size > fsize then return nil end

    local raw = file_read(f, entry.data_offset, entry.disc_size)
    if not raw or #raw < entry.disc_size then return nil end

    if entry.comp_type == 0 then
        -- Uncompressed
        return raw
    elseif entry.comp_type == 1 then
        -- PKWARE DCL Implode
        local result = implode_decompress(raw, entry.comp_flags, entry.uncomp_size)
        if not result then return nil end
        -- Convert array to string
        local chars = {}
        for i = 1, #result do
            chars[i] = string.char(result[i] % 256)
        end
        return table.concat(chars)
    end
    return nil
end

-- ============================================================================
-- CC4 file parser
-- CC4 format: offset table of u32le values, then raw data blocks
-- Resource i is at offset[i], size = offset[i+1] - offset[i]
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

    -- Read full offset table
    local offset_data = file_read(f, 0, first_offset)
    if not offset_data then return nil end

    local entries = {}
    for i = 0, num_entries - 1 do
        local pos = i * 4 + 1  -- 1-based
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
-- Palette loading - from RES.PAK index 5
-- VGA 6-bit palette (0-63 per component), 768 bytes
-- ============================================================================

local cached_palette = nil
local cached_palette_path = nil

local function load_game_palette(game_path)
    if cached_palette and cached_palette_path == game_path then
        return cached_palette
    end

    local f = file_open(game_path .. "/RES.PAK")
    if not f then return nil end

    local entries = parse_pak_entries(f)
    if not entries then
        file_close(f)
        return nil
    end

    -- Palette is at index 5 in RES.PAK
    local pal_entry = nil
    for _, e in ipairs(entries) do
        if e.index == 5 then pal_entry = e; break end
    end

    if not pal_entry then
        file_close(f)
        return nil
    end

    local pal_data = extract_pak_entry(f, pal_entry)
    file_close(f)

    if not pal_data or #pal_data < 768 then return nil end

    -- Convert 6-bit VGA palette to 8-bit
    local palette = {}
    for i = 0, 255 do
        local r = u8(pal_data, i * 3 + 1)
        local g = u8(pal_data, i * 3 + 2)
        local b = u8(pal_data, i * 3 + 3)
        -- Scale 6-bit (0-63) to 8-bit (0-255): multiply by 4, cap at 255
        palette[i * 3 + 1] = math.min(r * 4, 255)
        palette[i * 3 + 2] = math.min(g * 4, 255)
        palette[i * 3 + 3] = math.min(b * 4, 255)
    end

    cached_palette = palette
    cached_palette_path = game_path
    return palette
end

-- Also try loading alternate palettes from RES.PAK
-- Index 5 = gamePalette, Index 6 = flashbakPal
-- Index 7 = introPalette1, Index 8 = introPalette2
local function load_palette_by_index(game_path, pal_index)
    local f = file_open(game_path .. "/RES.PAK")
    if not f then return nil end
    local entries = parse_pak_entries(f)
    if not entries then file_close(f); return nil end

    local pal_entry = nil
    for _, e in ipairs(entries) do
        if e.index == pal_index then pal_entry = e; break end
    end
    if not pal_entry then file_close(f); return nil end

    local pal_data = extract_pak_entry(f, pal_entry)
    file_close(f)
    if not pal_data or #pal_data < 768 then return nil end

    local palette = {}
    for i = 0, 255 do
        local r = u8(pal_data, i * 3 + 1)
        local g = u8(pal_data, i * 3 + 2)
        local b = u8(pal_data, i * 3 + 3)
        palette[i * 3 + 1] = math.min(r * 4, 255)
        palette[i * 3 + 2] = math.min(g * 4, 255)
        palette[i * 3 + 3] = math.min(b * 4, 255)
    end
    return palette
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

    -- Collect PAK files (dNN.pak = backgrounds, aNN.pak = animations, RES.PAK, SMP.PAK)
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

    -- --- PAK files (scene backgrounds and animations) ---
    for _, pak_name in ipairs(pak_files) do
        local f = file_open(game_path .. "/" .. pak_name)
        if f then
            local entries = parse_pak_entries(f)
            file_close(f)
            if entries and #entries > 0 then
                local lower = pak_name:lower()
                local is_scene = lower:match("^d%d+%.pak$")
                local is_anim = lower:match("^a%d+%.pak$")

                local cat = {
                    id = "pak_" .. pak_name,
                    name = pak_name,
                    type = "category",
                    children = {}
                }

                -- Add a label based on file type
                if is_scene then
                    local mod_num = lower:match("^d(%d+)")
                    cat.name = string.format("%s - Module %s Backgrounds (%d entries)",
                        pak_name, mod_num, #entries)
                elseif is_anim then
                    local mod_num = lower:match("^a(%d+)")
                    cat.name = string.format("%s - Module %s Animations (%d entries)",
                        pak_name, mod_num, #entries)
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

                    -- Determine resource type hint
                    local res_type = "image"
                    if is_scene then
                        -- Even indices are backgrounds, odd are decoration sprites
                        if e.index % 2 == 0 then
                            label = label .. " (Background)"
                        else
                            label = label .. " (Decoration)"
                        end
                    end

                    cat.children[#cat.children + 1] = {
                        id   = string.format("pak_%s_%d", pak_name, e.index),
                        name = string.format("%s (%s)", label, size_str),
                        type = res_type
                    }
                end

                resources[#resources + 1] = cat
            end
        end
    end

    -- --- CC4 files (scripts, text) ---
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
-- Resource loading
-- ============================================================================

function engine.load_resource(game_path, resource_id)
    -- Parse resource ID: pak_FILENAME_INDEX or cc4_FILENAME_INDEX
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

    local entries = parse_pak_entries(f)
    if not entries then
        file_close(f)
        return { type = "text", text = "Cannot parse PAK: " .. pak_name }
    end

    -- Find the entry with the matching index
    local target = nil
    for _, e in ipairs(entries) do
        if e.index == res_index then target = e; break end
    end
    if not target then
        file_close(f)
        return { type = "text", text = string.format("Entry %d not found in %s", res_index, pak_name) }
    end

    -- Extract data
    local data = extract_pak_entry(f, target)
    file_close(f)

    if not data then
        return { type = "text", text = string.format(
            "Failed to extract entry %d from %s (comp=%d, disc=%d, uncomp=%d)",
            res_index, pak_name, target.comp_type, target.disc_size, target.uncomp_size) }
    end

    -- Determine what kind of resource this is based on filename pattern and data size
    local lower = pak_name:lower()
    local is_scene_pak = lower:match("^d%d+%.pak$")

    -- --- Scene background (64000 bytes = 320x200 raw pixels) ---
    if #data == 64000 then
        local palette = load_game_palette(game_path)
        if not palette then
            -- Fallback: grayscale
            palette = {}
            for i = 0, 255 do
                palette[i * 3 + 1] = i
                palette[i * 3 + 2] = i
                palette[i * 3 + 3] = i
            end
        end

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

    -- --- Palette data (768 bytes) ---
    if #data == 768 then
        -- Display as a palette swatch (16x16 grid of colors)
        local pal = {}
        for i = 0, 255 do
            local r = u8(data, i * 3 + 1)
            local g = u8(data, i * 3 + 2)
            local b = u8(data, i * 3 + 3)
            pal[i * 3 + 1] = math.min(r * 4, 255)
            pal[i * 3 + 2] = math.min(g * 4, 255)
            pal[i * 3 + 3] = math.min(b * 4, 255)
        end

        -- Create a 256x256 palette preview (16x16 blocks of 16x16 pixels each)
        local pw, ph = 256, 256
        local pixels = {}
        for y = 0, ph - 1 do
            local row = math.floor(y / 16)
            for x = 0, pw - 1 do
                local col = math.floor(x / 16)
                local color_idx = row * 16 + col
                pixels[y * pw + x + 1] = color_idx
            end
        end

        local img = image_create_indexed(pw, ph, pixels, pal)
        return {
            type = "image", image = img,
            description = string.format("Palette (%d bytes) - 256 colors, 6-bit VGA", #data)
        }
    end

    -- --- Try to interpret as a background with non-standard size ---
    -- Some entries might be slightly different sizes
    if #data > 32000 and #data <= 64000 then
        local palette = load_game_palette(game_path)
        if not palette then
            palette = {}
            for i = 0, 255 do
                palette[i * 3 + 1] = i
                palette[i * 3 + 2] = i
                palette[i * 3 + 3] = i
            end
        end

        -- Try to display as 320xH where H = data_size / 320
        local h = math.floor(#data / 320)
        if h > 0 and h <= 200 then
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

    -- --- Generic data: show hex dump ---
    local info = string.format("PAK Entry %d from %s\n", res_index, pak_name)
    info = info .. string.format("Compression: %s\n",
        target.comp_type == 0 and "None" or "PKWARE Implode")
    info = info .. string.format("Disc size: %d bytes\n", target.disc_size)
    info = info .. string.format("Uncompressed size: %d bytes\n", target.uncomp_size)
    if target.name and #target.name > 0 then
        info = info .. string.format("Name: %s\n", target.name)
    end
    info = info .. string.format("\nData size: %d bytes\n", #data)

    -- Show first 256 bytes as hex dump
    info = info .. "\nHex dump (first 256 bytes):\n"
    local dump_len = math.min(#data, 256)
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
        info = info .. line .. " " .. ascii .. "\n"
    end

    return { type = "text", text = info }
end

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

    -- Find the entry
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

    -- CC4 files contain scripts (rNN.cc4) or text (e.cc4, d.cc4, etc.)
    local lower = cc4_name:lower()
    local is_text = lower:match("^[a-z]%.cc4$")
    local is_script = lower:match("^r%d+%.cc4$")

    if is_text then
        -- Text resource: entire block is encrypted with data[i] -= 0x54*(i+1)
        -- Must decrypt ALL bytes first, then parse offset table from decrypted data
        -- (ScummVM TextResource constructor decrypts before reading _count)

        -- Decrypt entire block (i is 1-based in Lua, matching 0x54*(0+1) for C's i=0)
        local dec_chars = {}
        for i = 1, #data do
            dec_chars[i] = string.char((data:byte(i) - 0x54 * i) % 256)
        end
        local dec = table.concat(dec_chars)

        if #dec >= 4 then
            -- Decrypted structure: u32le count, then count u32le offsets, then string data
            local str_count = u32le(dec, 1)

            if str_count > 0 and str_count < 10000 then
                local info = string.format("Text Resource from %s[%d]\n", cc4_name, res_index)
                info = info .. string.format("%d strings:\n\n", str_count)

                for i = 0, math.min(str_count - 1, 99) do
                    local offs_pos = (i + 1) * 4 + 1  -- 1-based position for offset i
                    if offs_pos + 3 <= #dec then
                        local offs = u32le(dec, offs_pos)
                        -- String at dec[offs] (0-based offset), null-terminated
                        local str = ""
                        for j = offs + 1, #dec do  -- 1-based
                            local b = dec:byte(j)
                            if b == 0 then break end
                            if b >= 32 and b < 127 then
                                str = str .. string.char(b)
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
    end

    -- Generic: show hex dump
    local info = string.format("CC4 Entry %d from %s\n", res_index, cc4_name)
    info = info .. string.format("Offset: 0x%X, Size: %d bytes\n\n", target.offset, target.data_size)

    if is_script then
        info = info .. "Script data\n\n"
    end

    -- Hex dump
    info = info .. "Hex dump (first 256 bytes):\n"
    local dump_len = math.min(#data, 256)
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
        info = info .. line .. " " .. ascii .. "\n"
    end

    return { type = "text", text = info }
end

return engine

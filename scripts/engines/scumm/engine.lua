-- ============================================================================
-- Adventure Explorer - Engine Script: SCUMM V5 (1991-1993, DOS VGA)
-- ============================================================================
-- Reads SCUMM V5 data files (.000 index + .001 data)
-- XOR 0x69 encrypted (V5 DOS games: Monkey Island 2, Indiana Jones 4, etc.)
-- IFF-like block structure: 4-byte ASCII tag + 4-byte BE size
-- Room backgrounds: strip-based compression (SMAP), 8px wide vertical strips
-- Palettes: CLUT block, 256 * 3 bytes RGB (full 8-bit values)
-- ============================================================================

local engine = {}

engine.name        = "SCUMM"
engine.id          = "scumm"
engine.description = "SCUMM V5 (LucasArts, 1991-1993)"
engine.version     = "1.0"

local band   = bit32.band
local bor    = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local bxor   = bit32.bxor

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

local function tag4(data, pos)
    return data:sub(pos, pos + 3)
end

-- ── XOR decryption ──────────────────────────────────────────────

local function xor_decrypt(data, key)
    if key == 0 then return data end
    local bytes = {}
    for i = 1, #data do
        bytes[i] = string.char(bxor(data:byte(i), key))
    end
    return table.concat(bytes)
end

-- Read and decrypt a chunk from a file handle
local function read_decrypt(f, offset, length, key)
    local raw = file_read(f, offset, length)
    if not raw then return nil end
    return xor_decrypt(raw, key)
end

-- ── IFF block scanning ──────────────────────────────────────────
-- Scan a decrypted data region for IFF blocks (tag + BE size)
-- Returns list of {tag, offset_in_data, size, data_offset}

local function scan_blocks(data, start_pos, end_pos)
    local blocks = {}
    local pos = start_pos
    if not end_pos then end_pos = #data end

    while pos + 8 <= end_pos do
        local t = tag4(data, pos)
        local sz = u32be(data, pos + 4)
        if sz < 8 or pos + sz - 1 > end_pos then break end
        blocks[#blocks + 1] = {
            tag = t,
            offset = pos,         -- position of tag in data
            size = sz,            -- total block size (including 8-byte header)
            data_start = pos + 8  -- position of payload
        }
        pos = pos + sz
    end

    return blocks
end

-- Find the first block with a given tag
local function find_block(blocks, tag_name)
    for _, b in ipairs(blocks) do
        if b.tag == tag_name then return b end
    end
    return nil
end

-- ── Index file parsing ──────────────────────────────────────────
-- V5 index: blocks RNAM, MAXS, DROO, DSCR, DSOU, DCOS, DCHR, DOBJ

local function parse_index(data)
    local result = { room_names = {} }
    local blocks = scan_blocks(data, 1, #data)

    -- RNAM: room names (u8 id, 9 bytes name XOR 0xFF, ... until id==0)
    local rnam = find_block(blocks, "RNAM")
    if rnam then
        local pos = rnam.data_start
        local limit = rnam.offset + rnam.size
        while pos + 10 <= limit do
            local room_id = u8(data, pos)
            if room_id == 0 then break end
            local name_bytes = {}
            for j = 1, 9 do
                local b = bxor(u8(data, pos + j), 0xFF)
                if b == 0 then break end
                name_bytes[#name_bytes + 1] = string.char(b)
            end
            result.room_names[room_id] = table.concat(name_bytes)
            pos = pos + 10
        end
    end

    -- DROO: room directory (u16le count, count bytes file_numbers, count u32le offsets)
    local droo = find_block(blocks, "DROO")
    if droo then
        local pos = droo.data_start
        local count = u16le(data, pos)
        result.room_count = count
        result.room_files = {}
        result.room_offsets = {}
        for i = 0, count - 1 do
            result.room_files[i] = u8(data, pos + 2 + i)
        end
        for i = 0, count - 1 do
            result.room_offsets[i] = u32le(data, pos + 2 + count + i * 4)
        end
    end

    return result
end

-- ── Data file: LOFF room table ──────────────────────────────────
-- LECF container → first child is LOFF with room offset table

local function parse_loff(data)
    local rooms = {}
    -- Find LECF
    if tag4(data, 1) ~= "LECF" then return rooms end
    -- Scan inside LECF for LOFF
    local lecf_size = u32be(data, 5)
    local inner_blocks = scan_blocks(data, 9, math.min(lecf_size, #data))
    local loff = find_block(inner_blocks, "LOFF")
    if not loff then return rooms end

    local pos = loff.data_start
    local num_rooms = u8(data, pos)
    pos = pos + 1

    for i = 1, num_rooms do
        if pos + 5 > #data then break end
        local room_id = u8(data, pos)
        local offset  = u32le(data, pos + 1)
        pos = pos + 5
        if room_id > 0 and offset > 0 then
            rooms[#rooms + 1] = { id = room_id, offset = offset }
        end
    end

    return rooms
end

-- ── Room parsing ────────────────────────────────────────────────
-- LOFF offsets point directly to ROOM blocks (no LFLF wrapper in V5 DOS)

local function parse_room(data, room_offset, data_size)
    local result = {}

    -- Read block at room_offset (1-indexed, convert from 0-based file offset)
    local block_pos = room_offset + 1
    if block_pos + 8 > data_size then return nil end

    local block_tag  = tag4(data, block_pos)
    local block_size = u32be(data, block_pos + 4)

    -- Handle both LFLF-wrapped rooms and bare ROOM blocks
    local room_block_pos
    if block_tag == "LFLF" then
        -- Scan inside LFLF for ROOM
        local lflf_end = block_pos + block_size - 1
        local inner = scan_blocks(data, block_pos + 8, lflf_end)
        local rb = find_block(inner, "ROOM")
        if not rb then return nil end
        room_block_pos = rb.offset
        block_size = rb.size
    elseif block_tag == "ROOM" then
        room_block_pos = block_pos
    else
        log_warn("Expected ROOM or LFLF at offset " .. room_offset .. ", got " .. block_tag)
        return nil
    end

    local room_end = room_block_pos + block_size - 1
    local room_blocks = scan_blocks(data, room_block_pos + 8, room_end)

    -- RMHD: room header
    local rmhd = find_block(room_blocks, "RMHD")
    if rmhd then
        result.width  = u16le(data, rmhd.data_start)
        result.height = u16le(data, rmhd.data_start + 2)
        result.num_objects = u16le(data, rmhd.data_start + 4)
    end

    -- TRNS: transparent color
    local trns = find_block(room_blocks, "TRNS")
    if trns then
        result.transparent_color = u16le(data, trns.data_start)
    end

    -- CLUT: palette (8-byte header + 256*3 bytes)
    local clut = find_block(room_blocks, "CLUT")
    if clut then
        result.palette = {}
        local pal_pos = clut.data_start
        for i = 0, 255 do
            local idx = pal_pos + i * 3
            if idx + 2 <= #data then
                result.palette[i * 3 + 1] = u8(data, idx)
                result.palette[i * 3 + 2] = u8(data, idx + 1)
                result.palette[i * 3 + 3] = u8(data, idx + 2)
            else
                result.palette[i * 3 + 1] = i
                result.palette[i * 3 + 2] = i
                result.palette[i * 3 + 3] = i
            end
        end
    end

    -- RMIM → IM00 → SMAP
    local rmim = find_block(room_blocks, "RMIM")
    if rmim then
        local rmim_end = rmim.offset + rmim.size - 1
        local rmim_blocks = scan_blocks(data, rmim.data_start, rmim_end)

        local im00 = find_block(rmim_blocks, "IM00")
        if im00 then
            local im00_end = im00.offset + im00.size - 1
            local im00_blocks = scan_blocks(data, im00.data_start, im00_end)

            local smap = find_block(im00_blocks, "SMAP")
            if smap then
                result.smap_offset = smap.offset  -- absolute position in data
                result.smap_size   = smap.size
            end
        end
    end

    return result
end

-- ── SMAP strip decompression ────────────────────────────────────

-- Decode a single strip using ZIGZAG_H (horizontal scan, codes 24-28, 44-48)
local function decode_strip_zigzag_h(strip_data, height, decomp_shr, decomp_mask, transparent, trans_color)
    local pixels = {}
    local n = 0
    local pos = 1  -- codec byte already consumed, strip_data starts after it

    local color = u8(strip_data, pos); pos = pos + 1
    local bits  = u8(strip_data, pos); pos = pos + 1
    local cl    = 8
    local inc   = -1
    local len   = #strip_data

    for row = 1, height do
        for x = 1, 8 do
            -- FILL_BITS
            if cl <= 8 and pos <= len then
                bits = bor(bits, lshift(u8(strip_data, pos), cl))
                pos = pos + 1
                cl = cl + 8
            end

            -- Write pixel
            n = n + 1
            if transparent and color == trans_color then
                pixels[n] = trans_color  -- keep transparent
            else
                pixels[n] = color
            end

            -- Decision tree for next color
            local b0 = band(bits, 1)
            bits = rshift(bits, 1)
            cl = cl - 1

            if b0 ~= 0 then
                -- bit=1: something changes
                local b1 = band(bits, 1)
                bits = rshift(bits, 1)
                cl = cl - 1

                if b1 == 0 then
                    -- bits=10: read new color
                    if cl <= 8 and pos <= len then
                        bits = bor(bits, lshift(u8(strip_data, pos), cl))
                        pos = pos + 1
                        cl = cl + 8
                    end
                    color = band(bits, decomp_mask)
                    bits = rshift(bits, decomp_shr)
                    cl = cl - decomp_shr
                    inc = -1
                else
                    -- bits=11x
                    local b2 = band(bits, 1)
                    bits = rshift(bits, 1)
                    cl = cl - 1

                    if b2 == 0 then
                        -- bits=110: small step
                        color = band(color + inc, 0xFF)
                    else
                        -- bits=111: reverse + step
                        inc = -inc
                        color = band(color + inc, 0xFF)
                    end
                end
            end
            -- bit=0: color unchanged
        end
    end

    return pixels
end

-- Decode a single strip using ZIGZAG_V (vertical scan, codes 14-18, 34-38)
local function decode_strip_zigzag_v(strip_data, height, decomp_shr, decomp_mask, transparent, trans_color)
    local pixels = {}
    -- Initialize to 0
    for i = 1, 8 * height do pixels[i] = 0 end

    local pos = 1
    local color = u8(strip_data, pos); pos = pos + 1
    local bits  = u8(strip_data, pos); pos = pos + 1
    local cl    = 8
    local inc   = -1
    local len   = #strip_data

    for col = 0, 7 do
        for row = 0, height - 1 do
            -- FILL_BITS
            if cl <= 8 and pos <= len then
                bits = bor(bits, lshift(u8(strip_data, pos), cl))
                pos = pos + 1
                cl = cl + 8
            end

            -- Write pixel
            local idx = row * 8 + col + 1
            if transparent and color == trans_color then
                pixels[idx] = trans_color
            else
                pixels[idx] = color
            end

            -- Decision tree (same as ZIGZAG_H)
            local b0 = band(bits, 1)
            bits = rshift(bits, 1)
            cl = cl - 1

            if b0 ~= 0 then
                local b1 = band(bits, 1)
                bits = rshift(bits, 1)
                cl = cl - 1

                if b1 == 0 then
                    if cl <= 8 and pos <= len then
                        bits = bor(bits, lshift(u8(strip_data, pos), cl))
                        pos = pos + 1
                        cl = cl + 8
                    end
                    color = band(bits, decomp_mask)
                    bits = rshift(bits, decomp_shr)
                    cl = cl - decomp_shr
                    inc = -1
                else
                    local b2 = band(bits, 1)
                    bits = rshift(bits, 1)
                    cl = cl - 1

                    if b2 == 0 then
                        color = band(color + inc, 0xFF)
                    else
                        inc = -inc
                        color = band(color + inc, 0xFF)
                    end
                end
            end
        end
    end

    return pixels
end

-- Decode a single strip using MAJMIN_H (complex codec, codes 64-68, 84-88, 104-108, 124-128)
local function decode_strip_complex(strip_data, height, decomp_shr, transparent, trans_color)
    local pixels = {}
    local pos = 1
    local len = #strip_data

    local color   = u8(strip_data, pos); pos = pos + 1
    -- Read 16-bit initial bits (LE)
    local lo = (pos <= len) and u8(strip_data, pos) or 0; pos = pos + 1
    local hi = (pos <= len) and u8(strip_data, pos) or 0; pos = pos + 1
    local bits    = bor(lo, lshift(hi, 8))
    local numBits = 16

    local repeatMode  = false
    local repeatCount = 0

    local function fill()
        if numBits <= 8 and pos <= len then
            bits = bor(bits, lshift(u8(strip_data, pos), numBits))
            pos = pos + 1
            numBits = numBits + 8
        end
    end

    local function readBits(n)
        fill()
        local mask = lshift(1, n) - 1
        local val = band(bits, mask)
        bits = rshift(bits, n)
        numBits = numBits - n
        return val
    end

    local n = 0
    for row = 1, height do
        for x = 1, 8 do
            n = n + 1
            if transparent and color == trans_color then
                pixels[n] = trans_color
            else
                pixels[n] = color
            end

            if not repeatMode then
                local b = readBits(1)
                if b == 1 then
                    local b2 = readBits(1)
                    if b2 == 1 then
                        -- Delta or repeat
                        local diff = readBits(3) - 4
                        if diff ~= 0 then
                            color = band(color + diff + 256, 0xFF)
                        else
                            -- Enter repeat mode
                            repeatMode = true
                            repeatCount = readBits(8) - 1
                        end
                    else
                        -- Absolute new color
                        color = readBits(decomp_shr)
                    end
                end
                -- b=0: color unchanged
            else
                repeatCount = repeatCount - 1
                if repeatCount <= 0 then
                    repeatMode = false
                end
            end
        end
    end

    return pixels
end

-- Decode a raw (codec 1) strip
local function decode_strip_raw(strip_data, height)
    local pixels = {}
    local pos = 1
    local n = 0
    for row = 1, height do
        for x = 1, 8 do
            n = n + 1
            pixels[n] = (pos <= #strip_data) and u8(strip_data, pos) or 0
            pos = pos + 1
        end
    end
    return pixels
end

-- Dispatch strip decoding based on codec byte
local function decode_strip(strip_data, height, trans_color)
    if #strip_data < 2 then return nil end

    local code = u8(strip_data, 1)
    local payload = strip_data:sub(2)  -- everything after codec byte

    local decomp_shr  = code % 10
    local decomp_mask = band(rshift(0xFF, 8 - decomp_shr), 0xFF)
    -- Fix: for decomp_shr >= 8, mask is 0xFF
    if decomp_shr >= 8 then decomp_mask = 0xFF end
    if decomp_shr == 0 then decomp_mask = 0 end

    if code == 1 then
        -- Raw uncompressed
        return decode_strip_raw(payload, height)

    elseif code >= 14 and code <= 18 then
        -- ZIGZAG_V
        return decode_strip_zigzag_v(payload, height, decomp_shr, decomp_mask, false, trans_color)

    elseif code >= 24 and code <= 28 then
        -- ZIGZAG_H
        return decode_strip_zigzag_h(payload, height, decomp_shr, decomp_mask, false, trans_color)

    elseif code >= 34 and code <= 38 then
        -- ZIGZAG_VT (transparent)
        return decode_strip_zigzag_v(payload, height, decomp_shr, decomp_mask, true, trans_color)

    elseif code >= 44 and code <= 48 then
        -- ZIGZAG_HT (transparent)
        return decode_strip_zigzag_h(payload, height, decomp_shr, decomp_mask, true, trans_color)

    elseif code >= 64 and code <= 68 then
        -- MAJMIN_H
        return decode_strip_complex(payload, height, decomp_shr, false, trans_color)

    elseif code >= 84 and code <= 88 then
        -- MAJMIN_HT (transparent)
        return decode_strip_complex(payload, height, decomp_shr, true, trans_color)

    elseif code >= 104 and code <= 108 then
        -- RMAJMIN_H (same decoder)
        return decode_strip_complex(payload, height, decomp_shr, false, trans_color)

    elseif code >= 124 and code <= 128 then
        -- RMAJMIN_HT (transparent)
        return decode_strip_complex(payload, height, decomp_shr, true, trans_color)

    else
        -- Unknown codec - try zigzag_h as fallback
        log_warn(string.format("Unknown SMAP codec: %d (decomp_shr=%d)", code, decomp_shr))
        if decomp_shr >= 1 and decomp_shr <= 8 then
            return decode_strip_zigzag_h(payload, height, decomp_shr, decomp_mask, false, trans_color)
        end
        return nil
    end
end

-- ── Decode full room background from SMAP ───────────────────────

local function decode_room_background(data, room_info)
    if not room_info.smap_offset or not room_info.width or not room_info.height then
        return nil
    end

    local width  = room_info.width
    local height = room_info.height
    local num_strips = math.floor(width / 8)
    local trans_color = room_info.transparent_color or 0

    local smap_start = room_info.smap_offset  -- 1-based position of "SMAP" tag
    local smap_size  = room_info.smap_size

    -- Strip offset table starts at smap_start + 8 (after 8-byte header)
    -- Each offset is u32le, relative to smap_start (the "SMAP" tag position)
    local offsets = {}
    for s = 0, num_strips - 1 do
        local off_pos = smap_start + 8 + s * 4
        if off_pos + 3 <= #data then
            offsets[s] = u32le(data, off_pos)
        end
    end

    -- Pixel buffer: row-major, width * height
    local pixels = {}
    for i = 1, width * height do pixels[i] = 0 end

    local decoded_count = 0

    for s = 0, num_strips - 1 do
        if offsets[s] and offsets[s] > 0 then
            -- Strip data starts at smap_start + offsets[s] (1-based)
            local strip_pos = smap_start + offsets[s]

            -- Determine strip data length (to next strip or end of SMAP)
            local strip_end
            if s < num_strips - 1 and offsets[s + 1] and offsets[s + 1] > offsets[s] then
                strip_end = smap_start + offsets[s + 1] - 1
            else
                strip_end = smap_start + smap_size - 1
            end

            local strip_len = strip_end - strip_pos + 1
            if strip_len > 0 and strip_pos >= 1 and strip_end <= #data then
                local strip_data = data:sub(strip_pos, strip_end)
                local strip_pixels = decode_strip(strip_data, height, trans_color)

                if strip_pixels then
                    decoded_count = decoded_count + 1
                    -- Blit strip into pixel buffer
                    local base_x = s * 8
                    for row = 0, height - 1 do
                        for col = 0, 7 do
                            local src_idx = row * 8 + col + 1
                            local dst_idx = row * width + base_x + col + 1
                            if src_idx <= #strip_pixels and dst_idx <= width * height then
                                pixels[dst_idx] = strip_pixels[src_idx]
                            end
                        end
                    end
                end
            end
        end
    end

    if decoded_count == 0 then
        log_warn("No strips could be decoded")
        return nil
    end

    return pixels, width, height
end

-- ── Palette swatch ──────────────────────────────────────────────

local function build_palette_swatch(palette)
    local CELL = 16
    local GRID = 16
    local SIZE = CELL * GRID  -- 256
    local rgb = {}
    local n = 0
    for row = 0, SIZE - 1 do
        local pal_row = math.floor(row / CELL) * GRID
        for col = 0, SIZE - 1 do
            local pal_idx = pal_row + math.floor(col / CELL)
            n = n + 1; rgb[n] = palette[pal_idx * 3 + 1] or 0
            n = n + 1; rgb[n] = palette[pal_idx * 3 + 2] or 0
            n = n + 1; rgb[n] = palette[pal_idx * 3 + 3] or 0
        end
    end
    return image_create_rgb(SIZE, SIZE, rgb)
end

-- ── Game file discovery ─────────────────────────────────────────
-- Returns list of {base_name, index_path, data_path, xor_key}

local function find_scumm_games(game_path)
    local games = {}
    local files = list_files(game_path)

    -- Build lookup for case-insensitive matching
    local name_map = {}  -- uppercase -> actual name
    for _, f in ipairs(files) do
        name_map[f:upper()] = f
    end

    -- Look for .000/.001 pairs
    for _, f in ipairs(files) do
        local base = f:match("^(.+)%.000$") or f:match("^(.+)%.000$")
        if not base then
            base = f:match("^(.+)%.000$")
        end
        if base then
            local data_upper = base:upper() .. ".001"
            local data_file = name_map[data_upper]
            if data_file then
                games[#games + 1] = {
                    base_name  = base,
                    index_path = game_path .. "/" .. f,
                    data_path  = game_path .. "/" .. data_file,
                    xor_key    = 0x69  -- V5 default
                }
            end
        end
    end

    -- Look for .la0/.la1 pairs (V6+ games like Day of the Tentacle, Sam & Max)
    for _, f in ipairs(files) do
        local base = f:match("^(.+)%.la0$") or f:match("^(.+)%.LA0$")
        if base then
            local data_upper = base:upper() .. ".LA1"
            local data_file = name_map[data_upper]
            if data_file then
                games[#games + 1] = {
                    base_name  = base,
                    index_path = game_path .. "/" .. f,
                    data_path  = game_path .. "/" .. data_file,
                    xor_key    = 0x69
                }
            end
        end
    end

    -- Look for .sm0/.sm1 pairs (Loom, maybe others)
    for _, f in ipairs(files) do
        local base = f:match("^(.+)%.sm0$") or f:match("^(.+)%.SM0$")
        if base then
            local data_upper = base:upper() .. ".SM1"
            local data_file = name_map[data_upper]
            if data_file then
                games[#games + 1] = {
                    base_name  = base,
                    index_path = game_path .. "/" .. f,
                    data_path  = game_path .. "/" .. data_file,
                    xor_key    = 0x69
                }
            end
        end
    end

    return games
end

-- ── Detection ───────────────────────────────────────────────────

function engine.detect(game_path)
    local games = find_scumm_games(game_path)
    return #games > 0
end

-- ── Resource tree ───────────────────────────────────────────────

function engine.get_resources(game_path)
    local resources = {}
    local games = find_scumm_games(game_path)

    for _, game in ipairs(games) do
        -- Read and decrypt index file
        local idx_f = file_open(game.index_path)
        if idx_f then
            local idx_size = file_size(idx_f)
            local idx_raw = file_read(idx_f, 0, idx_size)
            file_close(idx_f)

            if idx_raw then
                local idx_data = xor_decrypt(idx_raw, game.xor_key)
                local index = parse_index(idx_data)

                -- Read beginning of data file to get LOFF
                local dat_f = file_open(game.data_path)
                if dat_f then
                    local dat_size = file_size(dat_f)
                    -- Read enough for LECF header + LOFF (first ~2KB should suffice)
                    local header_raw = file_read(dat_f, 0, math.min(4096, dat_size))
                    file_close(dat_f)

                    if header_raw then
                        local header_data = xor_decrypt(header_raw, game.xor_key)
                        local rooms = parse_loff(header_data)

                        if #rooms > 0 then
                            -- Sort rooms by ID
                            table.sort(rooms, function(a, b) return a.id < b.id end)

                            local room_children = {}
                            for _, room in ipairs(rooms) do
                                local room_name = index.room_names and index.room_names[room.id]
                                local display
                                if room_name and #room_name > 0 then
                                    display = string.format("Room %d: %s", room.id, room_name)
                                else
                                    display = string.format("Room %d", room.id)
                                end

                                -- Background image node
                                local children = {}
                                children[#children + 1] = {
                                    id = "bg:" .. game.base_name .. ":" .. room.id,
                                    name = display .. " — Background",
                                    type = "image"
                                }
                                -- Palette node (hidden from tree, used in dropdown)
                                children[#children + 1] = {
                                    id = "pal:" .. game.base_name .. ":" .. room.id,
                                    name = display .. " — Palette",
                                    type = "palette"
                                }

                                room_children[#room_children + 1] = {
                                    id = "room:" .. game.base_name .. ":" .. room.id,
                                    name = display,
                                    type = "category",
                                    children = children
                                }
                            end

                            resources[#resources + 1] = {
                                id = "game_" .. game.base_name,
                                name = game.base_name .. " (" .. #rooms .. " rooms)",
                                type = "category",
                                children = room_children
                            }
                        end
                    end
                end
            end
        end
    end

    return resources
end

-- ── Resource loading ────────────────────────────────────────────

-- LOFF cache: maps data_path → {rooms = [{id,offset},...]}
-- Avoids re-reading the full file; we only need the first ~4KB per game
local loff_cache = {}

-- Get room LOFF table for a game (reads first 4KB only)
local function get_loff(game)
    if loff_cache[game.data_path] then
        return loff_cache[game.data_path]
    end
    local f = file_open(game.data_path)
    if not f then return {} end
    local header_raw = file_read(f, 0, math.min(4096, file_size(f)))
    file_close(f)
    if not header_raw then return {} end
    local header_data = xor_decrypt(header_raw, game.xor_key)
    local rooms = parse_loff(header_data)
    loff_cache[game.data_path] = rooms
    return rooms
end

-- Read and decrypt exactly one room block from the data file, on demand.
-- Returns a decrypted string containing just that room block.
local function read_room_block(game, room_offset)
    local f = file_open(game.data_path)
    if not f then return nil end

    -- Read 8-byte block header to get block size
    local header_raw = file_read(f, room_offset, 8)
    if not header_raw then file_close(f); return nil end
    local header = xor_decrypt(header_raw, game.xor_key)

    -- Determine actual block (handle LFLF wrapper or bare ROOM)
    local tag = header:sub(1, 4)
    local block_size

    if tag == "LFLF" then
        block_size = u32be(header, 5)
    elseif tag == "ROOM" then
        block_size = u32be(header, 5)
    else
        -- Unknown – try reading a reasonable chunk
        log_warn("Unexpected tag '" .. tag .. "' at room offset " .. room_offset)
        block_size = 65536
    end

    -- Read the full block (re-read including header for simplicity)
    local raw = file_read(f, room_offset, block_size)
    file_close(f)
    if not raw then return nil end

    return xor_decrypt(raw, game.xor_key)
end

local function find_game(game_path, base_name)
    local games = find_scumm_games(game_path)
    for _, g in ipairs(games) do
        if g.base_name == base_name then return g end
    end
    return nil
end

local function find_room_in_loff(loff_rooms, room_id)
    for _, r in ipairs(loff_rooms) do
        if r.id == room_id then return r.offset end
    end
    return nil
end

function engine.load_resource(game_path, resource_id, palette_id)
    -- Parse resource ID: type:base_name:room_id
    local res_type, base_name, room_id_str = resource_id:match("^(%a+):(.+):(%d+)$")
    if not res_type then
        log_warn("Unknown resource ID: " .. resource_id)
        return nil
    end

    local room_id = tonumber(room_id_str)

    -- Find game entry
    local game = find_game(game_path, base_name)
    if not game then
        log_error("Game not found: " .. base_name)
        return nil
    end

    -- Get LOFF to find this room's offset (reads only first 4KB)
    local loff_rooms = get_loff(game)
    local room_offset = find_room_in_loff(loff_rooms, room_id)
    if not room_offset then
        log_warn("Room " .. room_id .. " not found in LOFF")
        return nil
    end

    -- Read only the room block (lazy, no full-file load)
    local room_data = read_room_block(game, room_offset)
    if not room_data then
        log_error("Failed to read room " .. room_id .. " block")
        return nil
    end

    -- Parse room from block (offset 0 within the block, 0-based → block starts at offset 0)
    local room_info = parse_room(room_data, 0, #room_data)
    if not room_info then
        log_warn("Failed to parse room " .. room_id)
        return nil
    end

    -- Handle palette resource
    if res_type == "pal" then
        if room_info.palette then
            local img = build_palette_swatch(room_info.palette)
            return {
                type = "image",
                image = img,
                description = string.format("Room %d palette — 256 colors", room_id)
            }
        end
        return { type = "text", text = "No CLUT palette found in room " .. room_id }
    end

    -- Handle background resource
    if res_type == "bg" then
        local palette = room_info.palette

        -- Apply external palette if requested (palette_id = "pal:<base>:<room>")
        if palette_id and palette_id ~= "" then
            local _, _, pal_room_str = palette_id:match("^(%a+):(.+):(%d+)$")
            if pal_room_str then
                local pal_room_id = tonumber(pal_room_str)
                if pal_room_id ~= room_id then
                    local pal_offset = find_room_in_loff(loff_rooms, pal_room_id)
                    if pal_offset then
                        local pal_data = read_room_block(game, pal_offset)
                        if pal_data then
                            local pal_room = parse_room(pal_data, 0, #pal_data)
                            if pal_room and pal_room.palette then
                                palette = pal_room.palette
                            end
                        end
                    end
                end
            end
        end

        if not palette then
            palette = {}
            for i = 0, 255 do
                palette[i * 3 + 1] = i
                palette[i * 3 + 2] = i
                palette[i * 3 + 3] = i
            end
        end

        if not room_info.smap_offset then
            return {
                type = "text",
                text = string.format(
                    "Room %d: %dx%d\nNo SMAP background data found",
                    room_id, room_info.width or 0, room_info.height or 0
                )
            }
        end

        local pixels, width, height = decode_room_background(room_data, room_info)
        if not pixels then
            return {
                type = "text",
                text = string.format(
                    "Room %d: %dx%d\nFailed to decode SMAP background",
                    room_id, room_info.width or 0, room_info.height or 0
                )
            }
        end

        local img = image_create_indexed(width, height, pixels, palette)

        -- Get room name from index file (index is small, OK to read each time)
        local room_name = ""
        local idx_f = file_open(game.index_path)
        if idx_f then
            local idx_raw = file_read(idx_f, 0, file_size(idx_f))
            file_close(idx_f)
            if idx_raw then
                local idx_data = xor_decrypt(idx_raw, game.xor_key)
                local index = parse_index(idx_data)
                if index.room_names and index.room_names[room_id] then
                    room_name = " (" .. index.room_names[room_id] .. ")"
                end
            end
        end

        return {
            type = "image",
            image = img,
            width = width,
            height = height,
            description = string.format(
                "Room %d%s — %dx%d, 256 colors, SCUMM V5",
                room_id, room_name, width, height
            )
        }
    end

    return nil
end

return engine

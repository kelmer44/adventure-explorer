-- ============================================================================
-- Adventure Explorer - Engine Script: Cruise for a Corpse
-- ============================================================================
-- Delphine Software Cinematique evo 2. 320x200.
-- VOL.CNF master index + D1,D2... volume files.
-- Backgrounds: 16-color (mode 0/4 bitplanes), 32-color (mode 5), or 256-color (mode 8).
-- ============================================================================

local engine = {}
engine.name        = "Cruise for a Corpse"
engine.id          = "cruise"
engine.description = "Cruise for a Corpse (1991, Delphine Software)"
engine.version     = "2.0"

-- Binary helpers
local function u8(data, pos)   return data:byte(pos) end
local function u16be(data, pos)
    return data:byte(pos) * 256 + data:byte(pos + 1)
end
local function u32be(data, pos)
    return data:byte(pos) * 16777216 + data:byte(pos + 1) * 65536
         + data:byte(pos + 2) * 256 + data:byte(pos + 3)
end

-- ============================================================================
-- Delphine backward LZ77 unpacker (same algorithm as cine engine)
-- Reads bits LSB-first via rotate-carry-right (rcr) mechanism.
-- Verified against ScummVM engines/cruise/delphine-unpack.cpp
-- ============================================================================

local function delphine_unpack(src_data, unpacked_size)
    local src_len = #src_data
    if src_len < 12 then
        local out = {}
        for i = 1, math.min(src_len, unpacked_size) do
            out[i] = src_data:byte(i)
        end
        for i = #out + 1, unpacked_size do out[i] = 0 end
        return out
    end

    -- Read 12-byte trailer: three BE uint32 words at end
    local read_pos = src_len - 3
    local datasize = u32be(src_data, read_pos)
    read_pos = read_pos - 4
    local crc = u32be(src_data, read_pos)
    read_pos = read_pos - 4
    local chunk = u32be(src_data, read_pos)
    read_pos = read_pos - 4

    local output = {}
    for i = 1, unpacked_size do output[i] = 0 end

    local dst_pos = unpacked_size
    local error_flag = false

    local function read_source()
        if read_pos < 1 then error_flag = true; return 0 end
        local val = u32be(src_data, read_pos)
        read_pos = read_pos - 4
        return val
    end

    -- Rotate carry right: extract LSB, shift right, optionally set MSB
    local function rcr(input_carry)
        local output_carry = chunk % 2
        chunk = math.floor(chunk / 2)
        if input_carry then chunk = chunk + 2147483648 end
        return output_carry
    end

    local function next_bit()
        local carry = rcr(false)
        if chunk == 0 then
            chunk = read_source()
            carry = rcr(true)
        end
        return carry
    end

    local function get_bits(n)
        local val = 0
        for _ = 1, n do val = val * 2 + next_bit() end
        return val
    end

    local function copy_raw(count)
        for _ = 1, count do
            if dst_pos < 1 then return end
            output[dst_pos] = get_bits(8)
            dst_pos = dst_pos - 1
        end
    end

    local function copy_ref(offset, count)
        for _ = 1, count do
            if dst_pos < 1 then return end
            local si = dst_pos + offset
            output[dst_pos] = (si >= 1 and si <= unpacked_size) and output[si] or 0
            dst_pos = dst_pos - 1
        end
    end

    while dst_pos > 0 and not error_flag do
        if next_bit() == 0 then
            if next_bit() == 0 then copy_raw(get_bits(3) + 1)
            else copy_ref(get_bits(8), 2) end
        else
            local c = get_bits(2)
            if c == 3 then copy_raw(get_bits(8) + 9)
            elseif c < 2 then
                copy_ref(get_bits(c + 9), c + 3)
            else
                local count = get_bits(8) + 1
                local offset = get_bits(12)
                copy_ref(offset, count)
            end
        end
    end

    return output
end

-- ============================================================================
-- Volume file parser (same format as cine bundles)
-- u16be numEntries, u16be entrySize(30), then 30-byte entries
-- ============================================================================

local function parse_volume(data)
    if not data or #data < 4 then return nil end

    local num = u16be(data, 1)
    if num == 0 or num > 10000 then return nil end

    local entries = {}
    for i = 0, num - 1 do
        local base = 5 + i * 30
        if base + 29 > #data then break end

        local name = ""
        for c = 0, 13 do
            local b = data:byte(base + c)
            if not b or b == 0 then break end
            name = name .. string.char(b)
        end

        entries[#entries + 1] = {
            name = name,
            offset = u32be(data, base + 14),
            packed_size = u32be(data, base + 18),
            unpacked_size = u32be(data, base + 22)
        }
    end

    return entries
end

-- ============================================================================
-- Bitplane decoders
-- ============================================================================

-- Mode 0/4: 4-plane interleaved, Atari ST style -> 16 colors
local function decode_mode4(data, offset, w, h)
    local pixels = {}; local n = 0
    local pos = offset
    local chunks = w / 16

    for _ = 1, h do
        for _ = 1, chunks do
            if pos + 7 > #data then
                for _ = 1, 16 do n = n + 1; pixels[n] = 0 end
            else
                local w0 = u16be(data, pos + 0)
                local w1 = u16be(data, pos + 2)
                local w2 = u16be(data, pos + 4)
                local w3 = u16be(data, pos + 6)
                for bit = 0, 15 do
                    local mask = 2 ^ (15 - bit)
                    local c = 0
                    if w0 % (mask * 2) >= mask then c = c + 1 end
                    if w1 % (mask * 2) >= mask then c = c + 2 end
                    if w2 % (mask * 2) >= mask then c = c + 4 end
                    if w3 % (mask * 2) >= mask then c = c + 8 end
                    n = n + 1; pixels[n] = c
                end
            end
            pos = pos + 8
        end
    end
    return pixels
end

-- Mode 5: 5-plane sequential, Amiga style -> 32 colors
local function decode_mode5(data, offset, w, h)
    local pixels = {}
    local bytes_per_row = w / 8  -- 40
    local plane_size = bytes_per_row * h  -- 8000

    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local col = math.floor(x / 8)
            local bit = 7 - (x % 8)
            local byte_off = y * bytes_per_row + col
            local c = 0
            for plane = 0, 4 do
                local p = offset + plane * plane_size + byte_off
                if p <= #data then
                    local b = u8(data, p)
                    if b % (2^(bit + 1)) >= 2^bit then
                        c = c + 2^plane
                    end
                end
            end
            pixels[y * w + x + 1] = c
        end
    end
    return pixels
end

-- ============================================================================
-- Palette decoders
-- ============================================================================

local function atari_st_palette(data, offset, num_colors)
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
    end
    for i = 0, num_colors - 1 do
        local val = u16be(data, offset + i * 2)
        local r = math.floor(val / 256) % 8
        local g = math.floor(val / 16) % 8
        local b = val % 8
        palette[i * 3 + 1] = math.floor(r * 255 / 7)
        palette[i * 3 + 2] = math.floor(g * 255 / 7)
        palette[i * 3 + 3] = math.floor(b * 255 / 7)
    end
    return palette
end

local function amiga_palette(data, offset, num_colors)
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
    end
    for i = 0, num_colors - 1 do
        local b0 = u8(data, offset + i * 2 + 0)  -- 0x0R
        local b1 = u8(data, offset + i * 2 + 1)  -- 0xGB
        local r = b0 % 16
        local g = math.floor(b1 / 16)
        local b = b1 % 16
        palette[i * 3 + 1] = r * 17
        palette[i * 3 + 2] = g * 17
        palette[i * 3 + 3] = b * 17
    end
    return palette
end

local function rgb_palette(data, offset)
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = u8(data, offset + i * 3 + 0)
        palette[i * 3 + 2] = u8(data, offset + i * 3 + 1)
        palette[i * 3 + 3] = u8(data, offset + i * 3 + 2)
    end
    return palette
end

-- ============================================================================
-- Detection
-- ============================================================================

function engine.detect(game_path)
    local has_d1 = file_exists(game_path .. "/D1") or file_exists(game_path .. "/d1")
    local has_vol = file_exists(game_path .. "/VOL.CNF") or file_exists(game_path .. "/vol.cnf")
    return has_d1 and has_vol
end

-- ============================================================================
-- Resource tree: scan volume files for background resources
-- ============================================================================

function engine.get_resources(game_path)
    local files = list_files(game_path)
    if not files then return {} end

    -- Find volume files (D1, D2, ...)
    local volumes = {}
    for _, fname in ipairs(files) do
        local lower = fname:lower()
        if lower:match("^d%d+$") then
            volumes[#volumes + 1] = fname
        end
    end
    table.sort(volumes, function(a, b) return a:lower() < b:lower() end)

    local resources = {}

    for _, vol_name in ipairs(volumes) do
        local f = file_open(game_path .. "/" .. vol_name)
        if f then
            local fsize = file_size(f)
            local header_size = math.min(fsize, 4 + 10000 * 30)
            local raw = file_read(f, 0, header_size)
            file_close(f)

            if raw then
                local entries = parse_volume(raw)
                if entries then
                    -- Show all entries, mark likely backgrounds
                    local bg_entries = {}
                    for _, e in ipairs(entries) do
                        local lower = e.name:lower()
                        if lower:match("%.pi1$") or lower:match("%.pix$") or
                           lower:match("%.bg$") or lower:match("%.bmp$") or
                           e.unpacked_size >= 32000 then
                            bg_entries[#bg_entries + 1] = e
                        end
                    end

                    if #bg_entries == 0 then bg_entries = entries end

                    if #bg_entries > 0 then
                        local cat = {
                            id = "vol_" .. vol_name,
                            name = string.format("%s (%d resources)", vol_name, #bg_entries),
                            type = "category", children = {}
                        }
                        for _, e in ipairs(bg_entries) do
                            cat.children[#cat.children + 1] = {
                                id   = "res_" .. vol_name .. "_" .. e.name,
                                name = string.format("%s (%dB)", e.name, e.unpacked_size),
                                type = "image"
                            }
                        end
                        resources[#resources + 1] = cat
                    end
                end
            end
        end
    end

    return resources
end

-- ============================================================================
-- Resource loading
-- ============================================================================

function engine.load_resource(game_path, resource_id)
    local vol_name, file_name = resource_id:match("^res_([^_]+)_(.+)$")
    if not vol_name or not file_name then return nil end

    local f = file_open(game_path .. "/" .. vol_name)
    if not f then return nil end
    local fsize = file_size(f)
    local vol_data = file_read(f, 0, fsize)
    file_close(f)
    if not vol_data then return nil end

    local entries = parse_volume(vol_data)
    if not entries then return nil end

    local target = nil
    for _, e in ipairs(entries) do
        if e.name == file_name then target = e; break end
    end
    if not target then return nil end

    -- Extract raw data
    if target.offset + target.packed_size > #vol_data then return nil end
    local packed = vol_data:sub(target.offset + 1, target.offset + target.packed_size)

    local data
    if target.packed_size == target.unpacked_size or target.unpacked_size == 0 then
        data = packed
    else
        local result = delphine_unpack(packed, target.unpacked_size)
        if not result then return nil end
        local chars = {}
        for i = 1, #result do chars[i] = string.char(result[i]) end
        data = table.concat(chars)
    end

    if not data or #data < 10 then return nil end

    -- Parse background
    local w, h = 320, 200
    local pixels, palette

    -- Check for "PAL" header (256-color raw)
    if data:sub(1, 3) == "PAL" then
        if #data >= 4 + 768 + 64000 then
            palette = rgb_palette(data, 5)
            pixels = {}
            for i = 1, 64000 do pixels[i] = u8(data, 772 + i) end
        end
    else
        -- Binary header: byte 0 = resolution, byte 1 = mode
        local mode = u8(data, 2)

        if mode == 8 then
            -- 256-color: 2 bytes header + 768 palette + 64000 pixels
            if #data >= 770 then
                palette = rgb_palette(data, 3)
                pixels = {}
                local start = 771
                for i = 1, math.min(64000, #data - start + 1) do
                    pixels[i] = u8(data, start + i - 1)
                end
                while #pixels < 64000 do pixels[#pixels + 1] = 0 end
            end
        elseif mode == 5 then
            -- 32-color Amiga: 2 bytes header + 64 bytes palette + 40000 bytes (5 planes)
            if #data >= 66 + 40000 then
                palette = amiga_palette(data, 3, 32)
                pixels = decode_mode5(data, 67, 320, 200)
            end
        else
            -- Mode 0/4: 16-color Atari ST: 2 bytes header + 64 bytes palette + 32000 bytes (4 planes)
            if #data >= 66 + 32000 then
                palette = atari_st_palette(data, 3, 32)
                pixels = decode_mode4(data, 67, 320, 200)
            elseif #data >= 34 + 32000 then
                -- Compact: 2 bytes header + 32 bytes palette (16 colors) + 32000 bytes
                palette = atari_st_palette(data, 3, 16)
                pixels = decode_mode4(data, 35, 320, 200)
            end
        end
    end

    if not pixels or not palette then
        return { type = "text", text = string.format("%s: unable to decode (%d bytes, mode byte=%d)",
            file_name, #data, u8(data, 2)) }
    end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image", image = img,
        description = string.format("Cruise for a Corpse - %s - %dx%d", file_name, w, h)
    }
end

return engine

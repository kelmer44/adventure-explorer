-- RNC methods 1/2 with packed and unpacked CRC checks.
-- Reused from the Curse of Enchantia decoder in this project.
-- bit twiddling
-- ------------------------------------------------------------------------
-- Lua 5.1 has no bitwise operators. Build the full 8-bit XOR table with
-- XOR8[a][b] = 2*XOR8[a>>1][b>>1] + ((a%2) XOR (b%2)), which needs no
-- bitwise ops in Lua itself.
local XOR8 = {}
do
    local base = {}
    for j = 0, 255 do base[j] = j end
    XOR8[0] = base
    for i = 1, 255 do
        local src = XOR8[math.floor(i / 2)]
        local row = {}
        local li = i % 2
        for j = 0, 255 do
            row[j] = src[math.floor(j / 2)] * 2
                     + (li ~= (j % 2) and 1 or 0)
        end
        XOR8[i] = row
    end
end

local function bxor(a, b)
    return XOR8[a % 256][b % 256]
         + 256 * XOR8[math.floor(a / 256)][math.floor(b / 256)]
end

-- CRC-16/ARC
-- ------------------------------------------------------------------------
local CRC_TAB, CRC_LOOKUP = {}, {}
do
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if c % 2 == 1 then c = bxor(math.floor(c / 2), 0xA001)
            else c = math.floor(c / 2) end
        end
        CRC_TAB[i] = c
    end
    -- Flatten CRC_TAB[lo XOR b] so the hot loop needs one lookup for the table
    -- index instead of two.
    for lo = 0, 255 do
        for b = 0, 255 do
            CRC_LOOKUP[lo * 256 + b] = CRC_TAB[XOR8[lo][b]]
        end
    end
end

-- CRC over a string slice. "from" is a 1-based index.
local function crc16_str(data, from, len)
    local crc = 0
    for i = from, from + len - 1 do
        local hi = math.floor(crc / 256)
        local t = CRC_LOOKUP[(crc % 256) * 256 + data:byte(i)]
        -- "crc >> 8" is a 16-bit value whose low byte is hi, so hi is mixed
        -- into the low byte of t and the high byte passes through untouched.
        crc = XOR8[hi][t % 256] + 256 * math.floor(t / 256)
    end
    return crc
end

-- Same, over a 1-based table of byte values (the decoder output).
local function crc16_tab(t, len)
    local crc = 0
    for i = 1, len do
        local hi = math.floor(crc / 256)
        local c = CRC_LOOKUP[(crc % 256) * 256 + t[i]]
        crc = XOR8[hi][c % 256] + 256 * math.floor(c / 256)
    end
    return crc
end

-- RNC method 2
-- ------------------------------------------------------------------------
-- MSB-first bit reader, one byte refilled at a time (input_bits_m2). Reads are
-- clamped to the end of the current block so a corrupt stream cannot wander
-- into the next one.
local function m2_new(data, from, block_end)
    return { d = data, p = from, stop = block_end, buf = 0, count = 0 }
end

local function m2_byte(s)
    if s.p <= s.stop then
        local b = s.d:byte(s.p)
        s.p = s.p + 1
        return b
    end
    error("Truncated RNC stream")
end

local function m2_bits(s, n)
    local v = 0
    for _ = 1, n do
        if s.count == 0 then
            s.buf = m2_byte(s)
            s.count = 8
        end
        if s.buf >= 128 then v = v * 2 + 1 else v = v * 2 end
        s.buf = (s.buf * 2) % 256
        s.count = s.count - 1
    end
    return v
end

local function m2_match_offset(s)
    local off = 0
    if m2_bits(s, 1) == 1 then
        off = m2_bits(s, 1)
        if m2_bits(s, 1) == 1 then
            off = off * 2 + m2_bits(s, 1) + 4
            if m2_bits(s, 1) == 0 then
                off = off * 2 + m2_bits(s, 1)
            end
        elseif off == 0 then
            off = m2_bits(s, 1) + 2
        end
    end
    return off * 256 + m2_byte(s) + 1
end

local function m2_match_count(s)
    local n = m2_bits(s, 1) + 4
    if m2_bits(s, 1) == 1 then
        n = (n - 1) * 2 + m2_bits(s, 1)
    end
    return n
end

local function rnc_method2(data, from, block_end, unpacked_size)
    local s = m2_new(data, from, block_end)
    local out, n = {}, 0
    local key = 0
    local done = 0

    local function ror_key()
        if key % 2 == 1 then key = 0x8000 + math.floor(key / 2)
        else key = math.floor(key / 2) end
    end

    m2_bits(s, 1)                        -- two probe bits before dispatch
    m2_bits(s, 1)

    while done < unpacked_size do
        local escape = false
        while not escape do
            if n > unpacked_size or s.p > block_end + 1 then return nil, 0 end
            if m2_bits(s, 1) == 0 then            -- 0: literal byte
                n = n + 1
                out[n] = XOR8[key % 256][m2_byte(s)]
                ror_key()
                done = done + 1
            else
                local count, off
                local copied = false
                if m2_bits(s, 1) == 0 then        -- 10: 4..9, or a raw block
                    count = m2_match_count(s)
                    if count == 9 then             -- 12..75 literal bytes
                        local len = m2_bits(s, 4) * 4 + 12
                        for _ = 1, len do
                            n = n + 1
                            out[n] = XOR8[key % 256][m2_byte(s)]
                        end
                        ror_key()
                        done = done + len
                    else
                        off = m2_match_offset(s)
                        copied = true
                    end
                elseif m2_bits(s, 1) == 0 then    -- 110: 2 bytes, offset 1..256
                    count = 2
                    off = m2_byte(s) + 1
                    copied = true
                elseif m2_bits(s, 1) == 0 then    -- 1110: 3 bytes
                    count = 3
                    off = m2_match_offset(s)
                    copied = true
                else                              -- 1111: 9..263, or escape
                    count = m2_byte(s) + 8
                    if count == 8 then             -- a source byte of 0 ends it
                        m2_bits(s, 1)
                        escape = true
                    else
                        off = m2_match_offset(s)
                        copied = true
                    end
                end
                if copied then
                    for _ = 1, count do
                        n = n + 1
                        if n > unpacked_size or not out[n - off] then return nil, 0 end
                        out[n] = out[n - off]
                    end
                    done = done + count
                end
            end
        end
    end
    return out, n
end

-- RNC method 1
-- ------------------------------------------------------------------------
-- A block is a series of sections; each starts with three Huffman tables (raw
-- length, match offset, match length) and a 16-bit chunk count. The bit buffer
-- refills four bytes at a time, LSB first, and resync() merges fresh bytes
-- above whatever is still buffered.
local function m1_new(data, from, block_end)
    return { d = data, p = from, stop = block_end, b = 0, have = 0 }
end

local function m1_read_byte(s)
    if s.p <= s.stop then
        local b = s.d:byte(s.p)
        s.p = s.p + 1
        return b
    end
    error("Truncated RNC stream")
end

local function m1_peek(s, offset)
    local i = s.p + offset
    if i <= s.stop then return s.d:byte(i) end
    return 0
end

local function m1_resync(s)
    local fresh = m1_peek(s, 2) * 65536 + m1_peek(s, 1) * 256 + m1_peek(s, 0)
    local keep = 2 ^ s.have
    s.b = (fresh * keep + s.b % keep) % 4294967296
end

local function m1_bits(s, count)
    local out, prev = 0, 1
    for _ = 1, count do
        if s.have == 0 then
            local b1 = m1_read_byte(s)
            local b2 = m1_read_byte(s)
            s.b = m1_peek(s, 1) * 16777216 + m1_peek(s, 0) * 65536
                  + b2 * 256 + b1
            s.have = 16
        end
        if s.b % 2 == 1 then out = out + prev end
        s.b = math.floor(s.b / 2)
        prev = prev * 2
        s.have = s.have - 1
    end
    return out
end

local function inverse_bits(value, count)
    local i = 0
    for _ = 1, count do
        i = i * 2
        if value % 2 == 1 then i = i + 1 end
        value = math.floor(value / 2)
    end
    return i
end

-- The reference implementation's "proc 20": hand out canonical codes, shortest
-- length first, in table order.
local function proc20(lengths)
    local leaves = {}
    local val, div = 0, 2147483648
    for bits_count = 1, 16 do
        for i = 1, #lengths do
            if lengths[i] == bits_count then
                leaves[#leaves + 1] = {
                    code = inverse_bits(math.floor(val / div), bits_count),
                    len = bits_count,
                    value = i - 1,
                }
                val = val + div
            end
        end
        div = math.floor(div / 2)
    end
    return leaves
end

local function read_huffman_table(s)
    local num = m1_bits(s, 5)
    if num == 0 then return nil end
    if num > 16 then num = 16 end
    local lengths = {}
    for i = 1, num do lengths[i] = m1_bits(s, 4) end
    local leaves = proc20(lengths)
    if #leaves == 0 then return nil end
    return leaves
end

local function read_huffman(leaves, s)
    for i = 1, #leaves do
        local leaf = leaves[i]
        if s.b % 2 ^ leaf.len == leaf.code then
            m1_bits(s, leaf.len)
            if leaf.value < 2 then return leaf.value end
            return m1_bits(s, leaf.value - 1) + 2 ^ (leaf.value - 1)
        end
    end
    return nil
end

local function rnc_method1(data, from, block_end, unpacked_size)
    local s = m1_new(data, from, block_end)
    local out, n = {}, 0

    m1_bits(s, 2)                        -- two probe bits before dispatch

    while s.p < block_end do
        local raw_t = read_huffman_table(s)
        local len_t = read_huffman_table(s)
        local pos_t = read_huffman_table(s)
        if not raw_t or not len_t or not pos_t then return nil, 0 end

        local chunks = m1_bits(s, 16)
        while chunks > 0 do
            local run = read_huffman(raw_t, s)
            if run == nil then return nil, 0 end
            if run ~= 0 then
                for _ = 1, run do
                    n = n + 1
                    out[n] = m1_read_byte(s)
                end
                m1_resync(s)
            end
            chunks = chunks - 1

            if chunks > 0 then
                local off = read_huffman(len_t, s)
                local count = read_huffman(pos_t, s)
                if off == nil or count == nil then return nil, 0 end
                off = off + 1
                count = count + 2
                if n < off then return nil, 0 end
                for _ = 1, count do
                    n = n + 1
                    if n > unpacked_size or not out[n - off] then return nil, 0 end
                        out[n] = out[n - off]
                end
            end
        end
        if n >= unpacked_size then break end
    end
    return out, n
end

-- Unpack the RNC block whose "RNC" magic starts at 1-based index `i`.
-- Returns (pixels, pixel_count, next_index), or nil when the block is not valid.
local function rnc_unpack(data, i)
    if i < 1 or i + 17 > #data then return nil end
    if data:sub(i, i + 2) ~= "RNC" then return nil end
    local method = data:byte(i + 3) % 4
    if method ~= 1 and method ~= 2 then return nil end

    local unpacked_size = data:byte(i + 4) * 16777216 + data:byte(i + 5) * 65536
                         + data:byte(i + 6) * 256 + data:byte(i + 7)
    local packed_size = data:byte(i + 8) * 16777216 + data:byte(i + 9) * 65536
                       + data:byte(i + 10) * 256 + data:byte(i + 11)
    local want_unpacked = data:byte(i + 12) * 256 + data:byte(i + 13)
    local want_packed = data:byte(i + 14) * 256 + data:byte(i + 15)

    if unpacked_size <= 0 or packed_size <= 0 or unpacked_size > 4000000 then
        return nil
    end

    local from = i + 18
    local block_end = from + packed_size - 1
    if block_end > #data then return nil end
    if crc16_str(data, from, packed_size) ~= want_packed then return nil end

    local out, n
    if method == 1 then
        out, n = rnc_method1(data, from, block_end, unpacked_size)
    else
        out, n = rnc_method2(data, from, block_end, unpacked_size)
    end
    if not out or n < unpacked_size then return nil end

    -- The unpacked CRC doubles as a full-content check on the decoded pixels.
    if crc16_tab(out, unpacked_size) ~= want_unpacked then return nil end

    return out, unpacked_size, block_end + 1
end


return function(data)
    local ok, out, n = pcall(rnc_unpack, data, 1)
    if ok then return out, n end
end

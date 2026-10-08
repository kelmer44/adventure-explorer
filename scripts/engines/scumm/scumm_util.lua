-- ============================================================================
-- SCUMM shared helpers (binary readers, IFF-style block scanning)
-- Loaded by engine.lua and the other scumm_* modules through require().
-- ============================================================================

local U = {}

function U.u8(data, pos)
    return data:byte(pos) or 0
end

function U.u16le(data, pos)
    local a, b = data:byte(pos, pos + 1)
    if not b then return 0 end
    return a + b * 256
end

function U.i16le(data, pos)
    local v = U.u16le(data, pos)
    if v >= 32768 then v = v - 65536 end
    return v
end

function U.u32le(data, pos)
    local a, b, c, d = data:byte(pos, pos + 3)
    if not d then return 0 end
    return a + b * 256 + c * 65536 + d * 16777216
end

function U.u32be(data, pos)
    local a, b, c, d = data:byte(pos, pos + 3)
    if not d then return 0 end
    return a * 16777216 + b * 65536 + c * 256 + d
end

function U.u16be(data, pos)
    local a, b = data:byte(pos, pos + 1)
    if not b then return 0 end
    return a * 256 + b
end

function U.tag4(data, pos)
    return data:sub(pos, pos + 3)
end

--- Scan IFF-like blocks (4-byte tag + big-endian size that includes the 8-byte
--- header). Positions are 1-based string indices.
function U.scan_blocks(data, start_pos, end_pos)
    local blocks = {}
    local pos = start_pos
    end_pos = end_pos or #data
    while pos + 8 <= end_pos + 1 do
        local sz = U.u32be(data, pos + 4)
        if sz < 8 or pos + sz - 1 > end_pos then break end
        blocks[#blocks + 1] = {
            tag = data:sub(pos, pos + 3),
            offset = pos,
            size = sz,
            data_start = pos + 8,
        }
        pos = pos + sz
    end
    return blocks
end

function U.find_block(blocks, tag)
    for _, b in ipairs(blocks) do
        if b.tag == tag then return b end
    end
    return nil
end

--- Transparent colour used when previewing sprites (shown as magenta).
U.TRANSPARENT_RGB = { 255, 0, 255 }

--- Copy a palette (768-entry table) and force palette slot 255 to magenta so
--- that transparent pixels written as index 255 show up as such.
function U.with_key_color(palette, index)
    local p = {}
    for i = 1, 768 do p[i] = palette[i] or 0 end
    p[index * 3 + 1] = 255
    p[index * 3 + 2] = 0
    p[index * 3 + 3] = 255
    return p
end

return U

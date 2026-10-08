-- ============================================================================
-- SCUMM V7/V8 NUT bitmap fonts (SMUSH "ANIM" files: AHDR + one FRME/FOBJ per glyph)
-- Codec 1 (row RLE), 21 and 44 (skip/copy runs). Source: ScummVM nut_renderer.cpp
-- ============================================================================

local U = require("scumm_util")
local Cost = require("scumm_cost")
local u16le, i16le, u32be = U.u16le, U.i16le, U.u32be

local N = {}

local function blank(w, h)
    local px = {}
    for i = 1, w * h do px[i] = -1 end
    return px
end

-- codec 21 / 44: per row u16 length, then { u16 skip, u16 (count-1), bytes } runs
local function decode_runs(data, pos, w, h)
    local px = blank(w, h)
    for y = 0, h - 1 do
        local row_len = u16le(data, pos)
        local p = pos + 2
        local x = 0
        while x < w do
            x = x + u16le(data, p); p = p + 2
            if x >= w then break end
            local n = u16le(data, p) + 1; p = p + 2
            if x + n > w then n = w - x end
            for i = 0, n - 1 do
                px[y * w + x + i + 1] = data:byte(p + i) or 0
            end
            p = p + n
            x = x + n
        end
        pos = pos + row_len + 2
    end
    return px
end

-- codec 1: BOMP-style row RLE where colour 0 is transparent
local function decode_rle(data, pos, w, h)
    local px = blank(w, h)
    for y = 0, h - 1 do
        local row_len = u16le(data, pos)
        local p = pos + 2
        local x = 0
        while x < w do
            local code = data:byte(p); p = p + 1
            if not code then break end
            local n = math.floor(code / 2) + 1
            if n > w - x then n = w - x end
            if code % 2 == 1 then
                local c = data:byte(p) or 0; p = p + 1
                if c ~= 0 then for i = 0, n - 1 do px[y * w + x + i + 1] = c end end
            else
                for i = 0, n - 1 do
                    local c = data:byte(p + i) or 0
                    if c ~= 0 then px[y * w + x + i + 1] = c end
                end
                p = p + n
            end
            x = x + n
        end
        pos = pos + row_len + 2
    end
    return px
end

--- Parse a NUT file. Returns { palette = {768}, glyphs = { {w,h,pixels,...} } } or nil.
function N.parse(data)
    if #data < 24 or data:sub(1, 4) ~= "ANIM" then return nil end
    if data:sub(9, 12) ~= "AHDR" then return nil end
    local ahdr_size = u32be(data, 13)
    local count = u16le(data, 19)
    local palette = {}
    for i = 1, 768 do palette[i] = data:byte(22 + i) or 0 end

    local glyphs = {}
    local pos = 17 + ahdr_size + (ahdr_size % 2)         -- first FRME (1-based)
    while #glyphs < count and pos + 30 <= #data do
        if data:sub(pos, pos + 3) ~= "FRME" then break end
        local fsize = u32be(data, pos + 4)
        local fobj = pos + 8
        if data:sub(fobj, fobj + 3) ~= "FOBJ" then break end
        local codec = u16le(data, fobj + 8)
        local w, h = u16le(data, fobj + 14), u16le(data, fobj + 16)
        local px
        if w > 0 and h > 0 and w * h < 400000 then
            if codec == 1 then px = decode_rle(data, fobj + 22, w, h)
            elseif codec == 21 or codec == 44 then px = decode_runs(data, fobj + 22, w, h) end
        end
        glyphs[#glyphs + 1] = px and { w = w, h = h, pixels = px,
            relx = i16le(data, fobj + 10), rely = i16le(data, fobj + 12), code = #glyphs, limb = 0 }
            or { w = 1, h = 1, pixels = { -1 }, code = #glyphs, limb = 0 }
        pos = pos + 8 + fsize + (fsize % 2)
    end
    return { palette = palette, glyphs = glyphs }
end

--- Render all glyphs on one sheet. Returns image handle, w, h.
function N.render(font)
    return Cost.render_sheet_of(font.glyphs, font.palette)
end

return N

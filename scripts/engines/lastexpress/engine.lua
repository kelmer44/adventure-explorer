-- ============================================================================
-- Adventure Explorer - Engine Script: The Last Express
-- ============================================================================
-- Jordan Mechner / Broderbund, 1997.  640x480 24-bit RGB backgrounds.
-- Resources packed in HPF (Hard-disk Package File) sector-based archives.
-- BG files store R, B, G channels separately with per-channel RLE+LZ77.
-- SEQ files (character animations) decoded with multi-codec decompressor.
-- ============================================================================

local engine = {}
engine.name        = "The Last Express"
engine.id          = "lastexpress"
engine.description = "The Last Express (1997, Jordan Mechner / Broderbund)"
engine.version     = "1.0"

-- ============================================================================
-- Binary helpers
-- ============================================================================

local function u8(data, pos)   return data:byte(pos) end
local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end
local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end
local function i32le(data, pos)
    local v = u32le(data, pos)
    return v < 2147483648 and v or v - 4294967296
end

-- ============================================================================
-- HPF archive parser
-- Header: u32le numFiles
-- Each entry (22 bytes): char[12] name + u32le sector + u32le numSectors + u16le isOnHD
-- Sector size: 2048 bytes (CD-ROM sector).  Offsets are absolute within the HPF file.
-- ============================================================================

local function parse_hpf(data)
    if not data or #data < 4 then return nil end
    local num_files = u32le(data, 1)
    if num_files == 0 or num_files > 100000 then return nil end

    local hdr_size = 4 + num_files * 22
    if #data < hdr_size then
        -- Partial read: parse only what we have
        num_files = math.floor((#data - 4) / 22)
    end

    local entries = {}
    for i = 0, num_files - 1 do
        local ofs = 5 + i * 22  -- 1-based start of this entry
        -- Name: 12 bytes, NUL-terminated
        local name = ""
        for j = 0, 11 do
            local c = data:byte(ofs + j)
            if c == 0 then break end
            name = name .. string.char(c)
        end
        local sector      = u32le(data, ofs + 12)
        local num_sectors = u32le(data, ofs + 16)
        -- isOnHD at ofs+20 (u16le) — not needed for extraction

        if #name > 0 and num_sectors > 0 then
            entries[#entries + 1] = {
                name        = name,
                offset      = sector * 2048,  -- 0-based absolute byte offset in HPF
                size        = num_sectors * 2048
            }
        end
    end
    return entries
end

-- ============================================================================
-- BG image decoder
-- Header (28 bytes): i32le PosX, PosY, Width, Height, RSize, BSize, GSize
-- Then: RSize bytes of compressed R channel, BSize bytes of B, GSize bytes of G.
-- Per-channel compression:
--   byte < 0x80: RLE fill  — len = (byte >> 5) + 1, val = (byte & 0x1F) << 3
--   byte >= 0x80: LZ ref   — len = ((byte & 0x7F) >> 4) + 3,
--                            pos = out_pos - 4096 + ((byte & 0x0F) << 8 | nextByte)
-- Note: the lower 3 bits of the fill path are zeroed (quantized to multiples of 8).
-- ============================================================================

local function decompress_bg_channel(data, src_ofs, comp_size, out_size)
    local out = {}
    local o = 1                     -- 1-based output write position
    local p = src_ofs               -- 1-based input read position
    local p_end = src_ofs + comp_size - 1

    while o <= out_size and p <= p_end do
        local code = data:byte(p); p = p + 1

        if code < 0x80 then
            -- RLE fill: (code >> 5) + 1 pixels of value (code & 0x1F) << 3
            local len = math.floor(code / 32) + 1
            local val = (code % 32) * 8
            for _ = 1, len do
                if o > out_size then break end
                out[o] = val; o = o + 1
            end
        else
            -- LZ back-reference: 4096-byte sliding window
            -- len = ((code & 0x7F) >> 4) + 3
            local len = math.floor((code % 128) / 16) + 3
            if p > p_end then break end
            local b2 = data:byte(p); p = p + 1
            -- back_pos (1-based): current position backward 4096 plus 12-bit field
            local back_pos = o - 4096 + (code % 16) * 256 + b2

            for _ = 1, len do
                if o > out_size then break end
                out[o] = (back_pos >= 1 and back_pos < o) and out[back_pos] or 0
                back_pos = back_pos + 1
                o = o + 1
            end
        end
    end

    while o <= out_size do out[o] = 0; o = o + 1 end
    return out
end

local function decode_bg(data)
    if not data or #data < 28 then return nil end

    local pos_x  = i32le(data,  1)
    local pos_y  = i32le(data,  5)
    local width  = i32le(data,  9)
    local height = i32le(data, 13)
    local r_size = i32le(data, 17)
    local b_size = i32le(data, 21)
    local g_size = i32le(data, 25)

    if width <= 0 or height <= 0 or width > 4096 or height > 4096 then return nil end
    if r_size < 0 or b_size < 0 or g_size < 0 then return nil end

    local out_size = width * height
    local r_start = 29          -- 1-based: after 28-byte header
    local b_start = r_start + r_size
    local g_start = b_start + b_size

    -- Clamp sizes to available data
    local avail = #data - r_start + 1
    if r_size > avail then r_size = avail end
    avail = #data - b_start + 1
    if avail < 0 then avail = 0 end
    if b_size > avail then b_size = avail end
    avail = #data - g_start + 1
    if avail < 0 then avail = 0 end
    if g_size > avail then g_size = avail end

    local r_ch = decompress_bg_channel(data, r_start, r_size, out_size)
    local b_ch = decompress_bg_channel(data, b_start, b_size, out_size)
    local g_ch = (g_size > 0)
                 and decompress_bg_channel(data, g_start, g_size, out_size)
                 or {}

    -- Combine channels into RGB pixels (file order is R, B, G)
    local rgb = {}
    local n = 1
    for i = 1, out_size do
        rgb[n] = r_ch[i] or 0;    n = n + 1
        rgb[n] = g_ch[i] or 0;    n = n + 1
        rgb[n] = b_ch[i] or 0;    n = n + 1
    end

    return rgb, width, height, pos_x, pos_y
end

-- ============================================================================
-- Bitwise helpers (LuaJ 3.0.1 has no bit32)
-- ============================================================================

local function bshr(x, n) return math.floor(x / (2 ^ n)) end
local function bshl(x, n) return x * (2 ^ n) end
local function band(a, b)
    local r, bit = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + bit end
        a = math.floor(a / 2); b = math.floor(b / 2); bit = bit * 2
    end
    return r
end

-- ============================================================================
-- SEQ Animation Decoder
-- The Last Express SEQ format:
--   Header (8 bytes): u32le numFrames, u32le unknown
--   Then numFrames * 68-byte frame entries (TTLEFrame records)
--   Frame data + per-frame palettes follow at offsets specified in each entry.
--   Each frame decompresses to a 640x480 indexed image with embedded palette.
--   Palette: array of u16le words in 15-bit RGB (5-5-5) format.
--   Compression types: 0x03, 0x04, 0x05, 0x07, 0xFF (+ empty for null ofs).
-- ============================================================================

local SCREEN_W = 640
local SCREEN_H = 480
local SCREEN_SIZE = SCREEN_W * SCREEN_H  -- 307200
local SEQ_FRAME_SIZE = 68
local MAX_PAL = 256
local MAX_SEQ_FRAMES = 200  -- sanity cap for memory

local function parse_seq_frame(data, pos)
    return {
        data_ofs     = u32le(data, pos),
        unknown1     = u32le(data, pos + 4),
        pal_ofs      = u32le(data, pos + 8),
        dirty_left   = u32le(data, pos + 12),
        dirty_top    = u32le(data, pos + 16),
        dirty_right  = u32le(data, pos + 20),
        dirty_bottom = u32le(data, pos + 24),
        initial_skip = u32le(data, pos + 28),
        decomp_size  = u32le(data, pos + 32),
        comp_type    = u8(data, pos + 44)
    }
end

-- Read palette at pal_ofs (0-based byte offset in file) and convert 15-bit 5-5-5 to RGB
local function read_seq_palette(data, pal_ofs_0, pal_size)
    local pal = {}
    local pos = pal_ofs_0 + 1  -- 1-based
    for i = 0, pal_size - 1 do
        if pos + 1 <= #data then
            local w = u16le(data, pos)
            pal[i] = {
                r = band(bshr(w, 10), 0x1f) * 8,
                g = band(bshr(w, 5), 0x1f) * 8,
                b = band(w, 0x1f) * 8
            }
        else
            pal[i] = { r = 0, g = 0, b = 0 }
        end
        pos = pos + 2
    end
    return pal
end

-- Decompress_Empty: just a blank frame
local function decomp_empty(fr, data)
    local scr = {}
    for i = 1, SCREEN_SIZE do scr[i] = 0 end
    return scr, 1
end

-- Decompress_03
local function decomp_03(fr, data)
    local scr = {}
    for i = 1, SCREEN_SIZE do scr[i] = 0 end
    local pal_size = 1

    local num_blanks = 639 - (fr.dirty_right - fr.dirty_left)
    local in_idx = fr.data_ofs  -- 0-based
    local out_idx = bshr(fr.initial_skip, 1)
    local limit = bshr(fr.decomp_size, 1)
    local parity = math.floor(out_idx / SCREEN_W) % 2

    while out_idx < limit do
        if in_idx + 1 > #data then break end
        local op = data:byte(in_idx + 1); in_idx = in_idx + 1

        if band(op, 0x80) ~= 0 then
            if band(op, 0x40) ~= 0 then
                op = band(op, 0x3f)
                out_idx = out_idx + num_blanks + op + 1
                parity = math.floor(out_idx / SCREEN_W) % 2
                out_idx = out_idx + 1
            else
                op = band(op, 0x3f)
                if band(op, 0x20) ~= 0 then
                    if in_idx + 1 > #data then break end
                    op = band(op, 0x1f) * 256 + data:byte(in_idx + 1); in_idx = in_idx + 1
                    if band(op, 0x1000) ~= 0 then
                        out_idx = out_idx + band(op, 0x0fff)
                        parity = math.floor(out_idx / SCREEN_W) % 2
                        -- continue (skip the rest of this iteration)
                        op = -1  -- sentinel
                    end
                end
                if op >= 0 then
                    out_idx = out_idx + op + 1
                    parity = math.floor(out_idx / SCREEN_W) % 2
                    out_idx = out_idx + 1
                end
            end
        else
            local val = band(op, 0x07)
            op = bshr(op, 3)
            if val + 1 > pal_size then pal_size = val + 1 end
            if op == 0 then
                if in_idx + 1 > #data then break end
                op = data:byte(in_idx + 1); in_idx = in_idx + 1
            end
            if (out_idx % 2) == parity then
                if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                out_idx = out_idx + 1; op = op - 1
                if op == 0 then op = -1 end  -- skip pixel loop
            end
            if op > 0 then
                local half = math.floor(op / 2)
                for _ = 1, half do
                    if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                    if out_idx + 1 < SCREEN_SIZE then scr[out_idx + 2] = val end
                    out_idx = out_idx + 2
                end
                if op % 2 ~= 0 then
                    if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                    out_idx = out_idx + 1
                end
            end
        end
    end
    return scr, pal_size
end

-- Decompress_04
local function decomp_04(fr, data)
    local scr = {}
    for i = 1, SCREEN_SIZE do scr[i] = 0 end
    local pal_size = 1

    local num_blanks = 639 - (fr.dirty_right - fr.dirty_left)
    local in_idx = fr.data_ofs
    local out_idx = bshr(fr.initial_skip, 1)
    local limit = bshr(fr.decomp_size, 1)
    local parity = math.floor(out_idx / SCREEN_W) % 2

    while out_idx < limit do
        if in_idx + 1 > #data then break end
        local op = data:byte(in_idx + 1); in_idx = in_idx + 1

        if band(op, 0x80) ~= 0 then
            if band(op, 0x40) ~= 0 then
                op = band(op, 0x3f)
                out_idx = out_idx + num_blanks + op + 1
                parity = math.floor(out_idx / SCREEN_W) % 2
                out_idx = out_idx + 1
            else
                op = band(op, 0x3f)
                if band(op, 0x20) ~= 0 then
                    if in_idx + 1 > #data then break end
                    op = band(op, 0x1f) * 256 + data:byte(in_idx + 1); in_idx = in_idx + 1
                    if band(op, 0x1000) ~= 0 then
                        out_idx = out_idx + band(op, 0x0fff)
                        parity = math.floor(out_idx / SCREEN_W) % 2
                        op = -1
                    end
                end
                if op >= 0 then
                    out_idx = out_idx + op + 1
                    parity = math.floor(out_idx / SCREEN_W) % 2
                    out_idx = out_idx + 1
                end
            end
        else
            local val = band(op, 0x0f)
            op = bshr(op, 4)
            if val + 1 > pal_size then pal_size = val + 1 end
            if op == 0 then
                if in_idx + 1 > #data then break end
                op = data:byte(in_idx + 1); in_idx = in_idx + 1
            end
            if (out_idx % 2) == parity then
                if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                out_idx = out_idx + 1; op = op - 1
                if op == 0 then op = -1 end
            end
            if op > 0 then
                for _ = 1, math.floor(op / 2) do
                    if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                    if out_idx + 1 < SCREEN_SIZE then scr[out_idx + 2] = val end
                    out_idx = out_idx + 2
                end
                if op % 2 ~= 0 then
                    if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                    out_idx = out_idx + 1
                end
            end
        end
    end
    return scr, pal_size
end

-- Decompress_05
local function decomp_05(fr, data)
    local scr = {}
    for i = 1, SCREEN_SIZE do scr[i] = 0 end
    local pal_size = 1

    local in_idx = fr.data_ofs
    local out_idx = bshr(fr.initial_skip, 1)
    local limit = bshr(fr.decomp_size, 1)
    local parity = math.floor(out_idx / SCREEN_W) % 2

    while out_idx < limit do
        if in_idx + 1 > #data then break end
        local op = data:byte(in_idx + 1); in_idx = in_idx + 1

        if band(op, 0x1f) == 0 then
            if in_idx + 1 > #data then break end
            op = bshl(op, 3) + data:byte(in_idx + 1); in_idx = in_idx + 1
            if band(op, 0x0400) ~= 0 then
                out_idx = out_idx + band(op, 0x03ff)
                parity = math.floor(out_idx / SCREEN_W) % 2
            else
                out_idx = out_idx + op + 1
                parity = math.floor(out_idx / SCREEN_W) % 2
                out_idx = out_idx + 1
            end
        else
            local val = band(op, 0x1f)
            op = bshr(op, 5)
            if val + 1 > pal_size then pal_size = val + 1 end
            if op == 0 then
                if in_idx + 1 > #data then break end
                op = data:byte(in_idx + 1); in_idx = in_idx + 1
            end
            if (out_idx % 2) == parity then
                if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                out_idx = out_idx + 1; op = op - 1
                if op == 0 then op = -1 end
            end
            if op > 0 then
                for _ = 1, math.floor(op / 2) do
                    if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                    if out_idx + 1 < SCREEN_SIZE then scr[out_idx + 2] = val end
                    out_idx = out_idx + 2
                end
                if op % 2 ~= 0 then
                    if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                    out_idx = out_idx + 1
                end
            end
        end
    end
    return scr, pal_size
end

-- Decompress_07
local function decomp_07(fr, data)
    local scr = {}
    for i = 1, SCREEN_SIZE do scr[i] = 0 end
    local pal_size = 1

    local num_blanks = 639 - (fr.dirty_right - fr.dirty_left)
    local in_idx = fr.data_ofs
    local out_idx = bshr(fr.initial_skip, 1)
    local limit = bshr(fr.decomp_size, 1)
    local parity = math.floor(out_idx / SCREEN_W) % 2

    while out_idx < limit do
        if in_idx + 1 > #data then break end
        local op = data:byte(in_idx + 1); in_idx = in_idx + 1

        if band(op, 0x80) ~= 0 then
            if band(op, 0x40) ~= 0 then
                if band(op, 0x20) ~= 0 then
                    op = band(op, 0x1f)
                    out_idx = out_idx + num_blanks + op + 1
                    parity = math.floor(out_idx / SCREEN_W) % 2
                    out_idx = out_idx + 1
                else
                    op = band(op, 0x1f)
                    if band(op, 0x10) ~= 0 then
                        if in_idx + 1 > #data then break end
                        op = band(op, 0x0f) * 256 + data:byte(in_idx + 1); in_idx = in_idx + 1
                        if band(op, 0x0800) ~= 0 then
                            out_idx = out_idx + band(op, 0x07ff)
                            parity = math.floor(out_idx / SCREEN_W) % 2
                            op = -1
                        end
                    end
                    if op >= 0 then
                        out_idx = out_idx + op + 1
                        parity = math.floor(out_idx / SCREEN_W) % 2
                        out_idx = out_idx + 1
                    end
                end
            else
                -- RLE with explicit value byte
                op = band(op, 0x3f)
                if in_idx + 1 > #data then break end
                local val = data:byte(in_idx + 1); in_idx = in_idx + 1
                if val + 1 > pal_size then pal_size = val + 1 end

                if (out_idx % 2) == parity then
                    if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                    out_idx = out_idx + 1; op = op - 1
                    if op == 0 then op = -1 end
                end
                if op > 0 then
                    for _ = 1, math.floor(op / 2) do
                        if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                        if out_idx + 1 < SCREEN_SIZE then scr[out_idx + 2] = val end
                        out_idx = out_idx + 2
                    end
                    if op % 2 ~= 0 then
                        if out_idx < SCREEN_SIZE then scr[out_idx + 1] = val end
                        out_idx = out_idx + 1
                    end
                end
            end
        else
            -- Single pixel
            if op + 1 > pal_size then pal_size = op + 1 end
            if out_idx < SCREEN_SIZE then scr[out_idx + 1] = op end
            out_idx = out_idx + 1
        end
    end
    return scr, pal_size
end

-- Decompress_ff (LZ77-like with RLE)
local function decomp_ff(fr, data)
    local scr = {}
    for i = 1, SCREEN_SIZE do scr[i] = 0 end
    local pal_size = 1

    local in_idx = fr.data_ofs
    local out_idx = 0

    while out_idx < SCREEN_SIZE do
        if in_idx + 2 > #data then break end
        local lo = data:byte(in_idx + 1)
        local hi = data:byte(in_idx + 2)

        if lo < 0x80 then
            in_idx = in_idx + 1
            if lo + 1 > pal_size then pal_size = lo + 1 end
            if out_idx < SCREEN_SIZE then scr[out_idx + 1] = lo end
            out_idx = out_idx + 1
        else
            in_idx = in_idx + 2
            if lo < 0xf0 then
                if lo < 0xe0 then
                    -- Back-reference
                    local pos = out_idx + band(lo, 0x07) * 256 + hi - 2048
                    local len = bshr(band(lo, 0x78), 3) + 3
                    for _ = 1, len do
                        if out_idx >= SCREEN_SIZE then break end
                        local v = (pos >= 0 and pos < out_idx) and scr[pos + 1] or 0
                        scr[out_idx + 1] = v
                        pos = pos + 1; out_idx = out_idx + 1
                    end
                else
                    -- RLE
                    local val = hi
                    local len = band(lo, 0x0f) + 1
                    if val + 1 > pal_size then pal_size = val + 1 end
                    for _ = 1, len do
                        if out_idx >= SCREEN_SIZE then break end
                        scr[out_idx + 1] = val
                        out_idx = out_idx + 1
                    end
                end
            else
                -- Skip
                local skip_val = band(lo, 0x0f) * 256 + hi  -- low 12 bits
                -- Actually: ((lo shl 8) | hi) & 0x0fff
                -- lo & 0x0f = band(lo, 0x0f); result = band(lo, 0x0f)*256 + hi
                out_idx = out_idx + skip_val
            end
        end
    end
    return scr, pal_size
end

-- Main SEQ frame decompressor: dispatches by compression type
local function decompress_seq_frame(fr, data)
    if fr.data_ofs == 0 or fr.data_ofs + 1 > #data then
        return decomp_empty(fr, data)
    end
    local ct = fr.comp_type
    if ct == 0x03 then return decomp_03(fr, data)
    elseif ct == 0x04 then return decomp_04(fr, data)
    elseif ct == 0x05 then return decomp_05(fr, data)
    elseif ct == 0x07 then return decomp_07(fr, data)
    elseif ct == 0xff then return decomp_ff(fr, data)
    else
        log_warn(string.format("SEQ: unsupported compression type 0x%02x", ct))
        return decomp_empty(fr, data)
    end
end

-- Decode a full SEQ file into animation frames
local function decode_seq(data)
    if not data or #data < 8 then return nil end

    local num_frames = u32le(data, 1)
    if num_frames == 0 or num_frames > 50000 then return nil end

    local hdr_end = 8 + num_frames * SEQ_FRAME_SIZE
    if #data < hdr_end then return nil end

    -- Limit frames for memory
    local frame_count = math.min(num_frames, MAX_SEQ_FRAMES)

    local handles = {}
    local decoded = 0
    local errors = 0

    for i = 0, frame_count - 1 do
        local entry_pos = 9 + i * SEQ_FRAME_SIZE  -- 1-based
        local fr = parse_seq_frame(data, entry_pos)

        local ok, scr, pal_size = pcall(decompress_seq_frame, fr, data)
        if not ok then
            errors = errors + 1
            scr = nil
        end

        if scr then
            -- Read per-frame palette
            pal_size = math.min(pal_size, MAX_PAL)
            local pal = read_seq_palette(data, fr.pal_ofs, pal_size)

            -- Convert indexed 640x480 to RGB
            local rgb = {}
            local n = 1
            for p = 1, SCREEN_SIZE do
                local idx = scr[p] or 0
                local c = pal[idx]
                if c then
                    rgb[n] = c.r; rgb[n+1] = c.g; rgb[n+2] = c.b
                else
                    rgb[n] = 0; rgb[n+1] = 0; rgb[n+2] = 0
                end
                n = n + 3
            end

            handles[#handles + 1] = image_create_rgb(SCREEN_W, SCREEN_H, rgb)
            decoded = decoded + 1
        end
    end

    if decoded == 0 then return nil end

    return handles, num_frames, decoded, errors
end

-- ============================================================================
-- Detection
-- ============================================================================

function engine.detect(game_path)
    -- Primary marker: TRAIN.EXE (the game executable)
    if file_exists(game_path .. "/TRAIN.EXE") or file_exists(game_path .. "/train.exe") then
        return true
    end
    -- Fallback: any HPF archive (sector-based CD format unique to this game)
    local files = list_files(game_path)
    if files then
        for _, name in ipairs(files) do
            if name:lower():match("%.hpf$") then
                -- Quick sanity: first 4 bytes should be a reasonable file count
                local fh = file_open(game_path .. "/" .. name)
                if fh then
                    local hdr = file_read(fh, 0, 4)
                    file_close(fh)
                    if hdr and #hdr == 4 then
                        local n = u32le(hdr, 1)
                        if n > 0 and n < 100000 then return true end
                    end
                end
            end
        end
    end
    return false
end

-- ============================================================================
-- Resource tree
-- ============================================================================

function engine.get_resources(game_path)
    local files = list_files(game_path)
    if not files then return {} end

    -- Collect HPF archives
    local hpf_files = {}
    for _, name in ipairs(files) do
        if name:lower():match("%.hpf$") then
            hpf_files[#hpf_files + 1] = name
        end
    end
    table.sort(hpf_files, function(a, b) return a:lower() < b:lower() end)

    local resources = {}

    for _, hpf_name in ipairs(hpf_files) do
        local fh = file_open(game_path .. "/" .. hpf_name)
        if fh then
            local sz   = file_size(fh)
            -- Read just enough to get the full directory
            -- Max practical size: 4 + 50000 * 22 = ~1.1 MB; cap at actual file size
            local max_hdr = math.min(sz, 4 + 50000 * 22)
            local hdr_data = file_read(fh, 0, max_hdr)
            file_close(fh)

            if hdr_data then
                local entries = parse_hpf(hdr_data)
                if entries and #entries > 0 then
                    local bg_items  = {}
                    local seq_items = {}

                    for _, e in ipairs(entries) do
                        local lower = e.name:lower()
                        if lower:match("%.bg$") then
                            bg_items[#bg_items + 1] = e
                        elseif lower:match("%.seq$") then
                            seq_items[#seq_items + 1] = e
                        end
                    end

                    -- Backgrounds category
                    if #bg_items > 0 then
                        local cat = {
                            id       = "bg|" .. hpf_name,
                            name     = string.format("%s - Backgrounds (%d)", hpf_name, #bg_items),
                            type     = "category",
                            children = {}
                        }
                        for _, e in ipairs(bg_items) do
                            local base = e.name:match("^(.+)%.") or e.name
                            cat.children[#cat.children + 1] = {
                                id   = "bgf|" .. hpf_name .. "|" .. e.name,
                                name = base,
                                type = "image"
                            }
                        end
                        resources[#resources + 1] = cat
                    end

                    -- Animations category (SEQ)
                    if #seq_items > 0 then
                        local cat = {
                            id       = "seq|" .. hpf_name,
                            name     = string.format("%s - SEQ Animations (%d)", hpf_name, #seq_items),
                            type     = "category",
                            children = {}
                        }
                        for _, e in ipairs(seq_items) do
                            local base = e.name:match("^(.+)%.") or e.name
                            cat.children[#cat.children + 1] = {
                                id   = "seqf|" .. hpf_name .. "|" .. e.name,
                                name = base,
                                type = "animation"
                            }
                        end
                        resources[#resources + 1] = cat
                    end
                end
            end
        end
    end

    -- Also scan for loose BG files not in any HPF
    local loose_bg = {}
    for _, name in ipairs(files) do
        if name:lower():match("%.bg$") then
            loose_bg[#loose_bg + 1] = name
        end
    end
    if #loose_bg > 0 then
        table.sort(loose_bg, function(a, b) return a:lower() < b:lower() end)
        local cat = { id = "loose_bg", name = string.format("Loose BG Files (%d)", #loose_bg),
                      type = "category", children = {} }
        for _, name in ipairs(loose_bg) do
            local base = name:match("^(.+)%.") or name
            cat.children[#cat.children + 1] = {
                id = "lbg|" .. name, name = base, type = "image"
            }
        end
        resources[#resources + 1] = cat
    end

    return resources
end

-- ============================================================================
-- Resource loading
-- ============================================================================

-- Load BG data from an HPF archive given the entry name
local function read_from_hpf(game_path, hpf_name, entry_name)
    local fh = file_open(game_path .. "/" .. hpf_name)
    if not fh then return nil end

    local sz      = file_size(fh)
    local max_hdr = math.min(sz, 4 + 50000 * 22)
    local hdr_data = file_read(fh, 0, max_hdr)
    if not hdr_data then file_close(fh); return nil end

    local entries = parse_hpf(hdr_data)
    if not entries then file_close(fh); return nil end

    local found = nil
    for _, e in ipairs(entries) do
        if e.name:lower() == entry_name:lower() then found = e; break end
    end
    if not found then file_close(fh); return nil end

    -- Read up to 4 MB per resource (BG files are always < a few hundred KB)
    local read_size = math.min(found.size, 4 * 1024 * 1024)
    local data = file_read(fh, found.offset, read_size)
    file_close(fh)
    return data
end

function engine.load_resource(game_path, resource_id, palette_id)
    -- bgf|<hpf>|<entry>  — background from HPF
    -- seqf|<hpf>|<entry> — SEQ animation metadata
    -- lbg|<filename>     — loose BG file
    local prefix = resource_id:match("^([^|]+)|")
    if not prefix then return nil end

    if prefix == "bgf" then
        local hpf_name, entry_name = resource_id:match("^bgf|([^|]+)|(.+)$")
        if not hpf_name or not entry_name then return nil end

        local bg_data = read_from_hpf(game_path, hpf_name, entry_name)
        if not bg_data then return nil end

        local rgb, w, h, px, py = decode_bg(bg_data)
        if not rgb then
            log_warn("BG decode failed for " .. entry_name)
            return nil
        end

        local base = entry_name:match("^(.+)%.") or entry_name
        local img  = image_create_rgb(w, h, rgb)
        return {
            type        = "image",
            image       = img,
            description = string.format("%s - %dx%d at (%d,%d)", base, w, h, px, py)
        }

    elseif prefix == "seqf" then
        local hpf_name, entry_name = resource_id:match("^seqf|([^|]+)|(.+)$")
        if not hpf_name or not entry_name then return nil end

        local seq_data = read_from_hpf(game_path, hpf_name, entry_name)
        local base = entry_name:match("^(.+)%.") or entry_name
        if not seq_data or #seq_data < 8 then
            return { type = "text", text = base .. ".SEQ\n\nCould not read file data." }
        end

        local num_frames = u32le(seq_data, 1)

        local handles, total, decoded, errors = decode_seq(seq_data)
        if not handles or #handles == 0 then
            return {
                type = "text",
                text = string.format(
                    "%s.SEQ (in %s)\n\nFrames: %d\nFile size: %d bytes\n\n"
                    .. "Decoding failed — compression type may be unsupported.",
                    base, hpf_name, num_frames, #seq_data)
            }
        end

        local desc = string.format(
            "%s.SEQ (in %s)\nFrames: %d decoded of %d total",
            base, hpf_name, decoded, total)
        if errors > 0 then
            desc = desc .. string.format(" (%d errors)", errors)
        end
        if total > MAX_SEQ_FRAMES then
            desc = desc .. string.format("\n(Showing first %d frames)", MAX_SEQ_FRAMES)
        end
        desc = desc .. string.format("\nResolution: %dx%d", SCREEN_W, SCREEN_H)

        if #handles == 1 then
            return { type = "image", image = handles[1], description = desc }
        end

        local anim = animation_create(handles, 100)
        return {
            type = "animation",
            animation = anim,
            delay_ms = 100,
            description = desc
        }

    elseif prefix == "lbg" then
        local fname = resource_id:match("^lbg|(.+)$")
        if not fname then return nil end

        local fh = file_open(game_path .. "/" .. fname)
        if not fh then return nil end
        local sz   = file_size(fh)
        local data = file_read(fh, 0, math.min(sz, 4 * 1024 * 1024))
        file_close(fh)
        if not data then return nil end

        local rgb, w, h, px, py = decode_bg(data)
        if not rgb then return nil end

        local base = fname:match("^(.+)%.") or fname
        local img  = image_create_rgb(w, h, rgb)
        return {
            type        = "image",
            image       = img,
            description = string.format("%s - %dx%d at (%d,%d)", base, w, h, px, py)
        }
    end

    return nil
end

return engine

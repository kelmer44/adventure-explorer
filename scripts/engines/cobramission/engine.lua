-- ============================================================================
-- Adventure Explorer - Engine Script: Cobra Mission
-- ============================================================================
-- MegaTech, 1992. DOS.
--
-- VOL archive: the first u32le is the header size in bytes, so the offset
--   table occupies exactly header_size/4 slots. Offsets ascend from
--   header_size and the last one equals the file size; the remaining slots
--   are padding. Repeated offsets are empty placeholder entries.
--   The header size varies per file (32/64/96/128/256/384), so reading a
--   fixed 256 bytes would mistake payload bytes for offsets.
--
-- GC image format (16-color planar, Huffman-compressed):
--   Header:
--     u8[0..1] sig "GC", u8[2..3] version, u8[4] palette flag (0x80 = present),
--     u16le subchunk_table_offset, u16le num_subchunks, u16le entry_size, ...
--   Optional palette: 16 colors * u16le in 0GRB format (4 bits per channel)
--   Subchunk offset table: (num_subchunks+1) * u32le
--   Each GC data chunk (10-byte header + Huffman bitstream):
--     u8 marker (0xA4), u8 checksum,
--     u8 x_offset, u8 y_offset (pixel positions),
--     u8 unknown, u8 width_entries2 (width in 8-pixel units is this >> 1),
--     u16le data_size, u16le unknown
--   Huffman codes (MSB-first, 16-bit bit buffer):
--     00=copy_back, 01=copy_skip, 10=skip, 110=copy_store,
--     1110=copy_move, 1111=copy_backing
--   The height is not stored: the bitstream self-terminates when the chunk's
--   data_size bytes have been consumed, so lines are decoded until then.
--   Output is planar: 4 bytes -> 8 pixels (4 planes)
-- ============================================================================

local engine = {}
engine.name        = "Cobra Mission"
engine.id          = "cobramission"
engine.description = "Cobra Mission (MegaTech, 1992)"
engine.version     = "1.1"

-- ============================================================================
-- Binary helpers
-- ============================================================================

local function u8(data, pos)  return data:byte(pos) end
local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end
local function u32le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536 + data:byte(pos + 3) * 16777216
end

local POW2 = {}
for i = 0, 16 do POW2[i] = 2 ^ i end

local function bittest(v, bit)
    return math.floor(v / POW2[bit]) % 2 == 1
end

-- ============================================================================
-- VOL Archive Reader
-- ============================================================================

local function vol_entries(fh, fsize)
    if fsize < 8 then return {} end
    local head = file_read(fh, 0, 4)
    if not head or #head < 4 then return {} end

    local hdr_size = u32le(head, 1)
    local slots = math.floor(hdr_size / 4)
    if slots < 2 or slots > 4096 or hdr_size > fsize then return {} end

    local tbl = file_read(fh, 0, hdr_size)
    if not tbl or #tbl < hdr_size then return {} end

    local offs = {}
    for i = 0, slots - 1 do
        local v = u32le(tbl, i * 4 + 1)
        if v == 0 or v > fsize then break end
        local n = #offs
        if n > 0 and v < offs[n] then break end
        offs[n + 1] = v
    end
    if #offs < 2 then return {} end

    local entries = {}
    for i = 1, #offs - 1 do
        if offs[i + 1] > offs[i] then
            table.insert(entries, {
                offset = offs[i],
                size = offs[i + 1] - offs[i],
            })
        end
    end
    return entries
end

-- ============================================================================
-- 0GRB Palette (16 colors, 4 bits per channel)
-- ============================================================================

local function parse_0grb(data, pos)
    local pal = {}
    for i = 0, 15 do
        local val = u16le(data, pos + i * 2)
        local r4 = math.floor(val / 16) % 16
        local g4 = math.floor(val / 256)
        local b4 = val % 16
        pal[i * 3 + 1] = r4 * 17
        pal[i * 3 + 2] = g4 * 17
        pal[i * 3 + 3] = b4 * 17
    end
    for i = 16, 255 do pal[i*3+1]=0; pal[i*3+2]=0; pal[i*3+3]=0 end
    return pal
end

local function default_palette()
    local pal = {}
    for i = 0, 15 do
        local v = math.floor(i * 255 / 15)
        pal[i*3+1]=v; pal[i*3+2]=v; pal[i*3+3]=v
    end
    for i = 16, 255 do pal[i*3+1]=0; pal[i*3+2]=0; pal[i*3+3]=0 end
    return pal
end

-- ============================================================================
-- GC Data Chunk Decoder
-- ============================================================================

local DELTAS = { -1, -2, -4, -8, 1, 0 }
local MAX_LINES = 2048
local OP_GUARD = 100000

-- Grow `canvas` (cw x ch) so it can hold at least need_w x need_h pixels.
local function canvas_resize(canvas, cw, ch, need_w, need_h)
    if need_w <= cw and need_h <= ch then return canvas, cw, ch end
    local nw = math.max(cw, 1)
    local nh = math.max(ch, 1)
    while nw < need_w do nw = nw * 2 end
    while nh < need_h do nh = nh * 2 end
    local grown = {}
    for i = 1, nw * nh do grown[i] = 0 end
    for y = 0, ch - 1 do
        local srow = y * cw
        local drow = y * nw
        for x = 0, cw - 1 do grown[drow + x + 1] = canvas[srow + x + 1] end
    end
    return grown, nw, nh
end

-- Decodes one GC subchunk and blits it into the canvas at (x_off, y_off).
local function decode_gc_chunk(data, cpos, canvas, cw, ch)
    if cpos + 9 > #data then return canvas, cw, ch, 0, 0 end
    local x_off = u8(data, cpos + 2)
    local y_off = u8(data, cpos + 3)
    local w_ent = math.floor(u8(data, cpos + 5) / 2)
    local dsize = u16le(data, cpos + 6)
    if w_ent < 1 or dsize < 1 then return canvas, cw, ch, 0, 0 end

    local blen = w_ent * 4
    canvas, cw, ch = canvas_resize(canvas, cw, ch, x_off + w_ent * 8, y_off + 1)

    -- Two line buffers, swapped after every line. `prev` holds the line
    -- above, `cur` is being written and still holds the line two rows up.
    local cur, prev = {}, {}
    for i = 1, blen do cur[i] = 0; prev[i] = 0 end
    local bx = {}
    for i = 1, 1024 do bx[i] = 0 end
    local bxi = 0

    local p = cpos + 10
    local consumed = 0
    local overrun = false
    local offset = 0

    local function rbyte()
        consumed = consumed + 1
        if p > #data then overrun = true; return 0 end
        local v = data:byte(p)
        p = p + 1
        return v
    end

    -- Bit and nibble readers share the byte stream with literal reads.
    local bitbuf, nbits = 0, 0
    local function refill()
        bitbuf = rbyte() + rbyte() * 256
        nbits = 16
    end
    local function gbit()
        local rv = 0
        if bitbuf >= 32768 then rv = 1 end
        bitbuf = (bitbuf * 2) % 65536
        nbits = nbits - 1
        if nbits == 0 then refill() end
        return rv
    end

    local nibbuf, hasnib = 0, false
    local function gnib()
        if hasnib then
            hasnib = false
            return math.floor(nibbuf / 16)
        end
        hasnib = true
        nibbuf = rbyte()
        return nibbuf % 16
    end

    -- Entry-granular access (1-based byte arrays, 0-based entry index).
    local function gget(buf, e)
        local o = e * 4
        if o < 0 or o + 4 > blen then return nil end
        return buf[o + 1], buf[o + 2], buf[o + 3], buf[o + 4]
    end
    local function gput(buf, e, a, b, c, d)
        local o = e * 4
        if o < 0 or o + 4 > blen then
            overrun = true
            return false
        end
        buf[o + 1], buf[o + 2], buf[o + 3], buf[o + 4] = a, b, c, d
        return true
    end

    -- Repeat the previous line's column, or fill from the backing store.
    local function put_prev(e)
        local a, b, c, d = gget(prev, e)
        if not a then
            overrun = true
            return false
        end
        return gput(cur, e, a, b, c, d)
    end

    local function handle_one()
        local op
        if gbit() == 1 then
            if gbit() == 1 then
                if gbit() == 1 then
                    if gbit() == 1 then op = "bx" else op = "move" end
                else op = "store" end
            else op = "skip" end
        else
            if gbit() == 1 then op = "skiptable" else op = "back" end
        end

        if op == "skip" then -- 10: skip single entry
            offset = offset + 1

        elseif op == "store" then -- 110: 4 literal bytes, also into backing table
            local v1, v2, v3, v4 = rbyte(), rbyte(), rbyte(), rbyte()
            gput(cur, offset, v1, v2, v3, v4)
            local bo = bxi * 4
            bx[bo+1], bx[bo+2], bx[bo+3], bx[bo+4] = v1, v2, v3, v4
            bxi = (bxi + 1) % 256
            offset = offset + 1

        elseif op == "bx" then -- 1111: copy from backing table
            local bo = rbyte() * 4
            gput(cur, offset, bx[bo+1], bx[bo+2], bx[bo+3], bx[bo+4])
            offset = offset + 1

        elseif op == "skiptable" then -- 01: copy with skip table
            local v = gnib()
            if v == 0 then
                local v2 = gnib()
                gput(cur, offset,
                    bittest(v2, 0) and 0xFF or 0x00,
                    bittest(v2, 1) and 0xFF or 0x00,
                    bittest(v2, 2) and 0xFF or 0x00,
                    bittest(v2, 3) and 0xFF or 0x00)
                offset = offset + 1
            elseif v == 15 then
                put_prev(offset)
                offset = offset + 1
            else
                -- Only the set bits take a literal byte; the rest of the
                -- entry is left as-is.
                local o = offset * 4
                if o + 4 <= blen then
                    for n = 0, 3 do
                        if bittest(v, n) then
                            cur[o + n + 1] = rbyte()
                        end
                    end
                end
                offset = offset + 1
            end

        elseif op == "move" then -- 1110: copy with move table
            local v = gnib()
            if v == 0 then
                local cb = rbyte()
                local delta = DELTAS[math.floor(cb / 64) + 1]
                local cnt = cb % 64 + 0x12
                for _ = 1, cnt do
                    local d1, d2, d3, d4 = gget(cur, offset + delta)
                    if not d1 then break end
                    gput(cur, offset, d1, d2, d3, d4)
                    offset = offset + 1
                end
            elseif v == 15 then
                local cb = rbyte()
                local cnt = cb % 64 + 0x12
                if math.floor(cb / 64) == 0 then
                    for _ = 1, cnt do
                        if not put_prev(offset) then break end
                        offset = offset + 1
                    end
                else
                    offset = offset + cnt
                end
            else
                -- Set bits always consume a literal byte, so the stream
                -- stays aligned even at offset 0 where the clear bits have
                -- no previous entry to repeat.
                local o = offset * 4
                if o + 4 <= blen then
                    for n = 0, 3 do
                        if bittest(v, n) then
                            cur[o + n + 1] = rbyte()
                        elseif o >= 4 then
                            cur[o + n + 1] = cur[o + n - 3]
                        else
                            cur[o + n + 1] = 0x00
                        end
                    end
                end
                offset = offset + 1
            end

        else -- "back": copy from back
            local a = gnib()
            if a < 4 then
                local d1, d2, d3, d4 = gget(cur, offset + DELTAS[a + 1])
                if d1 then
                    gput(cur, offset, d1, d2, d3, d4)
                else
                    overrun = true
                end
                offset = offset + 1
            else
                local cnt, delta
                if a < 10 then
                    cnt = gnib() + 2
                    delta = DELTAS[a - 3]
                else
                    cnt = w_ent - offset
                    delta = DELTAS[a - 9]
                end
                if delta < 0 then
                    for _ = 1, cnt do
                        if offset >= w_ent then break end
                        local d1, d2, d3, d4 = gget(cur, offset + delta)
                        if not d1 then
                            overrun = true
                            break
                        end
                        gput(cur, offset, d1, d2, d3, d4)
                        offset = offset + 1
                    end
                elseif delta > 0 then
                    for _ = 1, cnt do
                        if offset >= w_ent then break end
                        if not put_prev(offset) then break end
                        offset = offset + 1
                    end
                else
                    offset = offset + cnt
                end
            end
        end
    end

    -- Prime the bit buffer, then decode one line per stream termination.
    refill()
    local lines = 0
    while lines < MAX_LINES and consumed < dsize and not overrun do
        offset = 0
        local guard = 0
        while offset < w_ent and not overrun do
            handle_one()
            guard = guard + 1
            if guard > OP_GUARD then
                overrun = true
                break
            end
        end

        canvas, cw, ch = canvas_resize(canvas, cw, ch,
            x_off + w_ent * 8, y_off + lines + 1)

        local ey = y_off + lines
        if ey < ch then
            for ex = 0, w_ent - 1 do
                local o = ex * 4
                local pb1, pb2, pb3, pb4 = cur[o+1], cur[o+2], cur[o+3], cur[o+4]
                local prow = ey * cw + x_off
                for px = 0, 7 do
                    local bp = 7 - px
                    canvas[prow + ex * 8 + px + 1] =
                          (bittest(pb1, bp) and 1 or 0)
                        + (bittest(pb2, bp) and 2 or 0)
                        + (bittest(pb3, bp) and 4 or 0)
                        + (bittest(pb4, bp) and 8 or 0)
                end
            end
        end

        lines = lines + 1
        cur, prev = prev, cur
    end

    return canvas, cw, ch, x_off + w_ent * 8, y_off + lines
end

-- ============================================================================
-- GC Image Decoder
-- ============================================================================

local function decode_gc(data)
    if #data < 16 then return nil end
    if u8(data, 1) ~= 0x47 or u8(data, 2) ~= 0x43 then return nil end

    local haspal = u8(data, 5) == 0x80
    local tbl_off = u16le(data, 7)
    local nsub = u16le(data, 9)
    if haspal and tbl_off ~= 0x30 then tbl_off = 0x30 end
    if not haspal and tbl_off ~= 0x10 then tbl_off = 0x10 end
    if nsub < 1 or nsub > 4096 then return nil end
    if tbl_off + 4 * (nsub + 1) > #data then return nil end

    local pal = (haspal and 17 + 31 <= #data)
        and parse_0grb(data, 17) or default_palette()

    local canvas, cw, ch = {}, 0, 0
    local used_w, used_h = 0, 0
    for i = 0, nsub - 1 do
        local co = u32le(data, tbl_off + 1 + i * 4)
        if co + 10 <= #data and u8(data, co + 1) == 0xA4 then
            local uw, uh
            canvas, cw, ch, uw, uh = decode_gc_chunk(data, co + 1, canvas, cw, ch)
            if uw > used_w then used_w = uw end
            if uh > used_h then used_h = uh end
        end
    end

    if used_w < 1 or used_h < 1 then return nil end

    -- The canvas is grown by doubling, so crop it back to the extent the
    -- chunks actually covered.
    local pixels = {}
    for y = 0, used_h - 1 do
        local srow = y * cw
        local drow = y * used_w
        for x = 0, used_w - 1 do
            pixels[drow + x + 1] = canvas[srow + x + 1]
        end
    end

    return image_create_indexed(used_w, used_h, pixels, pal)
end

-- ============================================================================
-- Public engine API
-- ============================================================================

local GFX_VOLS = {
    "PIC1", "PIC2", "PIC3", "PICA",
    "CUT1", "CUT2", "CUT3", "CUTA",
    "OPENING", "MAP", "ENM", "ENMA",
}

function engine.detect(game_path)
    local found = 0
    for _, name in ipairs(GFX_VOLS) do
        if file_exists(game_path .. "/" .. name .. ".VOL") then
            found = found + 1
        end
    end
    return found >= 3
end

function engine.get_resources(game_path)
    local tree = {}
    for _, vn in ipairs(GFX_VOLS) do
        local path = game_path .. "/" .. vn .. ".VOL"
        local fh = file_open(path)
        if fh then
            local fs = file_size(fh)
            local ents = vol_entries(fh, fs)
            file_close(fh)
            if #ents > 0 then
                local kids = {}
                for i = 1, #ents do
                    table.insert(kids, {
                        id = vn .. ":" .. (i - 1),
                        name = string.format("Entry %d", i - 1),
                        type = "image",
                    })
                end
                table.insert(tree, {
                    id = "vol_" .. vn, name = vn .. ".VOL",
                    type = "category", children = kids,
                })
            end
        end
    end
    return tree
end

function engine.load_resource(game_path, resource_id)
    local vn, idx_s = resource_id:match("^(.+):(%d+)$")
    if not vn then
        return { type = "text", text = "Unknown resource: " .. resource_id }
    end
    local idx = tonumber(idx_s)

    local fh = file_open(game_path .. "/" .. vn .. ".VOL")
    if not fh then
        return { type = "text", text = "Cannot open " .. vn .. ".VOL" }
    end

    local fs = file_size(fh)
    local ents = vol_entries(fh, fs)
    if idx + 1 > #ents then
        file_close(fh)
        return { type = "text", text = "Entry index out of range" }
    end

    local e = ents[idx + 1]
    local data = file_read(fh, e.offset, e.size)
    file_close(fh)
    if not data then
        return { type = "text", text = "Failed to read entry data" }
    end

    local img = decode_gc(data)
    if img then
        return {
            type = "image", image = img,
            description = string.format("%s.VOL entry %d", vn, idx),
        }
    end

    return {
        type = "text",
        text = string.format("%s.VOL[%d]: %d bytes (not a recognized image)", vn, idx, e.size),
    }
end

return engine

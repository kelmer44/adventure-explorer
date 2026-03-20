-- ============================================================================
-- Adventure Explorer - Engine Script: Cobra Mission
-- ============================================================================
-- MegaTech, 1992. DOS.
--
-- VOL archive: no header, just u32le offset table (padded to 256 bytes).
--   Last non-zero offset = total file size. Entries between consecutive offsets.
--
-- GC image format (16-color planar, Huffman-compressed):
--   Header (16 bytes):
--     u16le sig "GC" (0x4347), u16le version, u16le palette_flag,
--     u16le subchunk_table_offset, u32le num_subchunks,
--     u16le chunk_size, u8 pad, u8 checksum
--   Optional palette: 16 colors * u16le in 0GRB format (4 bits per channel)
--   Subchunk offset table: (num_subchunks+1) * u32le
--   Each GC data chunk (10-byte header + Huffman bitstream):
--     u8 marker (0xA4), u8 checksum,
--     u8 x_offset, u8 y_offset (pixel positions),
--     u8 width_entries (in 8-pixel units), u8 height,
--     u16le data_size, u16le unknown
--   Huffman codes (MSB-first, 16-bit bit buffer):
--     00=copy_back, 01=copy_skip, 10=skip, 110=copy_store,
--     1110=copy_move, 1111=copy_backing
--   Output is planar: 4 bytes -> 8 pixels (4 planes)
-- ============================================================================

local engine = {}
engine.name        = "Cobra Mission"
engine.id          = "cobramission"
engine.description = "Cobra Mission (MegaTech, 1992)"
engine.version     = "1.0"

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

-- ============================================================================
-- VOL Archive Reader
-- ============================================================================

local function vol_entries(fh, fsize)
    local max_tbl = math.min(fsize, 256)
    local tbl = file_read(fh, 0, max_tbl)
    if not tbl or #tbl < 4 then return {} end

    local offs = {}
    for i = 0, math.floor(#tbl / 4) - 1 do
        local o = u32le(tbl, i * 4 + 1)
        if o > 0 and o <= fsize then table.insert(offs, o) end
    end
    table.sort(offs)

    -- Deduplicate
    local uoffs = { offs[1] }
    for i = 2, #offs do
        if offs[i] ~= offs[i - 1] then table.insert(uoffs, offs[i]) end
    end

    local entries = {}
    for i = 1, #uoffs - 1 do
        if uoffs[i] < uoffs[i + 1] then
            table.insert(entries, { offset = uoffs[i], size = uoffs[i + 1] - uoffs[i] })
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
        pal[i * 3 + 1] = r4 * 16 + math.floor(r4 / 4)
        pal[i * 3 + 2] = g4 * 16 + math.floor(g4 / 4)
        pal[i * 3 + 3] = b4 * 16 + math.floor(b4 / 4)
    end
    for i = 16, 255 do pal[i*3+1]=0; pal[i*3+2]=0; pal[i*3+3]=0 end
    return pal
end

-- ============================================================================
-- GC Data Chunk Decoder
-- ============================================================================

local OFF_TABLE = {-1, -2, -4, -8, 1, 0}

local function decode_gc_chunk(data, cpos, csize, canvas, canvas_w)
    if cpos + 9 > #data then return end
    local x_off = u8(data, cpos + 2)
    local y_off = u8(data, cpos + 3)
    local w_ent = u8(data, cpos + 4)
    local height = u8(data, cpos + 5)
    if w_ent < 1 or height < 1 then return end

    local dstart = cpos + 10
    local line_bytes = w_ent * 4
    local total_bytes = w_ent * height * 4

    -- Output buffer (4 bytes per entry, line-organized)
    local out = {}
    for i = 1, total_bytes do out[i] = 0 end
    local opos = 0

    -- Backing store: 256 entries * 4 bytes
    local bk = {}
    for i = 1, 1024 do bk[i] = 0 end
    local bk_idx = 0

    -- Shared stream position
    local spos = dstart

    -- Bit buffer (MSB-first from 16-bit LE word, matching reference decoder)
    local bbuf, bcount = 0, 0
    local function bload()
        if spos + 1 <= #data then
            bbuf = data:byte(spos) + data:byte(spos + 1) * 256
            spos = spos + 2
            bcount = 16
        else
            bbuf = 0
            bcount = 16
        end
    end
    bload()

    local function rbit()
        bcount = bcount - 1
        local bit = math.floor(bbuf / POW2[bcount]) % 2
        if bcount == 0 then bload() end
        return bit
    end

    -- Nibble buffer
    local nib_has = false
    local nib_hi = 0
    local function rnib()
        if nib_has then nib_has = false; return nib_hi end
        if spos > #data then return 0 end
        local b = data:byte(spos); spos = spos + 1
        nib_has = true
        nib_hi = math.floor(b / 16)
        return b % 16
    end

    local function rbyte()
        if spos > #data then return 0 end
        local b = data:byte(spos); spos = spos + 1
        return b
    end

    -- Entry operations
    local function write4(b1, b2, b3, b4)
        if opos + 3 < total_bytes then
            out[opos+1]=b1; out[opos+2]=b2; out[opos+3]=b3; out[opos+4]=b4
        end
        opos = opos + 4
    end

    local function copy_from(src)
        if src >= 0 and src + 3 < total_bytes and opos + 3 < total_bytes then
            out[opos+1]=out[src+1]; out[opos+2]=out[src+2]
            out[opos+3]=out[src+3]; out[opos+4]=out[src+4]
        end
        opos = opos + 4
    end

    local function do_back(off_val, count)
        for _ = 1, count do
            if opos >= total_bytes then break end
            if off_val == 0 then
                opos = opos + 4
            elseif off_val == 1 then
                copy_from(opos - line_bytes)
            else
                copy_from(opos + off_val * 4)
            end
        end
    end

    local function remaining()
        return w_ent - math.floor((opos % line_bytes) / 4)
    end

    -- Decompression loop
    while opos < total_bytes do
        local b1 = rbit()
        local b2 = rbit()

        if b1 == 0 and b2 == 0 then
            -- 00: Copy from back
            local v = rnib()
            if v < 4 then
                do_back(OFF_TABLE[v + 1], 1)
            elseif v < 10 then
                local n = rnib()
                do_back(OFF_TABLE[v - 4 + 1], n + 2)
            else
                do_back(OFF_TABLE[v - 10 + 1], remaining())
            end

        elseif b1 == 0 and b2 == 1 then
            -- 01: Copy with Skip
            local v = rnib()
            if v == 0 then
                local n = rnib()
                local e = {}
                for bit = 0, 3 do
                    e[bit+1] = (math.floor(n / POW2[bit]) % 2 == 1) and 0xFF or 0x00
                end
                write4(e[1], e[2], e[3], e[4])
            elseif v == 15 then
                copy_from(opos - line_bytes)
            else
                local e = {0,0,0,0}
                if opos + 3 < total_bytes then
                    for j=0,3 do e[j+1] = out[opos+j+1] end
                end
                for bit = 0, 3 do
                    if math.floor(v / POW2[bit]) % 2 == 1 then
                        e[bit+1] = rbyte()
                    end
                end
                write4(e[1], e[2], e[3], e[4])
            end

        elseif b1 == 1 and b2 == 0 then
            -- 10: Skip single entry
            opos = opos + 4

        else
            local b3 = rbit()
            if b3 == 0 then
                -- 110: Copy and store
                local r1,r2,r3,r4 = rbyte(),rbyte(),rbyte(),rbyte()
                bk[bk_idx*4+1]=r1; bk[bk_idx*4+2]=r2
                bk[bk_idx*4+3]=r3; bk[bk_idx*4+4]=r4
                bk_idx = (bk_idx + 1) % 256
                write4(r1, r2, r3, r4)
            else
                local b4 = rbit()
                if b4 == 0 then
                    -- 1110: Copy with Move
                    local v = rnib()
                    if v == 0 then
                        local x = rbyte()
                        local cnt = (x % 64) + 18
                        local oidx = math.floor(x / 64)
                        do_back(OFF_TABLE[oidx + 1], cnt)
                    elseif v == 15 then
                        local x = rbyte()
                        local cnt = (x % 64) + 18
                        local top = math.floor(x / 64)
                        if top == 0 then
                            for _ = 1, cnt do
                                if opos >= total_bytes then break end
                                copy_from(opos - line_bytes)
                            end
                        else
                            for _ = 1, cnt do
                                if opos >= total_bytes then break end
                                opos = opos + 4
                            end
                        end
                    else
                        local e = {0,0,0,0}
                        if opos >= 4 then
                            for j=0,3 do e[j+1] = out[opos-4+j+1] end
                        end
                        for bit = 0, 3 do
                            if math.floor(v / POW2[bit]) % 2 == 1 then
                                e[bit+1] = rbyte()
                            end
                        end
                        write4(e[1], e[2], e[3], e[4])
                    end
                else
                    -- 1111: Copy from backing store
                    local idx = rbyte()
                    write4(bk[idx*4+1], bk[idx*4+2], bk[idx*4+3], bk[idx*4+4])
                end
            end
        end
    end

    -- Convert planar output to pixel indices on canvas
    for ey = 0, height - 1 do
        for ex = 0, w_ent - 1 do
            local ep = (ey * w_ent + ex) * 4
            local pb1, pb2, pb3, pb4 = out[ep+1], out[ep+2], out[ep+3], out[ep+4]
            for p = 0, 7 do
                local bp = 7 - p
                local pixel = math.floor(pb1 / POW2[bp]) % 2
                            + math.floor(pb2 / POW2[bp]) % 2 * 2
                            + math.floor(pb3 / POW2[bp]) % 2 * 4
                            + math.floor(pb4 / POW2[bp]) % 2 * 8
                local cx = x_off + ex * 8 + p
                local cy = y_off + ey
                local ci = cy * canvas_w + cx + 1
                if cx < canvas_w and ci >= 1 and ci <= #canvas then
                    canvas[ci] = pixel
                end
            end
        end
    end
end

-- ============================================================================
-- GC Image Decoder
-- ============================================================================

local function decode_gc(data)
    if #data < 16 then return nil end
    local sig = u16le(data, 1)
    if sig ~= 0x4347 then return nil end

    local pal_flag = u16le(data, 5)
    local tbl_off = u16le(data, 7)
    local nsub = u32le(data, 9)
    if nsub < 1 or nsub > 100 then return nil end

    -- Palette
    local pal
    if pal_flag ~= 0 and 17 + 31 <= #data then
        pal = parse_0grb(data, 17)
    end
    if not pal then
        pal = {}
        for i = 0, 15 do
            local v = math.floor(i * 255 / 15)
            pal[i*3+1]=v; pal[i*3+2]=v; pal[i*3+3]=v
        end
        for i = 16, 255 do pal[i*3+1]=0; pal[i*3+2]=0; pal[i*3+3]=0 end
    end

    -- Subchunk offset table
    local tpos = tbl_off + 1
    local soffs = {}
    for i = 0, nsub do
        if tpos + i * 4 + 3 <= #data then
            soffs[i] = u32le(data, tpos + i * 4)
        end
    end

    -- Determine canvas size from chunk headers
    local cw, ch = 0, 0
    for i = 0, nsub - 1 do
        local cp = (soffs[i] or 0) + 1
        if cp + 5 <= #data then
            local x = u8(data, cp + 2)
            local y = u8(data, cp + 3)
            local we = u8(data, cp + 4)
            local he = u8(data, cp + 5)
            local r = x + we * 8
            local b = y + he
            if r > cw then cw = r end
            if b > ch then ch = b end
        end
    end
    if cw < 1 or ch < 1 or cw > 1024 or ch > 1024 then return nil end

    local canvas = {}
    for i = 1, cw * ch do canvas[i] = 0 end

    for i = 0, nsub - 1 do
        local co = soffs[i] or 0
        local ce = soffs[i + 1] or #data
        decode_gc_chunk(data, co + 1, ce - co, canvas, cw)
    end

    return image_create_indexed(cw, ch, canvas, pal)
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

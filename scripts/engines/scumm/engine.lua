-- ============================================================================
-- Adventure Explorer - Engine Script: SCUMM V5-V8 (1991-1997, DOS VGA)
-- ============================================================================
-- Reads SCUMM V5-V8 data files:
--   .000 index + .001 data        (Monkey Island 2, Atlantis, Indy 4, The Dig)
--   .LA0 index + .LA1[.LA2..] data (The Dig V7, The Curse of Monkey Island V8)
--   .SM0 index + .SM1 data        (Space Quest V5/V6)
--   <BASE>.000..<BASE>.015         (Day of the Tentacle, multiple data parts)
--   <BASE>.000 + ROOM/%02d.LFL      (standalone per-room-file releases)
-- Encryption is auto-detected per file: 0x00 plain, 0x69 XOR (V5/V6),
-- 0xFF XOR (old bundle / standalone LFL).
-- IFF-like block structure: 4-byte ASCII tag + 4-byte BE size
-- Room backgrounds: strip-based compression (SMAP), 8px wide vertical strips
-- Palettes: CLUT block (V5/V6) or PALS/WRAP/APAL (V7), 256 * 3 bytes RGB
-- Object sprites: OBIM/IMHD/IMxx/SMAP, V5/V6 widths from the old IMHD
-- layout, V7 from the v7 IMHD layout, V8 from IMAG/WRAP/SMAP
-- Actor sprites: COST (V5/V6) and AKOS (V7/V8) costumes, rendered per
--   animation (scumm_cost.lua)
-- Audio: SOUN resources (SBL digital samples, ROL/GMD MIDI), iMUSE streams and
--   the .BUN music/speech bundles (scumm_snd.lua)
-- ============================================================================

local engine = {}

local Cost  = require("scumm_cost")
local Sound = require("scumm_snd")
local Nut   = require("scumm_nut")

engine.name        = "SCUMM"
engine.id          = "scumm"
engine.description = "SCUMM V5-V8 (LucasArts, 1991-1997)"
engine.version     = "3.0"

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
    return xor_bytes(data, string.char(key))
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

-- ── Key sniffing ────────────────────────────────────────────────
-- SCUMM games use one of three obfuscation keys:
--   0x00  - plaintext        (V6/V7 HE games: The Dig)
--   0x69  - GF_USE_KEY       (V5/V6 floppy releases: MI2, Atlantis, DOTT)
--   0xFF  - old-bundle V0-V3 (Maniac Mansion)
local KEY_CANDIDATES = { 0x00, 0x69, 0xFF }
local DEFAULT_KEY = 0x69

-- Sniff the key of a data file by checking for the LECF container signature.
local function sniff_data_key(data)
    if not data or #data < 4 then return nil end
    for _, key in ipairs(KEY_CANDIDATES) do
        local probe = (key == 0) and data:sub(1, 4) or xor_decrypt(data:sub(1, 4), key)
        if probe == "LECF" then return key end
    end
    return nil
end

-- Sniff the key of an index file by requiring a coherent chain of IFF blocks
-- that includes both DROO and MAXS. Random bytes satisfy this essentially never.
local function sniff_index_key(data)
    if not data or #data < 16 then return nil end
    for _, key in ipairs(KEY_CANDIDATES) do
        local dec = (key == 0) and data or xor_decrypt(data, key)
        local blocks = scan_blocks(dec, 1, #dec)
        if #blocks >= 3 and find_block(blocks, "DROO") and find_block(blocks, "MAXS") then
            local last = blocks[#blocks]
            if last.offset + last.size - 1 >= #dec - 16 then
                return key
            end
        end
    end
    return nil
end

-- ── Index file parsing ──────────────────────────────────────────
-- V5 index: blocks RNAM, MAXS, DROO, DSCR, DSOU, DCOS, DCHR, DOBJ

-- Directory block: count (u16, u32 in V8), `count` room bytes, `count` u32 offsets.
local function parse_directory(data, blk, wide)
    local pos = blk.data_start
    local count = wide and u32le(data, pos) or u16le(data, pos)
    pos = pos + (wide and 4 or 2)
    local list = {}
    if count > 65535 or pos + count * 5 > blk.offset + blk.size then return list, 0 end
    for i = 0, count - 1 do
        list[i] = { room = u8(data, pos + i), offs = u32le(data, pos + count + i * 4) }
    end
    return list, count
end

local function parse_index(data)
    local result = { room_names = {} }
    local blocks = scan_blocks(data, 1, #data)

    -- V8 (COMI) is recognised by its extra DRSC (room scripts) directory and
    -- by 32-bit directory counts.
    local wide = find_block(blocks, "DRSC") ~= nil
    local maxs = find_block(blocks, "MAXS")
    result.version = wide and 8 or ((maxs and maxs.size - 8 >= 30) and 6 or 5)
    if find_block(blocks, "ANAM") then result.version = 7 end

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

    -- DROO: room directory. `room` is the data part / disk number holding the room.
    local droo = find_block(blocks, "DROO")
    if droo then
        local list, count = parse_directory(data, droo, wide)
        result.room_count = count
        result.room_files = {}
        result.room_offsets = {}
        for i = 0, count - 1 do
            result.room_files[i] = list[i].room
            result.room_offsets[i] = list[i].offs
        end
    end

    -- Resource directories: room number + offset inside that room's data
    local dcos = find_block(blocks, "DCOS")
    if dcos then result.costumes = parse_directory(data, dcos, wide) end
    local dsou = find_block(blocks, "DSOU")
    if dsou then result.sounds = parse_directory(data, dsou, wide) end

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
            -- LOFF offsets are relative to the single data part (file 1)
            rooms[#rooms + 1] = { id = room_id, file = 1, offset = offset }
        end
    end

    return rooms
end

--- Every numbered data part opens with a LECF header followed by a room
--- offset table: u8 count, then count entries of (u8 roomId, u32le offset).
--- This is what ScummEngine::readRoomsOffsets reads, and it -- not DROO --
--- is the authoritative room directory: DROO's offsets are zero on
--- multi-part releases such as Day of the Tentacle.
local function parse_room_offset_table(data)
    local rooms = {}
    if tag4(data, 1) ~= "LECF" then return rooms end

    local n = #data
    if n < 17 then return rooms end

    local count = u8(data, 17)          -- 0-based offset 16
    if count == 0 or count > 512 then return rooms end

    local pos = 18
    for _ = 1, count do
        if pos + 5 > n then break end
        local room_id = u8(data, pos)
        local offset  = u32le(data, pos + 1)
        pos = pos + 5
        if room_id > 0 and offset > 0 then
            rooms[#rooms + 1] = { id = room_id, offset = offset }
        end
    end

    return rooms
end

-- Room directory of one data part: the offset-16 table, falling back to LOFF.
local function part_room_table(path, key)
    local f = file_open(path)
    if not f then return nil end
    local head = file_read(f, 0, 65536)
    file_close(f)
    if not head or #head < 17 then return nil end

    local dec = (key == 0) and head or xor_decrypt(head, key)
    local rooms = parse_room_offset_table(dec)
    if #rooms > 0 then return rooms end
    return parse_loff(dec)
end

-- Count the strips in an SMAP by walking its offset table. Used when the
-- image width is unknown (V5/V6 IMHD omits it): real offsets are strictly
-- increasing and point inside the block, so the first entry that does not
-- marks the end of the table.
local function smap_strip_count(data, smap_offset, smap_size)
    local n, prev = 0, 0
    while true do
        local p = smap_offset + 8 + n * 4
        if p + 3 > smap_offset + smap_size - 1 then break end
        local off = u32le(data, p)
        if off < 8 or off >= smap_size or off <= prev then break end
        prev = off
        n = n + 1
    end
    return n
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

    -- RMHD: room header.
    --   V5/V6: u16 width, u16 height, u16 numObjects
    --   V7:    u32 version (e.g. 730), u16 width, u16 height, u16 numObjects
    local rmhd = find_block(room_blocks, "RMHD")
    if rmhd then
        local version = u32le(data, rmhd.data_start)
        if version >= 800 and version < 1000 then
            -- V8: version, width, height, numObjects are all 32-bit
            result.version     = version
            result.width       = u32le(data, rmhd.data_start + 4)
            result.height      = u32le(data, rmhd.data_start + 8)
            result.num_objects = u32le(data, rmhd.data_start + 12)
        elseif version >= 700 and version < 1000 then
            result.version     = version
            result.width       = u16le(data, rmhd.data_start + 4)
            result.height      = u16le(data, rmhd.data_start + 6)
            result.num_objects = u16le(data, rmhd.data_start + 8)
        else
            result.width       = u16le(data, rmhd.data_start)
            result.height      = u16le(data, rmhd.data_start + 2)
            result.num_objects = u16le(data, rmhd.data_start + 4)
        end
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

    -- V8 background: IMAG -> WRAP -> (OFFS, SMAP) where the SMAP wraps its strip
    -- data in BSTR -> WRAP -> OFFS. Strip offsets are relative to that inner
    -- OFFS block, 24 bytes into the SMAP.
    if not result.smap_offset then
        local imag = find_block(room_blocks, "IMAG")
        if imag then
            local wrap = find_block(scan_blocks(data, imag.data_start, imag.offset + imag.size - 1), "WRAP")
            if wrap then
                local smap = find_block(scan_blocks(data, wrap.data_start, wrap.offset + wrap.size - 1), "SMAP")
                if smap then
                    result.smap_offset = smap.offset + 24
                    result.smap_size   = smap.size - 24
                end
            end
        end
    end

    -- PALS (V6/V7): payload is a single WRAP block holding a padded OFFS
    -- directory followed by one APAL block per palette (768 bytes of RGB).
    -- The OFFS table cannot be used to count palettes -- its declared size is
    -- padded into the following APAL header -- so scan for the APAL children.
    local pals = find_block(room_blocks, "PALS")
    if pals then
        local pals_end = pals.offset + pals.size - 1
        local wrap = find_block(scan_blocks(data, pals.data_start, pals_end), "WRAP")
        if wrap then
            local wrap_end = wrap.offset + wrap.size - 1
            for _, child in ipairs(scan_blocks(data, wrap.data_start, wrap_end)) do
                if child.tag == "APAL" then
                    local pal = {}
                    for i = 0, 767 do
                        pal[i + 1] = u8(data, child.data_start + i) or 0
                    end
                    result.palettes = result.palettes or {}
                    result.palettes[#result.palettes + 1] = pal
                end
            end
        end
    end
    if result.palettes and result.palettes[1] then
        result.palette = result.palettes[1]
    end

    -- OBIM blocks (V5-V7): each holds an IMHD header plus IMxx image states.
    -- IMxx payloads contain an SMAP. IMHD.width is in pixels, so the strip
    -- count is ceil(width / 8) -- each strip covers 8 horizontal pixels.
    result.objects = {}
    for _, obim in ipairs(room_blocks) do
        if obim.tag == "OBIM" then
            local obim_end = obim.offset + obim.size - 1
            local obim_blocks = scan_blocks(data, obim.data_start, obim_end)
            local imhd = find_block(obim_blocks, "IMHD")

            local obj
            if imhd then
                local version = u32le(data, imhd.data_start)
                local v8_version = u32le(data, imhd.data_start + 40)
                if v8_version >= 800 and v8_version < 1000 and imhd.size >= 88 then
                    -- V8: name[32], 2 x u32, version, imageCount, x, y, width, height ...
                    local name = data:sub(imhd.data_start, imhd.data_start + 31):gsub("%z.*", "")
                    obj = {
                        obj_id = #result.objects + 1,
                        name   = name,
                        states = u32le(data, imhd.data_start + 44),
                        x      = u32le(data, imhd.data_start + 48),
                        y      = u32le(data, imhd.data_start + 52),
                        width  = u32le(data, imhd.data_start + 56),
                        height = u32le(data, imhd.data_start + 60),
                        images = {}
                    }
                    local imag = find_block(obim_blocks, "IMAG")
                    local wrap = imag and find_block(
                        scan_blocks(data, imag.data_start, imag.offset + imag.size - 1), "WRAP")
                    if wrap then
                        local state = 0
                        for _, sm in ipairs(scan_blocks(data, wrap.data_start, wrap.offset + wrap.size - 1)) do
                            if sm.tag == "SMAP" then
                                state = state + 1
                                if obj.width > 0 and obj.height > 0 then
                                    obj.images[#obj.images + 1] = {
                                        state       = state,
                                        smap_offset = sm.offset + 24,
                                        smap_size   = sm.size - 24,
                                        width       = obj.width,
                                        height      = obj.height
                                    }
                                end
                            end
                        end
                    end
                elseif version >= 700 and version < 1000 then
                    obj = {
                        obj_id = u16le(data, imhd.data_start + 4),
                        states = u16le(data, imhd.data_start + 6),
                        x      = u16le(data, imhd.data_start + 8),
                        y      = u16le(data, imhd.data_start + 10),
                        width  = u16le(data, imhd.data_start + 12),
                        height = u16le(data, imhd.data_start + 14),
                        images = {}
                    }
                else
                    -- V5/V6 ("old") IMHD: u16 objId, u16 imageCount,
                    -- u16 unk, u8 flags, u8 unk1, u16 unk2[2],
                    -- u16 width, u16 height, u16 hotspotCount, i16 hotspot[15][2]
                    obj = {
                        obj_id = u16le(data, imhd.data_start),
                        states = u16le(data, imhd.data_start + 2),
                        x      = u16le(data, imhd.data_start + 4),
                        y      = u16le(data, imhd.data_start + 6),
                        width  = u16le(data, imhd.data_start + 12),
                        height = u16le(data, imhd.data_start + 14),
                        images = {}
                    }
                end
            end

            if obj and #obj.images == 0 then
                for _, im in ipairs(obim_blocks) do
                    local state = tonumber(im.tag:match("^IM(%d%d)$"))
                    if state then
                        local smap = find_block(
                            scan_blocks(data, im.data_start, im.offset + im.size - 1), "SMAP")
                        if smap then
                            local width = obj.width
                                  or smap_strip_count(data, smap.offset, smap.size) * 8
                            local height = obj.height
                            if height and height > 0 then
                                obj.images[#obj.images + 1] = {
                                    state       = state,
                                    smap_offset = smap.offset,
                                    smap_size   = smap.size,
                                    width       = width,
                                    height      = height
                                }
                            end
                        end
                    end
                end
            end

            if obj and #obj.images > 0 then
                result.objects[#result.objects + 1] = obj
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

-- ── Decode a full SMAP bitmap ───────────────────────────────────
-- SMAP strip offsets are u32 values relative to the SMAP *tag* position
-- (not its payload), so every offset is resolved against smap_offset.
-- num_strips is counted in 8-pixel strips; width/height are in pixels.

local function decode_smap(data, smap_offset, smap_size, width, height, num_strips, trans_color)
    if not smap_offset or not smap_size or not width or not height then
        return nil
    end
    num_strips = num_strips or math.ceil(width / 8)
    if num_strips <= 0 then return nil end

    local offsets = {}
    for s = 0, num_strips - 1 do
        local off_pos = smap_offset + 8 + s * 4
        if off_pos + 3 > #data then return nil end
        offsets[s] = u32le(data, off_pos)
    end

    -- Pixel buffer: row-major, width * height
    local pixels = {}
    for i = 1, width * height do pixels[i] = 0 end

    local decoded_count = 0

    for s = 0, num_strips - 1 do
        if offsets[s] and offsets[s] > 0 then
            local strip_pos = smap_offset + offsets[s]

            -- Strip data runs until the next strip (or the end of the SMAP)
            local strip_end
            if s < num_strips - 1 and offsets[s + 1] and offsets[s + 1] > offsets[s] then
                strip_end = smap_offset + offsets[s + 1] - 1
            else
                strip_end = smap_offset + smap_size - 1
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

-- Decode a room background: the room width counts pixels, strips are 8px wide.
local function decode_room_background(data, room_info)
    if not room_info.smap_offset or not room_info.width or not room_info.height then
        return nil
    end
    return decode_smap(data, room_info.smap_offset, room_info.smap_size,
        room_info.width, room_info.height,
        math.ceil(room_info.width / 8),
        room_info.transparent_color or 0)
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

-- Read an entire file into a binary string (nil when unreadable/empty)
local function read_whole_file(path)
    local f = file_open(path)
    if not f then return nil end
    local size = file_size(f)
    if not size or size <= 0 then file_close(f); return nil end
    local data = file_read(f, 0, size)
    file_close(f)
    return data
end

-- Sniff a data file's key from its first bytes (avoids loading huge files)
local function sniff_data_file_key(path)
    local f = file_open(path)
    if not f then return nil end
    local head = file_read(f, 0, 8)
    file_close(f)
    return sniff_data_key(head)
end

-- Some releases ship one .LFL per room instead of a single data file
-- (Day of the Tentacle). Locate the directory holding them, if any.
local function find_room_file_dir(game_path)
    for _, name in ipairs(list_files(game_path)) do
        if name:upper():match("%.LFL$") then return "" end
    end
    for _, sub in ipairs(list_files(game_path)) do
        local found
        for _, name in ipairs(list_files(game_path .. "/" .. sub)) do
            if name:upper():match("%.LFL$") then found = sub; break end
        end
        if found then return found end
    end
    return nil
end

-- Returns list of game records:
--   { dir, base_name, index_path, data_path, data_files, xor_key, data_key, room_dir }
-- data_path is nil when rooms live in standalone .LFL files (room_dir set).
-- data_files maps DROO file numbers to paths for multi-part releases
-- (Day of the Tentacle: TENTACLE.000 index + TENTACLE.001/.002/.003 rooms).
local function find_scumm_games(game_path)
    local games = {}
    local files = list_files(game_path)

    -- Case-insensitive lookup: UPPERCASE -> actual filename
    local name_map = {}
    for _, f in ipairs(files) do
        name_map[f:upper()] = f
    end

    local room_dir = find_room_file_dir(game_path)

    local function try_pair(base, idx_ext, data_ext)
        local idx_file = name_map[(base .. idx_ext):upper()]
        if not idx_file then return end

        local index_path = game_path .. "/" .. idx_file
        local index_raw = read_whole_file(index_path)
        if not index_raw then return end

        -- The key is validated by the index contents, not assumed per extension
        local key = sniff_index_key(index_raw)
        if not key then return end

        -- Collect every numbered data part belonging to this base name.
        -- DROO file number 0 is the index file itself (which on multi-part
        -- releases such as Day of the Tentacle also holds some rooms).
        local data_files = { [0] = index_path }
        -- Numbered parts follow the index extension: .000 -> .001 .002 ...,
        -- .la0 -> .la1 .la2 ... (COMI's two discs), .sm0 -> .sm1 ...
        local ext_stem = idx_ext:sub(2, -2)  -- "la", "sm" or "00"
        for num = 1, 15 do
            local fname
            if num == 1 then
                fname = base .. data_ext
            elseif idx_ext == ".000" then
                fname = string.format("%s.%03d", base, num)
            else
                fname = string.format("%s.%s%d", base, ext_stem, num)
            end
            local part = name_map[fname:upper()]
            if part then data_files[num] = game_path .. "/" .. part end
        end

        local data_path, data_key = data_files[1], nil
        if data_path then
            data_key = sniff_data_file_key(data_path)
            if not data_key then return end
        end
        -- A validated index identifies the game on its own. When its data
        -- parts are absent the game still registers, so get_resources can name
        -- the missing part instead of the game not being detected at all.

        games[#games + 1] = {
            dir        = game_path,
            base_name  = base,
            index_path = index_path,
            data_path  = data_path,
            data_files = data_files,
            xor_key    = key,
            data_key   = data_key or key,
            room_dir   = data_path and nil or room_dir
        }
    end

    -- .000/.001  V5/V6 floppy releases (Monkey Island 2, Atlantis, Monkey)
    -- .la0/.la1  V7 HE releases (The Dig)
    -- .sm0/.sm1  older V6 HE releases
    for _, f in ipairs(files) do
        local base, ext = f:match("^(.+)%.([^.]+)$")
        if base then
            local up = ext:upper()
            if up == "000" then
                try_pair(base, ".000", ".001")
            elseif up == "LA0" then
                try_pair(base, ".la0", ".la1")
            elseif up == "SM0" then
                try_pair(base, ".sm0", ".sm1")
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

-- ── Per-game state (index + room table) ──────────────────────────
-- Cached per index file so get_resources/load_resource share one parse.

local game_states = {}

-- Path of the standalone .LFL holding one room, if this release uses them.
local function lfl_room_path(game, room_id)
    local dir = game.dir
    if game.room_dir and game.room_dir ~= "" then
        dir = dir .. "/" .. game.room_dir
    end
    return dir .. "/" .. string.format("%02d.LFL", room_id)
end

local function get_game_state(game)
    local cached = game_states[game.index_path]
    if cached then return cached end

    local state = { index = {}, rooms = {} }
    game_states[game.index_path] = state

    local index_raw = read_whole_file(game.index_path)
    if index_raw then
        state.index = parse_index(xor_decrypt(index_raw, game.xor_key))
    end

    if game.data_path then
        -- Rooms are found via the offset-16 table of each numbered data part.
        -- DROO only says which part a room belongs to (its offsets are 0 on
        -- multi-part releases), so honour it whenever that part is present.
        local by_id = {}
        for file = 0, 15 do
            local path = game.data_files[file]
            if path then
                for _, r in ipairs(part_room_table(path, game.data_key) or {}) do
                    local entry = by_id[r.id]
                    if not entry then
                        entry = { id = r.id, offsets = {} }
                        by_id[r.id] = entry
                    end
                    entry.offsets[file] = r.offset
                end
            end
        end

        for _, entry in pairs(by_id) do
            local want  = state.index.room_files[entry.id]
            local file, offset
            if want and entry.offsets[want] then
                file, offset = want, entry.offsets[want]
            else
                -- No DROO hint (or that part is missing): take the last part
                -- that lists the room, matching ScummVM's own preference.
                for f = 15, 0, -1 do
                    if entry.offsets[f] then
                        file, offset = f, entry.offsets[f]
                        break
                    end
                end
            end
            if offset then
                state.rooms[#state.rooms + 1] =
                    { id = entry.id, file = file, offset = offset }
            end
        end
    end

    if #state.rooms == 0 and game.room_dir ~= nil then
        -- Per-room-file release: DROO only carries the room count and the
        -- rooms themselves live in ROOM/%02d.LFL. Only offer rooms that are
        -- actually present, so a bundled sub-game's .LFL files (Maniac
        -- Mansion ships inside Day of the Tentacle) are never mistaken for
        -- this game's rooms.
        for id = 0, (state.index.room_count or 0) - 1 do
            if file_exists(lfl_room_path(game, id)) then
                state.rooms[#state.rooms + 1] = { id = id }
            end
        end
    end

    -- DROO names the data part each room belongs to. When none of those parts
    -- are installed, say so once and by name instead of failing per room.
    if not game.data_path and state.index.room_count then
        local wanted = {}
        for id = 0, state.index.room_count - 1 do
            local f = state.index.room_files[id]
            if f and not game.data_files[f] then
                wanted[f] = string.format("%s.%03d", game.base_name, f)
            end
        end
        local names = {}
        for _, v in pairs(wanted) do names[#names + 1] = v end
        if #names > 0 then
            table.sort(names)
            state.missing_parts = names
            log_warn(string.format(
                "%s: index declares %d rooms but data part(s) %s are not installed",
                game.base_name, state.index.room_count, table.concat(names, ", ")))
        end
    end

    table.sort(state.rooms, function(a, b) return a.id < b.id end)
    return state
end

local function find_room_entry(rooms, room_id)
    for _, r in ipairs(rooms) do
        if r.id == room_id then return r end
    end
    return nil
end

-- Read the block that starts at a file offset and return it decrypted. An LFLF
-- wrapper is skipped so only its ROOM child is read (V7/V8 LFLFs also hold the
-- costumes, sounds and scripts, which can be megabytes).
local function read_block_at(path, key, offset)
    local f = file_open(path)
    if not f then return nil end
    local header = xor_decrypt(file_read(f, offset, 16) or "", key)
    if #header < 8 then file_close(f); return nil end

    local tag = header:sub(1, 4)
    if tag ~= "ROOM" and tag ~= "LFLF" then
        file_close(f)
        log_warn("Unexpected tag '" .. tag .. "' at room offset " .. offset)
        return nil
    end

    local start, size = offset, u32be(header, 5)
    if tag == "LFLF" and #header >= 16 and header:sub(9, 12) == "ROOM" then
        start, size = offset + 8, u32be(header, 13)
    end
    local raw = file_read(f, start, size)
    file_close(f)
    return raw and xor_decrypt(raw, key) or nil
end

-- Locate a room inside a standalone .LFL file. Such a file begins with a
-- fixed header followed by a room offset table: u8 count, then count
-- entries of (u8 roomId, u32 absolute file offset).
local function lfl_room_offset(raw, room_id)
    local n = #raw
    for _, base in ipairs({ 16, 12 }) do
        local count = (base + 1 <= n) and u8(raw, base + 1) or 0
        if count > 0 and count < 512 and base + 1 + count * 5 <= n then
            local p = base + 2
            for _ = 1, count do
                local rid = u8(raw, p)
                local off = u32le(raw, p + 1)
                p = p + 5
                if rid == room_id and off > 0 and off + 8 <= n then
                    return off
                end
            end
        end
    end
    return nil
end

local function read_lfl_room(path, room_id)
    local raw = read_whole_file(path)
    if not raw then return nil end
    -- Each release used its own key; try them all and keep the one that
    -- yields a plausible room block.
    for _, key in ipairs(KEY_CANDIDATES) do
        local dec = (key == 0) and raw or xor_decrypt(raw, key)
        local off = lfl_room_offset(dec, room_id)
        if off then
            local tag = tag4(dec, off + 1)
            if tag == "ROOM" or tag == "LFLF" then
                return dec:sub(off + 1)
            end
        end
    end
    return nil
end

-- Read and decrypt the room block for a room id, however the game stores it.
local function read_room(game, room_id)
    local state = get_game_state(game)
    local entry = find_room_entry(state.rooms, room_id)
    if not entry then return nil end

    if game.data_path then
        if not entry.offset then return nil end
        -- DROO records which data part each room lives in; multi-part
        -- releases (TENTACLE.000/.001/.002) rely on it.
        local part = game.data_files[entry.file or 0]
        if not part then return nil end
        return read_block_at(part, game.data_key, entry.offset)
    end

    local dir = game.dir
    if game.room_dir and game.room_dir ~= "" then
        dir = dir .. "/" .. game.room_dir
    end
    return read_lfl_room(lfl_room_path(game, room_id), room_id)
end

-- Build the tree node list for one room's object sprites.
local function sprite_children(game, room)
    local room_data = read_room(game, room.id)
    if not room_data then return nil end
    local room_info = parse_room(room_data, 0, #room_data)
    if not room_info or not room_info.objects then return nil end

    local sprites = {}
    for _, obj in ipairs(room_info.objects) do
        for _, img in ipairs(obj.images) do
            sprites[#sprites + 1] = {
                id = string.format("obj:%s:%d:%d:%d",
                    game.base_name, room.id, obj.obj_id, img.state),
                name = string.format("Object %d — state %d (%dx%d)",
                    obj.obj_id, img.state, img.width, img.height),
                type = "image"
            }
        end
    end
    return sprites
end

-- ── Resource location (costumes, sounds) ────────────────────────
-- Directory entries (DCOS/DSOU) give a room number plus an offset relative to
-- that room's start; the room itself is found through the part's room table.

-- Standalone .LFL file of a room: key + 0-based offset of its ROOM block.
local function lfl_locate(game, room_id)
    local path = lfl_room_path(game, room_id)
    local raw = read_whole_file(path)
    if not raw then return nil end
    for _, key in ipairs(KEY_CANDIDATES) do
        local dec = (key == 0) and raw or xor_decrypt(raw, key)
        local off = lfl_room_offset(dec, room_id)
        if off then
            local tag = tag4(dec, off + 1)
            if tag == "ROOM" or tag == "LFLF" then return path, key, off end
        end
    end
    return nil
end

local function res_origin(game, state, room_id)
    state.origins = state.origins or {}
    local cached = state.origins[room_id]
    if cached ~= nil then return cached or nil end

    local origin = false
    local entry = find_room_entry(state.rooms, room_id)
    if entry then
        if game.data_path then
            local part = game.data_files[entry.file or 0]
            if part and entry.offset then
                origin = { path = part, key = game.data_key, base = entry.offset }
            end
        else
            local path, key, off = lfl_locate(game, room_id)
            if path then origin = { path = path, key = key, base = off } end
        end
    end
    state.origins[room_id] = origin
    return origin or nil
end

-- `res` = { room =, offs = } from a directory block; rel is relative to the resource.
local function read_res_range(game, state, res, rel, len)
    local origin = res_origin(game, state, res.room)
    if not origin then return nil end
    local f = file_open(origin.path)
    if not f then return nil end
    local raw = file_read(f, origin.base + res.offs + rel, len)
    file_close(f)
    if not raw then return nil end
    return xor_decrypt(raw, origin.key)
end

local function read_res_block(game, state, res, expect_tag)
    local head = read_res_range(game, state, res, 0, 8)
    if not head or #head < 8 then return nil end
    if expect_tag and head:sub(1, #expect_tag) ~= expect_tag then return nil end
    local size = u32be(head, 5)
    if size < 8 or size > 64 * 1024 * 1024 then return nil end
    return read_res_range(game, state, res, 0, size)
end

local function valid_resource(state, dir, id)
    local res = dir and dir[id]
    if not res or res.room == 0 then return nil end
    if not find_room_entry(state.rooms, res.room) then return nil end
    return res
end

-- ── Costume tree ────────────────────────────────────────────────

-- Cheap summary of an AKOS costume: only block headers, AKHD and AKCH are read.
local function akos_summary(game, state, res)
    local head = read_res_range(game, state, res, 0, 8)
    if not head or head:sub(1, 4) ~= "AKOS" then return nil end
    local total = u32be(head, 5)
    local pos, chores, cels = 8, nil, 0
    local chore_count = 0
    while pos + 8 <= total do
        local h = read_res_range(game, state, res, pos, 8)
        if not h or #h < 8 then break end
        local tag, size = h:sub(1, 4), u32be(h, 5)
        if size < 8 then break end
        if tag == "AKHD" then
            local p = read_res_range(game, state, res, pos + 8, 12)
            if p then chore_count, cels = u16le(p, 5), u16le(p, 7) end
        elseif tag == "AKCH" then
            local p = read_res_range(game, state, res, pos + 8, size - 8)
            chores = {}
            for c = 0, chore_count - 1 do
                if p and u16le(p, c * 2 + 1) ~= 0 then chores[#chores + 1] = c end
            end
            break
        end
        pos = pos + size
    end
    return { chores = chores or {}, cels = cels }
end

local function costume_children(game, state)
    local dir = state.index.costumes
    if not dir then return nil, 0 end
    local nodes = {}
    for id = 1, #dir do
        local res = valid_resource(state, dir, id)
        if res then
            local children = {}
            local label
            local info = akos_summary(game, state, res)
            if info then
                -- V7/V8
                if info.cels > 0 then
                    children[#children + 1] = {
                        id = string.format("cossheet:%s:%d", game.base_name, id),
                        name = string.format("All cels (%d)", info.cels), type = "image" }
                end
                for _, c in ipairs(info.chores) do
                    children[#children + 1] = {
                        id = string.format("cosanim:%s:%d:%d", game.base_name, id, c),
                        name = string.format("Chore %d", c), type = "animation" }
                end
                label = string.format("%d chore(s), %d cel(s)", #info.chores, info.cels)
            else
                local block = read_res_block(game, state, res, "COST")
                local cost = block and Cost.parse(block, state.index.version)
                if cost then
                    children[#children + 1] = {
                        id = string.format("cossheet:%s:%d", game.base_name, id),
                        name = "All cels", type = "image" }
                    local anims = cost:animations()
                    for _, a in ipairs(anims) do
                        children[#children + 1] = {
                            id = string.format("cosanim:%s:%d:%d", game.base_name, id, a.id),
                            name = a.name, type = "animation" }
                    end
                    label = string.format("%d animation(s)", #anims)
                end
            end
            if #children > 0 then
                nodes[#nodes + 1] = {
                    id = string.format("cos:%s:%d", game.base_name, id),
                    name = string.format("Costume %d (room %d) — %s", id, res.room, label or ""),
                    type = "category", children = children }
            end
        end
    end
    return nodes, #nodes
end

-- ── Sound tree ──────────────────────────────────────────────────

-- Tags of the chunks inside a SOUN resource (headers only).
local function sound_tags(game, state, res)
    local head = read_res_range(game, state, res, 0, 16)
    if not head or #head < 16 or head:sub(1, 4) ~= "SOUN" then return nil end
    local base = head:sub(9, 12)
    if base ~= "SOU " then return { base } end
    local total = u32be(head, 13)
    local tags, pos = {}, 16
    while pos < 16 + total and #tags < 16 do
        local h = read_res_range(game, state, res, pos, 8)
        if not h or #h < 8 then break end
        tags[#tags + 1] = h:sub(1, 4)
        pos = pos + 8 + u32be(h, 5)
    end
    return tags
end

local function tag_id(tag) return (tag:gsub(" ", "_")) end
local function tag_from_id(id) return (id:gsub("_", " ")) end

local function sound_children(game, state)
    local dir = state.index.sounds
    if not dir then return nil, 0 end
    local nodes, listed, unplayable = {}, 0, 0
    for id = 1, #dir do
        local res = valid_resource(state, dir, id)
        if res then
            local tags = sound_tags(game, state, res)
            local leaves = {}
            for _, tag in ipairs(tags or {}) do
                local kind = Sound.chunk_kind(tag)
                if kind then
                    leaves[#leaves + 1] = {
                        id = string.format("snd:%s:%d:%s", game.base_name, id, tag_id(tag)),
                        name = string.format("Sound %d — %s", id, Sound.device_name(tag)),
                        type = kind }
                end
            end
            if #leaves == 1 then
                nodes[#nodes + 1] = leaves[1]
                listed = listed + 1
            elseif #leaves > 1 then
                nodes[#nodes + 1] = {
                    id = string.format("sound:%s:%d", game.base_name, id),
                    name = string.format("Sound %d (%d versions)", id, #leaves),
                    type = "category", children = leaves }
                listed = listed + 1
            elseif tags then
                unplayable = unplayable + 1
            end
        end
    end
    return nodes, listed, unplayable
end

-- ── Audio bundles (.BUN) ────────────────────────────────────────

local bundle_cache = {}

local function find_files_with_ext(game_path, ext)
    local paths = {}
    local function scan(dir)
        for _, name in ipairs(list_files(dir)) do
            if name:upper():match("%." .. ext .. "$") then paths[#paths + 1] = dir .. "/" .. name end
        end
    end
    scan(game_path)
    for _, sub in ipairs(list_files(game_path)) do
        local up = sub:upper()
        if not up:match("%.") then scan(game_path .. "/" .. sub) end
    end
    return paths
end

local function find_bundle_paths(game_path)
    return find_files_with_ext(game_path, "BUN")
end

local function get_bundle(path)
    local b = bundle_cache[path]
    if b == nil then
        b = Sound.read_bundle(path) or false
        bundle_cache[path] = b
    end
    return b or nil
end

local sou_cache = {}

local function find_sou_paths(game_path)
    local paths = {}
    for _, name in ipairs(list_files(game_path)) do
        if name:upper():match("%.SOU$") then paths[#paths + 1] = game_path .. "/" .. name end
    end
    return paths
end

local function get_sou(path)
    local v = sou_cache[path]
    if v == nil then
        v = Sound.read_sou(path) or false
        sou_cache[path] = v
    end
    return v or nil
end

local function font_resources(game_path)
    local leaves = {}
    for _, path in ipairs(find_files_with_ext(game_path, "NUT")) do
        local name = path:match("([^/\\]+)$")
        leaves[#leaves + 1] = { id = "nut:" .. name, name = name, type = "image" }
    end
    if #leaves == 0 then return nil end
    return { id = "fonts_nut", name = string.format("Fonts (NUT, %d)", #leaves),
             type = "category", children = leaves }
end

local function bundle_resources(game_path)
    local nodes = {}
    for _, path in ipairs(find_sou_paths(game_path)) do
        local sou = get_sou(path)
        if sou then
            local groups, children = {}, {}
            for i = 1, #sou.clips do
                local g = math.floor((i - 1) / 200)
                groups[g] = groups[g] or {}
                table.insert(groups[g], { id = string.format("sou:%s:%d", sou.name, i),
                    name = string.format("Clip %d", i), type = "sound" })
            end
            for g = 0, math.floor(#sou.clips / 200) do
                if groups[g] then
                    children[#children + 1] = {
                        id = string.format("sougrp:%s:%d", sou.name, g),
                        name = string.format("Clips %d-%d", g * 200 + 1, g * 200 + #groups[g]),
                        type = "category", children = groups[g] }
                end
            end
            nodes[#nodes + 1] = { id = "souarc:" .. sou.name,
                name = string.format("%s — speech (%d clips)", sou.name, #sou.clips),
                type = "category", children = children }
        end
    end
    for _, path in ipairs(find_bundle_paths(game_path)) do
        local bundle = get_bundle(path)
        if bundle then
            local leaves = {}
            for i, e in ipairs(bundle.entries) do
                leaves[#leaves + 1] = {
                    id = string.format("bun:%s:%d", bundle.name, i),
                    name = e.name, type = "sound" }
            end
            -- Large bundles (thousands of voice lines) are grouped by name prefix
            local children = leaves
            if #leaves > 300 then
                local groups, order = {}, {}
                for _, leaf in ipairs(leaves) do
                    local key = leaf.name:sub(1, 3):upper()
                    if not groups[key] then groups[key] = {}; order[#order + 1] = key end
                    table.insert(groups[key], leaf)
                end
                table.sort(order)
                children = {}
                for _, key in ipairs(order) do
                    children[#children + 1] = {
                        id = string.format("bungrp:%s:%s", bundle.name, key),
                        name = string.format("%s* (%d)", key, #groups[key]),
                        type = "category", children = groups[key] }
                end
            end
            nodes[#nodes + 1] = {
                id = "bundle:" .. bundle.name,
                name = string.format("%s — %s bundle (%d sounds)", bundle.name,
                    Sound.bundle_kind(bundle.name), #bundle.entries),
                type = "category", children = children }
        end
    end
    return nodes
end

-- ── Resource tree ───────────────────────────────────────────────

function engine.get_resources(game_path)
    local resources = {}
    local games = find_scumm_games(game_path)

    for _, game in ipairs(games) do
        local state = get_game_state(game)
        if #state.rooms > 0 then
            local room_children = {}

            for _, room in ipairs(state.rooms) do
                local room_name = state.index.room_names
                              and state.index.room_names[room.id]
                local display = (room_name and #room_name > 0)
                    and string.format("Room %d: %s", room.id, room_name)
                    or  string.format("Room %d", room.id)

                local prefix = "room:" .. game.base_name .. ":" .. room.id

                local children = {
                    {
                        id   = "bg:" .. game.base_name .. ":" .. room.id,
                        name = display .. " — Background",
                        type = "image"
                    },
                    {
                        -- Palette node is consumed by the colour dropdown
                        id   = "pal:" .. game.base_name .. ":" .. room.id,
                        name = display .. " — Palette",
                        type = "palette"
                    }
                }

                -- Per-room object sprites come from the OBIM/IMxx sub-blocks.
                -- Only block headers are parsed here (no pixel decoding), so
                -- this costs one room read per room.
                local sprites = sprite_children(game, room)
                if sprites and #sprites > 0 then
                    children[#children + 1] = {
                        id = "sprites:" .. game.base_name .. ":" .. room.id,
                        name = string.format("Room %d — Object sprites (%d)",
                            room.id, #sprites),
                        type = "category",
                        children = sprites
                    }
                end

                room_children[#room_children + 1] = {
                    id = prefix,
                    name = display,
                    type = "category",
                    children = children
                }
            end

            local game_children = {
                { id = "rooms_" .. game.base_name,
                  name = string.format("Rooms (%d)", #room_children),
                  type = "category", children = room_children }
            }

            local costumes, ncos = costume_children(game, state)
            if costumes and ncos > 0 then
                game_children[#game_children + 1] = {
                    id = "costumes_" .. game.base_name,
                    name = string.format("Costumes / actor sprites (%d)", ncos),
                    type = "category", children = costumes }
            end

            local sounds, nsnd, skipped = sound_children(game, state)
            if sounds and nsnd > 0 then
                local label = string.format("Sounds / music (%d)", nsnd)
                if skipped and skipped > 0 then
                    label = label .. string.format(" — %d AdLib/PC-speaker only not shown", skipped)
                end
                game_children[#game_children + 1] = {
                    id = "sounds_" .. game.base_name, name = label,
                    type = "category", children = sounds }
            end

            resources[#resources + 1] = {
                id = "game_" .. game.base_name,
                name = string.format("%s (%d rooms)", game.base_name, #state.rooms),
                type = "category",
                children = game_children
            }
        end
    end

    for _, node in ipairs(bundle_resources(game_path)) do
        resources[#resources + 1] = node
    end
    local fonts = font_resources(game_path)
    if fonts then resources[#resources + 1] = fonts end

    return resources
end

-- ── Resource loading ────────────────────────────────────────────

local function find_game(game_path, base_name)
    for _, g in ipairs(find_scumm_games(game_path)) do
        if g.base_name == base_name then return g end
    end
    return nil
end

-- Greyscale ramp used when a room carries no palette of its own
local function default_palette()
    local p = {}
    for i = 0, 255 do
        p[i * 3 + 1] = i; p[i * 3 + 2] = i; p[i * 3 + 3] = i
    end
    return p
end

-- Split "type:base:room[:obj:state]" into its fields. base_name never
-- contains a colon, so the trailing numeric fields are unambiguous.
local function parse_resource_id(resource_id)
    local parts = {}
    for part in resource_id:gmatch("[^:]+") do parts[#parts + 1] = part end
    local id = {
        res_type = parts[1],
        base_name = parts[2],
        room_id = tonumber(parts[3]),
        obj_id = tonumber(parts[4]),
        state = tonumber(parts[5])
    }
    if not id.res_type or not id.base_name or not id.room_id then
        return nil
    end
    if id.res_type == "obj" and (not id.obj_id or not id.state) then
        log_warn(string.format(
            "Malformed object id %q — expected obj:%s:<room>:<object>:<state>",
            resource_id, id.base_name))
        return nil
    end
    return id
end

-- Resolve the palette to colour an image with. A palette_id of the form
-- "pal:<base>:<room>" overrides the room's own palette.
local function resolve_palette(game, room_id, room_info, palette_id)
    if palette_id and palette_id ~= "" then
        local pal = parse_resource_id(palette_id)
        if pal and pal.res_type == "pal" and pal.room_id ~= room_id then
            local data = read_room(game, pal.room_id)
            if data then
                local other = parse_room(data, 0, #data)
                if other and other.palette then return other.palette end
            end
        end
    end
    return room_info.palette or default_palette()
end

-- Where a room's bytes are expected to live, for diagnostics.
local function room_location(game, room_id, room_entry)
    if room_entry and room_entry.offset then
        local file = room_entry.file or 0
        local path = game.data_files[file]
        if not path then
            return string.format("%s.%03d (data part) is missing",
                                 game.base_name, file)
        end
        return string.format("%s at offset %d of %s (room block not found there)",
                             room_id, room_entry.offset,
                             path:match("([^/]+)$") or path)
    end

    local dir = game.dir
    if game.room_dir and game.room_dir ~= "" then
        dir = dir .. "/" .. game.room_dir
    end
    return string.format("%02d.LFL", room_id) ..
        ((game.room_dir and game.room_dir ~= "") and (" in " .. game.room_dir .. "/")
         or "") .. " is missing"
end

-- ── Costume / sound loading ─────────────────────────────────────

local function load_costume_resource(game_path, resource_id, palette_id)
    local kind, base, cid, extra = resource_id:match("^(%a+):([^:]+):(%d+):?(%d*)$")
    local game = find_game(game_path, base)
    if not game then return nil end
    local state = get_game_state(game)
    cid = tonumber(cid)
    local res = valid_resource(state, state.index.costumes, cid)
    if not res then return nil end

    local block = read_res_block(game, state, res)
    local cost = block and Cost.parse(block, state.index.version)
    if not cost then
        return { type = "text", text = "Costume " .. cid .. " could not be parsed" }
    end

    -- Sprites use the palette of the room that stores them unless the user picked one
    local palette = default_palette()
    local room_data = read_room(game, res.room)
    local room_info = room_data and parse_room(room_data, 0, #room_data)
    if room_info then palette = resolve_palette(game, res.room, room_info, palette_id) end

    if kind == "cossheet" then
        local img, w, h, shown, total = cost:render_sheet(palette)
        if not img then return { type = "text", text = "Costume " .. cid .. " has no decodable cels" } end
        local more = (shown and total and shown < total)
            and string.format(" (first %d of %d)", shown, total) or ""
        return { type = "image", image = img, width = w, height = h,
                 description = string.format("Costume %d (room %d) — all cels%s, %dx%d",
                     cid, res.room, more, w, h) }
    end

    local anim = tonumber(extra)
    local handle, nframes, w, h, animated = cost:render_animation(anim, palette)
    if not handle then
        return { type = "text", text = string.format("Costume %d animation %d has nothing to draw", cid, anim) }
    end
    local desc = string.format("Costume %d, %s %d — %d frame(s), %dx%d (room %d palette)",
        cid, cost.kind == "akos" and "chore" or "animation", anim, nframes, w, h, res.room)
    if animated then
        return { type = "animation", animation = handle, delay_ms = 110, description = desc }
    end
    return { type = "image", image = handle, width = w, height = h, description = desc }
end

local function load_sound_resource(game_path, resource_id)
    local base, sid, tag = resource_id:match("^snd:([^:]+):(%d+):(.+)$")
    local game = find_game(game_path, base)
    if not game then return nil end
    local state = get_game_state(game)
    sid = tonumber(sid)
    local res = valid_resource(state, state.index.sounds, sid)
    if not res then return nil end
    local block = read_res_block(game, state, res, "SOUN")
    local info = block and Sound.parse_soun(block)
    if not info then return { type = "text", text = "Sound " .. sid .. " could not be read" } end
    local out = Sound.load_chunk(info, tag_from_id(tag), string.format("Sound %d (room %d)", sid, res.room))
    return out or { type = "text", text = "Sound " .. sid .. " has no " .. tag_from_id(tag) .. " data" }
end

local function load_bundle_resource(game_path, resource_id)
    local name, index = resource_id:match("^bun:(.+):(%d+)$")
    for _, path in ipairs(find_bundle_paths(game_path)) do
        if path:match("([^/\\]+)$") == name then
            local bundle = get_bundle(path)
            if bundle then return Sound.load_bundle_entry(bundle, tonumber(index)) end
        end
    end
    return nil
end

-- Sprites (costumes, object images) are shown with the palette of the room that
-- stores them. The app asks for this when a node has no palette sibling.
function engine.default_palette(game_path, resource_id)
    local prefix, base, num = resource_id:match("^(%a+):([^:]+):(%d+)")
    if not base then return nil end
    local game = find_game(game_path, base)
    if not game then return nil end
    local state = get_game_state(game)
    num = tonumber(num)
    if prefix == "cossheet" or prefix == "cosanim" then
        local res = valid_resource(state, state.index.costumes, num)
        if res then return string.format("pal:%s:%d", base, res.room) end
    elseif prefix == "obj" then
        return string.format("pal:%s:%d", base, num)   -- object ids start with the room number
    end
    return nil
end

function engine.load_resource(game_path, resource_id, palette_id)
    local prefix = resource_id:match("^(%a+):")
    if prefix == "cossheet" or prefix == "cosanim" then
        return load_costume_resource(game_path, resource_id, palette_id)
    elseif prefix == "snd" then
        return load_sound_resource(game_path, resource_id)
    elseif prefix == "bun" then
        return load_bundle_resource(game_path, resource_id)
    elseif prefix == "nut" then
        local name = resource_id:match("^nut:(.+)$")
        for _, path in ipairs(find_files_with_ext(game_path, "NUT")) do
            if path:match("([^/\\\\]+)$") == name then
                local data = read_whole_file(path)
                local font = data and Nut.parse(data)
                if not font then return { type = "text", text = name .. ": not a NUT font" } end
                local img, w, h = Nut.render(font)
                if not img then return { type = "text", text = name .. ": no glyphs" } end
                return { type = "image", image = img, width = w, height = h,
                         description = string.format("%s — %d glyphs", name, #font.glyphs) }
            end
        end
        return nil
    elseif prefix == "sou" then
        local name, index = resource_id:match("^sou:(.+):(%d+)$")
        for _, path in ipairs(find_sou_paths(game_path)) do
            if path:match("([^/\\\\]+)$") == name then
                local sou = get_sou(path)
                if sou then return Sound.load_sou_clip(sou, tonumber(index)) end
            end
        end
        return nil
    end

    local id = parse_resource_id(resource_id)
    if not id then
        log_warn("Unknown resource ID: " .. resource_id)
        return nil
    end

    local game = find_game(game_path, id.base_name)
    if not game then
        log_error("Game not found: " .. id.base_name)
        return nil
    end

    local state = get_game_state(game)
    local room_entry = find_room_entry(state.rooms, id.room_id)
    if not room_entry then
        log_warn(string.format("Room %d not present in %s", id.room_id, id.base_name))
        return nil
    end

    local room_data = read_room(game, id.room_id)
    if not room_data then
        log_warn(string.format("Room %d data unavailable in %s: %s",
            id.room_id, id.base_name, room_location(game, id.room_id, room_entry)))
        return nil
    end

    local room_info = parse_room(room_data, 0, #room_data)
    if not room_info then
        log_warn("Failed to parse room " .. id.room_id)
        return nil
    end

    local room_name = (state.index.room_names and state.index.room_names[id.room_id]) or ""

    -- ── Palette swatch ───────────────────────────────────────────
    if id.res_type == "pal" then
        if room_info.palette then
            return {
                type = "image",
                image = build_palette_swatch(room_info.palette),
                description = string.format(
                    "Room %d palette — %d colour(s)", id.room_id,
                    #(room_info.palettes or { room_info.palette }))
            }
        end
        return { type = "text",
                 text = "No CLUT/PALS palette found in room " .. id.room_id }
    end

    -- ── Object sprite ────────────────────────────────────────────
    if id.res_type == "obj" then
        local palette = resolve_palette(game, id.room_id, room_info, palette_id)
        for _, obj in ipairs(room_info.objects or {}) do
            if obj.obj_id == id.obj_id then
                for _, img in ipairs(obj.images) do
                    if img.state == id.state then
                        local pixels, w, h = decode_smap(room_data, img.smap_offset,
                            img.smap_size, img.width, img.height, nil,
                            room_info.transparent_color or 0)
                        if not pixels then
                            return { type = "text", text = string.format(
                                "Failed to decode object %d state %d", id.obj_id, id.state) }
                        end
                        return {
                            type = "image",
                            image = image_create_indexed(w, h, pixels, palette),
                            width = w,
                            height = h,
                            description = string.format(
                                "Room %d object %d, state %d — %dx%d%s",
                                id.room_id, id.obj_id, img.state, w, h,
                                room_name ~= "" and (" (" .. room_name .. ")") or "")
                        }
                    end
                end
            end
        end
        log_warn(string.format("Object %d state %d not found in room %d",
            id.obj_id, id.state, id.room_id))
        return nil
    end

    -- ── Room background ──────────────────────────────────────────
    if id.res_type == "bg" then
        if not room_info.smap_offset then
            return { type = "text", text = string.format(
                "Room %d: %dx%d\nNo SMAP background data found",
                id.room_id, room_info.width or 0, room_info.height or 0) }
        end

        local pixels, width, height = decode_room_background(room_data, room_info)
        if not pixels then
            return { type = "text", text = string.format(
                "Room %d: %dx%d\nFailed to decode SMAP background",
                id.room_id, room_info.width or 0, room_info.height or 0) }
        end

        local palette = resolve_palette(game, id.room_id, room_info, palette_id)
        return {
            type = "image",
            image = image_create_indexed(width, height, pixels, palette),
            width = width,
            height = height,
            description = string.format(
                "Room %d%s — %dx%d, 256 colours%s", id.room_id,
                room_name ~= "" and (" (" .. room_name .. ")") or "",
                width, height,
                room_info.version
                    and (", SCUMM V" .. tostring(math.floor(room_info.version / 100)))
                     or ", SCUMM")
        }
    end

    return nil
end

return engine

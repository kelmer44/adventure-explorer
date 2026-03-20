-- ============================================================================
-- Adventure Explorer - Engine Script: Broken Sword 1 (Shadow of the Templars)
-- ============================================================================
--
-- RESOURCE SYSTEM OVERVIEW
-- ========================
--
-- Index file: swordres.rif (Resource Index File)
-- Data files: *.CLU (Cluster files, PC) or *.CLM (Mac, big-endian)
--
-- swordres.rif byte layout:
--   Offset 0x00: uint32_le  noClu       -- number of clusters
--   Offset 0x04: uint32_le[noClu]       -- cluster index (0 = absent, non-zero = present)
--   Then for each present cluster:
--     32 bytes: label (null-terminated ASCII, e.g. "paris1", "general")
--     uint32_le: noGrp                  -- number of groups in this cluster
--     uint32_le[noGrp]: group index     -- (0 = absent)
--     For each present group:
--       uint32_le: noRes                -- number of resources in this group
--       uint32_le[noRes]: res index     -- (0 = absent)
--       For each present resource:
--         uint32_le: offset             -- byte offset within the CLU file
--         uint32_le: length             -- byte length of resource data
--
-- CLU filename = label .. ".CLU"  (PC) or label .. ".CLM" (Mac)
--
-- Known CLU files and their cluster numbers (1-based):
--   Cluster 1: compacts.clu    (game object compacts)
--   Cluster 2: scripts.clu     (game scripts)
--   Cluster 3: general.clu     (fonts, cursors, menus, shared sprites)
--   Cluster 4: text.clu        (dialogue text per language)
--   Cluster 5: maps.clu        (walkgrid/routing data)
--   Cluster 6: paris1.clu      (rooms 1-8: Paris cafe, streets, sewers)
--   Cluster 7: paris2.clu      (rooms 9-17: Paris museum, hotel, etc.)
--   Cluster 8: ireland.clu     (rooms 18-26)
--   Cluster 9: paris3.clu      (rooms 27-31)
--   Cluster 10: paris4.clu     (rooms 32-38)
--   Cluster 11: scotland.clu   (rooms 39-44)
--   Cluster 12: spain.clu      (rooms 45-54)
--   Cluster 13: syria.clu      (rooms 55-70)
--   Cluster 14: train.clu      (rooms 71+)
--
-- RESOURCE ID FORMAT (32-bit):
--   Bits 31-24: cluster number (1-based)
--   Bits 23-16: group number within cluster
--   Bits 15-0:  resource index within group
--   Example: 0x06010002 → cluster 6 (paris1.clu), group 1, resource 2
--
-- RESOURCE HEADER (20 bytes) - present on sprites, scripts, foreground layers:
--   struct Header {
--     char   type[6];          // +0x00  resource type identifier
--     uint16 version;          // +0x06  version number
--     uint32 comp_length;      // +0x08  compressed length
--     char   compression[4];   // +0x0C  compression type string
--     uint32 decomp_length;    // +0x10  decompressed length
--   };  // Total: 20 bytes, packed
--
-- BACKGROUND LAYER 0: NO Header. Raw pixel data, width*height bytes, 8bpp indexed.
-- PALETTE RESOURCES: NO Header. Raw RGB triplets, 6-bit VGA (0-63 per channel).
--   Background palette: 184 colors (552 bytes) at palettes[0]
--   Sprite palette: 72 colors (216 bytes) at palettes[1]
--   Combined: 256 colors total. Multiply each component by 4 for 8-bit RGB.
-- FOREGROUND LAYERS 1+: HAVE the 20-byte Header. Skip it to get pixel data.
--
-- Screen: 640x400 base, some rooms wider (e.g. 784, 976) for scrolling.
--
-- ROOM TABLE (first 10 rooms):
--   Room  1: 784x400  bg=0x06010002  bgPal=0x06010001  sprPal=0x06010000 (paris1.clu)
--   Room  2: 640x400  bg=0x06020001  bgPal=0x06020000  sprPal=0x06010000 (paris1.clu)
--   Room  3: 640x400  bg=0x06030001  bgPal=0x06030000  sprPal=0x06010000 (paris1.clu)
--   Room  4: 640x400  bg=0x06040001  bgPal=0x06040000  sprPal=0x06010000 (paris1.clu)
--   Room  5: 640x400  bg=0x06050001  bgPal=0x06050000  sprPal=0x06010000 (paris1.clu)
--   Room  6: 640x400  bg=0x06060002  bgPal=0x06060001  sprPal=0x06060000 (paris1.clu)
--   Room  7: 640x400  bg=0x06070001  bgPal=0x06070000  sprPal=0x06060000 (paris1.clu)
--   Room  8: 784x400  bg=0x06080001  bgPal=0x06080000  sprPal=0x06010000 (paris1.clu)
--   Room  9: 640x400  bg=0x07010002  bgPal=0x07010001  sprPal=0x07010000 (paris2.clu)
--   Room 10: 640x400  bg=0x07020002  bgPal=0x07020001  sprPal=0x07020000 (paris2.clu)
-- ============================================================================

local engine = {}
engine.name        = "Broken Sword: Shadow of the Templars"
engine.id          = "sword1"
engine.description = "Broken Sword: The Shadow of the Templars (1996, Revolution Software)"
engine.version     = "1.0"

-- ── Binary helpers ───────────────────────────────────────────────

local function u8(data, pos)   return data:byte(pos) end

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function i16le(data, pos)
    local v = data:byte(pos) + data:byte(pos + 1) * 256
    if v >= 32768 then v = v - 65536 end
    return v
end

local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end

-- ── Sprite decompression ─────────────────────────────────────────

-- "NONE": raw uncompressed pixels (compSize == w*h)
local function decompress_none(data, src, comp_size, w, h)
    local pixels = {}
    local n = w * h
    for i = 1, n do
        if src + i - 1 <= #data then
            pixels[i] = data:byte(src + i - 1)
        else
            pixels[i] = 0
        end
    end
    return pixels
end

-- "JIM " / Tony compression: alternating flat-run + literal-run
local function decompress_tony(data, src, comp_size, w, h)
    local pixels = {}
    local n = w * h
    for i = 1, n do pixels[i] = 0 end
    local sp = src
    local dp = 1
    local src_end = src + comp_size
    while sp < src_end and dp <= n do
        local num_flat = data:byte(sp); sp = sp + 1
        if num_flat > 0 then
            local flat_val = data:byte(sp); sp = sp + 1
            for i = 0, num_flat - 1 do
                if dp + i <= n then pixels[dp + i] = flat_val end
            end
            dp = dp + num_flat
        end
        if sp < src_end and dp <= n then
            local num_lit = data:byte(sp); sp = sp + 1
            for i = 0, num_lit - 1 do
                if dp + i <= n and sp <= #data then
                    pixels[dp + i] = data:byte(sp)
                end
                sp = sp + 1
            end
            dp = dp + num_lit
        end
    end
    return pixels
end

-- "RLE0": Run-length with transparent (0) runs
local function decompress_rle0(data, src, comp_size, w, h)
    local pixels = {}
    local n = w * h
    for i = 1, n do pixels[i] = 0 end
    local sp = src
    local dp = 1
    local src_end = src + comp_size
    while sp < src_end and dp <= n do
        local color = data:byte(sp); sp = sp + 1
        if color ~= 0 then
            pixels[dp] = color; dp = dp + 1
        else
            if sp >= src_end then break end
            local skip = data:byte(sp); sp = sp + 1
            dp = dp + skip  -- leave as 0 (transparent)
        end
    end
    return pixels
end

-- "RLE7": Run-length variant
local function decompress_rle7(data, src, comp_size, w, h)
    local pixels = {}
    local n = w * h
    for i = 1, n do pixels[i] = 0 end
    local sp = src
    local dp = 1
    local src_end = src + comp_size
    while sp < src_end and dp <= n do
        local code = data:byte(sp); sp = sp + 1
        if code > 127 or code == 0 then
            -- literal pixel
            if dp <= n then pixels[dp] = code end
            dp = dp + 1
        else
            -- repeat next byte (code+1) times
            local val = 0
            if sp <= #data then val = data:byte(sp); sp = sp + 1 end
            for i = 0, code do
                if dp + i <= n then pixels[dp + i] = val end
            end
            dp = dp + code + 1
        end
    end
    return pixels
end

-- Decompress sprite frame pixel data based on tag
local function decompress_frame(data, src, comp_size, w, h, tag)
    if tag == "RLE0" then
        return decompress_rle0(data, src, comp_size, w, h)
    elseif tag == "RLE7" then
        return decompress_rle7(data, src, comp_size, w, h)
    elseif tag == "NONE" then
        return decompress_none(data, src, comp_size, w, h)
    else
        -- "JIM " and any unknown tags use Tony compression
        return decompress_tony(data, src, comp_size, w, h)
    end
end

-- ── Hardcoded room definition table ──────────────────────────────
-- From ScummVM staticres.cpp _roomDefTable.
-- Each entry: { totalLayers, sizeX, sizeY, gridWidth, layers[4], grids[3], palettes[2], parallax[2] }
-- We only need: sizeX, sizeY, layers[0] (bg resource ID), palettes[0] (bg palette), palettes[1] (sprite pal)

local ROOM_DEFS = {
    -- PARIS 1 (cluster 6 = paris1.clu)
    [1]  = { w=784,  h=400,  bg=0x06010002, bgPal=0x06010001, sprPal=0x06010000 },
    [2]  = { w=640,  h=400,  bg=0x06020001, bgPal=0x06020000, sprPal=0x06010000 },
    [3]  = { w=640,  h=400,  bg=0x06030001, bgPal=0x06030000, sprPal=0x06010000 },
    [4]  = { w=640,  h=400,  bg=0x06040001, bgPal=0x06040000, sprPal=0x06010000 },
    [5]  = { w=640,  h=400,  bg=0x06050001, bgPal=0x06050000, sprPal=0x06010000 },
    [6]  = { w=640,  h=400,  bg=0x06060002, bgPal=0x06060001, sprPal=0x06060000 },
    [7]  = { w=640,  h=400,  bg=0x06070001, bgPal=0x06070000, sprPal=0x06060000 },
    [8]  = { w=784,  h=400,  bg=0x06080001, bgPal=0x06080000, sprPal=0x06010000 },
    -- PARIS 2 (cluster 7 = paris2.clu)
    [9]  = { w=640,  h=400,  bg=0x07010002, bgPal=0x07010001, sprPal=0x07010000 },
    [10] = { w=640,  h=400,  bg=0x07020002, bgPal=0x07020001, sprPal=0x07020000 },
    [11] = { w=640,  h=400,  bg=0x07030001, bgPal=0x07030000, sprPal=0x07010000 },
    [12] = { w=640,  h=400,  bg=0x07040001, bgPal=0x07040000, sprPal=0x07010000 },
    [13] = { w=976,  h=400,  bg=0x07050002, bgPal=0x07050001, sprPal=0x07050000 },
    [14] = { w=640,  h=400,  bg=0x07060001, bgPal=0x07060000, sprPal=0x07010000 },
    [15] = { w=640,  h=400,  bg=0x07070001, bgPal=0x07070000, sprPal=0x07010000 },
    [16] = { w=640,  h=400,  bg=0x07080001, bgPal=0x07080000, sprPal=0x07010000 },
    [17] = { w=640,  h=400,  bg=0x07090001, bgPal=0x07090000, sprPal=0x07010000 },
    [18] = { w=640,  h=400,  bg=0x070A0002, bgPal=0x070A0001, sprPal=0x070A0000 },
    [46] = { w=640,  h=400,  bg=0x070B0001, bgPal=0x070B0000, sprPal=0x07010000 },
    -- IRELAND (cluster 8 = ireland.clu / paris3.clu)
    [27] = { w=640,  h=400,  bg=0x08040002, bgPal=0x08040001, sprPal=0x05000003 },
    [28] = { w=640,  h=400,  bg=0x08050002, bgPal=0x08050001, sprPal=0x08050000 },
    [29] = { w=640,  h=400,  bg=0x08060003, bgPal=0x08060002, sprPal=0x08060000 },
    [30] = { w=640,  h=400,  bg=0x080A0040, bgPal=0x080A0041, sprPal=0x08040000 },
    [31] = { w=640,  h=400,  bg=0x08070001, bgPal=0x08070000, sprPal=0x08040000 },
    [32] = { w=640,  h=400,  bg=0x08080001, bgPal=0x08080000, sprPal=0x08040000 },
    [33] = { w=640,  h=400,  bg=0x08090001, bgPal=0x08090000, sprPal=0x08040000 },
    [34] = { w=1120, h=400,  bg=0x080A0001, bgPal=0x080A0000, sprPal=0x08040000 },
    [35] = { w=640,  h=400,  bg=0x080B0001, bgPal=0x080B0000, sprPal=0x08040000 },
    -- PARIS 4 (cluster 9 = paris4.clu)
    [36] = { w=960,  h=400,  bg=0x09010001, bgPal=0x09010004, sprPal=0x09010000 },
    [37] = { w=640,  h=400,  bg=0x09020001, bgPal=0x09020000, sprPal=0x05000003 },
    [38] = { w=640,  h=400,  bg=0x09030002, bgPal=0x09030001, sprPal=0x09030000 },
    [39] = { w=640,  h=400,  bg=0x09040001, bgPal=0x09040004, sprPal=0x09040000 },
    [40] = { w=640,  h=400,  bg=0x09050000, bgPal=0x09050001, sprPal=0x05000003 },
    [41] = { w=640,  h=400,  bg=0x09060000, bgPal=0x09060003, sprPal=0x05000003 },
    [42] = { w=640,  h=400,  bg=0x09070001, bgPal=0x09070000, sprPal=0x05000003 },
    [43] = { w=640,  h=400,  bg=0x09080001, bgPal=0x09080000, sprPal=0x05000003 },
    [48] = { w=1184, h=400,  bg=0x09090001, bgPal=0x09090006, sprPal=0x09090000 },
    -- SCOTLAND (cluster 10 = scotland.clu)
    [19] = { w=848,  h=864,  bg=0x0A010001, bgPal=0x0A010006, sprPal=0x0A010000 },
    [20] = { w=640,  h=400,  bg=0x0A020001, bgPal=0x0A020008, sprPal=0x0A020000 },
    [21] = { w=640,  h=400,  bg=0x0A030000, bgPal=0x0A030005, sprPal=0x05000003 },
    [22] = { w=784,  h=400,  bg=0x0A040001, bgPal=0x0A040004, sprPal=0x0A040000 },
    [23] = { w=640,  h=400,  bg=0x0A050000, bgPal=0x0A050001, sprPal=0x05000003 },
    [24] = { w=880,  h=400,  bg=0x0A060000, bgPal=0x0A060004, sprPal=0x05000003 },
    [25] = { w=640,  h=400,  bg=0x0A070001, bgPal=0x0A070004, sprPal=0x0A070000 },
    [26] = { w=640,  h=400,  bg=0x0A080001, bgPal=0x0A080006, sprPal=0x0A080000 },
    -- SPAIN (cluster 11 = spain.clu)
    [56] = { w=640,  h=400,  bg=0x0B010001, bgPal=0x0B010006, sprPal=0x0B010000 },
    [57] = { w=1760, h=400,  bg=0x0B020000, bgPal=0x0B020003, sprPal=0x0B010000 },
    [58] = { w=864,  h=400,  bg=0x0B030000, bgPal=0x0B030003, sprPal=0x0B010000 },
    [59] = { w=640,  h=400,  bg=0x0B040000, bgPal=0x0B040005, sprPal=0x0B010000 },
    [60] = { w=640,  h=400,  bg=0x0B050000, bgPal=0x0B050005, sprPal=0x0B010000 },
    [61] = { w=640,  h=400,  bg=0x0B060000, bgPal=0x0B060003, sprPal=0x0B010000 },
    [62] = { w=640,  h=400,  bg=0x0B070000, bgPal=0x0B070001, sprPal=0x05000003 },
    -- SYRIA (cluster 12 = syria.clu)
    [45] = { w=1152, h=400,  bg=0x0C020002, bgPal=0x0C020005, sprPal=0x0C020001 },
    [47] = { w=640,  h=800,  bg=0x0C030000, bgPal=0x0C030005, sprPal=0x0C020000 },
    [49] = { w=640,  h=400,  bg=0x0C040000, bgPal=0x0C040005, sprPal=0x0C020000 },
    [50] = { w=640,  h=400,  bg=0x0C050000, bgPal=0x0C050007, sprPal=0x0C020000 },
    [53] = { w=880,  h=1736, bg=0x0C060000, bgPal=0x0C060001, sprPal=0x0C060004 },
    [54] = { w=896,  h=1112, bg=0x0C070000, bgPal=0x0C070003, sprPal=0x0C020000 },
    [55] = { w=1040, h=400,  bg=0x0C080001, bgPal=0x0C080002, sprPal=0x0C080000 },
    -- TRAIN (cluster 13 = train.clu)
    [63] = { w=2160, h=400,  bg=0x0D010001, bgPal=0x0D010004, sprPal=0x0D010000 },
    [65] = { w=640,  h=400,  bg=0x0D020000, bgPal=0x0D020003, sprPal=0x0D010000 },
    [66] = { w=640,  h=400,  bg=0x0D030000, bgPal=0x0D030001, sprPal=0x0D010000 },
    [67] = { w=640,  h=400,  bg=0x0D040000, bgPal=0x0D040003, sprPal=0x0D010000 },
    [69] = { w=640,  h=400,  bg=0x0D050001, bgPal=0x0D050004, sprPal=0x0D050000 },
    -- BULL RING (cluster 14 = ???)
    [71] = { w=1760, h=400,  bg=0x0E010000, bgPal=0x0E010003, sprPal=0x05000003 },
    [72] = { w=640,  h=400,  bg=0x0E020000, bgPal=0x0E020003, sprPal=0x05000003 },
    [73] = { w=640,  h=400,  bg=0x0E030001, bgPal=0x0E030006, sprPal=0x0E030000 },
    [74] = { w=1136, h=400,  bg=0x0E040001, bgPal=0x0E040004, sprPal=0x0E040000 },
    [75] = { w=640,  h=400,  bg=0x0E050000, bgPal=0x0E050001, sprPal=0x0E040000 },
    [76] = { w=640,  h=400,  bg=0x0E060000, bgPal=0x0E060001, sprPal=0x0E040000 },
    [77] = { w=640,  h=400,  bg=0x0E070000, bgPal=0x0E070001, sprPal=0x0E040000 },
    [78] = { w=640,  h=400,  bg=0x0E080000, bgPal=0x0E080001, sprPal=0x0E040000 },
    [79] = { w=640,  h=400,  bg=0x0E090000, bgPal=0x0E090001, sprPal=0x0E040000 },
    -- SPECIAL ROOMS (cluster 5 = maps.clu)
    [80] = { w=640,  h=400,  bg=0x05000001, bgPal=0x05000000, sprPal=0x05000003 },
    [81] = { w=640,  h=400,  bg=0x07090010, bgPal=0x0709000F, sprPal=0x05000003 },
    [82] = { w=640,  h=400,  bg=0x0C080007, bgPal=0x0C080008, sprPal=0x05000003 },
    [86] = { w=640,  h=400,  bg=0x05010001, bgPal=0x05010000, sprPal=0x05000003 },
    [87] = { w=640,  h=400,  bg=0x09090023, bgPal=0x09090024, sprPal=0x05000003 },
    [88] = { w=640,  h=400,  bg=0x09090025, bgPal=0x09090026, sprPal=0x05000003 },
    [90] = { w=640,  h=400,  bg=0x05020000, bgPal=0x05020001, sprPal=0x05020002 },
    [91] = { w=640,  h=400,  bg=0x05030000, bgPal=0x05030001, sprPal=0x05000003 },
    [92] = { w=640,  h=400,  bg=0x0709000B, bgPal=0x0709000C, sprPal=0x05000003 },
    [93] = { w=640,  h=400,  bg=0x07090007, bgPal=0x07090008, sprPal=0x05000003 },
    [94] = { w=640,  h=400,  bg=0x08060007, bgPal=0x08060008, sprPal=0x08060001 },
    [95] = { w=640,  h=400,  bg=0x09030006, bgPal=0x09030007, sprPal=0x05000003 },
    [96] = { w=640,  h=400,  bg=0x09070007, bgPal=0x09070008, sprPal=0x05000003 },
    [99] = { w=640,  h=400,  bg=0x05040001, bgPal=0x05040000, sprPal=0x05000003 },
}

local ROOM_NAMES = {
    [1]  = "Paris - Cafe (exterior)",
    [2]  = "Paris - Rue Jarry",
    [3]  = "Paris - Cafe (interior)",
    [4]  = "Paris - Back alley",
    [5]  = "Paris - Roadworks",
    [6]  = "Paris - Sewer entrance",
    [7]  = "Paris - Sewer",
    [8]  = "Paris - Cafe (exterior, after bomb)",
    [9]  = "Paris - Police station",
    [10] = "Paris - Museum lobby",
    [11] = "Paris - Museum corridor",
    [12] = "Paris - Museum upstairs",
    [13] = "Paris - Museum gallery",
    [14] = "Paris - Hotel lobby",
    [15] = "Paris - Hotel corridor",
    [16] = "Paris - Nico's apartment",
    [17] = "Paris - Nico's apartment (alt)",
}

-- ── swordres.rif parser ──────────────────────────────────────────
-- Returns: { clusters = { [cluIdx] = { label=str, groups = { [grpIdx] = { resources = { [resIdx] = {offset, length} } } } } } }

local function parse_rif(f)
    local rif = { clusters = {} }

    -- Read number of clusters
    local head = file_read(f, 0, 4)
    if not head or #head < 4 then return nil end
    local noClu = u32le(head, 1)

    -- Read cluster index array
    local clu_idx_data = file_read(f, 4, noClu * 4)
    if not clu_idx_data then return nil end

    local pos = 4 + noClu * 4  -- current read position in the file

    for ci = 0, noClu - 1 do
        local clu_present = u32le(clu_idx_data, ci * 4 + 1)
        if clu_present ~= 0 then
            -- Read 32-byte label
            local label_raw = file_read(f, pos, 32)
            pos = pos + 32
            local label = ""
            if label_raw then
                for i = 1, 31 do
                    local b = label_raw:byte(i)
                    if b == 0 then break end
                    label = label .. string.char(b)
                end
            end

            -- Number of groups
            local noGrp_data = file_read(f, pos, 4)
            pos = pos + 4
            local noGrp = u32le(noGrp_data, 1)

            -- Group index array
            local grp_idx_data = file_read(f, pos, noGrp * 4)
            pos = pos + noGrp * 4

            local groups = {}
            for gi = 0, noGrp - 1 do
                local grp_present = u32le(grp_idx_data, gi * 4 + 1)
                if grp_present ~= 0 then
                    -- Number of resources
                    local noRes_data = file_read(f, pos, 4)
                    pos = pos + 4
                    local noRes = u32le(noRes_data, 1)

                    -- Resource index array
                    local res_idx_data = file_read(f, pos, noRes * 4)
                    pos = pos + noRes * 4

                    local resources = {}
                    for ri = 0, noRes - 1 do
                        local res_present = u32le(res_idx_data, ri * 4 + 1)
                        if res_present ~= 0 then
                            local off_len = file_read(f, pos, 8)
                            pos = pos + 8
                            resources[ri] = {
                                offset = u32le(off_len, 1),
                                length = u32le(off_len, 5)
                            }
                        else
                            resources[ri] = nil
                        end
                    end

                    groups[gi] = { noRes = noRes, resources = resources }
                else
                    groups[gi] = nil
                end
            end

            rif.clusters[ci] = { label = label, noGrp = noGrp, groups = groups }
        end
    end

    rif.noClu = noClu
    return rif
end

-- ── Resolve a resource ID to (clu_label, offset, length) ──────────

local function resolve_resource(rif, res_id)
    local clu_idx = math.floor(res_id / 0x1000000) - 1   -- top byte, 1-based to 0-based
    local grp_idx = math.floor(res_id / 0x10000) % 256    -- second byte
    local res_idx = res_id % 0x10000                       -- bottom 16 bits

    local cluster = rif.clusters[clu_idx]
    if not cluster then return nil end

    local group = cluster.groups[grp_idx]
    if not group then return nil end

    local res = group.resources[res_idx]
    if not res then return nil end

    return cluster.label, res.offset, res.length
end

-- ── Read raw resource data from its CLU file ─────────────────────

local function read_resource(data_dir, rif, res_id)
    local label, offset, length = resolve_resource(rif, res_id)
    if not label then return nil end

    local clu_path = data_dir .. "/" .. label .. ".CLU"
    -- Try uppercase, then lowercase
    local clu = file_open(clu_path)
    if not clu then
        clu_path = data_dir .. "/" .. string.upper(label) .. ".CLU"
        clu = file_open(clu_path)
    end
    if not clu then
        clu_path = data_dir .. "/" .. string.lower(label) .. ".clu"
        clu = file_open(clu_path)
    end
    if not clu then return nil end

    local data = file_read(clu, offset, length)
    file_close(clu)
    return data
end

-- ── Build full 256-color palette from bg + sprite palette resources ──

local function build_palette(data_dir, rif, bg_pal_id, spr_pal_id)
    local palette = {}
    -- Initialize to black
    for i = 1, 768 do palette[i] = 0 end

    -- Background palette: colors 0-183 (184 colors x 3 = 552 bytes)
    local bg_pal_data = read_resource(data_dir, rif, bg_pal_id)
    if bg_pal_data then
        local count = math.min(184, math.floor(#bg_pal_data / 3))
        for i = 0, count - 1 do
            -- 6-bit VGA palette → shift left 2 for 8-bit
            palette[i * 3 + 1] = math.min(bg_pal_data:byte(i * 3 + 1) * 4, 255)
            palette[i * 3 + 2] = math.min(bg_pal_data:byte(i * 3 + 2) * 4, 255)
            palette[i * 3 + 3] = math.min(bg_pal_data:byte(i * 3 + 3) * 4, 255)
        end
    end

    -- Sprite palette: colors 184-255 (72 colors x 3 = 216 bytes)
    local spr_pal_data = read_resource(data_dir, rif, spr_pal_id)
    if spr_pal_data then
        local count = math.min(72, math.floor(#spr_pal_data / 3))
        for i = 0, count - 1 do
            local ci = 184 + i
            palette[ci * 3 + 1] = math.min(spr_pal_data:byte(i * 3 + 1) * 4, 255)
            palette[ci * 3 + 2] = math.min(spr_pal_data:byte(i * 3 + 2) * 4, 255)
            palette[ci * 3 + 3] = math.min(spr_pal_data:byte(i * 3 + 3) * 4, 255)
        end
    end

    -- Force color 0 to black (as ScummVM does)
    palette[1] = 0; palette[2] = 0; palette[3] = 0

    return palette
end

-- ── Detection ────────────────────────────────────────────────────

-- Find the data directory (files may be in root or clusters/ subfolder)
local function find_data_dir(game_path)
    if file_exists(game_path .. "/clusters/swordres.rif") then
        return game_path .. "/clusters"
    elseif file_exists(game_path .. "/CLUSTERS/SWORDRES.RIF") then
        return game_path .. "/CLUSTERS"
    elseif file_exists(game_path .. "/swordres.rif") then
        return game_path
    end
    return nil
end

function engine.detect(game_path)
    local data_dir = find_data_dir(game_path)
    if not data_dir then return false end
    return file_exists(data_dir .. "/paris1.clu")
        or file_exists(data_dir .. "/PARIS1.CLU")
        or file_exists(data_dir .. "/paris1.clm")
        or file_exists(data_dir .. "/general.clu")
        or file_exists(data_dir .. "/GENERAL.CLU")
end

-- ── Resource tree ────────────────────────────────────────────────

function engine.get_resources(game_path)
    local data_dir = find_data_dir(game_path)
    if not data_dir then return {} end
    local rif_file = file_open(data_dir .. "/swordres.rif")
    if not rif_file then return {} end
    local rif = parse_rif(rif_file)
    file_close(rif_file)
    if not rif then return {} end

    local resources = {}

    -- Build room nodes for all defined rooms
    local room_ids = {}
    for k, _ in pairs(ROOM_DEFS) do
        if k > 0 then room_ids[#room_ids + 1] = k end
    end
    table.sort(room_ids)

    -- Cache open CLU file handles to avoid re-opening per room
    local clu_cache = {}

    for _, room_num in ipairs(room_ids) do
        local def = ROOM_DEFS[room_num]
        if not def or def.bg == 0 then goto continue end

        -- Verify the background resource actually exists in the RIF
        local label, off, len = resolve_resource(rif, def.bg)
        if not label then goto continue end

        local room_label = ROOM_NAMES[room_num] or ("Room " .. room_num)
        local room_node = {
            id       = "room_" .. room_num,
            name     = string.format("Room %02d - %s", room_num, room_label),
            type     = "category",
            children = {}
        }

        -- Background
        room_node.children[#room_node.children + 1] = {
            id   = "bg_" .. room_num,
            name = string.format("Background (%dx%d)", def.w, def.h),
            type = "image"
        }

        -- Palette swatch
        room_node.children[#room_node.children + 1] = {
            id   = "pal_" .. room_num,
            name = "Palette",
            type = "palette"
        }

        -- Scan for sprite resources in this room's group
        local clu_idx = math.floor(def.bg / 0x1000000) - 1
        local grp_idx = math.floor(def.bg / 0x10000) % 256
        local cluster = rif.clusters[clu_idx]
        if cluster then
            local group = cluster.groups[grp_idx]
            if group then
                -- Open CLU file (cached)
                local clu_key = cluster.label
                if not clu_cache[clu_key] then
                    local clu_path = data_dir .. "/" .. cluster.label .. ".CLU"
                    local clu = file_open(clu_path)
                    if not clu then
                        clu_path = data_dir .. "/" .. string.upper(cluster.label) .. ".CLU"
                        clu = file_open(clu_path)
                    end
                    if not clu then
                        clu_path = data_dir .. "/" .. string.lower(cluster.label) .. ".clu"
                        clu = file_open(clu_path)
                    end
                    clu_cache[clu_key] = clu
                end
                local clu = clu_cache[clu_key]

                if clu then
                    -- Collect sprite resource indices
                    local sprite_indices = {}
                    for ri, res in pairs(group.resources) do
                        if res and res.length >= 24 then
                            local header = file_read(clu, res.offset, 6)
                            if header then
                                local ftype = ""
                                for i = 1, 6 do
                                    local b = header:byte(i)
                                    if b == 0 then break end
                                    ftype = ftype .. string.char(b)
                                end
                                if ftype == "Sprite" then
                                    sprite_indices[#sprite_indices + 1] = ri
                                end
                            end
                        end
                    end
                    table.sort(sprite_indices)

                    if #sprite_indices > 0 then
                        local sprites_node = {
                            id = "sprites_" .. room_num,
                            name = string.format("Sprites (%d)", #sprite_indices),
                            type = "category",
                            children = {}
                        }
                        for _, ri in ipairs(sprite_indices) do
                            local res = group.resources[ri]
                            -- Read nFrames from the resource
                            local nf_data = file_read(clu, res.offset + 20, 4)
                            local nf = 0
                            if nf_data and #nf_data >= 4 then
                                nf = u32le(nf_data, 1)
                            end
                            local entry_type = "image"
                            if nf > 1 then entry_type = "animation" end
                            sprites_node.children[#sprites_node.children + 1] = {
                                id = string.format("spr_%d_%d", room_num, ri),
                                name = string.format("Sprite %d (%d frame%s, %d bytes)",
                                    ri, nf, nf ~= 1 and "s" or "", res.length),
                                type = entry_type
                            }
                        end
                        room_node.children[#room_node.children + 1] = sprites_node
                    end
                end
            end
        end

        resources[#resources + 1] = room_node
        ::continue::
    end

    -- Close cached CLU files
    for _, clu in pairs(clu_cache) do
        file_close(clu)
    end

    return resources
end

-- ── Background loader ─────────────────────────────────────────────
-- Background layer 0: raw 8bpp indexed pixels, NO header, width*height bytes.

function load_background(game_path, room_num, pal_room_num)
    local def = ROOM_DEFS[room_num]
    if not def or def.bg == 0 then return nil end

    local data_dir = find_data_dir(game_path)
    if not data_dir then return nil end
    local rif_file = file_open(data_dir .. "/swordres.rif")
    if not rif_file then return nil end
    local rif = parse_rif(rif_file)
    file_close(rif_file)

    -- Read background pixel data (raw, no header)
    local bg_data = read_resource(data_dir, rif, def.bg)
    if not bg_data then return nil end

    local w, h = def.w, def.h
    local expected = w * h

    -- Convert to pixel array
    local pixels = {}
    local count = math.min(#bg_data, expected)
    for i = 1, count do
        pixels[i] = bg_data:byte(i)
    end
    -- Pad if short
    while #pixels < expected do
        pixels[#pixels + 1] = 0
    end

    -- Build combined 256-color palette (use override room if specified)
    local pal_def = ROOM_DEFS[pal_room_num or room_num] or def
    local palette = build_palette(data_dir, rif, pal_def.bgPal, pal_def.sprPal)

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image",
        image = img,
        description = string.format(
            "Room %d background - %dx%d, 256 colors\nBG resource: 0x%08X  Palette: 0x%08X + 0x%08X",
            room_num, w, h, def.bg, def.bgPal, def.sprPal
        )
    }
end

-- ── Palette swatch ────────────────────────────────────────────────

function load_palette_swatch(game_path, room_num)
    local def = ROOM_DEFS[room_num]
    if not def then return nil end

    local data_dir = find_data_dir(game_path)
    if not data_dir then return nil end
    local rif_file = file_open(data_dir .. "/swordres.rif")
    if not rif_file then return nil end
    local rif = parse_rif(rif_file)
    file_close(rif_file)

    local palette = build_palette(data_dir, rif, def.bgPal, def.sprPal)

    -- Render 16x16 grid of color cells
    local CELL, GRID = 16, 16
    local SIZE = CELL * GRID  -- 256 pixels

    local rgb = {}
    local n = 0
    for py = 0, SIZE - 1 do
        for px = 0, SIZE - 1 do
            local ci = math.floor(py / CELL) * GRID + math.floor(px / CELL)
            n = n + 1; rgb[n] = palette[ci * 3 + 1]
            n = n + 1; rgb[n] = palette[ci * 3 + 2]
            n = n + 1; rgb[n] = palette[ci * 3 + 3]
        end
    end

    local img = image_create_rgb(SIZE, SIZE, rgb)
    return {
        type = "image",
        image = img,
        description = string.format(
            "Room %d palette - 256 colors (6-bit VGA x 4)\nBG palette (0-183): 0x%08X\nSprite palette (184-255): 0x%08X",
            room_num, def.bgPal, def.sprPal
        )
    }
end

-- ── Sprite decoder ────────────────────────────────────────────────
-- Sprite resource format:
--   ResHeader (20 bytes): type[6] + version[2] + comp[4] + decompSize[4] + compSize[4]
--   u32le nFrames
--   u32le[nFrames] offset table (absolute offsets from resource start)
--   At each offset: 16-byte FrameHeader + compSize bytes pixel data
--     FrameHeader: tag[4] + compSize(u32) + width(u16) + height(u16) + offsetX(i16) + offsetY(i16)

local function decode_sprite(data, palette)
    if not data or #data < 24 then return nil end

    -- Check resource type
    local res_type = ""
    for i = 1, 6 do
        local b = data:byte(i)
        if b == 0 then break end
        res_type = res_type .. string.char(b)
    end
    if res_type ~= "Sprite" then return nil end

    -- Read frame count and offset table
    local n_frames = u32le(data, 21)  -- byte 20 (0-based), Lua 1-based = 21
    if n_frames < 1 or n_frames > 1000 then return nil end

    local table_end = 25 + n_frames * 4
    if table_end > #data then return nil end

    local offsets = {}
    for i = 0, n_frames - 1 do
        offsets[i + 1] = u32le(data, 25 + i * 4)
    end

    -- Decode each frame
    local frames = {}
    for fi = 1, n_frames do
        local foff = offsets[fi] + 1  -- convert to Lua 1-based
        if foff + 15 > #data then break end

        -- Read tag (4 bytes)
        local tag = ""
        for i = 0, 3 do
            local b = data:byte(foff + i)
            if b >= 32 and b < 127 then tag = tag .. string.char(b)
            else tag = tag .. "?" end
        end

        local comp_size = u32le(data, foff + 4)
        local fw = u16le(data, foff + 8)
        local fh = u16le(data, foff + 10)
        local ox = i16le(data, foff + 12)
        local oy = i16le(data, foff + 14)

        if fw == 0 or fh == 0 or comp_size == 0 then
            -- Empty frame, skip
        else
            local pixel_start = foff + 16
            local pixels = decompress_frame(data, pixel_start, comp_size, fw, fh, tag)
            if pixels then
                local img = image_create_indexed(fw, fh, pixels, palette)
                if img then
                    frames[#frames + 1] = {
                        image = img,
                        width = fw,
                        height = fh,
                        offsetX = ox,
                        offsetY = oy,
                        tag = tag,
                        comp_size = comp_size
                    }
                end
            end
        end
    end

    return frames, n_frames
end

-- ── Sprite resource loader ────────────────────────────────────────

local function load_sprite(game_path, room_num, res_idx)
    local def = ROOM_DEFS[room_num]
    if not def then return nil end

    local data_dir = find_data_dir(game_path)
    if not data_dir then return nil end
    local rif_file = file_open(data_dir .. "/swordres.rif")
    if not rif_file then return nil end
    local rif = parse_rif(rif_file)
    file_close(rif_file)

    -- Determine cluster and group from room's bg resource ID
    local clu_idx = math.floor(def.bg / 0x1000000)
    local grp_idx = math.floor(def.bg / 0x10000) % 256

    -- Build resource ID
    local res_id = clu_idx * 0x1000000 + grp_idx * 0x10000 + res_idx

    -- Read the raw resource data
    local data = read_resource(data_dir, rif, res_id)
    if not data then return nil end

    -- Build the room's palette
    local palette = build_palette(data_dir, rif, def.bgPal, def.sprPal)

    -- Decode
    local frames, n_frames = decode_sprite(data, palette)
    if not frames or #frames == 0 then return nil end

    -- Single frame → image, multiple frames → animation
    if #frames == 1 then
        local f = frames[1]
        return {
            type = "image",
            image = f.image,
            description = string.format(
                "Sprite (resource %d) - %dx%d, tag=%s\nOffset: (%d, %d), compressed: %d bytes",
                res_idx, f.width, f.height, f.tag, f.offsetX, f.offsetY, f.comp_size
            )
        }
    else
        local handles = {}
        for i = 1, #frames do handles[i] = frames[i].image end
        local anim = animation_create(handles, 100)
        local f = frames[1]
        return {
            type = "animation",
            image = f.image,
            frames = handles,
            animation = anim,
            description = string.format(
                "Sprite animation (resource %d) - %d frames, %dx%d, tag=%s\nOffset: (%d, %d)",
                res_idx, #frames, f.width, f.height, f.tag, f.offsetX, f.offsetY
            )
        }
    end
end

-- ── Resource dispatcher ──────────────────────────────────────────

function engine.load_resource(game_path, resource_id, palette_id)
    -- Handle sprite IDs: "spr_ROOM_RESINDEX"
    local spr_room, spr_ri = resource_id:match("^spr_(%d+)_(%d+)$")
    if spr_room then
        return load_sprite(game_path, tonumber(spr_room), tonumber(spr_ri))
    end

    local prefix, num_str = resource_id:match("^(%a+)_(%d+)$")
    local num = tonumber(num_str)
    if not prefix or not num then return nil end

    if prefix == "bg" then
        local pal_room = num
        if palette_id and palette_id ~= "" then
            local _, pnum_str = palette_id:match("^(%a+)_(%d+)$")
            if pnum_str then pal_room = tonumber(pnum_str) end
        end
        return load_background(game_path, num, pal_room)
    elseif prefix == "pal" then return load_palette_swatch(game_path, num)
    end
    return nil
end

return engine

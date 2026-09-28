-- ============================================================================
-- Adventure Explorer - Engine Script: Simon the Sorcerer 1 & 2 (AGOS)
-- ============================================================================
-- Adventure Soft, 1993 / 1995. AGOS engine.
--
-- Verified against ScummVM (engines/agos): zones.cpp (loadZone),
-- res.cpp (loadVGAVideoFile slot formula), vga.cpp (setImage / animate /
-- vc10_draw / drawImage_init / vc10_depackColumn / vc10_uncompressFlip),
-- vga_s1.cpp (vc22_setPalette), vga.h (header structs) and debug.cpp
-- (dumpBitmap - the reference decoder used by ScummVM's -d agos-dump-bitmaps).
--
-- ── GME archive ────────────────────────────────────────────────────────────
-- u32le table size, then that many u32le offsets. Slot i is
-- [offsets[i], offsets[i+1]). vgaFile1 = slot zone*2, vgaFile2 = slot zone*2+1
-- (id = id*2 + (type-1) in res.cpp loadVGAVideoFile).
--
-- ── vgaFile1 ───────────────────────────────────────────────────────────────
-- All big-endian. A u16 at offset 4 points to VgaFile1Header_Common:
--   [+0] x_1  [+2] imageCount  [+4] x_2  [+6] animationCount
--   [+8] x_3  [+10] imageTable [+12] x_4 [+14] animationTable [+16] x_5
-- ImageHeader_Simon  (8 bytes): id, color, x_2, scriptOffs
-- AnimationHeader_Simon (6 bytes): id, x_2, scriptOffs
-- Palette blocks: 96 bytes each at offset 6 + block*96, 32 RGB triples,
-- 6-bit VGA scaled to 8-bit by *4.
--
-- ── vgaFile2 image table ───────────────────────────────────────────────────
-- 8-byte entries, image N at N*8 (entry 0 is a sentinel):
--   [+0..+3] u32be data offset   [+4] u8 flags
--   [+5] u8 height               [+6..+7] u16be width (PIXELS)
-- The table is self-terminating: it ends where image 2's data offset begins.
-- Each entry's byte span runs to the next entry's offset, which identifies
-- the encoding exactly (this is what makes decoding unambiguous):
--   width > 320            -> column table: (w/8) BE u32 relative offsets,
--                             then per 8-column group an RLE column block
--   span == w/8*5*h        -> 5bpp, uncompressed, 8 pixels per 5 bytes
--   span == w/2*h          -> 4bpp, uncompressed, 2 pixels per byte
--   otherwise              -> 4bpp RLE, w/2 RLE columns of h bytes,
--                             2 pixels per byte (vc10_depackColumn)
--
-- ── Palettes ───────────────────────────────────────────────────────────────
-- vc22_setPalette(a, b) loads block b into display bank a: 32 colours when
-- a == 0, otherwise 16, at display entries a*16.. . vc10_draw's palette
-- argument is the bank, and pixels are emitted as (nibble | bank*16).
-- Backgrounds are 5bpp so they use bank 0 (32 colours) directly.
-- ============================================================================

local engine = {}

-- ============================================================================
-- Binary helpers (1-based Lua string positions)
-- ============================================================================

local function u8(data, pos)
    return data:byte(pos) or 0
end

local function u16be(data, pos)
    local a, b = data:byte(pos, pos + 1)
    if not a then return 0 end
    return a * 256 + b
end

local function s16be(data, pos)
    local v = u16be(data, pos)
    return v >= 32768 and v - 65536 or v
end

local function u32be(data, pos)
    local a, b, c, d = data:byte(pos, pos + 3)
    if not a then return 0 end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function u32le(data, pos)
    local a, b, c, d = data:byte(pos, pos + 3)
    if not a then return 0 end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- ============================================================================
-- GME archive parser
-- The offset table is little-endian and its last entry is not always the file
-- size (Simon 2 has a stray trailing value), so keep the monotonic prefix.
-- ============================================================================

local function parse_gme(f)
    local fsize = file_size(f)
    if fsize < 8 then return nil end

    local table_size = u32le(file_read(f, 0, 4) or "", 1)
    if table_size < 8 or table_size > fsize then return nil end
    table_size = table_size - (table_size % 4)

    local raw = file_read(f, 0, table_size)
    if not raw or #raw < table_size then return nil end

    local offsets, n = {}, 0
    for i = 0, table_size / 4 - 1 do
        local off = u32le(raw, i * 4 + 1)
        if i > 0 and off < offsets[i - 1] then break end
        offsets[i] = off
        n = i + 1
    end
    if n < 2 then return nil end
    return offsets, n - 1                     -- n-1 slots
end

-- Read GME slot `slot`; returns nil when empty.
local function read_slot(f, offsets, nslots, slot)
    if slot < 0 or slot >= nslots then return nil end
    local off  = offsets[slot]
    local last = offsets[slot + 1] or file_size(f)
    if off == nil or last <= off then return nil end
    if last - off > 100 * 1024 * 1024 then return nil end
    return file_read(f, off, last - off)
end

-- Same, but resolving the archive by path (used by the cached GME reader).
local function read_slot_file(path, offsets, nslots, slot)
    if slot < 0 or slot >= nslots then return nil end
    local off = offsets[slot]
    if off == nil then return nil end
    local last = offsets[slot + 1]
    local f = file_open(path)
    if not f then return nil end
    local data
    if last == nil then
        local size = file_size(f)
        if size and size > off then data = file_read(f, off, size - off) end
    elseif last > off and last - off <= 100 * 1024 * 1024 then
        data = file_read(f, off, last - off)
    end
    file_close(f)
    return data
end

-- ============================================================================
-- vgaFile1 header
-- ============================================================================

local function parse_vga1_header(f1)
    if not f1 or #f1 < 24 then return nil end
    local hb = u16be(f1, 5)                   -- u16 at 0-based offset 4
    if hb == 0 or hb + 18 > #f1 then return nil end

    local h = {
        imageCount   = u16be(f1, hb + 3),
        animCount    = u16be(f1, hb + 7),
        imageTable   = u16be(f1, hb + 11),
        animTable    = u16be(f1, hb + 15),
    }
    -- Some GME slots are not VGA files at all (other resource blocks share the
    -- archive), so only trust a table that actually fits inside vgaFile1.
    h.images_ok = (h.imageTable >= hb + 18)
        and (h.imageTable + h.imageCount * 8 <= #f1)
    h.anims_ok  = (h.animTable >= hb + 18)
        and (h.animTable + h.animCount * 6 <= #f1)
    if not h.images_ok and not h.anims_ok then return nil end
    return h
end

-- ImageHeader_Simon: id, color, x_2, scriptOffs (8 bytes each)
local function parse_vga1_images(f1, hdr)
    local out = {}
    if not hdr or not hdr.images_ok then return out end
    for i = 0, hdr.imageCount - 1 do
        local p = hdr.imageTable + i * 8 + 1
        if p + 7 > #f1 then break end
        out[#out + 1] = {
            index      = i + 1,
            id         = u16be(f1, p),
            color      = u16be(f1, p + 2),
            scriptOffs = u16be(f1, p + 6),
        }
    end
    return out
end

-- AnimationHeader_Simon: id, x_2, scriptOffs (6 bytes each)
local function parse_vga1_anims(f1, hdr)
    local out = {}
    if not hdr or not hdr.anims_ok then return out end
    for i = 0, hdr.animCount - 1 do
        local p = hdr.animTable + i * 6 + 1
        if p + 5 > #f1 then break end
        out[#out + 1] = {
            index      = i + 1,
            id         = u16be(f1, p),
            scriptOffs = u16be(f1, p + 4),
        }
    end
    return out
end

-- ============================================================================
-- vgaFile2 image table
-- ============================================================================

local function parse_img_table(f2)
    if not f2 or #f2 < 24 then return {} end

    -- ScummVM addresses this table directly as vgaFile2 + image * 8 (see
    -- draw.cpp's sprite source lookup), so it is not a record count and does
    -- not end at the first blank slot: a zone may simply leave an image id
    -- unused. Scanning until a zero width stops early and loses the sprites
    -- past that hole, which is what animation scripts reference.
    --
    -- Read every slot the table occupies, not just the run from slot 1. ScummVM
    -- addresses entries directly as vgaFile2 + image * 8 (see draw.cpp's sprite
    -- source lookup), so an unused image id is simply a hole, not the end of
    -- the table: stopping at the first blank slot drops the sprites after it,
    -- which is exactly what many animation scripts reference.
    --
    -- The table runs from offset 8 up to the first image's data. Slot 1 holds
    -- the background and can be a hole, so the bound is the offset of the first
    -- slot that really is an entry rather than a fixed field.
    local function entry_at(i)
        local p = i * 8 + 1
        if p + 7 > #f2 then return nil end
        local off    = u32be(f2, p)
        local height = u8(f2, p + 5)
        local width  = u16be(f2, p + 6)
        if width > 0 and height > 0 and off > 0 and off < #f2 then
            return { index = i, offset = off, width = width, height = height,
                     flags = u8(f2, p + 4) }
        end
        return nil
    end

    local first
    for i = 1, math.floor((#f2 - 8) / 8) do
        first = entry_at(i)
        if first then break end
    end
    if not first then return {} end

    local table_end = first.offset
    local out = {}
    for i = 1, math.floor((table_end - 1) / 8) do
        local e = entry_at(i)
        if e then out[#out + 1] = e end
    end
    if #out == 0 then return out end

    -- Byte span per entry -> identifies the encoding exactly. Data blocks run
    -- in ascending offset order, so each runs to the next entry's offset and
    -- the last runs to the end of vgaFile2 (some zones hold a single
    -- background image, so the table end and the data end coincide there).
    local order = {}
    for n = 1, #out do order[n] = n end
    table.sort(order, function(a, b) return out[a].offset < out[b].offset end)
    for k, n in ipairs(order) do
        local nxt = order[k + 1]
        out[n].span = (nxt and out[nxt].offset or #f2) - out[n].offset
    end

    for _, e in ipairs(out) do
        local w, h, span = e.width, e.height, e.span
        if w > 320 then
            e.kind = "coltable"
        elseif w % 8 == 0 and math.floor(w / 8) * 5 * h == span then
            e.kind = "5bpp"
        elseif math.ceil(w / 2) * h == span then
            e.kind = "4bpp"
        else
            e.kind = "rle"
        end
        e.compressed = (e.kind == "rle")
        e.is_background = (e.kind == "5bpp" or e.kind == "coltable")
    end

    return out
end

-- ============================================================================
-- VGA script walker
--
-- Opcode 10 (vc10_draw) and 22 (vc22_setPalette) are the ops we care about;
-- every other opcode just has to be *skipped by the right number of bytes* or
-- the walk desynchronises and we start missing later draws.
--
-- The lengths below come from reading the real handlers, NOT from
-- ScummVM's vcSkipNextInstruction() tables. Those tables are only
-- authoritative for opcodes that have no handler at all; several handled
-- opcodes disagree with them, e.g.
--   * op 12 delay       reads a single BYTE in Simon 2 (table says 2)
--   * op 26 setSubWindow reads FIVE words / 10 bytes (table says 8)
--   * op 3  loadSprite  Simon 1 omits zoneNum, so 10 bytes not 12
--   * op 59 stopAnimations (Simon 2) reads three words, not one
--   * op 61 setMaskImage has no entry in either skip table
--
-- Registration follows ScummVM's inheritance chain, so the two games differ:
--   AGOSEngine::setupVideoOpcodes          -- base
--     AGOSEngine_Simon1::setupVideoOpcodes -- + Simon 1 overrides
--       AGOSEngine_Simon2::setupVideoOpcodes -- calls Simon 1's, then adds more
-- Simon 2 therefore INHERITS every Simon 1 override, including the two-word
-- op 22 setPalette, op 32 copyVar, op 37 addToSpriteY, op 48 setPathFinder and
-- op 61 setMaskImage.
-- ============================================================================

-- Each entry is { param bytes for Simon 1, param bytes for Simon 2,
--                 true if the handler can skip the following instruction }.
-- V(len1, len2, cond) keeps the three fields unambiguous; len2 defaults to
-- len1, and a bare "true" in the second slot would otherwise be mistaken for
-- a length when resolving Simon 2.
local function V(len1, len2, cond) return { len1, len2 or len1, cond } end

-- Handlers shared by both games.
local VC_BASE = {
    [1]  = V(6),        -- vc1_fadeOut
    [2]  = V(2),        -- vc2_call (vcReadVarOrWord: always 2 bytes here)
    [3]  = V(10, 12),   -- vc3_loadSprite  S1: win+sprite+x+y+pal, S2: +zone
    [4]  = V(6),        -- vc4_fadeIn
    [5]  = V(4, nil, true),  -- vc5_ifEqual          (conditional)
    [6]  = V(2, nil, true),  -- vc6_ifObjectHere     (conditional)
    [7]  = V(2, nil, true),  -- vc7_ifObjectNotHere  (conditional)
    [8]  = V(4, nil, true),  -- vc8_ifObjectIsAt     (conditional)
    [9]  = V(4, nil, true),  -- vc9_ifObjectStateIs  (conditional)
    [10] = V(10, 9),    -- vc10_draw  img+pal(2)+x+y+flags(word for S1, byte S2)
    [12] = V(2, 1),     -- vc12_delay  Simon 2 reads a single BYTE
    [13] = V(2),        -- vc13_addToSpriteX
    [14] = V(2),        -- vc14_addToSpriteY
    [15] = V(2),        -- vc15_sync
    [16] = V(2),        -- vc16_waitSync
    [18] = V(2),        -- vc18_jump (signed relative offset)
    [20] = V(4),        -- vc20_setRepeat (word + in-place word)
    [21] = V(2),        -- vc21_endRepeat
    [23] = V(2),        -- vc23_setPriority
    [24] = V(8, 7),     -- vc24_setSpriteXY  img+x+y+flags(word S1, byte S2)
    [25] = V(0),        -- vc25_halt_sprite
    [26] = V(10),       -- vc26_setSubWindow  win+x+y+w+h  (five words)
    [27] = V(0),        -- vc27_resetSprite
    [29] = V(0),        -- vc29_stopAllSounds
    [30] = V(2),        -- vc30_setFrameRate
    [31] = V(2),        -- vc31_setWindow
    [33] = V(0),        -- vc33_setMouseOn
    [34] = V(0),        -- vc34_setMouseOff
    [35] = V(4),        -- vc35_clearWindow (num + colour)
    [36] = V(4),        -- vc36_setWindowImage
    [38] = V(2, nil, true),  -- vc38_ifVarNotZero  (conditional)
    [39] = V(4),        -- vc39_setVar
    [40] = V(4),        -- vc40_scrollRight
    [41] = V(4),        -- vc41_scrollLeft
    [42] = V(4, nil, true),  -- vc42_delayIfNotEQ  (conditional)
    [43] = V(2, nil, true),  -- vc43_ifBitSet      (conditional)
    [44] = V(2, nil, true),  -- vc44_ifBitClear    (conditional)
    [45] = V(2),        -- vc45_setSpriteX
    [46] = V(2),        -- vc46_setSpriteY
    [47] = V(4),        -- vc47_addToVar
    [49] = V(2, nil, true),  -- vc49_setBit        (conditional)
    [50] = V(2, nil, true),  -- vc50_clearBit      (conditional)
    [51] = V(2),        -- vc51_enableBox
    [52] = V(2),        -- vc52_playSound
    [55] = V(6),        -- vc55_moveBox (id + x + y)
}

-- Simon 1 overrides; Simon 2 inherits all of these.
local VC_SIMON1 = {
    [11] = V(0),        -- vc11_clearPathFinder
    [17] = V(-1, -1),       -- vc17_setPathfinderItem: VARIABLE, scans to a sentinel
    [22] = V(4),        -- vc22_setPalette: TWO words (bank, block)
    [32] = V(4),        -- vc32_copyVar
    [37] = V(2),        -- vc37_addToSpriteY (overrides vc37_pokePalette)
    [48] = V(0),        -- vc48_setPathFinder
    [59] = V(0, nil, true),  -- vc59_ifSpeech (conditional)
    [60] = V(2, 4),     -- vc60_stopAnimation S1: sprite, S2: zone + sprite
    [61] = V(6),        -- vc61_setMaskImage (image + x + y)
    [62] = V(0),        -- vc62_fastFadeOut
    [63] = V(0),        -- vc63_fastFadeIn
}

-- Simon 2 additions, applied on top of Simon 1's table.
local VC_SIMON2 = {
    [56] = V(2),        -- vc56_delayLong
    [58] = V(6),        -- vc58_changePriority (zone + sprite + priority)
    [59] = V(6),        -- vc59_stopAnimations (file + start + end)
    [64] = V(0, nil, true),  -- vc64_ifSpeech     (conditional)
    [65] = V(0),        -- vc65_slowFadeIn
    [66] = V(4, nil, true),  -- vc66_ifEqual      (conditional)
    [67] = V(4, nil, true),  -- vc67_ifLE         (conditional)
    [68] = V(4, nil, true),  -- vc68_ifGE         (conditional)
    [69] = V(4),        -- vc69_playSeq (track + loop)
    [70] = V(4),        -- vc70_joinSeq (track + loop)
    [71] = V(0, nil, true),  -- vc71_ifSeqWaiting (conditional)
    [72] = V(4),        -- vc72_segue (track + loop)
    [73] = V(2),        -- vc73_setMark
    [74] = V(2),        -- vc74_clearMark
}

-- ScummVM's vcSkipNextInstruction tables. Only used for opcodes with no
-- handler at all; the walk then genuinely skips that many bytes.
local SKIP_SIMON1 = {
    0,6,2,10,6,4,2,2, 4,4,10,0,2,2,2,2, 2,0,2,0,4,2,4,2,
    8,0,10,0,8,0,2,2, 4,0,0,4,4,2,2,4, 4,4,4,2,2,2,2,4,
    0,2,2,2,2,4,6,6, 0,0,0,0,2,6,0,0, 0,
}
local SKIP_SIMON2 = {
    0,6,2,12,6,4,2,2, 4,4,9,0,1,2,2,2, 2,0,2,0,4,2,4,2,
    7,0,10,0,8,0,2,2, 4,0,0,4,4,2,2,4, 4,4,2,2,2,2,4,0,
    2,2,2,2,4,6,6,2, 0,6,6,4,6,0,0,0, 0,4,4,4,4,4,0,4,
    2,2,
}
local MAX_OP_SIMON1 = 64
local MAX_OP_SIMON2 = 75

-- Resolve a per-opcode length table, honouring the inheritance chain.
local function build_vclen(game)
    local skip = (game == 1) and SKIP_SIMON1 or SKIP_SIMON2
    local maxop = (game == 1) and MAX_OP_SIMON1 or MAX_OP_SIMON2
    local reg = {}
    local function apply(tbl)
        for op, e in pairs(tbl) do reg[op] = e end
    end
    apply(VC_BASE)
    apply(VC_SIMON1)
    if game == 2 then apply(VC_SIMON2) end

    local len, cond = {}, {}
    for op = 0, maxop - 1 do
        local e = reg[op]
        if e then
            len[op] = e[game]
            cond[op] = e[3] or false
        else
            len[op] = (op < #skip) and skip[op + 1] or 0
            cond[op] = false
        end
    end
    return len, cond, maxop
end

-- Resolved once at load time: VC_LEN[game] = { lengths, conditional?, maxop }
local VC_LEN = { [1] = {}, [2] = {} }
for _g = 1, 2 do
    local _len, _cond, _maxop = build_vclen(_g)
    VC_LEN[_g] = { _len, _cond, _maxop }
end

local function run_vga_script(f1, script_off, game)
    local ops = {}
    if not f1 or #f1 < 4 then return ops end

    local L = VC_LEN[game]
    local len, maxop = L[1], L[3]
    local alen = (game == 1) and 2 or 1
    -- vc22_setPalette is opcode 22 for both games: Simon 2 inherits Simon 1's
    -- registration, and the Simon 1 override in vga_s1.cpp reads TWO words
    -- (bank a, block b).
    local p = script_off + 1                 -- 0-based -> 1-based
    local guard = 0

    while p <= #f1 and guard < 40000 do
        guard = guard + 1
        if p + alen - 1 > #f1 then break end
        local op = (game == 1) and u16be(f1, p) or u8(f1, p)
        if op == 0 then break end
        if op >= maxop then break end        -- desync: stop

        local n = len[op]
        local q = p + alen                   -- 1-based index of first param byte

        if n == -1 then
            -- vc17_setPathfinderItem: a slot index followed by 4-byte pairs
            -- terminated by the sentinel 999 (9999 for FF/PP, not Simon).
            local e = q + 1
            while e + 1 <= #f1 and u16be(f1, e) ~= 999 do e = e + 4 end
            n = (e + 1) - q
        elseif op == 22 then                                  -- vc22_setPalette
            if q + 3 > #f1 then break end
            local a = u16be(f1, q)
            local b = u16be(f1, q + 2)
            if a <= 15 then ops[#ops + 1] = { op = "pal", bank = a, block = b } end
        elseif op == 10 then                                -- vc10_draw
            -- vc10_draw: image(2) | <byte 1 of 2> = palette | x(2, signed) |
            --            y(2, signed) | flags(2 for Simon 1, 1 for Simon 2)
            if q + 7 > #f1 then break end
            local pal = u8(f1, q + 2)                -- _vcPtr[1], both games
            -- Signed: a negative image number names a variable (vcReadVarOrWord),
            -- which costs one extra word inside this instruction and cannot be
            -- resolved without the game's variable array.
            local image = s16be(f1, q)
            if image < 0 then n = n + 2 end
            if image > 0 and pal <= 15 then
                ops[#ops + 1] = {
                    op    = "draw",
                    image = image,
                    bank  = pal,
                    x     = s16be(f1, q + 4),
                    y     = s16be(f1, q + 6),
                }
            end
        end

        p = p + alen + n
    end

    return ops
end

-- ============================================================================
-- Animation script interpreter
--
-- Animation frames do NOT come from vc10_draw. Across both games vc10_draw
-- fires only 620 times (Simon 1) and 3 times (Simon 2), while
-- vc24_setSpriteXY -- which assigns vsp->image -- fires 36,618 and 128,924
-- times respectively. An animation is a script that repeatedly points a
-- sprite at a different image in vgaFile2, so the frame list is the ordered
-- sequence of vc24_setSpriteXY image indices.
--
-- vc3_loadSprite is not a frame either: it calls animate() to *start* another
-- animation (vcgfp/vcPtr are restored afterwards), so it only contributes
-- the palette bank and origin that the sprite was started with.
--
-- Unlike the plain linear walk this follows control flow:
--   * conditional opcodes may skip the next instruction, so BOTH the
--     fall-through and the skip target are explored (depth first, with a
--     visited set so animation loops terminate)
--   * vc18_jump is unconditional, so only its target is followed
--   * vc19_loop restarts the animation and never returns: treat as end
--   * vc12_delay / vc56_delayLong suspend and later resume at the same
--     point, so for a static frame listing they are simply stepped over
--   * a negative vc24 image is a variable reference (vcReadVarOrWord); with
--     no variable state there is nothing to resolve, so it is skipped
-- ============================================================================

local function run_anim_script(f1, script_off, game)
    local ops = {}
    if not f1 or #f1 < 4 then return ops end

    local L = VC_LEN[game]
    local len, cond, maxop = L[1], L[2], L[3]
    local alen = (game == 1) and 2 or 1
    local visited, stack, guard = {}, {}, 0
    local pending_delay, nframes = nil, 0

    stack[#stack + 1] = script_off + 1          -- 0-based -> 1-based

    while #stack > 0 and guard < 40000 do
        local p = stack[#stack]
        stack[#stack] = nil

        while p + alen - 1 <= #f1 and guard < 40000 do
            guard = guard + 1
            if visited[p] then break end
            visited[p] = true

            local op = (game == 1) and u16be(f1, p) or u8(f1, p)
            if op == 0 then break end          -- end of script
            if op >= maxop then break end       -- desync: abandon this path

            local n = len[op]
            local q = p + alen                  -- 1-based first param byte

            if n == -1 then                    -- vc17_setPathfinderItem
                local e = q + 1
                while e + 1 <= #f1 and u16be(f1, e) ~= 999 do e = e + 4 end
                n = (e + 1) - q
            end

            if op == 24 then                                       -- vc24_setSpriteXY
                if q + 6 > #f1 then break end
                -- vcReadVarOrWord reads a SIGNED word: a negative value is a
                -- variable number, and reading the variable costs one extra
                -- word inside this same instruction. The result is not
                -- knowable statically, so only a real index is a frame.
                local image = s16be(f1, q)
                if image < 0 then n = n + 2 end
                if image > 0 then
                    nframes = nframes + 1
                    ops[nframes] = {
                        op = "sprite", image = image,
                        dx  = s16be(f1, q + 2),
                        dy  = s16be(f1, q + 4),
                        delay = pending_delay,
                    }
                    pending_delay = nil
                end
            elseif op == 10 then                                   -- vc10_draw
                if q + 7 > #f1 then break end
                local image = u16be(f1, q)
                if image ~= 0 then
                    nframes = nframes + 1
                    ops[nframes] = {
                        op = "sprite", image = image,
                        bank = u8(f1, q + 2),
                        dx = s16be(f1, q + 4), dy = s16be(f1, q + 6),
                        delay = pending_delay,
                    }
                    pending_delay = nil
                end
            elseif op == 22 then                                   -- vc22_setPalette
                if q + 3 > #f1 then break end
                local a = u16be(f1, q)
                if a <= 15 then
                    ops[#ops + 1] = { op = "pal", bank = a, block = u16be(f1, q + 2) }
                end
            elseif op == 3 then                                    -- vc3_loadSprite
                -- Starts another animation; keep the palette it starts with.
                if q + 9 <= #f1 then
                    local sprite = (game == 2) and u16be(f1, q + 4) or u16be(f1, q + 2)
                    local pal    = u16be(f1, q + ((game == 2) and 10 or 8))
                    if pal <= 15 then
                        ops[#ops + 1] = { op = "start", sprite = sprite, bank = pal }
                    end
                end
            elseif op == 12 or op == 56 then                       -- delay
                if q <= #f1 then
                    -- Remember it: the delay that runs just before a frame is
                    -- that frame's interval.
                    pending_delay = (game == 1) and u16be(f1, q) or u8(f1, q)
                end
            elseif op == 18 then                                   -- vc18_jump
                if q + 1 > #f1 then break end
                local offs = s16be(f1, q)
                local target = q + n + offs
                if target >= 1 and target <= #f1 then stack[#stack + 1] = target end
                break                        -- unconditional: no fall-through
            elseif op == 19 then                                   -- vc19_loop
                break                           -- restarts the animation
            end

            if cond[op] then
                -- This handler may skip the following instruction, so the
                -- instruction after it is a second path worth exploring.
                local skip = q + n
                if skip >= 1 and skip + alen - 1 <= #f1 and not visited[skip] then
                    stack[#stack + 1] = skip
                end
            end

            p = q + n
        end
    end

    -- The delay that actually separates frames is the one that ran just
    -- before each frame; a script also contains longer end-of-loop waits that
    -- are not a frame interval. animation_create takes a single delay, so use
    -- the most common per-frame interval.
    local best, bestn = nil, 0
    local counts = {}
    for i = 1, nframes do
        local v = ops[i].delay
        if v and v > 0 then
            counts[v] = (counts[v] or 0) + 1
            if counts[v] > bestn then bestn, best = counts[v], v end
        end
    end
    ops.delay = best
    ops.frames = nframes
    return ops
end

-- ============================================================================
-- Palette
-- ============================================================================

-- Build the 256-entry display palette (768 bytes) from a script's
-- vc22_setPalette calls. Bank a holds 32 colours when a == 0, else 16,
-- loaded from vgaFile1 at offset 6 + block*96, scaled by 4.
local function build_palette(f1, ops)
    local pal = {}
    for i = 0, 255 do
        pal[i * 3 + 1] = 0
        pal[i * 3 + 2] = 0
        pal[i * 3 + 3] = 0
    end
    if not f1 then return pal end

    for _, o in ipairs(ops) do
        if o.op == "pal" then
            local num  = (o.bank == 0) and 32 or 16
            local base = 7 + o.block * 96        -- 0-based offset 6
            for c = 0, num - 1 do
                local p = base + c * 3
                if p + 2 > #f1 then break end
                local d = (o.bank * 16 + c) * 3
                pal[d + 1] = math.min(255, u8(f1, p) * 4)
                pal[d + 2] = math.min(255, u8(f1, p + 1) * 4)
                pal[d + 3] = math.min(255, u8(f1, p + 2) * 4)
            end
        end
    end
    return pal
end

-- Grey ramp fallback so an image is never fully black.
local function grey_palette()
    local pal = {}
    for i = 0, 255 do
        pal[i * 3 + 1] = 0
        pal[i * 3 + 2] = 0
        pal[i * 3 + 3] = 0
    end
    for i = 0, 255 do
        local v = math.floor(i * 255 / 255)
        pal[i * 3 + 1] = v
        pal[i * 3 + 2] = v
        pal[i * 3 + 3] = v
    end
    return pal
end

-- ============================================================================
-- Decoders
-- All return a 1-based flat table of palette indices, width*height entries.
-- ============================================================================

local function s8(v)
    return v >= 128 and v - 256 or v
end

-- RLE column reader: faithful port of gfx.cpp vc10_depackColumn. Decodes one
-- column of h bytes; the run state (st.a) and the source position carry over
-- into the next column, exactly as in the original.
local function rle_new(f2, off)
    return { f2 = f2, pos = off, a = -128, eof = false }
end

local function rle_byte(st)
    if st.pos >= #st.f2 then st.eof = true; return 0 end
    local v = u8(st.f2, st.pos + 1)          -- st.pos is a 0-based offset
    st.pos = st.pos + 1
    return v
end

local function rle_column(st, h)
    local col, i = {}, 0                 -- col[1] is the top row
    if st.a == -128 then st.a = s8(rle_byte(st)) end
    while not st.eof do
        if st.a >= 0 then
            local color = rle_byte(st)
            while true do
                i = i + 1
                col[i] = color
                if i >= h then
                    st.a = st.a - 1
                    if st.a < 0 then st.a = -128 else st.pos = st.pos - 1 end
                    return col
                end
                st.a = st.a - 1
                if st.a < 0 then break end
            end
        else
            while true do
                i = i + 1
                col[i] = rle_byte(st)
                if i >= h then
                    st.a = st.a + 1
                    if st.a == 0 then st.a = -128 end
                    return col
                end
                st.a = st.a + 1
                if st.a == 0 then break end
            end
        end
        st.a = s8(rle_byte(st))
    end
    return col
end

-- 5 bits per pixel, uncompressed: 8 pixels per 5 bytes, most significant bits
-- first (debug.cpp dumpBitmap's 320x{134,135,200} branch).
local function decode_5bpp(f2, offset, w, h)
    local pixels = {}
    local n, pos = 0, offset + 1
    local groups = math.floor(w / 8)

    for _ = 1, h do
        for _ = 1, groups do
            if pos + 4 > #f2 then
                for _ = 1, 8 do n = n + 1; pixels[n] = 0 end
            else
                local v = ((u8(f2, pos) * 256 + u8(f2, pos + 1)) * 256
                           + u8(f2, pos + 2)) * 256 + u8(f2, pos + 3)
                v = v * 256 + u8(f2, pos + 4)          -- 40 bits, big-endian
                for k = 0, 7 do
                    n = n + 1
                    pixels[n] = math.floor(v / (2 ^ (35 - 5 * k))) % 32
                end
            end
            pos = pos + 5
        end
    end
    return pixels
end

-- 4bpp uncompressed: w/2 bytes per row, high nibble = left pixel.
local function decode_4bpp(f2, offset, w, h, bank)
    local pixels = {}
    for i = 1, w * h do pixels[i] = 0 end
    -- Rows are padded to a whole byte, so an odd width still advances by
    -- ceil(w/2); the final low nibble is padding, not a pixel.
    local row_bytes = math.ceil(w / 2)
    local pos = offset + 1

    for row = 0, h - 1 do
        for col = 0, row_bytes - 1 do
            local bv = (pos <= #f2) and (u8(f2, pos) or 0) or 0
            pos = pos + 1
            local o = col * 2
            if o + 1 <= w then pixels[row * w + o + 1] = math.floor(bv / 16) + bank end
            if o + 2 <= w then pixels[row * w + o + 2] = (bv % 16) + bank end
        end
    end
    return pixels
end

-- 4bpp RLE: w/2 RLE columns of h bytes, 2 pixels per byte.
local function decode_rle(f2, offset, w, h, bank)
    local pixels = {}
    for i = 1, w * h do pixels[i] = 0 end
    if w < 2 or h < 1 then return pixels end

    local st = rle_new(f2, offset)
    for col = 0, math.floor(w / 2) - 1 do
        local c = rle_column(st, h)
        for row = 0, h - 1 do
            local bv = c[row + 1] or 0
            pixels[row * w + col * 2 + 1] = math.floor(bv / 16) + bank
            if col * 2 + 2 <= w then
                pixels[row * w + col * 2 + 2] = (bv % 16) + bank
            end
        end
        if st.eof then break end
    end
    return pixels
end

-- Wide images (w > 320, 8bpp): a table of (w/8) big-endian u32 offsets relative
-- to the table start, one per 8-pixel group. Each group is an independent RLE
-- stream of 8 columns x h bytes, one byte per pixel (gfx.cpp decodeColumn).
-- Wide images (w > screen width) are a table of w/8 big-endian u32 offsets;
-- each points at an independently compressed 8-column block of 8-bit pixels.
-- This is AGOSEngine::decodeColumn, NOT vc10_depackColumn: the run counter is
-- re-read for every run and there is no state carried between columns.
local function decode_coltable(f2, offset, w, h, bank)
    local pixels = {}
    for i = 1, w * h do pixels[i] = 0 end
    if w < 8 or h < 1 then return pixels end

    for g = 0, math.floor(w / 8) - 1 do
        local tp = offset + g * 4 + 1
        if tp + 3 > #f2 then break end
        local p = offset + u32be(f2, tp) + 1
        local col, row = 0, 0

        while col < 8 do
            if p > #f2 then break end
            local reps = u8(f2, p)
            if reps >= 128 then reps = reps - 256 end
            p = p + 1
            local n = (reps >= 0) and (reps + 1) or -reps

            for _ = 1, n do
                if col >= 8 then break end
                local v
                if reps >= 0 then
                    if p > #f2 then return pixels end
                    v = u8(f2, p)
                    p = p + 1
                else
                    if p > #f2 then return pixels end
                    v = u8(f2, p)
                    p = p + 1
                end
                pixels[row * w + (g * 8 + col) + 1] = v
                row = row + 1
                if row >= h then row = 0; col = col + 1 end
            end
        end
    end
    return pixels
end

-- Dispatch on the detected encoding.
local function decode_image(f2, entry, bank)
    if entry.kind == "5bpp" then
        return decode_5bpp(f2, entry.offset, entry.width, entry.height)
    elseif entry.kind == "4bpp" then
        return decode_4bpp(f2, entry.offset, entry.width, entry.height, bank)
    elseif entry.kind == "coltable" then
        return decode_coltable(f2, entry.offset, entry.width, entry.height, 0)
    else
        return decode_rle(f2, entry.offset, entry.width, entry.height, bank)
    end
end


-- ============================================================================
-- Detection
-- ============================================================================

local function find_gme(game_path)
    for _, name in ipairs({ "simon.gme", "SIMON.GME", "simon2.gme", "SIMON2.GME" }) do
        local path = game_path .. "/" .. name
        if file_exists(path) then
            local f = file_open(path)
            if f then
                local offsets, nslots = parse_gme(f)
                if offsets then
                    return f, offsets, nslots, name
                end
                file_close(f)
            end
        end
    end
    return nil
end

local function is_simon1(game_path)
    return file_exists(game_path .. "/gamepc")
        or file_exists(game_path .. "/GAMEPC")
end

local function is_simon2(game_path)
    return file_exists(game_path .. "/GSPTR30")
        or file_exists(game_path .. "/gsptr30")
end

function engine.detect(game_path)
    return is_simon1(game_path) or is_simon2(game_path)
end

-- vgaFile1 = slot zone*2, vgaFile2 = slot zone*2+1
-- The GME offset table is identical for every zone, so parse it once per
-- game path instead of once per slot.
local GME_CACHE, GME_CACHE_KEY = {}, nil

local function gme_info(game_path)
    if GME_CACHE_KEY == game_path then return GME_CACHE[game_path] end
    GME_CACHE_KEY = game_path
    local f, offsets, nslots, name = find_gme(game_path)
    local info = { path = name and (game_path .. "/" .. name) or nil }
    if f then
        info.offsets, info.nslots = offsets, nslots
        file_close(f)
    end
    GME_CACHE[game_path] = info
    return info
end

local function get_zone_data(game_path, zone, file_type)
    local info = gme_info(game_path)
    if info.offsets then
        local data = read_slot_file(info.path, info.offsets, info.nslots,
                                    zone * 2 + (file_type - 1))
        if data and #data > 0 then return data end
        return nil
    end

    -- Fallback: loose VGA files NNN1.VGA / NNN2.VGA
    local vga_name = string.format("%.3d%d.VGA", zone, file_type)
    local vf = file_open(game_path .. "/" .. vga_name)
    if not vf then vf = file_open(game_path .. "/" .. vga_name:lower()) end
    if vf then
        local sz   = file_size(vf)
        local data = file_read(vf, 0, sz)
        file_close(vf)
        return data
    end
    return nil
end

-- ============================================================================
-- Zone context
-- ============================================================================

-- Parsing a zone means reading the GME offset table and walking both VGA
-- files, and a single game has tens of thousands of images spread over its
-- zones, so memoise per (game path, zone).  Kept deliberately simple: the
-- cache is dropped whenever the set of game paths changes.
local ZONE_CACHE, ZONE_CACHE_KEY = {}, nil

local function invalidate_cache()
    ZONE_CACHE = {}
    ZONE_CACHE_KEY = nil
end

local function cache_key(game_path, zone)
    return game_path .. "\0" .. tostring(zone)
end

local function load_zone(game_path, zone, game)
    if ZONE_CACHE_KEY ~= game_path then invalidate_cache(); ZONE_CACHE_KEY = game_path end
    local ck = cache_key(game_path, zone)
    local hit = ZONE_CACHE[ck]
    if hit ~= nil then return hit or nil end

    local f1 = get_zone_data(game_path, zone, 1)
    local f2 = get_zone_data(game_path, zone, 2)
    if not f1 and not f2 then
        ZONE_CACHE[ck] = false
        return nil
    end
    local hdr = parse_vga1_header(f1)
    local images = parse_vga1_images(f1, hdr)
    local ctx = {
        zone  = zone,
        game  = game,
        f1    = f1,
        f2    = f2,
        hdr   = hdr,
        images = images,
        anims  = parse_vga1_anims(f1, hdr),
        raw     = f2 and parse_img_table(f2) or {},
    }
    -- The room background's script is what sets the palette the rest of the
    -- zone (sprites and animations included) draws with, so cache its
    -- setPalette calls once per zone.
    local bg
    for _, im in ipairs(images) do
        if bg == nil or im.id < bg.id then bg = im end
    end
    if bg and bg.scriptOffs and bg.scriptOffs < (f1 and #f1 or 0) then
        ctx.pal_ops = run_vga_script(f1, bg.scriptOffs, game)
    end
    ZONE_CACHE[ck] = ctx
    return ctx
end

local function find_raw(ctx, index)
    for _, e in ipairs(ctx.raw) do
        if e.index == index then return e end
    end
    return nil
end

-- The room background is the vgaFile1 image whose id is zone*100 (the lowest
-- id in the zone). Its script lists the palette banks and draw calls that
-- make up the composited room view.
local function background_image(ctx)
    local best
    for _, im in ipairs(ctx.images) do
        if best == nil or im.id < best.id then best = im end
    end
    return best
end

-- ============================================================================
-- Rendering
-- ============================================================================

-- Composite a script's draw calls onto a screen-sized indexed canvas.
local function composite(ctx, ops, screen_w, screen_h)
    local canvas = {}
    for i = 1, screen_w * screen_h do canvas[i] = 0 end

    for _, o in ipairs(ops) do
        if o.op == "draw" and o.image ~= 0 then
            local e = find_raw(ctx, o.image)
            if e then
                local px = decode_image(ctx.f2, e, o.bank * 16)
                for row = 0, e.height - 1 do
                    local Y = o.y + row
                    if Y >= 0 and Y < screen_h then
                        local srow = row * e.width
                        for col = 0, e.width - 1 do
                            local X = o.x + col
                            if X >= 0 and X < screen_w then
                                canvas[Y * screen_w + X + 1] = px[srow + col + 1] or 0
                            end
                        end
                    end
                end
            end
        end
    end

    return canvas
end

-- ============================================================================
-- Resource tree
-- ============================================================================

local SCREEN_W, SCREEN_H = 320, 200

function engine.get_resources(game_path)
    local info    = gme_info(game_path)
    local max_zone = 200
    if info.offsets then
        max_zone = math.floor(info.nslots / 2)
    end

    local game  = is_simon2(game_path) and 2 or 1
    local label = (game == 2) and "Simon 2" or "Simon 1"

    local zones_cat = {
        id = "zones", name = label .. " Zones", type = "category", children = {}
    }

    local total_bg, total_img, total_anim = 0, 0, 0

    for zone = 0, math.min(max_zone, 500) do
        local f1 = get_zone_data(game_path, zone, 1)
        local f2 = get_zone_data(game_path, zone, 2)
        if f1 and f2 and #f2 >= 24 then
            local ctx = load_zone(game_path, zone, game)
            if ctx and #ctx.raw > 0 then
                local children = {}

                -- Composed room view(s).  Only the script that draws a
                -- full-width / 5bpp image is the room background; other
                -- scripts with draws are overlay layers.
                local byindex = {}
                for _, e in ipairs(ctx.raw) do byindex[e.index] = e end
                local bg_best, bg_score
                local layers = {}
                for _, im in ipairs(ctx.images) do
                    local ops = run_vga_script(f1, im.scriptOffs, game)
                    local ndraw, nwide, npal = 0, 0, 0
                    for _, o in ipairs(ops) do
                        if o.op == "draw" and o.image ~= 0 then
                            ndraw = ndraw + 1
                            local e = byindex[o.image]
                            if e and (e.kind == "5bpp" or e.width >= 320) then
                                nwide = nwide + 1
                            end
                        elseif o.op == "pal" then
                            npal = npal + 1
                        end
                    end
                    if ndraw > 0 then
                        local score = nwide * 1000 + npal
                        layers[#layers + 1] = { im = im, ndraw = ndraw, wide = nwide }
                        if not bg_score or score > bg_score then bg_best, bg_score = im, score end
                    end
                end
                for _, L in ipairs(layers) do
                    local is_bg = (bg_best ~= nil and L.im.index == bg_best.index)
                    children[#children + 1] = {
                        id   = string.format("room_%d_%d", zone, L.im.index),
                        name = is_bg
                            and string.format("Room %d (background)", zone)
                            or  string.format("Overlay %d (%d draws)", L.im.id, L.ndraw),
                        type = "image",
                    }
                    if is_bg then total_bg = total_bg + 1 end
                end

                -- Animations
                for _, an in ipairs(ctx.anims) do
                    local ops = run_vga_script(f1, an.scriptOffs, game)
                    local ndraw, seen = 0, {}
                    for _, o in ipairs(ops) do
                        if o.op == "draw" and o.image ~= 0 and not seen[o.image] then
                            seen[o.image] = true
                            ndraw = ndraw + 1
                        end
                    end
                    children[#children + 1] = {
                        id   = string.format("anim_%d_%d", zone, an.index),
                        name = string.format("Animation %d (%d frames)", an.id, ndraw),
                        type = "animation",
                    }
                    total_anim = total_anim + 1
                end

                -- Individual images
                for _, e in ipairs(ctx.raw) do
                    children[#children + 1] = {
                        id   = string.format("img_%d_%d", zone, e.index),
                        name = string.format("Image %d (%dx%d, %s)", e.index,
                                    e.width, e.height, e.kind),
                        type = "image",
                    }
                    total_img = total_img + 1
                end

                if #children > 0 then
                    zones_cat.children[#zones_cat.children + 1] = {
                        id   = string.format("zone_%d", zone),
                        name = string.format("Zone %d (%d images, %d animations)",
                                    zone, #ctx.raw, #ctx.anims),
                        type = "category",
                        children = children,
                    }
                end
            end
        end
    end

    zones_cat.name = string.format("%s Zones (%d room views, %d images, %d animations)",
                                    label, total_bg, total_img, total_anim)

    local resources = {}
    if #zones_cat.children > 0 then
        resources[#resources + 1] = zones_cat
    end
    return resources
end

-- ============================================================================
-- Resource loader
-- ============================================================================

function engine.load_resource(game_path, resource_id)
    local kind, zone_s, idx_s = resource_id:match("^(%a+)_(%d+)_(%d+)$")
    if not kind then return nil end
    local zone = tonumber(zone_s)
    local idx  = tonumber(idx_s)
    local game = is_simon2(game_path) and 2 or 1

    local ctx = load_zone(game_path, zone, game)
    if not ctx then return nil end

    -- Composed room view
    if kind == "room" then
        local im
        for _, e in ipairs(ctx.images) do
            if e.index == idx then im = e; break end
        end
        if not im then return nil end
        local ops   = run_vga_script(ctx.f1, im.scriptOffs, game)
        local pal   = build_palette(ctx.f1, ops)
        local canvas = composite(ctx, ops, SCREEN_W, SCREEN_H)
        local handle = image_create_indexed(SCREEN_W, SCREEN_H, canvas, pal)
        if not handle then return nil end
        return {
            type = "image", image = handle,
            description = string.format(
                "Zone %d room view (sprite %d) - %dx%d composited from %d draw ops",
                zone, im.id, SCREEN_W, SCREEN_H, #ops),
        }
    end

    -- Single image
    if kind == "img" then
        local e = find_raw(ctx, idx)
        if not e then return nil end
        -- The vgaFile2 index space is shared by every script in the zone, so
        -- walk them all in table order: the first draw of this image decides
        -- its palette bank, and they all contribute palette blocks.
        local ops, bank = {}, 0
        for _, im in ipairs(ctx.images) do
            local script = run_vga_script(ctx.f1, im.scriptOffs, game)
            for _, o in ipairs(script) do
                ops[#ops + 1] = o
                if bank == 0 and o.op == "draw" and o.image == e.index then
                    bank = o.bank
                end
            end
        end
        local pal = build_palette(ctx.f1, ops)
        local px = decode_image(ctx.f2, e, bank * 16)
        local handle = image_create_indexed(e.width, e.height, px, pal)
        if not handle then return nil end
        return {
            type = "image", image = handle,
            description = string.format("Zone %d image %d - %dx%d (%s, palette bank %d)",
                        zone, e.index, e.width, e.height, e.kind, bank),
        }
    end

    -- Animation
    if kind == "anim" then
        local an
        for _, e in ipairs(ctx.anims) do
            if e.index == idx then an = e; break end
        end
        if not an then return nil end
        local ops = run_anim_script(ctx.f1, an.scriptOffs, game)

        -- Palette: the room background's script is what the game would have
        -- loaded before running this animation, so prefer it, and fall back
        -- to the animation's own setPalette calls.
        local pal = build_palette(ctx.f1, ctx.pal_ops)
        if not ctx.pal_ops then pal = build_palette(ctx.f1, ops) end

        -- Frames are the ordered vc24_setSpriteXY / vc10_draw image indices.
        -- Keep repeats: a frame that alternates between two images is a real
        -- part of the animation, and a ping-pong sequence is common.
        local frames, frame_delays, bank = {}, {}, 0
        for _, o in ipairs(ops) do
            if o.op == "start" and bank == 0 then
                bank = o.bank
            elseif o.op == "sprite" and o.image and o.image ~= 0 then
                if o.bank then bank = o.bank end
                local e = find_raw(ctx, o.image)
                if e then
                    local px = decode_image(ctx.f2, e, bank * 16)
                    local hh = image_create_indexed(e.width, e.height, px, pal)
                    if hh then frames[#frames + 1] = hh; frame_delays[#frame_delays + 1] = o.delay end
                end
            end
        end
        if #frames == 0 then return nil end

        -- vc12_delay counts VGA frames. Simon 1 ticks every 50ms and Simon 2
        -- every 45ms (setupGame's _vgaPeriod), and the handler adds
        -- _vgaBaseDelay (1) on top of value * _frameCount (1).
        --
        -- A script also holds delays that belong to frames whose image index
        -- does not resolve in this zone, and longer end-of-loop waits, so take
        -- the most common interval among the frames we actually emit.
        local counts, bestn, best = {}, 0, nil
        for _, d in ipairs(frame_delays) do
            if d and d > 0 then
                counts[d] = (counts[d] or 0) + 1
                if counts[d] > bestn then bestn, best = counts[d], d end
            end
        end
        local ms = nil
        if best and best > 0 then
            ms = math.floor((best + 1) * ((game == 1) and 50 or 45))
        end
        if not ms or ms < 20 or ms > 2000 then ms = 100 end
        local anim = animation_create(frames, ms)
        if not anim then return nil end
        return {
            type = "animation", animation = anim,
            description = string.format(
                "Zone %d animation %d - %d frames, palette bank %d, %dms/frame",
                zone, an.id, #frames, bank, ms),
        }
    end

    return nil
end

-- Internal helpers exposed for offline test harnesses. Not used by the game.
engine._debug = {
    load_ctx  = load_zone,
    img_table = parse_img_table,
    anim_ops  = run_anim_script,
    vclen     = VC_LEN,
}

return engine

-- Lure of the Temptress: music/sound (MIDI) and text strings.
-- References (ScummVM engines/lure): sound.cpp (SoundManager::musicInterface_Play,
-- MidiMusic::MidiMusic packed data), strings.cpp (StringData), disk.cpp
-- (support file language blocks), luredefs.h (resource ids), lure.h (LureLanguage).
local X = {}

local function u16(d, p) local a, b = d:byte(p, p + 1); return (a or 0) + (b or 0) * 256 end
local function u32(d, p) local a, b, c, e = d:byte(p, p + 3); return (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (e or 0) * 16777216 end

-- ── Music and sound effects ────────────────────────────────────────────────
-- A sound bank is a count byte, a padding byte, then u32 offsets from byte 2.
-- Each entry is a standard MIDI file, optionally packed: 'C'/'c', 256 u16 words,
-- then one index byte per output word ('c' drops the first output byte).
X.BANKS = {
    { id = 0x000C, name = "Main (Roland)" }, { id = 0x000D, name = "Main (AdLib)" },
    { id = 0x0030, name = "Intro (Roland)" }, { id = 0x0031, name = "Intro (AdLib)" },
    { id = 0xFF10, name = "End game (Roland)" }, { id = 0xFF11, name = "End game (AdLib)" },
}

function X.bank_entries(bank)
    if not bank or #bank < 6 then return nil end
    local count = bank:byte(1)
    local out = {}
    for i = 0, count - 1 do
        local ofs = u32(bank, 3 + i * 4)
        local nxt = i < count - 1 and u32(bank, 3 + (i + 1) * 4) or #bank
        if ofs > 0 and ofs < #bank and nxt > ofs then out[#out + 1] = { index = i, offset = ofs, size = math.min(nxt, #bank) - ofs } end
    end
    return out
end

function X.unpack_midi(data)
    local tag = data:sub(1, 1)
    if tag == "C" or tag == "c" then
        local packed = #data - 0x201
        if packed <= 0 then return nil end
        local words = {}
        for i = 0, 255 do words[i] = data:sub(2 + i * 2, 3 + i * 2) end
        local out = {}
        for i = 1, packed do out[i] = words[data:byte(0x201 + i)] or "\0\0" end
        data = table.concat(out)
        if tag == "c" then data = data:sub(2) end
    end
    if data:sub(1, 4) ~= "MThd" then return nil end
    return data
end

-- ── Strings ────────────────────────────────────────────────────────────────
X.LANGUAGES = { [3] = "English", [4] = "English (Konami)", [5] = "Russian", [6] = "French", [7] = "German", [10] = "Italian", [17] = "Spanish" }

-- Bit-sequence decoder (support resource 0x3F19): repeated ASCII byte followed
-- by a zero-terminated string of '0'/'1' (first bit first), ending with 0xFF.
function X.parse_decoder(d)
    if not d then return nil end
    local codes, p = {}, 1
    while p <= #d and d:byte(p) ~= 0xFF do
        local ascii = d:byte(p)
        local seq = d:match("^[01]*", p + 1)
        local value = 0
        for i = 1, #seq do if seq:sub(i, i) == "1" then value = value + 2 ^ (i - 1) end end
        codes[#seq * 0x100000 + value] = ascii
        p = p + 1 + #seq + 1
    end
    return codes
end

local RANGE = 0x7D0

-- StringData::initPosition + readCharacter. Returns text (raw bytes) or nil.
local function decode(tables, codes, names, id)
    local t = tables[math.floor(id / RANGE)]
    if not t or #t < 6 then return nil end
    local sid = id % RANGE
    local pos = 5
    local total = 0
    for _ = 1, math.floor(sid / 32) do total = total + u16(t, pos); pos = pos + 2 end
    if sid % 32 ~= 0 then
        local skip = (sid - sid % 32) + u16(t, 1) + 1
        for i = 0, sid % 32 - 1 do
            local v = t:byte(skip + i) or 0
            total = total + (v < 0x80 and v or (v % 0x80) * 8)
        end
    end
    local mask = 0x80
    if total % 4 ~= 0 then mask = mask / 2 ^ ((total % 4) * 2) end
    local src = math.floor(total / 4) + u16(t, 3) + 1
    local function bit()
        local b = t:byte(src)
        if not b then return nil end
        local r = math.floor(b / mask) % 2
        mask = mask / 2
        if mask < 1 then mask = 0x80; src = src + 1 end
        return r
    end
    while true do
        local b = bit()
        if b == nil then return nil end
        if b == 0 then break end
        src = src + 2
    end
    if bit() == nil then return nil end -- articles flag
    local out = {}
    for _ = 1, 1000 do
        local value, ch = 0, nil
        for n = 1, 18 do
            local b = bit()
            if b == nil then return nil end
            value = value + b * 2 ^ (n - 1)
            ch = codes[n * 0x100000 + value]
            if ch then break end
        end
        if not ch then return nil end
        if ch == 0 then return table.concat(out) end
        if ch >= 0xA0 and names then
            local n = ch - 0xA0
            if n < u16(names, 1) / 2 then out[#out + 1] = names:match("^[^%z]*", u16(names, 1 + n * 2) + 1) end
        else
            out[#out + 1] = string.char(ch)
        end
    end
    return nil
end
X.decode = decode

-- Number of string ids in one table: blocks of 32 between the block-size list
-- (from byte 4) and the skip-byte area at u16(0).
function X.table_size(t)
    if not t or #t < 6 then return 0 end
    return math.floor((u16(t, 1) - 4) / 2) * 32
end

-- Accented letters follow the game font (disk resource 4, 8x8 glyphs from
-- character 32): 0x80-0x99 draw these characters; 0x8B is a check mark.
local FONT_HIGH = { 0xE2, 0xE0, 0xE7, 0xEA, 0xEB, 0xE8, 0xEF, 0xEE, 0xF4, 0xFB, 0xF9, 0x2713, 0xFC, 0xE4, 0xC4, 0xF6,
    0xD6, 0xDC, 0xDF, 0xF1, 0xBF, 0xA1, 0xF3, 0xED, 0xE1, 0xFA }
local CP437 = {}
for i, cp in ipairs(FONT_HIGH) do CP437[0x7F + i] = cp end
local function utf8(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end
function X.to_unicode(s)
    return (s:gsub("[\128-\255]", function(c) return utf8(CP437[c:byte()] or 0xFFFD) end))
end

-- ── Character animations ───────────────────────────────────────────────────
-- AnimationDecoder::decode_data (decode.cpp), a direct port of the original
-- 16-bit routine: the first 32 bytes give four 16-entry nibble tables, then a
-- bit stream of run-length coded nibbles. Returns a 0-based byte table.
local band, bor, bxor, lshift, rshift = bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift

function X.decode_anim(src, start)
    local dest = {}
    local function D(i) return dest[i] or 0 end
    local p = start + 1
    local function byte_at() local b = src:byte(p) or 0; p = p + 1; return b end
    for n = 0, 15 do
        local c = byte_at(); dest[n + 0x10] = c % 16; dest[n] = math.floor(c / 16)
        c = byte_at(); dest[n + 0x30] = c % 16; dest[n + 0x20] = math.floor(c / 16)
    end
    local pd = 0x40
    local cur = (src:byte(p) or 0) * 256 + (src:byte(p + 1) or 0); p = p + 2
    local bitCtr = 4
    dest[pd] = band(rshift(cur, 8), 0xF0)
    local tableOffset = rshift(cur, 12)
    cur = band(lshift(cur, 4), 0xFFFF)
    local dx, carry = 1, false
    local function rcl()
        local out = cur >= 0x8000
        cur = band(lshift(cur, 1), 0xFFFF) + (carry and 1 or 0)
        carry = out
    end
    local function step()
        rcl()
        bitCtr = (bitCtr - 1) % 0x10000
        if bitCtr == 0 then cur = band(cur, 0xFF00) + byte_at(); bitCtr = 8 end
    end
    local function decode2()
        dx = bor(band(dx, 0xFF), lshift(rshift(cur, 8), 8))
        for _ = 1, 8 do
            rcl()
            bitCtr = (bitCtr - 1) % 0x10000
            if bitCtr == 0 then
                if p > #src then cur = band(cur, 0xFF00) else cur = band(cur, 0xFF00) + byte_at() end
                bitCtr = 8
            end
        end
    end
    local loop, guard, tempReg1 = true, 0, 0
    while loop do
        guard = guard + 1
        if guard > 2000000 or pd > 0x80000 then return nil end
        while true do
            carry = false
            step()
            if not carry then tableOffset = D(tableOffset); break end
            step()
            if not carry then
                step()
                tableOffset = carry and D(tableOffset + 0x20) or D(tableOffset + 0x10)
                break
            end
            step()
            if not carry then tableOffset = D(tableOffset + 0x30); break end
            dx = bor(band(dx, 0xFF), lshift(rshift(cur, 12), 8))
            carry = false
            for _ = 1, 4 do step() end
            local high = rshift(dx, 8)
            if high == D(tableOffset) then
                tempReg1 = bitCtr
                local saved = dx
                decode2()
                dx = bor(band(dx, 0xFF00), rshift(dx, 8))
                decode2()
                bitCtr = bor(lshift(band(dx, 0xFF), 8), band(bitCtr, 0xFF))
                bitCtr = bor(band(bitCtr, 0xFF00), rshift(dx, 8))
                dx = saved
                if bitCtr == 0 then loop = false; break end
            elseif high == D(tableOffset + 0x10) then
                tempReg1 = bitCtr
                decode2()
                bitCtr = rshift(dx, 8)
            elseif high == D(tableOffset + 0x20) then
                dx = band(bor(band(dx, 0xFF), lshift(rshift(cur, 10), 8)), 0xFFFF)
                for _ = 1, 6 do step() end
                tempReg1 = bitCtr
                bitCtr = rshift(dx, 8)
            elseif high == D(tableOffset + 0x30) then
                dx = band(bor(band(dx, 0xFF), lshift(rshift(cur, 11), 8)), 0xFFFF)
                for _ = 1, 5 do step() end
                tempReg1 = bitCtr
                bitCtr = rshift(dx, 8)
            else
                tableOffset = band(rshift(dx, 8), 0xFF)
                break
            end
            if band(dx, 1) == 1 then
                dest[pd] = bor(D(pd), tableOffset); pd = pd + 1
                bitCtr = (bitCtr - 1) % 0x10000
                dx = band(dx, 0xFFFE)
            end
            dx = band(bor(band(dx, 0xFF), lshift(lshift(tableOffset, 4), 8)), 0xFFFF)
            tableOffset = band(bor(tableOffset, rshift(dx, 8)), 0xFF)
            for _ = 1, rshift(bitCtr, 1) do dest[pd] = tableOffset; pd = pd + 1 end
            bitCtr = band(bitCtr, 1)
            if bitCtr ~= 0 then dest[pd] = band(tableOffset, 0xF0); dx = bor(dx, 1) end
            bitCtr = tempReg1
            tableOffset = band(tableOffset, 0x0F)
        end
        if loop then
            dx = bxor(dx, 1)
            if band(dx, 1) ~= 0 then
                dx = band(bor(band(dx, 0xFF), lshift(lshift(tableOffset, 4), 8)), 0xFFFF)
                dest[pd] = rshift(dx, 8)
            else
                dest[pd] = bor(D(pd), tableOffset); pd = pd + 1
            end
        end
    end
    return dest, pd
end

-- Hotspot records (support 0x3F07, 62 bytes, ending with id 0xFFFF): name id at
-- +2, width/height at +24/+26, colour offset at +40, animation record id at +42.
function X.parse_hotspots(d)
    local out = {}
    if not d then return out end
    local p = 1
    while p + 61 <= #d and u16(d, p) ~= 0xFFFF do
        out[#out + 1] = { id = u16(d, p), name_id = u16(d, p + 2), room = u16(d, p + 14),
            width = u16(d, p + 24), height = u16(d, p + 26), color = u16(d, p + 40), anim = u16(d, p + 42) }
        p = p + 62
    end
    return out
end

-- Animation records (support 0x3F0B, 18 bytes): record id, disk resource, flags.
function X.parse_anims(d)
    local out = {}
    if not d then return out end
    local p = 1
    while p + 17 <= #d and u16(d, p) ~= 0xFFFF do
        out[u16(d, p)] = { anim_id = u16(d, p + 2), flags = u16(d, p + 4) }
        p = p + 18
    end
    return out
end

-- Hotspot::setAnimation: u16 frame count and per-frame sizes, the packed data
-- after them, then each frame as width x height nibbles plus the colour offset.
function X.anim_frames(src, width, height, color, flags)
    if not src or #src < 4 or width < 2 or height < 1 then return nil end
    local count = u16(src, 1)
    if count < 1 or count >= 100 then return nil end
    local dest = X.decode_anim(src, (count + 1) * 2 + 6)
    if not dest then return nil end
    local frames, ofs = {}, 0x40
    local p = 0x40
    for f = 0, count - 1 do
        if band(flags, 4) ~= 0 then p = ofs end
        local px = {}
        for i = 1, height * math.floor(width / 2) do
            local b = dest[p] or 0
            p = p + 1
            px[#px + 1] = color + math.floor(b / 16)
            px[#px + 1] = color + b % 16
        end
        frames[#frames + 1] = px
        if band(flags, 4) ~= 0 then ofs = ofs + rshift(u16(src, 3 + f * 2), 1) end
    end
    return frames, count
end

return X

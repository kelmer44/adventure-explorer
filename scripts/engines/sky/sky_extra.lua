-- Beneath a Steel Sky: sound effects, music, text and fonts.
-- References (ScummVM engines/sky): sound.cpp (Sound::loadSection, playSound),
-- music/musicbase.cpp + gmmusic.cpp + gmchannel.cpp (sequencer, 50 Hz polls),
-- text.cpp + hufftext.cpp (Text::getText, getTextChar, makeGameCharacter),
-- disk.cpp (determineGameVersion).
local Huff = require("sky_huff")
local X = {}

local function B(d, o) return d:byte(o + 1) or 0 end                 -- 0-based offsets
local function W(d, o) return B(d, o) + B(d, o + 1) * 256 end
local function WBE(d, o) return B(d, o) * 256 + B(d, o + 1) end

-- ── Game version (Disk::determineGameVersion) ─────────────────────────────
local VERSIONS = { [232] = 272, [243] = 109, [247] = 267, [1404] = 288, [1413] = 303,
    [1711] = 365, [5099] = 368, [5097] = 372 }
function X.game_version(dnr_entries, dsk_size)
    if dnr_entries == 1445 then return dsk_size == 8830435 and 348 or 331 end
    return VERSIONS[dnr_entries]
end

-- ── Sound effects: one driver file per section (60203 + 4 * section) ──────
-- Tables are big-endian: sample rate per sound (4 bytes), then 8-byte sfx info
-- entries (offset in 16-byte paragraphs from the sfx base, size, ..., loop).
function X.parse_sfx(data, version)
    local asm = version == 109 and 0x7C or 0x7E
    if #data < asm + 0x33 or B(data, asm) ~= 0x3C or B(data, asm + 0x27) ~= 0x8D
        or B(data, asm + 0x28) ~= 0x1E or B(data, asm + 0x2F) ~= 0x8D or B(data, asm + 0x30) ~= 0x36 then
        return nil
    end
    local total, rates, base = B(data, asm + 1), W(data, asm + 0x29), W(data, asm + 0x31)
    local sounds = {}
    for i = 0, total do
        local rate = math.min(WBE(data, rates + i * 4), 11025)
        local ofs = WBE(data, base + i * 8) * 16 + base
        local size = WBE(data, base + i * 8 + 2)
        if size > 0 and rate > 0 and ofs + size <= #data then
            sounds[#sounds + 1] = { index = i, rate = rate, offset = ofs, size = size }
        end
    end
    return sounds
end

-- ── Music: General MIDI / MT-32 sequencer data (60200 + 4 * section) ──────
local MT32_TO_GM = {
    0, 1, 0, 2, 4, 4, 5, 3, 16, 17, 18, 16, 16, 19, 20, 21, 6, 6, 6, 7, 7, 7, 8, 112, 62, 62, 63, 63, 38, 38, 39, 39,
    88, 95, 52, 98, 97, 99, 14, 54, 102, 96, 53, 102, 81, 100, 14, 80, 48, 48, 49, 45, 41, 40, 42, 42, 43, 46, 45, 24, 25, 28, 27, 104,
    32, 32, 34, 33, 36, 37, 35, 35, 79, 73, 72, 72, 74, 75, 64, 65, 66, 67, 71, 71, 68, 69, 70, 22, 56, 59, 57, 57, 60, 60, 58, 61,
    61, 11, 11, 98, 14, 9, 14, 13, 12, 107, 107, 77, 78, 78, 76, 76, 47, 117, 127, 118, 118, 116, 115, 119, 115, 112, 55, 124, 123, 0, 14, 117 }
local function velocity(v) -- GmMusic::_veloTab
    if v == 0 then return 0 end
    return math.min(0x7F, 0x40 + math.floor(v / 2))
end

local function music_loc(data, version)
    return W(data, version == 109 and 0x79B or 0x7DC)
end

function X.song_count(data, version)
    local loc = music_loc(data, version)
    return loc < #data and B(data, loc) or 0
end

local function be32(n) return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) end
local function vlq(n)
    local out = string.char(n % 128)
    n = math.floor(n / 128)
    while n > 0 do out = string.char(n % 128 + 128) .. out; n = math.floor(n / 128) end
    return out
end
local function track(events)
    table.sort(events, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[3] < b[3] end)
    local out, now = {}, 0
    for _, e in ipairs(events) do out[#out + 1] = vlq(e[1] - now) .. e[2]; now = e[1] end
    local body = table.concat(out) .. "\0\255\47\0"
    return "MTrk" .. be32(#body) .. body
end

-- One sequencer tick lasts 20 ms (50 Hz polls) divided by tempo0 * tempo1 / 3000
-- ticks per poll, i.e. 60,000,000 / (tempo0 * tempo1) microseconds. Written as a
-- format-1 file at 24 ticks per quarter note with one track per sequencer channel.
-- Channels end at their stop or loop command, so looping songs play once.
local PPQN = 24
local function tempo_meta(t0, t1)
    local mul = (t0 * t1) % 65536
    local us = mul > 0 and math.floor(PPQN * 60000000 / mul) or 500000
    us = math.max(1, math.min(0xFFFFFF, us))
    return "\255\81\3" .. be32(us):sub(2)
end

function X.song_to_midi(data, version, song)
    local loc = music_loc(data, version)
    if song < 1 or song > X.song_count(data, version) then return nil end
    local pos = W(data, W(data, loc + 1) + loc + (song - 1) * 2) + loc
    local t0, t1 = B(data, pos), B(data, pos + 1)
    local nch = B(data, pos + 2)
    local tempo = { { 0, tempo_meta(t0, t1), 0 } }
    local tracks, seq = {}, 0
    for c = 0, nch - 1 do
        local p = W(data, pos + 3 + c * 2) + loc
        local ev, ch, note, time, active = {}, 0, 0, 0, true
        local function next_time()
            local v, b = 0, 0
            for _ = 1, 4 do
                b = B(data, p); p = p + 1
                v = v * 128 + b % 128
                if b < 128 then break end
            end
            if b >= 128 then active = false; return 0 end
            return v
        end
        local function emit(...) seq = seq + 1; ev[#ev + 1] = { time, string.char(...), seq } end
        time = next_time()
        local guard = 0
        while active and p < #data and guard < 50000 do
            guard = guard + 1
            local op = B(data, p); p = p + 1
            if op >= 0x80 then
                if op == 0xFF then -- dummy
                elseif op >= 0x90 then
                    local sub = op % 16
                    if sub == 0 then emit(0x90 + ch, B(data, p) % 128, 0); p = p + 1
                    elseif sub == 2 then emit(0xC0 + ch, MT32_TO_GM[B(data, p) % 128 + 1]); p = p + 1
                    elseif sub == 3 then t1 = B(data, p); p = p + 1; seq = seq + 1; tempo[#tempo + 1] = { time, tempo_meta(t0, t1), seq }
                    elseif sub == 5 then emit(0xE0 + ch, 0, B(data, p) % 128); p = p + 1
                    elseif sub == 6 then emit(0xB0 + ch, 7, B(data, p) % 128); p = p + 1
                    elseif sub == 9 then emit(0x90 + ch, note, 0)
                    elseif sub == 11 then emit(0xB0 + ch, 10, B(data, p) % 128); p = p + 1
                    elseif sub == 12 then -- loop point
                    elseif sub == 13 then emit(0xB0 + ch, B(data, p) % 128, B(data, p + 1) % 128); p = p + 2
                    else active = false end -- 1 = stop, 8 = loop, others unknown
                else
                    ch = op % 16
                end
            else
                note = op
                emit(0x90 + ch, op, velocity(B(data, p) % 128)); p = p + 1
            end
            if active then time = time + next_time() end
        end
        -- release anything still sounding
        emit(0xB0 + ch, 123, 0)
        tracks[#tracks + 1] = track(ev)
    end
    return "MThd" .. be32(6) .. "\0\1" .. string.char(0, nch + 1, 0, PPQN) .. track(tempo) .. table.concat(tracks)
end

-- ── Text (60600 + 8 * language + section) ──────────────────────────────────
X.LANGUAGES = { [0] = "English (UK)", "German", "French", "English (US)", "Swedish", "Italian", "Portuguese", "Spanish" }

local function decode_message(data, tree, n)
    local block, msg = math.floor((n % 4096) / 32) * 32, n % 32
    local offset = 0
    for b = 0, block / 32 - 1 do offset = offset + W(data, 4 + b * 2) end
    local skip = block + W(data, 0)
    for m = 0, msg - 1 do
        local s = B(data, skip + m)
        if s >= 0x80 then s = (s % 0x80) * 8 end
        offset = offset + s
    end
    local bit = offset % 4
    local p = math.floor(offset / 4) + W(data, 2)
    bit = (3 - bit + 1) * 2 -- (bitPos ^ 3) + 1, then << 1
    local out = {}
    for _ = 1, 2000 do
        local node = 0
        repeat
            if bit > 0 then bit = bit - 1 else p = p + 1; bit = 7 end
            if p >= #data then return nil end
            local one = math.floor(B(data, p) / 2 ^ bit) % 2 == 1
            node = one and tree[node * 3 + 2] or tree[node * 3 + 1]
            if not node or not tree[node * 3 + 3] then return nil end -- not this table
        until tree[node * 3 + 1] == 0 and tree[node * 3 + 2] == 0
        local c = tree[node * 3 + 3]
        if c == 0 then return table.concat(out) end
        out[#out + 1] = string.char(c)
    end
    return nil
end

-- The game font replaces punctuation it never uses with accented letters and
-- adds more above 0x7F (glyphs of font 60150). Text is returned as UTF-8.
local CHARSET = {
    [0x23] = 0xFC, [0x28] = 0xDF, [0x29] = 0xF6, [0x2A] = 0xE4, [0x2B] = 0xE9, [0x2F] = 0xE7,
    [0x3C] = 0xE1, [0x3D] = 0xEA, [0x3E] = 0xFB, [0x40] = 0xF4, [0x5B] = 0xE2, [0x5C] = 0xFA,
    [0x5D] = 0xE8, [0x5E] = 0xC7, [0x5F] = 0xEE, [0x7B] = 0xEF, [0x7C] = 0xB4, [0x7D] = 0xDC,
    [0x7E] = 0xC4, [0x7F] = 0xD6, [0x80] = 0x3C, [0x81] = 0x3E, [0x82] = 0x2F, [0x83] = 0xC5,
    [0x84] = 0xC4, [0x85] = 0xE5, [0x86] = 0xC9, [0x87] = 0xED, [0x88] = 0xF3, [0x89] = 0xEB,
    [0x8A] = 0xBF, [0x8B] = 0xA1, [0x8C] = 0xD1, [0x8D] = 0xF1, [0x8E] = 0xEC, [0x8F] = 0xF2,
    [0x90] = 0xC1, [0x91] = 0xE0, [0x92] = 0xF9, [0x93] = 0xD3, [0x94] = 0xE6, [0x95] = 0xE3,
    [0x96] = 0xD5, [0x97] = 0xF5, [0x98] = 0xC3, [0x99] = 0xCA, [0x9A] = 0xDA, [0x9B] = 0x144,
    [0x9C] = 0x148,
}
local function utf8(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end
function X.to_unicode(text)
    return (text:gsub(".", function(c)
        local cp = CHARSET[c:byte()]
        if cp then return utf8(cp) end
        if c:byte() >= 0x80 then return utf8(0xFFFD) end
    end))
end

local function block_count(data)
    return math.min(math.floor((W(data, 0) - 4) / 2), math.floor((W(data, 2) - W(data, 0)) / 32))
end

-- Common words per language (index as X.LANGUAGES), used to pick the Huffman
-- table: releases can mix tables, e.g. the v0.0331 floppy stores English with
-- the 0331 table and the other languages with the 0348 one. Wrong tables keep
-- the message lengths but swap rare letters ("keine" -> "weine").
local COMMON = {
    [0] = "the you is to of and it what that this have know work who are doing here",
    [1] = "und der die das ist nicht ich du wer was wie es ein eine sie wir kann keine weiß für hier",
    [2] = "le la les de des et je tu vous est pas un une que qui ce ici êtes c'est où",
    [3] = "the you is to of and it what that this have know work who are doing here",
    [4] = "och det att jag du en inte som vad har vi kan är här vem gör för på så också då",
    [5] = "il la di che non un una per sono io tu mi ti è qui perché chi",
    [6] = "o a de que um uma eu para com se me te não você está aqui quem sou",
    [7] = "que de el la no es un una por con lo me se te yo qué aquí está quién trabajo",
}
local function score(data, tree, section, language)
    local words = {}
    for w in (COMMON[language] or COMMON[0]):gmatch("%S+") do words[w] = true end
    local hits, n = 0, 0
    for b = 0, block_count(data) - 1 do
        for m = 0, 31 do
            local text = decode_message(data, tree, section * 4096 + b * 32 + m)
            if text then
                for w in X.to_unicode(text):lower():gmatch("[^%s%p%d]+") do if words[w] then hits = hits + 1 end end
            end
            n = n + 1
            if n >= 160 then return hits end
        end
    end
    return hits
end

-- Pick one table for a whole language from all of its section files
-- ({ [section] = data }). Ties keep the release's own table, then the closest
-- version, so the choice is deterministic.
function X.pick_tree(sections, version, language)
    local order = {}
    for v in pairs(Huff) do order[#order + 1] = v end
    table.sort(order, function(a, b)
        if a == version or b == version then return a == version end
        return math.abs(a - (version or 0)) < math.abs(b - (version or 0))
    end)
    local best, best_score = nil, -1
    for _, v in ipairs(order) do
        local total = 0
        for section, data in pairs(sections) do total = total + score(data, Huff[v], section, language) end
        if total > best_score then best, best_score = v, total end
    end
    return best
end

-- All messages of one text file, as { number, text } pairs. Message numbers
-- are (section << 12) | (block << 5) | index, as the game scripts use them.
function X.decode_text_section(data, used, section)
    if #data < 8 then return nil end
    local tree = Huff[used]
    if not tree then return nil end
    local messages = {}
    for b = 0, block_count(data) - 1 do
        for m = 0, 31 do
            local n = section * 4096 + b * 32 + m
            local text = decode_message(data, tree, n)
            if text then messages[#messages + 1] = { number = n, text = X.to_unicode(text) } end
        end
    end
    -- the last block is padded with empty or runaway entries
    while #messages > 0 and messages[#messages].text == "" do messages[#messages] = nil end
    return messages, used
end

-- ── Fonts (60150 main, 60520 control, 60521 link): 128 width bytes, then
-- per glyph `height` rows of big-endian (data, mask) words. Mask-only pixels
-- are the black outline (colour 240 in game).
function X.render_font(data, height)
    local glyphs = math.min(128, math.floor((#data - 128) / (height * 4)))
    if glyphs <= 0 then return nil end
    local cols, cw = 16, 16
    local rows = math.ceil(glyphs / cols)
    local w, h = cols * (cw + 2), rows * (height + 2)
    local px = {}
    for i = 1, w * h do px[i] = 0 end
    for g = 0, glyphs - 1 do
        local width = math.min(cw, B(data, g) + 1)
        local gx, gy = (g % cols) * (cw + 2) + 1, math.floor(g / cols) * (height + 2) + 1
        local src = 128 + g * height * 4
        for y = 0, height - 1 do
            local bits, mask = WBE(data, src + y * 4), WBE(data, src + y * 4 + 2)
            for x = 0, width - 1 do
                local bitv = 2 ^ (15 - x)
                if math.floor(mask / bitv) % 2 == 1 then
                    px[(gy + y) * w + gx + x + 1] = math.floor(bits / bitv) % 2 == 1 and 1 or 2
                end
            end
        end
    end
    local pal = { 32, 32, 48, 255, 255, 255, 0, 0, 0 }
    for i = #pal + 1, 768 do pal[i] = 0 end
    return image_create_indexed(w, h, px, pal), w, h, glyphs
end

return X

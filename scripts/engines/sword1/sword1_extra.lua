-- Broken Sword 1: text, speech and music.
-- References (ScummVM engines/sword1): objectman.cpp (ObjectMan::lockText,
-- _textList in staticres.cpp), sound.cpp (initCowSystem, startSpeech,
-- expandSpeech), music.cpp (track files in MUSIC/).
local X = {}

local function u32(d, p) local a, b, c, e = d:byte(p, p + 3); return a + b * 256 + c * 65536 + e * 16777216 end

-- Text cluster groups are languages (resource ids 0x03LL00SS in swordres.h).
X.LANGUAGES = { [0] = "English", "French", "German", "Italian", "Spanish", "Czech", "Portuguese" }

local function utf8_latin1(s)
    return (s:gsub("[\128-\255]", function(c)
        local b = c:byte()
        return string.char(0xC0 + math.floor(b / 64), 0x80 + b % 64)
    end))
end

-- Text resource: 20-byte header, u32 count, u32 offsets (relative to the end of
-- the header, entry n at (n + 1) * 4), zero-terminated strings. Text ids are
-- section * 0x10000 + n. Strings use the game's Latin-1 based font encoding.
function X.parse_text(data, section)
    if not data or #data < 24 then return nil end
    local base = 21
    local count = u32(data, base)
    if count > 0x4000 then return nil end
    local lines = {}
    for n = 0, count - 1 do
        local off = u32(data, base + (n + 1) * 4)
        if off > 0 and base + off <= #data then
            local s = data:match("^[^%z]*", base + off)
            if s and s ~= "" then
                lines[#lines + 1] = string.format("%d  %s", section * 0x10000 + n, utf8_latin1(s))
            end
        end
    end
    return lines, count
end

-- Speech clusters SPEECHn.CL3 (MP3, from ScummVM's compression tool): u32 header
-- size, then u32 words. Words 0..rooms-1 give each room's byte offset into the
-- header; line k (from 1) of a room has its absolute file offset at word
-- loc + 2k - 1 and its size at word loc + 2k.
function X.parse_cow(head)
    local size = u32(head, 1)
    if size < 8 or size % 4 ~= 0 or #head < size then return nil end
    local words = {}
    for i = 0, size / 4 - 2 do words[i] = u32(head, 5 + i * 4) end
    local nwords = size / 4 - 1
    local first = nwords
    local i = 0
    while i < first do
        local loc = math.floor(words[i] / 4)
        if words[i] > 0 and loc < first then first = loc end
        i = i + 1
    end
    local rooms = {}
    for r = 0, first - 1 do
        if words[r] > 0 then rooms[#rooms + 1] = { room = r, loc = math.floor(words[r] / 4) } end
    end
    table.sort(rooms, function(a, b) return a.loc < b.loc end)
    for n, r in ipairs(rooms) do
        local next_loc = rooms[n + 1] and rooms[n + 1].loc or nwords
        r.lines = {}
        for k = 1, math.floor((next_loc - r.loc) / 2) do
            local off, len = words[r.loc + 2 * k - 1], words[r.loc + 2 * k]
            if off and len and len > 0 and len < 0x1000000 then r.lines[#r.lines + 1] = { line = k, offset = off, size = len } end
        end
    end
    table.sort(rooms, function(a, b) return a.room < b.room end)
    return rooms, size
end

return X

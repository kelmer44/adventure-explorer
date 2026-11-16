-- Atlantis: The Lost Tales / Atlantis: Les Terres Perdues (Cryo Interactive, 1997).
--
-- Licence: the HNM6 warp decoder (host function image_create_cryo_hnm6) and the APC decoder
-- (sound_create_cryo_apc) are ported from ScummVM, engines/cryomni3d and image/codecs/hnm.cpp,
-- audio/decoders/apc.cpp (GPL-2.0-or-later, the ScummVM Team). The BigFile container was
-- reverse engineered from BIGCD1.BIG; ScummVM does not support Atlantis.
--
-- BIGCDn.BIG ("BigFile 1.00"), all little-endian:
--   0x00 char[16]  "BigFile 1.00" + zero padding
--   0x10 u32       number of files
--   0x14 u32       length of the data area
--   0x18 u32       length of everything before the data area (header + table), so the data
--                  area starts at this offset (and the table ends there)
--   0x1C u32       0
--   0x20 records, back to back, one per file:
--        u32 nameLen (including the NUL)   u32 (memory pointer, ignore)
--        u32 size  u32 size  u32 size      u32 0
--        u32 offset into the data area     u32 (memory pointer, ignore)
--        char name[nameLen]                backslash separated, e.g. CYCLO\ATL16001.HNM
--   Files are stored contiguously in table order, uncompressed.
--
-- Contents of disc 1: CYCLO\*.HNM (377 panoramas: 2048x768 HNM6 "warp" images, the 360 degree
-- view of every node), WAV\*.APC (Cryo APC ADPCM: music, ambience, dialogue, effects),
-- WAV\*.SYC (lip-sync tables), UBB_VUE\*.HNM and DIALOG\*.UBB (videos), SPRITE\* and
-- DIALOG\*.SPF (sprites), WAM\*.WAM (node graphs and hotspots), SCENAR\*.CON (scripts),
-- IMAGES\*.TGA and PUZZLES\*.TGA (640x480 15-bit Targa).
local engine = {id = "atlantis_tlt", name = "Atlantis: The Lost Tales", version = "1.0",
    description = "Atlantis: The Lost Tales / Les Terres Perdues (1997, Cryo Interactive)"}

local MAX_FILES = 20000
local MAX_TOC = 4 * 1024 * 1024

local function u32(s, p)
    local a, b, c, d = s:byte(p, p + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u16(s, p)
    local a, b = s:byte(p, p + 1)
    return a + b * 256
end

local function resolve_ci(dir, pattern)
    local found = {}
    for _, n in ipairs(list_files(dir) or {}) do
        if n:upper():match(pattern) then found[#found + 1] = n end
    end
    table.sort(found)
    return found
end

local archive_cache = {}

--- Parses one BigFile table. Returns {path, base, entries = {{name, size, offset}...}} or nil.
local function open_archive(game_path, file_name)
    local path = game_path .. "/" .. file_name
    if archive_cache[path] then return archive_cache[path] end
    local f = file_open(path)
    if not f then return nil end
    local total = file_size(f)
    local head = file_read(f, 0, 32)
    if not head or #head < 32 or head:sub(1, 12) ~= "BigFile 1.00" then
        file_close(f)
        return nil
    end
    local count, data_len, base = u32(head, 17), u32(head, 21), u32(head, 25)
    if count > MAX_FILES or base < 32 or base > MAX_TOC or data_len + base ~= total then
        file_close(f)
        log_warn("atlantis_tlt: inconsistent BigFile header in " .. file_name)
        return nil
    end
    local toc = file_read(f, 0, base)
    file_close(f)
    if not toc or #toc ~= base then return nil end
    local entries = {}
    local pos = 33
    for i = 1, count do
        if pos + 32 > #toc then break end
        local name_len = u32(toc, pos)
        local size, offset = u32(toc, pos + 8), u32(toc, pos + 24)
        if name_len < 2 or name_len > 260 or pos + 32 + name_len > #toc + 1 or offset + size > data_len then
            log_warn("atlantis_tlt: bad table record " .. i .. " in " .. file_name)
            break
        end
        entries[i] = {name = toc:sub(pos + 32, pos + 30 + name_len), size = size, offset = offset}
        pos = pos + 32 + name_len
    end
    local arc = {path = path, base = base, entries = entries}
    archive_cache[path] = arc
    return arc
end

local function read_entry(arc, entry)
    local f = file_open(arc.path)
    if not f then return nil end
    local d = file_read(f, arc.base + entry.offset, entry.size)
    file_close(f)
    if not d or #d ~= entry.size then return nil end
    return d
end

local function archives(game_path)
    local out = {}
    for _, n in ipairs(resolve_ci(game_path, "^BIGCD%d+%.BIG$")) do
        local arc = open_archive(game_path, n)
        if arc then out[#out + 1] = {disc = tonumber(n:match("%d+")), arc = arc} end
    end
    return out
end

local function base_name(name)
    return (name:match("([^\\]+)$") or name)
end

local function stem(name)
    return (base_name(name):gsub("%.[^.]*$", ""))
end

function engine.detect(game_path)
    for _, n in ipairs(resolve_ci(game_path, "^BIGCD%d+%.BIG$")) do
        local f = file_open(game_path .. "/" .. n)
        if f then
            local head = file_read(f, 0, 12)
            file_close(f)
            if head == "BigFile 1.00" then return true end
        end
    end
    return false
end

local function audio_group(entry)
    local s = stem(entry.name):upper()
    if entry.size >= 800000 then return "music" end
    if s:match("^ATA%d") then return "dialogue" end
    if s:match("^CIN") or s:match("^FLI") then return "cinematic" end
    return "effects"
end

local GROUPS = {
    {id = "music", name = "Music and ambience"},
    {id = "dialogue", name = "Dialogue"},
    {id = "cinematic", name = "Cinematic sounds"},
    {id = "effects", name = "Sound effects"},
}

function engine.get_resources(game_path)
    local panoramas, images = {}, {}
    local audio = {}
    for _, g in ipairs(GROUPS) do audio[g.id] = {} end
    local multi = false
    local arcs = archives(game_path)
    if #arcs > 1 then multi = true end
    for _, a in ipairs(arcs) do
        local prefix = multi and string.format("CD%d ", a.disc) or ""
        for i, e in ipairs(a.arc.entries) do
            local up = e.name:upper()
            local id = string.format("%d:%d", a.disc, i)
            if up:match("^CYCLO\\.*%.HNM$") then
                panoramas[#panoramas + 1] = {id = "pan:" .. id, name = prefix .. stem(e.name), type = "image"}
            elseif up:match("^WAV\\.*%.APC$") then
                local g = audio_group(e)
                local list = audio[g]
                list[#list + 1] = {id = "apc:" .. id, name = prefix .. stem(e.name), type = "sound"}
            elseif up:match("%.TGA$") and (up:match("^IMAGES\\") or up:match("^PUZZLES\\")) then
                images[#images + 1] = {id = "tga:" .. id, name = prefix .. stem(e.name), type = "image"}
            end
        end
    end
    local tree = {}
    if #panoramas > 0 then
        tree[#tree + 1] = {id = "panoramas", name = "Panoramas (360 degree)", type = "category", children = panoramas}
    end
    local sounds = {}
    for _, g in ipairs(GROUPS) do
        if #audio[g.id] > 0 then
            sounds[#sounds + 1] = {id = "audio_" .. g.id, name = g.name, type = "category", children = audio[g.id]}
        end
    end
    if #sounds > 0 then
        tree[#tree + 1] = {id = "audio", name = "Audio", type = "category", children = sounds}
    end
    if #images > 0 then
        tree[#tree + 1] = {id = "images", name = "Images", type = "category", children = images}
    end
    return tree
end

--- Uncompressed 15/16-bit Targa (the only variant on the disc).
local function decode_tga(d)
    if #d < 18 then return nil, "short file" end
    local kind, bpp, desc = d:byte(3), d:byte(17), d:byte(18)
    local w, h = u16(d, 13), u16(d, 15)
    if kind ~= 2 or (bpp ~= 15 and bpp ~= 16) or w == 0 or h == 0 or w * h > 4194304 then
        return nil, string.format("unsupported Targa type %d, %d bpp, %dx%d", kind, bpp, w, h)
    end
    local start = 19 + d:byte(1)
    if start + w * h * 2 - 1 > #d then return nil, "truncated Targa" end
    local top_down = math.floor(desc / 32) % 2 == 1
    local px = {}
    local n = 0
    local floor = math.floor
    for y = 0, h - 1 do
        local row = top_down and y or (h - 1 - y)
        local p = start + row * w * 2
        for x = 0, w - 1 do
            local v = d:byte(p + x * 2) + d:byte(p + x * 2 + 1) * 256
            local r, g, b = floor(v / 1024) % 32, floor(v / 32) % 32, v % 32
            px[n + 1] = r * 8 + floor(r / 4)
            px[n + 2] = g * 8 + floor(g / 4)
            px[n + 3] = b * 8 + floor(b / 4)
            n = n + 3
        end
    end
    return image_create_rgb(w, h, px), w, h
end

local function find_entry(game_path, id)
    local kind, disc, index = id:match("^(%a+):(%d+):(%d+)$")
    if not kind then return nil end
    for _, a in ipairs(archives(game_path)) do
        if a.disc == tonumber(disc) then
            local e = a.arc.entries[tonumber(index)]
            if e then return kind, a.arc, e end
        end
    end
end

function engine.load_resource(game_path, resource_id)
    local kind, arc, entry = find_entry(game_path, resource_id)
    if not kind then return {type = "text", text = "Unknown resource " .. tostring(resource_id)} end
    local data = read_entry(arc, entry)
    if not data then return {type = "text", text = "Could not read " .. entry.name} end
    local title = stem(entry.name)
    if kind == "pan" then
        local img = image_create_cryo_hnm6(data)
        if not img then return {type = "text", text = title .. ": not a decodable HNM6 warp image"} end
        return {type = "image", image = img,
            description = title .. ": 360 degree warp panorama, 2048x768 (full turn horizontally)"}
    elseif kind == "apc" then
        local snd = sound_create_cryo_apc(data)
        if not snd then return {type = "text", text = title .. ": not a valid APC file"} end
        return {type = "sound", sound = snd, description = title .. " (Cryo APC, " .. #data .. " bytes)"}
    elseif kind == "tga" then
        local img, w, h = decode_tga(data)
        if not img then return {type = "text", text = title .. ": " .. tostring(w)} end
        return {type = "image", image = img, description = string.format("%s: %dx%d, 15-bit Targa", title, w, h)}
    end
    return {type = "text", text = "Unsupported resource " .. resource_id}
end

return engine

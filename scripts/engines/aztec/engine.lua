-- Aztec: The Curse in the Heart of the City of Gold / Azteca: La Maldicion del Corazon de la Ciudad
-- de Oro (Cryo Interactive, 1999).
--
-- Licence: the APC decoder (host function sound_create_cryo_apc) is ported from ScummVM,
-- audio/decoders/apc.cpp (GPL-2.0-or-later, the ScummVM Team). ScummVM's cryomni3d engine covers
-- Versailles 1685 only; the Aztec panorama format below was recovered from the data.
--
-- <disc>/Data is the game folder (Aztec.CD marks it). Useful subfolders:
--   Warp/*.JP6    198 panoramas. "JPEG6   CRYO99XG", u32le size[8] (six used), then six 512x512
--                 JPEG cube faces back to back from byte 48. Faces 0,5,1,4 are the walls left to
--                 right, 2 the sky, 3 the floor (see CryoJp6.kt for how the order was derived).
--   music/*.APC   81 music tracks      Sound/*.APC  50 effects     dialog/*.APC  694 voice lines
--   Special/*/    puzzle assets: .SPR sprites, .WAV/.APC sounds, bg.jpg backgrounds
--   doczone/*.JPG 146 encyclopedia pictures        Spr/*.jpg  interface backgrounds
--   fmv/*.hnm     videos (HNM4 with APC audio, not decoded)       game/*  scripts and tables
--   file/File.*   four 640 MiB padding files (no game data)
--   game/*        plain Latin-1 text with CRLF lines: Aztec.dlg (voice-line subtitles, "[HR058_01]"
--                 sections named after dialog/hr058_01.APC), aztec.msg (interface), aztec.dei and
--                 aztec.dem (encyclopedia index and entries), aztec.min (diary), Aztec.leg,
--                 Aztec.crd/cr0 (credits), plus .def/.var/.scp/.mus/.amb data. Aztec.scp and the
--                 .wa2 warp tables are binary and not listed.
-- Not decoded: .SPR/.SPW/.SPZ sprites, .crf fonts, .hnm videos and the binary game data.
local engine = {id = "aztec", name = "Aztec: The Curse in the Heart of the City of Gold", version = "1.0",
    description = "Aztec: The Curse in the Heart of the City of Gold (1999, Cryo Interactive)"}

local function sorted_names(dir)
    local names = {}
    for _, n in ipairs(list_files(dir) or {}) do names[#names + 1] = n end
    table.sort(names, function(a, b) return a:upper() < b:upper() end)
    return names
end

--- Finds <game_path>/Data (any case) or accepts game_path when it already is the Data folder.
local function data_root(game_path)
    for _, n in ipairs(list_files(game_path) or {}) do
        if n:upper() == "DATA" then
            local root = game_path .. "/" .. n
            if #sorted_names(root) > 0 then return root end
        end
    end
    return game_path
end

local function subdir(root, name)
    for _, n in ipairs(list_files(root) or {}) do
        if n:upper() == name:upper() then return root .. "/" .. n, n end
    end
end

local function has_extension(names, ext)
    for _, n in ipairs(names) do
        if n:upper():match("%." .. ext .. "$") then return true end
    end
    return false
end

function engine.detect(game_path)
    local root = data_root(game_path)
    local warp = subdir(root, "Warp")
    if not warp or not has_extension(sorted_names(warp), "JP6") then return false end
    for _, n in ipairs(list_files(root) or {}) do
        if n:upper() == "AZTEC.CD" then return true end
    end
    local game = subdir(root, "game")
    return game ~= nil and has_extension(sorted_names(game), "SCP")
end

-- Windows-1252 0x80-0x9F that differ from Latin-1 (punctuation); the rest of 0x80-0xFF maps 1:1.
local CP1252 = {[0x80] = 0x20AC, [0x85] = 0x2026, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C,
    [0x94] = 0x201D, [0x96] = 0x2013, [0x97] = 0x2014}

local function utf8_char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

--- The text files are Windows-1252; LuaJ hands strings to the UI as UTF-8.
local function to_utf8(text)
    return (text:gsub("[\128-\255]", function(c)
        local b = c:byte()
        return utf8_char(CP1252[b] or b)
    end):gsub("\r\n", "\n"))
end

-- Text files in Data/game, in listing order: file name, title.
local TEXT_FILES = {
    {"Aztec.dlg", "Dialogue subtitles"}, {"aztec.msg", "Interface messages"},
    {"aztec.dem", "Encyclopedia entries"}, {"aztec.dei", "Encyclopedia index"},
    {"aztec.min", "Diary"}, {"Aztec.leg", "Zones and legends"},
    {"Aztec.crd", "Credits"}, {"Aztec.cr0", "Credits (short)"},
    {"Aztec.def", "Definitions (characters, objects, variables)"}, {"Aztec.var", "Variables"},
    {"AztecDlg.scp", "Dialogue script"}, {"Visit.scp", "Visit script"}, {"Visit.var", "Visit variables"},
    {"Aztec.mus", "Music table"}, {"Aztec.amb", "Ambience table"},
}

local function stem(name)
    return (name:gsub("%.[^.]*$", ""))
end

local function add_files(list, id_prefix, folder_name, dir, extensions, kind, label)
    for _, n in ipairs(sorted_names(dir)) do
        local ext = n:match("%.([^.]+)$")
        if ext and extensions[ext:upper()] then
            list[#list + 1] = {
                id = string.format("%s:%s/%s", id_prefix, folder_name, n),
                name = (label or "") .. stem(n), type = kind,
            }
        end
    end
end

function engine.get_resources(game_path)
    local root = data_root(game_path)
    local tree = {}
    local function category(id, name, children)
        if #children > 0 then tree[#tree + 1] = {id = id, name = name, type = "category", children = children} end
    end

    local pan, nets = {}, {}
    local warp, warp_name = subdir(root, "Warp")
    if warp then
        add_files(pan, "pan", warp_name, warp, {JP6 = true}, "image")
        add_files(nets, "net", warp_name, warp, {JP6 = true}, "image")
    end
    category("panoramas", "Panoramas (360 degree)", pan)
    category("nets", "Panorama cube faces", nets)

    local audio_ext = {APC = true, WAV = true}
    local music, effects, dialogue = {}, {}, {}
    local dir, name = subdir(root, "music")
    if dir then add_files(music, "snd", name, dir, audio_ext, "sound") end
    dir, name = subdir(root, "Sound")
    if dir then add_files(effects, "snd", name, dir, audio_ext, "sound") end
    dir, name = subdir(root, "dialog")
    if dir then add_files(dialogue, "snd", name, dir, audio_ext, "sound") end
    local special, special_name = subdir(root, "Special")
    local pictures = {}
    if special then
        for _, sub in ipairs(sorted_names(special)) do
            local sub_dir = special .. "/" .. sub
            local entries = list_files(sub_dir)
            if entries and #entries > 0 then
                local folder = special_name .. "/" .. sub
                add_files(effects, "snd", folder, sub_dir, audio_ext, "sound", sub .. " ")
                add_files(pictures, "img", folder, sub_dir, {JPG = true}, "image", sub .. " ")
            end
        end
    end
    category("music", "Music", music)
    category("effects", "Sound effects", effects)
    category("dialogue", "Dialogue", dialogue)

    local docs = {}
    dir, name = subdir(root, "doczone")
    if dir then add_files(docs, "img", name, dir, {JPG = true}, "image") end
    category("documentation", "Documentation pictures", docs)

    local texts = {}
    local game, game_name = subdir(root, "game")
    if game then
        local present = {}
        for _, n in ipairs(list_files(game) or {}) do present[n:upper()] = n end
        for _, t in ipairs(TEXT_FILES) do
            local real = present[t[1]:upper()]
            if real then
                texts[#texts + 1] = {id = string.format("txt:%s/%s", game_name, real), name = t[2], type = "text"}
            end
        end
    end
    category("text", "Text", texts)
    dir, name = subdir(root, "Spr")
    if dir then add_files(pictures, "img", name, dir, {JPG = true}, "image") end
    category("backgrounds", "Backgrounds and puzzle pictures", pictures)
    return tree
end

local function read_whole(path)
    local f = file_open(path)
    if not f then return nil end
    local d = file_read(f, 0, file_size(f))
    file_close(f)
    return d
end

--- Subtitle for a dialog/<name>.APC voice line from the [NAME] section of Aztec.dlg, or nil.
local function subtitle(root, name)
    local game = subdir(root, "game")
    if not game then return nil end
    for _, n in ipairs(list_files(game) or {}) do
        if n:upper() == "AZTEC.DLG" then
            local data = read_whole(game .. "/" .. n)
            if not data then return nil end
            -- Do not lower-case the file: LuaJ re-encodes high bytes, which would shift every offset.
            local pattern = "%[" .. name:gsub("%w", function(c) return "[" .. c:lower() .. c:upper() .. "]" end) .. "%]"
            local _, header_end = data:find(pattern)
            if not header_end then return nil end
            local body_end = data:find("\n%[", header_end + 1) or (#data + 1)
            local body = data:sub(header_end + 1, body_end - 1):gsub("^%s+", ""):gsub("%s+$", "")
            return to_utf8(body)
        end
    end
end

function engine.load_resource(game_path, resource_id)
    local kind, rel = resource_id:match("^(%a+):(.+)$")
    if not kind or rel:find("%.%.") then return {type = "text", text = "Unknown resource " .. tostring(resource_id)} end
    local data = read_whole(data_root(game_path) .. "/" .. rel)
    if not data then return {type = "text", text = "Could not read " .. rel} end
    local title = stem(rel:match("([^/]+)$"))
    if kind == "pan" or kind == "net" then
        local img = image_create_cryo_jp6(data, kind == "pan" and "panorama" or "net")
        if not img then return {type = "text", text = title .. ": not a valid JP6 cube-map panorama"} end
        local text = kind == "pan"
            and title .. ": 360 degree panorama (cube map projected to 2048x1024 equirectangular; centre = front wall)"
            or title .. ": six 512x512 cube faces, sky above and floor below the front wall"
        return {type = "image", image = img, description = text}
    elseif kind == "txt" then
        return {type = "text", text = to_utf8(data), description = title}
    elseif kind == "snd" then
        local snd
        if data:sub(1, 12) == "CRYO_APC1.20" then snd = sound_create_cryo_apc(data) else snd = sound_create_encoded(data) end
        if not snd then return {type = "text", text = title .. ": unsupported audio data"} end
        local text = title .. " (" .. #data .. " bytes)"
        if rel:upper():match("^DIALOG/") then
            local line = subtitle(data_root(game_path), title)
            if line then text = text .. "\n" .. line end
        end
        return {type = "sound", sound = snd, description = text}
    elseif kind == "img" then
        local img = image_load_png(data)
        if not img then return {type = "text", text = title .. ": not a readable JPEG"} end
        return {type = "image", image = img, description = title}
    end
    return {type = "text", text = "Unsupported resource " .. resource_id}
end

return engine

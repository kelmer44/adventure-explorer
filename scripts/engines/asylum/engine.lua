-- Sanitarium / Asylum (1998, DreamForge). Windows demo and retail CD data.
-- References: ScummVM asylum/respack.cpp, system/graphics.cpp, system/screen.cpp,
-- system/sound.cpp and resources/worldstats.cpp. All file offsets below are zero-based.
local engine = { name = "Sanitarium", id = "asylum", version = "1.0",
    description = "Sanitarium (1998, DreamForge; Asylum resource packs)" }
local MAX_RESOURCE = 64 * 1024 * 1024
local MAX_PIXELS = 16 * 1024 * 1024
local MAX_ANIMATION = 32 * 1024 * 1024
local cache

local function u16(d, p)
    if p < 1 or p + 1 > #d then return nil end
    return d:byte(p) + d:byte(p + 1) * 256
end
local function u32(d, p)
    if p < 1 or p + 3 > #d then return nil end
    return u16(d, p) + u16(d, p + 2) * 65536
end
local function i16(d, p)
    local n = u16(d, p)
    return n and (n < 32768 and n or n - 65536)
end
local function read_slice(path, offset, size)
    if offset < 0 or size < 0 or size > MAX_RESOURCE then return nil end
    local f = file_open(path)
    if not f then return nil end
    local data
    if offset + size <= file_size(f) then data = size == 0 and "" or file_read(f, offset, size) end
    file_close(f)
    if not data or #data ~= size then return nil end
    return data
end

-- ScummVM respack.cpp repairs these lengths in the exact 299872422-byte
-- combined GOG/Steam shared-speech pack. Apply only to the matching disc/file.
local COMBINED_SPEECH = {
    [1] = { [0x2B0]=40146626, [0x72D]=7349518, [0x73B]=5534658, [0x745]=4333670, [0x76E]=1122128, [0x786]=755152, [0x93D]=383318, [0x97F]=52574 },
    [2] = { [0x71D]=40501676, [0x733]=40367314, [0x73C]=40347616, [0x746]=40214368, [0x74C]=40072902, [0x75E]=39099030, [0x781]=36131104, [0x783]=36119940, [0x8B9]=18430980, [0x968]=3920338, [0x97D]=524576, [0x983]=289832 },
    [3] = { [0x3EB]=18177962, [0x74A]=17247084, [0x756]=15741212, [0x782]=15468752, [0x93A]=6679208, [0x942]=4502532, [0x970]=654212 },
}

local function directory(path)
    local f = file_open(path)
    if not f then return nil end
    local size, head = file_size(f), file_read(f, 0, 4)
    local count = head and u32(head, 1)
    if not count or count < 1 or count > 65536 or 4 + count * 4 > size then file_close(f); return nil end
    local table_data = file_read(f, 4, count * 4)
    file_close(f)
    if not table_data or #table_data ~= count * 4 then return nil end
    local disc = size == 299872422 and tonumber(path:upper():match("RES%.([123])04$"))
    local patches = disc and COMBINED_SPEECH[disc]
    local entries = {}
    for i = 0, count - 1 do
        local offset = u32(table_data, i * 4 + 1)
        local stop = i + 1 < count and u32(table_data, i * 4 + 5) or size
        -- Zero offsets denote absent resources. Never read them as archive headers.
        if offset ~= 0 and (offset < 4 + count * 4 or offset > size) then return nil end
        if stop == 0 then stop = size end
        if patches and patches[i] and offset > 0 then stop = offset + patches[i] end
        if offset > 0 and (stop < offset or stop > size) then return nil end
        if offset > 0 and stop >= offset and stop <= size then
            entries[#entries + 1] = { index = i, offset = offset, size = stop - offset }
        end
    end
    return entries, count, size
end

local function palette_data(data)
    if #data < 28 or data:sub(1, 4) ~= "D3GR" or math.floor(data:byte(6) / 32) % 2 ~= 1 then return nil end
    local offset = u32(data, 13)
    if not offset or offset < 28 or offset + 4 > #data then return nil end
    local count, start = u16(data, offset + 1), data:byte(offset + 3)
    if count < 1 or start + count > 256 or offset + 4 + count * 3 > #data then return nil end
    local pal = {}; for i = 1, 768 do pal[i] = 0 end
    for i = 0, count * 3 - 1 do
        local value = data:byte(offset + 5 + i)
        if value > 63 then return nil end
        pal[start * 3 + i + 1] = value * 4
    end
    return pal, count, start
end

local function graphic_header(data, size)
    if #data < 28 or data:sub(1, 4) ~= "D3GR" then return nil end
    local count, content = u16(data, 25), u32(data, 9)
    if math.floor(data:byte(6) / 32) % 2 == 1 or count < 1 or count > 4096
        or #data < 28 + count * 4 then return nil end
    local frames = {}
    for i = 0, count - 1 do
        local offset = content + u32(data, 29 + i * 4)
        local stop = i + 1 < count and content + u32(data, 33 + i * 4) or size
        if offset < 28 + count * 4 or stop < offset + 16 or stop > size then return nil end
        frames[#frames + 1] = { index = i, offset = offset, stop = stop }
    end
    return frames
end
local function frame_header(data, frame)
    if #data < 16 then return false end
    local w, h = u16(data, 15), u16(data, 13)
    if w > 8192 or h > 8192 or w * h > MAX_PIXELS or frame.offset + 16 + w * h > frame.stop then return false end
    frame.x, frame.y, frame.width, frame.height = i16(data, 9), i16(data, 11), w, h
    return true
end
local function animation_bounds(frames)
    local left, top, right, bottom
    for _, f in ipairs(frames) do
        if f.width > 0 and f.height > 0 then
            left = left and math.min(left, f.x) or f.x
            top = top and math.min(top, f.y) or f.y
            right = right and math.max(right, f.x + f.width) or f.x + f.width
            bottom = bottom and math.max(bottom, f.y + f.height) or f.y + f.height
        end
    end
    if not left then return nil end
    local w, h = right - left, bottom - top
    if w > 8192 or h > 8192 or w * h * #frames > MAX_ANIMATION then return nil end
    return { x = left, y = top, width = w, height = h }
end
local function mask_header(data, size)
    if #data < 8 then return nil end
    local h, w = u32(data, 1), u32(data, 5)
    -- The original files include a four-byte trailer. Bits are LSB first.
    if w < 8 or w > 8192 or w % 8 ~= 0 or h < 1 or h > 8192 or w * h > MAX_PIXELS
        or size ~= 12 + w / 8 * h then return nil end
    return { width = w, height = h }
end

local CP1252 = { "€", "\\x81", "‚", "ƒ", "„", "…", "†", "‡", "ˆ", "‰", "Š", "‹", "Œ", "\\x8D", "Ž", "\\x8F", "\\x90", "‘", "’", "“", "”", "•", "–", "—", "˜", "™", "š", "›", "œ", "\\x9D", "ž", "Ÿ", " ", "¡", "¢", "£", "¤", "¥", "¦", "§", "¨", "©", "ª", "«", "¬", "­", "®", "¯", "°", "±", "²", "³", "´", "µ", "¶", "·", "¸", "¹", "º", "»", "¼", "½", "¾", "¿", "À", "Á", "Â", "Ã", "Ä", "Å", "Æ", "Ç", "È", "É", "Ê", "Ë", "Ì", "Í", "Î", "Ï", "Ð", "Ñ", "Ò", "Ó", "Ô", "Õ", "Ö", "×", "Ø", "Ù", "Ú", "Û", "Ü", "Ý", "Þ", "ß", "à", "á", "â", "ã", "ä", "å", "æ", "ç", "è", "é", "ê", "ë", "ì", "í", "î", "ï", "ð", "ñ", "ò", "ó", "ô", "õ", "ö", "÷", "ø", "ù", "ú", "û", "ü", "ý", "þ", "ÿ" }
local function text_data(data)
    local body = data:match("^([^%z]*)") or ""
    if body:find("[\2-\8\11\12\14-\31]") then return nil end
    body = body:gsub("\1", "")
    if not body:find("%S") then return nil end
    return (body:gsub("[\128-\255]", function(c) return CP1252[c:byte() - 127] end))
end
local function scene_header(data, demo)
    if #data < 6 + 0xA0 or data:sub(1, 6) ~= "DFISCN" then return nil end
    local scene = { chapter = u32(data, 15), background = u32(data, 43), palette = u32(data, 111),
        fonts = {u32(data, 99), u32(data, 103), u32(data, 107)},
        width = u32(data, 143), height = u32(data, 147),
        objects = u32(data, 163), actions = u32(data, 159) }
    -- WorldStats::load has eight coordinate words in the demo, seven in retail.
    local title = 6 + 0x2C0 + (demo and 4 or 0)
    if #data >= title + 8 then scene.title, scene.title_palette = u32(data, title + 1), u32(data, title + 5) end
    return scene
end
local function resource_key(pack, index) return pack .. ":" .. index end
local function from_resource_id(id)
    if not id or id < 2147483648 then return nil end
    local pack = math.floor(id / 65536) % 32768
    return resource_key(string.format("RES.%03d", pack), id % 65536)
end
local function files_in(path)
    local files = list_files(path) or {}
    table.sort(files)
    return files
end

local function data_root(game_path)
    local function marker(path)
        return file_exists(path .. "/RES.000") and
            (file_exists(path .. "/SNTRM.DAT") or file_exists(path .. "/ASYLUM.DAT"))
    end
    if marker(game_path) then return game_path end
    for _, name in ipairs(files_in(game_path)) do
        if name:upper() == "DATA" and marker(game_path .. "/" .. name) then return game_path .. "/" .. name end
    end
end
local function index_files(game_path)
    local files, seen = files_in(game_path), {}
    for _, name in ipairs(files) do seen[name:upper()] = true end
    local nested = {}
    for _, name in ipairs(files) do
        if name:upper() == "MUSIC" then
            for _, music in ipairs(files_in(game_path .. "/" .. name)) do
                if music:upper():match("^MUS%.%d%d%d$") and not seen[music:upper()] then
                    nested[#nested + 1] = name .. "/" .. music
                    seen[music:upper()] = true
                end
            end
        end
    end
    for _, name in ipairs(nested) do files[#files + 1] = name end
    table.sort(files)
    return files
end

local function build_index(game_path)
    if cache and cache.path == game_path then return cache end
    local requested_path = game_path
    game_path = data_root(game_path) or game_path
    local marker = file_open(game_path .. "/SNTRM.DAT") or file_open(game_path .. "/ASYLUM.DAT")
    local demo = marker and file_size(marker) == 326
    if marker then file_close(marker) end
    local idx = { path = requested_path, packs = {}, entries = {}, scenes = {}, palettes = {}, backgrounds = {}, fonts = {}, videos = {}, titles = {}, fixed_palettes = {} }
    for _, name in ipairs(index_files(game_path)) do
        local upper = name:match("[^/]+$"):upper()
        if upper:match("^SCN%.%d%d%d$") then
            local data = read_slice(game_path .. "/" .. name, 0, 722)
            local scene = data and scene_header(data, demo)
            if scene then
                scene.name, scene.file = upper, name
                scene.background_key, scene.palette_key = from_resource_id(scene.background), from_resource_id(scene.palette)
                idx.scenes[#idx.scenes + 1] = scene
                if scene.background_key then idx.backgrounds[scene.background_key] = scene end
                local title_key = from_resource_id(scene.title)
                if title_key then idx.titles[title_key] = from_resource_id(scene.title_palette) end
                for _, font in ipairs(scene.fonts) do
                    local key = from_resource_id(font)
                    if key then idx.fonts[key] = scene end
                end
            end
        elseif upper:match("^RES%.%d%d%d$") or upper:match("^MUS%.%d%d%d$") then
            local path = game_path .. "/" .. name
            local entries, count, size = directory(path)
            if entries then
                local pack = { name = upper, path = path, entries = entries, count = count, size = size, palettes = {} }
                idx.packs[#idx.packs + 1] = pack
                for _, e in ipairs(entries) do
                    e.pack, e.key, e.kind = pack, resource_key(upper, e.index), "data"
                    idx.entries[e.key] = e
                    if e.size > 0 then
                        local head = read_slice(path, e.offset, math.min(e.size, 44))
                        if head and head:sub(1, 4) == "D3GR" then
                            if #head >= 28 and math.floor(head:byte(6) / 32) % 2 == 1 then
                                local data = read_slice(path, e.offset, e.size)
                                local pal = data and palette_data(data)
                                if pal then
                                    e.kind, e.palette = "palette", pal
                                    idx.palettes[#idx.palettes + 1] = e
                                    pack.palettes[#pack.palettes + 1] = e
                                end
                            elseif #head >= 28 then
                                local n = u16(head, 25)
                                if n > 0 and n <= 4096 and 28 + n * 4 <= e.size then
                                    local table_data = read_slice(path, e.offset, 28 + n * 4)
                                    local frames = table_data and graphic_header(table_data, e.size)
                                    local valid = frames ~= nil
                                    for _, frame in ipairs(frames or {}) do
                                        local header = read_slice(path, e.offset + frame.offset, 16)
                                        if not header or not frame_header(header, frame) then valid = false; break end
                                    end
                                    if valid then e.kind, e.frames, e.bounds = "graphic", frames, animation_bounds(frames) end
                                end
                            end
                        elseif head and head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WAVE" then
                            if u32(head, 5) + 8 <= e.size then e.kind = "sound" end
                        elseif upper == "RES.000" then
                            local data = e.size <= 1024 * 1024 and read_slice(path, e.offset, e.size)
                            e.text = data and text_data(data)
                            if e.text then e.kind = "text" end
                        elseif head then
                            e.mask = mask_header(head, e.size)
                            if e.mask then e.kind = "mask" end
                        end
                    end
                end
            end
        elseif upper == "VIDS" then
            for _, video in ipairs(files_in(game_path .. "/" .. name)) do
                if video:upper():match("%.SMK$") then
                    idx.videos[#idx.videos + 1] = { name = video, path = game_path .. "/" .. name .. "/" .. video }
                end
            end
        elseif upper:match("%.SMK$") then
            idx.videos[#idx.videos + 1] = { name = name, path = game_path .. "/" .. name }
        end
    end
    -- References: menu.h/menu.cpp, scenetitle.cpp, video.cpp and insertdisc.cpp.
    local shared_fonts = { [16]=17, [22]=17, [25]=26, [32]=31, [57]=false }
    for number, palette in pairs(shared_fonts) do
        local key = resource_key("RES.001", number)
        if idx.entries[key] and idx.entries[key].kind == "graphic" then
            idx.fonts[key] = { palette_key = palette and resource_key("RES.001", palette) or nil }
        end
    end
    for _, number in ipairs({18, 19}) do
        local key = resource_key("RES.018", number)
        if idx.entries[key] and idx.entries[key].kind == "graphic" then idx.fonts[key] = { palette_key = "RES.018:11" } end
    end
    idx.fixed_palettes["RES.001:23"], idx.fixed_palettes["RES.001:33"] = "RES.001:26", "RES.001:31"
    for disc = 1, 3 do
        idx.fixed_palettes[resource_key("RES.018", 7 + disc)] = resource_key("RES.018", 10 + disc)
        idx.fixed_palettes[resource_key("RES.018", 13 + disc)] = resource_key("RES.018", 10 + disc)
    end
    for _, pack in ipairs(idx.packs) do
        local scene
        for _, s in ipairs(idx.scenes) do if s.name:sub(5) == pack.name:sub(5) then scene = s; break end end
        for _, e in ipairs(pack.entries) do
            if e.kind == "graphic" then
                local context = idx.backgrounds[e.key] or idx.fonts[e.key] or scene
                local palette_key = idx.titles[e.key] or idx.fixed_palettes[e.key] or (context and context.palette_key)
                local pal = palette_key and idx.entries[palette_key]
                -- Alternate palettes can precede room sprites in retail packs.
                -- Keep scene bindings first; infer archive order only without one.
                if not pal or pal.kind ~= "palette" then
                    for _, p in ipairs(pack.palettes) do if p.index <= e.index then pal = p end end
                end
                if not pal or pal.kind ~= "palette" then pal = pack.palettes[1] or idx.palettes[1] end
                e.palette_key = pal and pal.key
            end
        end
    end
    cache = idx
    return idx
end

local function swatch(pal)
    local px = {}
    for y = 0, 255 do for x = 0, 255 do px[y * 256 + x + 1] = math.floor(y / 16) * 16 + math.floor(x / 16) end end
    return image_create_indexed(256, 256, px, pal)
end
local function frame_pixels(data, frame, bounds)
    if #data ~= frame.width * frame.height then return nil end
    local w, h = bounds and bounds.width or frame.width, bounds and bounds.height or frame.height
    local pixels = {}; for i = 1, w * h do pixels[i] = 0 end
    local dx, dy = bounds and frame.x - bounds.x or 0, bounds and frame.y - bounds.y or 0
    for y = 0, frame.height - 1 do for x = 0, frame.width - 1 do
        pixels[(y + dy) * w + x + dx + 1] = data:byte(y * frame.width + x + 1)
    end end
    return pixels, w, h
end
local function load_frame(e, frame, pal, bounds, opaque)
    local data = read_slice(e.pack.path, e.offset + frame.offset + 16, frame.width * frame.height)
    if not data then return nil end
    local px, w, h = frame_pixels(data, frame, bounds)
    if not px or w == 0 or h == 0 then return nil end
    return image_create_indexed(w, h, px, pal, not opaque and 0 or nil)
end
local function mask_pixels(data, mask)
    local pixels, w, h = {}, mask.width, mask.height
    if #data < 8 + w / 8 * h then return nil end
    for y = 0, h - 1 do for x = 0, w - 1 do
        pixels[y * w + x + 1] = math.floor(data:byte(9 + y * (w / 8) + math.floor(x / 8)) / 2^(x % 8)) % 2
    end end
    return pixels
end
local function error_result(message) return { type = "text", text = message, description = message } end

function engine.detect(game_path)
    local root = data_root(game_path)
    return root ~= nil and directory(root .. "/RES.000") ~= nil
end
function engine.get_resources(game_path)
    cache = nil
    local idx = build_index(game_path)
    local groups = {}
    for _, spec in ipairs({{"backgrounds", "Backgrounds"}, {"sprites", "Sprites and UI"}, {"fonts", "Fonts"},
        {"masks", "Occlusion Masks"}, {"animations", "Animations"}, {"sounds", "Speech and Sound Effects"},
        {"music", "Music (PCM)"}, {"palettes", "Palettes"}, {"texts", "Text"}, {"data", "Scene and Archive Data"}}) do
        groups[spec[1]] = { id = spec[1], name = spec[2], type = "category", children = {} }
    end
    local function add(group, node) group.children[#group.children + 1] = node end
    for _, pack in ipairs(idx.packs) do
        local banks = {}
        local function bank(category)
            if not banks[category] then
                banks[category] = { id = "bank:" .. category .. ":" .. pack.name, name = pack.name, type = "category", children = {} }
                add(groups[category], banks[category])
            end
            return banks[category]
        end
        add(groups.data, { id = "archive:" .. pack.name, name = pack.name .. " directory", type = "text" })
        for _, e in ipairs(pack.entries) do
            if e.kind == "graphic" then
                local group = idx.backgrounds[e.key] and "backgrounds" or idx.fonts[e.key] and "fonts" or "sprites"
                local node = { id = "gfx:" .. e.key, name = string.format("#%d (%d frames)", e.index, #e.frames), type = "category", children = {} }
                for _, frame in ipairs(e.frames) do
                    if frame.width > 0 and frame.height > 0 then add(node, {
                        id = "frame:" .. e.key .. ":" .. frame.index, type = "image",
                        name = string.format("Frame %d (%dx%d)", frame.index, frame.width, frame.height) }) end
                end
                if #node.children > 0 then add(bank(group), node) end
                if #e.frames > 1 and e.bounds and not idx.fonts[e.key] then
                    add(bank("animations"), { id = "anim:" .. e.key, name = string.format("#%d (%d frames)", e.index, #e.frames), type = "animation" })
                end
            elseif e.kind == "palette" then
                add(bank("palettes"), { id = "pal:" .. e.key, name = "Palette #" .. e.index, type = "palette" })
            elseif e.kind == "sound" then
                local music = pack.name:match("^MUS%.") or pack.name == "RES.002"
                add(bank(music and "music" or "sounds"), { id = "sound:" .. e.key, name = "Clip #" .. e.index, type = "sound" })
            elseif e.kind == "mask" then
                add(bank("masks"), { id = "mask:" .. e.key, name = string.format("Mask #%d (%dx%d)", e.index, e.mask.width, e.mask.height), type = "image" })
            elseif e.kind == "text" then
                add(bank("texts"), { id = "text:" .. e.key, name = "#" .. e.index .. " " .. e.text:gsub("[\r\n]", " "):sub(1, 65), type = "text" })
            elseif e.size > 2 then
                add(bank("data"), { id = "data:" .. e.key, name = "Resource #" .. e.index, type = "text" })
            end
        end
    end
    for i, scene in ipairs(idx.scenes) do add(groups.data, { id = "scene:" .. i, name = scene.name, type = "text" }) end
    for i, video in ipairs(idx.videos) do add(groups.data, { id = "video:" .. i, name = video.name .. " metadata", type = "text" }) end
    local result = {}
    for _, name in ipairs({"backgrounds", "sprites", "fonts", "masks", "animations", "sounds", "music", "palettes", "texts", "data"}) do
        if #groups[name].children > 0 then result[#result + 1] = groups[name] end
    end
    return result
end
function engine.default_palette(game_path, resource_id)
    local key = resource_id:match("^frame:(RES%.%d%d%d:%d+):%d+$") or resource_id:match("^anim:(RES%.%d%d%d:%d+)$")
    local e = key and build_index(game_path).entries[key]
    return e and e.palette_key and "pal:" .. e.palette_key or nil
end
function engine.load_resource(game_path, resource_id, palette_id)
    local idx = build_index(game_path)
    local frame_key, frame_index = resource_id:match("^frame:(RES%.%d%d%d:%d+):(%d+)$")
    local kind, key = resource_id:match("^(%a+):((RES%.%d%d%d):%d+)$")
    if not kind then kind, key = resource_id:match("^(%a+):((MUS%.%d%d%d):%d+)$") end
    if frame_key then kind, key = "frame", frame_key end
    if kind == "frame" and not frame_key then return nil end
    local e = key and idx.entries[key]
    if e then
        if kind == "pal" and e.kind == "palette" then
            return { type = "image", image = swatch(e.palette), palette_colors = 256, description = e.pack.name .. " palette #" .. e.index }
        elseif kind == "text" and e.kind == "text" then return { type = "text", text = e.text, description = e.key }
        elseif kind == "sound" and e.kind == "sound" then
            local data = read_slice(e.pack.path, e.offset, e.size)
            local sound = data and sound_create_encoded(data)
            if not sound then return error_result("Unsupported or malformed WAV: " .. e.key) end
            return { type = "sound", sound = sound, description = e.key .. " - WAVE audio" }
        elseif kind == "mask" and e.kind == "mask" then
            local data = read_slice(e.pack.path, e.offset, e.size)
            local px = data and mask_pixels(data, e.mask)
            if not px then return error_result("Malformed mask: " .. e.key) end
            local pal = {}; for i = 1, 768 do pal[i] = 0 end
            pal[4], pal[5], pal[6] = 255, 255, 255
            return { type = "image", image = image_create_indexed(e.mask.width, e.mask.height, px, pal), palette_colors = 2,
                description = e.key .. " - LSB-first occlusion mask, white bits block drawing" }
        elseif (kind == "frame" or kind == "anim") and e.kind == "graphic" then
            local pk = e.palette_key
            if palette_id then pk = palette_id:match("^pal:(RES%.%d%d%d:%d+)$") end
            local palette = pk and idx.entries[pk]
            if not palette or palette.kind ~= "palette" then return error_result("Missing or invalid palette for " .. e.key) end
            local pal, opaque = palette.palette, idx.backgrounds[e.key] ~= nil or idx.titles[e.key] ~= nil
                or e.key == "RES.001:23" or e.key == "RES.001:33"
                or e.key:match("^RES%.018:[89]$") ~= nil or e.key == "RES.018:10"
            if kind == "frame" then
                local frame = e.frames[tonumber(frame_index) + 1]
                if not frame or frame.width == 0 or frame.height == 0 then return error_result("Absent/empty frame: " .. resource_id) end
                local image = load_frame(e, frame, pal, nil, opaque)
                if not image then return error_result("Truncated frame: " .. resource_id) end
                return { type = "image", image = image, palette_image = swatch(pal), palette_colors = 256,
                    description = string.format("%s frame %d - %dx%d, origin (%d,%d), %s palette", e.key, frame.index,
                        frame.width, frame.height, frame.x, frame.y, pk) }
            end
            if not e.bounds then return error_result("Animation exceeds preview bounds: " .. e.key) end
            local frames = {}
            for _, frame in ipairs(e.frames) do
                local image = load_frame(e, frame, pal, e.bounds, opaque)
                if not image then return error_result("Truncated animation frame: " .. e.key) end
                frames[#frames + 1] = image
            end
            return { type = "animation", animation = animation_create(frames, 100), delay_ms = 100,
                description = e.key .. " - aligned frames; fixed 100 ms preview timing", palette_image = swatch(pal), palette_colors = 256 }
        elseif kind == "data" then
            local data = read_slice(e.pack.path, e.offset, math.min(e.size, 256)) or ""
            local lines = { string.format("%s resource #%d\nOffset: 0x%08X\nSize: %d bytes\nKind: %s\n", e.pack.name, e.index, e.offset, e.size, e.kind) }
            for p = 1, #data, 16 do
                local hex = {}; for j = p, math.min(p + 15, #data) do hex[#hex + 1] = string.format("%02X", data:byte(j)) end
                lines[#lines + 1] = string.format("%04X  %s", p - 1, table.concat(hex, " "))
            end
            return { type = "text", text = table.concat(lines, "\n") }
        end
        return nil
    end
    local name = resource_id:match("^archive:([%w%.]+)$")
    if name then
        for _, pack in ipairs(idx.packs) do if pack.name == name then
            local lines = { string.format("%s - %d directory entries, %d bytes", name, pack.count, pack.size) }
            for _, entry in ipairs(pack.entries) do lines[#lines + 1] = string.format("%5d  %08X  %9d  %s", entry.index, entry.offset, entry.size, entry.kind) end
            return { type = "text", text = table.concat(lines, "\n") }
        end end
    end
    local scene = idx.scenes[tonumber(resource_id:match("^scene:(%d+)$")) or 0]
    if scene then return { type = "text", text = string.format("%s\nChapter: %d\nScene dimensions: %dx%d\nBackground: 0x%08X\nPalette: 0x%08X\nObjects: %d\nActions: %d\n",
        scene.name, scene.chapter, scene.width, scene.height, scene.background, scene.palette, scene.objects, scene.actions) } end
    local video = idx.videos[tonumber(resource_id:match("^video:(%d+)$")) or 0]
    if video then
        local f = file_open(video.path)
        if not f then return error_result("Missing " .. video.name) end
        local size = file_size(f); file_close(f)
        return { type = "text", text = video.name .. "\n" .. size .. " bytes\nSmacker cutscene. Video preview/export is not supported." }
    end
    return nil
end

return engine

-- I Have No Mouth, and I Must Scream (SAGA, DOS CD).
-- Format references: ScummVM engines/saga/{resource,image,scene,sprite,
-- animation,script,sndres,saga}.cpp. Resource numbers are zero-based.
local engine = {
    id = "saga", name = "I Have No Mouth, and I Must Scream",
    description = "I Have No Mouth, and I Must Scream (1995, Dreamers Guild)", version = "1.0",
}
local floor = math.floor
local function u16(d, p)
    if p < 1 or p + 1 > #d then return nil end
    return d:byte(p) + d:byte(p + 1) * 256
end
local function u32(d, p)
    if p < 1 or p + 3 > #d then return nil end
    return u16(d, p) + u16(d, p + 2) * 65536
end
local function be16(d, p)
    if p < 1 or p + 1 > #d then return nil end
    return d:byte(p) * 256 + d:byte(p + 1)
end
local function signed(n) return n >= 32768 and n - 65536 or n end
local function dimensions(w, h) return w and h and w > 0 and h > 0 and w <= 2048 and h <= 2048 and w * h <= 2097152 end
local function read_at(path, off, size)
    local f = file_open(path)
    if not f then return nil end
    local d = file_read(f, off, size)
    file_close(f)
    if not d or #d ~= size then return nil end
    return d
end
local function parse_archive(path)
    local f = file_open(path)
    if not f then return nil end
    local size = file_size(f)
    local footer = size >= 8 and file_read(f, size - 8, 8) or ""
    local off, count = u32(footer, 1), u32(footer, 5)
    if not count or count == 0 or count > 65536 or off ~= size - 8 - count * 8 then
        file_close(f) return nil
    end
    local d = file_read(f, off, count * 8)
    file_close(f)
    if not d or #d ~= count * 8 then return nil end
    local a = { path = path, count = count, entries = {} }
    for i = 0, count - 1 do
        local o, n = u32(d, i * 8 + 1), u32(d, i * 8 + 5)
        if o + n > off then return nil end
        a.entries[i] = { offset = o, size = n }
    end
    return a
end
local function resource(a, id, limit)
    local e = a and a.entries[id]
    if not e then return nil end
    return read_at(e.path or a.path, e.offset, math.min(e.size, limit or e.size))
end
local function palette(d, offset)
    if not d or #d < offset + 767 then return nil end
    local pal = {}
    for i = 0, 767 do pal[i + 1] = d:byte(offset + i) end
    return pal
end
local function gray()
    local p = {}
    for i = 0, 255 do p[i * 3 + 1], p[i * 3 + 2], p[i * 3 + 3] = i, i, i end
    return p
end

-- SAGA background RLE, including overlapping LZ copies and two-color bitfields.
local function decode_rle(d, size)
    local out, p, n = {}, 1, 0
    while p <= #d and n < size do
        local b = d:byte(p); p = p + 1
        local count, distance, value, literal, bits
        if b >= 192 then count, literal = b % 64, true
        elseif b >= 128 then count, value = b % 64 + 3, d:byte(p); p = p + 1
        elseif b >= 64 then count, distance = floor(b / 8) % 8 + 3, d:byte(p); p = p + 1
        elseif b >= 48 then count, bits = (b % 16 + 1) * 8, true
        elseif b >= 32 then count, literal = b % 16 * 256 + (d:byte(p) or 0), true; p = p + 1
        elseif b >= 16 then
            distance = b % 16 * 256 + (d:byte(p) or 0)
            count = d:byte(p + 1); p = p + 2
        else return nil end
        if not count or n + count > size then return nil end
        if bits then
            if p + 1 + count / 8 > #d then return nil end
            local a, c = d:byte(p, p + 1); p = p + 2
            for _ = 1, count / 8 do
                local mask = d:byte(p); p = p + 1
                for bit = 7, 0, -1 do
                    n = n + 1; out[n] = floor(mask / 2 ^ bit) % 2 == 1 and c or a
                end
            end
        elseif literal then
            if p + count - 1 > #d then return nil end
            for _ = 1, count do n = n + 1; out[n] = d:byte(p); p = p + 1 end
        elseif distance then
            if distance == 0 or distance > n then return nil end
            for _ = 1, count do n = n + 1; out[n] = out[n - distance] end
        else
            if not value then return nil end
            for _ = 1, count do n = n + 1; out[n] = value end
        end
    end
    -- ScummVM zero-initializes the padded rows; streams can omit this padding.
    for i = n + 1, size do out[i] = 0 end
    return out
end
local function decode_image(d, mask)
    local w, h = u16(d, 1), u16(d, 3)
    if #d <= 776 or not dimensions(w, h) then return nil end
    local raw = decode_rle(d:sub(777), w * (floor((h + 3) / 4) * 4))
    if not raw then return nil end
    local px = {}
    for y = 0, h - 1 do
        local destY = mask and y or h - 1 - y
        for x = 0, w - 1 do
            px[destY * w + x + 1] = raw[floor(y / 4) * w * 4 + x * 4 + y % 4 + 1]
        end
    end
    return px, w, h
end
local function sprite_list(d)
    local count = u16(d, 1)
    if not count or count == 0 or count > 4096 or 2 + count * 4 > #d then return nil end
    local frames, previous = {}, 2 + count * 4
    for i = 0, count - 1 do
        local off = u32(d, 3 + i * 4)
        if not off or off < previous or off + 8 > #d then return nil end
        local w, h = u16(d, off + 5), u16(d, off + 7)
        if not dimensions(w, h) then return nil end
        frames[#frames + 1] = { offset = off + 9, w = w, h = h,
            x = signed(u16(d, off + 1)), y = signed(u16(d, off + 3)) }
        previous = off
    end
    return frames
end
local function decode_sprite(d, f, ending)
    local px, n, p, size = {}, 0, f.offset, f.w * f.h
    while n < size and p + 1 <= ending do
        local skip, copy = d:byte(p, p + 1); p = p + 2
        if skip + copy == 0 then return nil end
        -- Some shipped sprites overrun the final transparent run. ScummVM
        -- clips at the output boundary; preserve the same behavior.
        for _ = 1, math.min(skip, size - n) do n = n + 1; px[n] = 0 end
        copy = math.min(copy, size - n)
        if p + copy - 1 > ending then return nil end
        for _ = 1, copy do n = n + 1; px[n] = d:byte(p); p = p + 1 end
    end
    for i = n + 1, size do px[i] = 0 end
    local flipped = {}
    for y = 0, f.h - 1 do
        for x = 1, f.w do flipped[(f.h - 1 - y) * f.w + x] = px[y * f.w + x] end
    end
    return flipped
end
-- IHNM's translated text uses Windows-1252 (font_map.cpp's DOS mapping
-- is for ITE). Convert to UTF-8 before returning strings to LuaJ.
local CP1252 = {
    8364,129,8218,402,8222,8230,8224,8225,710,8240,352,8249,338,141,381,143,
    144,8216,8217,8220,8221,8226,8211,8212,732,8482,353,8250,339,157,382,376,
}
local function utf8text(s)
    return (s:gsub("[\128-\255]", function(c)
        local v = c:byte()
        if v < 160 then v = CP1252[v - 127] end
        if v < 2048 then return string.char(192 + floor(v / 64), 128 + v % 64) end
        return string.char(224 + floor(v / 4096), 128 + floor(v / 64) % 64, 128 + v % 64)
    end))
end
local function strings(d)
    local first = u16(d, 1)
    if not first or first < 2 or first % 2 ~= 0 or first > #d then return nil end
    local lines, prev, wrap = {}, 0, 0
    for p = 1, first, 2 do
        local off = u16(d, p) + wrap
        if off < prev then wrap = wrap + 65536; off = off + 65536 end
        if off == #d then break end
        if off < first or off > #d then return nil end
        local ending = d:find("\0", off + 1, true)
        if not ending then return nil end
        lines[#lines + 1] = string.format("[%d] %s", #lines, utf8text(d:sub(off + 1, ending - 1)))
        prev = off
    end
    return table.concat(lines, "\n")
end

local cached_path, cached_index
local function get_index(path)
    if cached_path == path then return cached_index end
    local main = parse_archive(path .. "/SCREAM.RES")
    if not main or main.count ~= 1273 then return nil end -- full DOS CD layout
    local idx = { main = main, archives = { scream = main }, refs = {}, palettes = {}, animbg = {}, delays = {}, textids = { [21] = true } }
    local lut = resource(main, 1272) or ""
    for s = 0, floor(#lut / 2) - 1 do
        local desc = resource(main, u16(lut, s * 2 + 1)) or ""
        if #desc == 14 or #desc == 16 then
            local list = resource(main, u16(desc, 3)) or ""
            local bg, anims = nil, {}
            for p = 1, #list - 3, 4 do
                local id, kind = u16(list, p), u16(list, p + 2)
                if main.entries[id] then
                    idx.refs[id] = idx.refs[id] or { scene = s, kind = kind }
                    if kind == 2 then bg = id end
                    if kind >= 14 and kind <= 23 then anims[#anims + 1] = id end
                end
            end
            if bg then
                for _, id in ipairs(anims) do idx.animbg[id] = bg end
            end
        end
    end
    -- Chapter metadata: palettes for inventory/faces and cutaway background pairs.
    for _, id in ipairs({326,517,677,805,968,1165,1271}) do
        local meta = resource(main, id) or ""
        if #meta >= 54 then
            local scene = u16(meta, 1)
            local bg
            for rid, ref in pairs(idx.refs) do if ref.scene == scene and ref.kind == 2 then bg = rid end end
            for _, pos in ipairs({9,13,31}) do idx.palettes[u32(meta, pos)] = bg end
            idx.textids[u32(meta, 5)] = true
            idx.textids[u32(meta, 23)] = true
            local cutaways = resource(main, u32(meta, 47)) or ""
            for p = 1, #cutaways - 7, 8 do
                local b, a, rate = u16(cutaways, p), u16(cutaways, p + 2), signed(u16(cutaways, p + 6))
                if a > 0 then idx.animbg[a] = b; if rate > 0 then idx.delays[a] = floor(1000 / rate) end end
            end
        end
    end
    local intro = resource(main, 39) or ""
    for p = 1, #intro - 7, 8 do
        local bg, anim, rate = u16(intro, p), u16(intro, p + 2), signed(u16(intro, p + 6))
        if anim > 0 then
            idx.animbg[anim] = bg
            if rate > 0 then idx.delays[anim] = floor(1000 / rate) end
        end
    end
    local script = parse_archive(path .. "/SCRIPTS.RES")
    if script then idx.archives.scripts = script end
    for _, name in ipairs(list_files(path)) do
        local upper = name:upper()
        if upper == "SFX.RES" or upper == "MUSICGM.RES" or upper == "MUSICFM.RES" or upper:match("^VOICES[1-6S]%.RES$") then
            local a = parse_archive(path .. "/" .. name)
            if a then idx.archives[upper:sub(1, -5):lower()] = a end
        end
    end
    cached_path, cached_index = path, idx
    return idx
end
local function choose_palette(idx, id, override)
    if override then
        local rid = tonumber(override:match("^pal_(%d+)$"))
        if rid then
            local d = resource(idx.main, rid, 776)
            if d then return palette(d, #d == 768 and 1 or 9) end
        end
    end
    local bg = idx.animbg[id] or idx.palettes[id]
    if not bg then
        local ref = idx.refs[id]
        if ref then
            for rid, other in pairs(idx.refs) do if other.scene == ref.scene and other.kind == 2 then bg = rid; break end end
        end
    end
    local d = resource(idx.main, bg or 9, 776)
    return palette(d, 9) or gray()
end
local function node(id, name, kind) return { id = id, name = name, type = kind } end
local function group(id, name, children)
    return { id = id, name = name .. " (" .. #children .. ")", type = "category", children = children }
end
function engine.detect(path)
    if type(path) ~= "string" then return false end
    local a = parse_archive(path .. "/SCREAM.RES")
    return a ~= nil and a.count == 1273 and file_exists(path .. "/SCRIPTS.RES")
end
function engine.get_resources(path)
    local idx = get_index(path)
    if not idx then return {} end
    local bg, masks, sprites, anims, pals, texts, data = {}, {}, {}, {}, {}, {}, {}
    for id = 0, idx.main.count - 1 do
        local e = idx.main.entries[id]
        if e.size > 0 then
            local d = resource(idx.main, id, 776) or ""
            local ref = idx.refs[id]
            local label = string.format("Resource %04d%s", id, ref and (" - Scene " .. ref.scene) or "")
            local kind = ref and ref.kind
            local count, frames = u16(d, 1), nil
            if count and count > 0 and count <= 4096 and u32(d, 3) == 2 + count * 4 then
                frames = sprite_list(resource(idx.main, id) or "")
            end
            if kind == 2 or kind == 3 or (not frames and #d == 776 and d:sub(5, 8) == "\0\0\0\0" and dimensions(u16(d, 1), u16(d, 3))) then
                local mask = kind == 3
                local list = mask and masks or bg
                list[#list + 1] = node((mask and "mask_" or "bg_") .. id, label, "image")
                if not mask then pals[#pals + 1] = node("pal_" .. id, label .. " palette", "palette") end
            elseif u16(d, 1) == 68 and dimensions(u16(d, 3), u16(d, 5)) then
                anims[#anims + 1] = node("anim_" .. id, label, "animation")
            elseif e.size == 768 then
                pals[#pals + 1] = node("pal_" .. id, label, "palette")
            elseif kind == 5 or idx.textids[id] then
                texts[#texts + 1] = node("text_scream_" .. id, label, "text")
            else
                if frames then
                    local children = {}
                    for i, f in ipairs(frames) do
                        children[#children + 1] = node(string.format("sprite_%d_%d", id, i),
                            string.format("Frame %03d - %dx%d (%d,%d)", i - 1, f.w, f.h, f.x, f.y), "image")
                    end
                    sprites[#sprites + 1] = group("sprites_" .. id, label, children)
                else data[#data + 1] = node("data_scream_" .. id, label .. " - " .. e.size .. " bytes", "data") end
            end
        end
    end
    local result = { group("backgrounds", "Backgrounds and screens", bg), group("masks", "Scene masks", masks),
        group("sprites", "Sprites", sprites), group("animations", "Animations and cutaways", anims),
        group("palettes", "Palettes", pals), group("text", "Scene and interface text", texts) }
    local keys = {}; for key in pairs(idx.archives) do keys[#keys + 1] = key end; table.sort(keys)
    for _, key in ipairs(keys) do
        if key ~= "scream" then
            local a, children = idx.archives[key], {}
            for id = 0, a.count - 1 do
                local e = a.entries[id]
                if e.size > 0 then
                    local header = resource(a, id, 12) or ""
                    local kind = "data"
                    if header:sub(1, 4) == "RIFF" and header:sub(9, 12) == "WAVE" then kind = "sound"
                    elseif key:match("^music") and header:sub(1, 4) == "FORM" then kind = "midi"
                    elseif key == "scripts" then
                        local lut = resource(idx.main, 29) or ""
                        for p = 1, #lut - 15, 16 do if u16(lut, p + 2) == id then kind = "text" end end
                    end
                    children[#children + 1] = node(kind .. "_" .. key .. "_" .. id, string.format("%s %04d - %d bytes", key:upper(), id, e.size), kind)
                end
            end
            result[#result + 1] = group(key, key:upper(), children)
        end
    end
    result[#result + 1] = group("data", "Other game data", data)
    return result
end

-- Delta animation commands use big-endian coordinates even in DOS resources.
-- Decode one complete frame into the persistent canvas, preserving zero literals.
local function animation_frame(d, p, canvas, w, h)
    local cursor, xs, ys = nil, 0, 0
    local function word()
        local v = be16(d, p); p = p + 2; return v
    end
    local function run(count, value, literal)
        if not cursor or not count or cursor < 0 or cursor + count > w * h then return false end
        if literal and p + count - 1 > #d then return false end
        for _ = 1, count do
            local b = value
            if literal then b = d:byte(p); p = p + 1 end
            if b == nil then return false end
            if not literal or b ~= 0 then canvas[cursor + 1] = b end
            cursor = cursor + 1
        end
        return true
    end
    while p <= #d do
        local b = d:byte(p); p = p + 1
        if b == 15 then
            xs, ys = word(), word()
            if not ys or p + 8 > #d then return nil end
            p = p + 9 -- padding byte plus x,y,width,height rectangle
            cursor = ys * w + xs
        elseif b == 63 then return p
        elseif b == 31 then p = p + 3
        elseif b == 47 then
            local x, y = word(), word()
            if not y then return nil end
            cursor = (ys + signed(y)) * w + xs + signed(x)
        elseif b == 48 then
            local x = word()
            if not x or not cursor then return nil end
            cursor = cursor + signed(x)
        elseif b == 16 then
            local count = word()
            if not run(count, nil, true) then return nil end
        elseif b == 32 then
            local count = word(); local v = d:byte(p); p = p + 1
            if not run(count, v, false) then return nil end
        elseif b >= 192 then
            if not cursor then return nil end
            cursor = cursor + b % 64 + 1
        elseif b >= 128 then
            local v = d:byte(p); p = p + 1
            if not run(b % 64 + 1, v, false) then return nil end
        elseif b >= 64 then
            if not run(b % 64 + 1, nil, true) then return nil end
        else return nil end
    end
    return nil
end
local function load_animation(idx, id, override)
    local d = resource(idx.main, id)
    if not d or #d < 12 then return nil end
    local w, h = u16(d, 3), u16(d, 5)
    if not dimensions(w, h) then return nil end
    local canvas = {}
    local bgid = idx.animbg[id]
    if bgid then
        local bg = resource(idx.main, bgid)
        local px, bw, bh
        if bg then px, bw, bh = decode_image(bg) end
        if px then
            for y = 0, math.min(h, bh) - 1 do
                for x = 0, math.min(w, bw) - 1 do canvas[y * w + x + 1] = px[y * bw + x + 1] end
            end
        end
    end
    for i = 1, w * h do if not canvas[i] then canvas[i] = 0 end end
    local pal = choose_palette(idx, id, override)
    local p, frames, failed = 13, {}, false
    local total = d:byte(9)
    -- Bound preview memory. Scripts can change playback timing and layer animations.
    local cap = math.min(120, math.max(1, floor(12000000 / (w * h))))
    while p <= #d and #frames < total and #frames < cap do
        local nextp = animation_frame(d, p, canvas, w, h)
        if not nextp then failed = true; break end
        frames[#frames + 1] = image_create_indexed(w, h, canvas, pal)
        p = nextp
    end
    if #frames == 0 then return nil end
    local delay = idx.delays[id] or 140
    return { type = "animation", animation = animation_create(frames, delay), image = frames[1],
        description = string.format("Animation %d - %d/%d frames%s%s; %d ms, script timing/layers may differ",
            id, #frames, total, #frames == cap and p <= #d and " (preview limit)" or "", failed and " (incomplete stream)" or "", delay) }
end
local function load_wave(d)
    if d:sub(1, 4) ~= "RIFF" or d:sub(9, 12) ~= "WAVE" then return nil end
    local p, fmt, pcm = 13, nil, nil
    while p + 7 <= #d do
        local kind, n = d:sub(p, p + 3), u32(d, p + 4)
        if p + 7 + n > #d then return nil end
        if kind == "fmt " and n >= 16 then
            fmt = { codec = u16(d, p + 8), channels = u16(d, p + 10), rate = u32(d, p + 12), bits = u16(d, p + 22) }
        elseif kind == "data" then pcm = d:sub(p + 8, p + 7 + n) end
        p = p + 8 + n + n % 2
    end
    if not fmt or not pcm or fmt.codec ~= 1 or (fmt.channels ~= 1 and fmt.channels ~= 2) or
        (fmt.bits ~= 8 and fmt.bits ~= 16) or fmt.rate < 1 or fmt.rate > 192000 then return nil end
    return sound_create_pcm(fmt.rate, fmt.bits, fmt.channels, fmt.bits == 16, pcm)
end
local function metadata(d, label)
    local hex = {}
    for p = 1, math.min(#d, 512), 16 do
        local bytes = {}
        for i = p, math.min(p + 15, #d) do bytes[#bytes + 1] = string.format("%02X", d:byte(i)) end
        hex[#hex + 1] = string.format("%08X  %s", p - 1, table.concat(bytes, " "))
    end
    return { type = "text", text = label .. "\n" .. #d .. " bytes\n\n" .. table.concat(hex, "\n"), description = label }
end
function engine.default_palette(path, id)
    local idx = get_index(path)
    if not idx then return nil end
    local n = tonumber(id:match("^bg_(%d+)$"))
    if n then return "pal_" .. n end
    n = tonumber(id:match("^anim_(%d+)$") or id:match("^sprite_(%d+)_"))
    if n then
        local bg = idx.animbg[n] or idx.palettes[n]
        return "pal_" .. (bg or 9)
    end
    return nil
end
function engine.load_resource(path, id, override)
    local idx = get_index(path)
    if not idx or type(id) ~= "string" then return nil end
    local kind, digits = id:match("^(%a+)_(%d+)$")
    local n = tonumber(digits)
    if kind == "bg" or kind == "mask" then
        local d = resource(idx.main, n)
        if not d then return nil end
        local px, w, h = decode_image(d, kind == "mask")
        if not px then return nil end
        local pal = kind == "mask" and gray() or (override and choose_palette(idx, n, override) or palette(d, 9))
        return { type = "image", image = image_create_indexed(w, h, px, pal), description = string.format("%s %d - %dx%d", kind, n, w, h) }
    elseif kind == "pal" then
        local d = resource(idx.main, n, 776)
        local pal = d and palette(d, #d == 768 and 1 or 9)
        if not pal then return nil end
        local px = {}
        for y = 0, 255 do for x = 0, 255 do px[y * 256 + x + 1] = floor(y / 16) * 16 + floor(x / 16) end end
        return { type = "image", image = image_create_indexed(256, 256, px, pal), description = "Palette " .. n }
    elseif kind == "anim" then return load_animation(idx, n, override) end
    local rid, frame = id:match("^sprite_(%d+)_(%d+)$")
    if rid then
        n, frame = tonumber(rid), tonumber(frame)
        local d = resource(idx.main, n)
        local list = d and sprite_list(d)
        local f = list and list[frame]
        if not f then return nil end
        local px = decode_sprite(d, f, list[frame + 1] and list[frame + 1].offset - 9 or #d)
        if not px then return nil end
        return { type = "image", image = image_create_indexed(f.w, f.h, px, choose_palette(idx, n, override)),
            description = string.format("Sprite %d frame %d - %dx%d, origin (%d,%d); choose a scene palette for shared sprites", n, frame - 1, f.w, f.h, f.x, f.y) }
    end
    local typ, archive, num = id:match("^(%a+)_(%w+)_(%d+)$")
    local a = archive and idx.archives[archive]
    local d = a and resource(a, tonumber(num))
    if not d then return nil end
    if typ == "text" then
        local text = strings(d)
        if text then return { type = "text", text = text, description = archive .. " strings " .. num } end
    elseif typ == "sound" then
        local snd = load_wave(d)
        if snd then return { type = "sound", sound = snd, description = archive .. " sound " .. num } end
    elseif typ == "midi" then
        local midi = midi_create_from_xmi(d)
        if midi then return { type = "midi", midi = midi, description = archive .. " XMIDI " .. num } end
    end
    return metadata(d, archive .. " resource " .. num)
end
return engine

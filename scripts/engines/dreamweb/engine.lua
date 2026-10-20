-- DreamWeb (1994, Creative Reality), installed DOS floppy/CD resources.
-- Reference: ScummVM dreamweb/{structs.h,stubs.cpp,vgagrafx.cpp,sprite.cpp,sound.cpp}.
-- File offsets are zero-based; Lua string/table positions are one-based.
local engine = { id = "dreamweb", name = "DreamWeb", version = "1.0",
    description = "DreamWeb (1994, Creative Reality; DOS floppy/CD data)" }
local cache
local function u16(d, p)
    if p < 1 or p + 1 > #d then return nil end
    return d:byte(p) + d:byte(p + 1) * 256
end
local function read(path, offset, size)
    if offset < 0 or size < 0 or size > 16 * 1024 * 1024 then return nil end
    local f = file_open(path)
    if not f then return nil end
    local d
    if offset + size <= file_size(f) then d = size == 0 and "" or file_read(f, offset, size) end
    file_close(f)
    return d and #d == size and d or nil
end
local function whole(path)
    local f = file_open(path)
    if not f then return nil end
    local n = file_size(f); file_close(f)
    return read(path, 0, n)
end
local function header(d, count)
    if not d or #d < 96 or d:sub(1, 13) ~= "DREAMWEB DATA" then return nil end
    local segments, offset = {}, 96
    for i = 0, count - 1 do
        local n = u16(d, 51 + i * 2)
        if offset + n > #d then return nil end
        segments[i] = { offset = offset, size = n }
        offset = offset + n
    end
    return segments
end
local function prefix(path)
    for _, p in ipairs({ "DREAMWEB.", "DREAMWSP.", "DREAMWFR." }) do
        local h = read(path .. "/" .. p .. "R00", 0, 96)
        if h and h:sub(1, 13) == "DREAMWEB DATA" and file_exists(path .. "/" .. p .. "PAL") then return p end
    end
end
function engine.detect(path) return prefix(path) ~= nil end

local function frames(d, seg, limit)
    local result = {}
    if seg.size < 2080 then return result end
    for i = 0, (limit or 346) - 1 do
        local p = seg.offset + i * 6 + 1
        local w, h, off = d:byte(p), d:byte(p + 1), u16(d, p + 2)
        if w > 0 and h > 0 and off + w * h <= seg.size - 2080 then
            result[i] = { width = w, height = h, x = d:byte(p + 4), y = d:byte(p + 5),
                offset = seg.offset + 2080 + off, size = w * h }
        end
    end
    return result
end
local function palette_iff(d)
    if not d or #d < 12 or d:sub(1, 4) ~= "FORM" or d:sub(9, 12) ~= "ILBM" then return nil end
    local p = 13
    while p + 7 <= #d do
        local a,b,c,e = d:byte(p + 4, p + 7)
        local n = a*16777216 + b*65536 + c*256 + e
        if p + 7 + n > #d then return nil end
        if d:sub(p, p + 3) == "CMAP" and n == 768 then
            local pal = {}
            -- Runtime truncates the IFF's 8-bit RGB to the six-bit VGA DAC.
            for i = 1, 768 do pal[i] = math.floor(d:byte(p + 7 + i) / 4) * 4 end
            return pal
        end
        p = p + 8 + n + n % 2
    end
end
local function pcx_header(d)
    if not d or #d < 128 or d:byte(1) ~= 10 or d:byte(3) ~= 1 then return nil end
    local bits, planes = d:byte(4), d:byte(66)
    local w, h = u16(d, 9) - u16(d, 5) + 1, u16(d, 11) - u16(d, 7) + 1
    local stride = u16(d, 67)
    if w < 1 or h < 1 or w > 2048 or h > 2048 or w*h > 2097152
        or not ((bits == 1 and planes >= 1 and planes <= 4) or (bits == 8 and planes == 1))
        or stride < math.ceil(w * bits / 8) or stride > 4096 then return nil end
    local pal = {}; for i = 1, 768 do pal[i] = 0 end
    local colors = bits == 1 and 2^planes or 256
    local base = 16
    if bits == 8 then
        if #d < 897 or d:byte(#d - 768) ~= 12 then return nil end
        base = #d - 768
    end
    for i = 1, colors*3 do pal[i] = d:byte(base + i) end
    return { width = w, height = h, bits = bits, planes = planes, stride = stride,
        palette = pal, colors = colors, stop = bits == 8 and #d - 769 or #d }
end
local function pcx_pixels(d, f)
    if not d or #d < f.stop then return nil end
    local pixels, p, pending, value = {}, 129, 0, 0
    for y = 0, f.height - 1 do
        local row = {}
        for i = 1, f.stride * f.planes do
            if pending == 0 then
                if p > f.stop then return nil end
                value = d:byte(p); p = p + 1; pending = 1
                if value >= 192 then
                    pending = value % 64
                    if pending == 0 or p > f.stop then return nil end
                    value = d:byte(p); p = p + 1
                end
            end
            row[i] = value; pending = pending - 1
        end
        -- PCX encoding may cross plane boundaries but never scanline boundaries.
        if pending ~= 0 then return nil end
        for x = 0, f.width - 1 do
            local v = row[x + 1]
            if f.bits == 1 then
                v = 0
                for plane = 0, f.planes - 1 do
                    local byte = row[plane * f.stride + math.floor(x / 8) + 1]
                    v = v + math.floor(byte / 2^(7 - x % 8)) % 2 * 2^plane
                end
            end
            pixels[#pixels + 1] = v
        end
    end
    return pixels
end
local CP850 = { "Ç", "ü", "é", "â", "ä", "à", "å", "ç", "ê", "ë", "è", "ï", "î", "ì", "Ä", "Å", "É", "æ", "Æ", "ô", "ö", "ò", "û", "ù", "ÿ", "Ö", "Ü", "ø", "£", "Ø", "×", "ƒ", "á", "í", "ó", "ú", "ñ", "Ñ", "ª", "º", "¿", "®", "¬", "½", "¼", "¡", "«", "»", "░", "▒", "▓", "│", "┤", "Á", "Â", "À", "©", "╣", "║", "╗", "╝", "¢", "¥", "┐", "└", "┴", "┬", "├", "─", "┼", "ã", "Ã", "╚", "╔", "╩", "╦", "╠", "═", "╬", "¤", "ð", "Ð", "Ê", "Ë", "È", "ı", "Í", "Î", "Ï", "┘", "┌", "█", "▄", "¦", "Ì", "▀", "Ó", "ß", "Ô", "Ò", "õ", "Õ", "µ", "þ", "Þ", "Ú", "Û", "Ù", "ý", "Ý", "¯", "´", "­", "±", "‗", "¾", "¶", "§", "÷", "¸", "°", "¨", "·", "¹", "³", "²", "■", " " }
local function strings(d, seg, count, skip)
    local result = {}; skip = skip or 0
    if seg.size < skip + count * 2 then return result end
    local base, stop = seg.offset + skip + count * 2, seg.offset + seg.size
    for i = 0, count - 1 do
        local p = base + u16(d, seg.offset + skip + i*2 + 1) + 1
        local e = p <= stop and d:find("\0", p, true)
        if e and e <= stop then
            local s = d:sub(p, e - 1)
            -- DOS850 matches the original Western European releases. Preserve controls.
            s = s:gsub("[^\32-\126\9\10\13]", function(c)
                return CP850[c:byte()-127] or string.format("\\x%02X", c:byte())
            end)
            if s:find("%S") then result[i] = s end
        end
    end
    return result
end
local function sound_entries(d)
    local result = {}
    if not header(d, 0) then return result end
    local n = u16(d, 51)
    if n % 6 ~= 0 or n > 4096 or 96 + n > #d then return result end
    for i = 0, n/6 - 1 do
        local p = 97 + i*6
        local off = 96 + n + d:byte(p)*16384 + u16(d, p + 1)
        local size = u16(d, p + 3)*2048
        if size > 0 and off + size <= #d then result[i] = { offset = off, size = size } end
    end
    return result
end
local function animation_box(sequence)
    local right, bottom = 0, 0
    for _, f in ipairs(sequence) do right = math.max(right, f.x + f.width); bottom = math.max(bottom, f.y + f.height) end
    if right*bottom*#sequence > 8*1024*1024 then return nil end
    return { width = right, height = bottom }
end
local function build_index(path)
    if cache and cache.path == path then return cache end
    local p = prefix(path)
    local idx = { path = path, tree = {}, entries = {}, palettes = {} }
    cache = idx
    if not p then return idx end
    local groups = {}
    local function group(name, parent, id)
        local g = { id = id or name, name = name, type = "category", children = {} }
        parent[#parent + 1] = g; return g.children
    end
    for _, name in ipairs({ "Backgrounds", "Sprites", "UI", "Fonts", "Animations", "Palettes", "Sound and Music", "Speech", "Text", "Data" }) do
        groups[name] = group(name, idx.tree)
    end
    local function add(parent, id, name, kind, entry)
        entry.kind = entry.kind or kind; entry.id = id
        idx.entries[id] = entry
        parent[#parent + 1] = { id = id, name = name, type = kind }
    end
    local palid = "pal:" .. p .. "PAL"
    local pal = palette_iff(whole(path .. "/" .. p .. "PAL"))
    if pal then
        idx.palettes[palid] = pal
        add(groups.Palettes, palid, "Game VGA palette", "palette", { palette = pal, colors = 256 })
    end
    local files = list_files(path) or {}; table.sort(files)
    local function add_frames(d, seg, limit, file, bank, parent)
        local fs = frames(d, seg, limit)
        for i = 0, (limit or 346) - 1 do
            local f = fs[i]
            if f then
                f.file, f.palette_id, f.kind = file, palid, "frame"
                add(parent, "frame:" .. file .. ":" .. bank .. ":" .. i,
                    string.format("Frame %03d (%dx%d; +%d,+%d)", i, f.width, f.height, f.x, f.y), "image", f)
            end
        end
        return fs
    end
    local function add_text(d, seg, count, skip, file, bank, label)
        local ss = strings(d, seg, count, skip)
        local parent
        for i = 0, count - 1 do
            if ss[i] then
                parent = parent or group(file .. " - " .. label, groups.Text, "texts:" .. file .. ":" .. bank)
                add(parent, "text:" .. file .. ":" .. bank .. ":" .. i,
                    string.format("%04d %s", i, ss[i]:sub(1, 65)), "text", { text = ss[i] })
            end
        end
    end
    for _, file in ipairs(files) do
        local upper = file:upper()
        local suffix = upper:sub(1, #p) == p and upper:sub(#p + 1)
        if suffix and suffix:match("^[RCGSTVI]%d%d$") then
            local d = whole(path .. "/" .. file)
            local kind = suffix:sub(1, 1)
            if kind == "R" then
                local seg = header(d, 15)
                if seg then
                    local report = { file .. "\nRoom resource segments (zero-based offsets):" }
                    for s = 0, 14 do report[#report+1] = string.format("%02d: offset %d, %d bytes", s, seg[s].offset, seg[s].size) end
                    add(groups.Data, "info:" .. file, file .. " room structure", "text", { text = table.concat(report, "\n") })
                    local spritegroup = group(file, groups.Sprites, "sprites:" .. file)
                    local set = add_frames(d, seg[2], 346, file, 2, group("Set objects", spritegroup, "set:" .. file))
                    for s = 4, 6 do add_frames(d, seg[s], 160, file, s, group("Reel sprites " .. (s-3), spritegroup, "reels:" .. file .. ":" .. s)) end
                    add_frames(d, seg[12], 240, file, 12, group("Free objects", spritegroup, "free:" .. file))
                    local tiles = math.floor((seg[0].size - 192)/256)
                    -- Several retail banks end with 64 unused bytes after the last complete tile.
                    if tiles >= 1 and tiles <= 256 and seg[1].size <= 132*66 then
                        add(spritegroup, "tiles:" .. file, "Backdrop tile atlas", "image", {kind="tiles",file=file,offset=seg[0].offset+192,size=tiles*256,tiles=tiles,palette_id=palid})
                        local bg = group(file, groups.Backgrounds, "backgrounds:" .. file)
                        for y = 0, 5 do for x = 0, 5 do
                            local cells, used, valid = {}, false, true
                            for row = 0, 9 do for col = 0, 10 do
                                local o = (y*10+row)*132+x*11+col
                                local v = o < seg[1].size and d:byte(seg[1].offset+o+1) or 0
                                cells[#cells+1] = v
                                if v ~= 0 then used = true end
                                if v >= tiles then valid = false end
                            end end
                            if used and valid then
                                add(bg, "map:" .. file .. ":" .. x .. ":" .. y,
                                    string.format("Screen %d,%d (tiles %d,%d)", x, y, x*11, y*10), "image",
                                    {kind="map",file=file,offset=seg[0].offset+192,size=tiles*256,cells=cells,palette_id=palid})
                            end
                        end end
                    end
                    local ad = seg[3]
                    for o = 0, math.min(128, math.floor(ad.size/64)) - 1 do
                        local a = ad.offset + o*64 + 1
                        if d:byte(a+8) == 1 then
                            local seq, ended = {}, false
                            for i = 0, 39 do
                                local n = d:byte(a+18+i)
                                if n == 255 then ended = true; break end
                                if not set[n] then seq = {}; break end
                                seq[#seq+1] = set[n]
                            end
                            local box = #seq > 1 and ended and animation_box(seq)
                            if box then
                                add(groups.Animations, "anim:" .. file .. ":" .. o, file .. " object " .. o, "animation",
                                    {sequence=seq,box=box,palette_id=palid,delay=math.max(1,math.floor((d:byte(a+7)+1)*1000*4/70+0.5))})
                            end
                        end
                    end
                    for _, t in ipairs({{8,1026,24,"People"},{9,130,0,"Set objects"},{10,98,0,"Blocks"},{11,38,0,"Rooms"},{14,82,0,"Free objects"}}) do
                        add_text(d, seg[t[1]], t[2], t[3], file, t[1], t[4])
                    end
                end
            elseif kind == "G" or kind == "S" or kind == "C" then
                local seg = header(d, 1)
                if seg then add_frames(d, seg[0], 346, file, 0, group(file, groups[kind == "C" and "Fonts" or kind == "G" and "UI" or "Sprites"], "graphics:" .. file)) end
            elseif kind == "T" then
                local seg = header(d, 1)
                if seg then add_text(d, seg[0], 66, 0, file, 0, "Text") end
            elseif kind == "V" and d then
                local parent = group(file, groups["Sound and Music"], "sounds:" .. file)
                local sounds = sound_entries(d)
                for i = 0, 682 do if sounds[i] then
                    local s = sounds[i]; s.file = file
                    add(parent, "sound:" .. file .. ":" .. i, string.format("Sample %02d (%.2f s)", i, s.size/22050), "sound", s)
                end end
            elseif kind == "I" then
                local f = pcx_header(d)
                if f then
                    local id = "pal:" .. file
                    idx.palettes[id] = f.palette
                    add(groups.Palettes, id, file .. " PCX palette", "palette", {palette=f.palette,colors=f.colors})
                    f.file, f.palette_id, f.kind = file, id, "pcx"
                    add(groups.Backgrounds, "pcx:" .. file, file .. " title screen", "image", f)
                end
            end
        end
    end
    for _, dir in ipairs(files) do
        local name = dir:upper()
        if name == "SPEECH" or name == "SPANISH" or name == "FRENCH" then
            local clips = list_files(path .. "/" .. dir) or {}; table.sort(clips)
            for _, clip in ipairs(clips) do
                if clip:upper():match("^[RT]%d%d[CT]%d%d%d%d%.RAW$") then
                    local file = dir .. "/" .. clip
                    local f = file_open(path .. "/" .. file)
                    if f then
                        local n = file_size(f); file_close(f)
                        if n > 0 and n <= 16*1024*1024 then
                            add(groups.Speech, "speech:" .. file, clip, "sound", {file=file,offset=0,size=n})
                        end
                    end
                end
            end
        end
    end
    return idx
end
function engine.get_resources(path) return build_index(path).tree end
function engine.default_palette(path, id)
    local e = build_index(path).entries[id]
    return e and e.palette_id
end
local swatch = {}
for y = 0, 255 do for x = 0, 255 do swatch[#swatch+1] = math.floor(y/16)*16+math.floor(x/16) end end
local function frame_pixels(d, f, box)
    if not d or #d ~= f.size then return nil end
    local w, h = box and box.width or f.width, box and box.height or f.height
    local px = {}; for i = 1, w*h do px[i] = 0 end
    local dx, dy = box and f.x or 0, box and f.y or 0
    if dx+f.width > w or dy+f.height > h then return nil end
    for y = 0, f.height-1 do for x = 0, f.width-1 do
        px[(dy+y)*w+dx+x+1] = d:byte(y*f.width+x+1)
    end end
    return px, w, h
end
local function tile_pixels(d, e)
    if not d or #d ~= e.size then return nil end
    local w, h = e.kind == "map" and 176 or 256, e.kind == "map" and 160 or math.ceil(e.tiles/16)*16
    local px = {}; for i = 1, w*h do px[i] = 0 end
    local cols, total = w/16, e.kind == "map" and 110 or e.tiles
    for i = 0, total-1 do
        local tile = e.kind == "map" and e.cells[i+1] or i
        -- Zero denotes empty space on maps, even if tile zero has pixels.
        if e.kind ~= "map" or tile ~= 0 then
            if (tile+1)*256 > #d then return nil end
            local dx, dy = i%cols*16, math.floor(i/cols)*16
            for y = 0, 15 do for x = 0, 15 do px[(dy+y)*w+dx+x+1] = d:byte(tile*256+y*16+x+1) end end
        end
    end
    return px, w, h
end
function engine.load_resource(path, id, palette_id)
    local idx = build_index(path)
    local e = idx.entries[id]
    if not e then return nil end
    if e.kind == "text" then return { type="text", text=e.text } end
    if e.kind == "sound" then
        local d = read(path .. "/" .. e.file, e.offset, e.size)
        if not d then return nil end
        return {type="sound",sound=sound_create_pcm(22050,8,1,false,d),description=e.file .. ": unsigned 8-bit mono PCM, 22050 Hz"}
    end
    local pal = palette_id and idx.palettes[palette_id] or idx.palettes[e.palette_id]
    if e.kind == "palette" then
        return {type="image",image=image_create_indexed(256,256,swatch,e.palette),palette_colors=e.colors}
    end
    if not pal or (palette_id and not idx.palettes[palette_id]) then return {type="text",text="A valid DreamWeb palette is required."} end
    local function image_frame(f, box)
        local px,w,h = frame_pixels(read(path .. "/" .. f.file,f.offset,f.size),f,box)
        return px and image_create_indexed(w,h,px,pal,0)
    end
    if e.kind == "animation" then
        local handles = {}
        for _, f in ipairs(e.sequence) do
            local image = image_frame(f,e.box)
            if not image then return nil end
            handles[#handles+1] = image
        end
        return {type="animation",animation=animation_create(handles,e.delay),delay_ms=e.delay,
            description="Constant object sequence; original frame offsets; nominal 70 Hz game timing (four retraces per sprite update)."}
    end
    local image, description
    if e.kind == "frame" then
        image = image_frame(e)
        description = string.format("%s; %dx%d; frame origin +%d,+%d; transparent index 0",e.file,e.width,e.height,e.x,e.y)
    elseif e.kind == "pcx" then
        local d = whole(path .. "/" .. e.file)
        local px = d and pcx_pixels(d,e)
        image = px and image_create_indexed(e.width,e.height,px,pal)
        description = e.file .. "; original PCX dimensions and embedded palette"
    elseif e.kind == "map" or e.kind == "tiles" then
        local px,w,h = tile_pixels(read(path .. "/" .. e.file,e.offset,e.size),e)
        image = px and image_create_indexed(w,h,px,pal)
        description = e.kind == "map" and "176x160 tiled background; objects, actors and runtime shadows are separate." or "16x16 backdrop tiles in original index order"
    end
    if not image then return nil end
    local palette_entry = idx.entries[palette_id or e.palette_id]
    return {type="image",image=image,palette_image=image_create_indexed(256,256,swatch,pal),
        palette_colors=palette_entry and palette_entry.colors or 256,description=description}
end
return engine

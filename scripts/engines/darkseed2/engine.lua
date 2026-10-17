-- ============================================================================
-- Adventure Explorer - Engine Script: Dark Seed 2 (Cyberdreams, 1995)
-- ============================================================================
-- Assets live in "Glue" archives (GL00_NNN.000) that are either stored raw or
-- LZ compressed in 2048 byte chunks. GFILE.HDR is a master index listing every
-- archive plus a flat directory of every resource inside them, so the resource
-- tree can be built without decompressing a single byte.
--
-- GFILE.HDR (little endian, sizes confirmed against the archives):
--   u16 archiveCount, u16 resourceCount
--   archiveCount  x 64 byte records, archive name (12 bytes) at record start
--   resourceCount x 22 byte records:
--       u16 archiveIndex, char name[12], u32 size, u32 offset
--   size/offset are relative to the DECOMPRESSED archive.
--
-- Archive: u16 count, then count x { char name[12], u32 size, u32 offset }
--
-- Compression: 2048 byte physical chunks. The first chunk keeps the
-- uncompressed size as u32le at offset 2044 (plus 128). Each chunk is a run of
-- 17 byte groups - one mask byte driving eight operations - where a set bit
-- copies two literal bytes and a clear bit reads a u16 back-reference
-- (offset = (raw >> 4) + 1, count = (raw & 0xF) + 3). Back-references never
-- reach further back than 4096 bytes.
--
-- Backgrounds: one 640x480 8bpp uncompressed Windows BMP per room, named
-- RM%04d.BMP. All 3826 BMP names in the game are unique, so they are used
-- directly as resource ids. Other BMPs are sprites/UI or room thumbnails.
-- Palette-less sprites use the room BMP in the same archive, or FIX.PAL
-- (256 BGR0 quads) for the shared walking/action/inventory archives.
-- ============================================================================

local engine = {}
engine.name        = "Dark Seed 2"
engine.id          = "darkseed2"
engine.description = "Dark Seed 2 (1995, Cyberdreams)"
engine.version     = "1.1"

local GFILE_NAME = "GFILE.HDR"

local CHUNK_SIZE = 2048          -- physical chunk size
local CHUNK_WORK = 2040          -- 2048 - 8, i.e. whole 17 byte groups
local MAX_OUTPUT = 10 * 1024 * 1024

local BG_NAME    = "^RM%d%d%d%d%.BMP$"   -- RM0001.BMP, ...
local READ_CHUNK = 65536

-- Binary helpers ---------------------------------------------------------

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end

-- NUL terminated fixed width string
local function cstr(data, pos, len)
    local s = ""
    for i = 0, len - 1 do
        local b = data:byte(pos + i)
        if b == nil or b == 0 then break end
        s = s .. string.char(b)
    end
    return s
end

local function read_whole(path)
    local fh = file_open(path)
    if not fh then return nil end
    local size = file_size(fh)
    if not size or size <= 0 then
        file_close(fh)
        return nil
    end

    local parts = {}
    local got = 0
    while got < size do
        local want = size - got
        if want > READ_CHUNK then want = READ_CHUNK end
        local chunk = file_read(fh, got, want)
        if not chunk or #chunk == 0 then break end
        parts[#parts + 1] = chunk
        got = got + #chunk
    end
    file_close(fh)

    if got ~= size then return nil end
    return table.concat(parts)
end

-- GFILE.HDR --------------------------------------------------------------

-- Cache the active game's index for frame browsing; rebuilding the tree refreshes it.
local index_cache
-- Returns archives (index -> name) and dir (UPPERCASE name -> entry) or nil.
local function parse_gfile(game_path)
    if index_cache and index_cache.path == game_path then
        return index_cache.archives, index_cache.dir
    end
    local data = read_whole(game_path .. "/" .. GFILE_NAME)
    if not data or #data < 4 then return nil end

    local narch = u16le(data, 1)
    local nres  = u16le(data, 3)
    if narch == 0 or nres == 0 then return nil end

    -- Exact size check guards against picking up an unrelated index file
    if 4 + narch * 64 + nres * 22 ~= #data then return nil end

    local archives = {}
    for i = 0, narch - 1 do
        archives[i + 1] = cstr(data, 5 + i * 64, 12)
    end

    local base = 5 + narch * 64
    local dir = {}
    for i = 0, nres - 1 do
        local o = base + i * 22
        local idx = u16le(data, o) + 1        -- GFILE indices are 0-based
        local name = cstr(data, o + 2, 12):upper()
        if name ~= "" and archives[idx] then
            dir[name] = {
                archive = idx,
                size    = u32le(data, o + 14),
                offset  = u32le(data, o + 18),
            }
        end
    end

    index_cache = { path = game_path, archives = archives, dir = dir }
    return archives, dir
end

-- Glue archives ----------------------------------------------------------

-- The reference tool decides by trying to read a resource list straight out of
-- the file: if that fails the archive is compressed.
local function glue_is_compressed(data, fsize)
    if fsize < 2 then return true end
    local nres = u16le(data, 1)
    if 2 + nres * 20 > fsize then return true end

    local pos = 3
    for _ = 1, nres do
        -- Only alphanumerics, '.' and '_' may appear in a resource name
        for i = 0, 11 do
            local b = data:byte(pos + i)
            if b == 0 then break end
            local ok = (b >= 48 and b <= 57)      -- 0-9
                 or (b >= 65 and b <= 90)         -- A-Z
                 or (b >= 97 and b <= 122)        -- a-z
                 or b == 46                       -- .
                 or b == 95                        -- _
            if not ok then return true end
        end
        local size   = u32le(data, pos + 12)
        local offset = u32le(data, pos + 16)
        if size + offset > fsize then return true end
        pos = pos + 20
    end
    return false
end

-- Decompress into a 1-based byte table. Returns out, size (or nil, err).
-- The input buffer is treated as zero padded past the end of the file, which
-- is how the reference tool's fixed 2048 byte chunk buffer behaves.
local function glue_decompress(data, dsize)
    if dsize < CHUNK_SIZE then return nil, "archive smaller than one chunk" end

    -- The uncompressed size sits in the first chunk's 4 byte trailer
    local total = u32le(data, CHUNK_SIZE - 3) + 128
    if total < 0 or total > MAX_OUTPUT then
        return nil, "implausible uncompressed size"
    end

    local limit = total + 64       -- a final back-reference may overshoot
    local out = {}
    local w = 0                    -- bytes produced so far
    local start = 1                -- 1-based index of the current chunk

    while start <= dsize and w < limit do
        local nread = dsize - start + 1
        if nread > CHUNK_SIZE then nread = CHUNK_SIZE end

        local work = CHUNK_WORK
        if nread ~= CHUNK_SIZE then
            -- Round the tail up to whole 17 byte groups
            work = math.floor((nread + 16) / 17) * 17
        end

        -- The first byte of the chunk is the operation mask
        local p = start
        local mask = 0xFF00 + (data:byte(p) or 0)
        p = p + 1
        local consumed = 0

        while true do
            if mask % 2 == 1 then
                -- Literal: copy two bytes
                out[w + 1] = data:byte(p) or 0
                out[w + 2] = data:byte(p + 1) or 0
                p = p + 2
                w = w + 2
            else
                local raw = (data:byte(p) or 0) + (data:byte(p + 1) or 0) * 256
                p = p + 2
                local offset = math.floor(raw / 16) + 1
                local count  = (raw % 16) + 3
                -- The reference always writes 8 bytes and then, for a longer
                -- run, 10 more; only the first `count` bytes are kept.
                for i = 0, 7 do
                    local src = w + 1 + i - offset
                    out[w + 1 + i] = src >= 1 and out[src] or 0
                end
                if count > 8 then
                    for i = 0, 9 do
                        local src = w + 9 + i - offset
                        out[w + 9 + i] = src >= 1 and out[src] or 0
                    end
                end
                w = w + count
            end

            mask = math.floor(mask / 2)
            if mask < 256 then          -- the 0xFF sentinel has been shifted out
                consumed = consumed + 17
                if consumed >= work then break end
                mask = 0xFF00 + (data:byte(p) or 0)
                p = p + 1
            end
        end

        start = start + CHUNK_SIZE
    end

    -- The reference allocates the declared size and leaves the unwritten tail
    -- zeroed; the last chunk normally stops a little short of it.
    if w < total then
        for i = w + 1, total do out[i] = 0 end
    end

    return out, total
end

-- Keep only the most recently used archive; sprite browsing otherwise repeats
-- the same decompression for every frame. The game path is part of the key.
local archive_cache
local function read_resource(game_path, archives, entry)
    local path = game_path .. "/" .. archives[entry.archive]
    if not archive_cache or archive_cache.path ~= path then
        local raw = read_whole(path)
        if not raw then return nil, "cannot read " .. path end
        local data, size = raw, #raw
        if glue_is_compressed(raw, #raw) then
            data, size = glue_decompress(raw, #raw)
            if not data then return nil, size end
        end
        archive_cache = { path = path, data = data, size = size }
    end
    local data, size = archive_cache.data, archive_cache.size
    local base = entry.offset
    if entry.size <= 0 then return nil, "empty resource" end
    if base + entry.size > size then return nil, "resource past end of archive" end
    if type(data) == "string" then
        return function(i) if i >= 1 and i <= entry.size then return data:byte(base + i) end end, entry.size
    end
    return function(i) if i >= 1 and i <= entry.size then return data[base + i] end end, entry.size
end

-- BMP -------------------------------------------------------------------

local function u16at(getb, pos)
    return getb(pos) + getb(pos + 1) * 256
end

local function u32at(getb, pos)
    return getb(pos) + getb(pos + 1) * 256
         + getb(pos + 2) * 65536 + getb(pos + 3) * 16777216
end

local function i32at(getb, pos)
    local v = u32at(getb, pos)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

-- Decode a Windows BMP through the 1-based getter `getb`. Returns an image
-- table, or nil plus a message.
local function decode_bmp(getb, len, label, override_palette, palette_label)
    if len < 54 then return nil, "BMP too small" end
    if getb(1) ~= 0x42 or getb(2) ~= 0x4D then
        return nil, "not a Windows BMP"
    end

    local dataoff = u32at(getb, 11)
    local hdrsize = u32at(getb, 15)
    if hdrsize < 40 or 14 + hdrsize > len then return nil, "unsupported BMP header" end
    if dataoff < 14 + hdrsize or dataoff > len then return nil, "invalid BMP data offset" end

    local w = i32at(getb, 19)
    local h = i32at(getb, 23)
    local bpp = u16at(getb, 29)
    local comp = u32at(getb, 31)
    local ncol = u32at(getb, 47)

    if w <= 0 or h == 0 or w > 8192 or math.abs(h) > 8192 then
        return nil, "implausible BMP dimensions"
    end
    local topdown = h < 0
    if topdown then h = -h end
    if bpp ~= 8 and bpp ~= 4 then
        return nil, "unsupported BMP depth: " .. tostring(bpp)
    end
    -- Dark Seed 2 only ever writes two variants: biCompression 0 for a plain
    -- BI_RGB image, and 2 for its own scanline format (see below). Despite
    -- the 2, the latter is not RLE - nothing in the game is run length coded.
    if comp == 2 then
        if bpp ~= 8 then
            return nil, "unexpected depth for scanline image: " .. tostring(bpp)
        end
    elseif comp ~= 0 then
        return nil, "unsupported BMP compression: " .. tostring(comp)
    end
    local scanlines = (comp == 2)

    if ncol == 0 then ncol = 256 end
    if bpp == 4 and ncol > 16 then ncol = 16 end
    if bpp == 8 and ncol > 256 then ncol = 256 end

    -- Only palette quads that lie before the pixel data actually exist. A
    -- data offset of 54 (a bare 40-byte header) means the image carries no
    -- palette at all, so use a room/shared palette supplied by the caller.
    -- Clamp to what is really there instead of reading colour
    -- tables out of the pixel stream.
    local avail = math.floor((dataoff - 14 - hdrsize) / 4)
    if avail < 0 then avail = 0 end
    if ncol > avail then ncol = avail end

    -- Palette: BGRA quads, flattened to RGB triples for image_create_indexed
    local palette = {}
    local palbase = 15 + hdrsize                -- 1-based index of first quad
    for i = 0, ncol - 1 do
        local o = palbase + i * 4
        palette[i * 3 + 1] = getb(o + 2)        -- R
        palette[i * 3 + 2] = getb(o + 1)        -- G
        palette[i * 3 + 3] = getb(o)            -- B
    end
    for i = ncol * 3 + 1, 768 do palette[i] = 0 end

    if override_palette then palette = override_palette end
    local pixels = {}
    -- Cropped scanlines leave holes; give them a deterministic background index.
    for i = 1, w * h do pixels[i] = 0 end
    local rowbytes = math.floor((w * bpp / 8 + 3) / 4) * 4

    if scanlines then
        -- Each row is stored as u16 xOffset, u16 length, then `length` raw
        -- 8bpp pixels, unpadded, in BMP row order (bottom-up for h > 0).
        -- Rows may be cropped, which is how
        -- the game's perspective-projected sprites are stored.
        local pos = dataoff + 1
        local total = w * h
        for y = 0, h - 1 do
            if pos + 3 > len then return nil, "truncated scanline header" end
            local xoff = u16at(getb, pos)
            local rlen = u16at(getb, pos + 2)
            pos = pos + 4
            if xoff + rlen > w then return nil, "scanline exceeds image width" end
            if pos + rlen - 1 > len then return nil, "truncated scanline pixels" end
            local row = topdown and y or (h - 1 - y)
            local dst = row * w + xoff
            for i = 0, rlen - 1 do
                local k = dst + i + 1
                if k >= 1 and k <= total then pixels[k] = getb(pos + i) end
            end
            pos = pos + rlen
        end
    else
        if dataoff + rowbytes * h > len then return nil, "truncated BMP pixels" end
        for y = 0, h - 1 do
            -- BMP stores rows bottom-up unless the height is negative
            local row = topdown and y or (h - 1 - y)
            local src = dataoff + y * rowbytes + 1
            local dst = row * w
            if bpp == 8 then
                for x = 0, w - 1 do
                    pixels[dst + x + 1] = getb(src + x)
                end
            else
                for x = 0, w - 1 do
                    local b = getb(src + math.floor(x / 2))
                    if x % 2 == 0 then
                        pixels[dst + x + 1] = math.floor(b / 16)
                    else
                        pixels[dst + x + 1] = b % 16
                    end
                end
            end
        end
    end

    local img = image_create_indexed(w, h, pixels, palette)
    local colors
    if override_palette then
        colors = "palette: " .. (palette_label or "selected")
    elseif ncol == 0 then
        colors = "no palette in file"
    else
        colors = ncol .. " colors"
    end
    return {
        type = "image",
        image = img,
        width = w,
        height = h,
        description = string.format("%s - %dx%d, %s%s", label, w, h, colors,
            topdown and ", top-down" or ""),
    }
end

-- Palette sources are named resources, so the UI can also select room colours
-- manually for shared assets. FIX.PAL is BGR0, exactly like a BMP colour table.
local palette_cache = { path = nil, values = {} }
local function load_palette(game_path, archives, dir, name)
    if palette_cache.path ~= game_path then
        palette_cache = { path = game_path, values = {} }
    end
    if palette_cache.values[name] then return palette_cache.values[name] end
    local entry = dir[name]
    if not entry then return nil, "palette resource not found: " .. name end
    local getb, len = read_resource(game_path, archives, entry)
    if not getb then return nil, len end
    local start, count = 1, 256
    if name:match("%.BMP$") then
        if len < 54 or getb(1) ~= 66 or getb(2) ~= 77 then return nil, "invalid palette BMP" end
        local hdrsize, dataoff = u32at(getb, 15), u32at(getb, 11)
        if hdrsize < 40 or dataoff > len then return nil, "invalid palette header" end
        start = 15 + hdrsize
        count = math.min(256, math.floor((dataoff - 14 - hdrsize) / 4))
        local used = u32at(getb, 47)
        if used > 0 then count = math.min(count, used) end
    end
    if count <= 0 or start + count * 4 - 1 > len then return nil, "missing palette data" end
    local palette = {}
    for i = 0, 255 do
        local o = start + i * 4
        palette[i * 3 + 1] = i < count and getb(o + 2) or 0
        palette[i * 3 + 2] = i < count and getb(o + 1) or 0
        palette[i * 3 + 3] = i < count and getb(o) or 0
    end
    palette_cache.values[name] = palette
    return palette
end

local function room_palettes(dir)
    local rooms = {}
    for name, entry in pairs(dir) do
        if name:match(BG_NAME) then rooms[entry.archive] = name end
    end
    return rooms
end

local function palette_for(dir, rooms, name)
    local entry = dir[name]
    if not entry then return nil end
    return rooms[entry.archive] or (dir["FIX.PAL"] and "FIX.PAL")
end

-- Engine interface -------------------------------------------------------

function engine.detect(game_path)
    if not file_exists(game_path .. "/" .. GFILE_NAME) then return false end
    if not file_exists(game_path .. "/DARK0001.EXE") then return false end
    return true
end

function engine.get_resources(game_path)
    index_cache, archive_cache = nil, nil
    palette_cache = { path = game_path, values = {} }
    local archives, dir = parse_gfile(game_path)
    if not archives then return {} end
    local rooms = room_palettes(dir)
    local backgrounds = { id = "backgrounds", name = "Backgrounds", type = "category", children = {} }
    local sprites = { id = "sprites", name = "Sprites and UI", type = "category", children = {} }
    local maps = { id = "thumbnails", name = "Room Thumbnails", type = "category", children = {} }
    local palettes = { id = "palettes", name = "Palettes", type = "category", children = {} }
    local groups, names, sprite_count = {}, {}, 0
    for name in pairs(dir) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local base = name:match("^(.+)%.BMP$")
        if base then
            local node = { id = "img_" .. base, name = base, type = "image" }
            if name:match(BG_NAME) then
                node.id = "bg_" .. base
                backgrounds.children[#backgrounds.children + 1] = node
                palettes.children[#palettes.children + 1] = { id = "pal_" .. name, name = base, type = "palette" }
            elseif name:match("^RMAP%d%d%d%d%.BMP$") then
                maps.children[#maps.children + 1] = node
            else
                node.id = "spr_" .. base
                local a = dir[name].archive
                if not groups[a] then
                    local label = rooms[a] and ("Room " .. rooms[a]:match("^RM(%d+)")) or archives[a]:upper()
                    groups[a] = { id = "sprites_" .. a, name = label, type = "category", children = {} }
                end
                local children = groups[a].children
                children[#children + 1] = node
                sprite_count = sprite_count + 1
            end
        elseif name:match("%.PAL$") then
            palettes.children[#palettes.children + 1] = { id = "pal_" .. name, name = name, type = "palette" }
        end
    end
    for a = 1, #archives do
        if groups[a] then sprites.children[#sprites.children + 1] = groups[a] end
    end
    sprites.name = string.format("Sprites and UI (%d)", sprite_count)
    local resources = {}
    for _, cat in ipairs({ backgrounds, sprites, maps, palettes }) do
        if #cat.children > 0 then
            if cat ~= sprites then cat.name = string.format("%s (%d)", cat.name, #cat.children) end
            resources[#resources + 1] = cat
        end
    end
    return resources
end

function engine.default_palette(game_path, resource_id)
    local base = resource_id:match("^spr_(.+)$") or resource_id:match("^img_(.+)$")
    if not base then return nil end
    local archives, dir = parse_gfile(game_path)
    if not archives then return nil end
    local name = base:upper()
    if not name:match("%.BMP$") then name = name .. ".BMP" end
    if not dir[name] then return nil end
    local getb, size = read_resource(game_path, archives, dir[name])
    if not getb or size < 54 or u32at(getb, 11) ~= 54 then return nil end
    local pal = palette_for(dir, room_palettes(dir), name)
    return pal and ("pal_" .. pal)
end

-- Keep the existing bg_/img_/bare-name ids usable.
function engine.load_resource(game_path, resource_id, palette_id)
    local archives, dir = parse_gfile(game_path)
    if not archives then return { type = "text", text = "GFILE.HDR missing or malformed" } end
    local palname = resource_id:match("^pal_(.+)$")
    if palname then
        local palette, err = load_palette(game_path, archives, dir, palname)
        if not palette then return { type = "text", text = tostring(err) } end
        local pixels = {}
        for y = 0, 127 do
            for x = 0, 127 do pixels[y * 128 + x + 1] = math.floor(y / 8) * 16 + math.floor(x / 8) end
        end
        return { type = "image", image = image_create_indexed(128, 128, pixels, palette),
            width = 128, height = 128, description = "Palette: " .. palname }
    end
    local base = resource_id:match("^bg_(.+)$") or resource_id:match("^img_(.+)$")
        or resource_id:match("^spr_(.+)$") or resource_id
    base = base:upper():gsub("%.BMP$", "")
    if not base:match("^[%w_]+$") then return nil end
    local want = base .. ".BMP"
    local entry = dir[want]
    if not entry then return { type = "text", text = "Resource not found: " .. want } end

    -- Embedded palettes remain authoritative unless the user selects an override.
    local getb, size = read_resource(game_path, archives, entry)
    if not getb then return { type = "text", text = "Failed to read " .. want .. ": " .. tostring(size) } end
    local palette, palette_label
    if palette_id then
        palette_label = palette_id:match("^pal_(.+)$")
        if not palette_label then return { type = "text", text = "Invalid palette: " .. palette_id } end
    elseif size >= 54 and u32at(getb, 11) == 54 then
        palette_label = palette_for(dir, room_palettes(dir), want)
    end
    if palette_label then
        local err
        palette, err = load_palette(game_path, archives, dir, palette_label)
        if not palette then return { type = "text", text = "Failed to load palette: " .. tostring(err) } end
    end
    local label = string.format("%s (%s)", want, archives[entry.archive])
    local res, err = decode_bmp(getb, size, label, palette, palette_label)
    if not res then return { type = "text", text = "Failed to decode " .. want .. ": " .. tostring(err) } end
    return res
end

return engine

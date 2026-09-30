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
-- directly as resource ids.
-- ============================================================================

local engine = {}
engine.name        = "Dark Seed 2"
engine.id          = "darkseed2"
engine.description = "Dark Seed 2 (1995, Cyberdreams)"
engine.version     = "1.0"

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

-- Returns archives (index -> name) and dir (UPPERCASE name -> entry) or nil.
local function parse_gfile(game_path)
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

    return archives, dir
end

-- Glue archives ----------------------------------------------------------

-- The reference tool decides by trying to read a resource list straight out of
-- the file: if that fails the archive is compressed.
local function glue_is_compressed(data, fsize)
    local nres = u16le(data, 1)
    if fsize <= nres * 22 then return true end

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

-- Read one resource out of its archive. Returns a 1-based byte getter.
local function read_resource(game_path, archives, entry)
    local path = game_path .. "/" .. archives[entry.archive]
    local raw = read_whole(path)
    if not raw then return nil, "cannot read " .. path end

    local size = entry.size
    if size <= 0 then return nil, "empty resource" end

    if not glue_is_compressed(raw, #raw) then
        local offset = entry.offset
        if offset + size > #raw then return nil, "resource past end of archive" end
        local blob = raw:sub(offset + 1, offset + size)
        return function(i) return blob:byte(i) end, size
    end

    local out, outsize = glue_decompress(raw, #raw)
    if not out then return nil, outsize end

    local base = entry.offset
    if base + size > outsize then return nil, "resource past end of decompressed data" end
    return function(i) return out[base + i] end, size
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

-- Decode the 8bpp BI_RLE8 stream into `pixels`, starting at row `y0`.
local function rle8(getb, pos, limit, w, h, pixels, y0)
    local y = y0
    local x = 0
    while pos < limit do
        local n = getb(pos)
        pos = pos + 1
        if n == 0 then
            local code = getb(pos)
            pos = pos + 1
            if code == 0 then                       -- end of line
                y = y + 1
                x = 0
            elseif code == 1 then                   -- end of bitmap
                return pos, y, x, true
            elseif code == 2 then                   -- delta
                x = x + getb(pos)
                y = y + getb(pos + 1)
                pos = pos + 2
            else                                    -- absolute mode
                local padded = code + (code % 2)
                for i = 0, code - 1 do
                    if y >= 0 and y < h and x + i < w then
                        pixels[y * w + x + i + 1] = getb(pos + i)
                    end
                end
                pos = pos + padded
                x = x + code
            end
        else
            local c = getb(pos)
            pos = pos + 1
            for i = 0, n - 1 do
                if y >= 0 and y < h and x + i < w then
                    pixels[y * w + x + i + 1] = c
                end
            end
            x = x + n
        end
    end
    return pos, y, x, false
end

-- Decode a Windows BMP through the 1-based getter `getb`. Returns an image
-- table, or nil plus a message.
local function decode_bmp(getb, len, label)
    if len < 54 then return nil, "BMP too small" end
    if getb(1) ~= 0x42 or getb(2) ~= 0x4D then
        return nil, "not a Windows BMP"
    end

    local dataoff = u32at(getb, 11)
    local hdrsize = u32at(getb, 15)
    if hdrsize < 40 then return nil, "unsupported BMP header" end

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
    -- BI_RGB / BI_RLE8 are understood; BI_RLE4 does not occur in this game
    if comp == 1 and bpp == 8 then
        -- RLE8
    elseif comp == 0 then
        -- uncompressed
    else
        return nil, "unsupported BMP compression: " .. tostring(comp)
    end
    local rle = (comp == 1)

    if ncol == 0 then ncol = 256 end
    if bpp == 4 and ncol > 16 then ncol = 16 end
    if bpp == 8 and ncol > 256 then ncol = 256 end

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

    local pixels = {}
    local rowbytes = math.floor((w * bpp / 8 + 3) / 4) * 4

    if not rle then
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
    else
        -- RLE produces rows top-down
        rle8(getb, dataoff + 1, len, w, h, pixels, 0)
    end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image",
        image = img,
        width = w,
        height = h,
        description = string.format("%s - %dx%d, %d colors%s", label, w, h, ncol,
            topdown and ", top-down" or ""),
    }
end

-- Engine interface -------------------------------------------------------

function engine.detect(game_path)
    if not file_exists(game_path .. "/" .. GFILE_NAME) then return false end
    if not file_exists(game_path .. "/DARK0001.EXE") then return false end
    return true
end

function engine.get_resources(game_path)
    local resources = {}
    local archives, dir = parse_gfile(game_path)
    if not archives then return resources end

    -- Backgrounds are the per-room RM%04d.BMP images. Their 640x480 size is
    -- only known once the archive is decompressed, so the cheap name pattern
    -- is used to build the tree; load_resource verifies the geometry.
    local names = {}
    for name in pairs(dir) do
        if name:match(BG_NAME) then names[#names + 1] = name end
    end
    table.sort(names)

    if #names > 0 then
        local cat = {
            id = "backgrounds",
            name = string.format("Backgrounds (%d)", #names),
            type = "category",
            children = {}
        }
        for _, name in ipairs(names) do
            local base = name:match("^(.+)%.BMP$")
            cat.children[#cat.children + 1] = {
                id = "bg_" .. base,
                name = base,
                type = "image"
            }
        end
        resources[#resources + 1] = cat
    end

    return resources
end

function engine.load_resource(game_path, resource_id, palette_id)
    local base = resource_id:match("^bg_(.+)$")
    if not base then return nil end
    if base:match("%.BMP$") then base = base:match("^(.+)%.BMP$") end
    local want = base:upper() .. ".BMP"

    local archives, dir = parse_gfile(game_path)
    if not archives then
        return { type = "text", text = "GFILE.HDR missing or malformed" }
    end

    local entry = dir[want]
    if not entry then
        return { type = "text", text = "Resource not found: " .. want }
    end

    local getb, size = read_resource(game_path, archives, entry)
    if not getb then
        return { type = "text", text = "Failed to read " .. want .. ": " .. tostring(size) }
    end

    local label = string.format("%s (%s)", want, archives[entry.archive])
    local res, err = decode_bmp(getb, size, label)
    if not res then
        return { type = "text", text = "Failed to decode " .. want .. ": " .. tostring(err) }
    end
    return res
end

return engine

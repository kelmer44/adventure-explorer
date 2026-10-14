-- ============================================================================
-- Adventure Explorer - Engine Script: Beneath a Steel Sky (Revolution, 1994)
-- ============================================================================
-- Files: SKY.DSK (data), SKY.DNR (file table), SKY.CFG, SKY.RST
--
-- The game stores every resource (backgrounds, sprites, palettes, scripts,
-- music...) inside SKY.DSK. SKY.DNR is the "dinner table", an index that maps
-- a 16-bit file number to an (offset, size, flags) triple inside SKY.DSK.
--
-- Graphic files begin with a 22-byte DataFileHeader (all little-endian u16):
--   flag, s_x, s_y, s_width, s_height, s_sp_size, s_tot_size, s_n_sprites,
--   s_offset_x, s_offset_y, s_compressed_size
-- The pixel payload that follows is either raw 8bpp or RNC (Rob Northen)
-- compressed. Two layouts exist:
--   * Sprites   : s_sp_size == s_width*s_height, one frame per s_sp_size bytes
--   * Screens   : s_sp_size == 0, a single full-screen w*h image
--
-- Validated against ScummVM's engines/sky (disk.cpp / screen.cpp) and the
-- common RNC decompressor (common/compression/rnc_deco.cpp).
-- ============================================================================

local engine = {}
engine.name        = "Beneath a Steel Sky"
engine.id          = "sky"
engine.description = "Beneath a Steel Sky (Revolution Software, 1994)"
engine.version     = "1.0"

-- ============================================================================
-- Binary helpers
-- ============================================================================

local function u8(s, i) return s:byte(i) or 0 end
local function u16le(s, i)
    local a, b = s:byte(i, i + 1)
    if not a then return 0 end
    return a + (b or 0) * 256
end
local function u32le(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not a then return 0 end
    return a + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216
end
local function u32be(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not a then return 0 end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local band, bor, lshift, rshift =
    bit32.band, bit32.bor, bit32.lshift, bit32.rshift

-- ============================================================================
-- File I/O helpers
-- ============================================================================

local function read_at(fh, offset, length)
    if length <= 0 then return "" end
    local data = file_read(fh, offset, length)
    return data or ""
end

local function read_all(path)
    local fh = file_open(path)
    if not fh then return nil end
    local sz = file_size(fh)
    if not sz or sz <= 0 then file_close(fh); return nil end
    local data = file_read(fh, 0, math.floor(sz))
    file_close(fh)
    return data
end

-- ============================================================================
-- RNC "unpackM1" decompressor (port of ScummVM common/compression/rnc_deco.cpp)
-- ============================================================================

local function rnc_unpack(src)
    local n = #src
    if n < 18 then return nil end
    if u32be(src, 1) ~= 0x524E4301 then return nil end   -- "RNC\x01"

    local unpackLen = u32be(src, 5)
    if unpackLen <= 0 or unpackLen > 16 * 1024 * 1024 then return nil end

    local blocks = u8(src, 18)                            -- *(inputptr+5), inputptr=12
    if blocks < 1 then blocks = 1 end

    local pos = 18          -- 0-based _srcPtr (data starts at HEADER_LEN=18)
    local byteleft = n - 18 -- _inputByteLeft
    local bl, bh, bc = 0, 0, 0

    local function inputBits(amount)
        local ret = band(lshift(1, amount) - 1, bl)
        local nbc = bc - amount
        if nbc < 0 then
            nbc = nbc + amount
            local rem = band(lshift(bh, 16 - nbc), 0xffff)
            bh = rshift(bh, nbc)
            bl = rshift(bl, nbc)
            bl = bor(bl, rem)
            pos = pos + 2
            byteleft = byteleft - 2
            if byteleft <= 0 then
                bh = 0
            elseif byteleft == 1 then
                bh = u8(src, pos + 1)
            else
                bh = u16le(src, pos + 1)
            end
            amount = amount - nbc
            nbc = 16 - amount
        end
        local rem = band(lshift(bh, 16 - amount), 0xffff)
        bh = rshift(bh, amount)
        bl = bor(rshift(bl, amount), rem)
        bc = nbc
        return ret
    end

    local function makeHuff(tb)
        local numCodes = inputBits(5)
        if numCodes == 0 then return end
        local lens = {}
        for i = 1, numCodes do lens[i] = band(inputBits(4), 0xff) end
        local huffCode = 0
        local p = 0                                       -- 0-based table pointer
        for blen = 1, 16 do
            for i = 1, numCodes do
                if lens[i] == blen then
                    tb[p] = lshift(1, blen) - 1; p = p + 1
                    local b = rshift(huffCode, 16 - blen)
                    local a = 0
                    for j = 0, blen - 1 do
                        a = bor(a, lshift(band(rshift(b, j), 1), blen - j - 1))
                    end
                    tb[p] = a; p = p + 1
                    tb[p + 0x1e] = bor(lshift(lens[i], 8), band(i - 1, 0xff))
                    huffCode = huffCode + lshift(1, 16 - blen)
                end
            end
        end
    end

    local function inputValue(tb)
        local value = bl
        local p = 0
        while true do
            local valTwo = band(tb[p], value); p = p + 1
            local valOne = tb[p]; p = p + 1
            if valOne == valTwo then break end
        end
        value = tb[p + 0x1e]
        inputBits(band(rshift(value, 8), 0xff))
        value = band(value, 0xff)
        if value >= 2 then
            value = value - 1
            local v = band(inputBits(value), 0xff)
            v = bor(v, lshift(1, value))
            value = v
        end
        return value
    end

    bl = u16le(src, 19)   -- READ_LE_UINT16(input+18)
    bh = 0; bc = 0
    inputBits(2)

    local out = {}
    local outlen = 0

    for _ = 1, blocks do
        local raw, ptb, ltb = {}, {}, {}
        makeHuff(raw); makeHuff(ptb); makeHuff(ltb)
        local counts = inputBits(16)
        repeat
            local L = inputValue(raw)
            if L and L > 0 then
                if pos + L > n then return nil end
                for k = 0, L - 1 do
                    outlen = outlen + 1
                    out[outlen] = u8(src, pos + k + 1)
                end
                pos = pos + L
                byteleft = byteleft - L
                local a
                if byteleft <= 0 then a = 0
                elseif byteleft == 1 then a = u8(src, pos + 1)
                else a = u16le(src, pos + 1) end
                local b
                if byteleft <= 2 then b = 0
                elseif byteleft == 3 then b = u8(src, pos + 3)
                else b = u16le(src, pos + 3) end
                bl = band(bl, lshift(1, bc) - 1)
                bl = band(bor(bl, lshift(a, bc)), 0xffff)
                bh = band(bor(rshift(a, 16 - bc), lshift(b, bc)), 0xffff)
            end
            if counts > 1 then
                local off = inputValue(ptb) + 1
                L = inputValue(ltb) + 2
                local start = outlen - off + 1
                if start < 1 then return nil end
                for k = 0, L - 1 do
                    outlen = outlen + 1
                    out[outlen] = out[start + k] or 0
                end
            end
            counts = counts - 1
        until counts == 0
    end

    return out, outlen
end

local function packbytes(t, len)
    local chunks = {}
    local i = 1
    while i <= len do
        local e = i + 4095
        if e > len then e = len end
        local row = {}
        for j = i, e do row[#row + 1] = t[j] end
        chunks[#chunks + 1] = string.char(table.unpack(row))
        i = e + 1
    end
    return table.concat(chunks)
end

-- ============================================================================
-- SKY.DNR "dinner table" parsing
-- ============================================================================

-- Returns a table: fileNum -> { offset, size, compressed, incHeader }
local function parse_dnr(dnr)
    local count = u32le(dnr, 1)
    local map = {}
    for i = 0, count - 1 do
        local base = 5 + i * 8                 -- 1-based entry start (C: 4+i*8)
        local fnum = u16le(dnr, base)
        if fnum ~= 0xffff then
            local foRaw = u32le(dnr, base + 2)
            local b5 = u8(dnr, base + 5)
            local b6 = u8(dnr, base + 6)
            local b7 = u8(dnr, base + 7)
            local ff = b5 + b6 * 256 + b7 * 65536
            local offset = band(foRaw, 0xFFFFFF)
            if band(rshift(foRaw, 23), 1) == 1 then offset = lshift(offset, 4) end
            map[fnum] = {
                offset = offset,
                size = band(ff, 0x3FFFFF),
                compressed = band(rshift(ff, 23), 1) == 0,
                incHeader = band(rshift(ff, 22), 1) == 1,
            }
        end
    end
    return map
end

local function find_file(game_path, name)
    local p = game_path .. "/" .. name
    if file_exists(p) then return p end
    return nil
end

local function open_dsk(game_path)
    local p = find_file(game_path, "SKY.DSK")
    if not p then return nil end
    return file_open(p)
end

-- ============================================================================
-- DataFileHeader + payload loading
-- ============================================================================

local function parse_header(raw)
    if #raw < 22 then return nil end
    return {
        flag    = u16le(raw, 1),
        x       = u16le(raw, 3),
        y       = u16le(raw, 5),
        width   = u16le(raw, 7),
        height  = u16le(raw, 9),
        spSize  = u16le(raw, 11),
        totSize = u16le(raw, 13),
        numSprites = u16le(raw, 15),
        offX    = u16le(raw, 17),
        offY    = u16le(raw, 19),
        compSize = u16le(raw, 21),
    }
end

-- Load a file number, returning (header, pixel_bytes) or nil.
local function load_file(dsk, entry)
    local raw = read_at(dsk, entry.offset, entry.size)
    if #raw < 22 then return nil end
    local hdr = parse_header(raw)
    if not hdr then return nil end

    local pixels
    if entry.compressed and band(rshift(hdr.flag, 7), 1) == 1 then
        local dec, dlen = rnc_unpack(raw:sub(23))
        if dec then
            pixels = packbytes(dec, dlen)
        else
            pixels = raw:sub(23)
        end
    else
        pixels = raw:sub(23)
    end
    return hdr, pixels
end

-- ============================================================================
-- Palette helpers (6-bit VGA components expanded to 8-bit)
-- ============================================================================

local function palette_table_from(bytes)
    if not bytes or #bytes < 768 then return nil end
    local pal = {}
    for i = 0, 255 do
        local r = u8(bytes, i * 3 + 1)
        local g = u8(bytes, i * 3 + 2)
        local b = u8(bytes, i * 3 + 3)
        pal[i * 3 + 1] = lshift(r, 2) + rshift(r, 4)
        pal[i * 3 + 2] = lshift(g, 2) + rshift(g, 4)
        pal[i * 3 + 3] = lshift(b, 2) + rshift(b, 4)
    end
    return pal
end

-- ============================================================================
-- Detection
-- ============================================================================

function engine.detect(game_path)
    return (file_exists(game_path .. "/SKY.DSK") and file_exists(game_path .. "/SKY.DNR"))
        or (file_exists(game_path .. "/sky.dsk") and file_exists(game_path .. "/sky.dnr"))
end

-- ============================================================================
-- Resource tree
-- ============================================================================

local function classify(hdr, size)
    if not hdr then
        if size == 768 then return "palette" end
        return nil
    end
    local w, h, sp, nsp = hdr.width, hdr.height, hdr.spSize, hdr.numSprites
    if w >= 1 and w <= 1080 and h >= 1 and h <= 1080 then
        if sp == 0 and nsp >= 1 and nsp <= 8 then
            return "screen"
        end
        if sp == w * h and nsp >= 1 and nsp <= 512 then
            return "sprite"
        end
    end
    if size == 768 then return "palette" end
    return nil
end

function engine.get_resources(game_path)
    local dsk = open_dsk(game_path)
    local dnrPath = find_file(game_path, "SKY.DNR")
    if not dsk or not dnrPath then
        if dsk then file_close(dsk) end
        return {}
    end
    local dnr = read_all(dnrPath)
    if not dnr then file_close(dsk); return {} end
    local map = parse_dnr(dnr)

    local screens, sprites, palettes = {}, {}, {}
    -- deterministic ordering
    local nums = {}
    for num in pairs(map) do nums[#nums + 1] = num end
    table.sort(nums)

    for _, num in ipairs(nums) do
        local entry = map[num]
        local hdr = nil
        if entry.size >= 22 then
            local head = read_at(dsk, entry.offset, 22)
            hdr = parse_header(head)
        end
        local kind = classify(hdr, entry.size)
        local node
        if kind == "screen" then
            node = { id = "sky_bg_" .. num,
                     name = string.format("%d  %dx%d", num, hdr.width, hdr.height),
                     type = "file" }
            screens[#screens + 1] = node
        elseif kind == "sprite" then
            node = { id = "sky_spr_" .. num,
                     name = string.format("%d  %dx%d x%d", num, hdr.width, hdr.height, hdr.numSprites),
                     type = "file" }
            sprites[#sprites + 1] = node
        elseif kind == "palette" then
            node = { id = "sky_pal_" .. num,
                     name = string.format("Palette %d", num),
                     type = "file" }
            palettes[#palettes + 1] = node
        end
    end

    file_close(dsk)

    local resources = {}
    if #screens > 0 then
        resources[#resources + 1] = { id = "sky_backgrounds", name = "Backgrounds (" .. #screens .. ")", type = "category", children = screens }
    end
    if #sprites > 0 then
        resources[#resources + 1] = { id = "sky_sprites", name = "Sprites (" .. #sprites .. ")", type = "category", children = sprites }
    end
    if #palettes > 0 then
        resources[#resources + 1] = { id = "sky_palettes", name = "Palettes (" .. #palettes .. ")", type = "category", children = palettes }
    end
    return resources
end

-- ============================================================================
-- Resource loading
-- ============================================================================

local function load_palette(dsk, map, pal_id)
    local entry = map[pal_id]
    if not entry then return nil end
    return palette_table_from(read_at(dsk, entry.offset, entry.size))
end

function engine.load_resource(game_path, resource_id, palette_id)
    local dsk = open_dsk(game_path)
    local dnrPath = find_file(game_path, "SKY.DNR")
    if not dsk or not dnrPath then
        if dsk then file_close(dsk) end
        return nil
    end
    local dnr = read_all(dnrPath)
    if not dnr then file_close(dsk); return nil end
    local map = parse_dnr(dnr)

    local num = tonumber(resource_id:match("^sky_%a+_(%d+)$"))

    local result = nil
    if num and map[num] then
        local hdr, pixels = load_file(dsk, map[num])
        if hdr and pixels and #pixels > 0 then
            -- Resolve palette
            local palBytes
            if palette_id then
                local pnum = tonumber(palette_id:match("^sky_%a+_(%d+)$"))
                if pnum and map[pnum] then
                    palBytes = read_at(dsk, map[pnum].offset, map[pnum].size)
                end
            end
            if not palBytes then palBytes = read_at(dsk, map[60111].offset, map[60111].size) end
            local palette = palette_table_from(palBytes) or {}

            if hdr.spSize == 0 then
                local w = hdr.width
                local h = math.floor(#pixels / w)
                if w >= 1 and h >= 1 then
                    local pix = {}
                    for i = 1, w * h do pix[i] = u8(pixels, i) end
                    local handle = image_create_indexed(w, h, pix, palette)
                    if handle then
                        result = { type = "image", image = handle,
                                   description = string.format("Screen %d (%dx%d)", num, w, h) }
                    end
                end
            else
                local sp = hdr.spSize
                local w, h = hdr.width, hdr.height
                local frames = {}
                local avail = math.floor(#pixels / sp)
                local count = math.min(hdr.numSprites, avail, 128)
                for f = 1, count do
                    local base = (f - 1) * sp
                    local pix = {}
                    for i = 1, w * h do pix[i] = u8(pixels, base + i) end
                    local handle = image_create_indexed(w, h, pix, palette)
                    if handle then frames[#frames + 1] = handle end
                end
                if #frames == 1 then
                    result = { type = "image", image = frames[1],
                               description = string.format("Sprite %d (%dx%d)", num, w, h) }
                elseif #frames > 1 then
                    local anim = animation_create(frames, 120)
                    result = { type = "animation", animation = anim, delay_ms = 120,
                               description = string.format("Sprite %d (%dx%d, %d frames)", num, w, h, #frames) }
                end
            end
        end
    end

    file_close(dsk)
    return result
end

-- ============================================================================
-- Default palette
-- ============================================================================

function engine.default_palette(game_path, resource_id)
    return "sky_pal_60111"
end

return engine

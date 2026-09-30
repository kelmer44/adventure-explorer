-- ============================================================================
-- Adventure Explorer - Engine Script: Universe
-- ============================================================================
-- Everything lives in a single file, UNIVERSE.EPF, an "EPFS" archive. The
-- header is 11 bytes and the payload blocks start immediately after it:
--
--     0  'E' 'P' 'F' 'S'
--     4  u32le directory offset
--     8  u8   version, always 0
--     9  u16le entry count
--    11  first payload byte
--
-- The directory is a flat array of 22-byte records at the offset above:
--
--     0  12 bytes  name, "NAME.EXT" NUL padded, DOS 8.3
--    12  u8        unused
--    13  u8        compression method: 0 stored, 1 Huffman/LZ, 2 unsupported
--    14  u32le     stored size
--    18  u32le     decompressed size
--
-- The loader itself reads the method from offset 0xd, the stored size from 0xe
-- and the decompressed size from 0x12, so those three are confirmed rather than
-- guessed. The unused byte at +12 reads 0 or 5 and nothing else, and treating it
-- as part of the name would shift every later field by one byte.
--
-- Records carry no payload offset; the blocks sit back to back from offset 11
-- in directory order, so the offset of entry N is 11 plus the sum of the stored
-- sizes of entries 0..N-1. The directory itself is the last thing in the file,
-- and the 779 stored sizes add up to exactly the directory offset, which confirms
-- the layout. Every entry also decompresses to exactly its declared size.
--
-- Compression method 1
-- ------------------------------------------------------------------------
-- A canonical-code reader over a table that grows as it is used. Codes start at
-- 9 bits wide and widen by one bit (up to 14) whenever the entry count passes
-- (2^width) - 3, which is what keeps the average code length down. The reader is
-- MSB-first out of a 32-bit register refilled a byte at a time.
--
-- The first code of the stream is a plain byte and is emitted as-is. After that,
-- a code equal to the full mask (2^width - 1) ends the stream and a code equal to
-- mask-1 empties the table and makes the next code a fresh literal byte.
--
-- Every other code is a back reference into two parallel tables. If the code is
-- below the current table size it indexes them directly; otherwise the last byte
-- of the previous match is pushed onto the current match and the saved code is
-- used as the index instead. Walking the link chain yields the match bytes in
-- reverse, and they are emitted last byte first, so matches expand right to
-- left. The pair (saved code, last match byte) then becomes a new table entry.
--
-- Images
-- ------------------------------------------------------------------------
-- Every .LBM is an IFF ILBM with BMHD, CMAP and BODY, and the palette always
-- travels inside the file, so no .PAL resource is needed. All 168 are 320 wide
-- and 200, 240 or 256 tall, with no mask plane and run-length compression.
--
-- There are two body layouts and the IFF form type is the only reliable clue,
-- because both expand to the same number of bytes:
--
--   "PBM "  165 files, 8 bitplanes, 256-colour CMAP, but the BODY is one byte
--           per pixel. At 320 wide a plane row is 40 bytes, so 8 planes is
--           exactly 320 bytes and the "bitplanes" are really the 8 bits of one
--           pixel. The stream expands to width * height bytes.
--
--   "ILBM"    3 files (PAGE2-4.LBM), 5 bitplanes, 32-colour CMAP, 320x256. The
--           BODY is row-interleaved bitplanes, so a scanline is rowbytes *
--           planes bytes and the bitplanes have to be unpacked into indices.
--
-- The BODY is one continuous PackBits-style run over the whole chunk, not one
-- per scanline: the stream expands to exactly rowbytes * planes * height bytes
-- and ends on the last output byte, which is what proves there is no row
-- padding and no per-row restart. Runs are a control byte n where n < 128
-- copies the next n+1 bytes literally and n > 128 repeats the next byte 257-n
-- times; n == 128 never appears in these files.
--
-- .COL and .MSK are 8000-byte bitmaps, 40 bytes per row for 320x200, most
-- significant bit leftmost, so one bit per pixel with no row padding. They are
-- 1-bit collision and walk masks, one per room.
-- ============================================================================

local engine = {}
engine.name        = "Universe"
engine.id          = "universe"
engine.description = "Universe (1994, Sir-tech / Intracorp)"
engine.version     = "1.0"

local ARCHIVE = "/UNIVERSE.EPF"

-- archive layout
-- ------------------------------------------------------------------------
local EPFS_MAGIC   = "EPFS"
local EPFS_HEADER  = 11       -- payload blocks start here
local EPFS_RECORD  = 22       -- bytes per directory record
local EPFS_NAME    = 12       -- bytes of name inside a record

-- The widest image in the archive is 320 pixels; 640x400 leaves generous
-- headroom while still refusing a corrupt header before anything is allocated.
local MAX_W        = 640
local MAX_H        = 400

-- Method 1 never widens past 14 bits, so the tables can never need more than
-- 2^14 - 2 entries. M5.BIN is the entry that gets closest, using 16294 of them.
local MAX_TABLE    = 16384

-- The DOS decompressor refuses a match longer than 0xFA0 bytes.
local MAX_CHAIN    = 4000

local BITMAP_W     = 320
local BITMAP_H     = 200
local BITMAP_ROW   = 40       -- 320 / 8

-- binary helpers
-- ------------------------------------------------------------------------
local function u16le(d, p)
    return d:byte(p) + d:byte(p + 1) * 256
end

local function u32le(d, p)
    return d:byte(p) + d:byte(p + 1) * 256
         + d:byte(p + 2) * 65536 + d:byte(p + 3) * 16777216
end

local function u16be(d, p)
    return d:byte(p) * 256 + d:byte(p + 1)
end

local function u32be(d, p)
    return d:byte(p) * 16777216 + d:byte(p + 1) * 65536
         + d:byte(p + 2) * 256 + d:byte(p + 3)
end

local function upper(s)
    return (s:upper())
end

local function ext_of(name)
    return upper((name:match("%.([^.]+)$")))
end

-- archive directory
-- ------------------------------------------------------------------------
-- Returns a table with "order" (names in stored order) and "by_name", or nil if
-- the file is missing or is not an EPFS archive.
local function open_archive(game_path)
    local f = file_open(game_path .. ARCHIVE)
    if not f then return nil end

    local head = file_read(f, 0, EPFS_HEADER)
    if not head or #head < EPFS_HEADER or head:sub(1, 4) ~= EPFS_MAGIC then
        file_close(f)
        return nil
    end

    local dir_off = u32le(head, 5)
    local count   = u16le(head, 10)
    if count == 0 or dir_off < EPFS_HEADER then
        file_close(f)
        return nil
    end

    local dir = file_read(f, dir_off, count * EPFS_RECORD)
    file_close(f)
    if not dir or #dir < count * EPFS_RECORD then return nil end

    local order, by_name = {}, {}
    local offset = EPFS_HEADER
    for i = 1, count do
        local base = (i - 1) * EPFS_RECORD + 1        -- 1-based string index
        local raw = dir:sub(base, base + EPFS_NAME - 1)
        local nul = raw:find("\0", 1, true)
        local name = (nul and raw:sub(1, nul - 1) or raw):gsub("%s+$", "")
        if name ~= "" then
            local entry = {
                name   = name,
                method = dir:byte(base + 13),
                csize  = u32le(dir, base + 14),
                dsize  = u32le(dir, base + 18),
                offset = offset,
            }
            by_name[name] = entry
            order[#order + 1] = name
            offset = offset + entry.csize
        end
    end

    return { order = order, by_name = by_name }
end

local epf_decompress

-- Turn a 1-based array of byte values into a binary string. string.char takes
-- a bounded number of arguments, so this walks the table in blocks.
local unpack = table.unpack or unpack
local CHUNK_BYTES = 2048

local function to_bytes(t, n)
    local parts, p = {}, 1
    while p <= n do
        local last = p + CHUNK_BYTES - 1
        if last > n then last = n end
        parts[#parts + 1] = string.char(unpack(t, p, last))
        p = last + 1
    end
    return table.concat(parts)
end

-- Read and expand one entry. Returns the payload as a binary string, or nil
-- plus a message.
local function read_entry(game_path, entry)
    if entry.method == 2 then
        return nil, "compression method 2 is not used by this archive"
    end
    if entry.csize > entry.dsize and entry.method ~= 0 then
        return nil, "stored size exceeds decompressed size"
    end

    local f = file_open(game_path .. ARCHIVE)
    if not f then return nil, "cannot open " .. ARCHIVE end
    local raw = file_read(f, entry.offset, entry.csize)
    file_close(f)
    if not raw or #raw < entry.csize then
        return nil, "short read for " .. entry.name
    end

    if entry.method == 0 then
        return raw, nil
    end

    local out, err = epf_decompress(raw, entry.dsize, entry.name)
    if not out then return nil, err end
    return to_bytes(out, entry.dsize), nil
end

-- EPFS compression method 1
-- ------------------------------------------------------------------------
-- Returns a 1-based array of byte values, or nil plus a message.
function epf_decompress(src, dsize, name)
    local nbits, mask = 0, 0
    local function set_params(n)
        nbits = n
        mask  = (2 ^ n) - 1
    end

    local bitbuf, bitcnt, pos = 0, 0, 1
    local last_byte = #src
    local function read_bits()
        local ebx = bitbuf
        local ch, cl = nbits, bitcnt
        while ch > cl do
            local b = 0
            if pos <= last_byte then
                b = src:byte(pos)
            end
            pos = pos + 1
            ebx = (ebx * 256) % 4294967296
            ebx = ebx - (ebx % 256) + b
            cl = cl + 8
        end
        cl = cl - ch
        local code = math.floor(ebx / 2 ^ cl) % (mask + 1)
        bitcnt = cl
        bitbuf = ebx
        return code
    end

    local tab1, tab2 = {}, {}
    local out, n = {}, 0
    local t1, t2, t4 = 256, 0, 0
    local chain = {}

    set_params(9)
    bitcnt = 0

    local limit = dsize + MAX_CHAIN
    local function emit(b)
        n = n + 1
        if n <= limit then out[n] = b end
    end

    local first = read_bits()
    t2, t4 = first, first
    emit(first % 256)

    while n < dsize do
        local code = read_bits()
        if code == mask then
            break
        elseif code == mask - 1 then
            t1 = 256
            local lit = read_bits()
            t2, t4 = lit, lit
            emit(lit % 256)
        else
            local cn, bx = 0, 0
            if code >= t1 then
                cn = 1
                chain[cn] = t4 % 256
                bx = t2
            else
                bx = code
            end

            local guard = 0
            while true do
                if bx > 255 then
                    cn = cn + 1
                    if cn > MAX_CHAIN then
                        return nil, name .. ": match longer than " .. MAX_CHAIN
                    end
                    chain[cn] = tab2[bx] or 0
                    bx = tab1[bx] or 0
                    guard = guard + 1
                    if guard > MAX_CHAIN then
                        return nil, name .. ": match chain loops"
                    end
                else
                    cn = cn + 1
                    if cn > MAX_CHAIN then
                        return nil, name .. ": match longer than " .. MAX_CHAIN
                    end
                    chain[cn] = bx
                    break
                end
            end

            t4 = chain[cn]
            for i = cn, 1, -1 do
                emit(chain[i])
            end

            if t1 < MAX_TABLE then
                tab1[t1] = t2
                tab2[t1] = t4 % 256
            end
            t1 = t1 + 1
            if t1 > mask - 2 and nbits < 14 then
                set_params(nbits + 1)
            end
            t2 = code
        end
    end

    if n < dsize then
        return nil, string.format("%s: stream ended at %d of %d bytes",
                                   name, n, dsize)
    end
    return out, nil
end

-- IFF ILBM
-- ------------------------------------------------------------------------
-- Both form types turn up in the archive. "PBM " is what Deluxe Paint writes for
-- a 256-colour picture: 8 planes, but the body is one byte per pixel. "ILBM" is
-- a genuine bitplane file and holds its planes interleaved inside each scanline.
local FORM_TYPES = { ["PBM "] = true, ["ILBM"] = true }

-- Walk the chunk list, returning a table keyed by four-character chunk id.
local function read_chunks(data)
    local out, i = {}, 13
    while i + 8 <= #data do
        local id = data:sub(i, i + 3)
        local size = u32be(data, i + 4)
        local body_at = i + 8
        if body_at + size - 1 > #data then break end
        out[id] = { data = data, from = body_at, size = size }
        i = body_at + size + (size % 2)
    end
    return out
end

-- Body decompression. One continuous run over the whole chunk, expanding to
-- exactly w*h bytes. Returns a 1-based array of pixel indices.
local function decode_body(body, from, size, want)
    local px, n = {}, 0
    if size == 0 then return px, 0 end
    local p = from
    local stop = from + size - 1

    while p <= stop and n < want do
        local c = body:byte(p)
        p = p + 1
        if c < 128 then
            local run = c + 1
            if p + run - 1 > stop then return nil, 0 end
            for i = 0, run - 1 do
                n = n + 1
                px[n] = body:byte(p + i)
            end
            p = p + run
        elseif c > 128 then
            local run = 257 - c
            if p > stop then return nil, 0 end
            local v = body:byte(p)
            p = p + 1
            for _ = 1, run do
                n = n + 1
                px[n] = v
            end
        else
            return nil, 0
        end
    end
    return px, n
end

-- A 1-bit 320x200 row-per-40-bytes bitmap, rendered as black and white. The
-- host wants a full 256-entry table whatever the image actually uses, so the
-- two real colours sit in the first two slots and the rest stay black.
local BITMAP_PAL = (function()
    local p = {}
    for i = 1, 768 do p[i] = 0 end
    p[1], p[2], p[3] = 0, 0, 0
    p[4], p[5], p[6] = 255, 255, 255
    return p
end)()

local function decode_bitmap(data)
    local px, n = {}, 0
    if #data < BITMAP_ROW * BITMAP_H then return nil, 0 end
    for y = 0, BITMAP_H - 1 do
        local row = 1 + y * BITMAP_ROW
        for x = 0, BITMAP_W - 1 do
            local b = data:byte(row + math.floor(x / 8))
            n = n + 1
            px[n] = math.floor(b / 2 ^ (7 - (x % 8))) % 2
        end
    end
    return px, n
end

local function palette_swatch(pal)
    local rgb, n = {}, 0
    for py = 0, 15 do
        for pxx = 0, 15 do
            local ci = py * 16 + pxx
            n = n + 1
            rgb[n] = pal[ci * 3 + 1] or 0
            n = n + 1
            rgb[n] = pal[ci * 3 + 2] or 0
            n = n + 1
            rgb[n] = pal[ci * 3 + 3] or 0
        end
    end
    return image_create_rgb(256, 256, rgb)
end

-- How many of the 256 palette slots an image actually paints with.
local function count_used(px, n)
    local seen, c = {}, 0
    for i = 1, n do
        local v = px[i]
        if v and not seen[v] then
            seen[v] = true
            c = c + 1
        end
    end
    return c
end

-- How many pixels of a 1-bit map are set.
local function count_set(px, n)
    local c = 0
    for i = 1, n do
        if px[i] == 1 then c = c + 1 end
    end
    return c
end

-- resource loaders
-- ------------------------------------------------------------------------
local function load_lbm(game_path, entry)
    local blob, err = read_entry(game_path, entry)
    if not blob then return { type = "text", text = err } end

    local form = blob:sub(9, 12)
    if blob:sub(1, 4) ~= "FORM" or not FORM_TYPES[form] then
        return { type = "text",
                 text = string.format("%s: not an ILBM file (form %s)",
                                      entry.name, form:gsub("%z", ".")) }
    end

    local ch = read_chunks(blob)
    if not ch["BMHD"] or not ch["CMAP"] or not ch["BODY"] then
        return { type = "text",
                 text = entry.name .. ": ILBM is missing BMHD, CMAP or BODY" }
    end

    local bmhd = ch["BMHD"]
    local w = u16be(bmhd.data, bmhd.from)
    local h = u16be(bmhd.data, bmhd.from + 2)
    local planes  = bmhd.data:byte(bmhd.from + 8)
    local masking = bmhd.data:byte(bmhd.from + 9)
    local compr   = bmhd.data:byte(bmhd.from + 10)

    if w < 1 or h < 1 or w > MAX_W or h > MAX_H then
        return { type = "text",
                 text = string.format("%s: %dx%d is out of range", entry.name, w, h) }
    end
    if planes < 1 or planes > 8 or masking ~= 0 then
        return { type = "text",
                 text = string.format("%s: %d planes, mask %d", entry.name,
                                      planes, masking) }
    end
    if compr ~= 0 and compr ~= 1 then
        return { type = "text",
                 text = string.format("%s: compression %d", entry.name, compr) }
    end

    -- Each plane of a scanline is padded out to a 16-bit boundary, so a row of
    -- the body is rowbytes * planes bytes however few planes there are.
    local words = w + 15 - (w + 15) % 16
    local rowbytes = words / 16 * 2
    local total = rowbytes * planes * h
    local data, count

    if compr == 0 then
        data, count = {}, math.min(ch["BODY"].size, total)
        for i = 0, count - 1 do data[i + 1] = blob:byte(ch["BODY"].from + i) end
    else
        data, count = decode_body(blob, ch["BODY"].from, ch["BODY"].size, total)
    end
    if not data or count < total then
        return { type = "text",
                 text = string.format("%s: body decodes to %d of %d bytes",
                                      entry.name, count or 0, total) }
    end

    local px = {}
    if planes == 8 then
        -- rowbytes * 8 is exactly one byte per pixel at these widths
        for i = 1, w * h do px[i] = data[i] end
    else
        local row = rowbytes * planes
        for y = 0, h - 1 do
            local line = y * w + 1
            for p = 0, planes - 1 do
                local base = y * row + p * rowbytes
                local bit = 2 ^ p
                for x = 0, w - 1 do
                    local b = data[base + math.floor(x / 8) + 1]
                    if math.floor(b / 2 ^ (7 - (x % 8))) % 2 == 1 then
                        px[line + x] = (px[line + x] or 0) + bit
                    end
                end
            end
        end
    end

    local cmap = ch["CMAP"]
    local colors = math.floor(cmap.size / 3)
    if colors < 1 or colors > 256 then
        return { type = "text",
                 text = string.format("%s: CMAP holds %d bytes", entry.name, cmap.size) }
    end
    local pal = {}
    for i = 0, 767 do pal[i + 1] = 0 end
    for i = 0, colors * 3 - 1 do pal[i + 1] = cmap.data:byte(cmap.from + i) end

    local used = count_used(px, w * h)
    local kind = (planes == 8) and "8-bit" or string.format("%d-plane", planes)
    local formname = (form:gsub("%s+", ""))
    return {
        type = "image",
        image = image_create_indexed(w, h, px, pal),
        paletteImage = palette_swatch(pal),
        paletteColors = colors,
        description = string.format(
            "%s - %dx%d %s %s image, %d of %d colours used, own palette, %s",
            entry.name, w, h, formname, kind, used, colors,
            entry.method == 0 and "stored" or "Huffman/LZ compressed"),
    }
end

local function load_bitmap(game_path, entry, label)
    local blob, err = read_entry(game_path, entry)
    if not blob then return { type = "text", text = err } end

    local px, n = decode_bitmap(blob)
    if not px then
        return { type = "text",
                 text = string.format("%s: %d bytes, expected %d",
                                      entry.name, entry.dsize,
                                      BITMAP_ROW * BITMAP_H) }
    end

    local set = count_set(px, n)
    return {
        type = "image",
        image = image_create_indexed(BITMAP_W, BITMAP_H, px, BITMAP_PAL),
        description = string.format("%s - %dx%d 1-bit %s, %d of %d pixels set",
                                    entry.name, BITMAP_W, BITMAP_H, label,
                                    set, BITMAP_W * BITMAP_H),
    }
end

local function load_text(game_path, entry)
    local blob, err = read_entry(game_path, entry)
    if not blob then return { type = "text", text = err } end
    return {
        type = "text",
        text = string.format("%s - %d bytes\n\n%s", entry.name,
                             entry.dsize, blob),
    }
end

-- engine interface
-- ------------------------------------------------------------------------
function engine.detect(game_path)
    return file_exists(game_path .. ARCHIVE)
end

-- Room backgrounds are the SCENE* images; everything else that is an image is a
-- standalone screen (book pages, closing credits, intro and logo artwork). The
-- two 1-bit companions are listed under their room so the pair stays together.
function engine.get_resources(game_path)
    local archive = open_archive(game_path)
    if not archive then return {} end

    local rooms, screens, cols, masks, others = {}, {}, {}, {}, {}
    for _, name in ipairs(archive.order) do
        local entry = archive.by_name[name]
        local ext = ext_of(name)
        if ext == "LBM" then
            if name:match("^SCENE") then
                rooms[#rooms + 1] = name
            else
                screens[#screens + 1] = name
            end
        elseif ext == "COL" then
            cols[#cols + 1] = name
        elseif ext == "MSK" then
            masks[#masks + 1] = name
        elseif ext == "TXT" or ext == "BAT" then
            others[#others + 1] = name
        elseif entry.method == 2 then
            others[#others + 1] = name
        end
    end

    table.sort(rooms)
    table.sort(screens)
    table.sort(cols)
    table.sort(masks)
    table.sort(others)

    local resources = {}

    local function category(id, title, list, child_id, child_type)
        if #list == 0 then return end
        local cat = {
            id = id, name = string.format("%s (%d)", title, #list),
            type = "category", children = {},
        }
        for _, name in ipairs(list) do
            cat.children[#cat.children + 1] = {
                id = string.format("%s:%s", child_id, name),
                name = name,
                type = child_type,
            }
        end
        resources[#resources + 1] = cat
    end

    category("rooms", "Room Backgrounds", rooms, "bg", "image")
    category("screens", "Full-Screen Images", screens, "bg", "image")
    category("cols", "Collision Maps", cols, "col", "image")
    category("masks", "Walk Masks", masks, "msk", "image")
    category("data", "Data Files", others, "raw", "text")

    return resources
end

function engine.load_resource(game_path, resource_id, palette_id)
    local archive = open_archive(game_path)
    if not archive then return { type = "text", text = "UNIVERSE.EPF is missing" } end

    local kind, name = resource_id:match("^([^:]+):(.+)$")
    local entry = name and archive.by_name[name]
    if not kind or not entry then
        return { type = "text", text = "Unknown resource " .. resource_id }
    end

    if kind == "bg" then
        return load_lbm(game_path, entry)
    elseif kind == "col" then
        return load_bitmap(game_path, entry, "collision map")
    elseif kind == "msk" then
        return load_bitmap(game_path, entry, "walk mask")
    elseif kind == "raw" then
        return load_text(game_path, entry)
    end
    return { type = "text", text = "Unknown resource " .. resource_id }
end

return engine

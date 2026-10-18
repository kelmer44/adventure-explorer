-- ============================================================================
-- Adventure Explorer - Engine Script: Discworld 1 & 2 (Tinsel Engine)
-- ============================================================================
-- Psygnosis / Perfect Entertainment handle based resource system.
--
-- Data model (verified against ScummVM engines/tinsel):
--   * "index" holds fixed size records, one per data file:
--         V1 (DW1): 20 bytes = name[12], u32 filesize, 4 reserved bytes
--         V2 (DW2): 24 bytes = name[12], u32 filesize, 4 reserved, u32 flags2
--   * A SCNHANDLE packs a file index plus a byte offset:
--         V1: index = h >> 23, offset = h & 0x7FFFFF
--         V2: index = h >> 25, offset = h & 0x1FFFFFF
--   * Every data file is a singly linked list of chunks:
--         u32 chunkType, u32 nextChunkAbsoluteOffset (0 terminates the list)
--   * CHUNK_IMAGE (0x33340006) holds a flat list of 16 byte records:
--         i16 width, u16 height, i16 aniX, i16 aniY, u32 hImgBits, u32 hImgPal
--         the top two bits of height carry the packing type ("c16")
--   * CHUNK_PALETTE (0x33340005) holds one or more palettes, each of them
--         i32 numColors followed by numColors COLORREFs (0x00BBGGRR)
--
-- Decoders (ScummVM graphics.cpp DrawObject):
--   DW1  WrtNonZero        4x4 block list, block data at charBase = file+u32@0x10
--   DW2  WrtAll            raw 8bpp, used for the playfield backgrounds
--   DW2  t2WrtNonZero      byte RLE, used for c16 == 0 images that are not
--                          backgrounds, including the large cutscene frames
--   DW2  PackedWrtNonZero  run length packing, used for c16 = 1/2/3 images
--
-- Image palettes are installed into the video DAC starting at index 1
-- (palette.cpp: FGND_DAC_INDEX), so colour index 0 is the background colour
-- and colour n maps to palette entry n-1. That shift is applied when the
-- 768 entry lookup table is built.
--
-- FILM records link reels to animation bytecode and multipart frame lists.
-- Expose those sequences alongside the original individual images.
-- ============================================================================

local engine = {}
engine.name        = "Discworld"
engine.id          = "tinsel"
engine.description = "Discworld 1 & 2 (1995/1996, Perfect Entertainment)"
engine.version     = "3.1"

-- ============================================================================
-- Binary helpers (positions are 1 based, matching Lua string indexing)
-- ============================================================================

local function u8(data, pos) return data:byte(pos) end

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function i16le(data, pos)
    local v = data:byte(pos) + data:byte(pos + 1) * 256
    return v < 32768 and v or v - 65536
end

local function u32le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536 + data:byte(pos + 3) * 16777216
end

-- SCNHANDLE is "index in the high bits, byte offset in the low bits".
local function handle_parts(scnhandle, shift)
    local span = 2 ^ shift
    local index = math.floor(scnhandle / span)
    return index, scnhandle - index * span
end

-- ============================================================================
-- Constants
-- ============================================================================

local CHUNK_PALETTE = 0x33340005
local CHUNK_IMAGE   = 0x33340006

local DW1 = { shift = 23, index_record = 20 }
local DW2 = { shift = 25, index_record = 24 }

-- A background is the image that covers the whole playfield.
local DW1_BG_MIN_W, DW1_BG_MIN_H = 300, 150
local DW2_BG_MIN_W, DW2_BG_MIN_H = 600, 200

-- Discworld 1 always puts the block list of the playfield at this offset.
local DW1_BG_BITS_OFFSET = 24

-- ============================================================================
-- Detection
-- ============================================================================

local function index_path(game_path)
    for _, candidate in ipairs({ "index", "INDEX", "Index" }) do
        if file_exists(game_path .. "/" .. candidate) then
            return game_path .. "/" .. candidate
        end
    end
    return nil
end

local function is_dw2(game_path)
    return file_exists(game_path .. "/dw2.scn")
end

function engine.detect(game_path)
    if not index_path(game_path) then return false end
    return is_dw2(game_path) or file_exists(game_path .. "/dw.scn")
end

-- ============================================================================
-- Partial file access
-- Both data sets are close to a gigabyte in total, so only the byte ranges
-- that are actually needed are pulled into memory.
-- ============================================================================

local function open_data(game_path, name)
    if not name then return nil end
    local path = game_path .. "/" .. name
    if not file_exists(path) then return nil end
    local handle = file_open(path)
    if not handle then return nil end
    local size = file_size(handle)
    if not size then
        file_close(handle)
        return nil
    end
    return { handle = handle, size = math.floor(size) }
end

local function close_data(f)
    if f then file_close(f.handle) end
end

local function read_at(f, offset, length)
    if not f or length <= 0 or offset < 0 then return nil end
    if offset + length > f.size then length = f.size - offset end
    if length <= 0 then return nil end
    return file_read(f.handle, offset, length)
end

-- ============================================================================
-- Index file
-- ============================================================================

local function parse_index(game_path, fmt)
    local path = index_path(game_path)
    if not path then return nil end

    local handle = file_open(path)
    if not handle then return nil end
    local raw = file_read(handle, 0, math.floor(file_size(handle)))
    file_close(handle)
    if not raw then return nil end

    local record
    if #raw % fmt.index_record == 0 then
        record = fmt.index_record
    elseif #raw % 20 == 0 then
        record = 20
    else
        return nil
    end

    local count = math.floor(#raw / record)
    local handles, names = {}, {}
    for i = 0, count - 1 do
        local base = i * record + 1
        local name = ""
        for c = 0, 11 do
            local b = raw:byte(base + c)
            if not b or b == 0 then break end
            name = name .. string.char(b)
        end
        if #name > 0 then
            handles[i] = {
                name     = name,
                filesize = u32le(raw, base + 12) % 16777216,
            }
            names[#names + 1] = handles[i]
        end
    end

    return handles, names
end

-- ============================================================================
-- Chunk list
-- ============================================================================

local function walk_chunks(f)
    local chunks = {}
    local off, seen = 0, {}
    while off + 8 <= f.size and not seen[off] do
        seen[off] = true
        local header = read_at(f, off, 8)
        if not header then break end
        local chunk = {
            type = u32le(header, 1),
            off  = off,
            next = u32le(header, 5),
        }
        chunks[#chunks + 1] = chunk
        if chunk.next == 0 then break end
        if chunk.next <= off or chunk.next > f.size then break end
        off = chunk.next
    end
    return chunks
end

-- Byte range of the first chunk of the given type, as (offset, size).
local function find_chunk(f, chunk_type)
    for _, chunk in ipairs(walk_chunks(f)) do
        if chunk.type == chunk_type then
            local size = (chunk.next > chunk.off + 8) and (chunk.next - chunk.off - 8)
                      or (f.size - chunk.off - 8)
            if size < 0 then size = 0 end
            return chunk.off + 8, size
        end
    end
    return nil
end

-- ============================================================================
-- IMAGE records
-- ============================================================================

local function read_image_records(f)
    local out = {}
    local start, size = find_chunk(f, CHUNK_IMAGE)
    if not start or size < 16 then return out end

    local raw = read_at(f, start, size)
    if not raw then return out end

    for pos = 1, #raw - 15, 16 do
        local w     = i16le(raw, pos)
        local raw_h = u16le(raw, pos + 2)
        local h     = raw_h % 16384
        local hBits = u32le(raw, pos + 8)

        if w > 0 and h > 0 and hBits ~= 0 and w <= 4096 and h <= 4096 then
            out[#out + 1] = {
                record   = start + pos - 1,   -- 0 based position in the data file
                width    = w,
                height   = h,
                c16      = math.floor(raw_h / 16384) % 4,
                anioffX  = i16le(raw, pos + 4),
                anioffY  = i16le(raw, pos + 6),
                hImgBits = hBits,
                hImgPal  = u32le(raw, pos + 12),
            }
        end
    end

    return out
end

-- ============================================================================
-- Palettes
-- ============================================================================

-- One palette: i32 numColors followed by numColors COLORREFs.
local function read_palette(data, pos)
    if not data or pos < 1 or pos + 3 > #data then return nil end
    local num_colors = u32le(data, pos)
    if num_colors < 1 or num_colors > 1024 then return nil end
    if pos + 3 + num_colors * 4 > #data then return nil end

    local rgb = {}
    for i = 0, num_colors - 1 do
        local ref = u32le(data, pos + 4 + i * 4)
        rgb[i] = { ref % 256, math.floor(ref / 256) % 256, math.floor(ref / 65536) % 256 }
    end
    return rgb
end

-- The palette is reached through its own SCNHANDLE, so it can live in a
-- different data file than the image. A null handle is common in Discworld 2
-- and there the PALETTE chunk of the image's own file is used instead.
local function resolve_palette(game_path, handles, fmt, file_name, record)
    local rgb

    if record.hImgPal ~= 0 then
        local index, offset = handle_parts(record.hImgPal, fmt.shift)
        local owner = handles[index]
        if owner then
            local pf = open_data(game_path, owner.name)
            if pf then
                local data = read_at(pf, offset, 1028)
                rgb = data and read_palette(data, 1)
                close_data(pf)
            end
        end
    end

    if not rgb then
        local f = open_data(game_path, file_name)
        if f then
            local start, size = find_chunk(f, CHUNK_PALETTE)
            if start then
                local data = read_at(f, start, math.min(size, 1028))
                rgb = data and read_palette(data, 1)
            end
            close_data(f)
        end
    end

    return rgb
end

-- 768 entry lookup table for image_create_indexed. Index 0 is the DAC
-- background colour, index n uses palette entry n-1.
local function palette_table(rgb)
    local t = {}
    for i = 0, 255 do
        local c = (i > 0) and rgb[i - 1] or nil
        t[i * 3 + 1] = c and c[1] or 0
        t[i * 3 + 2] = c and c[2] or 0
        t[i * 3 + 3] = c and c[3] or 0
    end
    return t
end

local function grayscale_table()
    local t = {}
    for i = 0, 255 do
        t[i * 3 + 1] = i
        t[i * 3 + 2] = i
        t[i * 3 + 3] = i
    end
    return t
end

-- ============================================================================
-- Decoders
-- All of them return a 1 based table of colour indexes.
-- ============================================================================

-- DW1 WrtNonZero: a list of 4x4 block indexes plus a block matrix that lives
-- at an absolute offset inside the same file. A negative index selects a
-- transparent block, and only its non zero pixels are written.
local function decode_dw1(f, bits_off, w, h)
    local header = read_at(f, 0x10, 8)
    if not header then return nil end
    local char_base = u32le(header, 1)
    local trans_off = u32le(header, 5)
    if char_base <= 0 or char_base >= f.size then return nil end

    local blocks_w = math.floor((w + 3) / 4)
    local blocks_h = math.floor((h + 3) / 4)
    local index_data = read_at(f, bits_off, blocks_w * blocks_h * 2)
    if not index_data or #index_data < blocks_w * blocks_h * 2 then return nil end

    -- Only the blocks the image actually references need to be fetched, which
    -- is a lot less than the whole file for the small sprite images.
    local max_block = 0
    for t = 0, blocks_w * blocks_h - 1 do
        local value = i16le(index_data, t * 2 + 1)
        if value >= 0 then
            if value > max_block then max_block = value end
        else
            value = value % 32768
            if value > 0 and trans_off + value > max_block then
                max_block = trans_off + value
            end
        end
    end
    local matrix_size = (max_block + 1) * 16
    if char_base + matrix_size > f.size then matrix_size = f.size - char_base end
    if matrix_size < 16 then return nil end

    local matrix = read_at(f, char_base, matrix_size)
    if not matrix then return nil end

    local pixels = {}

    for t = 0, blocks_w * blocks_h - 1 do
        local value = i16le(index_data, t * 2 + 1)
        local bx, by = (t % blocks_w) * 4, math.floor(t / blocks_w) * 4

        local block, transparent
        if value >= 0 then
            block, transparent = value, false
        else
            value = value % 32768
            if value > 0 then
                block, transparent = trans_off + value, true
            end
        end

        if block then
            local base = block * 16 + 1
            if base + 15 <= #matrix then
                for py = 0, 3 do
                    local yy = by + py
                    if yy < h then
                        local row = yy * w
                        for px = 0, 3 do
                            local xx = bx + px
                            if xx < w then
                                local p = u8(matrix, base + py * 4 + px)
                                if p ~= 0 or not transparent then
                                    pixels[row + xx + 1] = p
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return pixels
end

-- DW2 WrtAll: plain 8bpp, row major.
local function decode_dw2_raw(f, off, w, h)
    local data = read_at(f, off, w * h)
    if not data or #data < w * h then return nil end
    local pixels = {}
    for i = 0, w * h - 1 do
        pixels[i + 1] = u8(data, i + 1)
    end
    return pixels
end

-- RLE and packed streams are variable length: a row can encode to fewer or
-- more bytes than its width, and the final run may read a little past the
-- last pixel. Over reading is harmless, the decoders stop after h rows.
local function read_stream(f, off, w, h)
    return read_at(f, off, math.max(w * h * 2, 4096))
end

-- DW2 t2WrtNonZero: byte oriented RLE, one row at a time. A set bit in the
-- opcode introduces a run of a single colour, colour 0 being transparent.
local function decode_dw2_rle(f, off, w, h)
    local data = read_stream(f, off, w, h)
    if not data then return nil end
    local total, src = #data, 1
    local pixels = {}

    for y = 0, h - 1 do
        local row, x = y * w, 0
        while x < w do
            if src > total then return pixels end
            local opcode = u8(data, src); src = src + 1

            if opcode >= 128 then
                local run = opcode % 128
                if src > total then return pixels end
                local color = u8(data, src); src = src + 1
                for _ = 1, run do
                    if x < w and color ~= 0 then pixels[row + x + 1] = color end
                    x = x + 1
                end
            else
                for _ = 1, opcode do
                    if src > total then return pixels end
                    if x < w then pixels[row + x + 1] = u8(data, src) end
                    src = src + 1
                    x = x + 1
                end
            end
        end
    end

    return pixels
end

-- DW2 PackedWrtNonZero: run length packing, packing types 1, 2 and 3.
local function decode_dw2_packed(f, off, w, h, pack_type)
    local data = read_stream(f, off, w, h)
    if not data then return nil end
    local total, src = #data, 1
    local color_table, base_col

    if pack_type == 3 then
        -- Variable colour table. Tinsel indexes it with the high nibble of the
        -- opcode without checking the declared length, so a short table simply
        -- gets read past its end. Mirror that instead of rejecting the image.
        if src > total then return nil end
        local count = u8(data, src); src = src + 1
        color_table = src
        src = src + count
    elseif pack_type == 1 then
        base_col = 0xF0
    else
        base_col = 0xE0
    end

    local pixels = {}

    for y = 0, h - 1 do
        local row, x, eol = y * w, 0, false
        if src > total then break end
        local x_offset = u8(data, src); src = src + 1

        while x < w do
            local color, num_bytes
            while true do
                if x_offset > 0 then
                    x = x + x_offset
                    x_offset = 0
                end
                if src > total then return pixels end
                local v = u8(data, src); src = src + 1
                num_bytes = v % 16
                if color_table then
                    local ci = color_table + math.floor(v / 16)
                    color = (ci <= total) and (u8(data, ci) or 0) or 0
                else
                    color = base_col + math.floor(v / 16)
                end
                if num_bytes ~= 0 then break end
                if src > total then return pixels end
                num_bytes = u8(data, src); src = src + 1
                if num_bytes >= 16 then break end
                x_offset = num_bytes + v
                if x_offset == 0 then
                    eol = true
                    break
                end
            end
            if eol then break end
            for _ = 1, num_bytes do
                if x < w then pixels[row + x + 1] = color end
                x = x + 1
            end
        end

        -- A row that reached the right edge is followed by an end marker.
        if not eol then src = src + 2 end
    end

    return pixels
end

-- ============================================================================
-- Classification
-- ============================================================================

-- Tinsel picks the decoder from the object type: 0x08/0x48 is a background and
-- is stored as plain 8bpp, while 0x01/0x41 and friends are RLE sprites. Those
-- type bytes live in the scene object table, not in the IMAGE record, so for a
-- c16 == 0 image the two have to be told apart indirectly: only a playfield
-- sized image is a background, and its pixel data has to actually be there.
-- The second rule is what separates the large RLE cutscene frames (BONEDIE,
-- COMPUTER, FILMSET, GIMLETS) from the real backgrounds.
local function is_background(fmt, img, file_size)
    if fmt == DW2 then
        if img.c16 ~= 0 then return false end
        if img.width < DW2_BG_MIN_W or img.height < DW2_BG_MIN_H then return false end
        local _, bits_off = handle_parts(img.hImgBits, DW2.shift)
        return bits_off + img.width * img.height <= file_size
    end
    local _, bits_off = handle_parts(img.hImgBits, DW1.shift)
    return bits_off == DW1_BG_BITS_OFFSET
       and img.width >= DW1_BG_MIN_W and img.height >= DW1_BG_MIN_H
end

-- ============================================================================
-- Decoding a single image record
-- ============================================================================

local function decode_pixels(game_path, handles, fmt, file_name, record)
    local bits_index, bits_off = handle_parts(record.hImgBits, fmt.shift)
    local owner = handles[bits_index]

    -- The pixels are described by their own handle, which normally points at
    -- the file the record was read from.
    local bits_file = open_data(game_path, (owner and owner.name) or file_name)
    if not bits_file then return nil end

    local w, h = record.width, record.height
    local pixels
    if fmt == DW2 then
        if record.c16 ~= 0 then
            pixels = decode_dw2_packed(bits_file, bits_off, w, h, record.c16)
        elseif is_background(DW2, record, bits_file.size) then
            pixels = decode_dw2_raw(bits_file, bits_off, w, h)
        else
            pixels = decode_dw2_rle(bits_file, bits_off, w, h)
        end
    else
        pixels = decode_dw1(bits_file, bits_off, w, h)
    end

    local rgb = resolve_palette(game_path, handles, fmt, file_name, record)
    close_data(bits_file)

    if not pixels then return nil end

    return pixels, rgb and palette_table(rgb) or grayscale_table()
end

local function decode_image(game_path, handles, fmt, file_name, record)
    local pixels, palette = decode_pixels(game_path, handles, fmt, file_name, record)
    if not pixels then return nil end
    return image_create_indexed(record.width, record.height, pixels, palette)
end

-- FILM chunks contain mixed MULTI_INIT, script and variable-length FILM data,
-- with no directory. Validate candidate headers against real IMAGE/frame handles
-- rather than treating consecutive IMAGE records as an animation.
local function animation_reader(game_path, handles, fmt)
    local ctx = { files = {}, images = {}, shapes = {} }
    function ctx:file(index)
        local entry = handles[index]
        if not entry then return nil end
        if self.files[index] == nil then
            self.files[index] = open_data(game_path, entry.name) or false
        end
        return self.files[index] or nil
    end
    function ctx:read(handle, length)
        local index, offset = handle_parts(handle, fmt.shift)
        local raw = read_at(self:file(index), offset, length)
        if not raw or #raw ~= length then return nil end
        return raw
    end
    function ctx:image(handle)
        local index, offset = handle_parts(handle, fmt.shift)
        if not self.images[index] then
            local records = {}
            local f = self:file(index)
            if f then
                for _, img in ipairs(read_image_records(f)) do
                    img.file_name = handles[index].name
                    records[img.record] = img
                end
            end
            self.images[index] = records
        end
        return self.images[index][offset]
    end
    function ctx:shape(handle)
        if self.shapes[handle] ~= nil then return self.shapes[handle] or nil end
        local parts = {}
        for i = 0, 63 do
            local raw = self:read(handle + i * 4, 4)
            if not raw then break end
            local h = u32le(raw, 1)
            if h == 0 then
                if #parts > 0 then self.shapes[handle] = parts; return parts end
                break
            end
            local img = self:image(h)
            if not img then break end
            parts[#parts + 1] = img
        end
        self.shapes[handle] = false
        return nil
    end
    function ctx:close()
        for _, f in pairs(self.files) do if f then close_data(f) end end
    end
    return ctx
end

local function signed32(v) return v < 2147483648 and v or v - 4294967296 end

local function read_sequence(ctx, script, initial, fmt)
    local frames, seen = {}, {}
    local pc, x, y, flip_h, flip_v = script, 0, 0, false, false
    local current = initial
    for _ = 1, 16384 do
        -- Terminate a loop at its bytecode address and flip state; adjustments may accumulate
        -- across cycles, so including position here could make loops unbounded.
        local state = tostring(pc) .. tostring(flip_h) .. tostring(flip_v)
        if seen[state] then return #frames > 1 and frames or nil end
        seen[state] = true
        local raw = ctx:read(pc, 4)
        if not raw then return nil end
        local op = u32le(raw, 1)
        pc = pc + 4
        if op == 0 then return #frames > 1 and frames or nil
        elseif op == 1 then
            raw = ctx:read(pc, 4)
            if not raw then return nil end
            pc = pc + signed32(u32le(raw, 1)) * 4
        elseif op >= 2 and op <= 4 then
            if op ~= 3 then flip_h = not flip_h end
            if op ~= 2 then flip_v = not flip_v end
        elseif op >= 5 and op <= 7 then
            raw = ctx:read(pc, op == 7 and 8 or 4)
            if not raw then return nil end
            if op ~= 6 then
                local dx = signed32(u32le(raw, 1))
                x = x + ((fmt == DW1 and flip_h) and -dx or dx)
            end
            if op ~= 5 then
                local dy = signed32(u32le(raw, op == 7 and 5 or 1))
                y = y + ((fmt == DW1 and flip_v) and -dy or dy)
            end
            pc = pc + (op == 7 and 8 or 4)
        elseif op == 9 or op == 11 then
            -- CALL is unsupported in ScummVM too; STOP belongs to sound reels.
            return nil
        elseif op == 8 and fmt == DW1 then
            -- V1 immediately advances again, without a displayed frame.
        else
            if op == 10 then current = {}
            elseif op ~= 8 then
                current = ctx:shape(op)
                if not current then return nil end
            end
            frames[#frames + 1] = { parts = current, x = x, y = y,
                flip_h = flip_h, flip_v = flip_v }
            if #frames >= 2048 then return nil end
        end
    end
    return nil
end

local function read_reel(ctx, raw, pos, fmt)
    local mobj, script = u32le(raw, pos), u32le(raw, pos + 4)
    local init = ctx:read(mobj, fmt == DW2 and 28 or 24)
    if not init or script == 0 then return nil end
    local initial = ctx:shape(u32le(init, 1))
    if not initial then return nil end
    return read_sequence(ctx, script, initial, fmt)
end

local function read_animations(ctx, f, fmt)
    local out = {}
    local start, size = find_chunk(f, 0x33340008)
    if not start then return out end
    local raw = read_at(f, start, size)
    if not raw then return out end
    local pos = 1
    while pos + 15 <= #raw do
        local fps, reels = u32le(raw, pos), u32le(raw, pos + 4)
        if fps >= 1 and fps <= 24 and reels >= 1 and reels <= 256
            and pos + 7 + reels * 8 <= #raw then
            local valid, sequences = true, {}
            for reel = 1, reels do
                local rp = pos + 8 + (reel - 1) * 8
                local init = ctx:read(u32le(raw, rp), fmt == DW2 and 28 or 24)
                if not init or not ctx:shape(u32le(init, 1))
                    or not ctx:read(u32le(raw, rp + 4), 4) then
                    valid = false; break
                end
                sequences[reel] = read_reel(ctx, raw, rp, fmt) or false
            end
            if valid then
                for reel, frames in ipairs(sequences) do
                    if frames then out[#out + 1] = { record = start + pos - 1,
                        reel = reel, fps = fps, frames = frames } end
                end
                pos = pos + 8 + reels * 8
            else pos = pos + 4 end
        else pos = pos + 4 end
    end
    return out
end

-- Compose all parts on a common canvas using IMAGE animation origins. Each
-- frame keeps its own palette, including cross-file palette references.
local function render_sequence(game_path, handles, fmt, sequence)
    local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
    for _, frame in ipairs(sequence.frames) do
        frame.placed = {}
        for _, img in ipairs(frame.parts) do
            local ax = frame.flip_h and (img.width - 1 - img.anioffX) or img.anioffX
            local ay = frame.flip_v and (img.height - 1 - img.anioffY) or img.anioffY
            local x, y = frame.x - ax, frame.y - ay
            left, top = math.min(left, x), math.min(top, y)
            right, bottom = math.max(right, x + img.width), math.max(bottom, y + img.height)
            frame.placed[#frame.placed + 1] = { img = img, x = x, y = y }
        end
    end
    local w, h = right - left, bottom - top
    if left == math.huge or w < 1 or h < 1 or w > 4096 or h > 4096
        or w * h * #sequence.frames > 64000000 then return nil end
    local decoded, frames = {}, {}
    for _, frame in ipairs(sequence.frames) do
        local pixels, palette, colors, count = {}, grayscale_table(), {}, 0
        for i = 1, w * h do pixels[i] = 0 end
        for _, part in ipairs(frame.placed) do
            local img = part.img
            local key = img.file_name .. ':' .. img.record
            if not decoded[key] then
                local p, pal = decode_pixels(game_path, handles, fmt, img.file_name, img)
                if not p then return nil end
                decoded[key] = { pixels = p, palette = pal }
            end
            local data, remap = decoded[key], {}
            for yy = 0, img.height - 1 do
                for xx = 0, img.width - 1 do
                    local sx = frame.flip_h and (img.width - 1 - xx) or xx
                    local sy = frame.flip_v and (img.height - 1 - yy) or yy
                    local color = data.pixels[sy * img.width + sx + 1] or 0
                    if color ~= 0 then
                        if not remap[color] then
                            local p = color * 3 + 1
                            local r, g, b = data.palette[p], data.palette[p + 1], data.palette[p + 2]
                            local rgb = r * 65536 + g * 256 + b
                            if not colors[rgb] then
                                count = count + 1
                                if count > 255 then return nil end
                                colors[rgb] = count
                                palette[count * 3 + 1], palette[count * 3 + 2], palette[count * 3 + 3] = r, g, b
                            end
                            remap[color] = colors[rgb]
                        end
                        pixels[(part.y - top + yy) * w + part.x - left + xx + 1] = remap[color]
                    end
                end
            end
        end
        frames[#frames + 1] = image_create_indexed(w, h, pixels, palette, 0)
    end
    -- The engine quantizes each frame to 24 Hz game ticks.
    local delay = math.floor(1000 * math.floor(24 / sequence.fps) / 24 + 0.5)
    return animation_create(frames, delay), #frames, delay
end

-- ============================================================================
-- Resource tree
-- ============================================================================

local function image_id(file_name, record)
    return string.format("img_%s_%d", file_name, record.record)
end

function engine.get_resources(game_path)
    if not engine.detect(game_path) then return {} end

    local fmt = is_dw2(game_path) and DW2 or DW1
    local label = (fmt == DW2) and "Discworld 2" or "Discworld 1"
    local handles, files = parse_index(game_path, fmt)
    if not handles then return {} end

    local backgrounds, sprite_groups, sprite_total = {}, {}, 0

    -- Classification needs the size of the file the pixels actually live in,
    -- which is not always the file the record was found in. Sizes are cached
    -- so a shared shape does not reopen its data file once per reference.
    local sizes = {}
    local function data_size(name, known)
        if known then return known end
        local cached = sizes[name]
        if cached then return cached end
        local f = open_data(game_path, name)
        local n = f and f.size or 0
        close_data(f)
        sizes[name] = n
        return n
    end

    for _, entry in ipairs(files) do
        local f = open_data(game_path, entry.name)
        if f then
            local images = read_image_records(f)
            local entry_size = f.size

            local ctx = animation_reader(game_path, handles, fmt)
            local animations = read_animations(ctx, f, fmt)
            ctx:close()
            close_data(f)

            local seen, sprites = {}, {}
            for _, sequence in ipairs(animations) do
                sprites[#sprites + 1] = {
                    id = string.format("anim_%s_%d_%d", entry.name, sequence.record, sequence.reel),
                    name = string.format("Animation @%X reel %d (%d frames)",
                        sequence.record, sequence.reel, #sequence.frames),
                    type = "animation",
                }
            end
            for _, img in ipairs(images) do
                -- Many records point at identical pixel data, list it once.
                if not seen[img.hImgBits] then
                    seen[img.hImgBits] = true
                    local bits_index = math.floor(img.hImgBits / (2 ^ fmt.shift))
                    local owner = handles[bits_index]
                    local owner_name = (owner and owner.name) or entry.name
                    local owner_size = data_size(owner_name,
                        owner_name == entry.name and entry_size or nil)

                    if is_background(fmt, img, owner_size) then
                        backgrounds[#backgrounds + 1] = {
                            id   = image_id(entry.name, img),
                            name = string.format("%s - %dx%d",
                                entry.name:upper(), img.width, img.height),
                            type = "image",
                        }
                    else
                        sprites[#sprites + 1] = {
                            id   = image_id(entry.name, img),
                            name = string.format("%dx%d", img.width, img.height),
                            type = "image",
                        }
                    end
                end
            end

            if #sprites > 0 then
                sprite_total = sprite_total + #sprites
                sprite_groups[#sprite_groups + 1] = {
                    id       = "sprites_" .. entry.name,
                    name     = string.format("%s (%d)", entry.name:upper(), #sprites),
                    type     = "category",
                    children = sprites,
                }
            end
        end
    end

    local resources = {}
    if #backgrounds > 0 then
        resources[#resources + 1] = {
            id       = "cat_backgrounds",
            name     = string.format("%s - Backgrounds (%d)", label, #backgrounds),
            type     = "category",
            children = backgrounds,
        }
    end
    if #sprite_groups > 0 then
        resources[#resources + 1] = {
            id       = "cat_sprites",
            name     = string.format("%s - Sprites (%d)", label, sprite_total),
            type     = "category",
            children = sprite_groups,
        }
    end

    return resources
end

-- ============================================================================
-- Resource loading
-- ============================================================================

function engine.load_resource(game_path, resource_id)
    if not engine.detect(game_path) then return nil end

    local anim_file, film_pos, reel = tostring(resource_id):match("^anim_(.+)_(%d+)_(%d+)$")
    if anim_file and tonumber(reel) >= 1 and tonumber(reel) <= 256 then
        local fmt = is_dw2(game_path) and DW2 or DW1
        local handles = parse_index(game_path, fmt)
        if not handles then return nil end
        local ctx = animation_reader(game_path, handles, fmt)
        local f = open_data(game_path, anim_file)
        local raw = read_at(f, tonumber(film_pos), 8 + tonumber(reel) * 8)
        close_data(f)
        local sequence
        if raw and #raw == 8 + tonumber(reel) * 8 then
            local fps, reels = u32le(raw, 1), u32le(raw, 5)
            if fps >= 1 and fps <= 24 and tonumber(reel) >= 1 and tonumber(reel) <= reels then
                local frames = read_reel(ctx, raw, 9 + (tonumber(reel) - 1) * 8, fmt)
                if frames then sequence = { fps = fps, frames = frames } end
            end
        end
        ctx:close()
        if sequence then
            local ok, anim, count, delay = pcall(render_sequence, game_path, handles, fmt, sequence)
            if ok and anim then
                return { type = "animation", animation = anim, delay_ms = delay,
                    description = string.format("%s - %s reel %d: %d frames (%d ms)",
                        fmt == DW2 and "Discworld 2" or "Discworld 1", anim_file:upper(),
                        tonumber(reel), count, delay) }
            end
        end
        return { type = "text", text = "Cannot decode animation: " .. resource_id }
    end

    local file_name, record_pos = tostring(resource_id):match("^img_(.+)_(%d+)$")
    if not file_name or not record_pos then
        return { type = "text", text = "Unknown resource: " .. tostring(resource_id) }
    end
    record_pos = tonumber(record_pos)

    local fmt = is_dw2(game_path) and DW2 or DW1
    local handles = parse_index(game_path, fmt)
    if not handles then return nil end

    local f = open_data(game_path, file_name)
    if not f then
        return { type = "text", text = "Cannot open: " .. file_name }
    end
    local raw = read_at(f, record_pos, 16)
    close_data(f)
    if not raw then
        return { type = "text", text = "Cannot read image record: " .. resource_id }
    end

    local raw_h = u16le(raw, 3)
    local record = {
        record   = record_pos,
        width    = i16le(raw, 1),
        height   = raw_h % 16384,
        c16      = math.floor(raw_h / 16384) % 4,
        anioffX  = i16le(raw, 5),
        anioffY  = i16le(raw, 7),
        hImgBits = u32le(raw, 9),
        hImgPal  = u32le(raw, 13),
    }

    local ok, img = pcall(decode_image, game_path, handles, fmt, file_name, record)
    if not ok or not img then
        return { type = "text", text = "Cannot decode: " .. resource_id }
    end

    return {
        type        = "image",
        image       = img,
        description = string.format("%s - %s %dx%d",
            (fmt == DW2) and "Discworld 2" or "Discworld 1", file_name:upper(),
            record.width, record.height),
    }
end

return engine

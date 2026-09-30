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
--   DW2  WrtAll            raw 8bpp, used for full screen backgrounds
--   DW2  t2WrtNonZero      byte RLE, used for small c16 == 0 images
--   DW2  PackedWrtNonZero  run length packing, used for c16 = 1/2/3 images
--
-- Image palettes are installed into the video DAC starting at index 1
-- (palette.cpp: FGND_DAC_INDEX), so colour index 0 is the background colour
-- and colour n maps to palette entry n-1. That shift is applied when the
-- 768 entry lookup table is built.
--
-- Tinsel has no animation container, so every image is exposed on its own.
-- ============================================================================

local engine = {}
engine.name        = "Discworld"
engine.id          = "tinsel"
engine.description = "Discworld 1 & 2 (1995/1996, Perfect Entertainment)"
engine.version     = "3.0"

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
                record   = start + pos - 1,   -- 1 based position in the data file
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

    local matrix = read_at(f, char_base, f.size - char_base)
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

            if opcode % 128 >= 128 then
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
        if src > total then return nil end
        local count = u8(data, src); src = src + 1
        if src + count - 1 > total then return nil end
        color_table = {}
        for i = 0, count - 1 do
            color_table[i] = u8(data, src + i)
        end
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
                color = color_table and color_table[math.floor(v / 16)]
                          or (base_col + math.floor(v / 16))
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

-- A background is the image that covers the whole playfield, and it is the
-- only kind stored as plain 8bpp pixel data. The packing type alone does not
-- say so, because Tinsel picks the decoder from the object flags and those
-- live in the scene object table, not in the IMAGE record. Two rules narrow it
-- down: only a playfield sized image is a background, and its pixel data has
-- to actually be there. Discworld 2 has a few large RLE cutscene frames
-- (BONEDIE, COMPUTER, FILMSET, GIMLETS) that only the second rule rules out.
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

local function decode_image(game_path, handles, fmt, file_name, record)
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

    return image_create_indexed(w, h, pixels, rgb and palette_table(rgb) or grayscale_table())
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

    for _, entry in ipairs(files) do
        local f = open_data(game_path, entry.name)
        if f then
            local images = read_image_records(f)
            close_data(f)

            local seen, sprites = {}, {}
            for _, img in ipairs(images) do
                -- Many records point at identical pixel data, list it once.
                if not seen[img.hImgBits] then
                    seen[img.hImgBits] = true
                    if is_background(fmt, img, f.size) then
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

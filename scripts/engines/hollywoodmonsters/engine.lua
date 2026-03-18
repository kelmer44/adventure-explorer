-- ============================================================================
-- Adventure Explorer - Engine Script: Hollywood Monsters (Pendulo Studios, 1997)
-- ============================================================================
-- Resource file format:
--   RESOURCE.000  : Main game data (globals, screen pages, verb icons)
--   RESOURCE.003  : Walk data & actor overlays (scene-indexed, XOR-encrypted)
--   RESOURCE.004  : Additional data
--   RESOURCE.A00–I18 : Chapter scene files (A=Ch1..I=Ch9)
--
-- Scene resource file layout (RESOURCE.Xxx):
--   Bytes 0–159  : Offset table (40 × uint32le, byte offsets within file)
--   Bytes 160–319: Size table   (40 × uint32le, byte sizes of each block)
--   Then sequential data blocks:
--     Block 0: Background image (raw 8bpp, 1024-byte stride × 480 lines)
--     Block 1: Palette (768 bytes = 256 × 3, VGA 6-bit RGB 0–63)
--     Block 2: Extra screen data (RLE z-masks, overlays, etc.)
--     Block 3: Z-order / transparency mask
--     Block 4: Combined resource buffer (sprites, hotspots, etc.)
--     Blocks 5+: Additional overlay layers
--
-- Offset table groups: 6 entries per scene variant (bg, pal, extra, z, res, layers)
-- Multiple variants per file support different room states
--
-- Screen: 640×480 @ 8bpp with 1024-byte pitch (384 bytes padding per scanline)
-- Palette: VGA 6-bit (values 0–63, multiply by 4 for 8-bit)
-- Z-buffer RLE: 3-byte records (fill_byte, run_length_u16le)
-- ============================================================================

local engine = {}
engine.name        = "Hollywood Monsters"
engine.id          = "hollywoodmonsters"
engine.description = "Hollywood Monsters (1997, Pendulo Studios, DOS)"
engine.version     = "1.0"

-- ── Binary helpers ───────────────────────────────────────────────

local function u8(data, pos)   return data:byte(pos) end

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end

-- ── Constants ────────────────────────────────────────────────────

local STRIDE       = 1024   -- VESA mode pitch (bytes per scanline)
local SCREEN_W     = 640
local SCREEN_H     = 480
local FB_SIZE      = STRIDE * SCREEN_H   -- 491,520 bytes
local TABLE_SIZE   = 160    -- 40 × uint32le = offset/size table
local TABLE_ENTRIES = 40
local PALETTE_SIZE = 768    -- 256 × 3 bytes
local ENTRIES_PER_VARIANT = 6  -- bg, pal, extra, z, res, layers

-- ── Chapter definitions ──────────────────────────────────────────
-- Each chapter maps a letter to a range of scene numbers (e.g. A00–A09)

local CHAPTERS = {
    { letter = "A", name = "Chapter A (CD 1)",   first = 0,  last = 9  },
    { letter = "B", name = "Chapter B (CD 2)",   first = 0,  last = 11 },
    { letter = "C", name = "Chapter C (CD 3)",   first = 0,  last = 11 },
    { letter = "D", name = "Chapter D (CD 4)",   first = 0,  last = 11 },
    { letter = "E", name = "Chapter E (CD 5)",   first = 0,  last = 13 },
    { letter = "F", name = "Chapter F (CD 6)",   first = 0,  last = 10 },
    { letter = "G", name = "Chapter G (CD 7)",   first = 1,  last = 10 },
    { letter = "H", name = "Chapter H (CD 8)",   first = 0,  last = 2  },
    { letter = "I", name = "Chapter I (CD 9)",   first = 0,  last = 18 },
}

-- ── File helpers ─────────────────────────────────────────────────

-- Try to find a file case-insensitively
local function find_file(game_path, name)
    local path = game_path .. "/" .. name
    if file_exists(path) then return path end
    path = game_path .. "/" .. name:upper()
    if file_exists(path) then return path end
    path = game_path .. "/" .. name:lower()
    if file_exists(path) then return path end
    return nil
end

-- Format scene number with leading zero (e.g. "A01", "B11")
local function scene_filename(letter, num)
    return string.format("RESOURCE.%s%02d", letter, num)
end

-- ── Read offset and size tables from a scene resource file ───────

local function read_scene_tables(f)
    local raw = file_read(f, 0, TABLE_SIZE * 2)
    if not raw or #raw < TABLE_SIZE * 2 then return nil, nil end

    local offsets = {}
    local sizes   = {}
    for i = 0, TABLE_ENTRIES - 1 do
        offsets[i] = u32le(raw, i * 4 + 1)
        sizes[i]   = u32le(raw, TABLE_SIZE + i * 4 + 1)
    end
    return offsets, sizes
end

-- ── Palette reader (from scene resource, block 1) ────────────────

local function read_palette_from_scene(f, offsets, sizes)
    -- Palette is at offset = 2 × TABLE_SIZE + sizes[0] (right after background)
    -- But we can compute from the file position: tables (320 bytes) + bg (sizes[0])
    local pal_offset = TABLE_SIZE * 2 + sizes[0]
    local pal_size = sizes[1]
    if pal_size == 0 then pal_size = PALETTE_SIZE end
    if pal_size > PALETTE_SIZE then pal_size = PALETTE_SIZE end

    local pal_raw = file_read(f, pal_offset, pal_size)
    if not pal_raw or #pal_raw < pal_size then return nil end

    local palette = {}
    for i = 0, 255 do
        if i * 3 + 3 <= #pal_raw then
            -- VGA 6-bit → 8-bit: multiply by 4, clamp to 255
            palette[i * 3 + 1] = math.min(pal_raw:byte(i * 3 + 1) * 4, 255)
            palette[i * 3 + 2] = math.min(pal_raw:byte(i * 3 + 2) * 4, 255)
            palette[i * 3 + 3] = math.min(pal_raw:byte(i * 3 + 3) * 4, 255)
        else
            palette[i * 3 + 1] = 0
            palette[i * 3 + 2] = 0
            palette[i * 3 + 3] = 0
        end
    end
    return palette
end

-- ── Background loader (from scene resource, block 0) ─────────────
-- Background is stored as raw 8bpp with 1024-byte stride, 480 lines.
-- We extract only the 640-pixel-wide visible portion.

local function load_bg_pixels(f, offsets, sizes)
    local bg_offset = TABLE_SIZE * 2  -- starts immediately after the two tables
    local bg_size   = sizes[0]
    if bg_size == 0 then return nil end

    local raw = file_read(f, bg_offset, bg_size)
    if not raw or #raw < 1 then return nil end

    local pixels = {}
    local n = 0

    if bg_size >= FB_SIZE then
        -- Full 1024-stride framebuffer: extract 640 pixels per row
        for row = 0, SCREEN_H - 1 do
            local row_start = row * STRIDE
            for col = 0, SCREEN_W - 1 do
                n = n + 1
                local pos = row_start + col + 1
                if pos <= #raw then
                    pixels[n] = raw:byte(pos)
                else
                    pixels[n] = 0
                end
            end
        end
    else
        -- Compact storage (640-byte stride or smaller): use raw directly
        local raw_stride = math.floor(bg_size / SCREEN_H)
        if raw_stride < SCREEN_W then raw_stride = SCREEN_W end
        for row = 0, SCREEN_H - 1 do
            local row_start = row * raw_stride
            for col = 0, SCREEN_W - 1 do
                n = n + 1
                local pos = row_start + col + 1
                if pos <= #raw then
                    pixels[n] = raw:byte(pos)
                else
                    pixels[n] = 0
                end
            end
        end
    end

    return pixels
end

-- ── Z-buffer RLE decompressor ────────────────────────────────────
-- Format: 3-byte records (fill_value, run_length_u16le)
-- Decompresses into STRIDE × SCREEN_H = 491,520 bytes

local function decompress_zbuffer_rle(data)
    local result = {}
    local n = 0
    local pos = 1
    local target = FB_SIZE

    while n < target and pos + 2 <= #data do
        local fill_val   = data:byte(pos)
        local run_length = u16le(data, pos + 1)
        pos = pos + 3
        for _ = 1, run_length do
            n = n + 1
            result[n] = fill_val
            if n >= target then break end
        end
    end

    -- Pad to full size
    while n < target do
        n = n + 1
        result[n] = 0
    end

    return result, n
end

-- ── Detection ────────────────────────────────────────────────────

function engine.detect(game_path)
    -- Hollywood Monsters: must have RESOURCE.000 and at least one chapter file
    local has_main = find_file(game_path, "RESOURCE.000") ~= nil
    local has_chapter = find_file(game_path, "RESOURCE.A00") ~= nil
                     or find_file(game_path, "RESOURCE.B00") ~= nil
    local has_r003 = find_file(game_path, "RESOURCE.003") ~= nil

    return has_main and has_chapter and has_r003
end

-- ── Resource tree ────────────────────────────────────────────────

function engine.get_resources(game_path)
    local resources = {}

    for _, chapter in ipairs(CHAPTERS) do
        local chapter_node = {
            id       = "chapter_" .. chapter.letter,
            name     = chapter.name,
            type     = "category",
            children = {}
        }

        local has_scenes = false

        for scene_num = chapter.first, chapter.last do
            local fname = scene_filename(chapter.letter, scene_num)
            local fpath = find_file(game_path, fname)

            if fpath then
                has_scenes = true
                local scene_id = string.format("%s%02d", chapter.letter, scene_num)
                chapter_node.children[#chapter_node.children + 1] = {
                    id       = "scene_" .. scene_id,
                    name     = string.format("Scene %s%02d", chapter.letter, scene_num),
                    type     = "category",
                    children = {
                        { id = "bg_"   .. scene_id, name = "Background", type = "image"   },
                        { id = "pal_"  .. scene_id, name = "Palette",    type = "palette" },
                        { id = "zbuf_" .. scene_id, name = "Z-Buffer",   type = "image"   },
                    }
                }
            end
        end

        if has_scenes then
            resources[#resources + 1] = chapter_node
        end
    end

    return resources
end

-- ── Resource dispatcher ──────────────────────────────────────────

function engine.load_resource(game_path, resource_id, palette_id)
    -- Background: bg_A00, bg_B05, etc.
    if resource_id:match("^bg_%u%d%d$") then
        return load_background(game_path, resource_id:sub(4), palette_id)
    end

    -- Palette: pal_A00, etc.
    if resource_id:match("^pal_%u%d%d$") then
        return load_palette_swatch(game_path, resource_id:sub(5))
    end

    -- Z-buffer: zbuf_A01, etc.
    if resource_id:match("^zbuf_%u%d%d$") then
        return load_zbuffer(game_path, resource_id:sub(6))
    end

    -- Variant background: varbg_A01_2
    local var_scene, var_idx = resource_id:match("^varbg_(%u%d%d)_(%d+)$")
    if var_scene and var_idx then
        return load_variant_background(game_path, var_scene, tonumber(var_idx))
    end

    return nil
end

-- ── Background loader ─────────────────────────────────────────────

function load_background(game_path, scene_id, palette_id)
    local letter = scene_id:sub(1, 1)
    local num    = tonumber(scene_id:sub(2))
    local fname  = scene_filename(letter, num)
    local fpath  = find_file(game_path, fname)
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local offsets, sizes = read_scene_tables(f)
    if not offsets or not sizes or sizes[0] == 0 then
        file_close(f)
        return nil
    end

    local pixels = load_bg_pixels(f, offsets, sizes)

    -- If a palette override is specified, use it
    local palette
    if palette_id and palette_id:match("^pal_%u%d%d$") then
        local pal_scene = palette_id:sub(5)
        local pal_letter = pal_scene:sub(1, 1)
        local pal_num    = tonumber(pal_scene:sub(2))
        local pal_fname  = scene_filename(pal_letter, pal_num)
        local pal_fpath  = find_file(game_path, pal_fname)
        if pal_fpath then
            local pf = file_open(pal_fpath)
            if pf then
                local po, ps = read_scene_tables(pf)
                if po and ps then
                    palette = read_palette_from_scene(pf, po, ps)
                end
                file_close(pf)
            end
        end
    end

    -- Default: read palette from same scene
    if not palette then
        palette = read_palette_from_scene(f, offsets, sizes)
    end

    file_close(f)

    if not pixels or not palette then return nil end

    local img = image_create_indexed(SCREEN_W, SCREEN_H, pixels, palette)
    return {
        type = "image",
        image = img,
        description = string.format(
            "Scene %s background - %dx%d, 256 colors (VGA 6-bit)",
            scene_id, SCREEN_W, SCREEN_H
        )
    }
end

-- ── Variant background loader ─────────────────────────────────────
-- Loads a scene variant using the offset table to seek within the file

function load_variant_background(game_path, scene_id, variant_idx)
    local letter = scene_id:sub(1, 1)
    local num    = tonumber(scene_id:sub(2))
    local fname  = scene_filename(letter, num)
    local fpath  = find_file(game_path, fname)
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local offsets, sizes = read_scene_tables(f)
    if not offsets or not sizes then
        file_close(f)
        return nil
    end

    -- Variant's sections start at index (variant_idx × ENTRIES_PER_VARIANT)
    local base = variant_idx * ENTRIES_PER_VARIANT
    if base >= TABLE_ENTRIES then file_close(f); return nil end

    local bg_offset = offsets[base]
    local bg_size   = sizes[base]
    if bg_offset == 0 or bg_size == 0 then file_close(f); return nil end

    local raw = file_read(f, bg_offset, bg_size)

    -- Palette: try variant's palette, fall back to variant 0
    local pal_offset = offsets[base + 1]
    local pal_size   = sizes[base + 1]
    local palette

    if pal_offset and pal_offset > 0 and pal_size and pal_size > 0 then
        local pal_raw = file_read(f, pal_offset, math.min(pal_size, PALETTE_SIZE))
        if pal_raw and #pal_raw >= PALETTE_SIZE then
            palette = {}
            for i = 0, 255 do
                palette[i * 3 + 1] = math.min(pal_raw:byte(i * 3 + 1) * 4, 255)
                palette[i * 3 + 2] = math.min(pal_raw:byte(i * 3 + 2) * 4, 255)
                palette[i * 3 + 3] = math.min(pal_raw:byte(i * 3 + 3) * 4, 255)
            end
        end
    end

    if not palette then
        palette = read_palette_from_scene(f, offsets, sizes)
    end

    file_close(f)

    if not raw or not palette then return nil end

    -- Extract 640 pixels per row from 1024-stride data
    local pixels = {}
    local n = 0
    if bg_size >= FB_SIZE then
        for row = 0, SCREEN_H - 1 do
            local row_start = row * STRIDE
            for col = 0, SCREEN_W - 1 do
                n = n + 1
                local pos = row_start + col + 1
                pixels[n] = (pos <= #raw) and raw:byte(pos) or 0
            end
        end
    else
        local raw_stride = math.max(math.floor(bg_size / SCREEN_H), SCREEN_W)
        for row = 0, SCREEN_H - 1 do
            local row_start = row * raw_stride
            for col = 0, SCREEN_W - 1 do
                n = n + 1
                local pos = row_start + col + 1
                pixels[n] = (pos <= #raw) and raw:byte(pos) or 0
            end
        end
    end

    local img = image_create_indexed(SCREEN_W, SCREEN_H, pixels, palette)
    return {
        type = "image",
        image = img,
        description = string.format(
            "Scene %s variant %d - %dx%d, 256 colors",
            scene_id, variant_idx, SCREEN_W, SCREEN_H
        )
    }
end

-- ── Palette swatch ────────────────────────────────────────────────

function load_palette_swatch(game_path, scene_id)
    local letter = scene_id:sub(1, 1)
    local num    = tonumber(scene_id:sub(2))
    local fname  = scene_filename(letter, num)
    local fpath  = find_file(game_path, fname)
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local offsets, sizes = read_scene_tables(f)
    local palette = read_palette_from_scene(f, offsets, sizes)
    file_close(f)

    if not palette then return nil end

    -- Render 16×16 grid of colored cells
    local CELL, GRID = 16, 16
    local SIZE = CELL * GRID

    local rgb = {}
    local n = 0
    for py = 0, SIZE - 1 do
        for px = 0, SIZE - 1 do
            local ci = math.floor(py / CELL) * GRID + math.floor(px / CELL)
            n = n + 1; rgb[n] = palette[ci * 3 + 1]
            n = n + 1; rgb[n] = palette[ci * 3 + 2]
            n = n + 1; rgb[n] = palette[ci * 3 + 3]
        end
    end

    local img = image_create_rgb(SIZE, SIZE, rgb)
    return {
        type = "image",
        image = img,
        description = string.format("Scene %s palette - 256 colors (VGA 6-bit ×4)", scene_id)
    }
end

-- ── Z-buffer viewer ───────────────────────────────────────────────
-- Renders the RLE-compressed z-buffer/priority map as a grayscale image

function load_zbuffer(game_path, scene_id)
    local letter = scene_id:sub(1, 1)
    local num    = tonumber(scene_id:sub(2))
    local fname  = scene_filename(letter, num)
    local fpath  = find_file(game_path, fname)
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local offsets, sizes = read_scene_tables(f)
    if not offsets or not sizes then file_close(f); return nil end

    -- Z-buffer is block 3; compute its file offset
    -- Sequential: tables (320) + block0 (sizes[0]) + block1 (sizes[1]) + block2 (sizes[2])
    local zbuf_offset = TABLE_SIZE * 2 + sizes[0] + sizes[1] + sizes[2]
    local zbuf_size   = sizes[3]
    if zbuf_size == 0 then file_close(f); return nil end

    local zbuf_raw = file_read(f, zbuf_offset, zbuf_size)
    file_close(f)

    if not zbuf_raw or #zbuf_raw < 3 then return nil end

    -- Decompress RLE
    local zbuf_pixels = decompress_zbuffer_rle(zbuf_raw)

    -- Extract 640-wide visible portion from 1024-stride data
    local pixels = {}
    local n = 0
    for row = 0, SCREEN_H - 1 do
        local row_start = row * STRIDE
        for col = 0, SCREEN_W - 1 do
            n = n + 1
            local idx = row_start + col + 1
            local val = zbuf_pixels[idx] or 0
            -- Scale z-values to visible grayscale range
            pixels[n] = math.min(val * 16, 255)
        end
    end

    -- Create a grayscale palette
    local gray_palette = {}
    for i = 0, 255 do
        gray_palette[i * 3 + 1] = i
        gray_palette[i * 3 + 2] = i
        gray_palette[i * 3 + 3] = i
    end

    local img = image_create_indexed(SCREEN_W, SCREEN_H, pixels, gray_palette)
    return {
        type = "image",
        image = img,
        description = string.format(
            "Scene %s z-buffer - %dx%d, RLE compressed (%d → %d bytes)",
            scene_id, SCREEN_W, SCREEN_H, zbuf_size, FB_SIZE
        )
    }
end

return engine

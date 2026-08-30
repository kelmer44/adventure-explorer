-- ============================================================================
-- Adventure Explorer - Engine Script: Hollywood Monsters (Pendulo Studios, 1997)
-- ============================================================================
-- Resource file format (cross-checked against ScummVM's in-progress
-- "hollywood" engine, PR scummvm/scummvm#7868):
--   RESOURCE.000     : Shared UI data (options/menu framebuffer, inventory
--                       pages, object palette) + 16 resident sound effects.
--                       1-byte header, then a 100-entry offset/size table.
--   RESOURCE.003     : Walk data & actor overlays (scene-indexed, XOR-encrypted)
--   RESOURCE.004     : Monolithic voice-speech archive shared by all chapters
--                       (4000-entry sequential cue table; PCM encoding is
--                       language-dependent - see SPEECH_ES/IT constants).
--   RESOURCE.A00–I18 : Chapter scene files (A=Ch1..I=Ch9)
--   RESOURCE.S01–S09 : Per-chapter ambient/SFX "sound bank" (not speech;
--                       1000-entry sequential cue table, 8-bit unsigned PCM).
--   RESOURCE.M01–M09 : Per-chapter music cue archive (100-entry sequential
--                       cue table, 16-bit signed LE PCM).
--
-- Scene resource file layout (RESOURCE.Xxx):
--   Bytes 0–159  : Offset table (40 × uint32le, byte offsets within file)
--   Bytes 160–319: Size table   (40 × uint32le, byte sizes of each block)
--   Then sequential data blocks:
--     Block 0: Background image (raw 8bpp, 1024-byte stride × 480 lines)
--     Block 1: Palette (768 bytes = 256 × 3, VGA 6-bit RGB 0–63)
--     Block 2: Extra screen data (overlay layer: raw framebuffer, or a
--              self-describing sprite/icon block list, see below)
--     Block 3: Z-order / transparency mask (RLE)
--     Block 4: Combined resource buffer - a fixed-layout metadata region
--              (pathfinding, palette and verb/relation tables, ending at
--              SCENE_METADATA_END = 0x610a) followed by per-scene sprite/
--              icon pixel data in the same block-list format.
--     Blocks 5+: Additional overlay layers
--
-- Sprite/icon block-list format (used for block 2 overlays, the block 4
-- sprite region, and some RESOURCE.000 UI resources):
--   u16 block_count; per block: u32 packed (x = low16, y = high16), u16
--   size, then `size` raw indexed pixel bytes (one horizontal scanline run
--   at column x, row y). Self-terminating and bounds-checked, so it is only
--   accepted when it fully validates against the source buffer.
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

-- RESOURCE.Sxx "sound bank 0" (per-chapter ambient/SFX archive, not voice
-- speech - see ScummVM's SoundBank0Player). Sequential [off[i], off[i+1])
-- cue pairs, 8-bit unsigned PCM @ 11025 Hz.
local SOUNDBANK_CUE_ENTRIES = 1000
local SOUNDBANK_CUE_TABLE_SIZE = SOUNDBANK_CUE_ENTRIES * 4  -- 4000 bytes
local SOUNDBANK_SAMPLE_RATE = 11025

-- RESOURCE.004: monolithic voice-speech archive shared by all chapters, one
-- cue table for the whole game (see ScummVM's SpeechPlayer). PCM encoding
-- differs by localized release; both interpretations are exposed since the
-- game files alone don't unambiguously identify the language.
local SPEECH004_CUE_ENTRIES = 4000
local SPEECH004_CUE_TABLE_SIZE = SPEECH004_CUE_ENTRIES * 4  -- 16000 bytes
local SPEECH004_ENTRIES_PER_GROUP = 200
local SPEECH_ES_SAMPLE_RATE = 22050  -- Spanish: 8-bit unsigned
local SPEECH_IT_SAMPLE_RATE = 11025  -- Italian: 16-bit signed LE

-- RESOURCE.M0x: per-chapter music cue archive (see ScummVM's MusicPlayer).
-- Sequential [off[i], off[i+1]) cue pairs, 16-bit signed LE PCM @ 11025 Hz.
local MUSIC_CUE_ENTRIES = 100
local MUSIC_CUE_TABLE_SIZE = MUSIC_CUE_ENTRIES * 4  -- 400 bytes
local MUSIC_SAMPLE_RATE = 11025

-- RESOURCE.000 has its own 1-byte header before its offset/size table (100
-- entries instead of 40), holding shared UI resources and 16 resident sound
-- effects (see ScummVM's Resource000FallbackEntry / kResidentSoundResourceEntries).
local R000_HEADER_SIZE     = 1
local R000_TABLE_ENTRIES   = 100
local R000_TABLE_SIZE      = R000_TABLE_ENTRIES * 4  -- 400 bytes
local R000_ENTRY_OPTIONS_FB      = 0x2a  -- main menu / options framebuffer
local R000_ENTRY_INVENTORY_PAGES = 0x2b  -- inventory page framebuffer(s)
local R000_ENTRY_OBJECT_PALETTE  = 0x31  -- 32-color inventory item palette
local R000_OBJECT_PALETTE_COLORS = 32
local RESIDENT_SOUND_ENTRIES = {
    0x55, 0x56, 0x57, 0x58, 0x55, 0x59, 0x55, 0x5a,
    0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62
}
local RESIDENT_SOUND_RATE = 11025  -- 16-bit signed LE

-- Known end of the fixed per-scene metadata region within block 4 (the
-- "combined resource buffer") - pathfinding/palette/verb/relation tables.
-- Any bytes after this point are candidate sprite/overlay pixel data.
local SCENE_METADATA_END = 0x610a

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

-- ── Read RESOURCE.000's offset/size table ─────────────────────────
-- Same layout as read_scene_tables, but with a 1-byte header and 100
-- entries (400-byte tables) instead of 40.

local function read_r000_tables(f)
    local raw = file_read(f, R000_HEADER_SIZE, R000_TABLE_SIZE * 2)
    if not raw or #raw < R000_TABLE_SIZE * 2 then return nil, nil end

    local offsets = {}
    local sizes   = {}
    for i = 0, R000_TABLE_ENTRIES - 1 do
        offsets[i] = u32le(raw, i * 4 + 1)
        sizes[i]   = u32le(raw, R000_TABLE_SIZE + i * 4 + 1)
    end
    return offsets, sizes
end

-- ── Palette reader (from scene resource) ─────────────────────────
-- The palette entry index varies per scene: it can be entry 1, 2, etc.
-- Find it by searching for an entry with exactly 768 bytes (full palette)
-- or a partial palette (<= 768 bytes, divisible by 3).

local function find_palette_in_entries(offsets, sizes, base_idx)
    base_idx = base_idx or 0
    -- First: look for exact 768-byte palette
    for i = base_idx + 1, base_idx + ENTRIES_PER_VARIANT - 1 do
        if i < TABLE_ENTRIES and offsets[i] and offsets[i] > 0
           and sizes[i] and sizes[i] == PALETTE_SIZE then
            return i
        end
    end
    -- Second: partial palette (multiple of 3, <= 768, > 0)
    for i = base_idx + 1, base_idx + ENTRIES_PER_VARIANT - 1 do
        if i < TABLE_ENTRIES and offsets[i] and offsets[i] > 0
           and sizes[i] and sizes[i] > 0
           and sizes[i] < PALETTE_SIZE and sizes[i] % 3 == 0 then
            return i
        end
    end
    return nil
end

local function read_palette_from_entry(f, offsets, sizes, entry_idx)
    local pal_offset = offsets[entry_idx]
    local pal_size = sizes[entry_idx]
    if pal_size > PALETTE_SIZE then pal_size = PALETTE_SIZE end

    local pal_raw = file_read(f, pal_offset, pal_size)
    if not pal_raw or #pal_raw < 3 then return nil end

    local palette = {}
    for i = 0, 255 do
        if i * 3 + 3 <= #pal_raw then
            -- VGA 6-bit to 8-bit: multiply by 4, clamp to 255
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

local function read_palette_from_scene(f, offsets, sizes)
    local pal_idx = find_palette_in_entries(offsets, sizes, 0)
    if pal_idx then
        return read_palette_from_entry(f, offsets, sizes, pal_idx)
    end
    -- Fallback: grayscale palette
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = i
        palette[i * 3 + 2] = i
        palette[i * 3 + 3] = i
    end
    return palette
end

-- ── Background loader (from scene resource, block 0) ─────────────
-- Background is stored as raw 8bpp with 1024-byte stride.
-- Height varies per scene (typically 480, but can be 320, 400, 940, etc.)
-- Scrolling scenes use more than 640 columns of the 1024-byte stride.
-- We extract the full stride and return actual dimensions.

-- Decodes any raw 8bpp/1024-stride framebuffer blob (autocrops horizontal
-- padding). Reused for scene backgrounds, scene overlay layers, and the
-- shared RESOURCE.000 UI framebuffers (options menu, inventory pages).
local function decode_framebuffer_blob(raw)
    if not raw or #raw < STRIDE then return nil, 0, 0 end

    local actual_h = math.floor(#raw / STRIDE)
    if actual_h == 0 then return nil, 0, 0 end

    -- Scan all rows to find the used column range (auto-crop horizontal padding)
    local min_col = STRIDE - 1
    local max_col = 0
    for row = 0, actual_h - 1 do
        local row_start = row * STRIDE
        for col = 0, STRIDE - 1 do
            local pos = row_start + col + 1
            if pos <= #raw and raw:byte(pos) ~= 0 then
                if col < min_col then min_col = col end
                if col > max_col then max_col = col end
            end
        end
    end

    -- If entire image is zeros, default to standard screen width
    if max_col < min_col then
        min_col = 0
        max_col = SCREEN_W - 1
    end

    local img_w = max_col - min_col + 1
    local pixels = {}
    local n = 0
    for row = 0, actual_h - 1 do
        local row_start = row * STRIDE
        for col = min_col, max_col do
            n = n + 1
            local pos = row_start + col + 1
            if pos <= #raw then
                pixels[n] = raw:byte(pos)
            else
                pixels[n] = 0
            end
        end
    end

    return pixels, actual_h, img_w
end

local function load_bg_pixels(f, offsets, sizes)
    local bg_offset = offsets[0]
    local bg_size   = sizes[0]
    if bg_size == 0 or bg_size < STRIDE then return nil, 0, 0 end

    local raw = file_read(f, bg_offset, bg_size)
    return decode_framebuffer_blob(raw)
end

-- ── Sequential cue-table helpers ──────────────────────────────────
-- Music (RESOURCE.M0x), speech (RESOURCE.004) and the sound bank
-- (RESOURCE.Sxx) all share the same simple layout: entry_count × u32le
-- offsets, where cue N spans [offsets[N], offsets[N+1]). This matches
-- ScummVM's MusicPlayer/SpeechPlayer/SoundBank0Player::read*Span().

local function read_cue_offsets(f, entry_count, byte_offset)
    byte_offset = byte_offset or 0
    local raw = file_read(f, byte_offset, entry_count * 4)
    if not raw or #raw < entry_count * 4 then return nil end
    local offs = {}
    for i = 0, entry_count - 1 do
        offs[i] = u32le(raw, i * 4 + 1)
    end
    return offs
end

local function cue_span(offsets, cue_idx, file_size_bytes)
    local start_off = offsets[cue_idx]
    local end_off   = offsets[cue_idx + 1]
    if not start_off or not end_off then return nil, nil end
    if start_off >= end_off or end_off > file_size_bytes then return nil, nil end
    return start_off, end_off - start_off
end

-- ── Resource block-list decoder ───────────────────────────────────
-- Self-describing sprite/UI block format (see ScummVM's drawResourceBlockList):
--   u16 block_count
--   per block: u32 packed_xy (x = low16, y = high16), u16 size, then `size`
--              raw indexed pixel bytes (one scanline run at column x, row y)
-- Strictly validated: only accepted when every block's bounds are sane and
-- fit within the source buffer, so a wrong offset simply fails to parse.

local function try_decode_block_list(raw, base_offset)
    base_offset = base_offset or 0
    if not raw or base_offset < 0 or base_offset + 2 > #raw then return nil end

    local block_count = u16le(raw, base_offset + 1)
    if block_count == 0 or block_count > 8192 then return nil end

    local cursor = base_offset + 2
    local entries = {}
    for _ = 1, block_count do
        if cursor + 6 > #raw then return nil end
        local packed = u32le(raw, cursor + 1)
        local size   = u16le(raw, cursor + 5)
        cursor = cursor + 6
        if size == 0 or cursor + size - 1 > #raw then return nil end

        local x = packed % 65536
        local y = math.floor(packed / 65536)
        if x < 0 or x > 4096 or y < 0 or y > 4096 then return nil end

        entries[#entries + 1] = { x = x, y = y, size = size, data_offset = cursor }
        cursor = cursor + size
    end

    if #entries == 0 then return nil end
    return entries
end

-- Composites decoded block-list entries onto a single indexed canvas sized
-- to their bounding box (each block is one horizontal pixel run).
local function render_block_list_image(raw, entries, palette)
    local max_x, max_y = 0, 0
    for _, e in ipairs(entries) do
        if e.x + e.size > max_x then max_x = e.x + e.size end
        if e.y + 1 > max_y then max_y = e.y + 1 end
    end
    if max_x == 0 or max_y == 0 or max_x * max_y > 4000000 then return nil end

    local pixels = {}
    for i = 1, max_x * max_y do pixels[i] = 0 end
    for _, e in ipairs(entries) do
        local row_base = e.y * max_x
        for col = 0, e.size - 1 do
            local src_pos = e.data_offset + col
            if src_pos <= #raw then
                pixels[row_base + e.x + col + 1] = raw:byte(src_pos)
            end
        end
    end

    return image_create_indexed(max_x, max_y, pixels, palette), max_x, max_y
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
                local scene_children = {
                    { id = "bg_"   .. scene_id, name = "Background", type = "image"   },
                    { id = "pal_"  .. scene_id, name = "Palette",    type = "palette" },
                    { id = "zbuf_" .. scene_id, name = "Z-Buffer",   type = "image"   },
                }

                -- Check for variant backgrounds, overlay data, and sprite data
                local vf = file_open(fpath)
                if vf then
                    local vo, vs = read_scene_tables(vf)
                    file_close(vf)
                    if vo and vs then
                        for var = 1, 6 do
                            local base = var * ENTRIES_PER_VARIANT
                            if base < TABLE_ENTRIES and vo[base] > 0 and vs[base] >= STRIDE
                               and vs[base] % STRIDE == 0 then
                                scene_children[#scene_children + 1] = {
                                    id   = "varbg_" .. scene_id .. "_" .. var,
                                    name = string.format("Variant %d", var),
                                    type = "image"
                                }
                            end
                        end

                        -- Block 2: extra screen data (overlay layer / RLE masks)
                        if vo[2] and vo[2] > 0 and vs[2] and vs[2] > 0 then
                            scene_children[#scene_children + 1] = {
                                id   = "overlay_" .. scene_id,
                                name = "Overlay",
                                type = "image"
                            }
                        end

                        -- Block 4: combined resource buffer - anything past the
                        -- fixed per-scene metadata region is candidate sprite data
                        if vo[4] and vo[4] > 0 and vs[4] and vs[4] > SCENE_METADATA_END then
                            scene_children[#scene_children + 1] = {
                                id   = "sprites_" .. scene_id,
                                name = "Sprites",
                                type = "image"
                            }
                        end
                    end
                end

                chapter_node.children[#chapter_node.children + 1] = {
                    id       = "scene_" .. scene_id,
                    name     = string.format("Scene %s%02d", chapter.letter, scene_num),
                    type     = "category",
                    children = scene_children
                }
            end
        end

        if has_scenes then
            resources[#resources + 1] = chapter_node
        end
    end

    -- Add sound bank categories (RESOURCE.Sxx - ambient/SFX, not speech)
    for ch_idx, chapter in ipairs(CHAPTERS) do
        local sb_fname = string.format("RESOURCE.S%02d", ch_idx)
        local sb_path = find_file(game_path, sb_fname)
        if sb_path then
            local sf = file_open(sb_path)
            if sf then
                local sf_size = file_size(sf)
                local offs = read_cue_offsets(sf, SOUNDBANK_CUE_ENTRIES)
                file_close(sf)

                if offs then
                    local sb_children = {}
                    for cue = 0, SOUNDBANK_CUE_ENTRIES - 2 do
                        local _, size = cue_span(offs, cue, sf_size)
                        if size and size > 1 then
                            sb_children[#sb_children + 1] = {
                                id   = string.format("soundbank_%d_%d", ch_idx, cue),
                                name = string.format("Clip %d", cue),
                                type = "sound"
                            }
                        end
                    end
                    if #sb_children > 0 then
                        resources[#resources + 1] = {
                            id   = "soundbank_ch_" .. chapter.letter,
                            name = string.format("Sound Bank %s (%d clips)", chapter.name, #sb_children),
                            type = "category",
                            children = sb_children
                        }
                    end
                end
            end
        end
    end

    -- Add music categories (RESOURCE.M0x)
    for ch_idx, chapter in ipairs(CHAPTERS) do
        local mfname = string.format("RESOURCE.M%02d", ch_idx)
        local mpath = find_file(game_path, mfname)
        if mpath then
            local mf = file_open(mpath)
            if mf then
                local mf_size = file_size(mf)
                local offs = read_cue_offsets(mf, MUSIC_CUE_ENTRIES)
                file_close(mf)

                if offs then
                    local music_children = {}
                    for cue = 0, MUSIC_CUE_ENTRIES - 2 do
                        local _, size = cue_span(offs, cue, mf_size)
                        if size and size > 1 then
                            music_children[#music_children + 1] = {
                                id   = string.format("music_%d_%d", ch_idx, cue),
                                name = string.format("Cue %d", cue),
                                type = "sound"
                            }
                        end
                    end
                    if #music_children > 0 then
                        resources[#resources + 1] = {
                            id   = "music_ch_" .. chapter.letter,
                            name = string.format("Music %s (%d cues)", chapter.name, #music_children),
                            type = "category",
                            children = music_children
                        }
                    end
                end
            end
        end
    end

    -- Add speech categories (RESOURCE.004 - monolithic voice archive).
    -- The PCM encoding is language-dependent and can't be told apart from the
    -- game files alone, so both known encodings are exposed side by side.
    local speech004_path = find_file(game_path, "RESOURCE.004")
    if speech004_path then
        local sf = file_open(speech004_path)
        if sf then
            local sf_size = file_size(sf)
            local offs = read_cue_offsets(sf, SPEECH004_CUE_ENTRIES)
            file_close(sf)

            if offs then
                local valid_cues = {}
                for cue = 0, SPEECH004_CUE_ENTRIES - 2 do
                    local _, size = cue_span(offs, cue, sf_size)
                    if size and size > 1 then
                        valid_cues[#valid_cues + 1] = cue
                    end
                end

                if #valid_cues > 0 then
                    local variants = {
                        { key = "es8",  label = "Spanish, 8-bit unsigned @ 22050 Hz" },
                        { key = "it16", label = "Italian, 16-bit signed @ 11025 Hz" },
                    }
                    for _, variant in ipairs(variants) do
                        local groups = {}
                        for gstart = 1, #valid_cues, SPEECH004_ENTRIES_PER_GROUP do
                            local gend = math.min(gstart + SPEECH004_ENTRIES_PER_GROUP - 1, #valid_cues)
                            local group_children = {}
                            for k = gstart, gend do
                                local cue = valid_cues[k]
                                group_children[#group_children + 1] = {
                                    id   = string.format("speech004_%s_%d", variant.key, cue),
                                    name = string.format("Clip %d", cue),
                                    type = "sound"
                                }
                            end
                            groups[#groups + 1] = {
                                id       = string.format("speech004grp_%s_%d", variant.key, gstart),
                                name     = string.format("Clips %d–%d", valid_cues[gstart], valid_cues[gend]),
                                type     = "category",
                                children = group_children
                            }
                        end
                        resources[#resources + 1] = {
                            id       = "speech004_cat_" .. variant.key,
                            name     = string.format("Speech (%s, %d clips)", variant.label, #valid_cues),
                            type     = "category",
                            children = groups
                        }
                    end
                end
            end
        end
    end

    -- Add shared RESOURCE.000 UI resources and resident sound effects
    local r000_path = find_file(game_path, "RESOURCE.000")
    if r000_path then
        local rf = file_open(r000_path)
        if rf then
            local ro, rs = read_r000_tables(rf)
            file_close(rf)

            if ro and rs then
                local main_children = {}

                if ro[R000_ENTRY_OPTIONS_FB] and ro[R000_ENTRY_OPTIONS_FB] > 0
                   and rs[R000_ENTRY_OPTIONS_FB] and rs[R000_ENTRY_OPTIONS_FB] % STRIDE == 0
                   and rs[R000_ENTRY_OPTIONS_FB] >= STRIDE then
                    main_children[#main_children + 1] = {
                        id = "r000_optionsfb", name = "Options Menu Background", type = "image"
                    }
                end

                if ro[R000_ENTRY_INVENTORY_PAGES] and ro[R000_ENTRY_INVENTORY_PAGES] > 0
                   and rs[R000_ENTRY_INVENTORY_PAGES] and rs[R000_ENTRY_INVENTORY_PAGES] % STRIDE == 0
                   and rs[R000_ENTRY_INVENTORY_PAGES] >= STRIDE then
                    main_children[#main_children + 1] = {
                        id = "r000_invpages", name = "Inventory Pages", type = "image"
                    }
                end

                if ro[R000_ENTRY_OBJECT_PALETTE] and ro[R000_ENTRY_OBJECT_PALETTE] > 0
                   and rs[R000_ENTRY_OBJECT_PALETTE] and rs[R000_ENTRY_OBJECT_PALETTE] > 0 then
                    main_children[#main_children + 1] = {
                        id = "r000_objpal", name = "Object Palette", type = "palette"
                    }
                end

                local sfx_children = {}
                for effect_id = 1, #RESIDENT_SOUND_ENTRIES do
                    local entry = RESIDENT_SOUND_ENTRIES[effect_id]
                    if ro[entry] and ro[entry] > 0 and rs[entry] and rs[entry] > 1 then
                        sfx_children[#sfx_children + 1] = {
                            id = "r000_sfx_" .. effect_id,
                            name = string.format("Effect %d", effect_id),
                            type = "sound"
                        }
                    end
                end
                if #sfx_children > 0 then
                    main_children[#main_children + 1] = {
                        id = "r000_sfx_cat",
                        name = string.format("Resident Sound Effects (%d)", #sfx_children),
                        type = "category",
                        children = sfx_children
                    }
                end

                if #main_children > 0 then
                    resources[#resources + 1] = {
                        id = "r000_cat", name = "Main Data (RESOURCE.000)",
                        type = "category", children = main_children
                    }
                end
            end
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

    -- Overlay layer (block 2): overlay_A01
    if resource_id:match("^overlay_%u%d%d$") then
        return load_scene_overlay(game_path, resource_id:sub(9))
    end

    -- Sprite/icon block list (block 4 trailing data): sprites_A01
    if resource_id:match("^sprites_%u%d%d$") then
        return load_scene_sprites(game_path, resource_id:sub(9))
    end

    -- Sound bank clip: soundbank_1_42
    local sb_ch, sb_clip = resource_id:match("^soundbank_(%d+)_(%d+)$")
    if sb_ch and sb_clip then
        return load_soundbank_clip(game_path, tonumber(sb_ch), tonumber(sb_clip))
    end

    -- Music cue: music_1_13
    local mus_ch, mus_cue = resource_id:match("^music_(%d+)_(%d+)$")
    if mus_ch and mus_cue then
        return load_music_cue(game_path, tonumber(mus_ch), tonumber(mus_cue))
    end

    -- Speech clip (RESOURCE.004): speech004_es8_123, speech004_it16_123
    local sp_variant, sp_cue = resource_id:match("^speech004_(%a+%d*)_(%d+)$")
    if sp_variant and sp_cue then
        return load_speech004_clip(game_path, sp_variant, tonumber(sp_cue))
    end

    -- RESOURCE.000 shared UI resources
    if resource_id == "r000_optionsfb" then
        return load_r000_framebuffer(game_path, R000_ENTRY_OPTIONS_FB, "Options Menu Background")
    end
    if resource_id == "r000_invpages" then
        return load_r000_framebuffer(game_path, R000_ENTRY_INVENTORY_PAGES, "Inventory Pages")
    end
    if resource_id == "r000_objpal" then
        return load_r000_object_palette(game_path)
    end

    -- Resident sound effect: r000_sfx_3
    local sfx_id = resource_id:match("^r000_sfx_(%d+)$")
    if sfx_id then
        return load_r000_resident_sfx(game_path, tonumber(sfx_id))
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

    local pixels, actual_h, img_w = load_bg_pixels(f, offsets, sizes)

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

    local img = image_create_indexed(img_w, actual_h, pixels, palette)
    return {
        type = "image",
        image = img,
        description = string.format(
            "Scene %s background - %dx%d, 256 colors (VGA 6-bit)",
            scene_id, img_w, actual_h
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

    -- Variant's sections start at index (variant_idx * ENTRIES_PER_VARIANT)
    local base = variant_idx * ENTRIES_PER_VARIANT
    if base >= TABLE_ENTRIES then file_close(f); return nil end

    local bg_offset = offsets[base]
    local bg_size   = sizes[base]
    if bg_offset == 0 or bg_size == 0 then file_close(f); return nil end

    -- Only raw framebuffers (size divisible by STRIDE) can be rendered
    if bg_size % STRIDE ~= 0 then
        file_close(f)
        return { type = "text", text = string.format(
            "Variant %d: compressed overlay (%d bytes, not raw framebuffer)",
            variant_idx, bg_size) }
    end

    local raw = file_read(f, bg_offset, bg_size)

    -- Palette: search variant's entries, fall back to base scene palette
    local palette
    local pal_idx = find_palette_in_entries(offsets, sizes, base)
    if pal_idx then
        palette = read_palette_from_entry(f, offsets, sizes, pal_idx)
    end
    if not palette then
        palette = read_palette_from_scene(f, offsets, sizes)
    end

    file_close(f)

    if not raw or not palette then return nil end

    local actual_h = math.floor(bg_size / STRIDE)

    -- Auto-crop horizontal padding (same as main background)
    local min_col = STRIDE - 1
    local max_col = 0
    for row = 0, actual_h - 1 do
        local row_start = row * STRIDE
        for col = 0, STRIDE - 1 do
            local pos = row_start + col + 1
            if pos <= #raw and raw:byte(pos) ~= 0 then
                if col < min_col then min_col = col end
                if col > max_col then max_col = col end
            end
        end
    end
    if max_col < min_col then
        min_col = 0
        max_col = SCREEN_W - 1
    end

    local img_w = max_col - min_col + 1
    local pixels = {}
    local n = 0
    for row = 0, actual_h - 1 do
        local row_start = row * STRIDE
        for col = min_col, max_col do
            n = n + 1
            local pos = row_start + col + 1
            pixels[n] = (pos <= #raw) and raw:byte(pos) or 0
        end
    end

    local img = image_create_indexed(img_w, actual_h, pixels, palette)
    return {
        type = "image",
        image = img,
        description = string.format(
            "Scene %s variant %d - %dx%d, 256 colors",
            scene_id, variant_idx, img_w, actual_h
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

    -- Z-buffer is block 3; use offset from the table
    local zbuf_offset = offsets[3]
    local zbuf_size   = sizes[3]
    if zbuf_offset == 0 or zbuf_size == 0 then file_close(f); return nil end

    local zbuf_raw = file_read(f, zbuf_offset, zbuf_size)
    file_close(f)

    if not zbuf_raw or #zbuf_raw < 3 then return nil end

    -- Decompress RLE into the full STRIDE*SCREEN_H buffer
    local zbuf_pixels = decompress_zbuffer_rle(zbuf_raw)

    -- Determine actual background dimensions from block 0
    local bg_size = sizes[0]
    local actual_h = SCREEN_H
    if bg_size > 0 then
        actual_h = math.floor(bg_size / STRIDE)
    end
    if actual_h == 0 then actual_h = SCREEN_H end

    -- Scan for used column range in z-buffer
    local min_col = STRIDE - 1
    local max_col = 0
    for row = 0, actual_h - 1 do
        local row_start = row * STRIDE
        for col = 0, STRIDE - 1 do
            local idx = row_start + col + 1
            local val = zbuf_pixels[idx] or 0
            if val ~= 0 then
                if col < min_col then min_col = col end
                if col > max_col then max_col = col end
            end
        end
    end
    if max_col < min_col then
        min_col = 0
        max_col = SCREEN_W - 1
    end

    local img_w = max_col - min_col + 1
    local pixels = {}
    local n = 0
    for row = 0, actual_h - 1 do
        local row_start = row * STRIDE
        for col = min_col, max_col do
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

    local img = image_create_indexed(img_w, actual_h, pixels, gray_palette)
    return {
        type = "image",
        image = img,
        description = string.format(
            "Scene %s z-buffer - %dx%d, RLE compressed (%d bytes)",
            scene_id, img_w, actual_h, zbuf_size
        )
    }
end

-- ── Sound bank support (RESOURCE.Sxx) ──────────────────────────────
-- Per-chapter ambient/SFX archive (ScummVM's SoundBank0Player), not voice
-- speech. 1000-entry sequential cue table, 8-bit unsigned PCM @ 11025 Hz.

function load_soundbank_clip(game_path, chapter_idx, clip_idx)
    local fname = string.format("RESOURCE.S%02d", chapter_idx)
    local fpath = find_file(game_path, fname)
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local fsize = file_size(f)
    local offs = read_cue_offsets(f, SOUNDBANK_CUE_ENTRIES)
    if not offs then file_close(f); return nil end

    local clip_off, clip_size = cue_span(offs, clip_idx, fsize)
    if not clip_off or clip_size <= 1 then
        file_close(f)
        return { type = "text", text = string.format("Empty sound bank clip %d", clip_idx) }
    end

    local pcm_data = file_read(f, clip_off, clip_size)
    file_close(f)
    if not pcm_data or #pcm_data < 2 then return nil end

    local snd = sound_create_pcm(SOUNDBANK_SAMPLE_RATE, 8, 1, false, pcm_data)
    local duration_ms = math.floor(clip_size * 1000 / SOUNDBANK_SAMPLE_RATE)
    return {
        type = "sound",
        sound = snd,
        description = string.format(
            "Sound bank clip %d (chapter %d) - %d bytes, %d ms @ %d Hz, 8-bit unsigned PCM",
            clip_idx, chapter_idx, clip_size, duration_ms, SOUNDBANK_SAMPLE_RATE
        )
    }
end

-- ── Music support (RESOURCE.M0x) ───────────────────────────────────
-- Per-chapter music cue archive (ScummVM's MusicPlayer). 100-entry
-- sequential cue table, 16-bit signed little-endian PCM @ 11025 Hz.

function load_music_cue(game_path, chapter_idx, cue_idx)
    local fname = string.format("RESOURCE.M%02d", chapter_idx)
    local fpath = find_file(game_path, fname)
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local fsize = file_size(f)
    local offs = read_cue_offsets(f, MUSIC_CUE_ENTRIES)
    if not offs then file_close(f); return nil end

    local cue_off, cue_size = cue_span(offs, cue_idx, fsize)
    if not cue_off or cue_size <= 1 then
        file_close(f)
        return { type = "text", text = string.format("Empty music cue %d", cue_idx) }
    end

    local pcm_data = file_read(f, cue_off, cue_size)
    file_close(f)
    if not pcm_data or #pcm_data < 2 then return nil end
    if #pcm_data % 2 == 1 then pcm_data = pcm_data:sub(1, #pcm_data - 1) end

    local snd = sound_create_pcm(MUSIC_SAMPLE_RATE, 16, 1, true, pcm_data)
    local duration_ms = math.floor(#pcm_data * 1000 / (MUSIC_SAMPLE_RATE * 2))
    return {
        type = "sound",
        sound = snd,
        description = string.format(
            "Music cue %d (chapter %d) - %d bytes, %d ms @ %d Hz, 16-bit signed PCM",
            cue_idx, chapter_idx, #pcm_data, duration_ms, MUSIC_SAMPLE_RATE
        )
    }
end

-- ── Speech support (RESOURCE.004) ───────────────────────────────────
-- Monolithic voice-speech archive shared across all chapters (ScummVM's
-- SpeechPlayer). 4000-entry sequential cue table; PCM encoding depends on
-- the localized release, so both known encodings are offered:
--   es8  = Spanish, 8-bit unsigned PCM  @ 22050 Hz
--   it16 = Italian, 16-bit signed LE PCM @ 11025 Hz

function load_speech004_clip(game_path, variant, cue_idx)
    local fpath = find_file(game_path, "RESOURCE.004")
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local fsize = file_size(f)
    local offs = read_cue_offsets(f, SPEECH004_CUE_ENTRIES)
    if not offs then file_close(f); return nil end

    local cue_off, cue_size = cue_span(offs, cue_idx, fsize)
    if not cue_off or cue_size <= 1 then
        file_close(f)
        return { type = "text", text = string.format("Empty speech clip %d", cue_idx) }
    end

    local pcm_data = file_read(f, cue_off, cue_size)
    file_close(f)
    if not pcm_data or #pcm_data < 1 then return nil end

    if variant == "it16" then
        if #pcm_data % 2 == 1 then pcm_data = pcm_data:sub(1, #pcm_data - 1) end
        if #pcm_data < 2 then return nil end
        local snd = sound_create_pcm(SPEECH_IT_SAMPLE_RATE, 16, 1, true, pcm_data)
        local duration_ms = math.floor(#pcm_data * 1000 / (SPEECH_IT_SAMPLE_RATE * 2))
        return {
            type = "sound",
            sound = snd,
            description = string.format(
                "Speech clip %d (Italian) - %d bytes, %d ms @ %d Hz, 16-bit signed PCM",
                cue_idx, #pcm_data, duration_ms, SPEECH_IT_SAMPLE_RATE
            )
        }
    end

    local snd = sound_create_pcm(SPEECH_ES_SAMPLE_RATE, 8, 1, false, pcm_data)
    local duration_ms = math.floor(#pcm_data * 1000 / SPEECH_ES_SAMPLE_RATE)
    return {
        type = "sound",
        sound = snd,
        description = string.format(
            "Speech clip %d (Spanish) - %d bytes, %d ms @ %d Hz, 8-bit unsigned PCM",
            cue_idx, #pcm_data, duration_ms, SPEECH_ES_SAMPLE_RATE
        )
    }
end

-- ── Scene overlay loader (block 2) ─────────────────────────────────
-- Extra screen data: either a raw framebuffer overlay layer, or a
-- self-describing sprite/icon block list.

function load_scene_overlay(game_path, scene_id)
    local letter = scene_id:sub(1, 1)
    local num    = tonumber(scene_id:sub(2))
    local fname  = scene_filename(letter, num)
    local fpath  = find_file(game_path, fname)
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local offsets, sizes = read_scene_tables(f)
    if not offsets or not sizes or not offsets[2] or offsets[2] == 0 or not sizes[2] or sizes[2] == 0 then
        file_close(f)
        return nil
    end

    local raw = file_read(f, offsets[2], sizes[2])
    local palette = read_palette_from_scene(f, offsets, sizes)
    file_close(f)

    if not raw or not palette then return nil end

    if #raw % STRIDE == 0 and #raw >= STRIDE then
        local pixels, h, w = decode_framebuffer_blob(raw)
        if pixels then
            local img = image_create_indexed(w, h, pixels, palette)
            return {
                type = "image",
                image = img,
                description = string.format(
                    "Scene %s overlay - %dx%d raw framebuffer (%d bytes)",
                    scene_id, w, h, #raw
                )
            }
        end
    end

    local entries = try_decode_block_list(raw, 0)
    if entries then
        local img, w, h = render_block_list_image(raw, entries, palette)
        if img then
            return {
                type = "image",
                image = img,
                description = string.format(
                    "Scene %s overlay - %d blocks composited into %dx%d (%d bytes)",
                    scene_id, #entries, w, h, #raw
                )
            }
        end
    end

    return { type = "text", text = string.format(
        "Scene %s overlay - unrecognized format (%d bytes)", scene_id, #raw) }
end

-- ── Scene sprite loader (block 4 trailing data) ────────────────────
-- Block 4 starts with a fixed-layout metadata region (pathfinding, palette
-- and verb/relation tables); anything after SCENE_METADATA_END is candidate
-- sprite/icon pixel data in the same self-describing block-list format.

function load_scene_sprites(game_path, scene_id)
    local letter = scene_id:sub(1, 1)
    local num    = tonumber(scene_id:sub(2))
    local fname  = scene_filename(letter, num)
    local fpath  = find_file(game_path, fname)
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local offsets, sizes = read_scene_tables(f)
    if not offsets or not sizes or not offsets[4] or offsets[4] == 0
       or not sizes[4] or sizes[4] <= SCENE_METADATA_END then
        file_close(f)
        return nil
    end

    local raw = file_read(f, offsets[4], sizes[4])
    local palette = read_palette_from_scene(f, offsets, sizes)
    file_close(f)

    if not raw or not palette then return nil end

    local entries = try_decode_block_list(raw, SCENE_METADATA_END)
    if not entries then
        return { type = "text", text = string.format(
            "Scene %s sprites - unrecognized format past metadata (%d bytes total)",
            scene_id, #raw) }
    end

    local img, w, h = render_block_list_image(raw, entries, palette)
    if not img then return nil end

    return {
        type = "image",
        image = img,
        description = string.format(
            "Scene %s sprites - %d blocks composited into %dx%d",
            scene_id, #entries, w, h
        )
    }
end

-- ── RESOURCE.000 shared UI resources ───────────────────────────────

function load_r000_framebuffer(game_path, entry_idx, label)
    local fpath = find_file(game_path, "RESOURCE.000")
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local offsets, sizes = read_r000_tables(f)
    if not offsets or not sizes or not offsets[entry_idx] or offsets[entry_idx] == 0
       or not sizes[entry_idx] or sizes[entry_idx] == 0 then
        file_close(f)
        return nil
    end

    local raw = file_read(f, offsets[entry_idx], sizes[entry_idx])

    -- Prefer a full 768-byte VGA palette entry anywhere in the table; fall
    -- back to the small 32-color object palette, then plain grayscale.
    local palette
    for i = 0, R000_TABLE_ENTRIES - 1 do
        if offsets[i] and offsets[i] > 0 and sizes[i] == PALETTE_SIZE then
            palette = read_palette_from_entry(f, offsets, sizes, i)
            break
        end
    end
    if not palette and offsets[R000_ENTRY_OBJECT_PALETTE] and offsets[R000_ENTRY_OBJECT_PALETTE] > 0
       and sizes[R000_ENTRY_OBJECT_PALETTE] and sizes[R000_ENTRY_OBJECT_PALETTE] > 0 then
        palette = read_palette_from_entry(f, offsets, sizes, R000_ENTRY_OBJECT_PALETTE)
    end
    file_close(f)

    if not raw then return nil end
    if not palette then
        palette = {}
        for i = 0, 255 do
            palette[i * 3 + 1] = i; palette[i * 3 + 2] = i; palette[i * 3 + 3] = i
        end
    end

    local pixels, h, w = decode_framebuffer_blob(raw)
    if not pixels then return nil end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image",
        image = img,
        description = string.format("%s - %dx%d, 256 colors", label, w, h)
    }
end

function load_r000_object_palette(game_path)
    local fpath = find_file(game_path, "RESOURCE.000")
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local offsets, sizes = read_r000_tables(f)
    if not offsets or not sizes or not offsets[R000_ENTRY_OBJECT_PALETTE]
       or offsets[R000_ENTRY_OBJECT_PALETTE] == 0 then
        file_close(f)
        return nil
    end

    local pal_size = sizes[R000_ENTRY_OBJECT_PALETTE]
    local pal_raw = file_read(f, offsets[R000_ENTRY_OBJECT_PALETTE], pal_size)
    file_close(f)
    if not pal_raw or #pal_raw < 3 then return nil end

    local num_colors = math.min(math.floor(#pal_raw / 3), R000_OBJECT_PALETTE_COLORS)
    local CELL, GRID = 32, 8
    local W, H = CELL * GRID, CELL * math.ceil(num_colors / GRID)

    local rgb = {}
    local n = 0
    for py = 0, H - 1 do
        for px = 0, W - 1 do
            local ci = math.floor(py / CELL) * GRID + math.floor(px / CELL)
            local r, g, b = 0, 0, 0
            if ci < num_colors then
                r = math.min(pal_raw:byte(ci * 3 + 1) * 4, 255)
                g = math.min(pal_raw:byte(ci * 3 + 2) * 4, 255)
                b = math.min(pal_raw:byte(ci * 3 + 3) * 4, 255)
            end
            n = n + 1; rgb[n] = r
            n = n + 1; rgb[n] = g
            n = n + 1; rgb[n] = b
        end
    end

    local img = image_create_rgb(W, H, rgb)
    return {
        type = "image",
        image = img,
        description = string.format("Object palette - %d colors (VGA 6-bit ×4)", num_colors)
    }
end

function load_r000_resident_sfx(game_path, effect_id)
    if effect_id < 1 or effect_id > #RESIDENT_SOUND_ENTRIES then return nil end
    local fpath = find_file(game_path, "RESOURCE.000")
    if not fpath then return nil end

    local f = file_open(fpath)
    if not f then return nil end

    local offsets, sizes = read_r000_tables(f)
    local entry = RESIDENT_SOUND_ENTRIES[effect_id]
    if not offsets or not sizes or not offsets[entry] or offsets[entry] == 0
       or not sizes[entry] or sizes[entry] < 2 then
        file_close(f)
        return nil
    end

    local pcm_data = file_read(f, offsets[entry], sizes[entry])
    file_close(f)
    if not pcm_data or #pcm_data < 2 then return nil end
    if #pcm_data % 2 == 1 then pcm_data = pcm_data:sub(1, #pcm_data - 1) end

    local snd = sound_create_pcm(RESIDENT_SOUND_RATE, 16, 1, true, pcm_data)
    local duration_ms = math.floor(#pcm_data * 1000 / (RESIDENT_SOUND_RATE * 2))
    return {
        type = "sound",
        sound = snd,
        description = string.format(
            "Resident sound effect %d - %d bytes, %d ms @ %d Hz, 16-bit signed PCM",
            effect_id, #pcm_data, duration_ms, RESIDENT_SOUND_RATE
        )
    }
end

return engine


-- ============================================================================
-- Adventure Explorer - Engine Script: Leather Goddesses of Phobos 2
-- ============================================================================
-- Activision / Infocom, 1992. DOS. MADE engine (V2).
--
-- Resource archive: LGOP2.PRJ
--   24-byte file header
--   Index of resource type directories (FLEX, SNDS, ANIM, MENU, FONT, etc.)
--   Each type has an INDX block with per-resource offset+size
--   Resources have a 62-byte header (V2) that is skipped
--
-- Pictures (FLEX): 18-byte header + optional palette + compressed image
--   Decompression: 4×4 pixel blocks with 2-bit command stream
--
-- Sounds (SNDS): Custom ADPCM-like compression
--   Header at offset 8: chunkCount, offset 12: chunkSize
--   Decompressed data: unsigned 8-bit PCM mono @ 8000 Hz
-- ============================================================================

local engine = {}
engine.name        = "Leather Goddesses of Phobos 2"
engine.id          = "lgop2"
engine.description = "Leather Goddesses of Phobos 2 (1992, Activision/Infocom)"
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

local function u32be(data, pos)
    return data:byte(pos) * 16777216
         + data:byte(pos + 1) * 65536
         + data:byte(pos + 2) * 256
         + data:byte(pos + 3)
end

-- ── Constants ────────────────────────────────────────────────────

local PRJ_HEADER_SIZE    = 24       -- 0x18 bytes skipped
local RES_HEADER_SIZE    = 62       -- V2 resource header (skipped)
local INDX_HEADER_SIZE   = 22       -- INDX block header before entries
local TYPE_ENTRY_SIZE    = 24       -- bytes per resource-type entry in PRJ
local SOUND_SAMPLE_RATE  = 8000     -- LGOP2 sound playback rate
local LINE_BUF_PITCH     = 320      -- row stride in decompression line buffer

-- Resource type tags (big-endian uint32)
local TAG_FLEX = 0x464C4558   -- 'FLEX' - Pictures
local TAG_SNDS = 0x534E4453   -- 'SNDS' - Sounds
local TAG_ANIM = 0x414E494D   -- 'ANIM' - Animations
local TAG_MENU = 0x4D454E55   -- 'MENU' - Menus
local TAG_FONT = 0x464F4E54   -- 'FONT' - Fonts
local TAG_XMID = 0x584D4944   -- 'XMID' - XMIDI music
local TAG_MIDI = 0x4D494449   -- 'MIDI' - MIDI music

-- Skipped internal types
local TAG_ARCH = 0x41524348
local TAG_FREE = 0x46524545
local TAG_OMNI = 0x4F4D4E49

-- Module-level palette cache (persists across load_resource calls)
local _resource_types = nil    -- set by get_resources()
local _game_palette   = nil    -- first palette found in any FLEX resource

local TAG_NAMES = {
    [TAG_FLEX] = "Pictures",
    [TAG_SNDS] = "Sounds",
    [TAG_ANIM] = "Animations",
    [TAG_MENU] = "Menus",
    [TAG_FONT] = "Fonts",
    [TAG_XMID] = "XMIDI Music",
    [TAG_MIDI] = "MIDI Music",
}

local TAG_ICONS = {
    [TAG_FLEX] = "image",
    [TAG_SNDS] = "sound",
    [TAG_ANIM] = "image",
    [TAG_MENU] = "text",
    [TAG_FONT] = "image",
    [TAG_XMID] = "midi",
    [TAG_MIDI] = "midi",
}

-- ── Palette cache helpers ───────────────────────────────────────

-- Lazily scan FLEX resources until we find one with an embedded palette.
-- Stores result in _game_palette for reuse by all subsequent loads.
local function ensure_game_palette(game_path)
    if _game_palette then return end
    if not _resource_types then return end

    local flex_slots = nil
    for _, rt in ipairs(_resource_types) do
        if rt.tag == TAG_FLEX then
            flex_slots = rt.slots
            break
        end
    end
    if not flex_slots or #flex_slots == 0 then return end

    local prj_path = game_path .. "/LGOP2.PRJ"
    if not file_exists(prj_path) then
        prj_path = game_path .. "/lgop2.prj"
    end
    if not file_exists(prj_path) then return end

    local f = file_open(prj_path)
    if not f then return end

    local limit = math.min(#flex_slots, 300)
    for i = 1, limit do
        local slot = flex_slots[i]
        -- Read 6 bytes: hasPalette(1) cmdFlags(1) pixelFlags(1) maskFlags(1) cmdOffsLo(1) cmdOffsHi(1)
        local hdr = file_read(f, slot.offset, 6)
        if hdr and #hdr >= 6 and hdr:byte(1) ~= 0 then
            local cmd_offs = hdr:byte(5) + hdr:byte(6) * 256
            if cmd_offs > 18 then
                local pal_count = math.floor((cmd_offs - 18) / 3)
                if pal_count >= 1 and pal_count <= 256 then
                    local pal_data = file_read(f, slot.offset + 18, pal_count * 3)
                    if pal_data and #pal_data >= pal_count * 3 then
                        _game_palette = {}
                        for j = 0, pal_count - 1 do
                            local p = j * 3 + 1
                            _game_palette[j * 3 + 1] = pal_data:byte(p)
                            _game_palette[j * 3 + 2] = pal_data:byte(p + 1)
                            _game_palette[j * 3 + 3] = pal_data:byte(p + 2)
                        end
                        for j = pal_count, 255 do
                            _game_palette[j * 3 + 1] = 0
                            _game_palette[j * 3 + 2] = 0
                            _game_palette[j * 3 + 3] = 0
                        end
                        log_info(string.format("[lgop2] Cached game palette from FLEX slot %d (%d colors)", i, pal_count))
                        break
                    end
                end
            end
        end
    end

    file_close(f)
end

-- ── File helpers ─────────────────────────────────────────────────

local function find_file(game_path, name)
    local path = game_path .. "/" .. name
    if file_exists(path) then return path end
    path = game_path .. "/" .. name:upper()
    if file_exists(path) then return path end
    path = game_path .. "/" .. name:lower()
    if file_exists(path) then return path end
    return nil
end

-- ── PRJ archive parser ──────────────────────────────────────────

local function parse_prj(game_path)
    local prj_path = find_file(game_path, "LGOP2.PRJ")
    if not prj_path then return nil end

    local f = file_open(prj_path)
    if not f then return nil end
    local fsize = file_size(f)

    -- Read header + index count
    local hdr = file_read(f, 0, PRJ_HEADER_SIZE + 2)
    if not hdr or #hdr < PRJ_HEADER_SIZE + 2 then
        file_close(f)
        return nil
    end

    local index_count = u16le(hdr, PRJ_HEADER_SIZE + 1)

    -- Read all type entries
    local type_data_offset = PRJ_HEADER_SIZE + 2
    local type_data = file_read(f, type_data_offset, index_count * TYPE_ENTRY_SIZE)
    if not type_data then file_close(f); return nil end

    local resource_types = {}

    for i = 0, index_count - 1 do
        local ep = i * TYPE_ENTRY_SIZE + 1
        local res_type = u32be(type_data, ep)
        local index_offs = u32le(type_data, ep + 4)

        -- Skip internal types
        if res_type ~= TAG_ARCH and res_type ~= TAG_FREE and res_type ~= TAG_OMNI
           and index_offs > 0 and index_offs < fsize then

            -- Read INDX block at index_offs
            local indx_hdr = file_read(f, index_offs, INDX_HEADER_SIZE + 2)
            if indx_hdr and #indx_hdr >= INDX_HEADER_SIZE then
                local count1 = u16le(indx_hdr, 17)  -- offset 16 in block
                local count2 = u16le(indx_hdr, 19)  -- offset 18
                local count = math.max(count1, count2)

                if count > 0 and count < 10000 then
                    local entries_data = file_read(f, index_offs + INDX_HEADER_SIZE, count * 8)
                    if entries_data and #entries_data >= count * 8 then
                        local slots = {}
                        for j = 0, count - 1 do
                            local sp = j * 8 + 1
                            local offs = u32le(entries_data, sp)
                            local sz = u32le(entries_data, sp + 4)
                            if offs > 0 and sz > RES_HEADER_SIZE then
                                slots[#slots + 1] = {
                                    index = j + 1,   -- 1-based
                                    offset = offs + RES_HEADER_SIZE,
                                    size = sz - RES_HEADER_SIZE,
                                }
                            end
                        end
                        if #slots > 0 then
                            resource_types[#resource_types + 1] = {
                                tag = res_type,
                                name = TAG_NAMES[res_type] or string.format("Type 0x%08X", res_type),
                                slots = slots,
                            }
                        end
                    end
                end
            end
        end
    end

    file_close(f)
    return resource_types
end

-- ── Picture decompression ────────────────────────────────────────

-- 4×4 block offsets into a 320-wide line buffer (4 rows × 320 cols)
local BLOCK_OFFSETS = {
    0, 1, 2, 3,
    LINE_BUF_PITCH, LINE_BUF_PITCH + 1, LINE_BUF_PITCH + 2, LINE_BUF_PITCH + 3,
    LINE_BUF_PITCH * 2, LINE_BUF_PITCH * 2 + 1, LINE_BUF_PITCH * 2 + 2, LINE_BUF_PITCH * 2 + 3,
    LINE_BUF_PITCH * 3, LINE_BUF_PITCH * 3 + 1, LINE_BUF_PITCH * 3 + 2, LINE_BUF_PITCH * 3 + 3,
}

local function decompress_image(data, width, height, cmd_offs, pixel_offs, mask_offs,
                                 line_size, pixel_flags, mask_flags)
    -- Data positions are 0-based offsets into the resource data, convert to 1-based
    local cmd_pos = cmd_offs + 1
    local pixel_nibble_mode = (pixel_flags % 4 >= 2)  -- bit 1
    local mask_nibble_mode = (mask_flags % 4 >= 2)

    -- Pixel reader state
    local pix_pos = pixel_offs + 1
    local pix_nibble_switch = false

    local function read_pixel_pix()
        if pixel_nibble_mode then
            local val
            if pix_nibble_switch then
                val = math.floor(u8(data, pix_pos) / 16) % 16
                pix_pos = pix_pos + 1
            else
                val = u8(data, pix_pos) % 16
            end
            pix_nibble_switch = not pix_nibble_switch
            return val
        else
            local val = u8(data, pix_pos)
            pix_pos = pix_pos + 1
            return val
        end
    end

    -- Mask reader state
    local mask_pos = mask_offs + 1
    local mask_nibble_switch = false

    local function read_pixel_mask()
        if mask_nibble_mode then
            local val
            if mask_nibble_switch then
                val = math.floor(u8(data, mask_pos) / 16) % 16
                mask_pos = mask_pos + 1
            else
                val = u8(data, mask_pos) % 16
            end
            mask_nibble_switch = not mask_nibble_switch
            return val
        else
            local val = u8(data, mask_pos)
            mask_pos = mask_pos + 1
            return val
        end
    end

    local function read_mask_u16()
        local val = u16le(data, mask_pos)
        mask_pos = mask_pos + 2
        return val
    end

    local function read_mask_u32()
        local val = u32le(data, mask_pos)
        mask_pos = mask_pos + 4
        return val
    end

    local function reset_mask_nibble()
        mask_nibble_switch = false
    end

    -- Output pixel buffer
    local pixels = {}
    for i = 1, width * height do pixels[i] = 0 end

    -- Line buffer: 4 rows × LINE_BUF_PITCH columns
    local line_buf = {}
    for i = 0, LINE_BUF_PITCH * 4 - 1 do line_buf[i] = 0 end

    -- Calculate last word offset and count
    local bit_buf_last_ofs = (math.floor((line_size + 1) / 2) * 2) - 2
    local bit_buf_last_count = math.floor((width + 3) / 4) % 8
    if bit_buf_last_count == 0 then bit_buf_last_count = 8 end

    local remaining_h = height
    local dest_row = 0

    while remaining_h > 0 do
        -- Clear line buffer
        for i = 0, LINE_BUF_PITCH * 4 - 1 do line_buf[i] = 0 end

        -- Read command bytes for this strip
        local bit_buf = {}
        for i = 0, line_size - 1 do
            if cmd_pos <= #data then
                bit_buf[i] = u8(data, cmd_pos)
                cmd_pos = cmd_pos + 1
            else
                bit_buf[i] = 0
            end
        end

        local draw_dest_ofs = 0

        -- Process command words (2 bytes each)
        local bit_buf_ofs = 0
        while bit_buf_ofs < line_size do
            local bits = (bit_buf[bit_buf_ofs] or 0) + (bit_buf[bit_buf_ofs + 1] or 0) * 256

            local bit_count
            if bit_buf_ofs == bit_buf_last_ofs then
                bit_count = bit_buf_last_count
            else
                bit_count = 8
            end

            for cur_cmd = 0, bit_count - 1 do
                local cmd = bits % 4
                bits = math.floor(bits / 4)

                if cmd == 0 then
                    -- SOLID FILL: 1 color for all 16 pixels
                    local pixel = read_pixel_pix()
                    for i = 1, 16 do
                        line_buf[draw_dest_ofs + BLOCK_OFFSETS[i]] = pixel
                    end

                elseif cmd == 1 then
                    -- 2-COLOR: 1-bit mask
                    local p0 = read_pixel_pix()
                    local p1 = read_pixel_pix()
                    local mask = read_mask_u16()
                    for i = 1, 16 do
                        if mask % 2 == 0 then
                            line_buf[draw_dest_ofs + BLOCK_OFFSETS[i]] = p0
                        else
                            line_buf[draw_dest_ofs + BLOCK_OFFSETS[i]] = p1
                        end
                        mask = math.floor(mask / 2)
                    end

                elseif cmd == 2 then
                    -- 4-COLOR: 2-bit mask
                    local p = {}
                    p[0] = read_pixel_pix()
                    p[1] = read_pixel_pix()
                    p[2] = read_pixel_pix()
                    p[3] = read_pixel_pix()
                    local mask = read_mask_u32()
                    for i = 1, 16 do
                        local idx = mask % 4
                        line_buf[draw_dest_ofs + BLOCK_OFFSETS[i]] = p[idx]
                        mask = math.floor(mask / 4)
                    end

                elseif cmd == 3 then
                    -- RAW PIXELS from mask reader
                    reset_mask_nibble()
                    for i = 1, 16 do
                        line_buf[draw_dest_ofs + BLOCK_OFFSETS[i]] = read_pixel_mask()
                    end
                end

                draw_dest_ofs = draw_dest_ofs + 4
            end

            bit_buf_ofs = bit_buf_ofs + 2
        end

        -- Copy 4 rows from line buffer to output
        for y = 0, 3 do
            if remaining_h <= 0 then break end
            for x = 0, width - 1 do
                pixels[dest_row * width + x + 1] = line_buf[y * LINE_BUF_PITCH + x]
            end
            dest_row = dest_row + 1
            remaining_h = remaining_h - 1
        end
    end

    return pixels
end

-- ── Palette helpers ─────────────────────────────────────────────

-- Extract the embedded palette from a FLEX resource at the given archive offset.
-- Returns (palette_table_768, color_count) or nil.
local function extract_flex_palette(game_path, off, sz)
    local prj_path = find_file(game_path, "LGOP2.PRJ")
    if not prj_path then return nil end
    local f = file_open(prj_path)
    if not f then return nil end
    local raw = file_read(f, off, math.min(sz, 18 + 256 * 3 + 4))
    file_close(f)
    if not raw or #raw < 7 then return nil end
    if raw:byte(1) == 0 then return nil end  -- no palette flag
    local cmd_offs = raw:byte(5) + raw:byte(6) * 256
    if cmd_offs <= 18 then return nil end
    local pal_count = math.min(math.floor((cmd_offs - 18) / 3), 256)
    if pal_count < 1 then return nil end
    local palette = {}
    for i = 0, pal_count - 1 do
        local pos = 19 + i * 3
        if pos + 2 <= #raw then
            palette[i * 3 + 1] = raw:byte(pos)
            palette[i * 3 + 2] = raw:byte(pos + 1)
            palette[i * 3 + 3] = raw:byte(pos + 2)
        else
            palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
        end
    end
    for i = pal_count, 255 do
        palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
    end
    return palette, pal_count
end

-- ── Load a FLEX picture resource ─────────────────────────────────

local function load_picture(game_path, res_offset, res_size, override_palette)
    local prj_path = find_file(game_path, "LGOP2.PRJ")
    if not prj_path then return nil end

    local f = file_open(prj_path)
    if not f then return nil end

    local raw = file_read(f, res_offset, res_size)
    file_close(f)
    if not raw or #raw < 18 then return nil end

    -- Check if chunked format (starts with "Flex") — not used by LGOP2
    if #raw >= 4 and u8(raw, 1) == 0x46 and u8(raw, 2) == 0x6C
       and u8(raw, 3) == 0x65 and u8(raw, 4) == 0x78 then
        return { type = "text", text = "Flex chunked format (not supported)" }
    end

    -- Parse 18-byte header
    local has_palette  = u8(raw, 1)
    local cmd_flags    = u8(raw, 2)
    local pixel_flags  = u8(raw, 3)
    local mask_flags   = u8(raw, 4)
    local cmd_offs     = u16le(raw, 5)
    local pixel_offs   = u16le(raw, 7)
    local mask_offs    = u16le(raw, 9)
    local line_size    = u16le(raw, 11)
    -- skip 2 bytes at offset 12
    local width        = u16le(raw, 15)
    local height       = u16le(raw, 17)

    if width < 1 or width > 640 or height < 1 or height > 480 then
        return { type = "text", text = string.format("Invalid picture dimensions: %dx%d", width, height) }
    end

    -- Extract palette
    local palette = {}
    local pal_source
    if override_palette then
        palette = override_palette
        pal_source = "override"
    elseif has_palette ~= 0 and cmd_offs > 18 then
        local pal_count = math.floor((cmd_offs - 18) / 3)
        if pal_count > 256 then pal_count = 256 end
        for i = 0, pal_count - 1 do
            local pos = 19 + i * 3
            if pos + 2 <= #raw then
                palette[i * 3 + 1] = u8(raw, pos)
                palette[i * 3 + 2] = u8(raw, pos + 1)
                palette[i * 3 + 3] = u8(raw, pos + 2)
            end
        end
        -- Fill remaining with black
        for i = pal_count, 255 do
            palette[i * 3 + 1] = 0
            palette[i * 3 + 2] = 0
            palette[i * 3 + 3] = 0
        end
        pal_source = "embedded"
    else
        -- No embedded palette: use the game's shared palette if we have it,
        -- otherwise fall back to grayscale so at least pixel structure is visible.
        ensure_game_palette(game_path)
        if _game_palette then
            palette = _game_palette
            pal_source = "game"
        else
            for i = 0, 255 do
                palette[i * 3 + 1] = i
                palette[i * 3 + 2] = i
                palette[i * 3 + 3] = i
            end
            pal_source = "grayscale"
        end
    end

    -- Decompress image
    local pixels = decompress_image(raw, width, height,
                                     cmd_offs, pixel_offs, mask_offs,
                                     line_size, pixel_flags, mask_flags)
    if not pixels then
        return { type = "text", text = "Failed to decompress picture" }
    end

    local img = image_create_indexed(width, height, pixels, palette)
    return {
        type = "image",
        image = img,
        description = string.format("Picture %dx%d, %s palette (%d bytes)",
            width, height, pal_source, res_size)
    }
end

-- ── Sound decompression ──────────────────────────────────────────

local function clip16(val)
    if val < -127 then return -127 end
    if val > 127 then return 127 end
    return val
end

local function decompress_sound(data, chunk_size, chunk_count)
    local out = {}
    local n = 0
    local prev_sample = 0
    local sound_buffer = {}
    for i = 0, 1024 do sound_buffer[i] = 128 end

    local pos = 1

    -- ADPCM mode lookup: {byte_count, bit_count, bit_mask, bit_shift}
    local mode_values = {
        {2, 8, 1, 1},    -- type 2
        {4, 4, 3, 2},    -- type 3
        {16, 2, 15, 4},  -- type 4
    }

    for chunk = 0, chunk_count - 1 do
        if pos > #data then break end

        local control = u8(data, pos)
        pos = pos + 1
        local delta_type = math.floor(control / 64)
        local comp_type = control % 16

        local work_chunk_size = chunk_size
        if delta_type == 1 then
            work_chunk_size = math.floor(chunk_size / 2)
        elseif delta_type == 2 then
            work_chunk_size = math.floor(chunk_size / 4)
        end

        local work_sample = prev_sample

        if comp_type == 0 then
            -- Silence
            for i = 0, work_chunk_size - 1 do
                sound_buffer[i] = 128
            end
            work_sample = 0

        elseif comp_type == 1 then
            -- Repeat previous chunk (no data read)

        elseif comp_type >= 2 and comp_type <= 4 then
            -- ADPCM modes
            local mode = mode_values[comp_type - 1]
            local byte_count = mode[1]
            local bit_count = mode[2]
            local bit_mask = mode[3]
            local bit_shift = mode[4]

            -- Read reference samples
            local ref = {}
            for i = 0, byte_count - 1 do
                if pos <= #data then
                    ref[i] = u8(data, pos) * 2 - 128
                    pos = pos + 1
                else
                    ref[i] = 0
                end
            end

            local ofs = 0
            while ofs < work_chunk_size do
                local val = 0
                if pos <= #data then
                    val = u8(data, pos)
                    pos = pos + 1
                end
                for bi = 0, bit_count - 1 do
                    local idx = val % (bit_mask + 1)
                    work_sample = clip16(work_sample + (ref[idx] or 0))
                    val = math.floor(val / (2 ^ bit_shift))
                    sound_buffer[ofs] = work_sample + 128
                    ofs = ofs + 1
                end
            end

        elseif comp_type == 5 then
            -- Raw PCM
            for i = 0, work_chunk_size - 1 do
                if pos <= #data then
                    sound_buffer[i] = u8(data, pos)
                    pos = pos + 1
                else
                    sound_buffer[i] = 128
                end
            end
            work_sample = sound_buffer[work_chunk_size - 1] - 128

        else
            -- Unknown type, stop
            break
        end

        -- Delta interpolation (upsample)
        if delta_type > 0 then
            sound_buffer[work_chunk_size] = sound_buffer[work_chunk_size - 1]

            local delta_buf = {}
            if delta_type == 1 then
                -- 2× interpolation
                for i = 0, chunk_size - 1, 2 do
                    local l = math.floor(i / 2)
                    delta_buf[i] = sound_buffer[l]
                    delta_buf[i + 1] = math.floor((sound_buffer[l] + sound_buffer[l + 1]) / 2)
                end
            elseif delta_type == 2 then
                -- 4× interpolation
                for i = 0, chunk_size - 1, 4 do
                    local l = math.floor(i / 4)
                    delta_buf[i] = sound_buffer[l]
                    delta_buf[i + 2] = math.floor((sound_buffer[l] + sound_buffer[l + 1]) / 2)
                    delta_buf[i + 1] = math.floor((delta_buf[i + 2] + sound_buffer[l]) / 2)
                    delta_buf[i + 3] = math.floor((delta_buf[i + 2] + sound_buffer[l + 1]) / 2)
                end
            end
            for i = 0, chunk_size - 1 do
                sound_buffer[i] = delta_buf[i] or 128
            end
        end

        prev_sample = work_sample

        -- Copy to output
        for i = 0, chunk_size - 1 do
            n = n + 1
            out[n] = sound_buffer[i]
        end
    end

    return out, n
end

-- ── Load a SNDS sound resource ───────────────────────────────────

local function load_sound(game_path, res_offset, res_size)
    local prj_path = find_file(game_path, "LGOP2.PRJ")
    if not prj_path then return nil end

    local f = file_open(prj_path)
    if not f then return nil end

    local raw = file_read(f, res_offset, res_size)
    file_close(f)
    if not raw or #raw < 15 then return nil end

    -- Sound header
    local chunk_count = u16le(raw, 9)    -- offset 8 (0-based)
    local chunk_size = u16le(raw, 13)    -- offset 12 (0-based)

    if chunk_count == 0 or chunk_size == 0 then
        return { type = "text", text = "Empty sound resource" }
    end

    -- Decompress from offset 14 (0-based) = pos 15 (1-based)
    local comp_data = raw:sub(15)
    local pcm_samples, pcm_count = decompress_sound(comp_data, chunk_size, chunk_count)

    if not pcm_samples or pcm_count == 0 then
        return { type = "text", text = "Failed to decompress sound" }
    end

    -- Convert to binary string for sound_create_pcm
    local bytes = {}
    for i = 1, pcm_count do
        bytes[i] = string.char(pcm_samples[i] or 128)
    end
    local pcm_data = table.concat(bytes)

    local snd = sound_create_pcm(SOUND_SAMPLE_RATE, 8, 1, false, pcm_data)
    local duration_ms = math.floor(pcm_count * 1000 / SOUND_SAMPLE_RATE)

    return {
        type = "sound",
        sound = snd,
        description = string.format(
            "Sound - %d samples, %d ms @ %d Hz, ADPCM (%d chunks × %d)",
            pcm_count, duration_ms, SOUND_SAMPLE_RATE, chunk_count, chunk_size)
    }
end

-- ── Load an XMIDI/MIDI music resource ────────────────────────────

local function load_midi(game_path, res_offset, res_size)
    local prj_path = find_file(game_path, "LGOP2.PRJ")
    if not prj_path then return nil end

    local f = file_open(prj_path)
    if not f then return nil end

    local raw = file_read(f, res_offset, res_size)
    file_close(f)
    if not raw then
        return { type = "text", text = "Failed to read music data" }
    end

    -- midi_create_auto() sniffs MThd/CTMF/FORM(XDIR) magic and converts as needed,
    -- letting the system's own MIDI synth/instruments handle playback.
    local midi = midi_create_auto(raw)
    if not midi then
        return { type = "text", text = string.format("Could not decode music resource (%d bytes)", res_size) }
    end

    return {
        type = "midi",
        midi = midi,
        description = string.format("Music (%d bytes)", res_size)
    }
end

-- ── Load a MENU resource ─────────────────────────────────────────

local function load_menu(game_path, res_offset, res_size)
    local prj_path = find_file(game_path, "LGOP2.PRJ")
    if not prj_path then return nil end

    local f = file_open(prj_path)
    if not f then return nil end

    local raw = file_read(f, res_offset, res_size)
    file_close(f)
    if not raw or #raw < 6 then return nil end

    -- MENU format: 4 bytes "MENU", uint16 count, then uint16 offsets
    local count = u16le(raw, 5)
    local strings = {}
    for i = 0, count - 1 do
        local str_off_pos = 7 + i * 2
        if str_off_pos + 1 > #raw then break end
        local str_off = u16le(raw, str_off_pos)
        if str_off + 1 <= #raw then
            -- Read null-terminated string
            local s = {}
            local p = str_off + 1
            while p <= #raw and raw:byte(p) ~= 0 do
                s[#s + 1] = string.char(raw:byte(p))
                p = p + 1
            end
            strings[#strings + 1] = table.concat(s)
        end
    end

    return {
        type = "text",
        text = table.concat(strings, "\n"),
        description = string.format("Menu (%d strings)", #strings)
    }
end

-- ── Detection ────────────────────────────────────────────────────

function engine.detect(game_path)
    local has_dat = find_file(game_path, "LGOP2.DAT") ~= nil
    local has_prj = find_file(game_path, "LGOP2.PRJ") ~= nil
    return has_dat and has_prj
end

-- ── Resource tree ────────────────────────────────────────────────

function engine.get_resources(game_path)
    local types = parse_prj(game_path)
    if not types then return {} end

    _resource_types = types   -- cache for lazy palette scan
    _game_palette   = nil     -- reset on new game folder load

    local resources = {}

    for _, rt in ipairs(types) do
        local children = {}
        for _, slot in ipairs(rt.slots) do
            children[#children + 1] = {
                id   = string.format("res_%08X_%d_%d_%d",
                    rt.tag, slot.index, slot.offset, slot.size),
                name = string.format("%s %d", TAG_NAMES[rt.tag] or "Resource", slot.index),
                type = TAG_ICONS[rt.tag] or "data",
            }
        end

        resources[#resources + 1] = {
            id       = string.format("type_%08X", rt.tag),
            name     = string.format("%s (%d)", rt.name, #children),
            type     = "category",
            children = children,
        }
    end

    -- Scan FLEX slots for embedded palettes and expose them as selectable palette nodes
    local flex_type = nil
    for _, rt in ipairs(types) do
        if rt.tag == TAG_FLEX then flex_type = rt; break end
    end

    if flex_type and #flex_type.slots > 0 then
        local prj_path = find_file(game_path, "LGOP2.PRJ")
        if prj_path then
            local f = file_open(prj_path)
            if f then
                local pal_slots = {}
                for _, slot in ipairs(flex_type.slots) do
                    local hdr6 = file_read(f, slot.offset, 6)
                    if hdr6 and #hdr6 >= 6 and hdr6:byte(1) ~= 0 then
                        local cmd_offs = hdr6:byte(5) + hdr6:byte(6) * 256
                        if cmd_offs > 18 then
                            pal_slots[#pal_slots + 1] = {
                                index  = slot.index,
                                offset = slot.offset,
                                size   = slot.size,
                            }
                        end
                    end
                end
                file_close(f)

                if #pal_slots > 0 then
                    local pal_cat = {
                        id       = "lgop2_palettes",
                        name     = string.format("Palettes (%d)", #pal_slots),
                        type     = "category",
                        children = {}
                    }
                    for _, slot in ipairs(pal_slots) do
                        pal_cat.children[#pal_cat.children + 1] = {
                            id   = string.format("palflex_%d_%d", slot.offset, slot.size),
                            name = string.format("Palette (Picture %d)", slot.index),
                            type = "palette"
                        }
                    end
                    resources[#resources + 1] = pal_cat
                end
            end
        end
    end

    return resources
end

-- ── Resource dispatcher ──────────────────────────────────────────

function engine.load_resource(game_path, resource_id, palette_id)
    -- Palette swatch resource
    local pal_off_s, pal_sz_s = resource_id:match("^palflex_(%d+)_(%d+)$")
    if pal_off_s then
        local palette, pal_count = extract_flex_palette(game_path, tonumber(pal_off_s), tonumber(pal_sz_s))
        if palette and pal_count then
            -- Render a 256×16 color swatch
            local sw, sh = 256, 16
            local pixels = {}
            for y = 0, sh - 1 do
                for x = 0, sw - 1 do
                    pixels[y * sw + x + 1] = math.floor(x * pal_count / sw)
                end
            end
            local img = image_create_indexed(sw, sh, pixels, palette)
            return { type = "image", image = img,
                     description = string.format("Palette (%d colors)", pal_count) }
        end
        return { type = "text", text = "Palette not found: " .. resource_id }
    end

    -- Resolve palette override when palette_id is supplied
    local override_palette = nil
    if palette_id and palette_id ~= "" then
        local poff_s, psz_s = palette_id:match("^palflex_(%d+)_(%d+)$")
        if poff_s then
            override_palette = extract_flex_palette(game_path, tonumber(poff_s), tonumber(psz_s))
        end
    end

    local tag_s, idx_s, off_s, sz_s = resource_id:match("^res_(%x+)_(%d+)_(%d+)_(%d+)$")
    if not tag_s then
        return { type = "text", text = "Unknown resource: " .. resource_id }
    end

    local tag = tonumber(tag_s, 16)
    local res_offset = tonumber(off_s)
    local res_size = tonumber(sz_s)

    if tag == TAG_FLEX then
        return load_picture(game_path, res_offset, res_size, override_palette)
    elseif tag == TAG_SNDS then
        return load_sound(game_path, res_offset, res_size)
    elseif tag == TAG_MENU then
        return load_menu(game_path, res_offset, res_size)
    elseif tag == TAG_XMID or tag == TAG_MIDI then
        return load_midi(game_path, res_offset, res_size)
    else
        -- Generic: show hex info
        return {
            type = "text",
            text = string.format("%s resource #%s at offset %d (%d bytes)",
                TAG_NAMES[tag] or "Unknown", idx_s, res_offset, res_size)
        }
    end
end

return engine

-- ============================================================================
-- Adventure Explorer - Engine Script: SCUMM V2 (Maniac Mansion, Zak McKracken)
-- ============================================================================
-- LucasArts 1988-1989. Each room stored in its own NN.LFL file.
-- XOR 0xFF encryption. V2 "old bundle" block format.
-- EGA 16-color graphics, 320x200 (or 640×128 for scrolling rooms).
-- ============================================================================

local engine = {}
engine.name        = "SCUMM V2"
engine.id          = "scummv2"
engine.description = "SCUMM V2 (Maniac Mansion, Zak McKracken, 1988-1989)"
engine.version     = "1.0"

local band   = bit32.band
local bor    = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local bxor   = bit32.bxor

-- ── Binary helpers ──────────────────────────────────────────────

local function u8(data, pos)
    return data:byte(pos)
end

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function xor_decrypt(data, key)
    if key == 0 then return data end
    local bytes = {}
    for i = 1, #data do
        bytes[i] = string.char(bxor(data:byte(i), key))
    end
    return table.concat(bytes)
end

-- ── EGA 16-color standard palette ──────────────────────────────
-- Fixed IBM EGA palette: 16 colors, 8-bit RGB values

local EGA_PALETTE = {
    -- R    G    B
       0,   0,   0,    -- 0  Black
       0,   0, 170,    -- 1  Blue
       0, 170,   0,    -- 2  Green
       0, 170, 170,    -- 3  Cyan
     170,   0,   0,    -- 4  Red
     170,   0, 170,    -- 5  Magenta
     170,  85,   0,    -- 6  Brown
     170, 170, 170,    -- 7  Light Gray
      85,  85,  85,    -- 8  Dark Gray
      85,  85, 255,    -- 9  Bright Blue
      85, 255,  85,    -- 10 Bright Green
      85, 255, 255,    -- 11 Bright Cyan
     255,  85,  85,    -- 12 Bright Red
     255,  85, 255,    -- 13 Bright Magenta
     255, 255,  85,    -- 14 Yellow
     255, 255, 255,    -- 15 White
}

-- Build a 256-entry palette table (entries 0-15 are EGA, rest black)
local function make_ega_palette()
    local pal = {}
    for i = 0, 255 do
        pal[i * 3 + 1] = 0
        pal[i * 3 + 2] = 0
        pal[i * 3 + 3] = 0
    end
    for i = 0, 15 do
        pal[i * 3 + 1] = EGA_PALETTE[i * 3 + 1]
        pal[i * 3 + 2] = EGA_PALETTE[i * 3 + 2]
        pal[i * 3 + 3] = EGA_PALETTE[i * 3 + 3]
    end
    return pal
end

-- ── V2 Room Header Parsing ──────────────────────────────────────

-- Parse a decrypted .LFL room file. Returns room info or nil.
local function parse_v2_room(data)
    if #data < 24 then return nil end

    -- Bytes +0: u16le total block size
    -- Bytes +2: u16le block tag (old-bundle format)
    -- Bytes +4: u16le room width
    -- Bytes +6: u16le room height
    -- Bytes +8: u16le (unknown)
    -- Bytes +10 (0x0A): u16le _IM00_offs (image sub-block offset from start)

    local total_size = u16le(data, 1)
    local tag        = u16le(data, 3)
    local width      = u16le(data, 5)
    local height     = u16le(data, 7)
    local im00_offs  = u16le(data, 11)  -- offset +10 = 0x0A

    -- Basic sanity checks
    if width == 0 or height == 0 then return nil end
    if width > 2048 or height > 512 then return nil end
    if im00_offs == 0 or im00_offs + 4 > #data then return nil end

    return {
        width    = width,
        height   = height,
        im00_offs = im00_offs,
        total_size = total_size,
        tag      = tag
    }
end

-- ── V2 EGA Bitmap Decoder ───────────────────────────────────────
-- V2 bitmap: column-by-column RLE encoding (matches ScummVM GdiV2::prepareDrawBitmap)
-- Each byte: if bit7 set → run = (byte & 0x7F), dither=true
--            if bit7 clear → run = (byte >> 4), dither=false
-- Color is always (byte & 0x0F).  If run == 0 → next byte is the full count.
-- Dither: when true, pixel comes from the dither table (previous column's value
-- at the same row); when false, the current color is written to the table.
-- The run counter is persistent across columns (NOT reset per column).

local function decode_v2_bitmap(data, bm_start, width, height)
    local pixels = {}
    local total = width * height
    for i = 1, total do pixels[i] = 0 end

    -- Dither table: one entry per row (max height 128 in original engine)
    local dither_table = {}
    for i = 0, 127 do dither_table[i] = 0 end

    local pos = bm_start
    local run = 1          -- starts at 1 so first decrement triggers a read
    local color = 0
    local dither = false

    for col = 0, width - 1 do
        local ptr_dither = 0               -- reset dither pointer each column
        for row = 0, height - 1 do
            run = run - 1
            if run == 0 then
                if pos > #data then break end
                local b = u8(data, pos); pos = pos + 1

                if band(b, 0x80) ~= 0 then
                    run = band(b, 0x7F)    -- high-bit set → dither mode
                    dither = true
                else
                    run = rshift(b, 4)     -- normal mode
                    dither = false
                end

                color = band(b, 0x0F)

                if run == 0 then
                    if pos > #data then break end
                    run = u8(data, pos); pos = pos + 1
                end
            end

            if not dither then
                dither_table[ptr_dither] = color
            end

            local pixel_color = dither_table[ptr_dither]
            ptr_dither = ptr_dither + 1

            local dst = row * width + col + 1
            if dst <= total then
                pixels[dst] = pixel_color
            end
        end
    end

    return pixels
end

-- ── Build palette swatch ────────────────────────────────────────

local function build_palette_swatch(palette)
    local CELL = 32
    local COLS = 8
    local ROWS = 2
    local W = COLS * CELL
    local H = ROWS * CELL
    local rgb = {}
    local n = 0

    for row = 0, H - 1 do
        local pal_row = math.floor(row / CELL)
        for col = 0, W - 1 do
            local pal_idx = pal_row * COLS + math.floor(col / CELL)
            local idx = pal_idx * 3
            n = n + 1; rgb[n] = palette[idx + 1] or 0
            n = n + 1; rgb[n] = palette[idx + 2] or 0
            n = n + 1; rgb[n] = palette[idx + 3] or 0
        end
    end

    return image_create_rgb(W, H, rgb)
end

-- ── Game discovery ──────────────────────────────────────────────

-- Check for SCUMM V2 LFL pattern: 00.LFL + 01.LFL must exist,
-- and game must NOT have .000/.001 files (those are V5).
local function is_v2_lfl(game_path)
    -- Must have 00.LFL and 01.LFL (index + first room)
    if not (file_exists(game_path .. "/00.LFL") or file_exists(game_path .. "/00.lfl")) then
        return false
    end
    if not (file_exists(game_path .. "/01.LFL") or file_exists(game_path .. "/01.lfl")) then
        return false
    end
    return true
end

-- Enumerate all room LFL files (01.LFL through NN.LFL)
-- Returns list of {room_id, path}
local function find_room_lfls(game_path)
    local rooms = {}
    local files = list_files(game_path)
    if not files then return rooms end

    for _, fname in ipairs(files) do
        local num_str = fname:match("^(%d+)%.LFL$") or fname:match("^(%d+)%.lfl$")
        if num_str then
            local n = tonumber(num_str)
            if n and n >= 1 then  -- skip 00.LFL (index)
                rooms[#rooms + 1] = {
                    id   = n,
                    path = game_path .. "/" .. fname
                }
            end
        end
    end

    -- Sort by room ID
    table.sort(rooms, function(a, b) return a.id < b.id end)
    return rooms
end

-- ── Detection ───────────────────────────────────────────────────

function engine.detect(game_path)
    return is_v2_lfl(game_path)
end

-- ── Resource tree ───────────────────────────────────────────────

function engine.get_resources(game_path)
    if not is_v2_lfl(game_path) then return {} end

    local room_lfls = find_room_lfls(game_path)
    if #room_lfls == 0 then return {} end

    local rooms_cat = {
        id = "rooms", name = string.format("Rooms (%d)", #room_lfls),
        type = "category", children = {}
    }

    for _, r in ipairs(room_lfls) do
        -- Quick parse to get dimensions (read only first 20 bytes)
        local f = file_open(r.path)
        if f then
            local raw = file_read(f, 0, 20)
            file_close(f)
            local info_str = ""
            if raw then
                local dec = xor_decrypt(raw, 0xFF)
                local w = u16le(dec, 5)
                local h = u16le(dec, 7)
                if w > 0 and w <= 2048 and h > 0 and h <= 512 then
                    info_str = string.format(" (%dx%d)", w, h)
                end
            end

            rooms_cat.children[#rooms_cat.children + 1] = {
                id = "room_" .. r.id,
                name = string.format("Room %d%s", r.id, info_str),
                type = "image"
            }
        end
    end

    if #rooms_cat.children == 0 then return {} end

    return { rooms_cat }
end

-- ── Resource loading ────────────────────────────────────────────

function engine.load_resource(game_path, resource_id, palette_id)
    local room_id_str = resource_id:match("^room_(%d+)$")
    if not room_id_str then
        log_warn("Unknown SCUMM V2 resource ID: " .. resource_id)
        return nil
    end

    local room_id = tonumber(room_id_str)

    -- Find the LFL file for this room
    local lfl_path = nil
    for _, suffix in ipairs({ ".LFL", ".lfl" }) do
        local candidate = string.format("%s/%02d%s", game_path, room_id, suffix)
        if file_exists(candidate) then
            lfl_path = candidate; break
        end
    end

    if not lfl_path then
        log_warn("No LFL file found for room " .. room_id)
        return nil
    end

    -- Read and decrypt the room file
    local f = file_open(lfl_path)
    if not f then
        log_warn("Failed to open " .. lfl_path)
        return nil
    end
    local sz = file_size(f)
    local raw = file_read(f, 0, sz)
    file_close(f)
    if not raw then return nil end

    local data = xor_decrypt(raw, 0xFF)

    -- Parse room header
    local room = parse_v2_room(data)
    if not room then
        log_warn(string.format("Room %d: invalid room block (width=%d, height=%d)",
            room_id,
            u16le(data, 5),
            u16le(data, 7)))
        return {
            type = "text",
            text = string.format("Room %d: invalid or empty room block (size=%d)", room_id, #data)
        }
    end

    -- Image data starts directly at im00_offs (V2 has no sub-block header)
    local bm_start = room.im00_offs + 1  -- +1 for Lua 1-based indexing

    if bm_start > #data then
        return {
            type = "text",
            text = string.format("Room %d (%dx%d): image block out of range (im00_offs=%d, data_size=%d)",
                room_id, room.width, room.height, room.im00_offs, #data)
        }
    end

    -- Decode bitmap
    local pixels = decode_v2_bitmap(data, bm_start, room.width, room.height)

    -- Build palette (EGA 16-color)
    local palette = make_ega_palette()

    local img = image_create_indexed(room.width, room.height, pixels, palette)

    return {
        type = "image",
        image = img,
        width = room.width,
        height = room.height,
        description = string.format("Room %d — %dx%d, EGA 16-color, SCUMM V2",
            room_id, room.width, room.height)
    }
end

return engine

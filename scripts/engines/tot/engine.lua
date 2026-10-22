-- ============================================================================
-- Adventure Explorer - Engine Script: Trick or Treat (TOT engine, 1997, DOS)
-- ============================================================================
-- Reads flat DAT files: BITMAPS.DAT, PANTALLA.DAT, PALETAS.DAT, OBJETOS.DAT,
-- CONVERSA.TXT
--
-- Image format: uint16le width-1, uint16le height-1, then raw 8-bit pixels
-- Palette: 768 bytes (256 x RGB), 6-bit VGA values (x4 for 8-bit)
-- Room record: 10856 bytes per room in PANTALLA.DAT (8 save variants; use 1st)
-- Object record: 279 bytes per object in OBJETOS.DAT
--
-- PANTALLA.DAT room record offsets (from ScummVM engines/tot/resources.cpp):
--   +0:    room code (u16le)
--   +2:    roomImagePointer (u32le) -- byte offset into BITMAPS.DAT
--   +6:    roomImageSize (u16le)
--   +9052: palettePointer (u16le)   -- DIRECT byte offset into PALETAS.DAT
-- ============================================================================

local engine = {}

engine.name        = "Trick or Treat"
engine.id          = "tot"
engine.description = "Trick or Treat (1997, DOS point-and-click adventure)"
engine.version     = "1.1"

-- ── Binary helpers ───────────────────────────────────────────────

local function u8(data, pos)
    return data:byte(pos)
end

local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end

-- Read a Pascal string: first byte = length, then chars
local function pascal_string(data, pos, max_len)
    local len = u8(data, pos)
    if len > max_len then len = max_len end
    local chars = {}
    for i = 1, len do
        local b = data:byte(pos + i)
        if b and b >= 0x20 and b < 0x80 then
            chars[#chars + 1] = string.char(b)
        end
    end
    return table.concat(chars)
end

-- ── Constants ────────────────────────────────────────────────────

local ROOM_RECORD_SIZE  = 10856   -- bytes per room in PANTALLA.DAT
local ROOM_VARIANTS     = 8       -- save-game variants per room (use 1st)
local OBJECT_RECORD_SIZE = 279    -- bytes per object in OBJETOS.DAT
local PALETTE_SIZE      = 768     -- 256 colors x 3 bytes

-- ── Detection ────────────────────────────────────────────────────

function engine.detect(game_path)
    return file_exists(game_path .. "/BITMAPS.DAT")
       and file_exists(game_path .. "/PANTALLA.DAT")
       and file_exists(game_path .. "/PALETAS.DAT")
       and (file_exists(game_path .. "/TOT.EXE")
            or file_exists(game_path .. "/ANIMA.EXE")
            or file_exists(game_path .. "/OBJETOS.DAT"))
end

-- ── Resource tree ─────────────────────────────────────────────────
-- Room-centric: each room gets Background + Palette children.
-- Objects and Conversation are separate top-level categories.

function engine.get_resources(game_path)
    local resources = {}

    -- Count rooms
    local f_pant = file_open(game_path .. "/PANTALLA.DAT")
    local total_file_size = file_size(f_pant)
    local total_rooms = math.floor(total_file_size / ROOM_RECORD_SIZE)

    -- Count objects
    local num_objects = 0
    if file_exists(game_path .. "/OBJETOS.DAT") then
        local fo = file_open(game_path .. "/OBJETOS.DAT")
        num_objects = math.floor(file_size(fo) / OBJECT_RECORD_SIZE)
        file_close(fo)
    end

    log_info(string.format("TOT: %d rooms, %d objects", total_rooms, num_objects))

    -- ── Rooms (room-centric tree) ──────────────────────────────────
    local rooms_cat = {
        id       = "rooms",
        name     = string.format("Rooms (%d)", total_rooms),
        type     = "category",
        children = {}
    }

    for room = 0, total_rooms - 1 do
        local room_offset = room * ROOM_RECORD_SIZE

        -- Read room header (10 bytes covers code + image pointer + image size)
        local header = file_read(f_pant, room_offset, 10)
        if not header or #header < 8 then goto continue end

        local room_code = u16le(header, 1)
        local img_ptr   = u32le(header, 3)
        local img_size  = u16le(header, 7)

        -- Read palettePointer at offset +9052 (direct byte offset into PALETAS.DAT)
        local pal_area  = file_read(f_pant, room_offset + 9052, 2)
        local pal_ptr   = pal_area and u16le(pal_area, 1) or 0

        local room_node = {
            id       = "room_" .. room,
            name     = string.format("Room %02d (code %d)", room, room_code),
            type     = "category",
            children = {}
        }

        -- Background child (only if bitmap exists)
        if img_ptr > 0 and img_size > 4 then
            room_node.children[#room_node.children + 1] = {
                id   = "bg_" .. room,
                name = "Background",
                type = "image"
            }
        end

        -- Palette child (always present)
        room_node.children[#room_node.children + 1] = {
            id   = "pal_" .. room,
            name = string.format("Palette (offset 0x%X)", pal_ptr),
            type = "palette"
        }

        rooms_cat.children[#rooms_cat.children + 1] = room_node
        ::continue::
    end
    file_close(f_pant)
    resources[#resources + 1] = rooms_cat

    -- ── Objects ───────────────────────────────────────────────────
    local objects = {
        id       = "objects",
        name     = string.format("Objects (%d)", num_objects),
        type     = "category",
        children = {}
    }

    if num_objects > 0 then
        local fo = file_open(game_path .. "/OBJETOS.DAT")
        for obj = 0, num_objects - 1 do
            local obj_data = file_read(fo, obj * OBJECT_RECORD_SIZE, 57)
            if obj_data and #obj_data >= 57 then
                local code    = u16le(obj_data, 1)
                local name    = pascal_string(obj_data, 4, 20)
                local bmp_ptr = u32le(obj_data, 52)
                local bmp_sz  = u16le(obj_data, 56)
                if bmp_ptr > 0 and bmp_sz > 4 and #name > 0 then
                    objects.children[#objects.children + 1] = {
                        id   = "obj_" .. obj,
                        name = string.format("%s (code %d)", name, code),
                        type = "image"
                    }
                end
            end
        end
        file_close(fo)
    end
    resources[#resources + 1] = objects

    -- ── Conversation Text ─────────────────────────────────────────
    local texts = {
        id       = "texts",
        name     = "Conversation Text",
        type     = "category",
        children = {}
    }

    if file_exists(game_path .. "/CONVERSA.TXT") then
        local ft = file_open(game_path .. "/CONVERSA.TXT")
        local num_entries = math.floor(file_size(ft) / 263)
        file_close(ft)

        local batch_size = 50
        for batch_start = 0, num_entries - 1, batch_size do
            local batch_end = math.min(batch_start + batch_size - 1, num_entries - 1)
            texts.children[#texts.children + 1] = {
                id   = string.format("txt_%d_%d", batch_start, batch_end),
                name = string.format("Entries %d-%d", batch_start, batch_end),
                type = "text"
            }
        end
        log_info(string.format("TOT: %d conversation entries", num_entries))
    end
    resources[#resources + 1] = texts
    for _, node in ipairs(engine.extra_resources(game_path)) do resources[#resources + 1] = node end

    return resources
end

-- ── Resource dispatcher ──────────────────────────────────────────

function engine.load_resource(game_path, resource_id, palette_id)
    if resource_id:match("^tt_") then return engine.load_extra(game_path, resource_id, palette_id) end
    local prefix, arg = resource_id:match("^(%a+)_(.+)$")

    if prefix == "bg"  then
        local pal_override = nil
        if palette_id and palette_id ~= "" then
            local _, pnum = palette_id:match("^(%a+)_(%d+)$")
            if pnum then pal_override = tonumber(pnum) end
        end
        return load_room_background(game_path, tonumber(arg), pal_override)
    elseif prefix == "pal"  then return load_room_palette(game_path, tonumber(arg))
    elseif prefix == "obj"  then
        local pal_override = nil
        if palette_id and palette_id ~= "" then
            local _, pnum = palette_id:match("^(%a+)_(%d+)$")
            if pnum then pal_override = tonumber(pnum) end
        end
        return load_object_image(game_path, tonumber(arg), pal_override)
    elseif prefix == "txt"  then
        local s, e = arg:match("^(%d+)_(%d+)$")
        if s and e then
            return load_conversation_text(game_path, tonumber(s), tonumber(e))
        end
    end
    return nil
end

-- ── Load room background ─────────────────────────────────────────

function load_room_background(game_path, room_num, pal_override)
    local f_pant = file_open(game_path .. "/PANTALLA.DAT")
    local room_offset = room_num * ROOM_RECORD_SIZE
    local header = file_read(f_pant, room_offset, 10)

    local room_code = u16le(header, 1)
    local img_ptr   = u32le(header, 3)
    local img_size  = u16le(header, 7)

    -- palettePointer at +9052: direct byte offset into PALETAS.DAT
    local pal_room = pal_override or room_num
    local pal_area = file_read(f_pant, pal_room * ROOM_RECORD_SIZE + 9052, 2)
    local pal_ptr  = u16le(pal_area, 1)
    file_close(f_pant)

    -- Read bitmap
    local f_bmp  = file_open(game_path .. "/BITMAPS.DAT")
    local bmp_data = file_read(f_bmp, img_ptr, img_size)
    file_close(f_bmp)

    if not bmp_data or #bmp_data < 5 then return nil end

    local w = u16le(bmp_data, 1) + 1
    local h = u16le(bmp_data, 3) + 1

    local pixels = {}
    local pixel_count = 0
    for i = 5, math.min(#bmp_data, 4 + w * h) do
        pixel_count = pixel_count + 1
        pixels[pixel_count] = bmp_data:byte(i)
    end
    while pixel_count < w * h do
        pixel_count = pixel_count + 1; pixels[pixel_count] = 0
    end

    -- Palette: use pal_ptr as DIRECT byte offset into PALETAS.DAT
    local palette = load_vga_palette_at(game_path, pal_ptr)
    if not palette then
        palette = {}
        for i = 0, 255 do
            palette[i*3+1] = i; palette[i*3+2] = i; palette[i*3+3] = i
        end
    end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image", image = img, width = w, height = h,
        description = string.format(
            "Room %d (code %d) - %dx%d, palette @0x%X",
            room_num, room_code, w, h, pal_ptr
        )
    }
end

-- ── Load room palette swatch ─────────────────────────────────────

function load_room_palette(game_path, room_num)
    local f_pant = file_open(game_path .. "/PANTALLA.DAT")
    local pal_area = file_read(f_pant, room_num * ROOM_RECORD_SIZE + 9052, 2)
    local pal_ptr  = u16le(pal_area, 1)
    file_close(f_pant)

    local palette = load_vga_palette_at(game_path, pal_ptr)
    if not palette then return nil end

    local CELL, GRID = 16, 16
    local SIZE = CELL * GRID
    local rgb = {}; local n = 0

    for py = 0, SIZE - 1 do
        for px = 0, SIZE - 1 do
            local ci = math.floor(py / CELL) * GRID + math.floor(px / CELL)
            n=n+1; rgb[n] = palette[ci*3+1]
            n=n+1; rgb[n] = palette[ci*3+2]
            n=n+1; rgb[n] = palette[ci*3+3]
        end
    end

    local img = image_create_rgb(SIZE, SIZE, rgb)
    return {
        type = "image", image = img, width = SIZE, height = SIZE,
        description = string.format(
            "Room %d palette - 256 colors, PALETAS.DAT @0x%X", room_num, pal_ptr
        )
    }
end

-- ── Load object image ────────────────────────────────────────────

function load_object_image(game_path, obj_num, pal_override)
    local fo = file_open(game_path .. "/OBJETOS.DAT")
    local obj_data = file_read(fo, obj_num * OBJECT_RECORD_SIZE, 279)
    file_close(fo)
    if not obj_data or #obj_data < 57 then return nil end

    local code    = u16le(obj_data, 1)
    local name    = pascal_string(obj_data, 4, 20)
    local bmp_ptr = u32le(obj_data, 52)
    local bmp_sz  = u16le(obj_data, 56)
    if bmp_ptr == 0 or bmp_sz <= 4 then return nil end

    local f_bmp = file_open(game_path .. "/BITMAPS.DAT")
    local bmp_data = file_read(f_bmp, bmp_ptr, bmp_sz)
    file_close(f_bmp)
    if not bmp_data or #bmp_data < 5 then return nil end

    local w = u16le(bmp_data, 1) + 1
    local h = u16le(bmp_data, 3) + 1
    local pixels = {}; local pixel_count = 0
    for i = 5, math.min(#bmp_data, 4 + w * h) do
        pixel_count = pixel_count + 1; pixels[pixel_count] = bmp_data:byte(i)
    end
    while pixel_count < w * h do
        pixel_count = pixel_count + 1; pixels[pixel_count] = 0
    end

    -- Use palette override if specified, otherwise try to find the object's room palette
    local pal_ptr = 0
    if pal_override then
        local f_pant = file_open(game_path .. "/PANTALLA.DAT")
        local pal_area = file_read(f_pant, pal_override * ROOM_RECORD_SIZE + 9052, 2)
        file_close(f_pant)
        pal_ptr = pal_area and u16le(pal_area, 1) or 0
    end
    local palette = load_vga_palette_at(game_path, pal_ptr)
    if not palette then
        palette = {}
        for i = 0, 255 do
            palette[i*3+1] = i; palette[i*3+2] = i; palette[i*3+3] = i
        end
    end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image", image = img, width = w, height = h,
        description = string.format(
            "%s (code %d) - %dx%d, bitmap @0x%X", name, code, w, h, bmp_ptr
        )
    }
end

-- ── Load conversation text ───────────────────────────────────────

local DECRYPTION_KEY = "23313212133122121312132132312312122132322131221322222112121"
    .. "32121121212112111212112333131232323213222132123211213221231"
    .. "32132213232333333213132132132322113212132121322123121232332"
    .. "23123221322213233221112312231221233232122332211112233122321"
    .. "222312211322312223"

local function bxor8(a, b)
    local r, bit = 0, 1
    for _ = 1, 8 do
        if (a % 2) ~= (b % 2) then r = r + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return r
end

local CP437 = { 0xC7, 0xFC, 0xE9, 0xE2, 0xE4, 0xE0, 0xE5, 0xE7, 0xEA, 0xEB, 0xE8, 0xEF, 0xEE, 0xEC, 0xC4, 0xC5,
    0xC9, 0xE6, 0xC6, 0xF4, 0xF6, 0xF2, 0xFB, 0xF9, 0xFF, 0xD6, 0xDC, 0xA2, 0xA3, 0xA5, 0x20A7, 0x192,
    0xE1, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xAA, 0xBA, 0xBF, 0x2310, 0xAC, 0xBD, 0xBC, 0xA1, 0xAB, 0xBB }
local function cp437(b)
    if b < 0x80 then return string.char(b) end
    local cp = CP437[b - 0x7F] or 0xFFFD
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

function load_conversation_text(game_path, start_idx, end_idx)
    local ft = file_open(game_path .. "/CONVERSA.TXT")
    local lines = {}

    for entry = start_idx, end_idx do
        local entry_data = file_read(ft, entry * 263, 263)
        if entry_data and #entry_data >= 256 then
            local len = u8(entry_data, 1)
            if len > 255 then len = 255 end
            local chars = {}
            for i = 1, len do
                -- XOR with TotEngine::_decryptionKey (tot.cpp), then code page 437
                local b = bxor8(entry_data:byte(1 + i) or 0, DECRYPTION_KEY:byte(i) or 0)
                if b >= 0x20 then chars[#chars + 1] = cp437(b) end
            end
            local text = table.concat(chars)
            if #text > 0 then
                lines[#lines + 1] = string.format("[%03d] %s", entry, text)
            end
        end
    end
    file_close(ft)

    return {
        type = "text",
        text = table.concat(lines, "\n"),
        description = string.format(
            "Entries %d-%d (%d lines)", start_idx, end_idx, #lines
        )
    }
end

-- ── VGA palette loader (DIRECT byte offset) ──────────────────────
-- pal_byte_offset is the RAW byte offset into PALETAS.DAT (not index x768)

function load_vga_palette_at(game_path, pal_byte_offset)
    if not file_exists(game_path .. "/PALETAS.DAT") then return nil end
    local fp  = file_open(game_path .. "/PALETAS.DAT")
    local raw = file_read(fp, pal_byte_offset, PALETTE_SIZE)
    file_close(fp)
    if not raw or #raw < PALETTE_SIZE then return nil end

    local palette = {}
    for i = 0, 255 do
        palette[i*3+1] = math.min(raw:byte(i*3+1) * 4, 255)
        palette[i*3+2] = math.min(raw:byte(i*3+2) * 4, 255)
        palette[i*3+3] = math.min(raw:byte(i*3+3) * 4, 255)
    end
    return palette
end

-- ── Animations, sound effects and music ─────────────────────────
-- References (ScummVM engines/tot): engine.cpp (loadAnimation,
-- loadAnimationForDirection), resources.cpp (loadCharAnimation for
-- PERSONAJ.SPT), graphics.cpp (putImg: u16 width-1, u16 height-1, pixels,
-- 0 transparent), sound.cpp (loadVoc: loose VOC files and EFECTOS.DAT clips;
-- playMidi: .MUS files are standard MIDI).

local function tt_read(path)
    local f = file_open(path)
    if not f then return nil end
    local d = file_read(f, 0, file_size(f))
    file_close(f)
    return d
end

-- Animation files: u16 frame size, u8 frame count, u8 direction count, then the
-- frames; PERSONAJ.SPT has only the u16 frame size before its frames.
local function anim_layout(name, size, head)
    if not head or #head < 4 then return nil end
    if name:upper() == "PERSONAJ.SPT" then
        local fs = u16le(head, 1)
        if fs > 4 and (size - 2) % fs == 0 then return 2, fs, (size - 2) / fs, 0 end
        return nil
    end
    local fs, fc, dirs = u16le(head, 1), u8(head, 3), u8(head, 4)
    if fs > 4 and fc > 0 and 4 + fc * fs == size then return 4, fs, fc, dirs end
end

-- EFECTOS.DAT is VOC clips back to back (the game seeks to offsets in its code).
local function efectos_clips(data)
    local clips, p = {}, 1
    while true do
        local s = data:find("Creative Voice File\26", p, true)
        if not s then break end
        local n = data:find("Creative Voice File\26", s + 20, true)
        clips[#clips + 1] = { offset = s, size = (n or #data + 1) - s }
        p = s + 20
    end
    return clips
end

function engine.extra_resources(game_path)
    local out, anims, sounds, music = {}, {}, {}, {}
    local names = list_files(game_path) or {}
    table.sort(names)
    for _, name in ipairs(names) do
        local up = name:upper()
        local ext = up:match("%.(%w+)$") or ""
        if ext == "DAT" or ext == "SEC" or ext == "SPT" then
            local f = file_open(game_path .. "/" .. name)
            if f then
                local size = file_size(f)
                local hdr, fs, count = anim_layout(name, size, file_read(f, 0, 4))
                file_close(f)
                if hdr then anims[#anims + 1] = { id = "tt_anim_" .. name, name = string.format("%s (%d frames)", name, count), type = "animation" } end
            end
            if up == "EFECTOS.DAT" then
                local clips = efectos_clips(tt_read(game_path .. "/" .. name) or "")
                for i = 1, #clips do sounds[#sounds + 1] = { id = "tt_efx_" .. (i - 1), name = string.format("EFECTOS.DAT clip %d", i - 1), type = "sound" } end
            end
        elseif ext == "VOC" then
            sounds[#sounds + 1] = { id = "tt_voc_" .. name, name = name, type = "sound" }
        elseif ext == "MUS" or ext == "MID" then
            local f = file_open(game_path .. "/" .. name)
            local head = f and file_read(f, 0, 4)
            if f then file_close(f) end
            if head == "MThd" then music[#music + 1] = { id = "tt_mid_" .. name, name = name, type = "midi" } end
        end
    end
    if #anims > 0 then out[#out + 1] = { id = "tt_anims", name = string.format("Animations (%d)", #anims), type = "category", children = anims } end
    if #sounds > 0 then out[#out + 1] = { id = "tt_sounds", name = string.format("Sound effects (%d)", #sounds), type = "category", children = sounds } end
    if #music > 0 then out[#out + 1] = { id = "tt_music", name = string.format("Music (%d)", #music), type = "category", children = music } end
    return out
end

function engine.load_extra(game_path, resource_id, palette_id)
    local name = resource_id:match("^tt_anim_(.+)$")
    if name then
        local d = tt_read(game_path .. "/" .. name)
        if not d then return nil end
        local hdr, fs, count, dirs = anim_layout(name, #d, d:sub(1, 4))
        if not hdr then return nil end
        -- Room palette when one is selected, otherwise DEFAULT.PAL (6-bit VGA)
        local palette
        local room = tonumber((palette_id or ""):match("^pal_(%d+)$") or "")
        if room then
            local f_pant = file_open(game_path .. "/PANTALLA.DAT")
            local pal_area = f_pant and file_read(f_pant, room * ROOM_RECORD_SIZE + 9052, 2)
            if f_pant then file_close(f_pant) end
            palette = pal_area and load_vga_palette_at(game_path, u16le(pal_area, 1))
        end
        if not palette then
            local raw = tt_read(game_path .. "/DEFAULT.PAL") or ""
            palette = {}
            for i = 1, 768 do palette[i] = math.min((raw:byte(i) or 0) * 4, 255) end
        end
        local frames, w, h = {}, 0, 0
        for k = 0, math.min(count, 400) - 1 do
            local p = hdr + k * fs + 1
            local fw, fh = u16le(d, p) + 1, u16le(d, p + 2) + 1
            if k == 0 then w, h = fw, fh end
            if fw == w and fh == h and 4 + fw * fh <= fs then
                local px = {}
                for i = 1, fw * fh do local c = d:byte(p + 3 + i) or 0; px[i] = c == 0 and 256 or c end
                frames[#frames + 1] = image_create_indexed(fw, fh, px, palette, 256)
            end
        end
        if #frames == 0 then return nil end
        local desc = string.format("%s — %d frames, %dx%d%s", name, #frames, w, h, (dirs or 0) > 0 and string.format(", %d directions", dirs) or "")
        if #frames == 1 then return { type = "image", image = frames[1], description = desc } end
        return { type = "animation", animation = animation_create(frames, 100), delay_ms = 100, description = desc }
    end
    local idx = tonumber(resource_id:match("^tt_efx_(%d+)$") or "")
    if idx then
        local d = tt_read(game_path .. "/EFECTOS.DAT")
        local clip = d and efectos_clips(d)[idx + 1]
        local snd = clip and sound_create_encoded(d:sub(clip.offset, clip.offset + clip.size - 1))
        return snd and { type = "sound", sound = snd, description = string.format("EFECTOS.DAT clip %d — VOC", idx) }
    end
    name = resource_id:match("^tt_voc_(.+)$")
    if name then
        local d = tt_read(game_path .. "/" .. name)
        local snd = d and sound_create_encoded(d)
        return snd and { type = "sound", sound = snd, description = name .. " — VOC" }
    end
    name = resource_id:match("^tt_mid_(.+)$")
    if name then
        local d = tt_read(game_path .. "/" .. name)
        return d and { type = "midi", midi = midi_create_raw(d), description = name .. " — MIDI" }
    end
end

return engine

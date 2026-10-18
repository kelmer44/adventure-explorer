-- ============================================================================
-- Adventure Explorer - Engine Script: Dark Seed (Cyberdreams, 1992)
-- ============================================================================
-- Floppy: ROOMn.ROM room definitions in root referencing named .PIC/.PAL/.NSP
--         (all files in the root directory)
-- CD:     named .PIC/.PAL files in PICTURE/ subdirectory, ROOMn.ROM/.NSP/.OBT
--         in ROOM/ subdirectory
-- Image format: u16be width, u16be height, then 4-bit nibble RLE, 16 colors
-- Palette: 16 × 3 bytes (6-bit VGA, scaled by <<2)
--
-- ROOMn.ROM layout (see ScummVM darkseed/room.cpp):
--   0x00  8 bytes  NSP filename base (space padded, e.g. "EDIT    ")
--   0x0d  8 bytes  PIC filename base (space padded, e.g. "BED1A   ")
--   0x1a  8 bytes  legacy editor PAL name (not the runtime room palette)
--   0x27  ...      room exits, walk map, object table
-- ============================================================================

local engine = {}
engine.name        = "Dark Seed"
engine.id          = "darkseed"
engine.description = "Dark Seed (1992, Cyberdreams) - floppy & CD"
engine.version     = "2.2"

-- Binary helpers
local function u16be(data, pos)
    return data:byte(pos) * 256 + data:byte(pos + 1)
end

-- Nibble RLE decompressor for .pic files
local function decompress_pic(data, start_pos, total_pixels)
    local pixels = {}
    local n = 0
    local pos = start_pos
    local nibble_idx = 0
    local len = #data

    local function read_nibble()
        if pos > len then return 0 end
        local b = data:byte(pos)
        if nibble_idx == 0 then
            nibble_idx = 1
            return math.floor(b / 16)
        else
            nibble_idx = 0
            pos = pos + 1
            return b % 16
        end
    end

    while n < total_pixels do
        local cmd = read_nibble()
        if cmd < 8 then
            local count = cmd + 1
            for _ = 1, count do
                if n >= total_pixels then break end
                n = n + 1
                pixels[n] = read_nibble()
            end
        else
            local count = 16 - cmd + 1
            local color = read_nibble()
            for _ = 1, count do
                if n >= total_pixels then break end
                n = n + 1
                pixels[n] = color
            end
        end
    end

    return pixels
end

-- Load palette from .pal file: 16 × 3 bytes, 6-bit VGA
local function load_palette(pal_path)
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
    end

    local fpal = file_open(pal_path)
    if not fpal then return nil end
    local pal_raw = file_read(fpal, 0, 48)
    file_close(fpal)
    if not pal_raw or #pal_raw < 48 then return nil end

    for i = 0, 15 do
        local r = pal_raw:byte(i * 3 + 1) or 0
        local g = pal_raw:byte(i * 3 + 2) or 0
        local b = pal_raw:byte(i * 3 + 3) or 0
        palette[i * 3 + 1] = math.min(r * 4, 255)
        palette[i * 3 + 2] = math.min(g * 4, 255)
        palette[i * 3 + 3] = math.min(b * 4, 255)
    end

    return palette
end

-- Default EGA palette fallback
local function ega_palette()
    local ega = {
        {0,0,0},{0,0,170},{0,170,0},{0,170,170},
        {170,0,0},{170,0,170},{170,85,0},{170,170,170},
        {85,85,85},{85,85,255},{85,255,85},{85,255,255},
        {255,85,85},{255,85,255},{255,255,85},{255,255,255}
    }
    local palette = {}
    for i = 0, 15 do
        palette[i*3+1] = ega[i+1][1]
        palette[i*3+2] = ega[i+1][2]
        palette[i*3+3] = ega[i+1][3]
    end
    for i = 16, 255 do
        palette[i*3+1] = 0; palette[i*3+2] = 0; palette[i*3+3] = 0
    end
    return palette
end

-- Try to find a file with case-insensitive matching
local function find_file(game_path, name)
    -- Resolve the actual spelling even when file_exists/file_open themselves
    -- are case insensitive: list_files requires an existing directory path.
    for _, entry in ipairs(list_files(game_path) or {}) do
        if entry:lower() == name:lower() then return game_path .. "/" .. entry end
    end
    return nil
end

-- Check for CD version (has PICTURE/ subdirectory)
local function has_picture_dir(game_path)
    local dir = find_file(game_path, "PICTURE")
    local files = dir and list_files(dir)
    return files ~= nil and #files > 0
end

-- CD separates pictures/palettes and room definitions/sprites.
local function picture_dir(game_path, is_cd)
    return is_cd and (find_file(game_path, "PICTURE") or game_path .. "/PICTURE") or game_path
end

local function room_dir(game_path, is_cd)
    return is_cd and (find_file(game_path, "ROOM") or game_path .. "/ROOM") or game_path
end

-- Read the 8-byte, space-padded, NUL-terminated name field at a given byte offset.
local function rom_name_field(data, off)
    local chars = {}
    for i = 0, 7 do
        local b = data:byte(off + i + 1)
        if not b or b == 0 then break end
        chars[#chars + 1] = string.char(b)
    end
    return (table.concat(chars):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Parse a ROOMn.ROM room definition and return the NSP/PIC/PAL filename bases.
local function parse_rom(game_path, room_base)
    local rom_path = find_file(game_path, room_base .. ".rom")
    if not rom_path then return nil end
    local f = file_open(rom_path)
    if not f then return nil end
    local data = file_read(f, 0, 0x27)
    file_close(f)
    if not data or #data < 0x27 then return nil end
    return rom_name_field(data, 0x00), rom_name_field(data, 0x0d), rom_name_field(data, 0x1a)
end

-- Sort key so ROOM2 < ROOM10 and ROOM61 < ROOM61A.
local function room_sort_key(room_base)
    local suffix = room_base:upper():gsub("^ROOM", "")
    local num, rest = suffix:match("^(%d+)(%a*)$")
    if num then return string.format("%04d%s", tonumber(num), rest) end
    return "9999" .. suffix
end

-- Rooms 20 and 22 share room 19's room definition in every release
-- (see ScummVM darkseed/room.cpp getRoomFilenameBase).
local function room_rom_base(room_base)
    local suffix = room_base:upper():gsub("^ROOM", "")
    if suffix == "20" or suffix == "22" then return "room19" end
    return room_base:lower()
end

-- Runtime rooms use ROOMn.PAL, not the stale PAL/NSP editor fields in
-- the ROM. Rooms 20/22 alias room19; 61A is an alternate walk map for 61.
local function room_palette(game_path, base, is_cd)
    base = room_rom_base(base)
    if base == "room61a" then base = "room61" end
    local pics = picture_dir(game_path, is_cd)
    local pal = find_file(pics, base .. ".pal")
    if pal then return pal end
    -- Some unused/editor rooms (e.g. 21) have no runtime palette at all.
    local _, _, legacy = parse_rom(room_dir(game_path, is_cd), base)
    if legacy and legacy ~= "" then return find_file(pics, legacy .. ".pal") end
    return nil
end

-- Standalone animations inherit the palette of the room/fullscreen picture
-- that draws them (ScummVM animation.cpp, darkseed.cpp and usecode.cpp).
-- Shared player/inventory sheets use a representative room in their world;
-- the palette selector can still preview them in other rooms.
local sprite_scene = {
    ASPIRIN="ROOM4", BEDSLEEP="ROOM0", SHOWER="ROOM4", PHONE="ROOM0",
    OPENDRWR="ROOM8", MIRROR="ROOM7", MGLOW="ROOM7", SMASH="ROOM7",
    DARKIN="ROOM38", DARKOUT="ROOM38", BEAMER="ROOM41",
    RM10STRS="ROOM10", RM11STRS="ROOM11", STAIRS="ROOM6",
    RTLADDER="ROOM2", LTLADDER="ROOM5", PUSH="ROOM61", PUSHTRNK="ROOM61",
    SLIDE="ROOM32", OPENDOOR="ROOM6", CROWBAR="ROOM6", TIEROPE="ROOM13",
    DELSTORE="ROOM16", GIVCLERK="ROOM16", DELSIDE="ROOM32", DELBERT="ROOM31",
    DELDRINK="ROOM32", MTHROW="ROOM53", OBSLEV="ROOM43", INSTRSHP="ROOM60",
    POWNEX="ROOM51", CUPHIT="ROOM30", COPCARD="ROOM30",
    LGRAVEDG="ROOM25", RGRAVEDG="ROOM25", RGRAVE="ROOM25",
    GLOVEBOX="ROOM34", DREKGRD="ROOM55", LIBRARIA="ROOM17",
    CBASE="ROOM0", CPLAYER="ROOM0", CLIEDOWN="ROOM0", LIEDOWN="ROOM0",
    GBASE="ROOM38", GPLAYER="ROOM38", GLIEDOWN="ROOM38", OBJECTS="ROOM0",
    TOSFONT="TOSSTD", LABPARTS="LAB", LIBPARTS="LIBINLIB", LIBMORPH="LIB-BABE",
}
local picture_scene = {
    CFRAME="ROOM0", GFRAME="ROOM38", ["12-NEW-E"]="ROOM12",
    -- Dark-world documents have no PAL; Pal::load inherits the room palette.
    GBCARD01="ROOM38", GBPRINT1="ROOM38", GDIARY="ROOM38",
    GJOUR201="ROOM38", GJOURN01="ROOM38", GLADY="ROOM38", GLCARD="ROOM38",
}

local function scene_palette(game_path, resource_id, is_cd)
    local pics = picture_dir(game_path, is_cd)
    local sprite = resource_id:match("^nsp_(.+)$")
    local bg = resource_id:match("^bg_(.+)$")
    local base = (sprite or bg or ""):upper()
    if base == "" then return nil end
    if base:match("^ROOM%d+%a*$") then return room_palette(game_path, base, is_cd) end

    -- A fullscreen picture/animation with its own palette takes precedence.
    local exact = find_file(pics, base .. ".pal")
    if exact then return exact end
    local scene = sprite and sprite_scene[base] or picture_scene[base:gsub("_", "-")]
    if scene then
        local pal = find_file(pics, scene .. ".pal")
        if not pal then pal = find_file(pics, scene:gsub("-", "_") .. ".pal") end
        if pal then return pal end
    end

    if bg then
        -- Named CD pictures get their runtime palette from the owning room.
        -- Read each ROM's own PIC field: aliasing 20/22 here would hide STACKB/D.
        local dir = room_dir(game_path, is_cd)
        local rooms = {}
        for _, name in ipairs(list_files(dir) or {}) do
            local room = name:upper():match("^(ROOM%d+%a*)%.ROM$")
            if room then rooms[#rooms + 1] = room end
        end
        table.sort(rooms, function(a, b) return room_sort_key(a) < room_sort_key(b) end)
        for _, room in ipairs(rooms) do
            local _, pic = parse_rom(dir, room)
            if pic and pic:upper() == base then
                local pal = room_palette(game_path, room, is_cd)
                if pal then return pal end
            end
        end
    end
    return find_file(pics, "AA.PAL")
end

-- Detection
function engine.detect(game_path)
    -- Check for executable
    local has_exe = file_exists(game_path .. "/TOS.EXE")
                 or file_exists(game_path .. "/tos.exe")
                 or file_exists(game_path .. "/DS.BAT")
                 or file_exists(game_path .. "/ds.bat")
                 or file_exists(game_path .. "/START.EXE")
                 or file_exists(game_path .. "/start.exe")

    if not has_exe then return false end

    -- CD version: named backgrounds in PICTURE/
    if has_picture_dir(game_path) then return true end

    -- Floppy version: ROOMn.ROM room definitions in the root (DSEED35)
    if find_file(game_path, "room0.rom") then return true end

    -- Older/other floppy releases: numbered backgrounds in the root
    for room = 0, 5 do
        if find_file(game_path, "room" .. room .. ".pic") then return true end
    end

    return false
end

-- Resource tree
function engine.get_resources(game_path)
    local resources = {}
    local is_cd = has_picture_dir(game_path)

    -- CD version: scan PICTURE/ for .PIC and .PAL files
    if is_cd then
        local pic_dir = picture_dir(game_path, true)
        local files = list_files(pic_dir)

        if files and #files > 0 then
            -- Collect .PIC and .PAL files
            local pic_files = {}
            local pal_files = {}
            for _, fname in ipairs(files) do
                local upper = fname:upper()
                if upper:match("%.PIC$") then
                    pic_files[#pic_files + 1] = fname
                elseif upper:match("%.PAL$") then
                    pal_files[#pal_files + 1] = fname
                end
            end
            table.sort(pic_files)
            table.sort(pal_files)

            if #pic_files > 0 then
                local cat = {
                    id = "cd_rooms",
                    name = string.format("Dark Seed CD (%d backgrounds)", #pic_files),
                    type = "category",
                    children = {}
                }

                for _, fname in ipairs(pic_files) do
                    local base = fname:match("^(.+)%.[Pp][Ii][Cc]$") or fname
                    cat.children[#cat.children + 1] = {
                        id = "bg_" .. base,
                        name = base,
                        type = "image"
                    }
                end

                resources[#resources + 1] = cat
            end

            if #pal_files > 0 then
                local pal_cat = {
                    id = "cd_palettes",
                    name = string.format("Palettes (%d)", #pal_files),
                    type = "category",
                    children = {}
                }

                for _, fname in ipairs(pal_files) do
                    local base = fname:match("^(.+)%.[Pp][Aa][Ll]$") or fname
                    pal_cat.children[#pal_cat.children + 1] = {
                        id = "pal_" .. base,
                        name = base .. " palette",
                        type = "palette"
                    }
                end

                resources[#resources + 1] = pal_cat
            end
        end
    end

    -- Floppy version: rooms are defined by ROOMn.ROM files in the root, each
    -- naming its background and palette. Lists rooms plus every palette/sprite.
    if not is_cd then
        local root_files = list_files(game_path) or {}

        local roms = {}
        for _, fname in ipairs(root_files) do
            local base = fname:match("^([Rr][Oo][Oo][Mm][%w]+)%.([Rr][Oo][Mm])$")
            if base then roms[#roms + 1] = base end
        end
        table.sort(roms, function(a, b) return room_sort_key(a) < room_sort_key(b) end)

        local rooms_cat = {
            id = "floppy_rooms",
            name = "Rooms (Floppy)",
            type = "category",
            children = {},
        }
        for _, base in ipairs(roms) do
            local _, pic, _ = parse_rom(game_path, room_rom_base(base))
            local label = base:upper():gsub("^ROOM", "")
            local name = "Room " .. label
            if pic and #pic > 0 then name = name .. " - " .. pic end
            rooms_cat.children[#rooms_cat.children + 1] = {
                id   = "bg_" .. base:lower(),
                name = name,
                type = "image",
            }
        end
        if #rooms_cat.children > 0 then
            rooms_cat.name = string.format("Rooms (%d)", #rooms_cat.children)
            resources[#resources + 1] = rooms_cat
        end

        local pal_cat = {
            id = "floppy_palettes",
            name = "Palettes (Floppy)",
            type = "category",
            children = {},
        }
        for _, fname in ipairs(root_files) do
            local base = fname:match("^(.+)%.[Pp][Aa][Ll]$")
            if base then
                pal_cat.children[#pal_cat.children + 1] = {
                    id   = "pal_" .. base,
                    name = base .. " palette",
                    type = "palette",
                }
            end
        end
        table.sort(pal_cat.children, function(a, b) return a.name < b.name end)
        if #pal_cat.children > 0 then
            pal_cat.name = string.format("Palettes (%d)", #pal_cat.children)
            resources[#resources + 1] = pal_cat
        end
    end

    -- Scan for .NSP sprite files (in root for floppy, ROOM/ for CD)
    local nsp_dir = room_dir(game_path, is_cd)

    local nsp_files = list_files(nsp_dir)
    if nsp_files and #nsp_files > 0 then
        local cat = {
            id = "sprites",
            name = "Sprites (NSP)",
            type = "category",
            children = {},
        }
        for _, fname in ipairs(nsp_files) do
            local base = fname:match("^(.+)%.[Nn][Ss][Pp]$")
            if base then
                cat.children[#cat.children + 1] = {
                    id   = "nsp_" .. base:upper(),
                    name = base:upper(),
                    type = "animation",
                }
            end
        end
        table.sort(cat.children, function(a, b) return a.name < b.name end)
        if #cat.children > 0 then
            cat.name = string.format("Sprites (%d NSP files)", #cat.children)
            resources[#resources + 1] = cat
        end
    end

    return resources
end

-- ── NSP sprite loader ────────────────────────────────────────────
-- NSP format (ScummVM darkseed/nsp.cpp):
--   192 bytes: 96 x (u8 width, u8 height) frame headers
--   Then: 96 pixel data blocks, nibble-packed (high nibble first)
--     pitch = width + (width & 1)   -- always even
--     For 1x1 sprite: 1 byte with only high nibble used
--     Otherwise: (pitch * height / 2) bytes per frame
--   Palette index 0xF (15) = transparent

local function load_nsp(nsp_path, pal_path)
    local f = file_open(nsp_path)
    if not f then return nil, "Cannot open NSP" end
    local fsize = file_size(f)
    local data  = file_read(f, 0, fsize)
    file_close(f)
    if not data or fsize < 192 then return nil, "NSP too small" end

    -- Load palette (6-bit VGA, already scaled x4 by load_palette)
    local palette
    if pal_path then palette = load_palette(pal_path) end
    if not palette then palette = ega_palette() end
    -- Index 15 = transparent: display as magenta so outlines are visible
    palette[15 * 3 + 1] = 255
    palette[15 * 3 + 2] = 0
    palette[15 * 3 + 3] = 255

    -- Read 96 frame headers
    local frames = {}
    for i = 0, 95 do
        local w = data:byte(i * 2 + 1)
        local h = data:byte(i * 2 + 2)
        local p = w + (w % 2)   -- pitch (even-padded)
        frames[i] = { w = w, h = h, p = p }
    end

    -- Decode pixel data starting at byte offset 192 (Lua pos 193)
    local pos = 193
    local handles = {}

    for i = 0, 95 do
        local fr = frames[i]
        if fr.w > 0 and fr.h > 0 then
            local total = fr.p * fr.h
            local pixels = {}
            for j = 1, total do pixels[j] = 0 end

            if fr.w == 1 and fr.h == 1 then
                -- Special case: 1 byte, only high nibble used
                if pos <= #data then
                    pixels[1] = math.floor(data:byte(pos) / 16)
                    pos = pos + 1
                end
            else
                -- Normal case: total nibbles = total pixels (always even because pitch is even)
                local byte_count = total / 2
                for j = 0, total - 1 do
                    local bp = pos + math.floor(j / 2)
                    if bp <= #data then
                        local b = data:byte(bp)
                        if j % 2 == 0 then
                            pixels[j + 1] = math.floor(b / 16)  -- high nibble
                        else
                            pixels[j + 1] = b % 16              -- low nibble
                        end
                    end
                end
                pos = pos + byte_count
            end

            handles[#handles + 1] = image_create_indexed(fr.p, fr.h, pixels, palette)
        end
    end

    if #handles == 0 then return nil, "No non-empty frames" end
    return handles
end

-- ── Background image loader ──────────────────────────────────────
-- Load a .PIC background image with optional .PAL palette
local function load_pic_image(pic_path, pal_path, label)
    if not pic_path then return { type = "text", text = "Background not found: " .. label } end
    local fp = file_open(pic_path)
    if not fp then return nil end
    local pic_size = file_size(fp)
    local pic_data = file_read(fp, 0, pic_size)
    file_close(fp)
    if not pic_data or #pic_data < 5 then return nil end

    local w = u16be(pic_data, 1)
    local h = u16be(pic_data, 3)

    if w == 0 or h == 0 or w > 1024 or h > 512 then
        return { type = "text", text = string.format("Invalid dimensions: %dx%d", w, h) }
    end

    local total_pixels = w * h
    local pixels = decompress_pic(pic_data, 5, total_pixels)

    -- Load palette
    local palette
    if pal_path then
        palette = load_palette(pal_path)
    end

    -- No PAL found or failed to load: try AA.PAL (game default) from same directory
    if not palette then
        local pic_dir = pic_path:match("^(.+)/[^/]+$") or "."
        local aa_path = pic_dir .. "/AA.PAL"
        if not file_exists(aa_path) then aa_path = pic_dir .. "/aa.pal" end
        if file_exists(aa_path) then
            palette = load_palette(aa_path)
        end
    end

    -- Last resort: EGA fallback colors
    if not palette then
        palette = ega_palette()
    end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image", image = img,
        description = string.format("%s - %dx%d, 16 colors", label, w, h)
    }
end

-- Resource loader
function engine.load_resource(game_path, resource_id, palette_id)
    local is_cd = has_picture_dir(game_path)

    -- Resolve a palette resource id (pal_<NAME>) to a .pal file path.
    local function resolve_pal_path(pid)
        if not pid or pid == "" then return nil end
        local name = pid:match("^pal_(.+)$")
        if not name then return nil end
        return find_file(picture_dir(game_path, is_cd), name .. ".pal")
    end

    local function get_override_pal_path()
        return resolve_pal_path(palette_id)
    end

    -- CD version resource: bg_BASENAME (named backgrounds in PICTURE/)
    local cd_base = resource_id:match("^bg_(.+)$")
    if cd_base and is_cd then
        local pic_dir = picture_dir(game_path, true)
        local pic_path = find_file(pic_dir, cd_base .. ".pic")

        -- Use override palette or find matching .PAL
        local pal_path = get_override_pal_path()
        if not pal_path then
            pal_path = scene_palette(game_path, resource_id, is_cd)
        end

        return load_pic_image(pic_path, pal_path, cd_base)
    end

    -- Floppy version resource: bg_roomNN (rooms described by ROOMn.ROM)
    local floppy_room = resource_id:match("^bg_(room.+)$")
    if floppy_room and not is_cd then
        local _, pic = parse_rom(game_path, room_rom_base(floppy_room))
        if not pic or #pic == 0 then
            return { type = "text", text = "No background for " .. floppy_room }
        end

        local pic_path = find_file(game_path, pic .. ".pic")
        if not pic_path then
            return { type = "text", text = "Missing .pic file: " .. pic }
        end

        local pal_path = get_override_pal_path()
        if not pal_path then pal_path = scene_palette(game_path, resource_id, is_cd) end
        return load_pic_image(pic_path, pal_path, pic)
    end

    -- Palette resource: pal_<NAME>
    local pal_arg = resource_id:match("^pal_(.+)$")
    if pal_arg then
        local pal_path = find_file(picture_dir(game_path, is_cd), pal_arg .. ".pal")
        if pal_path and file_exists(pal_path) then
            local palette = load_palette(pal_path)
            if palette then
                -- Render palette swatch
                local swatch_w = 128
                local swatch_h = 32
                local pixels = {}
                for y = 0, swatch_h - 1 do
                    for x = 0, swatch_w - 1 do
                        pixels[y * swatch_w + x + 1] = math.floor(x * 16 / swatch_w)
                    end
                end
                local img = image_create_indexed(swatch_w, swatch_h, pixels, palette)
                return {
                    type = "image", image = img,
                    description = string.format("Palette: %s (16 colors)", pal_arg)
                }
            end
        end
        return { type = "text", text = "Palette not found: " .. pal_arg }
    end

    -- NSP sprite resource
    local nsp_base = resource_id:match("^nsp_(.+)$")
    if nsp_base then
        local nsp_dir = room_dir(game_path, is_cd)
        local nsp_path = find_file(nsp_dir, nsp_base .. ".nsp")
        if not nsp_path then
            return { type = "text", text = "NSP file not found: " .. nsp_base }
        end
        local pal_path = get_override_pal_path() or scene_palette(game_path, resource_id, is_cd)

        local handles, err = load_nsp(nsp_path, pal_path)
        if not handles then
            return { type = "text", text = "Failed to load NSP: " .. (err or "unknown error") }
        end

        local pal_info = pal_path and pal_path:match("[^/]+$") or "EGA fallback"
        if #handles == 1 then
            return {
                type = "image",
                image = handles[1],
                description = string.format("%s - 1 frame, palette: %s", nsp_base, pal_info),
            }
        else
            local anim = animation_create(handles, 150)
            return {
                type = "animation",
                animation = anim,
                description = string.format("%s - %d frames, palette: %s", nsp_base, #handles, pal_info),
            }
        end
    end

    return nil
end

-- Use the same resolver for preview, export and the palette selector.
function engine.default_palette(game_path, resource_id)
    local path = scene_palette(game_path, resource_id or "", has_picture_dir(game_path))
    local name = path and path:match("([^/]+)%.[Pp][Aa][Ll]$")
    return name and ("pal_" .. name) or nil
end

return engine

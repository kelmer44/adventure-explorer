-- ============================================================================
-- Adventure Explorer - Engine Script: Dark Seed (Cyberdreams, 1992)
-- ============================================================================
-- Floppy: roomN.pic/roomN.pal/roomN.rom in root directory
-- CD: named .PIC/.PAL files in PICTURE/ subdirectory, .NSP/.OBT in ROOM/
-- Image format: u16be width, u16be height, then 4-bit nibble RLE, 16 colors
-- Palette: 16 × 3 bytes (6-bit VGA, scaled by <<2)
-- ============================================================================

local engine = {}
engine.name        = "Dark Seed"
engine.id          = "darkseed"
engine.description = "Dark Seed (1992, Cyberdreams)"
engine.version     = "2.0"

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
    local path = game_path .. "/" .. name
    if file_exists(path) then return path end
    path = game_path .. "/" .. name:upper()
    if file_exists(path) then return path end
    path = game_path .. "/" .. name:lower()
    if file_exists(path) then return path end
    return nil
end

-- Check for CD version (has PICTURE/ subdirectory)
local function has_picture_dir(game_path)
    local sub = list_files(game_path .. "/PICTURE")
    if sub and #sub > 0 then return true end
    sub = list_files(game_path .. "/picture")
    if sub and #sub > 0 then return true end
    return false
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

    -- Check for room files in root (floppy version)
    for room = 0, 5 do
        local base = "room" .. room
        if find_file(game_path, base .. ".pic") then return true end
    end

    -- Check for PICTURE/ subdirectory (CD version)
    if has_picture_dir(game_path) then return true end

    return false
end

-- Resource tree
function engine.get_resources(game_path)
    local resources = {}
    local is_cd = has_picture_dir(game_path)

    -- CD version: scan PICTURE/ for .PIC and .PAL files
    if is_cd then
        local pic_dir = game_path .. "/PICTURE"
        local files = list_files(pic_dir)
        if not files or #files == 0 then
            pic_dir = game_path .. "/picture"
            files = list_files(pic_dir)
        end

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

    -- Floppy version: scan root for roomN.pic files
    local rooms_cat = {
        id = "floppy_rooms",
        name = "Rooms (Floppy)",
        type = "category",
        children = {}
    }
    local floppy_pals = {
        id = "floppy_palettes",
        name = "Palettes (Floppy)",
        type = "category",
        children = {}
    }

    for room = 0, 80 do
        local base
        if room == 20 or room == 22 then base = "room19"
        else base = "room" .. room end

        local pic_path = find_file(game_path, base .. ".pic")
        if pic_path then
            rooms_cat.children[#rooms_cat.children + 1] = {
                id   = "bg_" .. room,
                name = string.format("Room %d", room),
                type = "image"
            }
            local pal_path = find_file(game_path, base .. ".pal")
            if pal_path then
                floppy_pals.children[#floppy_pals.children + 1] = {
                    id   = "pal_" .. room,
                    name = string.format("Room %d palette", room),
                    type = "palette"
                }
            end
        end
    end

    if #rooms_cat.children > 0 then
        rooms_cat.name = string.format("Rooms (%d)", #rooms_cat.children)
        resources[#resources + 1] = rooms_cat
    end
    if #floppy_pals.children > 0 then
        floppy_pals.name = string.format("Palettes (%d)", #floppy_pals.children)
        resources[#resources + 1] = floppy_pals
    end

    -- Scan for .NSP sprite files (in root for floppy, ROOM/ for CD)
    local nsp_dir = game_path
    if is_cd then
        local try_room = game_path .. "/ROOM"
        if file_exists(try_room .. "/ROOM0.NSP") or file_exists(try_room .. "/room0.nsp") then
            nsp_dir = try_room
        end
    end

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

-- Find a palette for an NSP sprite by name (ROOMN.NSP -> ROOMN.PAL)
local function find_nsp_palette(game_path, nsp_base, is_cd)
    -- Try exact match in same directory
    local function try(dir, base)
        local p = find_file(dir, base .. ".pal")
        if p then return p end
        p = dir .. "/" .. base .. ".PAL"
        if file_exists(p) then return p end
        return nil
    end

    if is_cd then
        local room_dir = game_path .. "/ROOM"
        local p = try(room_dir, nsp_base)
        if p then return p end
        -- Try PICTURE/ directory
        local pic_dir = game_path .. "/PICTURE"
        if not file_exists(pic_dir) then pic_dir = game_path .. "/picture" end
        p = try(pic_dir, nsp_base)
        if p then return p end
    else
        local p = try(game_path, nsp_base)
        if p then return p end
    end
    return nil
end

-- ── Background image loader ──────────────────────────────────────
-- Load a .PIC background image with optional .PAL palette
local function load_pic_image(pic_path, pal_path, label)
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

    -- Resolve palette override path
    local function get_override_pal_path()
        if not palette_id or palette_id == "" then return nil end
        local pal_base = palette_id:match("^pal_(.+)$")
        if not pal_base then return nil end

        if is_cd then
            -- CD: pal_base is the .PAL basename (e.g. "BEDROOM")
            local pic_dir = game_path .. "/PICTURE"
            if not file_exists(pic_dir) then pic_dir = game_path .. "/picture" end
            local try_pal = pic_dir .. "/" .. pal_base .. ".PAL"
            if file_exists(try_pal) then return try_pal end
            try_pal = pic_dir .. "/" .. pal_base .. ".pal"
            if file_exists(try_pal) then return try_pal end
        else
            -- Floppy: pal_base is room number
            local room_num = tonumber(pal_base)
            if room_num then
                local base
                if room_num == 20 or room_num == 22 then base = "room19"
                else base = "room" .. room_num end
                return find_file(game_path, base .. ".pal")
            end
        end
        return nil
    end

    -- CD version resource: bg_BASENAME
    local cd_base = resource_id:match("^bg_(.+)$")
    if cd_base and is_cd then
        local pic_dir = game_path .. "/PICTURE"
        if not file_exists(pic_dir .. "/" .. cd_base .. ".PIC") then
            pic_dir = game_path .. "/picture"
        end

        local pic_path = pic_dir .. "/" .. cd_base .. ".PIC"
        if not file_exists(pic_path) then
            pic_path = pic_dir .. "/" .. cd_base .. ".pic"
        end

        -- Use override palette or find matching .PAL
        local pal_path = get_override_pal_path()
        if not pal_path then
            local try_pal = pic_dir .. "/" .. cd_base .. ".PAL"
            if file_exists(try_pal) then
                pal_path = try_pal
            else
                try_pal = pic_dir .. "/" .. cd_base .. ".pal"
                if file_exists(try_pal) then pal_path = try_pal end
            end
        end

        return load_pic_image(pic_path, pal_path, cd_base)
    end

    -- Floppy version resource: bg_N
    local room_str = resource_id:match("^bg_(%d+)$")
    if room_str then
        local room_num = tonumber(room_str)
        local base
        if room_num == 20 or room_num == 22 then base = "room19"
        else base = "room" .. room_num end

        local pic_path = find_file(game_path, base .. ".pic")
        if not pic_path then
            return { type = "text", text = "No .pic file for room " .. room_num }
        end

        local pal_path = get_override_pal_path() or find_file(game_path, base .. ".pal")
        return load_pic_image(pic_path, pal_path, "Room " .. room_num)
    end

    -- Palette resource
    local pal_arg = resource_id:match("^pal_(.+)$")
    if pal_arg then
        local pal_path
        if is_cd then
            local pic_dir = game_path .. "/PICTURE"
            if not file_exists(pic_dir) then pic_dir = game_path .. "/picture" end
            pal_path = pic_dir .. "/" .. pal_arg .. ".PAL"
            if not file_exists(pal_path) then pal_path = pic_dir .. "/" .. pal_arg .. ".pal" end
        else
            local room_num = tonumber(pal_arg)
            if room_num then
                local base = (room_num == 20 or room_num == 22) and "room19" or ("room" .. room_num)
                pal_path = find_file(game_path, base .. ".pal")
            end
        end
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
        local nsp_dir = game_path
        if is_cd then
            local try_room = game_path .. "/ROOM"
            if file_exists(try_room .. "/" .. nsp_base .. ".NSP") or
               file_exists(try_room .. "/" .. nsp_base:lower() .. ".nsp") then
                nsp_dir = try_room
            end
        end
        local nsp_path = find_file(nsp_dir, nsp_base .. ".nsp")
        if not nsp_path then
            return { type = "text", text = "NSP file not found: " .. nsp_base }
        end
        local pal_path = find_nsp_palette(game_path, nsp_base, is_cd)

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

return engine

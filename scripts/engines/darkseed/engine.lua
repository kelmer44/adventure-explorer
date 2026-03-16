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

    -- CD version: scan PICTURE/ for .PIC files
    if is_cd then
        local pic_dir = game_path .. "/PICTURE"
        local files = list_files(pic_dir)
        if not files or #files == 0 then
            pic_dir = game_path .. "/picture"
            files = list_files(pic_dir)
        end

        if files and #files > 0 then
            -- Collect .PIC files
            local pic_files = {}
            for _, fname in ipairs(files) do
                if fname:upper():match("%.PIC$") then
                    pic_files[#pic_files + 1] = fname
                end
            end
            table.sort(pic_files)

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
                        id = "cd_" .. fname,
                        name = base,
                        type = "image"
                    }
                end

                resources[#resources + 1] = cat
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
        end
    end

    if #rooms_cat.children > 0 then
        rooms_cat.name = string.format("Rooms (%d)", #rooms_cat.children)
        resources[#resources + 1] = rooms_cat
    end

    return resources
end

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
function engine.load_resource(game_path, resource_id)
    -- CD version resource: cd_FILENAME.PIC
    local cd_name = resource_id:match("^cd_(.+)$")
    if cd_name then
        local pic_dir = game_path .. "/PICTURE"
        if not file_exists(pic_dir .. "/" .. cd_name) then
            pic_dir = game_path .. "/picture"
        end

        local pic_path = pic_dir .. "/" .. cd_name
        -- Find matching .PAL file
        local base = cd_name:match("^(.+)%.[Pp][Ii][Cc]$") or cd_name
        local pal_path = nil
        local try_pal = pic_dir .. "/" .. base .. ".PAL"
        if file_exists(try_pal) then
            pal_path = try_pal
        else
            try_pal = pic_dir .. "/" .. base .. ".pal"
            if file_exists(try_pal) then pal_path = try_pal end
        end

        return load_pic_image(pic_path, pal_path, base)
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

        local pal_path = find_file(game_path, base .. ".pal")
        return load_pic_image(pic_path, pal_path, "Room " .. room_num)
    end

    return nil
end

return engine

-- ============================================================================
-- Adventure Explorer - Engine Script: Igor: Objective Uikokahonia
-- ============================================================================
-- Pendulo Studios, 1994. DOS/Borland Overlay architecture.
-- Resources are packed inside IGOR.DAT (Borland "FBOV" overlay, 11 199 335 B).
--
-- The original ScummVM engine uses IGOR.TBL (a separate resource index file)
-- to locate data inside the overlay, but that file is absent from most
-- distributions.  This script uses a PRE-COMPUTED offset table derived from
-- full binary analysis of the English floppy IGOR.DAT.
--
-- Data layout per room:
--   VGA palette : 768 bytes (256 x RGB, 6-bit, all values 0-63)
--   Code gap    : variable (0-20 KB of TP overlay code between pal & pixels)
--   Raw pixels  : W x H bytes, indexed, row-major
--
-- Pixel blocks were found by scanning for contiguous rows of plausible pixel
-- data; palettes were matched by searching backward for the nearest valid
-- 768-byte all-<=63 VGA palette.  Entries flagged "~" have approximate/fallback
-- palettes because no palette was found within 100 KB before the image data.
--
-- Room names for the first rooms come from ScummVM resource_ids.h constants.
--
-- Reference: https://github.com/dreammaster/scummvm/tree/igor/engines/igor
-- ============================================================================

local engine = {}
engine.name        = "Igor: Objective Uikokahonia"
engine.id          = "igor"
engine.description = "Pendulo Studios (1994) - DOS floppy/CD"
engine.version     = "3.0"

-- ============================================================================
-- Constants
-- ============================================================================

local PAL_SIZE = 768        -- 256 colours x 3 bytes (R, G, B)
local IMG_W    = 320

-- ============================================================================
-- Pre-computed background offset table
-- Derived from binary analysis of IGOR.DAT (English floppy, 11 199 335 bytes).
-- Each entry: { name, pal_offset, img_offset, height }
--
-- 320 x height raw indexed pixels per image.
-- ============================================================================

local ROOMS = {
    -- ===================== Early data blocks (before first room) =============
    -- These appear in the overlay code section; palette is approximate.
    {"Data Block 1",                       421029,      35200, 161},
    {"Data Block 2",                       421029,      87680, 102},
    {"Data Block 3",                       421029,     120640, 198},
    {"Data Block 4",                       421029,     185280, 148},
    {"Data Block 5",                       421029,     263040, 200},
    {"Data Block 6",                       421029,     327680, 143},
    {"Data Block 7",                       421029,     379200, 133},

    -- ===================== Named rooms (ScummVM resource_ids.h) ==============
    {"Philip's Room",                      421029,     422080, 200},
    {"Physics Classroom",                  486549,     487360, 200},
    {"Chemistry Classroom",                552024,     552960, 200},
    {"College Stairs (2nd Floor)",         617495,     618560, 200},
    {"College Stairs (1st Floor)",         682966,     683840, 200},
    {"Corridor (Miss Barrymore)",          748437,     749440, 200},
    {"Corridor (Announcement Board)",      817152,     817920, 194},
    {"Corridor (Sharon & Michael)",        879379,     881600, 200},
    {"Corridor (Caroline)",                945439,     966720, 199},
    {"Corridor (Lucas)",                   945439,    1030720, 200},
    {"Corridor (Margaret)",               1115731,    1154560, 152},
    {"College Lockers ~",                 1115731,    1259200, 160},
    {"Women's Toilets ~",                 1115731,    1338240, 141},
    {"Men's Toilets ~",                   1523379,    1383680, 200},
    {"Outside College ~",                 1523379,    1450240, 152},
    {"Laboratory",                        1523379,    1553920, 165},
    {"Margaret's Room",                   1628740,    1630400, 200},
    {"Map ~",                             1628740,    1729280, 159},
    {"Spring Bridge ~",                   1857052,    1807040, 155},
    {"Spring Rock",                       1857052,    1865920, 153},
    {"Bell Church",                       1855765,    1931520, 150},
    {"Tobias' Office",                    1979814,    1987840, 157},
    {"Church Mosaic",                     2053413,    2061120, 152},
    {"Inside Church",                     2131319,    2153920, 166},
    {"Church Puzzle",                     2227614,    2253120, 183},
    {"Outside Church",                    2227612,    2314240, 161},

    -- ===================== Additional game backgrounds =======================
    {"Background 34",                     2385396,    2387840, 116},
    {"Background 35",                     2386514,    2429440, 162},
    {"Background 36",                     2505268,    2576320, 175},
    {"Library",                           2647030,    2650560, 141},
    {"Spring Bridge (Intro)",             2647030,    2706560, 157},
    {"Shareware Screen 1",               2789650,    2795200, 156},
    {"Shareware Screen 2",               2860589,    2864960, 160},
    {"Shareware Screen 3",               2931035,    2935360, 160},
    {"Shareware Screen 4",               3003737,    3008320, 155},
    {"Shareware Screen 5",               3075377,    3080000, 155},
    {"Shareware Screen 6",               3146967,    3151360, 156},
    {"Shareware Screen 7",               3218251,    3222720, 153},
    {"Title Screen",                     3288446,    3292800, 155},
    {"Pendulo Studios",                  3359454,    3363840, 153},
    {"Graphic Adventure",                3428887,    3433280, 156},
    {"Presents",                         3499983,    3504640, 151},
    {"Optik Software",                   3569032,    3573440, 155},
    {"Roman Numbers Paper",              3638564,    3642880, 153},
    {"Newspaper",                        3707857,    3712320, 150},
    {"Photo (Harrison & Margaret)",      3775875,    3780480, 152},
    {"Park",                             3844749,    3855360, 152},

    -- ===================== Extended rooms / alternate states ==================
    {"Admin (Secretary Room)",           5876805,    5883520, 153},
    {"Dean Pepper's Office",             5953494,    5960640, 155},
    {"Student Dormitory",                6045969,    6061120, 127},
    {"Background 58",                    6045969,    6106240, 167},
    {"Background 59",                    6159520,    6160960, 117},
    {"Background 60",                    6159998,    6200960, 165},
    {"Background 61",                    6274003,    6288320, 163},
    {"Background 62",                    6358236,    6366400, 127},
    {"Background 63",                    6357058,    6409600, 156},
    {"Background 64",                    6476192,    6487040, 154},
    {"Background 65",                    6552976,    6567680, 154},
    {"Background 66",                    6631534,    6636160, 154},
    {"Background 67",                    6702071,    6716800, 154},
    {"Background 68",                    6789022,    6811840, 157},
    {"Background 69",                    6878997,    6892160, 155},
    {"Background 70",                    6961491,    6978560, 105},
    {"Background 71",                    6961491,    7014720, 155},
    {"Background 72",                    7081358,    7096960, 155},
    {"Background 73",                    7190977,    7211520, 156},
    {"Background 74",                    7261816,    7308480, 156},
    {"Background 75",                    7384119,    7440320, 167},
    {"Background 76",                    7513740,    7604800, 156},
    {"Background 77 ~",                  7513740,    7656960, 182},
    {"Background 78 ~",                  7779541,    7717440, 151},
    {"Background 79",                    7779541,    7785280, 153},
    {"Background 80",                    7854029,    7868160, 153},
    {"Background 81",                    7931945,    7934400, 134},
    {"Background 82",                    7933063,    7979520, 151},
    {"Background 83",                    8044164,    8073280, 135},
    {"Background 84",                    8118943,    8122880, 112},
    {"Background 85",                    8208182,    8212480, 159},
    {"Background 86",                    8286990,    8292800, 154},
    {"Background 87",                    8286990,    8342400, 154},
    {"Background 88 ~",                  8286990,    8392640, 167},
    {"Background 89 ~",                  8518763,    8446400, 163},
    {"Background 90",                    8518763,    8523200, 156},
    {"Background 91",                    8599403,    8621120, 170},
    {"Background 92",                    8598227,    8678080, 159},
    {"Background 93",                    8777516,    8790720, 161},
    {"Background 94",                    8842429,    8845440, 168},
    {"Background 95",                    9000174,    9032640, 161},
    {"Background 96",                    9108639,    9119040, 116},
    {"Background 97",                    9108639,    9157120, 166},
    {"Background 98",                    9260423,    9277120, 178},
    {"Background 99",                    9259189,    9336320, 159},
    {"Background 100 ~",                 9259189,    9434880, 183},
    {"Background 101 ~",                 9568764,    9495680, 161},
    {"Background 102",                   9568764,    9584960, 159},
    {"Background 103",                   9652152,    9679680, 162},
    {"Background 104",                   9652150,    9734080, 155},
    {"Background 105",                   9812011,    9872640, 154},
    {"Background 106 ~",                 9812011,    9924160, 168},
    {"Background 107",                  10004120,   10054400, 113},
    {"Background 108",                  10004120,   10093120, 172},
    {"Background 109",                  10148547,   10153280, 133},
    {"Background 110",                  10148547,   10198080, 150},
    {"Background 111 ~",                10148547,   10248320, 159},
    {"Background 112 ~",                10148547,   10300480, 200},
    {"Background 113 ~",                10993073,   10689600, 121},
    {"Background 114 ~",                10993073,   10728640, 162},
    {"Background 115 ~",                10993073,   10780800, 166},
    {"Background 116 ~",                10993073,   10834240, 152},
    {"Background 117 ~",                10993073,   10886400, 162},
    {"Background 118 ~",                10993073,   10947840, 138},
    {"Background 119",                  10993073,   10994240, 160},
    {"Background 120",                  10993073,   11046080, 146},
    {"Background 121 ~",                10993073,   11095680, 135},
}

-- ============================================================================
-- File helper
-- ============================================================================

local function find_dat(game_path)
    local candidates = {
        game_path .. "/IGOR.DAT",
        game_path .. "/igor.dat",
    }
    for _, p in ipairs(candidates) do
        if file_exists(p) then return p end
    end
    return nil
end

-- Expand a 6-bit VGA value to 8-bit:  (v << 2) | (v >> 4)
local function expand6(v)
    return math.floor(v * 4) + math.floor(v / 16)
end

-- ============================================================================
-- engine.detect(game_path)
-- ============================================================================

function engine.detect(game_path)
    return find_dat(game_path) ~= nil
end

-- ============================================================================
-- engine.get_resources(game_path)
-- Returns the resource tree instantly from the hardcoded table.
-- ============================================================================

function engine.get_resources(game_path)
    local dat_path = find_dat(game_path)
    if not dat_path then
        return {{id="err", name="IGOR.DAT not found", type="category", children={}}}
    end

    -- Categorise entries
    local early_children  = {}   -- blocks 1-7
    local room_children   = {}   -- named rooms 8-33
    local game_children   = {}   -- game screens / shareware / title 34-54
    local extra_children  = {}   -- remaining 55+

    for i, room in ipairs(ROOMS) do
        local node = {
            id   = "bg_" .. i,
            name = room[1],
            type = "image",
        }

        if i <= 7 then
            early_children[#early_children + 1] = node
        elseif i <= 33 then
            room_children[#room_children + 1] = node
        elseif i <= 54 then
            game_children[#game_children + 1] = node
        else
            extra_children[#extra_children + 1] = node
        end
    end

    local root = {}

    if #early_children > 0 then
        root[#root + 1] = {
            id       = "cat_early",
            name     = "Early Data Blocks (1-7)",
            type     = "category",
            children = early_children,
        }
    end

    root[#root + 1] = {
        id       = "cat_rooms",
        name     = "Room Backgrounds (8-33)",
        type     = "category",
        children = room_children,
    }

    if #game_children > 0 then
        root[#root + 1] = {
            id       = "cat_game",
            name     = "Game / Title Screens (34-54)",
            type     = "category",
            children = game_children,
        }
    end

    if #extra_children > 0 then
        root[#root + 1] = {
            id       = "cat_extra",
            name     = "Extra Backgrounds (55-" .. #ROOMS .. ")",
            type     = "category",
            children = extra_children,
        }
    end

    return root
end

-- ============================================================================
-- engine.load_resource(game_path, resource_id, palette_id)
-- Loads a background image by index from the hardcoded table.
-- ============================================================================

function engine.load_resource(game_path, resource_id, palette_id)
    -- Parse index from id like "bg_12"
    local idx_str = resource_id:match("^bg_(%d+)$")
    if not idx_str then
        return {type="text", text="Invalid resource id: " .. tostring(resource_id)}
    end
    local idx = tonumber(idx_str)
    if idx < 1 or idx > #ROOMS then
        return {type="text", text="Background index out of range: " .. idx}
    end

    local room    = ROOMS[idx]
    local name    = room[1]
    local pal_off = room[2]
    local img_off = room[3]
    local img_h   = room[4]
    local img_size = IMG_W * img_h

    local dat_path = find_dat(game_path)
    if not dat_path then
        return {type="text", text="IGOR.DAT not found"}
    end

    local fh = file_open(dat_path)
    if not fh then
        return {type="text", text="Cannot open IGOR.DAT"}
    end

    -- Read palette (768 bytes) and image pixels
    local pal_raw = file_read(fh, pal_off, PAL_SIZE)
    local img_raw = file_read(fh, img_off, img_size)
    file_close(fh)

    if not pal_raw or #pal_raw < PAL_SIZE then
        return {type="text", text="Failed to read palette for " .. name}
    end
    if not img_raw or #img_raw < img_size then
        return {type="text", text="Failed to read image for " .. name}
    end

    -- Expand 6-bit VGA palette to 8-bit RGB (768-entry table, 1-based)
    local palette = {}
    for i = 1, PAL_SIZE do
        palette[i] = expand6(pal_raw:byte(i))
    end

    -- Build pixel array (1-based)
    local pixels = {}
    for i = 1, img_size do
        pixels[i] = img_raw:byte(i)
    end

    local img = image_create_indexed(IMG_W, img_h, pixels, palette)
    if not img then
        return {type="text", text="image_create_indexed failed for " .. name}
    end

    return {
        type        = "image",
        image       = img,
        description = string.format(
            "%s  |  %dx%d  |  VGA 6-bit palette  |  pal@%d  img@%d",
            name, IMG_W, img_h, pal_off, img_off),
    }
end

-- ============================================================================
return engine

-- ============================================================================
-- Adventure Explorer - Engine Script: Igor: Objective Uikokahonia
-- ============================================================================
-- Pendulo Studios, 1994. DOS / Borland Overlay architecture.
--
-- Supports BOTH versions:
--   Floppy (Spanish): IGOR.DAT 11,199,335 bytes (FBOV overlay container)
--   CD     (Spanish): IGOR.EXE  9,115,648 bytes (NE executable with embedded
--                     resources) + IGOR.DAT 61,682,719 bytes (speech)
--
-- Resource offsets:
--   Floppy: binary analysis of the 11.2 MB Spanish floppy IGOR.DAT
--           (the ScummVM resource_en_demo100.h is for a 4 MB English demo
--            and is NOT compatible with this file)
--   CD:     scummvm-create-igortbl/resource_sp_cdrom.h (offsets into IGOR.EXE)
--
-- Data formats:
--   IMG_  : Raw 8bpp indexed pixels, 320 x H, row-major
--   PAL_  : VGA DAC palette, 768 bytes (256 x RGB, 6-bit values 0-63)
--           or 624 bytes (208 colours) / 720 bytes (240 colours)
--   MSK_  : RLE-compressed walk mask (code_byte + u16LE length, fills 320x144)
--   BOX_  : 1280 bytes = 256 x 5-byte entries (area, object, y1Lum, y2Lum, dLum)
--   FRM_  : Raw sprite frame data (walking sprites = 1500 bytes/frame)
--   TXT_  : Text strings (Spanish text XOR-encrypted with 0x6D)
-- ============================================================================

local engine = {}
engine.name        = "Igor: Objective Uikokahonia"
engine.id          = "igor"
engine.description = "Pendulo Studios (1994) - DOS floppy & CD"
engine.version     = "5.0"

-- ============================================================================
-- Binary helpers (no bit32 in LuaJ 3.0.1)
-- ============================================================================

local function u8(data, pos)    return data:byte(pos) end
local function u16le(data, pos) return data:byte(pos) + data:byte(pos+1) * 256 end

-- Expand 6-bit VGA (0-63) to 8-bit (0-255): (v << 2) | (v >> 4)
local function expand6(v)
    return math.floor(v * 4) + math.floor(v / 16)
end

-- ============================================================================
-- Constants
-- ============================================================================

local PAL_FULL  = 768   -- 256 colours x 3
local IMG_W     = 320
local IMG_H_STD = 144   -- standard game area height (CD rooms)

-- ============================================================================
-- Version detection
-- ============================================================================

local VER_FLOPPY = "floppy"
local VER_CD     = "cd"

local function find_data_file(game_path)
    -- CD version: resources in IGOR.EXE (9,115,648 bytes)
    local exe_candidates = {
        game_path .. "/IGOR.EXE",
        game_path .. "/igor.exe",
    }
    for _, p in ipairs(exe_candidates) do
        if file_exists(p) then
            local fh = file_open(p)
            if fh then
                local sz = file_size(fh)
                file_close(fh)
                if sz == 9115648 then
                    return p, VER_CD
                end
            end
        end
    end

    -- Floppy version: resources in IGOR.DAT (11,199,335 bytes)
    local dat_candidates = {
        game_path .. "/IGOR.DAT",
        game_path .. "/igor.dat",
    }
    for _, p in ipairs(dat_candidates) do
        if file_exists(p) then
            local fh = file_open(p)
            if fh then
                local sz = file_size(fh)
                file_close(fh)
                if sz == 11199335 then
                    return p, VER_FLOPPY
                end
            end
        end
    end

    -- Fallback: any IGOR.DAT or IGOR.EXE
    for _, p in ipairs(dat_candidates) do
        if file_exists(p) then return p, VER_FLOPPY end
    end
    for _, p in ipairs(exe_candidates) do
        if file_exists(p) then return p, VER_CD end
    end
    return nil, nil
end

-- ============================================================================
-- RESOURCE TABLES
-- ============================================================================
--
-- CD rooms: { name, img_off, img_size, pal_off, pal_size,
--             msk_off, msk_size, box_off, box_size, txt_off, txt_size }
--
-- Floppy rooms: { name, img_off, img_size, pal_off, pal_size,
--                 0, 0, 0, 0, 0, 0 }
--   (no mask/box/text data available for the Spanish floppy version)
--
-- Fullscreen images: { name, img_off, img_size, pal_off, pal_size }
-- ============================================================================

-- ===== CD version (Spanish) - offsets into IGOR.EXE 9,115,648 bytes =====
-- From scummvm-create-igortbl/resource_sp_cdrom.h
local CD_ROOMS = {
    {"Philip's Room",               0x1a4f1c, 46080, 0x1b031c, 768,  0x1b061c, 3,    0x1b061f, 1280, 0x1a4a75, 1191},
    {"Physics Classroom",           0x3a5a17, 46080, 0x3b0e17, 624,  0x3b1087, 1557, 0x3b169c, 1280, 0x3a55a2, 1141},
    {"Chemistry Classroom",         0x3b9173, 46080, 0x3c4573, 624,  0x3c47e3, 1980, 0x3c4f9f, 1280, 0x3b8ca2, 1233},
    {"Park",                        0x3f723d, 46080, 0x40263d, 624,  0x4028ad, 4728, 0x403b25, 1280, 0x3f6ba2, 1691},
    {"College Stairs (2nd Floor)",  0x4115cf, 46080, 0x41c9cf, 624,  0x41cc3f, 4128, 0x41dc5f, 1280, 0x410fb3, 1564},
    {"College Stairs (1st Floor)",  0x43577d, 46080, 0x440b7d, 624,  0x440ded, 2934, 0x441963, 1280, 0x4352b3, 1226},
    {"Corridor (Miss Barrymore)",   0x44e61f, 46080, 0x459a1f, 624,  0x459c8f, 2484, 0x45a643, 1280, 0x44e0a2, 1405},
    {"Corridor (Announcement Bd)",  0x466062, 46080, 0x471462, 624,  0x4716d2, 3117, 0x4722ff, 1280, 0x465ba2, 1216},
    {"Corridor (Sharon & Michael)", 0x47f3d5, 46080, 0x48a7d5, 624,  0x48aa45, 3144, 0x48b68d, 1280, 0x47eea2, 1331},
    {"Corridor (Caroline)",         0x49c49d, 46080, 0x4a789d, 624,  0x4a7b0d, 2151, 0,       0,    0x49bcb3, 2026},
    {"Corridor (Lucas)",            0x4b34d7, 46080, 0x4be8d7, 624,  0x4beb47, 3297, 0x4bf828, 1280, 0x4b2fa2, 1333},
    {"Corridor (Margaret)",         0x4dafca, 46080, 0x4e63ca, 624,  0x4e663a, 3690, 0x4e74a4, 1280, 0x4da9b3, 1559},
    {"College Lockers",             0x4f1dbb, 46080, 0x4fd1bb, 624,  0x4fd42b, 2235, 0x4fdce6, 1280, 0x4f17a2, 1561},
    {"Women's Toilets",             0x511824, 46080, 0x51cc24, 624,  0x51ce94, 2022, 0x51d67a, 1280, 0x5111a2, 1666},
    {"Men's Toilets",               0x51e8e4, 46080, 0x529ce4, 624,  0x529f54, 1980, 0x52a710, 1280, 0x51e3a2, 1346},
    {"Outside College",             0x538ac2, 46080, 0x543ec2, 624,  0x544132, 4974, 0x5454a0, 1280, 0x5383a2, 1824},
    {"Margaret's Room",             0x55f022, 46080, 0x56a422, 768,  0x56a722, 3,    0x56a725, 1280, 0x55e975, 1709},
    {"Laboratory",                  0x57e06c, 46080, 0x58946c, 624,  0x5896dc, 2130, 0x589f2e, 1280, 0x57daa2, 1482},
    {"Map",                         0x5906a1, 46080, 0x59baa1, 624,  0x59bd11, 1809, 0x59c422, 1280, 0x5902a2, 1023},
    {"Tobias' Office",              0x5b13c6, 46080, 0x5bc7c6, 624,  0x5bca36, 1455, 0x5bcfe5, 1280, 0x5b0ba2, 2084},
    {"Bell Church",                 0x5cde24, 46080, 0x5d9224, 624,  0x5d9494, 861,  0x5d97f1, 1280, 0x5cd9a2, 1154},
    {"Admin (Secretary Room)",      0x7143fa, 46080, 0x71f7fa, 624,  0x71fa6a, 2400, 0x7203ca, 1280, 0x713da2, 1624},
    {"Dean Pepper's Office",        0x738c4e, 46080, 0x74404e, 624,  0x7442be, 2745, 0x744d77, 1280, 0x7385a2, 1708},
    {"Student Dormitory",           0x7b1e66, 46080, 0x7bd266, 624,  0x7bd566, 6699, 0x7bef91, 1280, 0x7b18a2, 1476},
    {"Spring Bridge (Intro)",       0x7d698f, 46080, 0x7e1d8f, 720,  0, 0, 0, 0,                     0x7d6264, 1835},
    {"Spring Rock",                 0x7e2de6, 46080, 0x7ee1e6, 720,  0x7ee4b6, 3117, 0x7ef0e3, 1280, 0x7e28a2, 1348},
    {"Spring Bridge",               0x6c0eda, 46080, 0x6cc2da, 624,  0x6cc5aa, 3936, 0x6cd50a, 1280, 0x6c0aa2, 1080},
}

-- CD: full-screen images (320x200 = 64000 bytes)
local CD_FULLSCREEN = {
    {"Pendulo Studios",    0x7efa6e, 64000, 0x7ef76e, 768},
    {"Graphic Adventure",  0x7ff86e, 64000, 0x7ff56e, 768},
    {"Presents",           0x80f66e, 64000, 0x80f36e, 768},
    {"Optik Software",     0x81f46e, 64000, 0x81f16e, 768},
}

-- CD: UI and sprite resources
local CD_UI = {
    {"Verbs Panel (320x12)",     0x848ae0, 3840},
    {"Inventory Panel (320x30)", 0x89a298, 9600},
    {"Objects Sheet (320x150)",  0x89c818, 48000},
    {"Meanwhile (320x144)",      0x56aeb7, 46080},
}

-- CD: Igor walking sprites
local CD_IGOR_SPRITES = {
    {"Igor Dir Back (set 1)",  0x83bdc3, 10500},
    {"Igor Dir Right (set 1)", 0x83e6c7, 13500},
    {"Igor Dir Front (set 1)", 0x841b83, 10500},
    {"Igor Dir Left (set 1)",  0x844487, 13500},
    {"Igor Head (set 1)",      0x847943, 3696},
    {"Igor Dir Back (set 2)",  0x82f0c3, 10500},
    {"Igor Dir Right (set 2)", 0x8319c7, 13500},
    {"Igor Dir Front (set 2)", 0x834e83, 10500},
    {"Igor Dir Left (set 2)",  0x837787, 13500},
    {"Igor Head (set 2)",      0x83ac43, 3696},
}

-- CD: Text resources
local CD_TEXTS = {
    {"Main Text Table", 0x8499e0, 28028},
}

-- ============================================================================
-- Floppy version (Spanish) - offsets into IGOR.DAT 11,199,335 bytes
-- Derived from binary analysis of the actual floppy IGOR.DAT.
-- Pixel blocks found by scanning for contiguous rows; palettes matched by
-- searching backward for the nearest valid 768-byte VGA palette.
-- Entries with shared palettes use the closest verified palette.
-- ============================================================================

-- Floppy rooms: { name, img_off, img_size, pal_off, 768, 0,0, 0,0, 0,0 }
-- No mask/box/text data available for the 11.2 MB Spanish floppy version.
local FLOPPY_ROOMS = {
    -- Early data blocks (before first named room)
    {"Data Block 1",                        35200, 51520,  421029, 768, 0,0, 0,0, 0,0},
    {"Data Block 2",                        87680, 32640,  421029, 768, 0,0, 0,0, 0,0},
    {"Data Block 3",                       120640, 63360,  421029, 768, 0,0, 0,0, 0,0},
    {"Data Block 4",                       185280, 47360,  421029, 768, 0,0, 0,0, 0,0},
    {"Data Block 5",                       263040, 64000,  421029, 768, 0,0, 0,0, 0,0},
    {"Data Block 6",                       327680, 45760,  421029, 768, 0,0, 0,0, 0,0},
    {"Data Block 7",                       379200, 42560,  421029, 768, 0,0, 0,0, 0,0},
    -- Named rooms (ScummVM resource_ids.h names)
    {"Philip's Room",                      422080, 64000,  421029, 768, 0,0, 0,0, 0,0},
    {"Physics Classroom",                  487360, 64000,  486549, 768, 0,0, 0,0, 0,0},
    {"Chemistry Classroom",                552960, 64000,  552024, 768, 0,0, 0,0, 0,0},
    {"College Stairs (2nd Floor)",         618560, 64000,  617495, 768, 0,0, 0,0, 0,0},
    {"College Stairs (1st Floor)",         683840, 64000,  682966, 768, 0,0, 0,0, 0,0},
    {"Corridor (Miss Barrymore)",          749440, 64000,  748437, 768, 0,0, 0,0, 0,0},
    {"Corridor (Announcement Bd)",         817920, 62080,  817152, 768, 0,0, 0,0, 0,0},
    {"Corridor (Sharon & Michael)",        881600, 64000,  879379, 768, 0,0, 0,0, 0,0},
    {"Corridor (Caroline)",                966720, 63680,  945439, 768, 0,0, 0,0, 0,0},
    {"Corridor (Lucas)",                  1030720, 64000,  945439, 768, 0,0, 0,0, 0,0},
    {"Corridor (Margaret)",               1154560, 48640, 1115731, 768, 0,0, 0,0, 0,0},
    {"College Lockers",                   1259200, 51200, 1115731, 768, 0,0, 0,0, 0,0},
    {"Women's Toilets",                   1338240, 45120, 1115731, 768, 0,0, 0,0, 0,0},
    {"Men's Toilets",                     1383680, 64000, 1523379, 768, 0,0, 0,0, 0,0},
    {"Outside College",                   1450240, 48640, 1523379, 768, 0,0, 0,0, 0,0},
    {"Laboratory",                        1553920, 52800, 1523379, 768, 0,0, 0,0, 0,0},
    {"Margaret's Room",                   1630400, 64000, 1628740, 768, 0,0, 0,0, 0,0},
    {"Map",                               1729280, 50880, 1628740, 768, 0,0, 0,0, 0,0},
    {"Spring Bridge",                     1807040, 49600, 1857052, 768, 0,0, 0,0, 0,0},
    {"Spring Rock",                       1865920, 48960, 1857052, 768, 0,0, 0,0, 0,0},
    {"Bell Church",                       1931520, 48000, 1855765, 768, 0,0, 0,0, 0,0},
    {"Tobias' Office",                    1987840, 50240, 1979814, 768, 0,0, 0,0, 0,0},
    {"Church Mosaic",                     2061120, 48640, 2053413, 768, 0,0, 0,0, 0,0},
    {"Inside Church",                     2153920, 53120, 2131319, 768, 0,0, 0,0, 0,0},
    {"Church Puzzle",                     2253120, 58560, 2227614, 768, 0,0, 0,0, 0,0},
    {"Outside Church",                    2314240, 51520, 2227612, 768, 0,0, 0,0, 0,0},
    -- Additional game backgrounds
    {"Background 34",                     2387840, 37120, 2385396, 768, 0,0, 0,0, 0,0},
    {"Background 35",                     2429440, 51840, 2386514, 768, 0,0, 0,0, 0,0},
    {"Background 36",                     2576320, 56000, 2505268, 768, 0,0, 0,0, 0,0},
    {"Library",                           2650560, 45120, 2647030, 768, 0,0, 0,0, 0,0},
    {"Spring Bridge (Intro)",             2706560, 50240, 2647030, 768, 0,0, 0,0, 0,0},
    {"Park",                              3855360, 48640, 3844749, 768, 0,0, 0,0, 0,0},
    -- Extended rooms (alternate states, additional areas)
    {"Admin (Secretary Room)",            5883520, 48960, 5876805, 768, 0,0, 0,0, 0,0},
    {"Dean Pepper's Office",              5960640, 49600, 5953494, 768, 0,0, 0,0, 0,0},
    {"Student Dormitory",                 6061120, 40640, 6045969, 768, 0,0, 0,0, 0,0},
    {"Background 58",                     6106240, 53440, 6045969, 768, 0,0, 0,0, 0,0},
    {"Background 59",                     6160960, 37440, 6159520, 768, 0,0, 0,0, 0,0},
    {"Background 60",                     6200960, 52800, 6159998, 768, 0,0, 0,0, 0,0},
    {"Background 61",                     6288320, 52160, 6274003, 768, 0,0, 0,0, 0,0},
    {"Background 62",                     6366400, 40640, 6358236, 768, 0,0, 0,0, 0,0},
    {"Background 63",                     6409600, 49920, 6357058, 768, 0,0, 0,0, 0,0},
    {"Background 64",                     6487040, 49280, 6476192, 768, 0,0, 0,0, 0,0},
    {"Background 65",                     6567680, 49280, 6552976, 768, 0,0, 0,0, 0,0},
    {"Background 66",                     6636160, 49280, 6631534, 768, 0,0, 0,0, 0,0},
    {"Background 67",                     6716800, 49280, 6702071, 768, 0,0, 0,0, 0,0},
    {"Background 68",                     6811840, 50240, 6789022, 768, 0,0, 0,0, 0,0},
    {"Background 69",                     6892160, 49600, 6878997, 768, 0,0, 0,0, 0,0},
    {"Background 70",                     6978560, 33600, 6961491, 768, 0,0, 0,0, 0,0},
    {"Background 71",                     7014720, 49600, 6961491, 768, 0,0, 0,0, 0,0},
    {"Background 72",                     7096960, 49600, 7081358, 768, 0,0, 0,0, 0,0},
    {"Background 73",                     7211520, 49920, 7190977, 768, 0,0, 0,0, 0,0},
    {"Background 74",                     7308480, 49920, 7261816, 768, 0,0, 0,0, 0,0},
    {"Background 75",                     7440320, 53440, 7384119, 768, 0,0, 0,0, 0,0},
    {"Background 76",                     7604800, 49920, 7513740, 768, 0,0, 0,0, 0,0},
    {"Background 77",                     7656960, 58240, 7513740, 768, 0,0, 0,0, 0,0},
    {"Background 78",                     7717440, 48320, 7779541, 768, 0,0, 0,0, 0,0},
    {"Background 79",                     7785280, 48960, 7779541, 768, 0,0, 0,0, 0,0},
    {"Background 80",                     7868160, 48960, 7854029, 768, 0,0, 0,0, 0,0},
    {"Background 81",                     7934400, 42880, 7931945, 768, 0,0, 0,0, 0,0},
    {"Background 82",                     7979520, 48320, 7933063, 768, 0,0, 0,0, 0,0},
    {"Background 83",                     8073280, 43200, 8044164, 768, 0,0, 0,0, 0,0},
    {"Background 84",                     8122880, 35840, 8118943, 768, 0,0, 0,0, 0,0},
    {"Background 85",                     8212480, 50880, 8208182, 768, 0,0, 0,0, 0,0},
    {"Background 86",                     8292800, 49280, 8286990, 768, 0,0, 0,0, 0,0},
    {"Background 87",                     8342400, 49280, 8286990, 768, 0,0, 0,0, 0,0},
    {"Background 88",                     8392640, 53440, 8286990, 768, 0,0, 0,0, 0,0},
    {"Background 89",                     8446400, 52160, 8518763, 768, 0,0, 0,0, 0,0},
    {"Background 90",                     8523200, 49920, 8518763, 768, 0,0, 0,0, 0,0},
    {"Background 91",                     8621120, 54400, 8599403, 768, 0,0, 0,0, 0,0},
    {"Background 92",                     8678080, 50880, 8598227, 768, 0,0, 0,0, 0,0},
    {"Background 93",                     8790720, 51520, 8777516, 768, 0,0, 0,0, 0,0},
    {"Background 94",                     8845440, 53760, 8842429, 768, 0,0, 0,0, 0,0},
    {"Background 95",                     9032640, 51520, 9000174, 768, 0,0, 0,0, 0,0},
    {"Background 96",                     9119040, 37120, 9108639, 768, 0,0, 0,0, 0,0},
    {"Background 97",                     9157120, 53120, 9108639, 768, 0,0, 0,0, 0,0},
    {"Background 98",                     9277120, 56960, 9260423, 768, 0,0, 0,0, 0,0},
    {"Background 99",                     9336320, 50880, 9259189, 768, 0,0, 0,0, 0,0},
    {"Background 100",                    9434880, 58560, 9259189, 768, 0,0, 0,0, 0,0},
    {"Background 101",                    9495680, 51520, 9568764, 768, 0,0, 0,0, 0,0},
    {"Background 102",                    9584960, 50880, 9568764, 768, 0,0, 0,0, 0,0},
    {"Background 103",                    9679680, 51840, 9652152, 768, 0,0, 0,0, 0,0},
    {"Background 104",                    9734080, 49600, 9652150, 768, 0,0, 0,0, 0,0},
    {"Background 105",                    9872640, 49280, 9812011, 768, 0,0, 0,0, 0,0},
    {"Background 106",                    9924160, 53760, 9812011, 768, 0,0, 0,0, 0,0},
    {"Background 107",                   10054400, 36160, 10004120, 768, 0,0, 0,0, 0,0},
    {"Background 108",                   10093120, 55040, 10004120, 768, 0,0, 0,0, 0,0},
    {"Background 109",                   10153280, 42560, 10148547, 768, 0,0, 0,0, 0,0},
    {"Background 110",                   10198080, 48000, 10148547, 768, 0,0, 0,0, 0,0},
    {"Background 111",                   10248320, 50880, 10148547, 768, 0,0, 0,0, 0,0},
    {"Background 112",                   10300480, 64000, 10148547, 768, 0,0, 0,0, 0,0},
    {"Background 113",                   10689600, 38720, 10993073, 768, 0,0, 0,0, 0,0},
    {"Background 114",                   10728640, 51840, 10993073, 768, 0,0, 0,0, 0,0},
    {"Background 115",                   10780800, 53120, 10993073, 768, 0,0, 0,0, 0,0},
    {"Background 116",                   10834240, 48640, 10993073, 768, 0,0, 0,0, 0,0},
    {"Background 117",                   10886400, 51840, 10993073, 768, 0,0, 0,0, 0,0},
    {"Background 118",                   10947840, 44160, 10993073, 768, 0,0, 0,0, 0,0},
    {"Background 119",                   10994240, 51200, 10993073, 768, 0,0, 0,0, 0,0},
    {"Background 120",                   11046080, 46720, 10993073, 768, 0,0, 0,0, 0,0},
    {"Background 121",                   11095680, 43200, 10993073, 768, 0,0, 0,0, 0,0},
}

-- Floppy: splash / shareware / title screens
local FLOPPY_FULLSCREEN = {
    {"Shareware Screen 1",                2795200, 49920, 2789650, 768},
    {"Shareware Screen 2",                2864960, 51200, 2860589, 768},
    {"Shareware Screen 3",                2935360, 51200, 2931035, 768},
    {"Shareware Screen 4",                3008320, 49600, 3003737, 768},
    {"Shareware Screen 5",                3080000, 49600, 3075377, 768},
    {"Shareware Screen 6",                3151360, 49920, 3146967, 768},
    {"Shareware Screen 7",                3222720, 48960, 3218251, 768},
    {"Title Screen",                      3292800, 49600, 3288446, 768},
    {"Pendulo Studios",                   3363840, 48960, 3359454, 768},
    {"Graphic Adventure",                 3433280, 49920, 3428887, 768},
    {"Presents",                          3504640, 48320, 3499983, 768},
    {"Optik Software",                    3573440, 49600, 3569032, 768},
    {"Roman Numbers Paper",               3642880, 48960, 3638564, 768},
    {"Newspaper",                         3712320, 48000, 3707857, 768},
    {"Photo (Harrison & Margaret)",       3780480, 48640, 3775875, 768},
}

-- Floppy: no verified UI or sprite offsets available for the 11.2 MB version
local FLOPPY_UI = {}
local FLOPPY_IGOR_SPRITES = {}
local FLOPPY_TEXTS = {}

-- Floppy: CMF music files (found by scanning for "CTMF" magic)
local FLOPPY_MUSIC = {
    {"CMF 1",   10706193, 26126},
    {"CMF 2",   10732319,  9417},
    {"CMF 3",   10741736, 10554},
    {"CMF 4",   10752290, 15495},
    {"CMF 5",   10767785, 13723},
    {"CMF 6",   10781508,  3279},
    {"CMF 7",   10784787,  7228},
    {"CMF 8",   10792015,  7450},
    {"CMF 9",   10799465,  8654},
    {"CMF 10",  10808119,  8004},
    {"CMF 11",  10816123,  6520},
    {"CMF 12",  10822643,  5088},
    {"CMF 13",  10827731,  2047},
    {"CMF 14",  10829778,  2959},
    {"CMF 15",  10832737,  4000},
}

-- ============================================================================
-- Palette loading
-- ============================================================================

local function read_palette(fh, pal_off, pal_size)
    if pal_off == 0 or pal_size == 0 then return nil end
    local pal_raw = file_read(fh, pal_off, pal_size)
    if not pal_raw then return nil end

    local palette = {}
    -- Expand 6-bit VGA to 8-bit, padding to 768 entries
    local num_colors = math.floor(pal_size / 3)
    for i = 0, num_colors - 1 do
        palette[i*3+1] = expand6(pal_raw:byte(i*3+1))
        palette[i*3+2] = expand6(pal_raw:byte(i*3+2))
        palette[i*3+3] = expand6(pal_raw:byte(i*3+3))
    end
    -- Fill remaining entries with black
    for i = num_colors, 255 do
        palette[i*3+1] = 0
        palette[i*3+2] = 0
        palette[i*3+3] = 0
    end
    return palette
end

-- ============================================================================
-- MSK (walk mask) RLE decompression
-- Format: code_byte + u16LE_length, repeated until 320x144 pixels filled
-- ============================================================================

local function decompress_mask(data)
    local output = {}
    local n = 0
    local target = IMG_W * IMG_H_STD  -- 46080
    local pos = 1
    while n < target and pos + 2 <= #data do
        local code = data:byte(pos)
        local len = u16le(data, pos + 1)
        pos = pos + 3
        if n + len > target then len = target - n end
        for j = 1, len do
            n = n + 1
            output[n] = code
        end
    end
    -- Pad if needed
    while n < target do
        n = n + 1
        output[n] = 0
    end
    return output
end

-- ============================================================================
-- Visualize walk mask as coloured overlay
-- ============================================================================

local MASK_COLORS = {
    {  0,   0,   0}, -- 0 = impassable (black)
    { 60, 180,  75}, -- 1 = green
    {255, 225,  25}, -- 2 = yellow
    {  0, 130, 200}, -- 3 = blue
    {245, 130,  48}, -- 4 = orange
    {145,  30, 180}, -- 5 = purple
    { 70, 240, 240}, -- 6 = cyan
    {240,  50, 230}, -- 7 = magenta
    {210, 245,  60}, -- 8 = lime
    {250, 190, 212}, -- 9 = pink
    {  0, 128, 128}, -- 10 = teal
    {220, 190, 255}, -- 11 = lavender
    {170, 110,  40}, -- 12 = brown
    {255, 250, 200}, -- 13 = beige
    {128,   0,   0}, -- 14 = maroon
    {170, 255, 195}, -- 15 = mint
}

local function render_mask(mask_pixels, w, h)
    local rgb = {}
    local n = 0
    for i = 1, w * h do
        local val = mask_pixels[i] or 0
        local ci = (val % #MASK_COLORS) + 1
        local c = MASK_COLORS[ci]
        n = n + 1; rgb[n] = c[1]
        n = n + 1; rgb[n] = c[2]
        n = n + 1; rgb[n] = c[3]
    end
    return image_create_rgb(w, h, rgb)
end

-- ============================================================================
-- Visualize BOX_ data
-- 256 entries x 5 bytes: area, object, y1_lum, y2_lum, delta_lum
-- ============================================================================

local function render_boxes(box_data)
    local entries = {}
    for i = 0, 255 do
        local base = i * 5 + 1
        if base + 4 <= #box_data then
            entries[i] = {
                area     = box_data:byte(base),
                object   = box_data:byte(base + 1),
                y1_lum   = box_data:byte(base + 2),
                y2_lum   = box_data:byte(base + 3),
                delta    = box_data:byte(base + 4),
            }
        end
    end

    -- Render as 16x16 grid of coloured blocks (each 20x20 pixels)
    local cell = 20
    local gw, gh = 16, 16
    local iw, ih = gw * cell, gh * cell
    local rgb = {}
    local n = 0
    for py = 0, ih - 1 do
        for px = 0, iw - 1 do
            local gx = math.floor(px / cell)
            local gy = math.floor(py / cell)
            local idx = gy * gw + gx
            local e = entries[idx]
            local r, g, b = 32, 32, 32
            if e then
                if e.area > 0 then
                    local ci = (e.area % #MASK_COLORS) + 1
                    local c = MASK_COLORS[ci]
                    r, g, b = c[1], c[2], c[3]
                end
            end
            -- Draw grid lines
            if px % cell == 0 or py % cell == 0 then
                r, g, b = 80, 80, 80
            end
            n = n + 1; rgb[n] = r
            n = n + 1; rgb[n] = g
            n = n + 1; rgb[n] = b
        end
    end
    return image_create_rgb(iw, ih, rgb), entries
end

-- ============================================================================
-- Render Igor walking sprites as individual animation frames
-- ============================================================================

local IGOR_FRAME_SIZE = 1500
local IGOR_FRAME_W    = 30
local IGOR_FRAME_H    = 50

local function render_igor_sprite_frames(sprite_data, palette, total_size)
    local num_frames = math.floor(total_size / IGOR_FRAME_SIZE)
    if num_frames < 1 then return nil end

    local handles = {}
    for frame = 0, num_frames - 1 do
        local pixels = {}
        local n = 0
        local frame_base = frame * IGOR_FRAME_SIZE
        for row = 0, IGOR_FRAME_H - 1 do
            for col = 0, IGOR_FRAME_W - 1 do
                local src_idx = frame_base + row * IGOR_FRAME_W + col + 1
                n = n + 1
                if src_idx <= #sprite_data then
                    pixels[n] = sprite_data:byte(src_idx)
                else
                    pixels[n] = 0
                end
            end
        end
        handles[#handles + 1] = image_create_indexed(IGOR_FRAME_W, IGOR_FRAME_H, pixels, palette)
    end

    return handles, num_frames
end

-- ============================================================================
-- Render inventory objects sheet
-- ============================================================================

local OBJ_W = 40
local OBJ_H = 30
local OBJ_STRIDE = OBJ_W * OBJ_H  -- 1200
local OBJ_COLS = 6

local function render_objects_sheet(obj_data, palette)
    if not obj_data then return nil end
    local num_objs = math.min(math.floor(#obj_data / OBJ_STRIDE), 40)
    if num_objs < 1 then return nil end

    local rows = math.ceil(num_objs / OBJ_COLS)
    local sheet_w = OBJ_COLS * OBJ_W
    local sheet_h = rows * OBJ_H
    local pixels = {}
    local n = 0

    for py = 0, sheet_h - 1 do
        for px = 0, sheet_w - 1 do
            local obj_col = math.floor(px / OBJ_W)
            local obj_row = math.floor(py / OBJ_H)
            local obj_idx = obj_row * OBJ_COLS + obj_col
            local lx = px % OBJ_W
            local ly = py % OBJ_H
            n = n + 1
            if obj_idx < num_objs then
                local src = obj_idx * OBJ_STRIDE + ly * OBJ_W + lx + 1
                if src <= #obj_data then
                    pixels[n] = obj_data:byte(src)
                else
                    pixels[n] = 0
                end
            else
                pixels[n] = 0
            end
        end
    end

    return image_create_indexed(sheet_w, sheet_h, pixels, palette)
end

-- ============================================================================
-- Text decoding (Spanish XOR 0x6D encryption)
-- ============================================================================

local function decode_text(data)
    local result = {}
    for i = 1, #data do
        local x = data:byte(i)
        -- Manual XOR 0x6D (no bitwise ops in LuaJ 3.0.1)
        local xor_val = 0x6D
        local b = 0
        local pow = 1
        for bit = 0, 7 do
            local a_bit = math.floor(x / pow) % 2
            local b_bit = math.floor(xor_val / pow) % 2
            if a_bit ~= b_bit then
                b = b + pow
            end
            pow = pow * 2
        end
        if b >= 32 and b <= 126 then
            result[#result + 1] = string.char(b)
        elseif b == 10 or b == 13 then
            result[#result + 1] = "\n"
        elseif b == 0 then
            result[#result + 1] = " | "
        else
            result[#result + 1] = string.format("[%02X]", b)
        end
    end
    return table.concat(result)
end

-- ============================================================================
-- CMF music file info
-- ============================================================================

local function describe_cmf(data)
    if #data < 36 then return "Too small for CMF" end
    local sig = data:sub(1, 4)
    if sig ~= "CTMF" then
        return string.format("Not a CMF file (magic: %s)", sig)
    end
    local inst_off = u16le(data, 5)
    local music_off = u16le(data, 7)
    local ticks = u16le(data, 9)
    local num_inst = u16le(data, 25)
    return string.format(
        "CMF Music File\nInstruments: %d\nTicks/beat: %d\nInstr offset: 0x%04X\nMusic offset: 0x%04X\nFile size: %d bytes",
        num_inst, ticks, inst_off, music_off, #data)
end

-- ============================================================================
-- engine.detect(game_path)
-- ============================================================================

function engine.detect(game_path)
    local path, ver = find_data_file(game_path)
    return path ~= nil
end

-- ============================================================================
-- engine.get_resources(game_path)
-- ============================================================================

function engine.get_resources(game_path)
    local data_path, version = find_data_file(game_path)
    if not data_path then
        return {{id="err", name="No IGOR data file found", type="category", children={}}}
    end

    local rooms, fullscreen, ui, igor_sprites, texts, music
    if version == VER_CD then
        rooms = CD_ROOMS
        fullscreen = CD_FULLSCREEN
        ui = CD_UI
        igor_sprites = CD_IGOR_SPRITES
        texts = CD_TEXTS
        music = nil
    else
        rooms = FLOPPY_ROOMS
        fullscreen = FLOPPY_FULLSCREEN
        ui = FLOPPY_UI
        igor_sprites = FLOPPY_IGOR_SPRITES
        texts = FLOPPY_TEXTS
        music = FLOPPY_MUSIC
    end

    local ver_label = version == VER_CD and "CD" or "Floppy"

    -- Build room nodes with sub-items for each room
    local room_children = {}
    for i, room in ipairs(rooms) do
        local sub = {}
        sub[#sub + 1] = {id = "room_bg_" .. i, name = "Background", type = "image"}
        if room[7] > 0 then
            sub[#sub + 1] = {id = "room_msk_" .. i, name = "Walk Mask", type = "image"}
        end
        if room[9] > 0 then
            sub[#sub + 1] = {id = "room_box_" .. i, name = "Walkbox Areas", type = "image"}
        end
        if room[11] > 0 then
            sub[#sub + 1] = {id = "room_txt_" .. i, name = "Text Strings", type = "image"}
        end
        room_children[#room_children + 1] = {
            id = "room_" .. i,
            name = room[1],
            type = "category",
            children = sub,
        }
    end

    -- Fullscreen images
    local fs_children = {}
    for i, fs in ipairs(fullscreen) do
        fs_children[#fs_children + 1] = {
            id = "fs_" .. i,
            name = fs[1],
            type = "image",
        }
    end

    -- UI elements
    local ui_children = {}
    for i, u in ipairs(ui) do
        ui_children[#ui_children + 1] = {
            id = "ui_" .. i,
            name = u[1],
            type = "image",
        }
    end

    -- Igor sprites
    local sprite_children = {}
    for i, s in ipairs(igor_sprites) do
        sprite_children[#sprite_children + 1] = {
            id = "igor_" .. i,
            name = s[1],
            type = "animation",
        }
    end

    -- Texts
    local text_children = {}
    for i, t in ipairs(texts) do
        text_children[#text_children + 1] = {
            id = "text_" .. i,
            name = t[1],
            type = "image",
        }
    end

    local root = {}
    root[#root + 1] = {
        id = "cat_rooms",
        name = "Room Backgrounds (" .. ver_label .. ", " .. #rooms .. " rooms)",
        type = "category",
        children = room_children,
    }

    if #fs_children > 0 then
        root[#root + 1] = {
            id = "cat_fullscreen",
            name = "Title / Splash Screens (" .. #fullscreen .. ")",
            type = "category",
            children = fs_children,
        }
    end

    if #ui_children > 0 then
        root[#root + 1] = {
            id = "cat_ui",
            name = "UI Elements (" .. #ui .. ")",
            type = "category",
            children = ui_children,
        }
    end

    if #sprite_children > 0 then
        root[#root + 1] = {
            id = "cat_igor",
            name = "Igor Sprites (" .. #igor_sprites .. ")",
            type = "category",
            children = sprite_children,
        }
    end

    if #text_children > 0 then
        root[#root + 1] = {
            id = "cat_texts",
            name = "Text Data (" .. #texts .. ")",
            type = "category",
            children = text_children,
        }
    end

    -- Music (floppy only)
    if music and #music > 0 then
        local music_children = {}
        for i, m in ipairs(music) do
            music_children[#music_children + 1] = {
                id = "music_" .. i,
                name = m[1],
                type = "image",
            }
        end
        root[#root + 1] = {
            id = "cat_music",
            name = "Music (CMF, " .. #music .. " tracks)",
            type = "category",
            children = music_children,
        }
    end

    return root
end

-- ============================================================================
-- engine.load_resource(game_path, resource_id)
-- ============================================================================

function engine.load_resource(game_path, resource_id)
    local data_path, version = find_data_file(game_path)
    if not data_path then
        return {type = "text", text = "No IGOR data file found"}
    end

    local rooms, fullscreen, ui, igor_sprites, texts, music
    if version == VER_CD then
        rooms = CD_ROOMS
        fullscreen = CD_FULLSCREEN
        ui = CD_UI
        igor_sprites = CD_IGOR_SPRITES
        texts = CD_TEXTS
        music = nil
    else
        rooms = FLOPPY_ROOMS
        fullscreen = FLOPPY_FULLSCREEN
        ui = FLOPPY_UI
        igor_sprites = FLOPPY_IGOR_SPRITES
        texts = FLOPPY_TEXTS
        music = FLOPPY_MUSIC
    end

    -- ====== Room background ======
    local room_type, room_idx = resource_id:match("^room_(%a+)_(%d+)$")
    if room_type and room_idx then
        local idx = tonumber(room_idx)
        if idx < 1 or idx > #rooms then
            return {type = "text", text = "Room index out of range: " .. idx}
        end
        local room = rooms[idx]
        local name      = room[1]
        local img_off   = room[2]
        local img_size  = room[3]
        local pal_off   = room[4]
        local pal_size  = room[5]
        local msk_off   = room[6]
        local msk_size  = room[7]
        local box_off   = room[8]
        local box_size  = room[9]
        local txt_off   = room[10]
        local txt_size  = room[11]

        local fh = file_open(data_path)
        if not fh then return {type = "text", text = "Cannot open data file"} end

        if room_type == "bg" then
            local palette = read_palette(fh, pal_off, pal_size)
            if not palette then
                file_close(fh)
                return {type = "text", text = "Failed to read palette for " .. name}
            end
            local img_raw = file_read(fh, img_off, img_size)
            file_close(fh)
            if not img_raw or #img_raw < img_size then
                return {type = "text", text = "Failed to read image for " .. name}
            end

            local img_h = math.floor(img_size / IMG_W)
            local pixels = {}
            for i = 1, img_size do
                pixels[i] = img_raw:byte(i)
            end

            local img = image_create_indexed(IMG_W, img_h, pixels, palette)
            return {
                type = "image",
                image = img,
                description = string.format(
                    "%s  |  %dx%d  |  pal@0x%X (%d bytes)  |  img@0x%X",
                    name, IMG_W, img_h, pal_off, pal_size, img_off),
            }

        elseif room_type == "msk" then
            if msk_off == 0 or msk_size == 0 then
                file_close(fh)
                return {type = "text", text = "No mask data for " .. name}
            end
            local msk_raw = file_read(fh, msk_off, msk_size)
            file_close(fh)
            if not msk_raw then
                return {type = "text", text = "Failed to read mask for " .. name}
            end

            local mask_pixels = decompress_mask(msk_raw)
            local img = render_mask(mask_pixels, IMG_W, IMG_H_STD)

            -- Count unique zones
            local zones = {}
            for i = 1, #mask_pixels do
                zones[mask_pixels[i]] = true
            end
            local zone_count = 0
            for _ in pairs(zones) do zone_count = zone_count + 1 end

            return {
                type = "image",
                image = img,
                description = string.format(
                    "%s - Walk Mask  |  %dx%d  |  %d zones  |  RLE %d bytes -> %d pixels",
                    name, IMG_W, IMG_H_STD, zone_count, msk_size, IMG_W * IMG_H_STD),
            }

        elseif room_type == "box" then
            if box_off == 0 or box_size == 0 then
                file_close(fh)
                return {type = "text", text = "No walkbox data for " .. name}
            end
            local box_raw = file_read(fh, box_off, box_size)
            file_close(fh)
            if not box_raw then
                return {type = "text", text = "Failed to read walkbox for " .. name}
            end

            local img, entries = render_boxes(box_raw)

            -- Build description with non-zero entries
            local desc_parts = {name .. " - Walkbox Areas (256 x 5-byte entries)"}
            local active_count = 0
            for i = 0, 255 do
                local e = entries[i]
                if e and (e.area > 0 or e.object > 0) then
                    active_count = active_count + 1
                    if active_count <= 20 then
                        desc_parts[#desc_parts + 1] = string.format(
                            "  [%3d] area=%d obj=%d y1=%d y2=%d delta=%d",
                            i, e.area, e.object, e.y1_lum, e.y2_lum, e.delta)
                    end
                end
            end
            if active_count > 20 then
                desc_parts[#desc_parts + 1] = string.format("  ... and %d more", active_count - 20)
            end
            desc_parts[1] = desc_parts[1] .. " (" .. active_count .. " active)"

            return {
                type = "image",
                image = img,
                description = table.concat(desc_parts, "\n"),
            }

        elseif room_type == "txt" then
            if txt_off == 0 or txt_size == 0 then
                file_close(fh)
                return {type = "text", text = "No text data for " .. name}
            end
            local txt_raw = file_read(fh, txt_off, txt_size)
            file_close(fh)
            if not txt_raw then
                return {type = "text", text = "Failed to read text for " .. name}
            end

            local decoded = decode_text(txt_raw)
            return {
                type = "text",
                text = string.format("%s - Text Strings (%d bytes)\n\n%s", name, txt_size, decoded),
            }
        end

        file_close(fh)
        return {type = "text", text = "Unknown room sub-resource: " .. room_type}
    end

    -- ====== Fullscreen images ======
    local fs_idx = resource_id:match("^fs_(%d+)$")
    if fs_idx then
        local idx = tonumber(fs_idx)
        if idx < 1 or idx > #fullscreen then
            return {type = "text", text = "Fullscreen index out of range"}
        end
        local fs = fullscreen[idx]
        local fh = file_open(data_path)
        if not fh then return {type = "text", text = "Cannot open data file"} end

        local palette = read_palette(fh, fs[4], fs[5])
        if not palette then
            file_close(fh)
            return {type = "text", text = "Failed to read palette"}
        end
        local img_raw = file_read(fh, fs[2], fs[3])
        file_close(fh)
        if not img_raw or #img_raw < fs[3] then
            return {type = "text", text = "Failed to read image data"}
        end

        local img_h = math.floor(fs[3] / IMG_W)
        local pixels = {}
        for i = 1, fs[3] do pixels[i] = img_raw:byte(i) end

        local img = image_create_indexed(IMG_W, img_h, pixels, palette)
        return {
            type = "image",
            image = img,
            description = string.format("%s  |  %dx%d", fs[1], IMG_W, img_h),
        }
    end

    -- ====== UI elements ======
    local ui_idx = resource_id:match("^ui_(%d+)$")
    if ui_idx then
        local idx = tonumber(ui_idx)
        if idx < 1 or idx > #ui then
            return {type = "text", text = "UI index out of range"}
        end
        local u = ui[idx]
        local fh = file_open(data_path)
        if not fh then return {type = "text", text = "Cannot open data file"} end

        local img_raw = file_read(fh, u[2], u[3])

        -- For UI elements, grab palette from the first room
        local pal_off = rooms[1][4]
        local pal_size = rooms[1][5]
        local palette = read_palette(fh, pal_off, pal_size)
        file_close(fh)

        if not img_raw or not palette then
            return {type = "text", text = "Failed to read UI data"}
        end

        -- Detect objects sheet
        if u[3] == 48000 then
            local img = render_objects_sheet(img_raw, palette)
            if img then
                return {
                    type = "image",
                    image = img,
                    description = u[1] .. "  |  30 inventory objects (40x30 each)",
                }
            end
        end

        -- Standard UI panel rendering
        local img_h = math.floor(u[3] / IMG_W)
        if img_h < 1 then img_h = 1 end
        local pixel_count = IMG_W * img_h
        local pixels = {}
        for i = 1, pixel_count do
            if i <= #img_raw then
                pixels[i] = img_raw:byte(i)
            else
                pixels[i] = 0
            end
        end

        local img = image_create_indexed(IMG_W, img_h, pixels, palette)
        return {
            type = "image",
            image = img,
            description = string.format("%s  |  %dx%d", u[1], IMG_W, img_h),
        }
    end

    -- ====== Igor sprites ======
    local igor_idx = resource_id:match("^igor_(%d+)$")
    if igor_idx then
        local idx = tonumber(igor_idx)
        if idx < 1 or idx > #igor_sprites then
            return {type = "text", text = "Igor sprite index out of range"}
        end
        local s = igor_sprites[idx]
        local fh = file_open(data_path)
        if not fh then return {type = "text", text = "Cannot open data file"} end

        local sprite_raw = file_read(fh, s[2], s[3])
        -- Grab palette from first room
        local palette = read_palette(fh, rooms[1][4], rooms[1][5])
        file_close(fh)

        if not sprite_raw or not palette then
            return {type = "text", text = "Failed to read sprite data"}
        end

        -- Set index 0 to magenta for transparency
        palette[1] = 255
        palette[2] = 0
        palette[3] = 255

        -- Special handling for head frames (3696 bytes = 4 positions x 924 bytes)
        if s[3] == 3696 then
            local head_w = 14
            local head_h = 11
            local head_frame_size = head_w * head_h  -- 154
            local frames_per_pos = 6
            local positions = 4
            local handles = {}
            for pos = 0, positions - 1 do
                for frame = 0, frames_per_pos - 1 do
                    local pixels = {}
                    local n = 0
                    for row = 0, head_h - 1 do
                        for col = 0, head_w - 1 do
                            local off = pos * 924 + frame * head_frame_size + row * head_w + col + 1
                            n = n + 1
                            if off <= #sprite_raw then
                                pixels[n] = sprite_raw:byte(off)
                            else
                                pixels[n] = 0
                            end
                        end
                    end
                    handles[#handles + 1] = image_create_indexed(head_w, head_h, pixels, palette)
                end
            end
            local anim = animation_create(handles, 150)
            return {
                type = "animation",
                animation = anim,
                delay_ms = 150,
                description = string.format(
                    "%s  |  4 positions x 6 frames (14x11 each)  |  %d bytes",
                    s[1], s[3]),
            }
        end

        local handles, num_frames = render_igor_sprite_frames(sprite_raw, palette, s[3])
        if not handles then
            return {type = "text", text = "Failed to render sprite"}
        end
        local anim = animation_create(handles, 150)
        return {
            type = "animation",
            animation = anim,
            delay_ms = 150,
            description = string.format(
                "%s  |  %d frames (30x50 each)  |  %d bytes",
                s[1], num_frames, s[3]),
        }
    end

    -- ====== Text data ======
    local text_idx = resource_id:match("^text_(%d+)$")
    if text_idx then
        local idx = tonumber(text_idx)
        if idx < 1 or idx > #texts then
            return {type = "text", text = "Text index out of range"}
        end
        local t = texts[idx]
        local fh = file_open(data_path)
        if not fh then return {type = "text", text = "Cannot open data file"} end

        local txt_raw = file_read(fh, t[2], t[3])
        file_close(fh)
        if not txt_raw then
            return {type = "text", text = "Failed to read text data"}
        end

        local decoded = decode_text(txt_raw)
        return {
            type = "text",
            text = string.format("%s (%d bytes)\n\n%s", t[1], t[3], decoded),
        }
    end

    -- ====== Music (CMF) ======
    if music and #music > 0 then
        local music_idx = resource_id:match("^music_(%d+)$")
        if music_idx then
            local idx = tonumber(music_idx)
            if idx < 1 or idx > #music then
                return {type = "text", text = "Music index out of range"}
            end
            local m = music[idx]
            local fh = file_open(data_path)
            if not fh then return {type = "text", text = "Cannot open data file"} end

            local cmf_raw = file_read(fh, m[2], m[3])
            file_close(fh)
            if not cmf_raw then
                return {type = "text", text = "Failed to read music data"}
            end

            local desc = describe_cmf(cmf_raw)
            return {
                type = "text",
                text = string.format("%s\n\n%s", m[1], desc),
            }
        end
    end

    return {type = "text", text = "Unknown resource: " .. tostring(resource_id)}
end

-- ============================================================================
return engine

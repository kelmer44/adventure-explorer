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
--   VOC_  : Creative Voice File audio (CD IGOR.DAT), 8-bit unsigned PCM,
--           indexed by a 1400-entry sound-offset table into IGOR.DAT
--           (indices 1-68 = sound effects, 101-1392 = speech/voice acting)
--   TXT_  : Text strings (Spanish, per-table byte shuffling, see below)
-- ============================================================================

local engine = {}
engine.name        = "Igor: Objective Uikokahonia"
engine.id          = "igor"
engine.description = "Pendulo Studios (1994) - DOS floppy & CD"
engine.version     = "7.3"

-- ============================================================================
-- Binary helpers (no bit32 in LuaJ 3.0.1)
-- ============================================================================

local function u8(data, pos)    return data:byte(pos) end
local function u16le(data, pos) return data:byte(pos) + data:byte(pos+1) * 256 end
local function u32le(data, pos)
    return data:byte(pos) + data:byte(pos+1) * 256 + data:byte(pos+2) * 65536 + data:byte(pos+3) * 16777216
end

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
-- Named rooms from scummvm-create-igortbl/resource_sp_cdrom.h (31 rooms).
-- Additional rooms found by scanning IGOR.EXE for 46080-byte image blocks
-- followed by valid VGA palettes (42 rooms, no text data).
local CD_ROOMS = {
    {"Room 3",                                0x02a76e, 46080, 0x035b6e, 768,  0,       0,    0,       0,    0,       0},
    {"Room 9",                                0x1046e7, 46080, 0x10fae7, 624,  0x10fd57, 2718, 0x1107f5, 1280, 0,       0},
    {"Room 10",                               0x134175, 46080, 0x13f575, 768,  0x13f875,    3, 0x13f878, 1280, 0,       0},
    {"Room 11",                               0x165847, 46080, 0x170c47, 624,  0,       0,    0x170eb7, 1280, 0,       0},
    {"Room 12",                               0x18ddea, 46080, 0x1991ea, 624,  0x19945a, 2760, 0x199f22, 1280, 0,       0},
    {"Philip's Room",                           0x1a4f1c, 46080, 0x1b031c, 768, 0x1b061c, 3, 0x1b061f, 1280, 0x1a4a75, 1191},
    {"Room 14",                               0x1b168a, 46080, 0x1bca8a, 624,  0,       0,    0,       0,    0,       0},
    {"Room 15",                               0x1c2718, 46080, 0x1cdb18, 768,  0x1cde18,    3, 0x1cde1b, 1280, 0,       0},
    {"Room 16",                               0x1d2a9f, 46080, 0x1dde9f, 624,  0x1de10f,  636, 0x1de38b, 1280, 0,       0},
    {"Church Mosaic (alt copy)",                         0x1eb513, 46080, 0x1f6913, 720,  0x1f6be3, 2445, 0,       0,    0,       0},
    {"Church Puzzle (alt copy)",                         0x2054e3, 46080, 0x2108e3, 624,  0x210b53, 1992, 0x21131b, 1280, 0x204eb0, 1587},
    {"Room 18",                               0x206f01, 46080, 0x212301, 624,  0x212571, 5325, 0x213a3e, 1280, 0,       0},
    {"Inside Church (alt copy)",                         0x21765f, 46080, 0x222a5f, 624,  0x222ccf, 2352, 0x2235ff, 1280, 0x217231, 1070},
    {"Room 19",                               0x22a238, 46080, 0x235638, 624,  0x2358a8, 3546, 0x236682, 1280, 0,       0},
    {"Outside Church (alt copy)",                        0x23ae4f, 46080, 0x24624f, 624,  0x2464bf, 3264, 0x24717f, 1280, 0x23a8bc, 1427},
    {"Room 20",                               0x23df9c, 46080, 0x24939c, 624,  0x24960c, 2511, 0x249fdb, 1280, 0,       0},
    {"Room 21",                               0x2625e0, 46080, 0x26d9e0, 624,  0,       0,    0x26dc4f, 1280, 0,       0},
    {"Room 22",                               0x276236, 46080, 0x281636, 768,  0,       0,    0x281936, 1280, 0,       0},
    {"Maze 66",                                 0x28beb2, 46080, 0x2972b2, 576, 0x297522, 2364, 0x297e5e, 1280, 0x28b9b3, 1279},
    {"Maze 65",                                 0x29d1b2, 46080, 0x2a85b2, 576, 0x2a8822, 3366, 0x2a9548, 1280, 0x29ccb3, 1279},
    {"Maze 64",                                 0x2ae6b2, 46080, 0x2b9ab2, 576, 0x2b9d22, 3273, 0x2ba9eb, 1280, 0x2ae1b3, 1279},
    {"Maze 63",                                 0x2c03b2, 46080, 0x2cb7b2, 576, 0x2cba22, 2034, 0x2cc214, 1280, 0x2bfeb3, 1279},
    {"Maze 62",                                 0x2d1db2, 46080, 0x2dd1b2, 576, 0x2dd422, 2139, 0x2ddc7d, 1280, 0x2d18b3, 1279},
    {"Maze 61",                                 0x2e36b2, 46080, 0x2eeab2, 576, 0x2eed22, 2256, 0x2ef5f2, 1280, 0x2e31b3, 1279},
    {"Maze 60",                                 0x2f4db2, 46080, 0x3001b2, 576, 0x300422, 1404, 0x30099e, 1280, 0x2f48b3, 1279},
    {"Maze 59",                                 0x3060b2, 46080, 0x3114b2, 576, 0x311722, 1992, 0x311eea, 1280, 0x305bb3, 1279},
    {"Maze 58",                                 0x3176b2, 46080, 0x322ab2, 576, 0x322d22, 1254, 0x323208, 1280, 0x3171b3, 1279},
    {"Maze 57",                                 0x3287b2, 46080, 0x333bb2, 576, 0x333e22, 2058, 0x33462c, 1280, 0x3282b3, 1279},
    {"Maze 56",                                 0x339eb2, 46080, 0x3452b2, 576, 0x345522, 1017, 0x34591b, 1280, 0x3399b3, 1279},
    {"Maze Entrance",                           0x34adb2, 46080, 0x3561b2, 576, 0x356422, 1884, 0x356b7e, 1280, 0x34a8b3, 1279},
    {"Maze 54",                                 0x35beb2, 46080, 0x3672b2, 576, 0x367522, 1278, 0x367a20, 1280, 0x35b9b3, 1279},
    {"Maze 53",                                 0x36ceb2, 46080, 0x3782b2, 576, 0x378522, 267, 0x37862d, 1280, 0x36c9b3, 1279},
    {"Maze 52",                                 0x37d9b2, 46080, 0x388db2, 576, 0x389022, 1128, 0x38948a, 1280, 0x37d4b3, 1279},
    {"Maze 51",                                 0x392ab2, 46080, 0x39deb2, 576, 0x39e122, 873, 0x39e48b, 1280, 0x3925b3, 1279},
    {"Physics Classroom",                       0x3a5a17, 46080, 0x3b0e17, 624, 0x3b1087, 1557, 0x3b169c, 1280, 0x3a55a2, 1141},
    {"Chemistry Classroom",                     0x3b9173, 46080, 0x3c4573, 624, 0x3c47e3, 1980, 0x3c4f9f, 1280, 0x3b8ca2, 1233},
    {"Park Right",                              0x3e042a, 46080, 0x3eb82a, 624, 0x3eba9a, 3972, 0x3eca1e, 1280, 0x3dffa2, 1160},
    {"Park",                                    0x3f723d, 46080, 0x40263d, 624, 0x4028ad, 4728, 0x403b25, 1280, 0x3f6ba2, 1691},
    {"College Stairs (2nd Floor)",              0x4115cf, 46080, 0x41c9cf, 624, 0x41cc3f, 4128, 0x41dc5f, 1280, 0x410fb3, 1564},
    {"College Stairs (1st Floor)",              0x43577d, 46080, 0x440b7d, 624, 0x440ded, 2934, 0x441963, 1280, 0x4352b3, 1226},
    {"Corridor (Miss Barrymore)",               0x44e61f, 46080, 0x459a1f, 624, 0x459c8f, 2484, 0x45a643, 1280, 0x44e0a2, 1405},
    {"Corridor (Announcement Bd)",              0x466062, 46080, 0x471462, 624, 0x4716d2, 3117, 0x4722ff, 1280, 0x465ba2, 1216},
    {"Corridor (Sharon & Michael)",             0x47f3d5, 46080, 0x48a7d5, 624, 0x48aa45, 3144, 0x48b68d, 1280, 0x47eea2, 1331},
    {"Corridor (Caroline)",                     0x49c49d, 46080, 0x4a789d, 624, 0x4a7b0d, 2151, 0x4a8374, 1280, 0x49bcb3, 2026},
    {"Corridor (Lucas)",                        0x4b34d7, 46080, 0x4be8d7, 624, 0x4beb47, 3297, 0x4bf828, 1280, 0x4b2fa2, 1333},
    {"Corridor (Margaret)",                     0x4dafca, 46080, 0x4e63ca, 624, 0x4e663a, 3690, 0x4e74a4, 1280, 0x4da9b3, 1559},
    {"College Lockers",                         0x4f1dbb, 46080, 0x4fd1bb, 624, 0x4fd42b, 2235, 0x4fdce6, 1280, 0x4f17a2, 1561},
    {"Women's Toilets",                         0x511824, 46080, 0x51cc24, 624, 0x51ce94, 2022, 0x51d67a, 1280, 0x5111a2, 1666},
    {"Men's Toilets",                           0x51e8e4, 46080, 0x529ce4, 624, 0x529f54, 1980, 0x52a710, 1280, 0x51e3a2, 1346},
    {"Outside College",                         0x538ac2, 46080, 0x543ec2, 624, 0x544132, 4974, 0x5454a0, 1280, 0x5383a2, 1824},
    {"Margaret's Room",                         0x55f022, 46080, 0x56a422, 768, 0x56a722, 3, 0x56a725, 1280, 0x55e975, 1709},
    {"Laboratory",                              0x57e06c, 46080, 0x58946c, 624, 0x5896dc, 2130, 0x589f2e, 1280, 0x57daa2, 1482},
    {"Map",                                     0x5906a1, 46080, 0x59baa1, 624, 0x59bd11, 1809, 0x59c422, 1280, 0x5902a2, 1023},
    {"Tobias' Office",                          0x5b13c6, 46080, 0x5bc7c6, 624, 0x5bca36, 1455, 0x5bcfe5, 1280, 0x5b0ba2, 2084},
    {"Bell Church",                             0x5cde24, 46080, 0x5d9224, 624, 0x5d9494, 861, 0x5d97f1, 1280, 0x5cd9a2, 1154},
    {"Room 60",                               0x601291, 46080, 0x60c691, 624,  0x60c901, 3237, 0x60d5a6, 1280, 0,       0},
    {"Church Mosaic",                           0x615952, 46080, 0x620d52, 720, 0x621022, 2445, 0, 0, 0, 0},
    {"Church Puzzle",                           0x62fa11, 46080, 0x63ae11, 624, 0x63b081, 1992, 0x63b849, 1280, 0x62f3a2, 1647},
    {"Inside Church",                           0x6430c3, 46080, 0x64e4c3, 624, 0x64e733, 2352, 0x64f063, 1280, 0x642ca2, 1057},
    {"Outside Church",                          0x669515, 46080, 0x674915, 624, 0x674b85, 3264, 0x675845, 1280, 0x668f73, 1442},
    {"Outside Administration Building B",       0x68692f, 46080, 0x691d2f, 624, 0x691f9f, 3858, 0x692eb1, 1280, 0x6864a2, 1165},
    {"Outside Administration Building A",       0x6940b3, 46080, 0x69f4b3, 624, 0x69f723, 5766, 0x6a0da9, 1280, 0x693ba2, 1297},
    {"Spring Bridge",                           0x6c0eda, 46080, 0x6cc2da, 624, 0x6cc5aa, 3936, 0x6cd50a, 1280, 0x6c0aa2, 1080},
    {"Library",                                 0x6e31c1, 46080, 0x6ee5c1, 624, 0x6ee831, 2217, 0x6ef0da, 1280, 0x6e29b3, 2062},
    {"Admin (Secretary Room)",                  0x7143fa, 46080, 0x71f7fa, 624, 0x71fa6a, 2400, 0x7203ca, 1280, 0x713da2, 1624},
    {"Dean Pepper's Office",                    0x738c4e, 46080, 0x74404e, 624, 0x7442be, 2745, 0x744d77, 1280, 0x7385a2, 1708},
    {"Administration Corridor",                 0x750190, 46080, 0x75b590, 624, 0x75b800, 2388, 0x75c154, 1280, 0x74fba2, 1518},
    {"Outside Student Dormitory",               0x76fef6, 46080, 0x77b2f6, 624, 0x77b566, 1524, 0x77bb5a, 1280, 0x76f9ad, 1353},
    {"Student Dormitory",                       0x7b1e66, 46080, 0x7bd266, 624, 0x7bd566, 6699, 0x7bef91, 1280, 0x7b18a2, 1476},
    {"Room 75",                               0x7bf8b4, 46080, 0x7cacb4, 768,  0,       0,    0,       0,    0,       0},
    {"Spring Bridge (Intro)",                   0x7d698f, 46080, 0x7e1d8f, 720, 0, 0, 0, 0, 0x7d6264, 1835},
    {"Spring Rock",                             0x7e2de6, 46080, 0x7ee1e6, 720, 0x7ee4b6, 3117, 0x7ef0e3, 1280, 0x7e28a2, 1348},
    {"Student Dormitory Attic",                 0x792de6, 46080, 0x79e1e6, 624, 0x79e456, 4545, 0x79f617, 1280, 0x7926a2, 1860},
    {"Roman Numbers Paper",                     0x866eea, 46080, 0x8722ea, 624, 0, 0, 0, 0, 0, 0},
    {"News Paper",                              0x87f2f8, 46080, 0x88a6f8, 624, 0, 0, 0, 0, 0, 0},
    {"Photo Harrison Margaret",                 0x88ac06, 46080, 0x896006, 624, 0, 0, 0, 0, 0, 0},
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

-- CD: sprite / animation resource groups (FRM_*, ANM_*): { name, pal_off, pal_size, { {off, size}, ... } }
-- Chunks are concatenated in order (as the engine does) and then scanned for sparse RLE frames.
local CD_ANIM_GROUPS = {
    {"Philip Vodka (ANM)", 0x1b031c, 768, {{0x19e46f, 24175}}},
    {"Park (FRM)", 0x40263d, 624, {{0x3ed1d9, 30376}, {0x3f4881, 62}, {0x3f48bf, 3969}, {0x3f5840, 3150}}},
    {"College Stairs First Floor (FRM)", 0x440b7d, 624, {{0x428c70, 48790}, {0x434b06, 140}}},
    {"Women Toilets (FRM)", 0x51cc24, 624, {{0x50c907, 854}, {0x50cc5d, 12}, {0x50cc69, 2744}, {0x50d721, 12855}, {0x510958, 102}}},
    {"Margaret Room (FRM)", 0x56a422, 768, {{0x5509d4, 10853}, {0x553439, 16}, {0x553449, 44564}, {0x55e25d, 80}}},
    {"Laboratory (FRM)", 0x58946c, 624, {{0x5763a3, 2254}, {0x576c71, 26218}, {0x57d2db, 128}}},
    {"Spring Rock (FRM)", 0x7ee1e6, 720, {{0x6ba53e, 84}, {0x6ba592, 759}, {0x6ba889, 5145}, {0x6bbca2, 4508}, {0x6bce3e, 13364}, {0x6c0272, 54}}},
    {"Park Laura (FRM)", 0x40263d, 624, {{0x3d58a5, 40622}, {0x3df753, 114}, {0x3df7c5, 48}}},
    {"Dean Pepper Office (FRM)", 0x74404e, 624, {{0x729b38, 2448}, {0x72a4c8, 2254}, {0x72ad96, 2744}, {0x72b84e, 2652}, {0x72c2aa, 2842}, {0x72cdc4, 2842}, {0x72d8de, 4293}, {0x72e9a3, 3850}, {0x72f8ad, 4704}, {0x730b0d, 1800}, {0x731215, 3480}, {0x731fad, 20}, {0x731fc1, 5075}, {0x733394, 620}, {0x733600, 18298}, {0x737d7a, 38}}},
    {"Philip Laura Intro (ANM)", 0x1b031c, 768, {{0x7cb4d4, 29824}}},
    {"Laura Intro (ANM)", 0x1b031c, 768, {{0x7d299e, 12793}}},
    {"Outside Church (FRM)", 0x674915, 624, {{0x661f88, 1869}, {0x6626d5, 20}, {0x6626e9, 2472}, {0x663091, 16}, {0x6630a1, 5147}, {0x6644bc, 14}, {0x6644ca, 5145}, {0x65b469, 27365}, {0x661f4e, 58}, {0x6658e3, 6805}, {0x667378, 14}, {0x667386, 5145}}},
    {"Church Puzzle (FRM)", 0x63ae11, 624, {{0x621cd1, 980}, {0x6220a5, 945}, {0x622456, 1794}, {0x623418, 2106}, {0x623c52, 1260}, {0x62413e, 1036}, {0x62454a, 1053}, {0x624967, 6}, {0x62496d, 26980}, {0x62b2d1, 120}, {0x62b349, 11607}, {0x62e0a0, 20}, {0x622b58, 2240}, {0x62e0b4, 2904}}},
    {"Library (FRM)", 0x6ee5c1, 624, {{0x6d9108, 2254}, {0x6d99d6, 18823}, {0x6de35d, 50}, {0x6de38f, 1440}, {0x6de92f, 14616}}},
    {"Numbers Paper (FRM)", 0x1b031c, 768, {{0x8728d1, 51163}, {0x87f0ac, 40}}},
}

-- CD: Text resources
local CD_TEXTS = {
    {"Main Text Table", 0x8499e0, 28028},
}

-- ============================================================================
-- CD: Sound effects (VOC files in IGOR.DAT)
-- ============================================================================
-- The Spanish CD ships its audio as contiguous Creative Voice File (.VOC)
-- chunks inside IGOR.DAT (61,682,719 bytes), indexed by a flat 1400-entry
-- table of file offsets (scummvm-create-igortbl/fsd_sp_cdrom.h). The game's
-- playSound(num, 1) helper looks sound effects up directly (1-based num ->
-- table slot num-1); indices 0-99 hold the sound effects (slot 0 and most of
-- the 69-99 range are empty), while indices 100+ hold the talkie voice acting.
-- Duplicated offsets are deliberate aliases (several ids map to the same
-- sound) and are kept verbatim so every game-referenced sound id is listed.
-- A zero offset means the slot is unused.
local CD_SOUND_OFFSETS = {
    0x00000000, 0x0000389B, 0x00007136, 0x0000A62E, 0x0000D14D, 0x0000ED67, 0x00010EF1, 0x00015FE9,
    0x00019BED, 0x0001B9B5, 0x0001EEBF, 0x0002D8AB, 0x0003E6A9, 0x0003F28B, 0x0003FA71, 0x000421D8,
    0x00049770, 0x00049770, 0x0004DEAA, 0x0005799A, 0x0005799A, 0x0005C030, 0x0005FB21, 0x00064019,
    0x000721AE, 0x00075C75, 0x00086004, 0x000882A3, 0x0008EC00, 0x000947B7, 0x000AA97E, 0x000AC589,
    0x000B3710, 0x000BFC96, 0x000C3185, 0x000D3F38, 0x000DEFB2, 0x000F7BE5, 0x000FE9BF, 0x0010279A,
    0x00108F55, 0x0010F750, 0x00137731, 0x0015218E, 0x0017109E, 0x00195C3C, 0x00198865, 0x001B2083,
    0x001B5622, 0x001BAE8D, 0x001BAE8D, 0x001BB2DA, 0x001BB2DA, 0x001BB2DA, 0x001C51F6, 0x001E3AC6,
    0x001ED144, 0x0020494C, 0x002151AC, 0x0021DC41, 0x00223F69, 0x0022DFF7, 0x0023CC8A, 0x0023D0D7,
    0x0024CC0F, 0x0024EF89, 0x00250225, 0x0025236A, 0x002562EB, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x002562EB, 0x00258EEA, 0x0025CC76,
    0x0025F1E8, 0x00263739, 0x00267E3B, 0x0026D886, 0x00271B45, 0x00275A31, 0x0027AE2A, 0x00281B73,
    0x00286C0F, 0x0028CC11, 0x00294F29, 0x0029AB14, 0x002A13B7, 0x002A7F7F, 0x002ADDCA, 0x002B2B99,
    0x002B80D1, 0x002BFDDE, 0x002C5ACA, 0x002CA9D6, 0x002CF42C, 0x002D2C03, 0x002D68C3, 0x002DBD34,
    0x002DE990, 0x002E256B, 0x002ECCAF, 0x002F2E45, 0x002F84C1, 0x00302DC1, 0x0030AB58, 0x00315870,
    0x0031EE0C, 0x00337507, 0x0033F4EF, 0x0034D167, 0x00357F2D, 0x00361D73, 0x0036A623, 0x003738EB,
    0x0037AF74, 0x003847D3, 0x00397260, 0x0039B53F, 0x003A860D, 0x003B12E2, 0x003B8051, 0x003C0167,
    0x003CF502, 0x003D3CFC, 0x003DD257, 0x003E13A5, 0x003E795F, 0x003F2953, 0x003FD007, 0x004098A6,
    0x00415A31, 0x00420B57, 0x0043BA62, 0x00441D94, 0x0044E70D, 0x0045180F, 0x0046B5DE, 0x00476CAB,
    0x00487702, 0x00492A30, 0x004A385F, 0x004AC5CE, 0x004BE57B, 0x004C99AF, 0x004D68BD, 0x004E0724,
    0x005007EA, 0x00519053, 0x0052CFAF, 0x0053E712, 0x00556525, 0x00563841, 0x00571D85, 0x0057CCA8,
    0x0058A3F2, 0x00590D15, 0x0059725A, 0x0059D8F5, 0x005A77CE, 0x005B09FE, 0x005B997F, 0x005C4845,
    0x005CC6B5, 0x005CF32B, 0x005D683C, 0x005DCD10, 0x005EAC1D, 0x005F1FDA, 0x005F5C7A, 0x005FC681,
    0x0060AF8F, 0x00620A08, 0x00626B46, 0x006347DD, 0x0064699E, 0x0064CD27, 0x00657491, 0x00667D74,
    0x0066E840, 0x00674296, 0x0067C0A1, 0x00683E1C, 0x0068AF93, 0x00694B3B, 0x006A1038, 0x006AAE76,
    0x006B4A7B, 0x006BFF65, 0x006CB30E, 0x006D5D2F, 0x006E0E2C, 0x006EA6C4, 0x006F491F, 0x006FB4BC,
    0x006FF055, 0x0070D348, 0x00715808, 0x0071BBFA, 0x007200D6, 0x00752FD2, 0x0075AC0A, 0x0075E845,
    0x0076BC42, 0x00776E7A, 0x00781DCE, 0x0078AD3B, 0x0079EF4B, 0x007AD5EC, 0x007B14EA, 0x007B8F1F,
    0x007CB7D3, 0x007D5C61, 0x007E39EA, 0x007E8D0A, 0x007EC07D, 0x00803525, 0x0082BE8A, 0x0083072A,
    0x00849330, 0x00854E38, 0x0085CC2C, 0x0086176D, 0x008693CF, 0x0086E743, 0x00879CE9, 0x0088527C,
    0x00892786, 0x0089ED3B, 0x008A6238, 0x008B9093, 0x008C172A, 0x008D14AC, 0x008D8F27, 0x008E4D2F,
    0x008EA409, 0x008FA528, 0x0090365B, 0x00906E9A, 0x00910D3F, 0x009186F9, 0x00922546, 0x0092D6B0,
    0x009378CF, 0x009413D2, 0x0094913D, 0x0094E41E, 0x0095555C, 0x0095C3FC, 0x0096398E, 0x0096AC28,
    0x00972761, 0x0097EA93, 0x009881AC, 0x009953CE, 0x009A438D, 0x009AD86F, 0x009B2E9C, 0x009B88BA,
    0x009BC845, 0x009CC44A, 0x009D5150, 0x009DBF5C, 0x009E515B, 0x009EA1B4, 0x009F2C02, 0x009F9B60,
    0x00A0495C, 0x00A0EB51, 0x00A19E57, 0x00A2876C, 0x00A39882, 0x00A41678, 0x00A4641A, 0x00A500A9,
    0x00A58786, 0x00A5F2D0, 0x00A78A9E, 0x00A87B53, 0x00A95618, 0x00AA353F, 0x00AB993F, 0x00ABC3A5,
    0x00AC62A5, 0x00ACF4E2, 0x00ADB3B2, 0x00AEA445, 0x00B081E1, 0x00B11E8D, 0x00B38EDA, 0x00B486A8,
    0x00B5C455, 0x00BA8DC1, 0x00BCC7EF, 0x00BE8202, 0x00BEE81E, 0x00BFCEF8, 0x00C0014F, 0x00C1963F,
    0x00C20C86, 0x00C2604D, 0x00C32159, 0x00C3E694, 0x00C49BE5, 0x00C5E5B7, 0x00C68631, 0x00C74AF9,
    0x00C7DA16, 0x00C868E5, 0x00C934FC, 0x00C9976F, 0x00CA3E80, 0x00CAA292, 0x00CAEB0D, 0x00CB4B8B,
    0x00CC2F5B, 0x00CCADB0, 0x00CD3693, 0x00CDD1EE, 0x00CE2359, 0x00CED11F, 0x00CF3DCD, 0x00CFB443,
    0x00D04753, 0x00D12989, 0x00D1F5F4, 0x00D2C157, 0x00D33A71, 0x00D42E5A, 0x00D46B32, 0x00D4D4F8,
    0x00D56C11, 0x00D6101F, 0x00D68CBA, 0x00D73BB4, 0x00D78291, 0x00D7F628, 0x00D883D9, 0x00D8C30F,
    0x00D94181, 0x00D9B768, 0x00DA2F85, 0x00DAB2AA, 0x00DB260F, 0x00DB6299, 0x00DC3976, 0x00DD45BB,
    0x00DE8FD5, 0x00DFCDEF, 0x00E040F0, 0x00E0D080, 0x00E14243, 0x00E1BC26, 0x00E271D6, 0x00E33059,
    0x00E3B378, 0x00E420CC, 0x00E48D52, 0x00E5A1C7, 0x00E69C6A, 0x00E6F237, 0x00E77128, 0x00E7AF6E,
    0x00E825D3, 0x00E8A059, 0x00E8FCB3, 0x00E99589, 0x00EB31DB, 0x00EB9202, 0x00EC3B10, 0x00ECADE9,
    0x00ED90B0, 0x00EE7657, 0x00EF092F, 0x00EF6C99, 0x00EF9E43, 0x00F057B3, 0x00F222B0, 0x00F2EBAB,
    0x00F3415C, 0x00F3A96D, 0x00F4709A, 0x00F55514, 0x00F61228, 0x00F6E246, 0x00F77081, 0x00F7D383,
    0x00F8881B, 0x00FA2559, 0x00FB4F2B, 0x00FBF49D, 0x00FD1566, 0x00FE30F9, 0x00FEF9A9, 0x00FF98DC,
    0x0100BDB7, 0x01011DB0, 0x0101DAB2, 0x0102970E, 0x0102CA15, 0x01030E27, 0x0103B1FA, 0x01046827,
    0x01051282, 0x01055FDF, 0x0105D177, 0x010741C8, 0x0107C01F, 0x01091815, 0x01097C92, 0x010A8E18,
    0x010AD64E, 0x010C1C94, 0x010DCEAB, 0x010E9E0A, 0x010F68A8, 0x0110213D, 0x0110BA7F, 0x01112247,
    0x0111BB13, 0x01129C45, 0x01134C76, 0x01140640, 0x0114CDBC, 0x01153E40, 0x0115E155, 0x01162D73,
    0x0116C108, 0x01172275, 0x0117BC59, 0x011839CE, 0x0118CEAA, 0x01197CD9, 0x011A40B3, 0x011B456E,
    0x011C0FAF, 0x011CD84B, 0x011DD309, 0x011E623B, 0x011F00BF, 0x011F6A0A, 0x012029CD, 0x0120C9B7,
    0x01219EE9, 0x01221674, 0x012266FD, 0x0124A3A8, 0x0125A235, 0x012606E0, 0x01274253, 0x0128A9BA,
    0x012A4BDB, 0x012C4BDD, 0x0130382B, 0x01308697, 0x013211CE, 0x0132CB15, 0x01333993, 0x013419A0,
    0x01349D9C, 0x01355C72, 0x01367450, 0x01374FC1, 0x0139CFAA, 0x013A7B93, 0x013DC4F0, 0x013E7BED,
    0x013F1605, 0x013FBB12, 0x01403274, 0x0140A7BD, 0x014121CC, 0x0141B0B5, 0x01423B22, 0x0142A176,
    0x014334E4, 0x0143C963, 0x01448943, 0x01457F98, 0x01463FD6, 0x01471CE2, 0x0148DBCF, 0x01497123,
    0x014A6291, 0x014B0486, 0x014B83FC, 0x014C1BC4, 0x014C560C, 0x014D03C9, 0x014DC603, 0x014EDCB8,
    0x014F7052, 0x0151325C, 0x01530305, 0x01548FB3, 0x01553071, 0x0155D421, 0x0156521D, 0x0156DDA1,
    0x01579F80, 0x01582C70, 0x0158A3DC, 0x0159232D, 0x0159A2C2, 0x015A6B2C, 0x015B194C, 0x015BE013,
    0x015C1B93, 0x015CA329, 0x015D18C4, 0x015DDAE8, 0x015E720A, 0x015EFD3D, 0x015FAB3A, 0x0160371A,
    0x016095E1, 0x016147E0, 0x0161F4F1, 0x0162CF2E, 0x016317E1, 0x0163E7D2, 0x01652C0B, 0x0165AC19,
    0x01663C7F, 0x0166C0DB, 0x01671F31, 0x01677503, 0x01681221, 0x0168A31E, 0x016923EC, 0x0169A911,
    0x0169FCD7, 0x016AA95A, 0x016BB4B8, 0x016C1862, 0x016CF45C, 0x016D859B, 0x016E23A2, 0x016F01DF,
    0x016F65C5, 0x016FFBF7, 0x01702D63, 0x0170F542, 0x0171E8A4, 0x017273C7, 0x017333D7, 0x0173AC69,
    0x01741DB2, 0x0174723C, 0x01752C05, 0x017613B3, 0x0177194F, 0x0177CC16, 0x017854A7, 0x017905A1,
    0x017987E6, 0x017A7B8C, 0x017B6C86, 0x017C2C5E, 0x017D0D6F, 0x017E1CBF, 0x017E5A7A, 0x017E8A6F,
    0x017EDDE2, 0x017F4FBF, 0x017FB374, 0x01802970, 0x01806C0E, 0x0180EC03, 0x0181417E, 0x01819E60,
    0x0182213B, 0x01828E4D, 0x0182CF0A, 0x01832B53, 0x018365C4, 0x0183C4D1, 0x01842220, 0x01845CCA,
    0x0184CFFB, 0x0185AD72, 0x0186449C, 0x018681D4, 0x01872E14, 0x0187FDA3, 0x0188B9E3, 0x0188FA10,
    0x01896B51, 0x0189DFCE, 0x018A9965, 0x018B70CF, 0x018C25E7, 0x018CA9CE, 0x018CFF5D, 0x018D5A6A,
    0x018D8FEE, 0x018DAD66, 0x018DFEC8, 0x018E45EF, 0x018E6790, 0x018F22DC, 0x01900277, 0x0190D186,
    0x0191A385, 0x0192653F, 0x0192B2EE, 0x01934F4D, 0x0193FE64, 0x0194ED24, 0x01955CD4, 0x0195979F,
    0x019623B0, 0x01972FE0, 0x0197B7E9, 0x019824C5, 0x01984433, 0x01987C94, 0x019A9057, 0x019B4A20,
    0x019D06BB, 0x019DC68B, 0x019E9F06, 0x019F13CA, 0x019F9A47, 0x01A02FC4, 0x01A0B4EB, 0x01A14A5F,
    0x01A273D5, 0x01A33BF0, 0x01A4352F, 0x01A55A5D, 0x01A6B328, 0x01A7B512, 0x01A95149, 0x01AA2B8C,
    0x01AB21DE, 0x01AB99BC, 0x01AC27A1, 0x01AD0577, 0x01AD8DF3, 0x01AE6E03, 0x01AFE2CE, 0x01B147C4,
    0x01B21E4D, 0x01B30AA8, 0x01B563F7, 0x01B8AD9F, 0x01BA1B2C, 0x01BC734F, 0x01BCC36C, 0x01BF8F29,
    0x01C04A7C, 0x01C0956F, 0x01C0D5EC, 0x01C18F59, 0x01C23DD5, 0x01C290F4, 0x01C326F3, 0x01C4B707,
    0x01C6EAAA, 0x01C82FDF, 0x01C8F5B5, 0x01CA0C3A, 0x01CB67C4, 0x01CC43F5, 0x01CC9F20, 0x01CD119F,
    0x01CD7672, 0x01CDF9A2, 0x01CE891A, 0x01CF36E0, 0x01D01C05, 0x01D0554F, 0x01D0EB0C, 0x01D147B0,
    0x01D17F16, 0x01D1D74B, 0x01D29987, 0x01D361DE, 0x01D41796, 0x01D4B527, 0x01D56640, 0x01D5F471,
    0x01D6D273, 0x01D746CC, 0x01D8146F, 0x01D8783D, 0x01D91939, 0x01D9C78F, 0x01DA8693, 0x01DB37A9,
    0x01DB841E, 0x01DBFEE9, 0x01DC659C, 0x01DCDB21, 0x01DD6345, 0x01DDE3DF, 0x01DE3FBA, 0x01DE8C25,
    0x01DF3F76, 0x01DFEE1D, 0x01E0368F, 0x01E091F6, 0x01E11C14, 0x01E17F1C, 0x01E2329B, 0x01E2929D,
    0x01E3A16C, 0x01E4CDE0, 0x01E61880, 0x01E6C219, 0x01E81112, 0x01E8D86B, 0x01E95E62, 0x01EA0312,
    0x01EA8D5B, 0x01EB3E78, 0x01EBE1B6, 0x01EDDBB6, 0x01EE6489, 0x01EF004D, 0x01EF8226, 0x01F06640,
    0x01F12647, 0x01F1CCE6, 0x01F2C8B3, 0x01F34FDD, 0x01F3AC85, 0x01F46D6D, 0x01F4EA3B, 0x01F5B4DB,
    0x01F6B62B, 0x01F72E1A, 0x01F7AFB1, 0x01F82601, 0x01F87BE8, 0x01F9AF24, 0x01FA1630, 0x01FA8433,
    0x01FB0131, 0x01FB66B4, 0x01FBBCD6, 0x01FC369F, 0x01FD535B, 0x01FED07B, 0x01FF7C14, 0x020108F8,
    0x020193D3, 0x0201F609, 0x0202C410, 0x02039781, 0x0203F529, 0x02049C13, 0x0204D48F, 0x02055FB9,
    0x02068E92, 0x0206EE85, 0x02073D55, 0x020770E3, 0x02081FDC, 0x02089A31, 0x02092945, 0x020A1178,
    0x020AAFD2, 0x020B354D, 0x020BE79E, 0x020C3E2D, 0x020CF672, 0x020DF203, 0x020E33C4, 0x020ECA26,
    0x020FD673, 0x02103CBA, 0x0210F178, 0x021179EA, 0x02125446, 0x021307CA, 0x0213FF71, 0x02148B68,
    0x02153D18, 0x0215CCFB, 0x021694AC, 0x02176970, 0x0217E0FE, 0x021854A4, 0x0218D096, 0x021915F5,
    0x02198172, 0x0219B930, 0x021A29D0, 0x021A8BBB, 0x021B22D1, 0x021BDA2F, 0x021CDA50, 0x021D5171,
    0x021DF008, 0x021EFBA3, 0x021F9AB7, 0x021FDD32, 0x0220E271, 0x0223001C, 0x02238AC0, 0x0224631B,
    0x0224A565, 0x022542A5, 0x02260BD5, 0x0226DDB8, 0x02273044, 0x022780F4, 0x0227FF6A, 0x0229676C,
    0x02299ACA, 0x022A1EF6, 0x022B6695, 0x022C6F14, 0x022D2465, 0x022E2503, 0x022E666C, 0x022E9814,
    0x022F33E9, 0x022FE3E0, 0x0230267D, 0x02309AA5, 0x023123F6, 0x0231D227, 0x02329C30, 0x023320A3,
    0x0233955A, 0x02345590, 0x0234FAA7, 0x0235F540, 0x02361E59, 0x02365A4E, 0x0236AFEB, 0x02377334,
    0x0238751A, 0x023960E3, 0x023A431E, 0x023B149B, 0x023BB74F, 0x023C5028, 0x023D809C, 0x023E8FEE,
    0x023F20ED, 0x023FED33, 0x0240B61F, 0x0241C490, 0x02427199, 0x02436945, 0x02446F5C, 0x02449917,
    0x0244EA60, 0x0245351D, 0x02458A26, 0x02462C58, 0x0246483B, 0x024667CE, 0x0246B66C, 0x02473FDC,
    0x02475F2A, 0x0248037E, 0x024905AE, 0x024995CC, 0x024A4478, 0x024AC460, 0x024B69A3, 0x024C7989,
    0x024D15B0, 0x024E6987, 0x024F312E, 0x024FF7AB, 0x0250C6BD, 0x02519535, 0x02522492, 0x0252B5B8,
    0x02537EB5, 0x0253E015, 0x02542CA2, 0x025521E3, 0x0255CC75, 0x02569ABF, 0x0257AA4A, 0x02583AAD,
    0x02595045, 0x025AA5DA, 0x025B9C9B, 0x025C802B, 0x025D5C2C, 0x025DAA3F, 0x025ED273, 0x02603727,
    0x02614F13, 0x02635C7B, 0x02652951, 0x026677EC, 0x0267F189, 0x0268CB37, 0x0269BFA4, 0x026ADA78,
    0x026C2754, 0x026CAFD8, 0x026DAF9D, 0x026EAE12, 0x026FF698, 0x02708762, 0x02710F9A, 0x0271E22F,
    0x02733BBB, 0x0273F98E, 0x0274D94A, 0x0275397A, 0x02765E58, 0x0276E66D, 0x0277BE78, 0x0278897F,
    0x0278EA4E, 0x0279DC65, 0x027B17A2, 0x027BD0B9, 0x027CFE22, 0x027E343E, 0x027F04AB, 0x02803B7A,
    0x0281129C, 0x0281F59D, 0x028281FF, 0x02839721, 0x02847BE3, 0x0285367B, 0x0285C3B8, 0x0286755A,
    0x0286F716, 0x02876BAE, 0x0287D763, 0x02884A52, 0x0288C975, 0x02891022, 0x02898301, 0x0289B9A7,
    0x028B27CC, 0x028B8F8A, 0x028DB6D9, 0x02905423, 0x029125D6, 0x02915320, 0x0291777F, 0x0291D75A,
    0x02935ABF, 0x0293D317, 0x02945FBA, 0x02950462, 0x0295787D, 0x029607BF, 0x0296C3AE, 0x029728C8,
    0x0297B33F, 0x02982CDE, 0x0298B805, 0x029A7345, 0x029AF080, 0x029C2347, 0x029C9652, 0x029CDCBC,
    0x029D394B, 0x029DCDF6, 0x029E4203, 0x029F2EB2, 0x02A07209, 0x02A11B6A, 0x02A1A75A, 0x02A21ACF,
    0x02A2830C, 0x02A2D7CF, 0x02A32984, 0x02A378F8, 0x02A40A4D, 0x02A4792A, 0x02A5513C, 0x02A5AC34,
    0x02A6737E, 0x02A72E9C, 0x02A7AC77, 0x02A7FE07, 0x02A86486, 0x02A8C2E1, 0x02A922E6, 0x02A9905F,
    0x02AA5BDC, 0x02AAB91A, 0x02AB7DD9, 0x02ABF2FD, 0x02AC7221, 0x02AEC7D4, 0x02AF833F, 0x02B09CEA,
    0x02B16679, 0x02B247B6, 0x02B374E0, 0x02B4761E, 0x02B50BE5, 0x02B6991F, 0x02B6F4D1, 0x02B83B46,
    0x02B982BA, 0x02BA6E2F, 0x02BB3FC0, 0x02BBAB63, 0x02BC7E16, 0x02BCF984, 0x02BDE5D8, 0x02BE8C9B,
    0x02BEF31A, 0x02BFA865, 0x02BFF484, 0x02C08864, 0x02C16B17, 0x02C1D56D, 0x02C26DA8, 0x02C32129,
    0x02C3C7E6, 0x02C43BCB, 0x02C4BAD4, 0x02C509A8, 0x02C5E4E1, 0x02C69201, 0x02C7D26F, 0x02C8A8E2,
    0x02C97226, 0x02C9D855, 0x02CA4881, 0x02CB185E, 0x02CBCCB5, 0x02CC12C9, 0x02CC8C05, 0x02CD3600,
    0x02CF2B8B, 0x02D05BCD, 0x02D11FEE, 0x02D23CEF, 0x02D3673E, 0x02D55953, 0x02D5F6D3, 0x02D6513B,
    0x02D69333, 0x02D731B3, 0x02D7EED3, 0x02D8D0CC, 0x02D93499, 0x02D9F1AB, 0x02DAA7B7, 0x02DB28AB,
    0x02DB87E0, 0x02DC91AC, 0x02DD2817, 0x02DE494A, 0x02DFA60F, 0x02E096E1, 0x02E1CAD2, 0x02E2E803,
    0x02E381B3, 0x02E42949, 0x02E4C396, 0x02E5A366, 0x02E5FCA7, 0x02E6C16B, 0x02E74B79, 0x02E869C6,
    0x02E90719, 0x02EAABAC, 0x02EB034D, 0x02EB8453, 0x02EC1112, 0x02EC72CC, 0x02ED9EBC, 0x02EE181D,
    0x02EE78CA, 0x02EF4686, 0x02F04E10, 0x02F11E1B, 0x02F176D6, 0x02F22796, 0x02F2DDC5, 0x02F3951E,
    0x02F429E2, 0x02F48FB9, 0x02F536CA, 0x02F5D15E, 0x02F69932, 0x02F764D1, 0x02F8186A, 0x02F8E6EF,
    0x02F99E7B, 0x02F9EC4D, 0x02FA57F3, 0x02FB2C78, 0x02FBB66C, 0x02FC5F7C, 0x02FD00BC, 0x02FDABDF,
    0x02FE2E89, 0x02FEFFDF, 0x02FF94A9, 0x02FFD5FB, 0x03005F21, 0x0300C1B6, 0x03012E9D, 0x030198CB,
    0x0301F4BE, 0x0302594C, 0x0302B864, 0x03031F36, 0x0303803F, 0x0303D40A, 0x0304394E, 0x03049D46,
    0x03050804, 0x03055479, 0x0305B53C, 0x03063476, 0x0306977F, 0x0306F2CB, 0x03079DAD, 0x0308328D,
    0x0308CC43, 0x03095169, 0x0309D62B, 0x030A4FAC, 0x030AC090, 0x030B6F48, 0x030C2B03, 0x030CD10C,
    0x030D6F76, 0x030E0892, 0x030EE5BD, 0x030F84B7, 0x03108C22, 0x0311224D, 0x03117972, 0x0311F52D,
    0x03126566, 0x0312D507, 0x03136F50, 0x031427F5, 0x031516D4, 0x0315B519, 0x03167812, 0x03171EF2,
    0x0317EDFD, 0x0318B191, 0x031954B4, 0x0319E6BC, 0x031A5986, 0x031B3405, 0x031BDD69, 0x031CCE81,
    0x031D524F, 0x031E437C, 0x031EF761, 0x031FB008, 0x0320BD69, 0x0321FC07, 0x03229992, 0x03239570,
    0x032440FE, 0x032513A2, 0x0325C205, 0x03263BBA, 0x0326FC95, 0x0327D2B9, 0x03288EC2, 0x03295398,
    0x032A015A, 0x032A6383, 0x032B3C73, 0x032BEF25, 0x032C9531, 0x032D570B, 0x032E13C9, 0x032EC9EC,
    0x032F56F1, 0x033010BF, 0x0330FABD, 0x03315260, 0x0331C9F3, 0x03329A01, 0x033397DA, 0x03342635,
    0x033466AA, 0x033564FA, 0x03362F5F, 0x03367432, 0x03370CC6, 0x0337C9A2, 0x03388450, 0x03398DE0,
    0x033AA843, 0x033B429F, 0x033C00BA, 0x033D5895, 0x033EADA3, 0x033F3F44, 0x03402E86, 0x03412F18,
    0x0342D61C, 0x03433558, 0x03442648, 0x034443FA, 0x0344B0DE, 0x0344E4CF, 0x0345AF5E, 0x0345EFEE,
    0x03465E91, 0x0346EA4D, 0x034797EB, 0x0348DDCD, 0x0349335C, 0x0349C9C1, 0x034A7167, 0x034AA3BC,
    0x034ADF3D, 0x034B1C86, 0x034BC9FC, 0x034C4053, 0x034D4C72, 0x034E7513, 0x034F2C86, 0x034FF2AF,
    0x0350DC18, 0x0351290B, 0x0351F343, 0x03529835, 0x03538765, 0x0353BEC8, 0x0353EBB3, 0x03547235,
    0x03551655, 0x0355956D, 0x03567B40, 0x035710F2, 0x0357A5BF, 0x0358584D, 0x03596C6B, 0x0359F993,
    0x035AD493, 0x035BAE2D, 0x035CD255, 0x035DA892, 0x035DE230, 0x035E3296, 0x035ECA66, 0x035F2D99,
    0x035FB284, 0x03605391, 0x0360B211, 0x0361129B, 0x0361AD95, 0x03623915, 0x0362E3CE, 0x036397B3,
    0x03647C45, 0x0365051B, 0x036540AD, 0x03667677, 0x03674BD2, 0x03677BC1, 0x0367D1F6, 0x03687B22,
    0x03691655, 0x036A5A00, 0x036A9F70, 0x036B152B, 0x036B4847, 0x036BE804, 0x036C666F, 0x036CD9CD,
    0x036D5D73, 0x036E67FE, 0x036EF80C, 0x036F85C3, 0x037028CC, 0x03719A74, 0x0372CF5D, 0x0373E91E,
    0x03745C12, 0x037509F0, 0x03758F54, 0x03769982, 0x03775F3B, 0x037800AC, 0x03796D3F, 0x0379FB7B,
    0x037A99DE, 0x037B514D, 0x037C2C5F, 0x037D197F, 0x037D7251, 0x037E1164, 0x037EC658, 0x037F1E9D,
    0x037FB90E, 0x03805AF1, 0x0380F25C, 0x0381994C, 0x0381C203, 0x0381FF6E, 0x0382B850, 0x0383BF3E,
    0x0384687C, 0x0384CB15, 0x0385AC30, 0x03861A0C, 0x038696B2, 0x03874D73, 0x0387B53A, 0x03895F1C,
    0x038A1039, 0x038AF204, 0x038C7F6D, 0x038D48A2, 0x038DE58F, 0x038E76D7, 0x038F6255, 0x03900188,
    0x0390A632, 0x03922200, 0x03935472, 0x0393A890, 0x0394801C, 0x03950A6F, 0x03959A22, 0x0395F6F1,
    0x03964BBC, 0x0396B5BE, 0x03974B4E, 0x03984580, 0x039929FA, 0x039A679E, 0x039B5769, 0x039BD9D2,
    0x039C504A, 0x039CCE46, 0x039DE754, 0x039F51DE, 0x039FD198, 0x03A066FC, 0x03A185F3, 0x03A1EAD3,
    0x03A2282C, 0x03A28D9C, 0x03A32AD7, 0x03A3B1BE, 0x03A3FAF0, 0x03A46FA7, 0x03A513CC, 0x03A617CD,
    0x03A6DB16, 0x03A81798, 0x03A85846, 0x03A90222, 0x03A9F226, 0x03AA4DF3, 0x03AA8AB9, 0x03ABDE84,
    0x03AC9DF3, 0x03AD341F, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
}

-- ============================================================================
-- CD speech (talkie voice acting in IGOR.DAT)
-- ============================================================================
-- Speech clip ids referenced by ADD_DIALOGUE_TEXT, in id order.
-- { speech id, text index, line count, source }  source "main" = the global
-- dialogue table in IGOR.EXE; otherwise a CD_ROOMS name (its TXT_ block).
local CD_SPEECH_DIALOGUE = {
    {4, 4, 1, "main"},
    {5, 5, 1, "main"},
    {6, 6, 1, "main"},
    {7, 7, 1, "main"},
    {8, 8, 1, "main"},
    {9, 9, 1, "main"},
    {10, 10, 1, "main"},
    {15, 15, 1, "main"},
    {18, 18, 1, "main"},
    {19, 19, 1, "main"},
    {22, 22, 1, "main"},
    {23, 23, 1, "main"},
    {24, 24, 1, "main"},
    {25, 25, 1, "main"},
    {28, 28, 1, "main"},
    {29, 29, 1, "main"},
    {30, 30, 1, "main"},
    {31, 31, 1, "main"},
    {32, 51, 1, "main"},
    {33, 52, 1, "main"},
    {34, 53, 1, "main"},
    {35, 54, 1, "main"},
    {36, 55, 3, "main"},
    {37, 58, 1, "main"},
    {38, 59, 2, "main"},
    {39, 61, 1, "main"},
    {40, 62, 1, "main"},
    {41, 63, 1, "main"},
    {42, 64, 1, "main"},
    {43, 65, 1, "main"},
    {44, 66, 1, "main"},
    {45, 67, 2, "main"},
    {46, 69, 1, "main"},
    {47, 70, 1, "main"},
    {48, 71, 1, "main"},
    {49, 72, 1, "main"},
    {50, 73, 1, "main"},
    {51, 74, 2, "main"},
    {52, 76, 1, "main"},
    {56, 80, 1, "main"},
    {57, 81, 1, "main"},
    {58, 82, 1, "main"},
    {59, 83, 2, "main"},
    {60, 85, 1, "main"},
    {61, 86, 2, "main"},
    {62, 88, 1, "main"},
    {63, 89, 2, "main"},
    {64, 92, 1, "main"},
    {65, 93, 3, "main"},
    {66, 96, 1, "main"},
    {67, 97, 2, "main"},
    {68, 99, 1, "main"},
    {69, 100, 2, "main"},
    {70, 140, 1, "main"},
    {71, 141, 1, "main"},
    {72, 142, 1, "main"},
    {73, 143, 1, "main"},
    {74, 144, 1, "main"},
    {75, 145, 3, "main"},
    {76, 148, 2, "main"},
    {77, 150, 2, "main"},
    {78, 152, 1, "main"},
    {79, 153, 3, "main"},
    {80, 156, 1, "main"},
    {81, 157, 1, "main"},
    {82, 158, 1, "main"},
    {83, 159, 1, "main"},
    {84, 160, 1, "main"},
    {85, 161, 1, "main"},
    {86, 162, 1, "main"},
    {87, 163, 1, "main"},
    {88, 164, 1, "main"},
    {89, 165, 1, "main"},
    {90, 166, 1, "main"},
    {91, 167, 1, "main"},
    {92, 168, 1, "main"},
    {93, 169, 1, "main"},
    {94, 170, 1, "main"},
    {545, 201, 3, "Spring Bridge (Intro)"},
    {546, 204, 1, "Spring Bridge (Intro)"},
    {547, 205, 3, "Spring Bridge (Intro)"},
    {548, 208, 1, "Spring Bridge (Intro)"},
    {549, 209, 2, "Spring Bridge (Intro)"},
    {550, 211, 1, "Spring Bridge (Intro)"},
    {551, 212, 1, "Spring Bridge (Intro)"},
    {552, 213, 1, "Spring Bridge (Intro)"},
    {553, 214, 1, "Spring Bridge (Intro)"},
    {554, 215, 1, "Spring Bridge (Intro)"},
    {555, 216, 2, "Spring Bridge (Intro)"},
    {556, 218, 1, "Spring Bridge (Intro)"},
    {557, 219, 2, "Spring Bridge (Intro)"},
    {558, 221, 2, "Spring Bridge (Intro)"},
    {559, 223, 2, "Spring Bridge (Intro)"},
    {560, 225, 2, "Spring Bridge (Intro)"},
    {561, 227, 3, "Spring Bridge (Intro)"},
    {1097, 201, 1, "Margaret's Room"},
    {1098, 202, 1, "Margaret's Room"},
    {1099, 203, 1, "Margaret's Room"},
    {1100, 204, 1, "Margaret's Room"},
    {1101, 205, 1, "Margaret's Room"},
    {1102, 206, 1, "Margaret's Room"},
    {1103, 207, 1, "Margaret's Room"},
    {1104, 208, 1, "Margaret's Room"},
    {1105, 209, 1, "Margaret's Room"},
    {1106, 210, 1, "Margaret's Room"},
    {1107, 211, 1, "Margaret's Room"},
    {1108, 212, 1, "Margaret's Room"},
    {1109, 213, 2, "Margaret's Room"},
    {1110, 215, 1, "Margaret's Room"},
    {1111, 216, 1, "Margaret's Room"},
    {1112, 217, 1, "Margaret's Room"},
    {1113, 218, 1, "Margaret's Room"},
    {1114, 219, 1, "Margaret's Room"},
    {1115, 220, 1, "Margaret's Room"},
    {1116, 221, 1, "Margaret's Room"},
    {1117, 222, 1, "Margaret's Room"},
    {1118, 223, 1, "Margaret's Room"},
    {1119, 224, 1, "Margaret's Room"},
    {1120, 225, 1, "Margaret's Room"},
    {1156, 201, 1, "Philip's Room"},
    {1157, 202, 2, "Philip's Room"},
    {1158, 204, 1, "Philip's Room"},
    {1159, 205, 1, "Philip's Room"},
    {1160, 206, 1, "Philip's Room"},
}

-- Re-key the table above by speech id; it is stored in id order for readability
-- but callers only ever have an id to hand.
local CD_SPEECH_BY_ID = {}
for _, entry in ipairs(CD_SPEECH_DIALOGUE) do
    CD_SPEECH_BY_ID[entry[1]] = entry
end

-- ============================================================================
-- Floppy version (Spanish) - offsets into IGOR.DAT 11,199,335 bytes
-- Room backgrounds are NOT listed here as a static table: the floppy game is a
-- Borland Pascal overlay executable and its room images only exist inside
-- per-room overlay segments (see get_floppy_rooms() / parse_floppy_stubs()
-- below), not at fixed flat offsets. Only the fullscreen splash images and CMF
-- music below were reliably found via flat-file signature scanning.
-- ============================================================================

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
-- Floppy room backgrounds: real Borland Pascal overlay parsing
-- ============================================================================
-- The floppy IGOR.EXE (~95KB) is a Borland Pascal "overlay" stub file: each
-- room is compiled to its own overlay segment stored in IGOR.DAT, indexed by a
-- table of 32-byte stub headers embedded in IGOR.EXE (starting at a fixed file
-- offset). A previous version of this engine guessed room image offsets by
-- scanning IGOR.DAT for pixel-like byte runs, which does not reflect the real
-- file layout and never produced correct backgrounds. This replaces that with
-- the actual overlay format, reverse engineered by the cyxx/igor project
-- (docs/RE.md, overlay_exe.cpp, room.cpp - see engine-sources.md).
--
-- Stub header (32 bytes, little-endian):
--   u16 int_code   (0x3FCD magic = "INT 3Fh" opcode used as an overlay marker)
--   u16 memswap    (always 0 for a valid header)
--   u32 fileoff    offset of this segment's code+data in IGOR.DAT
--   u16 codesize   size of this segment in IGOR.DAT
--   u16 relsize
--   u16 nentries   number of far-jump trampoline entries following the header
--   u16 prevstub
--   ...16 bytes workarea, then `nentries` x 5-byte far jumps (padded to 16)
--
-- Many room segments end with a trailing [768-byte VGA palette][320x200 8bpp
-- image] blob immediately after the last "pop bp; retf" (bytes 5D CB) in the
-- segment's compiled code. That marker + exact trailing size is how the
-- reference tool (and this engine) locates the image within each segment.
-- ============================================================================

local STUB_HEADER_SIZE     = 32
local STUB_SCAN_START      = 0x19F0
local FULLSCREEN_BLOB_SIZE = 768 + 320 * 200 -- palette + 320x200 8bpp image

local function find_exe_file(game_path)
    local candidates = {
        game_path .. "/IGOR.EXE",
        game_path .. "/igor.exe",
    }
    for _, p in ipairs(candidates) do
        if file_exists(p) then return p end
    end
    return nil
end

-- Parse the Pascal overlay stub table embedded in the floppy IGOR.EXE.
-- Mirrors OverlayExecutable::parse(): scan 32-byte-aligned blocks from a fixed
-- start offset, recording valid stub headers and skipping their jump tables.
local function parse_floppy_stubs(exe_path)
    local fh = file_open(exe_path)
    if not fh then return {} end
    local exe_size = file_size(fh)

    local stubs = {}
    local pos = STUB_SCAN_START
    while pos + STUB_HEADER_SIZE <= exe_size do
        local hdr = file_read(fh, pos, STUB_HEADER_SIZE)
        if not hdr or #hdr < STUB_HEADER_SIZE then break end

        -- isPascalStub(): u16le(hdr,0)==0x3FCD (bytes CD,3F) and u16le(hdr,2)==0
        if hdr:byte(1) == 0xCD and hdr:byte(2) == 0x3F and hdr:byte(3) == 0 and hdr:byte(4) == 0 then
            local seg_offset = u32le(hdr, 5)
            local seg_size   = u16le(hdr, 9)
            local count      = u16le(hdr, 13)
            if seg_size ~= 0 then
                stubs[#stubs + 1] = { offset = seg_offset, size = seg_size }
                local jmp_size = math.floor((count * 5 + 15) / 16) * 16
                pos = pos + STUB_HEADER_SIZE + jmp_size
            else
                pos = pos + STUB_HEADER_SIZE
            end
        else
            pos = pos + STUB_HEADER_SIZE
        end
    end
    file_close(fh)
    return stubs
end

-- Scan one overlay segment (read from IGOR.DAT) for a trailing
-- [768-byte palette][320x200 image] blob, validating the palette is in the
-- legal 6-bit VGA range (0-63) before trusting the match.
local function scan_floppy_room_blob(dat_path, stub)
    local fh = file_open(dat_path)
    if not fh then return nil end
    local seg = file_read(fh, stub.offset, stub.size)
    file_close(fh)
    if not seg then return nil end

    local size = #seg
    local pos = size - 1
    while pos >= 1 do
        if seg:byte(pos) == 0x5D and seg:byte(pos + 1) == 0xCB then -- pop bp; retf
            local blob_start = pos + 2
            local blob_size = size - blob_start + 1
            if blob_size == FULLSCREEN_BLOB_SIZE then
                local pal_raw = seg:sub(blob_start, blob_start + 767)
                local pal_ok = #pal_raw == 768
                if pal_ok then
                    for i = 1, 768 do
                        if pal_raw:byte(i) > 63 then pal_ok = false; break end
                    end
                end
                if pal_ok then
                    local img_raw = seg:sub(blob_start + 768, blob_start + 768 + 320 * 200 - 1)
                    if #img_raw == 320 * 200 then
                        return pal_raw, img_raw
                    end
                end
            end
            break -- only the first marker found scanning backward is considered
        end
        pos = pos - 1
    end
    return nil
end

-- Cached per game_path: dynamically-discovered floppy rooms (name, stub info).
local _floppy_rooms_cache = nil
local _floppy_rooms_cache_path = nil

local function get_floppy_rooms(game_path, dat_path)
    if _floppy_rooms_cache and _floppy_rooms_cache_path == game_path then
        return _floppy_rooms_cache
    end
    local rooms = {}
    local exe_path = find_exe_file(game_path)
    if exe_path then
        local stubs = parse_floppy_stubs(exe_path)
        for i, stub in ipairs(stubs) do
            local pal_raw, img_raw = scan_floppy_room_blob(dat_path, stub)
            if pal_raw and img_raw then
                rooms[#rooms + 1] = {
                    string.format("Floppy Room %d", i),
                    stub.offset, stub.size, 0, 0, 0, 0, 0, 0, 0, 0,
                }
            end
        end
    end
    _floppy_rooms_cache = rooms
    _floppy_rooms_cache_path = game_path
    return rooms
end

-- ============================================================================
-- Palette loading
-- ============================================================================

local function read_palette(fh, pal_off, pal_size)
    if pal_off == 0 or pal_size == 0 then return nil end
    local pal_raw = file_read(fh, pal_off, pal_size)
    if not pal_raw then return nil end

    local palette = {}
    local out_of_range = 0
    -- Expand 6-bit VGA to 8-bit, padding to 768 entries
    local num_colors = math.floor(pal_size / 3)
    for i = 0, num_colors - 1 do
        local r, g, b = pal_raw:byte(i*3+1), pal_raw:byte(i*3+2), pal_raw:byte(i*3+3)
        if r > 63 or g > 63 or b > 63 then out_of_range = out_of_range + 1 end
        palette[i*3+1] = expand6(r)
        palette[i*3+2] = expand6(g)
        palette[i*3+3] = expand6(b)
    end
    -- Fill remaining entries with black
    for i = num_colors, 255 do
        palette[i*3+1] = 0
        palette[i*3+2] = 0
        palette[i*3+3] = 0
    end
    -- out_of_range > 0 means this palette almost certainly points at the wrong
    -- file offset (valid VGA DAC values are 0-63 per channel); surfaced to the
    -- caller so a bad room offset shows a warning instead of silently
    -- rendering blown-out/garbled colours.
    return palette, out_of_range
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
-- Fixed (non-room) palette ranges, as set up by the engine at runtime:
--   192..207 : Igor sprite colours   (PAL_IGOR_1,  16 colours)
--   208..239 : UI / dialogue colours (PAL_96_1,    32 colours)
--   240..255 : UI / text colours     (PAL_48_1,    16 colours)
-- Room palettes only define colours 0..191 (or 0..207), so UI panels, inventory
-- objects and sprites must overlay these ranges to get their real colours.
-- Values are 6-bit VGA.
-- ============================================================================

local PAL_IGOR_1 = {
    0x35,0x1F,0x17, 0x30,0x19,0x10, 0x25,0x13,0x0B, 0x1D,0x0E,0x05,
    0x06,0x06,0x06, 0x3E,0x3E,0x3E, 0x27,0x1A,0x00, 0x35,0x27,0x06,
    0x2B,0x26,0x23, 0x25,0x20,0x1D, 0x1D,0x1A,0x17, 0x06,0x0B,0x14,
    0x04,0x08,0x0E, 0x02,0x05,0x09, 0x01,0x02,0x04, 0x25,0x05,0x05,
}

local PAL_96_1 = {
    0x00,0x00,0x00, 0x18,0x00,0x19, 0x00,0x00,0x1D, 0x00,0x03,0x21,
    0x00,0x09,0x26, 0x00,0x11,0x2B, 0x00,0x00,0x32, 0x00,0x16,0x00,
    0x03,0x1F,0x00, 0x00,0x21,0x0C, 0x14,0x23,0x00, 0x00,0x27,0x19,
    0x18,0x00,0x00, 0x1C,0x00,0x00, 0x26,0x00,0x00, 0x30,0x00,0x00,
    0x32,0x0D,0x00, 0x32,0x19,0x00, 0x33,0x21,0x00, 0x32,0x28,0x00,
    0x3F,0x3A,0x18, 0x3F,0x3F,0x33, 0x38,0x38,0x38, 0x2E,0x2E,0x2E,
    0x1C,0x1C,0x1C, 0x12,0x12,0x12, 0x06,0x06,0x06, 0x0E,0x05,0x00,
    0x1D,0x0D,0x02, 0x2A,0x17,0x00, 0x2A,0x1E,0x16, 0x31,0x27,0x23,
}

local PAL_48_1 = {
    0x2D,0x16,0x00, 0x3D,0x26,0x01, 0x32,0x32,0x24, 0x16,0x1D,0x16,
    0x12,0x19,0x12, 0x0B,0x12,0x0B, 0x32,0x32,0x24, 0x16,0x1D,0x16,
    0x12,0x19,0x12, 0x0B,0x12,0x0B, 0x3D,0x3D,0x3D, 0x3D,0x26,0x01,
    0x36,0x1F,0x01, 0x2D,0x16,0x00, 0x0F,0x08,0x00, 0x3F,0x3F,0x3F,
}

local function overlay_palette(palette, start_index, vals)
    for i = 1, #vals do
        palette[start_index * 3 + i] = expand6(vals[i])
    end
end

-- Overlay the engine's fixed colour ranges onto an (already expanded) palette.
local function apply_fixed_palette(palette)
    overlay_palette(palette, 192, PAL_IGOR_1)
    overlay_palette(palette, 208, PAL_96_1)
    overlay_palette(palette, 240, PAL_48_1)
    return palette
end

-- Palette used for UI elements and sprites: Philip's Room as the base for
-- colours 0..191, plus the fixed ranges above.
local function read_ui_palette(fh)
    local palette = read_palette(fh, 0x1b031c, 768)
    if not palette then return nil end
    return apply_fixed_palette(palette)
end

-- ============================================================================
-- FRM_* / ANM_* sparse frame streams
-- Frame: u16 y, u16 height, then per row: u8 runCount, then runs of
--   u8 skip, u8 len; len >= 0x80 -> fill (256-len) pixels with next byte,
--   otherwise len literal bytes follow.
-- Frames are packed back to back inside the concatenated resource chunks,
-- mixed with offset tables and raw pixel blocks whose geometry is hardcoded
-- per room, so the stream is scanned for valid frames.
-- ============================================================================

local FRAME_MIN_BYTES = 12

-- Returns end position (1-based, exclusive), y, h, minx, maxx or nil
local function parse_sparse_frame(data, p)
    local n = #data
    if p + 3 > n then return nil end
    local y = data:byte(p) + data:byte(p + 1) * 256
    local h = data:byte(p + 2) + data:byte(p + 3) * 256
    if h < 1 or h > 200 or y + h > 200 then return nil end
    local q = p + 4
    local minx, maxx = 999, 0
    for _ = 1, h do
        if q > n then return nil end
        local w = data:byte(q); q = q + 1
        local pos = 0
        for _ = 1, w do
            if q + 1 > n then return nil end
            pos = pos + data:byte(q)
            local len = data:byte(q + 1)
            q = q + 2
            if len >= 128 then
                if q > n then return nil end
                len = 256 - len
                q = q + 1
                if len == 0 then return nil end
            else
                if len == 0 then return nil end
                q = q + len
            end
            if pos < minx then minx = pos end
            pos = pos + len
            if pos > 320 then return nil end
            if pos > maxx then maxx = pos end
        end
    end
    if q - 1 > n then return nil end
    if minx == 999 then return nil end
    return q, y, h, minx, maxx
end

local function scan_sparse_frames(data)
    local frames = {}
    local p, n = 1, #data
    while p <= n - 4 do
        local q, y, h, minx, maxx = parse_sparse_frame(data, p)
        if q and q - p >= FRAME_MIN_BYTES then
            frames[#frames + 1] = {pos = p, y = y, h = h, minx = minx, maxx = maxx}
            p = q
        else
            p = p + 1
        end
    end
    return frames
end

-- Paint one frame into a canvas of width w (pixels[] 1-based) whose top-left
-- corresponds to (ox, oy) in screen space.
local function paint_sparse_frame(data, p, pixels, w, ox, oy)
    local y = data:byte(p) + data:byte(p + 1) * 256
    local h = data:byte(p + 2) + data:byte(p + 3) * 256
    local q = p + 4
    for r = 0, h - 1 do
        local runs = data:byte(q); q = q + 1
        local pos = 0
        for _ = 1, runs do
            pos = pos + data:byte(q)
            local len = data:byte(q + 1)
            q = q + 2
            local row = (y + r - oy) * w - ox + pos + 1
            if len >= 128 then
                len = 256 - len
                local c = data:byte(q); q = q + 1
                for i = 0, len - 1 do pixels[row + i] = c end
            else
                for i = 0, len - 1 do pixels[row + i] = data:byte(q + i) end
                q = q + len
            end
            pos = pos + len
        end
    end
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
-- CD sound effects (Creative Voice File in IGOR.DAT)
-- ============================================================================

-- Locate the CD audio container (IGOR.DAT). Sound effects live here while the
-- room/mask/sprite resources live in IGOR.EXE (see find_data_file()).
local function find_sound_file(game_path)
    local candidates = {
        game_path .. "/IGOR.DAT",
        game_path .. "/igor.dat",
        game_path .. "/Igor.dat",
    }
    for _, p in ipairs(candidates) do
        if file_exists(p) then return p end
    end
    return nil
end

-- The game plays sound effects with playSound(num, 1): the supplied 1-based
-- number indexes the sound table directly (slot num-1). Slots 0-99 are the
-- sound-effect area of the CD table. Build that list, keeping every non-empty
-- slot (duplicated offsets are intentional aliases, e.g. slot 16/17 both map
-- to the same file, so each game-referenced id is preserved for browsing).
local function collect_cd_sfx()
    local list = {}
    for slot = 0, 99 do
        local off = CD_SOUND_OFFSETS[slot + 1]
        if off and off > 0 then
            list[#list + 1] = { slot = slot, offset = off }
        end
    end
    return list
end

-- Speech is played by playSound(num, 0) while the talkie flag is set: after
-- the usual 1-based decrement the engine adds 100 before indexing the table,
-- so speech id N lives at table slot N+99. The CD data uses that whole band
-- contiguously - ids 2..1293 (slots 101..1392) are real VOC clips, id 1 and
-- slot 1393 are empty/sentinel and the rest of the table is unused.
local SPEECH_SLOT_BASE = 99
local SPEECH_GROUP_SIZE = 200

local function speech_offset(id)
    local off = CD_SOUND_OFFSETS[id + SPEECH_SLOT_BASE + 1]
    if not off or off <= 0 then return nil end
    return off
end

local function collect_cd_speech()
    local list = {}
    for id = 2, 1293 do
        local off = speech_offset(id)
        if off then list[#list + 1] = { id = id, offset = off } end
    end
    return list
end

-- ============================================================================
-- CD dialogue text (TXT_ blocks in IGOR.EXE)
-- ============================================================================
-- The Spanish text is byte-shuffled, not encrypted with one global key: each
-- table uses its own transform. Both variants land on the same output charset
-- (ASCII plus the eight CP850 letters Igor's text actually uses), so
-- codepoint_to_utf8() below renders the result directly.
--
-- Only these eight high bytes occur anywhere in the game's text, so they are
-- the only non-ASCII mappings needed (all eight appear in the reference
-- transcript's \xNN escapes, confirming CP850).
local CD_TEXT_HIGH = {
    [0x82] = "\195\169", -- e-acute
    [0xA0] = "\195\161", -- a-acute
    [0xA1] = "\195\173", -- i-acute
    [0xA2] = "\195\179", -- o-acute
    [0xA3] = "\195\186", -- u-acute
    [0xA4] = "\195\177", -- n-tilde
    [0xA8] = "\194\168", -- inverted question
    [0xAD] = "\194\169", -- inverted exclamation
}

-- Decode one shuffled byte from a room TXT_ block. Letters (upper and lower
-- case) are stored shifted up by 0x6D; the 0xE8-0xEE band is a second encoding
-- of the accented letters and is folded back onto the 0x80/0xA0 range; every
-- other byte (ASCII punctuation, digits, CP850 letters) is stored as-is.
local CD_TEXT_ROOM_FOLD = {
    [0xE8] = 0xA0, [0xE9] = 0x82, [0xEA] = 0xA1, [0xEB] = 0xA2,
    [0xEC] = 0xA3, [0xED] = 0xA4, [0xEE] = 0xA5,
}

local function decode_room_text_byte(c)
    if (c >= 0xAE and c <= 0xC7) or (c >= 0xCE and c <= 0xE7) then
        return c - 0x6D
    end
    if c > 0xE7 then
        return CD_TEXT_ROOM_FOLD[c] or c
    end
    return c
end

local function codepoint_to_utf8(c)
    if c < 0x80 then return string.char(c) end
    -- Only the eight codes in CD_TEXT_HIGH occur in the shipped game, so this
    -- is a safety net rather than an expected path; escape it visibly in the
    -- same style decode_text() uses instead of guessing a character.
    return CD_TEXT_HIGH[c] or string.format("[%02X]", c)
end

local function decode_shifted_bytes(data, from, len)
    local out = {}
    for i = 0, len - 1 do
        out[#out + 1] = codepoint_to_utf8((u8(data, from + i) - 0x6D) % 256)
    end
    return table.concat(out)
end

-- The global dialogue table (TXT_MainTable, 28,028 bytes in IGOR.EXE) opens
-- with the game strings and holds 250 fixed 102-byte entries starting at
-- offset 0x8BA. Each entry is length-prefixed and every byte is shifted by
-- 0x6D (space included, hence a different transform from the room blocks).
-- Offsets below are 1-based (Lua string indexing) despite the 0x form.
local TXT_MAIN_DLG_BASE   = 0x8BA + 1
local TXT_MAIN_DLG_STRIDE = 102
local TXT_MAIN_DLG_COUNT  = 250

-- CD_TEXTS entry holding the global dialogue table (name, offset, size).
local function find_main_text_block()
    for _, t in ipairs(CD_TEXTS) do
        if t[1] == "Main Text Table" then return t[2], t[3] end
    end
    return nil
end

local function decode_main_dialogue(data)
    local out = {}
    for i = 0, TXT_MAIN_DLG_COUNT - 1 do
        local pos = TXT_MAIN_DLG_BASE + i * TXT_MAIN_DLG_STRIDE
        if pos > #data then break end
        local len = (u8(data, pos) - 0x6D) % 256
        out[i] = len > 0 and decode_shifted_bytes(data, pos + 1, len) or nil
    end
    return out
end

-- Room TXT_ blocks start with 752 bytes of walk-grid/box data, then two
-- length-prefixed tables of object names and dialogue lines. Each list is
-- terminated by 0xF6 and 0xF4 marks the next list entry.
local TXT_ROOM_HEADER = 752 + 1   -- 1-based

local function decode_room_dialogue(data)
    local out = {}
    local pos = TXT_ROOM_HEADER
    for _, base in ipairs({0, 200}) do
        local idx = 0
        while pos + 1 <= #data do
            local code = u8(data, pos)
            pos = pos + 1
            if code == 0xF6 then break end
            if code == 0xF4 then idx = idx + 1 end
            local len = u8(data, pos)
            pos = pos + 1
            -- len 0 marks an unused slot: nothing inline to skip.
            if len > 0 then
                if pos + len - 1 > #data then break end
                local chars = {}
                for i = 0, len - 1 do
                    chars[#chars + 1] = codepoint_to_utf8(decode_room_text_byte(u8(data, pos + i)))
                end
                out[base + idx] = table.concat(chars)
                pos = pos + len
            end
        end
    end
    return out
end

-- Locate a CD room's TXT_ block by its display name, so the speech table can
-- name rooms instead of duplicating their offsets.
local function find_room_text_block(rooms, name)
    for _, room in ipairs(rooms) do
        if room[1] == name and room[10] > 0 and room[11] > 0 then
            return room[10], room[11]
        end
    end
    return nil
end

-- Decode the Spanish line(s) spoken by a clip listed in CD_SPEECH_DIALOGUE.
-- Text lives in IGOR.EXE, so this needs the executable rather than IGOR.DAT.
local function speech_dialogue_text(game_path, rooms, id, cache)
    local entry = CD_SPEECH_BY_ID[id]
    if not entry then return nil end
    local first_index, count, source = entry[2], entry[3], entry[4]

    local strings = cache[source]
    if strings == nil then
        local data_path = find_data_file(game_path)
        if not data_path then return nil end
        local fh = file_open(data_path)
        if not fh then return nil end
        local raw
        if source == "main" then
            local off, size = find_main_text_block()
            if not off then file_close(fh) return nil end
            raw = file_read(fh, off, size)
        else
            local off, size = find_room_text_block(rooms, source)
            if not off then file_close(fh) return nil end
            raw = file_read(fh, off, size)
        end
        file_close(fh)
        if not raw or #raw == 0 then return nil end
        strings = source == "main" and decode_main_dialogue(raw) or decode_room_dialogue(raw)
        cache[source] = strings
    end

    local lines = {}
    for i = 0, count - 1 do
        local line = strings[first_index + i]
        if not line or line == "" then return nil end
        lines[#lines + 1] = line
    end
    return lines
end

-- Tree label for a speech clip: "Speech #545 ..." plus, when known, the first
-- line of its dialogue in quotes, truncated to keep the tree readable. The full
-- text is shown in the preview pane instead.
local SPEECH_LABEL_MAX = 64

local function speech_node_label(id, lines)
    local label = string.format("Speech #%d", id)
    if not lines then return label end
    local text = lines[1]
    if #text > SPEECH_LABEL_MAX then
        text = text:sub(1, SPEECH_LABEL_MAX - 3)
        -- Cutting on a byte count can slice a 2-byte accented character in
        -- half; drop the orphaned tail bytes before appending the ellipsis.
        while #text > 0 do
            local last = text:byte(#text)
            if last < 0x80 or last >= 0xC0 then break end
            text = text:sub(1, #text - 1)
        end
        text = text .. "..."
    end
    return string.format("%s  \"%s\"", label, text)
end

-- First sound-table offset strictly greater than [off]; used to bound a VOC
-- chunk when reading it from IGOR.DAT (the files are stored contiguously).
local function next_sound_offset(off)
    for i = 1, #CD_SOUND_OFFSETS do
        local o = CD_SOUND_OFFSETS[i]
        if o and o > off then return o end
    end
    return nil
end

-- Describe a VOC file: version, sample rate, bits and duration. Mirrors the
-- block walk used by decode_voc_pcm() but only collects statistics.
local function parse_voc_info(data)
    if #data < 26 then return nil end
    if data:sub(1, 19) ~= "Creative Voice File" then return nil end

    local header_size = u16le(data, 21)
    local version = u16le(data, 23)
    local ver_major = math.floor(version / 256)
    local ver_minor = version % 256

    local pos = header_size + 1
    local total_samples = 0
    local sample_rate = 0
    local bits = 8

    while pos <= #data do
        local block_type = u8(data, pos)
        if block_type == 0 then break end
        if pos + 3 > #data then break end
        local block_size = u8(data, pos + 1) + u8(data, pos + 2) * 256 + u8(data, pos + 3) * 65536
        pos = pos + 4

        if block_type == 1 then
            if pos + 1 <= #data then
                local freq_div = u8(data, pos)
                local codec = u8(data, pos + 1)
                if sample_rate == 0 then
                    sample_rate = math.floor(1000000 / (256 - freq_div))
                end
                if codec == 4 then bits = 16 end
                total_samples = total_samples + block_size - 2
            end
        elseif block_type == 9 then
            if pos + 11 <= #data then
                sample_rate = u32le(data, pos)
                bits = u8(data, pos + 4)
                total_samples = total_samples + block_size - 12
            end
        end

        pos = pos + block_size
    end

    local duration = 0
    if sample_rate > 0 then
        duration = total_samples / sample_rate
    end

    return {
        version = string.format("%d.%02d", ver_major, ver_minor),
        sample_rate = sample_rate,
        bits = bits,
        total_samples = total_samples,
        duration = duration,
    }
end

-- Decode a VOC file to raw PCM. Igor's sound effects are 8-bit unsigned PCM
-- (codec 0) in sound-data blocks, so the samples can be passed straight to
-- sound_create_pcm(rate, 8, 1, false, pcm).
local function decode_voc_pcm(data)
    if #data < 26 then return nil end
    if data:sub(1, 19) ~= "Creative Voice File" then return nil end

    local header_size = u16le(data, 21)
    local pos = header_size + 1
    local sample_rate = 0
    local bits = 8
    local pcm_parts = {}

    while pos <= #data do
        local block_type = u8(data, pos)
        if block_type == 0 then break end
        if pos + 3 > #data then break end
        local block_size = u8(data, pos + 1) + u8(data, pos + 2) * 256 + u8(data, pos + 3) * 65536
        pos = pos + 4

        if block_type == 1 then
            if pos + 1 <= #data then
                local freq_div = u8(data, pos)
                local codec = u8(data, pos + 1)
                if sample_rate == 0 then
                    sample_rate = math.floor(1000000 / (256 - freq_div))
                end
                if codec ~= 0 and codec ~= 4 then
                    -- unsupported compression; skip the payload
                else
                    if codec == 4 then bits = 16 end
                    local pcm_len = block_size - 2
                    if pcm_len > 0 and pos + 2 + pcm_len - 1 <= #data then
                        pcm_parts[#pcm_parts + 1] = data:sub(pos + 2, pos + 2 + pcm_len - 1)
                    end
                end
            end
        elseif block_type == 9 then
            if pos + 11 <= #data then
                sample_rate = u32le(data, pos)
                bits = u8(data, pos + 4)
                local pcm_len = block_size - 12
                if pcm_len > 0 and pos + 12 + pcm_len - 1 <= #data then
                    pcm_parts[#pcm_parts + 1] = data:sub(pos + 12, pos + 12 + pcm_len - 1)
                end
            end
        end

        pos = pos + block_size
    end

    if sample_rate == 0 or #pcm_parts == 0 then return nil end
    return sample_rate, bits, table.concat(pcm_parts)
end

-- Read one VOC chunk out of IGOR.DAT and turn it into a previewable sound.
-- [label] is the on-screen name ("Sound #12" / "Speech #545") and is used in
-- both the success and the failure description.
local function load_cd_voc_clip(game_path, offset, label)
    local sound_path = find_sound_file(game_path)
    if not sound_path then
        return {type = "text", text = "No IGOR.DAT audio file found for the CD version"}
    end

    local fh = file_open(sound_path)
    if not fh then return {type = "text", text = "Cannot open " .. sound_path} end

    -- VOC chunks are stored contiguously in IGOR.DAT: borrow the next
    -- sound's offset as this chunk's bound (or the end of file).
    local end_off = next_sound_offset(offset) or file_size(fh)
    if end_off <= offset then end_off = offset + 1 end
    local voc_raw = file_read(fh, offset, end_off - offset)
    file_close(fh)
    if not voc_raw or #voc_raw < 26 then
        return {type = "text", text = string.format("%s  |  IGOR.DAT@0x%X\n\nFailed to read clip data", label, offset)}
    end

    local info = parse_voc_info(voc_raw)
    local sample_rate, bits, pcm = decode_voc_pcm(voc_raw)
    if not sample_rate or not pcm then
        local hint = ""
        if info then
            hint = string.format("\n\nVOC v%s present but no decodable PCM data blocks found", info.version)
        end
        return {
            type = "text",
            text = string.format("%s  |  IGOR.DAT@0x%X\n\nFailed to decode VOC audio%s", label, offset, hint),
        }
    end

    local snd = sound_create_pcm(sample_rate, bits, 1, bits == 16, pcm)
    if not snd then
        return {type = "text", text = "Failed to create audio for " .. label}
    end

    local dur = info and info.duration or 0
    if dur <= 0 and sample_rate > 0 then
        dur = #pcm / ((bits / 8) * sample_rate)
    end
    -- Format the duration with integer math (LuaJ's string.format does not
    -- honor float precision like "%.2f")
    local dur_ms = math.floor(dur * 1000 + 0.5)
    local dur_label = string.format("%d.%03d s", math.floor(dur_ms / 1000), dur_ms % 1000)
    local signed_label = bits == 16 and "signed" or "unsigned"

    return {
        type = "sound",
        sound = snd,
        -- [2] = the second description line, used when a clip has known text.
        meta = {
            version = info and info.version or "?",
            rate = sample_rate,
            bits = bits,
            bits_label = string.format("%d-bit %s", bits, signed_label),
            samples = #pcm,
            duration = dur_label,
            offset = offset,
        },
    }
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
        rooms = get_floppy_rooms(game_path, data_path)
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

    -- Sound effects (CD only: VOC files indexed by the IGOR.DAT sound table)
    local sfx_children = {}
    if version == VER_CD then
        for _, snd in ipairs(collect_cd_sfx()) do
            sfx_children[#sfx_children + 1] = {
                id = "sfx_" .. snd.slot,
                name = string.format("Sound #%d", snd.slot + 1),
                type = "sound",
            }
        end
    end

    -- Speech (CD only: talkie voice acting in the same IGOR.DAT sound table).
    -- 1,292 clips is too many for one flat row, so chunk them into groups of
    -- 200 and lead each clip with its Spanish line where the dialogue is known.
    local speech_groups = {}
    local speech_clip_count = 0
    if version == VER_CD then
        local clips = collect_cd_speech()
        speech_clip_count = #clips
        local text_cache = {}
        local group, group_children
        for i, clip in ipairs(clips) do
            if i == 1 or (i - 1) % SPEECH_GROUP_SIZE == 0 then
                group = {
                    id = string.format("speech_group_%d", #speech_groups + 1),
                    name = string.format("Speech %d-%d", clip.id,
                        math.min(clip.id + SPEECH_GROUP_SIZE - 1, clips[#clips].id)),
                    type = "category",
                    children = {},
                }
                group_children = group.children
                speech_groups[#speech_groups + 1] = group
            end
            group_children[#group_children + 1] = {
                id = "speech_" .. clip.id,
                name = speech_node_label(clip.id, speech_dialogue_text(game_path, rooms, clip.id, text_cache)),
                type = "sound",
            }
        end
    end

    -- Sprite / animation groups (CD only: FRM_* / ANM_* sparse frame streams)
    local anim_children = {}
    if version == VER_CD then
        for i, g in ipairs(CD_ANIM_GROUPS) do
            anim_children[#anim_children + 1] = {
                id = "anim_" .. i,
                name = g[1],
                type = "animation",
            }
        end
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

    if #anim_children > 0 then
        root[#root + 1] = {
            id = "cat_anim",
            name = "Sprites & Animations (" .. #anim_children .. " groups)",
            type = "category",
            children = anim_children,
        }
    end

    if #sfx_children > 0 then
        root[#root + 1] = {
            id = "cat_sfx",
            name = "Sound Effects (CD, " .. #sfx_children .. " sounds)",
            type = "category",
            children = sfx_children,
        }
    end

    if #speech_groups > 0 then
        root[#root + 1] = {
            id = "cat_speech",
            name = "Speech / Voice (CD, " .. speech_clip_count .. " clips)",
            type = "category",
            children = speech_groups,
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
                type = "midi",
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
        rooms = get_floppy_rooms(game_path, data_path)
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
            if version == VER_CD then
                local palette, bad_colors = read_palette(fh, pal_off, pal_size)
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
                local warning = ""
                if bad_colors and bad_colors > 0 then
                    warning = string.format(
                        "  |  WARNING: %d palette entries outside valid 6-bit VGA range - offsets are likely wrong for this room",
                        bad_colors)
                end
                return {
                    type = "image",
                    image = img,
                    description = string.format(
                        "%s  |  %dx%d  |  pal@0x%X (%d bytes)  |  img@0x%X%s",
                        name, IMG_W, img_h, pal_off, pal_size, img_off, warning),
                }
            end

            -- Floppy: img_off/img_size here are actually the overlay segment's
            -- (offset, size) in IGOR.DAT; re-scan it for the trailing
            -- [palette][image] blob (see get_floppy_rooms()).
            file_close(fh)
            local pal_raw, img_raw = scan_floppy_room_blob(data_path, { offset = img_off, size = img_size })
            if not pal_raw or not img_raw then
                return {type = "text", text = "No background data found for " .. name}
            end

            local palette = {}
            for i = 0, 255 do
                palette[i*3+1] = expand6(pal_raw:byte(i*3+1))
                palette[i*3+2] = expand6(pal_raw:byte(i*3+2))
                palette[i*3+3] = expand6(pal_raw:byte(i*3+3))
            end

            local pixels = {}
            for i = 1, #img_raw do
                pixels[i] = img_raw:byte(i)
            end

            local img = image_create_indexed(IMG_W, 200, pixels, palette)
            return {
                type = "image",
                image = img,
                description = string.format(
                    "%s  |  %dx200  |  overlay segment @0x%X (%d bytes)",
                    name, IMG_W, img_off, img_size),
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

        -- UI elements use the engine's fixed colour ranges (208..255) on top
        -- of a room palette for the low colours
        local palette = read_ui_palette(fh)
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

    -- ====== Sprite / animation groups (FRM_* / ANM_*) ======
    local anim_idx = resource_id:match("^anim_(%d+)$")
    if anim_idx then
        local g = CD_ANIM_GROUPS[tonumber(anim_idx)]
        if version ~= VER_CD or not g then
            return {type = "text", text = "Animation group not available"}
        end
        local fh = file_open(data_path)
        if not fh then return {type = "text", text = "Cannot open data file"} end

        local palette = read_palette(fh, g[2], g[3])
        local chunks = {}
        for _, c in ipairs(g[4]) do
            chunks[#chunks + 1] = file_read(fh, c[1], c[2]) or ""
        end
        file_close(fh)
        if not palette then
            return {type = "text", text = "Failed to read palette for " .. g[1]}
        end
        apply_fixed_palette(palette)

        local data = table.concat(chunks)
        local frames = scan_sparse_frames(data)
        if #frames == 0 then
            return {type = "text", text = g[1] .. ": no sparse frames found"}
        end

        -- Union bounding box so the animation keeps a stable canvas
        local x0, x1, y0, y1 = 320, 0, 200, 0
        local used = {}
        for _, f in ipairs(frames) do
            if f.minx < x0 then x0 = f.minx end
            if f.maxx > x1 then x1 = f.maxx end
            if f.y < y0 then y0 = f.y end
            if f.y + f.h > y1 then y1 = f.y + f.h end
        end
        local w, h = x1 - x0, y1 - y0

        -- Render every frame; find a colour index no frame uses for transparency
        local rendered = {}
        for fi, f in ipairs(frames) do
            local px = {}
            local ok = pcall(paint_sparse_frame, data, f.pos, px, w, x0, y0)
            rendered[fi] = ok and px or {}
            for _, c in pairs(rendered[fi]) do used[c] = true end
        end
        local key = 0
        while used[key] and key < 255 do key = key + 1 end
        palette[key * 3 + 1] = 255
        palette[key * 3 + 2] = 0
        palette[key * 3 + 3] = 255

        local handles = {}
        for fi = 1, #rendered do
            local px = rendered[fi]
            local out = {}
            for i = 1, w * h do out[i] = px[i] or key end
            handles[#handles + 1] = image_create_indexed(w, h, out, palette)
        end
        local anim = animation_create(handles, 120)
        return {
            type = "animation",
            animation = anim,
            delay_ms = 120,
            description = string.format(
                "%s  |  %d frames  |  canvas %dx%d at (%d,%d)  |  %d bytes",
                g[1], #frames, w, h, x0, y0, #data),
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
        -- Igor's own colours live at 192..207 (PAL_IGOR_1)
        local palette = read_ui_palette(fh)
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
            local midi = midi_create_from_cmf(cmf_raw)
            if not midi then
                return {
                    type = "text",
                    text = string.format("%s\n\nFailed to convert CMF to MIDI\n\n%s", m[1], desc),
                }
            end

            return {
                type = "midi",
                midi = midi,
                description = string.format("%s\n\n%s", m[1], desc),
            }
        end
    end

    -- ====== Sound effects (CD, VOC files in IGOR.DAT) ======
    local sfx_idx = resource_id:match("^sfx_(%d+)$")
    if sfx_idx then
        if version ~= VER_CD then
            return {type = "text", text = "Sound effects are only available in the CD version (vocal .VOC data in IGOR.DAT)"}
        end
        local slot = tonumber(sfx_idx)
        local offset = CD_SOUND_OFFSETS[slot + 1]
        if not offset or offset <= 0 then
            return {type = "text", text = "Sound slot " .. slot .. " is unused in the CD sound table"}
        end

        local label = string.format("Sound #%d", slot + 1)
        local clip = load_cd_voc_clip(game_path, offset, label)
        if clip.type ~= "sound" then return clip end

        local m = clip.meta
        clip.description = string.format(
            "%s  |  VOC v%s  |  %d Hz  |  %s PCM  |  %d samples  |  %s  |  IGOR.DAT@0x%X",
            label, m.version, m.rate, m.bits_label, m.samples, m.duration, m.offset)
        return clip
    end

    -- ====== Speech / voice acting (CD, VOC files in IGOR.DAT) ======
    local speech_idx = resource_id:match("^speech_(%d+)$")
    if speech_idx then
        if version ~= VER_CD then
            return {type = "text", text = "Speech is only available in the CD version (vocal .VOC data in IGOR.DAT)"}
        end
        local id = tonumber(speech_idx)
        local offset = speech_offset(id)
        if not offset then
            return {type = "text", text = "Speech id " .. id .. " is unused in the CD sound table"}
        end

        local label = string.format("Speech #%d", id)
        local clip = load_cd_voc_clip(game_path, offset, label)
        if clip.type ~= "sound" then return clip end

        local m = clip.meta
        local head = string.format(
            "%s  |  VOC v%s  |  %d Hz  |  %s PCM  |  %d samples  |  %s  |  IGOR.DAT@0x%X",
            label, m.version, m.rate, m.bits_label, m.samples, m.duration, m.offset)

        -- Known clips carry the Spanish line they speak; the rest are idents or
        -- shouts with no matching ADD_DIALOGUE_TEXT entry.
        local lines = speech_dialogue_text(game_path, rooms, id, {})
        if lines then
            clip.description = head .. "\n\n\"" .. table.concat(lines, "\"\n\"") .. "\""
        else
            clip.description = head
        end
        return clip
    end

    return {type = "text", text = "Unknown resource: " .. tostring(resource_id)}
end

-- ============================================================================
return engine

## Sources for engines

### SCUMM
Scummvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
games are located in ags/scumm folder
Key references used:
- `engines/scumm/object.h` - ImageHeader (old/v7/v8), CodeHeader, RoomHeader layouts
- `engines/scumm/object.cpp` - OBIM/OBCD parsing, `getObjectImage` (IMxx state mapping)
- `engines/scumm/gfx.h` / `gfx.cpp` - BMCOMP_* strip codecs and SMAP decompression
- `engines/scumm/resource.cpp` - block search (`findResource`), tag aliasing, `readRoomsOffsets` (room table at offset 16 of each data part)
- `engines/scumm/detection_tables.h` - per-game data file conventions (e.g. DOTT `tentacle.%03d` with `kGenDiskNum`)
- `engines/scumm/metaengine.cpp` - generated per-room filenames (`%02d.LFL` / `%03d.LFL`)
- `engines/scumm/resource.cpp` - `readIndexBlock` / `readResTypeList` (V8: 32-bit counts, DRSC), `openRoom`/`readRoomsOffsets` (per-disc `.LA1`/`.LA2` room tables)
- `engines/scumm/costume.cpp`, `base-costume.cpp` - V5/V6 `COST` limbs/cels, byleRLE; `akos.cpp`, `bomp.cpp` - V7/V8 `AKOS` (codecs 1, 5, 16) and sequence (`AKSQ`) commands
- `engines/scumm/sound.cpp` (`readSoundResource`) - `SOUN`/`SOU ` chunks (SBL, ROL, GMD, ADL, SPK); iMUSE MIDI is a standard `MThd` after an `MDhd` header
- `engines/scumm/imuse_digi/dimuse_bndmgr.cpp`, `dimuse_codecs.cpp` - `.BUN` bundles (LB83/LB23 directory, COMP block table, codecs 0-13/15), ported to `ImuseBundleCodecs.kt`
- `engines/scumm/nut_renderer.cpp` - `.NUT` bitmap fonts (codecs 1/21/44)
- MI3 (`COMI.LA0/1/2`) game located in ags/SCUMM/Monkey3 (music/speech in `RESOURCE/*.BUN`)

### SCI
Scummvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
games are located in ags/sci folder

### HOLMES
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
Source code for some tools in ags/tools/holmes

games are located in ags/holmes and ags/holmes2

Sprite/audio format notes (Serrated Scalpel):
- Per-room object sprites and cAnimations are embedded in each uncompressed
  (version != 10) RRM after the shapes/desc/seq sections; each blob's size comes
  from the BgFileHeaderInfo entry. See scummvm scene.cpp (Scene::load) and
  image_file.cpp (ImageFile::load / ImageFrame::decompressFrame).
- Frame header: u16le(w-1), u16le(h-1), u8 paletteBase, u8 rleFlag, u8 offX, u8 offY.
  paletteBase -> nibble-packed (w*h/2); rleFlag -> u16le(size)+u8 marker, data=size-11;
  else raw w*h. Optional embedded "VGA " palette block before the first frame.
- Global sprites: vgs.lib (WALK/CONTROLS/ITEMS/cursors/DARTS/BIGMAP/MENU) and
  portrait.lib (81x67 x7 portraits). Most carry no palette; DARTS/BIGMAP/INSTALL.LBV
  embed one. FONT1-3.VGS are fonts.
- Speech/SFX: SND.SND / TITLE.SND / EPILOGUE.SND are LIB containers of .SND files.
  Each .SND: skip 2, u32be size, u16be rate, then `size` bytes Creative ADPCM 4-bit
  (1 reference byte + nibble pairs). See scummvm sound.cpp (playSoundResource).

### BROKEN SWORD SERIES
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
games are located in ags/SWORD/

### TINSEL
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
games are located in ags/TINSEL (DISCWLD for Discworld 1, DW2 for Discworld 2)

key reference files: engines/tinsel/handle.cpp (SCNHANDLE + chunk list),
object.cpp (DMA flags / decoder selection), graphics.cpp (all four decoders),
palette.cpp (DAC palette index shift)

### TRICK OR TREAT
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)

### TOONSTRUCK
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
Tool in ags/tools/Pak reader.exe

game located in ags/toonstrk

### TOUCHE
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)

game located in ags/Touche

### Shadow of the comet
Branch on a scummvm fork https://github.com/sev-/scummvm/tree/comet

game located in ags/SHADOW

### Visionaire Engine (Daedalic games)
Tools in ags/TOOLS/ANB

### Gob engine
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)

games in ags/GOB/

### INDARK engine
Free in the dark engine in https://github.com/yaz0r/FITD

games in ags/INDARK

### CINE
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)

games in ags/CRUISE

### COBRA MISSION
https://moddingwiki.shikadi.net/wiki/Cobra_Mission
https://github.com/BlackStar-EoP/cobra-mission-writer
https://moddingwiki.shikadi.net/wiki/MegaTech_VOL_Format

games in ags/COBRA

### CURSE OF ENCHANTIA
No ScummVM engine exists for this game, so the format was reverse engineered from
the data itself. Both image containers are Rob Northen Compression (ProPack)
streams, decoded from the public ProPack source:
http://www.codersnotes.com/solaris/pack/propack.zip and the method 1 description
at http://www.codersnotes.com/solaris/pack/rnc_format.html

Method 1 (Huffman) appears in CORE.DAT, MENU.DAT and TITLE.DAT, method 2 in the
rest. Both header CRCs are CRC-16/ARC and every block is verified on decode.

Two containers sit on top of that:
- `.MAP` room backgrounds: a 576 byte palette (192 RGB triples, six bits per
  channel) at offset 0, then two bytes, then a u16 count N followed by N
  16-byte room records, then a chain of RNC blocks that are each one 32x200
  vertical strip stored left to right. N strips form a (32*N)x200 room. The
  palette is per room, not shared: BASEBAT.MAP's is 177/192 entries
  byte-identical to BASEBALL.PAL.
- `.DAT` full-screen images: a single RNC block, 320x200 (320x32 for MENU.DAT).
  These take their palette from a matching `.PAL` file.

Standalone `.PAL` files are 768 bytes, 256 RGB triples, six bits per channel, so
every component scales by 4. CORE.PAL is the exception: only its first 16
entries carry colour, and CORE.DAT is the one .DAT that stays inside that range.

games in ags/CURSE

### Dark Seed
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)

games in ags/darkseed and ags/DSEED35

### Dark Seed 2
No ScummVM engine exists for this game, so the format was reverse engineered from
the data itself plus the Dark Seed II resource tooling:
https://github.com/DrMcCoy/darkseed2-tools (see `src/unglue.cpp` for the Glue
archive container and its LZ variant).

game in ags/DARKSEED2

### DRASCULA
ScummVM source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
game in ags/DRASCULA
Key references used:
- `engines/drascula/graphics.cpp` - `loadPic` (`.ALG` layout), `decodeRLE`
- `engines/drascula/rooms.cpp` - `enterRoom`, the `.ALD` room description layout
- `engines/drascula/resource.cpp` - `TextResourceParser` (files are bit-inverted)
- `engines/drascula/drascula.h` - `OBJWIDTH`/`OBJHEIGHT`, character sheet constants
- `engines/drascula/detection.cpp` - `14.ALD` as the unpacked-release marker
- `engines/drascula/actors.cpp` - character sheets cut out of `.ALG` surfaces

### HARVESTER
Harvester branch in this scummvm fork https://github.com/alexbevi/scummvm/tree/harvester

game in ags/harverster

### EXPRESS
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
extra tooling source code in AGS/TOOLS/EXPRESS

game in ags/lastexpress

### KYRA
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
extra tooling source code in AGS/TOOLS/KYRA

Kyrandia 1 (LoK) per-scene palettes: each scene has a `<NAME>.DAT` (packed in
`DAT.PAK`, or loose) that stores 20 VGA colors at offset 0x17. ScummVM copies
them into palette1[228..247] (`sprites.cpp` loadDat), which `initSceneScreen`
then copies into palette0[228..247] (`scene_lok.cpp`). The room `.EMC` scripts
do not set this band (only a few call `o1_setCustomPaletteRange`).

games in ags/KYRA/

### HOLLYWOOD MONSTERS
Ghidra project through the MCP server

game in ags/hollywoodmonsters

### IGOR
branch igor in fork https://github.com/dreammaster/scummvm/tree/igor/engines/igor
game reimplementation in https://github.com/cyxx/igor
tools in ags/tools/igor

game in ags/igor and ags/igor-cd

Spanish CD support refreshed against the local `scummvm-fork/engines/igor`
checkout at `bd1bb3dfb81` (2026-10-11) and the matching catalog in
`igor-stuff/reference/scummvm-create-igortbl/resource_sp_cdrom.h`.
Room/resource pairing follows `resource_ids.h`, `room.cpp` and each part's
load calls; sparse frame addressing follows `graphics.cpp::getAnimFrame` and
parts 69, 74–79, 85; raw frame dimensions/strides follow parts 7, 70, 73, 76.
Text transforms and table layouts follow `room.cpp` / `resource.cpp`;
outfit palettes follow `static_cursor.cpp` / `resource.cpp`; intertitle colours
follow `part_main.cpp::PART_meanwhile`. CD music is separate audio tracks
(`sound.cpp::playMusic`), while floppy music is CMF.
Coverage: 74 verified room/scene backgrounds, 12 title/splash/credit images,
five intertitles, 31 frame groups (19 indexed/raw, 12 scanned), both Igor
outfits, decoded room/main text, 68 effects and 1,292 speech clips.

### STAR TREK
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
extra tooling in ags/tools/st25thjr


### INTERSPECTIVE
Interspective branch on this scummvm fork https://github.com/bluegr/scummvm/tree/interspective

games are:
- Innocent until caught
- Guilty
- The orion conspiracy
- The Gene Machine

games in ags/interspective/

### Queen
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)


game in ags/QUEEN


### LGOP2 (Leather Goddesses of Phobos 2)
ScummVM source code - MADE engine (/scummvm-fork/engines/made/ or http://github.com/scummvm/scummvm)
Key files: resource.cpp, graphics.cpp, sound.cpp, made.cpp

game in ags/LGOP2


### Prisoner of Ice (ICE)
No public source. All four containers use the same `Burp` directory layout
(`"Burp"`, u32le count, 20-byte entries, flag bit 2 = raw DEFLATE), so the formats
below were derived from the data itself plus the file lists on the archived
ScummVM wiki page:
- https://wiki.scummvm.org/index.php/Prisoner_of_Ice
- https://web.archive.org/web/20241111103625/https://wiki.scummvm.org/index.php/Prisoner_of_Ice

Classified per entry by payload signature: `RIFF`/`EDITLS`+`RIFF` = 8-bit 22222 Hz mono
WAVE, `HMIMIDIP0131` = Miles MIDI, `u16le width`/`u16le height` + `width*height` indices =
image, 768 bytes = palette, 11-byte-stride records with a name, an absolute offset and
padding = CP850 dialogue table (0xAD is a line break). Images and their sibling palettes
sit next to each other, so a palette lives at image index + 1.

Scene picture/opcode streams and Miles patch data are still opaque and are exposed as
metadata only.

game in ags/PRISONER


### Universe
No public source or ScummVM engine. Everything was derived by disassembling the
DOS loader in UNIVERSE.EXE and by decoding UNIVERSE.EPF directly:

- `UNIVERSE.EXE` 0xb4a2  loads the 11-byte EPFS header and the 22-byte-per-entry
                    directory
- `UNIVERSE.EXE` 0xb74a  compression method 1, the canonical-code Huffman/LZ
                    decompressor reimplemented in the engine script
- `UNIVERSE.EXE` 0xba09  code-width and mask setup (9 bits, widening to 14)

game in ags/universe/


### THE RIDDLE OF MASTER LU (M4 engine)
Scummvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
Game in ags/RIDDLE

Key references used (`engines/m4`):
- `fileio/sys_file.cpp` - RIPLEY.HAS hash index (u32 count, 47-byte records, 34-byte hagfile table), `*.HAG` addressing
- `adv_r/adv_file.cpp`, `platform/tile/tile_read.cpp` - `.TT` tiled backgrounds (+ 6-bit palette), `.COD` attribute buffers
- `wscript/ws_load.cpp` (`ProcessCELS`, `CreateSprite`), `graphics/graphics.h` - `M4SS` sprite series layout
- `platform/draw.cpp` (`RLE8Decode`) - sprite RLE8
- `graphics/gr_font.cpp` (`gr_font_load`) - `.FNT`
- `platform/sound/digi.cpp` - `.RAW` is 11025 Hz unsigned 8-bit
- `audio/midiparser_hmp.cpp` - `.HMP` header, converted to SMF in the script


### TSUNAMI / TsAGE (Ringworld, Blue Force)
Scummvm source code (/scummvm-fork/engines/tsage or http://github.com/scummvm/scummvm)

games in ags/Tsunami/RINGWORLD and ags/Tsunami/BLUE

Key references used:
- `resources.cpp` - `RLB`/`TLib` containers: root `TMI-` section holds the section
  index (6-byte `resNum, configId, fileOffset` records; `resType = configId & 0x1F`,
  absolute offset `= ((configId >> 5) & 0x7FF) << 16 | fileOffset`). Per-section
  `TMI-` entries are 12 bytes (`u16 id, u16 size, u16 uncSize, u8 sizeHi, u8 type,
  u32 offset`); `storedSize = size | ((sizeHi & 0x0F) << 16)`, `uncSize = unc |
  ((sizeHi & 0xF0) << 12)`, `compressed = (type >> 5) != 0`. Compressed bodies use
  the 9->12 bit LSB-first LZW stream (`BitReader`, terminator 0x101, reset 0x100).
- `resources.h` - `ResourceType` enum (RES_STRIP 1, RES_IMAGE 2, RES_PALETTE 3,
  RES_VISAGE 4, RES_SOUND 5, RES_MESSAGE 6, RES_FONT 7, RES_PRIORITY 11,
  RES_CONTROL 12, RES_WALKRGNS 13, RES_BITMAP 14, RES_SEQUENCE 16)
- `graphics.cpp` (`surfaceFromRes`) - sprite/frame record: `u16 w, u16 h, u16 cx,
  u16 cy, u8 transColor, u8 flags`, pixels at +10. `rleEncoded = (flags & 2) != 0`;
  raw else per-row RLE (control <0x80 = literal run, 0x80-0xBF = skip, >=0xC0 =
  fill run with following byte).
- `scenes.cpp` (`ScenePalette::loadPalette`) - palettes live in the RES_PALETTE
  section `getResource(RES_PALETTE, paletteNum, 0)`; bytes are `u16 start, u16
  count, count*3` 8-bit RGB. `TLib::getPalette(n)` uses section 0 (only for the
  global `getPalette(0)` dialog palette).
- Backgrounds: RES_BITMAP section resNum = scene; resource 9999 = `u16 w, u16 h`;
  tiles are `id = xSection*yHalfCount + ySection` (xSection=ceil(w/160),
  yHalfCount=ceil(h/100)), each a 160x100 8bpp block composited at (x*160, y*100).
- Messages: RES_MESSAGE resource 0, NUL-separated CP850 strings.
- Sounds: RES_SOUND scored Adlib/MIDI tracker data needing the game driver, exposed
  as header metadata only.

Libraries: Ringworld = `RING.RLB` + `TSAGE.RLB`; Blue Force = `BLUE.RLB` +
`FILES.RLB` + `TSAGE.RLB` (`INSTALL.RLB` skipped).

### NEVERHOOD (The Neverhood)
Scummvm source code (`/scummvm-fork/engines/neverhood`, `common/compression/dcl.cpp`)
and http://github.com/scummvm/scummvm. Game data in `ags/neverhood/DATA`.

Key references used:
- `detection.cpp` - `AD_ENTRY1s("hd.blb", "22958d968458c9ff221aee38577bb2b2", 4279716)`.
  Data files are UPPERCASE on disk (`HD.BLB`); search order is `DATA/`, `data/`, root.
- `blbarchive.cpp` / `blbarchive.h` - `BlbArchive::load`:
  header `u32 id1=0x2004940, u16 id2=7, u16 extDataSize, u32 fileSize, u32 fileCount`
  (16 bytes), then `fileCount` `u32` hashes, then `fileCount` 20-byte entries
  (`u8 type, u8 comprType, u16LE extDataOffset, u32LE timeStamp, u32LE offset,
  u32LE diskSize, u32LE size`), then the ext-data blob. `comprType` 1 = stored,
  3 = DCL, `0x65` = redirect (`diskSize` holds the target hash; follow the chain).
- `neverhood.cpp` - archive order `a, c, hd, i, m (optional jpn), s, t`; on hash
  collision the entry with the strictly greater timestamp wins.
- `resource.h` / `resourceman.cpp` (`Resource::load`, `queryResource`) - resource
  types: 2 bitmap, 3 palette, 4 animation, 5 data, 6 text, 7 sound, 8 music,
  10 video (Smacker). For `0x65` the ext-data comes from the alias entry while the
  payload comes from the resolved entry.
- `common/compression/dcl.cpp` - fixed-tree "blast" decompressor. Header byte 0 =
  mode (0 binary, 1 ASCII; Neverhood always 0), byte 1 = dictType (4/5/6). Fixed
  `lengthTree` (31) and `distanceTree` (127) sentinels `BN(pos,l,r)=(l<<12)|r`,
  leaves `LN(pos,v)=v|0x40000000`; LSB-first 24-bit-window bit reader. Copy:
  `len = value<8 ? value+2 : 8+(1<<(value-7))+getBits(value-7)` (519 = end);
  `offset = len==2 ? (value<<2)|getBits(2) : (value<<dictType)|getBits(dictType)`,
  then `+1`. Dictionary size = `2^(dictType+6)` (dictType 6 -> 4096); the token-offset
  shift uses `dictType` directly (`value << 6`). LSB-first getBits(24) for seed bits.
- `graphics.cpp` (`Bitmap::load`/`Bitmap::decodeRle`) - `u16 flags`:
  RLE 1, HAS_DIM 2, HAS_POS 4, HAS_PAL 8, HAS_IMG 16; optional size/pos, optional
  1024-byte palette (R,G,B,unused), image. RLE = `u16 rows, u16 chunks` blocks:
  `chunks==0` skips `rows`; else per row `chunks` x (`u16 skip, u16 copy, copy
  bytes`); terminated by `rows==0`. Normal pitch = `(w+3)&~3`.
- `animation.cpp` (`Animation::load`) - header `u16 animListCount, u16
  animInfoStartOfs, u32 spriteDataOfs, u32 paletteDataOfs`; animList entries 8 bytes
  (`u32 hash, u16 frameCount, u16 frameListStartOfs`) at offset 12; frame records
  32 bytes (`u32 frameHash, u16 counter, u16 drawX, u16 drawY, u16 w, u16 h,
  ..., u32 spriteDataOffs` at +28). Frame pixels are always RLE at
  `base + spriteDataOfs + spriteDataOffs`; palette at `base + paletteDataOfs`.
- `sound.cpp` (`SoundResource`, `NeverhoodAudioStream`) - `extData[0]` = shift;
  0xFF = 16-bit signed LE PCM @22050 mono; otherwise 8-bit signed delta
  (`sample = ((prev + int8) & 0xFFFF) << shift`).
- `text.cpp` - `u32 count`, then count+1 offsets; string i spans
  `data[base+off[i]..base+off[i+1]]` with `base = 4 + count*4`; embedded NUL = line
  break.
- `video.cpp` - Smacker videos handled as header metadata (id, size) since playback
  needs libsmacker.
- `modules/*.cpp` / `*.h` (`modules/module*.cpp`, `scene.cpp`, `resource.cpp`) -
  scene composition is not stored in the BLB data, so palettes for surfaces without
  an embedded palette are associated *per scene*. Each scene constructor calls
  `setBackground(hash)`/`setPalette(hash)` (the background bitmap carries the
  scene palette); the sprites/mice/rects it inserts (`insertStaticSprite(0x...)`,
  `insertSprite<Class>(0x...)`, `insertScreenMouse(0x...)`, `insertPuzzleMouse`,
  `createStaticScene(bg, cursor)`, `loadSprite(0x...)`, and the file-scope
  `kSceneNNNN*`/`kSsSceneNNNN*` hash tables) borrow that scene's palette. This map
  is extracted offline from the sources into `neverhood_palette.lua`, required by
  `engine.lua` (surface hash -> palette bitmap/palette hash). A surface without an
  embedded palette resolves to its scene palette; if unmapped it is rendered in
  neutral grayscale (the automatic/external palette override is not applied, so no
  bitmap is shown with an arbitrary palette).

Archives verified: HD (74), A (329), S (358 animations incl. 84 redirects),
T (577), M (13), I (1316), C (83) -> 2706 tree nodes in 8 categories.

### VIRTUAL THEATRE (Lure of the Temptress, Beneath a Steel Sky)
Scummvm source code (`/scummvm-fork/engines/sky`, `/scummvm-fork/engines/lure`,
`common/compression/rnc_deco.cpp`) and http://github.com/scummvm/scummvm.
Games in `ags/sky` (SKY.DSK, SKY.DNR, SKY.CFG, SKY.RST) and `ags/lure`
(DISK1-4.VGA/.EGA). Two separate engines in ScummVM.

**Beneath a Steel Sky** (`engines/sky`):
- `disk.cpp` / `disk.h` - SKY.DNR is the file table: `u32LE count`, then each
  8-byte entry `u16LE fileNum, u16LE x, u32LE offRaw`; `offset = offRaw & 0xFFFFFF`
  (`<<4` when bit 23 set). Flags come from bytes 5-7 (`READ_LE_UINT24`): `size =
  ff & 0x3FFFFF`, `compressed = ((ff>>23)&1)==0`, `includeHeader = ((ff>>22)&1)==1`.
  Payload lives in SKY.DSK at `offset`.
- `screen.cpp` - a graphic file begins with a 22-byte `DataFileHeader` (11 x `u16LE`:
  flag, x, y, w, h, spSize, totSize, nSprites, offX, offY, compSize). RNC magic
  `52 4E 43 01` follows immediately. RNC `unpackM1` is applied when the header flag's
  bit 7 (`flag>>7 & 1`) is set and the RNC signature is present. ScummVM gates this on
  the DNR `compressed` flag alone, but sprite files 2134-2136 (whose DNR flag reads as
  uncompressed) are nevertheless RNC streams, so the signature check is authoritative.
  Decoded payload is the raw pixel data for both `includeHeader` values: `spSize==0` ->
  one `w*h` image (screens), else `nSprites` frames of `w*h` bytes each at stride
  `spSize`. Screens verified: file 64/92 -> 61440 (320x192), 65 -> 36480. Sprites
  verified: 49 (28x24 x2), 60300 (22x22 x9). All 1022 Sky resources decode without
  error.
  Palette file 60111 is 768 raw bytes, 6-bit RGB expanded with `(v<<2)+(v>>4)`.
- `common/compression/rnc_deco.cpp` - RNC "unpackM1". HEADER_LEN 18, TABLE_SIZE 128,
  signature 0x524E4301, `unpackLen`/`packLen` big-endian at 4/8, `blocks` at byte 17.
  Per block: three Huffman tables (raw/pos/len), `counts = inputBits(16)`, literal
  run via `inputBits`/`inputValue(raw)`, back-reference `inputValue(pos)+1` and
  `inputValue(len)+2`; bit reader re-syncs from the source after each literal run.

**Lure of the Temptress** (`engines/lure`):
- `disk.cpp` / `disk.h` - each DISK*.VGA: `"heywow"` ident, `u16BE` file number,
  then 0xBF(191) 8-byte `FileEntry` records (`u16LE id, u8 unused, u8 sizeExtension,
  u16LE size, u16LE offset`); real size `+= 0x10000` when `sizeExtension`, real
  offset = `offset * 0x20`. Resource id top two bits pick the disk:
  `((id>>14)&3)+1`; `0x3fxx` ids live in `lure.dat` (not shipped with the disks).
- `decode.cpp` - `PictureDecoder::vgaDecode`: data-start offset at `u32LE(data+0x400)`,
  secondary pointer starts at `0x404`; CH/CL bit counter, `BP = color << 2`, colour
  table at 0x000-0x3FF. Decodes to a 320x192 playfield (or 320x200 full screen).
  EGA variant is `egaDecode` (selected when `(u16BE(data) & 0xfffe) == 0x140`).
- `surface.cpp` (`Surface::loadScreen`) / `room.cpp` (`RoomLayer`) - the 320x192
  decoded image is placed at row `MENUBAR_Y_SIZE` (8) of the 320x200 surface; the
  room palette is `(screenId & 0xffe0) - 1`, overridden to 0x45ff (room 6), 0xf1ff
  (room 49) or 0x40ff for 5-bit screens.
- `palette.cpp` - palettes are 660-byte RGB64 resources (220 x 3 bytes, 6-bit
  components expanded with `(v<<2)+(v>>4)`); `PaletteCollection` splits them into
  64-entry sub-palettes.

Screens verified pixel-for-pixel against a Python `vgaDecode` reference (320x192);
Sky backgrounds and sprites verified pixel-for-pixel against the Python RNC
reference. Tree: Sky 1022 nodes (162 backgrounds, 853 sprites, 7 palettes); Lure
151 nodes (102 screens, 49 palettes). Lure character sprites are nibble-packed
animation streams whose dimensions come from `lure.dat` (absent from the disk
images), so they are not exposed.

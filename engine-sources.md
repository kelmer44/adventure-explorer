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

### CAPSTONE (Genus GXL)
No ScummVM engine exists for these games; the GXL container and its embedded
PCX images were reverse engineered from the data itself.
games in ags/capstone/WAYNE (Wayne's World) and ags/capstone/DARKHALF (The Dark Half)

GXL container: `01 CA` then the ASCII copyright
"Copyright (c) Genus Microprogramming, Inc. 1988-90", a 0x80-byte header, then a
directory of 26-byte entries (`flag u8`, `name char[12]`, NUL, `u32 offset`,
`u32 size`, `u32 unknown`). Number of entries = `(firstDataOffset - 0x80) / 26`.
Each entry payload is a standard version-5 PCX (8bpp, single plane, RLE) with a
256-colour palette in the trailing 768 bytes.

### CAPSTONE / Manley & Associates / Synergistic

`scripts/engines/capstone/engine.lua` handles Fievel / An American Tail
(`ags/capstone/AMTAIL`), The Beverly Hillbillies (`ags/capstone/BHB`) and
L.A. Law (`ags/capstone/LALAW`). Formats were reverse engineered from the
supplied game data and DOS executables; no ScummVM engine is used.

- AMTAIL.EXE code segment 0x2a28: LH1 adaptive Huffman/LZ77 decoder (314 symbols,
  4096-byte space-filled history), picture PackBits and actor masks. PIC streams
  contain dimensions, two VGA palettes, a u16 encoded-length field, then pixels.
  ACT streams contain 16-byte frame headers, row/skip/copy masks and literal pixels.
- HB.EXE (LZEXE 0.91): resource directory and decompressor at code 0x97c0,
  PackBits at 0x2a240. IMAG resources have big-endian height/width/plane count,
  word-padded, row-interleaved planes. Startup selects DS:A09 / DS:D09 palettes;
  the explorer reads these from the unpacked executable without running it.
- LALAW.EXE (LZEXE 0.91): LZSS decoder at code 0x2e4f7. DISK*.RES consists of
  consecutive 14-byte block headers and payloads. Image headers are 14 bytes;
  palettes follow directly, with whole payloads padded to a 16-byte boundary.
- BHB/LA Law XMIDI uses the existing host converter. BHB animation/scene/sound
  records and Fievel scene bytecode are data previews; LA Law ABT speech remains
  metadata. Lua boundary tests and an optional full-data scan live in
  `scripts/tests/capstone.lua`.


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

### RUNAWAY: A ROAD ADVENTURE

`scripts/engines/runaway/engine.lua`, reverse engineered from the supplied
Spanish Windows release in `ags/runaway`. Sources are the loose `RESOURCE/`
and `DATAA/` files, plus `Runaway.exe` extracted for analysis from `Cab25.cab`.
No ScummVM Runaway engine was used. The resource directory resembles Hollywood
Monsters, but its scene pixels are RGB565, not indexed graphics.

- Scene tables: 40 or 50 offsets followed by the same number of sizes; total
  320 or 400 bytes. Backgrounds are little-endian RGB565. Most are 600 rows;
  ten scrolling scene exceptions have size-checked, visually verified dimensions.
- Sprite banks: 14-byte frame descriptors and spans with x/y i16, length u8,
  then `length` RGB565 pixels. Standalone overlays use a u16 span count,
  x/y/length u16 records and RGB565 data. Mask strips omit the pixel data.
  Depth/walk masks use `(value u8, run length u16)` records.
- Audio confirmed from the executable's DirectSound WAVEFORMATEX initialization:
  VA 0x408294-0x4082af: stereo 16-bit / 16000 Hz; VA 0x408436-0x40845f:
  mono 8-bit / 16000 Hz; VA 0x4086d8-0x4086e7: mono 16-bit / 16000 Hz.
  Mxx, Sxx and DATAACA*.000 cue tables contain 100, 1000 and 12000 u32 offsets.
- `scripts/prepare-runaway.py` prepares the installation layout using cabextract;
  it links loose resources and extracts only game data and the executable to a
  separate output folder. The runtime does not depend on cabextract. Shared
  RESOURCE.000-.004 data and Bink cutscenes are not interpreted.
- `scripts/tests/runaway.lua` contains synthetic format/bounds regressions and
  optional real-data validation of every sprite bank and both ends of each bank.

### NOCTROPOLIS

`scripts/engines/noctropolis/engine.lua`, ported from the ScummVM Access engine.
Data extracted from a Spanish CD release into `ags/NOCTROP` (`DARK/`, `COMDATA/`).

Key references in `scummvm-fork/engines/access`:
- `room.cpp` (`loadPlayField`, `loadHeader`) - 19-byte Noctropolis playfield header,
  768-byte 6-bit palette, `TILE_WIDTH*TILE_HEIGHT` byte tiles, `tilesWidth *
  tilesHeight` u16 tile indices, then wall/block rectangles.
- `files.cpp` (`handleFile`, `loadRawFile`, `handleScreen`) - DBE container handling;
  `loadScreen` reads a 768-byte palette then a DBE-compressed 640x400 buffer.
- `asurface.cpp` (`SpriteResource`, `SpriteFrame`) - u16le count + u32le offsets
  container; each frame is u16le w/h then per row `u8 xOffset, u8 length, bytes`.
- `decompress.cpp` (`decompressDBE`) - LZW variant, "DBE\x01" magic, u32le unpacked
  size at offset 4, stream from offset 16, 9..12 bit codes, 256 clear, 257 end.
- `noctropolis/noctropolis_resources.cpp` - `NOCT_FILES_1/2` FILENAMES, `ICON_PALETTE`.
- `screen.cpp` (`setManPalette`, `setIconPalette`) - player palette at colours
  192..235, icon palette (no 6-bit conversion) at colours 236..255.
- `detection_tables.h` - detection files `dark/scene01.ap` + `dark/scene13.ap`.

Container parsing was verified against every scene (73 playfields), screen (27)
and sprite resource (17) in the release; all decode without error, with playfield
sizes matching the header arithmetic exactly.

### LES MANLEY 2: LOST IN L.A.

`scripts/engines/les2/engine.lua`, reverse engineered from the supplied Spanish
DOS release (`ags/LES2`). No external engine source is used.

- `EXE.EXE` contains consecutive 14-byte resource records at file offset 114867:
  u32 filename hash, lower-case DAT letter, zero pad, u32 offset, u32 size.
  The engine locates the longest valid run, rather than assuming this EXE offset.
- Filename hash is the sum of character bytes times position-specific u32
  coefficients (20 entries at EXE file offset 110026), modulo 2^32. Internal
  resource extensions are `.pic`, `.lsc`, `.pal`. Decompressed `.SCN` sources
  preserve original image names with `.lbm`, allowing image names and palettes
  to be recovered through the hash table.
- Picture headers mimic IFF (`FORM`, `ILBM`, `BMHD`, `BODY`), but BMHD is 19
  physical bytes despite declaring 20. BODY is contiguous LSB-first LZW,
  9..12 bits, 256 clear, 257 end; pixels are chunky, consecutive image frames.
- Palettes are raw 8-bit RGB, 82 in DATAA and `256.pal` in DATAZ. DATAA starts
  with a 576-byte symbol table followed by a 1095-byte name table, then text.
- Verified 498 of 499 pictures (267 still / 231 animated), all 83 palettes,
  and metadata previews with `scripts/tests/les2.lua`. DATAF offset 502964
  rejects an invalid LZW code and remains an explicit metadata entry. Audio,
  original animation timing/compositing and some palette associations remain
  unsupported. The unindexed tail of DATAZ is not exposed.

### EL TESORO DE LA ISLA ALCACHOFA

`scripts/engines/tesoro/engine.lua`, reverse engineered from `ags/TESORO` and
`TESORO.EXE`; analysis in `/tmp/tesoro/decomp.c` informed the implementation.

- TRE has NO header: 2421 x 28-byte records: u32 DAT offset, u32 payload size,
  u8 flags, name[19]. Flag bit 4 denotes a file. Every DAT resource has a u32
  size prefix; read `offset+4` for `size` bytes. Earlier handoff notes started
  records at byte 8 and incorrectly paired names with the NEXT resource.
- ANM magic is `ANM\x01` (`ANM\x00` for the 141 font glyphs), followed by a 24-byte bank header: u16 frame count
  at +4, u16 image count at +8 (relative to magic). Frame records are 24 bytes
  plus the u16 additional-data byte count at +22. Then image blocks follow,
  each with u32 size. LVL has `LVL\x01`, a 12-byte header, bank count at +8,
  and sequential ANM banks; magic scanning is unnecessary.
- Image buffer: u32 pixel offset, u32 pixel byte count, u16 w/h/type/unused,
  h row entries (u32 span-table offset, u16 span count, u16 unused). Each span
  is u32 pixel offset or colour, u16 relative x skip, u16 length. X skips are
  relative to the END of the preceding span. Type 1 uses RGB565 pixels,
  type 3 solid RGB565 spans, type 2 shadow intensities (grayscale preview).
- `scripts/tests/tesoro.lua` validates malformed structures and synthetic span,
  colour and WAV fixtures, then optionally loads all 2,012 images and 2,346 WAV
  clips. 112 multi-image banks offer uniform 100 ms sequence previews. Scripts
  use Latin-1; compiled scripts/object metadata expose readable strings.
- Both engines were exercised through the Kotlin/LuaJ developer CLI. No changes
  to the Kotlin runtime or external extraction dependencies are required.

### PINK — Pink Panther: Passport to Peril / Hokus Pokus Pink

Local media: `~/Desktop/ags/PINKPANTHER/Peligrosa` and `Abracadabra`.
Reference: local `scummvm-fork/engines/pink/file.{cpp,h}` (ORB/BRO directory),
`resource_mgr.cpp` (external resources), `cel_decoder.cpp` (CEL header/prefix),
`sound.cpp` (VOX is WAV), and `video/flic_decoder.cpp` (FLIC codecs).

ORB v2 header: `ORB\0`, u16 minor=0, u16 major=2, u32 timestamp,
u32 object-table offset, u32 count. Each 32-byte object entry contains a
16-byte NUL-terminated page name, u32 object offset/count, u32 resource-table
offset/count. Each 26-byte resource entry has name[16], u32 absolute offset,
u32 size, u16 inBro. External resources use a matching timestamp BRO v1 in
the root or INSTALL directory. Directory padding after the first NUL is garbage.

CEL files are 8-bit FLC (`0xAF12`), 128-byte headers, frame count at offset 6,
width/height at 8/10, millisecond delay at 16 and first-frame offset at 80.
The first-frame pointer skips the optional CEL prefix. Frame type `0xF1FA`
contains a 16-byte header, chunk count, optional delay/dimension overrides.
Supported chunks: 4/11 palettes, 7 SS2 word delta (line skip and odd last pixel),
13 black, 15 byte-run, 16 raw copy; 18 postage stamp is skipped. Palette and
pixels persist between frames; ring frames after the declared count are ignored.
Animations retain up to eight million pixels / 200 frames per preview batch,
replaying prior deltas to reconstruct later batches. CEL centers/transparency
are not composited. The host API uses one uniform frame delay per preview.

Audio is signature-detected RIFF PCM (including WAV, VOX and MUS names); text
is converted from Windows-1252. Other resource formats return metadata.
Tests: `lua scripts/tests/pink.lua [game directory]` covers synthetic codec and
malformed-input cases, and optionally loads every leaf of the supplied archive.

Pink media compatibility details: `Pub/PBDRPP04.CEL` contains a stale frame
size at frame 16; actual subchunk boundaries remain valid. Like ScummVM,
the decoder advances by chunk count/size while bounding reads to the resource.
`StrangeInterior/SBPP0001.VOX` has an odd-length sample payload without RIFF
padding before cue metadata. Parsing stops once format and sample data are
available, so this trailing metadata does not prevent PCM playback.

`TheMarket/IMVS0002.CEL` and `TheVillage/FVSPB004.CEL` undercount final COPY
chunks by two bytes, including word padding for odd pixel counts. Recovery is
allowed only when the pixel count plus padding exactly matches the enclosing
frame boundary. Synthetic tests cover both even and odd pixel counts; arbitrary
truncated chunks are still rejected.

Verification: archive sweeps plus targeted reruns exercised all 25,966 leaves:
Passport 4,032 images, 4,474 animation previews, 3,542 PCM clips, 2,772 texts;
Hokus Pokus 4,084 images, 3,290 animation previews, 3,042 PCM clips, 730 texts.
Kotlin compilation and Lua regressions pass. LuaJ exports cover both games,
a six-frame animation, the repaired COPY animation and odd-sized VOX audio.
The exported Hokus Pokus background and all six frames of Passport's
`NC00WART.CEL` match FFmpeg RGB output pixel for pixel. Odd-width SS2 uses
ScummVM's last-pixel opcode semantics, independently covered by synthetic tests.

### EL SULFATO ATOMICO

Game data: `/Users/gabriel/Desktop/ags/mortadelos/SULFATO`.
Implemented in `scripts/engines/sulfato/engine.lua`, from direct inspection of
this release. No external source or game executable execution was needed.

- ALG: standard 8-bit single-plane PCX layout, except signature `4E 4D 50 08`
  (`NMP` plus depth 8). Dimensions come from xmin/ymin/xmax/ymax, pitch at
  offset 66; image data begins at 128 and uses PCX RLE. Palette marker 12 and
  768 8-bit RGB bytes terminate each file. 111 images; some are 1280x480.
- `1.SVS` is a standard PCX save thumbnail (640x240), not a sprite bank.
- VHS: Autodesk FLC (0xAF12), 640x480 indexed images; chunks 4 (palette),
  7 (word delta), 15 (byte run), and 18 (postage stamp, ignored). Standard
  codecs adapted from the project's Pink Panther engine. Honor the first-frame
  offset (80), skipping prefix chunks, and declared count, excluding the extra
  loop-closing frame. 53 banks. Preview batches cap retained pixels at eight
  million; replay earlier deltas before emitting later batches.
- WAV: 735 PCM mono unsigned 8-bit clips, mostly 11025 Hz, five at 22050 Hz and
  one at 13157 Hz. `sk494.wav` contains a developer text message.
- ALD/CAL/GSV/SAV/TXT: 42 plaintext room/script/save/help files, plus the
  misnamed WAV. Text accents use Latin-1 bytes. These are raw text previews;
  no scene interpreter or inferred sprite rectangles.

Validation: `lua scripts/tests/sulfato.lua [game path]` covers picture padding,
RLE truncation/overflow, FLC bounds and delta reconstruction; the optional
full-data sweep loads every image, palette, sound and text and reconstructs
every animation through its last declared frame.

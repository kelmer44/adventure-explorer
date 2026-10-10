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

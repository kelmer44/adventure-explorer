## Sources for engines

### SCUMM
Scummvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
games are located in ags/scumm folder

### SCI
Scummvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
games are located in ags/sci folder

### HOLMES
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
Source code for some tools in ags/tools/holmes

games are located in ags/holmes and ags/holmes2

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


### Universe
No public source or ScummVM engine. Everything was derived by disassembling the
DOS loader in UNIVERSE.EXE and by decoding UNIVERSE.EPF directly:

- `UNIVERSE.EXE` 0xb4a2  loads the 11-byte EPFS header and the 22-byte-per-entry
                    directory
- `UNIVERSE.EXE` 0xb74a  compression method 1, the canonical-code Huffman/LZ
                    decompressor reimplemented in the engine script
- `UNIVERSE.EXE` 0xba09  code-width and mask setup (9 bits, widening to 14)

game in ags/universe/

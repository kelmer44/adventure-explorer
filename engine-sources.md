## Sources for engines

### DreamWeb

Implemented in `scripts/engines/dreamweb/engine.lua`. Local ScummVM references:
`engines/dreamweb/structs.h` (96-byte header, Frame/SetObject/TextFile layouts),
`stubs.cpp` (`loadRoomData`, `sortOutMap`, `loadGraphicsFile`, `loadTextFile`,
`screenUpdate`), `sprite.cpp` (`findSource`, `constant`, `backObject`),
`vgagrafx.cpp` (`loadPalFromIFF`, `showPCX`, `showFrame`), `backdrop.cpp`
(`doBlocks`) and `sound.cpp` (`loadSounds`, `loadSpeech`, `playSound`).

Full English UK CD freeware downloaded from ScummVM's official games page:
https://downloads.scummvm.org/frs/extras/Dreamweb/dreamweb-cd-uk-1.1.zip
SHA-256: `4a6f13911ce67d62c526e41048ec067b279f1b378c9210f39e0ce8d3f2b80142`.
Installed at `/Users/gabriel/Desktop/ags/Dreamweb`: 588 files / 271152260 bytes;
every installed file hash was compared with its ZIP member. No DOS executable ran.

Coverage: 11,777 catalog leaves (6,665 images, 12 animations, 8 palettes, 589
sounds and 4,503 text/report entries). Independent JVM map reconstruction agrees
pixel-for-pixel; sound-bank and speech PCM agree byte-for-byte. All leaves load
in LuaJ, with actual PNG/alpha, WAV, animation, DOS850 text and palette exports.
Seven title PCXs additionally match Pillow's independent decoding.

`lua scripts/tests/dreamweb.lua` exercises bounds, frame origin alignment, planar
PCX/RLE, VGA palette quantization, tiled maps, DOS850 strings and paged sound
offsets. `DREAMWEB_TEST_PATH=... ./gradlew --offline test --tests '*Dreamweb*'`
validates the full UK CD and exports. Packed RNCA installers, alternative language
releases and legacy aggregate speech files remain outside verified coverage.

### SCUMM
Scummvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
games are located in ags/scumm folder
Key references used:
- `engines/scumm/resource_v2.cpp` (`readEnhancedIndexFile`), `object.cpp`
  (`ScummEngine_v3old::resetRoomObjects`, `ScummEngine_v4::resetRoomObject`,
  `getObjOrActorName`) and `gfx.cpp` (`GdiV2::prepareDrawBitmap`) - enhanced DOS V2
  index, room-relative image/code tables, names and geometry, whole-bitmap column
  RLE/dither and following mask-byte RLE. The Spanish `ags/SCUMM/MANIAC` copy
  validates 53 backgrounds, 269 object sprites, 322 masks, 53 reports containing
  460 object records, and one EGA palette (PNG plus 48-byte RGB export). Decode
  within the declared room block and validate bitmap plus mask before offering
  object pictures; non-drawing hotspots can share image pointers. Tests:
  `scripts/tests/scumm_v2.lua`, `LegacyEngineDecoderTest`, `ScummV2IntegrationTest`.
- `engines/scumm/resource_v3.cpp` - old-bundle V3 index magic `0x0100`, global object table and byte-counted room/costume/script/sound directories with u16 offsets. Implemented in `scumm_v3.lua`; tested with `ags/SCUMM/LOOM` (DOS EGA).
- `engines/scumm/resource_v4.cpp` (`readResTypeList`, `readIndexFile`) - plaintext V4 `000.LFL`, LE sizes + two-byte tags, interleaved room/u32-offset directories. `resource.cpp` (`readRoomsOffsets`, `getEncByte`, `loadResource`) - XOR-0x69 `DISKnn.LEC`, offset-12 FO room table, eight-byte LF wrapper before indexed resources. Implemented in `scumm_v4.lua`; tested with `ags/scumm/MONKEYEGA` (81 backgrounds, 606 objects, 115 costume sheets, 2,020 animation previews).
- `engines/scumm/gfx.cpp` (`Gdi::getStripPtr`, `GF_SMALL_HEADER` branch) - V4 VGA `BM`/`OI` bitmaps: u32 length, then u32 strip offsets from the bitmap start, decoded with the V5 strip codecs; `room.cpp` - `PA` palette (u16 768 + RGB) and the 255 transparent-colour default. `object.cpp` (`resetRoomObject`, V4 branch) - `OC` x/8 at +9, y/8 at +10 (low 7 bits). Tested with the Spanish MI1 VGA floppy (`MONKEY_VGA_TEST_PATH`, `ScummV4AudioFontTest`).
- `engines/scumm/sound.cpp` (`readSoundResourceSmallHeader`, `convertADResource`) - nested `SO` containers with `AD`/`WA` children or bare `RO`; AdLib music marker 0x80, 0x11-byte header plus eight 16-byte instruments before the MIDI stream, 480 PPQN, tempo `500000 * 256 / ticks`, initial ppqn/3 delay. `midiparser_ro.cpp` - Roland `RO` stream (F0/F1 delays, Ax markers, 00/FF end, 120 PPQN). `charset.cpp` (`CharsetRendererCommon::setCurID`, `CharsetRendererClassic::prepareDraw`, `drawBitsN`) - V4 font data 17 bytes into the charset resource; per-glyph width, height, offsets and a continuous bpp bit stream.
- `engines/scumm/players/player_ad.cpp` (`Player_AD`) - AdLib `AD` playback ported to `ScummAdPlayer.kt`: 472 Hz timer; music events from offset 0x93 with instrument offsets `i * 16 + 19`, rhythm instruments at instrument byte 13, timer limit 256 (Loom 473, ticks x2, VLQ >> 2 instead of >> 1), Loom tempo meta event 81 (`0x73000 / timing`); effects as up-to-three-channel instrument/note programs with software envelopes on a quarter-rate timer. V3 old-bundle sounds (`readSoundResourceSmallHeader`): u16-sized WA block, then the u16-sized AD block with its payload 4 bytes in.
- `engines/scumm/object.cpp` (`ScummEngine_v4::resetRoomObject`, `getObjectImage`) - V4 OC dimensions and OI image payload at +8. `costume.cpp` (`ClassicCostumeLoader::loadCostume`) - V4 CO base at zero, explicit palette, u16 limb command offsets. V3/V4 EGA share the EGA strip decoder and hardware palette. Non-DOS variants remain unsupported.
- `engines/scumm/room.cpp`, `object.cpp` (`resetRoomObjects`, `resetRoomObject`) - V3 room dimensions, image offsets and separate object image/code tables. Invisible interaction rectangles can share the next object's image pointer; validate both strip-table width and encoded height before listing sprites.
- `engines/scumm/gfx.cpp` (`Gdi::drawStrip`, `drawStripEGA`) - u16 strip offsets, solid/alternating/previous-column EGA runs. `costume.cpp` (`ClassicCostumeLoader`) - V3 single-byte limb command offsets and old-bundle palette/offset adjustments.
- `engines/scumm/object.h` - ImageHeader (old/v7/v8), CodeHeader, RoomHeader layouts
- `engines/scumm/object.cpp` - OBIM/OBCD parsing, `getObjectImage` (IMxx state mapping)
- `engines/scumm/gfx.h` / `gfx.cpp` - BMCOMP_* strip codecs and SMAP decompression
- `engines/scumm/resource.cpp` - block search (`findResource`), tag aliasing, `readRoomsOffsets` (room table at offset 16 of each data part)
- `engines/scumm/detection_tables.h` - per-game data file conventions (e.g. DOTT `tentacle.%03d` with `kGenDiskNum`)
- `engines/scumm/metaengine.cpp` - generated per-room filenames (`%02d.LFL` / `%03d.LFL`)
- `engines/scumm/resource.cpp` - `readIndexBlock` / `readResTypeList` (V8: 32-bit counts, DRSC), `openRoom`/`readRoomsOffsets` (per-disc `.LA1`/`.LA2` room tables)
- `engines/scumm/costume.cpp`, `base-costume.cpp` - V5/V6 `COST` limbs/cels, byleRLE; `akos.cpp`, `bomp.cpp` - V7/V8 `AKOS` (codecs 1, 5, 16) and sequence (`AKSQ`) commands
- `engines/scumm/sound.cpp` (`readSoundResource`) - `SOUN`/`SOU ` chunks (SBL, ROL, GMD, ADL, SPK); iMUSE MIDI is a standard `MThd` after an `MDhd` header
- Explorer modules: `scumm_cost.lua` exposes actor cel sheets and costume animation/chore previews; `scumm_snd.lua` handles MIDI, digital iMUSE music, effects and speech (including external `.BUN` and V6 `.SOU` archives).
- `engines/scumm/imuse/imuse_player.cpp`, `imuse_part.cpp`, `sysex_scumm.cpp`, `instrument.cpp`, `imuse.cpp` (`HookDatas::set`, `copyGlobalInstrument`) - MIDI iMUSE ported to `audio/imuse/ImuseSequencer.kt`: 250 Hz timer, `TICKS_PER_BEAT` 480, MDhd start parameters, SysEx 0 (part setup), 16/17 (AdLib instruments, nibble-encoded), 48-53 (hooks; id 0 always fires, ids < 0x80 disarm), 64 (markers), 80/81 (loops), 96; jumps via `MidiParser::jumpToTick` without firing skipped events. `drivers/midi.cpp` (`IMuseChannel_Midi::pitchBend`, `IMuseDriver_GMidi::initDevice`) - GM output with transpose/detune through a 16-semitone bend range; `audio/mididrv.cpp` `_mt32ToGm`. `audio/adlib.cpp` (`MidiDriver_ADLIB`, OPL2 mode) ported to `AdlibOplDevice.kt`.
- `engines/scumm/imuse_digi/dimuse_bndmgr.cpp`, `dimuse_codecs.cpp` - `.BUN` bundles (LB83/LB23 directory, COMP block table, codecs 0-13/15), ported to `ImuseBundleCodecs.kt`
- `engines/scumm/nut_renderer.cpp` - `.NUT` bitmap fonts (codecs 1/21/44)
- MI3 (`COMI.LA0/1/2`) game located in ags/SCUMM/Monkey3 (music/speech in `RESOURCE/*.BUN`)

### SANITARIUM / ASYLUM

Engine: `scripts/engines/asylum/engine.lua`.
Local reference: `scummvm-fork/engines/asylum/`:
- `respack.cpp` (`ResourcePack::init/get`): u32 entry count and u32 resource offsets
  in RES/MUS archives, with the final entry ending at EOF. Includes the 27 known
  combined-speech length corrections, scoped to the exact 299872422-byte pack
  and RES.104/204/304 disc filename. Synthetic tests exercise correction scoping
  and retain EOF bounds checks.
- `system/graphics.cpp` (`GraphicResource::init`): D3GR header, content-relative
  frame-offset table, signed x/y origins, height/width and raw CLUT8 pixels.
- `system/screen.cpp` (`getPaletteData/setupPalette`): palette flag 0x2000, header
  offset +12, count/start header and six-bit RGB channels scaled by four.
  `blitMasked/bltMasked`: u32 height/width then row-major LSB-first packed bits;
  index 0 is the sprite colour key. Preserve frame offsets in animation canvases.
- `views/scene.cpp` (`Scene::load`) and `resources/worldstats.cpp`: DFISCN magic,
  background/font/current-palette bindings and scene header fields.
- `system/sound.cpp` and `system/text.cpp`: RIFF/WAVE audio and NUL-terminated text;
  retain dialogue control markup and convert Western Windows text from CP1252.

Verified demo data: official Windows demo, downloaded from
https://www.scummvm.org/frs/demos/asylum/asylum-demo.zip and installed at
`/Users/gabriel/Desktop/ags/Sanitarium-demo` (moved aside when retail CD 1 was copied).
The 5 RES packs contain 2,051 nonempty
frames, 89 non-font animation banks, 7 masks, 3 palettes, 171 WAV clips, 158 text
strings, and 5 unknown lookup/script resources exposed as bounded hex reports.
There are also 5 archive directories, 1 scene-header report and 4 video reports.

`lua scripts/tests/asylum.lua [game directory]` covers synthetic malformed data
and an optional full sweep. `AsylumDecoderTest` repeats synthetic cases in LuaJ;
`SANITARIUM_TEST_PATH=... ./gradlew --offline test --tests '*AsylumIntegrationTest'`
checks every demo leaf and PNG/WAV/animation/text/palette export. Background RGB
was also byte-identical to an independent Python/Pillow decode.
Retail CD 1 validation: `/Volumes/SANITARIUM1/Data`, copied with SHA-256 checks
(31 files / 501310805 bytes) into `/Users/gabriel/Desktop/ags/Sanitarium`.
The loader accepts the CD root/Data folder and nested Music/MUS.xxx tracks.
An independent archive inventory confirms 14,320 nonempty graphics frames,
29 masks, 1,723 WAV clips, 27 palettes, 3,911 strings and 130 reports. Seven
shared/menu fonts are separated from animation banks, leaving 666 previews.
`views/menu.cpp/menu.h`, `scenetitle.cpp`, `insertdisc.cpp` and `video.cpp` provide
menu-font/title/screen bindings. WorldStats title/palette fields serialize at
+0x2C0/+0x2C4 in retail, +4 bytes in the demo. Scene palettes take priority over
archive-order inference; alternate palettes must not recolour subsequent sprites.
`SANITARIUM_RETAIL_TEST_PATH=... ./gradlew --offline test --tests '*AsylumIntegrationTest.retail*'`
checks the complete CD 1 catalog and representative exports. CD 2/3, digital
release quirks, script-driven effects/composition and Smacker decoding remain
outside this verified CD 1 coverage.

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

Broken Sword 1 text, speech and music (`scripts/engines/sword1/sword1_extra.lua`):
- `objectman.cpp` (`ObjectMan::lockText`), `staticres.cpp` (`_textList`), `swordres.h`
  (`ENGLISH0` = 0x03000000, `FRENCH0` = 0x03010000, ...) - text cluster groups are
  languages, resources are sections; after the 20-byte header, u32 count and u32
  offsets at `(n + 1) * 4`, zero-terminated Latin-1 strings.
- `sound.cpp` (`initCowSystem`, `startSpeech`) - `SPEECHn.CL3`: u32 header size, u32
  words; room table first (byte offset into the header), line k at word `loc + 2k - 1`
  (absolute file offset in compressed clusters) and `loc + 2k` (size). Original `.CLU`
  speech uses a 16-bit run-length scheme from `expandSpeech` and is not decoded.
- Tested with the English CD release with MP3 speech and music (`SWORD1_TEST_PATH`,
  `Sword1AudioTextTest`): 6 text languages, 5,995 + 5,833 speech lines, 252 tracks.

Broken Sword II text, speech and music (`scripts/engines/sword2/engine.lua`):
- `header.h` (`ResHeader`, `TEXT_FILE` = 8), `protocol.cpp` (`fetchTextLine`) - after the
  44-byte header, u32 line count and u32 offsets from the start of the resource; each
  line is a u16 official text number followed by a zero-terminated Latin-1 string.
  `function.cpp` (`fnISpeak`) uses that number as the speech id.
- `music.cpp` (`getAudioStream`) - compressed clusters: u32 entry count, then from byte
  12 an (offset, samples, encoded length) triple per clip.
- Tested with the Spanish release with MP3 audio (`SWORD2_TEST_PATH`,
  `Sword2AudioTextTest`): 112 text files, 2,841 + 3,265 speech clips, 237 + 257 music
  clips.

### TINSEL
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
games are located in ags/TINSEL (DISCWLD for Discworld 1, DW2 for Discworld 2)

key reference files: engines/tinsel/handle.cpp (SCNHANDLE + chunk list),
object.cpp (DMA flags / decoder selection), graphics.cpp (all four decoders),
palette.cpp (DAC palette index shift), film.h / anim.cpp / multiobj.cpp /
play.cpp (FILM reels, animation bytecode, multipart origins and 24 Hz timing).
Tinsel exposes animated reels as playable Animation entries within each Sprites
file group; individual images remain available.

### DISCWORLD NOIR (Tinsel 3)

Engine: `scripts/engines/noir/engine.lua`; native bounded codecs:
`src/main/kotlin/adventureexplorer/graphics/NoirCodec.kt`.

Local reference: `/Users/gabriel/Desktop/source/scummvm-fork/engines/tinsel/`:
- `handle.cpp`: 24-byte index records, full 32-bit size, flags2 compression bit,
  IMAGE records ending in isRLE/colorFlags rather than a palette handle.
- `noir/lzss.cpp`: MSB-first LZSS, zero dictionary, cursor 1, offset-zero terminator.
- `graphics.cpp`: t3WrtNonZero/t3WrtAll, RGB565 word RLE and magenta transparency.
- `sound.cpp`: IDX/SMP offset records with length-prefixed MPEG subsamples.
- `music.cpp`: MusicSegmentNoir (length/offset into MUS, MPEG Layer II on discs).
- `strres.cpp` / `strres.h`: linked TXT chunks, 64 IDs/chunk, extended lengths.

Original English CDs mounted at `/Volumes/DWN_ENG_1/cd1`,
`/Volumes/DWN_ENG_2/cd2`, `/Volumes/DWN_ENG_3/cd3`. The browser discovers the
other mounted discs when any of these roots/data folders is opened. CD 3
contains shared `english.idx` and `english.smp`; CDs 1/2 contain scene files.
Copied flat installations and cd1/cd2/cd3 folder layouts also work.

All 12,041 images in this disc set decode through LuaJ. Music, speech/subsamples,
TXT pages and chunk/file metadata are exposed. BMV movies and actor model files
have metadata/hex only; animation scripts and blend effects are not replayed.

### TRICK OR TREAT
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)


Animations, text and audio: `engine.cpp` (`loadAnimation`, `loadAnimationForDirection`:
u16 frame size, u8 frame count, u8 directions, frames), `resources.cpp`
(`loadCharAnimation`: `PERSONAJ.SPT` with only a u16 frame size; `readTextRegister`:
263-byte `CONVERSA.TXT` records, Pascal strings XORed with `_decryptionKey` from
`tot.cpp`), `graphics.cpp` (`putImg`: u16 width-1, u16 height-1, pixels, 0
transparent), `sound.cpp` (`loadVoc`: loose VOC files and VOC clips in `EFECTOS.DAT`;
`playMidi`: `.MUS` is standard MIDI). Tested with the Spanish release (`TOT_TEST_PATH`,
`TotExtraTest`).
### TOONSTRUCK
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
Tool in ags/tools/Pak reader.exe

game located in ags/toonstrk

### TOUCHE
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)

game located in ags/Touche


Sprites, icons, audio and text: `resource.cpp` - resource tables (sprites 0x2A0, icons
0x390, programs 0x908, music 0xB60, sounds 0xC28; entry n runs to entry n + 1, unused
slots share an offset), `res_loadSprite`/`res_loadImage` (u16 size + RLE rows) and
`res_loadImageHelper` (frame size from the 64/255 markers, colours 1-63 -> 193-255),
`res_loadSound` (VOC), `res_loadSpeechSegment` (`V<n>`: (offset, size) pairs, VOC
clips), `res_decodeProgramData` + `touche.cpp` `getString` (u32 at +4 -> u32 string
offsets), `startMusic` (standard MIDI). Tested with the Spanish CD (`TOUCHE_TEST_PATH`,
`ToucheExtraTest`): 49 sprite sheets, 85 icons, 119 sounds, 25 tracks, 58 programs,
7,989 speech clips.
### Shadow of the comet
Branch on a scummvm fork https://github.com/sev-/scummvm/tree/comet

game located in ags/SHADOW

### Visionaire Engine (Daedalic games)
Tools in ags/TOOLS/ANB

### Gob engine
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)

games in ags/GOB/, ags/FASCI/ and ags/Woodruff/

GOB references: `engines/gob/dataio.cpp`, `resources.cpp`, `video_v1.cpp`,
`video_v2.cpp`, `inter_v1.cpp`, `inter_fascin.cpp`, `sound/musplayer.cpp`, and
`video/coktel_decoder.cpp`. STK and ITK share the directory layout. Fascination
stores most sprites/palettes in TOT, starts in DISK0.STK and uses MDY/TBR music.
Woodruff uses palLoad subcommand 61, positioned background strips and indexed
VMDs in WOODRUFF.ITK. Unused VMD part descriptors contain arbitrary size bytes;
ignore them before reading or validating the size. Fascination's TIRA/TIRB use
PreIMD (128x80 with the calling TOT's palette); TIRB's frame count is one larger
than the number of physical records, so index the records before making clips.

AdLib music: `sound/adlib.cpp` (register writes, piano/drum presets, the 25-step
pitch-bend frequency tables, percussion voices), `sound/adlplayer.cpp` (ADL events at a
1 kHz timer, instrument modification) and `sound/musplayer.cpp` (MUS/SND timer of
`ticksPerBeat * tempo / 60` Hz). The chip is a Kotlin port of Nuked OPL3 1.8
(`audio/softsynth/opl/nuked.cpp`, upstream LGPL 2.1+); `Opl3Test` checks it sample for
sample against the C original. Event spacing follows the formats' delay values exactly;
ScummVM's timer loop adds one tick per delay, which is not reproduced.

Validation (2026-10-19): 1,964/1,964 Fascination and 5,110/5,110 Woodruff
resource leaves decode, including every video clip and nonempty VMD soundtrack.
Gobliiins 1/2/3 regressions decode all 457/335/367 image and palette leaves.
Full Gradle suite: 88 passed, 16 optional integration tests skipped, no failures.

### INDARK engine
Free in the dark engine in https://github.com/yaz0r/FITD

games in ags/INDARK


Samples and text: `LISTSAMP.PAK` entries are Creative VOC files; language PAKs (entry 0)
hold `@<number>:<string>` lines in code page 437, later entries are document pages with
`#` layout codes. Tested with the Spanish AITD 1-3 (`AITD_TEST_PATH` = folder holding
INDARK1-3, `AitdExtraTest`): 104/175/243 samples, 21/48/47 text entries.
### CINE
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)

Local data: `ags/LVDT` (Future Wars), `ags/CR256` (Cruise for a Corpse).
Operation Stealth data is not installed in these locations.

Sprite references: `scummvm-fork/engines/cine/anim.cpp` (`loadAni`, `loadSet`,
`convert8BBP`, `convert8BBP2`) and `gfx.cpp` (`gfxConvertSpriteToRaw`);
`scummvm-fork/engines/cruise/dataLoader.cpp` (`loadSetEntry`, `decodeGfxUnified`).
Cruise background palette layouts are in `background.cpp`.
Local validation (2026-10-18): all 1,989 Future Wars and 2,345 Cruise bitmap
frames decode. Cine ANI/ANM and SET plus Cruise SET/SEC are exposed individually,
with selectable background palettes. Cruise type-0 polygon records are exposed
as flat vector poses in the model viewer. All 2,812 poses, including mirrored
references, decode and render through the LuaJ integration test. Reference:
`cruise/mainDraw.cpp` (`flipPoly`, `buildPolyModel`, `drawPolyMode2`) and
`gfxModule.cpp` (`gfxModuleData_setPalEntries`, direct 8-bit RGB). See
`CruiseModelDecoder.kt` and `CruiseModelDecoderTest.kt`.
Operation Stealth decoding has synthetic format tests; no real-data validation.
See `scripts/tests/delphine.lua` and the Delphine sprite section of RESEARCH_REPORT.md.

### COBRA MISSION
https://moddingwiki.shikadi.net/wiki/Cobra_Mission
https://github.com/BlackStar-EoP/cobra-mission-writer
https://moddingwiki.shikadi.net/wiki/MegaTech_VOL_Format

games in ags/COBRA

Local data verification (2026-10-17): CODE.VOL has seven encoded authoring
scripts (856 scene labels in the Spanish copy), decoded with
`(0x11F - byte) % 256` for high bytes. ICP.VOL has a 16-byte IC header and
length-delimited constants; 98 whole ASCII strings are exposed, binary
constants remain undecoded. PCM1-6.VOL contain 155 Creative VOC clips using
8-bit PCM, silence and loop blocks. Runtime previews loop bodies once.
The existing 286 GC images remain available. See RESEARCH_REPORT.md section
2.3 and scripts/tests/cobramission.lua for the verified layouts and regressions.

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

Additional local data/executable verification (2026-10-20): SPR and BRD share
paragraph-offset / four-plane RLE, yielding 2,058 and 637 valid frames. SMALL.BRD
has one out-of-file padding word, skipped. Room sprites combine their matching
MAP's first 192 colours and SPRITES.PAL's upper 64; index 0 is transparent.
The 19 SFX banks contain 109 u16-length-prefixed unsigned 8-bit mono PCM samples
behind u16 byte-offset tables. CURSE.EXE file offsets 0x8342-0x8349 initialize
Sound Blaster DSP with 0x40/0x83 (8000 Hz); previews use that initial rate.
Three named DAT sequences expose 5/6/4 full-screen frames at fixed preview timing.
See scripts/tests/curseofenchantia.lua and CurseOfEnchantiaIntegrationTest.

games in ags/CURSE

### Dark Seed
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)

games in ags/darkseed and ags/DSEED35

Room palettes are `ROOMn.PAL` in both releases; the PAL/NSP fields inside
`ROOMn.ROM` are stale editor metadata. The PIC field still identifies the
background. Named CD backgrounds are matched to their owning ROM, and standalone
NSP animations inherit their room or fullscreen picture palette. Shared world
sprites/documents use a representative room palette and retain manual overrides.
Rooms 20/22 use room 19's palette; the 61A walk-map variant uses room 61's.

Regression/full-data validation: `lua scripts/tests/darkseed.lua
[/path/to/DSEED35] [/path/to/DARKSEED]`.

Text and audio: `tostext.cpp` (`TosText::load`, `loadString`) - u16 offset table whose
first entry / 2 is the count, strings run to the next offset; `sound.cpp` - speech
`SPEECH/<n>.VOC` for text entry n, `SOUND/*.SFX` (Creative VOC), `SOUND/*.MID`
(standard MIDI). Tested with the Spanish CD (`DARKSEED_TEST_PATH`,
`DarkSeedAudioTextTest`): 979 text entries, 667 speech clips, 49 effects, 20 songs.

### Dark Seed 2
No ScummVM engine exists for this game, so the format was reverse engineered from
the data itself plus the Dark Seed II resource tooling:
https://github.com/DrMcCoy/darkseed2-tools (see `src/unglue.cpp` for the Glue
archive container and its LZ variant).

Sprite decoding is verified against the supplied game data: `biCompression=2`
BMPs store `u16 xOffset, u16 length, byte pixels[length]` rows in BMP order
(positive height: bottom-up; negative: top-down).
They carry no palette. Scene sprites borrow the `RMdddd.BMP` palette in their
archive; shared walking/action/UI archives use `FIX.PAL` (256 BGR0 quads).
Embedded BMP palettes take precedence unless explicitly overridden. The first
95 nonzero colour indices are shared in sampled room palettes, while higher
indices vary by room; `FIX.PAL` alone is insufficient for scene objects.
The tree lists 83 backgrounds, 3660 sprite/UI frames, 83 thumbnails and 84
palettes, without decompression during listing. Frames are individual images,
with index 0 filling cropped areas; no animation sequencing is inferred.
Regression/optional full-data validation: `lua scripts/tests/darkseed2.lua
[/path/to/DARKSEED2]`.

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

Loose files (from the data; the `.SND`, `.XMI` and `.GFT` names are referenced in
`WW.EXE`/`DH.EXE`, which use the DigPak/MidPak drivers shipped beside them):
- `*.SND` headerless unsigned 8-bit PCM; sample rate not stored (11,025 Hz assumed).
- `*.TXT` bytes with bit 7 set are ASCII; lower bytes are spare font glyphs for Spanish
  letters (mapping derived from word context, different per game); `0x7F` ends the file.
- `*.GFT` Genus font: first/last character u16 at +0x24/+0x26, x-offset table and bitmap
  u32 offsets at +0x48/+0x4C, bytes per row and height u16 at +0x50/+0x52, one 1bpp strip.
- `*.MSK` 320x150 1bpp masks (6,000 bytes).

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

Audio and text (`HarvesterCmp.kt`, `scripts/engines/harvester/engine.lua`): `.CMP` is
"FCMP", u32 payload size, u32 sample rate, u16 bits, then one mono IMA ADPCM stream from
predictor 0 / step 0, low nibble first (high-first decodes drift and clip). Sources:
MultimediaWiki "FutureVision audio formats" and
https://alexbevi.com/blog/2026/03/29/reverse-engineering-harvester-with-ghidra-and-codex-part-5-debugging-audio-issues/
(the game zeroes the first 50 music samples). `INDEX.002` indexes `SOUND.DAT` (voices
and more WAVs) with the same 148-byte XFLE records as `INDEX.001`. `DIALOGUE.IDX` and
`HARVEST.SCR` are Latin-1 text XORed with 0xAA except CR/LF (the `0XAA.EXE` tool in the
game folder); `DIALOGUE.SPN` is the same dialogue unencrypted. Tested with the Spanish
release (`HARVESTER_TEST_PATH`, `HarvesterCmpTest`).

game in ags/harverster

### EXPRESS
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
extra tooling source code in AGS/TOOLS/EXPRESS

game in ags/lastexpress

Sounds and subtitles: `sound/mixer.cpp` (`decodeSamples`, `mix`) and `sound/slot.cpp` -
`.SND` is a 6-byte header (block count at +4) then 739-byte blocks: i16 predictor, i16
step index (x64), 735 bytes of codes, high nibble first, 22050 Hz; a block with a step
above 88 ends the sound. ScummVM's 1424-entry delta/step tables equal IMA ADPCM with
`delta = (2 * (code & 7) + 1) * step / 8` (clamped to 16 bits) and the standard index
adjustment, so `LastExpressAdpcm.kt` computes them. `sound/subtitle.cpp`
(`Subtitle::load`) - `.SBE` u16 words: count, then start, end, top length, bottom length
and one Latin-1 character per word. Tested with the Spanish CDs
(`LASTEXPRESS_TEST_PATH`, `LastExpressAdpcmTest`): 1,721 sounds, 227 subtitle files.

### KYRA
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)
extra tooling source code in AGS/TOOLS/KYRA

Kyrandia 1 (LoK) per-scene palettes: each scene has a `<NAME>.DAT` (packed in
`DAT.PAK`, or loose) that stores 20 VGA colors at offset 0x17. ScummVM copies
them into palette1[228..247] (`sprites.cpp` loadDat), which `initSceneScreen`
then copies into palette0[228..247] (`scene_lok.cpp`). The room `.EMC` scripts
do not set this band (only a few call `o1_setCustomPaletteRange`).

games in ags/KYRA/

Shared Westwood helpers (`scripts/engines/shared/westwood.lua`, reachable from every
engine through `require`):
- `graphics/screen.cpp` (`DOSFont::load`, `drawChar`) - 0x0500 font signature, descriptor
  (count - 1, height, width), bitmap/width/height tables, 4-bit rows low nibble first.
- `graphics/screen_v2.cpp` (`getPtrToShape`) and `screen.cpp` (`drawShape`) - u16 count,
  u32 offsets + 2; shape header (flags, height, width, unpacked size, colour count when
  flags & 4, colour table when flags & 1 = plot type 4), LCW data unless flags & 2, row
  runs with 0 + n transparent skips.
- `engine/util.cpp` (`decodeString1`, `decodeString2`), `engine/kyra_hof.cpp`
  (`getTableString`) - string tables; `script/script.cpp`, `script.h`
  (`stackPosString`) - EMC2 `TEXT` chunk with big-endian offsets.
- XMIDI files with several sequences use `midi_create_from_xmi(data, index)`;
  `xmi_sequence_notes` hides empty slots.
- Tested with Spanish Kyrandia 1 and Hand of Fate (`KYRA1_TEST_PATH`,
  `KYRA2_TEST_PATH`, `WestwoodExtraTest`).

### HOLLYWOOD MONSTERS
Ghidra project through the MCP server

game in ags/hollywoodmonsters

### IGOR
branch igor in fork https://github.com/dreammaster/scummvm/tree/igor/engines/igor
game reimplementation in https://github.com/cyxx/igor
tools in ags/tools/igor

game in ags/igor and ags/igor-cd

Spanish floppy and CD screen support refreshed on 2026-10-16 against the local
`igor-stuff/reference/scummvm-create-igortbl/resource_sp_floppy.h` and
`resource_sp_cdrom.h`. Game data used for validation is in `igor-stuff/IGOR`
and `igor-stuff/IGOR-CD`. The explorer embeds the verified offsets and does not
require the catalogs or IGOR.TBL at runtime.

Coverage: 76 floppy / 75 CD raw room backgrounds (including the beach ending),
three telescope views per version, 10 floppy / 12 CD startup and credit images,
five intertitles and four interface panels per version. The floppy has its own
math corridor and different room artwork, palettes and text. Telescope views
follow `part_32.cpp`: sparse frames 1 / 2 / 2+3, table 0x851e, bank loaded at +1.
The beach ending shares PAL_Part79. IMG_Part78Layer2 and IMG_Part79Layer2 are
animation banks, not raw screen pictures; IMG_Part81Strip is a 285x72 moving strip.
Floppy title resources are IMG_TitleScreen and IMG_FloppyTitleBackdrop with
PAL_TitleScreen; the old supposed shareware screens were invalid scan results.

Existing animation/audio coverage: 31 CD / 10 floppy frame groups, both Igor
outfits, 68 CD effects, 1,292 speech clips and floppy CMF music. Sparse frame
addressing follows `graphics.cpp::getAnimFrame`; intertitle colours follow
`part_main.cpp::partMainMeanwhile`. Validate screens with `scripts/tests/igor.lua`
and export the gallery with `scripts/igor-gallery.py`.

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

Sound, music and text layouts were worked out from the game files directly: RIFF/VOC
signatures and VOC block chains in the `S`/`VB`/`VS` files, `FORM XDIR` headers in the `A`
files, and XOR `0x6F` on the `PROG`/`MAIN` scripts (the copyright string decodes cleanly).

### Queen
Scummmvm source code (/scummvm-fork folder in the workspace or http://github.com/scummvm/scummvm)


game in ags/QUEEN


### LGOP2 (Leather Goddesses of Phobos 2)
ScummVM source code - MADE engine (/scummvm-fork/engines/made/ or http://github.com/scummvm/scummvm)
Key files: resource.cpp, graphics.cpp, sound.cpp, made.cpp

game in ags/LGOP2

The DOS PRJ contains 1,141 FLEX pictures and a single 256-color palette in
picture 547. Paletteless pictures inherit that shared RGB palette; scan the
entire FLEX index, including when loading a resource without enumerating first.
The preview exposes the shared palette through `default_palette` and returns its
swatch alongside each image. Image roles are inferred: full-width (320-pixel)
views are backgrounds, visually identified controls/cursors/menu/title graphics
are UI, and the remaining cutouts/poses/props are sprites. For this release the
split is 176 backgrounds, 859 sprites and 106 UI images; cropped scene fragments
may need further refinement. Regression: `lua scripts/tests/lgop2.lua` (optionally
pass the installed game folder to decode every picture).


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
- `TEXT*.<lang>` text files: layout (u16 offset table, 4-byte prefix, zero-terminated
  CP437 strings) worked out by inspecting the decompressed entries

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

**Lure of the Temptress** (`engines/lure`), additions in `lure_extra.lua`:
- `sound.cpp` (`musicInterface_Play`, `MidiMusic::MidiMusic`) - banks 0x0C/0x0D (main,
  Roland/AdLib), 0x30/0x31 (intro), 0xFF10/0xFF11 (end game): count byte, u32 offsets
  from byte 2, standard MIDI files, optionally packed ('C'/'c' + 256 u16 words + one
  index byte per word).
- `disk.cpp` (`openFile`) - `lure.dat`: "lure" + version, (language, u32 offset)
  records until 0xFF, each block a disk-style volume. `lure.h` (`LureLanguage`): 3
  English, 5 Russian, 6 French, 7 German, 10 Italian, 17 Spanish.
- `strings.cpp` (`StringData`) - decoder 0x3F19 (char + '0'/'1' sequence, first bit
  lowest), string tables 0x10-0x12 (2000 ids each), names resource 9 for codes >= 0xA0.
  The block whose decoder gives the shortest average strings is used (wrong tables
  rarely reach the terminator).
- `res.cpp`, `res_struct.h` - hotspots 0x3F07 (62-byte records: name id +2, size
  +24/+26, colour offset +40, animation record +42), animations 0x3F0B (18-byte records:
  id, disk resource, flags). `hotspots.cpp` (`Hotspot::setAnimation`) and `decode.cpp`
  (`AnimationDecoder::decode_data`) for the frames; game palette 0x3F01 (RGB64).
- `surface.cpp` - font resource 4 (8x8 glyphs from 32); codes 0x80-0x99 are accented
  letters, used for the Unicode text.
- Tested with the Spanish VGA floppy plus `lure.dat` (`LURE_TEST_PATH`, `LureExtraTest`):
  162 MIDI entries, 102 sprite sets, 3 string tables.

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

Sky audio and text (`sky_extra.lua`, `sky_huff.lua`):
- `sound.cpp` (`Sound::loadSection`, `playSound`) - section driver file `60203 + 4 *
  section`; signature bytes at `asmOfs` (0x7E, or 0x78/0x7C for v0.0109), sound count at
  +1, sample-rate table pointer at +0x29, sfx base at +0x31. Big-endian tables: rate per
  sound (capped at 11025), 8-byte info (paragraph offset from the base, size, loop).
  Unsigned 8-bit PCM.
- `music/musicbase.cpp`, `gmmusic.cpp`, `gmchannel.cpp` - files `60200 + 4 * section`,
  song table at `u16LE(0x7DC)` (0x79B for v0.0109), per song tempo0/tempo1 and channel
  pointers; channel bytecode: VLQ delays, notes with `_veloTab`, 0x8n channel select,
  0x9n commands (note off, stop, instrument via `MidiDriver::_mt32ToGm`, tempo, pitch,
  volume, loop, key off, pan, loop point, controller). Polled 50 times per second with
  `tempo0 * tempo1 / 3000` ticks per poll.
- `text.cpp` (`getText`, `getTextChar`, `makeGameCharacter`) and `hufftext.cpp` - text
  files `60600 + 8 * language + section`; block size table at +4, per-message skip bytes
  at `u16LE(+0)`, bit stream at `u16LE(+2)` in 2-bit units; nine version-specific Huffman
  trees (generated into `sky_huff.lua`). Fonts 60150/60520/60521: 128 width bytes, then
  12 rows of big-endian data/mask words per glyph. `disk.cpp` (`loadFile`,
  `determineGameVersion`) for RNC payloads with or without the 22-byte header.
- Tested with the English v0.0331 floppy (`SKY_TEST_PATH`, `SkyAudioTextTest`): 142
  effects, 30 songs, 64 text sections in eight languages.

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

### 3 SKULLS OF THE TOLTECS

- Game: `/Users/gabriel/Desktop/ags/3SKULLS/ESPA_OL.PDI/WESTERN` (Spanish CD).
- Local reference: `/Users/gabriel/Desktop/source/scummvm-fork/engines/toltecs/`.
- `resource.cpp`: offset directory and archive resource boundaries.
- `toltecs.cpp` (`loadScene`): scene dimensions, 128-color VGA palette and RLE.
- `screen.cpp`: GUI RLE and animation delta RLE (nibble-swapped colors).
- `sprite.cpp`, `screen.h`: 12-byte frame records, 16/256-color and shadow packets.
- `animation.cpp`: full palette, chained frame sizes, delta skips and hold markers.
- `palette.cpp`: VGA expansion, fragment allocation and interface palette base.
- `sound.cpp`: unsigned 8-bit mono 22050 Hz PCM; `music.cpp`: XMIDI/SMF.
- Implementation: `scripts/engines/toltecs/engine.lua`.
- Validation: `lua scripts/tests/toltecs.lua ~/Desktop/ags/3SKULLS` plus Gradle
  `compileKotlin` and the LuaJ `devcli` resource/export checks.

### AMAZON: GUARDIANS OF EDEN

- Supplied Spanish floppy data: `/Users/gabriel/Desktop/ags/AMAZON`.
- Local format reference: `/Users/gabriel/Desktop/source/scummvm-fork/engines/access/`.
- `files.cpp`: AP count/offset directory, DBE detection and palette-prefixed screens.
- `decompress.cpp`: DBE LZW, LSB-first codes, clear/end codes and early width growth.
- `room.cpp` (`loadHeader`, `loadPlayField`): 16-byte Amazon header, 256-byte
  tiles, one-byte tile indices, embedded VGA palette and trailing navigation data.
- `asurface.cpp`: sprite bank offsets, per-row crop and raw pixels.
- `video.cpp` (`VideoPlayer_v1`): dimensions/flags, u16 packet lengths,
  skip/literal deltas and optional initial raw background.
- `sound.cpp`: STEVE signed PCM rates and MIDI loading; `screen.cpp`: palette expansion.
- Palette links follow conversation calls in the decoded room scripts and
  `CharEntry` cells/videos: character numbers differ from room numbers (C00 uses
  S05, C05 uses S19, etc.). `loadBackground` transitions select distinct palettes
  for C03, S14, S28 and S64 videos. Chapter heading frames use screen 16; chapter
  illustrations use screen 15. Death, credits, inventory and shared player sheets
  use their drawing scene's palette; manual palette overrides remain available.
- Implementation: `scripts/engines/amazon/engine.lua`; regression/full-data scan:
  `lua scripts/tests/amazon.lua ~/Desktop/ags/AMAZON`.

### UNA AVENTURA DE CINE (ALCACHOFA V3)

`scripts/engines/alcachofa/engine.lua`, verified against the supplied Spanish
2003 CD in `ags/mortadelos/decine`, extracted with `scripts/prepare-decine.py`.
ScummVM references in the sibling `scummvm-fork` checkout:
- `engines/alcachofa/graphics.cpp`: `AnimationBase::readV3`, `readImageV3`,
  `Animation::imageIndex`, `spriteBounds` and `prerenderFrame` describe embedded
  TGA boundaries, sprite base/mapping tables, image offsets and frame composition.
- `engines/alcachofa/sounds.cpp`: `loadSND` describes the removed WAV chunks and
  the PCM / Microsoft IMA ADPCM formats. Decoder uses standard IMA per-bit
  rounding and includes each block's predictor sample, matching FFmpeg output.
- `engines/alcachofa/rooms.cpp`: `loadEncryptedFile` describes the embedded NKR
  XOR key after 32 cipher bytes, followed by four garbage bytes to discard.
- `engines/alcachofa/detection_tables.h`: Spanish CD `OBJETOS.NKR` size 24467,
  engine V3.0. Detection requires this game's named background and text folder.

Previews use an animation-wide bounding canvas, stored sprite offsets and alpha
blending over gray. Scripted frame center/movement, scene layering and variable
frame delays are not replayed. Batches cap decoded output at 100 frames / 8M
pixels. Three Ofelia banks contain no sprites/images and show placeholder text.
All 981 AN0 bank structures are checked; tests cover malformed TGA/AN0 input,
color order, ADPCM predictors and encrypted text headers. Actual runtime exports
were checked through the JVM developer CLI. BIN files are video data, not archives.

Opening guidance for Runaway and Una Aventura de Cine is available in each
engine's resource tree and in README.md. It distinguishes installed/extracted
folders from installer media, gives preparation commands and dependencies, and
explains that Runaway's linked loose files still require the original media.

### GRIM FANDANGO

Original PC discs available at `/Volumes/GRIM_DISC_A/GRIMDATA` and
`/Volumes/GRIM_DISC_B/GRIMDATA`; either disc root also opens directly.
Reference: workspace `scummvm-fork/engines/grim/`:
- `lab.cpp`: original LABN v0x10000, 16-byte directory records and string table.
- `bitmap.cpp`: BM header, per-image dimensions, RGB565, raw codec 0 and codec 3 LZ.
- `material.cpp`, `colormap.cpp`: MAT texture offsets and indexed data; CMP RGB at 64.
- `imuse/imuse_mcmp_mgr.cpp`, `imuse/imuse_sndmgr.cpp`: MCMP block tables,
  embedded WAVE/iMUS headers, PCM byte order and audio format fields.
- `movie/codecs/vima.cpp`: VIMA/IMA4 predictor tables and mono/stereo decoding.
- `localize.cpp`: RCNE dialogue XOR 0xDD, Windows-1252 in supplied PC release.

Implementation: `scripts/engines/grim/engine.lua`; regressions and optional
full-media scans: `scripts/tests/grim.lua`. Stored image states are independent
leaves rather than inferred animations. Texture palette assignment is manual;
no 3D renderer, script execution, scene composition, movie playback or iMUSE
transition simulation. Remastered/EMI and alternate platforms are not claimed.

### SAGA (I Have No Mouth, and I Must Scream)

Reference: `/Users/gabriel/Desktop/source/scummvm-fork/engines/saga/`.
Test data: `/Users/gabriel/Desktop/ags/IHNMAIMS` (Spanish DOS CD).
Implementation: `scripts/engines/saga/engine.lua`.

- `resource.cpp` (`loadResV1`): final 8 bytes are LE table offset/count;
  each zero-based entry is LE offset/size. Table ends immediately before footer.
- `saga.cpp`: full CD scene LUT = resource 1272, module LUT = 29,
  main strings = 21. `scene.cpp`: 14/16-byte scene descriptors, resource-list
  entries are u16 resource/u16 type; 2 = background, 3 = mask, 5 = strings,
  14..23 = animation, 27 = palette.
- `image.cpp`: 8-byte header, 768-byte RGB palette, SAGA RLE with literal,
  repeat, backreference and two-color bitfield commands. Four-row banking,
  height rounded up to 4; backgrounds flip vertically, masks do not.
- `sprite.cpp`: u16 count, u32 offsets; i16 x/y, u16 width/height, then
  skip/copy byte pairs. Flip vertically. Clamp shipped final transparent
  overruns just as ScummVM does (e.g. resource 834 frames 3 and 5, zero-based).
- `resource_res.cpp`: seven chapter metadata records (326,517,677,805,968,
  1165,1271) identify inventory/faces, actor/object strings and cutaways.
  Cutaways are 8-byte background/animation/cycles/rate records.
  `introproc_ihnm.cpp` uses resource 39 for intro cutaways.
- `animation.cpp`/`.h`: magic LE 0x0044, 12-byte header, BE delta-frame
  commands; IHNM uses 16-bit coordinates. Zero literals retain prior pixels.
  Previews composite onto mapped background, default 140ms or cutaway rate;
  cap 120 frames / 12 million pixels, without scripted layers/palette effects.
- `script.cpp`: module LUT has 16-byte records; strings resource is at +2
  in SCRIPTS.RES. `saga.cpp::loadStrings`: u16 absolute offsets with 64K wrap,
  terminated strings and optional end sentinel. Text converted from Windows-1252.
- `sndres.cpp`: RIFF WAVE speech/effects; `music.cpp`: XMIDI in GM/FM banks.
  Use host `midi_create_from_xmi` for playback/export.
- `detection_tables.h`: Spanish CD SCREAM.RES size 78,560,025;
  PATCH.RE_ is deliberately disabled for this release. Exclude demos and Mac.

Validation: `lua scripts/tests/saga.lua [game folder]` runs synthetic format
regressions and an optional full resource sweep. Exercise actual exports with
`./gradlew --offline devcli --args='load /path/to/IHNMAIMS bg_125 /tmp/bg.png'`.

### THE CITY OF LOST CHILDREN (PC)

Data: `/Users/gabriel/Desktop/ags/CITY`; open this folder or `DATAS` directly.
Implementation: `scripts/engines/city/engine.lua`; regression/full-data scan:
`lua scripts/tests/city.lua [CITY folder] [catalog|all]`.

Formats were reverse engineered from the supplied PC files; no external decoder
or ScummVM engine was used. `CITE1.DAT` has 708 resources; `CITEG.DAT` has 15.
Both start `CRSL 01 00`, a u16le count, then 28-byte directory records:
u32le stored size, unpacked size, absolute offset, 12-byte NUL-padded filename,
four flag bytes. All supplied entries have equal stored/unpacked sizes.

- CPA: `CRSL 01 01 00 01`, then 768 RGB VGA values (0..63, scaled by four).
- CRP: three headerless 640x480 screens; otherwise `CRSL 01 02 01`,
  u16le width/height, u32le payload size, then byte RLE. High-bit tag packets
  repeat the next byte `(tag & 127)+2` times; low-bit packets copy `tag+1`
  bytes. All 84 picture/font streams validate to their exact dimensions.
- ZBF: version u32le 2; width/height at offsets 16/18, decoded/encoded sizes
  at 20/24, same RLE from offset 28. All 77 decode to 640x480 depth values.
- FRM: texture atlas width u16le at 14, height u32le at 16, byte count u32le
  at 28; pixels begin at 40. Count u16le at 0; 14-byte crop records follow
  the atlas, with x/y/w/h at record offsets 6/8/10/12. All 38 atlases and
  672 crop rectangles validate, including two interface banks in CITEG.
  Crop previews retain stored colors and backgrounds; no 3D scene rendering.
- TXF/TXE/TXS/TXG/TXI: u32le text count, four-byte scene code, count+1
  u32le absolute offsets. The first locates count four-byte dialogue names;
  subsequent offsets locate blocks. Each line begins with u16 horizontal
  position and u8 style/speaker, then Windows-1252 text; 0x0C introduces another
  line header and 0 terminates the block. All 95 tables decode.
- SNW: u32le count and total PCM bytes, then count 16-byte records containing
  u32le size/absolute offset and two zero fields. All 273 clips validate.
  Rate/format confirmed in supplied CITE.EXE: file offsets 0x28680..0x28689
  set Miles sample format/flags to 0/0 (8-bit mono unsigned); 0x28691..0x2869B
  set playback rate to 0x2B11 (11025). All 265 loose WAVE speech files also
  explicitly declare PCM mono 8-bit 11025 Hz.

Matching same-stem CPA palettes are used first, then room SCENE.CPA; CIFONT
uses DEFAULTS.CPA. Missing palette associations fall back to grayscale and
allow manual override. ANI/SKL/ENV/TMM model/animation data and TSK scripts
remain bounded metadata/hex previews. MOVS/*.YOP and TRACK2.RAW likewise have
metadata only. No movie/CD music playback, script execution, 3D animation or
scene composition is claimed. Other editions/platforms are unverified.


### 3D preview formats

Grim 3DO binary/text geometry and hierarchy fields were checked against local
ScummVM `engines/grim/model.cpp`. The preview assembles the first geoset with
Z-X-Y Euler rotations and mesh-only pivots; no costume scripts are evaluated.
545 original PC 3DO entries were scanned, including empty helper objects.

City TMM files have Sony TMD ID `0x41`, relative pointers based at offset 12,
and 28-byte object descriptors. See the original Sony [File Format 4.7 manual](https://psx.arthus.net/sdk/Psy-Q/DOCS/FileFormat47.pdf).
All 44 supplied PC meshes use triangle primitive modes 0x34 (textured Gouraud),
0x35 with flag 1 (unlit), 0x24 (textured flat), or 0x30 (untextured Gouraud).
Each primitive advances by `4 + input_words * 4`; vertex references are checked
against the object vertex count. Coordinates are signed 16-bit XYZ with 8-byte
stride. CityModelPose assembles character bones using SKL's child ranges, ENV's
per-bone vertex ranges and the first ANI frame. Coordinates are Z up. Primitive
UV bytes are sampled from FRM atlases, including the texture page's V offset.


### Alone in the Dark body previews

Body layouts were checked against FITD [createBodyFromPtr](https://github.com/yaz0r/FITD/blob/master/FitdLib/hqr.cpp)
and [AnimNuage](https://github.com/yaz0r/FITD/blob/master/FitdLib/renderer.cpp).
After the flags and collision bounds, skip the length-prefixed scratch area;
vertices are signed XYZ shorts. Flag 2 introduces a bone order table and
16-byte bone records (24 bytes with flag 8). References store vertex byte
offsets divided by six. Original rotation groups affect descendants before
base-vertex attachment; optimized records rotate only their own groups.
Y-down coordinates are mapped to the viewer's Z-up convention.

Primitives include lines, variable-length polygons, points and spheres.
The viewer retains palette colors and lines, and tessellates sphere/point
markers. It does not execute LISTANIM or reproduce material-specific effects.
AITD1 uses ITD_RESS[3] as confirmed by AITD1_PALETTE_JEU. Later games take the
first CAMERA00 palette and apply the reserved first sixteen colors from FITD's
main.cpp; scene-specific recoloring is not evaluated. Palettes are cached per
folder to avoid scanning ITD_RESS for every model. PAK body output is capped at
four MB; vertex ranges, bone order, primitive references and counts are checked.
The supplied bodies total 542 entries in Alone 1's two banks, 532 in Alone 2,
and 787 in Alone 3 (three empty helper objects). Jack/TimeGate are unverified.


### Model texture and City pose follow-up

Grim 3DO decoders retain material names, UV vertices and per-face UV references.
The engine resolves named MAT resources (same LAB preferred), loads the first
stored material image and applies a filename-matched CMP (Manny defaults to suit;
otherwise a same-name CMP or item palette is preferred). CMP assignment is
scene-dependent; the viewer exposes a searchable image override and palette menu.
The orthographic rasterizer interpolates pixel-space UVs per triangle and wraps
texture coordinates; missing textures retain a solid geometry fallback.

City pose reconstruction was checked against the supplied CITE.EXE: file-offset
0x324F9 parses ANI blocks; 0x31969 assembles skeleton nodes, and 0x1F3E9 applies
row-major matrices. ANI starts with an 8-byte header and a four-byte-per-clip table.
Each clip has a 12-byte header, (frame count + 1) eight-byte root positions, then
frame count × bone count 20-byte rotation records. Matrices contain nine signed
12-bit fixed-point coefficients. SKL has a four-byte header and eight-byte nodes
(XYZ offset, child count, first child). ENV has a 12-byte header and 12-byte records
(vertex count/start, reserved, normal count/start). Parent rotation transforms
child offsets; parent × local rotation transforms each assigned vertex. The
preview omits root movement and uses frame zero of clip zero.

City selects room-prefixed SCTEX.FRM or shared CITEXFR.FRM and offers all FRM atlases
as overrides. Matching room palettes (101SCENE for shared models) are used by
default with MIETTE.CPA entries 208–255; an explicitly different palette is honored
in full. Texture mapping/material effects can depend on game scene state. Runtime
animation, texture animation and scene composition remain outside the viewer.

### BUD TUCKER IN DOUBLE TROUBLE

Source: local `../scummvm-fork/engines/tucker/` (ScummVM).
- `resource.cpp`: `loadImage` (8-bit PCX), `loadFile` / `decodeData`
  (ENC is byte minus 0x80), `loadPanObj` (50 32x24 icons), `loadSound`
  (`FX/FXn.WAV`, `MUSIC/MUSn.WAV`, `SPEECH/SAMnnnn.WAV`).
- `tucker.cpp`: `drawBackgroundSprites`, `drawSprite` (SPR frame count,
  one-based table slots, 24-bit offsets; 12-byte frame headers, dimensions
  at +0/+2 and origins at +8/+10). `copyLocBitmap` preserves PCX palettes;
  room tiles and walk masks remain separate resources in the explorer.
- `graphics.cpp`: zero followed by count skips transparent pixels; nonzero
  bytes are literal palette indices. Runs span rows.
- `resource.cpp` / `sequences.cpp`: compressed audio and intro formats are
  exposed as metadata only. Original PCM WAVs are decoded through RIFF chunks.

Verified data: `/Users/gabriel/Desktop/TUCKER` (Spanish DOS, encoded tables).
Script: `scripts/engines/tucker/engine.lua`; regression/full-data runner:
`scripts/tests/tucker.lua`. Every stored SPR frame is available, and bounded
animation batches retain stored origins at 100 ms/frame. Script timing, actor
sequences, composited rooms, movies and compressed replacement audio are not
implemented. DOS CP850 conversion preserves the Spanish text.


### JACK ORLANDO (original PC)

Primary source: supplied Spanish PC CD data at `~/Desktop/ags/orlando`.
Archive, BM/PBM, script and raw SND layouts were inspected directly. The engine
reads PAK/PA2 directories, including nested SETUP/GLOBAL archives in DATA.PAK,
and loose MOVIES resources without extracting or modifying the game files.

FLX chunk semantics were cross-checked against Konstantin Shishkov's NihAV
Game Tool 0.6.0 `src/input/decoders/avx.rs`, available from
https://nihav.org/game_tool.html . The implementation here is an independent
Lua decoder for standalone FLX, with bounded previews; AVX playback is not included.
PBM RLE and script byte transforms were derived from the supplied files.

Script: `scripts/engines/orlando/engine.lua`; tests: `scripts/tests/orlando.lua`.
PCM WAVE uses the embedded format; raw SND effects use an explicitly assumed
15360 Hz mono rate. Compressed SND speech, MUS music, DLG subtitles, fonts and
AVX movies remain metadata/hex. Original CD only; Director's Cut is unverified.

### FABLE

- Original PC CD resources inspected directly in `~/Desktop/ags/FABLE`.
- No Fable engine was present in the workspace ScummVM source. ARC1, SPR, TXT
  and CMB1 support is based on the supplied binary data and corpus validation.
- `scripts/engines/fable/engine.lua`: bounded ARC1 directories; 640x400 raw
  backgrounds and 320x200 installer art; raw/scanline RLE SPR frame banks,
  explicit frame palette patches, VGA palettes, DOS CP850 dialogue and labels,
  RIFF PCM and CMB1 PCM subresources.
- `scripts/tests/fable.lua`: malformed directory/SPR/TXT/WAVE fixtures,
  equal-size RLE regression, palette patches, optional full real-data scan.
- Movie, font, cursor, inventory and credits formats remain metadata only.
  Headerless palette blocks in CLOSEUP/MISCDAT banks retain shared palettes;
  script timing/placement and room composition are not emulated.

### AGOS: Simon the Sorcerer 1 & 2

Local source: `/Users/gabriel/Desktop/source/scummvm-fork/engines/agos/`.
Local test data: `/Users/gabriel/Desktop/ags/AGOS/SIMON/` and `SIMON2/`.
- `agos.cpp`, `res.cpp`: VGA zone ranges and GME slot layout (S1 music 329,
  S2 GM music 282, MT-32 music 435, SFX tables 415).
- `gfx.cpp::decodeColumn`: scrolling offsets are relative to each table word,
  positive runs repeat a byte, negative runs copy literal bytes.
- `debug.cpp::dumpBitmap`, `vga.cpp`, `vga_s1.cpp`, `vga_s2.cpp`: packed images,
  palette low byte, fixed-width variable operands, opcode sizes and frame delays.
- `icons.cpp::decompressIcon`: S1 24x24 icons, S2 dual-layer 20x20 icons.
- `sound.cpp::BaseSound`, `subroutine.cpp`: LE clip offsets and embedded SFX banks.
- `midiparser_gmf.cpp`: GMF header, DOS tempo mapping, operandless pitch bends.
- `EncodedAudioDecoder.kt`: bounded PCM VOC/WAV and bundled JLayer MP3 decoding.
  `GmfToMidiConverter.kt`: GMF to standard MIDI; XMIDI uses the existing converter.
- Run `SIMON1_TEST_PATH=... SIMON2_TEST_PATH=... ./gradlew test --tests '*Agos*'
  --tests '*SimonAudio*'` for real-data coverage and synthetic regressions.


### ANOTHER WORLD / OUT OF THIS WORLD (original DOS)

Data: `~/Desktop/ags/AW`. Script: `scripts/engines/anotherworld/engine.lua`.
Reference: local `../scummvm-fork/engines/awe/`; upstream interpreter reference:
[rawgl](https://github.com/cyxx/rawgl).

- `resource.cpp::MemEntry::load`: status/type, ignored 32-bit runtime pointer,
  rank/bank bytes, BE offset/packed/unpacked sizes; 20 bytes/record, FF sentinel.
  `MEMLIST_PARTS` associates palette, bytecode and two shape segments per part.
- `unpack.cpp`: backward ByteKiller; trailer words = bit accumulator, checksum,
  output size. LSB extraction, MSB-first multi-bit values, sentinel refill;
  checksum XOR includes every consumed source word. Validate sizes and refs.
- `video.cpp::decode_amiga` / `copyBitmapPtr`: DOS uses 4 sequential planes,
  8000 bytes each, 320x200 pixels, plane zero is the low bit.
- `readPaletteAmiga` / `readPaletteEGA`: 32 palettes of 16 BE words in each
  1024-byte half. VGA is 12-bit RGB; EGA takes the word's high nibble.
- `script.cpp::executeTask`, `static_res.cpp::OPCODE_TABLE`: static reachable
  disassembly for normal and compact drawing opcodes, branching/calls/tasks.
  Extract shape roots only from valid decoded instructions; no offset guessing.
- Per-image palette inference retains instruction addresses and constructs control
  flow across branches, calls/returns and installed task entries. Incoming palette
  definitions stop at another assignment; backward lookup finds palettes selected
  after drawing but before a display update. Proximity-weighted votes across all
  uses select a representative VGA palette per image. Black fade candidates are
  excluded using that image's color indices; ties are stable. Missing visible
  context uses a palette from the loading part, while verified logo mappings remain
  explicit. This is conservative static inference: call sites can merge and task
  scheduling/branch conditions are not simulated. Manual palette overrides remain.
- `video.cpp::drawShape`, `fillPolygon`, `drawShapeParts`: native-scale polygon
  vertices and composite child coordinates, word-addressed references and
  optional child colors. Explorer uses an independent scanline rasterizer;
  full VM page effects, built-in head masks and animation are outside scope.
- `sound.cpp`, `script.cpp::getSoundFreq`, `static_res.cpp::PERIOD_TABLE`:
  8-byte header, signed 8-bit PCM, initial and loop lengths are BE words.
  Script pitches are integer 7159092 / (period * 2). Otherwise label the 9943 Hz
  preview assumption. Loop portions play once. `sfx_player.cpp` supplies the
  module delay/order metadata; music rendering is not implemented.

Validated 146 indexed records: 103 sound records (six empty; 97 nonempty),
12 bitmaps, 9 palette banks, 9 bytecode banks, 9 part-shape banks, 1 common
shape bank and 3 music modules. The tree has 5,042 polygon previews, 12 bitmaps,
576 palettes, 313 pitched samples, 9 disassemblies and 146 metadata views:
6,098 leaves. Native Lua full sweep and malformed-input regressions live in
`scripts/tests/anotherworld.lua`; `AnotherWorldIntegrationTest.kt` exercises
real LuaJ decoding and image output when ANOTHER_WORLD_TEST_PATH is set.
Only the supplied DOS release was verified; no alternate-edition claims.


## Star Trek: 25th Anniversary / Judgment Rites (`startrek`)

Reference: local ScummVM `engines/startrek/{resource,lzss,bitmap,actors,graphics,sound}.cpp`.
The new Lua decoder independently implements the directory/run format, LZSS,
indexed images, palette scaling, masks and resolvable animation previews.
`resource.cpp` establishes LE24 direct offsets and indirect RUN strides;
`lzss.cpp` establishes the zeroed 4096-byte history and distance/length tokens.
`bitmap.cpp` establishes origins/dimensions; `actors.cpp` identifies 22-byte
ANM records and virtual/XOR actor frames; `graphics.cpp` establishes VGA scaling
and PRI nibble order. Real-data inspection establishes Rites BGD embedded palettes,
all nine archive triplets, Latin-1 Spanish text and UNCOMP VOC resources.
Music MT/GM files contain multiple nested XMIDI EVNT chunks; each gets a separate
resource to avoid dropping all but the first tune. No changes to host APIs.

Verified editions: `~/Desktop/ags/TREK/{STARTREK,RITES}` (Spanish DOS).
Unsupported formats retain metadata/hex. STARS.SHP is a table; S5ROOM3.BMP in
this 25th Anniversary copy points into incompatible data and fails decompression.

Validation: native Lua loaded all 44,631 catalog leaves (14,784 Anniversary;
29,847 Rites). Anniversary exposes 5,826 image/mask views, 1,269 animation
previews, 91 music sequences and three palettes. Rites exposes 11,029 image/mask
views, 2,739 animation previews, 1,134 music sequences, 123 palettes and 197 VOCs.
One Anniversary source entry is damaged (its image and metadata return a clear
diagnostic); no Rites decode failures. Five LuaJ tests pass, including 1,758
real previews, every music/palette/audio leaf, MIDI parsing, and manual palette
overrides. Both bridge PNG exports were visually inspected.


### TAKE-TWO DOS (Bureau 13 / Hell: A Cyberpunk Thriller)

Implemented in `scripts/engines/take2/engine.lua`. Primary references are the
local original DOS resources in `~/Desktop/ags/TAKE2/B13` and `HELL`, plus
Bureau 13 `B13.DAT` x86 image loader/decompressor (file offsets 0x25200 and
0x252D2). No ScummVM engine implements these games.

The decompressor confirms low-first delta nibbles, repeat/absolute escapes,
optional VGA palettes, post-palette index remapping and raw suffix pixels.
GL/PL/SL nested directory records and Bureau indexed CP850 dialogue were
validated directly against all member boundaries. Hell uses standard PCX and
Autodesk FLC; the existing sulfato decoder provided the starting point, with
LC support and validated recovery of short COPY chunk lengths. Some Hell FLC
headers have stale depth values. Read only indexed library members; do not
interpret DISK1.HEL installation data as a resource library. Scene scripts and
unrecognized binary assets remain metadata/hex entries.

Tests: `scripts/tests/take2.lua`, `Take2DecoderTest.kt`. Local fixtures verify
all still images and text boundaries; LuaJ integration exercises images,
custom palettes, animations, audio and MIDI through the real host APIs.


## Little Big Adventure 1 & 2 (`twine`)

Local format reference: ScummVM `engines/twine/resources/{hqr,resources}.cpp`,
`parser/{sprite,blocklibrary,text}.cpp`, `scene/grid.cpp`, and `audio/sound.cpp`.
HQR compression, palette assignments, brick/sprite RLE, LBA1 grids and speech
header repair were checked against those sources. LBA2's grouped polygon records
and bone indices differ from the local ScummVM body parser's assumptions.

Primary implementation references for LBA2 models, textures and grids:
- [LBA Lab remake body2 parser](https://github.com/LBALab/lba2remake/blob/master/src/resources/parsers/body2.ts)
- [Skeleton hierarchy](https://github.com/LBALab/lba2remake/blob/master/src/model/anim/Skeleton.ts)
- [Model geometry and UV groups](https://github.com/LBALab/lba2remake/blob/master/src/model/geometries.ts)
- [Outdoor object faces](https://github.com/LBALab/lba2remake/blob/master/src/game/scenery/island/objects.ts)
- [Island atlas](https://github.com/LBALab/lba2remake/blob/master/src/game/scenery/island/TextureAtlas.ts)
- [Resource mappings](https://github.com/LBALab/lba2remake/blob/master/www/resources/lba2.json)
- [LBA file-format community: LBA2 grid](https://lbafileinfo.kaziq.net/index.php/LBA2:Grid)
- [LBA2 background archive layout](https://lbafileinfo.kaziq.net/index.php/LBA2:LBA_bkg.hqr)

Implementation: `scripts/engines/twine/engine.lua`, `Lba2ModelDecoder.kt`,
`ImaWaveDecoder.kt`. These are independent parsers using the documented layouts.
Test data: supplied `~/Desktop/ags/LBA/LBA1` and `LBA2`. No proprietary data is
included. Animation playback, FLA/SMK video, LBA1 model previews and assembly of
outdoor island terrain remain outside the implemented previews.

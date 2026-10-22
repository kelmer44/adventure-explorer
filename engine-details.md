# Engine details

[Back to the README](README.md#supported-engines)

Click **Open Folder** in Adventure Explorer and select the folder described for your
engine below. The app detects the engine automatically; you do not need to select an
engine ID. Keep the game's data files and directory layout together. Opening a parent
folder only works where the entry explicitly says so.

The entries cover every implemented engine. Opening instructions follow the current Lua detection rules; release
coverage and known limitations are described where available. See also
[3D model previews](#3d-model-previews) for shared viewer controls.

| Engine / games | Engine ID |
|---|---|
| [3 Skulls of the Toltecs](#toltecs) | `toltecs` |
| [Alfred Pelrock](#pelrock) | `pelrock` |
| [Alone in the Dark series](#aitd) | `aitd` |
| [Amazon: Guardians of Eden](#amazon) | `amazon` |
| [Another World / Out of This World](#anotherworld) | `anotherworld` |
| [Beneath a Steel Sky](#sky) | `sky` |
| [Broken Sword II: The Smoking Mirror](#sword2) | `sword2` |
| [Broken Sword: Shadow of the Templars](#sword1) | `sword1` |
| [Bud Tucker in Double Trouble](#tucker) | `tucker` |
| [Bureau 13 / Hell: A Cyberpunk Thriller](#take2) | `take2` |
| [Capstone / Manley: Fievel, The Beverly Hillbillies and L.A. Law](#capstone) | `capstone` |
| [Cobra Mission](#cobramission) | `cobramission` |
| [Cruise for a Corpse](#cruise) | `cruise` |
| [Curse of Enchantia](#curseofenchantia) | `curseofenchantia` |
| [Dark Seed](#darkseed) | `darkseed` |
| [Dark Seed 2](#darkseed2) | `darkseed2` |
| [Discworld 1 & 2](#tinsel) | `tinsel` |
| [Discworld Noir](#noir) | `noir` |
| [Drascula: The Vampire Strikes Back](#drascula) | `drascula` |
| [DreamWeb](#dreamweb) | `dreamweb` |
| [El Sulfato Atomico](#sulfato) | `sulfato` |
| [El Tesoro de la Isla Alcachofa](#tesoro) | `tesoro` |
| [Fable](#fable) | `fable` |
| [Flight of the Amazon Queen](#queen) | `queen` |
| [Future Wars / Operation Stealth](#cine) | `cine` |
| [GOB / Coktel Vision](#gob) | `gob` |
| [Grim Fandango](#grim) | `grim` |
| [Harvester](#harvester) | `harvester` |
| [Hollywood Monsters](#hollywoodmonsters) | `hollywoodmonsters` |
| [I Have No Mouth, and I Must Scream](#saga) | `saga` |
| [Igor: Objective Uikokahonia](#igor) | `igor` |
| [Interspective games](#interspective) | `interspective` |
| [Jack Orlando](#orlando) | `orlando` |
| [Leather Goddesses of Phobos 2](#lgop2) | `lgop2` |
| [Les Manley 2: Lost in L.A.](#les2) | `les2` |
| [Little Big Adventure 1 & 2](#twine) | `twine` |
| [Lure of the Temptress](#lure) | `lure` |
| [MicroProse MADS games](#mads) | `mads` |
| [Noctropolis](#noctropolis) | `noctropolis` |
| [Pink Panther: Passport to Peril / Hokus Pokus Pink](#pink) | `pink` |
| [Prisoner of Ice](#ice) | `ice` |
| [Ripley's Believe It or Not!: The Riddle of Master Lu](#riddle) | `riddle` |
| [Runaway: A Road Adventure](#runaway) | `runaway` |
| [Sanitarium](#asylum) | `asylum` |
| [SCUMM V2](#scummv2) | `scummv2` |
| [SCUMM V3–V8](#scumm) | `scumm` |
| [Shadow of the Comet](#comet) | `comet` |
| [Sierra SCI](#sci) | `sci` |
| [Simon the Sorcerer 1 & 2](#agos) | `agos` |
| [Star Trek: 25th Anniversary / Judgment Rites](#startrek) | `startrek` |
| [The City of Lost Children](#city) | `city` |
| [The Last Express](#lastexpress) | `lastexpress` |
| [The Legend of Kyrandia](#kyra1) | `kyra1` |
| [The Legend of Kyrandia: Hand of Fate](#kyra2) | `kyra2` |
| [The Lost Files of Sherlock Holmes: Serrated Scalpel / Rose Tattoo](#sherlock) | `sherlock` |
| [The Neverhood](#neverhood) | `neverhood` |
| [Toonstruck](#toonstruck) | `toonstruck` |
| [Touché: Adventures of the Fifth Musketeer](#touche) | `touche` |
| [Trick or Treat](#tot) | `tot` |
| [TsAGE: Ringworld / Blue Force](#tsage) | `tsage` |
| [Una Aventura de Cine](#alcachofa) | `alcachofa` |
| [Universe](#universe) | `universe` |
| [Visionaire](#visionaire) | `visionaire` |
| [Wayne's World / The Dark Half (Genus GXL)](#gxl) | `gxl` |

<a id="toltecs"></a>

## 3 Skulls of the Toltecs

**Engine ID:** `toltecs`

3 Skulls of the Toltecs opens `3SKULLS`, a language `.PDI` directory, or an installed
directory containing `WESTERN`. The tested Spanish CD has 56 backgrounds, 533 sprite
banks (16-color, 256-color and shadow masks), 92 interface images, 11 animation banks,
90 palette fragments, 3,868 unsigned 22,050 Hz PCM speech/effect clips and 18 XMIDI/MIDI
music resources.

Backgrounds and animations use their embedded palettes. Sprite palettes are selected by
game scripts: previews use grayscale until a palette fragment is chosen manually.

Animation previews retain delta frames and holds, in batches of at most 100 frames /
eight million pixels, with uniform 100 ms timing.

Raw audio ranges are enabled only for the verified Spanish CD layout; other releases
retain unclassified resources as metadata and hex previews.

Scripts, fonts, cursor masks, movie playback and scene compositing are not interpreted.
Resource names are numeric archive indices.

<a id="pelrock"></a>

## Alfred Pelrock

**Engine ID:** `pelrock`

Open the game folder containing both `ALFRED.1` and `JUEGO.EXE`, with the other game
data files alongside them.

<a id="aitd"></a>

## Alone in the Dark series

**Engine ID:** `aitd`

Open the game data folder containing `CAMERA00.PAK` and a game marker such as
`LISTBOD2.PAK`, `PERE.PAK`, `MER.PAK`, `AN1.PAK` or `PURSUIT.PAK`. Keep the other PAK
files alongside them.

It also lists the sound samples in `LISTSAMP.PAK` (VOC) and the text in the language
PAK (`ENGLISH`, `FRANCAIS`, `DEUTSCH`, `ESPAGNOL`, `ITALIANO` or `USA`): entry 0 is the
numbered string table (`@<number>:<text>`), the other entries are the books and
documents read in the game. `LISTMUS.PAK` music is AdLib driver data and is not decoded.

<a id="amazon"></a>

## Amazon: Guardians of Eden

**Engine ID:** `amazon`

Amazon: Guardians of Eden opens the tested `AMAZON` directory, detected by `AMAZON.EXE`,
`S00.AP` and `C00.AP`. AP archives and DBE compression are read directly.

The tested Spanish floppy release exposes 41 tiled backgrounds, 40 full-screen pictures,
122 sprite banks, 11 loose images, 104 video sequences, 151 STEVE sound clips and 64
MIDI tracks. Wide backgrounds retain their full dimensions, including the 2560-pixel
panorama.

Image palettes are embedded; sprite/video palettes are suggested when their archive
contains a single picture palette, with manual override and grayscale fallback.

Video previews show all stored delta packets (including trailing packets), with a blank
initial canvas unless a background packet is supplied, at uniform 100 ms timing.
Previews are batched to at most 100 frames / eight million pixels.

Scripted animation timing, scene compositing, MIDI driver patches and script execution
are not interpreted; remaining data has hex/ASCII previews. Tested with the Spanish
floppy data; CD speech and alternate release layouts are unverified.

<a id="anotherworld"></a>

## Another World / Out of This World

**Engine ID:** `anotherworld`

Another World opens the original DOS `MEMLIST.BIN` + `BANK01`...`BANK0D` folder
directly. It exposes all 12 planar bitmaps, 5,042 script-referenced polygon artwork
previews across nine parts, 576 VGA/EGA palettes, and 97 nonempty signed PCM samples
(313 pitch previews). All 146 resource records have decompressed metadata/hex views; the
nine scripts also have static disassembly. ByteKiller streams are checksum checked.

Polygon previews retain composite child positions at native scale, with a standalone
scanline rasterizer and black backdrop. They do not reproduce the game's scene
composition, page-copy effects, built-in head masks, VM animation, zoom or timing. Each
image now gets a default inferred from palette commands along script control flow,
including palettes selected between drawing and display. Reused shapes get a
representative palette from their uses; missing usable contexts retain a visible
part-palette fallback. Logos keep their verified fade endpoints, and every palette can
still be selected manually. Preview descriptions identify inferred defaults, fallbacks
and manual overrides.

Samples use script-referenced pitches when available, otherwise a labeled 9943 Hz
preview rate; loop segments play once. The three music modules have metadata/hex
previews only. Text/fonts embedded in the executable, other platforms, demos and
anniversary editions are unsupported.

<a id="sky"></a>

## Beneath a Steel Sky

**Engine ID:** `sky`

Open the game data folder containing both `SKY.DSK` and `SKY.DNR`. The engine reads the
archive and index directly from that folder.

Besides backgrounds, sprites and palettes, the archive exposes:

- **Sound effects** from each section's sound driver file (unsigned 8-bit PCM at the
  rates stored in the driver).
- **Music** from the General MIDI/MT-32 sequencer files, converted to multi-track MIDI
  with MT-32 instruments mapped to General MIDI. Songs that loop in the game play once.
- **Text** for every language in the archive, one entry per text section with each
  message's number. The game's own charset is converted to Unicode.
- **Fonts**: the main, control-panel and link fonts.

Text is Huffman-coded with tables that differ between releases, and one release can mix
them: the English v0.0331 floppy used for testing stores English, German, French and
Italian with the v0.0348 table, Swedish and Portuguese with v0.0365 and Spanish with
v0.0368. Each
language therefore uses whichever of ScummVM's nine tables decodes the most common words
of that language. In that copy, Spanish `ú` still decodes as `8` in two words. CD speech
is not decoded (the tested copy is the floppy release).

<a id="sword2"></a>

## Broken Sword II: The Smoking Mirror

**Engine ID:** `sword2`

Open the data folder containing `GENERAL.CLU` and the other CLU files. If those files
are in a subfolder of the installation, select that subfolder directly.

- **Text:** every text file in `TEXT.CLU`. Each line shows its official text number,
  which is also the id of its clip in the speech cluster.
- **Speech and music:** `speech1.cl3`/`speech2.cl3` and `music1.cl3`/`music2.cl3`, the
  MP3 clusters made by ScummVM's compression tool, grouped by CD in blocks of 100 clips.
  The original `.CLU` audio and the Vorbis/FLAC `.clv`/`.clf` variants are not decoded.

<a id="sword1"></a>

## Broken Sword: Shadow of the Templars

**Engine ID:** `sword1`

Open the game folder containing `CLUSTERS/SWORDRES.RIF`, or open the `CLUSTERS` data
folder directly. Keep `SWORDRES.RIF` with the cluster files, including `PARIS1.CLU` or
`GENERAL.CLU`. Open the game folder itself (not `CLUSTERS`) to also see speech and music.

- **Text:** every language group in `TEXT.CLU`, one entry per section, with the text ids
  the scripts use (section × 65536 + line).
- **Speech:** `SPEECH/SPEECH1.CL3` and `SPEECH2.CL3`, grouped by CD and room. These are
  the MP3 speech clusters made by ScummVM's compression tool; the original uncompressed
  `.CLU` speech and the Vorbis/FLAC `.CLV`/`.CLF` variants are not decoded.
- **Music:** the `MP3` and `WAV` tracks in `MUSIC/`.

<a id="tucker"></a>

## Bud Tucker in Double Trouble

**Engine ID:** `tucker`

Bud Tucker opens the DOS game folder containing `CTABLE01.ENC` (or `CTABLE01.C`),
`BUD_1.PCX` and `PANEL1.PCX`, with `SPRITES`, `FX`, `MUSIC`, `SPEECH`, `AUDIO` and
`GRAPHICS` alongside them.

PCX images retain their embedded palettes; walk masks use grayscale. SPR frames use a
matching room palette where available, with manual palette selection and grayscale
fallback. Inventory icons are cropped from `PANOBJS` sheets.

Animation previews preserve stored frame origins and split long banks into batches of at
most 60 frames / four million pixels, using a uniform 100 ms delay. Backgrounds are
individual stored tiles; scene composition, game animation sequences and palette effects
are not reconstructed.

Encoded tables subtract 0x80 per byte and display as DOS CP850, including Spanish
dialogue. PCM WAV speech, effects, music and intro audio play/export; two mislabeled
non-WAVE clips, intro movies, raw data and ScummVM compressed audio replacements have
metadata previews.

The tested copy exposes 23,245 resources, including 17,031 stored sprite frames, 756
animation batches and 4,594 WAV clips.

Other editions and demos are unverified.

Validate with `lua scripts/tests/tucker.lua`, or append the game folder and `all` to
decode every resource (`catalog` lists counts only).

<a id="take2"></a>

## Bureau 13 / Hell: A Cyberpunk Thriller

**Engine ID:** `take2`

Open the original DOS game folder directly (`TAKE2/B13` or `TAKE2/HELL`). Bureau 13 is
detected by `DATA.GL`, `TEXT.GL` and `B13.DAT`/`B13.COM`; Hell by `BACKGRND.PL`,
`ARTWORK.PL` and `SOUND.SL`. Nested GL/PL/SL libraries are read in place.

Bureau 13 exposes 3,871 images, 301 palettes, 3,875 dialogue/text records (Spanish in
the tested copy), 63 WAV effects and ten MIDI tracks. Hell exposes 740 still images, 417
palettes, 447 FLI/FLC previews and 3,054 WAV/VOC speech/effect clips, plus binary
metadata. Animation previews show at most 60 frames and eight million pixels per clip.
Embedded palettes and preceding palette entries within each library supply image
defaults; Bureau 13 also has a common palette. Unassigned Hell sprites use grayscale;
select a scene palette to inspect them in context. Palette overrides work for still
images.

Scripts, fonts, translation tables and other unrecognized data retain metadata/hex
previews. Runtime scene composition, scripted sprite sequences and installation archives
(`DISK1.HEL`) are not decoded. Open the supplied Hell media folder without installation;
resources absent from that copy cannot be listed.

<a id="capstone"></a>

## Capstone / Manley: Fievel, The Beverly Hillbillies and L.A. Law

**Engine ID:** `capstone`

Open the individual game folder: `AMTAIL.EXE` with `MANLEY.PIC` for Fievel Goes West /
An American Tail; `HB.EXE` with `SCENES.RES` for The Beverly Hillbillies; or `LALAW.EXE`
with `DISK1.RES` for L.A. Law. Keep the remaining resource files alongside them.

Capstone / Manley support covers the tested AMTAIL, BHB and LALAW releases. Fievel actor
previews play stored frames in order at 100 ms; choose a scene palette for the intended
colours. Scene/animation bytecode and BHB sound effects are decoded data previews; LA
Law ABT speech is metadata only. Driver-encoded audio playback and scripted animation
timing/compositing are not implemented.

<a id="cobramission"></a>

## Cobra Mission

**Engine ID:** `cobramission`

Open the game folder containing the graphics VOL archives. Detection requires at least
three of `PIC1.VOL`, `PIC2.VOL`, `PIC3.VOL`, `PICA.VOL`, `CUT1.VOL`, `CUT2.VOL`,
`CUT3.VOL`, `CUTA.VOL`, `OPENING.VOL`, `MAP.VOL`, `ENM.VOL` and `ENMA.VOL`. Keep
`CODE.VOL`, `ICP.VOL` and the PCM volumes there for text and sound.

Cobra Mission adds **Texts** with seven decoded `CODE.VOL` authoring scripts and 856
individual scene entries in the tested Spanish copy. Scripts preserve speaker tags,
variables, author comments and original custom-font placeholders (such as `{`, `~`, `r`
and `w`); DOS accented bytes are converted to Unicode.

`ICP.VOL` also exposes 98 plain-text constants (names, messages and credits) across
eight entries.

**Sounds** contains all 155 Creative VOC clips from `PCM1.VOL` through `PCM6.VOL`,
including silence and multiple audio blocks; loop bodies play once for preview/export.

Existing 286 GC images remain available. Compiled IC bytecode, raw tile/sprite banks,
map layouts and OPL music are not decoded. Counts may vary by edition.

<a id="cruise"></a>

## Cruise for a Corpse

**Engine ID:** `cruise`

Open the game data folder containing `D1` and `VOL.CNF`, with the remaining volumes
alongside them. See [Future Wars / Operation Stealth](#cine) for the shared bitmap,
palette and Cruise polygon-preview details.

<a id="curseofenchantia"></a>

## Curse of Enchantia

**Engine ID:** `curseofenchantia`

Open the parent game folder containing `CURSE.EXE` and the `DATA` subfolder. Releases
without that executable need `CURSE.CFG` and `DATA/CORE.PAL`. Select the parent folder
so the engine can find the files under `DATA`.

The tested DOS release exposes 56 room backgrounds, 19 standalone screens,
2,058 sprite/UI/font frames in 57 `.SPR` banks, and 637 character frames in 29
`.BRD` banks. Sprites export with index 0 transparent. Room sprites use their
matching room palette with the shared upper 64 colours from `SPRITES.PAL`;
unmatched sprite and character banks use `SPRITES.PAL`. Select any of the six
standalone or 56 room palettes manually when a bank needs another context.

Also available: 109 PCM effects from 19 `.SFX` banks, and three full-screen
animation previews (BALCONY, BASEBAL and CAULDRN). Effects preview/export as
unsigned 8-bit mono at the driver's initial 8,000 Hz rate; banks contain no rate
field. Screen sequences use a fixed 100 ms preview delay. Character banks expose
individual frames; gameplay animation scripts and `.RS1`-`.RS5` music are not decoded.

<a id="darkseed"></a>

## Dark Seed

**Engine ID:** `darkseed`

Open the game folder containing `TOS.EXE`, `DS.BAT` or `START.EXE`. Keep the `PICTURE`
subfolder for the CD version, or the `ROOM0.ROM` / numbered `ROOM*.PIC` resources in the
root for floppy releases.

It also lists the game text from `TOSTEXT.BIN` (numbered entries), the CD speech clips in
`SPEECH/` (each named after the text entry it speaks), the `SOUND/*.SFX` effects and the
`SOUND/*.MID` music. `INVIS1.MID` and `INVIS2.MID` use another sequencer format and are
not listed.

<a id="darkseed2"></a>

## Dark Seed 2

**Engine ID:** `darkseed2`

Open the game folder containing `GFILE.HDR` and `DARK0001.EXE`, with the companion game
archives and `FIX.PAL` alongside them.

Dark Seed 2 exposes 83 room backgrounds, 3,660 sprite/UI images grouped by archive, 83
room thumbnails and 84 palettes in the tested release. Cropped scanline sprites use
their room background's palette; shared walking/action sprites use `FIX.PAL`. Images
with embedded palettes retain them, including the 4-bit inventory icon. Palettes can
also be selected manually.

Frames are shown individually; cropped areas use palette index 0 and animation playback
is not yet available.

<a id="tinsel"></a>

## Discworld 1 & 2

**Engine ID:** `tinsel`

Open the data folder containing `INDEX` and `DW.SCN` for Discworld 1, or `INDEX` and
`DW2.SCN` for Discworld 2. Keep the other SCN files in the same folder.

Open **Sprites → file name → Animation** to play or step through a stored animation
reel. Sequences follow the game's frame order, timing, flips and offsets, including
multipart sprites and transparent frames. Individual sprite images remain in the same
file groups. Reels are previewed independently; full scene composition and sound scripts
are not replayed.

<a id="noir"></a>

## Discworld Noir

**Engine ID:** `noir`

Open a mounted `DWN_ENG_1`, `DWN_ENG_2`, or `DWN_ENG_3` CD root or its `cd1`/`cd2`/`cd3`
folder. The browser finds the other mounted English CDs automatically. A copied
installation with `index` and `dw3.scn` also works, as does a folder containing `cd1`,
`cd2`, and `cd3` subfolders. CD 1 or 2 is needed for detection; CD 3 supplies
`english.idx`/`english.smp` for shared speech and sound. Missing scene files are listed
under **Scene and File Data → Disc set and format information**.

The original English 3CD set exposes 12,041 raw/word-RLE RGB565 images, with magenta
transparency, 76 music segments, 15,019 speech/sound subsamples, 1,092 language string
pages, and scene chunk metadata/hex. Large images include background layers and
overlays, rather than fully composed game scenes.

Color effects are previewed unblended. BMV movies, 3D actor models, and scripted
animation playback are not decoded; those files have metadata/hex entries. No disc
copying or installation step is required.

<a id="drascula"></a>

## Drascula: The Vampire Strikes Back

**Engine ID:** `drascula`

Open the unpacked game data folder containing numbered `.ALD` room descriptions and
`.ALG` pictures, including `14.ALD`. The detector checks several room files and a valid
picture; packed distribution archives must be unpacked first.

<a id="dreamweb"></a>

## DreamWeb

**Engine ID:** `dreamweb`

Open the installed game directory containing `DREAMWEB.R00` and `DREAMWEB.PAL`,
with the other `DREAMWEB.*` files alongside them. Spanish `DREAMWSP.*` and French
`DREAMWFR.*` names are recognized too. Keep CD speech in `SPEECH/`, `SPANISH/` or
`FRENCH/`. The verified full English UK freeware CD is installed at
`/Users/gabriel/Desktop/ags/Dreamweb`.

The full UK CD exposes **11,777 resources**: 140 tiled background screens, 34 tile
atlases, 6,484 sprite/UI/font/reel frames, seven original 640x480 PCX title screens,
12 constant-object animation previews, eight palettes, 120 sound/music samples,
469 speech clips, 4,469 text entries and 34 room-structure reports. Every resource
was decoded through the app's LuaJ host; representative PNG, WAV, animation, text
and palette exports were verified. Text uses DOS850. Sprites retain transparent
index zero; animations retain frame offsets, repeated frames and nominal game timing.

Backgrounds reconstruct the 11x10 tile viewport at 176x160. Objects, actors and
runtime shadows remain separate. Frames from all three reel banks are available,
but scripted cutscenes, doors, lifts, random-object behavior and actor walking are
not played as animations. The game VGA palette is used for graphics; PCX screens
use their own palettes, and manual palette selection is supported.

The full UK CD is verified. Other installed floppy/CD languages use the same
parsers but have not been validated; Russian/Czech text encodings are not handled.
Packed multi-disk `DREAMW_*.RNC` installers, original DOS executable playback,
legacy `P01/P02/WAV` aggregate data and PDF manuals are not extracted.

<a id="sulfato"></a>

## El Sulfato Atomico

**Engine ID:** `sulfato`

El Sulfato Atomico opens the unpacked `SULFATO` directory (detected by `SULFATO.EXE`,
`1.ALG` and `1.ALD`). The tested Spanish release contains 111 NMP/PCX ALG images plus
one SVS save thumbnail, their embedded palettes, 53 FLC animation banks in VHS files,
735 PCM WAV clips, and 43 text/data files.

Wide pictures retain their full dimensions. Large animation banks are split into batches
of at most 200 frames and eight million pixels, with all declared frames accessible; the
extra FLC loop-closing frame is omitted. Previews use uniform file timing.

Sprite sheets are shown whole; object extraction, script interpretation, character
movement and scene compositing are not implemented. The misnamed `sk494.wav` developer
message is shown as text.

<a id="tesoro"></a>

## El Tesoro de la Isla Alcachofa

**Engine ID:** `tesoro`

Open the game folder containing both `TESORO.TRE` and `TESORO.DAT`; the engine reads
them directly.

El Tesoro de la Isla Alcachofa reads `TESORO.TRE` / `TESORO.DAT` directly: 2,012 images
from the level, player and font banks, 112 image sequence previews, 2,346 PCM WAV clips,
plus scripts and readable object metadata. Shadow masks display as grayscale. Previews
use stored image order at 100 ms; game script timing, movement and scene compositing are
not interpreted.

<a id="fable"></a>

## Fable

**Engine ID:** `fable`

Fable opens the original PC CD folder directly, detected by `DECORS.DAT` containing
`101DECOR.RAW` and `101DECOR.PAL`. The tested edition exposes 83 room backgrounds, six
title/installer screens, 11,474 sprite frames in 473 banks, 85 palettes, 561 text
resources and 2,932 audio clips (including 2,739 speech WAVs and 191 bundled PCM
sounds).

English, French, German, Spanish and Italian dialogue/object labels decode as DOS CP850.
Raw and scanline RLE sprites use the corresponding room palette, or room 101 for shared
actors/UI; title and installer art use their own palettes. Verified per-frame palette
patches are applied by default. A manual palette selection overrides them. Twelve
headerless palette blocks in `CLOSEUP.SPR` and `MISCDAT*.SPR` remain unverified; those
banks retain the shared palette.

Frame bank previews show up to 60 stored frames / four million pixels at 100 ms per
frame. Game animation scripts, placement and scene composition are not reconstructed.

Fonts, cursors, inventory sheets, credits ANM and IMX movies have metadata/hex previews
only. Movie playback is unavailable.

Validate with `lua scripts/tests/fable.lua /path/to/FABLE all`.

<a id="queen"></a>

## Flight of the Amazon Queen

**Engine ID:** `queen`

Open the game data folder containing `QUEEN.1` or `QUEEN.1C`. Select the folder itself;
the engine reads the data archive in place.

<a id="cine"></a>

## Future Wars / Operation Stealth

**Engine ID:** `cine`

Open the game data folder containing `PART01` for Future Wars, or `PROCS00`, `PROCS1` or
`PROCS0` for Operation Stealth. Keep the other game volumes in the same folder.

Future Wars / Operation Stealth expose ANI/ANM frames and SET bitmaps; Cruise exposes
SET/SEC bitmap frames (1/4/5/8-bit encodings). Each volume has separate Backgrounds,
Sprites and Palettes groups. Sprite colours default to a matching scene-name background,
or an archive background fallback; choose another palette for actors reused across
scenes. Previews preserve all palette indices on an opaque canvas.

Cruise also exposes **Polygon Actors and Vector Art** with 2,812 stored poses, including
mirrored references, through the model viewer. These are flat vector shapes, shown
front-on with zoom, wireframe, palette selection and PNG export; authored colours,
concave boundaries and drawing order are preserved.

Script-driven palette changes and animation timing are not replayed. Validated with
1,989 Future Wars and 2,345 Cruise bitmap frames, plus every Cruise polygon pose;
Operation Stealth formats have synthetic tests.

<a id="gob"></a>

## GOB / Coktel Vision

**Engine ID:** `gob`

Open the individual game data folder containing its `.STK` or `.ITK` archives, such as
`DISK0.STK` for Fascination or `WOODRUFF.ITK` for Woodruff. Detection reads the archives
for `.TOT` script members. Keep all accompanying game archives and audio/video files in
place. This also applies to Gobliiins, Gobliins 2 and Goblins Quest 3.

Fascination and Woodruff now expose TOT and EXT sprites and selectable scene palettes.
Fascination includes `DISK0.STK`, MDY/TBR music, and the early
TIRA/TIRB movie format. Woodruff composes room strips at their script positions and
reads animation, speech and music members directly from `WOODRUFF.ITK`. Video
soundtracks are separate sound resources; long movies are split into consecutive clips
to bound preview memory. These are static asset previews; dynamic game scripts are not
executed. Other Coktel releases and external-codec VMDs are unverified.

AdLib music (Gobliiins `.ADL`, Fascination `.MDY` with its `.TBR` instruments) is
rendered through an emulated OPL2 chip (a port of the Nuked OPL3 emulator) driven the
way ScummVM's Gob AdLib driver drives it, so instruments, percussion and pitch bends
sound like the original hardware. Output is 44.1 kHz mono.

Restart with `./gradlew run` to load the native video/audio decoder changes.

Validate with `FASCINATION_TEST_PATH=/path/to/FASCI WOODRUFF_TEST_PATH=/path/to/Woodruff
GOB_SERIES_TEST_ROOT=/path/to/GOB GOB_SCAN_ALL=1 ./gradlew test --tests '*Gob*Test'
--tests '*CoktelVideoDecoderTest'`.

<a id="grim"></a>

## Grim Fandango

**Engine ID:** `grim`

Grim Fandango supports the original PC LAB archives. Open an installed folder containing
`DATA000.LAB` (or another `DATA00x.LAB`), or either CD root containing `GRIMDATA`. No
installation is required. To browse all four years together, copy the LAB files from
both discs into one folder, including `GRIM.TAB` for dialogue. Each disc can also be
browsed independently.

The tested discs expose 5,191 stored bitmap/depth/texture images and 125 CMP palettes in
total. BM codecs 0 and 3 are decoded as RGB565; ZBM depth images are shown in grayscale.
Every stored image state is a separate resource, preserving its own dimensions.

MAT textures default to grayscale; choose a CMP palette manually because palette
assignment depends on the scene.

Speech, effects and music support PCM WAVE, big-endian iMUSE PCM and MCMP/VIMA,
including stereo music. Audio plays linearly, without scripted iMUSE loops or
transitions.

`GRIM.TAB` dialogue is decrypted and displayed as Windows-1252, alongside text and SET
scene data.

3DO models have interactive previews with their named MAT textures and default pose.

Lua bytecode, costumes, keyframes and SNM movies have metadata/hex previews. Scene
composition, scripted animation and movie playback are not implemented; Remastered,
demos and other platforms are unverified.

Validate with `lua scripts/tests/grim.lua`, or append a game folder and an optional
resource type (`image`, `sound`, `text`, `palette`) to scan real game data.

<a id="harvester"></a>

## Harvester

**Engine ID:** `harvester`

Open the game folder containing `HARVEST.DAT` or `HARVEST.EXE`. Keep `INDEX.001` next to
`HARVEST.DAT` to browse archive members, and preserve any loose resources under
`GRAPHIC`.

It also lists the WAV sound effects (in `HARVEST.DAT` and `SOUND.DAT`), the voice clips
in `SOUND.DAT` (`INDEX.002`), the music in `SOUND/MUSIC/*.CMP`, the dialogue
(`DIALOGUE.SPN`, or the encrypted `DIALOGUE.IDX`) and the game script `HARVEST.SCR`.
`.CMP` audio is IMA ADPCM; its first 50 samples are silenced, as in the game, because
the decoder needs a moment to settle.

<a id="hollywoodmonsters"></a>

## Hollywood Monsters

**Engine ID:** `hollywoodmonsters`

Open the folder containing `RESOURCE.000`, `RESOURCE.003` and at least `RESOURCE.A00` or
`RESOURCE.B00`. Keep the remaining chapter, speech, music and sound resource files
alongside them.

<a id="saga"></a>

## I Have No Mouth, and I Must Scream

**Engine ID:** `saga`

I Have No Mouth, and I Must Scream supports the full DOS CD resource layout. Open the
folder containing `SCREAM.RES` and `SCRIPTS.RES`, with optional `SFX.RES`,
`MUSICGM.RES`, `MUSICFM.RES` and `VOICES1.RES` through `VOICES6.RES` plus `VOICESS.RES`.

Images decode SAGA RLE, four-row banking and the game's vertical inversion. Sprites are
individual stored frames, with scene/chapter palettes where known and the interface
palette as a fallback; shared actor sprites may need a manually selected palette. Delta
animation previews use scene or cutaway backgrounds, capped at 120 frames and 12 million
pixels.

Script-controlled timing, simultaneous animation layers and palette effects are not
reconstructed.

PCM WAVE speech/effects play directly and both GM/FM XMIDI banks export as MIDI (FM
instruments use the MIDI player's sounds).

Scene, interface, actor/object and script dialogue strings are decoded as Windows-1252.
Other resources have size/hex previews. The Spanish CD data was tested; demos, Macintosh
resources and compressed replacement audio are unsupported. `PATCH.RE_` is not applied,
matching ScummVM's Spanish CD configuration.

The verified copy exposes 9,210 resources: 176 backgrounds/screens, 80 masks, 4,834
sprite frames, 231 animations, 177 palettes, 100 text tables, 2,940 speech/effect clips,
80 music tracks and 592 data resources.

<a id="igor"></a>

## Igor: Objective Uikokahonia

**Engine ID:** `igor`

Open the verified Spanish game folder containing `IGOR.DAT` for the floppy release
(11,199,335 bytes) or `IGOR.EXE` for the CD release (9,115,648 bytes). Detection uses
these exact resource-file sizes. Keep the accompanying audio files in place.

Igor supports the verified Spanish floppy and CD releases. The explorer exposes 76
floppy and 75 CD room/scene backgrounds, including the beach ending and the floppy-only
math corridor, with available masks, walkbox areas and decoded text. Both versions
include three decoded telescope views, seven credit backgrounds and five intertitles.
Startup art uses each version's own resources: the floppy Pendulo logo, title and title
backdrop; the CD's four splashes and intro logo. The floppy screen and palette offsets
come from the current resource catalog, rather than image scans or matches against CD
artwork.

Both Igor outfits and the existing animation banks remain available (31 CD and 10 floppy
groups). Animation previews show frame banks at a uniform speed, rather than replaying
room scripts. Interface previews show the stored panels; menu labels and other
script-drawn content are not composited. CD audio includes 68 effects and 1,292 speech
clips. Music preview is available for the floppy; CD music uses separate audio tracks.

Generate a searchable local gallery of all 197 image previews (98 floppy, 99 CD,
including interface panels) with:

```sh
python3 scripts/igor-gallery.py --floppy /path/to/IGOR --cd /path/to/IGOR-CD
```

Open `build/igor-gallery/index.html`. The generator requires Lua and Pillow and also
writes a contact sheet for each version.

Validate without exporting with `lua scripts/tests/igor.lua /path/to/game`.

<a id="interspective"></a>

## Interspective games

**Engine ID:** `interspective`

Open the folder containing the game's prefixed `GRAF.DAT` or `MAIN.DAT` files, such as
`IUC_GRAF.DAT` or `VIC_MAIN.DAT`. Recognized prefixes are `VIC_`, `IUC_`, `GBG_`,
`CER_`, `JTL_` and `YSA_`; keep the matching resource files together.

- **Sound** lists every clip in the `*_Snn.DAT` files and, for Genesis, the `VIC_S99`,
  `VIC_S999`, `VIC_VBn` and `VIC_VSn` speech banks. Genesis stores back-to-back RIFF
  WAVE files, Guilty and Orion Creative VOC files, and IUC bare VOC block chains with a
  zero byte after each clip.
- **Music** lists the XMIDI sequences in the `*_Ann.DAT` files (Genesis, Guilty, Orion).
  IUC's `A` files hold AdLib instruments and its `R`/`SR` files Roland data; neither is
  listed.
- **Text** shows the dialogue strings found in the `*_PROG` and `*_MAIN` scripts (and
  their `.ESP`, `.FRN`, `.GER`, `.ITL` translations). The files are XOR `0x6F`; strings
  are zero-terminated CP437 inside the script bytecode, so they are listed in file order
  without speaker or scene context, and a few fragments may be split across lines. ` / `
  marks a line break. Orion keeps its scripts in the compressed `ORION.RNC` archive, so
  it has no Text category.

<a id="orlando"></a>

## Jack Orlando

**Engine ID:** `orlando`

Jack Orlando opens the tested original Spanish PC CD folder containing `DATA.PAK`,
`MENU.PAK`, `JACK95.EXE` and `ACTION` directly. No installation or extraction is needed;
nested installer archives and loose `MOVIES` resources are included.

BM backgrounds and numbered sprite files use RGB565; packed PBM sprites retain their own
128-color RGB565 palettes. FLX previews show up to 60 stored frames / eight million
pixels at their stored frame rate.

Scripts are decrypted and displayed as DOS CP850. PCM WAVE files play/export; raw SND
effects use an assumed 15,360 Hz mono rate. Compressed speech, MUS music, DLG subtitles,
fonts and AVX movies have metadata/hex previews.

Game scripts, scene composition, sprite placement and movie playback are not
reconstructed. Director's Cut PHK/PH2 archives and other editions are unverified.

All 22,418 images, 62 animation previews, 822 sound clips, two palettes and 9,150
text/metadata entries in the tested copy passed decoder checks.

Validate with `lua scripts/tests/orlando.lua`, or append the game folder and `all` to
decode every resource (`catalog` lists counts only).

<a id="lgop2"></a>

## Leather Goddesses of Phobos 2

**Engine ID:** `lgop2`

Open the game data folder containing both `LGOP2.DAT` and `LGOP2.PRJ`, with the
remaining game resources alongside them.

<a id="les2"></a>

## Les Manley 2: Lost in L.A.

**Engine ID:** `les2`

Open the game folder containing `DATAA.DAT`, `DATAB.DAT`, `EXE.EXE` and `OOPS.OOP`, with
the other `DATA*.DAT` files alongside them.

Les Manley 2 reads the resource directory from `EXE.EXE` alongside `DATA*.DAT` and
`OOPS.OOP`. The tested Spanish release exposes 267 still pictures, 231 animation banks
and 83 palettes.

Scene palettes are selected by filename hash where available; unassigned resources
permit manual palette selection. One picture (`DATAF.DAT` offset 502964) has an
undecodable LZW stream and is listed as metadata.

Audio and scripted scene playback are not implemented; animation previews use uniform
100 ms timing.

<a id="twine"></a>

## Little Big Adventure 1 & 2

**Engine ID:** `twine`

Open the original `LBA1` or `LBA2` game folder directly. The `twine` module reads
HQR/VOX archives in place.

**Isometric Scenery** reconstructs 134 LBA1 grids and 148 LBA2 interior grids at full
size using their block libraries and original bricks. These are static scenery previews;
actors, scripted changes and ceiling overlays are not composed. Screens, sprites
(including LBA1's second shadow image), 26,618 individual scenery bricks, RGB palettes,
and CP850 dialogue/interface text are also available.

**3D Models** exposes 1,445 LBA2 bodies, fixed objects and island `.OBL` objects. The
viewer assembles bone-local vertices in the rest pose and preserves polygon faces,
colors, lines and UVs. Bodies use `RESS.HQR`'s texture atlas; outdoor objects use entry
2 of the matching `.ILE`. Rotate, zoom, inspect wireframes, change the palette, or
export PNGs. Sphere primitives use mesh approximations. Two empty `ILOTCX.OBL` helpers
remain in Resource Data. LBA1 body previews, skeletal animation, original
shading/translucency effects and assembled LBA2 outdoor island terrain are not
implemented.

VOC/WAV speech and effects play directly, including hidden speech segments; LBA2 IMA
ADPCM speech/music is decoded to PCM. LBA1's two MIDI banks retain their original
instrument mappings. Available clips depend on installed media.

Models, animation records, scenes/scripts, island terrain records and other unrecognized
entries retain decompressed metadata/hex views. FLA/Smacker cinematics are not decoded.
No installation or conversion step is required.

Rebuild and restart the app (`./gradlew run`) for the new model/audio decoders. Run
`LBA_TEST_PATH=/path/to/LBA ./gradlew test --tests '*TwineDecoderTest' --tests
'*Lba2ModelDecoderTest' --tests '*ImaWaveDecoderTest'` for LuaJ, model and audio checks;
`lua scripts/tests/twine.lua /path/to/LBA` scans archive payloads with native Lua.

<a id="lure"></a>

## Lure of the Temptress

**Engine ID:** `lure`

Open the folder containing `DISK1.VGA` and the other game volumes (`DISK2.VGA` through
`DISK4.VGA`). The detector also recognizes `DISK1.EGA`; detection validates the first
volume's `heywow` signature.

Screens, palettes and the music/sound-effect banks (Roland and AdLib MIDI files, some
packed) come straight from the disks.

Character sprites and text also need ScummVM's `lure.dat` (from ScummVM's
`dists/engine-data`), which holds tables ScummVM extracted from each language's
executable. Copy it into the game folder to add:

- **Sprites and animations:** one entry per animated hotspot (characters, animals,
  animated objects), with its frames at the hotspot's size, coloured with the game
  palette. The rack serf, whose frames vary in size, is not listed.
- **Text:** the three string tables, in whichever language's decoder from `lure.dat`
  fits the disks (detected automatically). `%1`/`%2` mark object and character names.

The Spanish copy used for testing is not the Spanish build ScummVM's tables were made
for, so a few letters decode as name fragments ("Skorlevolution" for "Revolution") and
some accented letters come out wrong.

<a id="mads"></a>

## MicroProse MADS games

**Engine ID:** `mads`

For Rex Nebular, Return of the Phantom or Dragonsphere, open the game data folder
containing `GLOBAL.HAG` and at least one `SECTION0.HAG` through `SECTION9.HAG`, or
`SPEECH.HAG`. Keep all HAG archives together.

<a id="noctropolis"></a>

## Noctropolis

**Engine ID:** `noctropolis`

Open the game folder containing `DARK`, or open `DARK` directly. The data folder must
contain `SCENE01.AP` and `SCENE13.AP`. The demo layout is also detected under `DEMO` or
directly, using `SCENE01.AP` and `SCENE04.AP`.

Noctropolis scene backgrounds decode from the DBE-compressed playfield tiles plus their
256-colour palette; `.SCN` full screens (title, deaths, comic pages) decode with their
embedded palette. Character/interface sprite sets are exposed as frame animations;
character sprites use the character palette stored in the same `.AP` and interface icons
use the icon palette built into the executable.

Sprite colours in-game also depend on the active room palette, and cell
objects/sounds/music are not decoded yet.

<a id="pink"></a>

## Pink Panther: Passport to Peril / Hokus Pokus Pink

**Engine ID:** `pink`

Pink Panther reads `PPTP.ORB` (Passport to Peril) and `HPP.ORB` (Hokus Pokus Pink), with
matching companion BRO archives in the game root or `INSTALL`. Open
`PINKPANTHER/Peligrosa` or `PINKPANTHER/Abracadabra`. Resources are grouped by archive
page: indexed CEL stills and animations, PCM WAV/VOX audio and Windows-1252 text.

The tested Spanish copies expose 14,820 resources in Passport to Peril and 11,146 in
Hokus Pokus Pink.

Original-media CEL size and VOX padding quirks are handled. Large animations are split
into batches of at most 200 frames and eight million pixels; all frames remain
accessible. Previews use the last decoded frame delay uniformly.

Sprites retain their stored background colour; scene compositing, scripted playback, and
SONGS.SON/ALLSONGS.PTP are not decoded.

<a id="ice"></a>

## Prisoner of Ice

**Engine ID:** `ice`

Open the game data folder containing `ICE320.EXE` or `ICE640.EXE`, with its KRO
archives. Without an executable, detection requires `KVGA.KRO` or `KSVGA.KRO`, together
with `S_KLANG.KRO`.

Prisoner of Ice scene graphics (`scn_*` resources) are exposed as metadata only; the
scene picture/opcode stream is not decoded. `mus_ksound_*` entries are Miles
`HMIMIDIP0131` modules exposed as metadata only, so they cannot be played back.

<a id="riddle"></a>

## Ripley's Believe It or Not!: The Riddle of Master Lu

**Engine ID:** `riddle`

Open the game folder containing `RIPLEY.HAS` and `GLOBAL.HAG`, either directly or in its
`RESOURCE` / `OPTION1` subfolders. Opening the data subfolder directly also works when
it contains both files. Keep the other HAG archives in the same layout.

<a id="runaway"></a>

## Runaway: A Road Adventure

**Engine ID:** `runaway`

Runaway reads loose files from the game root or its `RESOURCE` directory. The tested
media folder exposes 70 backgrounds, 33,407 scene sprite frames, overlays/masks and 16
kHz PCM music, speech and effects.

Animation previews use batches of up to 32 stored frames at 100 ms; scripted
timing/compositing, Bink cutscenes and the shared `RESOURCE.000`-`.004` formats are not
interpreted.

Files still inside installer cabinets require extraction or an installed copy.

**Opening Runaway:** Click **Open Folder** and select the installed or prepared parent
folder containing `RESOURCE` and `DATAA`. Opening `RESOURCE` directly also works;
selecting the parent folder makes the speech directory easier to locate. In the resource
tree, expand **Opening Instructions** and select **How to open this game** for the same
instructions inside the app.

Installer media with `Cab/*.cab` can expose its loose files immediately, but additional
resources require one-time extraction. Extraction is not automatic. Either install the
game normally and open its installed folder, or install **Python 3** and **cabextract**
(both available in your terminal). From the Adventure Explorer source folder containing
`scripts/`, run this command, replacing both example paths:

```sh
python3 scripts/prepare-runaway.py "/path/to/media" "/path/to/runaway-data"
```

Choose a new or empty output folder outside the source media. When preparation finishes,
click **Open Folder** and select `runaway-data`. Subsequent opens need no preparation.
Cabinet resources are extracted, while loose files are linked: **keep the original media
folder in place** so those links continue to work. Bink cutscenes are not previewed.

<a id="asylum"></a>

## Sanitarium

**Engine ID:** `asylum`

Open the Windows game data folder containing `SNTRM.DAT` (or `ASYLUM.DAT`) and
`RES.000`, or select the CD root containing its `Data/` folder. Keep the remaining
`RES.xxx` and `SCN.xxx` files alongside them. Music archives may be in the root
or `Music/`; keep `Vids/` for cutscene metadata. No installer is needed.

The official Windows demo and the mounted English retail CD 1 are verified.
CD 1's 31 data files were copied and SHA-256 checked into
`~/Desktop/ags/Sanitarium`; the demo is preserved in `~/Desktop/ags/Sanitarium-demo`.
CD 1 exposes 14,320 graphics frames, 29 masks, 666 animation previews, 27 palettes,
1,723 audio clips (including 11 music tracks and 972 shared speech clips), 3,911
text strings and 130 data reports. This covers three scene backgrounds and their
chapter-title screens. CD 2/3 assets and GOG/Steam installations remain unverified;
known combined-speech size repairs are included from ScummVM's reference code.

The tested demo exposes 2,051 graphics frames (one background, 1,615 sprite/UI
frames, and 435 font glyphs), seven full-size black/white masks, 89 animation
previews, three palettes, and 171 WAV audio clips including music. There are also
158 dialogue/text entries and 15 archive, scene, lookup-table and cutscene reports.
Frames export as PNGs, audio as WAVs, text as UTF-8, and palettes as PNG/RGB tables.

Scene sprites, backgrounds and fonts keep their scene palette even when alternate
palettes appear before them in the archive. Chapter-title screens use their own
scene title palette; retail menu/credits fonts use their explicit palette bindings.
Other resources infer an archive palette when no binding exists. Select another
palette for assets whose colours change through scripts. Background/title/known
menu screens are opaque; other frames preserve index-0 transparency.
Empty glyphs are omitted, while empty animation frames retain their timing.

Animation previews align each frame using its signed origin on a stable canvas.
The fixed 100 ms preview delay does not replay gameplay timing, scripts, palette
cycling, blending or scene composition. Excessively large animation canvases are
omitted while their individual frames remain available. Smacker cutscenes expose
metadata only. Partial palettes leave unspecified entries black. Scene reports
cover the scene header; actor/object/script logic is not decoded.

<a id="scummv2"></a>

## SCUMM V2

**Engine ID:** `scummv2`

For enhanced V2 Maniac Mansion or Zak McKracken, open the game data folder containing
`00.LFL` and `01.LFL`, with the remaining numbered `.LFL` room files. The detector
validates the V2 index layout.

The tested Spanish enhanced DOS Maniac Mansion exposes 53 room backgrounds,
269 object sprites, 53 room masks, 269 object masks, 53 room/object text reports
and the EGA palette. Object images are named from the game data and grouped by
room. Masks export as black/white PNGs at full image dimensions, with white
marking set occlusion bits. Text reports include all 460 object records, including
hotspots without a decodable picture, with names, positions, walk-to coordinates,
parent indices and image offsets. Palette export includes a 48-byte RGB table.

Reopen the game folder to refresh the resource tree, then use Export for PNGs,
text and palette data. Actor costumes/animations, scripts and sound/music remain
unsupported in this V2 engine. Coverage is verified for enhanced DOS Maniac Mansion;
Zak uses the same layout but has not had a real-data sweep in this change.

<a id="scumm"></a>

## SCUMM V3–V8

**Engine ID:** `scumm`

Open the folder containing the game's index and resource volumes. For V3 EGA Loom, use
`00.LFL` and the numbered `.LFL` files; for V4 Monkey Island, use `000.LFL`, the
`DISKnn.LEC` volumes and the `901.LFL`-`904.LFL` charsets. For V5–V8, use the folder containing the matching
`.000` / `.001`, `.LA0` / `.LA1` / `.LA2`, or `.SM0` / `.SM1` files. Keep any `ROOM`
directory and accompanying `.SOU`, `.BUN` and `.NUT` files in the original layout.

### SCUMM V3 EGA

SCUMM V3 EGA opens the original Loom `00.LFL` + numbered `.LFL` files directly. Verified
76 backgrounds, 594 object sprites, 159 costume sheets and 2,521 animation previews.
Invisible interaction rectangles sharing an image pointer are omitted from the sprite
list. Object previews use a black backdrop where the image copies pixels from the
surrounding scene. Fonts, VGA/small-header releases and other platform variants are not
decoded.

AdLib music (19 tracks, with the same OPL2 / General MIDI switch as Monkey Island's
below) and sound effects (12, OPL2 only) are listed; Loom's own tempo rules are applied
when `LOOM.EXE` is in the folder. PC-speaker versions and the Roland release are not listed.

### SCUMM V4 (EGA and VGA)

SCUMM V4 opens the original DOS Monkey Island `000.LFL` + `DISKnn.LEC` folder directly,
in both the EGA (8 disks) and VGA (4 disks) floppy releases. Room names come from the
index.

- **Rooms:** each room has its background, a **Composite** with every object image at
  its `OC` position, and the object sprites. VGA rooms add their own 256-colour `PA`
  palette, used by default for the room's images and for costumes stored in that room.
  VGA bitmaps use the V5 strip codecs behind a small header; every V4 object strip uses
  an opaque codec, so objects are drawn as solid rectangles, as in the game.
- **Music:** AdLib (`AD`) tracks play either way, chosen with the **AdLib playback**
  switch above the player. **Nuked OPL3 emulation (OPL2)** (the default) runs the song
  on an emulated AdLib chip through a port of ScummVM's `Player_AD`, a reimplementation
  of the game's own AdLib player, so it uses the song's own instruments and percussion;
  looping songs are rendered for one pass. **Java MIDI synthesizer (General MIDI)**
  converts the song to MIDI with default instruments. Roland (`RO`) streams convert to
  standard MIDI.
- **AdLib sound effects:** `AD` effects (envelope programs for up to three channels)
  render the same way. Effects that loop forever stop after 8 seconds. PC-speaker-only
  sounds (`WA`) are not listed.
- **Fonts:** the `901.LFL`-`904.LFL` charsets render as glyph sheets.

Verified with the Spanish VGA floppy: 81 backgrounds, composites and palettes (rooms 88
and 94 are script-only), 606 object sprites, 120 costume sheets, 2,068 animation
previews, 38 music tracks (19 AdLib, 19 Roland) and 4 fonts. The EGA release has 81
backgrounds, 606 object sprites, 115 costume sheets, 2,020 animation previews, 19 AdLib
music tracks and 4 fonts. Standalone object previews use black where pixels copy the
surrounding scene; costume previews use the existing uniform timing and key-colour
backdrop. Non-DOS variants are not decoded.

Run `SCUMM_V4_TEST_PATH=/path/to/MONKEYEGA` and/or `MONKEY_VGA_TEST_PATH=/path/to/vga`
with `./gradlew test --tests '*ScummV4*'` for archive/detection regressions, a LuaJ
graphics scan and the music/font checks.

### SCUMM V5–V8

SCUMM V5-V8 supports per-room object sprites and actor costumes (`COST` for V5/V6,
`AKOS` for V7/V8), with cel sheets and animation previews.

Each room with object images also has a **Composite** entry: the background with
every object image placed at its position (`CDHD` for V5/V6, `IMHD` for V7/V8) and
named from `OBNA`. State 1 images are shown by default; other states are listed
and can be switched on. Transparency follows ScummVM: only the transparent strip
codecs skip the room's `TRNS` colour, except in V8, where every object strip does
and the colour comes from `RMHD`. Some objects are solid placeholder images (for
example two in Monkey Island 2's Woodtick) that the game rarely or never draws.

Music includes MIDI tracks from sound resources and digital iMUSE audio, including
`.BUN` music bundles for The Dig and The Curse of Monkey Island. Sound effects and
speech are also available when present in the game data. See [SCUMM V2](#scummv2) for its separate background, object, mask and data coverage.

<a id="comet"></a>

## Shadow of the Comet

**Engine ID:** `comet`

Open the game data folder containing `R00.CC4`. Keep the other CC4 files and PAK
archives, including `RES.PAK`, in the same folder.

<a id="sci"></a>

## Sierra SCI

**Engine ID:** `sci`

Open the game data folder containing `RESOURCE.MAP` and its numbered volumes, such as
`RESOURCE.000`. SCI32 layouts using `RESMAP.000` and `RESSCI.000` are also detected.
Keep all volumes together.

SCI supports the tested Spanish Gabriel Knight 1 release (`VERSION` 1.0, April 6, 1995).
Open its folder containing `RESOURCE.MAP` and `RESOURCE.000`. All 1,789 mapped resources
decompress; previews cover 152 backgrounds, 825 sprite/animation resources, 11 fonts and
seven palettes, including embedded picture palettes. Sounds, messages and scripts
currently show metadata only.

Run `lua scripts/tests/sci.lua /path/to/GK` for a complete resource scan, or `lua
scripts/tests/sci.lua` for synthetic map/header regression tests.

<a id="agos"></a>

## Simon the Sorcerer 1 & 2

**Engine ID:** `agos`

Open the game data folder containing `GAMEPC` for Simon 1 or `GSPTR30` for Simon 2. Keep
the accompanying GME/VGA files and installed audio banks in that folder.

Simon 1 & 2: fixed room composition, palette banks, sprite transparency and Simon 2
scrolling backgrounds (full-width images are also available separately). Includes
inventory icons, script-derived sprite animation previews, sound effects and speech from
VOC/WAV/MP3 banks, Simon 1 GMF music and Simon 2 GM/MT-32 XMIDI music. Audio entries
with identical offsets appear once.

Animation previews explore static script branches and use a common frame delay; runtime
variables, actor placement, and every scene-dependent palette variant are not simulated.
XMIDI banks preview their first sequence. Verified with DOS data; Amiga/Atari/PC-98
graphics and Ogg/FLAC audio are not supported by this decoder.

<a id="startrek"></a>

## Star Trek: 25th Anniversary / Judgment Rites

**Engine ID:** `startrek`

Open the original DOS game's `STARTREK` or `RITES` data folder. Detection requires
`DATA.DIR`, `DATA.RUN`, `DATA.001` and `STARTREK.EXE` or `RITES.EXE`.
The `startrek` engine reads all matching archive triplets, including Judgment
Rites' eight mission packs, plus external files in `UNCOMP`.

Previews cover indexed BMP/SHP sprites, 320×200 screens, Judgment Rites BGD
backgrounds with embedded palettes, priority masks, VGA palette swatches,
Latin-1 database/dialogue text, external VOC effects and speech, and individual
MT-32/General MIDI XMIDI sequences. Stored bitmap runs and fully resolved ANM
records have animation previews with aligned origins and transparent pixels.
Animations play in stored record order at a fixed 100 ms cadence; game timing,
random branches, virtual crew recoloring/XOR frames, BAN deltas, 3D scenes and
script execution are not replayed. Unresolved animation records and other
formats retain decompressed metadata/hex views. RAW audio stays in the data
view because its playback rate has not been established.

Backgrounds retain embedded colors. Sprites use a matching palette/background,
a mission palette, or a labeled shared preview palette; use the palette selector
for another scene. Music retains original instrument mappings. The supplied
25th Anniversary archive has an invalid `S5ROOM3.BMP` entry, shown as a diagnostic;
Judgment Rites' empty `IFOOD.BMP` placeholder remains in the data view.
Only the supplied Spanish DOS editions have been verified.

Run `./gradlew test --tests '*StarTrekDecoderTest'` for synthetic regressions.
Set `STAR_TREK_TEST_PATH` to the `TREK` parent folder for both-game LuaJ tests.
`lua scripts/tests/startrek.lua ~/Desktop/ags/TREK` validates every catalog leaf.

<a id="city"></a>

## The City of Lost Children

**Engine ID:** `city`

The City of Lost Children opens the tested PC `CITY` folder directly, containing
`DATAS/CITE1.DAT`, `DATAS/CITEG.DAT`, `LANGS`, `GLOBS` and `MOVS`. No installation or
extraction is required. Opening `DATAS` alone also works, with archive resources only.

The verified copy exposes 80 pictures, four font sheets, 77 grayscale depth masks, 38
texture atlases and 672 individual stored texture/sprite rectangles, 105 palettes, 273
sound effects, 265 speech WAVs and 95 dialogue tables across English, French, Spanish,
German and Italian.

Images use matching CPA palettes when available; palettes can be overridden manually,
and unassigned images use grayscale. Speech/effects are unsigned 8-bit mono PCM at
11,025 Hz. Dialogue and installer text are decoded as DOS CP850.

TMM models have textured previews, with character skeletons assembled from SKL/ENV data
and the first stored ANI pose.

Scripts, animations, YOP movies and `TRACK2.RAW` CD music have metadata/hex previews.
Scene composition, animation, movie playback and CD music decoding are not implemented.
Other releases and platforms are unverified.

Validate with `lua scripts/tests/city.lua`, or append the game folder and `all` to
decode every resource (`catalog` lists counts only).

<a id="lastexpress"></a>

## The Last Express

**Engine ID:** `lastexpress`

Open the game or disc data folder containing `TRAIN.EXE` and its HPF archives. A folder
containing valid `.HPF` archives can also be opened without the executable.

Sounds and speech (`.SND`, the game's ADPCM at 22050 Hz) are listed per archive, and
subtitles (`.SBE`) with their start and end times. Both are also read from the installed
`Data` subfolder (`HD.HPF`), which holds the subtitles. The credit images (`.TGA`) are
not decoded.

<a id="kyra1"></a>

## The Legend of Kyrandia

**Engine ID:** `kyra1`

Open the game data folder containing `GEMCUT.EMC`, with its PAK archives and other
resources alongside it.

Besides backgrounds, palettes and animations it lists the music in the `.XMI` files (one
entry per sequence that has notes; sound effects are short sequences in the same
files), the text in each room script's `TEXT` chunk, and the `.FNT` fonts. Character
frames are drawn from the CPS sheets already listed (for example `BRANDON.CPS`); the
cut-out shapes need the coordinates in ScummVM's `kyra.dat`, so they are not listed
separately. AdLib (`.ADL`) and PC-speaker (`.SND`) music are driver programs rather than
notes or samples and are not decoded.

<a id="kyra2"></a>

## The Legend of Kyrandia: Hand of Fate

**Engine ID:** `kyra2`

Open the game data folder containing `FATE.PAK` or `YOURPAST.TLK`. A folder containing
`YOURPAST.CPS` is also detected if it does not contain Kyrandia 1's `GEMCUT.EMC`. Keep
the remaining PAK and audio resources together.

It also lists, from loose files and PAK archives:

- **Shapes:** every `.SHP` file as a sheet of its shapes (character costumes, items,
  scene objects), coloured with whichever palette file gives the shapes' colours the most
  distinct values (character colours come from the scene palettes).
- **Music:** `.XMI` sequences that have notes; `.ADL`/`.C55` driver music is not decoded.
- **Sounds and voices:** the `.VOC` files.
- **Text:** the `.ENG`/`.FRE`/`.GER` string tables and script `TEXT` chunks.
- **Fonts:** the `.FNT` files.

CD speech (`.TLK`) is not decoded (the tested copy is the floppy release).

<a id="sherlock"></a>

## The Lost Files of Sherlock Holmes

**Engine ID:** `sherlock`

Covers both games: *The Case of the Serrated Scalpel* (1992) and *The Case of the Rose
Tattoo* (1996). Open the game data folder containing both `VGS.LIB` and `TALK.LIB`, with
the remaining LIB archives and audio resources alongside them. Rose Tattoo is recognised
by `WALK.LIB` and reads its rooms from the standalone `RESnn.RRM` files in the same folder.

Rose Tattoo lists its 640×480 room backgrounds with palettes and per-room sprites, plus
character, inventory, interface, map and screen sprites, sound effects and speech.

<a id="neverhood"></a>

## The Neverhood

**Engine ID:** `neverhood`

Open the game folder or its `DATA` subfolder containing `HD.BLB` or `A.BLB`. Keep the
other installed BLB archives in the same data folder.

<a id="toonstruck"></a>

## Toonstruck

**Engine ID:** `toonstruck`

Open the game folder or its `MISC` folder. PAK archives expose normal and scrolling
CPS backgrounds (including separate normal/close-up views and their palettes),
RNC/SPCN room masks, CAF sprites and animations, VGA palette swatches, TRE dialogue, and raw data previews. Standalone CAF files are included; empty placeholders show metadata.
Animations preserve frame offsets and transparent pixels; sprites without embedded
colors use their room palette when available. Use the palette selector for other
scene colors. **Automatic (stored colors)** preserves the decoded image. Combined
normal/close-up previews use two palettes; select either separate view to inspect
its swatch. Other palette choices are manual overrides. Speech is indexed by SVI/SVL pairs, sound effects by SEI/SEL pairs,
and standalone MUS music plays as 22100 Hz mono IMA ADPCM. Smacker movies, EMC
script execution, and game scene composition are not implemented.

Run synthetic regressions with `./gradlew test --tests '*ToonstruckDecoderTest'`.
Set `TOONSTRUCK_TEST_PATH` to a game folder to also check every installed background,
mask, palette, dialogue table, and CAF animation, plus samples from each audio pack.

<a id="touche"></a>

## Touché: Adventures of the Fifth Musketeer

**Engine ID:** `touche`

Open the game data folder containing `TOUCHE.DAT`. The engine reads its resources
directly from that archive.

Besides room backgrounds and palettes it lists the sprite sheets (with their frame size),
icons and inventory objects, the VOC sound effects, the MIDI music, the strings of every
room program, and the speech clips from the `V<n>` files next to `TOUCHE.DAT`. Sprites
and icons use the selected room palette for their character colours (193-255).

<a id="tot"></a>

## Trick or Treat

**Engine ID:** `tot`

Open the game folder containing `BITMAPS.DAT`, `PANTALLA.DAT` and `PALETAS.DAT`,
together with `TOT.EXE`, `ANIMA.EXE` or `OBJETOS.DAT`.

It also lists the character and scene animations (`PERSONAJ.SPT`, the `.DAT`/`.SEC`
animation files), the conversation text from `CONVERSA.TXT` (decrypted), the sound
effects (loose `.VOC` files and the clips in `EFECTOS.DAT`) and the `.MUS`/`.MID` music.
Animations use `DEFAULT.PAL` unless a room palette is selected; scene animations look
right with their own room's palette.

<a id="tsage"></a>

## TsAGE: Ringworld / Blue Force

**Engine ID:** `tsage`

Open the game data folder containing `RING.RLB` for Ringworld or `BLUE.RLB` for Blue
Force, with the other RLB libraries alongside it.

TsAGE (Ringworld, Blue Force) sound resources are scored Adlib/MIDI tracker data that
require the game's own sound driver, so they are listed as metadata only and cannot be
played back in the explorer.

<a id="alcachofa"></a>

## Una Aventura de Cine

**Engine ID:** `alcachofa`

Una Aventura de Cine supports the tested Spanish 2003 CD edition (Alcachofa V3.0). Open
the installed folder containing `Fondos`, `Animaciones`, `Mascaras`, `Sonidos` and
`Textos`.

The verified copy contains 123 background banks, 433 animation/sprite banks (three empty
placeholders), 425 mask/overlay banks, 4,150 SND speech/effect clips and 44 stereo WAV
tracks.

AN0 previews compose stored TGA sprites at their original offsets, blend alpha over dark
gray, and preserve full background dimensions. Animations are split into batches of at
most 100 frames / eight million pixels, using the first frame's duration uniformly.

Encrypted NKR text is decoded with its embedded XOR key and displayed as Windows-1252.

Scripts, room data and 13 BIN videos have raw metadata/hex previews; script execution,
scene composition and video playback are not implemented. Other Alcachofa games and
releases are unverified.

**Opening the game:** Click **Open Folder** and choose the installed or extracted parent
folder containing `Fondos`, `Animaciones`, `Mascaras`, `Sonidos` and `Textos`. Do not
select one of those subfolders. Select **How to open this game** in the resource tree
for the same instructions inside the app.

For installer media containing `data01.cab` and `data02.cab`, preparation is required
once; cabinet extraction is not automatic. Either install the game normally and open its
installed folder, or install **Python 3** and **cabextract** (both available in your
terminal), then run the following from the Adventure Explorer source folder containing
`scripts/`. Replace both example paths:

```sh
python3 scripts/prepare-decine.py "/path/to/decine" "/path/to/decine-data"
```

Choose a new or empty output folder outside the source media. When the command finishes,
click **Open Folder** and select `decine-data`. Subsequent opens need no preparation.
The script preserves Spanish filenames, copies extracted assets, and leaves the source
media untouched.

Validate with `lua scripts/tests/alcachofa.lua /path/to/output catalog` (all bank
structures), `audio` (all sound clips), or `visual` (first frame of every AN0 bank).

<a id="universe"></a>

## Universe

**Engine ID:** `universe`

Open the game data folder containing `UNIVERSE.EPF`. Select the folder itself; the
archive is read in place.

The **Text** category lists the `TEXT*.ENG`, `.FRE`, `.GER`, `.ITA` and `.SPA` files
(53 per language) one string per line. Each file starts with a table of 16-bit offsets;
every string carries a 4-byte prefix (screen position and colour, or `0xFF` when unused)
followed by zero-terminated code page 437 text.

Not decoded yet: the `.MCV`/`.MCB` sprite banks (the header is a count followed by
width, height and offset records, but the pixel encoding is unknown) and the
`BACK*.COM` files. The archive holds no digital audio.

<a id="visionaire"></a>

## Visionaire

**Engine ID:** `visionaire`

Open the folder containing the game's `.vis`, `.vs000` or `.vc000` archives. The
detector recognizes archives with a `VIS3` or `VIS5` header. Keep all archive parts and
any required `vis.key` in that folder.

Visionaire archives may be encrypted with a game-specific XOR key. Place a `vis.key`
file in the game folder for encrypted games (format: `ID;Game Name;Key`, one entry per
line). Unencrypted archives and archives shipped with known keys work without any extra
setup.

<a id="gxl"></a>

## Wayne's World / The Dark Half (Genus GXL)

**Engine ID:** `gxl`

Open the game data folder containing its `.GXL` files. Detection requires at least two
valid Genus GXL archives in that folder, such as the `R*.GXL` files for Wayne's World or
`K*.GXL` files for The Dark Half.

The loose files next to the archives are listed too:

- **Sound**: `*.SND` effects and speech. They are headerless 8-bit PCM; the games do not
  store a rate, so 11,025 Hz is assumed and pitch may be slightly off.
- **Music**: XMIDI sequences from the `*.XMI` files.
- **Text**: `*.TXT` messages. The tested copies are Spanish translations that put the
  accented letters in spare font slots, mapped per game to their Unicode letters. Each
  line keeps the game's `+` terminator, padding and trailing code.
- **Fonts**: `*.GFT` bitmap fonts as a glyph grid.
- **Masks**: Wayne's World `*.MSK` 320x150 walk masks.

## 3D model previews

Open Alone in the Dark, Grim Fandango or The City of Lost Children and select a resource in **3D Models**.
Drag to rotate, scroll or use **+ / −** to zoom, and switch **Wireframe** on to inspect
polygon edges. **Reset view** restores the camera; **Export PNG** saves the current
view. **Texture** selects automatic materials, an image override or an untextured
view; its search field finds images by filename. **Palette** recolors the texture.
Camera rotation and zoom are retained when changing textures or palettes.
The toolbar's **Export → 3D Models** exports default views in bulk.

Grim's binary and text 3DO models use the first geoset and stored hierarchy pose.
Grim automatically resolves each material's named MAT image. Its default CMP is
a filename-based best match; use the palette selector for scene-specific colors.
City assembles SKL/ENV skeletons using the first ANI frame and uses Z-up coordinates.
Room models select their room's SCTEX atlas; shared models use CITEXFR. The default
room palette includes Miette's reserved colors. Other releases may need a manual
texture or palette selection. Skeletal playback and game scene composition are
not included. Empty Grim helper models display an explanation instead of geometry.

Run decoder/renderer tests with `./gradlew test`. To also scan installed game assets,
set `GRIM_MODEL_TEST_PATH` and/or `CITY_MODEL_TEST_PATH` to their game folders.


Alone in the Dark 1–3 expose `LISTBODY.PAK` and, where present, `LISTBOD2.PAK`
under **3D Models**. Character bones are assembled in the body's stored pose.
Polygon colors use Alone 1's game palette or the first camera palette with reserved
colors for Alone 2/3. Lines are preserved; spheres and point primitives use mesh
approximations. Animation playback and original game material effects are not
simulated. All 1,861 tested body entries were checked, including three empty
helper objects in Alone 3. Jack and TimeGate model data remain unverified.
For optional real-data tests set `AITD1_MODEL_TEST_PATH`, `AITD2_MODEL_TEST_PATH`
and/or `AITD3_MODEL_TEST_PATH` before running `./gradlew test`.


After updating these preview scripts, rebuild and restart the app (`./gradlew run`)
to load the corresponding Kotlin decoders and viewer controls. An older running
app displays a restart message instead of a missing-function error.

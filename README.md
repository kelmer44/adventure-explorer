# Adventure Explorer

A universal resource browser for classic adventure games. Think **ScummRevisited** or **SCICompanion**, but engine-agnostic — new game engines are defined via **Lua scripts** with no recompilation needed.

![Kotlin](https://img.shields.io/badge/Kotlin-1.9-purple)
![Compose](https://img.shields.io/badge/Compose%20Desktop-1.6-blue)
![Lua](https://img.shields.io/badge/Scripting-Lua%205.2-blue)

## Features

- **Universal**: Any adventure game can be supported by writing a Lua engine script
- **Cross-platform**: Runs on macOS, Windows, and Linux (Compose Desktop / JVM)
- **No recompilation**: Add new game engines by dropping Lua scripts into `scripts/engines/`
- **Auto-detection**: Opens a game folder and automatically identifies the engine
- **Preview**: View room backgrounds, palettes, sprites, text data, and animations
- **Sound playback**: Play VOC and raw PCM sound effects with waveform display
- **Animation playback**: Frame-by-frame navigation, play/pause, adjustable speed
- **Export**: Save resources as PNG or WAV — individual frames, animation sequences, or sound files

## Supported Engines

57 game engines are currently supported via Lua scripts — no recompilation needed.

| Engine | Year | ID | Resources | Status |
|--------|------|----|-----------|--------|
| 3 Skulls of the Toltecs | 1996 | `toltecs` | Backgrounds, Sprites, Palettes, Animations, Speech/Sound, Music, Data | ✅ Working* |
| Una Aventura de Cine - Edición Especial | 2003 | `alcachofa` | Backgrounds, Sprites, Animation Previews, Masks, Speech/Sound, Text, Data | ✅ Working* |
| Alfred Pelrock | 1997 | `pelrock` | Backgrounds, Palettes, Text, Sprites | ✅ Working |
| Amazon: Guardians of Eden | 1992 | `amazon` | Tiled Backgrounds, Screens, Sprites, Video Previews, Palettes, Sound, MIDI, Data | ✅ Working* |
| Alone in the Dark series | 1992-95 | `aitd` | Backgrounds, 3D Models | ✅ Working |
| Another World / Out of This World (DOS) | 1991 | `anotherworld` | Bitmaps, Polygon Artwork, VGA/EGA Palettes, Sound Samples, Scripts, Data | ✅ Working* |
| Beneath a Steel Sky | 1994 | `sky` | Backgrounds, Sprites (animated), Palettes | ✅ Working |
| Broken Sword: Shadow of the Templars | 1996 | `sword1` | Backgrounds, Palettes, Sprites | ✅ Working |
| Broken Sword II: The Smoking Mirror | 1997 | `sword2` | Backgrounds, Palettes, Sprites | ✅ Working |
| Bud Tucker in Double Trouble | 1996 | `tucker` | Background Tiles, Sprite Sheets/Frames, Animation Previews, Inventory Sprites, Masks, Palettes, Speech, Sound, Music, Text, Data | ✅ Working* |
| The City of Lost Children | 1997 | `city` | Backgrounds, Fonts, Texture Atlases/Crops, Depth Masks, Palettes, Speech, Sound Effects, Dialogue, Data | ✅ Working* |
| Cobra Mission | 1992 | `cobramission` | Backgrounds, Dialogue Scripts, Names/Messages/Credits, Sound | ✅ Working* |
| Cruise for a Corpse | 1991 | `cruise` | Backgrounds, Sprite Frames, Polygon Actors, Palettes | ✅ Working |
| Curse of Enchantia | 1992 | `curseofenchantia` | Backgrounds | ✅ Working |
| Dark Seed | 1992 | `darkseed` | Backgrounds, Palettes, Sprites | ✅ Working |
| Dark Seed 2 | 1995 | `darkseed2` | Backgrounds, Sprites, UI, Room Thumbnails, Palettes | ✅ Working* |
| Discworld 1 & 2 | 1995/96 | `tinsel` | Backgrounds, Sprites, Animations | ✅ Working |
| Drascula: The Vampire Strikes Back | 1996 | `drascula` | Backgrounds, Object Sprites | ✅ Working |
| El Sulfato Atomico | 1998 | `sulfato` | Backgrounds, Sprite Sheets, Palettes, FLC Animation Previews, Speech, Sound, Room Data | ✅ Working* |
| El Tesoro de la Isla Alcachofa | 2000 | `tesoro` | RGB565 Backgrounds, Sprites, Animation Previews, Shadow Masks, Speech, Scripts | ✅ Working* |
| Fable | 1996 | `fable` | Backgrounds, Sprite Frames, Frame Bank Previews, Palettes, Dialogue, Speech, PCM Sound | ✅ Working* |
| Fievel Goes West / An American Tail | 1993 | `capstone` | Pictures, Palettes, Sprites & Animation Previews, Scene Data | ✅ Working* |
| Flight of the Amazon Queen | 1995 | `queen` | Backgrounds, Sprites & Actor Banks (animated), Palettes | ✅ Working |
| Future Wars / Operation Stealth | 1989/90 | `cine` | Backgrounds, Sprite Frames, Palettes | ✅ Working |
| Gobliiins / Gobliins 2 / Goblins Quest 3 | 1991-93 | `gob` | Backgrounds, Sound, Music | ✅ Working |
| Grim Fandango | 1998 | `grim` | RGB565 Bitmaps, Depth Masks, Textures, Palettes, Speech, Sound, Music, Dialogue, Scene Data | ✅ Working* |
| Harvester | 1996 | `harvester` | Backgrounds, Sprites | ✅ Working |
| Hollywood Monsters | 1997 | `hollywoodmonsters` | Backgrounds, Sprites, Palettes, Speech, Music, Sound | ✅ Working |
| I Have No Mouth, and I Must Scream | 1995 | `saga` | Backgrounds, Masks, Sprite Frames, Animation Previews, Palettes, Text, Speech, Sound, Music (XMI→MIDI), Data | ✅ Working* |
| Igor: Objective Uikokahonia | 1994 | `igor` | Backgrounds, Masks, Sprites, Animations, Text, Music, Sound Effects, Speech | ✅ Working |
| Interspective (Innocent Until Caught, etc.) | 1993-96 | `interspective` | Backgrounds | ✅ Working |
| Jack Orlando | 1997 | `orlando` | RGB565 Backgrounds, Packed Sprites, FLX Animation Previews, Palettes, Scripts, PCM Sound, Data | ✅ Working* |
| L.A. Law: The Computer Game | 1992 | `capstone` | Images, ILBM Fonts/Cursors, Case Text, Music (XMI→MIDI), Speech Metadata | ✅ Working* |
| Leather Goddesses of Phobos 2 | 1992 | `lgop2` | Backgrounds, Sound, Music | ✅ Working |
| Les Manley 2: Lost in L.A. | 1991 | `les2` | Scenes, Sprites, Animation Previews, Palettes, Text and Data | ✅ Working* |
| Lure of the Temptress | 1992 | `lure` | Screens, Palettes | ✅ Working* |
| MicroProse MADS games (Return of the Phantom, Rex Nebular and the Cosmic Gender Bender, Dragonsphere) | 1991-94 | `mads` | Backgrounds, Tiles, Sprites & Animations, Palettes, Fonts, Sound & Speech, Scene Data & Hex, Text | ✅ Working |
| Noctropolis | 1994 | `noctropolis` | Backgrounds, Screens, Sprites | ✅ Working* |
| Pink Panther: Passport to Peril / Hokus Pokus Pink | 1996/98 | `pink` | CEL Backgrounds, Sprites & Animations, Speech, Sound, Music, Text | ✅ Working* |
| Prisoner of Ice | 1997 | `ice` | Backgrounds, Palettes, Dialogue Text, Sound Effects | ✅ Working* |
| Ringworld: Revenge of the Patriarch / Blue Force | 1992-94 | `tsage` | Backgrounds, Palettes, Sprites & Animations, Messages, Sound metadata | ✅ Working* |
| Ripley's Believe It or Not!: The Riddle of Master Lu | 1995 | `riddle` | Backgrounds, Palettes, Sprites & Animations, Sound/Speech, Music (HMP→MIDI), Attribute Codes, Fonts, Scene Definitions | ✅ Working |
| Runaway: A Road Adventure | 2001 | `runaway` | RGB565 Backgrounds, Sprites & Animation Previews, Overlays, Masks, Music, Speech, Sound Effects, Data | ✅ Working* |
| SCUMM V2 (Maniac Mansion, Zak McKracken) | 1988-89 | `scummv2` | Backgrounds | ✅ Working |
| SCUMM V3 EGA (tested: Loom) | 1989-90 | `scumm` | Backgrounds, EGA Palette, Object & Actor Sprites, Costume Animations | ✅ Working* |
| SCUMM V5-V8 (Monkey Island 1-3, Atlantis, The Dig, Day of the Tentacle…) | 1990-97 | `scumm` | Backgrounds, Palettes, Object & Actor Sprites, Costume Animations, Fonts (NUT), Music (MIDI + digital iMUSE), Sound Effects, Speech | ✅ Working |
| Shadow of the Comet | 1993 | `comet` | Backgrounds, Palettes, Sprites, Animations, Sound | ✅ Working |
| Sherlock Holmes: Consulting Detective | 1991-93 | `sherlock2` | Backgrounds, Animations | ✅ Working |
| Sierra SCI (SCI0 EGA, SCI1 VGA, SCI1.1, SCI2/SCI32 — tested: Gabriel Knight 1, Larry 1 VGA, Larry 3, Larry 6, Larry 7, King's Quest 6, Laura Bow 2) | 1988-96 | `sci` | Backgrounds, Sprites, Cursors, Fonts, Palettes, Texts | ✅ Working |
| Simon the Sorcerer 1 & 2 | 1993/95 | `agos` | Backgrounds, Sprites, Animations, Inventory Icons, SFX, Speech, Music | ✅ Working |
| The Beverly Hillbillies | 1993 | `capstone` | Backgrounds, Sprites, Palettes, Dialogue, Music (XMI→MIDI), Data | ✅ Working* |
| The Last Express | 1997 | `lastexpress` | Backgrounds, Animations | ✅ Working |
| The Legend of Kyrandia | 1992 | `kyra1` | Backgrounds, Palettes, Animations | ✅ Working |
| The Legend of Kyrandia: Hand of Fate | 1993 | `kyra2` | Backgrounds, Palettes, Animations | ✅ Working |
| The Lost Files of Sherlock Holmes | 1992/96 | `sherlock` | Backgrounds, Palettes, Object Sprites, Animations, Sound Effects, Speech | ✅ Working |
| The Neverhood | 1996 | `neverhood` | Bitmaps, Animations, Palettes, Sounds, Music, Text, Data, Videos | ✅ Working |
| Toonstruck | 1996 | `toonstruck` | Backgrounds, Masks, Sprites & Animations, Palettes, Dialogue, Speech, Sound, Music, Data | ✅ Working* |
| Touché: Adventures of the Fifth Musketeer | 1995 | `touche` | Backgrounds, Palettes | ✅ Working |
| Trick or Treat | 1997 | `tot` | Backgrounds, Palettes, Objects | ✅ Working |
| Universe | 1994 | `universe` | Backgrounds, Palettes, Masks | ✅ Working |
| Visionaire Engine (Daedalic games) | 2005-15 | `visionaire` | Backgrounds (PNG), Game Data | ✅ Working* |
| Wayne's World / The Dark Half (Capstone, Genus GXL) | 1993 | `gxl` | Images | ✅ Working |

> **Discworld 1 & 2:** open **Sprites → file name → Animation** to play or
> step through a stored animation reel. Sequences follow the game's frame order,
> timing, flips and offsets, including multipart sprites and transparent frames.
> Individual sprite images remain in the same file groups. Reels are previewed
> independently; full scene composition and sound scripts are not replayed.

> \* **Another World** opens the original DOS `MEMLIST.BIN` + `BANK01`...`BANK0D`
> folder directly. It exposes all 12 planar
> bitmaps, 5,042 script-referenced polygon artwork previews across nine parts,
> 576 VGA/EGA palettes, and 97 nonempty signed PCM samples (313 pitch previews).
> All 146 resource records have decompressed metadata/hex views; the nine
> scripts also have static disassembly. ByteKiller streams are checksum checked.
> Polygon previews retain composite child positions at native scale, with a
> standalone scanline rasterizer and black backdrop. They do not reproduce
> the game's scene composition, page-copy effects, built-in head masks, VM
> animation, zoom or timing. Each image now gets a default inferred from palette
> commands along script control flow, including palettes selected between drawing
> and display. Reused shapes get a representative palette from their uses; missing
> usable contexts retain a visible part-palette fallback. Logos keep their
> verified fade endpoints, and every palette can still be selected manually.
> Preview descriptions identify inferred defaults, fallbacks and manual overrides.
> Samples use script-referenced pitches when available,
> otherwise a labeled 9943 Hz preview rate; loop segments play once. The three
> music modules have metadata/hex previews only. Text/fonts embedded in the
> executable, other platforms, demos and anniversary editions are unsupported.

SCI supports the tested Spanish Gabriel Knight 1 release (`VERSION` 1.0,
April 6, 1995). Open its folder containing `RESOURCE.MAP` and `RESOURCE.000`.
All 1,789 mapped resources decompress; previews cover 152 backgrounds,
825 sprite/animation resources, 11 fonts and seven palettes, including embedded
picture palettes. Sounds, messages and scripts currently show metadata only.
Run `lua scripts/tests/sci.lua /path/to/GK` for a complete resource scan, or
`lua scripts/tests/sci.lua` for synthetic map/header regression tests.

SCUMM V5-V8 supports per-room object sprites and actor costumes (`COST` for
V5/V6, `AKOS` for V7/V8), with cel sheets and animation previews. Music includes
MIDI tracks from sound resources and digital iMUSE audio, including `.BUN`
music bundles for The Dig and The Curse of Monkey Island. Sound effects and
speech are also available when present in the game data. SCUMM V2 support
remains limited to backgrounds.

> \* SCUMM V3 EGA opens the original Loom `00.LFL` + numbered `.LFL` files
> directly. Verified 76 backgrounds, 594 object sprites, 159 costume sheets and
> 2,521 animation previews. Invisible interaction rectangles sharing an image
> pointer are omitted from the sprite list. Object previews use a black backdrop
> where the image copies pixels from the surrounding scene. V3 music/sound,
> fonts, VGA/small-header releases and other platform variants are not decoded.
> V4 is still unsupported.

> Simon 1 & 2: fixed room composition, palette banks, sprite transparency and
> Simon 2 scrolling backgrounds (full-width images are also available separately).
> Includes inventory icons, script-derived sprite animation previews, sound effects
> and speech from VOC/WAV/MP3 banks, Simon 1 GMF music and Simon 2 GM/MT-32 XMIDI
> music. Audio entries with identical offsets appear once. Animation previews
> explore static script branches and use a common frame delay; runtime variables,
> actor placement, and every scene-dependent palette variant are not simulated.
> XMIDI banks preview their first sequence. Verified with DOS data;
> Amiga/Atari/PC-98 graphics and Ogg/FLAC audio are not supported by this decoder.

> Future Wars / Operation Stealth expose ANI/ANM frames and SET bitmaps; Cruise
> exposes SET/SEC bitmap frames (1/4/5/8-bit encodings). Each volume has separate
> Backgrounds, Sprites and Palettes groups. Sprite colours default to a matching
> scene-name background, or an archive background fallback; choose another palette
> for actors reused across scenes. Previews preserve all palette indices on an
> opaque canvas. Cruise also exposes **Polygon Actors and Vector Art** with 2,812
> stored poses, including mirrored references, through the model viewer. These are
> flat vector shapes, shown front-on with zoom, wireframe, palette selection and PNG
> export; authored colours, concave boundaries and drawing order are preserved.
> Script-driven palette changes and animation timing are not replayed. Validated
> with 1,989 Future Wars and 2,345 Cruise bitmap frames, plus every Cruise
> polygon pose; Operation Stealth formats have synthetic tests.

> \* Fable opens the original PC CD folder directly, detected by `DECORS.DAT`
> containing `101DECOR.RAW` and `101DECOR.PAL`. The tested edition exposes
> 83 room backgrounds, six title/installer screens, 11,474 sprite frames in
> 473 banks, 85 palettes, 561 text resources and 2,932 audio clips (including
> 2,739 speech WAVs and 191 bundled PCM sounds). English, French, German,
> Spanish and Italian dialogue/object labels decode as DOS CP850. Raw and
> scanline RLE sprites use the corresponding room palette, or room 101 for
> shared actors/UI; title and installer art use their own palettes. Verified
> per-frame palette patches are applied by default. A manual palette selection
> overrides them. Twelve headerless palette blocks in `CLOSEUP.SPR` and
> `MISCDAT*.SPR` remain unverified; those banks retain the shared palette.
> Frame bank previews show up to 60 stored frames / four million pixels at
> 100 ms per frame. Game animation scripts, placement and scene composition
> are not reconstructed. Fonts, cursors, inventory sheets, credits ANM and
> IMX movies have metadata/hex previews only. Movie playback is unavailable.
> Validate with `lua scripts/tests/fable.lua /path/to/FABLE all`.

> \* Jack Orlando opens the tested original Spanish PC CD folder containing
> `DATA.PAK`, `MENU.PAK`, `JACK95.EXE` and `ACTION` directly. No installation or
> extraction is needed; nested installer archives and loose `MOVIES` resources
> are included. BM backgrounds and numbered sprite files use RGB565; packed
> PBM sprites retain their own 128-color RGB565 palettes. FLX previews show up
> to 60 stored frames / eight million pixels at their stored frame rate.
> Scripts are decrypted and displayed as DOS CP850. PCM WAVE files play/export;
> raw SND effects use an assumed 15,360 Hz mono rate. Compressed speech, MUS
> music, DLG subtitles, fonts and AVX movies have metadata/hex previews.
> Game scripts, scene composition, sprite placement and movie playback are not
> reconstructed. Director's Cut PHK/PH2 archives and other editions are unverified.
> All 22,418 images, 62 animation previews, 822 sound clips, two palettes and
> 9,150 text/metadata entries in the tested copy passed decoder checks.
> Validate with `lua scripts/tests/orlando.lua`, or append the game folder and
> `all` to decode every resource (`catalog` lists counts only).

> \* Bud Tucker opens the DOS game folder containing `CTABLE01.ENC` (or
> `CTABLE01.C`), `BUD_1.PCX` and `PANEL1.PCX`, with `SPRITES`, `FX`, `MUSIC`,
> `SPEECH`, `AUDIO` and `GRAPHICS` alongside them. PCX images retain their
> embedded palettes; walk masks use grayscale. SPR frames use a matching room
> palette where available, with
> manual palette selection and grayscale fallback. Inventory icons are cropped
> from `PANOBJS` sheets. Animation previews preserve stored frame origins and
> split long banks into batches of at most 60 frames / four million pixels,
> using a uniform 100 ms delay. Backgrounds are individual stored tiles; scene
> composition, game animation sequences and palette effects are not reconstructed.
> Encoded tables subtract 0x80 per byte and display as DOS CP850, including
> Spanish dialogue. PCM WAV speech, effects, music and intro audio play/export;
> two mislabeled non-WAVE clips, intro movies, raw data and ScummVM compressed
> audio replacements have metadata previews. The tested copy exposes 23,245
> resources, including 17,031 stored sprite frames, 756 animation batches and
> 4,594 WAV clips. Other editions and demos are unverified. Validate with `lua scripts/tests/tucker.lua`, or append the game
> folder and `all` to decode every resource (`catalog` lists counts only).

> \* Cobra Mission adds **Texts** with seven decoded `CODE.VOL` authoring scripts
> and 856 individual scene entries in the tested Spanish copy. Scripts preserve
> speaker tags, variables, author comments and original custom-font placeholders
> (such as `{`, `~`, `r` and `w`); DOS accented bytes are converted to Unicode.
> `ICP.VOL` also exposes 98 plain-text constants (names, messages and credits)
> across eight entries. **Sounds** contains all 155 Creative VOC clips from
> `PCM1.VOL` through `PCM6.VOL`, including silence and multiple audio blocks;
> loop bodies play once for preview/export. Existing 286 GC images remain
> available. Compiled IC bytecode, raw tile/sprite banks, map layouts and OPL
> music are not decoded. Counts may vary by edition.

> \* I Have No Mouth, and I Must Scream supports the full DOS CD resource layout.
> Open the folder containing `SCREAM.RES` and `SCRIPTS.RES`, with optional
> `SFX.RES`, `MUSICGM.RES`, `MUSICFM.RES` and `VOICES1.RES` through `VOICES6.RES`
> plus `VOICESS.RES`. Images decode SAGA RLE, four-row banking and the game's
> vertical inversion. Sprites are individual stored frames, with scene/chapter
> palettes where known and the interface palette as a fallback; shared actor
> sprites may need a manually selected palette. Delta animation previews use
> scene or cutaway backgrounds, capped at 120 frames and 12 million pixels.
> Script-controlled timing, simultaneous animation layers and palette effects
> are not reconstructed. PCM WAVE speech/effects play directly and both GM/FM
> XMIDI banks export as MIDI (FM instruments use the MIDI player's sounds).
> Scene, interface, actor/object and script dialogue strings are decoded as
> Windows-1252. Other resources have size/hex previews. The Spanish CD data was tested;
> demos, Macintosh resources and compressed replacement audio are unsupported.
> `PATCH.RE_` is not applied, matching ScummVM's Spanish CD configuration.
> The verified copy exposes 9,210 resources: 176 backgrounds/screens, 80 masks,
> 4,834 sprite frames, 231 animations, 177 palettes, 100 text tables, 2,940
> speech/effect clips, 80 music tracks and 592 data resources.

> \* The City of Lost Children opens the tested PC `CITY` folder directly,
> containing `DATAS/CITE1.DAT`, `DATAS/CITEG.DAT`, `LANGS`, `GLOBS` and `MOVS`.
> No installation or extraction is required. Opening `DATAS` alone also works,
> with archive resources only. The verified copy exposes 80 pictures, four font
> sheets, 77 grayscale depth masks, 38 texture atlases and 672 individual stored
> texture/sprite rectangles, 105 palettes, 273 sound effects, 265 speech WAVs
> and 95 dialogue tables across English, French, Spanish, German and Italian.
> Images use matching CPA palettes when available; palettes can be overridden
> manually, and unassigned images use grayscale. Speech/effects are unsigned
> 8-bit mono PCM at 11,025 Hz. Dialogue and installer text are decoded as DOS CP850.
> TMM models have textured previews, with character skeletons assembled from
> SKL/ENV data and the first stored ANI pose. Scripts, animations, YOP movies and
> `TRACK2.RAW` CD music have metadata/hex previews. Scene composition, animation,
> movie playback and CD music decoding are not implemented. Other releases and
> platforms are unverified. Validate with `lua scripts/tests/city.lua`, or append
> the game folder and `all` to decode every resource (`catalog` lists counts only).

> \* Grim Fandango supports the original PC LAB archives. Open an installed folder
> containing `DATA000.LAB` (or another `DATA00x.LAB`), or either CD root containing
> `GRIMDATA`. No installation is required. To browse all four years together, copy
> the LAB files from both discs into one folder, including `GRIM.TAB` for dialogue.
> Each disc can also be browsed independently. The tested discs expose 5,191
> stored bitmap/depth/texture images and 125 CMP palettes in total. BM codecs 0
> and 3 are decoded as RGB565; ZBM depth images are shown in grayscale. Every
> stored image state is a separate resource, preserving its own dimensions.
> MAT textures default to grayscale; choose a CMP palette manually because
> palette assignment depends on the scene. Speech, effects and music support
> PCM WAVE, big-endian iMUSE PCM and MCMP/VIMA, including stereo music. Audio
> plays linearly, without scripted iMUSE loops or transitions. `GRIM.TAB` dialogue
> is decrypted and displayed as Windows-1252, alongside text and SET scene data.
> 3DO models have interactive previews with their named MAT textures and default pose.
> Lua bytecode, costumes, keyframes and SNM movies have metadata/hex previews.
> Scene composition, scripted animation and movie playback are not implemented; Remastered, demos and other platforms are unverified.
> Validate with `lua scripts/tests/grim.lua`, or append a game folder and an optional
> resource type (`image`, `sound`, `text`, `palette`) to scan real game data.

> \* Una Aventura de Cine supports the tested Spanish 2003 CD edition
> (Alcachofa V3.0). Open the installed folder containing `Fondos`, `Animaciones`,
> `Mascaras`, `Sonidos` and `Textos`. The verified copy contains 123 background
> banks, 433 animation/sprite banks (three empty placeholders), 425 mask/overlay
> banks, 4,150 SND speech/effect clips and 44 stereo WAV tracks. AN0 previews
> compose stored TGA sprites at their original offsets, blend alpha over dark gray,
> and preserve full background dimensions. Animations are split into batches of
> at most 100 frames / eight million pixels, using the first frame's duration
> uniformly. Encrypted NKR text is decoded with its embedded XOR key and displayed
> as Windows-1252. Scripts, room data and 13 BIN videos have raw metadata/hex
> previews; script execution, scene composition and video playback are not implemented.
> Other Alcachofa games and releases are unverified.
>
> **Opening the game:** Click **Open Folder** and choose the installed or extracted
> parent folder containing `Fondos`, `Animaciones`, `Mascaras`, `Sonidos` and
> `Textos`. Do not select one of those subfolders. Select **How to open this game**
> in the resource tree for the same instructions inside the app.
>
> For installer media containing `data01.cab` and `data02.cab`, preparation is
> required once; cabinet extraction is not automatic. Either install the game
> normally and open its installed folder, or install **Python 3** and **cabextract**
> (both available in your terminal), then run the following from the Adventure
> Explorer source folder containing `scripts/`. Replace both example paths:
>
> ```sh
> python3 scripts/prepare-decine.py "/path/to/decine" "/path/to/decine-data"
> ```
>
> Choose a new or empty output folder outside the source media. When the command
> finishes, click **Open Folder** and select `decine-data`. Subsequent opens need
> no preparation. The script preserves Spanish filenames, copies extracted assets,
> and leaves the source media untouched. Validate with
> `lua scripts/tests/alcachofa.lua /path/to/output catalog` (all bank structures),
> `audio` (all sound clips), or `visual` (first frame of every AN0 bank).

> \* Amazon: Guardians of Eden opens the tested `AMAZON` directory, detected
> by `AMAZON.EXE`, `S00.AP` and `C00.AP`. AP archives and DBE compression are read
> directly. The tested Spanish floppy release exposes 41 tiled backgrounds,
> 40 full-screen pictures, 122 sprite banks, 11 loose images, 104 video sequences,
> 151 STEVE sound clips and 64 MIDI tracks. Wide backgrounds retain their full
> dimensions, including the 2560-pixel panorama. Image palettes are embedded;
> sprite/video palettes are suggested when their archive contains a single
> picture palette, with manual override and grayscale fallback. Video previews
> show all stored delta packets (including trailing packets), with a blank initial
> canvas unless a background packet is supplied, at uniform 100 ms timing.
> Previews are batched to at most 100 frames / eight million pixels. Scripted
> animation timing, scene compositing, MIDI driver patches and script execution
> are not interpreted; remaining data has hex/ASCII previews. Tested with the
> Spanish floppy data; CD speech and alternate release layouts are unverified.

> \* 3 Skulls of the Toltecs opens `3SKULLS`, a language `.PDI` directory,
> or an installed directory containing `WESTERN`. The tested Spanish CD has
> 56 backgrounds, 533 sprite banks (16-color, 256-color and shadow masks),
> 92 interface images, 11 animation banks, 90 palette fragments, 3,868 unsigned
> 22,050 Hz PCM speech/effect clips and 18 XMIDI/MIDI music resources.
> Backgrounds and animations use their embedded palettes. Sprite palettes are
> selected by game scripts: previews use grayscale until a palette fragment is
> chosen manually. Animation previews retain delta frames and holds, in batches
> of at most 100 frames / eight million pixels, with uniform 100 ms timing.
> Raw audio ranges are enabled only for the verified Spanish CD layout;
> other releases retain unclassified resources as metadata and hex previews.
> Scripts, fonts, cursor masks, movie playback and scene compositing are not
> interpreted. Resource names are numeric archive indices.

> \* El Sulfato Atomico opens the unpacked `SULFATO` directory (detected by
> `SULFATO.EXE`, `1.ALG` and `1.ALD`). The tested Spanish release contains
> 111 NMP/PCX ALG images plus one SVS save thumbnail, their embedded palettes,
> 53 FLC animation banks in VHS files, 735 PCM WAV clips, and 43 text/data files.
> Wide pictures retain their full dimensions. Large animation banks are split
> into batches of at most 200 frames and eight million pixels, with all declared
> frames accessible; the extra FLC loop-closing frame is omitted. Previews use
> uniform file timing. Sprite sheets are shown whole; object extraction, script
> interpretation, character movement and scene compositing are not implemented.
> The misnamed `sk494.wav` developer message is shown as text.

> \* Pink Panther reads `PPTP.ORB` (Passport to Peril) and `HPP.ORB` (Hokus
> Pokus Pink), with matching companion BRO archives in the game root or `INSTALL`.
> Open `PINKPANTHER/Peligrosa` or `PINKPANTHER/Abracadabra`. Resources are grouped
> by archive page: indexed CEL stills and animations, PCM WAV/VOX audio and
> Windows-1252 text. The tested Spanish copies expose 14,820 resources in
> Passport to Peril and 11,146 in Hokus Pokus Pink. Original-media CEL size and
> VOX padding quirks are handled. Large animations are split into batches of at most 200 frames
> and eight million pixels; all frames remain accessible. Previews use the last
> decoded frame delay uniformly. Sprites retain their stored background colour;
> scene compositing, scripted playback, and SONGS.SON/ALLSONGS.PTP are not decoded.

> \* Les Manley 2 reads the resource directory from `EXE.EXE` alongside
> `DATA*.DAT` and `OOPS.OOP`. The tested Spanish release exposes 267 still
> pictures, 231 animation banks and 83 palettes. Scene palettes are selected by
> filename hash where available; unassigned resources permit manual palette
> selection. One picture (`DATAF.DAT` offset 502964) has an undecodable LZW
> stream and is listed as metadata. Audio and scripted scene playback are not
> implemented; animation previews use uniform 100 ms timing.
>
> \* El Tesoro de la Isla Alcachofa reads `TESORO.TRE` / `TESORO.DAT` directly:
> 2,012 images from the level, player and font banks, 112 image sequence previews,
> 2,346 PCM WAV clips, plus scripts and readable object metadata. Shadow masks
> display as grayscale. Previews use stored image order at 100 ms; game script
> timing, movement and scene compositing are not interpreted.

> \* Runaway reads loose files from the game root or its `RESOURCE` directory.
> The tested media folder exposes 70 backgrounds, 33,407 scene sprite frames,
> overlays/masks and 16 kHz PCM music, speech and effects. Animation previews use
> batches of up to 32 stored frames at 100 ms; scripted timing/compositing, Bink
> cutscenes and the shared `RESOURCE.000`-`.004` formats are not interpreted.
> Files still inside installer cabinets require extraction or an installed copy.

**Opening Runaway:** Click **Open Folder** and select the installed or prepared
parent folder containing `RESOURCE` and `DATAA`. Opening `RESOURCE` directly also
works; selecting the parent folder makes the speech directory easier to locate.
In the resource tree, expand **Opening Instructions** and select **How to open
this game** for the same instructions inside the app.

Installer media with `Cab/*.cab` can expose its loose files immediately, but
additional resources require one-time extraction. Extraction is not automatic.
Either install the game normally and open its installed folder, or install
**Python 3** and **cabextract** (both available in your terminal). From the
Adventure Explorer source folder containing `scripts/`, run this command,
replacing both example paths:

```sh
python3 scripts/prepare-runaway.py "/path/to/media" "/path/to/runaway-data"
```

Choose a new or empty output folder outside the source media. When preparation
finishes, click **Open Folder** and select `runaway-data`. Subsequent opens need
no preparation. Cabinet resources are extracted, while loose files are linked:
**keep the original media folder in place** so those links continue to work.
Bink cutscenes are not previewed.

> \* Capstone / Manley support covers the tested AMTAIL, BHB and LALAW releases.
> Fievel actor previews play stored frames in order at 100 ms; choose a scene palette
> for the intended colours. Scene/animation bytecode and BHB sound effects are decoded
> data previews; LA Law ABT speech is metadata only. Driver-encoded audio playback and
> scripted animation timing/compositing are not implemented.

> \* Prisoner of Ice scene graphics (`scn_*` resources) are exposed as metadata only; the
> scene picture/opcode stream is not decoded. `mus_ksound_*` entries are Miles
> `HMIMIDIP0131` modules exposed as metadata only, so they cannot be played back.

> \* Visionaire archives may be encrypted with a game-specific XOR key. Place a `vis.key` file
> in the game folder for encrypted games (format: `ID;Game Name;Key`, one entry per line).
> Unencrypted archives and archives shipped with known keys work without any extra setup.

> \* TsAGE (Ringworld, Blue Force) sound resources are scored Adlib/MIDI tracker data
> that require the game's own sound driver, so they are listed as metadata only and
> cannot be played back in the explorer.

> \* Noctropolis scene backgrounds decode from the DBE-compressed playfield tiles plus
> their 256-colour palette; `.SCN` full screens (title, deaths, comic pages) decode
> with their embedded palette. Character/interface sprite sets are exposed as frame
> animations; character sprites use the character palette stored in the same `.AP`
> and interface icons use the icon palette built into the executable. Sprite colours
> in-game also depend on the active room palette, and cell objects/sounds/music are
> not decoded yet.

> \* Dark Seed 2 exposes 83 room backgrounds, 3,660 sprite/UI images grouped by
> archive, 83 room thumbnails and 84 palettes in the tested release. Cropped
> scanline sprites use their room background's palette; shared walking/action
> sprites use `FIX.PAL`. Images with embedded palettes retain them, including
> the 4-bit inventory icon. Palettes can also be selected manually. Frames are
> shown individually; cropped areas use palette index 0 and animation playback
> is not yet available.
>
> \* Lure of the Temptress character sprites are stored as nibble-packed animation
> streams whose dimensions live in `lure.dat` (the engine support file in the game's
> own executable). That data is not part of the `.VGA` disk images, so sprites are not
> listed; screen backgrounds and their palettes decode fully.

Igor supports the verified Spanish floppy and CD releases. The explorer exposes
76 floppy and 75 CD room/scene backgrounds, including the beach ending and the
floppy-only math corridor, with available masks, walkbox areas and decoded text.
Both versions include three decoded telescope views, seven credit backgrounds
and five intertitles. Startup art uses each version's own resources: the floppy
Pendulo logo, title and title backdrop; the CD's four splashes and intro logo.
The floppy screen and palette offsets come from the current resource catalog,
rather than image scans or matches against CD artwork.

Both Igor outfits and the existing animation banks remain available (31 CD
and 10 floppy groups). Animation previews show frame banks at a uniform speed,
rather than replaying room scripts. Interface previews show the stored panels;
menu labels and other script-drawn content are not composited. CD audio includes
68 effects and 1,292 speech clips. Music preview is available for the floppy;
CD music uses separate audio tracks.

Generate a searchable local gallery of all 197 image previews (98 floppy,
99 CD, including interface panels) with:

```sh
python3 scripts/igor-gallery.py --floppy /path/to/IGOR --cd /path/to/IGOR-CD
```

Open `build/igor-gallery/index.html`. The generator requires Lua and Pillow and
also writes a contact sheet for each version. Validate without exporting with
`lua scripts/tests/igor.lua /path/to/game`.

## Building & Running

### Prerequisites

- **Java 17+** (JDK)
- **Gradle 8.5+** (or use the wrapper)

### Quick Start

```bash
# Install Gradle wrapper (first time)
gradle wrapper

# Build and run
./gradlew run
```

### Build Native Package

```bash
# macOS .dmg
./gradlew packageDmg

# Windows .msi
./gradlew packageMsi
```

## Running from a Binary Release

If you have a pre-built release (`.dmg`, `.msi`, or fat JAR), follow these steps:

### macOS (.dmg)

1. Open the `.dmg` file and drag **Adventure Explorer** to your Applications folder
2. Make sure the `scripts/` folder (containing engine Lua scripts) is located next to the application, or inside the app bundle's `Resources/` directory
3. Launch from Applications — if macOS blocks it, right-click → Open → Open

### Windows (.msi)

1. Run the `.msi` installer and follow the prompts
2. The `scripts/` folder is bundled inside the installation directory automatically
3. Launch from the Start Menu or desktop shortcut

### Fat JAR

If you have a standalone `.jar` file:

```bash
java -jar adventure-explorer.jar
```

The `scripts/` folder must be in the **working directory** (the folder you run the command from), or next to the JAR file.

### Requirements

- **Java 17+** runtime is required for the JAR distribution
- Native packages (`.dmg` / `.msi`) bundle their own JVM — no separate Java install needed
- The `scripts/engines/` folder must be accessible at runtime — this is where engine Lua scripts live

## Usage

1. Launch the application
2. Click **Open Folder** and select a game's data directory
   (e.g., the folder containing `ALFRED.1`, `JUEGO.EXE`, etc.)
3. The app auto-detects the game engine and populates the resource tree
4. Click on a resource to preview it
5. For animations: use the playback controls (play/pause, step forward/back, first/last frame)
6. Click **Export PNG** in the image preview to save the current image, or use the animation export buttons to save individual frames or the full sequence
7. Open the toolbar's **Export** menu and choose **Export all**, **Export selected folder**, or a category with its resource count. In the output folder dialog, choose **Resource tree path** to preserve the hierarchy or **Same folder** to place resources together (for example, all backgrounds in one folder). Choose **1× (original size)**, **2×**, or **3×** for PNG images and animation frames; scaling uses nearest-neighbor pixels and preserves transparency. Animations keep their own frame folders in either layout. Category exports omit unrelated branches. Background and sprite roles are inferred from engine folder labels and resource names/IDs; animations, images, sounds, MIDI, palettes, text, and data use explicit resource types. Categories can overlap: a sprite animation appears under both Sprites and Animations; Images (all) includes backgrounds and sprite stills.
8. Choose an output folder. Images use PNG, animations get numbered PNG frames with timing information, sounds use WAV, music uses MIDI, and text/metadata use TXT. Palettes include PNG swatches and RGB BIN files. Existing files are preserved by adding numbered suffixes; failed resources are listed in `export-errors.txt`. Click **Stop export** to stop after the current decode or file write; files already exported are kept.

### Toonstruck

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

## Writing Engine Scripts

Engine scripts live in `scripts/engines/<engine_id>/engine.lua`. Each script returns a table with:

```lua
local engine = {}

engine.name = "My Engine"
engine.id = "myengine"
engine.description = "Some Game (year)"

-- Called to check if a folder contains this game's files
function engine.detect(game_path)
    return file_exists(game_path .. "/GAME.DAT")
end

-- Return the resource tree structure
function engine.get_resources(game_path)
    return {
        {
            id = "backgrounds",
            name = "Backgrounds",
            type = "category",
            children = {
                { id = "bg_0", name = "Room 0", type = "image" },
                { id = "bg_1", name = "Room 1", type = "image" },
            }
        }
    }
end

-- Load a specific resource
function engine.load_resource(game_path, resource_id)
    -- Read files, decode data, create image
    local img = image_create_indexed(width, height, pixels, palette)
    return {
        type = "image",
        image = img,
        description = "Room background"
    }
end

return engine
```

### Lua API Reference

#### File I/O

| Function | Returns | Description |
|----------|---------|-------------|
| `file_exists(path)` | boolean | Check if file exists (case-insensitive) |
| `file_open(path)` | handle | Open file for reading |
| `file_close(handle)` | — | Close file |
| `file_size(handle)` | number | Get file size in bytes |
| `file_read(handle, offset, length)` | string | Read binary data (Lua string) |
| `list_files(path)` | table | List filenames in a directory |

#### Image Creation

| Function | Returns | Description |
|----------|---------|-------------|
| `image_create_indexed(w, h, pixels, palette)` | handle | Create image from indexed pixels + palette |
| `image_create_rgb(w, h, rgb_data)` | handle | Create image from RGB triplets |
| `image_load_png(data)` | handle | Load image from PNG binary data |

- `pixels`: Lua table (1-indexed), values 0–255 (color indices)
- `palette`: Lua table (1-indexed), 768 entries (R,G,B triplets, 0–255)
- `rgb_data`: Lua table (1-indexed), w×h×3 entries (R,G,B, 0–255)

#### Animation

| Function | Returns | Description |
|----------|---------|-------------|
| `animation_create(image_handles, delay_ms)` | handle | Create animation from a table of image handles |

- `image_handles`: Lua table of image handles (from `image_create_*` calls)
- `delay_ms`: Frame delay in milliseconds (default: 100)

#### Sound

| Function | Returns | Description |
|----------|---------|-------------|
| `sound_create_pcm(rate, bits, channels, signed, data)` | handle | Create playable raw PCM audio |
| `sound_create_gob_adl(data)` | handle | Render Coktel Vision ADL/OPL music to PCM |

#### MIDI

MIDI-family resources (CMF, XMIDI, standard MIDI) are converted to a standard MIDI
file rather than synthesized ourselves, so playback uses the system's own MIDI
device/instruments instead of an opinionated built-in synth.

| Function | Returns | Description |
|----------|---------|-------------|
| `midi_create_raw(data)` | handle | Wrap data that is already a standard MIDI file |
| `midi_create_from_cmf(data)` | handle | Convert Creative Music Format (CTMF) to standard MIDI |
| `midi_create_from_xmi(data)` | handle | Convert XMIDI (.xmi, IFF-wrapped or bare EVNT) to standard MIDI |
| `midi_create_auto(data)` | handle | Sniff the magic bytes and pick the right converter above |

#### Data Helpers

| Function | Returns | Description |
|----------|---------|-------------|
| `zlib_decompress(data)` | string | Decompress zlib-compressed data |
| `xor_bytes(data, key)` | string | XOR each byte of data with the key string (repeating) |

#### Logging

| Function | Description |
|----------|-------------|
| `log_info(msg)` | Informational message |
| `log_warn(msg)` | Warning |
| `log_error(msg)` | Error |

#### Binary Helpers (pure Lua)

Read little-endian values from a binary string (1-indexed):

```lua
local function u8(data, pos)    return data:byte(pos) end
local function u16le(data, pos) return data:byte(pos) + data:byte(pos+1) * 256 end
local function u32le(data, pos)
    return data:byte(pos) + data:byte(pos+1)*256 + data:byte(pos+2)*65536 + data:byte(pos+3)*16777216
end
```

## Architecture

```
adventure-explorer/
├── build.gradle.kts              # Compose Desktop build
├── settings.gradle.kts           # Gradle settings
├── scripts/
│   └── engines/                  # 57 engine scripts (Lua)
│       ├── agos/engine.lua       # Simon the Sorcerer 1 & 2
│       ├── anotherworld/engine.lua # Another World (original DOS)
│       ├── amazon/engine.lua      # Amazon: Guardians of Eden
│       ├── aitd/engine.lua       # Alone in the Dark series
│       ├── cine/engine.lua       # Future Wars / Operation Stealth
│       ├── city/engine.lua       # The City of Lost Children
│       ├── cobramission/         # Cobra Mission
│       ├── comet/engine.lua      # Shadow of the Comet
│       ├── cruise/engine.lua     # Cruise for a Corpse
│       ├── curseofenchantia/     # Curse of Enchantia
│       ├── universe/             # Universe
│       ├── darkseed/engine.lua   # Dark Seed
│       ├── darkseed2/engine.lua  # Dark Seed 2
│       ├── drascula/engine.lua   # Drascula: The Vampire Strikes Back
│       ├── fable/engine.lua      # Fable (original PC ARC1 resources)
│       ├── gob/engine.lua        # Gobliiins series
│       ├── capstone/engine.lua  # Fievel, Beverly Hillbillies, L.A. Law
│       ├── gxl/engine.lua        # Capstone Genus GXL (Wayne's World, The Dark Half)
│       ├── harvester/engine.lua  # Harvester
│       ├── hollywoodmonsters/    # Hollywood Monsters
│       ├── igor/engine.lua       # Igor: Objective Uikokahonia
│       ├── kyra1/engine.lua      # The Legend of Kyrandia
│       ├── kyra2/engine.lua      # Hand of Fate
│       ├── lastexpress/          # The Last Express
│       ├── lure/engine.lua       # Lure of the Temptress
│       ├── mads/engine.lua       # MicroProse MADS (Rex Nebular, Dragonsphere, Return of the Phantom)
│       ├── les2/engine.lua       # Les Manley 2: Lost in L.A.
│       ├── tesoro/engine.lua     # El Tesoro de la Isla Alcachofa
│       ├── orlando/engine.lua    # Jack Orlando (original PC)
│       ├── noctropolis/engine.lua # Noctropolis
│       ├── pelrock/engine.lua    # Alfred Pelrock
│       ├── runaway/engine.lua   # Runaway: A Road Adventure
│       ├── sci/engine.lua        # Sierra SCI (SCI0/SCI1/SCI1.1)
│       ├── saga/engine.lua       # I Have No Mouth, and I Must Scream
│       ├── scumm/engine.lua      # SCUMM V3 EGA / V5-V8 (+ scumm_v3/cost/snd/nut/util.lua modules)
│       ├── scummv2/engine.lua    # SCUMM V2
│       ├── sherlock/engine.lua   # Sherlock Holmes (Lost Files)
│       ├── sherlock2/engine.lua  # Sherlock Holmes (Consulting Detective)
│       ├── sky/engine.lua        # Beneath a Steel Sky
│       ├── sword1/engine.lua     # Broken Sword 1
│       ├── sword2/engine.lua     # Broken Sword 2
│       ├── tucker/engine.lua     # Bud Tucker in Double Trouble
│       ├── tinsel/engine.lua     # Discworld 1 & 2
│       ├── toltecs/engine.lua     # 3 Skulls of the Toltecs
│       ├── tot/engine.lua        # Trick or Treat
│       ├── toonstruck/engine.lua # Toonstruck
│       ├── tsage/engine.lua      # Ringworld & Blue Force (Tsunami/TsAGE)
│       ├── touche/engine.lua     # Touché
│       ├── riddle/               # The Riddle of Master Lu (M4 / HAG)
│       └── visionaire/           # Visionaire (Daedalic games)
└── src/main/kotlin/adventureexplorer/
    ├── Main.kt                   # Entry point
    ├── app/
    │   └── AppState.kt           # Reactive application state
    ├── model/
    │   ├── ResourceNode.kt       # Resource tree node
    │   ├── DetectionResult.kt    # Game detection result
    │   └── ResourceData.kt       # Loaded resource data
    ├── scripting/
    │   ├── LuaEngine.kt          # LuaJ wrapper + API registration
    │   └── ScriptManager.kt      # Script discovery + game detection
    └── ui/
        ├── App.kt                # Root UI composable
        ├── ResourceTreeView.kt   # Left panel tree view
        └── PreviewPane.kt        # Right panel preview
```

## Roadmap

- [x] Animation playback (sprite frames) with frame navigation and export
- [x] Sound/music preview and WAV export
- [x] Zoom for image and animation preview
- [ ] Sprite sheet viewer
- [x] More engine scripts (SCI, AITD, Harvester, Cobra Mission)
- [ ] Resource search/filter
- [x] Batch export
- [ ] Support for all scumm games
- [ ] Support for all Coktel games
- [x] Support for Capstone games (Genus GXL and Manley/Synergistic resource formats; driver audio remains metadata)
- [x] Support for Curse of Enchantia & Universe
- [ ] Support for The Neverhood
- [ ] Support for Sanitarium
- [x] Support for Microprose adventures
- [x] Support for Tsunami games
- [x] Support for Noctropolis


## License

MIT


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

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

64 game engines are currently supported via Lua scripts — no recompilation needed.

| Engine | Year | ID | Resources | Status |
|--------|------|----|-----------|--------|
| [3 Skulls of the Toltecs](engine-details.md#toltecs) | 1996 | `toltecs` | Backgrounds, Sprites, Palettes, Animations, Speech/Sound, Music, Data | ✅ Working* |
| [Una Aventura de Cine - Edición Especial](engine-details.md#alcachofa) | 2003 | `alcachofa` | Backgrounds, Sprites, Animation Previews, Masks, Speech/Sound, Text, Data | ✅ Working* |
| [Alfred Pelrock](engine-details.md#pelrock) | 1997 | `pelrock` | Backgrounds, Palettes, Text, Sprites | ✅ Working |
| [Amazon: Guardians of Eden](engine-details.md#amazon) | 1992 | `amazon` | Tiled Backgrounds, Screens, Sprites, Video Previews, Palettes, Sound, MIDI, Data | ✅ Working* |
| [Alone in the Dark series](engine-details.md#aitd) | 1992-95 | `aitd` | Backgrounds, 3D Models | ✅ Working |
| [Another World / Out of This World (DOS)](engine-details.md#anotherworld) | 1991 | `anotherworld` | Bitmaps, Polygon Artwork, VGA/EGA Palettes, Sound Samples, Scripts, Data | ✅ Working* |
| [Beneath a Steel Sky](engine-details.md#sky) | 1994 | `sky` | Backgrounds, Sprites (animated), Palettes | ✅ Working |
| [Broken Sword: Shadow of the Templars](engine-details.md#sword1) | 1996 | `sword1` | Backgrounds, Palettes, Sprites | ✅ Working |
| [Broken Sword II: The Smoking Mirror](engine-details.md#sword2) | 1997 | `sword2` | Backgrounds, Palettes, Sprites | ✅ Working |
| [Bud Tucker in Double Trouble](engine-details.md#tucker) | 1996 | `tucker` | Background Tiles, Sprite Sheets/Frames, Animation Previews, Inventory Sprites, Masks, Palettes, Speech, Sound, Music, Text, Data | ✅ Working* |
| [Bureau 13 / Hell: A Cyberpunk Thriller](engine-details.md#take2) | 1995/94 | `take2` | Backgrounds, Sprites, Palettes, FLC Previews (Hell), Dialogue (Bureau 13), WAV/VOC Speech and Sound, MIDI (Bureau 13), Data | ✅ Working* |
| [The City of Lost Children](engine-details.md#city) | 1997 | `city` | Backgrounds, Fonts, Texture Atlases/Crops, Depth Masks, Palettes, Speech, Sound Effects, Dialogue, Data | ✅ Working* |
| [Cobra Mission](engine-details.md#cobramission) | 1992 | `cobramission` | Backgrounds, Dialogue Scripts, Names/Messages/Credits, Sound | ✅ Working* |
| [Cruise for a Corpse](engine-details.md#cruise) | 1991 | `cruise` | Backgrounds, Sprite Frames, Polygon Actors, Palettes | ✅ Working |
| [Curse of Enchantia](engine-details.md#curseofenchantia) | 1992 | `curseofenchantia` | Backgrounds, sprites/character frames, screen animations, PCM effects, palettes | ✅ Working |
| [Dark Seed](engine-details.md#darkseed) | 1992 | `darkseed` | Backgrounds, Palettes, Sprites | ✅ Working |
| [Dark Seed 2](engine-details.md#darkseed2) | 1995 | `darkseed2` | Backgrounds, Sprites, UI, Room Thumbnails, Palettes | ✅ Working* |
| [Discworld 1 & 2](engine-details.md#tinsel) | 1995/96 | `tinsel` | Backgrounds, Sprites, Animations | ✅ Working |
| [Discworld Noir](engine-details.md#noir) | 1999 | `noir` | RGB565 Backgrounds/Screens, Sprites/Overlays, Music, Speech/Sound, Text, Scene Data | ✅ Working* |
| [Drascula: The Vampire Strikes Back](engine-details.md#drascula) | 1996 | `drascula` | Backgrounds, Object Sprites | ✅ Working |
| [DreamWeb](engine-details.md#dreamweb) | 1994 | `dreamweb` | Tiled Backgrounds, Sprites/UI, Fonts, Object Animations, PCX Titles, Palettes, PCM Sound/Music, CD Speech, Text, Data | ✅ Working* |
| [El Sulfato Atomico](engine-details.md#sulfato) | 1998 | `sulfato` | Backgrounds, Sprite Sheets, Palettes, FLC Animation Previews, Speech, Sound, Room Data | ✅ Working* |
| [El Tesoro de la Isla Alcachofa](engine-details.md#tesoro) | 2000 | `tesoro` | RGB565 Backgrounds, Sprites, Animation Previews, Shadow Masks, Speech, Scripts | ✅ Working* |
| [Fascination](engine-details.md#gob) | 1991 | `gob` | Backgrounds, Sprites, Palettes, AdLib Music, IMD Animation Clips | ✅ Working* |
| [Fable](engine-details.md#fable) | 1996 | `fable` | Backgrounds, Sprite Frames, Frame Bank Previews, Palettes, Dialogue, Speech, PCM Sound | ✅ Working* |
| [Fievel Goes West / An American Tail](engine-details.md#capstone) | 1993 | `capstone` | Pictures, Palettes, Sprites & Animation Previews, Scene Data | ✅ Working* |
| [Flight of the Amazon Queen](engine-details.md#queen) | 1995 | `queen` | Backgrounds, Sprites & Actor Banks (animated), Palettes | ✅ Working |
| [Future Wars / Operation Stealth](engine-details.md#cine) | 1989/90 | `cine` | Backgrounds, Sprite Frames, Palettes | ✅ Working |
| [Gobliiins / Gobliins 2 / Goblins Quest 3](engine-details.md#gob) | 1991-93 | `gob` | Backgrounds, Sprites, Palettes, Sound, Music | ✅ Working |
| [Grim Fandango](engine-details.md#grim) | 1998 | `grim` | RGB565 Bitmaps, Depth Masks, Textures, Palettes, Speech, Sound, Music, Dialogue, Scene Data | ✅ Working* |
| [Harvester](engine-details.md#harvester) | 1996 | `harvester` | Backgrounds, Sprites | ✅ Working |
| [Hollywood Monsters](engine-details.md#hollywoodmonsters) | 1997 | `hollywoodmonsters` | Backgrounds, Sprites, Palettes, Speech, Music, Sound | ✅ Working |
| [I Have No Mouth, and I Must Scream](engine-details.md#saga) | 1995 | `saga` | Backgrounds, Masks, Sprite Frames, Animation Previews, Palettes, Text, Speech, Sound, Music (XMI→MIDI), Data | ✅ Working* |
| [Igor: Objective Uikokahonia](engine-details.md#igor) | 1994 | `igor` | Backgrounds, Masks, Sprites, Animations, Text, Music, Sound Effects, Speech | ✅ Working |
| [Interspective (Innocent Until Caught, etc.)](engine-details.md#interspective) | 1993-96 | `interspective` | Backgrounds | ✅ Working |
| [Jack Orlando](engine-details.md#orlando) | 1997 | `orlando` | RGB565 Backgrounds, Packed Sprites, FLX Animation Previews, Palettes, Scripts, PCM Sound, Data | ✅ Working* |
| [L.A. Law: The Computer Game](engine-details.md#capstone) | 1992 | `capstone` | Images, ILBM Fonts/Cursors, Case Text, Music (XMI→MIDI), Speech Metadata | ✅ Working* |
| [Leather Goddesses of Phobos 2](engine-details.md#lgop2) | 1992 | `lgop2` | Backgrounds, Sound, Music | ✅ Working |
| [Les Manley 2: Lost in L.A.](engine-details.md#les2) | 1991 | `les2` | Scenes, Sprites, Animation Previews, Palettes, Text and Data | ✅ Working* |
| [Little Big Adventure 1 / Twinsen's Odyssey](engine-details.md#twine) | 1994/97 | `twine` | Isometric Scenery, Screens, Sprites, Bricks, LBA2 3D Models, Palettes, Dialogue, Speech, Effects, Music, Data | ✅ Working* |
| [Lure of the Temptress](engine-details.md#lure) | 1992 | `lure` | Screens, Palettes | ✅ Working* |
| [MicroProse MADS games (Return of the Phantom, Rex Nebular and the Cosmic Gender Bender, Dragonsphere)](engine-details.md#mads) | 1991-94 | `mads` | Backgrounds, Tiles, Sprites & Animations, Palettes, Fonts, Sound & Speech, Scene Data & Hex, Text | ✅ Working |
| [Noctropolis](engine-details.md#noctropolis) | 1994 | `noctropolis` | Backgrounds, Screens, Sprites | ✅ Working* |
| [Pink Panther: Passport to Peril / Hokus Pokus Pink](engine-details.md#pink) | 1996/98 | `pink` | CEL Backgrounds, Sprites & Animations, Speech, Sound, Music, Text | ✅ Working* |
| [Prisoner of Ice](engine-details.md#ice) | 1997 | `ice` | Backgrounds, Palettes, Dialogue Text, Sound Effects | ✅ Working* |
| [Ringworld: Revenge of the Patriarch / Blue Force](engine-details.md#tsage) | 1992-94 | `tsage` | Backgrounds, Palettes, Sprites & Animations, Messages, Sound metadata | ✅ Working* |
| [Ripley's Believe It or Not!: The Riddle of Master Lu](engine-details.md#riddle) | 1995 | `riddle` | Backgrounds, Palettes, Sprites & Animations, Sound/Speech, Music (HMP→MIDI), Attribute Codes, Fonts, Scene Definitions | ✅ Working |
| [Runaway: A Road Adventure](engine-details.md#runaway) | 2001 | `runaway` | RGB565 Backgrounds, Sprites & Animation Previews, Overlays, Masks, Music, Speech, Sound Effects, Data | ✅ Working* |
| [Sanitarium](engine-details.md#asylum) | 1998 | `asylum` | Backgrounds, Sprites/UI, Fonts, Aligned Animation Previews, Masks, Palettes, WAV Audio, Text, Data | ✅ Working* |
| [SCUMM V2 (Maniac Mansion, Zak McKracken)](engine-details.md#scummv2) | 1988-89 | `scummv2` | Backgrounds, object sprites, occlusion masks, object data, EGA palette | ✅ Working |
| [SCUMM V3 EGA (tested: Loom)](engine-details.md#scumm) | 1989-90 | `scumm` | Backgrounds, EGA Palette, Object & Actor Sprites, Costume Animations | ✅ Working* |
| [SCUMM V4 EGA (tested: Monkey Island)](engine-details.md#scumm) | 1990 | `scumm` | Backgrounds, EGA Palette, Object & Actor Sprites, Costume Animations | ✅ Working* |
| [SCUMM V5-V8 (Monkey Island 1-3, Atlantis, The Dig, Day of the Tentacle…)](engine-details.md#scumm) | 1990-97 | `scumm` | Backgrounds, Palettes, Object & Actor Sprites, Costume Animations, Fonts (NUT), Music (MIDI + digital iMUSE), Sound Effects, Speech | ✅ Working |
| [Shadow of the Comet](engine-details.md#comet) | 1993 | `comet` | Backgrounds, Palettes, Sprites, Animations, Sound | ✅ Working |
| [Sierra SCI (SCI0 EGA, SCI1 VGA, SCI1.1, SCI2/SCI32 — tested: Gabriel Knight 1, Larry 1 VGA, Larry 3, Larry 6, Larry 7, King's Quest 6, Laura Bow 2)](engine-details.md#sci) | 1988-96 | `sci` | Backgrounds, Sprites, Cursors, Fonts, Palettes, Texts | ✅ Working |
| [Simon the Sorcerer 1 & 2](engine-details.md#agos) | 1993/95 | `agos` | Backgrounds, Sprites, Animations, Inventory Icons, SFX, Speech, Music | ✅ Working |
| [Star Trek: 25th Anniversary / Judgment Rites (DOS)](engine-details.md#startrek) | 1992/93 | `startrek` | Backgrounds, Sprites, Animation Previews, Priority Masks, Palettes, Text, VOC Sound, XMIDI Music, Data | ✅ Working* |
| [The Beverly Hillbillies](engine-details.md#capstone) | 1993 | `capstone` | Backgrounds, Sprites, Palettes, Dialogue, Music (XMI→MIDI), Data | ✅ Working* |
| [The Last Express](engine-details.md#lastexpress) | 1997 | `lastexpress` | Backgrounds, Animations | ✅ Working |
| [The Legend of Kyrandia](engine-details.md#kyra1) | 1992 | `kyra1` | Backgrounds, Palettes, Animations | ✅ Working |
| [The Legend of Kyrandia: Hand of Fate](engine-details.md#kyra2) | 1993 | `kyra2` | Backgrounds, Palettes, Animations | ✅ Working |
| [The Lost Files of Sherlock Holmes: The Case of the Serrated Scalpel / The Case of the Rose Tattoo](engine-details.md#sherlock) | 1992/96 | `sherlock` | Backgrounds, Palettes, Object Sprites, Animations, Sound Effects, Speech | ✅ Working |
| [The Neverhood](engine-details.md#neverhood) | 1996 | `neverhood` | Bitmaps, Animations, Palettes, Sounds, Music, Text, Data, Videos | ✅ Working |
| [Toonstruck](engine-details.md#toonstruck) | 1996 | `toonstruck` | Backgrounds, Masks, Sprites & Animations, Palettes, Dialogue, Speech, Sound, Music, Data | ✅ Working* |
| [Touché: Adventures of the Fifth Musketeer](engine-details.md#touche) | 1995 | `touche` | Backgrounds, Palettes | ✅ Working |
| [Trick or Treat](engine-details.md#tot) | 1997 | `tot` | Backgrounds, Palettes, Objects | ✅ Working |
| [Universe](engine-details.md#universe) | 1994 | `universe` | Backgrounds, Palettes, Masks | ✅ Working |
| [Visionaire Engine (Daedalic games)](engine-details.md#visionaire) | 2005-15 | `visionaire` | Backgrounds (PNG), Game Data | ✅ Working* |
| [Wayne's World / The Dark Half (Capstone, Genus GXL)](engine-details.md#gxl) | 1993 | `gxl` | Images | ✅ Working |
| [Woodruff and the Schnibble of Azimuth](engine-details.md#gob) | 1994/95 | `gob` | Composed Backgrounds, Sprites, Palettes, Sound, Music, VMD Animation Clips and Soundtracks | ✅ Working* |

See [Engine details](engine-details.md) for opening instructions, resource coverage,
preparation steps and known limitations for each engine.

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

For game-specific setup, see [Engine details](engine-details.md). For model viewer
controls, see [3D model previews](engine-details.md#3d-model-previews).

## Writing Engine Scripts

When adding or changing an engine, update its support-table row above and its
[Engine details](engine-details.md) entry, including the folder and files needed to open it.

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
| `animation_create_coktel(data, first_frame, count [, width, height, palette])` | handle | Decode an indexed VMD/IMD clip; dimensions/palette select early Fascination IMD |

- `image_handles`: Lua table of image handles (from `image_create_*` calls)
- `delay_ms`: Frame delay in milliseconds (default: 100)

#### Sound

| Function | Returns | Description |
|----------|---------|-------------|
| `sound_create_pcm(rate, bits, channels, signed, data)` | handle | Create playable raw PCM audio |
| `sound_create_gob_adl(data)` | handle | Render Coktel Vision ADL/OPL music to PCM |
| `sound_create_gob_mdy(song, timbres)` | handle | Render MDY/TBR AdLib music to PCM |
| `sound_create_coktel_video(data)` | handle | Decode a Woodruff VMD soundtrack to PCM |

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
│   └── engines/                  # 64 engine scripts (Lua)
│       ├── agos/engine.lua       # Simon the Sorcerer 1 & 2
│       ├── anotherworld/engine.lua # Another World (original DOS)
│       ├── dreamweb/engine.lua    # DreamWeb (installed DOS floppy/CD data)
│       ├── asylum/engine.lua      # Sanitarium (Windows demo and retail CD 1)
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
│       ├── twine/engine.lua      # Little Big Adventure 1 & 2
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
│       ├── scumm/engine.lua      # SCUMM V3/V4 EGA / V5-V8 (+ scumm_v3/v4/cost/snd/nut/util.lua modules)
│       ├── scummv2/engine.lua    # SCUMM V2
│       ├── sherlock/engine.lua   # Sherlock Holmes (Lost Files)
│       ├── sky/engine.lua        # Beneath a Steel Sky
│       ├── startrek/engine.lua    # 25th Anniversary / Judgment Rites (DOS)
│       ├── sword1/engine.lua     # Broken Sword 1
│       ├── sword2/engine.lua     # Broken Sword 2
│       ├── tucker/engine.lua     # Bud Tucker in Double Trouble
│       ├── noir/engine.lua       # Discworld Noir (Tinsel 3)
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
- [x] Support for DreamWeb (full English UK CD resources)
- [x] Support for Sanitarium (Windows demo and retail CD 1 resources)
- [x] Support for Microprose adventures
- [x] Support for Tsunami games
- [x] Support for Noctropolis


## License

MIT

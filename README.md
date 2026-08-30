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

30 game engines are currently supported via Lua scripts — no recompilation needed.

| Engine | Year | ID | Resources | Status |
|--------|------|----|-----------|--------|
| Simon the Sorcerer 1 & 2 | 1993/95 | `agos` | Backgrounds | ✅ Working |
| Alone in the Dark series | 1992-95 | `aitd` | Backgrounds | ✅ Working |
| Future Wars / Operation Stealth | 1989/90 | `cine` | Backgrounds | ✅ Working |
| Shadow of the Comet | 1993 | `comet` | Backgrounds, Palettes, Sprites, Animations, Sound | ✅ Working |
| Cruise for a Corpse | 1991 | `cruise` | Backgrounds | ✅ Working |
| Cobra Mission | 1992 | `cobramission` | Backgrounds | ✅ Working |
| Dark Seed | 1992 | `darkseed` | Backgrounds, Palettes, Sprites | ✅ Working |
| Gobliiins / Gobliins 2 / Goblins Quest 3 | 1991-93 | `gob` | Backgrounds, Sound, Music | ✅ Working |
| Hollywood Monsters | 1997 | `hollywoodmonsters` | Backgrounds, Speech | ✅ Working |
| Harvester | 1996 | `harvester` | Backgrounds, Sprites | ✅ Working |
| Igor: Objective Uikokahonia | 1994 | `igor` | Backgrounds, Sprites, Animations | ✅ Working |
| Interspective (Innocent Until Caught, etc.) | 1993-96 | `interspective` | Backgrounds | ✅ Working |
| The Last Express | 1997 | `lastexpress` | Backgrounds, Animations | ✅ Working |
| The Legend of Kyrandia | 1992 | `kyra1` | Backgrounds, Palettes, Animations | ✅ Working |
| The Legend of Kyrandia: Hand of Fate | 1993 | `kyra2` | Backgrounds, Palettes, Animations | ✅ Working |
| Alfred Pelrock | 1997 | `pelrock` | Backgrounds, Palettes, Text, Sprites | ✅ Working |
| SCUMM V5 (Monkey Island 2, Indiana Jones 4…) | 1991-93 | `scumm` | Backgrounds, Palettes | ✅ Working |
| SCUMM V2 (Maniac Mansion, Zak McKracken) | 1988-89 | `scummv2` | Backgrounds | ✅ Working |
| The Lost Files of Sherlock Holmes | 1992/96 | `sherlock` | Backgrounds, Palettes | ✅ Working |
| Sherlock Holmes: Consulting Detective | 1991-93 | `sherlock2` | Backgrounds, Animations | ✅ Working |
| Broken Sword: Shadow of the Templars | 1996 | `sword1` | Backgrounds, Palettes, Sprites | ✅ Working |
| Broken Sword II: The Smoking Mirror | 1997 | `sword2` | Backgrounds, Palettes, Sprites | ✅ Working |
| Discworld 1 & 2 | 1995/96 | `tinsel` | Backgrounds | ✅ Working |
| Trick or Treat | 1997 | `tot` | Backgrounds, Palettes, Objects | ✅ Working |
| Toonstruck | 1996 | `toonstruck` | Images | ✅ Working |
| Touché: Adventures of the Fifth Musketeer | 1995 | `touche` | Backgrounds, Palettes | ✅ Working |
| Leather Goddesses of Phobos 2 | 1992 | `lgop2` | Backgrounds, Sound | ✅ Working |
| Flight of the Amazon Queen | 1995 | `queen` | Backgrounds | ✅ Working |
| Sierra SCI (SCI0/SCI1/SCI1.1) | 1988-96 | `sci` | Backgrounds, Sprites, Cursors, Palettes | ✅ Working |
| Visionaire Engine (Daedalic games) | 2005-15 | `visionaire` | Backgrounds (PNG), Game Data | ✅ Working* |

> \* Visionaire archives may be encrypted with a game-specific XOR key. Place a `vis.key` file
> in the game folder for encrypted games (format: `ID;Game Name;Key`, one entry per line).
> Unencrypted archives and archives shipped with known keys work without any extra setup.

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
6. Click **Export PNG** to save the current preview, or use the animation export buttons to save individual frames or the full sequence

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
│   └── engines/                  # 27 engine scripts (Lua)
│       ├── agos/engine.lua       # Simon the Sorcerer 1 & 2
│       ├── aitd/engine.lua       # Alone in the Dark series
│       ├── cine/engine.lua       # Future Wars / Operation Stealth
│       ├── cobramission/         # Cobra Mission
│       ├── comet/engine.lua      # Shadow of the Comet
│       ├── cruise/engine.lua     # Cruise for a Corpse
│       ├── darkseed/engine.lua   # Dark Seed
│       ├── gob/engine.lua        # Gobliiins series
│       ├── harvester/engine.lua  # Harvester
│       ├── hollywoodmonsters/    # Hollywood Monsters
│       ├── igor/engine.lua       # Igor: Objective Uikokahonia
│       ├── kyra1/engine.lua      # The Legend of Kyrandia
│       ├── kyra2/engine.lua      # Hand of Fate
│       ├── lastexpress/          # The Last Express
│       ├── pelrock/engine.lua    # Alfred Pelrock
│       ├── scumm/engine.lua      # SCUMM V5
│       ├── sci/engine.lua        # Sierra SCI (SCI0)
│       ├── scumm/engine.lua      # SCUMM V5
│       ├── scummv2/engine.lua    # SCUMM V2
│       ├── sherlock/engine.lua   # Sherlock Holmes (Lost Files)
│       ├── sherlock2/engine.lua  # Sherlock Holmes (Consulting Detective)
│       ├── sword1/engine.lua     # Broken Sword 1
│       ├── sword2/engine.lua     # Broken Sword 2
│       ├── tinsel/engine.lua     # Discworld 1 & 2
│       ├── tot/engine.lua        # Trick or Treat
│       ├── toonstruck/engine.lua # Toonstruck
│       ├── touche/engine.lua     # Touché
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
- [ ] Batch export

## License

MIT

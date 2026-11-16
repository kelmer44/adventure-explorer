# Third-party code and credits

Adventure Explorer is free software, released under the **GNU General Public License, version 3 or (at your
option) any later version** (see `LICENSE`). It contains ports of, and is derived from, the projects below.
Their copyright notices stay in the source files; do not remove them. The program is distributed in the hope
that it will be useful, but WITHOUT ANY WARRANTY; see the GPL for details. The complete corresponding source
is this repository.

## ScummVM (GPL-2.0-or-later / GPL-3.0-or-later)

Copyright (C) the ScummVM Team. https://www.scummvm.org - https://github.com/scummvm/scummvm

### Kotlin ports

| File | Derived from |
|---|---|
| `audio/imuse/ImuseSequencer.kt`, `ImuseSong.kt`, `ImuseDevice.kt`, `JavaMidiDevice.kt` | iMUSE player, parts and SysEx handler: `engines/scumm/imuse/imuse_player.cpp`, `imuse_part.cpp`, `sysex_scumm.cpp` (GPLv2+), plus the timing and jump parts of `MidiParser` and the `MidiDriver` interface |
| `audio/imuse/AdlibOplDevice.kt`, `audio/MidiOplRenderer.kt` | `MidiDriver_ADLIB`, `audio/adlib.cpp` (GPLv2+), and its General MIDI FM bank |
| `audio/ScummAdPlayer.kt` | `Player_AD`, `engines/scumm/players/player_ad.cpp` (GPLv3+) |
| `audio/CmfOplDevice.kt` | register layout of `engines/igor/midi.cpp` (GPLv3+) |
| `audio/ImuseBundleCodecs.kt` | `BundleCodecs::decompressCodec`, `engines/scumm/imuse_digi/dimuse_codecs.cpp` |
| `audio/GobAdlDecoder.kt` | Gob `AdLib` class, `engines/gob/sound/adlib.cpp` (GPLv2+) |
| `audio/CryoApc.kt` | Cryo APC decoder, `audio/decoders/apc.cpp` (GPLv2+) |
| `graphics/CryoHnm6.kt` | HNM6 warp image decoder, `image/codecs/hnm.cpp` and `engines/cryomni3d/image/hnm.cpp` (GPLv2+) |
| `audio/LastExpressAdpcm.kt`, `audio/GmfToMidiConverter.kt`, `video/CoktelVideoDecoder.kt`, `models/GrimModelDecoder.kt` | format references: Last Express mixer, AGOS GMF parser, Coktel video decoder, Grim model loader |

### Engine scripts (`scripts/engines/`)

The engine scripts are written against ScummVM's engine sources, which document the file formats of the
games. Where a script ports an algorithm (decompressors, image and sprite decoders, music and sound
converters, script/text parsers) it is a derivative work of ScummVM and is covered by the same GPL. Each
such script says so in its header or next to the ported function. Notably:

| File | Derived from |
|---|---|
| `sci/engine.lua` | `engines/sci/resource/` (resource maps, volumes, `DecompressorLZW`, `DecompressorHuffman`, `DecompressorLZS`, DCL), `engines/sci/graphics/` (pictures, views, palettes, fonts, cursors) and the sound resource handling of `engines/sci/sound/` (track layout, device ids, event stream and timing). The MT-32 to General MIDI instrument table is original work from the Roland timbre list |
| other `*/engine.lua`, `scumm/*.lua`, `shared/westwood.lua`, `sky/*.lua`, ... | the corresponding ScummVM engines; see each file |

ScummVM data files (such as `lure.dat`) are not distributed with this program.

## Nuked OPL3 (LGPL-2.1-or-later)

`audio/Opl3.kt` is a Kotlin port of Nuked OPL3 1.8. Copyright (C) 2013-2018 Alexey Khokholov (Nuke.YKT).
https://github.com/nukeykt/Nuked-OPL3. Used and distributed here under the terms of the GPL, which the LGPL
permits.

## Libraries (not modified, linked at build time)

| Library | Licence |
|---|---|
| Kotlin standard library, kotlinx.coroutines | Apache-2.0 |
| JetBrains Compose Multiplatform (Desktop, Material), Skiko / Skia | Apache-2.0 / BSD-3-Clause |
| LuaJ (`luaj-jse`) | MIT |
| JLayer (`javazoom:jlayer`) | LGPL |

Apache-2.0 is compatible with GPL version 3, which is why the project is GPL-3.0-or-later and not GPL-2.0-only.

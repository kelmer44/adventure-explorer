# El Tesoro de la Isla Alcachofa (TESORO) — Reverse-Engineering Handoff

## Implementation update (2026-10-16)

The image blocker described below has been resolved. The new `tesoro` engine
loads all 2,012 images and 2,346 PCM WAV clips in the supplied data, with 112
image sequence previews, script text and readable metadata.

**Corrections to the historical analysis below:** TRE has NO 8-byte header.
It contains 2421 complete 28-byte records: u32 DAT offset, u32 payload size,
u8 flag, name[19]. Starting at byte 8 paired each name with the NEXT record's
resource, making fonts appear empty and mislabelling room/player data. Resources
have a 4-byte size prefix excluded from the indexed payload size.
ANM has a 24-byte header after its magic; frame records are 24 bytes plus the
u16 extra-data length at +22. Image buffers contain RGB565 spans: row tables
point to (pixel offset/colour, relative x skip, pixel count) records. Skips are
relative to the END of the previous span. Types 1/3 are literal/solid colour;
type 2 is a shadow mask. LVL banks are sequential, with count at magic +8.
See `engine-sources.md` and `scripts/tests/tesoro.lua` for exact layouts.

Original script timing and scene compositing remain unsupported. The historical
investigation below is retained, but its blocked status, resource names/offsets
and container-layout claims are superseded by this update.


Status: **container fully cracked; image format still unknown.** The `.TRE`
index and the `.DAT` resource pool have been fully decoded, all resource names
and offsets are recoverable, and the script/dialogue format is understood. The
**pixel format inside `.LVL` / `.ANM` is not yet decoded** (16-bit RGB565 is the
leading hypothesis). This document captures everything so a fresh agent (or the
user) can continue without re-doing the work.

Last updated: 2026-10-16.

---

## 1. Goal

Add a `tesoro` engine to `adventure-explorer` (Kotlin/Compose resource browser).
Engines are pure-Lua scripts at `scripts/engines/<name>/engine.lua`; no Kotlin
recompile is needed (`ScriptManager.kt` discovers them). Noctropolis is done and
is the style reference. TESORO needs from-scratch RE.

## 2. Game facts

- **"El Tesoro de la Isla Alcachofa"**, Alcachofa Soft (Spain), Windows
  **DirectX** game, ~2000 (`TESORO.EXE` PE timestamp 975603075 ≈ 2000-11).
- Runs on Windows 95/98; CD-based. Spanish abandonware; discussed at
  `https://www.abandonsocios.org/index.php?topic=19163.0` (a prepared copy is
  linked there). Main character is **"Jim"**; goal is the treasure of "Isla
  Alcachofa".
- The same **Alcachofa Soft engine** also powers their *Mortadelo y Filemón*
  and *Dráscula: El Dominio del Ocaso* — cracking this format likely unlocks
  those games too. (The user also has a `DRASCULA` title in `~/Desktop/ags`.)
- Game dir: `/Users/gabriel/Desktop/ags/TESORO`.

Files:

| File | Size | Notes |
|---|---|---|
| `TESORO.TRE` | 67788 | **index**: 8-byte header + N×28-byte records |
| `TESORO.DAT` | 263612966 | **resource pool**: concatenation of all resources |
| `TESORO.EXE` | 200192 | **PE32 GUI i386** (DirectDraw/DInput/DSound) |

`TESORO.EXE` is a normal PE32, 5 sections (`.text .rdata .data .idata .rsrc`),
imports `DDRAW.dll DINPUT.dll DSOUND.dll GDI32.dll KERNEL32.dll ole32.dll`,
uses `GetVersion`. No palette found in the EXE.

---

## 2b. Files / artifacts

- Game data: `/Users/gabriel/Desktop/ags/TESORO/`
- Extracted scripts: `/tmp/tesoro/` (`anims.txt`, `convers.txt`, `icons.txt`,
  `objetos.txt`, `anims.dlg`, `Convers.dlg`, `Icons.dlg`, `objetos.dlg`,
  `Tabla1.tbl`)
- Rendered test PNGs (unverified, may be wrong geometry):
  `/tmp/tesoro/jim_W320.png` etc.

---

## 3. Environment / tooling

- **Python 3** + **Pillow** for data analysis.
- **Lua 5.5** at `/opt/homebrew/bin/lua` (+ `luac`) for engine tests.
- **Ghidra 11.4.2**: `/opt/homebrew/Caskroom/ghidra/11.4.2-20250826/ghidra_11.4.2_PUBLIC`
- **DOSBox-X** at `/opt/homebrew/bin/dosbox-x` — **not useful here** (this is a
  Windows/DirectX game, not DOS). For dynamic analysis you'd need **Wine**
  (installed? check `which wine`), 86Box/PCem with Win95, or an actual VM. A
  debugger (x64dbg/Wine + winedbg) would let you dump decoded surfaces.
- No public documentation of the engine/format exists.

---

## 4. `TESORO.TRE` — index format (SOLVED)

- **8-byte header**, then **28-byte records** until EOF. 2420 records total.
- Record layout:

  ```
  +0x00  u8   type      1=root, 3=folder, 6=file, 4=other
  +0x01  char name[]    null-terminated (<=15 bytes, fits in the 28-byte record)
  +0x10  u32  A         usually 0; purpose unknown (maybe a "sub-resource" id)
  +0x14  u32  B         offset into TESORO.DAT
  +0x18  u32  C         size in TESORO.DAT
  ```

- Record counts: types `{1:2, 3:3, 4:3, 6:2412}`.
- Extensions: `wav:2345, lvl:50, anm:10, txt:4, dlg:4, tbl:1, an:1, none:5`.
- **Verified consistent**: no overlap between (offset,size) ranges and
  `max_end = 263598259` ≈ DAT size `263612966`.
- Top-level folders: `Raiz` (off 4039717 sz 72365), `Niveles` (LVL files),
  `Jim` (off 3639493 sz 400220, the `.ANM` animation set), `Sonidos` (WAVs),
  `Textos` (off 263598263 sz 14699).
- Records with offset 0 and size 0 are dead entries (`FUENTES.anm`,
  `JIMQUIETO.anm`, `objetos.txt`, `Tabla1.tbl`). DAT offset 0 is genuinely used
  by the first real resource (`JIMIZQUIERDA.anm`).

Reference parser (Python):

```python
import struct
t = open("TESORO.TRE","rb").read()
i = 8
while i+28 <= len(t):
    typ = t[i]
    j = i+1
    while t[j] != 0: j += 1
    name = t[i+1:j].decode('latin1')
    a, off, size = struct.unpack("<III", t[i+0x10:i+0x1c])
    print(typ, name, off, size)
    i += 28
```

## 4b. `TESORO.DAT`

Pure concatenation of resource bytes indexed by the TRE. Starts at offset 0
with `JIMIZQUIERDA.anm`. Contains RIFF/WAVE audio (2345 files), `.lvl` level
files, `.anm`/`.an` sprite animations (16-bit, see §5), and text.

Resource inventory (from DAT scanning): `ANM\x01`=402, `LVL\x01`=51, `RIFF`=2358,
`BM`=3113, `RLE`=280, `BMP`=25, `ANIM`=25, `TABL`=11, `PAL`=38. Most
`BM`/`PAL`/`RLE`/`ANIM` hits are **coincidental byte patterns** (same lesson as
LES2's ILBM red herring) — validate before trusting.

---

## 5. `LVL` and `ANM` — image/level format (PARTIAL)

Both `.lvl` and `.anm` begin with a `u32` size followed by a 4-byte magic:

- `.lvl` magic = `"LVL\x01"`, `.anm`/`.an` magic = `"ANM\x01"`.
- **`.lvl` embeds one or more `ANM\x01` blocks** (the backgrounds + sprites),
  plus an object/dialogue table.

### 5.1 Header examples

`1.lvl` (off 4960116, size 661320), first 24 bytes:

```
48 17 0a 00 | 4c 56 4c 01 | 01 00 00 00 | 02 00 00 00 | 06 00 00 00 | 41 4e 4d 01
u32=661320    "LVL\x01"      1             2             6            "ANM\x01"
```

`Almacen2.lvl` (off 18523601, size 10817), first 24 bytes:

```
2a 35 00 00 | 4c 56 4c 01 | 01 00 00 00 | 01 00 00 00 | 06 00 00 00 | 41 4e 4d 01
u32=13610     "LVL\x01"      1             1             6            "ANM\x01"
```

- First `u32` looks like an **uncompressed size**: equals the file size for
  `1.lvl` (661320) but is `13610` for `Almacen2.lvl` (file 10817). **Not yet
  reconciled** — possibly the size field is post-decompression, or a checksum.
- The three `u32`s after the magic are `1/2/6`, `1/1/6` — the last is `6` in
  both; likely object/layer counts or version fields.
- `JIMIZQUIERDA.anm` header: `u32` size `163630`, `"ANM\x01"`, then `4, 4`
  (frame/direction counts?), then 16 zero bytes, then behavior/metadata bytes.

### 5.2 `LVL` object table (readable — good news)

After the embedded image data, `.lvl` files contain an **object/property table**
of plain (Latin-1) strings. Example from `Almacen2.lvl`:

```
ROOM  ED004
CANDADO, CANDABIERTO, PALERO, TABLONES, ANIMJIM, ANIMCUERDA
UNNAMED001 .. UNNAMED014  (placeholder object names)
OBJ125T07, OBJ125T09, ... (dialogue/text ids -> object NNN text TT)
Clase->SubClase, Naturaleza, Jim|Posicion, Jim|Orientacion,
objeto->Nombre, Textos|Texto
```

Note the strings appear **truncated/split at fixed record boundaries**
(`Natur`, `ubClase->Su`, `os Jim|Posi`, `y orientaci`), which means the records
are a **fixed-size serialized object list** with a known field vocabulary
(`Clase`, `SubClase`, `Jim|Posicion`, `Orientacion`, `objeto->Nombre`,
`Textos|Texto`). This table is directly extractable and useful for the browser
even before images work.

### 5.3 The embedded ANM (image) layout — UNRESOLVED

`JIMIZQUIERDA.anm` (163630 bytes) after its 0x94-byte header contains a table of
**8-byte `(u32 a, u32 b)` records** starting at `0x94`, where `a ∈ {1,2,3,4}`
and `b` increases contiguously by `8*`(previous `a`):

```
0x94: a=1 b=0x940    0x9c: a=1 b=0x948    0xa4: a=2 b=0x958
0xac: a=1 b=0x960    ...    0x124: a=2 b=0x9e0   ...
```

This runs ~277 entries up to `b≈0x940` and looks like a **block/chunk directory**
(a = number of 8-byte blocks, b = offset into the file). Whether it is a
per-scanline span table, a decompression chunk table, or a heap/allocation trace
is **unknown**.

The raw data has the statistical fingerprint of a **16-bit colour bitmap**:

- Per-byte entropy ~4.3–6.1 (well below random 8.0), limited distinct values.
- A region near the end of `JIMIZQUIERDA.anm` decodes as a **perfect 6-bit
  grayscale ramp** in RGB565: u16 values `0x1082, 0x18c3, 0x2945, 0x3186,
  0x39c7, 0x4208, 0x4a49, 0x528a …` (constant step `0x0841`). That is the
  RGB565 encoding of a smooth greyscale gradient → strong evidence the payload
  is **16-bit RGB565 pixels** (matching the 2002 Alcachofa interview: art was
  "digitalizado a 16 bits de color").
- However, naive raw renders at widths 160/320/640 give a flat autocorrelation
  score, and the strongest non-trivial autocorrelation peak is at **~76 pixels**
  (weak). So the pixels are **not** a simple linear `width×height` block; there
  is likely an RLE/span/block encoding, or a per-row header, hinted at by the
  `(count, offset)` table.
- **No 6-bit VGA palette** exists (it's 16-bit direct colour), so "find the
  palette" is a dead end — do not chase it.

### 5.4 `LVL` first-frame metadata

`1.lvl` embeds `ANM\x01` at file-relative offsets `20` and `660573` (two images:
background + an overlay). `1.lvl` head after the magics includes `c3 ff 1a 01`
(=-61,282), `01 00 0b 00`, `2a 00 00 00`, and repeats of `c3 ff 1a 01`,
`c7 ff 16 01`, `cb ff 14 01` — plausibly **per-frame placement rects / deltas**
(x,y,w,h style), but not confirmed.

---

## 6. Script / dialogue format (`.TXT` source, `.DLG` compiled)

Both a source `.txt` and a compiled `.dlg` ship for the console/dialogue logic:

| Source | Compiled | Size (.txt / .dlg) |
|---|---|---|
| `anims.txt` | `anims.dlg` | 26057 / 26292 |
| `convers.txt` | `Convers.dlg` | 13958 / 70863 |
| `icons.txt` | `Icons.dlg` | 30103 / 31213 |
| `objetos.txt` | `objetos.dlg` | 0 / 59268 |
| `Tabla1.tbl` | — | 0 |

The `.txt` files are a small **scripting language** (labels + commands):

```
_main:
  menu
  menuitem0 next
  break
  return
  jmp <label>
  run <script>
  sendmessage ...
  if v2==0 jmp <label>
```

- Labels start `_` (e.g. `_main`); variables are `v0..vN`.
- Dialogue/line references look like `CNV01T02`, `ICON01T007`, `OBJ125T09`
  (conversation/icon/object + text number) and correspond to `.WAV` assets,
  e.g. `icon01t007.wav` in `Sonidos`.
- `objetos.txt` and `Tabla1.tbl` are empty (0 bytes) — unused/placeholder.

---

## 6b. Static analysis of `TESORO.EXE` (Ghidra, 537 functions) — SOLVED core

Full decompilation written to `/tmp/tesoro/decomp.c` (27.7k lines). Headless
run:
```bash
GH=/opt/homebrew/Caskroom/ghidra/11.4.2-20250826/ghidra_11.4.2_PUBLIC
mkdir -p /tmp/tesorogh
"$GH/support/analyzeHeadless" /tmp/tesorogh TESORO \
  -import ~/Desktop/ags/TESORO/TESORO.EXE \
  -scriptPath /tmp/ghscripts -postScript tesoro_decomp.py -deleteProject
```
Engine is **custom Alcachofa Soft** (confirmed: same studio as the Mortadelo
games; `MOS`/`alcachofa` ScummVM engine is the later descendant — TESORO's
`ANM\x01`/`LVL\x01` magics are *not* ScummVM's `ANI`/`AN0`, and no
`ImageV1` span header matched, so TESORO predates it).

### Archive / index API (maps 1:1 to §4)
- `FUN_00403250(this, "Tesoro.DAT", "Tesoro.TRE")` — opens the `.TRE` index,
  parses it (`FUN_00403380`), closes it, then opens `Tesoro.DAT` for data and
  keeps the handle at `this+4`.
- `FUN_00403380` — reads `0x1c` (28) byte index records; keeps the ones whose
  flag byte has bit `4`; copies ≤`0x13` (19) byte name + data offset into an
  in-memory array of `0x18`-byte entries, then sorts it in place (comparison is
  plain ASCII `strcmp`). Global index base = `DAT_00442068`.
- `FUN_00403500(idx, name, report)` — **binary search** the sorted names →
  returns the resource data offset (or `-1`); `report=1` pops a MessageBox on
  miss. This is the single "get resource" entry point.
- File primitives: `FUN_0041b7a0`=fopen, `FUN_0041b7c0`=fclose,
  `FUN_0041b4c0`=fread(buf,size,count), `FUN_0041b490`=tell, `FUN_0041b3f0`=seek,
  `FUN_004032e0`/`00403300`/`00403320` = seek/tell/seek wrappers on the DAT handle.
- **Resource block layout:** `[u32 size][payload…]`. Loaders do `seek(offset+4)`
  to skip the size word.

### `FUN_00401160` — generic sprite-bank / animation / font loader
Called as `FUN_00401160(obj, resOffset, allocTag, mode)` (mode `2` = index only,
lazy pixel load; `0` = decode eagerly). Used for `FUENTES.ANM` (fonts, line
13997) and all player `JIM*.ANM` (line 4717).
- `seek(resOffset+4)`; read a **`0x18`-byte header**:
  - `u16 countA` → `obj+0x22` (frame/entry count)
  - `u16 countB` → `obj+0x20` (image/sprite count)
  - `u32, u32, u32`   → `obj+0x32/0x36/0x3a`
  - `u8 flag`         → `obj+0x18 |= flag==1 ? 8 : 0`
- allocs: `countB×4` (offsets), `countB×4` (decoded images), `countA×0x24`
  (frame records).
- **frame record = `0x18` bytes** into a `0x24`-byte in-memory slot;
  `switch(rect.type)` handles 0/1 (static), 2 (linear motion over N keyframes),
  4 (keyframes + extra array). Fields include `x,y` (int16) and a per-frame
  `tw`/position used for interpolation.
- then for each of `countB` images: record `tell()` in `obj+4[i]`; if mode==2
  skip `u32 size` bytes, else decode via `FUN_004015a0`.
- finally normalizes frame offsets relative to frame 0.

### `FUN_004015a0` — image (span bitmap) decoder
- reads `u32 size`, allocs, `fread`s the block.
- **pixel data offset = first u32 of the block** (`*(u32*)buf`), pixels live at
  `buf + thatOffset`.
- applies 16-bit colour conversion (`DAT_00442108+0x67c` selects RGB555↔RGB565
  path), then walks **span runs** `(ptr, count)` rewriting pixels — i.e. the
  in-block image is a **span/segment bitmap** (same *shape* as ScummVM
  `ImageV1`, different header/magic).
- `FUN_00401010` builds a 32-entry + 2048-entry lookup table and remaps 16-bit
  pixels (quantise/expand), confirming packed 16-bit source.

### Player + room loading
- `FUN_004070c0` (player init) hardcodes the animation name list:
  `JIMHABDER.ANM, JIMQUIETO.ANM, JIMARRIBA.ANM, JIMABAJO.ANM, JIMIZQUIERDA.ANM,
  JIMDERECHA.ANM, JIMHABIZ.ANM, JIMHABAR.ANM, …`, `0x14`-byte stride, each loaded
  via `FUN_00403500`→`FUN_00401160(mode=2)`. Alloc slot `0x24`.
- Room/scene loader (≈line 13983): `Tesoro.DAT`+`Tesoro.TRE`, `TABLA1.TBL`,
  `FUENTES.ANM`, `OBJETOS.TXT` (names on a `0xf` (15)-byte stride),
  `INTERFACE.LVL`, `CUBIERTA.LVL`, `MAPA.LVL`, `DESPACHO*.LVL`, `PRINCIPAL.LVL`,
  `NUEVO.LVL` — level filenames are **fixed 15-byte records**.

### Remaining ambiguity
The header read at `resOffset+4` yields `countA=4,countB=0` for `JIMIZQUIERDA`
under the literal index offset, which does not line up with the 295-frame /
528-sprite table found in the blob — the exact `+4`/magic-skip and the
countA/countB roles need one validation run (see §7). But every field's location
is now known; this is arithmetic, not a format mystery.

---

## 7. Recommended next steps

**Priority A — view a candidate decode (cheapest unblock).** A human (or a
vision-capable model) should look at `/tmp/tesoro/jim_W320.png` and friends, or
render fresh candidates. Because the payload is 16-bit RGB565, once the right
geometry/encoding is found the image will snap into focus. Generate a grid of
candidate `(start_offset, width, [raw | per-row-size-prefixed])` PNGs and pick
the one that looks like a character/room.

**Priority B — dynamic analysis (most reliable).**
1. Run the game under **Wine** (`wine TESORO.EXE`) or a Win95 VM, ideally with
   the original CD.
- Use a debugger to break after the DirectDraw blit and dump the decoded
  surface (`Lock`ed surface = `width×height` RGB565). Two or three captured
  frames pin down the exact decode.
- Or use Wine's `+d3d`/DDraw tracing, or hook `IDirectDrawSurface::Lock`.

**Priority B2 — get the Mortadelo/Dráscula games.** They use the same engine and
may ship uncompressed assets or extra tooling/documentation that reveals the
format.

**Priority C — static RE. ✅ DONE (see §6b).** The loader (`FUN_00401160`),
image decoder (`FUN_004015a0`) and archive API are fully mapped. Remaining work
is validating the header counts: take `resOffset` from `FUN_00403500`, compute
the exact byte where the `0x18` header begins (test `+0`/`+4`/`+8`), and confirm
`countA`/`countB` against the 295-frame / 528-sprite blob. Then render one span
bitmap with the reconstructed colours.
- The `(a,b)` table at `0x94` in `JIMIZQUIERDA.anm` is the **frame table**: 295
  entries `(countA_i, offset_i)` where `offset_{i+1}-offset_i = 8*countA_{i+1}`
  (holds 294/294). `sum(countA)=528` 8-byte sprite records starting at `0x940`
  (base = first offset = `0x940`).
- Try RLE/span hypotheses on the 16-bit payload (live runs, delta runs,
  per-row `(count,offset)` spans) and score by 2-D coherence against random.
- Disassemble the `.EXE` (it's plain PE32) and find the loader/drawer: look for
  `DirectDrawSurface::Lock`/`Blt`, and the routine that walks `TESORO.TRE`.
  Imports are in `.idata`; `GetVersion`, `DDRAW`, `DSOUND` give anchors.

**Priority D — ship a partial engine** (works even if images stay blocked):
- `scripts/engines/tesoro/engine.lua` that `detect()`s the game (presence of
  `TESORO.TRE` + `TESORO.DAT` + `TESORO.EXE`) and:
  - parses `TESORO.TRE` and lists the resource tree (names, sizes);
  - extracts/plays `Sonidos/*.wav`;
  - dumps the `.lvl` object tables and `.txt`/`.dlg` scripts as text.
  Extend with images later.

---

## 7. Repo integration reminders (for whoever finishes it)

- Engine script: `scripts/engines/tesoro/engine.lua` (style ref:
  `scripts/engines/noctropolis/engine.lua`).
- Test: `scripts/tests/tesoro.lua`, run with `/opt/homebrew/bin/lua`. Follow the
  upvalue-scan convention in `scripts/tests/runaway.lua`
  (`debug.getupvalue(fn, key)` scanning by name).
- Lua 5.2 semantics under Luaj: no bitwise ops; use `math.floor`, `2^n`;
  `(table.unpack or unpack)`; chunk `string.char` (≤4096 args).
- Lua API: `file_exists, file_open, file_close, file_size, file_read, list_files,
  image_create_indexed, image_create_rgb, animation_create, sound_*, midi_*
  (auto/xmi/cmf), imuse_*, zlib_decompress, xor_bytes, image_load_png`
  (`src/main/kotlin/adventureexplorer/scripting/LuaEngine.kt`).
- Update docs when done: `README.md`, `engine-sources.md` (SKILLS.md is
  gitignored/local).

---

## 8. Quick one-liners

- Parse the TRE index (see §4).
- List `.lvl` files by size (all ~660 KB – 5.8 MB; `1.lvl`..`20.lvl` are the
  numbered levels, plus named scenes `Playa`, `Pantano`, `Cocina`, `Creditos`,
  `INTERFACE`, `Mapa`, `Final`, ...).
- Extract any resource by name:
  ```python
  # name -> (off,size) from the TRE parser, then TESORO.DAT[off:off+size]
  ```
- Count magics in DAT:
  `python3 -c "d=open('TESORO.DAT','rb').read();print(d.count(b'ANM\x01'),d.count(b'LVL\x01'),d.count(b'RIFF'))"`
- Grep strings in DAT:
  `python3 -c "import re;d=open('TESORO.DAT','rb').read();print(len(re.findall(rb'[ -~]{6,}',d)))"`

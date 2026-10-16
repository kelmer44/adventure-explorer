# Les Manley in: Lost in LA (LES2) — Reverse-Engineering Handoff

## Implementation update (2026-10-16)

The blocker described below has been resolved. `scripts/engines/les2/engine.lua`
decodes 498/499 picture blocks (267 still, 231 animated) and 83 raw RGB palettes.
The remaining picture at DATAF offset 502964 rejects an invalid LZW code and is
listed as metadata. Audio and original animation/script playback remain open.

**Corrections to the historical analysis below:** ILBM is NOT a red herring.
The BMHD declares 20 bytes but occupies 19, so strict IFF walkers miss BODY.
BODY uses GIF-style 9..12-bit LSB LZW (256 clear, 257 end), producing chunky
pixels and consecutive frames. Palettes are 8-bit RGB, not 6-bit DAC triples.
The EXE contains the resource directory at file offset 114867, with 14-byte
hash/letter/offset/size records; the engine discovers this table dynamically.
Filename hashes use position-weighted sums; the 20 coefficients are at 110026.
Decompressed scene resources name `.lbm` images; archive hashes use `.pic` and
`.lsc` extensions. DATAA's name table begins at 576, not 1342. See
`engine-sources.md` and `scripts/tests/les2.lua` for the verified format.

The original investigation is retained below as historical context; its format
hypotheses and blocked status are superseded by this update.


Status: **blocked on the graphics container/compression format.** The resident
DOS EXE has been located, mapped, and largely decompiled, but the image store
format in `DATA*.DAT` has **not** been cracked. This document captures everything
so a fresh agent can continue without re-doing the work.

Last updated: 2026-10-16.

---

## 1. Goal

Add a `les2` engine to `adventure-explorer` (Kotlin/Compose resource browser).
Engines are pure-Lua scripts at `scripts/engines/<name>/engine.lua`; no Kotlin
recompile is needed (`ScriptManager.kt` discovers them). Noctropolis is done and
is the style reference. LES2 needs from-scratch RE.

## 2. Game facts

- 1991 Accolade / Manley & Associates, **Spanish** release, MS-DOS.
- `LES2.BAT` = `EXE MCGA Mouse E` (320x200, 256 colors, MCGA/VGA mode 5/3).
- Game dir: `/Users/gabriel/Desktop/ags/LES2`.

Files:

| File | Size | Date | Notes |
|---|---|---|---|
| `DATAA.DAT` | 231137 | 1993 | symbol table + `id\tname` directory + Spanish text |
| `DATAB.DAT` | 691496 | 1993 | image/data heavy; 29882-byte header |
| `DATAC.DAT` | 706648 | 1993 | starts with Spanish dialogue text |
| `DATAD.DAT` | 698700 | 1993 | image-heavy |
| `DATAE.DAT` | 710075 | 1993 | image-heavy |
| `DATAF.DAT` | 697543 | 1993 | image-heavy |
| `DATAZ.DAT` | 33204 | 1993 | shares **identical 29882-byte header** with DATAB, then 1 image
| `EXE.EXE` | 137013 | **2020 (!)** | main executable; **modified date** — suspicious |
| `OOPS.OOP` | 13395 | 1993 | magic `Oops` |
| `MUSIC.DRV`, `SAMPLE.DRV` | 5845 / 3648 | 1991 | drivers |
| `SETUP.EXE` | 13342 | 1991 | setup |
| `SAVE_0.SAV` | 13404 | 2014 | save game
| `LES2.BAT` | 19 B | | `EXE MCGA Mouse E` |

`LES2.BAT` = `EXE MCGA Mouse E`. Run needs ~575K free RAM (per README).
Referenced-but-**absent** files: `INSTALL.EXE`, `game1.ivy`, `game2.ivy`,
`game3.ivy`, `index.dat`, `256.PAL`, `dataX.txt`. Only `SAVE_0.SAV` + `SETUP.EXE`
present. `EXE.EXE` is dated 2020 (possibly repacked/recompiled by a fan or a
"fixed" build). **Get the original install if possible** — the missing `.ivy`
overlays are likely the high-level game logic.

---

## 2b. Files

- Game data: `/Users/gabriel/Desktop/ags/LES2/`
- EXE copy for Ghidra: `/tmp/les2.exe`
- Ghidra project: `/tmp/ghproj` (project `les2`, program `les2.exe`)
- Ghidra scripts: `/tmp/ghscripts/*.py`
- All-functions decompile: `/tmp/allfuncs.c` (571 functions, greppable)

---

## 3. Environment / tooling (already set up)

- **Ghidra 11.4.2**: `/opt/homebrew/Caskroom/ghidra/11.4.2-20250826/ghidra_11.4.2_PUBLIC`
  - Headless run template:
    ```
    GH=/opt/homebrew/Caskroom/ghidra/11.4.2-20250826/ghidra_11.4.2_PUBLIC
    "$GH/support/analyzeHeadless" /tmp/ghproj les2 -process les2.exe -noanalysis \
        -scriptPath /tmp/ghscripts -postScript <script>.py
    ```
  - `-noanalysis` is used because the program is already analyzed; scripts do
    on-demand `DisassembleCommand` + `CreateFunctionCmd` + `DecompInterface`.
  - **Jython 2.7** — no f-strings, no `capstone` module. `Memory.findBytes`
    takes 5–6 args. Use `int(x,16)` etc.
- **Lua 5.5** at `/opt/homebrew/bin/lua` (+ `luac`) for engine tests.
- **Python 3** + **Pillow** for data analysis.
- **DOSBox-X** at `/opt/homebrew/bin/dosbox-x` — **key asset for dynamic
  analysis** (see §7). `dosbox`/`dosemu` are NOT installed.
- ScummVM fork at `/Users/gabriel/Desktop/source/scummvm-fork/engines/` — has
  **no** Les Manley engine (`rg -i manley` only false positives).
- Related but insufficient: `scripts/engines/capstone/engine.lua` (Manley &
  Associates family) handles AMTAIL/BHB/LALAW only — **not** the LES2 format.

### Ghidra address mapping (important)

- MS-DOS 16-bit MZ EXE, entry `CS:IP = 0x204a:0x0012`.
- **File offset `0x200` → `1000:0000`.** Therefore:
  - `file_offset X  ->  0x1000:(X - 0x200)`
  - The resident image base is segment `0x1000`.
- Strings live in segment `2000`; a string at file offset `X` is at
  `seg 0x2000`, off `X - 0x200` (e.g. `256.PAL` @ file `0x1f3aa` = `2000:f1aa`).
- Ghidra found **571 functions**; decompiled dump at `/tmp/allfuncs.c`.

---

## 4. EXE analysis results

### 4a. Packing
- **EXE.EXE is NOT LZEXE/PKLITE/UPX packed.** Entry `CS:IP = 0x204a:0x0012`
  sits near the end of the file; the bytes at file `0x200` are normal C code.
- The string `Packed file is corrupt` exists at file `0x133047` but appears to be
  an unrelated embedded runtime message. No `LZEXE`/`PKLITE`/`UPX` signatures.
- `relocs = 0` — no relocation table.

## 4b. Segments / memory map (Ghidra import)

- `CODE_0`: `1000:0000`–`3000:049f` (resident code)
- `CODE_1`: `304a:0000`–`304a:1094`
- `DATA`: `304a:1095`–`304a:ec74` (uninitialized/BSS-ish)
- Strings live in segment `2000`.

## 4c. Key routines found

- `FUN_1000_ba1b` — **palette fade routine** (`.PAL` loader/uploader).
  - Palette port write `mov dx, 0x3c8` at `1000:ba9f` (file `0xbc9f`).
  - Delta-decodes 768 bytes (`al = src - cl`, clamped), uploads R/G/B to DAC
    via ports `0x3c8`/`0x3c9`, syncing on `0x3da` (VGA retrace).
  - Param check: mode == 3 (VGA) or == 5 (MCGA).
- `FUN_1000_8929` @ `1000:8929` — **resource file loader**.
  - Uses a runtime table at `DS:0xf98`; **14-byte records**:
    `+0x00 u32 handle_lo`, `+0x04 u32 handle_hi`, `+0x08 char file_letter`,
    `+0x0a u32 offset`, `+0x0e u16 size_lo`, `+0x10 u16 size_hi`
    (offsets relative to record start; exact field order to be confirmed).
  - Looks up the requested 32-bit handle, opens the file via DOS INT21 wrappers,
    seeks, reads `size` raw bytes into a caller buffer, closes. **No
    decompression here — raw read only.**
  - DOS wrappers: `FUN_1000_b939/b954/b996/b9b4/b9d8` (open/seek/read/close).
- `FUN_1000_2562` → calls loader then `func_0x0000ca79(0x87b, ...)`.
- `FUN_1000_25c2` → loads a **64000-byte (320×200) full-screen resource** into
  `[0xb44]`, then `func_0x0000ca79(...)`.
- `func_0x0000ca79` appears ~12+ times with signature
  `(seg, src_lo, src_hi, dst_lo, dst_hi, 0,0,0)` → almost certainly a **far
  `memcpy`**, *not* a decoder.
- `[0xb44]` = offscreen 320×200 (64000 B) image buffer segment; `[0xb46]` =
  second buffer; `[0xb4c]` = mode store. Allocated via `FUN_1000_c650`
  (INT21 AH=48 = allocate memory).
- `FUN_1000_6186` = **command-line switch parser**: `v`→mode 3 (VGA),
  `e`→mode 2 (EGA), `m`→mode 5 (MCGA), `t`→mode 4 (Tandy). Graphics mode
  stored at `[0xbc]`.
- `FUN_1000_bb16` = video-mode init + dither (LFSR `0xa9cb`/`0x8805`).
- `FUN_1000_c6df` = builds MCGA scanline offset table at `0x948` (stride
  `0x140` = 320).
- `FUN_1000_bd1f` = masked image/sprite draw (uses ports `0x3c4`/`0x3ce`/`0x3cf`).

## 4d. Unresolved far calls (overlays)

Decompiler emits many `func_0x0000XXXX(...)` with **segment 0000** — e.g.
`func_0x00008929`, `func_0x0000ca79`, `func_0x0001a2b4`, `func_0x0001a5a2`,
`func_0x00005558`, `func_0x00008327`, `func_0x0001a2b4`. These look like
**overlay segments patched at runtime**. There are **no near-offset xrefs** to
string offsets searched (`0xf1aa`, `0xface`, `0xbc68`, `0xbc6d`, `0xa8eb`,
`0xbc3d`, `0xbc58`, `0xedf4`, `0xbabf`, `0xbadd`) in the resident code either —
consistent with the high-level logic (and probably the decompressor) living in
the missing `game1/2/3.ivy` overlays.

## 4e. Strings (EXE, file offsets)

`256.PAL` @ `0x1f3aa`; `Oops` @ `0x1ea85`; `MUSIC.DRV` @ `0x1aea4`;
`dataX.dat`, `dataX.txt`, `index.dat`, `convfile.dat`, `game1/2/3.ivy`;
`.ODF`, `.SCN`, `.PAL`, `.BAN`, `.FNT`, `mnsion`, `frdoor`, `hphone`, ...
Also `BACKGROUND`, `SPRITES`, `CONDITIONS`, `Objdesc`, `vstring`, `whoswho`,
`THISTOPIC`, `ADJTOPIC`, `M_NEWDISPLAY`, `GLOBALS`, `FLAGS`, `EXTRN_ARRAY`,
`INTRN_ARRAY`, `lista`, `listb`, `null`, `cpoolb`.

---

## 5. Data-file format findings

## 5.1 `DATAA.DAT` (the "symbol/name" file)

- First 576 bytes = **95 records × 6 bytes**: `(id:u16 BE, value:u32 BE)`.
  - Records r0..r94; r95 @ offset 570 = `FF FF FF FF FF FF` terminator.
  - `id`s observed: `30,31,32,33,…,59,60,70,76,87,92,100,105,107,127,108,156,…,
    330,333,…,421`. (Not perfectly sorted.)
  - Aliased ids share the same `value` (e.g. ids 49 & 50 identical; 53–56
    identical). Semantics unknown — possibly symbol addresses/flags.
- Name table (ASCII `id\tname\r\n`) begins at **offset 1342** (`30\t`).
  → 101 entries, ids `30`–`338`, names like
  `null, cpoolb, mnsion, frdoor, hphone, beacha, …`.
- Bytes 576–1342 (766 B, between the two tables) = unparsed (likely another
  header/pointer table). **TODO.**
- After the name table: Spanish dialogue text beginning with `---|`.
- Region ~67200: a binary block (suspected palette? — but no ≤63 768-byte
  palette found; see §5.4).

## 5.2 `DATAB.DAT` / `DATAZ.DAT` shared header (29882 bytes)

- `DATAB` and `DATAZ` share an **identical 29882-byte prefix** (byte-for-byte).
- Start looks like a table of small values, e.g.
  `00 80 00 00 00 00 00 00 02 00 00 00 …`.
- Tail (last ~200 B before the 0xFF terminator) is a **directory of 8-byte
  records**, e.g.:

  ```
  ... 14 01 9a 16 b5 00 00 00
      15 01 9a 17 06 00 00 00
      16 01 9a 17 b9 00 00 00
      17 01 9a 18 39 00 00 00
      18 01 9a 18 8d 00 00 00
      19 01 9a 18 e9 00 00 00
      1a 01 9a 19 65 00 00 00
      3c 01 9b 00 d8 00 00 00
      14 01 9b 1a 09 00 00 00
      15 01 9b 1a 1f 00 00
      ff ff ff ff ff ff ff ff ff ff ff ff ff ff
  ```

  Pattern per record: `[id:u8][0x01][0x9a or 0x9b][v:u16 BE][00][00][00]`.
  The `u16 BE` values increase steadily (`0x16b5,0x1706,0x17b9,0x1839,…`)
  — they look like **offsets or cumulative pointers**, range ~5700–6690.
  The `0x9a`/`0x9b` byte changes (brach/segment?). **Not yet decoded.**
- This directory is the prime suspect for the resource → (offset,size) map.
  Note the loader's runtime record (§4c) has `handle, file_letter, offset,
  size` — likely built from this directory.

## 5.3 `DATAC.DAT` / `DATAD.DAT` / `DATAE.DAT` / `DATAF.DAT`

- `DATAC` starts directly with Spanish text `...|Acosado por los violentos
  relámpagos y con el viento azotándole la espalda, Les se abre paso`.
- These files are a mix of text and binary blobs. Boundaries unknown.

## 5.4 No palette found

Searched all `DATA*.DAT`, `OOPS.OOP`, and the EXE for a 768-byte palette where
every byte ≤ 0x3F (6-bit VGA DAC format): **none found.** Palette source is
unknown. `256.PAL` is referenced by the EXE but **not present** on disk. The
palette is likely either built in code (fade routine `FUN_1000_ba1b` only
*uploads* a buffer) or embedded in a compressed resource. **TODO.**

## 5.4b Dead end: ILBM is a red herring

- `DATAB–F` contain 79–133 occurrences of the literal strings `FORM`, `ILBM`,
  `BMHD`, `BODY`. **These are coincidental byte patterns, not real IFF/ILBM.**
  Verification: strictly walking chunk sizes inside each `FORM` yields **0
  valid ILBMs**; e.g. `DATAD`'s first `FORM` (@1456) is followed by a chunk
  `TIGO` with a nonsense size `1394626642`.
- Consequence: earlier attempts to decode a "BODY" with byteRun1 were decoding
  arbitrary data. **Ignore all FORM/ILBM/BODY leads.**

## 5.5 Image-compression Ruled Out

- The body bytes show per-byte entropy ≈ **7.94**, mean run length **1.0**, max
  run **3** → **not RLE / not byteRun1**, and not any trivial run-based scheme.
- Attempts to interpret candidate 64000-byte outputs (from a byteRun1 decode)
  as 320×200 chunky or as 4/8-plane (row-interleaved or plane-major, MSB/LSB)
  all gave noise-level neighbor-diff (mean |Δ| ≈ 47–96). **No layout produced a
  coherent image.**
- Conclusion: images use a **custom compression** (unknown), most likely
  implemented in code that lives in the **missing `.ivy` overlays**.

## 5.6 No palette / no reference

- Scanned all `DATA*.DAT`, `OOPS.OOP`, and the EXE for a 768-byte ≤63 palette —
  **none found**.
- No ScummVM driver and no online/community documentation of this format.

---

## 6. Architecture hypothesis

- `EXE.EXE` contains: mode setup, VGA/DAC palette upload, the **resource loader
  (`FUN_1000_8929`, raw read)**, memory allocation, sprite blit (`FUN_1000_bd1f`),
  and small far helpers (`memcpy` at `0xca79`).
- The **high-level game logic and almost certainly the image decompressor** are
  in overlays referenced as `game1/2/3.ivy` — **not present on disk**. The
  decompiler's `func_0x0000XXXX` far calls (segment 0) corroborate this: those
  segments are patched in at runtime.
- Because the loader does a **raw** read, the decompression must happen in the
  caller (overlay code) — which is why no decoder is visible in the resident
  segment.

---

## 7. Recommended next steps

**Priority A — dynamic analysis (fastest path, DOSBox-X is installed).**
1. Run the game: `dosbox-x -c "mount c ~/Desktop/ags/LES2" -c "c:" -c "EXE MCGA Mouse E"`.
   Use the DOSBox-X **debugger** (`DEBUGBOX`/`-debug` or the built-in debugger)
   to:
   - Set a breakpoint after the loader read, or at the palette port write
     (`out 3c8`/`out 3c9`), and **dump the 768-byte DAC palette** to a file
     (`MEMDUMPBIN` of the palette buffer, or read the `3c8`-written buffer).
   - Breakpoint the framebuffer `A000:0000` after a screen is drawn and dump
     `320×200` to get the decoded image **and** confirm the decoded geometry.
   - Two or three captured (image + palette) pairs are enough to reverse the
     container (offsets/sizes) and to validate a decompressor.
2. Alternatively dump the offscreen buffer `[0xb44]` (segment from the loader
   call) right after `FUN_1000_25c2` returns — that is the decoded 64000-byte
   screen.
3. A DOSBox-X screenshot (Ctrl+F5) after the title screen gives a ground-truth
   PNG to diff candidate decoders against.

**Priority B — get the original/complete files.**
- Find a complete copy containing `INSTALL.EXE` and `game1/2/3.ivy` (and
  `256.PAL`, `index.dat`). The missing overlays likely contain the decompressor.
- The English "Search for the King" / original release may ship the same engine
  with readable strings.

**Priority C — continue static RE.**
- Decode the 29882-byte header directory in `DATAB`/`DATAZ` (§5.2): figure out
  the 8-byte record fields, verify against the file size, and cross-check with
  the loader's runtime record at `DS:0xf98`.
- Decompile the DOS wrappers and the caller chain of `FUN_1000_8929`/`2562`/
  `25c2` in `/tmp/allfuncs.c`; look for a decode loop over `[0xb44]`.
- Search the EXE for overlay-loading logic (how `game*.ivy` segments get
  patched into `func_0x0000XXXX`). If overlays can be reconstructed, the
  decompressor becomes reachable.
- Identify the engine by the distinctive strings (`Objdesc`, `THISTOPIC`,
  `M_NEWDISPLAY`, `lista/listb`) — it may be a known Accolade/Manley interpreter.

**Priority D — ship a partial engine** if images stay blocked:
- `scripts/engines/les2/engine.lua` that `detect()`s the game (presence of
  `DATA?.DAT` + `EXE.EXE` + `OOPS.OOP`), and lists `DATAA` symbol/name table +
  text. Extend later.

---

## 8. Repo integration reminders (for whoever finishes it)

- Engine script: `scripts/engines/les2/engine.lua` (style ref:
  `scripts/engines/noctropolis/engine.lua`).
- Test: `scripts/tests/les2.lua`, run with `/opt/homebrew/bin/lua`. Follow the
  upvalue-scan convention in `scripts/tests/runaway.lua`
  (`debug.getupvalue(fn, key)` scanning by name; see `scripts/tests/runaway.lua`).
- Lua 5.2 semantics under Luaj: no bitwise ops; use `math.floor`, `2^n`;
  `(table.unpack or unpack)`; chunk `string.char` (≤4096 args).
- Lua API: `file_exists, file_open, file_close, file_size, file_read, list_files,
  image_create_indexed, image_create_rgb, animation_create, sound_*, midi_*
  (auto/xmi/cmf), imuse_*, zlib_decompress, xor_bytes, image_load_png`
  (`src/main/kotlin/adventureexplorer/scripting/LuaEngine.kt`).
- Update docs when done: `README.md`, `engine-sources.md` (SKILLS.md is
  gitignored/local).

---

## 9. Ghidra script inventory (`/tmp/ghscripts/`)

- `explore.py`, `explore2.py` — list functions/blocks.
- `pal.py` — search palette-related bytes/ports.
- `strs.py` — find strings.
- `xref.py`, `xrefs.py` — cross-references.
- `ptr.py` — pointer scan.
- `int21.py` — find INT 21 sites.
- `b44.py` — inspect buffer segment `0xb44` usage.
- `dec.py`, `dec2.py`, `dec3.py`, `dec4.py`, `dec5.py` — on-demand
  disassemble + decompile specific addresses (use `dec5.py` as template).
- `dumpall.py` — dump/decompile all functions (produced `/tmp/allfuncs.c`).
- `find.py`, `findbytes.py` — byte-pattern search.

Template for on-demand decompile (`dec5.py`):
```python
from ghidra.app.decompiler import DecompInterface
from ghidra.util.task import ConsoleTaskMonitor
ifc = DecompInterface(); ifc.openProgram(currentProgram)
mon = ConsoleTaskMonitor()
for a in ["1000:8929"]:
    addr = toAddr(a)
    ghidra.app.cmd.disassemble.DisassembleCommand(addr, None, True).applyTo(currentProgram, mon)
    ghidra.app.cmd.function.CreateFunctionCmd(addr).applyTo(currentProgram, mon)
    f = getFunctionContaining(addr)
    r = ifc.decompileFunction(f, 120, mon)
    print(r.getDecompiledFunction().getC())
```

---

## 10. Quick one-liners

- Count ILBM red herrings:
  `python3 -c "d=open('DATAB.DAT','rb').read();print(d.count(b'FORM'),d.count(b'ILBM'))"`
- Shared B/Z prefix length:
  `python3 -c "b=open('DATAB.DAT','rb').read();z=open('DATAZ.DAT','rb').read();print(next(i for i in range(len(z)) if b[i]!=z[i]))"`
- Ghidra headless (see §3).
- Run game:
  `dosbox-x -c "mount c ~/Desktop/ags/LES2" -c "c:" -c "EXE MCGA Mouse E"`

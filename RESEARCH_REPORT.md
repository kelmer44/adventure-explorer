# Comprehensive Technical Research Report
## Retro Game Format Decompression & Resource Systems

This report covers three topics in full technical detail, suitable for implementing decoders in Lua.

---

# Part 1: FITD PAK_explode / PKWare DCL Implode

## 1.1 PAK Archive Structure (Alone in the Dark)

Source: [FITD pak.cpp](https://github.com/yaz0r/FITD/blob/master/FitdLib/pak.cpp)

### File-Level Layout

A PAK file begins with an **offset table** — an array of `UINT32LE` values. Each entry gives the absolute file offset to a packed entry. The number of entries is determined by reading offsets until you reach one that points past the first offset or equals zero.

### Per-Entry Header: `pakInfoStruct`

Each entry in the PAK archive has a 10-byte header:

| Offset | Size | Field              | Description                                |
|--------|------|--------------------|--------------------------------------------|
| 0x00   | 4    | `discSize`         | Compressed size in bytes (INT32LE)         |
| 0x04   | 4    | `uncompressedSize` | Decompressed size in bytes (INT32LE)       |
| 0x08   | 1    | `compressionFlag`  | Compression method indicator               |
| 0x09   | 1    | `info5`            | Dictionary size parameter (for DCL)        |

#### Compression Flag Values

| Value | Method          | Description                                  |
|-------|-----------------|----------------------------------------------|
| 0     | None            | Raw data, just copy `discSize` bytes          |
| 1     | PAK_explode     | PKWare DCL Implode decompression              |
| 4     | PAK_deflate     | zlib-style deflate decompression              |

### PAK_explode Function Signature

From `unpack.h`:

```c
int PAK_explode(
    unsigned char *srcBuffer,       // compressed data
    unsigned char *dstBuffer,       // output buffer
    unsigned int compressedSize,    // pakInfo.discSize
    unsigned int uncompressedSize,  // pakInfo.uncompressedSize
    unsigned short flags            // pakInfo.info5 (dictionary type)
);
```

The `info5` / `flags` parameter is the **dictionary type** byte from the PKWare DCL stream. It determines the sliding window size:

| info5 Value | Dictionary Size | Bit Count for Distance Low Bits |
|-------------|-----------------|--------------------------------|
| 4           | 1024 bytes      | 4 extra bits                   |
| 5           | 2048 bytes      | 5 extra bits                   |
| 6           | 4096 bytes      | 6 extra bits                   |

**Important**: In the FITD PAK format, the `info5` value is stored *in the PAK entry header* (not in the compressed stream itself). When calling PAK_explode, this value is passed directly. However, in the standard PKWare DCL format (as used elsewhere), the dictionary type is read from the *second byte* of the compressed stream.

## 1.2 PKWare DCL Implode Algorithm (Complete Specification)

Source: [ScummVM dcl.cpp](https://github.com/scummvm/scummvm/blob/master/common/compression/dcl.cpp)

PKWare DCL "Implode" is a compression algorithm combining **Shannon-Fano (Huffman-like) coding** with **LZ77 sliding window** back-references. It is **NOT related to zlib/deflate**. It is PKWARE's proprietary Data Compression Library format, also known as "explode" (decompression side).

### Stream Header (2 bytes)

| Byte | Name             | Values                                 |
|------|------------------|----------------------------------------|
| 0    | `mode`           | 0 = Binary mode, 1 = ASCII mode        |
| 1    | `dictionaryType` | 4 = 1024, 5 = 2048, 6 = 4096 byte dict |

**Note**: In FITD, these two bytes may be embedded differently. The `info5` field in the PAK header corresponds to `dictionaryType`. The mode byte may be the first byte of the compressed data, or it may default to binary mode.

### Bit Reading Order

All bits are read **LSB-first** (least significant bit first). This is critical and different from many other compression formats.

```lua
-- Lua bit reader (LSB-first)
function BitReader:new(data)
    local o = { data = data, pos = 1, bits = 0, nBits = 0 }
    setmetatable(o, { __index = BitReader })
    return o
end

function BitReader:fetch()
    while self.nBits <= 24 do
        local byte = self.data:byte(self.pos) or 0
        self.pos = self.pos + 1
        self.bits = self.bits | (byte << self.nBits)
        self.nBits = self.nBits + 8
    end
end

function BitReader:get(n)
    if self.nBits < n then self:fetch() end
    local val = self.bits & ((1 << n) - 1)
    self.bits = self.bits >> n
    self.nBits = self.nBits - n
    return val
end
```

### Decompression Main Loop

```
read mode byte (0=binary, 1=ascii)
read dictionaryType byte (4/5/6)
dictionarySize = 1 << dictionaryType  -- 1024, 2048, or 4096
dictionaryMask = dictionarySize - 1
initialize circular dictionary buffer
dictionaryPos = 0

while output not complete:
    bit = getBitsLSB(1)

    if bit == 1:  -- (length, distance) pair
        value = huffman_lookup(length_tree)

        if value < 8:
            tokenLength = value + 2
        else:
            tokenLength = 8 + (1 << (value - 7)) + getBitsLSB(value - 7)

        if tokenLength == 519:
            break  -- END OF STREAM marker

        value = huffman_lookup(distance_tree)

        if tokenLength == 2:
            tokenOffset = (value << 2) | getBitsLSB(2)
        else:
            tokenOffset = (value << dictionaryType) | getBitsLSB(dictionaryType)

        tokenOffset = tokenOffset + 1  -- offsets are 1-based

        -- Copy tokenLength bytes from dictionary at (dictionaryPos - tokenOffset)
        baseIndex = (dictionaryPos - tokenOffset) & dictionaryMask
        for i = 0, tokenLength - 1:
            srcIndex = (baseIndex + (i % tokenOffset)) & dictionaryMask
            byte = dictionary[srcIndex]
            output(byte)
            dictionary[dictionaryPos] = byte
            dictionaryPos = (dictionaryPos + 1) & dictionaryMask

    else:  -- literal byte
        if mode == ASCII_MODE:
            value = huffman_lookup(ascii_tree)
        else:
            value = getBitsLSB(8)  -- raw byte in binary mode

        output(value)
        dictionary[dictionaryPos] = value
        dictionaryPos = (dictionaryPos + 1) & dictionaryMask
```

### Huffman Tree Lookup

The trees are stored as arrays of branch/leaf nodes. Each node is either:
- **Branch**: encodes left child (bits 23..12) and right child (bits 11..0)
- **Leaf**: has bit 30 set (`0x40000000`), value in lower 16 bits

```lua
function huffman_lookup(tree, reader)
    local pos = 1  -- 1-indexed for Lua
    while (tree[pos] & 0x40000000) == 0 do
        local bit = reader:get(1)
        if bit == 1 then
            pos = (tree[pos] & 0xFFF) + 1  -- right child
        else
            pos = (tree[pos] >> 12) + 1     -- left child
        end
    end
    return tree[pos] & 0xFFFF
end
```

### The Three Huffman Trees

#### Length Tree (16 symbols: 0-15)

Used to decode the "length" part of (length, distance) pairs:

| Symbol | Meaning                                            |
|--------|----------------------------------------------------|
| 0      | length = 2                                         |
| 1      | length = 3                                         |
| ...    | ...                                                |
| 7      | length = 9                                         |
| 8+     | length = 8 + (1 << (symbol-7)) + extra_bits        |
| (519)  | End of stream signal (symbol that yields len=519)  |

Full tree data (as node array, 0-indexed):

```
Node 0:  BN(1, 2)
Node 1:  BN(3, 4)       Node 2:  BN(5, 6)
Node 3:  BN(7, 8)       Node 4:  BN(9, 10)      Node 5:  BN(11, 12)   Node 6:  LN(1)
Node 7:  BN(13, 14)     Node 8:  BN(15, 16)     Node 9:  BN(17, 18)   Node 10: LN(3)
Node 11: LN(2)          Node 12: LN(0)
Node 13: BN(19, 20)     Node 14: BN(21, 22)     Node 15: BN(23, 24)   Node 16: LN(6)
Node 17: LN(5)          Node 18: LN(4)
Node 19: BN(25, 26)     Node 20: BN(27, 28)     Node 21: LN(10)       Node 22: LN(9)
Node 23: LN(8)          Node 24: LN(7)
Node 25: BN(29, 30)     Node 26: LN(13)         Node 27: LN(12)       Node 28: LN(11)
Node 29: LN(15)         Node 30: LN(14)
```

#### Distance Tree (64 symbols: 0-63)

Used to decode the high bits of the back-reference distance. The full distance is computed as:
- If tokenLength == 2: `distance = (symbol << 2) | getBitsLSB(2)`
- Otherwise: `distance = (symbol << dictionaryType) | getBitsLSB(dictionaryType)`

The tree has 127 nodes total. The leaf values represent the 6-bit distance code (0-63). The tree encodes frequent small distances with shorter codes.

#### ASCII Tree (256 symbols: 0-255)

Used only in ASCII mode (mode byte = 1). Contains 511 nodes, one leaf for each possible byte value. Common ASCII characters (space=32, 'e'=101, 't'=116, etc.) have shorter codes.

### Relationship to zlib

PKWare DCL Implode is **completely separate** from zlib/deflate:
- **DCL Implode**: Shannon-Fano trees (fixed, not transmitted), LZ77, LSB-first bit reading
- **zlib Deflate**: Dynamic Huffman trees (transmitted in stream), LZ77, different distance encoding

The FITD `compressionFlag=4` (PAK_deflate) uses actual zlib deflate. `compressionFlag=1` (PAK_explode) uses PKWare DCL.

## 1.3 HQR Resource System

Source: [FITD hqr.cpp](https://github.com/yaz0r/FITD/blob/master/FitdLib/hqr.cpp)

HQR (High Quality Resource) is the higher-level resource archive format used by AITD games. Each entry within an HQR file is itself a PAK-compressed block. The HQR system manages loading, caching (via a linked-list-based LRU cache), and decompression of these blocks.

---

# Part 2: Cobra Mission VOL Archive & GC Image Format

## 2.1 VOL Archive Structure

Source: [cobra-mission-writer volfile.cpp](https://github.com/BlackStar-EoP/cobra-mission-writer), [MegaTech VOL Format wiki](https://wiki.scummvm.org/index.php/User:Wikipedia/Cobra_Mission)

### Archive Layout

A VOL file has **no magic signature**. It is simply:

```
[Header: Array of UINT32LE offsets]
[Data entries...]
```

**Parsing algorithm**:
1. Read first UINT32LE → this is `headerSize` (= first entry's offset)
2. `numEntries = headerSize / 4`
3. Read `numEntries` UINT32LE values as offset table
4. Each entry spans from `offset[i]` to `offset[i+1]` (last entry spans to EOF)

### VOL File Types

| Filename Pattern       | Content Type | Description                      |
|------------------------|-------------|----------------------------------|
| CUT1.VOL - CUTA.VOL   | GC          | Cutscene graphics                |
| ENM.VOL, ENMA.VOL      | GC          | Enemy graphics                   |
| MAP.VOL                | GC          | Map/location backgrounds         |
| OPENING.VOL            | GC          | Opening sequence graphics        |
| PIC1.VOL - PICA.VOL   | GC          | Picture/CG scene graphics        |
| MCG.VOL                | SPRITES     | 32×32 tile sprites (raw)         |
| MED.VOL                | MAPS        | Map/level layout data            |
| EMI.VOL                | MUSIC       | OPL FM music                     |

## 2.2 GC Image Format (Graphics Chunk)

### GC Entry Header (16 bytes)

| Offset | Size | Field              | Description                          |
|--------|------|--------------------|--------------------------------------|
| 0x00   | 2    | Signature          | "GC" (0x47, 0x43)                    |
| 0x02   | 1    | Version            | Format version (0 in game data)      |
| 0x03   | 1    | (padding)          | Usually 0                            |
| 0x04   | 1    | Palette flag       | Exactly 0x80 if a palette follows    |
| 0x05   | 1    | (padding)          | Usually 0                            |
| 0x06   | 2    | Subchunk table ptr | UINT16LE: 0x30 with palette, else 0x10 |
| 0x08   | 2    | Num subchunks      | UINT16LE number of image subchunks   |
| 0x0A   | 2    | (padding)          | 0                                    |
| 0x0C   | 2    | Chunk size         | UINT16LE total size of this GC entry |

Verified against all 972 GC subchunks in the game data: `0x06` always agrees with the palette flag, `0x08` is a UINT16LE (a UINT32LE read happens to work on this data only because the upper bytes are zero), and `data_size == next_offset - offset - 10` for every subchunk.

### Palette (32 bytes, if palette flag set)

Located at offset 0x10 (immediately after header). Contains **16 colors** as UINT16LE values in **0GRB** format:

```
Bits: 0000 GGGG RRRR BBBB
```

Color extraction:
```lua
function decode_palette_entry(val)
    local r = (val >> 4) & 0xF
    local g = (val >> 8) & 0xF
    local b = val & 0xF
    -- Scale from 4-bit to 8-bit
    r = (r << 4) + (r >> 2)  -- equivalent to r * 255 / 63 approximately
    g = (g << 4) + (g >> 2)
    b = (b << 4) + (b >> 2)
    return r, g, b
end
```

The scaling formula `(x << 4) + (x >> 2)` maps 0→0, 15→63 (EGA-range), which can be further scaled to 0-255 by multiplying by 4 (or `(x << 4) | x` for 0-255 mapping).

### Subchunk Table

After the palette (if present), at the offset given by `subchunkTablePtr`:
- Array of `(numSubchunks + 1)` UINT32LE values
- Each pair `[offset[i], offset[i+1]]` defines a subchunk's data range

### GC Subchunk Data Header (10 bytes)

Each subchunk has a 10-byte header:

| Offset | Size | Field          | Description                          |
|--------|------|----------------|--------------------------------------|
| 0x00   | 1    | Marker         | Always 0xA4                          |
| 0x01   | 1    | Checksum       | Data integrity                       |
| 0x02   | 1    | X offset       | Horizontal position in pixels        |
| 0x03   | 1    | Y offset       | Vertical position in pixels          |
| 0x04   | 1    | Unknown        | -                                    |
| 0x05   | 1    | Width × 2      | Width in 8-pixel units is `this >> 1`|
| 0x06   | 2    | Data size      | Compressed data size (UINT16LE)      |
| 0x08   | 2    | Unknown        | -                                    |

### Image Dimensions

- Width is in **8-pixel units** due to planar encoding (each 4-byte planar group = 8 pixels), so pixel width is `(header[0x05] >> 1) * 8`. Note this is the `>> 1` of byte 5, **not** byte 4.
- **Height is not stored.** The bitstream is self-terminating: lines are decoded until the chunk's `data_size` bytes have been consumed. Measured against all 967 GC subchunks in the game data, this consumes the payload exactly in every case.
- Full-screen images decode to 640×400 (the standard VGA resolution). Sub-rect images decode to their own extents, e.g. 432×292.
- `header[0x04]` is not the height. It equals the line count for some sprite subchunks but disagrees for the full-screen ones (e.g. 144 vs 400 for PIC1), so it must not be used as one.
- Subchunks within a GC entry are composited at their (x, y) pixel offsets; the image extent is the maximum `x + width` and `y + height` over all subchunks.

## 2.3 GC Decompression Algorithm

Source: [gcparse.cpp](https://github.com/BlackStar-EoP/cobra-mission-writer/blob/master/gcparse.cpp)

The GC format uses a custom **Huffman + LZ77/LZ78 hybrid** compression scheme operating on **4-bit planar** pixel data.

### Data Structures

```lua
-- Decoder state
local bitBuffer = 0       -- 16-bit bit buffer
local bitsLeft = 0        -- bits remaining in buffer
local nibbleBuffer = 0    -- cached nibble (4 bits)
local hasNibble = false   -- whether nibbleBuffer is valid

-- Backing store: 256 entries of 4 bytes each
local backingStore = {}   -- backingStore[0..255][1..4]
local bxWritePos = 0      -- circular write position (0-255)

-- Output buffers
local output = {}         -- current line output (array of 4-byte entries)
local lastLine = {}       -- previous line output (for delta references)

-- Delta/offset table for CopyFromBack
local deltaTable = { -1, -2, -4, -8, 1, 0 }
```

### Bit Reading (MSB-first within GC)

Unlike PKWare DCL, GC data reads bits **MSB-first**:

```lua
function readBit()
    if bitsLeft == 0 then
        -- Read 16-bit value as little-endian from stream
        local lo = readByte()
        local hi = readByte()
        bitBuffer = (hi << 8) | lo
        bitsLeft = 16
    end
    bitsLeft = bitsLeft - 1
    local bit = (bitBuffer >> bitsLeft) & 1
    return bit
end
```

### Nibble Reading

Many operations work on **nibbles** (4-bit values). Bytes are split into two nibbles, high nibble first:

```lua
function readNibble()
    if hasNibble then
        hasNibble = false
        return nibbleBuffer
    else
        local byte = readByte()
        nibbleBuffer = byte & 0x0F
        hasNibble = true
        return (byte >> 4) & 0x0F
    end
end
```

### Huffman Codes

The decoder reads variable-length codes MSB-first:

| Binary Code | Operation        | Description                                    |
|-------------|------------------|------------------------------------------------|
| `10`        | SkipSingle       | Leave 4-byte entry unchanged (copy from prev)  |
| `00`        | CopyFromBack     | Copy from relative position in current line    |
| `01`        | CopySkipTable    | Read nibble count + nibble index, selective copy|
| `110`       | CopyAndStore     | Read 4 nibbles, write entry, store in backing  |
| `1110`      | CopyMoveTable    | Read 4 nibbles, write entry, advance position  |
| `1111`      | CopyFromBxTable  | Read index nibble, copy from backing store     |

### Operation Details

#### SkipSingle (`10`)
Copy the 4-byte entry from the corresponding position in `lastLine` to `output`. This implements inter-line prediction.

#### CopyFromBack (`00`)
Read a 3-bit index (MSB-first) into `deltaTable = {-1, -2, -4, -8, 1, 0}`:
- If index 0-4: copy the 4-byte entry from `output[currentPos + delta]` 
- If index 5 (delta=0): read one nibble as a signed offset, copy from `output[currentPos + nibbleOffset]`

#### CopySkipTable (`01`)
1. Read one nibble → `count` (how many of the 4 bytes to copy from `lastLine`)
2. For each bit set in `count` (from bit 3 down to bit 0), read a nibble and place it at the corresponding byte position
3. Remaining bytes come from `lastLine`

#### CopyAndStore (`110`)
1. Read 4 nibbles → assemble into the 4-byte entry
2. Write to output at current position
3. Store in backing store at `bxWritePos`, advance `bxWritePos = (bxWritePos + 1) & 0xFF`

#### CopyMoveTable (`1110`)
Same as CopyAndStore, but does NOT store in backing store. Just reads 4 nibbles and writes them.

#### CopyFromBxTable (`1111`)
1. Read 2 nibbles → 8-bit index into backing store
2. Copy the 4-byte entry from `backingStore[index]` to output

### Planar to Pixel Conversion

Each 4-byte entry encodes **8 pixels** in planar format (4 planes, 1 bit per pixel per plane):

```lua
function planarToPixels(entry)
    -- entry = {byte0, byte1, byte2, byte3} (4 planes)
    local pixels = {}
    for bit = 7, 0, -1 do
        local color = 0
        for plane = 0, 3 do
            if entry[plane + 1] & (1 << bit) ~= 0 then
                color = color | (1 << plane)
            end
        end
        pixels[8 - bit] = color  -- 4-bit color index (0-15)
    end
    return pixels
end
```

### Full Line Decoding

```
for each line (0 to height-1):
    copy output → lastLine
    for each entry position (0 to entriesPerLine-1):
        read Huffman code
        execute corresponding operation
    convert planar entries to pixel colors using palette
```

## 2.4 MCG.VOL (Tileset Sprites)

- 14 tilesets total
- Each tile: 32×32 pixels
- **1 byte per pixel** (raw, uncompressed, VGA palette index)
- Each tile = 1024 bytes
- Tilesets are variable-length arrays of tiles

## 2.5 MED.VOL (Map Data)

Each map chunk has:
- **MD Header** (96 bytes): map metadata
- **Tile Data**: 2D grid of tile indices
- **Trigger Data**: event trigger definitions
- **Footer** (256 bytes): additional map data

## 2.6 EMI.VOL (Music)

OPL/AdLib FM music format:
- Instrument bank at start
- EM entries contain note/timing data
- Standard OPL register writes

---

## 2.3 CODE scripts, IC constants and VOC sound (2026-10-17)

Verified directly against `/Users/gabriel/Desktop/ags/COBRA`, independently of
external format documentation:

- `CODE.VOL`: seven nonempty entries, 212,627 bytes in total. High bytes decode
  as `(0x11F - byte) modulo 256`; CR, LF and TAB are unencoded. The result is
  complete authoring text with English developer comments and Spanish dialogue
  in this copy. CP850 conversion follows deobfuscation. Preserve custom font
  placeholders and speaker/variable markup rather than guessing substitutions.
  Lines starting `*` plus digits delimit 856 scenes. Repeated labels require
  ordinal scene resource IDs. Complete-script resources also retain preambles.
- `ICP.VOL`: nine IC entries. Offset 4 is a LE word containing the padded
  constant section size; add the 16-byte header to get the bytecode start.
  Walk `u16 VM_address, u16 payload_length, payload` records from offset 16
  until 0xFFFF padding. Do not treat VM addresses as archive offsets or guess
  strings inside binary records. Whole NUL-terminated ASCII constants with
  letters yield 98 strings across eight entries: names, credits, shop signs,
  lock messages and combat messages. Other constants and bytecode are not
  decoded, and this is not a compiled-dialogue decompiler.
- `PCM1.VOL` through `PCM6.VOL`: 155 VOC resources. Every entry has the Creative
  Voice File signature and a terminator block. Across the archives there are
  210 type-1 PCM blocks (codec 0), 49 type-3 silence blocks, 15 type-6 loop starts
  and 15 type-7 loop ends. All are unsigned 8-bit mono. All blocks in each clip
  use a consistent sample rate; derive it from `1,000,000 / (256 - time_constant)`.
  Silence length is `u16 + 1` samples. Preview/export emits each loop body once,
  including infinite loops. Reject truncated blocks, unsupported codecs,
  unbalanced loops and sample-rate changes.

The Lua regression harness checks synthetic malformed data and can load all
286 existing images, 871 text resources (7 complete scripts + 856 scenes + 8
constant tables) and 155 sounds. The optional output directory exports text
without adding commercial assets to the repository.


# Part 3: Sierra SCI Resource Format

## 3.1 Overview & Version History

Source: [ScummVM resource.cpp, resource.h, resource_intern.h](https://github.com/scummvm/scummvm/tree/master/engines/sci/resource)

Sierra's **Script Creation Interpreter (SCI)** engine evolved through many versions:

| Version          | Era        | Games                                              |
|------------------|------------|-----------------------------------------------------|
| SCI0             | 1988-1989  | KQ4, LSL2, PQ2, SQ3                                |
| SCI01            | 1989-1990  | KQ1SCI, LSL3, QFG1, Iceman                         |
| SCI1 Early       | 1990       | KQ5 (floppy), SQ4 (floppy), Jones                  |
| SCI1 Middle      | 1991       | KQ5 CD, LSL5                                        |
| SCI1 Late        | 1991-1992  | QFG1VGA, EcoQuest, PEPPER                           |
| SCI1.1           | 1992-1993  | KQ6, LSL6, QFG3, SQ5, GK1                          |
| SCI2             | 1993-1994  | GK1CD (early SCI2 games)                            |
| SCI2.1           | 1994-1996  | Phantasmagoria, LSL7, GK2, Torin                    |
| SCI3             | 1996-1998  | LSL7, Lighthouse, RAMA                              |

## 3.2 Resource Map Format

Resource maps tell the engine where to find each resource. The format differs significantly between versions.

### SCI0 Resource Map (`RESOURCE.MAP`)

**Entry format: 6 bytes each**

| Offset | Size | Field     | Description                              |
|--------|------|-----------|------------------------------------------|
| 0x00   | 2    | `id`      | Resource type (high 5 bits) + number (low 11 bits) |
| 0x02   | 4    | `offset`  | Volume number (high bits) + file offset (low bits) |

```lua
function read_sci0_map_entry(data, pos)
    local id = read_uint16le(data, pos)
    local offset_raw = read_uint32le(data, pos + 2)
    
    local resType = (id >> 11) & 0x1F
    local resNumber = id & 0x7FF
    
    -- Volume number is in the top 2-4 bits of offset
    -- For most SCI0 games: top 2 bits = volume
    local volume = offset_raw >> 26       -- upper bits
    local fileOffset = offset_raw & 0x03FFFFFF  -- lower 26 bits
    
    return resType, resNumber, volume, fileOffset
end
```

**Terminator**: The map ends with a 6-byte entry where all bytes are `0xFF` (checking `id == 0xFFFF` suffices, or checking last 4 bytes = `0xFFFFFFFF`).

### SCI1 / SCI1.1 Resource Map

Structured as a **directory** followed by resource entries.

#### Directory Entries (3 bytes each)

| Offset | Size | Field    | Description                              |
|--------|------|----------|------------------------------------------|
| 0x00   | 1    | `type`   | Resource type (0xFF = end of directory)  |
| 0x01   | 2    | `offset` | Offset within map to resource entries (UINT16LE) |

#### SCI1 Resource Entries (6 bytes each)

| Offset | Size | Field     | Description                              |
|--------|------|-----------|------------------------------------------|
| 0x00   | 2    | `number`  | Resource number (UINT16LE)               |
| 0x02   | 4    | `offset`  | Volume (high bits) + file offset (low bits) |

#### SCI1.1 Resource Entries (5 bytes each)

| Offset | Size | Field     | Description                              |
|--------|------|-----------|------------------------------------------|
| 0x00   | 2    | `number`  | Resource number (UINT16LE)               |
| 0x02   | 3    | `offset`  | 24-bit value, actual offset = value << 1 |

The 3-byte offset is read as: `byte0 | (byte1 << 8) | (byte2 << 16)`, then multiply by 2 to get the actual file offset. Volume number is encoded in the top bits.

### SCI2 / SCI3 Resource Map

Uses numbered files: `RESMAP.000`, `RESMAP.001`, etc. paired with `RESSCI.000`, `RESSCI.001`, etc.

**SCI3 entries**: Plain 32-bit absolute offsets, no volume encoding needed (each map corresponds to exactly one volume).

## 3.3 Resource Volume Format

Resource volumes (`RESOURCE.000`, `RESOURCE.001`, etc. or `RESSCI.###`) contain the actual resource data. Each resource entry in the volume has a header:

### SCI0 Volume Entry Header (8 bytes)

| Offset | Size | Field          | Description                            |
|--------|------|----------------|----------------------------------------|
| 0x00   | 2    | `resId`        | Type (high bits) + number (low bits)   |
| 0x02   | 2    | `packedSize`   | Compressed size + 4 (includes header)  |
| 0x04   | 2    | `unpackedSize` | Decompressed size                      |
| 0x06   | 2    | `compression`  | Compression method                     |

**Note**: `packedSize` in SCI0 includes the 4 bytes of `packedSize` + `unpackedSize` fields themselves. Actual data size = `packedSize - 4`.

### SCI1 Volume Entry Header (9 bytes)

| Offset | Size | Field          | Description                            |
|--------|------|----------------|----------------------------------------|
| 0x00   | 1    | `resType`      | Resource type                          |
| 0x01   | 2    | `resNumber`    | Resource number (UINT16LE)             |
| 0x03   | 2    | `packedSize`   | Compressed size + 4                    |
| 0x05   | 2    | `unpackedSize` | Decompressed size                      |
| 0x07   | 2    | `compression`  | Compression method                     |

### SCI1.1 Volume Entry Header (9 bytes)

Same layout as SCI1, but `packedSize` does NOT have the +4 adjustment. The packed size is the actual compressed data size.

### SCI32 (SCI2/2.1/3) Volume Entry Header (13 bytes)

| Offset | Size | Field          | Description                            |
|--------|------|----------------|----------------------------------------|
| 0x00   | 1    | `resType`      | Resource type                          |
| 0x01   | 2    | `resNumber`    | Resource number (UINT16LE)             |
| 0x03   | 4    | `packedSize`   | Compressed size (UINT32LE)             |
| 0x07   | 4    | `unpackedSize` | Decompressed size (UINT32LE)           |
| 0x0B   | 2    | `compression`  | Compression method                     |

## 3.4 Compression Types

| Code | SCI0 Meaning | SCI1+ Meaning | Description                           |
|------|-------------|---------------|---------------------------------------|
| 0    | None         | None          | Uncompressed data                     |
| 1    | LZW          | Huffman       | SCI0: LZW (LSB), SCI1+: Huffman tree |
| 2    | Huffman      | LZW1          | SCI0: Huffman, SCI1+: LZW (MSB)      |
| 3    | —            | LZW1+View     | LZW1 + view reordering post-process  |
| 4    | —            | LZW1+Pic      | LZW1 + pic reordering post-process   |
| 18   | —            | DCL           | PKWare DCL Implode                    |
| 19   | —            | DCL           | PKWare DCL Implode (alternate)        |
| 20   | —            | DCL           | PKWare DCL Implode (alternate)        |
| 32   | —            | STACpack      | STACpack/LZS compression (SCI32)      |

**Note**: Compression codes 18, 19, 20 all map to DCL decompression. Code 32 (STACpack) uses a different LZS-based algorithm with 7-bit and 11-bit offsets.

### SCI0 LZW Decompressor

- Bit reading: **LSB-first**
- Initial code size: 9 bits
- Dictionary: 4096 entries max
- Code 256 = reset dictionary
- Code 257 = end of stream
- Code size increases at power-of-2 boundaries (512, 1024, 2048, 4096)

### SCI1 LZW1 Decompressor

- Bit reading: **MSB-first**
- Same dictionary structure as SCI0 LZW
- **"Early change" bug**: Code size increases one code earlier than standard LZW
  - Increase at (boundary - 1): 511, 1023, 2047, 4095

```lua
-- Key difference between SCI0 LZW and SCI1 LZW1:
-- SCI0: codeLimit = 1 << codeBitLength (e.g., 512, 1024, 2048, 4096)
-- SCI1: codeLimit = (1 << codeBitLength) - 1 (e.g., 511, 1023, 2047, 4095)
```

### SCI Huffman Decompressor

Structure of the Huffman tree:
1. First byte: `numNodes` (number of node pairs)
2. Second byte: terminator symbol (OR'd with 0x100 to distinguish from normal bytes)
3. `numNodes * 2` bytes: the tree node data

Each node pair is 2 bytes: `[value, children]`:
- `children == 0`: leaf node, `value` is the decoded byte
- `children != 0`: branch node
  - Bit 0 → go to child at `(children >> 4) * 2` offset
  - Bit 1 → go to child at `(children & 0x0F) * 2` offset
  - If child offset is 0 when taking branch, read next 8 bits as literal | 0x100

### STACpack/LZS Decompressor (SCI32)

Used in SCI2/2.1/3 games. Based on Stac Electronics LZS:

```
while not done:
    if getBitsMSB(1) == 1:  -- compressed
        if getBitsMSB(1) == 1:  -- 7-bit offset
            offset = getBitsMSB(7)
            if offset == 0: break  -- end marker
            length = getCompLen()
            copy(offset, length)
        else:  -- 11-bit offset
            offset = getBitsMSB(11)
            length = getCompLen()
            copy(offset, length)
    else:  -- literal byte
        output getByteMSB()
```

`getCompLen()` encoding:
- `00` → 2
- `01` → 3
- `10` → 4
- `1100` → 5
- `1101` → 6
- `1110` → 7
- `1111` + nibbles → 8 + sum of 4-bit nibbles until nibble ≠ 15

## 3.5 Resource Types

### SCI0/SCI1 Resource Type Mapping

| Type ID | Name     | File Suffix | Description                    |
|---------|----------|-------------|--------------------------------|
| 0       | view     | .v56        | Animated sprites/characters    |
| 1       | pic      | .p56        | Background pictures            |
| 2       | script   | .scr        | Game logic scripts             |
| 3       | text     | .tex        | Text strings                   |
| 4       | sound    | .snd        | Music/sound effects            |
| 5       | memory   | —           | (internal use)                 |
| 6       | vocab    | .voc        | Vocabulary/parser data         |
| 7       | font     | .fon        | Bitmap fonts                   |
| 8       | cursor   | .cur        | Mouse cursors                  |
| 9       | patch    | .pat        | Resource patches               |
| 10      | bitmap   | .bit        | Bitmap graphics (SCI1.1+)      |
| 11      | palette  | .pal        | Color palettes (SCI1+)         |
| 12      | cdaudio  | .cda        | CD audio track references      |
| 13      | audio    | .aud        | Digital audio                  |
| 14      | sync     | .syn        | Lip-sync data                  |
| 15      | message  | .msg        | Message/dialog resources       |
| 16      | map      | .map        | Audio map                      |
| 17      | heap     | .hep        | Heap data (SCI1.1+)            |

### SCI2.1 Resource Type Mapping (differs from SCI0!)

| Type ID | Name      | Description                          |
|---------|-----------|--------------------------------------|
| 0       | view      | Same                                 |
| 1       | pic       | Same                                 |
| 2       | script    | Same                                 |
| 3       | animation | **Changed** (was text in SCI0)       |
| 4       | sound     | Same                                 |
| 5       | etc       | **Changed** (was memory in SCI0)     |
| 6       | vocab     | Same                                 |
| 7       | font      | Same                                 |
| 8       | cursor    | Same                                 |
| 9       | patch     | Same                                 |
| 10      | bitmap    | Same                                 |
| 11      | palette   | Same                                 |
| ...     | ...       | ...                                  |

## 3.6 Version Detection Algorithm

ScummVM determines the SCI version by analyzing the resource map structure:

### Step 1: Check for SCI0

Read the last 6 bytes of RESOURCE.MAP. If the last 4 bytes are `0xFFFFFFFF` (and byte at -5 from end is also 0xFF), it's SCI0 format.

### Step 2: Analyze Directory Structure

If not SCI0, read the first few directory entries (3 bytes each: type + offset):
1. If first 4 bytes match SCI0 pattern (could be a valid 6-byte SCI0 entry), it's SCI0
2. Otherwise, analyze directory offsets to distinguish SCI1 from SCI1.1:
   - Read directory entries until type == 0xFF
   - For each type, the offset points to resource entries
   - SCI1: entries are 6 bytes, SCI1.1: entries are 5 bytes
   - Check entry counts: `(nextOffset - thisOffset) / entrySize` should be whole number

### Step 3: Volume Version Detection

Read the first resource header from the volume file and check:
- If first 2 bytes decode to a valid SCI0 entry (type+number match map), it's SCI0
- Test each format (SCI0/SCI1/SCI11/SCI32) by reading a header and checking if compression type is valid (0, 1, 2, 3, 4, 18, 19, 20, or 32)

### View Type Detection

To distinguish EGA from VGA views:
```lua
-- Read byte at offset 1 of a view resource
local viewByte = viewData[2]  -- 1-indexed

if viewByte == 0x80 then
    -- VGA view (8-bit colors, 256 palette)
elseif viewByte == 0x00 then
    -- EGA or Amiga view (4-bit colors, 16 palette)
    -- Further heuristics needed to distinguish EGA from Amiga
end
```

## 3.7 SCI Pic Resource Format

Source: [ScummVM picture.cpp](https://github.com/scummvm/scummvm/blob/master/engines/sci/graphics/picture.cpp)

### Format Detection

```lua
local headerSize = read_uint16le(picData, 0)
if headerSize == 0x26 then
    -- SCI 1.1 VGA picture (bitmap + vector)
else
    -- SCI0/SCI1 vector picture (all versions)
end
```

### SCI 1.1 VGA Picture Header (0x26 = 38 bytes)

| Offset | Size | Field                | Description                       |
|--------|------|----------------------|-----------------------------------|
| 0x00   | 2    | headerSize           | Always 0x0026 (38)                |
| 0x02   | 1    | unknown              |                                   |
| 0x03   | 1    | priorityBandCount    | Always 14 for SCI1.1              |
| 0x04   | 1    | hasCel               | Non-zero if bitmap cel present    |
| 0x05   | 1    | unknown              |                                   |
| 0x10   | 4    | vectorDataOffset     | Offset to vector drawing commands |
| 0x1C   | 4    | paletteDataOffset    | Offset to VGA palette             |
| 0x20   | 4    | celHeaderOffset      | Offset to cel (bitmap) header     |
| 0x28   | var  | priorityBandData     | 14 × UINT16LE priority bands      |

### Vector Drawing Opcodes

SCI pic resources use a **vector drawing** language. These opcodes apply to ALL SCI versions (SCI0 through SCI1.1):

| Opcode | Name              | Arguments                               |
|--------|-------------------|-----------------------------------------|
| 0xF0   | SET_COLOR         | 1 byte: color index                    |
| 0xF1   | DISABLE_VISUAL    | No args (sets color to 0xFF = disabled) |
| 0xF2   | SET_PRIORITY      | 1 byte: priority (low 4 bits)          |
| 0xF3   | DISABLE_PRIORITY  | No args                                 |
| 0xF4   | SHORT_PATTERNS    | Abs coord + pattern data, then rel coords |
| 0xF5   | MEDIUM_LINES      | Abs coord, then medium relative coords  |
| 0xF6   | LONG_LINES        | Abs coord, then absolute coords         |
| 0xF7   | SHORT_LINES       | Abs coord, then short relative coords   |
| 0xF8   | FILL              | Absolute coordinates for flood fill     |
| 0xF9   | SET_PATTERN       | 1 byte: pattern code                    |
| 0xFA   | ABSOLUTE_PATTERN  | Pattern with absolute coordinates       |
| 0xFB   | SET_CONTROL        | 1 byte: control color (low 4 bits)     |
| 0xFC   | DISABLE_CONTROL   | No args                                 |
| 0xFD   | MEDIUM_PATTERNS   | Pattern with medium relative coords     |
| 0xFE   | EXTENDED (OPX)    | Sub-opcode follows                      |
| 0xFF   | TERMINATE         | End of picture data                     |

Any byte value < 0xF0 is treated as coordinate data for the current operation.

### Coordinate Encoding

**Absolute coordinates** (3 bytes):
```lua
local byte1 = data[pos]; pos = pos + 1
local byte2 = data[pos]; pos = pos + 1
local byte3 = data[pos]; pos = pos + 1
local x = byte2 + ((byte1 & 0xF0) << 4)  -- 0-319
local y = byte3 + ((byte1 & 0x0F) << 8)  -- 0-189 or 0-199
```

**Short relative coordinates** (1 byte):
```lua
local pixel = data[pos]; pos = pos + 1
local dx, dy
if pixel & 0x80 ~= 0 then
    dx = -((pixel >> 4) & 7)
else
    dx = (pixel >> 4) & 0xF
end
if pixel & 0x08 ~= 0 then
    dy = -(pixel & 7)
else
    dy = pixel & 7
end
-- x = x + dx, y = y + dy
```

**Medium relative coordinates** (2 bytes):
```lua
local byte1 = data[pos]; pos = pos + 1
local byte2 = data[pos]; pos = pos + 1
local dy, dx
if byte1 & 0x80 ~= 0 then
    dy = -(byte1 & 0x7F)
else
    dy = byte1
end
if byte2 & 0x80 ~= 0 then
    dx = -(128 - (byte2 & 0x7F))
else
    dx = byte2
end
```

### Extended Opcodes (0xFE)

#### EGA Extended Opcodes

| Sub-op | Name                    | Description                              |
|--------|-------------------------|------------------------------------------|
| 0      | SET_PALETTE_ENTRIES     | Set individual EGA palette entries        |
| 1      | SET_PALETTE             | Set entire EGA palette (40 bytes)         |
| 2-6    | MONO0-MONO4             | Monochrome display modes                  |
| 7      | EMBEDDED_VIEW           | Embedded sprite inside picture           |
| 8      | SET_PRIORITY_TABLE      | 14 bytes of priority band data           |

#### VGA Extended Opcodes

| Sub-op | Name                    | Description                              |
|--------|-------------------------|------------------------------------------|
| 0      | SET_PALETTE_ENTRIES     | Set VGA palette entries                   |
| 1      | EMBEDDED_VIEW           | Embedded bitmap/cel in picture           |
| 2      | SET_PALETTE             | Full 256-color VGA palette (1028 bytes)  |
| 3      | PRIORITY_TABLE_EQDIST   | Equidistant priority bands (4 bytes)     |
| 4      | PRIORITY_TABLE_EXPLICIT | Explicit priority bands (14 bytes)       |

### Pattern Drawing

The `SET_PATTERN` opcode sets a pattern code byte:

```lua
local patternCode = data[pos]; pos = pos + 1
-- Bit 0-2: pen size (0-7, radius of pattern)
-- Bit 4: 0 = circle, 1 = rectangle
-- Bit 5: 0 = solid, 1 = textured (use texture lookup table)
```

Constants:
```lua
SCI_PATTERN_CODE_PENSIZE      = 0x07
SCI_PATTERN_CODE_RECTANGLE    = 0x10
SCI_PATTERN_CODE_USE_TEXTURE  = 0x20
```

### Flood Fill Algorithm

The fill at 0xF8 uses a **stack-based** scanline flood fill:
1. Start at (x, y), determine the "search" color at that pixel
2. For visual fills: only fill if target color differs from current screen pixel AND screen pixel is white
3. For priority fills: only fill if target priority differs AND screen priority is 0
4. Expand left and right along the scanline
5. Push adjacent unfilled pixels from rows above and below

### SCI Screen Dimensions

| Version     | Resolution | Notes                              |
|-------------|------------|-------------------------------------|
| SCI0/SCI1   | 320×200    | 160×200 in EGA undithered mode     |
| SCI1 Mac    | 480×300    | 1.5× upscale                       |
| SCI1.1      | 320×200    | With optional 640×400 upscale      |
| SCI2/2.1/3  | 640×480    | Full VGA resolution                 |

### Three Screen Layers

SCI maintains three separate screen buffers:
1. **Visual** (color): What the player sees
2. **Priority**: Determines draw order / walkability (0-15)
3. **Control**: Defines interactive regions (0-15)

All vector drawing operations can write to any combination of these three layers simultaneously, controlled by the current color, priority, and control state (0xFF = disabled for that layer).

## 3.8 SCI View Resource Format

Views contain animated sprites organized as loops (directions/animation sequences) containing cels (individual frames).

### View Header

```lua
-- After decompression, read the view header
local celDataOffset = read_uint16le(data, 0) + 2  -- offset to cel length table
local numLoops = data[3]         -- number of animation loops
local loopPresent = data[4]      -- which loops have unique data
local loopMask = read_uint16le(data, 5)  -- bitmask of "not present" loops
local unknown = read_uint16le(data, 7)
local paletteOffset = read_uint16le(data, 9)
local totalCels = read_uint16le(data, 11)
```

### View Byte 1 Detection

```lua
if data[2] == 0x80 then
    -- VGA view: 8-bit colors, 256-color palette
    -- VIEW_HEADER_COLORS_8BIT
elseif data[2] == 0x00 then
    -- EGA view: 4-bit colors
end
```

### Cel Header (8 bytes per cel after reordering)

| Offset | Size | Field      | Description                          |
|--------|------|------------|--------------------------------------|
| 0x00   | 2    | width      | Cel width in pixels (UINT16LE)       |
| 0x02   | 2    | height     | Cel height in pixels (UINT16LE)      |
| 0x04   | 1    | displaceX  | Horizontal hotspot offset            |
| 0x05   | 1    | displaceY  | Vertical hotspot offset              |
| 0x06   | 1    | clearColor | Transparent color index              |
| 0x07   | 1    | (padding)  |                                      |

### Cel RLE Encoding

Cel pixel data uses an RLE scheme:

```lua
-- RLE decoding
while outputPos < width * height do
    local command = rleData[rlePos]; rlePos = rlePos + 1
    
    local commandType = command & 0xC0
    
    if commandType == 0x00 or commandType == 0x40 then
        -- Copy N literal pixels from pixel data stream
        local count = command  -- (command & 0x3F for some variants)
        for i = 1, count do
            output[outputPos] = pixelData[pixPos]
            pixPos = pixPos + 1
            outputPos = outputPos + 1
        end
    elseif commandType == 0x80 then
        -- Copy 1 pixel from pixel data
        output[outputPos] = pixelData[pixPos]
        pixPos = pixPos + 1
        outputPos = outputPos + 1
    else -- 0xC0
        -- Skip (transparent) - no pixel data consumed
    end
end
```

### LZW1+View Post-Processing

When compression type = 3 (kCompLZW1View), the raw LZW1 output is reordered:
1. First pass: extract header, loop headers, and cel headers
2. Separate RLE data and pixel data streams
3. Decode each cel using interleaved RLE+pixel streams
4. If palette present (paletteOffset > 0), append "PAL" header + 256 identity mapping + 1024-byte RGBX palette

### LZW1+Pic Post-Processing

When compression type = 4 (kCompLZW1Pic), the raw LZW1 output is reordered:
1. Extract embedded view size and start offset
2. Extract palette (256 × 4-byte RGBX)
3. Rearrange data with proper OPX opcodes for palette and embedded view
4. Decode view cel data using RLE

## 3.9 File Naming Conventions

### SCI0/SCI1

- `RESOURCE.MAP` — Resource map
- `RESOURCE.000`, `RESOURCE.001`, ... — Resource volumes

### SCI1.1+

- `RESOURCE.MAP` — Resource map
- `RESOURCE.000`, etc. — Resource volumes

### SCI2/SCI3

- `RESMAP.000`, `RESMAP.001`, ... — Per-volume resource maps
- `RESSCI.000`, `RESSCI.001`, ... — Resource volumes

### Patch Files (Override Resources)

Individual resource files on disk can override volume resources:

| Type    | Suffix  |
|---------|---------|
| view    | .v56    |
| pic     | .p56    |
| script  | .scr    |
| text    | .tex    |
| sound   | .snd    |
| vocab   | .voc    |
| font    | .fon    |
| cursor  | .cur    |
| patch   | .pat    |
| bitmap  | .bit    |
| palette | .pal    |
| cdaudio | .cda    |
| audio   | .aud    |
| sync    | .syn    |
| message | .msg    |
| map     | .map    |
| heap    | .hep    |

---

# Appendix A: Summary of All Compression Algorithms

| Format     | Algorithm       | Bit Order | Dictionary   | Trees          |
|------------|-----------------|-----------|-------------|----------------|
| AITD PAK   | PKWare DCL      | LSB-first | 1K/2K/4K    | Fixed Shannon-Fano |
| AITD PAK   | zlib Deflate    | —         | 32K         | Dynamic Huffman |
| Neverhood BLB | PKWare DCL (blast) | LSB-first | 1K/2K/4K | Fixed Shannon-Fano |
| GC (Cobra) | Custom Huffman+LZ | MSB-first | 256×4 backing | Fixed 6-code  |
| SCI0       | LZW             | LSB-first | 4096 entries | —              |
| SCI1+      | LZW1            | MSB-first | 4096 entries | — (early change) |
| SCI0       | Huffman         | MSB-first | —           | Embedded tree   |
| SCI1.1     | DCL             | LSB-first | 1K/2K/4K    | Fixed Shannon-Fano |
| SCI32      | STACpack/LZS    | MSB-first | Window      | —              |

# Appendix B: Key Differences Between Formats

## PKWare DCL vs zlib Deflate
- DCL uses **fixed** Huffman trees hardcoded in the decompressor; deflate transmits trees in the stream
- DCL reads bits **LSB-first**; deflate also reads LSB-first but has different tree encoding
- DCL dictionary is 1K/2K/4K; deflate uses 32K
- DCL has separate binary/ASCII modes; deflate has no such distinction
- They are **completely incompatible** formats

## SCI0 LZW vs SCI1 LZW1
- SCI0: LSB-first bit reading
- SCI1: MSB-first bit reading  
- SCI1 has "early change" bug: code size increases one step earlier
- Both use same dictionary structure (4096 entries, codes 256=reset, 257=terminate)

## GC vs Standard Image Formats
- GC uses 4-bit **planar** encoding (like EGA), not chunky
- Custom Huffman with only 6 fixed codes, not a general-purpose tree
- Inter-line prediction (delta from previous line)
- 256-entry circular backing store for dictionary-like repetition

---

# Part 4: Tinsel (Discworld 1 & 2) Resource Format

Source: ScummVM `engines/tinsel/` — `handle.cpp`, `object.cpp`, `graphics.cpp`, `palette.cpp`.
Engine script: `scripts/engines/tinsel/engine.lua`

## 4.1 File Layout

An `index` file holds one fixed size record per data file.

| Game | Record size | Layout |
|------|-------------|--------|
| Discworld 1 | 20 bytes | `name[12]`, `u32 filesize`, 4 reserved |
| Discworld 2 | 24 bytes | `name[12]`, `u32 filesize`, 4 reserved, `u32 flags2` |

Each `.SCN` data file is a singly linked list of chunks:

```
u32 chunkType
u32 nextChunkAbsoluteOffset    -- 0 terminates the list
```

`CHUNK_IMAGE` (0x33340006) is a flat array of 16 byte records:

| Offset | Size | Field |
|--------|------|-------|
| 0x00 | 2 | `i16 width` |
| 0x02 | 2 | `u16 height` — top 2 bits are the packing type, rest is the real height |
| 0x04 | 2 | `i16 aniX` |
| 0x06 | 2 | `i16 aniY` |
| 0x08 | 4 | `u32 hImgBits` — SCNHANDLE to the pixel data |
| 0x0C | 4 | `u32 hImgPal` — SCNHANDLE to the palette |

`CHUNK_PALETTE` (0x33340005) holds one or more palettes, each an `i32 numColors`
followed by `numColors` `COLORREF` values in `0x00BBGGRR` order.

## 4.2 SCNHANDLE

A handle packs a file index in the high bits and a byte offset in the low bits.

| Game | Index | Offset |
|------|-------|--------|
| Discworld 1 | `h >> 23` | `h & 0x7FFFFF` |
| Discworld 2 | `h >> 25` | `h & 0x1FFFFFF` |

Note the palette handle resolves to a *different file* than the image handle
in general, so it must be resolved independently.

## 4.3 Choosing a Decoder

Tinsel picks the decoder from the object type byte, which lives in the scene
object table and **not** in the IMAGE record. `InitObject` merges the packing
type into the object flags:

```c
pObj->flags = DMA_CHANGED | pInitTbl->objFlags;
pObj->flags |= pImg->imgHeight & C16_FLAG_MASK;   // C16_FLAG_MASK = 0xC000
```

then `DrawObject` branches on the result:

| Condition | Decoder | Encoding |
|-----------|---------|----------|
| `packType != 0` (height top 2 bits) | `PackedWrtNonZero` | 1/2/3 run length packing |
| `typeId` 0x01, 0x41, 0x02, 0x11, 0x42, 0x51 | `t2WrtNonZero` | byte RLE |
| `typeId` 0x08, 0x48 | `WrtAll` | raw 8bpp (backgrounds) |
| `typeId` 0x04, 0x44 | `WrtConst` | solid fill |
| `typeId` 0x84, 0xC4 | `WrtTrans` | translucent rectangle |

Because the type byte is not available to a standalone extractor, a
`c16 == 0` image has to be classified indirectly. For **Discworld 1** the block
list of the playfield always sits at bits offset 24, and 147 of the 149 files
carry exactly one large image there (`DW.SCN` and `OBJECTS.SCN` contribute only
small false positives). For **Discworld 2** two rules apply together: the image
must be playfield sized (at least 600x200) *and* its `width * height` bytes must
actually be present at the bits offset. The second rule is what separates the
real backgrounds from the large RLE cutscene frames in `BONEDIE`, `BONEDIE2`,
`COMPUTER`, `FILMSET` and `GIMLETS` — a pure size test misclassifies all six.

## 4.4 Discworld 1 Decoding (`WrtNonZero`)

The block matrix base is read from the **start of the data file**, not from the
image data:

```
charBase    = u32le(file, 0x10)
transOffset = u32le(file, 0x14)
```

The pixel data is a list of `i16` block indexes, `ceil(w/4) * ceil(h/4)` of them.
A positive index is an opaque block at `charBase + index*16`; a negative index
is transparent, masked with `0x7FFF`, and read at
`charBase + (transOffset + index)*16`, writing only non-zero pixels. An index
that masks to zero is skipped entirely.

## 4.5 Discworld 2 Decoders

**`WrtAll` (backgrounds)** — `width * height` bytes, row major, no framing.

**`t2WrtNonZero` (RLE sprites)** — per scan line, the opcode's top bit selects a
run of the following colour (colour 0 transparent) or a literal run of that many
bytes. Note the run length is `opcode & 0x7F`, so an opcode of 0x80 is a
zero-length run, not a literal.

**`PackedWrtNonZero` (packing types 1/2/3)** — type 1 uses base colour `0xF0`,
type 2 uses `0xE0`, type 3 carries a `u8` colour count followed by that many
palette bytes at the start of the stream. Each row begins with an `xOffset`
skip byte. An opcode's low nibble is the run length and its high nibble selects
the colour; a zero low nibble means the next byte is either a run length of 16+
or a skip/eol pair (`numBytes + opcode == 0` ends the row). A row that reaches
the right edge without an explicit eol is followed by a two byte end marker.

Two implementation traps:

- The stream is variable length, so a `width * height` sized read window is not
  enough; the final run of a row can read past the last pixel.
- For type 3, Tinsel indexes the colour table with the opcode's high nibble
  **without bounds checking it**. Some real images declare fewer colours than
  they reference, so a bounds check turns those images into decode failures
  where Tinsel itself just reads into the following bytes.

## 4.6 Palette Index Shift

Palettes are installed into the video DAC starting at index 1
(`FGND_DAC_INDEX` in `palette.cpp`), leaving index 0 as the background colour.
A 256 colour palette therefore occupies DAC entries 1..255, and pixel value
`n` maps to palette entry `n-1`. Forgetting this shift costs exactly one
palette entry and visibly darkens/misaligns every image.

## 4.7 FILM Reel Animations

Both games retain animation data in `CHUNK_FILM (0x33340008)` and frame lists in
`CHUNK_ANI_FRAME (0x33340007)`. FILM chunks mix several structures, so their
payload is not a flat array. FILM headers contain `i32 fps, i32 numReels` followed
by `(SCNHANDLE mobj, SCNHANDLE script)` pairs. Each MULTI_INIT begins with the
initial multipart shape handle (24 bytes in DW1, 28 bytes in DW2).

A script's ordinary DWORDs reference null-terminated lists of IMAGE handles,
not IMAGE records directly. Control words are 0=end, 1=jump (signed DWORD offset
in words, relative to the operand itself), 2/3/4=horizontal/vertical/both flips,
5/6/7=relative X/Y/XY adjustment, 8=nosleep, 9=unsupported CALL, and 10=hide.
Opcode 11 belongs to sound reels. DW1 reverses adjustments along flipped axes;
DW2 does not. DW1 skips NOSLEEP without consuming a display interval; DW2
consumes an interval with the current shape. Flip state starts clear.

Frame parts share an animation origin; each IMAGE is placed at
`position - anioff`. When flipped, its origin becomes `dimension - 1 - anioff`.
A shared canvas over the sequence preserves alignment, transparent index 0
leaves underlying parts visible, and each part resolves its own palette handle.
Playback uses `floor(24/fps)` game ticks per frame, converted to milliseconds.
The explorer exposes each animated reel independently inside its Sprites file
group. Repeated bytecode states end preview cycles; static/sound reels,
unsupported calls, and invalid or excessive scripts are excluded.

Validated against local ScummVM `film.h`, `anim.cpp`, `multiobj.cpp`, `object.cpp`,
`play.cpp`, and `timers.h`, plus the installed DW1/DW2 data. Catalog discovery
finds 2,311 animated reels in DW1 and 1,078 in DW2. Regression fixtures cover
both versions, multipart frames, offsets, flips, hide, loops and invalid scripts;
100 evenly distributed real animations per game were decoded successfully.

# Part 5: Dark Seed 2 Resource Format

No ScummVM engine exists for Dark Seed 2, so the format was derived from the
game data itself and cross-checked against the Dark Seed II resource tooling at
https://github.com/DrMcCoy/darkseed2-tools (`src/unglue.cpp`).
Engine script: `scripts/engines/darkseed2/engine.lua`
Game location: `ags/DARKSEED2`

## 5.1 Top Level Layout

| File | Purpose |
|------|---------|
| `DARK0001.EXE` | Executable (detection) |
| `GFILE.HDR` | Master index: every archive plus every resource in the game |
| `DS2RUN.HDR` | Datafile header |
| `GL00_NNN.000` | 90 per-room Glue archives (compressed) |
| `GL00__*.000` | 18 bulk Glue archives |
| `*.AVI`, `SNDTRACK/` | Videos and music |

`GFILE.HDR` is the important discovery: a single 211,318 byte file indexes all
9,291 resources, so the whole resource tree can be listed without decompressing
a single byte of the 26 MB of archives.

```
u16 archiveCount   (= 108)
u16 resourceCount  (= 9291)
archiveCount  x 64 byte records, archive name[12] at the record start
resourceCount x 22 byte records:
    u16 archiveIndex      (0-based index into the table above)
    char name[12]
    u32 size
    u32 offset
```

`4 + 108*64 + 9291*22 == 211318` exactly, which is used as a sanity check
before the file is trusted. Names are stored lower case while the files on disk
are upper case, so lookups are case folded. `size`/`offset` are relative to the
**decompressed** archive - `GL00_002.000` is only 159,418 bytes on disk but its
`RM0002.BMP` sits at offset 111,804 with size 308,278.

Verified by decompressing all 108 archives independently and comparing every
one of the 9,291 entries: 0 size/offset mismatches.

## 5.2 Glue Archive Format

```
u16 count
count x { char name[12]; u32 size; u32 offset; }
```

Offsets are absolute within the uncompressed archive, so the data starts at
`2 + count*20`. Whether an archive is compressed is decided the way the
reference tool does it: attempt to read a resource list straight out of the
file, and treat the archive as compressed if that fails (a count that cannot
fit, a name character outside `[A-Za-z0-9._]`, or a resource running past the
end of the file). 85 of the 108 archives are compressed.

## 5.3 Glue Compression

2048 byte physical chunks. The first chunk carries the uncompressed size as a
`u32` at offset 2044, plus 128:

```
uncompressedSize = readU32LE(chunk0, 2044) + 128
```

Each chunk is then a run of 17 byte groups: one mask byte driving eight
operations. A set mask bit copies two literal bytes; a clear bit reads a `u16`:

```
offset = (raw >> 4) + 1        -- 1..4096
count  = (raw & 0xF) + 3       -- 3..18
```

When the mask byte has been fully shifted out (eight operations done, 17 input
bytes consumed) the next mask byte is read. A trailing partial chunk rounds its
input length up to a whole number of 17 byte groups.

Two details matter for a correct port:

* The reference unconditionally writes 8 bytes per back-reference and then 10
  more when `count > 8`, so it writes up to 15 bytes past the logical end of a
  short run. Only the first `count` bytes are meaningful, and a faithful port
  should append exactly `count` bytes.
* Decompression stops a little short of the declared size (typically ~125
  bytes) because the tail chunk cannot be completed. The reference allocates
  the declared size and leaves the remainder zeroed, so the output must be
  padded to `uncompressedSize` rather than treated as a short read.

Back-references never reach further back than 4096 bytes, so a small sliding
window is enough; a 1.6 MB archive is the largest in this game.

## 5.4 Images

All 3,826 images are 8-bit Windows BMPs, but they come in two quite different
encodings, only one of which is a normal BMP:

| Variant | Count | `dataoff` | Palette in file |
|---------|-------|-----------|-----------------|
| 8bpp BI_RGB (`biCompression = 0`) | 211 | 1,078 | yes, 256 entries |
| 8bpp scanline (`biCompression = 2`) | 3,614 | 54 | none (`biClrUsed = 0`) |
| 4bpp BI_RGB (`biCompression = 0`) | 1 (`IBCARD.BMP`) | 118 | yes, 16 entries |

The `biCompression = 2` images are **not** run length encoded, despite the tag
and despite what the `00 00` byte pairs at each row boundary look like. Decoding
them as `BI_RLE8` runs the rows hundreds of thousands of pixels past the image
width. The real layout is a per-row prefix, verified by parsing every one of the
3,614 images with zero failures, zero leftover bytes, and exactly `h` rows each:

```
u16 xOffset      -- pixels to skip at the left of the row, 0..w
u16 length       -- number of pixel bytes that follow, 1..w
byte pixels[length]   -- raw 8bpp, no padding
```

repeated for all `abs(h)` rows in BMP row order (bottom-up for positive
heights, top-down for negative heights). This was derived from `002BTN01.BMP`
(340x55, 18,920 pixel bytes, exactly 55 uniform 344-byte rows of
`00 00 54 01` + 340 raw pixels) and confirmed on cropped rows by `101CHR01.BMP`,
a perspective-projected chair whose rows run from `xOffset = 6, length = 68` at
the top to `xOffset = 0, length = 86` in the middle and back down to
`length = 31` at the base. 2,787 of the 3,614 images have at least one cropped
row; the format exists precisely to store those trapezoids compactly.

Because `dataoff = 54` leaves no room before the pixel data, those 3,614 images
carry **no palette whatsoever**. Only palette quads before `dataoff` are real;
reading the pixel stream as a colour table is incorrect. Scene sprites use
the embedded palette of the room background in the same archive. Shared
walking/action sprites use `FIX.PAL` (1024 bytes of BGR0 quads, 8-bit channels).
Comparisons with RM0101/RM0102/RM0802 show indices 1..95 agree with FIX.PAL,
while higher colours vary by room. Therefore FIX.PAL is insufficient for scene
objects such as `101CHR01.BMP`, which uses indices up to 236. This corrects
the earlier assumption of a single game-wide palette for all sprites.
The earlier top-down scanline assumption was also incorrect: the walking
character is inverted unless positive-height rows are reversed, as in BI_RGB.

The `RM*.BMP` files (one per room archive) are the room backgrounds: 640x480,
8bpp, uncompressed, with the palette in the header. One asset, `RM0816.BMP`, is
genuinely 640x481 in the data and is decoded as such. `RMAP*.BMP` files are not
backgrounds - they are 64x48 room thumbnails, and the name prefix needs a
`RM%d%d%d%d` match rather than a plain `RM` prefix to tell them apart.

All 3,826 BMP names are unique across the whole game, which is what allows a
resource to be addressed by name alone.

## 5.5 Backgrounds

83 of the 108 archives hold exactly one full-screen image each: 82 at 640x480
and `GL00_816.000` at 640x481. The engine selects them by name (`RM%04d.BMP`)
rather than by geometry, because the geometry is only knowable after
decompressing each archive, and listing must stay cheap.

All 83 are `biCompression = 0`. The engine also lists 3,660 sprite/UI images,
grouped by their source archive, 83 `RMAPdddd.BMP` room thumbnails, and 84
palette resources (83 background palettes plus FIX.PAL). Listing reads only
GFILE.HDR. Individual frames are exposed without inferring animation order or
timing. Cropped regions are filled with index 0; images use the existing indexed
image output with no alpha channel.

Palette-less images automatically borrow their room background palette, falling
back to FIX.PAL in shared archives. Embedded palettes remain authoritative
(including the 4bpp grayscale IBCARD.BMP), unless a user explicitly selects
another palette. The default-palette hook returns a palette only for images
without an embedded colour table. Palette previews and manual overrides are
available through the standard palette selector.

A bounded single-archive cache avoids decompressing the same archive for every
sprite; palette tables are cached separately for the active game folder. BMP
decoding validates header/pixel bounds and rejects cropped rows extending past
the width or truncated scanlines. Synthetic regressions cover cropped and empty
rows, palette overrides, bottom-up/top-down BMPs, 4bpp pixels and malformed
input. `scripts/tests/darkseed2.lua` optionally checks every exposed resource
against the supplied media.

---

# Part 6: Curse of Enchantia RNC Images & Room Backgrounds

No ScummVM engine exists for Curse of Enchantia, so the format was derived from
the game data itself, using the public ProPack source and the RNC method 1
description at http://www.codersnotes.com/solaris/pack/rnc_format.html
Engine script: `scripts/engines/curseofenchantia/engine.lua`
Game location: `ags/CURSE`

## 6.1 Top Level Layout

Every asset is a single flat file under `DATA/`, with no archives and no
directory tree. That makes the whole resource list buildable by directory scan
alone: 56 `.MAP` room backgrounds, 20 `.DAT` files and 6 `.PAL` palettes.

## 6.2 RNC Stream (Rob Northen Compression / ProPack)

Both image containers are RNC streams. The 18-byte header is big-endian:

```
0   'R' 'N' 'C' <method>
4   u32 unpackedSize
8   u32 packedSize
12  u16 unpackedCRC
14  u16 packedCRC
16  2 reserved bytes
18  packed data
```

Both CRCs are CRC-16/ARC (reflected, poly 0xA001). Checking them is what makes
the format trustworthy: a block is only accepted once its packed bytes **and**
its decoded bytes both hash correctly, so any image the engine returns has been
proven correct rather than merely plausible.

| Method | Used by | Shape |
|--------|---------|-------|
| 1 | `CORE.DAT`, `MENU.DAT`, `TITLE.DAT` | Series of sections, each with three Huffman tables (raw run, match offset, match length) and a u16 chunk count |
| 2 | everything else | MSB-first bit reader; literals, matches, and a key that rotates by one bit per literal |

Method 2 is the interesting one for a decoder without bitwise operators: the
running key has to be rotated right, which is why the engine builds a full
`XOR8[a][b]` table from `2*XOR8[a>>1][b>>1] + ((a%2) XOR (b%2))` and does all
256-bit arithmetic in floating point.

## 6.3 `.MAP` Room Backgrounds

A `.MAP` is not a plain RNC stream. It opens with its own colour table:

```
0     576 bytes  palette, 192 RGB triples, six bits per channel
576   2 bytes    unknown
578   u16 count N, then N 16-byte room records (N * 16 bytes)
...   a chain of RNC blocks
```

The chain decodes to 6,400-byte blocks, and `6400 = 32 x 200`: each block is
one **32-pixel-wide vertical strip**, stored left to right. Room width therefore
follows from the strip count, with no width field anywhere in the file.

| File | Strips | Size |
|------|--------|------|
| `GRAVE.MAP` | 4 | 128x200 |
| `BENN.MAP` | 8 | 256x200 |
| `CAVE.MAP` | 10 | 320x200 (one screen) |
| `CAVECOR.MAP` | 20 | 640x200 |
| `SNOWAST2.MAP` | 34 | 1088x200 (widest in the game) |

The first 576 bytes were confirmed to be a palette three independent ways.
1. All components fall in 0..63, the VGA DAC range, so it scales by 4 exactly
   like the standalone `.PAL` files.
2. The header size is always `576 + 2 + N*16`, and the u16 at 578 always equals
   N, so the region is accounted for exactly with no slack.
3. Correlation between the index difference and the colour difference across
   horizontally adjacent pixels scores 0.84-0.96 for the embedded palette
   against at most 0.86 for any `.PAL`, and 0.03 for `CORE.PAL`.

**The palette is per room, not shared.** All 56 rooms carry a different one. The
decisive evidence is `BASEBAT.MAP`, whose embedded table is **177 of 192 entries
byte-identical to `BASEBALL.PAL`**, while every other room matches every `.PAL`
in at most 2 entries. That single near-identity is what links the room files to
the standalone screens and confirms the whole reading.

25 of the 56 rooms also reference indices 192..255, which the file never
stores. Those pixels are sparse (0.00% to 8%, non-contiguous), consistent with
the game retargeting those slots at runtime for effects such as water and fire.
The engine pads them with a grey ramp so they stay visible instead of going
black, and documents it as a guess rather than a decode.

## 6.4 `.DAT` Full-Screen Images and `.PAL` Palettes

A `.DAT` is a single RNC block holding one indexed image: 320x200, except
`MENU.DAT` at 320x32. 19 of the 20 are images; `BOXDET.DAT` is a plain offset
table with no RNC magic and is skipped.

`.PAL` files are 768 bytes, 256 RGB triples, six bits per channel, scaling by 4
to reach 0..252. `CORE.PAL` is the exception and behaves like a 16-colour VGA
palette: its first 16 entries carry colour and the other 240 are black.
`CORE.DAT` is exactly the one `.DAT` that stays inside 0..15, which is a
confirmation rather than a coincidence.

Palette assignment for the screens is taken from the game's own naming
(`BALCONY1-5` to `BALCONY.PAL`, `BASEBAL1-6` and `BASEBAT` to `BASEBALL.PAL`,
`CAULDRN1-4` to `CAULDRN.PAL`, `CORE.DAT` to `CORE.PAL`, `TITLE.DAT` to
`TITLE.PAL`). `MENU.DAT` has no matching name, and it is provably not a `CORE`
image: 99.4% of its pixels sit above index 15, so `CORE.PAL` would render it
almost entirely black. It is mapped to `TITLE.PAL` as the remaining full
256-colour palette. This one mapping is inferred rather than confirmed.

Several palette tests were tried and rejected as evidence, which is worth
recording so they are not retried:
- **Mean absolute colour difference between neighbours.** Always picks
  `SPRITES.PAL`, because that palette is 192/256 black, so a low-contrast table
  wins regardless of the image.
- **Correlation between index delta and colour delta.** Favours any globally
  sorted ramp, so it rated `TITLE.PAL` above `BALCONY.PAL` for balcony art, and
  after subtracting each palette's mean score it picked `BASEBALL.PAL` for
  `BALCONY1.DAT`. It is only trustworthy where the palette is already known by
  construction, as with the embedded `.MAP` tables.

A useful positive result from the same data: `BALCONY1-5`, `CAULDRN1-4` and
`BASEBAL1-6` are 94-99% pixel-identical to the first file in their group, so
each set is an animation sharing one palette.

## 6.5 Verification

Decoding was cross-checked against an independent Python implementation of
both RNC methods under LuaJ 3.0.1, the same runtime the app uses:

- 75 of 75 resources decode, 0 failures, about 12.6 s total
- 5,879,040 image bytes byte-identical to the reference
- 57,600 palette bytes byte-identical to the reference

## 6.6 Sprite, character, PCM and sequence expansion (2026-10-20)

The 57 SPR banks already listed by the engine contain 2,058 images. All 29 BRD
character banks use the same format and add 637 frames: the first u16 gives the
header size in paragraphs, hence eight u16 paragraph offsets per paragraph.
Zero entries are absent. SMALL.BRD contains a stray 0x3F00 word after its last
valid offset, outside the file, so do not enumerate it. Headers are width,
height, end-of-plane-2/1/0 (u16 each); planes start after the ten-byte header.
Each row ends in zero; positive controls give literal counts, negative controls
skip transparent bytes then give a literal count. Plane byte x maps to pixel
4*x+plane. Bounds checks must cover each plane, each row and the output width.
All 2,695 frames pass these checks. Palette index 0 exports as transparent.

The previous SPRITES-only palette lost room-specific sprite colours. Same-stem
SPR banks now take their room's 192 colours plus SPRITES.PAL's upper 64. This
shared upper range also replaces the old grey-ramp guess for MAP backgrounds.
Other banks default to SPRITES.PAL; all six standalone and 56 merged room palettes
are exposed for manual selection. Palette swatches now use actual 16x16 colour
cells and the host's `palette_image`/`palette_colors` result keys.

Every SFX bank starts with u16 byte offsets; the first offset is also the table
size. Each offset addresses a u16 sample length followed by unsigned 8-bit mono
PCM, ending exactly at the next offset (or EOF). All 19 banks account for every
byte and expose 109 samples. CURSE.EXE file offsets 0x8342/0x8347 send DSP command
0x40 and time constant 0x83: 1,000,000/(256-131)=8000 Hz. This establishes the
initial driver rate used for previews; sample banks have no per-clip rate field.

BALCONY1-5, BASEBAL1-6 and CAULDRN1-4 now also expose animation previews while
retaining individual screens. The 100 ms delay is a UI preview choice. BRD banks
remain individual frames; gameplay sequencing and RS music remain undecoded.

Validation: native Lua synthetic malformed-plane/offset/PCM regressions plus a
complete sweep of 2,770 images, 109 sounds, 3 animations and 62 palettes. The
optional CurseOfEnchantiaIntegrationTest exercises the real LuaJ host APIs.

# Part 7: Universe EPFS Archive & Method-1 Compression

## 7.1 Archive Layout

`UNIVERSE.EPF` is a single 6,217,836-byte file holding all 779 game resources.

```
 0  'E' 'P' 'F' 'S'
 4  u32le directory offset      0x005E9D7A (6,200,698)
 8  u8   version                always 0
 9  u16le entry count           779
11  first payload byte
```

The directory sits at the *end* of the file, immediately after the payloads.

The directory is a flat array of 22-byte records at the offset above:

```
 0  12 bytes  name, "NAME.EXT" NUL padded (DOS 8.3)
12  u8        unused
13  u8        compression method: 0 stored, 1 Huffman/LZ, 2 unused
14  u32le     stored size
18  u32le     decompressed size
```

Records carry no payload offset. Blocks sit back to back from offset 11 in
directory order, so the offset of entry N is 11 plus the sum of the stored sizes
of entries 0..N-1. Two independent checks confirm this: the 779 stored sizes add
up to exactly the directory offset (6,200,687 + 11 = 6,200,698), and all 779
payloads decode to sane content. The 779 records occupy the final 17,138 bytes,
which is 779 x 22 exactly.

The executable confirms all three offsets independently. At 0xb559 the loader
reads `es:[di+0xd]` as the method byte and branches on 0 and 1; at 0xb593 and
0xb598 it reads `es:[di+0xe]` and `es:[di+0x12]` as the stored and decompressed
sizes. Those are offsets 13, 14 and 18, which is the layout above. The record
size is confirmed too, because at 0xb4c5 the loader computes
`(count + 1) * 0x16`, allocates it with a `shr` by 4 to convert bytes to
paragraphs, and reads entries from that buffer at 22-byte strides.

The unused byte at +12 is worth flagging because it sits right where a flag would
be and it reads as one. It is almost always 0, but `ICONS.ENG` carries 5 there.
The full set of values across all 779 records is just {0, 5}, so it is almost
certainly padding garbage rather than a field, and a parser that reads the name
as 13 bytes instead of 12 will be off by one on every subsequent field.

The archive holds 21 stored entries and 758 method-1 entries. No entry uses
method 2, although the DOS loader at 0xb559 has a branch for it.

## 7.2 Method 1: Canonical-Code Huffman with Match Chains

Recovered by disassembling `UNIVERSE.EXE` 0xb74a-0xba20. This is *not* the
ProPack/RNC method 1 used by Curse of Enchantia: there is no 5-bit leaf count, no
table-descriptor section and no 16-bit chunk counter. It is closer to DEFLATE in
spirit - a code space that widens as it fills - but with a very different match
representation.

**Code space.** Codes start at 9 bits. `[0xd8cc]`, `[0xd8ce]` and `[0xd8d0]`
hold `(1<<n)-1`, `(1<<n)-2` and `(1<<n)-3`, where `n` is the current width in
`[0xd8cb]`. Widths never exceed 14. The widest file in the archive, `M5.BIN`,
grows the table to 16,294 entries, just under the 16,382 ceiling that a 14-bit
mask allows.

**Bit reader.** MSB-first out of a 32-bit register refilled a byte at a time.
At 0xb835 it does `shl ebx,8` then `mov bl,gs:[si]`, so the newest byte is the
low byte; the code itself is then taken as `shr eax,cl` followed by
`and ax,[0xd8cc]` at 0xb8e0, i.e. the top `n` bits of the register.

The bit counter lives in `cl` and the width in `ch`, and the refill test at
0xb85a is `cmp ch,cl` with a **signed** `jg`. Because both are bytes, a count
that reaches 0x80 turns negative and the refill stops early, so the count can
never exceed 127. A port that uses an unsigned compare, or a 16-bit counter,
behaves the same for these files but is not a faithful reproduction, and the
difference would show up on a file with a long run of codes at one width.

**Stream grammar.**
- The first code is a plain byte and is emitted as-is.
- A code equal to the full mask `(1<<n)-1` ends the stream.
- A code equal to mask-1 empties the table and makes the next code a fresh
  literal byte.
- Any other code is a back reference.

**Match expansion.** Two parallel tables, `tab1` holding 16-bit links and `tab2`
holding bytes. If the code is below the current table size it indexes them
directly. Otherwise the last byte of the previous match is pushed onto a 4000
byte scratch buffer and the *previously saved code* indexes the tables instead.
Walking the link chain yields match bytes in reverse, and the copy loop at 0xb984
decrements its pointer to zero, so matches expand right to left. The pair
(saved code, last match byte) then becomes a new table entry.

Widen the code width when the entry count passes mask-2 and the width is still
below 14, which keeps the average code length near 8 bits across a whole file.

The routine allocates four tables at 0xb74a, and their paragraph counts are worth
recording because they set the real limits: 0x8D0, 0x468, 0xFA and 0xFFF, stored
through DOS handles at 0xd8d2, 0xd8da, 0xd8e2 and 0xd8ea. The chain scratch
buffer is the 0xFA0-byte one that the overflow check at 0xb919 guards.

Those two overflow checks are the trap for anyone porting this. `cmp bp, 0xfa0`
at 0xb919 walks a pointer that was just incremented, and `cmp bp, 0x8d00` at
0xb99c follows an `lfs` into the arena. Both compare a *linear address inside the
heap*, not a table length, so they only make sense against a real DOS allocator
and will fire spuriously in a flat-memory port. A port has to drop them or place
its arena below 0x8D00.

## 7.3 Images

All 168 `.LBM` files are IFF ILBM with `BMHD`, `CMAP` and `BODY`, run-length
compressed, and all carry a full palette inside the file. There are no `.PAL`
files in the archive and none are needed.

Two body layouts appear, distinguished by the IFF form type:

| Form type | Files | Geometry | Planes | CMAP | Body layout |
|-----------|-------|----------|--------|------|-------------|
| `PBM `    | 165   | 320x200  | 8      | 768  | one byte per pixel |
| `PBM `    | 2     | 320x240  | 8      | 768  | one byte per pixel |
| `PBM `    | 2     | 320x256  | 8      | 768  | one byte per pixel |
| `ILBM`    | 3     | 320x256  | 5      | 96   | interleaved bitplanes |

`PAGE2-4.LBM` are the odd ones out: 5 planes, a 32-colour palette and genuine
interleaved bitplanes. The other 165 declare 8 planes but store one byte per
pixel - at 320 pixels wide a plane row is 40 bytes, so 8 planes is exactly 320
bytes and the "planes" are just the 8 bits of one pixel. Masking is 0 in all 168
files and compression is 1 in all 168, so neither case is stored.

The three chunk layouts in the archive are:

| Count | Chunks |
|-------|--------|
| 87  | `BMHD` `BODY` `CMAP` |
| 78  | `BMHD` `BODY` `CMAP` `CRNG` `DPPS` `TINY` |
| 3   | `BMHD` `BODY` `CAMG` `CMAP` `DPPS` `DRNG` |

`CAMG` and `DRNG` appear only in the three `ILBM` files. The palette-masking and
colour-cycling chunks are Deluxe Paint view-state, not image data, so the engine
skips them.

The `BODY` is one continuous run over the whole chunk, not one per scanline. The
stream expands to exactly `rowbytes * planes * h` bytes and lands on the final
output byte for all 168 files, which is what proves there is no row padding and
no per-row restart. The escape is a control byte `n` where `n < 128` copies the
next `n+1` bytes literally and `n > 128` repeats the next byte `257-n` times.

Deciding between contiguous and bitplane layouts needed evidence rather than
convention, because for the 165 `PBM ` files both readings yield exactly the same
number of bytes and there is no length left over to check against.

The measure used is the mean absolute pixel-index difference across horizontal
neighbour pairs, averaged over all `h * (w-1)` of them. Real artwork is locally
coherent, so neighbouring pixels normally hold nearby palette indices; a wrong
interleave scrambles that and the score explodes. Lower is better.

| File | planes | contiguous | row-interleaved | plane-major |
|------|--------|-----------|-----------------|-------------|
| `SCENE02.LBM`  | 8 | **22.46** | 92.62 | 89.61 |
| `PAGE1.LBM`    | 8 | **0.55**  | 6.54  | 42.67 |
| `INTRO.LBM`    | 8 | **8.88**  | 64.11 | 64.14 |
| `CLOS0001.LBM` | 8 | **0.17**  | 43.88 | 58.97 |
| `LOGO.LBM`     | 8 | **0.18**  | 1.04  | 1.30 |
| `PAGE2.LBM`    | 5 | n/a       | **0.28** | 0.48 |

For the 8-plane files the contiguous reading wins by a factor of four to two
hundred, which settles those 165. `PAGE2.LBM` is the converse: it is 5 planes,
so no contiguous reading is even available, and row-interleaving beats
plane-major. `PAGE1.LBM` shows the same ordering at 8 planes (6.54 against
42.67), so the two layouts are being compared on the same terms.

The absolute values for the winning column are not comparable between files, and
should not be read as image quality. `SCENE02.LBM` scores 22.46 while winning
because it is a dithered 256-colour backdrop where adjacent palette indices
genuinely differ; `PAGE2.LBM` scores 0.28 because it is a 32-colour image. Only
the ordering within a row is meaningful.

## 7.4 Bitmaps

The 49 `.COL` and 48 `.MSK` files are all exactly 8000 bytes: 40 bytes per row
for 320x200, most significant bit leftmost, one bit per pixel with no row
padding. They are the per-room collision and walk masks. `BLANK.COL` is all
zeros and `SCENE02.COL` has 49,997 of 64,000 pixels set, so the two names do
mean what they say.

## 7.5 Other Contents

The remaining 549 entries are not images and are not covered by the engine:

| Extension | Count | Notes |
|-----------|-------|-------|
| `COM`     | 57    | `BACK01.COM` to `BACK58.COM`, with `BACK32.COM` absent; structure undecoded |
| `MCV`     | 155   | 73 to 64,302 bytes; structure undecoded |
| `MCB`     | 13    | `BLOCK31A-C`, `ICONS`, `ICONS1`, `MENU_BD`, `SC221` to `SC227` |
| `BIN`     | 21    | 13 are exactly 64,000 bytes, the rest 3,840 to 56,064 |
| `ENG` `FRE` `GER` `ITA` `SPA` | 53 each | UI strings in five languages; structure undecoded |
| `EXE` `BAT` `TXT` | 3 | the game itself, a batch file, and a note from the author |

`README.TXT` decodes to a note from the author, and it is indented as a staircase:

```
Hello Troy,

	 please run the remake.bat batch file,

		thanks,

			Neil
```

`REMAKE.BAT` is a single line, `epfs -a universe.epf text46.fre`, which is the
archive builder. It confirms that `UNIVERSE.EPF` was assembled from loose files
with a tool of the same name, and it names `TEXT46.FRE` as the source of one
entry - so the five language variants are interchangeable builds rather than
different content.

The 13 exact-64,000-byte `BIN` files match the geometry of a 320x200 picture at
one byte per pixel, which suggests they are raw screen buffers, but that is an
observation from the size alone and has not been confirmed by content.

## 7.6 Verification

The decoder was ported to LuaJ 3.0.1-compatible Lua for the engine script and
checked against an independent Python implementation of the same specification,
written from this document rather than from the engine script:

- all 779 archive entries decompress to exactly their declared decompressed size,
  with no overflow, no runaway chain and no short stream
- 265 of 265 image resources decode, 0 failures (168 `.LBM`, 49 `.COL`, 48
  `.MSK`), plus 2 text resources decoded as text
- 17,075,200 image bytes byte-identical to the Python reference
- 203,520 palette bytes byte-identical to the Python reference

The image run was done twice, under Lua 5.5 and under LuaJ 3.0.1, which is the
runtime the app itself uses. Both produced byte-identical output, and both agreed
with the Python reference on every byte, so the engine does not depend on any
Lua 5.3+ behaviour.

The largest single decode is `M5.BIN`, which drives the match table to 16,294
entries. Two entries exceed the 64 KB boundary that the DOS loader handles
through a different input-buffering path: `SCENE01.LBM` (66,012 in, 66,012 out)
and `UNIVERSE.EXE` itself (81,707 in, 94,392 out). Both are treated identically
in a flat-memory port, since the bit reader only ever walks the buffer forward.

# Part 8: SCUMM V3/V4 EGA / V5-V8 Resource Layout

Source: ScummVM `engines/scumm/` — `resource.cpp`, `resource.h`, `object.h`,
`object.cpp`, `gfx.h`, `gfx.cpp`, `detection_tables.h`.

Current coverage includes room backgrounds and palettes, object sprites, actor
costumes and animation previews, NUT fonts, MIDI music, digital iMUSE music,
sound effects and speech. The room-directory findings and resource counts below
describe the earlier V5-V7 background/object-sprite validation; they are not
totals for the expanded resource tree.

## 8.1 Data File Conventions

V5-V7 games ship an index file plus one or more data files. The index carries a
`DROO` block; the data files carry the room blocks themselves.

| Pattern | Games |
|---|---|
| `<BASE>.000` + `<BASE>.001` | Monkey Island 2, Atlantis, Indy 4 |
| `<BASE>.LA0` + `<BASE>.LA1` | later HE/V7 releases |
| `<BASE>.SM0` + `<BASE>.SM1` | Space Quest V5/V6 |
| `<BASE>.000` .. `<BASE>.015` | Day of the Tentacle |
| `<BASE>.000` + `ROOM/%02d.LFL` | standalone per-room-file releases |

Day of the Tentacle is *not* a `MANIAC/%02d.LFL` release: `detection_tables.h`
registers it as `tentacle.%03d` with `kGenDiskNum`, i.e. numbered data parts.

All V5-V7 files are XOR-encrypted with `0x69`; the key is verified per file by
decrypting the 8-byte header and checking for a known tag (`DROO`, `LECF`,
`LFLF`, `ROOM`), with `0x00` and `0xFF` tried as fallbacks.

## 8.2 The Room Directory Is Not In DROO

`DROO` looks like a room directory — `u16 count`, then `count` bytes of data-file
numbers, then `count` `u32` offsets — but the offsets are **zero on multi-part
releases**. Treating DROO as authoritative yields offset 0 for every room.

The real directory is a table stored at **offset 16 of each data file**, read by
`ScummEngine::readRoomsOffsets`:

```
u8   count            // 0-based offset 16, i.e. immediately after the 16-byte LECF header
repeat count times:
    u8   roomId
    u32le offset       // 0-based, absolute within THIS data part
```

`LOFF` inside `LECF` is the same table for single-part games, and the two agree
byte for byte on every title checked (Monkey Island 2, Atlantis). So the engine
prefers the offset-16 table, falling back to `LOFF`, and uses DROO only to pick
*which part* a room lives in.

## 8.3 Detection and Broken Installs

A V5-V7 game is identified by its index alone: the decrypted header must walk
into at least three blocks, include both `DROO` and `MAXS`, and end on a block
boundary. `RNAM`, `MAXS`, `DROO`, `DSCR`, `DSOU`, `DCOS`, `DCHR`, `DOBJ`, `AARY`
is the signature — that check is strict enough to key detection even when every
data part is missing, which is what makes an incomplete install reportable
instead of invisible.

Day of the Tentacle ships Maniac Mansion as a bonus game in a `MANIAC/`
subdirectory. Because a V6 index with no data parts used to fall back to
"whatever directory has `.LFL` files", the bundled game hijacked detection: DOTT
was reported with Maniac Mansion's 54 room files. Two changes fix this.

- Detection no longer requires a data part, so a game with a valid index is
  registered even when incomplete, and `get_resources` can name the part that is
  missing instead of the game silently not being detected.
- The `.LFL` fallback only offers rooms whose file actually exists, so a bundled
  sub-game's rooms can never be attributed to the parent game.

An incomplete install now still reports itself honestly:

```
detect(.../DOTT) = true
total leaf resources: 0
TENTACLE: index declares 91 rooms but data part(s) TENTACLE.001 are not installed
```

With the full data part installed the same folder yields the complete game, so
the partial-install path is a diagnostic rather than a dead end:

```
detect(.../DOTT) = true
total leaf resources: 823
```

## 8.4 Verification

- `TENTACLE.000` decrypts to the block list above and declares 91 rooms, 89 of
  them in data part 1. It carries no `LECF`, `LFLF` or `ROOM` block and every
  `DROO` offset is zero, which is exactly why it is useless as a room directory
  and why DROO alone cannot locate a room's data.
- `TENTACLE.001` (11,378,198 bytes) holds the real room data. The engine reads
  its offset-16 table, follows DROO's part assignment, and walks part 1 to 0x015.
  All 823 leaves load with zero exceptions: 91 backgrounds, 91 palettes and 641
  object-sprite images grouped under a per-room `Object sprites` sub-category.
  `bg:TENTACLE:72` decodes to 320x200 with 128 unique colours and
  `bg:TENTACLE:1` to 784x200 with 170, so the previously blank rooms are real.
- Room dimensions vary as expected for V6: 320x200, 784x200, 632x144. Room 1's
  784x200 width is the V6 wide-screen layout, not a decode error.
- Multi-part loading was additionally validated against a synthesized
  `TENTACLE.001` carrying a `LECF` header, an offset-16 room table and two `LFLF`
  room blocks before the real part was present; rooms 1 and 72 were both
  discovered through DROO's part assignment.
- Some rooms legitimately have no objects — rooms 1, 2 and 72 expose only a
  background and a palette. `load_resource` on a missing object warns
  (`Object 1 state 0 not found in room 72`) instead of raising, and a malformed
  `obj:` id is rejected up front with the expected shape.
- `MANIAC/` holds `00.LFL`-`53.LFL` that are byte-identical to the real Maniac
  Mansion files and decrypt to `BJ` V2 data under `0xFF`; they are from a
  different game and contribute nothing to the 823 DOTT resources.
- No other title changed: MONKEY2 1231, ATLANTIS 1499, Monkey 869, DIG 689
  leaf resources. `MANIAC` is still correctly *not* detected by the V5-V7 engine
  while `scummv2` at that stage detected it with 53 backgrounds, so there was no
  cross-detection between the two engines.

## 8.5 Actor Sprites and Music

- `scumm_cost.lua` decodes V5/V6 `COST` and V7/V8 `AKOS` actor costumes.
  The resource tree exposes cel sheets and animation/chore previews under
  `Costumes / actor sprites`, alongside the existing per-room object sprites.
- `scumm_snd.lua` extracts standard MIDI from sound-resource device chunks and
  decodes digital samples and resident `iMUS` streams. Indexed audio appears
  under `Sounds / music`.
- External `.BUN` bundles expose digital iMUSE music and speech, including
  The Dig and The Curse of Monkey Island. Bundle decompression uses the host's
  `ImuseBundleCodecs.kt`; V6 `.SOU` speech archives contain VOC clips.
- Format references: ScummVM `costume.cpp`, `base-costume.cpp`, `akos.cpp`,
  `bomp.cpp`, `sound.cpp`, `imuse_digi/dimuse_bndmgr.cpp` and
  `imuse_digi/dimuse_codecs.cpp`. These additions apply to the `scumm` engine;
  the separate `scummv2` engine at that stage exposed backgrounds only (expanded below on 2026-10-20).

## 8.6 V3 Old-Bundle EGA (Loom)

The supplied DOS EGA Loom uses XOR `0xFF` numbered `.LFL` files. Its decrypted
`00.LFL` begins with u16 `0x0100`, a u16 global-object count and four bytes per
global object. Four directories follow (rooms, costumes, scripts, sounds), each
with a byte count, an array of room bytes and an array of u16 offsets; `0xFFFF`
marks missing resources. Room resources use their own numbered file. Enhanced
V2 shares the index magic but stores one byte per global object rather than
four. Filename-only detection previously confused V3 with V2; detection now
validates the appropriate global-object layout and all four directories.

V3 room headers retain u16 dimensions at +4/+6 and the image offset at +10.
The object count at +20 precedes image/code offset arrays at +29. Object code
records contain the ID at +4, width in strips at +9 and height/direction at +15.
Invisible interaction objects reuse another image pointer: matching the image's
strip-table width and encoded height avoids decoding their rectangles as art.
Some object images copy pixels from outside their left edge; standalone previews
use black for those pixels.

EGA images have a u16 size and u16 relative offsets per eight-pixel strip. Runs
advance vertically, then into the next column. A clear high bit selects a solid
low-nibble colour; `0x80` copies the previous column; `0xC0` alternates the next
byte's nibbles. Zero run lengths read an extra byte. This differs from V2's
whole-image dither-table codec and V5's codec-prefixed strips.

Old-bundle costumes share the classic renderer, with an initial base of -2,
one palette-substitution byte, offsets relative to the resource's size word,
and **one-byte** limb-command offsets (`0xFF` stops a limb). V5/V6 continue to
use two-byte limb-command offsets. Cel sheets and animation previews retain
the existing renderer's uniform timing and key-colour background.

Validation: `lua scripts/tests/scumm_v3.lua /path/to/LOOM` checks the parser,
truncated data, V2/V3 detection and all exposed graphics. The supplied release
has 76 backgrounds, 594 object sprites, 159 costume sheets, 2,521 animation
previews and one palette, all loading successfully. Background and object
scans also pass through the app's LuaJ developer CLI; exported background and
costume artwork was inspected visually. V3 sound/music, fonts, VGA/small-header
and other platform variants remain unsupported; this is not a claim of full
V3 coverage.

## 8.7 V4 DOS EGA (Monkey Island)

The supplied Monkey Island EGA uses plaintext `000.LFL` and XOR `0x69`
`DISK01.LEC` through `DISK08.LEC`. It was not detected because the old-bundle
V3 and IFF-style V5-V8 parsers do not cover V4's six-byte small headers:
u32 little-endian total size followed by a two-byte tag. Index blocks are
`RN` (room names, XOR `0xFF`), `0R`, `0S`, `0N`, `0C` and `0O`.
Resource directories have a u16 count followed by interleaved u8 room/u32
offset records, rather than V5's separate room and offset arrays. Room entries
map to disk numbers; other resources reference room IDs.

Each decrypted archive is a `LE` container. Its `FO` table has a byte count
at offset 12 followed by room ID/u32 physical offset records. These offsets
point to `LF` containers; room data begins eight bytes later. Indexed costume
offsets are relative to the same room base and also skip that eight-byte LF
wrapper. Sizes, offsets, tags and enclosing resource bounds are checked before
reading. A validated EGA BM strip table is required for detection; filenames
alone and VGA-style strip tables do not match.

Room `RO` resources contain `HD` dimensions, `BM` EGA bitmap data and paired
`OC`/`OI` object records. OC has the object ID at +6, width in strips at +11,
height/direction at +17; OI's bitmap starts at +8. BM and OI use the same u16
strip offsets and EGA run codec as V3. Costumes have a `CO` header, base zero,
an explicit 16-colour palette and u16 limb-command offsets, in contrast to V3's
single palette substitution and byte command offsets. Existing classic-costume
cel sheets and animation previews are reused.

References: ScummVM `resource_v4.cpp`, `resource.cpp` (`readRoomsOffsets`,
`getEncByte`, `loadResource`), `object.cpp` (`resetRoomObject`, `getObjectImage`),
`gfx.cpp` (`drawStripEGA`) and `costume.cpp` (`ClassicCostumeLoader`).

Validation: `SCUMM_V4_TEST_PATH=/path/to/MONKEYEGA ./gradlew test --tests
'*ScummV4DecoderTest'` passes four tests, including disk/room routing, LF
offsets, truncated index/archive bounds, VGA rejection and V4 costume offsets.
All 2,823 graphics leaves load through LuaJ: 81 backgrounds, 606 object sprites,
115 costume sheets, 2,020 animation previews and one palette. Exported bar,
beach and Guybrush costume-sheet previews were inspected visually. V4
sound/music, fonts, VGA and non-DOS variants remain unsupported.

# Part 9: Drascula — The Vampire Strikes Back

Source: ScummVM `engines/drascula/` — `graphics.cpp`, `rooms.cpp`,
`resource.cpp`, `drascula.h`, `detection.cpp`.

## 9.1 File Set

The unpacked DOS release is flat, with one file per asset kind. There is no
archive and no index:

| Extension | Role |
|---|---|
| `NN.ALG` | 320x200 indexed picture — room backgrounds, character sheets, cutscene art |
| `NN.ALD` | room description: music, layered surface, palette level, object list |
| `NN.ALS` | sound (`sound.cpp` builds `"s%i.als"`) |
| `NN.CAL` | screenplay |
| `*.ALG` | named surfaces: `AUX*.ALG`, `PLAN*.ALG`, `CIELO*.ALG`, … |
| `*.BIN` | engine tables and script data |

`.ALS` is sound, not sprites. Pictures are `.ALG` throughout.

## 9.2 `.ALG` — plain header, RLE body, trailing palette

`DrasculaEngine::loadPic` gives the whole layout:

```
offset 0    128 bytes   header, zero-filled
offset 128  size-896    run-length encoded pixels
tail        768 bytes   256 * 3 RGB
```

There is no tag, no magic number, no compression id. `decodeRLE`:

```c
pixel = *src++;
repeat = 1;
if ((pixel & 192) == 192) {   // 11xxxxxx
    repeat = pixel & 63;
    pixel = *src++;
}
for (j = 0; j < repeat; j++) {
    *dst++ = pixel;
    if (++col >= 320) { col = 0; if (++line >= 200) done; }
}
```

A byte with both top bits set is a run header: the low six bits are the pixel
count and the next byte is the colour. Any other byte is a literal pixel.
Note that `repeat` is the raw low-six-bits value with no `+1`, so a run can be
zero pixels long — the original relies on that only for padding.

Room backgrounds load with `HALF_PAL` (128) and character sheets with the full
256, which is visible in the data: room pictures use 127-134 distinct indices,
sheets 17-32.

## 9.3 `.ALD` — inverted text, three layouts

`TextResourceParser::getLine` reads `~byte`, discards CR and ends a line on LF,
so the entire file is bit-inverted. Lines are plain ASCII; there are exactly as
many values as the reader asks for.

`enterRoom` reads, in order:

```
roomNumber, music, roomDisk, palLevel
[chapter 2 only]
    overriddenWidth
    if overriddenWidth != 0:
        curHeight, feetHeight, stepX, stepY
        frontSurface, extraSurface, unusedSurface, backSurface
numRoomObjs
    per object:
        objectNum, objName, x1, y1, x2, y2, x, y, track, visible, isDoor
        if isDoor: destRoom, x, y, trackAlkeva, exitId
walkRect: x1, y1, x2, y2
[chapter != 2] upperLimit, lowerLimit
```

The chapter is only known at runtime, so rather than hard-code a chapter table
the engine tries each layout and keeps the one that consumes the file exactly.
Across all 57 `.ALD` files in the local copy each file has exactly one fitting
layout — no ambiguity, and a file that fails to parse exactly is rejected:

| layout | header | trailing | files |
|---|---|---|---|
| plain room | 4 | 2 | 40 |
| chapter 2, `overriddenWidth == 0` | 5 | 0 | 7 |
| chapter 2, `overriddenWidth != 0` | 13 | 0 | 9 |
| chapter 2 header *and* limits | 13 | 2 | 1 (`2.ALD`) |

`2.ALD` is the one file that mixes both: it has the chapter-2 surface block and
still ends with `upperLimit`/`lowerLimit`. Trying all six combinations handles it
without a special case. Object rectangles can be negative (`SALIDA` is
`[-1,141,24,197]`) and one object in `3.ALD` is degenerate (`[0,0,0,0]`), so no
coordinate is assumed to be in range.

## 9.4 Sprites

There are no sprite files. A room's interactive objects are rectangles of the
room picture listed in the `.ALD`:

```
x1 y1 x2 y2   the rectangle, drawn straight onto the background
x   y         where the object sits when the player walks up to it
```

So sprites are recovered by cropping `_objectRect` out of the decoded `.ALG`.
The character is the exception: `placeIgor`, `placeDrascula` and the protagonist
draw cut rectangles out of `extraSurface` / `frontSurface` / `backSurface`, which
are themselves `.ALG` sheets — `96.alg`, `97.alg`, `99.alg` for chapter 2, plus
the `96x`/`97x`/`98x`/`99x` variants. Those sheets show the walk cycle repeated
across each row, which is why they decode to 17-32 distinct indices rather than
128.

Of the 85 numbered `.ALG` files, 57 are room backgrounds named by a `.ALD`. The
other 28 (`46`, `47`, `48`, `95`-`104`, `961`-`964`, `971`-`974`, `981`-`984`,
`991`-`994`) are surfaces referenced by name from room descriptions and scripts
rather than by room number, and are exposed as sheets.

## 9.5 Verification

- 354 leaf resources (57 backgrounds + 269 object sprites + 28 sheets); all 354
  decode, 0 failures, 5.4 s for the full sweep under LuaJ 3.0.1.
- The Lua decoder was checked against an independent Python implementation
  written from this document: `1.ALG`, `96.ALG` and `102.ALG` match on all
  64,000 pixels each, and object crops `obj:DRASCULA:1:1` (93x91) and
  `obj:DRASCULA:62:7` (`PIZARRA`, 16x16 at 73,66) match exactly.
- Room descriptions: all 57 files have exactly one valid layout; the object
  names recovered (`PUERTA`, `VENTANA`, `SALIDA`, `CEMENTERIO`, `CABAÑA`,
  `PIZARRA`, `BORRACHO`, …) are consistent with the Spanish original, which
  confirms the field alignment rather than just the token count.

---

# Part 10: Prisoner of Ice — Burp Archives, Dialogue Tables and Sound

Source: derived from the data in `ags/PRISONER`, cross-checked against the file
list on the (archived) ScummVM wiki page:
https://wiki.scummvm.org/index.php/Prisoner_of_Ice

## 10.1 File Set and the Burp Container

All game data sits in four archives:

| File | Entries | Content |
|---|---|---|
| `KVGA.KRO` | 1335 | 748 scene streams, 130 images, 126 palettes, plus 160 empty stubs and 171 misc |
| `KSVGA.KRO` | 1338 | 748 scene streams, 122 images, 126 palettes, plus 175 empty stubs and 167 misc |
| `S_KLANG.KRO` | 722 | 646 RIFF/WAVE sounds, 67 dialogue tables, 9 empty |
| `KSOUND.KRO` | 353 | 307 RIFF/WAVE sounds, 46 Miles MIDI modules |

Every `.KRO` file uses one directory format, named `Burp`:

```
0x00  ASCII "Burp"
0x04  u32le  entryCount
0x08  entryCount * 20 bytes:
        +0x00 u32le decompressedSize
        +0x04 u32le storedSize
        +0x08 u32le reserved (always 0)
        +0x0C u32le fileOffset
        +0x10 u32le flags   (bit 2, value 4, = raw DEFLATE)
```

Entries carry no names, so the reader caches the directory per path and seeks only
to the entry it needs; the payload is decompressed in memory.

## 10.2 Entry Classification

There is no per-entry type field, so the type is derived from the payload:

| Signature | Type |
|---|---|
| `RIFF....WAVE` | sound |
| `EDITLS` + 24 bytes + `RIFF....WAVE` | sound (43 such entries in `S_KLANG.KRO`) |
| `HMIMIDIP0131` | Miles MIDI module (metadata only) |
| `u16le w`, `u16le h`, then `w * h` bytes | indexed image |
| exactly 768 bytes | 256-colour palette |
| 11-byte-stride record table | dialogue table |

The record-table test is: read records while `name[0] != 0` and all seven name
bytes are in `0x20..0x7E` or NUL, then require at least two records and at least half
of the `u16le` offsets to land inside the payload. Running this over all four
archives yields exactly 67 dialogue tables, all in `S_KLANG.KRO`, with no false
positives in `KVGA.KRO`, `KSVGA.KRO` or `KSOUND.KRO`.

## 10.3 Images and Palettes

```
+0x00  u16le width
+0x02  u16le height
+0x04  width * height palette indices, row-major
```

Palettes are 768 raw RGB bytes, no VGA 6-bit scaling. They are interleaved with the
images they belong to: 126 of the 130 KVGA images and 118 of the 122 KSVGA images are
followed immediately by their palette, so the palette for image index `i` sits at
`i + 1` and the resource tree exposes both.

## 10.4 Sound

Standard RIFF/WAVE, mono 8-bit PCM at 22222 Hz. One subtlety is an off-by-one in the
chunk bounds test: because Lua strings are 1-based and the `data` chunk id occupies
`p`..`p+3` with the 4-byte size at `p+4`..`p+7`, the payload starts at `p+8`, so the
bound must read `p + 7 + size > #data`. Testing `p + 8 + size` rejects the final sound
in every archive; with the corrected test all 953 sounds load.

## 10.5 Dialogue Tables

Each record is 11 bytes:

```
+0x00  name[7]      ASCII, NUL padded
+0x07  u16le         absolute offset into the decompressed payload
+0x09  u16le         padding
```

Text is stored in a string pool as `<control:u8><NUL terminated text>` blocks. The
control byte is small (`1`..`10`); `0xAD` in the text is a line break, and the rest of
the high range is CP850, decoded with the standard 128-entry table.

The record offset does not point at the first control byte. It lands a few metadata
bytes earlier, so the reader scans the 16 bytes from the offset for the first block
that looks like `<control in 1..10><byte >= 0x20>`. A record can hold several blocks:
long sentences are split, and a block with no control byte continues the previous
block's control. The next record's offset bounds the scan, so a record can never
swallow its neighbour.

Reading only the first block truncates long lines, so the run loop keeps consuming
blocks until it reaches the next record offset, hits a byte that is neither a valid
control nor a printable byte, or finds no NUL terminator. Across all 67 tables this
yields 2697 strings from 1862 records, and 61 records are trailing `S_*` entries
whose offsets are `0` or point back into the record table itself — these are skipped
rather than treated as text.

Two structural details are worth noting for future work:

- The offsets are not strictly ordered (names sort by number, offsets do not), so the
  per-record bound must be the next *greater* offset, not the next record in name order.
- Some tables are tiny, e.g. entry 713 holds two records and only three bytes of text;
  a strict classification test rejects it, which is why the offset check accepts any
  offset strictly inside the payload rather than requiring a plausible text size.

## 10.6 Not Decoded

Two containers remain opaque and are exposed as metadata only:

- Scene streams (748 per graphics archive). The 748 entries in each archive are the
  same scenes; their picture/opcode stream is not decoded, so no scene image is
  produced.
- Miles `HMIMIDIP0131` modules (46 in `KSOUND.KRO`). Only the format tag and size are
  reported; the patch/instrument stream is not decoded, so no playable audio results.

`S_VIDEO/*.MUX`, `S_KLANG.BIN` and `__ICE__.PAR` are also unidentified.

## 10.7 Verification

- Full sweep of all four archives under LuaJ 3.0.1: 3310 resources, 0 load failures.
  748 images, 953 sounds, 1609 text resources (1496 scene metadata entries, 67
  dialogue tables, 46 Miles MIDI entries).
- Resource tree matches the archive inventory: KVGA graphics 256 / scenes 748 /
  palettes 126, KSVGA 240 / 748 / 126, sound effects 953, dialogue 67, music 46.
- Dialogue output was spot-checked against the Spanish original: record `1030` of
  `S_KLANG.KRO` entry 642 resolves to "¡Diablos! ¡Subo al puente de mando!" and record
  `107` of entry 645 resolves to the five-block hypnosis exchange, both including the
  continuations that a single-block reader drops.

---

# Part 11: Tsunami / TsAGE — RLB Resource Libraries (Ringworld & Blue Force)

Source: ScummVM `engines/tsage` (`resources.cpp`/`.h`, `graphics.cpp`, `scenes.cpp`,
`core.cpp`, `sound.cpp`) at `/scummvm-fork`. Games in `ags/Tsunami/RINGWORLD` and
`ags/Tsunami/BLUE`.

Tsunami Media shipped two adventure games on a shared in-house engine that ScummVM
calls **TsAGE**: *Ringworld: Revenge of the Patriarch* (1992) and *Blue Force*
(1993). All assets live in one or more `.RLB` ("resource library") files, each a
sequence of self-describing `TMI-` sections addressed through a root index.

## 11.1 Top-Level Layout

Every `.RLB` starts at file offset 0 with a `TMI-` section header:

```
0x00  ASCII "TMI-"           (0x54 0x4D 0x49 0x2D)
0x04  u8    unknown1
0x05  u8    numEntries
0x06  numEntries * 12 bytes:
        +0x00 u16le id
        +0x02 u16le sizeLo
        +0x04 u16le uncSizeLo
        +0x06 u8    sizeHi
        +0x07 u8    typeWord
        +0x08 u32le offset      (relative to the section base)
```

Derived fields (`resources.cpp`):

```
storedSize = sizeLo | ((sizeHi & 0x0F) << 16)
uncSize    = uncSizeLo | ((sizeHi & 0xF0) << 12)
compressed = (typeWord >> 5) != 0
```

Each `offset` is relative to the section base (i.e. the start of the enclosing
`TMI-` block), not the file.

## 11.2 Section Index (Resource 0)

The root section holds a single resource with `id 0`. Its body is a flat table of
6-byte records, terminated by `0xFFFF`:

```
u16le resNum
u16le configId
u16le fileOffset
```

```
resourceType = configId & 0x1F
absOffset    = ((configId >> 5) & 0x7FF) << 16 | fileOffset
```

`absOffset` points at the `TMI-` section for that resource. Every section in the
file is described by exactly one record, so the index is the complete map of the
library. When a file has several libraries (Ringworld uses `RING.RLB` + shared
`TSAGE.RLB`; Blue Force uses `BLUE.RLB` + `FILES.RLB` + `TSAGE.RLB`) a given
section number can appear in more than one, so sections are de-duplicated by
`(type, resNum)` when building the tree.

## 11.3 Compression — LSB-First LZW

Compressed resources use the same 9→12 bit LZW stream as ScummVM's `BitReader`
(`resources.cpp`). Codes are packed **LSB-first** within the byte stream, so the
first code occupies the low bits of the first byte:

```
numBits     starts at 9, widens to 12
code 0x100  resets the dictionary (numBits back to 9)
code 0x101  terminates the stream
```

The dictionary starts with single bytes `0x000..0x0FF`, `ctrCurrent = 0x102`.
On a normal code the previous word (prepended with the current code when
`code >= ctrCurrent`) is emitted, the new entry `(prevCode, firstByteOfCurrent)`
is appended while `ctrCurrent <= 0xFFF`, and `numBits` widens whenever
`ctrCurrent >= ctrMax` (`ctrMax` doubles from `0x200`). A simpler equivalent
bit reader (read bytes, shift out low bits) reproduces ScummVM's byte/bit order
exactly and is what the Lua decoder uses. Output is truncated to `uncSize`.

## 11.4 Resource Types

`resources.h` defines the `ResourceType` enum:

| Value | Name | Content |
|---|---|---|
| 1 | `RES_STRIP` | cutscene script strips (not decoded) |
| 2 | `RES_IMAGE` | full-screen images |
| 3 | `RES_PALETTE` | palettes |
| 4 | `RES_VISAGE` | sprite frame sets |
| 5 | `RES_SOUND` | scored Adlib/MIDI tracker data |
| 6 | `RES_MESSAGE` | dialogue strings |
| 7 | `RES_FONT` | bitmap fonts |
| 11 | `RES_PRIORITY` | z-order tables |
| 12 | `RES_CONTROL` | input tables |
| 13 | `RES_WALKRGNS` | walk regions |
| 14 | `RES_BITMAP` | scene backgrounds |
| 16 | `RES_SEQUENCE` | animation sequences |

## 11.5 Backgrounds (RES_BITMAP)

A `RES_BITMAP` section's section number is the **scene number**. It is a tile set:

- Resource `id 9999` is the size record: `u16le width, u16le height` (10 bytes).
- Every other resource is one raw 8bpp tile that decompresses to exactly 16000
  bytes (160×100).
- Tile id is `xSection * yHalfCount + ySection`, where
  `xSection = ceil(width/160)` and `yHalfCount = ceil(height/100)`.
- Tiles composite at `(xSection*160, ySection*100)` into a `width × height` index
  buffer.

Every `RES_BITMAP` scene has a matching `RES_PALETTE` section of the same number.

## 11.6 Palettes (RES_PALETTE)

`ScenePalette::loadPalette(n)` fetches section `n`, resource `0`. The decoded
buffer is:

```
u16le palStart
u16le palCount
palCount * 3 bytes RGB        (8-bit components, 0-255 — not 6-bit scaled)
```

The palette image fills indices `palStart .. palStart+palCount-1`.

`TLib::getPalette(n)` is a *different* lookup: section `0`, resource `n`. It is
only ever called with `getPalette(0)` for the global dialog/interface palette, so
resource `0` of the global palette section is used as each game's default. The
Lua engine uses the same-numbered scene palette for a sprite when it exists and
otherwise falls back to that default (Ringworld `(0, 0)`, Blue Force `(1, 0)`).

## 11.7 Sprites / Visages (RES_VISAGE)

A `RES_VISAGE` section's number identifies the visage. Resource `id 9999` is an
index; each other resource is a **frame set**:

```
u16le numFrames
u32le offsets[numFrames]      (relative to the start of the frame-set resource)
```

Each offset points at a `surfaceFromRes` record (`graphics.cpp`):

```
+0x00 u16le width
+0x02 u16le height
+0x04 u16le centroidX
+0x06 u16le centroidY
+0x08 u8    transColor
+0x09 u8    flags
+0x0A ...   pixel data
```

`rleEncoded = (flags & 2) != 0` (bit 1, **not** bit 0). Otherwise the pixels are
raw `width * height` bytes.

RLE is per scanline. The buffer is pre-filled with `transColor`, then each row is
consumed until `width` pixels are produced:

| Control byte | Meaning |
|---|---|
| `< 0x80` | copy the next `control` bytes literally |
| `0x80..0xBF` | skip `control & 0x3F` pixels (leave as `transColor`) |
| `>= 0xC0` | read one colour byte and fill `control & 0x3F` pixels with it |

A frame set with one frame becomes an image; multiple frames become an animation
(previewed at 100 ms/frame).

## 11.8 Messages (RES_MESSAGE)

Each `RES_MESSAGE` section holds one resource (`id 0`) of NUL-separated strings in
**CP850**. The Blue Force copy is Spanish. The Lua engine decodes each byte with an
embedded CP850→Unicode table and emits UTF-8, one string per line.

## 11.9 Sound (RES_SOUND)

`RES_SOUND` resources are scored Adlib/MIDI tracker data that require the game's
own sound driver to play, so they are exposed as header metadata only
(`maxVersion@4`, `minVersion@6`, `groupTableOffset@8`, `priority@12`, `loop@14`).
`RES_STRIP` cutscene scripts are likewise not decoded.

## 11.10 Verification

- Independent Python reference decoder (RLB parse + LZW + tile composite +
  palette + surfaceFromRes/RLE) reproduced pixel-for-pixel and, under the real
  LuaJ 3.0.1 runtime via `./gradlew devcli load`, matched with **0 differing
  pixels**: Ringworld `bg_20` 640×200 (0/128000), Ringworld `spr_1502_1` 5 frames
  (0/13340), Blue Force `bg_20` 320×200 (0/64000), Blue Force `spr_0_1` 5 frames
  (0/12480).
- Full-corpus sweep under LuaJ (`devcli scan`, every leaf) decoded with **0 load
  failures**: Ringworld 1298 leaves (90 backgrounds, 92 palettes, 896 sprite sets
  = 4638 frames, of which 4457 across 715 multi-frame animations, 56 messages, 164
  sound metadata); Blue Force 1560 leaves (67 backgrounds, 85 palettes, 1242 sprite
  sets = 8526 frames, of which 8325 across 1041 multi-frame animations, 47 messages,
  119 sound metadata).

---

# Part 12: The Neverhood — BLB Archives & Resources

Source: ScummVM `engines/neverhood` (`blbarchive.cpp`/`.h`, `resource.cpp`/`.h`,
`resourceman.cpp`, `graphics.cpp`, `animation.cpp`, `sound.cpp`, `text.cpp`,
`video.cpp`, `neverhood.cpp`, `detection.cpp`) and `common/compression/dcl.cpp`
at `/scummvm-fork`. Game data in `ags/neverhood/DATA`. Engine script:
`scripts/engines/neverhood/engine.lua`.

The Neverhood (1996) stores every asset in a set of `.BLB` ("DreamWorks
interactive") archives. Detection is
`AD_ENTRY1s("hd.blb", md5 22958d968458c9ff221aee38577bb2b2, 4279716)`. On disk the
names are upper-case (`HD.BLB`); the loader searches `DATA/`, `data/`, then the game
root. Archives are merged in the order `a, c, hd, i, m` (plus an optional Japanese
`m`), `s, t`.

## 12.1 BLB Archive Layout

```
0x00  u32le id1          = 0x02004940
0x04  u16le id2          = 7
0x06  u16le extDataSize
0x08  u32le fileSize
0x0C  u32le fileCount
0x10  fileCount * u32le  resource hashes
      fileCount * 20 bytes entry headers
      extData blob (extDataSize bytes)
```

Each 20-byte entry (`blbarchive.h`):

```
+0x00 u8    type           (2 bitmap, 3 palette, 4 animation, 5 data,
                            6 text, 7 sound, 8 music, 10 video)
+0x01 u8    comprType      (1 stored, 3 DCL, 0x65 redirect)
+0x02 u16le extDataOffset  (1-based into the extData blob)
+0x04 u32le timeStamp
+0x08 u32le offset         (absolute file offset of the payload)
+0x0C u32le diskSize       (bytes on disk; for 0x65 = target hash)
+0x10 u32le size           (uncompressed size)
```

On hash collisions the entry with the **strictly greater** timestamp replaces an
existing one (`neverhood.cpp`).

### Redirect entries (`comprType == 0x65`)

A redirect stores the target hash in `diskSize`; `resolve_entry` follows the chain
to the real entry. The ext-data always comes from the **alias** entry while the
payload comes from the resolved entry (`ResourceManager::queryResource`). In this
game redirects appear only in `S.BLB` and always point at animation containers.

## 12.2 PKWare DCL (blast)

The compression is PKWare's "implode"/blast, identical in family to the AITD
decompressor. Stream header: byte 0 = mode (`0` binary, `1` ASCII; Neverhood always
binary), byte 1 = dictType (4, 5 or 6). Two hard-coded canonical Huffman trees
(`lengthTree` 31 entries, `distanceTree` 127) are encoded as
`BN(pos,l,r)=(l<<12)|r`; leaves are `LN(pos,v)=v|0x40000000`. A 24-bit LSB-first
window feeds `getBits`.

Decode loop:

```
len = value < 8 ? value + 2 : 8 + (1 << (value - 7)) + getBits(value - 7)
len == 519  -> end of stream
off = len == 2 ? (value << 2) | getBits(2)
               : (value << dictType) | getBits(dictType)
off += 1
copy len bytes from (dictPos - off) mod dictionarySize
```

**Critical detail:** the dictionary size is `2^(dictType + 6)` (1024/2048/4096 for
dictType 4/5/6), while the token-offset shift uses `dictType` itself
(`value << 6` for dictType 6). Confusing the two produces output that is correct
for the first ~64 bytes and then silently corrupts, since the dictionary wrap mask
is wrong. This was the one bug found during bring-up.

## 12.3 Bitmap (type 2)

`u16le flags`: RLE 1, HAS_DIM 2, HAS_POS 4, HAS_PAL 8, HAS_IMG 16. Header fields in
order: optional `u16 w, u16 h`; optional `u16 x, u16 y`; optional 1024-byte palette
(R,G,B,unused per entry); then the image.

- Non-RLE: rows are `(w+3) & ~3` bytes (pitch), values are palette indices.
- RLE: repeated `u16 rows, u16 chunks` blocks. `chunks == 0` skips `rows` rows;
  otherwise each of `rows` rows is `chunks` x (`u16 skip`, `u16 copy`, `copy`
  bytes). Terminated by a block with `rows == 0`. Always follows `spriteDataOffs`
  for animation frames.

Palette presence: full-screen HD backgrounds (entries 1-3) always embed one; most
sprite/font bitmaps do not and rely on an external palette. In the tree, images with
no embedded palette are rendered grayscale unless the user (or the auto-palette
hook) supplies one.

## 12.4 Animation (type 4)

```
0x00 u16le animListCount
0x02 u16le animInfoStartOfs
0x04 u32le spriteDataOfs
0x08 u32le paletteDataOfs
0x0C animListCount * 8 bytes:
       +0x00 u32le hash
       +0x04 u16le frameCount
       +0x06 u16le frameListStartOfs
```

`frameList = base + animInfoStartOfs + frameListStartOfs`. Each 32-byte frame record:

```
+0x00 u32le frameHash
+0x04 u16le counter        (draw delay accumulator)
+0x06 u16le drawX
+0x08 u16le drawY
+0x0A u16le w
+0x0C u16le h
+0x0E u16le deltaX
+0x10 u16le deltaY
+0x12 u16le collisionX/Y/W/H (4 * u16)
+0x1C u32le spriteDataOffs
```

Frame pixels are **always** RLE, located at
`base + spriteDataOfs + spriteDataOffs`; the palette (if `paletteDataOfs > 0`) is at
`base + paletteDataOfs`. A container's animList may carry more than one hash; the
addressable hashes include those contributed by redirects that point at it. The
per-frame delay is `(sum of counter) / frameCount * 1000 / 24 ms`. The Lua engine
caps frames at 150 for responsiveness. `S.BLB` holds 274 containers plus 84
redirects; `I.BLB` holds 13 self-contained animations.

## 12.5 Palette (type 3)

1024 bytes = 256 x (R, G, B, unused). Rendered as a 256x256 swatch (16x16 blocks).

## 12.6 Sound (type 7)

`extData[0]` is the shift. `0xFF` = 16-bit signed little-endian PCM @ 22050 Hz mono.
Otherwise the payload is 8-bit signed delta encoded:
`prev = (prev + int8) & 0xFFFF; sample = (prev << shift) & 0xFFFF` (16-bit signed
PCM). Shift is taken from the ext-data regardless of the BLB `comprType`.

## 12.7 Text (type 6)

`u32le count`; `base = 4 + count*4`; string *i* spans
`data[base + off(i*4) .. base + off((i+1)*4)]` using a `(count+1)`-entry offset
table (the last string runs to end of data). Embedded `\0` bytes are line breaks.

## 12.8 Data / Music / Video

Type 5 (data) is exposed as a hex/size preview. Type 8 (music) and type 10 (video,
Smacker) require their respective decoders; video is exposed as header metadata.
Music is surfaced under the "Music" category.

## 12.9 Palette association for surfaces without an embedded palette

Most bitmaps carry no embedded palette: of 1379 bitmaps, 298 carry a palette
(flags `HAS_PAL`) and 1081 do not. The 1081 no-palette surfaces are sprites, mice,
fonts, cursors and UI pieces. In game they are drawn over a scene background and
use that scene's palette, which is not recorded in the BLB archives — scene
composition lives only in the compiled game code (mirrored by ScummVM's
`modules/*.cpp`). The viewer originally applied an arbitrary palette to these,
which produced wrong colours.

Association is derived offline from the ScummVM module sources: each scene
constructor establishes its palette via `setBackground(hash)`/`setPalette(hash)`
(the background bitmap holds the scene palette), and the entities it inserts
borrow it. Signals used: `insertStaticSprite(0x...)`, `insertSprite<Class>(0x...)`,
`insertScreenMouse`/`insertPuzzleMouse`/`insertNavigationMouse(0x...)`,
`createStaticScene(bg, cursor)`, `loadSprite(0x...)`, class names embedding a scene
number (`SceneNNNN`, `AsSceneNNNN…`), and file-scope hash arrays named after the
scene (`kSceneNNNN*`, `kSsSceneNNNN*`). The result is emitted as
`scripts/engines/neverhood/neverhood_palette.lua`, a sibling module `require`d by
`engine.lua` (surface hash -> palette hash, where the palette value is a bitmap
with an embedded palette or a type-3 palette resource).

Coverage is partial by nature: 565 of the 1081 no-palette surfaces are mapped;
many of the rest are not referenced by any scene (unused/left-over assets), and
some shared sprites are legitimately reused across scenes with different
backgrounds. Resolution in `load_bitmap` when no embedded palette exists: use the
mapped scene palette if available, otherwise render neutral grayscale. The
automatic/external palette override is deliberately ignored for these surfaces, so
no bitmap is ever shown with an arbitrary palette. Scene palettes are memoised per
process so a shared background palette is decoded once.

## 12.10 Verification

Engine `scripts/engines/neverhood/engine.lua`; headless harness `devcli`
(`tree`/`scan`/`load`). Reference decoder in Python (`verify.py`, `dcltest.py`).

- **DCL:** byte-exact vs the Python reference for text resource `0x00918480`
  (`compr 3`, 916 bytes), including the long LZ copy/overlap runs.
- **Bitmaps:** pixel-for-pixel match with the Python reference — `0x00004011`
  640x480 non-RLE embedded palette, `0x0ca04202` 640x480 RLE embedded palette, and
  `0x0e018400` 96x224 non-RLE with an external palette override.
- **Animations:** `0x04441334` (12 frames, 2280x101 strip) and `0x06019390`
  (5 frames) decoded pixel-for-pixel against the Python reference.
- **Sounds:** `0x90805c50` (shift 2, 52736 samples) matched the Python delta decoder
  sample-for-sample (2391 ms @ 22050 Hz).
- **Text:** `0x00918480` decodes to "I am Quater. Read my words, ..." with correct
  line breaks.
- **Trees:** 2706 nodes in 8 categories — Bitmaps 1379, Animations 327 (= 316 from
  S.BLB + 13 from I.BLB minus 2 cross-archive duplicate hashes), Palettes 54,
  Sounds 295, Music 34, Text 12, Data 54, Videos 551.
- **Palette association:** sprite `0x020462e0` (21x266 RLE, no embedded palette)
  renders pixel-for-pixel identical to a Python render that applies the embedded
  palette of its mapped scene background `0x41983216`.
- **Sweep:** `devcli scan` over every category (bmp_, anim_, pal_, snd_, txt_,
  dat_) decoded with 0 load failures.

# Part 13: Virtual Theatre — Lure of the Temptress & Beneath a Steel Sky

Source: ScummVM `engines/lure` (`disk.cpp`/`.h`, `decode.cpp`, `surface.cpp`,
`room.cpp`, `palette.cpp`, `luredefs.h`), `engines/sky` (`disk.cpp`/`.h`,
`screen.cpp`, `screen.h`, `skydefs.h`) and `common/compression/rnc_deco.cpp` at
`/scummvm-fork`. Game data in `ags/lure` and `ags/sky`. Engine scripts:
`scripts/engines/lure/engine.lua` and `scripts/engines/sky/engine.lua`.

Revolution's Virtual Theatre shipped as two ScummVM engines; both games are
implemented as separate scripts here.

## 13.1 Beneath a Steel Sky — SKY.DNR table

`SKY.DNR` is an index into the `SKY.DSK` payload:

```
0x00  u32le  count
       count * 8-byte entries:
         +0x00 u16le fileNum
         +0x02 u16le x
         +0x04 u32le offRaw
```

`offset = offRaw & 0xFFFFFF` (shifted `<<4` when bit 23 set). Flags are read from
bytes 5-7 (`READ_LE_UINT24`): `size = ff & 0x3FFFFF`,
`compressed = ((ff>>23)&1)==0`, `includeHeader = ((ff>>22)&1)==1`. In this data set
1445 entries are present (`fileNum` up to 60663).

## 13.2 Beneath a Steel Sky — DataFileHeader and RNC

Each graphic begins with a 22-byte `DataFileHeader` (11 x `u16le`): `flag, s_x,
s_y, s_width, s_height, s_sp_size, s_tot_size, s_n_sprites, s_offset_x,
s_offset_y, s_compressed_size`. The RNC signature `52 4E 43 01` follows at byte 22.
File compression is RNC `unpackM1`, applied when `((flag>>7)&1)` is set and the RNC
signature is present. ScummVM gates this on the DNR `compressed` flag alone, but files
2134-2136 (whose DNR flag reads as uncompressed) are nevertheless RNC streams, so the
signature check is authoritative. The decoded payload is raw pixel data for both
`includeHeader` values:

- `s_sp_size == 0`: a single `width * height` image (screens/backgrounds).
- otherwise: `n_sprites` frames of `width * height` bytes at stride `s_sp_size`.

`decompSize = (flag & ~0xFF) << 8 | s_tot_size` is unreliable for backgrounds; the
RNC-internal `unpackLen` is used instead. Classification (empirical): sprites satisfy
`s_sp_size == width * height`; backgrounds are the raw screens (`(flag & 0xFF)` in
`{0x80, 0x82}`, 320 wide, `s_sp_size == 0`). The main palette is file 60111 (768 raw
bytes, 6-bit RGB expanded `(v<<2)+(v>>4)`).

## 13.3 Beneath a Steel Sky — RNC unpackM1

`common/compression/rnc_deco.cpp`: HEADER_LEN 18, TABLE_SIZE 128, signature
`0x524E4301`, `unpackLen`/`packLen` big-endian at 4/8, `blocks` at byte 17, data
starts at 18. The 16-bit bit reader is seeded from `LE16(src, 18)` then
`inputBits(2)`. Each block builds three Huffman tables (raw/pos/len) via
`makeHufftable`, reads `counts = inputBits(16)`, and loops: literal run length from
`inputValue(raw)` (copy those bytes from the source, then re-sync the bit reader from
the source position), and while `counts > 1` a back-reference with
`inputValue(pos) + 1` (offset) and `inputValue(len) + 2` (length) copied from the
already-produced output.

## 13.4 Lure of the Temptress — Disk format

Each `DISK*.VGA` (or `.EGA`) is a raw volume:

```
0x00  "heywow"               6-byte ident
0x06  u16be                  disk/file number
0x08  0xBF (191) * 8 bytes   FileEntry:
         +0x00 u16le id
         +0x02 u8    unused
         +0x03 u8    sizeExtension
         +0x04 u16le size
         +0x06 u16le offset
```

Real size `+= 0x10000` when `sizeExtension` is set; real offset = `offset * 0x20`.
The disk for an id is `((id >> 14) & 3) + 1`; ids in the `0x3fxx` range live in
`lure.dat`, the engine support file embedded in the game executable and **not part of
the disk images**.

## 13.5 Lure of the Temptress — Pictures and palettes

`PictureDecoder::vgaDecode` reads a colour table at `0x000-0x3FF`, a data-start
offset at `u32LE(data + 0x400)` and a secondary pointer starting at `0x404`; it uses
a CH/CL bit counter and `BP = color << 2` to index the table. Output is a 320x192
playfield (some full screens are 320x200). An EGA variant `egaDecode` is selected
when `(u16BE(data) & 0xfffe) == 0x140`. `Surface::loadScreen` places the 192-row
image at row `MENUBAR_Y_SIZE` (8) of the 320x200 surface.

Room palettes are `(screenId & 0xffe0) - 1`, overridden to `0x45ff` (room 6),
`0xf1ff` (room 49) or `0x40ff` for 5-bit screens. Palette resources are 660-byte
RGB64 (220 x 3 bytes, 6-bit components expanded `(v<<2)+(v>>4)`); `PaletteCollection`
splits them into 64-entry sub-palettes. When the computed palette id is absent
(disk-1 intro screens use `screenId + 1`), the loader falls back to `screenId +/- 1`.

## 13.6 Not decoded

Lure character sprites use `AnimationDecoder::decode_data` (nibble-packed streams
whose width/height come from the hotspot data in `lure.dat`). Since `lure.dat` is not
shipped with the disk images, sprites are not exposed. Cutscene `AnimationSequence`
data is likewise out of scope.

## 13.7 Verification

Engine scripts `scripts/engines/sky/engine.lua` and `scripts/engines/lure/engine.lua`;
headless harness `devcli` (`tree`/`scan`/`load`); Python reference decoders
(`rnc_test.py`, `lure_test.py`, `pngcmp.py`).

- **RNC (Sky):** outputs match the expected unpacked lengths — file 49 -> 1344,
  60300 -> 4356, files 64/92 -> 61440.
- **Sky backgrounds:** `sky_bg_64` renders 320x192 pixel-for-pixel identical to the
  Python RNC decode through palette 60111 (0 mismatches).
- **Sky sprites:** `sky_spr_49` frame 0 matches the Python decode (0 mismatches);
  animation strips carry all frames. Files 2134-2136 (10x8) decode via the RNC
  signature despite their DNR flag reading "uncompressed".
- **Lure screens:** `lure_scr_4201` renders 320x192 pixel-for-pixel identical to the
  Python `vgaDecode` through palette `0x41ff` (0 mismatches).
- **Full scan:** all 1022 Sky resources (162 backgrounds, 853 sprites, 7 palettes) and
  all 151 Lure resources (102 screens, 49 palettes) load with zero failures.
- **Trees:** Sky 1022 nodes in 3 categories — Backgrounds 162, Sprites 853,
  Palettes 7; Lure 151 nodes in 2 categories — Screens 102, Palettes 49. Detection
  and enumeration run in ~3.5 s for Lure (candidate decode-and-confirm at scan time).

# Part 14: Capstone / Genus GXL (Wayne's World & The Dark Half)

## 14.1 Scope

Wayne's World (1993) and The Dark Half (1993) are Capstone games whose graphics
are stored in **Genus Microprogramming GXL** containers. Both use the same
container; only the file naming differs (`R00-R39`, `E00/E01`, `M00-M06`,
`OA2/OA3/OAN`.GXL for Wayne's World; `K*.GXL` for The Dark Half). No ScummVM
engine exists for them — the format was reverse engineered from the data.

Fievel / An American Tail (Capstone, 1993) is a *different*, Manley &
Associates engine and is covered separately in section 14.4 (implemented in the `capstone` engine).

## 14.2 GXL container

```
+0x000  u8       0x01
+0x001  u8       0xCA
+0x002  ASCII    "Copyright (c) Genus Microprogramming, Inc. 1988-90"
+0x080  DIR      array of 26-byte directory entries
        DATA     entry payloads (absolute file offsets from the directory)
```

Directory entry (26 bytes):

| Offset | Type | Meaning |
|--------|------|---------|
| +0  | u8    | flag (0x00 for graphics entries) |
| +1  | char[12] | name, space padded, NUL terminated (e.g. `BACKG   .PCX`) |
| +13 | u8    | NUL terminator |
| +14 | u32le | data offset (absolute) |
| +18 | u32le | data size in bytes |
| +22 | u32le | unknown / unused (not a checksum; varies) |

The directory has no explicit count: it ends at the first data offset, so
`entries = (firstDataOffset - 0x80) / 26`. Every payload is a standard
**version-5 PCX** (8bpp, single plane, RLE) whose 256-colour palette sits in the
trailing 768 bytes (after a `0x0C` marker). A handful of entries are not PCX and
are surfaced as text metadata.

Detection requires at least two `*.GXL` files carrying the `01 CA` +
"Genus" signature.

## 14.3 Verification

`scripts/engines/gxl/engine.lua`. Cross-checked against PIL: Wayne's World
`R00.GXL` (BACKG 320x150, SPEAKER 43x12, CAMERA 73x36 …), `E00.GXL`
(BACKG 320x200, PHONE1 156x74 …), and The Dark Half `KEA00.GXL`
(ARREST 320x133, GAMEOVER 213x36, DEADTHAD 320x133) all decode to matching
dimensions. Each game exposes 52 GXL files.

## 14.4 Fievel / An American Tail (AMTAIL) — implemented PIC and ACT resources

Reverse engineered from `AMTAIL.EXE`. Each `.PIC` is a container
(`LZPX` = LZ-compressed, `UNCP` = stored):

```
magic[4]      "LZPX" or "UNCP"
u32le P       offset of the first stream (= 8 + 4*numExtraStreams)
(P-8)/4 x u32le   offsets of streams 2..N
streams start at P, then at each table entry
```

Each stream is size-prefixed (`u32le payloadSize`). Uncompressed payload layout:

```
u16le width
u16le height
768 bytes   palette 1 (256 x RGB, 6-bit VGA)
768 bytes   palette 2 (fade / dark variant)
u16le       encoded pixel-stream length
RLE pixel data
```

The pixel RLE is: read `c`; if `c & 0x80` -> run of `(257 - c)` copies of the
next byte; else -> a literal run of `c + 1` bytes. Runs may overrun the final
row slightly; the decoder stops at `width * height`.

The `LZPX` decompressor (AMTAIL.EXE, code segment paragraph 0x2a28) is an
**adaptive Huffman + LZ77** codec over 314 symbols (0-255 literals, 256-313
match lengths) with a 4096-byte sliding window seeded with `0x20` bytes. It was
ported to pure Lua in `scripts/engines/capstone/engine.lua`, including tree
reconstruction at frequency 0x8000. The saved earlier emulator outputs diverge
from the standard LH1 reconstruction on some long streams and should not be
used as a byte-exact oracle for those tails. The implemented streams produce
size-consistent image and actor data and have been scanned and visually checked.

ACT (`LZST`/`LZSP`) headers store frame count at +4 and decoded size at +10.
The LH1 stream starts at +14. Each frame contains eight u16 fields: width,
height, left/right/top/bottom bounds, mask length, literal-pixel count. After the
16-byte header come the mask bytes and then the literal pixels. A mask high bit
starts a new row; bit 6 copies `low6` pixels, otherwise `low6` pixels are skipped.
Some Geneva sprites have a right bound one beyond the nominal width; use the
larger width. Preview animations enumerate stored frames, without interpreting
scene scheduling. Actor colours come from the selected PIC palette.

## 14.5 The Beverly Hillbillies — RES archives

Header: u32 data start (16), u32 directory offset, u32 data length, u32 directory
length. The footer repeats this header, followed by directory metadata and typed
groups at footer +30. Group records use reversed FourCCs (`GAMI`, `LMRF`, `RTSC`,
`NECS`, `XFSD`), last-index u16 and entry-size u16. Ordinary entries have 12-byte
stride: id u16, sentinel u16, packed offset u32, unused u32. The low 24 bits of
the packed offset are relative to data start; the high byte contains flags.
MMAP nests references to map data and image resources.

Each payload starts with u32 stored size. Compressed payloads also have a u32
expanded size. Flag 1 selects PackBits; flag 0x80 selects byte-flag LZSS, LSB
first. A set flag copies a literal; a clear flag reads `a,b`, distance
`4*b + floor(a/64)`, length `(a % 64)+3`. Distance zero ends the stream.
PackBits decoding stops at expanded size; some resources have trailing padding
which is not another command.

IMAG data starts with big-endian u16 height, width and plane count. Rows have
word-padded bitplanes interleaved by row, with the low plane first. The two VGA
palettes are stored in HB.EXE at DS:A09 and DS:D09; DS is supplied by the startup
MOV DX instruction. The explorer unpacks LZEXE data without executing the game.
STRC dialogue is DOS CP850. FRML/SCEN/DSFX and MMAP map bytecode are data previews.

## 14.6 L.A. Law — DISK resources

DISK*.RES consists of contiguous `LZSS` blocks with checksum u16, packed size u32,
expanded size u32 and payload. Flags are u16 little endian, consumed MSB first.
Set bits copy literals; clear bits read a u16 with distance `(v % 1024)+1`,
length `floor(v/1024)+3`. A zero reference terminates the stream.

The expanded image header is **14 bytes**, not 16: dimensions at +6/+8,
row stride at +10 and palette colour count at +12. The palette starts at +14,
followed by chunky pixels. Expanded blocks round up to 16-byte boundaries;
assuming a 16-byte image header shifts both colours and pixels and rejects the
169x173 image in DISK3. Standalone LBM files are standard ILBM (including
ByteRun1 row/plane data). Case text is CP850 and XMI music uses the host decoder.
ABT speech uses the game's sound driver encoding and remains metadata.

## 14.7 Capstone validation (2026-10-15)

Full scans through the application's LuaJ runtime loaded all 3,388 listed leaves
with zero failures: AMTAIL 1,634 (80 pictures, 1,336 actor frames, 50 animation
previews, 160 palettes and 8 scene-data previews); BHB 1,638 (including 1,364
IMAGs, 2 palettes and 5 playable MIDI conversions); LALAW 116 (93 archived images,
3 ILBMs, 3 MIDI conversions, 8 case texts and 9 speech-data previews).
Representative Fievel sprites/logo, BHB forest background and LA Law photographs
were visually checked. Existing Wayne's World and The Dark Half GXL detection
and sample image loads still pass. `lua scripts/tests/capstone.lua` covers
compression boundary cases; append the local Capstone data root to scan all
three games, check resource-ID uniqueness and validate image/palette sizes.


# Part 15: Runaway: A Road Adventure

## 15.1 Scope and installation layout

The supplied Spanish Windows media (`ags/runaway`) has 80 RESOURCE files and
five DATAA speech archives loose on disc; additional shared resources, opening
animations, two speech archives and two SFX archives remain in Microsoft LZX
cabinets. The `runaway` engine detects the media root, an installed game root,
or a RESOURCE directory directly. It requires two valid scene archives with
size-consistent RGB565 backgrounds and a 1536-byte block 2, avoiding the indexed
Hollywood Monsters format. It does not execute the game.

`scripts/prepare-runaway.py` uses cabextract to build a separate data folder:
85 original loose files are linked and 14 cabinet members are extracted in this
copy. Original media remain untouched. This is a preparation-time dependency;
the engine itself reads ordinary files. Shared RESOURCE.000-.004 archives remain
metadata previews. Bink cutscenes and encrypted game logic are not decoded.

## 15.2 Scene archive, RGB565 and geometry

Each RESOURCE.[A-I]nn starts with an offset array followed by a size array.
The first data offset is 320 (40 entries) or 400 (50 entries, including E03).
Offsets/sizes are u32 little endian. Zero pairs mark unused slots; entries are
bounds-checked against the file length. Block zero is usually an RGB565 image;
opening-animation archives may instead have sprite banks in block zero.

RGB565 words have red in bits 11-15, green in 5-10, blue in 0-4. Components expand
using floor(value*255/maximum). Pixels run left to right, top to bottom. Raw
backgrounds lack dimensions; most use 600 rows. Scrolling exceptions were
identified using independent row-correlation analysis and visually verified:
D03 1200x670, D06 1760x1200, E10 1880x700, F37/H37 1444x800, G01 1400x760,
G02 1640x800, G03 1520x900, I01 2048x900, I03 1024x2062. These dimensions apply
only when the block size matches exactly. Assuming all images have 600 rows can
produce plausible repeated rows in D06, so dimensions require visual checking.

## 15.3 Sprite banks and masks

Frame descriptors are 14 bytes: relative span offset u32, x i16, width i16,
first/last y i16, span count u16. All descriptors precede span data; each relative
offset is measured from the end of that descriptor table. Spans carry x/y i16,
length u8, then twice that length in RGB565 bytes. Boundaries must meet the next
frame's offset exactly; the final frame consumes the block. First/last frames
are checked when indexing; each selected frame is checked when rendered. The
optional regression scanner validates every span of every frame.

Standalone overlays start with u16 span count, followed by x/y/length u16 and
RGB565 pixels. Standalone masks carry the same span coordinates without pixel
data. Depth/walk masks instead contain `(value u8, count u16)` runs expanding
to the background's pixel count. Overlays are cropped to their bounds, with the
original position included in the description. Unknown blocks remain metadata.

Preview animations use consecutive batches of at most 32 frames at 100 ms.
Every individual frame remains selectable. This bounds preview memory for banks
with over 1000 frames; it does not reproduce game-script scheduling or compositing.

## 15.4 PCM audio

Mxx (100 offsets), Sxx (1000 offsets), and DATAACA*.000 (12000 offsets) use cue N
spans `[offset[N], offset[N+1])`. Zero/repeated pointers, references into the
header and out-of-file ranges are skipped. Speech tables contain repeated/aliased
spans, so total cue bytes can exceed archive length without invalid references.

The extracted executable confirms **16000 Hz**, rather than assuming Hollywood
Monsters' rates: stereo signed 16-bit music at VA 0x408294-0x4082af, mono unsigned
8-bit speech at 0x408436-0x40845f, mono signed 16-bit effects at 0x4086d8-0x4086e7.
Each clip must align to its PCM frame size. Sample exports were parsed as WAV
and checked against these formats.

## 15.5 Verification

The supplied media tree exposes 45,638 leaves. Full bank validation covers
408 banks and 33,407 frame layouts. The real-data regression rendered 1308
images (backgrounds, masks, overlays, both ends of each bank and sample previews)
and loaded all 10,362 listed PCM cues. All 70 backgrounds also loaded through
the application's LuaJ runtime; exceptional dimensions were visually checked.
Additional LuaJ checks cover sprite frames, a 32-frame animation, a cabinet-only
opening animation, and speech/music exports. Independent Python RGB565 decoding
is compared to the LuaJ output. Synthetic regressions exercise RGB565 extrema,
truncated spans, frame bounds, exact block consumption and scrolling dimensions.


The prepared folder exposes 49,193 leaves: 34,541 images, 1,287 animation
previews, 13,133 PCM cues and 232 metadata entries. Its full regression validates
425 banks / 34,131 frame layouts, renders 1,357 images and loads every listed
PCM cue. Original and prepared-folder scans complete without failed loads in
these checks. Background E01 and frame B02/4/1 match the independent Python
RGB565 decoder pixel for pixel; exported WAV headers confirm 16000 Hz stereo
16-bit music and mono 8-bit speech. Opening the existing Hollywood Monsters
folder still selects its own engine.


## Les Manley 2 and El Tesoro de la Isla Alcachofa (2026-10-16)

Both games now have Lua resource engines. See the corresponding sections of
`engine-sources.md` for verified binary layouts and validation coverage.

Two prior handoff conclusions were incorrect: LES2's ILBM tags are real custom
picture wrappers (19-byte BMHD and LZW chunky pixels), and TESORO.TRE has no
8-byte header (each 28-byte record begins with offset/size, then flag/name).
Tesoro image spans store relative skips, not absolute x positions. Resource
names, audio, RGB565 room images and sparse character sprites now decode.
LES2 exposes 498 decoded picture banks and 83 palettes; its one remaining
invalid LZW stream is preserved as metadata. Neither engine interprets original
scripted scene composition/timing; LES2 audio remains unsupported.


## Pink Panther (2026-10-16)

The supplied Spanish Passport to Peril (`Peligrosa/PPTP.ORB`) and Hokus Pokus
Pink (`Abracadabra/HPP.ORB`) use the Pink ORB v2 resource layout. They have
600 and 219 object directory entries respectively, with 14,737 and 11,091
resource references. All references in these copies reside inside the ORB;
companion BRO files are still supported for other layouts.

Passport: 8,423 CEL, 2,189 VOX, 1,349 WAV, 2,772 TXT, four MUS references.
Hokus Pokus: 7,319 CEL, 1,717 VOX, 1,325 WAV, 730 TXT references.
CEL is standard indexed FLC with a prefix and a first-frame pointer, not an
image file accepted by ImageIO. The new Lua engine decodes palette packets,
BRUN, COPY, BLACK and SS2 deltas, including odd last-pixel and line-skip opcodes.
Audio signatures identify WAV independently of filename. Resource page and
filename are preserved; no MFC object deserialization or scene interpreter is
needed for extraction. See `engine-sources.md` for offsets and preview limits.

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


## El Sulfato Atomico resource formats (2026-10-16)

The supplied Spanish DOS release at `ags/mortadelos/SULFATO` contains 111
`.alg` images whose first four bytes are `NMP\x08`. The remaining header,
PCX RLE byte stream, trailing palette marker (12) and 768-byte RGB palette
follow single-plane 8-bit PCX. Header coordinate bounds determine dimensions,
not the nominal 640x480 resolution fields: wide sheets/backgrounds are
1280x480. Every image expands exactly to header pitch times height. `1.SVS`
is an ordinary 640x240 PCX thumbnail, bringing the picture total to 112.

All 53 VHS files are FLC containers (magic 0xAF12). Fifty-two have prefix
chunks at offset 128; use the first-frame offset at header offset 80. Frame
magic is 0xF1FA; observed chunk types are palette 4, word delta 7, byte run 15
and postage stamp 18. Each file stores one extra loop-closing frame beyond
the declared frame count; omit it from previews. File speed is milliseconds.
Preview batches reconstruct earlier deltas and retain no more than eight
million pixels or 200 frames. They use uniform file timing and do not emulate
script playback or scene composition.

Of 736 WAV-named files, 735 are PCM mono unsigned 8-bit: 729 at 11025 Hz,
five at 22050 Hz, one at 13157 Hz. The remaining `sk494.wav` is a plaintext
developer message. Together with 31 ALD, eight CAL, one GSV, one SAV and one
TXT, this gives 43 raw text/data previews. ALD files are plaintext, unlike
Drascula's inverted text. No object rectangle layout or script semantics are
assumed. The new `sulfato` engine exposes complete image sheets, palettes,
FLIC previews, PCM audio and raw text, with strict picture/chunk bounds.


## 3 Skulls of the Toltecs (Spanish CD, 2026-10-16)

The 308,391,018-byte `ESPA_OL.PDI/WESTERN` starts with a 19,364-byte
little-endian offset directory. Its last word (4101) is not an offset;
the preceding offset points at the final 22-byte GUI image. EOF supplies
that resource's end. There are 4,840 payloads (indices 0-4839).

Scene payloads begin with `u32 imageSize, u16 height, u16 width`, followed
by 384 VGA palette bytes. Pixels begin at offset 392; a high-bit byte is
its low seven bits repeated `nextByte+2` times, otherwise one literal.
`imageSize+4` is the end of image data / start of the segmentation map.
All 56 backgrounds decode exactly to their declared dimensions and boundary.
GUI images use `u16 headerSize=4, u8 width, u8 height` and the same RLE,
with color base 224. Resource 9 supplies the 32 GUI palette colors.

Sprite banks contain 12-byte frame headers: signed y/x anchor, u16 h/w,
u32 offset. The first offset gives the table size. Every row and payload
boundary is validated when choosing a packet format: nibble color/count,
byte color/count, or seven-bit count with high-bit shadow presence.
All 533 banks validate unambiguously (415 16-color, 87 256-color, 31 shadow).
Palette fragments are script-selected; the browser exposes manual selection
and grayscale fallback, without inferring scene colors from archive order.

Animation banks begin `u16 h,w,deltaTickCount`, 768 VGA palette bytes,
then chained u32 packet sizes. Each normal packet contains pairs of count
and nibble-swapped color; zero count skips the second byte's pixel count,
preserving the previous canvas. Size 0 or 1 carries a one-byte hold count.
The timeline contains the initial image plus deltaTickCount ticks. The large
resource 914 declares 1000 delta ticks but stores only 955 packets, because
holds repeat the existing canvas. All 11 banks are exposed in bounded batches;
each batch reconstructs earlier deltas before emitting its selected frames.
Uniform 100 ms preview timing does not interpret game scripts.

The Spanish layout's raw audio ranges 936-4800 and 4819-4822 contain 3,868
unsigned 8-bit mono 22050 Hz clips. Enable these only when archive size,
directory size and resource count match the tested layout. Other releases
still get structural image/music classification and metadata for unknown data.
Indices 4801-4818 alternate nine XMIDI and nine standard MIDI resources.
The remaining 172 resources (including one empty audio entry) include scripts, fonts, cursor masks and 16
movie streams; these receive bounded hex/ASCII previews, not guessed decoders.


## Amazon: Guardians of Eden (Spanish floppy, 2026-10-16)

The supplied `AMAZON` directory uses AP archives with a u16 little-endian
count and u32 offset table; EOF ends the last member. DBE compression may
wrap a member or follow a screen palette. DBE has a 16-byte header, decoded
length at offset 4, and LSB-first LZW codes (256 clear, 257 end, dictionary
from 258). Width starts at 9 bits and grows when the next dictionary code
reaches a power of two, up to the source's 13-bit limit. The implementation
checks input bounds, dictionary references and exact output length.

Amazon playfields have a 16-byte header: u8 tile width/height/count,
u8 display width/height/unused, u16 wall/block counts, six unused bytes.
A 768-byte VGA palette follows, then count*256 bytes of 16x16 tiles and a
width*height byte matrix. This differs from Noctropolis's 19-byte header,
u16 tile count and u16 matrix entries. The supplied data has 41 playfields,
including the 2560x96 panorama in S45.AP. Another 40 screens contain a VGA
palette followed by raw or DBE pixels; recognized sizes are 320x200,
640x400 and 640x480. VGA components expand by floor(value*255/63).

Sprite banks use the AP offset structure. Frames have u16 width/height,
then each row is u8 x offset, u8 byte count, and raw pixels. Frames may have
up to 15 arbitrary padding bytes, normally aligning to 16 bytes; treating
padding as pixels rejects valid banks. There are 122 banks and 11 loose
BLK images. Index zero is shown as the stored background color.

There are 104 v1 videos: u16 declared count, width, height, a reserved byte
and flags byte, followed by u16 packet sizes. Flag 1 supplies an initial
raw background; other packets use byte commands (high bit means skip the
low-seven-bit count, otherwise copy that many literals). The supplied files
store declaredCount-1 packets. The game normally plays declaredCount-2
deltas; the browser deliberately exposes every stored packet, including
trailing packets, at uniform 100 ms. Earlier deltas are reconstructed for
each batch. A missing initial background begins black/index zero.

Palettes for actors and video depend on runtime state. The browser suggests
the only picture palette in the same archive; this is a suggestion, not
reconstructed game state. Character Cxx and scene Sxx numbers do not establish
a palette relationship, so no match is inferred between them.
Unassigned resources use grayscale and allow manual palette selection.

151 STEVE sound resources have a 32-byte header: rate selector at offset 5,
u16 sample count at offset 7, and signed 8-bit mono PCM at offset 32.
Selectors 1-4 map to 16666, 8334, 5525 and 4150 Hz, matching Access's
sound.cpp (Audio::makeRawStream flags=0). All 64 MIDI.AP members are offered
through the existing MIDI converter. MIDIDRV.AP remains driver metadata;
custom instrument patches, script execution and animation command streams
are not interpreted. Alternate/CD releases are not validated.


## Igor screen coverage refresh (2026-10-16)

The current Spanish floppy catalog identifies the room resources directly in
IGOR.DAT (11,199,335 bytes). The previous byte matching against CD resources
omitted different floppy artwork and reused incorrect palettes. The supposed
15 floppy shareware/splash screens were scan artifacts, not authored screens.
The catalog supplies the real Pendulo logo, title, title backdrop, seven credits,
five intertitles and 76 room/close-up backgrounds. The CD now has 75 backgrounds,
including IMG_Part79b (beach ending) with PAL_Part79. The extra floppy background
is IMG_CollegeCorridorMathClass. Floppy BOX_PhilipRoom is at 0x1c5416, not the
previous unrelated byte match at 0x16ddf0. Each maze uses its own catalog palette.

Telescope views are sparse pictures in ANM_Part32Tower, not raw IMG assets.
part_32.cpp loads the bank at buffer+1; the offset table is at buffer+0x851e.
For zero-based frame N the word is at data[0x851d+2*N], and the word points one
byte past the corresponding zero-based data position. Empty view draws frame 1,
tower draws frame 2, and conversation draws frames 2 then 3 onto a cleared
320x144 canvas. These previews use PAL_Part32Tower. Layer2 IMG resources in parts
78 and 79 are compressed animation banks and must not be shown as raw pictures.

Validation: the Lua harness decoded 301 floppy and 299 CD screen-related
resources, covering backgrounds, masks, boxes, text, telescope views, startup,
credits and UI. Every image had the expected pixel count and palette range;
all room palettes passed the VGA range check. The application’s LuaJ runtime
also loaded both versions’ complete room lists and startup/credit resources,
as well as telescope views and floppy UI. Exported contact sheets were visually
inspected. The gallery contains 98 floppy / 99 CD images; four per version are
stored interface panels without dynamically drawn labels. This is an artwork
catalog, not an exhaustive replay of gameplay states or cutscene compositions.


## Una Aventura de Cine: verified Alcachofa V3.0 resource formats

The supplied 2003 Spanish CD stores the installed folder hierarchy in two
independent Microsoft cabinets, `data01.cab` and `data02.cab`. Use cabextract
with Windows-1252 filename encoding. The installer `Data/adata` directory is
not the game data. The second cabinet holds thirteen BIN videos.

AN0 has no magic: two little-endian u32 counts (sprite count, image count),
then consecutive TGA images ending with the 18-byte `TRUEVISION-XFILE.\0`
marker. The verified data uses RLE 32-bit/24-bit truecolor and 8-bit paletted
TGA. After the images: 256 u32 sprite bases, one signed i32 x/y pair per image,
256 u32 sprite mappings, u32 frame count. Each frame stores spriteCount u32
image offsets, signed i32 center x/y and movement x/y, and u32 duration.
For sprite ID i, j=mapping[i], and nonzero offset selects image
base[j]+offset-1 (zero-based). Offset zero disables a sprite. Transparent 2x1
images are placeholders. Image offsets position sprite layers. Three Ofelia
banks have zero sprites/images but valid frame tables; these are empty resources.

SND begins with u32 format length, the WAVEFORMAT payload, u32 data length,
then audio data. The verified 4,150 clips are mono 22,050 Hz IMA ADPCM;
44 WAV tracks are stereo 44,100 Hz IMA ADPCM. ADPCM uses a predictor and
step index per channel, low nibble first, and four-byte channel groups.
Standard IMA rounding matches FFmpeg byte for byte on the checked speech clip.

V3 NKR files retain 32 cipher bytes, one embedded XOR key, four garbage bytes,
then remaining cipher bytes. Remove the five inserted bytes, XOR both cipher
ranges with that key, then decode Windows-1252. Full dialogue content is exposed.
Other room/script data and video files retain bounded hex/metadata previews.


## Grim Fandango (original PC, October 2026)

Verified the mounted GRIM_DISC_A/B archives using ScummVM's Grim implementation.
LABN version 0x10000 stores count/string-table size at offsets 8/12, followed by
16-byte records (name offset, absolute data offset, size, reserved). The NUL
string table follows all records. Validate all directory and member ranges.
The engine accepts a LAB directory or a disc root with GRIMDATA, without writing
to the media; copying both discs' LAB files into one folder permits combined browsing.

BM signature is `BM  F\0\0\0`. Codec, image count, format and bpp are at
8/16/32/36. Images start at 128, each with its own u32le width/height. Codec 0
stores raw pixels; codec 3 adds a u32le compressed length and an interleaved LSB
16-bit control stream with short/long overlapping byte references and explicit
end marker. RGB is little-endian RGB565; depth images use a grayscale preview.
All stored states are exposed separately, without inventing animation timing.
MAT image count is at 12; the field at 76 selects a 0- or 16-byte extra header.
Image data starts at 60 + count*40 + extra, with a 24-byte per-image header and
width*height palette indices. CMP contains 768 RGB bytes at offset 64. Texture
palettes are scene-selected; default previews use grayscale and manual overrides.
The discs together contain 5,191 decoded image states and 125 CMP palettes.

MCMP starts with a big-endian u16 record count and 9-byte records (codec, decoded
length, stored length). The first record describes an uncompressed WAVE/iMUS
header. A u16 codec-string-table length follows the records; audio blocks follow
the codec names and header. VIMA blocks carry mono or stereo predictors, MSB
variable-width codes, signed absolute escapes and an IMA4 fallback. Output is
signed little-endian PCM16. Forty speech/effect/music blocks were compared
byte-for-byte with the ScummVM C++ decoder. Some speech files end with a four-byte
VIMA block producing a single 16-bit sample; no speculative two-byte lookahead
is needed by the Lua decoder. Uncompressed iMUS PCM16 is big-endian and is swapped
for the host API. Playback concatenates stored blocks without executing iMUSE
jumps, hooks, regions or fades. RCNE GRIM.TAB uses XOR 0xDD after its four-byte
signature; supplied PC text uses Windows-1252.

Scene SET files and credits are readable text. Models, costumes, Lua bytecode,
keyframes and movies retain archive metadata and bounded hex previews. Scene
composition, scripted animation, 3D and SNM playback remain outside this engine.
Remastered, demos, EMI and alternate-platform layouts are unverified.


## SAGA: I Have No Mouth, and I Must Scream (DOS CD)

Implemented from the local ScummVM `engines/saga` sources; see the SAGA section
of `engine-sources.md` for exact source files and field offsets. Verified with
`/Users/gabriel/Desktop/ags/IHNMAIMS`, the Spanish DOS CD release.

RES archives have no magic header: the final two LE DWORDs are table offset and
count, with offset/size DWORD pairs immediately before the footer. Validate
both directory placement and every payload's bounds. Full CD SCREAM.RES has
1273 entries; scene LUT 1272 links scene descriptors to explicitly typed resources.

Images have dimensions, four reserved bytes, 768 RGB palette bytes and SAGA
RLE data. The decoder supports short/long literal runs, fills, overlapping
backreferences and two-color bitfields. Unbank groups of four rows before
flipping backgrounds vertically. Masks retain their stored vertical orientation.
Sprite banks start with u16 count and u32 offsets; beware that a one-frame bank
can resemble a 1x6 background. Validate sprite structure before image heuristics.
Some resource 834 sprite frames finish with a transparent run beyond the output
buffer; ScummVM clips these runs, so the explorer does the same.

Animations use LE magic 0x0044 and dimensions but BE commands/coordinates.
Decode delta frames into a persistent canvas with zero literals transparent.
Use scene resource lists, chapter cutaways and intro cutaway list 39 to pair
animations with backgrounds and palettes. Previews are bounded and cannot
reproduce script scheduling, concurrent layers or palette effects. Sprite banks
are exposed as individual frames, without inventing animation sequences.

Text tables use absolute u16 offsets, potentially wrapping at 65536, and NUL
terminators. Chapter metadata supplies actor/object text; module LUT 29 supplies
script dialogue IDs. PCM RIFF/WAVE audio lives in SFX/VOICES archives; GM/FM music
is XMIDI and uses the existing host converter. Untyped data gets a hex preview.
Spanish CD PATCH.RE_ remains unapplied, following its ScummVM detection entry.

---

## City of Lost Children: verified PC CRSL resources (2026-10-17)

The supplied `CITY/DATAS/CITE1.DAT` (708 entries) and `CITEG.DAT` (15) use
`CRSL 01 00`, u16le count and 28-byte directory records: three u32le values
(stored size, unpacked size, absolute offset), 12 filename bytes and four flag
bytes. These flags must not be included in filenames. All supplied entries are
uncompressed at the archive level; image compression is inside CRP/ZBF.

CRP uses `CRSL 01 02 01`, u16le dimensions at 7/9, u32le compressed size at 11,
and RLE at 15. Tags below 128 copy tag+1 literal bytes; tags >=128 repeat the
following byte tag-126 times. In particular, 0x80 is a two-byte run and 0xFF a
129-byte run. This accounts exactly for every supplied compressed picture/font
sheet. Three 307200-byte CRPs instead store headerless 640x480 indices.
CPA has eight header bytes `CRSL 01 01 00 01` followed by 768 RGB VGA components.
Depth ZBF version 2 stores dimensions at 16/18, decoded byte count at 20,
compressed byte count at 24 and the same RLE at 28. All 77 are 640x480.

FRM is a texture atlas, not a standalone encoded animation. The width at 14
(u16le), height at 16 (u32le), byte count at 28 (u32le) describe indexed pixels
at 40. A u16le rectangle count at 0 describes 14-byte records after the pixels;
x/y/width/height are at +6/+8/+10/+12. All 672 rectangles fit within 38 atlases.
Trailing data is retained but its sequence/3D meaning is not interpreted.

Dialogue has a u32le count, four-byte scene code, and count+1 u32le offsets.
Offset zero points to four-byte names; the rest point to text blocks. Lines
carry a u16 position and u8 style/speaker before Windows-1252 bytes; form feed starts
the next header. This yields 95 tables in five languages. Installer TEXTDATA
files are also plain Windows-1252. SNW directories contain count/data-byte-count,
then 16-byte size/offset/zero/zero records; all 273 effect clips validate.
CITE.EXE offsets 0x28680..0x2869B set Miles format 0, flags 0 and rate 11025,
confirming unsigned 8-bit mono PCM. All 265 loose WAVs declare this same format.

The engine exposes 1955 leaves: 871 images (80 pictures, four font sheets,
77 depth masks, 38 atlases, 672 crops), 105 palettes, 538 audio clips, and
441 text/metadata resources. Images use same-stem or room CPA palettes, with
manual selection and grayscale fallback. No 3D rendering, scene composition,
model animation, script execution, YOP playback or TRACK2.RAW decoding is
implemented. Reference: engine-sources.md; regression and full-media decoding
runner: scripts/tests/city.lua. LuaJ runtime exports verify the host integration.

Validation: synthetic decoder/archive tests and a complete 9,210-resource sweep
passed, including all 176 backgrounds/screens, 80 masks, 4,834 sprite frames,
231 bounded animation previews, 177 palettes, 100 text tables, 2,940 PCM WAVE
clips, 80 XMIDI tracks and 592 metadata previews. All 231 animations reached
their frame count or documented preview cap without incomplete-stream errors.
Headless LuaJ exports also verified actual PNG, WAVE, MIDI and text output.


### 3D preview implementation follow-up (2026-10-17)

Grim binary/text 3DO previews now assemble stored hierarchy poses with a shared
software renderer. City TMM previews decode mesh geometry only; character parts
remain in bone space pending SKL/ENV/ANI interpretation. Both support rotation,
zoom, wireframe and PNG export. A real-data test scanned 545 Grim entries
(including four empty helper objects) and all 44 City meshes without unexpected
decode failures. Parser bounds, hierarchy transforms, depth ordering and PNG
bulk export are covered by the Kotlin tests. No skeletal playback or texture
sampling is claimed.


### Bud Tucker in Double Trouble (2026-10-17)

The supplied Spanish DOS data resides at `~/Desktop/TUCKER`, rather than
`~/Desktop/ags/TUCKER`. Its loose PCX art uses standard 8-bit single-plane RLE
with bytes-per-line padding and a trailing 0x0C + 768-byte RGB palette. Walk
masks are separate PATH PCX files; LOC files are stored background tiles.
PANOBJS sheets have 50 inventory icons on a 10x5 grid, 32x24 pixels each.

SPR files start with a u32le frame count and count four-byte offset slots;
ScummVM reads only the low 24 bits. Each frame has a 12-byte header (width,
height at +0/+2, x/y origins at +8/+10), then nonzero literal colors or a zero
followed by the count of transparent pixels. Runs span rows. The 660 banks
contain 17,031 stored frames. Animation previews align those origins on a
shared canvas and batch at 60 frames / four million pixels, with a uniform
100 ms delay. Room palettes are selected by A/C bank location number;
unmatched banks use grayscale and permit manual palette selection.

ENC tables subtract 0x80 modulo 256. Their resulting Spanish DOS CP850 bytes
are converted to UTF-8; authoring comments and script/table syntax remain
visible. WAV audio is PCM, 8/16-bit mono in the supplied copy. FX298.WAV is
actually Creative VOC and SAM1571.WAV is a non-RIFF binary; both are retained
as metadata. Intro FLC/FLR/PIC, RAW and ScummVM compressed audio replacements
also receive metadata previews. No game scripts, room composition, palette
animation, actor sequence logic or movie playback are executed.


Validation: synthetic PCX stride/RLE, SPR offsets/runs/origins, RIFF chunk and
CP850 regressions passed. A complete native-Lua scan decoded all 17,498 images,
756 animation batches, 317 PCX palettes, 4,594 WAV clips, 25 text tables and 54
metadata resources without failures. The additional grayscale palette and
manual palette override passed focused checks. Headless LuaJ exports verified
background and palette PNGs, aligned sprite animations, Spanish UTF-8 text and
16-bit PCM speech WAV output. The final catalog has 23,245 leaves, including
the added grayscale palette (318 palettes in total).


### Jack Orlando original PC CD (2026-10-17)

Verified against `~/Desktop/ags/orlando` (Spanish original PC CD). PAK and PA2
start with a u32le directory byte size, followed by 21-byte entries: u32le
absolute offset relative to the current archive, u32le stored size, and a
13-byte NUL-terminated filename. The count is `(directorySize - 4) / 21`.
Entries may overlap or repeat names; retain each directory slot with a unique
resource ID. DATA.PAK embeds SETUP.PAK and GLOBAL.PAK, whose offsets are local
to those embedded archives. Empty top-level archives are ignored.

BM and many numbered extensions store u16le width/height and exactly w*h
RGB565 words, top to bottom. Packed PBM (and some BM) stores the same dimensions,
128 RGB565 palette words at byte 4, then tokens at byte 260. An even token is
one pixel with index token/2. An odd token is followed by a byte repeat count,
with index floor(token/2). Decode exactly w*h pixels; a few small frames retain
unused bytes at the end of their allocated buffer. Tiny placeholder PBMs are
metadata, not images. BMX has a 24-byte header followed by indexed pixels,
with ERROR.COL or PALETA.COL (768 RGB bytes) from MENU.PAK.

Standalone FLX has a 20-byte header: `FLX\0`, u16le frame count, width, height,
fps and eight further bytes. Chunks are u16le kind / u32le size including six
header bytes. Kind 4 replaces the palette (512 RGB565 or 768 RGB bytes).
Kinds 0/1/2 draw transparent-zero skip/copy packets over the previous frame;
kind 1 adds a u32le linear start offset. Kind 2 starts with u32le expanded size
(including eight header bytes), u32le start offset, and byte RLE where FF,
value, count expands to repeated values. Terminal skip packets and unused
trailing packets are present. Kind 3 contains placement metadata, not a frame.
Previews are bounded to 60 frames and eight million pixels; placement is not
used to compose scenes. FLX packet semantics were cross-checked against the
NihAV Game Tool AVX decoder (see engine-sources.md).

Authoring script bytes decode as `(262 - byte) modulo 256`, recovering CRLF
text, bracketed filenames, numeric tables and REC/END sequences. DOS CP850
conversion preserves Spanish characters. Plain installer text is also exposed.
Raw SND effects have a 12-byte header (u32le payload length and eight zero
bytes), followed by unsigned 8-bit PCM. The 15360 Hz mono preview rate is an
assumption; WAVE clips instead use their embedded PCM format. Most Tnnn.SND
speech has a different 52-byte compressed header and remains undecoded. MUS,
DLG, AVX and fonts likewise retain metadata/hex previews. Scripts are not
executed, and animations are not assembled into game scenes.

Validation: synthetic tests cover RGB565 channels, packed runs and truncation,
script decryption, archive bounds, PCM RIFF parsing and FLX deltas. Per-category
scans of the supplied copy successfully loaded all 22,418 image resources,
62 bounded FLX previews, 822 PCM sound clips, two COL palettes and 9,150
text/metadata entries (including the help entry). LuaJ/DevCli detection and
representative image, animation and audio loads passed. Exported room and
character PNGs were visually inspected for orientation and palette correctness.


## Fable (1996) original PC CD resources

Verified directly against `~/Desktop/ags/FABLE`; offsets below are zero-based,
all integers little-endian. There is no Fable engine in the local ScummVM tree.

**ARC1:** four-byte magic, u16 entry count, then 22-byte records: name[14]
(NUL-padded), u32 absolute offset, u32 size. Entries are uncompressed. Bounds
are checked against the enclosing archive, with no entry path extraction.
`DECORS.DAT` holds 83 pairs of 256,000-byte raw 640x400 indexed images and
768-byte RGB VGA palettes (components 0..63, multiplied by four). Five title
screens are also 640x400; installer BACKGRND.RAW is 320x200.

**SPR:** magic `SPR\0`; u32 at offset 4 is 20; u32 fields at 8 and 12 reference
subsequent sections; u32 at 16 ends the pixel region and begins a per-frame
palette-offset table. u16 frame count at 20; absolute u32 frame offsets at 22.
The final frame ends at the field at 16, not the field at 8: using the latter
incorrectly includes palette tables. Each frame begins with four u16 values
(anchor X, anchor Y, width, height). Pixel streams are either width*height raw
bytes or row RLE: 0 ends the row, 1..127 copies that many literals, 128..255
skips opcode-128 transparent pixels. The decoder validates all rows, widths
and exact stream consumption before accepting RLE; only an exact-size payload
can fall back to raw. Some small RLE frames occupy exactly width*height bytes
(e.g. MCSPIRIT and bubble effects), so a raw-size shortcut corrupts them.

The palette-offset table has one absolute u32 per frame, zero meaning no patch.
The common patch format is u16 firstColor, u16 colorCount, then VGA RGB triplets.
468 nonzero pointers follow this format. Twelve older headerless blocks in
INSTALL/CLOSEUP and MISC/MISCDAT are unverified; their banks use the shared
palette. Room-local frames start with the corresponding DECOR palette; global
actors/UI start with room 101, title art with BOOKPAL, installer with PALETTE.
A manual override replaces that choice and suppresses patches. Frame-bank
previews are bounded uniform-speed overviews, not recovered script sequences.
There are 473 SPR banks containing 11,474 frames in this edition.

**TXT:** `TXT\0`, u32 dialogue-table offset (normally 12), u32 label-table offset.
A zero label offset denotes a dialogue-only file (245 of 555 TXT resources).
Each section starts with relative u16 string offsets; the first offset divided
by two gives the count. Dialogue entries begin with a speaker/control byte and
end with `$`; labels end with NUL. Display keeps speaker IDs and converts DOS
CP850 to UTF-8. Five localized extensions TXE/TXF/TXG/TXS/TXI are present.
Six installer text files bring the displayed text-resource count to 561.

**Audio:** 2,739 SPEECH WAV entries and one installer WAV use RIFF PCM; the
loose TITLE.WAV is also playable. SOUNDS.DAT holds 61 CMB1 bundles: magic, u16
count, pairs of u32 relative offset and u32 size. Each child begins with u32 PCM
byte count, u16 sample rate, u16 bits, u16 channels, then raw samples. All 191
children were validated: 176 at 22050/8/mono, eight at 22050/16/mono, five at
11025/8/mono and two at 15000/8/mono. 8-bit samples are unsigned, 16-bit signed.

Fonts FNT, cursor MOU, inventory INV, credits ANM, miscellaneous binary data
and IMAX movies are listed with bounded metadata/hex previews. They are not
decoded. No original script execution or animation timing is claimed.


## Delphine sprite frames (2026-10-18)

Verified against local ScummVM Cine `anim.cpp` / `gfx.cpp` and Cruise
`dataLoader.cpp` / `background.cpp`. Cine ANI/ANM has a 22-byte header: BE
byte-width at offset 4, height at 6, frame count at 14. Frames follow sequentially
as interleaved four-plane 16-pixel groups, each byte-width*height bytes.
SET has count at offset 4 and 16-byte records from offset 6: BE u32 relative
payload offset, u16 width, height, encoding, then three u16 metadata values.
Cine encodings 1/4/5/8 mean 1-bit mask, interleaved four-plane, 16-byte colour
lookup plus packed nibbles, and blocks of eight 16-bit plane words (even/odd
bytes provide the first/second eight pixels).

Cruise SET uses encodings 1/4/5/8 for mask, four-plane, five sequential planes
and raw 8-bit indices. SEC subtracts encoding*2 from byte-width before sizing.
For non-SEC type 5, display width is (storedWidth-10)*8/5 but plane rows retain
storedWidth/5 bytes: the last 16 pixels are cropped. Type 0 contains polygon
data; separate model-viewer listings now expose these flat actor poses and vector
artwork, including mirrored-frame references.

Cruise LOGOFIN.SET has directory size 2243 but compressed trailer size 2242.
Using the directory size as the backward decoder's output cursor introduces a
leading zero and shifts the SET header. Both decoders now use the trailer size,
bounded by directory size and 16 MiB. Cruise 16-colour backgrounds have 32
palette bytes, not 64; optional footer data must not change the pixel offset.

Background palette nodes provide explicit colour selection. Defaults prefer a
matching scene-name prefix, then an archive background; reused actors and
script-driven palette changes require manual selection. Frames are shown on
an opaque canvas with their original palette indices. Scripted animation timing
and transparency compositing are not replayed.

Validation: synthetic ANI, SET 1/4/5/8, SEC, truncated data, invalid dimensions,
and padded unpack-size regressions in `scripts/tests/delphine.lua`; complete
local sweeps decode 1,989 Future Wars frames in LVDT (including PART04B) and
2,345 Cruise frames in CR256 across D1-D5. Operation Stealth formats share the
Cine decoders and are covered synthetically; its game data is not installed.


## Simon 1 & 2 AGOS decoding corrections (2026-10-18)

GME contains heterogeneous resources, not graphics pairs throughout. Simon 1's
music starts at slot 329, Simon 2's GM banks at 282, and MT-32 banks at 435.
Simon 2 graphics extend through zone 140 (slots 280/281). Header validation and
zone bounds prevent XMIDI and script data from becoming bogus images.

Wide-image offsets are relative to each 4-byte offset entry, not the beginning
of the image. Their signed RLE counts repeat one source byte for nonnegative
counts and copy literals for negative counts. Ordinary 4bpp sprites use the
header compression flag; 5bpp packed images are identified by their byte span,
including non-screen-sized artwork. Transparent nibble zero and draw flip flags
must be preserved during composition/animation. Palette words use the low byte.

Negative VGA operands reference variables without consuming another word.
Pathfinder records start after a two-byte slot and end in word 999. Simon 2 long
delays are words. Palette/start operations must append to the same stream as
sprite frames rather than being overwritten by a separate frame counter.
Animation counts now derive from vc24 frames; empty script-only entries are omitted.
UI palettes persist from zone 0; Simon 1's actor bank 2 is initialized by zone 19.
Room and animation palette operations override those startup colours.

Sound banks use LE offsets, with a zero slot followed by the table byte size;
repeated offsets alias a sample. Simon 2 SFX banks start at GME slot 415, with
sample offsets relative to each bank. External EFFECTS/SIMON/SIMON2 VOC, WAV or
MP3 banks share that layout. VOC PCM blocks and continuation/silence blocks are
decoded, and JLayer decodes individual MP3 clips without an external executable.
GMF music uses seven-byte headers, 192 PPQN, DOS tempo mapping and operandless
pitch bends. XMIDI banks currently preview their first sequence.

Inventory icons use vertical nibble-pair RLE. Simon 1 has one 24x24 layer in bank
14; Simon 2 has two 20x20 layers in banks 14 and 13, with zero nibbles preserving
the previous layer. Both use the persistent UI palette.


### Cruise polygon actors and vector poses

Type-0 SET records use width*height as their payload size. Direct poses contain
anchor x/y at offsets 3/4, unsigned point count at 5, then unsigned byte x/y
pairs from 6. The remaining stream contains ordered commands: u8 point count,
u8 colour index, unused u8, BE u16 minimum scale, and point indices when count
is greater than one. Counts zero/one skip only the five-byte command header.
A 0xFF byte terminates the stream. The preview uses scale 512 (natural size),
including commands with minimum scale <=512. Two-point commands draw lines.

A payload starting with two zero bytes is an eight-byte alias: BE signed
relative frame index, signed x offset, signed y offset. Resolve against the
original SET record index, reflect the target around its anchor, and apply
the offsets as `x = -x - offsetX`, `z = z + offsetY`. Bounds checks reject
invalid, cyclic and nested references, non-polygon targets, invalid point
indices and unterminated or truncated commands.

These are 2D vector drawings, not volumetric meshes. The shared model viewer
uses a planar flag, front-facing initial view, unlit palette colours and
painter-order rendering. Concave polygons retain their full boundaries; lines
remain interleaved with polygons. Zoom, wireframe, rotation, palette selection
and PNG export reuse the existing controls. No invented depth is introduced.
Cruise's RGB palettes are full 8-bit components, passed directly to ScummVM's
`gfxModuleData_setPalEntries`; the previous VGA multiply-by-four was incorrect.
Shared actors may need a different scene palette, selectable in the viewer.

Verified against `cruise/mainDraw.cpp` (`flipPoly`, `buildPolyModel`),
`dataLoader.cpp` (`loadSetEntry`) and `gfxModule.cpp`. Six Kotlin tests cover
polygon overlap, exact colours, line order, concavity, minimum-scale filtering,
malformed resources and mirrored references; the LuaJ integration test decodes
and renders all 2,812 polygon poses across the installed CR256 D1-D5 volumes.
The existing 2,345 bitmap frames still pass the Lua resource sweep. Scripted
animation, scene placement, clipping masks and palette changes are not replayed.


## Another World: original DOS resource support

The supplied `~/Desktop/ags/AW` has a 2940-byte MEMLIST (146 twenty-byte
big-endian records plus a final sentinel record) and thirteen BANK files.
Cross-checked layouts against the local ScummVM `engines/awe` implementation;
see `engine-sources.md` for function-level references and limitations.

The DOS bitmap format is planar despite the engine's 4bpp terminology:
four 8000-byte planes at 320x200. Palette banks contain two independent halves,
32 VGA palettes followed by 32 EGA palettes, rather than 64 RGB palettes.
Palette zero often represents a fade to black; previews must choose a visible
palette. Protection/title script 0x15 uses resource 0x12 for the Interplay logo
(the supplied data differs from the title description in the reference comment).
Its gold palette is slot 4 in resource 0x14. The visible ends of the scripted fades use slot 9 for the title resources
0x13/0x53 and slot 15 for the Delphine logo 0x47; the earlier script palette
assignments (14/23) are black fade endpoints. All can be overridden.

ByteKiller decompression validates trailer output length, backward reference
bounds and XOR checksum. The shipped compressed streams all pass. Empty
sound records remain visible as metadata without creating empty audio clips.
Sample headers describe initial and loop lengths in words; all 97 nonempty
samples fit their payloads. There are 313 previews after retaining unique
script-referenced playback rates (or explicitly labeled fallback rates).

Static control-flow traversal of nine bytecode banks finds 5,042 distinct
part/palette/shape-root combinations, including the shared 0x11 bank. Polygon
hierarchies validate without guessing record starts. Native-scale previews
retain child placements and colors on black; the standalone rasterizer does
not claim pixel-exact game scan conversion, VM animation, scene composition,
built-in head masks or page-copy effects. Music modules, font/text in the EXE,
and alternate editions are outside decoded playback support.

Per-image defaults now use static palette contexts rather than one palette for
an entire part. The decoder records instruction PCs, branch/call/task targets,
resource loads and palette commands. Call return sites are summarized without
executing scripts. Multi-source shortest-path passes find preceding palette
assignments and following assignments before the next display update; another
assignment stops propagation. The latter receives twice the proximity weight,
because the displayed image can acquire its palette after its geometry is drawn.
Votes accumulate across uses of a reused shape or bitmap. Candidate palettes
must illuminate a color index used by the image; otherwise a visible part palette
is retained. Deterministic ties choose the lowest palette ID. Verified logo fade
endpoints remain explicit. Descriptions identify inferred versus fallback palettes.

These defaults are representative, not a reconstruction of runtime scene state:
call returns are context-insensitive, installed tasks are analyzed conservatively,
and conditions, scheduling, page copies and palette animation are not executed.
Synthetic regressions cover palette reassignment, both branch arms, call returns,
task inheritance, drawing before palette selection, display boundaries, black
fade rejection and stable fallback/ties. LuaJ checks defaults across all image
IDs, different palettes within the introduction, and a manual override without
changing the automatic default.

Validation commands: `lua scripts/tests/anotherworld.lua ~/Desktop/ags/AW`
and `ANOTHER_WORLD_TEST_PATH=... ./gradlew --offline test --tests
'*AnotherWorldIntegrationTest'`. The former loads all 6098 leaves and tests
malformed compression, directory bounds, palette/bitplane interpretation,
polygon recursion and truncated instructions. The latter checks the actual
LuaJ host and representative exports, including all twelve bitmap resources.


# Discworld Noir / Tinsel 3 (English Windows 3CD)

Verified against the mounted original English discs on 2026-10-18 and local
ScummVM `engines/tinsel/{handle,graphics,sound,music,strres}.cpp`, `scn.h`, and
`noir/lzss.cpp`. Implemented separately in `scripts/engines/noir/engine.lua`
with bounded native LZSS/RGB565 decoding in `NoirCodec.kt`.

The 1,968-byte index has 82 records of 24 bytes: a 12-byte filename, full u32
unpacked size, unused u32, flags2 u32. Unlike DW1/2, size is not masked to 24
bits; the largest scene (`unseobse.scn`) is 24,927,309 bytes unpacked.
Compression bit 28 lives in flags2. The compressed scene stream has no size
header; it is MSB-first LZSS. A 1 bit introduces an 8-bit literal. A 0 bit
introduces a 12-bit dictionary offset followed by a 4-bit length minus two.
Offset zero terminates; no length is required after that sentinel. Dictionary
size is 4096, initialized to zero, write cursor 1; overlap is allowed. Decode
must stop at the sentinel and match the index size exactly.

Unpacked SCN files use the same absolute linked chunk headers as DW1/2.
IMAGE chunk 0x33340006 still contains 16-byte records, but the trailing fields
are i16 isRLE and i16 colorFlags, not hImgPal. Handles retain 25-bit offsets
and 7-bit index slots. RGB565 is little endian and 0xF81F is transparent.
Raw images store width*height words. RLE rows contain u16 codes: high bit means
repeat the following color word, otherwise copy literal words; low 15 bits
are the run length. Runs must fill each row exactly. colorFlags describe
scene blending and are reported without applying background-dependent effects.
Large images include full-screen overlays as well as base backgrounds.

Music chunk 0x3334001E holds u32 length/offset pairs into matching MUS files.
The original English tracks are MPEG Layer II (e.g. header FF FD), supported
by the existing JLayer path despite its MP3-oriented API names. Do not decode
concatenated scene music as a single track: preserve stored segment boundaries.
CD 3 has the shared English speech index/archive. IDX is a u32 offset table,
first word zero on this release. Nonzero entries point into SMP at a u32
length, or a high-bit-set subsample count followed by length/data pairs.
These payloads are also MPEG audio. Parse only the small headers when building
the catalog, and read an individual payload on playback.

Language TXT files use linked CHUNK_STRING/CHUNK_MBSTRING pages (64 IDs/page).
A normal byte is length; 0x80 introduces an 8-bit length, 0x90 introduces an
8-bit length plus 256. Other high-bit prefixes introduce multiple substrings.
SCN chunks tagged CHUNK_STRING can contain binary pixels, so only TXT files
are parsed as dialogue text.

The browser accepts flat installed data, copied cd1/cd2/cd3 folder layouts,
and any mounted DWN_ENG_n root or data folder. For the mounted English set it
also discovers the other two volumes. Missing scene files are reported in
catalog information; one decompressed scene is cached to limit memory.
BMV movies, GBL/RBH/H/PAL/VMC actor data, and runtime FILM/pcode animation and
scene composition are not decoded; chunk/file metadata and hex are available.

Catalog: 1,345 backgrounds/screens, 10,696 sprites/overlays, 76 music segments,
15,019 speech/sound subsamples, 1,092 text pages, and 1,569 data entries. The
original discs omit the index-referenced `extra.scn`; this is reported as
unavailable and does not prevent opening other resources.

Validation includes all 12,041 catalogued images through LuaJ, exact RGB565
and alpha fixtures, overlapping/zero dictionary references, malformed streams
and rows, original MPEG music/speech samples, language text, and portable
case-insensitive folder/missing-file fixtures.


## Star Trek DOS archives (25th Anniversary and Judgment Rites)

Both supplied Spanish editions use 14-byte DIR records and companion RUN/001
files. Names are 8+3 bytes; NUL terminates the basename even if trailing bytes
contain junk. The LE24 offset has a run flag at bit 23, seven-bit count, and
16-bit RUN offset. RUN contains an absolute LE24 position followed by LE16
strides between packed records. Each record starts with unpacked/packed LE16
lengths. LZSS uses LSB flags, one literal, zero match; match distance is the
upper 12 bits and length is low nibble plus three, with zero-filled 4 KiB history.

Rites has DATA plus FED, LIGHT, MADNESS, METH, NOMAN, SCOTTY, SENTNL and VOIDS
triplets. Bitmap run members must retain archive-qualified IDs: many mission
packs reuse resource names. BGD files are 64,776 bytes: 768 palette bytes,
an eight-byte bitmap header and 64,000 indexed pixels. BMP and ordinary SHP
use the same header without the palette. Origins are signed. STARS.SHP is an
816-byte starfield table, not a 3×3 image despite its initial header-like bytes.
PRI files store 64,000 four-bit priorities, high nibble first. PAL is 768 six-bit
VGA components. Database/dialogue text in these copies uses Latin-1 accents.

ANM uses 22-byte records with frame name, signed placement offsets, priority,
duration and four candidate next indices. Stored-order previews resolve bitmap
aliases through RUN entries and align frame origins. They deliberately do not
simulate branches, runtime timing, virtual crew recoloring/XOR overlays or BAN
background deltas. RAW audio has no confirmed sample rate. External UNCOMP VOCs
have self-described audio headers. MT/GM archives contain several XMIDI EVNT
sequences, all exposed individually with original instrument mapping.

The supplied STARTREK directory's S5ROOM3.BMP offset (4,653,198) points into
incompatible content (FORM bytes follow), and cannot expand to its declared
size. It remains browsable as a diagnostic. Rites SENTNL IFOOD.BMP is an empty
placeholder. Neither finding prevents other archive members from loading.

The exhaustive native Lua sweep validated 44,631 catalog leaves, including all
image/mask and animation previews. Only the known Anniversary S5ROOM3 source
entry produced a damage diagnostic; Rites had no failures. Five passing LuaJ
tests cover malformed LZSS, overlap/zero history, signed origins, VGA scaling,
Spanish text and 1,758 real previews across both games. All 1,225 music
sequences were also parsed as standard MIDI by the JVM; 197 external VOCs and
126 palettes were loaded through the host APIs. Bridge exports were visually
checked for both games.


## Take-Two DOS: Bureau 13 and Hell: A Cyberpunk Thriller

The supplied folders `~/Desktop/ags/TAKE2/B13` and `HELL` share the same
six-byte library header and trailing directory. Header fields are u16 count
and u32 directory offset. Each 12-byte record contains u32 payload offset
and an eight-byte NUL-padded name. Payload lengths come from the next record,
or the directory offset. Every offset is relative to its containing library;
Bureau's DATA.GL contains several levels of nested actor/image banks. Hell
also nests libraries (notably BACKGRND.PL/rtp). No extraction is needed.

### Packed image codec

Reverse engineering B13.DAT at file offsets 0x25200 (decompressor) and
0x252D2 (loader) established the 28-byte image header:

| Offset | Field |
| --- | --- |
| 0 | u8 flags: bit 0 palette, bit 1 index-remapping table |
| 1 | u8 maximum encoded color index (modulus = value + 1) |
| 2 | u8 final palette color index |
| 3 | u8 color key index, before remapping |
| 4 | u8 codec: 1 delta, 2 delta with repeat escape |
| 5 | fifteen delta bytes |
| 20 | u16 raw suffix pixel count |
| 22 | u16 height |
| 24 | u16 width |
| 26 | u16 compressed byte count |

The first compressed byte is an absolute encoded index. Remaining nibbles
are read low half first. Opcodes 0..D add the header's delta byte modulo the
color count; E also adds a delta for codec 1. F reads an absolute index from
the next two nibbles. Codec-2 E repeats the previous pixel `nextByte+2` times.
If that byte is FF, read two more bytes in high/low order for a 16-bit count,
then add two. The final rawTail pixels are uncompressed encoded indices at
the end of the packed buffer. Apply optional remapping to every output index.
After packed bytes comes (paletteLast+1)*3 VGA RGB bytes when flag 1 is set,
then maxIndex+1 mapping bytes when flag 2 is set. Validate the exact member
size and reject stream truncation, invalid indices, and output overruns.

All 3,871 Bureau images decoded, including 300 embedded palettes. The common
B13RTP resource contributes one additional palette (its first 768 bytes are
VGA RGB; its remaining translation data is not interpreted). Title and scene
exports were inspected visually. Preceding embedded palettes in each bank
supply defaults for later frames; the Bureau common palette handles remaining
unassigned images. These defaults do not reconstruct runtime scene scripts.

### Dialogue and media

Bureau TEXT.GL has twenty indexed text tables. Each starts with u16
nameWidthMinusOne and u16 count, followed by name[width+1], u32 offset,
u16 byte length records; offsets are relative to the table. All 3,875
strings fit their table bounds. The supplied edition is Spanish CP850;
NUL/tilde separators are displayed as line breaks. DATA.GL also has 63
PCM WAVE effects and ten standard MIDI files (Sound Blaster and Roland sets).
Other scripts/font/scene data retain metadata and bounded hex previews.

Hell PCX resources have one 8-bit plane and a trailing 256-color RGB palette.
Custom packed sprites use the same codec as Bureau. RTP palette resources
are nested in BACKGRND.PL. Many Hell resources are Autodesk FLC with palette,
BRUN, COPY, BLACK, SS2 word delta and LC byte delta chunks. Some FLC headers
have stale depth fields; all decoded frames remain bounded by dimensions and
chunk sizes. Some final COPY chunks declare two bytes fewer than the actual
pixel payload; accept the correction only when dimensions and the enclosing
frame size agree exactly. Previews cap at sixty frames/eight million pixels,
without reconstructing game scripts or scene composition. Unassigned sprite
palettes fall back to grayscale and can be overridden in the explorer.
Hell audio includes Creative VOC and PCM WAVE, decoded through existing host
APIs. DISK1.HEL is installation data, not a GL/PL/SL library; absent installed
resources are not fabricated or silently taken from another directory.

Regression coverage is in `scripts/tests/take2.lua` and `Take2DecoderTest.kt`,
including delta wraparound, repeat escapes, raw tails, remapping, VGA scaling,
CP850, malformed streams and optional real-folder integration.


Validation of the supplied data found 8,139 Bureau catalog leaves and 4,667
Hell leaves. Hell contributes 740 still images, 417 palettes, 3,054 sound
clips, 447 animation previews and nine metadata entries. An exhaustive native
Lua sweep initially found six short-COPY diagnostics; all six clips plus the
stale-depth MANSION clip passed after the bounded correction. The remaining
native previews passed. Real LuaJ integration verified 241 Bureau resources
and 860 Hell resources, including every MIDI track parsed by Java's MIDI
reader. Full-size ABYSS PCX and Bureau TITLE exports were visually inspected.
Palette state is reset at nested-library boundaries to avoid assigning an
unrelated parent/sibling scene palette to unassigned thumbnail banks.


## Little Big Adventure / TwinE resource findings (2026-10-19)

The supplied original PC editions are supported by `twine`. HQR is a sparse u32
absolute-offset directory with ten-byte entry headers and LZSS modes 0/1/2.
Some directories end in EOF offsets, others do not; infer slots from first offset
rather than universally subtracting one. Speech VOX files contain additional
unindexed records; enumerate them within each indexed entry's physical boundary.
Their first byte can carry continuation flags, replacing the C of Creative VOC
or R of RIFF. Restore it only when the rest of that signature is recognizable.

Verified native Lua sweeps decoded every catalog entry in both folders: LBA1 has
134 grids, 8,715 bricks, 120 sprite images, nine screens, 12 palettes, 70 text
banks, 230 effects, 2,818 speech segments, 66 MIDI entries and 13,168 metadata
entries. LBA2 has 148 grids, 17,903 bricks, 425 sprites, 39 screens, 42 palettes,
84 text banks, 606 effects, 1,261 speech segments, 18 WAV tracks and 25,191 metadata
entries. Native audio stubs verify signatures; actual decoding is checked in LuaJ.

LBA1 scenery uses matching GRI/BLL archive indices and shared BRK images. LBA2
BKG entry 0 specifies grid/fragment/library/brick ranges; grids add 34 bytes
before the same 64x64 column table. Library index is header byte 0; u16 column
offsets are relative to data after that header. Compositing brick RLE images in
z/x/y order with (x-z)*24, (x+z)*12-y*15 reproduces the full static scenery.
Actor composition, state changes, ceiling overlays and outdoor island terrain
are separate systems and not rendered. Twinsen's house was visually verified.

LBA2 BODY, OBJFIX and OBL models share a 96-byte v0x10 header, but do not use
LBA1's variable polygon records or vertex offsets multiplied by six. Polygons
are grouped by render type, with fixed record stride inferred per section.
Type bit 15 selects quads; UV-bearing triangles/quads use 24/32-byte records.
Bones translate vertices from local coordinates via parent anchor points; the
fourth u16 of each vertex is its bone index, not padding. UV group rectangles
crop the palette-indexed atlas; BODY/OBJFIX use RESS[6], OBL uses matching ILE[2].
The 1,447 model entries include two empty helpers (`ILOTCX.OBL` 12 and 13), kept
only as data. Preview surfaces retain polygon boundaries, palette colors, UVs,
lines and approximate sphere meshes, assembled in their rest pose. Skeletal
animation and game-specific transparency/shading are not simulated.

Dialogue uses paired ID/offset banks and CP850 strings, with an extra leading
byte in LBA2 strings. All palettes are byte RGB. LBA1 MIDI_MI and MIDI_SB keep
original mappings. LBA2 WAV files include Microsoft IMA ADPCM (codec 17);
`ImaWaveDecoder` implements predictor/index block headers, low-nibble-first
samples, stereo channel groups and fact chunk trimming with allocation bounds.
Regression tests cover malformed compression/RLE, skeleton cycles, direct polygon
indices, texture crops, ADPCM samples and optional real-game LuaJ previews.


Validation completed with the full Gradle test suite and nine targeted TwinE,
LBA2 model and IMA tests. The optional real-game integration decoded all 1,445
visible models through LuaJ plus representative resources from every archive
and category in both games, including real ADPCM speech/music. All assertions
passed. Twinsen, a fixed object, a Citadel outdoor tree and the first full scenery
in each game were rendered for visual inspection under `build/twine-previews`.
The model pass also checked palette overrides and missing-resource handling.


# SCUMM enhanced V2 object and mask extraction (2026-10-20)

Verified against the local ScummVM `resource_v2.cpp`, `object.cpp` and `gfx.cpp`
and the Spanish enhanced DOS Maniac Mansion under `ags/SCUMM/MANIAC`.

Only the first u16-length room block belongs to the room; scripts, costumes and
sound can follow in the same LFL. The u8 at +20 counts objects. Parallel u16
room-relative image/code-offset tables start at +28 and +28+2*objectCount.
For each code record, +4 is the u16 global ID, +7/+8 the x/y bytes (x8; y&127 then x8),
+9 width (x8), +10 parent, +11/+12 walk-to coordinates (x8, y&31 then x8),
+13 height/direction (height&248; direction&7), and +14 the byte offset to a
zero-terminated object name. DOS extended names convert from CP850 to UTF-8.

Both room and object pictures use whole-image column-major RLE. A clear high
bit gives high-nibble count/low-nibble colour; a set high bit copies the previous
column's colour at the same y, using the low seven bits as count. Zero count
reads an extended u8 count. Runs carry across columns, and the previous-column
table initializes to black. Return the consumed byte position: mask RLE starts
immediately there, not at an independent header offset.

Mask RLE emits one byte per eight horizontal pixels, walking down each strip
before the next strip. A set control high bit repeats the next byte; clear high
bit copies literal bytes; low seven bits give the count. Expand each byte MSB
first to a full-size black/white image. Reads stay inside the room/image section.

Non-drawing hotspots can reuse arbitrary picture pointers or point directly at
the code region. Listing them as bitmaps creates garbage and out-of-bounds reads.
All 460 code records remain in text reports, but pictures are offered only when
both bitmap and mask decode fully before the first object code record. Images
can intentionally overlap in encoded data, so the next image pointer is not a
reliable per-image bound.

The tested copy yields 53 room pictures, 269 object pictures, 322 masks, 53 text
reports and one EGA palette: 698 leaves. Native Lua and LuaJ scans pass; LuaJ
also exports representative object/mask PNGs, text and the 48-byte RGB palette.
Asset-free tests cover dither across columns, extended runs, mask bit order,
truncation, zero runs and invalid room/object tables. Original room_N IDs are
preserved. Actor costumes, scripts, music and other platforms remain outside this
V2 expansion; Zak has no real-data verification in this change.


# Sanitarium / Asylum resource extraction (2026-10-20)

New engine: `scripts/engines/asylum/engine.lua`. Reference: local ScummVM Asylum
`respack.cpp`, `system/graphics.cpp`, `system/screen.cpp`, `system/sound.cpp`,
`system/text.cpp`, `views/scene.cpp`, and `resources/worldstats.cpp`.

The official Windows demo was obtained from ScummVM's public demo download
(https://www.scummvm.org/frs/demos/asylum/asylum-demo.zip) and extracted to the
user-requested `/Users/gabriel/Desktop/ags/Sanitarium`. It contains RES.000/001/
002/004/005, SCN.005, sntrm.dat, and four Vids/*.SMK cutscenes. The ZIP is retained
under ignored build/sanitarium-research/. No installer or game executable is run.

## Archive and graphics layout

RES/MUS archives have u32 count then count u32 offsets; the last item extends to
EOF. Directory bounds, nondecreasing offsets and all resource/frame reads are
validated. The 27 combined-speech length repairs from ScummVM respack.cpp apply
only to the exact 299872422-byte RES.104/204/304 file and matching disc/index.
Synthetic tests verify the repair, filename/file-size scoping, and EOF rejection;
this source-based retail exception is not a full retail-data verification.
Zero offsets are absent entries, and zero-length entries are omitted
from resource previews. Only one resource is read for audio/graphics, rather than
loading entire potentially large speech archives. Directory/frame metadata caches
are rebuilt when the game is opened.

D3GR resource headers contain flags +4, content offset +8, palette pointer +12,
u16 frame count +24, u16 maximum width +26 and a u32 frame-offset table +28.
Frame offsets are relative to content offset. Each frame begins with two u32s
(size/flag), i16 x/y, u16 height/width, then raw row-major CLUT8 pixels. Header
sizes and output dimensions are checked before allocation. Empty frames remain in
animations, while empty font glyphs are omitted from image leaves. Font banks
must not be listed as ordinary animation sequences.

Palettes are D3GR resources with flag 0x2000; follow the +12 pointer, read u16
count/u8 first index/u8 unknown, then RGB triples in 0..63, scaled by four. The
three demo palettes each cover 256 colours. Partial palettes are accepted with
unassigned entries black, rather than inventing missing state.

DFISCN scene files begin with six-byte magic before WorldStats. Background,
fonts and current palette are at WS +0x24, +0x5C/+0x60/+0x64 and +0x68. Width/
height and action/object counts are at +0x88/+0x8C and +0x98/+0x9C. Resource IDs
encode 0x80000000+pack*65536+index. This binds the tower background and fonts to
RES.005 entry 20. Other images use the preceding same-pack palette when available,
with scene/archive fallback; such defaults do not claim to reproduce palette
swaps performed by scripts. All palettes remain manually selectable.

Sprites preserve index-0 alpha. Backgrounds stay opaque. Animation previews
compose each raw frame at its signed origin into a common bounding rectangle,
retaining blank frames. Delay is a fixed 100 ms UI choice; no gameplay scripts,
palette cycling, fades, blending or scene-layer composition are replayed. Bounded
animation canvases avoid excessive allocations; individual frames remain available.

## Masks, text, audio and data

Seven demo resources are masks: u32 height, u32 width, then width/8*height packed
bytes and a four-byte trailer. Bits are row-major, LSB first; white bits block
sprite drawing, confirmed against Screen::bltMasked. These export as full-size
black/white PNGs. Three 65536-byte colour-translation tables remain hex metadata.

RIFF/WAVE clips use the existing host decoder. All 171 demo clips are signed
16-bit mono PCM at 11025 or 22050 Hz, including the RES.002 music track. The
shared resource banks retain archive/index identity rather than inventing voice
speaker names. MUS.xxx files use the same archive reader for retail music data.

RES.000 contains 158 nonblank dialogue/text strings, 61 blank placeholders and
two binary script/lookup entries. Preserve brace markup, omit trailing SOH/NUL,
and convert Western Windows text from CP1252 to UTF-8. Binary data is not scanned
for arbitrary printable fragments. Reports include archive directories, bounded
hex for unclassified resources, scene-header fields and Smacker video metadata.
Smacker movie playback/extraction is not implemented.

## Verification and scope

The official demo yields 2494 leaves: 2051 raw graphics frames (1 background,
1615 sprite/UI frames, 435 glyphs), 7 masks, 89 animation previews, 171 WAV clips,
3 palettes, 158 text strings and 15 data reports. Native Lua sweeps load all
leaves. The background's 1095x897 RGB bytes match an independent Python/Pillow
decode byte-for-byte. Synthetic regressions cover malformed/sparse directories,
frame bounds, signed-origin alignment, partial palettes, mask bit order, text
controls and scene headers; they also run in LuaJ. AsylumIntegrationTest checks
all demo leaves and representative PNG/alpha, animation, WAV, text and palette
export, and compares decoded PCM with the JVM's independent WAVE reader.

Retail formats follow ScummVM's source layouts but have not been tested with
retail CD/GOG/Steam assets. In particular, multi-disc/shared-audio archive quirks,
localized encodings beyond Western CP1252, and script-driven visual state are not
established by this demo sweep. Opening a folder does not claim game execution.


## Sanitarium retail CD 1 follow-up

The user mounted retail CD 1 at `/Volumes/SANITARIUM1`. Loose files in `Data/`
include RES.000/001/003/005/006/007/018/104, SCN.005/006/007, SNTRM.DAT,
Music/MUS.005/006/007, Vids/ movies and vids.cap. No installer is needed. The 31
files (501310805 bytes) were copied and SHA-256 verified into
`/Users/gabriel/Desktop/ags/Sanitarium`. The previous official demo was preserved
at `/Users/gabriel/Desktop/ags/Sanitarium-demo` before replacing the root folder.

The loader now accepts either the Data folder or a disc root containing Data/,
and discovers Music/MUS.xxx without flattening the copied disc layout. Root music
archives win over nested duplicates. A separate mmap/struct inventory validates
all resource and frame ranges. CD 1 contains 14,320 nonempty raw graphics frames,
29 LSB-first masks, 27 palettes, 1,723 WAV clips (11 in nested music packs, 972 in
the sparse RES.104 speech pack), 3,911 text strings and 130 metadata reports.

Retail exposed a palette-default bug in the initial implementation: alternate
palettes at RES.005 indices 24-28 occur before ordinary sprites, which must keep
the scene's palette 20. Scene bindings now take precedence over archive order.
Chapter titles have explicit graphics/palette fields in WorldStats, serializing
at WS +0x2C0/+0x2C4 in retail and +4 bytes in the demo. Examples: RES.005 204/205,
RES.006 677/678, RES.007 400/401. The title images remain opaque and use those
palettes, rather than the room palette.

Source references in menu.cpp/menu.h, scenetitle.cpp, insertdisc.cpp and video.cpp
identify seven shared/menu font banks. They are grouped as glyphs rather than
animation previews. Retail menu/credit and insert-disc screens have explicit
palette bindings; subtitle and other dynamic assets may still need manual palette
selection. The resulting CD 1 tree has 20,806 leaves, including 666 animation
previews, 2,818 font glyphs, 11,499 sprite/UI frames and three room backgrounds.

AsylumIntegrationTest has separate demo and retail CD1 modes. The retail test
checks every leaf and representative background, title, music, speech, palette,
text and mask exports. The asset-free Lua/LuaJ tests also cover disc-root discovery,
nested-music duplicate precedence and demo-versus-retail title-header offsets.
CD 2/3 and digital releases still require their own data validation; CD 1 coverage
must not be described as validation of the complete three-disc game.

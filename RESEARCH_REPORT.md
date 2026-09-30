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

repeated for all `h` rows, top-down. This was derived from `002BTN01.BMP`
(340x55, 18,920 pixel bytes, exactly 55 uniform 344-byte rows of
`00 00 54 01` + 340 raw pixels) and confirmed on cropped rows by `101CHR01.BMP`,
a perspective-projected chair whose rows run from `xOffset = 6, length = 68` at
the top to `xOffset = 0, length = 86` in the middle and back down to
`length = 31` at the base. 2,787 of the 3,614 images have at least one cropped
row; the format exists precisely to store those trapezoids compactly.

Because `dataoff = 54` leaves no room before the pixel data, those 3,614 images
carry **no palette whatsoever**. The game keeps a single shared palette (the one
`.PAL` resource in `GFILE.HDR`), and its indices are game-wide, so a decoder
must not read colour tables out of the pixel stream: only palette quads that
lie before `dataoff` are real. Decoding clamped this way, both variants match an
independent decoder exactly.

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

All 83 are `biCompression = 0`, so background decoding never touches the
scanline format of 5.4. That format is implemented and verified (against 30
sampled scanline images plus 11 `BI_RGB` ones, pixels and palettes matching a
separate decoder byte for byte), but the engine only lists backgrounds for now.

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

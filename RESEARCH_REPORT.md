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

Source: [cobra-mission-writer volfile.cpp](https://github.com/AshleyWright/cobra-mission-writer), [MegaTech VOL Format wiki](https://wiki.scummvm.org/index.php/User:Wikipedia/Cobra_Mission)

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
| 0x02   | 1    | Version            | Format version                        |
| 0x03   | 1    | (padding)          | Usually 0                             |
| 0x04   | 1    | Palette flag       | Non-zero if palette follows header   |
| 0x05   | 1    | (padding)          | Usually 0                             |
| 0x06   | 4    | Subchunk table ptr | Offset to subchunk offset table      |
| 0x0A   | 2    | Num subchunks      | Number of image subchunks            |
| 0x0C   | 2    | Chunk size         | Total size of this GC entry          |
| 0x0E   | 2    | Checksum           | Integrity check                       |

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
| 0x02   | 2    | X offset       | Horizontal position (UINT16LE)       |
| 0x04   | 2    | Y offset       | Vertical position (UINT16LE)         |
| 0x06   | 1    | Width          | Width in 8-pixel units               |
| 0x07   | 1    | Height         | Height in pixels                     |
| 0x08   | 2    | Data size      | Compressed data size (UINT16LE)      |

### Image Dimensions

- **Resolution**: 640×480 (standard) or 592×360 (alternate, as seen in standalone decoder)
- Width is in **8-pixel units** due to planar encoding (each 4-byte planar group = 8 pixels)

## 2.3 GC Decompression Algorithm

Source: [gcparse.cpp](https://github.com/AshleyWright/cobra-mission-writer/blob/master/gcparse.cpp)

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

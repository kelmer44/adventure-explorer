-- ============================================================================
-- Adventure Explorer - Engine Script: Future Wars / Operation Stealth
-- ============================================================================
-- Delphine Software Cinematique evo 1 & 2. 320x200.
-- FW: 16-color, part01/part02 bundles, Atari ST bitplanes.
-- OS: 16-color or 256-color, vol.cnf + rscNN volumes.
-- ============================================================================

local engine = {}
engine.name        = "Future Wars / Operation Stealth"
engine.id          = "cine"
engine.description = "Future Wars (1989) / Operation Stealth (1990) - Delphine Software"
engine.version     = "3.0"

-- Binary helpers
local function u8(data, pos)   return data:byte(pos) end
local function u16be(data, pos)
    return data:byte(pos) * 256 + data:byte(pos + 1)
end
local function u32be(data, pos)
    return data:byte(pos) * 16777216 + data:byte(pos + 1) * 65536
         + data:byte(pos + 2) * 256 + data:byte(pos + 3)
end
local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end

-- ============================================================================
-- CineUnpacker - Backward LZ77 decompression (Delphine format)
-- Reads bits LSB-first via rotate-carry-right (rcr) mechanism.
-- Reads 32-bit BE words backwards from end of compressed data.
-- Verified against ScummVM engines/cine/unpack.cpp
-- ============================================================================

local function cine_unpack(src_data, unpacked_size)
    local src_len = #src_data
    if src_len < 12 then
        -- Not enough data for trailer; return raw bytes as array
        local out = {}
        for i = 1, math.min(src_len, unpacked_size) do
            out[i] = src_data:byte(i)
        end
        for i = #out + 1, unpacked_size do out[i] = 0 end
        return out
    end

    -- Read 12-byte trailer from end of source (three BE uint32 words)
    local read_pos = src_len - 3   -- last 4-byte word (1-based start)
    local datasize = u32be(src_data, read_pos)
    -- The trailer is authoritative: some directory sizes include a padding byte
    -- (for example Cruise LOGOFIN.SET). Decode from its true end, not that padding.
    assert(datasize > 0 and datasize <= unpacked_size and datasize <= 16777216, "Invalid unpacked size")
    unpacked_size = datasize
    read_pos = read_pos - 4
    local crc = u32be(src_data, read_pos)
    read_pos = read_pos - 4
    local chunk = u32be(src_data, read_pos)
    read_pos = read_pos - 4

    local output = {}
    for i = 1, unpacked_size do output[i] = 0 end

    local dst_pos = unpacked_size
    local error_flag = false

    -- Read next 32-bit BE word from source (moving backwards)
    local function read_source()
        if read_pos < 1 then
            error_flag = true
            return 0
        end
        local val = u32be(src_data, read_pos)
        read_pos = read_pos - 4
        return val
    end

    -- Rotate carry right: extract LSB, shift right, optionally set MSB
    local function rcr(input_carry)
        local output_carry = chunk % 2   -- extract LSB (carry out)
        chunk = math.floor(chunk / 2)    -- shift right
        if input_carry then
            chunk = chunk + 2147483648   -- set bit 31 (sentinel)
        end
        return output_carry
    end

    -- Get next bit from bitstream (LSB-first extraction)
    local function next_bit()
        local carry = rcr(false)
        if chunk == 0 then
            -- Sentinel consumed; refill from source
            chunk = read_source()
            carry = rcr(true)  -- put new sentinel in MSB
        end
        return carry
    end

    -- Get N bits, assembled MSB-first into result
    local function get_bits(n)
        local val = 0
        for _ = 1, n do
            val = val * 2 + next_bit()
        end
        return val
    end

    -- Copy raw bytes from bitstream to output (backwards)
    local function copy_raw(count)
        for _ = 1, count do
            if dst_pos < 1 then return end
            output[dst_pos] = get_bits(8)
            dst_pos = dst_pos - 1
        end
    end

    -- Copy relocated bytes: read from dst+offset (forward reference backwards)
    local function copy_ref(offset, count)
        for _ = 1, count do
            if dst_pos < 1 then return end
            local src_idx = dst_pos + offset
            output[dst_pos] = (src_idx >= 1 and src_idx <= unpacked_size) and output[src_idx] or 0
            dst_pos = dst_pos - 1
        end
    end

    -- Main decompression loop
    while dst_pos > 0 and not error_flag do
        if next_bit() == 0 then -- 0...
            if next_bit() == 0 then -- 0 0
                copy_raw(get_bits(3) + 1)
            else -- 0 1
                copy_ref(get_bits(8), 2)
            end
        else -- 1...
            local c = get_bits(2)
            if c == 3 then -- 1 1 1
                copy_raw(get_bits(8) + 9)
            elseif c < 2 then -- 1 0 x
                local count = c + 3
                local offset = get_bits(c + 9)
                copy_ref(offset, count)
            else -- 1 1 0
                local count = get_bits(8) + 1   -- count FIRST (per ScummVM)
                local offset = get_bits(12)      -- offset SECOND
                copy_ref(offset, count)
            end
        end
    end

    return output
end

-- ============================================================================
-- Bundle file parser (Big Endian)
-- u16be numEntries, u16be entrySize, then numEntries * 30 byte entries
-- Each entry: 14-byte name, u32be offset, u32be packedSize, u32be unpackedSize, u32be unused
-- ============================================================================

local function parse_bundle(data)
    if not data or #data < 4 then return nil end

    local num_entries = u16be(data, 1)
    local entry_size  = u16be(data, 3)  -- should be 30

    if num_entries == 0 or num_entries > 10000 then return nil end
    if entry_size ~= 30 then entry_size = 30 end  -- force

    local header_size = 4 + num_entries * 30
    if header_size > #data then return nil end

    local entries = {}
    for i = 0, num_entries - 1 do
        local base = 5 + i * 30  -- 1-based
        if base + 29 > #data then break end

        local name = ""
        for c = 0, 13 do
            local b = data:byte(base + c)
            if not b or b == 0 then break end
            name = name .. string.char(b)
        end

        local offset      = u32be(data, base + 14)
        local packed_size  = u32be(data, base + 18)
        local unpacked_size = u32be(data, base + 22)

        entries[#entries + 1] = {
            name          = name,
            offset        = offset,
            packed_size   = packed_size,
            unpacked_size = unpacked_size
        }
    end

    return entries
end

-- Extract and decompress a resource from bundle data
local function extract_from_bundle(bundle_data, entry)
    if entry.offset + entry.packed_size > #bundle_data then return nil end

    local packed = bundle_data:sub(entry.offset + 1, entry.offset + entry.packed_size)

    if entry.packed_size == entry.unpacked_size or entry.unpacked_size == 0 then
        -- Not compressed
        return packed
    end

    -- Decompress
    local result = cine_unpack(packed, entry.unpacked_size)
    if not result then return nil end

    -- Convert array to string
    local chars = {}
    for i = 1, #result do
        chars[i] = string.char(result[i])
    end
    return table.concat(chars)
end

-- ============================================================================
-- Bitplane decoder: Atari ST interleaved 4-plane -> 8bpp linear
-- 320x200, 16 colors
-- ============================================================================

local function decode_bitplanes(data, offset, w, h)
    local pixels = {}
    local n = 0
    local pos = offset
    local chunks_per_row = w / 16  -- 20 for 320 pixels

    for row = 1, h do
        for chunk = 1, chunks_per_row do
            -- Read 4 big-endian words (8 bytes)
            if pos + 7 > #data then
                -- Pad remaining pixels
                for _ = 1, 16 do n = n + 1; pixels[n] = 0 end
            else
                local w0 = u16be(data, pos + 0)
                local w1 = u16be(data, pos + 2)
                local w2 = u16be(data, pos + 4)
                local w3 = u16be(data, pos + 6)

                for bit = 0, 15 do
                    local mask = 2 ^ (15 - bit)
                    local color = 0
                    if w0 % (mask * 2) >= mask then color = color + 1 end
                    if w1 % (mask * 2) >= mask then color = color + 2 end
                    if w2 % (mask * 2) >= mask then color = color + 4 end
                    if w3 % (mask * 2) >= mask then color = color + 8 end
                    n = n + 1; pixels[n] = color
                end
            end
            pos = pos + 8
        end
    end

    return pixels
end

-- ============================================================================
-- Parse 16-color 9-bit palette (32 bytes, big-endian)
-- ============================================================================

local function parse_16color_palette(data, offset)
    local palette = {}
    -- Initialize as 256-entry for indexed image
    for i = 0, 255 do
        palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
    end

    for i = 0, 15 do
        local val = u16be(data, offset + i * 2)
        local r = math.floor(val / 256) % 8    -- bits [8..10]
        local g = math.floor(val / 16) % 8     -- bits [4..6]
        local b = val % 8                       -- bits [0..2]
        -- 3-bit to 8-bit: val * 255 / 7
        palette[i * 3 + 1] = math.floor(r * 255 / 7)
        palette[i * 3 + 2] = math.floor(g * 255 / 7)
        palette[i * 3 + 3] = math.floor(b * 255 / 7)
    end

    return palette
end

-- ============================================================================
-- Parse 256-color 24-bit palette (768 bytes, R,G,B sequential)
-- ============================================================================

local function parse_256color_palette(data, offset)
    local palette = {}
    for i = 0, 255 do
        -- VGA DAC palette is 6-bit (0-63), scale to 8-bit (0-255)
        palette[i * 3 + 1] = math.min(u8(data, offset + i * 3 + 0) * 4, 255)
        palette[i * 3 + 2] = math.min(u8(data, offset + i * 3 + 1) * 4, 255)
        palette[i * 3 + 3] = math.min(u8(data, offset + i * 3 + 2) * 4, 255)
    end
    return palette
end

-- ============================================================================
-- Detection
-- ============================================================================

local function is_future_wars(game_path)
    return file_exists(game_path .. "/part01") or file_exists(game_path .. "/PART01")
end

local function is_operation_stealth(game_path)
    return file_exists(game_path .. "/procs00") or file_exists(game_path .. "/PROCS00")
        or file_exists(game_path .. "/procs1")  or file_exists(game_path .. "/PROCS1")
        or file_exists(game_path .. "/procs0")  or file_exists(game_path .. "/PROCS0")
end

function engine.detect(game_path)
    return is_future_wars(game_path) or is_operation_stealth(game_path)
end

-- ============================================================================
-- Resource tree
-- ============================================================================

-- ============================================================================
-- Resource loading
-- ============================================================================

local function load_background(game_path, resource_id, palette_id)
    -- Parse: res_BUNDLENAME_FILENAME
    local bundle_name, file_name = resource_id:match("^res_([^_]+)_(.+)$")
    if not bundle_name or not file_name then return nil end

    -- Read bundle
    local f = file_open(game_path .. "/" .. bundle_name)
    if not f then return nil end
    local fsize = file_size(f)
    local bundle_data = file_read(f, 0, fsize)
    file_close(f)
    if not bundle_data then return nil end

    local entries = parse_bundle(bundle_data)
    if not entries then return nil end

    -- Find entry
    local target = nil
    for _, e in ipairs(entries) do
        if e.name == file_name then target = e; break end
    end
    if not target then return nil end

    -- Extract and decompress
    local data = extract_from_bundle(bundle_data, target)
    if not data or #data < 32 then return nil end

    local is_fw = is_future_wars(game_path)
    local pixels, palette, w, h

    -- PI1 (Atari ST low-res) format:
    --   +0: u16be resolution word (0=low, ignore)
    --   +2: 32 bytes palette (16 x u16be 9-bit color)
    --   +34: 32000 bytes interleaved bitplanes
    -- Total: 32034 bytes
    if is_fw then
        -- Future Wars: always 16-color PI1 format
        if #data < 32034 then
            -- Some bundles strip the 2-byte resolution word
            if #data >= 32032 then
                palette = parse_16color_palette(data, 1)
                pixels = decode_bitplanes(data, 33, 320, 200)
            else
                return { type = "text", text = string.format("Data too small: %d bytes (need 32034)", #data) }
            end
        else
            -- Standard PI1: skip 2-byte resolution word
            palette = parse_16color_palette(data, 3)
            pixels = decode_bitplanes(data, 35, 320, 200)
        end
        w, h = 320, 200
    else
        -- Operation Stealth: check discriminator
        local bpp = u16be(data, 1)
        if bpp == 8 then
            -- 256-color VGA: 2 bytes bpp + 768 bytes palette + 64000 bytes
            if #data < 64770 then
                return { type = "text", text = string.format("Data too small for 256-color: %d bytes", #data) }
            end
            palette = parse_256color_palette(data, 3)
            pixels = {}
            for i = 1, 64000 do
                pixels[i] = u8(data, 770 + i)
            end
        else
            -- 16-color: bpp word + 32-byte palette + bitplanes
            if #data >= 32034 then
                palette = parse_16color_palette(data, 3)
                pixels = decode_bitplanes(data, 35, 320, 200)
            elseif #data >= 32032 then
                -- No resolution word
                palette = parse_16color_palette(data, 1)
                pixels = decode_bitplanes(data, 33, 320, 200)
            else
                return { type = "text", text = string.format("Data too small for 16-color: %d bytes", #data) }
            end
        end
        w, h = 320, 200
    end

    if not pixels or not palette then return nil end

    local img = image_create_indexed(w, h, pixels, palette)
    local colors = is_fw and "16" or (u16be(data, 1) == 8 and "256" or "16")
    return {
        type = "image", image = img, palette = palette,
        description = string.format("%s - %s - %dx%d, %s colors",
            is_fw and "Future Wars" or "Operation Stealth",
            file_name, w, h, colors)
    }
end


-- Sprite records are indexed separately from full-screen artwork. Offsets below
-- are 1-based into the decompressed resource; archive offsets remain 0-based.
local function sprite_frames(data)
    local frames = {}
    local function add(p, bw, h, mode, stride, visible)
        local w = visible or (mode == 1 and bw * 8 or (mode == 4 or mode == 5) and bw * 2 or bw)
        assert(w > 0 and w <= 4096 and h > 0 and h <= 4096 and w*h <= 4194304, "Invalid sprite dimensions")
        local size = stride or bw * h + (mode == 5 and 16 or 0)
        assert(p >= 1 and p + size - 1 <= #data, "Truncated sprite pixels")
        frames[#frames + 1] = {pos=p, bw=bw, w=w, h=h, mode=mode, stride=stride}
    end
    if data:sub(1,3) == "SET" then
        assert(#data >= 6, "Truncated SET header")
        local count = u16be(data,5)
        assert(count <= 4096 and 6 + count*16 <= #data, "Invalid SET table")
        local start = 7 + count*16
        for i=0,count-1 do
            local p = 7 + i*16
            local off,bw,h,mode = u32be(data,p),u16be(data,p+4),u16be(data,p+6),u16be(data,p+8)
            assert(mode==1 or mode==4 or mode==5 or mode==8, "Unsupported SET encoding")
            if mode==4 then assert(bw%8==0,"Unaligned planar sprite") end
            if mode==8 then assert(bw*h%16==0,"Unaligned 8-bit sprite") end
            add(start+off,bw,h,mode)
        end
    else
        assert(#data>=22,"Truncated ANI header")
        local bw,h,count=u16be(data,5),u16be(data,7),u16be(data,15)
        assert(bw>0 and bw%8==0 and count>0 and count<=4096,"Invalid ANI header")
        assert(22+bw*h*count<=#data,"Truncated ANI frames")
        for i=0,count-1 do add(23+i*bw*h,bw,h,4) end
    end
    return frames
end

local function sprite_pixels(data, f)
    local px = {}
    local p,bw,w,h,mode = f.pos,f.bw,f.w,f.h,f.mode
    if mode == 4 then
        px = decode_bitplanes(data,p,w,h)
    elseif mode == 1 then
        for i=0,w*h-1 do
            px[i+1] = math.floor(data:byte(p+math.floor(i/8)) / 2^(7-i%8))%2
        end
    elseif mode == 5 then
        for i=0,bw*h-1 do
            local b=data:byte(p+16+i)
            px[i*2+1]=data:byte(p+math.floor(b/16))
            px[i*2+2]=data:byte(p+b%16)
        end
    else
        -- Cine 8-bit SET: blocks of eight 16-bit plane words, even then odd pixels.
        for block=0,w*h/16-1 do for half=0,1 do for bit=0,7 do
            local color=0
            for plane=0,7 do
                local b=data:byte(p+block*16+plane*2+half)
                color=color+math.floor(b/2^(7-bit))%2*2^plane
            end
            px[block*16+half*8+bit+1]=color
        end end end
    end
    return px
end

local catalog_path, catalog, records, palette_cache
local payload_key, payload_data
local function payload(path, r)
    local key = path .. "/" .. r.bundle .. ":" .. r.entry.name
    if payload_key == key then return payload_data end
    local f = assert(file_open(path .. "/" .. r.bundle), "Missing volume")
    local packed = file_read(f,r.entry.offset,r.entry.packed_size)
    file_close(f)
    assert(packed and #packed == r.entry.packed_size, "Truncated archive entry")
    local data = packed
    if r.entry.unpacked_size > 0 and r.entry.packed_size ~= r.entry.unpacked_size then
        assert(r.entry.unpacked_size <= 16777216, "Oversized resource")
        local bytes = cine_unpack(packed,r.entry.unpacked_size)
        local chars = {}; for i=1,#bytes do chars[i]=string.char(bytes[i]) end
        data = table.concat(chars)
    end
    payload_key,payload_data=key,data
    return data
end

local function index(path)
    if catalog_path == path then return end
    catalog_path=nil; catalog={}; records={}; palette_cache={}; payload_key=nil; payload_data=nil
    local names = {}
    for _,name in ipairs(list_files(path) or {}) do
        if name:lower():match("^part%d+%a*$") or name:lower():match("^rsc%d+$") then names[#names+1]=name end
    end
    table.sort(names,function(a,b) return a:lower()<b:lower() end)
    for _,name in ipairs(names) do
        local f=file_open(path.."/"..name)
        local entries
        if f then
            local size=file_size(f)
            entries=parse_bundle(file_read(f,0,math.min(size,300004)))
            file_close(f)
            if entries then
                for _,e in ipairs(entries) do
                    assert(e.offset >= 4+#entries*30 and e.offset+e.packed_size<=size, "Invalid archive range")
                end
            end
        end
        if entries then
            local bg={id="bg_"..name,name="Backgrounds",type="category",children={}}
            local sp={id="sprites_"..name,name="Sprites",type="category",children={}}
            local pal={id="palettes_"..name,name="Palettes (backgrounds)",type="category",children={}}
            local backgrounds={}
            for _,e in ipairs(entries) do
                if e.name:lower():match("%.pi1$") or e.name:lower():match("%.bg$") then
                    local id="res_"..name.."_"..e.name
                    local pid="pal_"..name.."_"..e.name
                    local r={bundle=name,entry=e,pal=pid}
                    records[id]=r; records[pid]={background=id}
                    backgrounds[#backgrounds+1]={name=e.name:upper(),id=pid}
                    bg.children[#bg.children+1]={id=id,name=e.name,type="image"}
                    pal.children[#pal.children+1]={id=pid,name=e.name,type="palette"}
                end
            end
            local previous=backgrounds[1] and backgrounds[1].id
            for _,e in ipairs(entries) do
                local bgid="pal_"..name.."_"..e.name
                if records[bgid] then previous=bgid end
                if e.name:lower():match("%.ani$") or e.name:lower():match("%.anm$") or e.name:lower():match("%.set$") then
                    local r={bundle=name,entry=e,pal=previous}
                    -- Prefer the background sharing the sprite's scene prefix.
                    local stem=e.name:upper():gsub("%.[^.]+$","")
                    local best=0
                    for _,b in ipairs(backgrounds) do
                        local base=b.name:gsub("%.[^.]+$","")
                        if stem:sub(1,#base)==base and #base>best then r.pal=b.id;best=#base end
                    end
                    local ok,frames=pcall(sprite_frames,payload(path,r))
                    if ok and #frames>0 then
                        local group={id="sprites_"..name.."_"..e.name,name=e.name,type="category",children={}}
                        for i,frame in ipairs(frames) do
                            local id="spr_"..name.."_"..e.name.."_"..i
                            records[id]={bundle=name,entry=e,frame=frame,pal=r.pal}
                            group.children[#group.children+1]={id=id,name=string.format("Frame %d (%dx%d)",i,frame.w,frame.h),type="image"}
                        end
                        sp.children[#sp.children+1]=group
                    elseif not ok then
                        log_warn(e.name..": "..tostring(frames))
                    end
                end
            end
            local cat={id="bundle_"..name,name=name,type="category",children={}}
            for _,c in ipairs({bg,sp,pal}) do if #c.children>0 then cat.children[#cat.children+1]=c end end
            if #cat.children>0 then catalog[#catalog+1]=cat end
        end
    end
    catalog_path=path
end

function engine.get_resources(path) index(path); return catalog end
function engine.default_palette(path,id) index(path); return records[id] and records[id].pal end

local function resource_palette(path,id)
    if palette_cache[id] then return palette_cache[id] end
    local r=records[id]
    if not r or not r.background then return nil end
    local data=payload(path,records[r.background])
    local pal
    if #data>=770 and u16be(data,1)==8 then pal=parse_256color_palette(data,3)
    elseif #data>=34 then pal=parse_16color_palette(data,3) end
    if pal then palette_cache[id]=pal;return pal end
end

function engine.load_resource(path,id,palette_id)
    index(path)
    local r=records[id]
    if not r then return nil end
    if id:sub(1,4)=="res_" then return load_background(path,id,palette_id) end
    local pal=resource_palette(path,palette_id or (r.background and id or r.pal))
    local fallback=not pal
    if not pal then
        pal={};for i=0,255 do pal[i*3+1]=i;pal[i*3+2]=i;pal[i*3+3]=i end
    end
    if r.background then
        local px={};for i=0,65535 do px[i+1]=math.floor(i/4096)*16+math.floor(i%256/16) end
        return {type="image",image=image_create_indexed(256,256,px,pal),palette=pal}
    end
    local px=sprite_pixels(payload(path,r),r.frame)
    return {type="image",image=image_create_indexed(r.frame.w,r.frame.h,px,pal),palette=pal,
        description=string.format("%s - %dx%d; %s. Palette can be changed; script-driven palette changes are not replayed.",
            r.entry.name,r.frame.w,r.frame.h,fallback and "grayscale fallback" or "background palette")}
end

return engine

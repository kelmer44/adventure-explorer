-- ============================================================================
-- Adventure Explorer - Engine Script: Cruise for a Corpse
-- ============================================================================
-- Delphine Software Cinematique evo 2. 320x200.
-- VOL.CNF master index + D1,D2... volume files.
-- Backgrounds: 16-color (mode 0/4 bitplanes), 32-color (mode 5), or 256-color (mode 8).
-- ============================================================================

local engine = {}
engine.name        = "Cruise for a Corpse"
engine.id          = "cruise"
engine.description = "Cruise for a Corpse (1991, Delphine Software)"
engine.version     = "3.1"

-- Binary helpers
local function u8(data, pos)   return data:byte(pos) end
local function u16be(data, pos)
    return data:byte(pos) * 256 + data:byte(pos + 1)
end
local function u32be(data, pos)
    return data:byte(pos) * 16777216 + data:byte(pos + 1) * 65536
         + data:byte(pos + 2) * 256 + data:byte(pos + 3)
end

-- ============================================================================
-- Delphine backward LZ77 unpacker (same algorithm as cine engine)
-- Reads bits LSB-first via rotate-carry-right (rcr) mechanism.
-- Verified against ScummVM engines/cruise/delphine-unpack.cpp
-- ============================================================================

local function delphine_unpack(src_data, unpacked_size)
    local src_len = #src_data
    if src_len < 12 then
        local out = {}
        for i = 1, math.min(src_len, unpacked_size) do
            out[i] = src_data:byte(i)
        end
        for i = #out + 1, unpacked_size do out[i] = 0 end
        return out
    end

    -- Read 12-byte trailer: three BE uint32 words at end
    local read_pos = src_len - 3
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

    local function read_source()
        if read_pos < 1 then error_flag = true; return 0 end
        local val = u32be(src_data, read_pos)
        read_pos = read_pos - 4
        return val
    end

    -- Rotate carry right: extract LSB, shift right, optionally set MSB
    local function rcr(input_carry)
        local output_carry = chunk % 2
        chunk = math.floor(chunk / 2)
        if input_carry then chunk = chunk + 2147483648 end
        return output_carry
    end

    local function next_bit()
        local carry = rcr(false)
        if chunk == 0 then
            chunk = read_source()
            carry = rcr(true)
        end
        return carry
    end

    local function get_bits(n)
        local val = 0
        for _ = 1, n do val = val * 2 + next_bit() end
        return val
    end

    local function copy_raw(count)
        for _ = 1, count do
            if dst_pos < 1 then return end
            output[dst_pos] = get_bits(8)
            dst_pos = dst_pos - 1
        end
    end

    local function copy_ref(offset, count)
        for _ = 1, count do
            if dst_pos < 1 then return end
            local si = dst_pos + offset
            output[dst_pos] = (si >= 1 and si <= unpacked_size) and output[si] or 0
            dst_pos = dst_pos - 1
        end
    end

    while dst_pos > 0 and not error_flag do
        if next_bit() == 0 then
            if next_bit() == 0 then copy_raw(get_bits(3) + 1)
            else copy_ref(get_bits(8), 2) end
        else
            local c = get_bits(2)
            if c == 3 then copy_raw(get_bits(8) + 9)
            elseif c < 2 then
                copy_ref(get_bits(c + 9), c + 3)
            else
                local count = get_bits(8) + 1
                local offset = get_bits(12)
                copy_ref(offset, count)
            end
        end
    end

    return output
end

-- ============================================================================
-- Volume file parser (same format as cine bundles)
-- u16be numEntries, u16be entrySize(30), then 30-byte entries
-- ============================================================================

local function parse_volume(data)
    if not data or #data < 4 then return nil end

    local num = u16be(data, 1)
    if num == 0 or num > 10000 then return nil end

    local entries = {}
    for i = 0, num - 1 do
        local base = 5 + i * 30
        if base + 29 > #data then break end

        local name = ""
        for c = 0, 13 do
            local b = data:byte(base + c)
            if not b or b == 0 then break end
            name = name .. string.char(b)
        end

        entries[#entries + 1] = {
            name = name,
            offset = u32be(data, base + 14),
            packed_size = u32be(data, base + 18),
            unpacked_size = u32be(data, base + 22)
        }
    end

    return entries
end

-- ============================================================================
-- Bitplane decoders
-- ============================================================================

-- Mode 0/4: 4-plane interleaved, Atari ST style -> 16 colors
local function decode_mode4(data, offset, w, h)
    local pixels = {}; local n = 0
    local pos = offset
    local chunks = w / 16

    for _ = 1, h do
        for _ = 1, chunks do
            if pos + 7 > #data then
                for _ = 1, 16 do n = n + 1; pixels[n] = 0 end
            else
                local w0 = u16be(data, pos + 0)
                local w1 = u16be(data, pos + 2)
                local w2 = u16be(data, pos + 4)
                local w3 = u16be(data, pos + 6)
                for bit = 0, 15 do
                    local mask = 2 ^ (15 - bit)
                    local c = 0
                    if w0 % (mask * 2) >= mask then c = c + 1 end
                    if w1 % (mask * 2) >= mask then c = c + 2 end
                    if w2 % (mask * 2) >= mask then c = c + 4 end
                    if w3 % (mask * 2) >= mask then c = c + 8 end
                    n = n + 1; pixels[n] = c
                end
            end
            pos = pos + 8
        end
    end
    return pixels
end

-- Mode 5: 5-plane sequential, Amiga style -> 32 colors
local function decode_mode5(data, offset, w, h)
    local pixels = {}
    local bytes_per_row = w / 8  -- 40
    local plane_size = bytes_per_row * h  -- 8000

    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local col = math.floor(x / 8)
            local bit = 7 - (x % 8)
            local byte_off = y * bytes_per_row + col
            local c = 0
            for plane = 0, 4 do
                local p = offset + plane * plane_size + byte_off
                if p <= #data then
                    local b = u8(data, p)
                    if b % (2^(bit + 1)) >= 2^bit then
                        c = c + 2^plane
                    end
                end
            end
            pixels[y * w + x + 1] = c
        end
    end
    return pixels
end

-- ============================================================================
-- Palette decoders
-- ============================================================================

local function atari_st_palette(data, offset, num_colors)
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
    end
    for i = 0, num_colors - 1 do
        local val = u16be(data, offset + i * 2)
        local r = math.floor(val / 256) % 8
        local g = math.floor(val / 16) % 8
        local b = val % 8
        palette[i * 3 + 1] = math.floor(r * 255 / 7)
        palette[i * 3 + 2] = math.floor(g * 255 / 7)
        palette[i * 3 + 3] = math.floor(b * 255 / 7)
    end
    return palette
end

local function amiga_palette(data, offset, num_colors)
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = 0; palette[i * 3 + 2] = 0; palette[i * 3 + 3] = 0
    end
    for i = 0, num_colors - 1 do
        local b0 = u8(data, offset + i * 2 + 0)  -- 0x0R
        local b1 = u8(data, offset + i * 2 + 1)  -- 0xGB
        local r = b0 % 16
        local g = math.floor(b1 / 16)
        local b = b1 % 16
        palette[i * 3 + 1] = r * 17
        palette[i * 3 + 2] = g * 17
        palette[i * 3 + 3] = b * 17
    end
    return palette
end

local function rgb_palette(data, offset)
    local palette = {}
    for i = 0, 255 do
        -- Cruise stores full 8-bit RGB, passed directly to setPalEntries.
        palette[i * 3 + 1] = u8(data, offset + i * 3 + 0)
        palette[i * 3 + 2] = u8(data, offset + i * 3 + 1)
        palette[i * 3 + 3] = u8(data, offset + i * 3 + 2)
    end
    return palette
end

-- ============================================================================
-- Detection
-- ============================================================================

function engine.detect(game_path)
    local has_d1 = file_exists(game_path .. "/D1") or file_exists(game_path .. "/d1")
    local has_vol = file_exists(game_path .. "/VOL.CNF") or file_exists(game_path .. "/vol.cnf")
    return has_d1 and has_vol
end

-- ============================================================================
-- Resource tree: scan volume files for background resources
-- ============================================================================

-- ============================================================================
-- Resource loading
-- ============================================================================

local function load_background(game_path, resource_id, palette_id)
    local vol_name, file_name = resource_id:match("^res_([^_]+)_(.+)$")
    if not vol_name or not file_name then return nil end

    local f = file_open(game_path .. "/" .. vol_name)
    if not f then return nil end
    local fsize = file_size(f)
    local vol_data = file_read(f, 0, fsize)
    file_close(f)
    if not vol_data then return nil end

    local entries = parse_volume(vol_data)
    if not entries then return nil end

    local target = nil
    for _, e in ipairs(entries) do
        if e.name == file_name then target = e; break end
    end
    if not target then return nil end

    -- Extract raw data
    if target.offset + target.packed_size > #vol_data then return nil end
    local packed = vol_data:sub(target.offset + 1, target.offset + target.packed_size)

    local data
    if target.packed_size == target.unpacked_size or target.unpacked_size == 0 then
        data = packed
    else
        local result = delphine_unpack(packed, target.unpacked_size)
        if not result then return nil end
        local chars = {}
        for i = 1, #result do chars[i] = string.char(result[i]) end
        data = table.concat(chars)
    end

    if not data or #data < 10 then return nil end

    -- Parse background
    local w, h = 320, 200
    local pixels, palette

    -- Check for "PAL" header (256-color raw)
    if data:sub(1, 3) == "PAL" then
        if #data >= 4 + 768 + 64000 then
            palette = rgb_palette(data, 5)
            pixels = {}
            for i = 1, 64000 do pixels[i] = u8(data, 772 + i) end
        end
    else
        -- Binary header: byte 0 = resolution, byte 1 = mode
        local mode = u8(data, 2)

        if mode == 8 then
            -- 256-color: 2 bytes header + 768 palette + 64000 pixels
            if #data >= 770 then
                palette = rgb_palette(data, 3)
                pixels = {}
                local start = 771
                for i = 1, math.min(64000, #data - start + 1) do
                    pixels[i] = u8(data, start + i - 1)
                end
                while #pixels < 64000 do pixels[#pixels + 1] = 0 end
            end
        elseif mode == 5 then
            -- 32-color Amiga: 2 bytes header + 64 bytes palette + 40000 bytes (5 planes)
            if #data >= 66 + 40000 then
                palette = amiga_palette(data, 3, 32)
                pixels = decode_mode5(data, 67, 320, 200)
            end
        else
            -- Mode 0/4: 2 bytes header + 32 palette bytes + 32000 pixel bytes
            if #data >= 34 + 32000 then
                palette = atari_st_palette(data, 3, 16)
                pixels = decode_mode4(data, 35, 320, 200)
            end
        end
    end

    if not pixels or not palette then
        return { type = "text", text = string.format("%s: unable to decode (%d bytes, mode byte=%d)",
            file_name, #data, u8(data, 2)) }
    end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image", image = img, palette = palette,
        description = string.format("Cruise for a Corpse - %s - %dx%d", file_name, w, h)
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
    if data:sub(1,3) == "SET" or data:sub(1,3) == "SEC" then
        assert(#data >= 6, "Truncated SET header")
        local count = u16be(data,5)
        assert(count <= 4096 and 6 + count*16 <= #data, "Invalid SET table")
        local start = 7 + count*16
        for i=0,count-1 do
            local p = 7 + i*16
            local off,bw,h,mode = u32be(data,p),u16be(data,p+4),u16be(data,p+6),u16be(data,p+8)
            -- Polygon records (type 0) are not bitmap sprites.
            if mode==1 or mode==4 or mode==5 or mode==8 then
                local sec=data:sub(1,3)=="SEC"
                if sec then bw=bw-mode*2 end
                local stored=bw*h
                local visible
                if mode==5 then
                    visible=math.floor((bw-(sec and 0 or 10))*8/5)
                    assert(bw%5==0,"Invalid five-plane stride")
                elseif mode==4 then assert(bw%8==0,"Unaligned planar sprite") end
                add(start+off,bw,h,mode,stored,visible)
            end
        end
    else
        error("Missing SET/SEC signature")
    end
    return frames
end

-- Keep the original SET indices: mirrored poses reference relative record slots.
local function polygon_frames(data)
    assert(#data>=6 and (data:sub(1,3)=="SET" or data:sub(1,3)=="SEC"),"Missing SET/SEC signature")
    local count=u16be(data,5)
    assert(count<=4096 and 6+count*16<=#data,"Invalid SET table")
    local frames={}
    for i=0,count-1 do
        local p=7+i*16
        if u16be(data,p+8)==0 then
            local pos=7+count*16+u32be(data,p)
            local size=u16be(data,p+4)*u16be(data,p+6)
            assert(size>=2 and pos+size-1<=#data,"Truncated polygon frame")
            frames[#frames+1]={index=i,mirror=u16be(data,pos)==0}
        end
    end
    return frames
end

local function sprite_pixels(data, f)
    local px = {}
    local p,bw,w,h,mode = f.pos,f.bw,f.w,f.h,f.mode
    if mode == 4 then
        px = decode_mode4(data,p,w,h)
    elseif mode == 1 then
        for i=0,w*h-1 do
            px[i+1] = math.floor(data:byte(p+math.floor(i/8)) / 2^(7-i%8))%2
        end
    elseif mode == 5 then
        local stride=bw/5
        local plane_size=stride*h
        for y=0,h-1 do for x=0,w-1 do
            local color=0
            for plane=0,4 do
                local b=data:byte(p+plane*plane_size+y*stride+math.floor(x/8))
                color=color+math.floor(b/2^(7-x%8))%2*2^plane
            end
            px[y*w+x+1]=color
        end end
    else
        for i=1,w*h do px[i]=data:byte(p+i-1) end
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
        local bytes = delphine_unpack(packed,r.entry.unpacked_size)
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
        if name:lower():match("^d%d+$") then names[#names+1]=name end
    end
    table.sort(names,function(a,b) return a:lower()<b:lower() end)
    for _,name in ipairs(names) do
        local f=file_open(path.."/"..name)
        local entries
        if f then
            local size=file_size(f)
            entries=parse_volume(file_read(f,0,math.min(size,300004)))
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
            local models={id="actors_"..name,name="Polygon Actors and Vector Art",type="category",children={}}
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
                if e.name:lower():match("%.set$") then
                    local r={bundle=name,entry=e,pal=previous}
                    -- Prefer the background sharing the sprite's scene prefix.
                    local stem=e.name:upper():gsub("%.[^.]+$","")
                    local best=0
                    for _,b in ipairs(backgrounds) do
                        local base=b.name:gsub("%.[^.]+$","")
                        if stem:sub(1,#base)==base and #base>best then r.pal=b.id;best=#base end
                    end
                    local data=payload(path,r)
                    local ok,frames=pcall(sprite_frames,data)
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
                    local polyok,polygons=pcall(polygon_frames,data)
                    if polyok and #polygons>0 then
                        local group={id="actors_"..name.."_"..e.name,name=e.name,type="category",children={}}
                        for _,frame in ipairs(polygons) do
                            local id="poly_"..name.."_"..e.name.."_"..frame.index
                            records[id]={bundle=name,entry=e,polygon=frame.index,pal=r.pal}
                            group.children[#group.children+1]={id=id,type="model",
                                name=string.format("Pose %d%s",frame.index+1,frame.mirror and " (mirrored)" or "")}
                        end
                        models.children[#models.children+1]=group
                    elseif not polyok then log_warn(e.name..": "..tostring(polygons)) end
                end
            end
            local cat={id="bundle_"..name,name=name,type="category",children={}}
            for _,c in ipairs({bg,sp,models,pal}) do if #c.children>0 then cat.children[#cat.children+1]=c end end
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
    if data:sub(1,3)=="PAL" and #data>=772 then pal=rgb_palette(data,5)
    elseif #data>=2 then
        local mode=data:byte(2)
        if mode==8 and #data>=770 then pal=rgb_palette(data,3)
        elseif mode==5 and #data>=66 then pal=amiga_palette(data,3,32)
        elseif (mode==0 or mode==4) and #data>=34 then pal=atari_st_palette(data,3,16) end
    end
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
    if r.polygon~=nil then
        return {type="model",model=model_decode_cruise(payload(path,r),r.polygon,pal),palette=pal,
            description=string.format("%s - pose %d; flat polygon artwork at scale 512 with %s. Mirrored references resolved; script animation is not replayed.",
                r.entry.name,r.polygon+1,fallback and "grayscale fallback" or "background palette")}
    end
    local px=sprite_pixels(payload(path,r),r.frame)
    return {type="image",image=image_create_indexed(r.frame.w,r.frame.h,px,pal),palette=pal,
        description=string.format("%s - %dx%d; %s. Palette can be changed; script-driven palette changes are not replayed.",
            r.entry.name,r.frame.w,r.frame.h,fallback and "grayscale fallback" or "background palette")}
end

return engine

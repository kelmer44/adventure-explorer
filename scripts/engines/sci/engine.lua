-- ============================================================================
-- Adventure Explorer - Engine Script: Sierra SCI
-- ============================================================================
-- Sierra On-Line, 1988-1996. DOS. SCI resource system.
--
-- Supports SCI0 resource format (used by early Sierra games):
--   King's Quest 4, Space Quest 3, Leisure Suit Larry 2/3, Police Quest 2, etc.
--
-- Resource system:
--   RESOURCE.MAP : 6-byte entries  (u16le type_id, u32le vol_offset)
--     type_id = (type << 11) | number;  type 0-10, number 0-2047
--     vol_offset = (volume << 26) | (byte_offset & 0x03FFFFFF)
--     Terminated by type_id == 0xFFFF
--
--   RESOURCE.xxx : volume files (xxx = volume number, e.g., 000, 001)
--     At each offset: 8-byte header + compressed data
--       u16le type_id, u16le comp_size, u16le decomp_size, u16le comp_method
--       comp_method: 0=none, 1=LZW_SCI0 (LSB), 2=Huffman, 3=LZW_SCI1, 4=DCL
--
-- View format (SCI0 EGA):
--   Byte 2: loop_count
--   Byte 4+: u16le loop_offsets[loop_count] (relative to view start)
--   At loop_offset: u8 cel_count, 3 pad bytes, u16le cel_offsets[cel_count]
--   At cel_offset: u16le width, u16le height, u8 dispX, u8 dispY, u8 clearKey
--   Pixel data (RLE): byte>=0x80 = skip (byte&0x7F) pixels; byte<0x80 = pixel
-- ============================================================================

local engine = {}
engine.name        = "Sierra SCI"
engine.id          = "sci"
engine.description = "Sierra SCI games (1988-1996)"
engine.version     = "1.0"

-- ============================================================================
-- Binary helpers
-- ============================================================================

local function u8(data, pos)  return data:byte(pos) end
local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end
local function u32le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536 + data:byte(pos + 3) * 16777216
end

local POW2 = {}
for i = 0, 24 do POW2[i] = 2 ^ i end

-- ============================================================================
-- Standard EGA 16-color palette
-- ============================================================================

local function ega_palette()
    local c = {
        {0,0,0},{0,0,170},{0,170,0},{0,170,170},
        {170,0,0},{170,0,170},{170,85,0},{170,170,170},
        {85,85,85},{85,85,255},{85,255,85},{85,255,255},
        {255,85,85},{255,85,255},{255,255,85},{255,255,255},
    }
    local pal = {}
    for i = 0, 15 do
        pal[i*3+1] = c[i+1][1]; pal[i*3+2] = c[i+1][2]; pal[i*3+3] = c[i+1][3]
    end
    for i = 16, 255 do pal[i*3+1]=0; pal[i*3+2]=0; pal[i*3+3]=0 end
    return pal
end

-- ============================================================================
-- LZW decompressor (SCI0 variant, LSB-first)
-- ============================================================================

local function lzw_sci0(data, expected_size)
    local spos = 1
    local bbuf = 0
    local bcount = 0

    local function read_code(w)
        while bcount < w do
            if spos > #data then return nil end
            bbuf = bbuf + data:byte(spos) * POW2[bcount]
            bcount = bcount + 8
            spos = spos + 1
        end
        local code = bbuf % POW2[w]
        bbuf = math.floor(bbuf / POW2[w])
        bcount = bcount - w
        return code
    end

    -- Dictionary: linked list (parent, char, first_byte, length)
    local dp, dc, df, dl = {}, {}, {}, {}
    for i = 0, 255 do dp[i]=-1; dc[i]=i; df[i]=i; dl[i]=1 end

    local function init()
        for k = 258, 4095 do dp[k]=nil; dc[k]=nil; df[k]=nil; dl[k]=nil end
        return 258, 9, 512
    end

    local next_code, cw, max_code = init()

    local function decode(code)
        local len = dl[code]
        if not len then return nil end
        local bytes = {}
        local c = code
        for i = len, 1, -1 do bytes[i] = dc[c]; c = dp[c] end
        return bytes
    end

    local out = {}
    local out_n = 0
    local prev = nil

    while true do
        local code = read_code(cw)
        if not code or code == 257 then break end

        if code == 256 then
            next_code, cw, max_code = init()
            prev = nil
        else
            local bytes
            if dl[code] then
                bytes = decode(code)
            elseif code == next_code and prev then
                bytes = decode(prev)
                if bytes then bytes[#bytes + 1] = df[prev] end
            else
                break
            end
            if not bytes then break end

            for i = 1, #bytes do
                out_n = out_n + 1
                out[out_n] = bytes[i]
            end

            if prev then
                dp[next_code] = prev
                dc[next_code] = bytes[1]
                df[next_code] = df[prev]
                dl[next_code] = dl[prev] + 1
                next_code = next_code + 1
                if next_code >= max_code and cw < 12 then
                    cw = cw + 1
                    max_code = max_code * 2
                end
            end
            prev = code
        end

        if expected_size > 0 and out_n >= expected_size then break end
    end

    local t = {}
    local limit = (expected_size > 0) and math.min(out_n, expected_size) or out_n
    for i = 1, limit do t[i] = string.char(out[i]) end
    return table.concat(t)
end

-- ============================================================================
-- SCI0 Resource Map Parser
-- ============================================================================

local RES_NAMES = {
    [0] = "Views", [1] = "Pics", [2] = "Scripts", [3] = "Texts",
    [4] = "Sounds", [5] = "Memory", [6] = "Vocab", [7] = "Fonts",
    [8] = "Cursors", [9] = "Patches", [10] = "Bitmaps",
    [11] = "Palettes", [15] = "Messages", [17] = "Heaps",
}

-- ============================================================================
-- Map parsers: SCI0, SCI1, SCI1.1
-- ============================================================================

-- Detect SCI version from the map data
local function detect_sci_version(data)
    local first = data:byte(1)
    if first >= 0x80 then
        -- SCI1/SCI1.1 directory format; detect sub-version from entry size
        local pos = 1
        local offsets = {}
        while pos + 2 <= #data do
            local t = data:byte(pos)
            if t >= 0xFF then break end
            local off = u16le(data, pos + 1)
            table.insert(offsets, off)
            pos = pos + 3
        end
        if #offsets >= 2 then
            local span = offsets[2] - offsets[1]
            if span > 0 and span % 5 == 0 and span % 6 ~= 0 then
                return "sci11"
            end
        end
        return "sci1"
    end
    return "sci0"
end

local function parse_map_sci0(data)
    local resources = {}
    local pos = 1
    while pos + 5 <= #data do
        local type_id = u16le(data, pos)
        if type_id == 0xFFFF then break end
        local rtype = math.floor(type_id / 2048)
        local rnum = type_id % 2048
        local off_data = u32le(data, pos + 2)
        local vol = math.floor(off_data / POW2[26])
        local offset = off_data % POW2[26]
        table.insert(resources, {
            type = rtype, number = rnum,
            volume = vol, offset = offset,
        })
        pos = pos + 6
    end
    return resources
end

local function parse_map_sci1(data)
    -- Directory: 3-byte entries (u8 type, u16le offset), terminated by 0xFF
    local dir = {}
    local pos = 1
    while pos + 2 <= #data do
        local t = data:byte(pos)
        if t >= 0xFF then break end
        local off = u16le(data, pos + 1)
        table.insert(dir, { type = t - 0x80, offset = off })
        pos = pos + 3
    end

    local resources = {}
    for di = 1, #dir do
        local rtype = dir[di].type
        local start = dir[di].offset + 1  -- 1-indexed
        local stop = (di < #dir) and dir[di + 1].offset or (#data - 5)
        local p = start
        while p + 5 <= #data do
            if p > stop then break end
            local rnum = u16le(data, p)
            if rnum == 0xFFFF then break end
            local off_data = u32le(data, p + 2)
            local vol = math.floor(off_data / POW2[26])
            local offset = off_data % POW2[26]
            table.insert(resources, {
                type = rtype, number = rnum,
                volume = vol, offset = offset,
            })
            p = p + 6
        end
    end
    return resources
end

local function parse_map_sci11(data)
    -- Directory: 3-byte entries, same as SCI1
    local dir = {}
    local pos = 1
    while pos + 2 <= #data do
        local t = data:byte(pos)
        if t >= 0xFF then break end
        local off = u16le(data, pos + 1)
        table.insert(dir, { type = t - 0x80, offset = off })
        pos = pos + 3
    end

    local resources = {}
    for di = 1, #dir do
        local rtype = dir[di].type
        local start = dir[di].offset + 1  -- 1-indexed
        local stop = (di < #dir) and dir[di + 1].offset or (#data - 4)
        local p = start
        while p + 4 <= #data do
            if p > stop then break end
            local rnum = u16le(data, p)
            if rnum == 0xFFFF then break end
            -- 3-byte offset: actual_offset = raw * 2
            local raw_off = data:byte(p + 2)
                          + data:byte(p + 3) * 256
                          + data:byte(p + 4) * 65536
            local offset = raw_off * 2
            table.insert(resources, {
                type = rtype, number = rnum,
                volume = 0, offset = offset,
            })
            p = p + 5
        end
    end
    return resources
end

local function parse_map(game_path)
    local fh = file_open(game_path .. "/RESOURCE.MAP")
    if not fh then return nil, nil end
    local sz = file_size(fh)
    local data = file_read(fh, 0, sz)
    file_close(fh)
    if not data or #data < 6 then return nil, nil end

    local ver = detect_sci_version(data)
    local resources
    if ver == "sci11" then
        resources = parse_map_sci11(data)
    elseif ver == "sci1" then
        resources = parse_map_sci1(data)
    else
        resources = parse_map_sci0(data)
    end
    return resources, ver
end

-- ============================================================================
-- Resource Volume Readers
-- ============================================================================

local function read_resource_sci0(game_path, vol, offset)
    local vol_name = string.format("RESOURCE.%03d", vol)
    local fh = file_open(game_path .. "/" .. vol_name)
    if not fh then return nil end

    local hdr = file_read(fh, offset, 8)
    if not hdr or #hdr < 8 then file_close(fh); return nil end

    local comp_size = u16le(hdr, 3)
    local decomp_size = u16le(hdr, 5)
    local comp_method = u16le(hdr, 7)

    local raw = file_read(fh, offset + 8, comp_size)
    file_close(fh)
    if not raw then return nil end

    if comp_method == 0 then
        return raw
    elseif comp_method == 1 then
        return lzw_sci0(raw, decomp_size)
    else
        log_warn("SCI: unsupported compression method " .. comp_method)
        return nil
    end
end

local function read_resource_sci1(game_path, vol, offset)
    local vol_name = string.format("RESOURCE.%03d", vol)
    local fh = file_open(game_path .. "/" .. vol_name)
    if not fh then return nil end

    local hdr = file_read(fh, offset, 9)
    if not hdr or #hdr < 9 then file_close(fh); return nil end

    -- SCI1: u8 type, u16le number, u16le packedSz, u16le unpackedSz, u16le method
    -- packedSz includes the 4 sub-header bytes (unpackedSz + method)
    local packed_sz = u16le(hdr, 4)
    local unpack_sz = u16le(hdr, 6)
    local comp_method = u16le(hdr, 8)
    local data_sz = packed_sz - 4
    if data_sz < 0 then data_sz = 0 end

    local raw = file_read(fh, offset + 9, data_sz)
    file_close(fh)
    if not raw then return nil end

    if comp_method == 0 then
        return raw
    elseif comp_method == 1 then
        return lzw_sci0(raw, unpack_sz)
    else
        log_warn("SCI: unsupported compression method " .. comp_method)
        return nil
    end
end

local function read_resource_sci11(game_path, vol, offset)
    local vol_name = string.format("RESOURCE.%03d", vol)
    local fh = file_open(game_path .. "/" .. vol_name)
    if not fh then return nil end

    local hdr = file_read(fh, offset, 9)
    if not hdr or #hdr < 9 then file_close(fh); return nil end

    -- SCI1.1: packedSz is raw data size (no sub-header included)
    local packed_sz = u16le(hdr, 4)
    local unpack_sz = u16le(hdr, 6)
    local comp_method = u16le(hdr, 8)

    local raw = file_read(fh, offset + 9, packed_sz)
    file_close(fh)
    if not raw then return nil end

    if comp_method == 0 then
        return raw
    elseif comp_method == 1 then
        return lzw_sci0(raw, unpack_sz)
    else
        log_warn("SCI: unsupported compression method " .. comp_method)
        return nil
    end
end

local function read_resource(game_path, vol, offset, ver)
    if ver == "sci11" then
        return read_resource_sci11(game_path, vol, offset)
    elseif ver == "sci1" then
        return read_resource_sci1(game_path, vol, offset)
    else
        return read_resource_sci0(game_path, vol, offset)
    end
end

-- ============================================================================
-- SCI0 View Parser and Cel Renderer
-- ============================================================================

local function parse_view_loops(data)
    if #data < 5 then return nil end
    local loop_count = u8(data, 3) -- byte 2 (0-based)
    if loop_count < 1 or loop_count > 128 then return nil end

    local loops = {}
    for lno = 0, loop_count - 1 do
        local loff_pos = 5 + lno * 2 -- byte 4+lno*2 (0-based) -> 1-based
        if loff_pos + 1 > #data then break end
        local loop_off = u16le(data, loff_pos) -- 0-based offset

        if loop_off + 1 > #data then break end
        local cel_count = u8(data, loop_off + 1) -- byte loop_off (0-based)
        if cel_count < 1 or cel_count > 200 then
            table.insert(loops, {})
            goto next_loop
        end

        local cels = {}
        for cno = 0, cel_count - 1 do
            local coff_pos = loop_off + 5 + cno * 2 -- loopData+4+cno*2 (0-based) -> +1
            if coff_pos + 1 > #data then break end
            local cel_off = u16le(data, coff_pos) -- 0-based offset

            if cel_off + 7 > #data then break end
            local w = u16le(data, cel_off + 1)
            local h = u16le(data, cel_off + 3)
            local clear_key = u8(data, cel_off + 7)

            if w < 1 or w > 1024 or h < 1 or h > 1024 then break end
            table.insert(cels, {
                width = w, height = h,
                clear_key = clear_key,
                data_pos = cel_off + 8, -- pixel data at 1-based position
            })
        end
        table.insert(loops, cels)
        ::next_loop::
    end
    return loops
end

local function render_cel(data, cel, pal)
    local w, h, ck = cel.width, cel.height, cel.clear_key
    local pix = {}
    for i = 1, w * h do pix[i] = ck end

    local pos = cel.data_pos
    for y = 0, h - 1 do
        local x = 0
        while x < w and pos <= #data do
            local b = u8(data, pos)
            pos = pos + 1
            if b >= 128 then
                x = x + (b - 128) -- skip transparent
            else
                pix[y * w + x + 1] = b
                x = x + 1
            end
        end
    end

    return image_create_indexed(w, h, pix, pal)
end

-- ============================================================================
-- Public engine API
-- ============================================================================

function engine.detect(game_path)
    if not file_exists(game_path .. "/RESOURCE.MAP") then return false end
    for i = 0, 9 do
        if file_exists(game_path .. string.format("/RESOURCE.%03d", i)) then
            return true
        end
    end
    return false
end

function engine.get_resources(game_path)
    local resources, ver = parse_map(game_path)
    if not resources then return {} end

    -- Group by type
    local by_type = {}
    for _, r in ipairs(resources) do
        if not by_type[r.type] then by_type[r.type] = {} end
        table.insert(by_type[r.type], r)
    end

    local tree = {}
    -- Sorted type order: views first, then pics, then others
    local type_order = {0, 1, 7, 8, 2, 3, 4, 6, 9}
    for _, t in ipairs(type_order) do
        local items = by_type[t]
        if items then
            local type_name = RES_NAMES[t] or ("Type " .. t)
            local kids = {}
            for _, r in ipairs(items) do
                local res_type = (t == 0 or t == 1 or t == 7 or t == 8) and "image" or "text"
                table.insert(kids, {
                    id = string.format("r_%d_%d", t, r.number),
                    name = string.format("%s %d", type_name:sub(1, -2), r.number),
                    type = res_type,
                })
            end
            table.sort(kids, function(a, b) return a.name < b.name end)
            table.insert(tree, {
                id = "type_" .. t,
                name = type_name .. " (" .. #items .. ")",
                type = "category",
                children = kids,
            })
        end
    end

    return tree
end

function engine.load_resource(game_path, resource_id)
    local rtype_s, rnum_s = resource_id:match("^r_(%d+)_(%d+)$")
    if not rtype_s then
        return { type = "text", text = "Unknown resource: " .. resource_id }
    end

    local rtype = tonumber(rtype_s)
    local rnum = tonumber(rnum_s)

    -- Find the resource in the map
    local resources, ver = parse_map(game_path)
    if not resources then
        return { type = "text", text = "Failed to parse RESOURCE.MAP" }
    end

    local res
    for _, r in ipairs(resources) do
        if r.type == rtype and r.number == rnum then res = r; break end
    end
    if not res then
        return { type = "text", text = "Resource not found in map" }
    end

    local data = read_resource(game_path, res.volume, res.offset, ver)
    if not data then
        return { type = "text", text = string.format("Failed to load %s %d (vol=%d, comp?)",
            RES_NAMES[rtype] or "resource", rnum, res.volume) }
    end

    local pal = ega_palette()

    -- VIEW resource (type 0)
    if rtype == 0 then
        local loops = parse_view_loops(data)
        if not loops or #loops == 0 then
            return { type = "text", text = string.format("View %d: %d bytes (parse failed)", rnum, #data) }
        end

        -- Collect all renderable cels
        local frames = {}
        for lno, cels in ipairs(loops) do
            for cno, cel in ipairs(cels) do
                local img = render_cel(data, cel, pal)
                if img then table.insert(frames, { img = img, loop = lno - 1, cel = cno - 1 }) end
            end
        end

        if #frames == 0 then
            return { type = "text", text = string.format("View %d: no renderable cels", rnum) }
        end

        if #frames == 1 then
            return {
                type = "image", image = frames[1].img,
                description = string.format("View %d (Loop %d, Cel %d)", rnum, frames[1].loop, frames[1].cel),
            }
        end

        -- Multiple cels: show first loop as animation (or all cels)
        local first_loop_cels = loops[1]
        if first_loop_cels and #first_loop_cels > 1 then
            local anim_frames = {}
            for _, cel in ipairs(first_loop_cels) do
                local img = render_cel(data, cel, pal)
                if img then table.insert(anim_frames, img) end
            end
            if #anim_frames > 1 then
                local anim = animation_create(anim_frames, 150)
                return {
                    type = "animation", animation = anim,
                    image = anim_frames[1], frames = anim_frames,
                    description = string.format("View %d (%d loops, %d total cels)", rnum, #loops, #frames),
                }
            end
        end

        return {
            type = "image", image = frames[1].img,
            description = string.format("View %d (Loop %d, Cel %d) [%d total cels]",
                rnum, frames[1].loop, frames[1].cel, #frames),
        }
    end

    -- PIC resource (type 1)
    if rtype == 1 then
        return {
            type = "text",
            text = string.format("Pic %d: %d bytes (SCI0 vector format - rendering not supported)", rnum, #data),
        }
    end

    -- FONT resource (type 7)
    if rtype == 7 then
        -- SCI0 font: simple bitmap font, could render a preview
        return {
            type = "text",
            text = string.format("Font %d: %d bytes", rnum, #data),
        }
    end

    -- CURSOR resource (type 8)
    if rtype == 8 then
        -- SCI0 cursor: 16x16 monochrome, 2bpp? Or similar to a small view cel
        if #data >= 68 then
            -- Try: 4-byte header + 16x16 data (2 bytes per row = 32 bytes cursor + 32 bytes mask)
            -- Actually: SCI0 cursor = 2x(16x16 bits) = 2x32 bytes = 64 bytes + small header
            local w, h = 16, 16
            local pix = {}
            for i = 1, w * h do pix[i] = 15 end -- white default
            -- Assume: 4 bytes header, then 32 bytes mask, then 32 bytes pixels
            -- Each row is 2 bytes (16 bits)
            for y = 0, 15 do
                local mask_hi = u8(data, 5 + y * 2)
                local mask_lo = u8(data, 6 + y * 2)
                local pix_hi = u8(data, 37 + y * 2)
                local pix_lo = u8(data, 38 + y * 2)
                for x = 0, 7 do
                    local bp = 7 - x
                    local m = math.floor(mask_hi / POW2[bp]) % 2
                    local p = math.floor(pix_hi / POW2[bp]) % 2
                    if m == 0 then
                        pix[y * 16 + x + 1] = p == 1 and 15 or 0
                    else
                        pix[y * 16 + x + 1] = 0 -- transparent = black
                    end
                end
                for x = 0, 7 do
                    local bp = 7 - x
                    local m = math.floor(mask_lo / POW2[bp]) % 2
                    local p = math.floor(pix_lo / POW2[bp]) % 2
                    if m == 0 then
                        pix[y * 16 + x + 8 + 1] = p == 1 and 15 or 0
                    else
                        pix[y * 16 + x + 8 + 1] = 0
                    end
                end
            end
            local img = image_create_indexed(w, h, pix, pal)
            return {
                type = "image", image = img,
                description = string.format("Cursor %d (16x16)", rnum),
            }
        end
        return { type = "text", text = string.format("Cursor %d: %d bytes", rnum, #data) }
    end

    -- Other resource types: show metadata
    local type_name = RES_NAMES[rtype] or ("Type " .. rtype)
    return {
        type = "text",
        text = string.format("%s %d: %d bytes", type_name, rnum, #data),
    }
end

return engine

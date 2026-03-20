-- ============================================================================
-- Adventure Explorer - Engine Script: Broken Sword 2 (The Smoking Mirror)
-- ============================================================================
-- Archive: CLU cluster files with embedded index table at end
-- Screen resources (fileType=2): ResHeader(44) + MultiScreenHeader(36)
-- Background: parallax-compressed scanlines (packets of skip/copy)
-- Palette: 1024 bytes (256 x RGBA), full 8-bit, at MSH palette offset
-- ============================================================================

local engine = {}
engine.name        = "Broken Sword II: The Smoking Mirror"
engine.id          = "sword2"
engine.description = "Broken Sword II: The Smoking Mirror (1997, Revolution)"
engine.version     = "1.0"

-- Binary helpers
local function u8(data, pos)   return data:byte(pos) end
local function u16le(data, pos)
    return data:byte(pos) + data:byte(pos + 1) * 256
end
local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end

local function i16le(data, pos)
    local v = data:byte(pos) + data:byte(pos + 1) * 256
    if v >= 32768 then v = v - 65536 end
    return v
end

-- ── Sprite decompression (BS2 RLE256) ────────────────────────────
-- From ScummVM decompressRLE256: alternating flat/raw pairs
--   1) read flat_count: if >0, read fill_color, fill flat_count pixels
--   2) read raw_count:  if >0, copy raw_count literal pixels
-- Loop until all pixels produced.

local function decompress_rle256(data, src, comp_size, w, h)
    local pixels = {}
    local n = w * h
    for i = 1, n do pixels[i] = 0 end
    local sp = src
    local dp = 1
    local src_end = src + comp_size
    while dp <= n and sp < src_end and sp <= #data do
        -- Flat run
        local flat_count = data:byte(sp); sp = sp + 1
        if flat_count > 0 then
            if sp > #data then break end
            local fill_val = data:byte(sp); sp = sp + 1
            for i = 1, flat_count do
                if dp > n then break end
                pixels[dp] = fill_val; dp = dp + 1
            end
        end
        if dp > n or sp >= src_end or sp > #data then break end
        -- Raw run
        local raw_count = data:byte(sp); sp = sp + 1
        if raw_count > 0 then
            for i = 1, raw_count do
                if dp > n or sp > #data then break end
                pixels[dp] = data:byte(sp); sp = sp + 1
                dp = dp + 1
            end
        end
    end
    return pixels
end

-- ============================================================================
-- CLU file reader: enumerate resources from a single CLU
-- Format: data at front, index table at end
--   offset 0: u32le table_offset
--   at table_offset: array of (u32le offset, u32le length) pairs
-- ============================================================================

local function read_clu_index(f)
    local fsize = file_size(f)
    if fsize < 8 then return nil end

    local head = file_read(f, 0, 4)
    if not head or #head < 4 then return nil end
    local table_offset = u32le(head, 1)

    if table_offset >= fsize or table_offset < 4 then return nil end

    local table_size = fsize - table_offset
    local num_entries = math.floor(table_size / 8)
    if num_entries == 0 then return nil end

    local tab_data = file_read(f, table_offset, table_size)
    if not tab_data or #tab_data < 8 then return nil end

    local entries = {}
    for i = 0, num_entries - 1 do
        local pos = i * 8 + 1  -- 1-based
        if pos + 7 > #tab_data then break end
        local off = u32le(tab_data, pos)
        local len = u32le(tab_data, pos + 4)
        if off > 0 and len > 0 and off + len <= fsize then
            entries[#entries + 1] = { index = i, offset = off, length = len }
        end
    end
    return entries
end

-- ============================================================================
-- Parallax decompressor
-- Each layer: 4-byte header (u16 w, u16 h), then h x u32 scanline offsets,
-- then packet-compressed scanline data.
-- ============================================================================

local function decompress_parallax(data, start_pos, expected_w, expected_h)
    -- Read parallax header
    local pw = u16le(data, start_pos)
    local ph = u16le(data, start_pos + 2)
    local w = expected_w or pw
    local h = expected_h or ph

    if w == 0 or h == 0 or w > 4096 or h > 4096 then return nil, 0, 0 end

    -- Read scanline offset table: h entries of u32le
    local line_offsets = {}
    for y = 0, h - 1 do
        local pos = start_pos + 4 + y * 4
        if pos + 3 > #data then break end
        line_offsets[y] = u32le(data, pos)
    end

    -- Initialize output buffer
    local pixels = {}
    local total = w * h
    for i = 1, total do pixels[i] = 0 end

    -- Decode each scanline
    for y = 0, h - 1 do
        local line_off = line_offsets[y]
        if line_off and line_off > 0 then
            -- Offset is relative to start of parallax data
            local abs_pos = start_pos + line_off
            if abs_pos + 3 <= #data then
                local packets = u16le(data, abs_pos)
                local x_off = u16le(data, abs_pos + 2)
                local pos = abs_pos + 4
                local dst = y * w + x_off

                if packets == 0 then
                    -- Uncompressed: copy w raw pixels
                    for x = 0, w - 1 do
                        if pos <= #data and x < w then
                            pixels[y * w + x + 1] = u8(data, pos)
                            pos = pos + 1
                        end
                    end
                else
                    -- Packet-compressed
                    local zeros = false
                    local j = 0
                    while j < packets and pos <= #data do
                        if zeros then
                            -- Skip count
                            local skip = u8(data, pos); pos = pos + 1
                            dst = dst + skip
                            zeros = false
                            j = j + 1
                        else
                            local b = u8(data, pos)
                            if b == 0 then
                                -- Switch to zeros mode
                                pos = pos + 1
                                zeros = true
                                j = j + 1
                            else
                                -- Copy count pixels
                                local count = b; pos = pos + 1
                                for k = 0, count - 1 do
                                    if dst >= 0 and dst < total and pos <= #data then
                                        pixels[dst + 1] = u8(data, pos)
                                    end
                                    dst = dst + 1
                                    pos = pos + 1
                                end
                                zeros = true
                                j = j + 1
                            end
                        end
                    end
                end
            end
        end
    end

    return pixels, w, h
end

-- ============================================================================
-- Detection
-- ============================================================================

function engine.detect(game_path)
    return file_exists(game_path .. "/general.clu")
        or file_exists(game_path .. "/GENERAL.CLU")
end

-- ============================================================================
-- Resource tree: scan all CLU files for screen resources (fileType == 2)
-- ============================================================================

function engine.get_resources(game_path)
    local resources = {}
    local rooms_cat = {
        id       = "rooms",
        name     = "Rooms",
        type     = "category",
        children = {}
    }

    -- Find all CLU files
    local all_files = list_files(game_path)
    local clu_files = {}
    for _, fname in ipairs(all_files) do
        if fname:lower():match("%.clu$") then
            clu_files[#clu_files + 1] = fname
        end
    end
    table.sort(clu_files)

    local anim_cat = {
        id       = "animations",
        name     = "Animations",
        type     = "category",
        children = {}
    }

    local screen_count = 0
    local anim_count = 0

    for _, clu_name in ipairs(clu_files) do
        local clu_path = game_path .. "/" .. clu_name
        local f = file_open(clu_path)
        if f then
            local entries = read_clu_index(f)
            if entries then
                local clu_screens = {}
                local clu_anims = {}
                local first_screen_idx = nil

                for _, entry in ipairs(entries) do
                    -- Read first 48 bytes: ResHeader(44) + AnimHeader start (runTimeComp + noAnimFrames)
                    local hdr = file_read(f, entry.offset, 48)
                    if hdr and #hdr >= 1 then
                        local ftype = u8(hdr, 1)
                        if ftype == 2 then
                            clu_screens[#clu_screens + 1] = entry
                            if not first_screen_idx then
                                first_screen_idx = entry.index
                            end
                        elseif ftype == 1 and #hdr >= 47 then
                            local runtime_comp = u8(hdr, 45)
                            local num_frames = u16le(hdr, 46)
                            if runtime_comp <= 2 and num_frames >= 1 and num_frames <= 4096 then
                                entry.num_frames = num_frames
                                entry.runtime_comp = runtime_comp
                                clu_anims[#clu_anims + 1] = entry
                            end
                        end
                    end
                end

                local clu_label = clu_name:match("^(.+)%.[cC][lL][uU]$") or clu_name

                if #clu_screens > 0 then
                    local clu_node = {
                        id       = "clu_" .. clu_label,
                        name     = string.format("%s (%d screens)", clu_label, #clu_screens),
                        type     = "category",
                        children = {}
                    }

                    for _, entry in ipairs(clu_screens) do
                        screen_count = screen_count + 1

                        local name_data = file_read(f, entry.offset + 10, 34)
                        local name = "Screen"
                        if name_data then
                            name = ""
                            for c = 1, 34 do
                                local b = name_data:byte(c)
                                if not b or b == 0 then break end
                                name = name .. string.char(b)
                            end
                            if name == "" then name = "Screen" end
                        end

                        local screen_node = {
                            id       = "screen_" .. clu_label .. "_" .. entry.index,
                            name     = string.format("[%d] %s", entry.index, name),
                            type     = "category",
                            children = {}
                        }

                        screen_node.children[#screen_node.children + 1] = {
                            id   = "bg_" .. clu_label .. "_" .. entry.index,
                            name = "Background",
                            type = "image"
                        }
                        screen_node.children[#screen_node.children + 1] = {
                            id   = "pal_" .. clu_label .. "_" .. entry.index,
                            name = "Palette",
                            type = "palette"
                        }

                        clu_node.children[#clu_node.children + 1] = screen_node
                    end

                    rooms_cat.children[#rooms_cat.children + 1] = clu_node
                end

                if #clu_anims > 0 then
                    local anim_clu_node = {
                        id       = "animclu_" .. clu_label,
                        name     = string.format("%s (%d animations)", clu_label, #clu_anims),
                        type     = "category",
                        children = {}
                    }

                    for _, entry in ipairs(clu_anims) do
                        anim_count = anim_count + 1

                        local name_data = file_read(f, entry.offset + 10, 34)
                        local anim_name = "Anim"
                        if name_data then
                            anim_name = ""
                            for c = 1, 34 do
                                local b = name_data:byte(c)
                                if not b or b == 0 then break end
                                anim_name = anim_name .. string.char(b)
                            end
                            if anim_name == "" then anim_name = "Anim" end
                        end

                        -- Encode first_screen_idx for palette lookup
                        local pal_suffix = ""
                        if first_screen_idx then
                            pal_suffix = "_pal" .. first_screen_idx
                        end

                        anim_clu_node.children[#anim_clu_node.children + 1] = {
                            id   = "anim_" .. clu_label .. "_" .. entry.index .. pal_suffix,
                            name = string.format("[%d] %s (%d frames)", entry.index, anim_name, entry.num_frames),
                            type = entry.num_frames > 1 and "animation" or "image"
                        }
                    end

                    anim_cat.children[#anim_cat.children + 1] = anim_clu_node
                end
            end
            file_close(f)
        end
    end

    rooms_cat.name = string.format("Screens (%d)", screen_count)
    resources[#resources + 1] = rooms_cat

    if anim_count > 0 then
        anim_cat.name = string.format("Animations (%d)", anim_count)
        resources[#resources + 1] = anim_cat
    end

    return resources
end


local function find_clu_file(game_path, label)
    local candidates = { label .. ".clu", label .. ".CLU",
                         string.upper(label) .. ".CLU", string.lower(label) .. ".clu" }
    for _, name in ipairs(candidates) do
        local path = game_path .. "/" .. name
        if file_exists(path) then return path end
    end
    return nil
end

local function read_screen_resource(game_path, clu_label, res_index)
    local clu_path = find_clu_file(game_path, clu_label)
    if not clu_path then return nil end

    local f = file_open(clu_path)
    if not f then return nil end

    local entries = read_clu_index(f)
    if not entries then file_close(f); return nil end

    -- Find the matching entry
    local target = nil
    for _, entry in ipairs(entries) do
        if entry.index == res_index then target = entry; break end
    end
    if not target then file_close(f); return nil end

    -- Read entire resource
    local data = file_read(f, target.offset, target.length)
    file_close(f)
    return data
end

function load_screen_bg(game_path, clu_label, res_index, pal_clu, pal_idx)
    local data = read_screen_resource(game_path, clu_label, res_index)
    if not data or #data < 80 then return nil end

    -- Verify fileType == 2
    if u8(data, 1) ~= 2 then return nil end

    -- ResHeader: 44 bytes (skip)
    -- MultiScreenHeader at +44 (36 bytes)
    local msh_base = 45  -- 1-based: byte 45 = offset 44
    local pal_off    = u32le(data, msh_base + 0)
    local bgpar0_off = u32le(data, msh_base + 4)
    local bgpar1_off = u32le(data, msh_base + 8)
    local screen_off = u32le(data, msh_base + 12)

    -- ScreenHeader at 44 + screen_off
    local sh_abs = 45 + screen_off  -- 1-based
    if sh_abs + 5 > #data then return nil end
    local scr_w = u16le(data, sh_abs)
    local scr_h = u16le(data, sh_abs + 2)
    -- local noLayers = u16le(data, sh_abs + 4)

    if scr_w == 0 or scr_h == 0 or scr_w > 4096 or scr_h > 4096 then return nil end

    -- Background data: try main screen first (at 44 + screen_off + 6)
    -- The background image is actually the bg_parallax[0], not after ScreenHeader
    -- But if bg_parallax[0] is 0, use screen_off + 6
    local bg_start
    if bgpar0_off > 0 then
        bg_start = 45 + bgpar0_off
    else
        bg_start = sh_abs + 6
    end

    -- Read parallax header to get actual dimensions
    if bg_start + 3 > #data then return nil end
    local pw = u16le(data, bg_start)
    local ph = u16le(data, bg_start + 2)

    -- Use parallax dimensions if they look valid
    local w, h
    if pw > 0 and pw <= 4096 and ph > 0 and ph <= 4096 then
        w, h = pw, ph
    else
        w, h = scr_w, scr_h
    end

    local pixels = decompress_parallax(data, bg_start, w, h)
    if not pixels then return nil end

    -- Determine palette source (override from a different screen if requested)
    local pal_data = data
    if pal_clu and pal_idx and (pal_clu ~= clu_label or pal_idx ~= res_index) then
        local override = read_screen_resource(game_path, pal_clu, pal_idx)
        if override and #override >= 80 and u8(override, 1) == 2 then
            pal_data = override
        end
    end

    -- Read palette from pal_data at 44 + pal_off (1024 bytes: 256 x [R,G,B,pad])
    local pd_msh = 45
    local pd_pal_off = u32le(pal_data, pd_msh + 0)
    local pal_abs = 45 + pd_pal_off
    local palette = {}
    for i = 0, 255 do
        palette[i * 3 + 1] = 0
        palette[i * 3 + 2] = 0
        palette[i * 3 + 3] = 0
    end

    if pal_abs + 1023 <= #pal_data then
        -- Skip color 0 (forced black), read from entry 1
        for i = 1, 255 do
            local p = pal_abs + i * 4
            if p + 2 <= #pal_data then
                palette[i * 3 + 1] = u8(pal_data, p + 0)
                palette[i * 3 + 2] = u8(pal_data, p + 1)
                palette[i * 3 + 3] = u8(pal_data, p + 2)
            end
        end
    end

    local img = image_create_indexed(w, h, pixels, palette)
    return {
        type = "image", image = img,
        description = string.format("Screen [%s:%d] - %dx%d, 256 colors", clu_label, res_index, w, h)
    }
end

function load_screen_pal(game_path, clu_label, res_index)
    local data = read_screen_resource(game_path, clu_label, res_index)
    if not data or #data < 80 then return nil end
    if u8(data, 1) ~= 2 then return nil end

    local msh_base = 45
    local pal_off = u32le(data, msh_base + 0)
    local pal_abs = 45 + pal_off

    if pal_abs + 1023 > #data then return nil end

    -- Build color array
    local colors = {}
    for i = 0, 255 do
        if i == 0 then
            colors[i] = { 0, 0, 0 }
        else
            local p = pal_abs + i * 4
            colors[i] = {
                u8(data, p + 0),
                u8(data, p + 1),
                u8(data, p + 2)
            }
        end
    end

    -- Render 16x16 grid
    local CELL, GRID = 16, 16
    local SIZE = CELL * GRID
    local rgb = {}; local n = 0

    for py = 0, SIZE - 1 do
        for px = 0, SIZE - 1 do
            local ci = math.floor(py / CELL) * GRID + math.floor(px / CELL)
            local c = colors[ci] or { 0, 0, 0 }
            n = n + 1; rgb[n] = c[1]
            n = n + 1; rgb[n] = c[2]
            n = n + 1; rgb[n] = c[3]
        end
    end

    local img = image_create_rgb(SIZE, SIZE, rgb)
    return {
        type = "image", image = img,
        description = string.format("Screen [%s:%d] palette - 256 colors", clu_label, res_index)
    }
end

-- ============================================================================
-- Animation/sprite decoder
-- Format: ResHeader(44) + AnimHeader(15) + CDT(numFrames*9) [+ colorTable(16)] + Frames
-- AnimHeader: runTimeComp(u8) + noAnimFrames(u16) + feet coords/dir + blend
-- CDT entry: x(i16) + y(i16) + frameOffset(u32) + frameType(u8) = 9 bytes
-- FrameHeader: compSize(u32) + width(u16) + height(u16) = 8 bytes, then pixel data
-- runTimeComp: 0=NONE, 1=RLE256, 2=RLE16
-- ============================================================================

local function decode_bs2_animation(data, palette)
    if not data or #data < 68 then return nil end

    -- Check fileType == 1 (animation)
    if u8(data, 1) ~= 1 then return nil end

    -- AnimHeader starts at byte 45 (1-based), after 44-byte ResHeader
    local runtime_comp = u8(data, 45)      -- 0=NONE, 1=RLE256, 2=RLE16
    local num_frames = u16le(data, 46)     -- uint16 noAnimFrames
    if num_frames < 1 or num_frames > 4096 then return nil end

    -- CDT starts at byte 60 (1-based): offset 44 (ResHeader) + 15 (AnimHeader) = 59 (0-based)
    local cdt_base = 60  -- Lua 1-based

    -- Read CDT entries (9 bytes each): i16 x, i16 y, u32 frameOffset, u8 frameType
    -- frameOffset is relative to start of AnimHeader (byte 45 in 1-based)
    local cdt = {}
    for i = 0, num_frames - 1 do
        local cp = cdt_base + i * 9
        if cp + 8 <= #data then
            cdt[i + 1] = {
                x = i16le(data, cp),
                y = i16le(data, cp + 2),
                frame_offset = u32le(data, cp + 4),
                frame_type = u8(data, cp + 8)
            }
        end
    end

    -- Parse frames using CDT frameOffset for positioning
    local frames = {}
    for fi = 1, num_frames do
        local cd = cdt[fi]
        if not cd then break end

        -- Frame position: byte 45 (AnimHeader start) + frameOffset
        local fp = 45 + cd.frame_offset
        if fp + 7 > #data then break end

        local comp_size = u32le(data, fp)
        local fw = u16le(data, fp + 4)
        local fh = u16le(data, fp + 6)

        if fw == 0 or fh == 0 or comp_size > #data then break end

        local pixel_start = fp + 8
        local raw_size = fw * fh
        local pixels

        if runtime_comp == 0 or comp_size == raw_size then
            -- Uncompressed: raw pixels
            pixels = {}
            for i = 1, raw_size do
                if pixel_start + i - 1 <= #data then
                    pixels[i] = data:byte(pixel_start + i - 1)
                else
                    pixels[i] = 0
                end
            end
        elseif runtime_comp == 1 then
            -- RLE256 compressed
            pixels = decompress_rle256(data, pixel_start, comp_size, fw, fh)
        else
            -- RLE16 or unknown compression: skip for now
            pixels = nil
        end

        if pixels then
            local img = image_create_indexed(fw, fh, pixels, palette)
            if img then
                frames[#frames + 1] = {
                    image = img,
                    width = fw,
                    height = fh,
                    offsetX = cd.x,
                    offsetY = cd.y,
                    comp_size = comp_size
                }
            end
        end
    end

    return frames, num_frames
end

local function load_bs2_animation(game_path, clu_label, res_index, pal_clu, pal_idx)
    local data = read_screen_resource(game_path, clu_label, res_index)
    if not data or #data < 68 then return nil end

    -- Get palette from nearest screen resource in the same CLU
    local palette = {}
    for i = 1, 768 do palette[i] = 0 end

    -- Try to find a screen resource in the same CLU for palette
    if pal_clu and pal_idx then
        local pal_data = read_screen_resource(game_path, pal_clu, pal_idx)
        if pal_data and #pal_data >= 80 and u8(pal_data, 1) == 2 then
            local msh_base = 45
            local pal_off = u32le(pal_data, msh_base)
            local pal_abs = 45 + pal_off
            if pal_abs + 1023 <= #pal_data then
                for i = 1, 255 do
                    local p = pal_abs + i * 4
                    if p + 2 <= #pal_data then
                        palette[i * 3 + 1] = u8(pal_data, p)
                        palette[i * 3 + 2] = u8(pal_data, p + 1)
                        palette[i * 3 + 3] = u8(pal_data, p + 2)
                    end
                end
            end
        end
    end

    local frames, total = decode_bs2_animation(data, palette)
    if not frames or #frames == 0 then return nil end

    local name = ""
    local name_raw = data:sub(11, 44)
    for i = 1, #name_raw do
        local b = name_raw:byte(i)
        if b == 0 then break end
        name = name .. string.char(b)
    end

    if #frames == 1 then
        return {
            type = "image",
            image = frames[1].image,
            description = string.format(
                "Animation '%s' [%s:%d] - %dx%d, %d bytes",
                name, clu_label, res_index, frames[1].width, frames[1].height, frames[1].comp_size
            )
        }
    else
        local handles = {}
        for i = 1, #frames do handles[i] = frames[i].image end
        local anim = animation_create(handles, 100)
        return {
            type = "animation",
            image = frames[1].image,
            frames = handles,
            animation = anim,
            description = string.format(
                "Animation '%s' [%s:%d] - %d frames, %dx%d",
                name, clu_label, res_index, #frames, frames[1].width, frames[1].height
            )
        }
    end
end

-- ============================================================================
-- Resource loading
-- ============================================================================

function engine.load_resource(game_path, resource_id, palette_id)
    -- Animation resources: anim_CLUNAME_INDEX[_palN]
    local anim_clu, anim_idx_str, pal_screen = resource_id:match("^anim_(.+)_(%d+)_pal(%d+)$")
    if not anim_clu then
        anim_clu, anim_idx_str = resource_id:match("^anim_(.+)_(%d+)$")
    end
    if anim_clu and anim_idx_str then
        local anim_idx = tonumber(anim_idx_str)
        local pal_clu_src = nil
        local pal_idx_src = nil
        if pal_screen then
            pal_clu_src = anim_clu
            pal_idx_src = tonumber(pal_screen)
        end
        if palette_id and palette_id ~= "" then
            local _, pc, pi = palette_id:match("^(%a+)_(.+)_(%d+)$")
            if pc and pi then
                pal_clu_src = pc
                pal_idx_src = tonumber(pi)
            end
        end
        return load_bs2_animation(game_path, anim_clu, anim_idx, pal_clu_src, pal_idx_src)
    end

    -- Screen resources: bg_CLUNAME_INDEX or pal_CLUNAME_INDEX
    local prefix, clu_label, idx_str = resource_id:match("^(%a+)_(.+)_(%d+)$")
    local idx = tonumber(idx_str)
    if not prefix or not clu_label or not idx then return nil end

    if prefix == "bg" then
        local pal_clu, pal_idx = clu_label, idx
        if palette_id and palette_id ~= "" then
            local _, pc, pi = palette_id:match("^(%a+)_(.+)_(%d+)$")
            if pc and pi then pal_clu = pc; pal_idx = tonumber(pi) end
        end
        return load_screen_bg(game_path, clu_label, idx, pal_clu, pal_idx)
    end
    if prefix == "pal" then return load_screen_pal(game_path, clu_label, idx) end
    return nil
end

return engine

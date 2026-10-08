-- ============================================================================
-- SCUMM costume (actor sprite) decoding
--   V5/V6  'COST'  : limbs -> cels, byleRLE column RLE, up to 32 colours
--   V7/V8  'AKOS'  : AKHD/AKPL/AKSQ/AKCH/AKOF/AKCI/AKCD, codecs 1 (byleRLE),
--                    5 (BOMP) and 16 (MajMin)
-- Sources: ScummVM engines/scumm/costume.cpp, akos.cpp, base-costume.cpp, bomp.cpp
--
-- A parsed costume exposes:
--   cost.kind          "cost" | "akos"
--   cost:animations()  -> list of { id=, name= } non-empty animations (chores)
--   cost:cel_count()   -> number of distinct cels
--   cost:render_animation(id, palette) -> animation handle, frames, width, height
--   cost:render_sheet(palette)         -> image handle, width, height
-- ============================================================================

local U = require("scumm_util")
local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift
local u16le, i16le, u32le = U.u16le, U.i16le, U.u32le

local C = {}

local MAX_FRAMES = 96
local MAX_CANVAS = 1200 * 900

-- ── Cel pixel decoders (return row-major arrays, -1 = transparent) ──────────

local function blank(w, h)
    local px = {}
    for i = 1, w * h do px[i] = -1 end
    return px
end

-- Column-major byleRLE: runs go down each column, left to right.
local function decode_byle(data, pos, w, h, ncolors, map)
    local px = blank(w, h)
    local shr, mask
    if ncolors == 32 then shr, mask = 3, 7
    elseif ncolors == 64 then shr, mask = 2, 3
    else shr, mask = 4, 15 end

    local x, y = 0, 0
    local len_data = #data
    while x < w and pos <= len_data do
        local b = data:byte(pos); pos = pos + 1
        local color = rshift(b, shr)
        local len = band(b, mask)
        if len == 0 then
            len = data:byte(pos) or 0; pos = pos + 1
            if len == 0 then len = 256 end
        end
        for _ = 1, len do
            if color ~= 0 and x < w then
                px[y * w + x + 1] = map(color)
            end
            y = y + 1
            if y >= h then
                y = 0
                x = x + 1
                if x >= w then break end
            end
        end
    end
    return px
end

-- BOMP: each row is u16 length + RLE (bit0 set = run of one colour, else literal).
local function decode_bomp(data, pos, w, h, map)
    local px = blank(w, h)
    for row = 0, h - 1 do
        local rowlen = u16le(data, pos)
        local p = pos + 2
        local x = 0
        while x < w and p <= #data do
            local code = data:byte(p); p = p + 1
            local num = rshift(code, 1) + 1
            if num > w - x then num = w - x end
            if band(code, 1) ~= 0 then
                local color = data:byte(p) or 0; p = p + 1
                if color ~= 0 then
                    local c = map and map(color) or color
                    for i = 0, num - 1 do px[row * w + x + i + 1] = c end
                end
                x = x + num
            else
                for i = 0, num - 1 do
                    local color = data:byte(p) or 0; p = p + 1
                    if color ~= 0 then px[row * w + x + i + 1] = map and map(color) or color end
                end
                x = x + num
            end
        end
        pos = pos + rowlen + 2
    end
    return px
end

-- MajMin codec (AKOS codec 16): row-major, colour 255 = transparent.
local function decode_majmin(data, pos, w, h)
    local px = blank(w, h)
    local shift = data:byte(pos) or 0
    local color = data:byte(pos + 1) or 0
    local bits = (data:byte(pos + 2) or 0) + (data:byte(pos + 3) or 0) * 256
    local numBits = 16
    local p = pos + 4
    local repeatMode, repeatCount = false, 0

    local function read_bits(n)
        if numBits <= 8 then
            bits = bor(bits, lshift(data:byte(p) or 0, numBits))
            p = p + 1
            numBits = numBits + 8
        end
        local v = band(bits, lshift(1, n) - 1)
        bits = rshift(bits, n)
        numBits = numBits - n
        return v
    end

    for i = 1, w * h do
        if color ~= 255 then px[i] = color end
        if not repeatMode then
            if read_bits(1) ~= 0 then
                if read_bits(1) ~= 0 then
                    local diff = read_bits(3) - 4
                    if diff ~= 0 then
                        color = band(color + diff, 0xFF)
                    else
                        repeatMode = true
                        repeatCount = read_bits(8) - 1
                    end
                else
                    color = read_bits(shift)
                end
            end
        else
            repeatCount = repeatCount - 1
            if repeatCount == 0 then repeatMode = false end
        end
    end
    return px
end

-- ── Compositing ─────────────────────────────────────────────────────────────

-- placements: list of { cel = {w,h,pixels}, x =, y = } drawn in order.
-- Returns bounds {minx,miny,maxx,maxy} (maxx/maxy exclusive) or nil if empty.
local function bounds_of(frames)
    local minx, miny, maxx, maxy
    for _, placements in ipairs(frames) do
        for _, p in ipairs(placements) do
            local x2, y2 = p.x + p.cel.w, p.y + p.cel.h
            if not minx or p.x < minx then minx = p.x end
            if not miny or p.y < miny then miny = p.y end
            if not maxx or x2 > maxx then maxx = x2 end
            if not maxy or y2 > maxy then maxy = y2 end
        end
    end
    if not minx then return nil end
    return { minx, miny, maxx, maxy }
end

local function pick_key(used)
    for i = 255, 0, -1 do
        if not used[i] then return i end
    end
    return 255
end

-- Paint placements into a w*h canvas. Returns pixel table (transparent = key).
local function paint(placements, bx, by, w, h, key, used)
    local canvas = {}
    for i = 1, w * h do canvas[i] = key end
    for _, p in ipairs(placements) do
        local cel = p.cel
        local ox, oy = p.x - bx, p.y - by
        local px = cel.pixels
        for cy = 0, cel.h - 1 do
            local ty = oy + cy
            if ty >= 0 and ty < h then
                local srow = cy * cel.w
                local trow = ty * w
                for cx = 0, cel.w - 1 do
                    local c = px[srow + cx + 1]
                    if c >= 0 then
                        local tx = ox + cx
                        if tx >= 0 and tx < w then
                            canvas[trow + tx + 1] = c
                        end
                    end
                end
            end
        end
    end
    return canvas
end

local function collect_used(frames, used)
    for _, placements in ipairs(frames) do
        for _, p in ipairs(placements) do
            local px = p.cel.pixels
            for i = 1, #px do
                local c = px[i]
                if c >= 0 then used[c] = true end
            end
        end
    end
end

-- Render a list of frames (each a list of placements) into an animation.
local function render_frames(frames, palette, delay_ms)
    local b = bounds_of(frames)
    if not b then return nil end
    local w, h = b[3] - b[1], b[4] - b[2]
    if w <= 0 or h <= 0 or w * h > MAX_CANVAS then return nil end

    local used = {}
    collect_used(frames, used)
    local key = pick_key(used)
    local pal = U.with_key_color(palette, key)

    local handles = {}
    for _, placements in ipairs(frames) do
        local canvas = paint(placements, b[1], b[2], w, h, key, used)
        handles[#handles + 1] = image_create_indexed(w, h, canvas, pal)
    end
    if #handles == 1 then
        return handles[1], 1, w, h, false
    end
    return animation_create(handles, delay_ms or 120), #handles, w, h, true
end

-- Tile the cels of a costume on one sheet. Very large costumes are cut off
-- once the sheet would exceed SHEET_BUDGET pixels; the shown count is returned.
local SHEET_BUDGET = 3000000

local function render_cel_sheet(all_cels, palette)
    local cels, area = {}, 0
    for _, cel in ipairs(all_cels) do
        area = area + (cel.w + 4) * (cel.h + 4)
        if area > SHEET_BUDGET and #cels > 0 then break end
        cels[#cels + 1] = cel
    end
    local n = #cels
    if n == 0 then return nil end
    -- Aim for a roughly square sheet
    local total = 0
    for _, cel in ipairs(cels) do total = total + (cel.w + 4) * (cel.h + 4) end
    local target_w = math.max(256, math.floor(math.sqrt(total) * 1.3))

    local placements, used = {}, {}
    local x, y, row_h, max_w = 4, 4, 0, 0
    for _, cel in ipairs(cels) do
        if x > 4 and x + cel.w > target_w then
            x = 4
            y = y + row_h + 4
            row_h = 0
        end
        placements[#placements + 1] = { cel = cel, x = x, y = y }
        x = x + cel.w + 4
        if x > max_w then max_w = x end
        if cel.h > row_h then row_h = cel.h end
    end
    local w, h = max_w, y + row_h + 4

    collect_used({ placements }, used)
    local key = pick_key(used)
    local canvas = paint(placements, 0, 0, w, h, key, used)
    return image_create_indexed(w, h, canvas, U.with_key_color(palette, key)), w, h, n, #all_cels
end

-- ── V5/V6 classic costumes ──────────────────────────────────────────────────

local Classic = {}
Classic.__index = Classic

local FORMAT_COLORS = { [0x58] = 16, [0x59] = 32, [0x60] = 16, [0x61] = 32 }

function Classic.parse(block, version)
    -- offsets below are 0-based positions inside the block, like ScummVM's pointers
    local base = (version >= 6) and 8 or 2
    local function B(off) return block:byte(off + 1) or 0 end
    local function W(off) return u16le(block, off + 1) end

    local num_anim = B(base + 6)
    local fmt = band(B(base + 7), 0x7F)
    local ncolors = FORMAT_COLORS[fmt]
    if not ncolors then return nil end

    local self = setmetatable({}, Classic)
    self.kind = "cost"
    self.block, self.base, self.B, self.W = block, base, B, W
    self.num_anim = num_anim
    self.ncolors = ncolors
    self.pal = {}
    for i = 0, ncolors - 1 do self.pal[i] = B(base + 8 + i) end
    local ptr = base + 8 + ncolors
    self.anim_cmds = base + W(ptr)
    self.frame_offsets = ptr + 2
    self.data_offsets = ptr + 34
    self.cel_cache = {}
    return self
end

function Classic:cel(limb, code)
    local key = limb * 256 + code
    local cached = self.cel_cache[key]
    if cached ~= nil then return cached or nil end

    local W, base = self.W, self.base
    local frameptr = base + W(self.frame_offsets + limb * 2)
    local src = base + W(frameptr + code * 2)
    local w, h = W(src), W(src + 2)
    if w == 0 or h == 0 or w > 640 or h > 480 or src >= #self.block then
        self.cel_cache[key] = false
        return nil
    end
    local pal = self.pal
    local cel = {
        w = w, h = h,
        relx = i16le(self.block, src + 4 + 1),
        rely = i16le(self.block, src + 6 + 1),
        movex = i16le(self.block, src + 8 + 1),
        movey = i16le(self.block, src + 10 + 1),
        limb = limb, code = code,
    }
    cel.pixels = decode_byle(self.block, src + 12 + 1, w, h, self.ncolors,
        function(c) return pal[c] or c end)
    self.cel_cache[key] = cel
    return cel
end

-- Parse one animation into per-limb sequences of cel codes.
function Classic:parse_anim(anim)
    if anim < 0 or anim >= self.num_anim + 1 then return nil end
    local W, B, base = self.W, self.B, self.base
    local off = W(self.data_offsets + anim * 2)
    if off == 0 then return nil end
    local r = base + off
    local mask = W(r); r = r + 2
    local limbs = {}
    local i = 0
    local guard = 0
    repeat
        if band(mask, 0x8000) ~= 0 then
            local j = W(r); r = r + 2
            if j ~= 0xFFFF then
                local extra = B(r); r = r + 1
                local cmd = B(self.anim_cmds + j)
                if cmd ~= 0x7A and cmd ~= 0x79 then
                    limbs[i] = { start = j, stop = j + band(extra, 0x7F),
                                 once = band(extra, 0x80) ~= 0 }
                end
            end
        end
        i = i + 1
        mask = band(lshift(mask, 1), 0xFFFF)
        guard = guard + 1
    until mask == 0 or guard > 16
    return limbs
end

function Classic:animations()
    local list = {}
    for a = 0, self.num_anim do
        local limbs = self:parse_anim(a)
        if limbs and next(limbs) then
            local dir = ({ [0] = "W", "E", "S", "N" })[a % 4]
            list[#list + 1] = { id = a, name = string.format("Anim %d (chore %d, %s)", a, math.floor(a / 4), dir) }
        end
    end
    return list
end

function Classic:all_cels()
    if self.cels_list then return self.cels_list end
    local seen, list = {}, {}
    for a = 0, self.num_anim do
        local limbs = self:parse_anim(a)
        for limb, l in pairs(limbs or {}) do
            for i = l.start, l.stop do
                local code = band(self.B(self.anim_cmds + i), 0x7F)
                if code < 0x79 and code ~= 0x7B then
                    local key = limb * 256 + code
                    if not seen[key] then
                        seen[key] = true
                        local cel = self:cel(limb, code)
                        if cel then list[#list + 1] = cel end
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.limb ~= b.limb then return a.limb < b.limb end
        return a.code < b.code
    end)
    self.cels_list = list
    return list
end

function Classic:cel_count()
    return #self:all_cels()
end

function Classic:render_sheet(palette)
    return render_cel_sheet(self:all_cels(), palette)
end

function Classic:render_animation(anim, palette)
    local limbs = self:parse_anim(anim)
    if not limbs then return nil end

    -- Build each limb's displayed sequence of positions.
    local seqs, nframes = {}, 1
    for limb = 0, 15 do
        local l = limbs[limb]
        if l then
            local seq = {}
            for i = l.start, l.stop do
                local raw = self.B(self.anim_cmds + i)
                local skip = (i ~= l.start) and (raw == 0x7C or (raw >= 0x71 and raw <= 0x78))
                if not skip then seq[#seq + 1] = i end
            end
            if #seq == 0 then seq[1] = l.start end
            seqs[limb] = { seq = seq, once = l.once }
            if #seq > nframes then nframes = #seq end
        end
    end
    if nframes > MAX_FRAMES then nframes = MAX_FRAMES end

    local frames = {}
    for t = 0, nframes - 1 do
        local placements = {}
        local xmove, ymove = 0, 0
        for limb = 0, 15 do
            local s = seqs[limb]
            if s then
                local n = #s.seq
                local idx = s.once and math.min(t + 1, n) or (t % n) + 1
                local code = band(self.B(self.anim_cmds + s.seq[idx]), 0x7F)
                if code < 0x79 and code ~= 0x7B then
                    local cel = self:cel(limb, code)
                    if cel then
                        placements[#placements + 1] = {
                            cel = cel, x = xmove + cel.relx, y = ymove + cel.rely }
                        xmove = xmove + cel.movex
                        ymove = ymove - cel.movey
                    end
                end
            end
        end
        frames[#frames + 1] = placements
    end
    return render_frames(frames, palette, 120)
end

-- ── V7/V8 AKOS costumes ─────────────────────────────────────────────────────

local Akos = {}
Akos.__index = Akos

-- Sizes (bytes) of AKSQ commands, keyed by the 16-bit command code.
local AKC_SIZE = {}
local function akc(size, ...)
    for _, code in ipairs({ ... }) do AKC_SIZE[code] = size end
end
akc(5, 0xC031, 0xC040, 0xC010, 0xC090, 0xC091, 0xC092, 0xC093, 0xC094, 0xC095,
    0xC016, 0xC017, 0xC018, 0xC019)
akc(3, 0xC088, 0xC083, 0xC08C, 0xC08D, 0xC050, 0xC080, 0xC081, 0xC015, 0xC042, 0xC044, 0xC0A3)
akc(8, 0xC089)
akc(6, 0xC08B, 0xC085, 0xC087)
akc(2, 0xC09F, 0xC086, 0xC060, 0xC061, 0xC001, 0xC0FF)
akc(7, 0xC070, 0xC071, 0xC072, 0xC073, 0xC074, 0xC075, 0xC082)
akc(4, 0xC08A, 0xC030, 0xC084, 0xC0A0, 0xC0A1, 0xC0A2, 0xC08E)

function Akos.parse(block)
    if block:sub(1, 4) ~= "AKOS" then return nil end
    local blocks = U.scan_blocks(block, 9, #block)
    local function find(tag) return U.find_block(blocks, tag) end
    local akhd, akpl, aksq, akch = find("AKHD"), find("AKPL"), find("AKSQ"), find("AKCH")
    local akof, akci, akcd = find("AKOF"), find("AKCI"), find("AKCD")
    if not (akhd and aksq and akch and akof and akci and akcd) then return nil end

    local self = setmetatable({}, Akos)
    self.kind = "akos"
    self.block = block
    self.chore_count = u16le(block, akhd.data_start + 4)
    self.cel_total = u16le(block, akhd.data_start + 6)
    self.codec = u16le(block, akhd.data_start + 8)
    self.flags = u16le(block, akhd.data_start + 2)
    self.aksq, self.akch, self.akof, self.akci, self.akcd = aksq, akch, akof, akci, akcd
    self.pal = {}
    self.npal = 0
    if akpl then
        self.npal = akpl.size - 8
        for i = 0, self.npal - 1 do self.pal[i] = block:byte(akpl.data_start + i) end
    end
    self.cel_cache = {}
    return self
end

function Akos:cel(n)
    local cached = self.cel_cache[n]
    if cached ~= nil then return cached or nil end
    if n < 0 or n >= self.cel_total then self.cel_cache[n] = false; return nil end

    local blk = self.block
    local ofs = self.akof.data_start + n * 6
    local akcd_off = u32le(blk, ofs)
    local akci_off = u16le(blk, ofs + 4)
    local ci = self.akci.data_start + akci_off
    local w, h = u16le(blk, ci), u16le(blk, ci + 2)
    if w == 0 or h == 0 or w > 1024 or h > 1024 then
        self.cel_cache[n] = false
        return nil
    end
    local cel = {
        w = w, h = h,
        relx = i16le(blk, ci + 4), rely = i16le(blk, ci + 6),
        movex = i16le(blk, ci + 8), movey = i16le(blk, ci + 10),
        code = n, limb = 0,
    }
    local src = self.akcd.data_start + akcd_off
    local pal, npal = self.pal, self.npal
    if self.codec == 1 then
        cel.pixels = decode_byle(blk, src, w, h, npal, function(c) return pal[c] or c end)
    elseif self.codec == 5 then
        cel.pixels = decode_bomp(blk, src, w, h, nil)
    elseif self.codec == 16 then
        cel.pixels = decode_majmin(blk, src, w, h)
    else
        self.cel_cache[n] = false
        return nil
    end
    self.cel_cache[n] = cel
    return cel
end

function Akos:parse_chore(chore)
    if chore < 0 or chore >= self.chore_count then return nil end
    local blk = self.block
    local off = u16le(blk, self.akch.data_start + chore * 2)
    if off == 0 then return nil end
    local r = self.akch.data_start + off
    local mask = u16le(blk, r); r = r + 2
    local limbs = {}
    local i, guard = 0, 0
    repeat
        if band(mask, 0x8000) ~= 0 then
            local code = blk:byte(r); r = r + 1
            if code ~= 1 and code ~= 4 and code ~= 5 then
                local start, len = u16le(blk, r), u16le(blk, r + 2)
                r = r + 4
                limbs[i] = { type = code, start = start, stop = start + len }
            end
        end
        i = i + 1
        mask = band(lshift(mask, 1), 0xFFFF)
        guard = guard + 1
    until mask == 0 or guard > 32
    return limbs
end

function Akos:animations()
    local list = {}
    for c = 0, self.chore_count - 1 do
        local limbs = self:parse_chore(c)
        if limbs and next(limbs) then
            list[#list + 1] = { id = c, name = string.format("Chore %d", c) }
        end
    end
    return list
end

function Akos:cel_count()
    return self.cel_total
end

function Akos:render_sheet(palette)
    local cels = {}
    for n = 0, self.cel_total - 1 do
        local cel = self:cel(n)
        if cel then cels[#cels + 1] = cel end
    end
    return render_cel_sheet(cels, palette)
end

-- Read the cel code at an AKSQ state. Returns code, size.
function Akos:code_at(state)
    local blk = self.block
    local p = self.aksq.data_start + state
    local c1 = blk:byte(p) or 0
    if c1 >= 0x80 then return U.u16be(blk, p), 2 end
    return c1, 1
end

-- Walk one limb's AKSQ range and return its draw entries. Each entry is a
-- list of { cel = n, dx =, dy = } plus optional trailing offsets.
function Akos:limb_entries(limb)
    local blk = self.block
    local base = self.aksq.data_start
    local entries = {}
    local state = limb.start
    local guard = 0
    -- "Always run" layers (type 6) are scripts: they ignore the end state and
    -- follow GoToState jumps until the sequence repeats.
    local script = (limb.type == 6 or limb.type == 7 or limb.type == 8)
    local visited = {}
    local aksq_len = self.aksq.size - 8
    while (script and state < aksq_len or state <= limb.stop) and guard < 2000 do
        guard = guard + 1
        if script then
            if visited[state] then break end
            visited[state] = true
        end
        local p = base + state
        local code, size = self:code_at(state)
        local step = size

        if code < 0xC000 then
            -- plain cel (1- or 2-byte); the high bit is only the "extended" flag
            entries[#entries + 1] = { draws = { { cel = band(code, 0xFFF), dx = 0, dy = 0, plain = true } } }
        elseif code == 0xC001 then
            entries[#entries + 1] = { draws = {} }
            step = 2
        elseif code == 0xC0FF then
            break
        elseif code == 0xC030 and script then
            -- GoToState: continue at the target (sequence repeats once revisited)
            state = u16le(blk, p + 2)
            step = 0
        elseif code == 0xC020 or code == 0xC025 or code == 0xC021 or code == 0xC022 then
            local q = p
            local lastdx, lastdy = 0, 0
            local total
            if code == 0xC021 or code == 0xC022 then
                local n = blk:byte(p + 3) or 0
                total = blk:byte(p + 2) or 2
                q = p + n + 2
                if code == 0xC022 then
                    lastdx, lastdy = i16le(blk, q + 2), i16le(blk, q + 4)
                    q = q + 4
                end
            elseif code == 0xC025 then
                lastdx, lastdy = i16le(blk, p + 2), i16le(blk, p + 4)
                q = p + 4
            end
            local count = blk:byte(q + 2) or 0
            local d = q + 3
            local draws = {}
            for _ = 1, count do
                local dx, dy = i16le(blk, d), i16le(blk, d + 2)
                local c1 = blk:byte(d + 4) or 0
                local ccode, csz
                if c1 >= 0x80 then ccode, csz = U.u16be(blk, d + 4), 2 else ccode, csz = c1, 1 end
                draws[#draws + 1] = { cel = band(ccode, 0xFFF), dx = dx, dy = dy }
                d = d + 4 + csz
            end
            entries[#entries + 1] = { draws = draws, lastdx = lastdx, lastdy = lastdy }
            if total then step = total else step = d - p end
        else
            step = AKC_SIZE[code] or 2
            -- script/sound commands draw nothing and do not produce a frame
        end
        if step > 0 or not script then
            if step < 1 then step = 1 end
            state = state + step
        end
    end
    return entries
end

function Akos:render_animation(chore, palette)
    local limbs = self:parse_chore(chore)
    if not limbs then return nil end

    local seqs, nframes = {}, 1
    for limb = 0, 31 do
        local l = limbs[limb]
        if l then
            local entries = self:limb_entries(l)
            if #entries > 0 then
                seqs[limb] = { entries = entries, once = (l.type == 3) }
                if #entries > nframes then nframes = #entries end
            end
        end
    end
    if nframes > MAX_FRAMES then nframes = MAX_FRAMES end

    local frames = {}
    for t = 0, nframes - 1 do
        local placements = {}
        local xmove, ymove = 0, 0
        for limb = 0, 31 do
            local s = seqs[limb]
            if s then
                local n = #s.entries
                local idx = s.once and math.min(t + 1, n) or (t % n) + 1
                local entry = s.entries[idx]
                for _, d in ipairs(entry.draws) do
                    local cel = self:cel(d.cel)
                    if cel then
                        if d.plain then
                            placements[#placements + 1] = {
                                cel = cel, x = xmove + cel.relx, y = ymove + cel.rely }
                            xmove = xmove + cel.movex
                            ymove = ymove - cel.movey
                        else
                            placements[#placements + 1] = {
                                cel = cel, x = xmove + d.dx, y = ymove + d.dy }
                        end
                    end
                end
                if entry.lastdx then
                    xmove = xmove + entry.lastdx
                    ymove = ymove - entry.lastdy
                end
            end
        end
        frames[#frames + 1] = placements
    end
    return render_frames(frames, palette, 100)
end

-- ── Public API ──────────────────────────────────────────────────────────────

--- Parse a costume block. `version` is the SCUMM major version (5..8).
function C.parse(block, version)
    if not block or #block < 16 then return nil end
    local tag = block:sub(1, 4)
    if tag == "AKOS" then return Akos.parse(block) end
    if tag == "COST" then return Classic.parse(block, version) end
    return nil
end

-- Shared with the object-sprite code path.
C.render_frames = render_frames
C.render_sheet_of = render_cel_sheet

return C

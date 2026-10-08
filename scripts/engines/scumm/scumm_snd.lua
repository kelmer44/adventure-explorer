-- ============================================================================
-- SCUMM audio
--   SOUN resources (V5/V6): 'SOU ' container with one chunk per output device
--       SBL  digital sample (AUhd + AUdt, VOC blocks)      -> PCM
--       ROL  Roland MT-32 music (MDhd + standard MIDI)     -> MIDI
--       GMD  General MIDI music                            -> MIDI
--       AMI  Amiga/Mac MIDI                                -> MIDI
--       ADL / SPK  AdLib / PC speaker driver data (same MIDI wrapper)
--   SOUN resources (V7/V8): resident iMUSE stream ('iMUS' MAP/FRMT/REGN/DATA)
--   .BUN bundles (The Dig, Curse of Monkey Island): LB83/LB23 directory of
--       compressed iMUSE sounds (music and speech)
-- Sources: ScummVM sound.cpp, dimuse_bndmgr.cpp, dimuse_codecs.cpp, audio/decoders/voc.cpp
-- ============================================================================

local U = require("scumm_util")
local u32be, u32le, u16le = U.u32be, U.u32le, U.u16le

local S = {}

-- ── Creative Voice (VOC) blocks ─────────────────────────────────────────────

--- Convert a run of VOC blocks (with or without the "Creative Voice File"
--- header) into 8-bit unsigned PCM. Returns pcm, sample_rate, bits, channels.
function S.voc_to_pcm(data, pos)
    pos = pos or 1
    if data:sub(pos, pos + 18) == "Creative Voice File" then
        pos = pos + u16le(data, pos + 20)
    end
    local parts, rate, bits, channels = {}, nil, 8, 1
    local n = #data
    local guard = 0
    while pos <= n and guard < 10000 do
        guard = guard + 1
        local btype = data:byte(pos)
        if btype == 0 or not btype then break end
        local size = u16le(data, pos + 1) + (data:byte(pos + 3) or 0) * 65536
        local body = pos + 4
        if btype == 1 then
            local div = data:byte(body) or 0
            local codec = data:byte(body + 1) or 0
            if codec ~= 0 then return nil end
            rate = rate or math.floor(1000000 / (256 - div) + 0.5)
            parts[#parts + 1] = data:sub(body + 2, body + size - 1)
        elseif btype == 2 then
            parts[#parts + 1] = data:sub(body, body + size - 1)
        elseif btype == 3 then
            local len = u16le(data, body) + 1
            parts[#parts + 1] = string.rep("\128", len)
        elseif btype == 9 then
            rate = rate or u32le(data, body)
            bits = data:byte(body + 4) or 8
            channels = data:byte(body + 5) or 1
            parts[#parts + 1] = data:sub(body + 12, body + size - 1)
        end
        pos = body + size
    end
    if #parts == 0 then return nil end
    return table.concat(parts), rate or 11025, bits, channels
end

--- Build a sound resource table from PCM produced by voc_to_pcm.
local function pcm_resource(pcm, rate, bits, channels, description)
    local handle = sound_create_pcm(rate, bits, channels, bits == 16, pcm)
    if not handle then return nil end
    return { type = "sound", sound = handle, description = description }
end

-- ── MIDI extraction ─────────────────────────────────────────────────────────

--- Pull the standard MIDI file out of an iMUSE MIDI chunk payload
--- ("MDhd" header followed by MThd/MTrk). Returns a midi handle or nil.
function S.midi_from_payload(payload)
    local start = payload:find("MThd", 1, true)
    if not start then return nil end
    local smf = payload:sub(start)
    if #smf < 14 then return nil end
    -- Format 2 (independent sequences) is not understood by every player;
    -- these files carry a single track, so present them as format 0.
    local ntrks = U.u16be(smf, 11)
    local fmt = (ntrks <= 1) and 0 or 1
    smf = smf:sub(1, 8) .. string.char(0, fmt) .. smf:sub(11)
    return midi_create_raw(smf)
end

-- ── SOUN resource parsing ───────────────────────────────────────────────────

--- Parse a full SOUN block (starting at the 'SOUN' tag).
--- Returns { base = "SOU "|"iMUS"|"MIDI"|"Crea"|..., chunks = { {tag=, payload=} } }
function S.parse_soun(block)
    if block:sub(1, 4) ~= "SOUN" or #block < 16 then return nil end
    local base = block:sub(9, 12)
    local info = { base = base, chunks = {} }
    if base == "SOU " then
        local total = u32be(block, 13)
        local pos = 17
        local limit = math.min(#block, 16 + total)
        while pos + 8 <= limit + 1 do
            local tag = block:sub(pos, pos + 3)
            local size = u32be(block, pos + 4)
            if size < 0 or pos + 8 + size - 1 > #block then break end
            info.chunks[#info.chunks + 1] = {
                tag = tag, payload = block:sub(pos + 8, pos + 8 + size - 1) }
            pos = pos + 8 + size
        end
    else
        -- single resident stream (iMUS), bare MIDI or a VOC file
        info.chunks[1] = { tag = base, payload = block:sub(9) }
    end
    return info
end

local MIDI_TAGS = { ["ROL "] = "Roland MT-32", ["GMD "] = "General MIDI", ["AMI "] = "Amiga MIDI",
                    ["MIDI"] = "MIDI", ["ADL "] = "AdLib (GM instruments)",
                    ["SPK "] = "PC speaker (GM instruments)" }
local DEVICE_NAMES = {
    ["SBL "] = "Digital sample", ["ROL "] = "Roland MT-32", ["GMD "] = "General MIDI",
    ["AMI "] = "Amiga MIDI", ["ADL "] = "AdLib", ["SPK "] = "PC speaker",
    ["MAC "] = "Macintosh", ["TOWS"] = "FM-Towns", ["iMUS"] = "iMUSE digital", ["Crea"] = "Digital sample",
    ["MIDI"] = "MIDI",
}

function S.device_name(tag)
    return DEVICE_NAMES[tag] or tag
end

--- Playable kind of a chunk tag: "sound", "midi" or nil.
function S.chunk_kind(tag)
    if tag == "SBL " or tag == "iMUS" or tag == "Crea" then return "sound" end
    if MIDI_TAGS[tag] then return "midi" end
    return nil
end

--- Load one chunk of a SOUN resource as a resource table.
function S.load_chunk(info, tag, description)
    for _, chunk in ipairs(info.chunks) do
        if chunk.tag == tag then
            if tag == "iMUS" then
                return S.load_imus(chunk.payload, description)
            elseif tag == "Crea" then
                local pcm, rate, bits, ch = S.voc_to_pcm(chunk.payload, 1)
                if not pcm then return { type = "text", text = "Unsupported VOC data" } end
                return pcm_resource(pcm, rate, bits, ch,
                    string.format("%s - %d Hz, %.2fs", description, rate, #pcm / rate))
            elseif tag == "SBL " then
                local audt = chunk.payload:find("AUdt", 1, true)
                if not audt then return { type = "text", text = "SBL chunk without AUdt" } end
                local pcm, rate, bits, ch = S.voc_to_pcm(chunk.payload, audt + 8)
                if not pcm then return { type = "text", text = "Unsupported VOC data" } end
                return pcm_resource(pcm, rate, bits, ch,
                    string.format("%s - %d Hz, %.2fs", description, rate, #pcm / rate))
            elseif MIDI_TAGS[tag] then
                local midi = S.midi_from_payload(chunk.payload)
                if not midi then return { type = "text", text = "No MIDI data in " .. tag } end
                return { type = "midi", midi = midi,
                         description = description .. " (" .. MIDI_TAGS[tag] .. ")" }
            end
        end
    end
    return nil
end

--- Resident iMUSE stream (V7/V8 SOUN block).
function S.load_imus(raw, description)
    local imus = raw:find("iMUS", 1, true)
    if not imus then return nil end
    local pcm, rate, bits, ch = imuse_stream_sound(raw:sub(imus))
    if not pcm then return { type = "text", text = "Could not decode iMUSE stream" } end
    local frame = math.floor(bits / 8) * ch
    return pcm_resource(pcm, rate, bits, ch, string.format("%s - %d Hz, %d-bit, %s, %.2fs",
        description, rate, bits, ch == 2 and "stereo" or "mono", #pcm / (rate * frame)))
end

-- ── .BUN bundles ────────────────────────────────────────────────────────────

--- Read a bundle directory. Returns { path, name, tag, entries = { {name, offset, size} } }.
function S.read_bundle(path)
    local f = file_open(path)
    if not f then return nil end
    local head = file_read(f, 0, 12)
    if not head or #head < 12 then file_close(f); return nil end
    local tag = head:sub(1, 4)
    if tag ~= "LB83" and tag ~= "LB23" then file_close(f); return nil end
    local dir_off, count = u32be(head, 5), u32be(head, 9)
    local entry_size = (tag == "LB23") and 32 or 20
    if count <= 0 or count > 100000 then file_close(f); return nil end
    local dir = file_read(f, dir_off, count * entry_size)
    file_close(f)
    if not dir or #dir < count * entry_size then return nil end

    local entries = {}
    for i = 0, count - 1 do
        local p = i * entry_size + 1
        local name
        if tag == "LB23" then
            name = dir:sub(p, p + 23):gsub("%z.*", "")
            p = p + 24
        else
            local stem = dir:sub(p, p + 7):gsub("%z", "")
            local ext = dir:sub(p + 8, p + 11):gsub("%z", "")
            name = stem .. "." .. ext
            p = p + 12
        end
        entries[#entries + 1] = { name = name, offset = u32be(dir, p), size = u32be(dir, p + 4) }
    end
    return { path = path, tag = tag, entries = entries,
             name = path:match("([^/\\]+)$") or path }
end

--- Which kind of bundle is this, judging by its file name?
function S.bundle_kind(name)
    local up = name:upper()
    if up:find("MUS") then return "Music" end
    if up:find("VOX") or up:find("VOICE") then return "Speech" end
    return "Audio"
end

--- Decode one bundle entry into a sound resource.
function S.load_bundle_entry(bundle, index)
    local e = bundle.entries[index]
    if not e then return nil end
    local default_channels = 0
    local pcm, rate, bits, ch = imuse_bundle_sound(bundle.path, e.offset, e.size, default_channels)
    if not pcm then
        return { type = "text", text = string.format("Could not decode %s (offset %d, %d bytes)",
            e.name, e.offset, e.size) }
    end
    local frame = math.floor(bits / 8) * ch
    local secs = #pcm / (rate * frame)
    return pcm_resource(pcm, rate, bits, ch, string.format("%s / %s - %d Hz, %d-bit, %s, %d:%04.1f",
        bundle.name, e.name, rate, bits, ch == 2 and "stereo" or "mono",
        math.floor(secs / 60), secs % 60))
end

-- ── Speech archives (.SOU, V6: Day of the Tentacle / Sam & Max) ──────────────
-- Layout: "SOU " + u32, then repeated { "VCTL" u32be(size incl. header) ..., a
-- complete Creative Voice file }. Clips are found by walking the VOC blocks.

function S.read_sou(path)
    local f = file_open(path)
    if not f then return nil end
    local fsize = file_size(f)
    local head = file_read(f, 0, 8)
    if not head or head:sub(1, 4) ~= "SOU " then file_close(f); return nil end

    local clips, pos = {}, 8
    while pos + 8 < fsize and #clips < 60000 do
        local h = file_read(f, pos, 8)
        if not h or #h < 8 or h:sub(1, 4) ~= "VCTL" then break end
        local voc = pos + u32be(h, 5)
        local hdr = file_read(f, voc, 26)
        if not hdr or hdr:sub(1, 19) ~= "Creative Voice File" then break end
        local p = voc + u16le(hdr, 21)
        local guard = 0
        while guard < 4096 do
            guard = guard + 1
            local b = file_read(f, p, 4)
            if not b or #b < 1 then break end
            local t = b:byte(1)
            if t == 0 then p = p + 1; break end
            if #b < 4 then break end
            p = p + 4 + b:byte(2) + b:byte(3) * 256 + b:byte(4) * 65536
        end
        clips[#clips + 1] = { start = voc, stop = p }
        pos = p
    end
    file_close(f)
    if #clips == 0 then return nil end
    return { path = path, name = path:match("([^/\\]+)$") or path, clips = clips }
end

function S.load_sou_clip(sou, index)
    local clip = sou.clips[index]
    if not clip then return nil end
    local f = file_open(sou.path)
    if not f then return nil end
    local data = file_read(f, clip.start, clip.stop - clip.start)
    file_close(f)
    if not data then return nil end
    local pcm, rate, bits, ch = S.voc_to_pcm(data, 1)
    if not pcm then return { type = "text", text = "Unsupported voice clip" } end
    return pcm_resource(pcm, rate, bits, ch, string.format("%s clip %d - %d Hz, %.2fs",
        sou.name, index, rate, #pcm / rate))
end

return S

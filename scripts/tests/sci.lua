-- lua scripts/tests/sci.lua [game folder] [all|sample]
local engine = dofile('scripts/engines/sci/engine.lua')
local function up(fn, key)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if name == key then return value end
        if not name then break end
    end
    error('Missing upvalue ' .. key)
end
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n) return le16(n % 65536) .. le16(math.floor(n / 65536)) end
local function map(entries, five)
    local out, offset = {}, (#entries + 1) * 3
    for _, e in ipairs(entries) do
        out[#out + 1] = string.char(e[1] + 128) .. le16(offset)
        offset = offset + #e[2] * (five and 5 or 6)
    end
    out[#out + 1] = '\255' .. le16(offset)
    for _, e in ipairs(entries) do
        for _, r in ipairs(e[2]) do
            out[#out + 1] = le16(r[1]) .. (five and le32(r[2] / 2):sub(1, 3) or le32(r[2]))
        end
    end
    return table.concat(out)
end
local fs = {}
function file_exists(p) return fs[p] ~= nil end
function file_open(p) return fs[p] end
function file_size(f) return #f end
function file_read(f, o, n) return f:sub(o + 1, o + n) end
function file_close() end
function log_warn(s) error(s) end
function image_create_indexed(w, h, pixels, palette)
    assert(w > 0 and h > 0 and #pixels == w * h)
    assert(#palette == 768)
    for _, v in ipairs(pixels) do assert(v >= 0 and v <= 255) end
    return {width = w, height = h, pixels = pixels, palette = palette}
end
function animation_create(frames) return frames end

-- Adjacent map blocks must not leak their first entry into the previous type.
local parse1 = up(up(engine.get_resources, 'get_info'), 'parse_map_sci1')
local parse11 = up(up(engine.get_resources, 'get_info'), 'parse_map_sci11')
for _, five in ipairs({false, true}) do
    local entries = (five and parse11 or parse1)(map({{0, {{1, 0}, {2, 20}}}, {1, {{3, 40}}}}, five))
    assert(#entries == 3 and entries[2].type == 0 and entries[3].type == 1)
    assert(entries[3].number == 3 and entries[3].offset == 40)
end

-- SCI1 and SCI2 can have identical six-byte map entries. Only the volume
-- header distinguishes the sizes and compression; the filenames do not.
local entries, old, new = {}, {}, {}
for i = 0, 2 do
    entries[#entries + 1] = {i, i * 20}
    old[#old + 1] = string.char(132) .. le16(i) .. le16(5) .. le16(1) .. le16(0) .. 'A' .. string.rep('\0', 10)
    new[#new + 1] = string.char(132) .. le16(i) .. le32(1) .. le32(1) .. le16(0) .. 'B' .. string.rep('\0', 6)
end
for _, name in ipairs({'old', 'new'}) do
    fs[name .. '/RESOURCE.MAP'] = map({{4, entries}})
    fs[name .. '/RESOURCE.000'] = table.concat(name == 'old' and old or new)
    assert(engine.detect(name))
    local tree = engine.get_resources(name)
    assert(#tree == 1 and #tree[1].children == 3)
end
local get_info = up(engine.get_resources, 'get_info')
local read_resource = up(engine.load_resource, 'read_resource')
assert(get_info('old').ver == 'sci1')
assert(get_info('new').ver == 'sci2' and not get_info('new').resmap)
assert(read_resource('old', get_info('old'), get_info('old').resources[1]) == 'A')
assert(read_resource('new', get_info('new'), get_info('new').resources[1]) == 'B')
fs['resmap/RESMAP.000'] = fs['new/RESOURCE.MAP']
fs['resmap/RESSCI.000'] = fs['new/RESOURCE.000']
assert(engine.detect('resmap'))
engine.get_resources('resmap')
assert(get_info('resmap').resmap)
assert(read_resource('resmap', get_info('resmap'), get_info('resmap').resources[1]) == 'B')
-- A misleading 13-byte prefix must not override an ordinary SCI1 header.
fs['bad/RESOURCE.MAP'] = fs['new/RESOURCE.MAP']
fs['bad/RESOURCE.000'] = string.char(129) .. fs['new/RESOURCE.000']:sub(2)
engine.get_resources('bad')
assert(get_info('bad').ver == 'sci1')
print('SCI synthetic format/map regressions passed')

-- Sound (type 4): SCI1 tracks per device, SCI0 channel masks, digital samples.
local function str(...) return string.char(...) end
function midi_create_raw(bytes) return {midi = bytes} end
function midi_create_sci(gm, adlib, patch, version, header) return {midi = gm, adlib = adlib, patch = patch, version = version} end
function sound_create_pcm(rate, bits, channels, signed, data) return {rate = rate, bits = bits, pcm = data} end
local sound_content = up(engine.load_resource, 'sci_sound_content')
local SMF_HEAD = 'MThd' .. str(0, 0, 0, 6, 0, 0, 0, 1, 0, 60) .. 'MTrk'
local function smf(events)
    local track = str(0, 255, 81, 3, 15, 66, 64) .. events
    return SMF_HEAD .. str(0, 0, 0, #track) .. track
end
-- SCI1: [F0 prio ... FF] header, one track of one channel; the channel header
-- (number, polyphony) sits at the entry's offset and the events follow it.
local function sci1(track_type, channel_number, body)
    local head = str(0xF0, 100, 0, 0, 0, 0, 0, 0xFF)
    local off = #head + 1 + 6 + 1 + 1
    local chan = str(channel_number, 1) .. body
    return head .. str(track_type) .. str(0, 0, off % 256, 0, #chan % 256, 0) .. str(0xFF, 0xFF) .. chan
end
local events1 = str(0, 0xC1, 5, 0, 0xB1, 7, 100, 0, 0x91, 60, 100, 0xF8, 10, 0x81, 60, 64, 0, 0xFC)
local c = sound_content(sci1(0x07, 1, events1), 'sci11')
assert(c.kind == 'midi', c.reason)
-- 250 ticks (F8 + 10) is VLQ 81 7A; the song ends on its last event.
assert(c.smf == smf(str(0, 0xC1, 5, 0, 0xB1, 7, 100, 0, 0x91, 60, 100, 0x81, 0x7A, 0x81, 60, 64, 0, 255, 47, 0)))
-- MT-32 tracks hold MT-32 instruments: 3 (Elec Piano 1) -> GM 4, but drums stay.
c = sound_content(sci1(0x0C, 1, str(0, 0xC1, 3, 0, 0xC9, 3, 0, 0xFC)), 'sci11')
assert(c.kind == 'midi' and c.smf:find(str(0, 0xC1, 4, 0, 0xC9, 3), 1, true), 'MT-32 instrument mapping')
-- Channel 15 program changes and driver controllers are not music; running status works.
c = sound_content(sci1(0x07, 1, str(0, 0xCF, 0x7F, 0, 0xB1, 0x60, 5, 0, 0x4B, 8, 0, 0x91, 60, 100, 4, 62, 90, 0, 0xFC)), 'sci1')
assert(c.kind == 'midi' and not c.smf:find(str(0xCF), 1, true) and not c.smf:find(str(0x60), 1, true))
-- the second note arrives by running status and is written out with its own status
assert(c.smf:find(str(0, 0x91, 60, 100, 4, 0x91, 62, 90, 0, 255, 47, 0), 1, true), 'running status expanded')
-- GM track beats MT-32 and AdLib; digital channels (FE) are skipped, not played
local both = str(0xF0, 100, 0, 0, 0, 0, 0, 0xFF)
local ev = str(0, 0x91, 60, 100, 0, 0xFC)
local function entry(off, size) return str(0, 0, off % 256, 0, size % 256, 0) end
local tail_off = #both + (1 + 6 + 1) * 3 + 1
local chan = str(1, 1) .. ev
local multi = both .. str(0x00) .. entry(tail_off, #chan) .. str(0xFF) .. str(0x0C) .. entry(tail_off, #chan)
    .. str(0xFF) .. str(0x07) .. entry(tail_off, #chan) .. str(0xFF, 0xFF) .. chan
assert(sound_content(multi, 'sci11').desc:find('General MIDI', 1, true))
-- digital sample: header u16 rate, u16 length, u16 loop start, u16 loop end
local pcm = str(128, 130, 140, 150)
local dchan = str(0xFE, 0) .. str(0x7C, 0x15, 4, 0, 0, 0, 4, 0) .. pcm
local d = sound_content(sci1(0x00, 0xFE, dchan:sub(3)), 'sci1')
assert(d.kind == 'sound' and d.rate == 5500 and d.pcm == pcm)
-- empty sounds have no tracks at all
local none = sound_content(str(0xF0, 50, 0, 0, 0, 0, 0, 0xFF, 0xFF) .. string.rep(str(0), 27), 'sci11')
assert(none.kind == 'none' and none.reason == 'empty sound')
-- SCI0: byte 0, 16 x (voices, device mask), then one stream for all channels
local head0 = str(0)
for ch = 0, 15 do head0 = head0 .. str(1, ch == 1 and 0x01 or ch == 2 and 0x02 or 0x04) end
local stream0 = str(0, 0x91, 60, 100, 0, 0x92, 62, 100, 5, 0x81, 60, 0, 0, 0xFC)
c = sound_content(head0 .. stream0, 'sci0')
assert(c.kind == 'midi' and c.desc:find('Roland', 1, true))
assert(c.smf:find(str(0x91, 60, 100), 1, true) and not c.smf:find(str(0x92), 1, true), 'only Roland channels')
-- no Roland channel: fall back to AdLib channels
head0 = str(0)
for ch = 0, 15 do head0 = head0 .. str(1, ch == 2 and 0x02 or ch == 1 and 0x04 or 0) end
c = sound_content(head0 .. stream0, 'sci0')
assert(c.desc:find('AdLib', 1, true) and c.smf:find(str(0x91, 60, 100), 1, true) and not c.smf:find(str(0x92), 1, true))
-- AdLib arrangement: the AdLib track (type 00) on the driver's device channels. SCI1 songs without
-- a rhythm bank use the highest free device channel; with one (5382-byte patch) channels 0-8.
local sci_adlib_song = up(sound_content, 'sci_adlib_song')
local channel_map = up(sci_adlib_song, 'sci_adlib_channel_map')
local adlib_events = str(0, 0xC1, 5, 0, 0xB1, 7, 100, 0, 0x91, 60, 100, 0xF8, 10, 0x81, 60, 64, 0, 0xFC)
c = sound_content(sci1(0x00, 1, adlib_events), 'sci11', {patch = string.rep(str(0), 2690)})
assert(c.adlib and c.adlib.version == 0 and c.adlib.header == '')
assert(c.adlib.smf:find(str(0xBF, 75, 1), 1, true), 'voice count sent on the device channel')
assert(c.adlib.smf:find(str(0xCF, 5), 1, true) and c.adlib.smf:find(str(0x9F, 60, 100), 1, true), 'events moved to device channel 15')
assert(c.adlib.smf:find(str(0x8F, 60, 64), 1, true))
c = sound_content(sci1(0x00, 1, adlib_events), 'sci11', {patch = string.rep(str(0), 5382)})
assert(c.adlib.smf:find(str(0xB8, 75, 1), 1, true) and c.adlib.smf:find(str(0x98, 60, 100), 1, true), 'rhythm bank: channels 0-8')
-- an unknown bank size, or no AdLib track, leaves OPL on the generic path
assert(sound_content(sci1(0x00, 1, adlib_events), 'sci11', {patch = 'short'}).adlib == nil)
assert(sound_content(sci1(0x07, 1, adlib_events), 'sci11', {patch = string.rep(str(0), 2690)}).adlib == nil)
-- driver channel map: nine voices; non-essential channels (priority > 0) are dropped when they do not fit,
-- the control channel is never mapped, the rhythm channel (flag 2) keeps its number
local entries = {}
for ch = 1, 9 do entries[#entries + 1] = {channel = ch, flags = 0, prio = 0, poly = 1} end
entries[#entries + 1] = {channel = 10, flags = 0, prio = 5, poly = 1}
entries[#entries + 1] = {channel = 15, flags = 0, prio = 0, poly = 1}
local chmap, voices = channel_map(entries, false)
assert(chmap[1] and chmap[9] and chmap[10] == nil and chmap[15] == nil, 'priority and control channel')
entries = {{channel = 9, flags = 2, prio = 0, poly = 1}, {channel = 3, flags = 0, prio = 0, poly = 2}}
chmap, voices = channel_map(entries, true)
assert(chmap[9] == 9 and chmap[3] == 8 and voices[3] == 2, 'rhythm channel stays on 9, others use 0-8')
-- SCI0 AdLib: header kept for the driver, only channels played by AdLib (0x04), no remapping
head0 = str(0)
for ch = 0, 15 do head0 = head0 .. str(1, ch == 1 and 0x04 or 0x01) end
c = sound_content(head0 .. stream0, 'sci0', {patch = string.rep(str(0), 2690)})
assert(c.adlib.version == 2 and #c.adlib.header == 0x21 and c.adlib.smf:find(str(0x91, 60, 100), 1, true))
assert(not c.adlib.smf:find(str(0x92), 1, true))
-- early SCI0: header is 0x11 bytes with one byte per channel (voices << 4 | device bits)
local early0 = str(0)
for ch = 0, 15 do early0 = early0 .. str(ch == 1 and 0x11 or 0x00) end
c = sound_content(early0 .. stream0, 'sci0', {patch = string.rep(str(0), 2690), early = true})
assert(c.kind == 'midi' and c.adlib.version == 1 and #c.adlib.header == 0x11 and c.smf:find(str(0x91, 60, 100), 1, true))
-- the tree lists sounds as MIDI / sample / text according to their content
do
    local songs = {sci1(0x07, 1, events1), sci1(0x00, 0xFE, dchan:sub(3)),
        str(0xF0, 50, 0, 0, 0, 0, 0, 0xFF, 0xFF) .. string.rep(str(0), 27)}
    local blocks, entries, offset = {}, {}, 0
    for i, song in ipairs(songs) do
        entries[#entries + 1] = {i, offset}
        local block = string.char(132) .. le16(i) .. le16(#song + 4) .. le16(#song) .. le16(0) .. song
        blocks[#blocks + 1] = block
        offset = offset + #block
    end
    fs['snd/RESOURCE.MAP'] = map({{4, entries}})
    fs['snd/RESOURCE.000'] = table.concat(blocks)
    assert(engine.detect('snd'))
    local group = engine.get_resources('snd')[1]
    assert(group.id == 'type_4' and #group.children == 3)
    assert(group.children[1].type == 'midi' and group.children[2].type == 'sound' and group.children[3].type == 'text')
    assert(engine.load_resource('snd', 'r_4_1').type == 'midi')
    assert(engine.load_resource('snd', 'r_4_2').sound.rate == 5500)
    assert(engine.load_resource('snd', 'r_4_3').text:find('empty sound', 1, true))
end
print('SCI synthetic sound regressions passed')

if not arg[1] then return end
function file_exists(p) local f = io.open(p, 'rb'); if f then f:close(); return true end; return false end
function file_open(p) return io.open(p, 'rb') end
function file_size(f) local pos = f:seek(); local n = f:seek('end'); f:seek('set', pos); return n end
function file_read(f, o, n) f:seek('set', o); return f:read(n) end
function file_close(f) f:close() end
local path, sample = arg[1], arg[2] == 'sample'
assert(engine.detect(path), 'Game not detected')
local tree = engine.get_resources(path)
local info = get_info(path)
local counts, failures, seen = {}, {}, {}
local read_header = up(read_resource, 'read_resource_header')
for _, r in ipairs(info.resources) do
    local id = 'r_' .. r.type .. '_' .. r.number
    local graphics = r.type == 0 or r.type == 1 or r.type == 7 or r.type == 8 or r.type == 11
    if not sample or (graphics and (seen[r.type] or 0) < 3) then
        seen[r.type] = (seen[r.type] or 0) + 1
        local ok, err = pcall(function()
            local d = assert(read_resource(path, info, r), 'Read failed')
            local vol = assert(file_open(path .. (info.resmap and '/RESSCI.000' or string.format('/RESOURCE.%03d', r.volume))))
            local h = assert(read_header(vol, info.ver, r.offset)); file_close(vol)
            assert(#d == h.unpacked, 'Decompressed size mismatch')
            if graphics then
                local result = engine.load_resource(path, id)
                assert(result and result.image, result and result.text or 'No image')
                counts[r.type] = (counts[r.type] or 0) + 1
            end
        end)
        if not ok then failures[#failures + 1] = id .. ': ' .. tostring(err) end
    end
end
-- every sound resolves to MIDI, a digital sample or an explained text; none may raise
local sounds = {midi = 0, sound = 0, text = 0}
local node_kinds = {}
for _, group in ipairs(tree) do
    if group.id == 'type_4' then for _, node in ipairs(group.children) do node_kinds[node.id] = node.type end end
end
for _, r in ipairs(info.resources) do
    if r.type == 4 and not sample then
        local id = 'r_4_' .. r.number
        local ok, result = pcall(engine.load_resource, path, id)
        if not ok then failures[#failures + 1] = id .. ': ' .. tostring(result)
        elseif result.type ~= node_kinds[id] then failures[#failures + 1] = id .. ': tree type ' .. tostring(node_kinds[id]) .. ' but loaded ' .. result.type
        else sounds[result.type] = (sounds[result.type] or 0) + 1 end
    end
end
print(string.format('Sounds: %d MIDI, %d samples, %d unsupported', sounds.midi, sounds.sound, sounds.text))
for _, t in ipairs({0, 1, 7, 8, 11}) do print('Type ' .. t .. ': ' .. (counts[t] or 0) .. ' previews') end
for _, err in ipairs(failures) do print(err) end
assert(#failures == 0, #failures .. ' resource failures')
print(path .. ': ' .. #info.resources .. ' resources, ' .. info.ver .. ', validation passed')

-- lua scripts/tests/darkseed.lua [game-folder ...]
-- Synthetic palette regressions plus optional complete floppy/CD data checks.
local engine = dofile('scripts/engines/darkseed/engine.lua')
local files, dirs = {}, {}
function file_exists(p) return files[p] ~= nil or dirs[p] ~= nil end
function list_files(p) return dirs[p] or {} end
function file_open(p) return files[p] end
function file_read(f, offset, length) return f:sub(offset + 1, offset + length) end
function file_size(f) return #f end
function file_close() end
function image_create_indexed(w, h, pixels, palette)
    assert(w > 0 and h > 0 and #pixels == w * h and #palette == 768)
    return {palette=palette, pixels=pixels}
end
function animation_create(frames) return frames end
local function add(dir, name, data)
    dirs[dir] = dirs[dir] or {}
    dirs[dir][#dirs[dir]+1] = name
    files[dir .. '/' .. name] = data
end
local function rom(pic)
    -- Deliberately misleading editor palette and sprite fields.
    return 'EDIT    .nsp\0' .. string.format('%-8s', pic) .. '.pic\0' .. 'CYBER   .pal\0'
end
local pic = string.char(0,1,0,1,0x01)
local nsp = string.char(1,1) .. string.rep('\0',190) .. string.char(0x10)
for _, cd in ipairs({false, true}) do
    local root = cd and '/cd' or '/floppy'
    local pd, rd = cd and root..'/Picture' or root, cd and root..'/room' or root
    dirs[root] = cd and {'Picture','room'} or {}
    add(root, 'TOS.EXE', '')
    for name, value in pairs({ROOM0=2,ROOM12=3,ROOM19=4,ROOM38=5,ROOM61=6,ROOM8=10,ROOM30=11,ROOM53=12,AA=7,CYBER=8,LAB=9}) do
        add(pd, name..'.PAL', string.rep(string.char(value),48))
    end
    for name, bg in pairs({ROOM0='BED1A',ROOM12='STREETC',ROOM19='STACKA',ROOM20='STACKB',ROOM22='STACKD',ROOM61A='ATTIC'}) do
        add(rd, name..'.ROM', rom(bg))
        add(pd, bg..'.PIC', pic)
    end
    for _, name in ipairs({'ROOM0','CPLAYER','GPLAYER','LABPARTS','ROOM61','OPENDRWR','MTHROW','CUPHIT'}) do add(rd,name..'.NSP',nsp) end
    assert(engine.detect(root))
    local function check(id, palette)
        assert(engine.default_palette(root,id) == 'pal_'..palette, id)
        local r = assert(engine.load_resource(root,id))
        assert(r.type == 'image', id .. ': ' .. tostring(r.text))
        assert(r.image.palette[1] == files[pd..'/'..palette..'.PAL']:byte(1)*4, id)
        local overridden = assert(engine.load_resource(root,id,'pal_CYBER'))
        assert(overridden.image.palette[1] == 32, 'override ignored: '..id)
    end
    check(cd and 'bg_BED1A' or 'bg_room0','ROOM0')
    check(cd and 'bg_STREETC' or 'bg_room12','ROOM12')
    check(cd and 'bg_STACKB' or 'bg_room20','ROOM19')
    check(cd and 'bg_STACKD' or 'bg_room22','ROOM19')
    check('nsp_ROOM0','ROOM0'); check('nsp_CPLAYER','ROOM0')
    check('nsp_GPLAYER','ROOM38'); check('nsp_LABPARTS','LAB'); check('nsp_ROOM61','ROOM61')
    check('nsp_OPENDRWR','ROOM8'); check('nsp_MTHROW','ROOM53'); check('nsp_CUPHIT','ROOM30')
    if not cd then check('bg_room61a','ROOM61') end
    assert(engine.default_palette(root,'pal_ROOM0') == nil)
    local sprites = 0
    for _, cat in ipairs(engine.get_resources(root)) do
        if cat.id == 'sprites' then sprites = #cat.children end
    end
    assert(sprites == 8, 'CD sprite directory discovery')
end
print('Dark Seed floppy/CD palette regressions passed')
if not arg[1] then return end

-- Read-only adapters for real game data, preserving exact filename case.
local listings = {}
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
function list_files(p)
    if not listings[p] then
        local pipe = assert(io.popen('ls -1 '..quote(p)..' 2>/dev/null'))
        local result = {}; for name in pipe:lines() do result[#result+1] = name end
        pipe:close(); listings[p] = result
    end
    return listings[p]
end
function file_exists(p)
    local dir, name = p:match('^(.*)/([^/]+)$')
    for _, entry in ipairs(list_files(dir)) do if entry == name then return true end end
    return false
end
function file_open(p) return io.open(p,'rb') end
function file_read(f, offset, length) assert(f:seek('set',offset)); return f:read(length) end
function file_size(f) return f:seek('end') end
function file_close(f) f:close() end
for _, root in ipairs(arg) do
    assert(engine.detect(root))
    local counts, seen = {}, {}
    for _, cat in ipairs(engine.get_resources(root)) do
        for _, node in ipairs(cat.children) do
            assert(not seen[node.id], 'Duplicate resource '..node.id); seen[node.id] = true
            local pal = engine.default_palette(root,node.id)
            if node.type ~= 'palette' then
                assert(pal and pal ~= 'pal_AA', 'Unmapped palette: '..node.id)
            end
            local auto = assert(engine.load_resource(root,node.id))
            local selected = assert(engine.load_resource(root,node.id,pal))
            assert(auto.type == 'image' or auto.type == 'animation', node.id..': '..tostring(auto.text))
            local a = auto.image or auto.animation[1]
            local b = selected.image or selected.animation[1]
            assert(table.concat(a.palette,',') == table.concat(b.palette,','), node.id)
            counts[node.type] = (counts[node.type] or 0)+1
        end
    end
    print(root..': '..counts.image..' backgrounds, '..counts.animation..' sprite sheets, '..counts.palette..' palettes verified')
end

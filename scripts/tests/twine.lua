-- lua scripts/tests/twine.lua [LBA parent] [category prefix, e.g. grids]
local engine=dofile('scripts/engines/twine/engine.lua');local d=engine._debug
assert(d.unpack(string.char(1,65,0,0),4,2)=='AAAA')
assert(d.unpack(string.char(7,65,66,67,0x21,0),6,1)=='ABCABC')
assert(not pcall(d.unpack,string.char(0,0,0),4,1))
assert(not pcall(d.unpack,string.char(1),1,1))
assert(d.text('Espa\164a')=='España')
assert(not pcall(d.sprite,string.char(1,1,0,0,1,0x81,9),0))
print('TwinE synthetic regressions passed')
if not arg[1] then return end
local function quote(s)return "'"..s:gsub("'","'\\''").."'" end
function list_files(p)
    local f=io.popen('ls -1 '..quote(p)..' 2>/dev/null');local a={}
    for s in f:lines() do a[#a+1]=s end;f:close();return a
end
function file_exists(p)local f=io.open(p,'rb');if f then f:close();return true end;return false end
function file_open(p)return io.open(p,'rb') end
function file_close(f)f:close() end
function file_size(f)local p=f:seek();local n=f:seek('end');f:seek('set',p);return n end
function file_read(f,o,n)f:seek('set',o);return f:read(n) or '' end
function image_create_indexed(w,h,px,pal)
    assert(w*h==#px and #pal==768)
    for _,v in ipairs(px) do assert(v>=0 and v<=255) end
    return true
end
function sound_create_encoded(s)
    assert(s:sub(1,19)=='Creative Voice File' or (s:sub(1,4)=='RIFF' and s:sub(9,12)=='WAVE'),'Invalid audio signature')
    return true
end
function model_decode_lba2(s,pal,atlas) assert(#s>=96 and #pal==768);assert(not atlas or #atlas==65536);return true end
function midi_create_auto(s)assert(s:sub(1,4)=='MThd' or s:sub(1,4)=='FORM');return true end
for _,game in ipairs({'LBA1','LBA2'}) do
    local path=arg[1]..'/'..game;assert(engine.detect(path))
    local counts={};local seen={};local failures={};local n=0
    local function walk(nodes)
        for _,node in ipairs(nodes) do if node.children then walk(node.children)
        else
            assert(not seen[node.id],'Duplicate '..node.id);seen[node.id]=true
            local cat=node.id:match('^[^:]+')
            if not arg[2] or cat:match('^'..arg[2]) then
                local r=assert(engine.load_resource(path,node.id),node.id)
                if r.description:find('decode diagnostic',1,true) then failures[#failures+1]=node.id..': '..r.text end
                assert(r.model or r.image or r.sound or r.midi or r.text,node.id)
                counts[cat]=(counts[cat] or 0)+1;n=n+1
                if n%1000==0 then collectgarbage() end
            end
        end end
    end
    walk(engine.get_resources(path))
    for k,v in pairs(counts) do print(game,k,v) end
    for _,f in ipairs(failures) do print(f) end
    assert(#failures==0,tostring(#failures)..' decode failures')
end

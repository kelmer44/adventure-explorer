-- lua scripts/tests/startrek.lua [TREK parent directory]
local engine=dofile('scripts/engines/startrek/engine.lua')
local d=engine._debug
assert(d.lzss(string.char(7,65,66,67,0x33,0),9)=='ABCABCABC')
assert(d.lzss(string.char(1,65,0x12,0),6)=='AAAAAA')
assert(d.lzss(string.char(0,0,0),3)==string.rep('\0',3))
assert(not pcall(d.lzss,string.char(0,0,0),2))
assert(not pcall(d.lzss,string.char(1),1))
assert(not pcall(d.bitmap,string.rep('\0',8)))
assert(d.text('Espa\241a')=='España')
print('Star Trek synthetic regressions passed')
if not arg[1] then return end
local function quote(s) return "'"..s:gsub("'","'\\''").."'" end
function list_files(path)
    local p=io.popen('ls -1 '..quote(path)..' 2>/dev/null');local out={}
    for name in p:lines() do out[#out+1]=name end;p:close();return out
end
function file_exists(path) local f=io.open(path,'rb');if f then f:close();return true end;return false end
function file_open(path) return io.open(path,'rb') end
function file_size(f) local p=f:seek();local n=f:seek('end');f:seek('set',p);return n end
function file_read(f,o,n) f:seek('set',o);return f:read(n) or '' end
function file_close(f) f:close() end
function image_create_indexed(w,h,px,pal,transparent)
    assert(#px==w*h);assert(#pal==768)
    for _,v in ipairs(px) do assert(v>=0 and v<256) end
    return {w=w,h=h}
end
function animation_create(frames,delay) assert(#frames>0);return true end
function sound_create_encoded(s) assert(s:sub(1,19)=='Creative Voice File');return true end
function midi_create_from_xmi(s) assert(s:sub(1,4)=='EVNT');return true end
for _,folder in ipairs({'STARTREK','RITES'}) do
    local path=arg[1]..'/'..folder;assert(engine.detect(path))
    local totals={};local count=0;local damaged={}
    local function scan(nodes)
        for _,node in ipairs(nodes) do
            if node.children then scan(node.children)
            else
                local ok,r=pcall(engine.load_resource,path,node.id)
                assert(ok,node.id..': '..tostring(r));assert(r,node.id)
                if r.description:find('damaged resource',1,true) then damaged[#damaged+1]=node.id
                elseif node.type=='image' or node.type=='palette' then assert(r.image,node.id)
                elseif node.type=='animation' then assert(r.animation,node.id)
                elseif node.type=='midi' then assert(r.midi,node.id)
                elseif node.type=='sound' then assert(r.sound,node.id)
                else assert(r.text,node.id) end
                totals[node.type]=(totals[node.type] or 0)+1;count=count+1
            end
        end
    end
    scan(engine.get_resources(path))
    print(folder..': '..count..' leaves decoded')
    for k,v in pairs(totals) do print('  '..k..': '..v) end
    print('  damaged records: '..table.concat(damaged,', '))
end

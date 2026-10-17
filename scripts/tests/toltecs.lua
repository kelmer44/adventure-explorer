-- lua scripts/tests/toltecs.lua [3SKULLS folder]
local engine=dofile('scripts/engines/toltecs/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local function le16(n) return string.char(n%256,math.floor(n/256)%256) end
local function le32(n) return le16(n%65536)..le16(math.floor(n/65536)) end
local rle=up(engine.load_resource,'rle')
local p=rle(string.char(1,130,2,3),1,4,6,1,0,true)
assert(table.concat(p,',')=='1,2,2,2,2,3')
assert(rle(string.char(59),1,1,1,1,224,true)[1]==27)
assert(not pcall(rle,string.char(130,9),1,2,5,1,0,true))
assert(not pcall(rle,string.char(130),1,1,5,1,0,true))
local delta=up(engine.load_resource,'delta')
local pixels={9,8,7,6};delta(string.char(0,2,2,0x21),1,4,pixels,4)
assert(table.concat(pixels,',')=='9,8,18,18')
assert(not pcall(delta,string.char(0,0),1,2,pixels,4))
assert(not pcall(delta,string.char(0,5),1,2,pixels,4))
local sprite=up(engine.load_resource,'sprite_pixels')
local frame={offset=0,w=3,h=1}
assert(table.concat(sprite(string.char(0x12,0x21),frame,2,16,true),',')=='1,1,2')
assert(table.concat(sprite(string.char(42,3),frame,2,256,true),',')=='42,42,42')
assert(table.concat(sprite(string.char(0x83),frame,1,1,true),',')=='255,255,255')
assert(not pcall(sprite,string.char(0x14),frame,1,16,true))
local anim=up(up(engine.load_resource,'catalog'),'animation_frames')
local fixture=string.rep('\0',774)..le32(2)..string.char(3,0x21)..le32(0)..string.char(2)
local frames=anim(fixture,3,1,2);assert(#frames==3 and frames[1]==frames[2] and frames[2]==frames[3])
assert(not pcall(anim,fixture:sub(1,-2),3,1,2))
local fs={}
function file_exists(path) return fs[path]~=nil end
function list_files(path) return path=='fixture' and {'SPANISH.PDI'} or {} end
function file_open(path) return fs[path] end
function file_size(s) return #s end
function file_close() end
function file_read(s,o,n) return s:sub(o+1,o+n) end
-- Terminal non-offset directory word; last resource is still accessible.
fs['fixture/SPANISH.PDI/WESTERN']=le32(12)..le32(15)..le32(1)..'abc'..'def'
assert(engine.detect('fixture'));assert(not engine.detect('missing'))
local tree=engine.get_resources('fixture');assert(#tree==8)
assert(engine.load_resource('fixture','toltecs/1').text:match('64 65 66'))
assert(up(engine.load_resource,'read')('missing',0,0)=='')
fs['bad/WESTERN']=le32(12)..le32(999)..le32(1)..'abc'
assert(not engine.detect('bad'))
print('Toltecs RLE, deltas, sprite modes, holds, directory and detection regressions passed')
if not arg[1] then return end
function file_open(path) return io.open(path,'rb') end
function file_exists(path) local f=io.open(path,'rb');if not f then return false end;f:close();return true end
function file_size(f) return f:seek('end') end
function file_read(f,o,n) assert(f:seek('set',o));return f:read(n) end
function file_close(f) f:close() end
function list_files() return {'ESPA_OL.PDI'} end
local counts,seen={},{}
function image_create_indexed(w,h,p,pal)
    assert(w*h==#p and #pal==768)
    for i=1,#p do assert(p[i]>=0 and p[i]<=255) end
    for i=1,#pal do assert(pal[i]>=0 and pal[i]<=255) end
    return 1
end
function sound_create_pcm(rate,bits,channels,signed,pcm)
    assert(rate==22050 and bits==8 and channels==1 and not signed and #pcm>0);return 1
end
function midi_create_auto(s) assert(s:sub(1,4)=='FORM' or s:sub(1,4)=='MThd');return 1 end
function animation_create(frames,delay) assert(#frames>=1 and delay==100);return 1 end
assert(engine.detect(arg[1]))
local loaded=0
local function walk(nodes)
    for _,n in ipairs(nodes) do
        assert(not seen[n.id],n.id);seen[n.id]=true
        if n.children then walk(n.children)
        else
            local ok,result=pcall(engine.load_resource,arg[1],n.id)
            assert(ok,n.id..': '..tostring(result));assert(result and result.type)
            counts[n.type]=(counts[n.type] or 0)+1;loaded=loaded+1
            if loaded%2000==0 then print('Loaded '..loaded) end
        end
    end
end
walk(engine.get_resources(arg[1]))
for k,v in pairs(counts) do print(k..': '..v) end
print('Loaded all '..loaded..' resources successfully')

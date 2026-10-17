-- lua scripts/tests/amazon.lua [AMAZON folder]
local engine=dofile('scripts/engines/amazon/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local function le16(n) return string.char(n%256,math.floor(n/256)%256) end
local function le32(n) return le16(n%65536)..le16(math.floor(n/65536)) end
local catalog=up(engine.get_resources,'catalog')
local decode=up(catalog,'dbe')
local function packed(codes,size)
    local out,acc,bits={},0,0
    for _,v in ipairs(codes) do
        acc=acc+v*2^bits;bits=bits+9
        while bits>=8 do out[#out+1]=string.char(acc%256);acc=math.floor(acc/256);bits=bits-8 end
    end
    if bits>0 then out[#out+1]=string.char(acc) end
    return 'DBE\1'..le32(size)..string.rep('\0',8)..table.concat(out)
end
local compressed=packed({256,65,66,258,257},4)
assert(decode(compressed)=='ABAB')
assert(decode(packed({256,65,258,257},3))=='AAA')
assert(not pcall(decode,compressed:sub(1,-3)))
assert(not pcall(decode,packed({256,65,300,257},4)))
assert(not pcall(decode,packed({256,65,257},2)))
assert(not pcall(decode,'DBE'))
local offsets=up(catalog,'offsets')
assert(not offsets(le16(2)..le32(10)..le32(999)))
assert(not offsets(le16(2)..le32(11)..le32(10)..'x'))
local sprite=up(engine.load_resource,'sprite')
local frame=le16(4)..le16(2)..string.char(1,2,7,8,0,1,9)
local p,w,h=sprite(frame..'padding',1,#frame+7,true)
assert(w==4 and h==2 and table.concat(p,',')=='0,7,8,0,9,0,0,0')
assert(not pcall(sprite,frame:sub(1,-2),1,#frame-1,true))
assert(not pcall(sprite,le16(2)..le16(1)..string.char(1,2,7,8),1,8,true))
local delta=up(engine.load_resource,'video_delta')
local pixels={1,2,3,4};delta(string.char(0x82,2,9,8),1,4,pixels,4)
assert(table.concat(pixels,',')=='1,2,9,8')
assert(not pcall(delta,string.char(0x85),1,1,pixels,4))
assert(not pcall(delta,string.char(2,9),1,2,pixels,4))
local video=up(up(catalog,'classify'),'video')
local movie=le16(3)..le16(2)..le16(1)..le16(0)..le16(3)..string.char(2,6,7)..le16(1)..string.char(0x82)
local v=video(movie);assert(v and #v.frames==2)
assert(not video(movie:sub(1,-2)))
local fs={['fixture/AMAZON.EXE']='', ['fixture/C00.AP']=le16(1)..le32(6)..compressed,
    ['fixture/S00.AP']=le16(1)..le32(6)..'text'}
function file_exists(path) return fs[path]~=nil end
function file_open(path) return fs[path] end
function file_read(s,o,n) return s:sub(o+1,o+n) end
function file_size(s) return #s end
function file_close() end
function list_files() return {'AMAZON.EXE','C00.AP','S00.AP'} end
assert(engine.detect('fixture') and not engine.detect('missing'))
assert(#engine.get_resources('fixture')==3)
assert(engine.load_resource('fixture','amazon/C00.AP/0').text:match('ABAB'))
print('Amazon DBE, AP directories, padded sprites, video deltas and detection regressions passed')
if not arg[1] then return end
function file_open(path) return io.open(path,'rb') end
function file_exists(path) local f=io.open(path,'rb');if not f then return false end;f:close();return true end
function file_read(f,o,n) assert(f:seek('set',o));return f:read(n) end
function file_size(f) return f:seek('end') end
function file_close(f) f:close() end
function list_files(path)
    local quoted="'"..path:gsub("'", "'\\''").."'"
    local names={};local f=assert(io.popen('ls -1 '..quoted))
    for name in f:lines() do names[#names+1]=name end;f:close();return names
end
function image_create_indexed(w,h,p,pal)
    assert(#p==w*h and #pal==768)
    for i=1,#p do assert(p[i]>=0 and p[i]<=255) end
    for i=1,#pal do assert(pal[i]>=0 and pal[i]<=255) end
    return 1
end
function animation_create(frames,delay) assert(#frames>0 and delay==100);return 1 end
function sound_create_pcm(rate,bits,channels,signed,data)
    assert(rate>0 and bits==8 and channels==1 and signed and #data>0);return 1
end
function midi_create_auto(s) assert(s:sub(1,4)=='MThd' or s:sub(1,4)=='FORM');return 1 end
assert(engine.detect(arg[1]))
local counts,seen,loaded={},{},0
local function walk(nodes)
    for _,n in ipairs(nodes) do
        assert(not seen[n.id],n.id);seen[n.id]=true
        if n.children then walk(n.children)
        else
            local ok,result=pcall(engine.load_resource,arg[1],n.id)
            assert(ok,n.id..': '..tostring(result));assert(result and result.type)
            counts[n.type]=(counts[n.type] or 0)+1;loaded=loaded+1
            if loaded%1000==0 then print('Loaded '..loaded) end
        end
    end
end
walk(engine.get_resources(arg[1]))
for k,v in pairs(counts) do print(k..': '..v) end
local banks={};for _,e in ipairs(catalog(arg[1]).entries) do banks[e.kind]=(banks[e.kind] or 0)+1 end
for k,v in pairs(banks) do print('Banks '..k..': '..v) end
print('Loaded all '..loaded..' resources successfully')

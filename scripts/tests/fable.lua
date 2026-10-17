-- lua scripts/tests/fable.lua [game folder] [catalog|all|image|animation|sound|text|palette|data]
local engine=dofile('scripts/engines/fable/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local function le16(n) return string.char(n%256,math.floor(n/256)%256) end
local function le32(n) return le16(n%65536)..le16(math.floor(n/65536)) end
local function reject(fn,...) assert(not pcall(fn,...),'Expected malformed resource rejection') end
local pixels=up(engine.load_resource,'pixels')
local s=le16(2)..le16(3)..le16(4)..le16(2)..'\129\2\7\8\0\4\1\2\3\4\0'
local w,h,p,x,y=pixels(s,{offset=0,size=#s})
assert(w==4 and h==2 and x==2 and y==3 and table.concat(p,',')=='0,7,8,0,1,2,3,4')
reject(pixels,s:sub(1,-2),{offset=0,size=#s-1})
reject(pixels,le16(0)..le16(0)..le16(4)..le16(1)..'\133\0',{offset=0,size=10})
local raw=le16(0)..le16(0)..le16(2)..le16(1)..'\128\255'
local _,_,rp=pixels(raw,{offset=0,size=#raw});assert(rp[1]==128 and rp[2]==255)
-- This RLE stream occupies exactly w*h bytes and must not decode as raw.
local equal=le16(0)..le16(0)..le16(4)..le16(1)..'\2\7\8\0'
local _,_,ep=pixels(equal,{offset=0,size=#equal});assert(table.concat(ep,',')=='7,8,0,0')
local patch=up(engine.load_resource,'frame_palette')
local base={};for i=1,768 do base[i]=0 end
local patched=patch(le32(4)..le16(96)..le16(1)..'\63\1\0',{paletteOffset=0},base)
assert(patched[289]==252 and patched[290]==4 and base[289]==0)
reject(patch,le32(4)..le16(255)..le16(2)..string.rep('\0',6),{paletteOffset=0},base)
local sprites=up(up(engine.get_resources,'index'),'sprites')
local spr='SPR\0'..le32(20)..le32(36)..le32(0)..le32(36)..le16(1)..le32(26)..raw
local fs=sprites(spr,#spr);assert(#fs==1 and fs[1].offset==26 and fs[1].size==10)
reject(sprites,spr:sub(1,-2),#spr-2)
local text=up(engine.load_resource,'text')
local txt='TXT\0'..le32(12)..le32(20)..le16(2)..'\5caf\130$'..le16(2)..'tree\0'
local decoded=text(txt);assert(decoded:find('café',1,true) and decoded:find('tree',1,true))
assert(text('TXT\0'..le32(12)..le32(0)..le16(2)..'\1Hi$'):find('Hi',1,true))
reject(text,'TXT\0'..le32(12)..le32(100))
local directory=up(engine.detect,'directory')
local memory='ARC1'..le16(1)..'TEST.RAW'..string.rep('\0',6)..le32(28)..le32(2)..'XY'
function file_open() return true end
function file_read(_,o,n) return memory:sub(o+1,o+n) end
function file_close() end
function file_size() return #memory end
assert(directory('fixture')[1].size==2)
memory=memory:sub(1,-2);reject(directory,'fixture')
local wav=up(engine.load_resource,'wav')
function sound_create_pcm(rate,bits,ch,signed,s)
    assert(rate>0 and (bits==8 or bits==16) and (ch==1 or ch==2) and signed==(bits==16))
    assert(#s>0 and #s%(bits/8*ch)==0);return 1
end
local fmt=le16(1)..le16(1)..le32(22050)..le32(22050)..le16(1)..le16(8)
local wave='WAVEfmt '..le32(16)..fmt..'data'..le32(2)..'\128\129'
assert(wav('RIFF'..le32(#wave)..wave)==1)
reject(wav,'RIFF'..le32(#wave+1)..wave)
print('Fable ARC1, raw/RLE SPR, TXT and PCM regressions passed')
if not arg[1] then return end
local function quote(s) return "'"..s:gsub("'","'\\''").."'" end
function file_open(p) return io.open(p,'rb') end
function file_exists(p) local f=file_open(p);if f then f:close();return true end;return false end
function file_size(f) return assert(f:seek('end')) end
function file_read(f,o,n) assert(f:seek('set',o));return f:read(n) or '' end
function file_close(f) f:close() end
function list_files(p)
    local f=assert(io.popen('ls -1 '..quote(p)..' 2>/dev/null'));local out={};for n in f:lines() do out[#out+1]=n end;f:close();return out
end
function image_create_indexed(w,h,p,pal)
    assert(w>0 and h>0 and #p==w*h and #pal==768)
    for _,v in ipairs(p) do assert(v>=0 and v<=255 and v%1==0) end
    for _,v in ipairs(pal) do assert(v>=0 and v<=255) end
    return 1
end
function animation_create(frames,delay) assert(#frames>0 and #frames<=60 and delay==100);return 1 end
assert(engine.detect(arg[1]));assert(not engine.detect('/tmp'))
local ids,counts,loaded,errors={},{},{},{}
local checked=0
local function walk(nodes)
    for _,n in ipairs(nodes) do
        assert(not ids[n.id],'Duplicate ID '..n.id);ids[n.id]=true
        if n.children then walk(n.children) else
            counts[n.type]=(counts[n.type] or 0)+1
            if arg[2]~='catalog' and (not arg[2] or arg[2]=='all' or arg[2]==n.type) then
                local ok,r=pcall(engine.load_resource,arg[1],n.id)
                if not ok or not r then errors[#errors+1]=n.id..': '..tostring(r)
                else loaded[n.type]=(loaded[n.type] or 0)+1 end
                checked=checked+1
                if checked%1000==0 then print('Checked '..checked..' resources');io.stdout:flush() end
                collectgarbage('collect')
            end
        end
    end
end
walk(engine.get_resources(arg[1]))
for k,v in pairs(counts) do print(k..': '..v..' ('..(loaded[k] or 0)..' loaded)') end
for _,e in ipairs(errors) do print('ERROR '..e) end
assert(#errors==0,#errors..' decode failures')
print('Fable real-data checks passed')

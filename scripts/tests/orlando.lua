-- lua scripts/tests/orlando.lua [game folder] [catalog|all|image|animation|sound|text|palette]
local engine=dofile('scripts/engines/orlando/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local function le16(n) return string.char(n%256,math.floor(n/256)%256) end
local function le32(n) return le16(n%65536)..le16(math.floor(n/65536)) end
local function reject(fn,...) assert(not pcall(fn,...),'Expected rejection') end
local packed=up(engine.load_resource,'packed');local bitmap=up(engine.load_resource,'bitmap')
local palette=le16(0)..le16(0xf800)..string.rep('\0',252)
local w,h,p,pal=packed(le16(3)..le16(1)..palette..'\3\3')
assert(w==3 and h==1 and #p==3 and p[3]==1 and pal[4]==255 and pal[5]==0)
reject(packed,le16(2)..le16(1)..palette..'\3\3')
reject(packed,le16(2)..le16(1)..palette..'\3')
reject(packed,le16(2)..le16(1)..palette..'\3\0')
local _,_,rgb=bitmap(le16(3)..le16(1)..le16(0xf800)..le16(0x07e0)..le16(0x001f))
assert(table.concat(rgb,',')=='255,0,0,0,255,0,0,0,255')
reject(bitmap,le16(3)..le16(1)..le16(0))
assert(up(engine.load_resource,'text')(string.char(171,190,179,195,169,249,252),true)=='[HSC]\r\n')
function image_create_indexed(w,h,p,pal)
    assert(w>0 and h>0 and #p==w*h and #pal==768)
    for _,v in ipairs(p) do assert(v>=0 and v<=255 and v%1==0) end
    return {w=w,h=h,p=p,pal=pal}
end
function image_create_rgb(w,h,p) assert(#p==w*h*3);return {w=w,h=h,p=p} end
function animation_create(frames,delay) assert(#frames>0 and delay>0);return frames end
function sound_create_pcm(rate,bits,ch,signed,s) assert(rate>0 and #s>0 and #s%(bits/8*ch)==0);return s end
local flx=up(engine.load_resource,'flx')
local function chunk(k,s) return le16(k)..le32(#s+6)..s end
local f='FLX\0'..le16(2)..le16(2)..le16(1)..le16(10)..string.rep('\0',8)
f=f..chunk(4,le16(0)..le16(0xf800)..string.rep('\0',508))..chunk(0,'\0\2\1\1')..chunk(1,le32(1)..'\0\1\0')
local frames,delay,total=flx(f)
assert(#frames==2 and delay==100 and total==2 and frames[2].p[1]==1 and frames[2].p[2]==1)
reject(flx,f:sub(1,-2))
-- Archive offsets must stay within their parent, including nested archives.
local directory=up(engine.detect,'directory')
local memory=le32(25)..le32(25)..le32(2)..'A.BM'..string.rep('\0',9)..'XY'
function file_open() return true end
function file_read(_,o,n) return memory:sub(o+1,o+n) end
function file_close() end
local es=directory({path='fixture',offset=0,size=#memory,name='fixture'})
assert(#es==1 and es[1].offset==25 and es[1].size==2 and es[1].name=='A.BM')
reject(directory,{path='fixture',offset=0,size=26,name='fixture'})
local wav=up(engine.load_resource,'wav')
local fmt=le16(1)..le16(1)..le32(11025)..le32(11025)..le16(1)..le16(8)
local wave='WAVEfmt '..le32(16)..fmt..'data'..le32(2)..'\128\129'
assert(wav('RIFF'..le32(#wave)..wave)=='\128\129')
reject(wav,'RIFF'..le32(#wave+1)..wave)
print('Orlando RGB565, packed RLE, script transform and FLX regressions passed')
if not arg[1] then return end
local function quote(s) return "'"..s:gsub("'","'\\''").."'" end
function file_open(p)
    local f=io.open(p,'rb');if not f then return end
    local _,err=f:read(1);if err then f:close();return end
    f:seek('set',0);return f
end
function file_exists(p) local f=file_open(p);if f then f:close();return true end;return false end
function file_size(f) return assert(f:seek('end')) end
function file_read(f,o,n) assert(f:seek('set',o));return f:read(n) or '' end
function file_close(f) f:close() end
function list_files(p)
    local f=assert(io.popen('ls -1 '..quote(p)..' 2>/dev/null'));local out={};for n in f:lines() do out[#out+1]=n end;f:close();return out
end
assert(engine.detect(arg[1]));assert(not engine.detect('/tmp'))
local tree=engine.get_resources(arg[1]);local ids,counts,loaded,errors={},{},{},{}
local checked=0
local function walk(nodes)
    for _,n in ipairs(nodes) do
        assert(not ids[n.id],'Duplicate ID '..n.id);ids[n.id]=true
        if n.children then walk(n.children) else
            counts[n.type]=(counts[n.type] or 0)+1
            if arg[2]~='catalog' and (not arg[2] or arg[2]=='all' or arg[2]==n.type) then
                local ok,r=pcall(engine.load_resource,arg[1],n.id)
                if not ok or not r then errors[#errors+1]=n.id..' '..n.name..': '..tostring(r)
                else loaded[n.type]=(loaded[n.type] or 0)+1 end
                checked=checked+1
                if checked%1000==0 then print('Checked '..checked..' resources');io.stdout:flush() end
                collectgarbage('collect')
            end
        end
    end
end
walk(tree)
for k,v in pairs(counts) do print(k..': '..v..' ('..(loaded[k] or 0)..' loaded)') end
for _,e in ipairs(errors) do print('ERROR '..e) end
assert(#errors==0,#errors..' decode failures')
print('Orlando real-data checks passed')

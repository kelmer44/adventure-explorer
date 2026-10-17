-- lua scripts/tests/alcachofa.lua [prepared game folder] [catalog|audio|visual|all]
local engine=dofile('scripts/engines/alcachofa/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local bank=up(engine.get_resources,'bank')
local tga=up(bank,'tga')
local decrypt=up(engine.load_resource,'decrypt')
local audio=up(engine.load_resource,'audio')
local ima=up(audio,'ima')
local function le16(n) return string.char(n%256,math.floor(n/256)%256) end
local function le32(n) return le16(n%65536)..le16(math.floor(n/65536)) end
local function rejects(fn,...) assert(not pcall(fn,...),'Expected malformed data to be rejected') end
local hdr='\0\0\10'..string.rep('\0',9)..le16(1)..le16(1)..'\32\40'
local t=hdr..'\128\1\2\3\255'..string.rep('\0',8)..'TRUEVISION-XFILE.\0'
local im=tga(t,1);assert(im.w==1 and im.h==1)
rejects(tga,t:sub(1,-2),1)
rejects(tga,hdr..'\129\1\2\3\255'..string.rep('\0',8)..'TRUEVISION-XFILE.\0',1)
rejects(bank,le32(257)..le32(1));rejects(bank,le32(1)..le32(1)..t)
assert(ima(le16(0)..'\0\0\x11\x11\x11\x11',8,1)==le16(0)..le16(1)..le16(2)..le16(3)..le16(4)..le16(5)..le16(6)..le16(7)..le16(8))
rejects(ima,le16(0)..'\89\0',4,1)
local sounds,images=0,0
function sound_create_pcm(rate,bits,ch,signed,data)
    assert(rate>0 and #data%(bits/8*ch)==0);sounds=sounds+1;return data
end
local pcm=audio(le32(16)..le16(1)..le16(1)..le32(22050)..le32(22050)..le16(1)..le16(8)..le32(2)..'\128\128',true)
assert(pcm.sound=='\128\128')
rejects(audio,'bad',true)
function image_create_rgb(w,h,p)
    assert(#p==w*h*3);for _,v in ipairs(p) do assert(v>=0 and v<=255) end
    images=images+1;return {w=w,h=h,p=p}
end
function animation_create(handles,delay) assert(#handles>1 and delay>0);return handles end
local render=up(engine.load_resource,'render')
local b={w=1,h=1,x=0,y=0,images={im},offsets={{0,0}}}
local rgb=render(t,b,{images={1}});assert(rgb.p[1]==3 and rgb.p[2]==2 and rgb.p[3]==1)
assert(decrypt(string.rep('A',32)..'\0JUNK'..'hello')==string.rep('A',32)..'hello')
rejects(decrypt,'short')
print('Alcachofa malformed data, TGA color, and ADPCM predictor regressions passed')
if not arg[1] then return end
function file_open(p) return io.open(p,'rb') end
function file_read(f,o,n) assert(f:seek('set',o));return f:read(n) or '' end
function file_size(f) return assert(f:seek('end')) end
function file_close(f) f:close() end
function file_exists(p)
    local parent,name=p:match('^(.*)/([^/]*)$');for _,n in ipairs(list_files(parent)) do if n:lower()==name:lower() then return true end end;return false
end
function list_files(p)
    local f=assert(io.popen("ls -1 '"..p:gsub("'","'\\''").."'"));local out={};for n in f:lines() do out[#out+1]=n end;f:close();return out
end
assert(engine.detect(arg[1]));local tree=engine.get_resources(arg[1]);local cache=up(engine.load_resource,'cache')
local ids,counts={},{};local errors=0
local function walk(nodes)
 for _,n in ipairs(nodes) do
    assert(not ids[n.id],n.id);ids[n.id]=true
    if n.children then walk(n.children) else
        counts[n.type]=(counts[n.type] or 0)+1
        local e=cache.entries[n.id];assert(not e.error,n.id..': '..tostring(e.error))
        if arg[2]~='catalog' and (arg[2]=='all' or (arg[2]=='audio' and e.sound) or (arg[2]=='visual' and e.bank and e.first==1) or not counts['loaded_'..n.type]) then
            local last=e.last
            if arg[2]=='visual' and e.bank then e.last=e.first end
            assert(engine.load_resource(arg[1],n.id),n.id);e.last=last;counts['loaded_'..n.type]=(counts['loaded_'..n.type] or 0)+1
            collectgarbage('collect')
        end
    end
 end
end
walk(tree)
for k,v in pairs(counts) do print(k..': '..v) end
print('Alcachofa real-data catalog and resource checks passed')

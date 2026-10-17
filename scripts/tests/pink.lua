-- lua scripts/tests/pink.lua [game folder] [maximum leaves; default all] [start resource ID]
local engine=dofile('scripts/engines/pink/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local function le16(n) return string.char(n%256,math.floor(n/256)%256) end
local function le32(n) return le16(n%65536)..le16(math.floor(n/65536)) end
local function chunk(kind,s) return le32(#s+6)..le16(kind)..s end
local function frame(chunks) local s=table.concat(chunks);return le32(#s+16)..le16(0xf1fa)..le16(#chunks)..string.rep('\0',8)..s end
local function cel(frames,w,h)
    return le32(128+#table.concat(frames))..le16(0xaf12)..le16(#frames)..le16(w)..le16(h)..le16(8)..le16(0)..le32(75)..string.rep('\0',60)..le32(128)..string.rep('\0',44)..table.concat(frames)
end
local images={}
function image_create_indexed(w,h,p,pal)
    assert(#p==w*h and #pal==768);local copy={}
    for i=1,#p do assert(p[i]>=0 and p[i]<=255);copy[i]=p[i] end
    images[#images+1]={pixels=copy,w=w,h=h,pal={pal[1],pal[2],pal[3]}}
    return #images
end
function animation_create(frames,delay) assert(#frames>1 and delay>0);return 1 end
function sound_create_pcm(rate,bits,channels,signed,pcm) assert(rate>0 and #pcm%(bits/8*channels)==0 and signed==(bits==16));return 1 end
function log_warn(s) print('WARNING: '..s) end
local decode=up(engine.load_resource,'decode_cel')
local palette=chunk(4,le16(1)..'\0\1'..string.char(12,34,56))
local s=cel({frame({palette,chunk(16,string.char(1,2,3,4,5))}),
    frame({chunk(7,le16(1)..le16(0x8009)..le16(1)..'\0\255\7\8')})},5,1)
local handles,delay=decode(s);assert(#handles==2 and delay==75)
assert(table.concat(images[1].pixels,',')=='1,2,3,4,5')
assert(table.concat(images[2].pixels,',')=='7,8,3,4,9')
assert(images[1].pal[2]==34)
images={};decode(s,2,2);assert(#images==1 and images[1].pixels[5]==9)
local raw=cel({frame({chunk(16,string.char(1,2,3,4,5,6))})},6,1)
raw=raw:sub(1,144)..le32(10)..raw:sub(149)
images={};decode(raw);assert(images[1].pixels[6]==6)
local oddraw=cel({frame({chunk(16,string.char(1,2,3,4,5,0))})},5,1)
oddraw=oddraw:sub(1,144)..le32(10)..oddraw:sub(149)
images={};decode(oddraw);assert(images[1].pixels[5]==5)
local brun=cel({frame({chunk(15,'\0\2\5\253\1\2\3')})},5,1)
images={};decode(brun);assert(table.concat(images[1].pixels,',')=='5,5,1,2,3')
assert(not pcall(decode,s:sub(1,-2)))
-- Stale frame sizes in original media must not override valid chunk boundaries.
local stale=s:sub(1,128)..le32(16)..s:sub(133)
assert(pcall(decode,stale))
assert(not pcall(decode,cel({frame({chunk(15,'\0\6\1')})},5,1)))
assert(not pcall(decode,cel({frame({chunk(7,le16(1)..le16(0xffff)..le16(0))})},5,1)))
local wav=up(engine.load_resource,'wav')
local wave='WAVEfmt '..le32(16)..le16(1)..le16(1)..le32(22050)..le32(22050)..le16(1)..le16(8)..'JUNK'..le32(1)..'x\0'..'data'..le32(2)..'\128\128'
assert(wav('RIFF'..le32(#wave)..wave));
local odd=wave:sub(1,-3)..'x'..'cue '..le32(0)
odd=odd:gsub('data'..le32(2),'data'..le32(1),1)
assert(wav('RIFF'..le32(#odd)..odd));assert(not pcall(wav,'RIFF'..le32(#wave)..wave:sub(1,-2)))
-- In-memory ORB/BRO fixture tests directory offsets and external resource routing.
local function pad(s,n) return s..string.rep('\0',n-#s) end
local resource=pad('HELLO.TXT',16)..le32(20)..le32(4)..le16(1)
local object=pad('Room',16)..le32(0)..le32(0)..le32(52)..le32(1)
local orb='ORB\0'..le16(0)..le16(2)..le32(123)..le32(20)..le32(1)..object..resource
local bro=pad('BRO\0'..le16(0)..le16(1)..le32(123),20)..'caf'..string.char(233)
local fs={['fixture/PPTP.ORB']=orb,['fixture/INSTALL/PPTP.BRO']=bro}
function file_open(p) return fs[p] end
function file_read(s,o,n) return s:sub(o+1,o+n) end
function file_size(s) return #s end
function file_close() end
assert(engine.detect('fixture'))
local tree=engine.get_resources('fixture');assert(tree[1].children[1].name=='Room')
assert(engine.load_resource('fixture','PPTP/0/0').text=='caf'..string.char(195,169))
engine.get_resources('empty');fs['fixture/INSTALL/PPTP.BRO']=nil
assert(engine.load_resource('fixture','PPTP/0/0').text:match('Missing or mismatched'))
engine.get_resources('empty');fs['fixture/INSTALL/PPTP.BRO']=bro:sub(1,8)..le32(124)..bro:sub(13)
assert(engine.load_resource('fixture','PPTP/0/0').text:match('Missing or mismatched'))
engine.get_resources('empty');fs['fixture/PPTP.ORB']=orb:sub(1,16)..le32(1000)..orb:sub(21)
assert(not pcall(engine.get_resources,'fixture'))
print('Pink CEL codecs, malformed input, PCM WAV and ORB/BRO routing regressions passed')
if not arg[1] then return end
function file_open(p) return io.open(p,'rb') end
function file_read(f,o,n) assert(f:seek('set',o));return f:read(n) end
function file_close(f) f:close() end
function file_size(f) return f:seek('end') end
assert(engine.detect(arg[1]));assert(not engine.detect('/nonexistent'))
local counts,ids,loaded={}, {},0
local max=tonumber(arg[2]) or math.huge
local started=not arg[3]
-- Do not retain the decoded game images during a whole-archive sweep.
function image_create_indexed(w,h,p,pal) assert(#p==w*h and #pal==768);return 1 end
local function walk(nodes)
    for _,n in ipairs(nodes) do
        assert(not ids[n.id],'Duplicate '..n.id);ids[n.id]=true
        if n.children then walk(n.children)
        else
            counts[n.type]=(counts[n.type] or 0)+1
            if n.id==arg[3] then started=true end
            if started and loaded<max then assert(engine.load_resource(arg[1],n.id),'Failed '..n.id);loaded=loaded+1;if loaded%1000==0 then print('Loaded '..loaded) end end
        end
    end
end
walk(engine.get_resources(arg[1]))
for k,v in pairs(counts) do print(k..': '..v) end
print('Loaded '..loaded..' resources successfully')

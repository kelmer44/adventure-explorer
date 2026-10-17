-- lua scripts/tests/tesoro.lua [TESORO directory]
local engine=dofile('scripts/engines/tesoro/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local function le16(n) return string.char(n%256,math.floor(n/256)%256) end
local function le32(n) return le16(n%65536)..le16(math.floor(n/65536)) end
local decode=up(engine.load_resource,'decode_image')
local banks=up(engine.load_resource,'banks')
local parse_index=up(up(engine.get_resources,'catalog'),'parse_index')
local im={base=1,size=52,width=5,height=1,kind=1}
-- Two spans, with skip relative to the END of the previous span.
local s=le32(40)..le32(12)..le16(5)..le16(1)..le16(1)..le16(0)
    ..le32(24)..le16(2)..le16(0)
    ..le32(40)..le16(1)..le16(1)..le32(42)..le16(1)..le16(1)
    ..le16(0xf800)..le16(0x07e0)..string.rep('\0',8)
local px=assert(decode(s,im));assert(#px==15 and px[4]==255 and px[11]==255 and px[7]==0)
assert(not decode(s:sub(1,-2),im))
assert(not decode(s:sub(1,30)..le16(10)..s:sub(33),im))
local solid=s:sub(1,24)..le32(0x001f)..s:sub(29);im.kind=3
px=assert(decode(solid,im));assert(px[6]==255)
im.kind=2;px=assert(decode(solid,im));assert(px[4]==255 and px[5]==255)
-- Standalone ANM: magic, 24-byte header, 24-byte frame + one extra byte,
-- size-prefixed image. No magic scanning through arbitrary pixel data.
im.kind=1
local bank='ANM\1'..le32(1)..le32(1)..string.rep('\0',16)..string.rep('\0',22)..le16(1)..'x'..le32(#s)..s
local bs,finish=banks(bank);assert(bs and #bs==1 and finish==#bank+1 and bs[1].images[1].width==5)
assert(banks('ANM\0'..bank:sub(5)))
assert(not banks(bank:sub(1,-2)));assert(not banks('LVL\1'..le32(0)..le32(2)..le32(0)..bank))
local rec=le32(0)..le32(#bank)..string.char(6)..'longfilename12.anm'..'\0'
assert(#rec==28)
local entries=assert(parse_index(rec,#bank+4));assert(#entries==1 and entries[1].offset==0)
assert(#parse_index(rec,#bank+3)==0)
assert(not parse_index('truncated',100))
local nimage,nsound=0,0
function image_create_rgb(w,h,p) assert(#p==w*h*3);nimage=nimage+1;return nimage end
function animation_create(handles,delay) assert(#handles>1 and delay==100);return 1 end
function sound_create_pcm(rate,bits,channels,signed,pcm)
    assert(rate>0 and #pcm%(bits/8*channels)==0 and signed==(bits==16));nsound=nsound+1;return nsound
end
local wav=up(engine.load_resource,'wav')
local wave='WAVEfmt '..le32(16)..le16(1)..le16(1)..le32(22050)..le32(22050)..le16(1)..le16(8)..'JUNK'..le32(1)..'x\0'..'data'..le32(2)..'\128\128'
assert(wav('RIFF'..le32(#wave)..wave));assert(not wav('RIFF'..le32(#wave)..wave:sub(1,-2)))
nsound=0
print('Tesoro format regressions passed')
if not arg[1] then return end
function list_files(path)
    local f=assert(io.popen("ls -1 '"..path:gsub("'","'\\''").."'"));local out={};for n in f:lines() do out[#out+1]=n end;f:close();return out
end
function file_open(p) return io.open(p,'rb') end
function file_read(f,o,n) assert(f:seek('set',o));return f:read(n) end
function file_close(f) f:close() end
function file_size(f) return f:seek('end') end
assert(engine.detect(arg[1]));local tree=engine.get_resources(arg[1]);local ids,counts={},{}
local function walk(nodes)
    for _,node in ipairs(nodes) do
        assert(not ids[node.id],'Duplicate ID '..node.id);ids[node.id]=true
        if node.children then walk(node.children)
        else
            counts[node.type]=(counts[node.type] or 0)+1
            -- All individual images and WAVs; animations reuse the same images.
            if node.type~='animation' then assert(engine.load_resource(arg[1],node.id),'Failed '..node.id) end
        end
    end
end
walk(tree)
for typ,n in pairs(counts) do print(typ..': '..n) end
assert(nimage==2012 and nsound==2346)
print('Tesoro full resource sweep passed')

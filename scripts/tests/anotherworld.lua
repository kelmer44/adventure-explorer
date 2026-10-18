-- lua scripts/tests/anotherworld.lua [DOS game directory]
local engine=dofile('scripts/engines/anotherworld/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local function be16(n) return string.char(math.floor(n/256)%256,n%256) end
local function be32(n) return be16(math.floor(n/65536))..be16(n%65536) end
local function reject(fn,...) assert(not pcall(fn,...),'Malformed input was accepted') end
local unpack_bank=up(up(engine.load_resource,'payload'),'unpack_bank')
-- Build a single-word stream in the decoder's LSB-first bit order.
local function packed(bitstring,size)
    assert(#bitstring<=31)
    local word=2^#bitstring
    for i=1,#bitstring do if bitstring:sub(i,i)=='1' then word=word+2^(i-1) end end
    return be32(word)..be32(word)..be32(size)
end
local literal='00000'..'01000001' -- literal run of 1, ASCII A
local a=packed(literal,1);assert(unpack_bank(a,1)=='A')
assert(unpack_bank(packed(literal..'01'..'00000001',3),3)=='AAA') -- overlapping reference
assert(unpack_bank(packed(literal..'100'..'000000001',4),4)=='AAAA')
assert(unpack_bank(packed(literal..'101'..'0000000001',5),5)=='AAAAA')
reject(unpack_bank,a,2)
reject(unpack_bank,a:sub(1,4)..be32(0)..be32(1),1) -- CRC mismatch
reject(unpack_bank,packed('01'..'00000000',2),2) -- zero offset
reject(unpack_bank,packed('01'..'00000001',2),2) -- reference before any literals
reject(unpack_bank,be32(0)..be32(0)..be32(1),1) -- truncated refill
local bitmap=up(engine.load_resource,'bitmap')
local px=bitmap('\128'..string.rep('\0',7999)..'\64'..string.rep('\0',7999)..'\32'..string.rep('\0',7999)..'\16'..string.rep('\0',7999))
assert(#px==64000 and px[1]==1 and px[2]==2 and px[3]==4 and px[4]==8 and px[5]==0)
reject(bitmap,string.rep('\0',31999))
local palette=up(engine.load_resource,'palette')
local pal=palette(be16(0x123)..string.rep('\0',2046),0,false)
assert(#pal==768 and pal[1]==17 and pal[2]==34 and pal[3]==51 and pal[768]==0)
local ep=palette(string.rep('\0',1024)..be16(0xf000)..string.rep('\0',1022),0,true)
assert(ep[1]==255 and ep[2]==255 and ep[3]==255)
reject(palette,string.rep('\0',2048),32,false)
local polygons=up(engine.load_resource,'polygons');local render=up(engine.load_resource,'render')
local poly=string.char(0xc3,4,4,4,0,0,0,4,4,4,4,0)
local ps=polygons(poly,0);local w,h,p=render(ps)
assert(#ps==1 and #p==w*h and ps[1].color==3)
assert(p[(1+2)*w+3+1]==3) -- interior
-- Parent at 0 points to a polygon at byte offset 8 and overrides its color.
local composite=string.char(2,0,0,0)..be16(0x8004)..string.char(5,6,9,0)..poly
-- Header is ten bytes with a color override: reference must point to byte 10.
composite=composite:sub(1,4)..be16(0x8005)..composite:sub(7)
local cp=polygons(composite,0)
assert(cp[1].color==9 and cp[1].points[1][1]==3 and cp[1].points[1][2]==4)
reject(polygons,string.char(2,0,0,0)..be16(0)..'\0\0',0) -- recursive reference
reject(polygons,poly:sub(1,-2),0)
reject(polygons,string.char(0xc0,2,2,5)..string.rep('\0',10),0) -- odd vertex count
local disassemble=up(up(engine.get_resources,'index'),'disassemble')
local code=string.char(4)..be16(4)..string.char(17,0x80,0,0,0,5)
local draws,_,_,text=disassemble(code)
assert(#draws==1 and draws[1].offset==0 and text:find('drawShape',1,true))
reject(disassemble,string.char(0x40))
reject(disassemble,string.char(27))
reject(disassemble,string.char(7)..be16(65535))
local memory=''
function file_open() return true end
function file_size() return #memory end
function file_read(_,o,n) return memory:sub(o+1,o+n) end
function file_close() end
local directory=up(engine.detect,'directory')
local record=string.char(0,2)..be32(0)..string.char(0,1)..be32(0)..be32(32000)..be32(32000)
memory=record..'\255';assert(#directory('fixture')==1)
memory=record;reject(directory,'fixture')
memory=record:sub(1,-2);reject(directory,'fixture')
memory=record:sub(1,16)..be32(1048577)..'\255';reject(directory,'fixture')
print('Another World ByteKiller, bitplanes, palettes, shapes, script and directory regressions passed')
if not arg[1] then return end
function file_open(p) return io.open(p,'rb') end
function file_size(f) return assert(f:seek('end')) end
function file_read(f,o,n) assert(f:seek('set',o));if n==0 then return nil end;return f:read(n) or '' end
function file_close(f) f:close() end
function image_create_indexed(w,h,p,pal)
    assert(w>0 and h>0 and #p==w*h and #pal==768)
    for _,v in ipairs(p) do assert(v>=0 and v<=255 and v%1==0) end
    for _,v in ipairs(pal) do assert(v>=0 and v<=255) end
    return 1
end
function sound_create_pcm(rate,bits,ch,signed,s)
    assert(rate>0 and bits==8 and ch==1 and signed and #s>0);return 1
end
assert(engine.detect(arg[1]));assert(not engine.detect('/tmp'))
local ids,counts={},{};local samples={};local total=0
local function walk(nodes)
    for _,n in ipairs(nodes) do
        assert(not ids[n.id],'Duplicate ID '..n.id);ids[n.id]=true
        if n.children then walk(n.children) else
            counts[n.type]=(counts[n.type] or 0)+1
            assert(engine.load_resource(arg[1],n.id),'Failed '..n.id);total=total+1
            local num=n.id:match('^sound_(%d+)_');if num then samples[num]=true end
        end
    end
end
walk(engine.get_resources(arg[1]))
for kind,n in pairs(counts) do print(kind..': '..n) end
local n=0;for _ in pairs(samples) do n=n+1 end
print(n..' unique sound samples; '..total..' resources loaded')
assert(engine.load_resource(arg[1],'bitmap_18','pal_14_00_ega'))
assert(engine.load_resource(arg[1],'not_a_resource')==nil)
print('Another World real-data sweep passed')

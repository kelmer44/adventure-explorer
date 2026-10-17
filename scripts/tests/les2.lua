-- lua scripts/tests/les2.lua [LES2 directory]
local engine=dofile('scripts/engines/les2/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local picture=up(engine.load_resource,'picture')
local lzw=up(picture,'lzw')
local hash=up(engine.get_resources,'hash')
assert(hash('mnsion.pal')==0xf53a7a21)
assert(hash('mnsion.pic')==0xf53f0492)
assert(hash(string.rep('x',21))==nil)
local function pack(codes)
    local out,bits,value={},0,0
    for _,code in ipairs(codes) do
        value=value+code*2^bits;bits=bits+9
        while bits>=8 do out[#out+1]=string.char(value%256);value=math.floor(value/256);bits=bits-8 end
    end
    if bits>0 then out[#out+1]=string.char(value%256) end
    return table.concat(out)
end
assert(lzw(pack({256,65,258,257}))=='AAA') -- dictionary special case
assert(lzw(pack({256,65,256,66,257}))=='AB')
assert(not lzw(pack({256,259,257})))
assert(not lzw(pack({256,65}))) -- EOF is not end code
assert(not lzw(pack({256,65,258,257}),2))
local function be16(n) return string.char(math.floor(n/256)%256,n%256) end
local function be32(n) return be16(math.floor(n/65536))..be16(n%65536) end
local raw=pack({256,1,2,3,4,257})
local fixture='FORM'..be32(39+#raw)..'ILBMBMHD'..be32(20)..be16(2)..be16(1)..string.rep('\0',15)..'BODY'..be32(#raw)..raw
local pic=assert(picture(fixture));assert(pic.count==2 and pic.raw==string.char(1,2,3,4))
assert(not picture(fixture:sub(1,-2)));assert(not picture(fixture:sub(1,20)..be16(0)..fixture:sub(23)))
-- The executable directory can move between builds. Bounds determine the
-- valid run, and an out-of-file entry terminates it.
local directory=up(up(engine.get_resources,'catalog'),'directory')
local function le16(n) return string.char(n%256,math.floor(n/256)%256) end
local function le32(n) return le16(n%65536)..le16(math.floor(n/65536)) end
local records={}
for i=0,19 do records[#records+1]=le32(i+100)..'a\0'..le32(i*10)..le32(10) end
local entries=assert(directory('prefix'..table.concat(records),{a={path='DATAA.DAT',size=200}}))
assert(#entries==20 and entries[1].offset==0 and entries[20].offset==190)
assert(not directory('prefix'..table.concat(records),{a={path='DATAA.DAT',size=199}}))
local nimage,nanim=0,0
function image_create_indexed(w,h,p,pal) assert(#p==w*h and #pal==768);nimage=nimage+1;return nimage end
function animation_create(handles,delay) assert(#handles>1 and delay==100);nanim=nanim+1;return nanim end
print('LES2 format regressions passed')
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
            assert(engine.load_resource(arg[1],node.id),'Failed '..node.id)
        end
    end
end
walk(tree)
for typ,n in pairs(counts) do print(typ..': '..n) end
assert(counts.image==267 and counts.animation==231 and counts.palette==83)
print('LES2 full resource sweep passed: '..nimage..' rendered images, '..nanim..' animations')

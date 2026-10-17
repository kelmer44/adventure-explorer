-- lua scripts/tests/sulfato.lua [SULFATO folder]
local engine=dofile('scripts/engines/sulfato/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local function le16(n) return string.char(n%256,math.floor(n/256)%256) end
local function le32(n) return le16(n%65536)..le16(math.floor(n/65536)) end
local picture=up(engine.load_resource,'picture')
local function pcx(body,stride)
    return 'NMP\8'..le16(0)..le16(0)..le16(2)..le16(0)..string.rep('\0',53)..'\1'..le16(stride)..string.rep('\0',60)..body..'\12'..string.rep('\42',768)
end
local w,h,px,pal=picture(pcx('\193\200\2\3\99',4))
assert(w==3 and h==1 and #px==3 and px[1]==200 and px[3]==3 and pal[768]==42)
assert(not pcall(picture,pcx('\196\1',3))) -- overflow
assert(not pcall(picture,pcx('\193',3))) -- missing run colour
assert(not pcall(picture,pcx('\1\2',3))) -- incomplete pixels
assert(not pcall(picture,pcx('\1\2\3\4',3))) -- trailing pixel data
local images,lastPixels=0,nil
function image_create_indexed(w,h,p,pal)
    assert(#p==w*h and #pal==768)
    if w*h<=16 then lastPixels=table.concat(p,',') end
    images=images+1;return images
end
function animation_create(handles,delay) assert(#handles>=1 and #handles<=200 and delay>0);return 1 end
function sound_create_pcm(rate,bits,channels,signed,pcm)
    assert(rate>0 and #pcm%(bits/8*channels)==0 and signed==(bits==16));return 1
end
local decode=up(engine.load_resource,'decode_cel')
local function chunk(kind,s) return le32(#s+6)..le16(kind)..s end
local function frame(s,n) return le32(#s+16)..le16(0xf1fa)..le16(n)..string.rep('\0',8)..s end
local function flc(frames)
    local body=table.concat(frames)
    return le32(128+#body)..le16(0xaf12)..le16(#frames)..le16(4)..le16(1)..le16(8)..le16(0)..le32(85)..string.rep('\0',60)..le32(128)..string.rep('\0',44)..body
end
local data=flc({frame(chunk(15,'\0\4\7'),1),frame(chunk(7,le16(1)..le16(1)..'\0\255\2\3'),1)})
local handles,delay=decode(data);assert(#handles==2 and delay==85 and lastPixels=='2,3,7,7')
handles=decode(data,2,2);assert(#handles==1 and lastPixels=='2,3,7,7')
assert(not pcall(decode,data:sub(1,-2)))
local small=data:sub(1,128)..le32(16)..data:sub(133)
assert(not pcall(decode,small))
local wav=up(engine.load_resource,'wav')
local wave='WAVEfmt '..le32(16)..le16(1)..le16(1)..le32(11025)..le32(11025)..le16(1)..le16(8)..'data'..le32(2)..'\128\128'
assert(wav('RIFF'..le32(#wave)..wave))
assert(not pcall(wav,'RIFF'..le32(#wave)..wave:sub(1,-2)))
assert(not pcall(wav,'developer text'))
print('Sulfato format regressions passed')
if not arg[1] then return end
function list_files(path)
    local f=assert(io.popen("ls -1 '"..path:gsub("'","'\\''").."'"));local out={};for n in f:lines() do out[#out+1]=n end;f:close();return out
end
function file_open(p) return io.open(p,'rb') end
function file_read(f,o,n) assert(f:seek('set',o));return f:read(n) end
function file_close(f) f:close() end
function file_size(f) return f:seek('end') end
assert(engine.detect(arg[1]));assert(not engine.detect('.'))
local tree=engine.get_resources(arg[1]);local ids,counts={},{}
local animations={}
for _,group in ipairs(tree) do
    for _,node in ipairs(group.children) do
        assert(not ids[node.id]);ids[node.id]=true;counts[node.type]=(counts[node.type] or 0)+1
        if node.type=='animation' then
            -- Decode each bank once, emitting one frame at a time to avoid retaining
            -- all images in the host. Also exercise the public first-batch loader.
            local name=node.id:match('^animation:(.-):')
            if not animations[name] then
                animations[name]=true
                assert(engine.load_resource(arg[1],node.id))
                local f=assert(io.open(arg[1]..'/'..name,'rb'));local s=f:read('*a');f:close()
                local count=s:byte(7)+s:byte(8)*256
                -- The last batch forces reconstruction of every preceding delta.
                decode(s,count,count)
            end
        else assert(engine.load_resource(arg[1],node.id),'Failed '..node.id) end
    end
end
for typ,n in pairs(counts) do print(typ..': '..n) end
assert(counts.image==112 and counts.palette==112 and counts.sound==735 and counts.text==43)
print('Sulfato full resource sweep passed')

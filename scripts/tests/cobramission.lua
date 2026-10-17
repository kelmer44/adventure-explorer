-- lua scripts/tests/cobramission.lua [game-directory] [existing-text-export-directory]
local engine = dofile('scripts/engines/cobramission/engine.lua')
local function up(fn, key)
    for i=1,100 do
        local name,value=debug.getupvalue(fn,i)
        if name==key then return value end
        if not name then break end
    end
    error('Missing helper '..key)
end
local decode=up(engine.load_resource,'decode_script')
local scenes=up(engine.load_resource,'script_scenes')
local ic=up(engine.load_resource,'compiled_strings')
local voc=up(engine.load_resource,'decode_voc')
local function w(n) return string.char(n%256,math.floor(n/256)%256) end
local function dw(n) return w(n%65536)..w(math.floor(n/65536)) end
local function encode(s)
    return (s:gsub('[^\9\10\13]',function(c) return string.char((287-c:byte())%256) end))
end
local source=';Comment\r\n*100 Intro\r\n(JR) @Ja: caf'..string.char(130)..'!\r\n*100 Repeated label\r\nOther text\r\n'
assert(decode(encode(source))==source)
local ss,full=scenes(encode(source))
assert(#ss==2 and ss[1].name=='*100 Intro' and ss[2].name=='*100 Repeated label')
assert(full:find('café!',1,true) and full:find('@Ja',1,true))
-- Complete records only; skip binary constants even when containing ASCII runs.
local constants=w(2)..w(6)..'Hello\0'..w(8)..w(4)..'A\1B\0'..w(65535)
local hdr='IC'..w(0)..w(#constants)..string.rep('\0',10)
local text,count=ic(hdr..constants)
assert(text=='[0002] Hello' and count==1)
assert(not ic((hdr..constants):sub(1,-2)))
assert(not ic(''))
local function block(t,payload)
    return string.char(t,#payload%256,math.floor(#payload/256)%256,math.floor(#payload/65536))..payload
end
local vh='Creative Voice File\26'..w(26)..w(0x10A)..w(0x1129)
local clip=vh..block(6,w(65535))..block(1,string.char(131,0)..'ABC')
    ..block(3,w(1)..string.char(131))..block(2,'D')..block(7,'')..'\0'
local pcm,rate=voc(clip)
assert(pcm=='ABC'..string.rep(string.char(128),2)..'D' and rate==8000)
assert(not voc(clip:sub(1,-2)))
assert(not voc(vh..block(1,string.char(131,1)..'ABC')..'\0')) -- unsupported compression
assert(not voc(vh..block(7,'')..'\0')) -- unmatched loop end
assert(not voc(vh..block(1,string.char(131,0)..'ABC')..block(1,string.char(143,0)..'X')..'\0'))
assert(not voc(vh..string.char(1,255,255,255)))
local entries=up(engine.get_resources,'vol_entries')
function file_read(data,p,n) return data:sub(p+1,p+n) end
local archive=dw(16)..dw(16)..dw(19)..dw(22)..'ABCDEF'
local es=entries(archive,#archive)
assert(#es==2 and es[1].offset==16 and es[2].size==3)
assert(#entries(dw(4096)..'bad',7)==0)
print('Cobra script, scene, IC, VOC and archive regressions passed')
if not arg[1] then return end
function file_open(p) return io.open(p,'rb') end
function file_close(f) f:close() end
function file_size(f) return f:seek('end') end
function file_read(f,p,n) assert(f:seek('set',p));return f:read(n) end
function file_exists(p) local f=file_open(p);if f then f:close();return true end;return false end
function image_create_indexed(wi,he,p,pal)
    assert(wi>0 and he>0 and #p==wi*he and #pal==768)
    return 1
end
function sound_create_pcm(sr,bits,ch,signed,data)
    assert(sr>0 and bits==8 and ch==1 and not signed and #data>0)
    return 1
end
local counts,seen={image=0,text=0,sound=0},{}
assert(engine.detect(arg[1]))
local function walk(nodes)
    for _,node in ipairs(nodes) do
        assert(not seen[node.id],'Duplicate id '..node.id);seen[node.id]=true
        if node.children then walk(node.children)
        else
            local r=engine.load_resource(arg[1],node.id)
            assert(r and r.type==node.type,'Wrong type for '..node.id..': '..tostring(r and r.text))
            if r.type=='text' then
                assert(#r.text>0 and not r.text:find('Invalid IC',1,true),node.id)
                if arg[2] then
                    local out=assert(io.open(arg[2]..'/'..node.id:gsub(':','_')..'.txt','wb'))
                    out:write(r.text);out:close()
                end
            end
            counts[node.type]=counts[node.type]+1
        end
    end
end
walk(engine.get_resources(arg[1]))
print(string.format('Real game: %d images, %d text resources, %d sounds',counts.image,counts.text,counts.sound))
assert(counts.sound==155 and counts.text==871 and counts.image>200)

-- lua scripts/tests/saga.lua [IHNMAIMS folder]
local engine = dofile('scripts/engines/saga/engine.lua')
local function up(fn, key)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if name == key then return value end
        if not name then break end
    end
    error('Missing upvalue ' .. key)
end
local decode_image = up(engine.load_resource, 'decode_image')
local decode_rle = up(decode_image, 'decode_rle')
local sprite_list = up(engine.load_resource, 'sprite_list')
local decode_sprite = up(engine.load_resource, 'decode_sprite')
local strings = up(engine.load_resource, 'strings')
local load_wave = up(engine.load_resource, 'load_wave')
local parse_archive = up(up(engine.load_resource, 'get_index'), 'parse_archive')
local animation_frame = up(up(engine.load_resource, 'load_animation'), 'animation_frame')
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n) return le16(n % 65536) .. le16(math.floor(n / 65536)) end
local function eq(t, want) assert(t and table.concat(t, ',') == want) end
-- Short/long literals, fills, overlapping short/long backreferences, bitfields.
eq(decode_rle(string.char(195,1,2,3,128,9), 6), '1,2,3,9,9,9')
eq(decode_rle(string.char(33,0) .. string.rep('x',256),256), string.rep('120,',255)..'120')
eq(decode_rle(string.char(193,7,64,1),4), '7,7,7,7')
eq(decode_rle(string.char(193,8,16,1,4),5), '8,8,8,8,8')
eq(decode_rle(string.char(48,2,3,170),8), '3,2,3,2,3,2,3,2')
assert(not decode_rle(string.char(64,1),3))
assert(not decode_rle(string.char(195,1),3))
assert(not decode_rle(string.char(191,1),4))
assert(not decode_rle(string.char(0),1))
local img = le16(2)..le16(4)..le32(0)..string.rep('\0',768)..string.char(200,1,2,3,4,5,6,7,8)
local px,w,h = decode_image(img)
assert(w==2 and h==4); eq(px,'4,8,3,7,2,6,1,5')
eq(decode_image(img,true),'1,5,2,6,3,7,4,8')
assert(not decode_image(img:sub(1,776)))
assert(not decode_image(le16(65535)..img:sub(3)))
local spr = le16(1)..le32(6)..le16(0)..le16(0)..le16(2)..le16(2)..string.char(1,3,5,6,7)
local frames = assert(sprite_list(spr)); eq(decode_sprite(spr,frames[1],#spr),'6,7,0,5')
assert(not sprite_list(le16(2)..le32(999)))
local single = le16(1)..le32(6)..le16(0)..le16(0)..le16(2)..le16(2)..string.char(9,0)
local sf=assert(sprite_list(single))[1]
eq(decode_sprite(single,sf,#single),'0,0,0,0') -- shipped transparent overrun
assert(not decode_sprite(spr:sub(1,-2),frames[1],#spr-1))
assert(strings(le16(4)..le16(7)..'Hi\0'..string.char(241)..'!\0') == '[0] Hi\n[1] ñ!')
assert(not strings(le16(20)..'short'))
local pcm
function sound_create_pcm(rate,bits,channels,isSigned,data)
    assert(rate==22050 and bits==8 and channels==1 and not isSigned)
    pcm=data; return 1
end
local fmt = le16(1)..le16(1)..le32(22050)..le32(22050)..le16(1)..le16(8)
local wav = 'RIFF'..le32(0)..'WAVEJUNK'..le32(1)..'x\0fmt '..le32(#fmt)..fmt..'data'..le32(2)..'ab'
assert(load_wave(wav)==1 and pcm=='ab'); assert(not load_wave(wav:sub(1,-2)))
local canvas={1,2,3,4}
local stream=string.char(15,0,0,0,0,0)..string.rep('\0',8)..string.char(65,9,0,63)
assert(animation_frame(stream,1,canvas,2,2)==#stream+1); eq(canvas,'9,2,3,4')
assert(not animation_frame(string.char(128,5),1,{},2,2))
-- In-memory archive validates directory footer and payload bounds.
local mock= 'abc'..le32(0)..le32(3)..le32(3)..le32(1)
function file_open() return 1 end
function file_size() return #mock end
function file_read(_,off,n) return mock:sub(off+1,off+n) end
function file_close() end
assert(parse_archive('mock').entries[0].size==3)
mock='abc'..le32(2)..le32(3)..le32(3)..le32(1)
assert(not parse_archive('mock'))
print('SAGA synthetic format regressions passed')
if not arg[1] then return end
-- Real data sweep, without retaining decoded media.
function file_open(p) return io.open(p,'rb') end
function file_size(f) local n=f:seek('end'); return n end
function file_read(f,off,n) f:seek('set',off); return f:read(n) or '' end
function file_close(f) f:close() end
function file_exists(p) local f=io.open(p,'rb'); if f then f:close(); return true end; return false end
function list_files(path)
    local p=assert(io.popen("ls -1 '"..path:gsub("'","'\\''").."'"))
    local names={}; for s in p:lines() do names[#names+1]=s end; p:close(); return names
end
local nimages, nanims, nsounds, nmidis = 0,0,0,0
function image_create_indexed(w,h,px,pal)
    assert(w>0 and h>0 and #px==w*h and #pal==768)
    for _,v in ipairs(px) do assert(v>=0 and v<=255) end
    nimages=nimages+1; return nimages
end
function animation_create(fr,delay) assert(#fr>0 and delay>0); nanims=nanims+1; return nanims end
function sound_create_pcm(rate,bits,ch,sign,data)
    assert(rate>0 and (bits==8 or bits==16) and (ch==1 or ch==2) and #data>0)
    nsounds=nsounds+1; return nsounds
end
function midi_create_from_xmi(data) assert(data:sub(1,4)=='FORM'); nmidis=nmidis+1; return nmidis end
assert(engine.detect(arg[1]))
local counts,ids,failures={},{},{}
local function walk(n)
    if n.children then for _,c in ipairs(n.children) do walk(c) end; return end
    assert(not ids[n.id], 'Duplicate '..n.id); ids[n.id]=true
    local kind=n.id:match('^(%a+)_'); counts[kind]=(counts[kind] or 0)+1
    local r=engine.load_resource(arg[1],n.id)
    if not r or ((n.type=='image' or n.type=='animation' or n.type=='sound' or n.type=='midi') and r.type~=n.type)
        or (r and r.description and r.description:find('(incomplete stream)',1,true))
        or (n.type=='text' and not r.text:match('^%[0%]')) then failures[#failures+1]=n.id end
end
for _,n in ipairs(engine.get_resources(arg[1])) do walk(n); print('Checked '..n.id); io.stdout:flush() end
assert(counts.bg>=90 and counts.sprite>1000 and counts.anim>100 and counts.sound>1000)
for k,v in pairs(counts) do print(k,v) end
print('Media created',nimages,nanims,nsounds,nmidis)
assert(#failures==0,'Failed resources: '..table.concat(failures,', '))
print('SAGA real-data sweep passed')

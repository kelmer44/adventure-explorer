-- lua scripts/tests/neverhood.lua [game-folder]
package.path = 'scripts/engines/neverhood/?.lua;' .. package.path
local engine = dofile('scripts/engines/neverhood/engine.lua')
local map = require('neverhood_palette')
local function w(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function dw(n) return w(n % 65536) .. w(math.floor(n / 65536)) end
local function palette(r,g,b) return string.rep(string.char(r,g,b,0),256) end
local function bitmap(pal) return w(pal and 26 or 18)..w(1)..w(1)..(pal or '')..string.char(7,0,0,0) end
local function animation(hash,pal)
    local pixels=w(1)..w(1)..w(0)..w(1)..string.char(7)..w(0)..w(0)
    return w(1)..w(20)..dw(52)..dw(pal and (52+#pixels) or 0)
        ..dw(hash)..w(1)..w(0)..dw(0)..w(1)..w(0)..w(0)..w(1)..w(1)
        ..string.rep('\0',14)..dw(0)..pixels..(pal or '')
end
local function archive(entries)
    local hashes,records,data={},{},{}
    local offset=16+#entries*24
    for _,e in ipairs(entries) do
        hashes[#hashes+1]=dw(e[1])
        records[#records+1]=string.char(e[2],e.alias and 101 or 1)..w(0)..dw(0)..dw(offset)..dw(e.alias or #e[3])..dw(#e[3])
        data[#data+1]=e[3];offset=offset+#e[3]
    end
    return dw(0x02004940)..w(7)..w(0)..dw(offset)..dw(#entries)..table.concat(hashes)..table.concat(records)..table.concat(data)
end
local red,green,blue=palette(120,20,30),palette(10,140,40),palette(50,60,160)
local function fixture(scene)
    return archive({{0x2311326a,2,bitmap()},{0x023023b4,2,bitmap(scene)},
        {1,2,bitmap(red)},{2,3,green},{3,4,animation(3,blue)},
        {4,4,animation(4)},{5,3,'',alias=2}})
end
local files={['fixture/hd.blb']=fixture(blue),['other/hd.blb']=fixture(green)}
function file_open(p) return files[p] end
function file_close() end
function file_read(f,p,n) return f:sub(p+1,p+n) end
function image_create_indexed(wi,he,px,pal)
    assert(#px==wi*he and #pal==768)
    return {pixels=px,palette=pal}
end
function animation_create(frames,delay) return frames end
local function colour(result,r,g,b)
    assert(result and result.image,result and result.text)
    local p=result.image.palette
    assert(p[22]==r and p[23]==g and p[24]==b,table.concat({p[22],p[23],p[24]},','))
end
colour(engine.load_resource('fixture','bmp_2311326a'),50,60,160)
colour(engine.load_resource('other','bmp_2311326a'),10,140,40) -- cache is per game
colour(engine.load_resource('fixture','bmp_00000001'),120,20,30)
colour(engine.load_resource('fixture','bmp_2311326a','pal_00000002'),10,140,40)
colour(engine.load_resource('fixture','bmp_00000001','pal_00000005'),10,140,40) -- alias
colour(engine.load_resource('fixture','bmp_00000001','pal_auto'),120,20,30)
colour(engine.load_resource('fixture','anim_00000003','pal_auto'),50,60,160)
colour(engine.load_resource('fixture','anim_00000003','pal_00000002'),10,140,40)
colour(engine.load_resource('fixture','anim_00000004'),7,7,7)
map[4]=0x023023b4
colour(engine.load_resource('fixture','anim_00000004'),50,60,160)
map[4]=nil
colour(engine.load_resource('fixture','bmp_00000001','pal_bad'),120,20,30)
assert(engine.default_palette('fixture','bmp_00000001')=='pal_auto')
assert(engine.default_palette('fixture','anim_00000003')=='pal_auto')
for _,group in ipairs(engine.get_resources('fixture')) do
    if group.id=='palettes' then assert(group.children[1].id=='pal_auto') end
end
-- All six teleporter locations select the corresponding background, including
-- array strides of six for the location buttons and lights.
local backgrounds={0x023023b4,0x36204507,0x046cf08e,0x9313a237,0xa651f246,0x02108034}
local buttons={0x010d7748,0x9d02019a,0x351a2f43,0x448138e5,0x02788cf0,0x71718024}
local lights={0x03136246,0x3cc24258,0xb059afc4,0x14611904,0x0644a6ec,0x0925b82c}
local locations={0x2311326a,0x39464212,0x2452a7c4,0x16a31921,0x464006b4,0x58652c04}
for i,bg in ipairs(backgrounds) do
    assert(map[buttons[i]]==bg and map[lights[i]]==bg and map[locations[i]]==bg)
end
print('Neverhood automatic/override palettes, aliases, game cache and teleporter mappings passed')
if not arg[1] then return end
function file_open(p) return io.open(p,'rb') end
function file_close(f) f:close() end
function file_read(f,p,n) assert(f:seek('set',p));return f:read(n) end
assert(engine.detect(arg[1]))
for i,hash in ipairs(buttons) do
    local r=engine.load_resource(arg[1],string.format('bmp_%08x',hash))
    local bg=engine.load_resource(arg[1],string.format('bmp_%08x',backgrounds[i]))
    assert(r.type=='image' and bg.type=='image')
    for j=1,768 do assert(r.image.palette[j]==bg.image.palette[j]) end
    print(string.format('Teleporter %d: 0x%08x -> 0x%08x verified',i,hash,backgrounds[i]))
end
print('Real game teleporter sprite palettes passed')

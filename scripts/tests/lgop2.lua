-- lua scripts/tests/lgop2.lua [installed-game-folder]
local function w(n) return string.char(n%256,math.floor(n/256)%256) end
local function dw(n) return w(n%65536)..w(math.floor(n/65536)) end
local function picture(width,height,pal)
    local line=math.ceil(width/4/8)*2
    local commands=string.rep('\0',line*math.ceil(height/4))
    local pixels=string.rep('\1',math.ceil(width/4)*math.ceil(height/4))
    local cmd=18+#pal;local pix=cmd+#commands
    return string.char(#pal>0 and 1 or 0,0,0,0)..w(cmd)..w(pix)..w(pix+#pixels)..w(line)..w(0)..w(width)..w(height)..pal..commands..pixels
end
local function archive(rgb)
    local count=547
    local offset=50+22+count*8
    local entries,body={},{}
    for i=1,count do
        local pal=i==547 and string.rep(string.char(0,0,0),1)..rgb..string.rep('\0',254*3) or ''
        local raw=picture(i==16 and 320 or 4,i==16 and 200 or 4,pal)
        entries[i]=dw(offset)..dw(62+#raw)
        body[i]=string.rep('\0',62)..raw;offset=offset+#body[i]
    end
    return string.rep('\0',24)..w(1)..'FLEX'..dw(50)..string.rep('\0',16)..
        string.rep('\0',16)..w(count)..w(count)..w(0)..table.concat(entries)..table.concat(body)
end
local files={['red/LGOP2.PRJ']=archive(string.char(200,10,20)),['green/LGOP2.PRJ']=archive(string.char(5,210,30))}
function file_exists(p) return files[p]~=nil end
function file_open(p) return files[p] end
function file_size(f) return #f end
function file_read(f,p,n) return f:sub(p+1,p+n) end
function file_close(f) end
function log_info(s) end
function image_create_indexed(wi,he,px,pal)
    assert(#px==wi*he and #pal==768)
    for _,v in ipairs(px) do assert(v>=0 and v<=255) end
    return {w=wi,h=he,px=px,pal=pal}
end
local engine=dofile('scripts/engines/lgop2/engine.lua')
local function leaves(nodes,result)
    result=result or {}
    for _,n in ipairs(nodes) do
        if n.children then leaves(n.children,result) else result[#result+1]=n end
    end
    return result
end
local tree=engine.get_resources('red')
local nodes=leaves(tree)
local function pic(index)
    for _,n in ipairs(nodes) do if n.id:match('^res_464C4558_'..index..'_') then return n.id end end
    error('missing picture '..index)
end
assert(tree[1].name=='Pictures (547)')
assert(tree[1].children[1].name=='Backgrounds (1)')
assert(tree[1].children[3].id=='lgop2_ui')
local pal=engine.default_palette('red',pic(1))
assert(pal and pal==engine.default_palette('red',pic(547)))
assert(engine.default_palette('red','other')==nil)
local function color(path,id,override,r,g,b)
    local result=engine.load_resource(path,id,override)
    assert(result.image.px[1]==1)
    local p=result.image.pal
    assert(p[4]==r and p[5]==g and p[6]==b,'wrong automatic/override color')
    assert(result.palette_image.pal==p and result.palette_colors==256)
    return result
end
color('red',pic(1),nil,200,10,20) -- Palette after 300 valid pictures.
color('red',pic(547),nil,200,10,20) -- Embedded palette.
color('red',pic(1),pal,200,10,20) -- Explicit palette picker.
color('green',pic(1),nil,5,210,30) -- Cache must not leak between folders.
color('red',pic(1),nil,200,10,20)
local swatch=engine.load_resource('red',pal)
assert(swatch.palette_colors==256 and swatch.image.pal[4]==200)
print('LGOP2 late palette, override, swatches, folder cache and classification regressions passed')
if not arg[1] then return end
function file_exists(p) local f=io.open(p,'rb');if f then f:close();return true end;return false end
function file_open(p) return io.open(p,'rb') end
function file_close(f) f:close() end
function file_size(f) return f:seek('end') end
function file_read(f,p,n) f:seek('set',p);return f:read(n) end
local real=engine.get_resources(arg[1]);local counts={};local count=0
for _,group in ipairs(real[1].children) do counts[group.name]=#group.children end
for _,n in ipairs(leaves(real)) do
    if n.id:match('^res_464C4558_') then
        local data=engine.load_resource(arg[1],n.id)
        assert(data and data.image and data.palette_image,n.id)
        assert(not data.description:match('grayscale'),n.id)
        assert(engine.default_palette(arg[1],n.id),n.id)
        count=count+1
    end
end
for name,n in pairs(counts) do print(name) end
assert(count==1141,'unexpected installed picture count '..count)
print('Decoded all '..count..' installed pictures with automatic color palettes')

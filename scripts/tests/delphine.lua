-- lua scripts/tests/delphine.lua [cine|cruise] [game directory]
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local function be16(n) return string.char(math.floor(n/256)%256,n%256) end
local function be32(n) return be16(math.floor(n/65536))..be16(n%65536) end
local function set(mode,w,h,pixels,signature)
    return (signature or 'SET')..'\0'..be16(1)..be32(0)..be16(w)..be16(h)..be16(mode)..string.rep('\0',6)..pixels
end
local function reject(fn,...) assert(not pcall(fn,...),'Expected malformed data rejection') end
for _,name in ipairs({'cine','cruise'}) do
    local engine=dofile('scripts/engines/'..name..'/engine.lua')
    local index=up(engine.get_resources,'index')
    local unpack=up(up(index,'payload'),name=='cine' and 'cine_unpack' or 'delphine_unpack')
    -- A padded directory size must not shift the actual payload to the right.
    local decoded=unpack(be32(12352)..be32(0)..be32(1),2)
    assert(#decoded==1 and decoded[1]==65)
    local frames=up(index,'sprite_frames')
    local pixels=up(engine.load_resource,'sprite_pixels')
    local planar='\128\0\64\0\32\0\16\0'
    local data=set(4,8,1,planar)
    local f=frames(data)[1];assert(f.w==16 and f.h==1)
    local p=pixels(data,f)
    assert(#p==16 and p[1]==1 and p[2]==2 and p[3]==4 and p[4]==8 and p[5]==0)
    reject(frames,data:sub(1,-2));reject(frames,set(4,7,1,planar))
    reject(frames,'SET\0'..be16(4097))
    local mask=set(1,2,1,'\128\1')
    local mp=pixels(mask,frames(mask)[1]);assert(#mp==16 and mp[1]==1 and mp[16]==1 and mp[2]==0)
    if name=='cine' then
        local ani='ANIM'..be16(8)..be16(1)..string.rep('\0',6)..be16(2)..string.rep('\0',6)..planar..planar
        assert(#frames(ani)==2 and frames(ani)[2].pos==31)
        reject(frames,ani:sub(1,-2))
        local lut={};for i=0,15 do lut[#lut+1]=string.char(32+i) end
        local mapped=set(5,1,1,table.concat(lut)..'\18')
        local p5=pixels(mapped,frames(mapped)[1]);assert(p5[1]==33 and p5[2]==34)
        local full=set(8,16,1,'\128'..string.rep('\0',15))
        local p8=pixels(full,frames(full)[1]);assert(#p8==16 and p8[1]==1 and p8[2]==0)
    else
        local pal=up(up(engine.load_resource,'resource_palette'),'rgb_palette')
        local colors=pal(string.char(64,128,255)..string.rep('\0',765),1)
        assert(colors[1]==64 and colors[2]==128 and colors[3]==255)
        local poly=up(index,'polygon_frames')
        local entries=poly(set(0,8,1,string.rep('\0',8)))
        assert(#entries==1 and entries[1].index==0 and entries[1].mirror)
        reject(poly,set(0,8,1,string.rep('\0',7)))
        local raw=set(8,2,1,'\7\255');local p8=pixels(raw,frames(raw)[1]);assert(p8[1]==7 and p8[2]==255)
        -- Non-SEC type 5 has two extra bytes per plane per row, cropped on display.
        local five=set(5,15,1,'\128\0\0'..'\64\0\0'..'\32\0\0'..'\16\0\0'..'\8\0\0')
        local f5=frames(five)[1];assert(f5.w==8)
        local p5=pixels(five,f5);assert(#p5==8 and p5[1]==1 and p5[2]==2 and p5[5]==16)
        local sec=set(4,16,1,planar,'SEC');assert(frames(sec)[1].w==16)
        assert(#frames(set(0,1,1,'\0'))==0) -- polygons are not bitmaps
    end
end
print('Delphine ANI/SET/SEC decoding and malformed input regressions passed')
if not arg[2] then return end
local engine=dofile('scripts/engines/'..arg[1]..'/engine.lua')
function file_open(p) return io.open(p,'rb') end
function file_exists(p) local f=file_open(p);if f then f:close();return true end;return false end
function file_size(f) return assert(f:seek('end')) end
function file_read(f,o,n) assert(f:seek('set',o));return f:read(n) or '' end
function file_close(f) f:close() end
function list_files(p)
    local f=assert(io.popen("ls -1 '"..p:gsub("'","'\\''").."'"));local out={};for n in f:lines() do out[#out+1]=n end;f:close();return out
end
function log_warn(s) error(s) end
function image_create_indexed(w,h,p,pal)
    assert(w>0 and h>0 and #p==w*h and #pal==768)
    for _,v in ipairs(p) do assert(v>=0 and v<=255 and v%1==0) end
    return 1
end
assert(engine.detect(arg[2]))
local count,ids=0,{}
local function walk(nodes)
    for _,n in ipairs(nodes) do
        assert(not ids[n.id],'Duplicate id '..n.id);ids[n.id]=true
        if n.children then walk(n.children)
        elseif n.id:match('^spr_') then
            local r=assert(engine.load_resource(arg[2],n.id));assert(r.type=='image')
            count=count+1
        end
    end
end
walk(engine.get_resources(arg[2]));assert(count>0)
print(arg[1]..': '..count..' sprite frames decoded')

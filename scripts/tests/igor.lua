-- lua scripts/tests/igor.lua [Spanish floppy or CD directory] [PPM export directory]
local engine = dofile('scripts/engines/igor/engine.lua')
local function up(fn, key)
    for i=1,100 do
        local n,v=debug.getupvalue(fn,i)
        if n==key then return v end
        if not n then break end
    end
    error('Missing upvalue '..key)
end
local parse=up(engine.load_resource,'parse_sparse_frame')
assert(not parse('',1,true))
assert(not parse(string.char(0,0,201,0),1,true))
-- One row containing a skipped pixel and two repeated pixels.
local stream=string.char(0,0,1,0,1,1,254,7)
local q,y,h,lo,hi=parse(stream,1,true)
assert(q==9 and y==0 and h==1 and lo==1 and hi==3)
assert(not parse(stream:sub(1,-2),1,true))
local paint=up(engine.load_resource,'paint_sparse_frame')
local pixels={0,0,0,0};paint(stream,1,pixels,4,0,0)
assert(table.concat(pixels,',')=='0,7,7,0')
local fake={}
function file_exists(p) return fake[p]~=nil end
function file_open(p) return fake[p] end
function file_close() end
function file_read() return nil end
function file_size(f) return f end
fake['bad/IGOR.DAT']=1234
assert(not engine.detect('bad'))
fake['cd/IGOR.EXE']=9115648
fake['floppy/IGOR.DAT']=11199335
assert(engine.detect('cd') and engine.detect('floppy'))
for _,version in ipairs({'cd','floppy'}) do
    local tree=engine.get_resources(version)
    assert(#tree[1].children==(version=='cd' and 75 or 76))
    assert(tree[2].id=='cat_scenes' and #tree[2].children==3)
    assert(#tree[3].children==(version=='cd' and 12 or 10))
end
print('Igor sparse-frame, version detection and catalog coverage regressions passed')
if not arg[1] then return end
function file_open(p) return io.open(p,'rb') end
function file_exists(p) local f=io.open(p,'rb');if not f then return false end;f:close();return true end
function file_size(f) return f:seek('end') end
function file_read(f,o,n) assert(f:seek('set',o));local s=f:read(n);assert(s and #s==n,'Short read at '..o);return s end
function file_close(f) f:close() end
local current,images,manifest
images=0; manifest={}
function image_create_indexed(w,h,p,pal)
    assert(#p==w*h,current..' pixel count '..#p..' vs '..w*h)
    assert(#pal==768)
    for _,v in ipairs(pal) do assert(v>=0 and v<=255,current..' palette range') end
    for _,v in ipairs(p) do assert(v>=0 and v<=255,current..' pixel range') end
    images=images+1
    if arg[2] then
        local out=assert(io.open(arg[2]..'/'..current..'.ppm','wb'))
        out:write('P6\n'..w..' '..h..'\n255\n')
        for row=0,h-1 do
            local line={}
            for col=1,w do
                local i=p[row*w+col]*3+1
                line[#line+1]=string.char(pal[i],pal[i+1],pal[i+2])
            end
            out:write(table.concat(line))
        end
        out:close()
    end
    return images
end
function image_create_rgb(w,h,p)
    assert(#p==w*h*3)
    for _,v in ipairs(p) do assert(v>=0 and v<=255) end
    return 1
end
local count=0
local function walk(nodes, parent)
    for _,n in ipairs(nodes) do
        if n.children then walk(n.children, n.name)
        elseif n.id:match('^room_') or n.id:match('^fs_') or n.id:match('^ui_') or n.id:match('^scene_') then
            current=n.id
            local r=engine.load_resource(arg[1],n.id)
            assert(r and r.type==n.type,n.id..': '..tostring(r and r.text))
            assert(not (r.description or ''):match('WARNING'),n.id)
            if n.type=='image' and not n.id:match('^room_msk_') and not n.id:match('^room_box_') then manifest[#manifest+1]=n.id..'\t'..(n.name=='Background' and parent or n.name)..'\t'..(r.description or '') end
            count=count+1
        end
    end
end
walk(engine.get_resources(arg[1]))
if arg[2] then
    local f=assert(io.open(arg[2]..'/manifest.tsv','w'));f:write(table.concat(manifest,'\n'));f:close()
end
print('Verified '..count..' room, mask, walkbox, text, screen and UI resources; '..images..' images')

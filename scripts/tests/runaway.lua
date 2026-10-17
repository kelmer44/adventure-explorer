-- Run from repository root: lua scripts/tests/runaway.lua [Runaway data folder]
-- Pure-format regressions run without commercial data. The optional scan checks
-- every bank's span boundaries and samples both ends of each bank in the host API.
local engine=dofile("scripts/engines/runaway/engine.lua")
local function up(fn,key)
    for i=1,100 do
        local name,value=debug.getupvalue(fn,i)
        if name==key then return value end
        if not name then break end
    end
    error("Missing local "..key)
end
local load=up(engine.load_resource,"load")
local frame_image=up(load,"frame_image")
local color=up(up(frame_image,"paint"),"color")
local descriptors=up(engine.get_resources,"descriptors")
local spans=up(engine.get_resources,"spans")
local dimensions=up(engine.get_resources,"dimensions")
local rle_size=up(engine.get_resources,"rle_size")
local function le16(n) return string.char(n%256,math.floor(n/256)%256) end
local function le32(n) return le16(n%65536)..le16(math.floor(n/65536)) end
local function rgb_is(v,r,g,b) local a,c,d=color(v); assert(a==r and c==g and d==b) end
rgb_is(0xf800,255,0,0); rgb_is(0x07e0,0,255,0); rgb_is(0x001f,0,0,255); rgb_is(0xffff,255,255,255)
local header=le32(0)..le16(10)..le16(2)..le16(20)..le16(20)..le16(1)
local pixels=le16(0xf800)..le16(0x07e0)
local frame=header..le16(10)..le16(20)..string.char(2)..pixels
local frames=assert(descriptors(frame,true)); assert(#frames==1 and frames[1].offset==14)
assert(not descriptors(frame:sub(1,-2),true))
assert(not descriptors(header..le16(11)..le16(20)..string.char(2)..pixels,true)) -- outside bbox
assert(not descriptors(frame.."padding",true)) -- complete block consumption
local strips=le16(1)..le16(10)..le16(20)..le16(2)..pixels
local s=assert(spans(strips,false)); assert(s.width==2 and s.height==1 and s.x==10 and s.y==20)
assert(not spans(strips:sub(1,-2),false))
assert(spans(strips:sub(1,8),true))
assert(not spans(strips,true))
assert(rle_size(string.char(7)..le16(3)..string.char(2)..le16(4))==7)
assert(not rle_size("bad!"))
local w,h=dimensions("I03",4222976); assert(w==1024 and h==2062)
assert(not dimensions("I03",4222975))
w,h=dimensions("D03",1608000); assert(w==1200 and h==670)
w,h=dimensions("D06",4224000); assert(w==1760 and h==1200)
local nimage,nsound=0,0
function image_create_rgb(w,h,px)
    assert(#px==w*h*3,"RGB pixel count mismatch")
    for _,i in ipairs({1,math.floor(#px/2),#px}) do assert(px[i]>=0 and px[i]<=255 and px[i]%1==0) end
    nimage=nimage+1; return nimage
end
function image_create_indexed(w,h,px,pal) assert(#px==w*h and #pal==768); nimage=nimage+1; return nimage end
function animation_create(images,delay) assert(#images>0 and #images<=32 and delay==100); return 1 end
function sound_create_pcm(rate,bits,channels,signed,d)
    assert(rate==16000 and #d%(bits/8*channels)==0 and signed==(bits==16))
    nsound=nsound+1; return nsound
end
assert(frame_image(frame,frames[1],"fixture"))
print("Runaway format regressions passed")
if not arg[1] then return end
local function quote(s) return "'"..s:gsub("'","'\\''").."'" end
function list_files(dir)
    local p=assert(io.popen("ls -1 "..quote(dir).." 2>/dev/null"))
    local names={}; for n in p:lines() do names[#names+1]=n end; p:close(); return names
end
function file_open(path) return io.open(path,"rb") end
function file_read(f,p,n) assert(f:seek("set",p)); return f:read(n) end
function file_size(f) return f:seek("end") end
function file_close(f) f:close() end
function log_warn(m) error(m) end
assert(engine.detect(arg[1]),"Runaway detection failed")
local tree=engine.get_resources(arg[1]); local ids,counts,banks={},{},{}
local state=up(engine.get_resources,"state")
local block_data=up(load,"block_data")
local function check(id)
    local r=engine.load_resource(arg[1],id); assert(r,"Failed resource "..id)
    return r
end
local animation_samples=0
local function walk(nodes)
    for _,node in ipairs(nodes) do
        assert(not ids[node.id],"Duplicate resource ID "..node.id); ids[node.id]=true
        if node.children then walk(node.children)
        else
            counts[node.type]=(counts[node.type] or 0)+1
            local e=assert(state.entries[node.id])
            if e.kind=="frame" then
                local key=e.block.path..":"..e.block.offset
                local bank=banks[key]
                if not bank then
                    local raw=assert(block_data(e.block))
                    local fs=assert(descriptors(raw,true),"Full span validation failed: "..key)
                    banks[key]={first=node.id,last=node.id,count=#fs}
                    check(node.id)
                else bank.last=node.id end
            elseif e.kind=="animation" then
                if animation_samples<3 then check(node.id); animation_samples=animation_samples+1 end
            else check(node.id) end
        end
    end
end
walk(tree)
local nbanks,nframes=0,0
for _,bank in pairs(banks) do check(bank.last); nbanks=nbanks+1; nframes=nframes+bank.count end
for typ,n in pairs(counts) do print(typ..": "..n) end
assert(nbanks>100 and nframes>10000)
print(string.format("Validated %d banks / %d frame layouts; rendered %d images; loaded %d PCM clips",nbanks,nframes,nimage,nsound))

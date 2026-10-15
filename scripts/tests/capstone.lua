-- Run from the repository root: lua scripts/tests/capstone.lua [game-data-root]
-- No commercial data is distributed here. The optional root contains AMTAIL/BHB/LALAW.
local engine=dofile("scripts/engines/capstone/engine.lua")
local function up(fn,key)
    for i=1,100 do
        local name,value=debug.getupvalue(fn,i)
        if name==key then return value end
        if not name then break end
    end
    error("Missing decoder "..key)
end
local load=up(engine.load_resource,"load")
local bhb_data=up(load,"bhb_data")
local packbits=up(bhb_data,"packbits")
local bhb_lz=up(bhb_data,"bhb_lz")
local law_lz=up(up(load,"law_data"),"law_lz")
local lzh=up(up(load,"fv_picture"),"lzh")
assert(packbits(string.char(128,2).."ABC"..string.char(254).."D".."padding",6)=="ABCDDD")
assert(packbits(string.char(3).."A",4)==nil)
assert(bhb_lz(string.char(1).."A"..string.char(66,0,0,0),6)=="AAAAAA")
assert(bhb_lz(string.char(0,64,0),10)==nil) -- reference before output
assert(law_lz(string.char(0,128).."A"..string.char(0,8,0,0),6)=="AAAAAA")
assert(law_lz(string.char(0,0,1,0),10)==nil)
assert(law_lz(string.char(0,128).."A"..string.char(0,8,0,0),5)==nil) -- output overrun
assert(not pcall(lzh,"",10))
assert(lzh("",0)==nil)
print("Compression boundary regressions passed")
if not arg[1] then return end

local function quote(s) return "'"..s:gsub("'","'\\''").."'" end
function list_files(dir)
    local pipe=assert(io.popen("find "..quote(dir).." -maxdepth 1 -type f"))
    local names={}; for path in pipe:lines() do names[#names+1]=path:match("[^/]+$") end
    pipe:close(); table.sort(names); return names
end
function file_open(path)
    local f=io.open(path,"rb"); if f then return f end
    local dir,name=path:match("^(.*)/([^/]+)$")
    for _,candidate in ipairs(list_files(dir)) do
        if candidate:lower()==name:lower() then return io.open(dir.."/"..candidate,"rb") end
    end
end
function file_exists(path) local f=file_open(path); if f then f:close(); return true end; return false end
function file_read(f,p,n) f:seek("set",p); return f:read(n) end
function file_size(f) return f:seek("end") end
function file_close(f) f:close() end
function log_warn(m) error(m) end
function image_create_indexed(w,h,px,pal)
    assert(#px==w*h and #pal==768,"Invalid image dimensions/palette")
    for _,v in ipairs(px) do assert(v>=0 and v<=255 and v%1==0) end
    for _,v in ipairs(pal) do assert(v>=0 and v<=255) end
    return {width=w,height=h}
end
function animation_create(frames,delay) assert(#frames>0 and delay>0); return frames end
function midi_create_from_xmi(d) assert(d:sub(1,4)=="FORM"); return 1 end
for _,game in ipairs({"AMTAIL","BHB","LALAW"}) do
    local path=arg[1].."/"..game
    assert(engine.detect(path),"Detection: "..game)
    local tree=engine.get_resources(path); local count,ids=0,{}
    local function walk(nodes)
        for _,n in ipairs(nodes) do
            assert(not ids[n.id],"Duplicate resource "..n.id); ids[n.id]=true
            if n.children then walk(n.children)
            else
                local r=engine.load_resource(path,n.id,engine.default_palette(path,n.id))
                assert(r,"Failed "..game.." / "..n.id); count=count+1
                if n.type=="image" or n.type=="palette" then assert(r.type=="image") end
                if n.type=="animation" then assert(r.type=="animation") end
            end
        end
    end
    walk(tree)
    assert(count>50,"Unexpectedly empty resource tree")
    print(game..": "..count.." leaves loaded")
end
assert(not engine.detect(arg[1]),"False positive on parent directory")

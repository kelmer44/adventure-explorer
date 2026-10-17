-- lua scripts/tests/city.lua [CITY folder] [catalog|all]
local engine=dofile('scripts/engines/city/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local function le16(n) return string.char(n%256,math.floor(n/256)%256) end
local function le32(n) return le16(n%65536)..le16(math.floor(n/65536)) end
local function reject(fn,...) assert(not pcall(fn,...),'Expected invalid input to fail') end
local rle=up(up(engine.load_resource,'crp'),'rle')
local crp=up(engine.load_resource,'crp');local frm=up(up(engine.get_resources,'build'),'frm')
local snw=up(up(engine.get_resources,'build'),'snw');local dialogue=up(engine.load_resource,'dialogue')
local p=rle('\2\1\2\3\128\7\255\9',1,134)
assert(#p==134 and p[1]==1 and p[3]==3 and p[4]==7 and p[5]==7 and p[134]==9)
reject(rle,'\128',1,2);reject(rle,'\1\1',1,2);reject(rle,'\255\0',1,2);reject(rle,'\128\1\0',1,2)
local header='CRSL\1\2\1'..le16(2)..le16(1)..le32(2)
local w,h,pix=crp(header..'\128\42');assert(w==2 and h==1 and pix[2]==42)
reject(crp,header..'\129\42');reject(crp,header:sub(1,-2))
reject(frm,string.rep('\0',40));reject(snw,le32(2)..le32(0));reject(dialogue,le32(100000))
local text=le32(1)..'101\0'..le32(16)..le32(20)..'ABC\0'..'\1\0\1Ol\130\0'
assert(dialogue(text):find('Olé',1,true));reject(dialogue,text:sub(1,-2))
print('City RLE packet, bounds, image header and CP850 dialogue regressions passed')
if not arg[1] then return end
local function quote(s) return "'"..s:gsub("'","'\\''").."'" end
function file_open(p)
    local f=io.open(p,'rb');if not f then return nil end
    local _,err=f:read(1);if err then f:close();return nil end
    f:seek('set',0);return f
end
function file_size(f) return assert(f:seek('end')) end
function file_read(f,o,n) assert(f:seek('set',o));return f:read(n) or '' end
function file_close(f) f:close() end
function list_files(p)
    local f=assert(io.popen('ls -1 '..quote(p)));local out={};for n in f:lines() do out[#out+1]=n end;f:close();return out
end
local counts,loaded,ids={},{},{}
function image_create_indexed(w,h,p,pal)
    assert(w>0 and h>0 and #p==w*h and #pal==768)
    for _,v in ipairs(p) do assert(v>=0 and v<=255) end
    for _,v in ipairs(pal) do assert(v>=0 and v<=255) end
    return {w=w,h=h,p=p,pal=pal}
end
function sound_create_pcm(rate,bits,ch,signed,s)
    assert(rate==11025 and bits==8 and ch==1 and not signed and #s>0);return s
end
assert(engine.detect(arg[1]));assert(not engine.detect('/tmp'))
local tree=engine.get_resources(arg[1]);local errors={};local examples={}
local function walk(nodes)
    for _,n in ipairs(nodes) do
        assert(not ids[n.id],'Duplicate '..n.id);ids[n.id]=true
        if n.children then walk(n.children) else
            counts[n.type]=(counts[n.type] or 0)+1
            if arg[2]~='catalog' then
                local ok,r=pcall(engine.load_resource,arg[1],n.id)
                if not ok or not r then errors[#errors+1]=n.id..': '..tostring(r)
                else loaded[n.type]=(loaded[n.type] or 0)+1;examples[n.name]=examples[n.name] or n.id end
                collectgarbage('collect')
            end
        end
    end
end
walk(tree)
for k,v in pairs(counts) do print(k..': '..v..' ('..(loaded[k] or 0)..' loaded)') end
for _,e in ipairs(errors) do print('ERROR '..e) end
assert(#errors==0,tostring(#errors)..' resource failures')
if arg[2]~='catalog' then
    local id=assert(examples['101SCE01.CRP']);local r=engine.load_resource(arg[1],id)
    assert(r.image.w==640 and r.image.h==480 and r.image.p[1]==51 and r.image.p[2]==62)
    local pal=assert(engine.default_palette(arg[1],id));local other=assert(examples['CIMENG.CPA'])
    assert(pal~=other);local changed=engine.load_resource(arg[1],id,other)
    assert(table.concat(changed.image.pal,',')~=table.concat(r.image.pal,','))
end
print('City real-data catalog and decoder checks passed')

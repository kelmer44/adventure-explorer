-- lua scripts/tests/grim.lua [game folder] [image|sound|text|palette]
-- Synthetic regressions run without game data. Optional scan checks every leaf
-- of the chosen type (all types when omitted), including all stored image states.
local e=dofile('scripts/engines/grim/engine.lua')
local function up(f,key)
    for i=1,100 do local n,v=debug.getupvalue(f,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local function le16(v) return string.char(v%256,math.floor(v/256)%256) end
local function le32(v) return le16(v%65536)..le16(math.floor(v/65536)) end
local function be16(v) return string.char(math.floor(v/256)%256,v%256) end
local function be32(v) return be16(math.floor(v/65536))..be16(v%65536) end
local decode=up(up(e.load_resource,'bitmap'),'codec3')
-- Literal, short overlapping reference, long reference and end marker.
assert(table.concat(decode(le16(0x41)..'A'..string.char(255,0,240,0),4),',')=='65,65,65,65')
assert(table.concat(decode(le16(0x15)..'A'..string.char(255,255,0,240,0),19),',')==string.rep('65,',18)..'65')
assert(not pcall(decode,le16(0x41)..'A'..string.char(255,0,240,0),3))
assert(not pcall(decode,le16(0)..string.char(255),4))
assert(not pcall(decode,le16(2)..string.char(0,240,0),2))
local vima=up(up(e.load_resource,'sound'),'vima')
-- VIMA predictors, absolute escape, short final block, stereo and IMA4 branch.
assert(vima(string.char(0,0,0,0),2)=='\0\0')
assert(vima(string.char(0,0,0,0x71,0x23,0x40),2)==le16(0x1234))
assert(vima(string.char(255,0,12,0,0,34,0),4)==le16(12)..le16(34))
assert(vima(string.char(0,0,0)..'IMA4'..'\0',4)==le16(0)..le16(0))
assert(not pcall(vima,string.char(89,0,0,0),2))
assert(not pcall(vima,string.char(0,0,0,0x70),2))
local bitmap=up(e.load_resource,'bitmap')
local header='BM  F\0\0\0'..le32(0)..le32(0)..le32(2)..string.rep('\0',12)..le32(1)..le32(16)..string.rep('\0',88)
assert(#header==128)
local last_rgb,last_pcm
function image_create_rgb(w,h,p) assert(w==1 and h==1);last_rgb=p;return 1 end
function image_create_indexed(w,h,p,pal) assert(#p==w*h and #pal==768);return 2 end
local bm=header..le32(1)..le32(1)..le16(0xf800)..le32(1)..le32(1)..le16(0x07e0)
assert(bitmap(bm,2,false).type=='image' and last_rgb[1]==0 and last_rgb[2]==255 and last_rgb[3]==0)
assert(not pcall(bitmap,bm:sub(1,-2),2,false))
local sound=up(e.load_resource,'sound')
function sound_create_pcm(rate,bits,ch,sign,s)
    assert(rate==22050 and bits==16 and ch==1 and sign);last_pcm=s;return 1
end
local wave='RIFF'..le32(38)..'WAVEfmt '..le32(16)..le16(1)..le16(1)..le32(22050)..le32(44100)..le16(2)..le16(16)..'data'..le32(2)
local mcmp='MCMP'..be16(2)..'\0'..be32(44)..be32(44)..'\1'..be32(2)..be32(4)..be16(10)..'NULL\0VIMA\0'..wave..string.char(0,0,0,0)
assert(sound(mcmp).type=='sound' and last_pcm=='\0\0')
assert(not pcall(sound,mcmp:sub(1,-2)))
local names='room.bm\0'
local offset=16+16+#names
local lab='LABN'..le32(0x10000)..le32(1)..le32(#names)..le32(0)..le32(offset)..le32(#bm)..le32(0)..names..bm
local fs={['fixture/DATA000.LAB']=lab}
function file_open(p) return fs[p] end
function file_close() end
function file_read(s,o,n) return s:sub(o+1,o+n) end
function file_size(s) return #s end
function list_files(p) return p=='fixture' and {'DATA000.LAB'} or {} end
assert(e.detect('fixture') and not e.detect('missing'))
local flat_list=list_files
fs['disc/GRIMDATA/DATA000.LAB']=lab
function list_files(p)
    if p=='disc' then return {'GRIMDATA'} end
    if p=='disc/GRIMDATA' then return {'DATA000.LAB'} end
    return flat_list(p)
end
assert(e.detect('disc'))
fs['disc/GRIMDATA/DATA000.LAB']=lab:sub(1,4)..le32(0)..lab:sub(9)
assert(not e.detect('disc'))

local tree=e.get_resources('fixture');assert(#tree==2 and #tree[2].children[1].children==2)
assert(e.load_resource('fixture','grim/2').type=='image')
fs['fixture/DATA000.LAB']=lab:sub(1,20)..le32(999999)..lab:sub(25)
assert(not e.detect('fixture'))
print('Grim LAB, bitmap states, codec 3, VIMA, MCMP and malformed-data regressions passed')
if not arg[1] then return end
function file_open(p) return io.open(p,'rb') end
function file_close(f) f:close() end
function file_size(f) return f:seek('end') end
function file_read(f,o,n) assert(f:seek('set',o));return f:read(n) end
function list_files(p)
    local names={};local f=assert(io.popen("ls -1 '"..p:gsub("'","'\\''").."' 2>/dev/null"))
    for name in f:lines() do names[#names+1]=name end;f:close();return names
end
function image_create_rgb(w,h,p)
    assert(#p==w*h*3)
    for _,v in ipairs(p) do assert(v>=0 and v<=255) end
    return 1
end
function sound_create_pcm(rate,bits,ch,sign,s)
    assert(rate>=4000 and (bits==8 or bits==16) and (ch==1 or ch==2) and #s>0 and #s%(ch*bits/8)==0)
    return 1
end
assert(e.detect(arg[1]))
local counts,seen={},{}
local function walk(nodes)
    for _,n in ipairs(nodes) do
        assert(not seen[n.id],n.id);seen[n.id]=true
        if n.children then walk(n.children)
        elseif not arg[2] or arg[2]==n.type then
            local r=assert(e.load_resource(arg[1],n.id),n.id)
            assert(not (r.text and r.text:match('Unable to preview:')),n.id..': '..(r.text or ''))
            if n.type=='image' then assert(r.type=='image',n.id) end
            if n.type=='sound' then assert(r.type=='sound',n.id) end
            counts[n.type]=(counts[n.type] or 0)+1
        end
    end
end
walk(e.get_resources(arg[1]))
for kind,n in pairs(counts) do print(kind..': '..n) end
print('All selected resources decoded successfully')

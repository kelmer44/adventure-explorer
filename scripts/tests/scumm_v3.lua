-- lua scripts/tests/scumm_v3.lua [EGA Loom directory] [PPM output directory]
package.path = 'scripts/engines/scumm/?.lua;' .. package.path
if not bit32 then
    bit32 = {}
    function bit32.band(a,b) return a & b end
    function bit32.bor(a,b) return a | b end
    function bit32.bxor(a,b) return a ~ b end
    function bit32.lshift(a,b) return (a << b) & 0xffffffff end
    function bit32.rshift(a,b) return (a & 0xffffffff) >> b end
end
function xor_bytes(d,key)
    local out={};for i=1,#d do out[i]=string.char(bit32.bxor(d:byte(i),key:byte((i-1)%#key+1))) end
    return table.concat(out)
end
local fake={}
function file_open(p) return fake[p] or io.open(p,'rb') end
function file_exists(p) local f=file_open(p);if f then if type(f)~='string' then f:close() end;return true end;return false end
function file_close(f) if type(f)~='string' then f:close() end end
function file_size(f) if type(f)=='string' then return #f end;return f:seek('end') end
function file_read(f,o,n) if type(f)=='string' then return f:sub(o+1,o+n) end;f:seek('set',o);return f:read(n) or '' end
function log_warn(s) error(s) end
local images={}
function image_create_indexed(w,h,p,pal)
    assert(w>0 and h>0 and #p==w*h and #pal==768)
    for _,v in ipairs(p) do assert(v>=0 and v<=255 and v%1==0) end
    images[#images+1]={w=w,h=h,p=p,pal=pal};return #images
end
function animation_create(handles,delay)
    assert(#handles>0 and delay>0)
    return 1
end
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing upvalue '..key)
end
local v3=require('scumm_v3')
local bitmap=up(v3.load_resource,'bitmap')
local function le(n) return string.char(n%256,math.floor(n/256)) end
-- Alternating runs reset nibble parity per run; repeat commands copy the
-- previous column, including across strip boundaries.
local encoded=le(9)..le(4)..string.char(0xc4,0x12,0x84,0x44,0x44)
local p=bitmap(encoded,0,8,2)
assert(table.concat(p,',')=='1,1,1,1,4,4,4,4,2,2,2,2,4,4,4,4')
assert(not pcall(bitmap,encoded:sub(1,-2),0,8,2))
assert(not pcall(bitmap,le(5)..le(4)..string.char(0x80),0,8,2))
-- V3 limb command offsets are bytes, with FF stopping a limb. V5 uses words.
local bytes={};for i=1,128 do bytes[i]=0 end
local function put(off,...) for i,v in ipairs({...}) do bytes[off+i]=v end end
put(4,0,0x58,1);put(7,100,0);put(41,60,0)
put(60,0,0xc0,5,1,0xff)
local chars={};for i,b in ipairs(bytes) do chars[i]=string.char(b) end
local c=assert(require('scumm_cost').parse(table.concat(chars),3))
local limbs=c:parse_anim(0)
assert(c.base==0 and c.anim_cmds==100 and c.pal[1]==0 and c.pal[2]==2)
assert(limbs[0].start==5 and limbs[0].stop==6 and limbs[1]==nil)
local good=le(0x100)..le(1)..string.rep('\0',4)..string.char(0,0,0,0)
fake['fixture/00.LFL']=xor_bytes(good,'\255')
assert(v3.detect('fixture'))
fake['fixture/00.LFL']=xor_bytes(good:sub(1,-2),'\255')
assert(not v3.detect('fixture'))
local v2=dofile('scripts/engines/scummv2/engine.lua')
fake['fixture/01.LFL']='x'
fake['fixture/00.LFL']=xor_bytes(good,'\255')
assert(not v2.detect('fixture'))
fake['fixture/00.LFL']=xor_bytes(le(0x100)..le(1)..string.rep('\0',5),'\255')
assert(v2.detect('fixture') and not v3.detect('fixture'))
print('V3 EGA strip decoding, malformed input and V2/V3 detection regressions passed')
if not arg[1] then return end
local engine=dofile('scripts/engines/scumm/engine.lua')
assert(engine.detect(arg[1]) and not v2.detect(arg[1]))
local counts,ids={},{}
local function walk(nodes)
    for _,n in ipairs(nodes) do
        assert(not ids[n.id],'Duplicate '..n.id);ids[n.id]=true
        if n.children then walk(n.children) else
            images={}
            local ok,r=pcall(engine.load_resource,arg[1],n.id)
            assert(ok,n.id..': '..tostring(r));assert(r,'Failed '..n.id)
            assert(r.type=='image' or r.type=='animation' or r.type=='text',n.id)
            if r.type=='text' then counts.empty=(counts.empty or 0)+1 end
            local kind=n.id:match('^v3:(%a+)');counts[kind]=(counts[kind] or 0)+1
            if arg[2] and (n.id=='v3:bg:2' or n.id=='v3:sheet:1') then
                local im=images[r.image];local f=assert(io.open(arg[2]..'/'..kind..'.ppm','wb'))
                f:write('P6\n'..im.w..' '..im.h..'\n255\n')
                for _,c in ipairs(im.p) do f:write(string.char(im.pal[c*3+1],im.pal[c*3+2],im.pal[c*3+3])) end
                f:close()
            end
        end
    end
end
walk(engine.get_resources(arg[1]))
assert((counts.bg or 0)>0 and (counts.obj or 0)>0 and (counts.sheet or 0)>0)
for _,k in ipairs({'bg','obj','sheet','anim','pal','empty'}) do print(k..': '..(counts[k] or 0)) end

-- lua scripts/tests/tucker.lua [game-folder] [catalog|all]
local engine=dofile('scripts/engines/tucker/engine.lua')
local function up(fn,key)
    for i=1,100 do local n,v=debug.getupvalue(fn,i);if n==key then return v end;if not n then break end end
    error('Missing helper '..key)
end
local pcx=up(engine.load_resource,'pcx')
local frames=up(engine.load_resource,'spr_frames')
local pixels=up(engine.load_resource,'spr_pixels')
local wave=up(engine.load_resource,'wave')
local decode=up(engine.load_resource,'decode_table')
local text=up(engine.load_resource,'text_utf8')
local function w(n) return string.char(n%256,math.floor(n/256)%256) end
local function dw(n) return w(n%65536)..w(math.floor(n/65536)) end
local function rejects(fn,...) assert(not pcall(fn,...),'Malformed input accepted') end
local palette=string.char(12)..string.rep(string.char(10,20,30),256)
local hdr=string.char(10,5,1,8)..w(0)..w(0)..w(2)..w(1)..string.rep('\0',52)..string.char(0,1)..w(4)..string.rep('\0',60)
assert(#hdr==128)
local pic=pcx(hdr..string.char(193,200,2,3,99,4,5,6,99)..palette)
assert(pic.w==3 and pic.h==2 and #pic.pixels==6 and pic.pixels[1]==200 and pic.pixels[4]==4 and pic.palette[3]==30)
rejects(pcx,hdr..string.char(255,1)..palette)
rejects(pcx,hdr..string.char(192,1)..palette)
rejects(pcx,hdr..palette)
local spr=dw(2)..dw(12)..dw(28)..w(3)..w(1)..dw(0)..w(5)..w(7)..string.char(8,0,2,0)..w(1)..w(1)..dw(0)..w(0)..w(0)..string.char(9)
local fs=frames(spr);assert(#fs==2 and fs[1].x==5 and fs[1].y==7)
local bounds=up(engine.load_resource,'spr_bounds')
local x,y,bw,bh=bounds(fs);assert(x==0 and y==0 and bw==8 and bh==8)
-- Offset slot high bytes are flags, and zero runs can cross row boundaries.
assert(#frames(spr:sub(1,7)..string.char(128)..spr:sub(9))==2)
assert(#pixels(string.rep('\0',12)..string.char(0,4),{offset=0,finish=14,w=2,h=2})==4)
local px=pixels(spr,fs[1]);assert(#px==3 and px[1]==8 and px[2]==0 and px[3]==0)
assert(pixels(spr,fs[2])[1]==9)
rejects(frames,dw(999999));rejects(frames,dw(1)..dw(4)..string.rep('\0',20))
rejects(pixels,spr:sub(1,24)..string.char(0,4),{offset=12,finish=26,w=3,h=1})
local function chunk(tag,s) return tag..dw(#s)..s..(#s%2==1 and '\0' or '') end
local fmt=w(1)..w(1)..dw(22050)..dw(22050)..w(1)..w(8)
local body='WAVE'..chunk('JUNK','x')..chunk('fmt ',fmt)..chunk('data','abc')
local wav='RIFF'..dw(#body)..body
function sound_create_pcm(rate,bits,ch,signed,data)
    assert(rate==22050 and bits==8 and ch==1 and not signed and data=='abc');return 1
end
assert(wave(wav)==1);rejects(wave,wav:sub(1,-3))
rejects(wave,'RIFF'..dw(#body)..body:gsub('fmt '..dw(16)..w(1),'fmt '..dw(16)..w(2),1))
local all={};for i=0,255 do all[#all+1]=string.char(i) end
local s=table.concat(all);assert(decode(decode(s))==s)
assert(text('caf'..string.char(130)..' '..string.char(168))=='café ¿')
print('Tucker PCX, SPR, WAV and text regressions passed')
if not arg[1] then return end
function file_open(p) return io.open(p,'rb') end
function file_close(f) f:close() end
function file_size(f) return f:seek('end') end
function file_read(f,p,n) assert(f:seek('set',p));return f:read(n) end
function file_exists(p)
    local parent,name=p:match('^(.*)/([^/]+)$')
    local pipe=io.popen('ls -1 '..string.format('%q',parent))
    for f in pipe:lines() do if f:upper()==name:upper() then pipe:close();return true end end
    pipe:close();return false
end
function list_files(p)
    local pipe=io.popen('ls -1 '..string.format('%q',p)..' 2>/dev/null');local names={}
    for n in pipe:lines() do names[#names+1]=n end;pipe:close();return names
end
local imageCount,animationCount=0,0
function image_create_indexed(wi,he,p,pal)
    assert(wi>0 and he>0 and #p==wi*he and #pal==768)
    for _,v in ipairs(p) do assert(v>=0 and v<=255) end
    imageCount=imageCount+1;return imageCount
end
function animation_create(handles,delay) assert(#handles>0 and #handles<=60 and delay==100);animationCount=animationCount+1;return animationCount end
function sound_create_pcm(rate,bits,ch,signed,data)
    assert(rate>0 and (bits==8 or bits==16) and (ch==1 or ch==2) and #data>0 and signed==(bits==16));return 1
end
assert(engine.detect(arg[1]));assert(not engine.detect('/tmp'))
local counts,seen={},{}
local function walk(nodes)
    for _,n in ipairs(nodes) do
        assert(not seen[n.id],'Duplicate ID '..n.id);seen[n.id]=true
        if n.children then walk(n.children)
        else
            counts[n.type]=(counts[n.type] or 0)+1
            if arg[2]~='catalog' then
                local r=engine.load_resource(arg[1],n.id)
                local expected=n.type=='data' and 'text' or n.type=='palette' and 'image' or n.type
                assert(r and r.type==expected,n.id..': '..tostring(r and r.text))
                if r.text then assert(not r.text:find('Cannot decode:',1,true),n.id..': '..r.text) end
            end
        end
    end
end
walk(engine.get_resources(arg[1]))
for k,v in pairs(counts) do print(k,v) end
assert(engine.default_palette(arg[1],'sprite:SPRITES/A01_01.SPR:1')=='pal:LOC01.PCX')
assert(engine.default_palette(arg[1],'sprite:SPRITES/A09_01.SPR:1')=='pal:LOC09B.PCX')
assert(engine.default_palette(arg[1],'pcx:PATH01.PCX')=='pal:grayscale')
assert(engine.load_resource(arg[1],'pal:grayscale').type=='image')
assert(engine.load_resource(arg[1],'sprite:SPRITES/A01_01.SPR:1','pal:grayscale').type=='image')
print('Real game scan passed; decoded images '..imageCount..', animation batches '..animationCount)

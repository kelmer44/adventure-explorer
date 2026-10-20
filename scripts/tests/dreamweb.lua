-- Synthetic format regressions, runnable in native Lua and the app's LuaJ.
local engine = dofile('scripts/engines/dreamweb/engine.lua')
local function up(fn, key)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if name == key then return value end
        if not name then break end
    end
    error('Missing helper ' .. key)
end
local function w(n) return string.char(n%256, math.floor(n/256)%256) end
local function be(n) return string.char(math.floor(n/16777216)%256, math.floor(n/65536)%256,math.floor(n/256)%256,n%256) end
local index = up(engine.get_resources,'build_index')
local header = up(index,'header')
local frames = up(index,'frames')
local pcx_header = up(index,'pcx_header')
local pcx_pixels = up(engine.load_resource,'pcx_pixels')
local strings = up(index,'strings')
local palette = up(index,'palette_iff')
local sounds = up(index,'sound_entries')
local tiles = up(engine.load_resource,'tile_pixels')
local pixels = up(engine.load_resource,'frame_pixels')
local box = up(index,'animation_box')
local magic = 'DREAMWEB DATA' .. string.rep(' ',37)
local head = magic .. w(2086) .. string.rep('\0',44)
local f = string.char(2,2)..w(2)..string.char(1,3)
local data = head .. f .. string.rep('\0',2074) .. string.char(99,99,1,2,0,4)
local seg = assert(header(data,1))
local fs = frames(data,seg[0]); assert(fs[0].offset==2178 and fs[0].size==4 and fs[0].x==1)
assert(not header(data:sub(1,-2),1))
assert(not header('invalid',1))
local invalid = head .. string.char(2,2)..w(3)..string.char(1,3)..data:sub(103)
assert(not frames(invalid,seg[0])[0])
local bounds = box({fs[0]}); assert(bounds.width==3 and bounds.height==5)
local px,width,height = pixels(string.char(1,2,0,4),fs[0],bounds)
assert(width==3 and height==5 and px[11]==1 and px[12]==2 and px[14]==0 and px[15]==4)
assert(not pixels('',fs[0]))
assert(not box({{width=255,height=255,x=255,y=255},{width=255,height=255,x=255,y=255}, {width=4096,height=4096,x=0,y=0}}))
local cmap = string.rep(string.char(255,129,3),256)
local iff = 'FORM' .. be(4+8+768) .. 'ILBM' .. 'CMAP' .. be(768) .. cmap
local pal = assert(palette(iff)); assert(#pal==768 and pal[1]==252 and pal[2]==128 and pal[3]==0)
assert(not palette(iff:sub(1,-2)))
assert(not palette('FORM'..be(0)..'ILBM'..'CMAP'..be(4294967295)))
local txt = w(0)..w(5)..w(999)..'Caf'..string.char(130)..'\0Next\0'
local ss = strings(txt,{offset=0,size=#txt},3)
assert(ss[0]=='Café' and ss[1]=='Next' and not ss[2])
assert(not strings(txt:sub(1,-2),{offset=0,size=#txt-1},3)[1])
local sound = magic .. w(12) .. string.rep('\0',44) .. string.char(0)..w(0)..w(1)..'\0' .. string.char(0)..w(65535)..w(1)..'\0' .. string.rep('\128',2048)
local se = sounds(sound); assert(se[0].offset==108 and se[0].size==2048 and not se[1])
assert(not sounds(sound:sub(1,-2))[0])
local td = string.rep('\7',256)..string.rep('\9',256)
local ts,tw,th = tiles(td,{size=512,tiles=2,kind='tiles'})
assert(tw==256 and th==16 and ts[1]==7 and ts[17]==9 and ts[33]==0)
local cells={};for i=1,110 do cells[i]=0 end;cells[2]=1
local mp,mw,mh=tiles(td,{size=512,kind='map',cells=cells})
assert(mw==176 and mh==160 and mp[1]==0 and mp[17]==9)
cells[2]=2;assert(not tiles(td,{size=512,kind='map',cells=cells}))
-- Two padded bitplanes: indexes 1,2,3,0; source is MSB-first.
local h = string.char(10,5,1,1)..w(0)..w(0)..w(3)..w(0)..w(4)..w(1)
    ..string.rep('\0',48)..'\0'..string.char(2)..w(2)..string.rep('\0',60)
assert(#h==128)
local pcx = h .. string.char(160,0,96,0)
local ph=assert(pcx_header(pcx));assert(ph.width==4 and ph.planes==2)
local decoded=assert(pcx_pixels(pcx,ph))
assert(decoded[1]==1 and decoded[2]==2 and decoded[3]==3 and decoded[4]==0)
assert(not pcx_pixels(pcx:sub(1,-2),ph))
local over = h .. string.char(197,0);assert(not pcx_pixels(over,assert(pcx_header(over))))
assert(not pcx_header(h:sub(1,3)..string.char(4)..h:sub(5)))
-- Full public path test with a virtual installed folder; do not trust resource IDs as paths.
function file_open(path) if path=='game/DREAMWEB.R00' then return data elseif path=='game/DREAMWEB.PAL' then return iff end end
function file_exists(path) return file_open(path)~=nil end
function file_read(d,o,n) return d:sub(o+1,o+n) end
function file_size(d) return #d end
function file_close() end
function list_files() return {} end
assert(engine.detect('game') and not engine.detect('wrong'))
assert(not engine.load_resource('game','../../etc/passwd'))
print('DreamWeb bounds, VGA palette, frame offsets, PCX planes/RLE, PCM offsets, text and tile-map regressions passed')

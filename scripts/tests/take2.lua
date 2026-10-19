-- lua scripts/tests/take2.lua [TAKE2 parent folder] [comma-separated resource IDs]
local engine=dofile('scripts/engines/take2/engine.lua');local d=engine._debug
local function le16(n) return string.char(n%256,math.floor(n/256)) end
local function image(w,h,stream,flags,tail,mode,map,pal)
    return string.char(flags or 0,2,255,255,mode or 2)..string.char(0,1,2)..string.rep('\0',12)
        ..le16(tail or 0)..le16(h)..le16(w)..le16(#stream)..stream..(pal or '')..(map or '')
end
local w,h,p=d.packed(image(3,1,string.char(0,0x11)))
assert(w==3 and h==1 and table.concat(p,',')=='0,1,2')
local _,_,p=d.packed(image(6,1,string.char(1,0x3e,0)))
assert(#p==6 and p[6]==1)
local _,_,p=d.packed(image(2,2,string.char(0,1,2,1),0,2))
assert(table.concat(p,',')=='0,1,2,1')
local _,_,p,pal=d.packed(image(3,1,string.char(0,0x11),3,0,2,string.char(9,8,7),string.rep(string.char(63,32,1),256)))
assert(table.concat(p,',')=='9,8,7' and #pal==768 and pal[1]==252 and pal[2]==128)
assert(not pcall(d.packed,image(5,1,string.char(1,0x3e,0)))) -- run overflows
assert(not pcall(d.packed,image(4,1,string.char(0)))) -- truncated nibbles
assert(not d.packed_header(string.rep('\0',28),28))
assert(d.text('Espa\164a~Si\0')=='España\nSi\n')
print('Take-Two synthetic regressions passed')
if not arg[1] then return end
local function quote(s) return "'"..s:gsub("'","'\\''").."'" end
function list_files(path)
    local p=io.popen('ls -1 '..quote(path));local out={};for n in p:lines() do out[#out+1]=n end;p:close();return out
end
function file_open(path) return io.open(path,'rb') end
function file_size(f) local pos=f:seek();local n=f:seek('end');f:seek('set',pos);return n end
function file_read(f,o,n) f:seek('set',o);return n==0 and '' or f:read(n) or '' end
function file_close(f) f:close() end
function image_create_indexed(w,h,p,pal)
    assert(#p==w*h,'Pixel count mismatch');assert(#pal==768,'Palette size mismatch')
    for _,v in ipairs(p) do assert(v>=0 and v<=255) end
    return {w=w,h=h}
end
function animation_create(frames,delay) assert(#frames>0 and delay>0);return true end
function sound_create_encoded(s) assert(s:sub(1,4)=='RIFF' or s:sub(1,19)=='Creative Voice File');return true end
function midi_create_raw(s) assert(s:sub(1,4)=='MThd');return true end
local selected
if arg[2] then selected={};for id in arg[2]:gmatch('[^,]+') do selected[id]=true end end
for _,game in ipairs({'B13','HELL'}) do
    local path=arg[1]..'/'..game;assert(engine.detect(path));local totals={};local seen={};local failures={}
    local function scan(nodes)
        for _,node in ipairs(nodes) do
            assert(not seen[node.id],'Duplicate '..node.id);seen[node.id]=true
            if node.children then scan(node.children) elseif not selected or selected[node.id] then
                local r=assert(engine.load_resource(path,node.id),node.id)
                totals[node.type]=(totals[node.type] or 0)+1
                if r.description:find('decode error',1,true) then failures[#failures+1]=node.id..' '..r.text
                elseif node.type=='image' or node.type=='palette' then assert(r.image,node.id)
                elseif node.type=='animation' then assert(r.animation,node.id)
                elseif node.type=='sound' then assert(r.sound,node.id)
                elseif node.type=='midi' then assert(r.midi,node.id) else assert(r.text,node.id) end
            end
        end
    end
    scan(engine.get_resources(path));print(game)
    for k,v in pairs(totals) do print('  '..k..': '..v) end
    print('  failures: '..#failures);for _,v in ipairs(failures) do print(v) end
    assert(#failures==0)
end

-- Take-Two DOS libraries: Bureau 13 and Hell: A Cyberpunk Thriller.
-- Format verified against the supplied DOS files and Bureau 13's image decoder.
local engine={id='take2',name='Take-Two (Bureau 13 / Hell)',version='1.0',
    description='Bureau 13 and Hell: A Cyberpunk Thriller, original DOS resources'}
local floor=math.floor
local function u16(s,p) assert(p>=1 and p+1<=#s,'Truncated word');return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function read(e,off,n)
    off=off or 0;n=n or e.size
    assert(off>=0 and n>=0 and off+n<=e.size and n<=67108864,'Read outside resource')
    if n==0 then return '' end
    local f=assert(file_open(e.path),'Missing '..e.path)
    local ok,s=pcall(file_read,f,e.offset+off,n);file_close(f)
    assert(ok and s and #s==n,'Truncated '..e.name);return s
end
-- All offsets are relative to this library, including nested libraries.
local function directory(e)
    if e.size<6 then return end
    local head=read(e,0,6);local n,off=u16(head,1),u32(head,3)
    if n==0 or n>20000 or off<6 or off+n*12~=e.size then return end
    local s=read(e,off,n*12);local entries={}
    for i=0,n-1 do
        local p=i*12+1;local start=u32(s,p)
        local finish=i+1<n and u32(s,p+12) or off
        local name=s:sub(p+4,p+11):match('^[^%z]*')
        assert(start>=6 and finish>=start and finish<=off and name~='','Invalid library directory')
        entries[#entries+1]={path=e.path,offset=e.offset+start,size=finish-start,name=name}
    end
    return entries
end
local function gray() local p={};for i=0,255 do for _=1,3 do p[#p+1]=i end end;return p end
local function vga(s)
    assert(#s<=768 and #s%3==0,'Invalid VGA palette');local p={}
    for i=1,768 do local v=s:byte(i) or 0;assert(v<=63,'Invalid VGA component');p[i]=v*4 end
    return p
end
local function packed_header(s,size)
    if #s<28 or s:byte(1)>3 or (s:byte(5)~=1 and s:byte(5)~=2) then return end
    local h,w,n=u16(s,23),u16(s,25),u16(s,27)
    local flags=s:byte(1);local pal=flags%2==1 and (s:byte(3)+1)*3 or 0
    local map=floor(flags/2)%2==1 and s:byte(2)+1 or 0
    local tail=u16(s,21)
    if w==0 or h==0 or w>2048 or h>2048 or w*h>2097152 or n==0 or tail>=w*h or tail>n
        or 28+n+pal+map~=size then return end
    return {w=w,h=h,n=n,pal=pal,map=map,tail=tail,mode=s:byte(5),mod=s:byte(2)+1}
end
local function packed(s)
    local im=assert(packed_header(s,#s),'Invalid packed image')
    local data=s:sub(29,28+im.n);local mapping=s:sub(29+im.n+im.pal)
    local function color(v)
        assert(v<im.mod,'Invalid packed color')
        return im.map>0 and assert(mapping:byte(v+1),'Truncated color map') or v
    end
    local current=data:byte(1);local pixels={color(current)};local pos=2
    local function nibble()
        assert(floor(pos/2)+1<=#data-im.tail,'Truncated packed stream')
        local v=floor(data:byte(floor(pos/2)+1)/2^(pos%2*4))%16;pos=pos+1;return v
    end
    local function byte() local a=nibble();return a+nibble()*16 end
    local target=im.w*im.h-im.tail
    while #pixels<target do
        local op=nibble()
        if op==14 and im.mode==2 then
            local count=byte();if count==255 then local hi=byte();count=hi*256+byte() end
            count=count+2;assert(#pixels+count<=target,'Packed run overflow')
            local v=pixels[#pixels];for _=1,count do pixels[#pixels+1]=v end
        else
            if op==15 then current=byte() else current=(current+s:byte(6+op))%im.mod end
            pixels[#pixels+1]=color(current)
        end
    end
    for i=im.n-im.tail+1,im.n do pixels[#pixels+1]=color(data:byte(i)) end
    local pal=im.pal>0 and vga(s:sub(29+im.n,28+im.n+im.pal)) or nil
    return im.w,im.h,pixels,pal
end
local function picture(s)
    assert(#s>=897 and s:sub(1,4)=='\10\5\1\8','Invalid picture header')
    local w,h=u16(s,9)-u16(s,5)+1,u16(s,11)-u16(s,7)+1
    local stride=u16(s,67)
    assert(w>0 and h>0 and w<=4096 and h<=2048 and stride>=w and stride<=4096 and s:byte(66)==1,'Invalid picture dimensions')
    assert(s:byte(#s-768)==12,'Missing PCX palette')
    local p,finish,n=129,#s-769,0
    local pixels,palette={},{}
    while p<=finish and n<stride*h do
        local v=s:byte(p);p=p+1;local count=1
        if v>=192 then
            count=v-192;assert(count>0 and p<=finish,'Truncated PCX run');v=s:byte(p);p=p+1
        end
        assert(n+count<=stride*h,'PCX run overflow')
        for _=1,count do
            local x=n%stride
            if x<w then pixels[math.floor(n/stride)*w+x+1]=v end
            n=n+1
        end
    end
    assert(n==stride*h,'Incomplete PCX pixels')
    for i=1,768 do palette[i]=s:byte(#s-768+i) end
    return w,h,pixels,palette
end

-- Standard Autodesk FLI/FLC; bounded preview, adapted from sulfato.
local function decode_cel(s,first,last)
    assert(#s>=128 and (u16(s,5)==0xAF12 or u16(s,5)==0xAF11),'Invalid CEL header')
    local count,w,h=u16(s,7),u16(s,9),u16(s,11)
    assert(count>0 and count<=10000 and w>0 and h>0 and w<=2048 and h<=2048,'Invalid CEL dimensions')
    first=first or 1;last=math.min(last or count,count,60,math.max(1,floor(8000000/(w*h))))
    assert(first>=1 and last>=first and (last-first+1)*w*h<=8000000,'CEL preview too large')
    local pos=u32(s,81)+1;if pos==1 then pos=129 end
    local pixels,palette,handles={},{},{}
    for i=1,w*h do pixels[i]=0 end
    for i=1,768 do palette[i]=0 end
    local delay=u16(s,5)==0xAF11 and floor(u16(s,17)*1000/70) or u32(s,17)
    for frame=1,last do
        assert(pos>=129 and pos+15<=#s,'Truncated FLC frame header')
        local frameSize=u32(s,pos)
        assert(frameSize>=16 and pos+frameSize<=#s+1 and u16(s,pos+4)==0xF1FA,'Invalid CEL frame')
        local chunks=u16(s,pos+6);local speed=u16(s,pos+8)
        if speed>0 then delay=speed end
        local nw,nh=u16(s,pos+12),u16(s,pos+14)
        if nw~=0 or nh~=0 then
            w=nw~=0 and nw or w;h=nh~=0 and nh or h
            assert(w>0 and h>0 and w<=2048 and h<=2048 and w*h*(last-first+1)<=8000000,'CEL resize too large')
            pixels={};for i=1,w*h do pixels[i]=0 end
        end
        local cp=pos+16
        for chunkIndex=1,chunks do
            assert(cp+6<=pos+frameSize,'Truncated FLC chunk header')
            local cs=u32(s,cp);local kind=u16(s,cp+4)
            -- Hell's encoder undercounts some final COPY chunks by two bytes.
            local copySize=w*h+6+(w*h)%2
            if kind==16 and chunkIndex==chunks and cs==copySize-2 and cp+copySize==pos+frameSize then cs=copySize end
            assert(cs>=6 and cp+cs<=pos+frameSize and cp+cs<=#s+1,'Invalid CEL chunk')
            local data=s:sub(cp+6,cp+cs-1);local p=1
            local function byte() assert(p<=#data,'Truncated CEL chunk');local v=data:byte(p);p=p+1;return v end
            local function word() local a=byte();return a+byte()*256 end
            local function signed() local v=byte();return v<128 and v or v-256 end
            local function put(x,y,v) assert(x>=0 and x<w and y>=0 and y<h,'CEL pixel outside frame');pixels[y*w+x+1]=v end
            if kind==4 or kind==11 then
                local packets=word();local color=0
                for _=1,packets do
                    color=color+byte();local n=byte();if n==0 then n=256 end
                    assert(color+n<=256,'CEL palette overflow')
                    for i=color*3+1,(color+n)*3 do palette[i]=byte()*(kind==11 and 4 or 1) end
                    color=color+n
                end
            elseif kind==13 then
                for i=1,w*h do pixels[i]=0 end
            elseif kind==16 then
                assert(#data>=w*h,'Truncated CEL copy')
                for i=1,w*h do pixels[i]=data:byte(i) end
            elseif kind==15 then
                for y=0,h-1 do
                    byte();local x=0
                    while x<w do
                        local n=signed();assert(n~=0 and x+math.abs(n)<=w,'Invalid CEL byte run')
                        if n>0 then local v=byte();for _=1,n do put(x,y,v);x=x+1 end
                        else for _=1,-n do put(x,y,byte());x=x+1 end end
                    end
                end
            elseif kind==7 then
                local lines=word();local y=0
                assert(lines<=h,'Invalid CEL delta line count')
                for _=1,lines do
                    local packets
                    repeat
                        local op=word();local code=math.floor(op/16384)
                        if code==0 then packets=op
                        elseif code==2 then put(w-1,y,op%256)
                        elseif code==3 then y=y+65536-op;assert(y<h,'Invalid CEL line skip')
                        else error('Invalid CEL delta opcode') end
                    until packets
                    local x=0
                    for _=1,packets do
                        x=x+byte();local n=signed()
                        assert(x+math.abs(n)*2<=w,'Invalid CEL delta span')
                        if n>=0 then for _=1,n*2 do put(x,y,byte());x=x+1 end
                        else local a,b=byte(),byte();for _=1,-n do put(x,y,a);put(x+1,y,b);x=x+2 end end
                    end
                    y=y+1
                end
            elseif kind==12 then
                local y,lines=word(),word();assert(y+lines<=h,'FLC LC line overflow')
                for _=1,lines do
                    local packets=byte();local x=0
                    for _=1,packets do
                        x=x+byte();local n=signed();assert(x+math.abs(n)<=w,'FLC LC span overflow')
                        if n>=0 then for _=1,n do put(x,y,byte());x=x+1 end
                        else local v=byte();for _=1,-n do put(x,y,v);x=x+1 end end
                    end
                    y=y+1
                end
            elseif kind~=18 then error('Unsupported CEL chunk '..kind) end
            cp=cp+cs
        end
        if frame>=first then handles[#handles+1]=assert(image_create_indexed(w,h,pixels,palette)) end
        pos=pos+frameSize
    end
    return handles,math.max(1,delay),count
end
local cachedPath,tree,entries,palCache
local cp850 = {199,252,233,226,228,224,229,231,234,235,232,239,238,236,196,197,201,230,198,244,246,242,251,249,255,214,220,248,163,216,215,402,225,237,243,250,241,209,170,186,191,174,172,189,188,161,171,187,9617,9618,9619,9474,9508,193,194,192,169,9571,9553,9559,9565,162,165,9488,9492,9524,9516,9500,9472,9532,227,195,9562,9556,9577,9574,9568,9552,9580,164,240,208,202,203,200,305,205,206,207,9496,9484,9608,9604,166,204,9600,211,223,212,210,245,213,181,254,222,218,219,217,253,221,175,180,173,177,8215,190,182,167,247,184,176,168,183,185,179,178,9632,160}
local function utf8char(n)
    if n<128 then return string.char(n) end
    if n<2048 then return string.char(192+floor(n/64),128+n%64) end
    return string.char(224+floor(n/4096),128+floor(n/64)%64,128+n%64)
end
local function text(s)
    s=s:gsub('[%z~]', '\n'):gsub('[\1-\8\11\12\14-\31]', ' ')
    return (s:gsub('[\128-\255]',function(c) return utf8char(cp850[c:byte()-127]) end))
end
local function catalog(path)
    if cachedPath==path then return tree end
    cachedPath=nil;tree={};entries={};palCache={}
    local groups,folders={},{}
    for _,g in ipairs({{'backgrounds','Backgrounds and Screens'},{'sprites','Sprites and Images'},
        {'animations','Animation Previews'},{'palettes','Palettes'},{'sounds','Speech and Sound'},
        {'music','MIDI Music'},{'text','Dialogue and Text'},{'data','Game Data'}}) do
        local node={id=g[1],name=g[2],type='category',children={}};tree[#tree+1]=node;groups[g[1]]=node
    end
    local function add(group,typ,e,key)
        local id=key or e.id;assert(not entries[id],'Duplicate resource ID');e.id=id;entries[id]=e
        local folder=group..':'..e.folder
        if not folders[folder] then
            local node={id=folder,name=e.folder,type='category',children={}}
            folders[folder]=node;groups[group].children[#groups[group].children+1]=node
        end
        folders[folder].children[#folders[folder].children+1]={id=id,name=e.name,type=typ}
        return id
    end
    local function visit(e,folder,id,depth,inherited)
        assert(depth<=8,'Library nesting too deep');e.folder=folder;e.id=id
        local children=directory(e)
        if children then
            -- A sibling library does not establish the palette for this bank.
            local previous=nil
            for i,child in ipairs(children) do
                local pal=visit(child,folder..' / '..e.name,id..'/'..i,depth+1,previous)
                if pal then previous=pal end
            end
            return
        end
        local head=read(e,0,math.min(128,e.size));local im=packed_header(head,e.size)
        if e.path:upper():match('/TEXT%.GL$') and #head>=4 then
            local width,n=u16(head,1),u16(head,3);local stride=width+7
            if width>0 and width<=64 and n>0 and 4+n*stride<=e.size then
                local index=read(e,4,n*stride)
                for i=0,n-1 do
                    local p=i*stride+1;local off,size=u32(index,p+width+1),u16(index,p+width+5)
                    assert(off>=4+n*stride and off+size<=e.size,'Invalid text directory')
                    local name=index:sub(p,p+width):match('^[^%z]*')
                    local child={path=e.path,offset=e.offset+off,size=size,name=name,folder=folder..' / '..e.name,kind='text'}
                    add('text','text',child,id..'/text/'..i)
                end
                return
            end
        end
        local kind,group,typ='data','data','data'
        if im then
            kind='packed';typ='image';group=im.w>=320 and im.h>=200 and 'backgrounds' or 'sprites';e.im=im
        elseif head:sub(1,4)=='\10\5\1\8' then
            kind='pcx';typ='image';group='backgrounds'
        elseif #head>=128 and (u16(head,5)==0xAF12 or u16(head,5)==0xAF11) and u16(head,7)>0 and u16(head,9)>0 and u16(head,9)<=2048 and u16(head,11)>0 and u16(head,11)<=2048 then
            kind='flc';typ='animation';group='animations'
        elseif head:sub(1,4)=='RIFF' and head:sub(9,12)=='WAVE' or head:sub(1,19)=='Creative Voice File' then
            kind='sound';typ='sound';group='sounds'
        elseif head:sub(1,4)=='MThd' then kind='midi';typ='midi';group='music'
        elseif e.size==4864 and (e.name:lower()=='b13rtp' or folder:lower():match(' / rtp$')) then
            kind='rtp';typ='palette';group='palettes'
        end
        e.kind=kind;add(group,typ,e)
        if kind=='packed' and im.pal>0 or kind=='pcx' or kind=='rtp' then
            local pe={path=e.path,offset=e.offset,size=e.size,name=e.name,folder=folder,kind='palette',source=e}
            if kind=='rtp' then e.source=e;e.kind='palette';e.palette=id;return id end
            e.palette=add('palettes','palette',pe,'pal:'..id)
        elseif kind=='packed' then e.palette=inherited end
        return e.palette
    end
    local names=list_files(path) or {};table.sort(names,function(a,b) return a:upper()<b:upper() end)
    for _,name in ipairs(names) do
        local upper=name:upper()
        if upper:match('%.GL$') or upper:match('%.PL$') or upper:match('%.SL$') then
            local f=file_open(path..'/'..name)
            if f then
                local size=file_size(f);file_close(f)
                local e={path=path..'/'..name,offset=0,size=size,name=name}
                visit(e,'Libraries',upper,0,nil)
            end
        end
    end
    -- The Bureau's common palette is stored separately from individual actor banks.
    local common
    for id,e in pairs(entries) do if e.name:lower()=='b13rtp' then common=id end end
    for _,e in pairs(entries) do if e.kind=='packed' and not e.palette then e.palette=common end end
    local keep={};for _,node in ipairs(tree) do if #node.children>0 then keep[#keep+1]=node end end
    tree=keep;cachedPath=path;return tree
end
local function palette(id)
    if not id or not entries[id] or entries[id].kind~='palette' then return gray() end
    if palCache[id] then return palCache[id] end
    local e=entries[id].source;local p
    if e.kind=='pcx' then
        local s=read(e,e.size-769,769);assert(s:byte(1)==12,'Missing PCX palette');p={s:byte(2,769)}
    elseif e.im then p=vga(read(e,28+e.im.n,e.im.pal))
    else p=vga(read(e,0,768)) end
    palCache[id]=p;return p
end
function engine.detect(path)
    local function exists(name) local f=file_open(path..'/'..name);if f then file_close(f);return true end;return false end
    return exists('DATA.GL') and exists('TEXT.GL') and (exists('B13.DAT') or exists('B13.COM'))
        or exists('BACKGRND.PL') and exists('ARTWORK.PL') and exists('SOUND.SL')
end
function engine.get_resources(path) return catalog(path) end
function engine.default_palette(path,id) catalog(path);return entries[id] and entries[id].palette end
function engine.load_resource(path,id,override)
    catalog(path);local e=entries[id];if not e then return end
    local desc=e.folder..' / '..e.name
    local ok,result=pcall(function()
        if e.kind=='palette' then
            local pixels={};for y=0,255 do for x=0,255 do pixels[#pixels+1]=floor(y/16)*16+floor(x/16) end end
            return {type='image',image=image_create_indexed(256,256,pixels,palette(id)),description=desc}
        elseif e.kind=='packed' or e.kind=='pcx' then
            local w,h,pixels,pal
            if e.kind=='packed' then w,h,pixels,pal=packed(read(e)) else w,h,pixels,pal=picture(read(e)) end
            if override or not pal then pal=palette(override or e.palette) end
            -- Byte 3 is the transparent-color index before the optional remapping.
            local transparent
            if e.kind=='packed' and e.im.w<320 then
                local s=read(e,0,4);local index=s:byte(4)
                if index<e.im.mod then
                    if e.im.map>0 then transparent=read(e,28+e.im.n+e.im.pal+index,1):byte(1) else transparent=index end
                end
            end
            return {type='image',image=image_create_indexed(w,h,pixels,pal,transparent),
                description=desc..' / '..w..'x'..h..(not e.palette and e.kind=='packed' and ' / unassigned palette: grayscale' or '')}
        elseif e.kind=='flc' then
            local frames,delay,total=decode_cel(read(e))
            return {type='animation',animation=animation_create(frames,delay),image=frames[1],frames=frames,
                description=desc..' / '..#frames..' of '..total..' frames (bounded preview)'}
        elseif e.kind=='sound' then return {type='sound',sound=assert(sound_create_encoded(read(e)),'Unsupported audio'),description=desc}
        elseif e.kind=='midi' then return {type='midi',midi=midi_create_raw(read(e)),description=desc}
        elseif e.kind=='text' then return {type='text',text=text(read(e)),description=desc}
        end
        local s=read(e,0,math.min(256,e.size));local lines={desc,e.size..' bytes; undecoded game data'}
        for p=1,#s,16 do
            local line={};for i=p,math.min(p+15,#s) do line[#line+1]=string.format('%02X',s:byte(i)) end
            lines[#lines+1]=string.format('%08X  %s',p-1,table.concat(line,' '))
        end
        return {type='text',text=table.concat(lines,'\n'),description=desc}
    end)
    if ok then return result end
    return {type='text',text='Cannot decode resource: '..tostring(result),description=desc..' / decode error'}
end
engine._debug={packed=packed,packed_header=packed_header,directory=directory,picture=picture,flc=decode_cel,text=text}
return engine

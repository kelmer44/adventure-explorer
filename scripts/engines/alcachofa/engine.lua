-- Alcachofa V3 (Movie Adventure). Format reference: ScummVM alcachofa/graphics.cpp,
-- AnimationBase::readV3 and Animation::imageIndex; sounds.cpp::loadSND.
local engine = {id='alcachofa', name='Una Aventura de Cine', version='1.0',
    description='Mortadelo y Filemon: Una Aventura de Cine - Edicion Especial (Alcachofa V3)'}
local floor, min, max = math.floor, math.min, math.max
local function u16(s,p) assert(p>0 and p+1<=#s,'Truncated word');return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function i32(s,p) local n=u32(s,p);return n<2147483648 and n or n-4294967296 end
local function read(path)
    local f=file_open(path);if not f then return nil end
    local s=file_read(f,0,file_size(f));file_close(f);return s
end
local function utf8(n)
    if n<128 then return string.char(n) elseif n<2048 then return string.char(192+floor(n/64),128+n%64)
    else return string.char(224+floor(n/4096),128+floor(n/64)%64,128+n%64) end
end
local cp={ [128]=8364,[130]=8218,[131]=402,[132]=8222,[133]=8230,[134]=8224,[135]=8225,[136]=710,[137]=8240,[138]=352,[139]=8249,[140]=338,[142]=381,[145]=8216,[146]=8217,[147]=8220,[148]=8221,[149]=8226,[150]=8211,[151]=8212,[152]=732,[153]=8482,[154]=353,[155]=8250,[156]=339,[158]=382,[159]=376 }
local function decrypt(s)
    assert(#s>=37,'Truncated encrypted text')
    local key=s:byte(33);local map={}
    for n=0,255 do
        local v=0
        for bit=0,7 do if floor(n/2^bit)%2~=floor(key/2^bit)%2 then v=v+2^bit end end
        map[string.char(n)]=string.char(v)
    end
    return ((s:sub(1,32)..s:sub(38)):gsub('.',map))
end
local function text1252(s) return (s:gsub('[\128-\255]',function(c) local n=c:byte();return utf8(cp[n] or n) end)) end

-- Record TGA ranges without decoding their pixels during tree construction.
local function tga(s,p)
    assert(p+17<=#s,'Truncated TGA')
    local im={start=p,w=u16(s,p+12),h=u16(s,p+14),kind=s:byte(p+2),bits=s:byte(p+16),flags=s:byte(p+17)}
    assert(im.w>0 and im.h>0 and im.w*im.h<=16000000,'Invalid TGA size')
    assert(im.kind==1 or im.kind==2 or im.kind==3 or im.kind==9 or im.kind==10 or im.kind==11,'Unsupported TGA')
    im.cmap=u16(s,p+3);im.colors=u16(s,p+5);im.cbits=s:byte(p+7)
    local q=p+18+s:byte(p)
    im.palette=q;q=q+im.colors*math.ceil(im.cbits/8);im.pixels=q
    local bpp=math.ceil(im.bits/8);assert(bpp>=1 and bpp<=4,'Invalid TGA depth')
    local count=im.w*im.h
    if im.kind<9 then q=q+count*bpp else
        local n=0
        while n<count do
            local tag=s:byte(q);assert(tag,'Truncated TGA RLE');q=q+1
            local run=tag%128+1;assert(n+run<=count,'TGA RLE overflow')
            q=q+(tag>=128 and bpp or run*bpp);n=n+run
        end
    end
    assert(q-1<=#s,'Truncated TGA pixels')
    local a,b=s:find('TRUEVISION-XFILE.\0',q,true);assert(a and a-q<=4096,'Missing TGA footer')
    im.finish=b;return im,b+1
end
local function bank(s)
    local b={sprites=u32(s,1),images={},bases={},offsets={},mapping={},frames={}}
    local ni=u32(s,5);assert(b.sprites>=0 and b.sprites<=256 and ni>=0 and ni<=65536,'Invalid AN0 counts')
    local p=9
    for i=1,ni do b.images[i],p=tga(s,p) end
    for i=1,b.sprites do b.bases[i]=u32(s,p+(i-1)*4);assert(b.bases[i]<ni,'Invalid sprite base') end
    p=p+1024
    for i=1,ni do b.offsets[i]={i32(s,p),i32(s,p+4)};p=p+8 end
    for i=1,b.sprites do b.mapping[i]=u32(s,p+(i-1)*4)+1;assert(b.mapping[i]<=b.sprites,'Invalid sprite mapping') end
    p=p+1024
    local nf=u32(s,p);p=p+4;assert(nf>0 and nf<=100000,'Invalid frame count')
    assert(p+nf*(b.sprites*4+20)-1<=#s,'Truncated AN0 frame table')
    local x0,y0,x1,y1=0,0,1,1
    local first=true
    for f=1,nf do
        local frame={images={}}
        for i=1,b.sprites do
            local j=b.mapping[i];local v=u32(s,p+(j-1)*4)
            if v>0 then
                local idx=b.bases[j]+v;local im=b.images[idx];assert(im,'Invalid frame image')
                if im.w~=2 or im.h~=1 then
                    frame.images[#frame.images+1]=idx
                    local o=b.offsets[idx]
                    if first then x0,y0,x1,y1=o[1],o[2],o[1]+im.w,o[2]+im.h;first=false
                    else x0,y0,x1,y1=min(x0,o[1]),min(y0,o[2]),max(x1,o[1]+im.w),max(y1,o[2]+im.h) end
                end
            end
        end
        p=p+b.sprites*4
        frame.cx,frame.cy,frame.x,frame.y=i32(s,p),i32(s,p+4),i32(s,p+8),i32(s,p+12)
        frame.delay=u32(s,p+16);p=p+20;b.frames[f]=frame
    end
    b.x,b.y,b.w,b.h=x0,y0,x1-x0,y1-y0
    assert(b.w>0 and b.h>0 and b.w*b.h<=16000000,'Invalid AN0 canvas')
    b.batch=max(1,min(100,floor(8000000/(b.w*b.h))))
    return b
end
local function pixels(s,im)
    local rgba={};local q=im.pixels;local n=0;local bpp=math.ceil(im.bits/8)
    local function color(p)
        local r,g,b,a
        if im.kind==1 or im.kind==9 then
            local idx=s:byte(p)-im.cmap;assert(idx>=0 and idx<im.colors,'Invalid TGA palette index')
            local off=im.palette+idx*math.ceil(im.cbits/8)
            b,g,r=s:byte(off,off+2);a=im.cbits==32 and s:byte(off+3) or 255
        elseif im.kind==3 or im.kind==11 then r=s:byte(p);g=r;b=r;a=255
        else b,g,r=s:byte(p,p+2);a=bpp==4 and im.flags%16>0 and s:byte(p+3) or 255 end
        assert(r and g and b and a,'Truncated TGA color');return r,g,b,a
    end
    local function put(r,g,b,a)
        local x=n%im.w;local y=floor(n/im.w)
        if floor(im.flags/32)%2==0 then y=im.h-1-y end
        if floor(im.flags/16)%2==1 then x=im.w-1-x end
        local o=(y*im.w+x)*4
        rgba[o+1],rgba[o+2],rgba[o+3],rgba[o+4]=r,g,b,a;n=n+1
    end
    while n<im.w*im.h do
        local count,repeatPixel=1,false
        if im.kind>=9 then local tag=s:byte(q);q=q+1;count=tag%128+1;repeatPixel=tag>=128 end
        if repeatPixel then local r,g,b,a=color(q);q=q+bpp;for _=1,count do put(r,g,b,a) end
        else for _=1,count do put(color(q));q=q+bpp end end
    end
    return rgba
end
local function render(s,b,frame)
    local rgb={};for i=1,b.w*b.h*3 do rgb[i]=32 end
    for _,idx in ipairs(frame.images) do
        local im=b.images[idx];local rgba=pixels(s,im);local o=b.offsets[idx]
        for y=0,im.h-1 do for x=0,im.w-1 do
            local src=(y*im.w+x)*4;local dst=((y+o[2]-b.y)*b.w+x+o[1]-b.x)*3
            local a=rgba[src+4]/255
            for c=1,3 do rgb[dst+c]=floor(rgba[src+c]*a+rgb[dst+c]*(1-a)+0.5) end
        end end
    end
    return image_create_rgb(b.w,b.h,rgb)
end
-- Standard Microsoft IMA ADPCM: per-channel predictor/index headers, then
-- groups of four bytes per channel. Only mono/stereo are accepted.
local steps={7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767}
local shifts={-1,-1,-1,-1,2,4,6,8}
local function ima(s,block,channels)
    assert(block>=4*channels and block<=65536,'Invalid ADPCM block size')
    local out={}
    local function sample(n) if n<0 then n=n+65536 end;return string.char(n%256,floor(n/256)) end
    for start=1,#s,block do
        local finish=min(#s,start+block-1);assert(finish-start+1>=4*channels,'Truncated ADPCM header')
        local pred,index,decoded={},{},{}
        for c=1,channels do
            local p=start+(c-1)*4;pred[c]=u16(s,p);if pred[c]>=32768 then pred[c]=pred[c]-65536 end
            index[c]=s:byte(p+2);assert(index[c]<=88,'Invalid ADPCM step index');decoded[c]={sample(pred[c])}
        end
        local p=start+4*channels
        while p<=finish do
            for c=1,channels do
                for _=1,4 do
                    if p<=finish then
                        local v=s:byte(p);p=p+1
                        for half=1,2 do
                            local code=half==1 and v%16 or floor(v/16);local st=steps[index[c]+1]
                            local diff=floor(st/8)+(code%2==1 and floor(st/4) or 0)
                                +(floor(code/2)%2==1 and floor(st/2) or 0)+(floor(code/4)%2==1 and st or 0)
                            pred[c]=max(-32768,min(32767,pred[c]+(code>=8 and -diff or diff)))
                            index[c]=max(0,min(88,index[c]+shifts[code%8+1]))
                            decoded[c][#decoded[c]+1]=sample(pred[c])
                        end
                    end
                end
            end
        end
        for i=1,#decoded[1] do for c=1,channels do assert(decoded[c][i],'Incomplete ADPCM channel group');out[#out+1]=decoded[c][i] end end
    end
    return table.concat(out)
end
local function audio(s,isSnd)
    if #s==0 then return {type='text',text='Empty sound: silence in the game.'} end
    local fmt,data
    if isSnd then
        local ending=u32(s,1)+8;assert(ending>=24 and ending<=#s,'Invalid SND header')
        fmt=s:sub(5,ending);data=s:sub(ending+1)
    else
        assert(s:sub(1,4)=='RIFF' and s:sub(9,12)=='WAVE','Invalid WAV')
        local p=13
        while p+7<=#s do
            local tag=s:sub(p,p+3);local n=u32(s,p+4);assert(p+7+n<=#s,'Truncated WAV chunk')
            if tag=='fmt ' then fmt=s:sub(p+8,p+7+n) elseif tag=='data' then data=s:sub(p+8,p+7+n) end
            p=p+8+n+n%2
        end
    end
    assert(fmt and #fmt>=16 and data,'Missing audio format/data')
    local kind,channels,rate,bits=u16(fmt,1),u16(fmt,3),u32(fmt,5),u16(fmt,15)
    assert(channels>=1 and channels<=2 and rate>0 and rate<=192000,'Invalid audio format')
    if kind==17 then data=ima(data,u16(fmt,13),channels);bits=16
    else assert(kind==1 and (bits==8 or bits==16),'Unsupported audio codec') end
    assert(#data%(channels*bits/8)==0,'Incomplete audio sample')
    return {type='sound',sound=sound_create_pcm(rate,bits,channels,bits==16,data)}
end
local cache
local function detected(path) return file_exists(path..'/Textos/Objetos.NKR') and file_exists(path..'/Fondos/DESPACHO_MOMIEZ.AN0') end
local function media(path)
    return file_exists(path..'/data01.cab') and file_exists(path..'/data02.cab')
        and file_exists(path..'/Data/TEXTOS_INSTALADOR.nkr')
end
local function instructions(path)
    return {type='text',text='HOW TO OPEN UNA AVENTURA DE CINE - EDICION ESPECIAL\n\n'
        ..'Installed or previously extracted copy:\n'
        ..'Click Open Folder and select the game folder containing Fondos, Animaciones, Mascaras, Sonidos and Textos. '
        ..'Select that parent folder, rather than one of its subfolders. No preparation is needed.\n\n'
        ..'CD installer copy (data01.cab and data02.cab):\n'
        ..'Extraction is required once; the explorer does not extract cabinets automatically. '
        ..'You can install the game normally and open its installed folder, or use the preparation script below.\n\n'
        ..'1. Install Python 3 and cabextract, with both available in your terminal.\n'
        ..'2. Open a terminal in the Adventure Explorer source folder (the folder containing scripts).\n'
        ..'3. Run this command, replacing the example paths with your media folder and a new or empty output folder:\n\n'
        ..'python3 scripts/prepare-decine.py "/path/to/decine" "/path/to/decine-data"\n\n'
        ..'4. In Adventure Explorer, click Open Folder and select decine-data.\n\n'
        ..'Keep the output outside the original media folder. The script copies the extracted assets and leaves '
        ..'the source media unchanged. Once extraction finishes, you can reopen the output directly.\n\n'
        ..'Currently selected folder: '..path}
end
function engine.detect(path) return detected(path) or media(path) end
function engine.get_resources(path)
    cache={path=path,entries={}};local tree={{id='opening_instructions',name='How to open this game',type='text'}}
    cache.entries.opening_instructions={instructions=true}
    if media(path) and not detected(path) then return {{id='installation',name='How to open this game (CD preparation)',type='text'}} end
    local folders={{'Fondos','Backgrounds'},{'Animaciones','Animations and Sprites'},{'Mascaras','Masks and Overlays'},
        {'Sonidos','Speech and Sound'},{'Textos','Text'},{'Mapas','Room Data'},{'Script','Scripts'},{'Data','Videos (metadata)'}}
    for _,folder in ipairs(folders) do
        local cat={id=folder[1],name=folder[2],type='category',children={}}
        local files={}
        for _,name in ipairs(list_files(path..'/'..folder[1]) or {}) do
            -- The original CD's Data folder also contains installer files.
            if folder[1]~='Data' or name:lower():match('%.bin$') then files[#files+1]=name end
        end
        table.sort(files)
        for _,name in ipairs(files) do
            local id=folder[1]..'/'..name;local full=path..'/'..id
            if name:lower():match('%.an0$') then
                local s=read(full);local ok,b=pcall(bank,s or '')
                if ok then
                    local node={id=id,name=name,type='category',children={}}
                    for first=1,#b.frames,b.batch do
                        local last=min(#b.frames,first+b.batch-1);local key=id..'#'..first
                        local typ=#b.images==0 and 'text' or (first==last and 'image' or 'animation')
                        node.children[#node.children+1]={id=key,name='Frames '..first..'-'..last..' ('..b.w..'x'..b.h..')',type=typ}
                        cache.entries[key]={file=full,bank=b,first=first,last=last,name=name}
                    end
                    cat.children[#cat.children+1]=node
                else
                    cache.entries[id]={file=full,error=tostring(b)}
                    cat.children[#cat.children+1]={id=id,name=name..' (unrecognized)',type='text'}
                end
            else
                local ext=name:lower():match('%.([^.]*)$');local sound=ext=='snd' or ext=='wav'
                cache.entries[id]={file=full,sound=sound,snd=ext=='snd',name=name,text=ext=='nkr' or ext=='txt',encrypted=ext=='nkr'}
                cat.children[#cat.children+1]={id=id,name=name,type=sound and 'sound' or 'text'}
            end
        end
        if #cat.children>0 then tree[#tree+1]=cat end
    end
    return tree
end
function engine.load_resource(path,id)
    if id=='opening_instructions' or (id=='installation' and media(path)) then return instructions(path) end
    if not cache or cache.path~=path then engine.get_resources(path) end
    local e=cache.entries[id];if not e then return nil end
    if e.error then return {type='text',text='Cannot decode AN0: '..e.error} end
    if e.bank then
        if #e.bank.images==0 then return {type='text',text=e.name..' - empty animation placeholder (no sprites or images).'} end
        local s=assert(read(e.file));local frames={}
        for i=e.first,e.last do frames[#frames+1]=render(s,e.bank,e.bank.frames[i]) end
        local desc=e.name..' - stored frame composition; alpha over dark gray. Uniform preview timing; no scene scripts.'
        if #frames==1 then return {type='image',image=frames[1],description=desc} end
        local delay=max(1,min(10000,e.bank.frames[e.first].delay))
        return {type='animation',animation=animation_create(frames,delay),image=frames[1],description=desc}
    end
    if e.sound then local result=audio(assert(read(e.file)),e.snd);result.description=e.name;return result end
    local f=file_open(e.file);if not f then return nil end
    local size=file_size(f);local s=file_read(f,0,min(size,e.text and 4194304 or 1024));file_close(f)
    if e.text then
        if e.encrypted then s=decrypt(s) end
        return {type='text',text=text1252(s),description=e.name}
    end
    local lines={e.name..'\n'..size..' bytes. Raw data preview (first 1024 bytes); scripts and videos are not interpreted.'}
    for i=1,min(#s,1024),16 do
        local row=s:sub(i,i+15);local hex={};for j=1,#row do hex[#hex+1]=string.format('%02X',row:byte(j)) end
        lines[#lines+1]=string.format('%08X  %-47s  %s',i-1,table.concat(hex,' '),row:gsub('[^ -~]','.'))
    end
    return {type='text',text=table.concat(lines,'\n'),description=e.name}
end
return engine

-- El Sulfato Atomico: NMP/PCX stills, FLC animations and PCM WAV audio.
local engine = {id='sulfato', name='El Sulfato Atomico',
    description='Mortadelo y Filemon: El Sulfato Atomico (1998, Alcachofa Soft)', version='1.0'}
local function u16(s,p) return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function read(path)
    local f=file_open(path);if not f then return nil end
    local s=file_read(f,0,file_size(f));file_close(f);return s
end
local function picture(s)
    assert(#s>=897 and (s:sub(1,4)=='NMP\8' or s:sub(1,4)=='\10\5\1\8'),'Invalid picture header')
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
    assert(n==stride*h and p==finish+1,'Incomplete PCX pixels')
    for i=1,768 do palette[i]=s:byte(#s-768+i) end
    return w,h,pixels,palette
end
-- Standard Autodesk FLC codecs, adapted from the Pink Panther engine.
local function decode_cel(s,first,last)
    assert(#s>=128 and u16(s,5)==0xAF12 and u16(s,13)==8,'Invalid CEL header')
    local count,w,h=u16(s,7),u16(s,9),u16(s,11)
    assert(count>0 and count<=10000 and w>0 and h>0 and w<=2048 and h<=2048,'Invalid CEL dimensions')
    first=first or 1;last=math.min(last or count,count)
    assert(first>=1 and last>=first and (last-first+1)*w*h<=8000000,'CEL preview too large')
    local pos=u32(s,81)+1;if pos==1 then pos=129 end
    local pixels,palette,handles={},{},{}
    for i=1,w*h do pixels[i]=0 end
    for i=1,768 do palette[i]=0 end
    local delay=u32(s,17)
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
            elseif kind~=18 then error('Unsupported CEL chunk '..kind) end
            cp=cp+cs
        end
        if frame>=first then handles[#handles+1]=assert(image_create_indexed(w,h,pixels,palette)) end
        pos=pos+frameSize
    end
    return handles,math.max(1,delay),count
end
local function wav(s)
    assert(s:sub(1,4)=='RIFF' and s:sub(9,12)=='WAVE','Invalid WAV')
    local finish=u32(s,5)+9;assert(finish<=#s+1,'Truncated WAV')
    local p,fmt,pcm=13
    while p+7<finish do
        local n=u32(s,p+4);assert(p+8+n<=finish,'Invalid WAV chunk')
        local tag=s:sub(p,p+3)
        if tag=='fmt ' then assert(n>=16,'Short WAV format');fmt=s:sub(p+8,p+7+n)
        elseif tag=='data' then pcm=s:sub(p+8,p+7+n) end
        -- Audio decoders stop at the sample payload. Some shipped VOX files
        -- omit the pad byte before trailing cue metadata after odd data sizes.
        if fmt and pcm then break end
        p=p+8+n+n%2
    end
    assert(fmt and pcm and u16(fmt,1)==1,'Only PCM WAV is supported')
    local channels,rate,bits=u16(fmt,3),u32(fmt,5),u16(fmt,15)
    assert((channels==1 or channels==2) and rate>0 and rate<=192000 and (bits==8 or bits==16),'Invalid PCM format')
    assert(#pcm%(channels*bits/8)==0,'Incomplete PCM sample')
    return sound_create_pcm(rate,bits,channels,bits==16,pcm)
end
local entries,cachedPath,tree={},nil,nil
local function header(path,n)
    local f=file_open(path);if not f then return nil end
    local s=file_read(f,0,math.min(n,file_size(f)));file_close(f);return s
end
function engine.detect(path)
    local names={}
    for _,n in ipairs(list_files(path)) do names[n:upper()]=n end
    if not (names['SULFATO.EXE'] and names['1.ALG'] and names['1.ALD']) then return false end
    local s=header(path..'/'..names['1.ALG'],4)
    return s=='NMP\8'
end
local function catalog(path)
    if path==cachedPath then return tree end
    entries={};tree={}
    local groups={}
    for _,g in ipairs({{'rooms','Room Backgrounds'},{'sheets','Sprite Sheets and Screens'},
        {'palettes','Palettes'},{'animations','Animations'},{'sounds','Speech and Sound'},
        {'text','Room Data and Text'}}) do
        local node={id=g[1],name=g[2],type='category',children={}}
        groups[g[1]]=node;tree[#tree+1]=node
    end
    local names=list_files(path);table.sort(names,function(a,b) return a:upper()<b:upper() end)
    local function add(group,id,name,typ,e)
        entries[id]=e;groups[group].children[#groups[group].children+1]={id=id,name=name,type=typ}
    end
    for _,name in ipairs(names) do
        local upper=name:upper();local ext=upper:match('%.([^%.]+)$')
        if ext=='ALG' or ext=='SVS' then
            local s=header(path..'/'..name,128)
            if s and #s==128 and (s:sub(1,4)=='NMP\8' or s:sub(1,4)=='\10\5\1\8') then
                local id='image:'..name
                add(upper:match('^%d+%.ALG$') and 'rooms' or 'sheets',id,
                    string.format('%s (%dx%d)',name,u16(s,9)-u16(s,5)+1,u16(s,11)-u16(s,7)+1),'image',{kind='image',file=name})
                add('palettes','palette:'..name,name,'palette',{kind='palette',file=name})
            end
        elseif ext=='VHS' then
            local s=header(path..'/'..name,128)
            if s and #s==128 and u16(s,5)==0xAF12 and u16(s,13)==8 then
                local count,w,h=u16(s,7),u16(s,9),u16(s,11)
                assert(count>0 and count<=10000 and w>0 and h>0 and w<=2048 and h<=2048,'Invalid FLC header')
                local batch=math.min(200,math.floor(8000000/(w*h)))
                for first=1,count,batch do
                    local last=math.min(count,first+batch-1)
                    add('animations','animation:'..name..':'..first,
                        string.format('%s (frames %d-%d)',name,first,last),'animation',
                        {kind='animation',file=name,first=first,last=last})
                end
            end
        elseif ext=='WAV' then
            local s=header(path..'/'..name,12)
            if s and s:sub(1,4)=='RIFF' and s:sub(9,12)=='WAVE' then
                add('sounds','sound:'..name,name,'sound',{kind='sound',file=name})
            else
                -- sk494.wav in the supplied release is a short developer message.
                add('text','text:'..name,name..' (text)','text',{kind='text',file=name})
            end
        elseif ext=='ALD' or ext=='CAL' or ext=='TXT' or ext=='GSV' or ext=='SAV' then
            add('text','text:'..name,name,'text',{kind='text',file=name})
        end
    end
    cachedPath=path;return tree
end
function engine.get_resources(path) return catalog(path) end
function engine.default_palette(path,id)
    catalog(path);local e=entries[id]
    if e and e.kind=='image' then return 'palette:'..e.file end
end
local function text_utf8(s)
    -- The supplied text uses Windows Latin-1 accents (e.g. E1 in ZETA.TXT).
    return (s:gsub('[\128-\255]',function(c)
        local n=c:byte();return string.char(192+math.floor(n/64),128+n%64)
    end))
end
function engine.load_resource(path,id,paletteId)
    catalog(path);local e=entries[id];if not e then return nil end
    local s=read(path..'/'..e.file);if not s then return nil end
    if e.kind=='image' or e.kind=='palette' then
        local w,h,pixels,palette=picture(s)
        if e.kind=='palette' then
            local swatch={}
            for y=0,127 do for x=0,127 do swatch[y*128+x+1]=math.floor(y/8)*16+math.floor(x/8) end end
            return {type='image',image=image_create_indexed(128,128,swatch,palette),description=e.file..' palette'}
        end
        local chosen=paletteId and entries[paletteId]
        if chosen and chosen.kind=='palette' then
            local other=read(path..'/'..chosen.file)
            if other then local _,_,_,pal=picture(other);palette=pal end
        end
        return {type='image',image=image_create_indexed(w,h,pixels,palette),description=e.file}
    elseif e.kind=='animation' then
        local frames,delay=decode_cel(s,e.first,e.last)
        return {type='animation',animation=animation_create(frames,delay),image=frames[1],frames=frames,
            description=e.file..' - stored frame order; uniform '..delay..' ms preview'}
    elseif e.kind=='sound' then
        return {type='sound',sound=wav(s),description=e.file}
    else
        return {type='text',text=text_utf8(s),description=e.file..' - original data'}
    end
end
return engine

-- Pink Panther ORB/BRO and Autodesk CEL/FLC resources.
-- Format references: ScummVM engines/pink/{file,cel_decoder,sound}.cpp,
-- video/flic_decoder.cpp. No game scripts or scene composition are executed.
local engine = {id='pink', name='Pink Panther', version='1.0',
    description='The Pink Panther: Passport to Peril / Hokus Pokus Pink'}
local function u16(s,p) assert(p>=1 and p+1<=#s,'Truncated word');return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function name(s) return s:match('^[^%z]*') end
local function read(path,offset,size)
    local f=file_open(path);if not f then return nil end
    local data=file_read(f,offset,size);file_close(f)
    if not data or #data~=size then return nil end
    return data
end
local function length(path)
    local f=file_open(path);if not f then return nil end
    local n=file_size(f);file_close(f);return n
end
local function header(path,magic,major)
    local h=read(path,0,20)
    return h and h:sub(1,4)==magic and u16(h,5)==0 and u16(h,7)==major and u32(h,9)~=0 and h
end
local function archives(path)
    local out={}
    for _,base in ipairs({'PPTP','HPP'}) do
        local p=path..'/'..base..'.ORB'
        if header(p,'ORB\0',2) then out[#out+1]={path=p,base=base} end
    end
    return out
end
function engine.detect(path) return #archives(path)>0 end
local cachedPath,entries,tree
local function catalog(path)
    if cachedPath==path then return tree end
    entries={};tree={};cachedPath=nil
    for _,arc in ipairs(archives(path)) do
        local h=header(arc.path,'ORB\0',2);local size=length(arc.path)
        local offset,count=u32(h,13),u32(h,17)
        assert(count<=10000 and offset+count*32<=size,'Invalid ORB object table')
        local objects=assert(read(arc.path,offset,count*32))
        local root={id=arc.base,name=arc.base=='PPTP' and 'Passport to Peril' or 'Hokus Pokus Pink',type='category',children={}}
        tree[#tree+1]=root
        local bro
        for _,p in ipairs({path..'/'..arc.base..'.BRO',path..'/INSTALL/'..arc.base..'.BRO'}) do
            local b=header(p,'BRO\0',1)
            if b and u32(b,9)==u32(h,9) then bro=p;break end
        end
        local broSize=bro and length(bro)
        for i=0,count-1 do
            local p=i*32+1;local page=name(objects:sub(p,p+15))
            local ro,rc=u32(objects,p+24),u32(objects,p+28)
            assert(rc<=100000 and ro+rc*26<=size,'Invalid ORB resource table')
            if rc>0 then
                local rs=assert(read(arc.path,ro,rc*26))
                local group={id=arc.base..'/'..i,name=page,type='category',children={}}
                root.children[#root.children+1]=group
                for j=0,rc-1 do
                    local q=j*26+1;local rn=name(rs:sub(q,q+15));local off,n=u32(rs,q+16),u32(rs,q+20)
                    local external=u16(rs,q+24)~=0;local source=external and bro or arc.path
                    if external and not bro then source=nil end
                    local sourceSize=external and broSize or size
                    local id=group.id..'/'..j
                    local e={path=source,offset=off,size=n,name=rn,page=page}
                    local ext=rn:upper():match('%.([^.]*)$')
                    local node={id=id,name=rn,type='text'}
                    if source and off+n<=sourceSize then
                        local ch=read(source,off,math.min(128,n))
                        if ch and #ch>=128 and u16(ch,5)==0xAF12 and u16(ch,13)==8 then
                            local frames,w,hh=u16(ch,7),u16(ch,9),u16(ch,11)
                            if frames>0 and frames<=10000 and w>0 and hh>0 and w<=2048 and hh<=2048 then
                                e.kind='cel';node.type=frames>1 and 'animation' or 'image'
                                -- Bound retained image memory. Every frame remains accessible in batches.
                                local batch=math.max(1,math.min(200,math.floor(8000000/(w*hh))))
                                if frames>batch then
                                    node.type='category';node.children={}
                                    for first=1,frames,batch do
                                        local last=math.min(frames,first+batch-1);local cid=id..'/'..first
                                        entries[cid]={path=source,offset=off,size=n,name=rn,page=page,kind='cel',first=first,last=last}
                                        node.children[#node.children+1]={id=cid,name='Frames '..first..'-'..last,type=last>first and 'animation' or 'image'}
                                    end
                                end
                            end
                        elseif ch and ch:sub(1,4)=='RIFF' and ch:sub(9,12)=='WAVE' then
                            e.kind='wav';node.type='sound'
                        elseif ext=='TXT' then e.kind='text' end
                    else
                        e.problem=external and 'Missing or mismatched companion BRO archive' or 'Resource outside archive'
                        node.name=rn..' (unavailable)'
                    end
                    entries[id]=e;group.children[#group.children+1]=node
                end
            end
        end
    end
    cachedPath=path;return tree
end
function engine.get_resources(path) return catalog(path) end

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
        local frameSize=u32(s,pos)
        -- Some original CELs have stale frame sizes. ScummVM follows the chunk
        -- count and chunk sizes instead; keep all reads bounded by the resource.
        assert(frameSize>=16 and pos+16<=#s+1 and u16(s,pos+4)==0xF1FA,'Invalid CEL frame')
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
            local cs=u32(s,cp);local kind=u16(s,cp+4)
            -- Some COPY chunks undercount pixels/padding by two bytes. Recover
            -- only when dimensions and the enclosing frame agree exactly.
            local copySize=w*h+6+(w*h)%2
            if kind==16 and chunkIndex==chunks and cs==copySize-2
                and cp+copySize==pos+frameSize then cs=copySize end
            assert(cs>=6 and cp+cs<=#s+1,'Invalid CEL chunk')
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
        pos=cp
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
function engine.load_resource(path,id)
    catalog(path);local e=entries[id];if not e then return nil end
    local desc=e.page..' / '..e.name
    if e.problem then return {type='text',text=desc..'\n'..e.problem} end
    local ok,result=pcall(function()
        local s=assert(read(e.path,e.offset,e.size),'Cannot read resource')
        if e.kind=='cel' then
            local frames,delay,count=decode_cel(s,e.first,e.last)
            desc=desc..' ('..count..' frames; '..delay..' ms/frame)'
            if #frames==1 then return {type='image',image=frames[1],description=desc} end
            return {type='animation',animation=animation_create(frames,delay),image=frames[1],frames=frames,description=desc}
        elseif e.kind=='wav' then return {type='sound',sound=assert(wav(s)),description=desc}
        elseif e.kind=='text' then
            -- The supplied Spanish releases use Windows-1252 text. Convert to UTF-8.
            local cp1252={[128]=8364,[130]=8218,[131]=402,[132]=8222,[133]=8230,[134]=8224,[135]=8225,[136]=710,[137]=8240,[138]=352,[139]=8249,[140]=338,[142]=381,[145]=8216,[146]=8217,[147]=8220,[148]=8221,[149]=8226,[150]=8211,[151]=8212,[152]=732,[153]=8482,[154]=353,[155]=8250,[156]=339,[158]=382,[159]=376}
            local text=s:gsub('[\128-\255]',function(c)
                local n=c:byte();n=cp1252[n] or n
                if n<2048 then return string.char(192+math.floor(n/64),128+n%64) end
                return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64)
            end)
            return {type='text',text=text,description=desc}
        end
        return {type='text',text=desc..'\n'..e.size..' bytes; unsupported resource format',description=desc}
    end)
    if not ok then log_warn(desc..': '..tostring(result));return nil end
    return result
end
return engine

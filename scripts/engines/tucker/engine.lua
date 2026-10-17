-- Bud Tucker in Double Trouble (DOS). Format reference: ScummVM engines/tucker/
-- resource.cpp (PCX, encoded tables, WAV) and tucker.cpp / graphics.cpp (SPR).
-- Stored art and animation frames are browsed independently of game scripts.
local engine = {id='tucker', name='Bud Tucker in Double Trouble', version='1.0',
    description='Bud Tucker in Double Trouble (1996, Merit Studios)'}
local floor = math.floor
local function u16(s,p)
    assert(p>=1 and p+1<=#s,'Truncated word')
    return s:byte(p)+s:byte(p+1)*256
end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function read(path,limit)
    local f=file_open(path);if not f then return nil end
    local n=file_size(f);local s=file_read(f,0,math.min(n,limit or n));file_close(f)
    return s
end
local function gray()
    local p={};for i=0,255 do p[#p+1]=i;p[#p+1]=i;p[#p+1]=i end;return p
end
local function pcx_palette(s)
    assert(#s>=897 and s:byte(#s-768)==12,'Missing PCX palette')
    local pal={};for i=1,768 do pal[i]=s:byte(#s-768+i) end;return pal
end
local function pcx(s)
    assert(#s>=897 and s:byte(1)==10 and s:byte(3)<=1 and s:byte(4)==8 and s:byte(66)==1,'Unsupported PCX')
    local w,h=u16(s,9)-u16(s,5)+1,u16(s,11)-u16(s,7)+1
    local stride=u16(s,67)
    assert(w>0 and h>0 and w<=2048 and h<=2048 and stride>=w and stride<=4096,'Invalid PCX dimensions')
    local pal=pcx_palette(s)
    local pixels={};local pos,run,color=129,0,0
    for y=0,h-1 do
        for x=0,stride-1 do
            if run==0 then
                assert(pos<#s-768,'Truncated PCX pixels')
                color=s:byte(pos);pos=pos+1;run=1
                if s:byte(3)==1 and color>=192 then
                    run=color-192;assert(run>0 and pos<#s-768,'Invalid PCX run')
                    color=s:byte(pos);pos=pos+1
                end
            end
            run=run-1
            if x<w then pixels[y*w+x+1]=color end
        end
    end
    assert(run==0,'PCX run exceeds image')
    return {w=w,h=h,pixels=pixels,palette=pal}
end
local function spr_frames(s)
    local n=u32(s,1)
    assert(n>0 and n<=10000 and 4+n*4<=#s,'Invalid SPR frame count')
    local frames={}
    for i=1,n do
        -- The fourth offset byte is not part of ScummVM's 24-bit offset.
        local off=u32(s,1+i*4)%16777216
        local finish=i<n and u32(s,5+i*4)%16777216 or #s
        assert(off>=4+n*4 and off+12<=finish and finish<=#s,'Invalid SPR offsets')
        local w,h=u16(s,off+1),u16(s,off+3)
        assert(w>0 and h>0 and w<=640 and h<=200,'Invalid SPR dimensions')
        frames[i]={offset=off,finish=finish,w=w,h=h,x=u16(s,off+9),y=u16(s,off+11)}
    end
    return frames
end
local function spr_pixels(s,f)
    local px={};local p=f.offset+13;local total=f.w*f.h
    while #px<total do
        assert(p<=f.finish,'Truncated SPR pixels')
        local c=s:byte(p);p=p+1
        if c==0 then
            assert(p<=f.finish,'Truncated SPR run')
            local n=s:byte(p);p=p+1
            assert(n>0 and #px+n<=total,'Invalid SPR run')
            for _=1,n do px[#px+1]=0 end
        else px[#px+1]=c end
    end
    return px
end
local function spr_bounds(frames)
    local x,y,right,bottom=640,200,0,0
    for _,f in ipairs(frames) do
        x=math.min(x,f.x);y=math.min(y,f.y)
        right=math.max(right,f.x+f.w);bottom=math.max(bottom,f.y+f.h)
    end
    assert(right-x<=640 and bottom-y<=200,'SPR canvas exceeds preview bounds')
    return x,y,right-x,bottom-y
end
local function wave(s)
    assert(s:sub(1,4)=='RIFF' and s:sub(9,12)=='WAVE','Unsupported audio (expected PCM WAVE)')
    local finish=u32(s,5)+8;assert(finish<=#s,'Truncated WAV')
    local p,fmt,pcm=13
    while p+7<=finish do
        local n=u32(s,p+4);assert(p+7+n<=finish,'Truncated WAV chunk')
        local tag=s:sub(p,p+3)
        if tag=='fmt ' then assert(n>=16,'Short WAV format');fmt=s:sub(p+8,p+7+n)
        elseif tag=='data' then pcm=s:sub(p+8,p+7+n) end
        if fmt and pcm then break end
        p=p+8+n+n%2
    end
    assert(fmt and pcm and u16(fmt,1)==1,'Unsupported WAV codec')
    local ch,rate,bits=u16(fmt,3),u32(fmt,5),u16(fmt,15)
    assert((ch==1 or ch==2) and rate>0 and rate<=192000 and (bits==8 or bits==16),'Invalid WAV format')
    assert(#pcm%(ch*bits/8)==0,'Incomplete WAV sample')
    return sound_create_pcm(rate,bits,ch,bits==16,pcm)
end
local function decode_table(s)
    return (s:gsub('.',function(c) return string.char((c:byte()+128)%256) end))
end
-- DOS code page 850: the Spanish copy uses 82=e-acute, A0=a-acute, A8=inverted question mark.
local cp850 = {199,252,233,226,228,224,229,231,234,235,232,239,238,236,196,197,201,230,198,244,246,242,251,249,255,214,220,248,163,216,215,402,225,237,243,250,241,209,170,186,191,174,172,189,188,161,171,187,9617,9618,9619,9474,9508,193,194,192,169,9571,9553,9559,9565,162,165,9488,9492,9524,9516,9500,9472,9532,227,195,9562,9556,9577,9574,9568,9552,9580,164,240,208,202,203,200,305,205,206,207,9496,9484,9608,9604,166,204,9600,211,223,212,210,245,213,181,254,222,218,219,217,253,221,175,180,173,177,8215,190,182,167,247,184,176,168,183,185,179,178,9632,160}
local function utf8char(n)
    if n<128 then return string.char(n) end
    if n<2048 then return string.char(192+floor(n/64),128+n%64) end
    return string.char(224+floor(n/4096),128+floor(n/64)%64,128+n%64)
end
local function text_utf8(s)
    return (s:gsub('[\128-\255]',function(c) return utf8char(cp850[c:byte()-127]) end))
end
local function hex(s)
    local lines={}
    for p=1,math.min(#s,256),16 do
        local b={};for i=p,math.min(p+15,#s) do b[#b+1]=string.format('%02X',s:byte(i)) end
        lines[#lines+1]=string.format('%08X  %s',p-1,table.concat(b,' '))
    end
    return table.concat(lines,'\n')
end
local cachedPath,entries,tree,files,palettes,paletteCache
local spriteFile,spriteData,spriteFrames
local function sorted_files(path)
    local names=list_files(path) or {};table.sort(names);return names
end
local function index(path)
    if cachedPath==path then return tree end
    cachedPath=nil;entries={};tree={};files={};palettes={};paletteCache={}
    spriteFile,spriteData,spriteFrames=nil,nil,nil
    for _,dir in ipairs({'','SPRITES','FX','MUSIC','SPEECH','AUDIO','GRAPHICS'}) do
        for _,name in ipairs(sorted_files(path..(dir=='' and '' or '/'..dir))) do
            local key=(dir=='' and name or dir..'/'..name):upper()
            files[key]=dir=='' and name or dir..'/'..name
        end
    end
    local groups={}
    local function add(group,label,id,name,kind,e)
        if not groups[group] then
            groups[group]={id=group,name=label,type='category',children={}};tree[#tree+1]=groups[group]
        end
        e=e or {};e.kind=kind;entries[id]=e
        local typ=(kind=='pcx' or kind=='frame' or kind=='crop') and 'image' or kind=='anim' and 'animation' or kind=='wav' and 'sound' or (kind=='pal' or kind=='gray') and 'palette' or kind=='data' and 'data' or 'text'
        groups[group].children[#groups[group].children+1]={id=id,name=name,type=typ}
    end
    add('palettes','Palettes','pal:grayscale','Grayscale (unassigned sprites / masks)','gray')
    local keys={};for key in pairs(files) do keys[#keys+1]=key end;table.sort(keys)
    for _,key in ipairs(keys) do
        local name=files[key];local ext=key:match('%.([^.]+)$')
        if ext=='PCX' then
            local group,label='screens','Screens and sprite sheets'
            if key:match('^LOC%d') then group,label='backgrounds','Background tiles'
            elseif key:match('^PATH') or key=='ROCHPATH.PCX' then group,label='masks','Walk masks' end
            add(group,label,'pcx:'..key,name,'pcx',{file=name,mask=group=='masks'})
            add('palettes','Palettes','pal:'..key,name,'pal',{file=name})
            if key:match('^LOC%d') then
                local loc=tonumber(key:match('^LOC(%d+)'))
                -- loadLoc installs each tile's palette in order, except the park's second tile.
                if loc~=16 or not palettes[loc] then palettes[loc]='pal:'..key end
            end
            if key:match('^PANOBJS%d%.PCX$') then
                for i=0,49 do
                    add('inventory','Inventory sprites','crop:'..key..':'..i,name..' / '..i,'crop',
                        {file=name,x=i%10*32,y=floor(i/10)*24,w=32,h=24})
                end
            end
        elseif ext=='SPR' then
            local s=read(path..'/'..name)
            local ok,frames=pcall(function()
                local f=spr_frames(s or '');spr_bounds(f);return f
            end)
            if ok then
                local _,_,cw,ch=spr_bounds(frames)
                local group='sprites:'..key
                local loc=tonumber(key:match('/[AC](%d+)_'))
                for i,f in ipairs(frames) do
                    add(group,name,'sprite:'..key..':'..i,'Frame '..i,'frame',{file=name,frame=i,loc=loc})
                end
                -- Batches retain every stored frame while keeping host memory bounded.
                local first=1
                while first<=#frames do
                    local last,pixels=first-1,0
                    while last<#frames and last-first+1<60 and pixels+cw*ch<=4000000 do
                        last=last+1;pixels=pixels+cw*ch
                    end
                    add('animations','Sprite animation previews','anim:'..key..':'..first,name..' / frames '..first..'-'..last,'anim',
                        {file=name,first=first,last=last,loc=loc})
                    first=last+1
                end
            else add('data','Data and unsupported media','data:'..key,name,'data',{file=name,problem=tostring(frames)}) end
        elseif ext=='WAV' then
            local header=read(path..'/'..name,12)
            local group=key:match('^([^/]+)/') or 'audio'
            local labels={FX='Sound effects',MUSIC='Music (WAV)',SPEECH='Speech',AUDIO='Intro audio'}
            if header and header:sub(1,4)=='RIFF' and header:sub(9,12)=='WAVE' then
                add(group,labels[group] or group,'wav:'..key,name,'wav',{file=name})
            else add('data','Data and unsupported media','data:'..key,name,'data',{file=name,problem='Non-WAVE audio; retained as metadata'}) end
        elseif ext=='ENC' or ext=='C' or ext=='TXT' or ext=='DTA' then
            add('texts','Text and script tables','text:'..key,name,'text',{file=name,encoded=ext=='ENC'})
        elseif key:match('^GRAPHICS/') or key:match('^AUDIO/.*%.RAW$') or key:match('^TUCKER%.SO[FG3]$') then
            add('data','Data and unsupported media','data:'..key,name,'data',{file=name})
        end
    end
    -- Collapse per-bank sprite folders beneath one category.
    local banks,other={},{}
    for _,g in ipairs(tree) do
        if g.id:match('^sprites:') then banks[#banks+1]=g else other[#other+1]=g end
    end
    if #banks>0 then other[#other+1]={id='sprites',name='Sprite frames',type='category',children=banks} end
    tree=other;cachedPath=path;return tree
end
function engine.detect(path)
    return (file_exists(path..'/CTABLE01.ENC') or file_exists(path..'/CTABLE01.C'))
        and (file_exists(path..'/BUD_1.PCX') or file_exists(path..'/BUDL00_1.PCX'))
        and file_exists(path..'/PANEL1.PCX')
end
function engine.get_resources(path) return index(path) end
function engine.default_palette(path,id)
    index(path);local e=entries[id];if not e then return nil end
    if e.kind=='frame' or e.kind=='anim' then return palettes[e.loc] or 'pal:grayscale' end
    if e.mask then return 'pal:grayscale' end
    if e.kind=='pcx' and not e.mask or e.kind=='crop' then return 'pal:'..e.file:upper() end
end
local function chosen_palette(path,e,override)
    local id=override or (e.loc and palettes[e.loc])
    local pe=id and entries[id]
    if pe and pe.kind=='gray' then return gray() end
    if pe and pe.kind=='pal' then
        if not paletteCache[id] then paletteCache[id]=pcx_palette(assert(read(path..'/'..pe.file),'Missing palette')) end
        return paletteCache[id]
    end
    return gray()
end
function engine.load_resource(path,id,override)
    index(path);local e=entries[id];if not e then return nil end
    local ok,result=pcall(function()
        local s
        if e.kind=='gray' then s=''
        elseif (e.kind=='frame' or e.kind=='anim') and spriteFile==e.file then s=spriteData
        else s=assert(read(path..'/'..e.file,e.kind=='data' and 512 or nil),'Cannot read resource') end
        local desc=e.file
        if e.kind=='pcx' or e.kind=='crop' then
            local pic=pcx(s);local px,w,h=pic.pixels,pic.w,pic.h
            if e.kind=='crop' then
                assert(e.x+e.w<=w and e.y+e.h<=h,'Crop outside sheet');px={}
                for y=0,e.h-1 do for x=0,e.w-1 do px[#px+1]=pic.pixels[(e.y+y)*w+e.x+x+1] end end
                w,h=e.w,e.h
            end
            local pal=e.mask and gray() or override and chosen_palette(path,e,override) or pic.palette
            return {type='image',image=image_create_indexed(w,h,px,pal),description=desc..' / '..w..'x'..h}
        elseif e.kind=='pal' or e.kind=='gray' then
            local px={}
            for y=0,255 do for x=0,255 do px[#px+1]=floor(y/16)*16+floor(x/16) end end
            return {type='image',image=image_create_indexed(256,256,px,e.kind=='gray' and gray() or pcx_palette(s)),description=(desc or 'Grayscale')..' / 256-color palette'}
        elseif e.kind=='frame' or e.kind=='anim' then
            if spriteFile~=e.file then
                spriteFrames=spr_frames(s);spriteFile=e.file;spriteData=s
            end
            local frames=spriteFrames;local pal=chosen_palette(path,e,override)
            if e.kind=='frame' then
                local f=frames[e.frame];local px=spr_pixels(s,f)
                return {type='image',image=image_create_indexed(f.w,f.h,px,pal),
                    description=string.format('%s / frame %d / %dx%d / origin (%d,%d); scene palette or grayscale',desc,e.frame,f.w,f.h,f.x,f.y)}
            end
            local handles={};local x0,y0,w,h=spr_bounds(frames)
            for i=e.first,e.last do
                local f=frames[i];local source=spr_pixels(s,f);local canvas={}
                for j=1,w*h do canvas[j]=0 end
                for y=0,f.h-1 do for x=0,f.w-1 do
                    canvas[(f.y-y0+y)*w+f.x-x0+x+1]=source[y*f.w+x+1]
                end end
                handles[#handles+1]=image_create_indexed(w,h,canvas,pal)
            end
            return {type='animation',animation=animation_create(handles,100),image=handles[1],frames=handles,
                description=desc..' / stored frames '..e.first..'-'..e.last..'; stored origins, 100 ms preview; script timing and scene composition are not reconstructed'}
        elseif e.kind=='wav' then return {type='sound',sound=wave(s),description=desc}
        elseif e.kind=='text' then
            if e.encoded then s=decode_table(s) end
            return {type='text',text=text_utf8(s),description=desc..' / DOS CP850'..(e.encoded and ' / decoded (-0x80)' or '')}
        end
        return {type='text',text=desc..'\n'..(e.problem or 'Metadata only: movie, raw intro data or compressed audio is not decoded')..'\n\nFirst bytes:\n'..hex(s),description=desc}
    end)
    if ok then return result end
    return {type='text',text=(e.file or 'Grayscale')..'\nCannot decode: '..tostring(result),description=e.file}
end
return engine

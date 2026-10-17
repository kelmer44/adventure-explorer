-- Fable (Simbiosis Interactive, 1996), original PC ARC1 resources.
local engine={id='fable',name='Fable',description='Fable (1996, Simbiosis Interactive)',version='1.0'}
local floor=math.floor
local function u16(s,p) assert(p>=1 and p+1<=#s,'Truncated word');return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function read(path,offset,size)
    local f=assert(file_open(path),'Cannot open '..path)
    local length=file_size(f);offset=offset or 0;size=size or length
    if offset<0 or size<0 or offset+size>length then file_close(f);error('Resource outside file') end
    local s=file_read(f,offset,size);file_close(f)
    assert(s and #s==size,'Truncated read');return s
end
local function directory(path)
    local f=file_open(path);if not f then return nil end
    local size=file_size(f);local h=file_read(f,0,6)
    if #h~=6 or h:sub(1,4)~='ARC1' then file_close(f);return nil end
    local n=u16(h,5);local bytes=6+n*22
    if bytes>size then file_close(f);error('Truncated ARC1 directory') end
    local s=file_read(f,6,n*22);file_close(f);assert(#s==n*22,'Truncated ARC1 directory')
    local entries={}
    for i=0,n-1 do
        local p=i*22+1;local name=s:sub(p,p+13):match('^[^%z]*');local o,z=u32(s,p+14),u32(s,p+18)
        assert(name~='' and o>=bytes and o+z<=size,'Invalid ARC1 entry')
        entries[#entries+1]={path=path,name=name,offset=o,size=z}
    end
    return entries
end
function engine.detect(path)
    local ok,entries=pcall(directory,path..'/DECORS.DAT')
    if not ok or not entries then return false end
    local raw,pal=false,false
    for _,e in ipairs(entries) do
        if e.name:upper()=='101DECOR.RAW' and e.size==256000 then raw=true end
        if e.name:upper()=='101DECOR.PAL' and e.size==768 then pal=true end
    end
    return raw and pal
end
local function payload(e,limit) return read(e.path,e.offset,math.min(e.size,limit or e.size)) end
local function sprites(s,size)
    assert(s:sub(1,4)=='SPR\0' and u32(s,5)==20,'Invalid SPR header')
    local finish,n=u32(s,17),u16(s,21)
    assert(n>0 and n<=4096 and finish>=22+n*4 and finish<=size,'Invalid SPR frame table')
    local frames={}
    for i=1,n do
        local o=u32(s,23+(i-1)*4);local last=i<n and u32(s,23+i*4) or finish
        assert(o>=22+n*4 and last>=o+8 and last<=finish,'Invalid SPR frame offset')
        frames[i]={offset=o,size=last-o,paletteOffset=finish+(i-1)*4}
    end
    return frames
end
local function pixels(s,f)
    local p=f.offset+1;local x,y,w,h=u16(s,p),u16(s,p+2),u16(s,p+4),u16(s,p+6)
    assert(w>0 and h>0 and w<=2048 and h<=2048 and w*h<=1048576,'Invalid sprite dimensions')
    local finish=f.offset+f.size;p=p+8
    local function rle()
        local out={}
        for i=1,w*h do out[i]=0 end
        for row=0,h-1 do
            local col=0
            while true do
                assert(p<=finish,'Truncated SPR row');local op=s:byte(p);p=p+1
                if op==0 then break end
                local n=op>=128 and op-128 or op
                assert(col+n<=w,'SPR row overrun')
                if op<128 then
                    assert(p+n-1<=finish,'Truncated SPR literals')
                    for j=1,n do out[row*w+col+j]=s:byte(p+j-1) end
                    p=p+n
                end
                col=col+n
            end
        end
        assert(p==finish+1,'Unexpected SPR trailing data')
        return out
    end
    -- Some valid RLE streams have exactly w*h bytes. Validate RLE before
    -- accepting the raw representation, otherwise small effects are corrupted.
    local ok,out=pcall(rle)
    if not ok then
        assert(f.size==8+w*h,out)
        out={};for i=1,w*h do out[i]=s:byte(f.offset+8+i) end
    end
    return w,h,out,x,y
end
local function frame_palette(s,f,base)
    -- Older installer/UI banks use headerless palette blocks; retain the
    -- shared palette until their range mapping is verified.
    if f.legacyPalette then return base end
    local o=u32(s,f.paletteOffset+1)
    if o==0 then return base end
    local first,count=u16(s,o+1),u16(s,o+3)
    assert(first+count<=256 and o+4+count*3<=#s,'Invalid SPR palette patch')
    local p={};for i=1,768 do p[i]=base[i] end
    for i=1,count*3 do
        local v=s:byte(o+4+i);assert(v<=63,'Invalid SPR palette component');p[first*3+i]=v*4
    end
    return p
end

local function pcm(rate,bits,ch,s)
    assert(rate>0 and rate<=192000 and (bits==8 or bits==16) and (ch==1 or ch==2) and #s%(bits/8*ch)==0,'Invalid PCM format')
    return sound_create_pcm(rate,bits,ch,bits==16,s)
end
local function wav(s)
    assert(s:sub(1,4)=='RIFF' and s:sub(9,12)=='WAVE','Invalid WAVE')
    local finish=u32(s,5)+8;assert(finish<=#s,'Truncated WAVE')
    local p,fmt,data=13
    while p+7<=finish do
        local z=u32(s,p+4);assert(p+7+z<=finish,'Invalid WAVE chunk')
        local tag=s:sub(p,p+3)
        if tag=='fmt ' then assert(z>=16,'Short WAVE format');fmt=s:sub(p+8,p+7+z)
        elseif tag=='data' then data=s:sub(p+8,p+7+z) end
        p=p+8+z+z%2
    end
    assert(fmt and data and u16(fmt,1)==1,'Unsupported WAVE encoding')
    return pcm(u32(fmt,5),u16(fmt,15),u16(fmt,3),data)
end
local cp850 = {199,252,233,226,228,224,229,231,234,235,232,239,238,236,196,197,201,230,198,244,246,242,251,249,255,214,220,248,163,216,215,402,225,237,243,250,241,209,170,186,191,174,172,189,188,161,171,187,9617,9618,9619,9474,9508,193,194,192,169,9571,9553,9559,9565,162,165,9488,9492,9524,9516,9500,9472,9532,227,195,9562,9556,9577,9574,9568,9552,9580,164,240,208,202,203,200,305,205,206,207,9496,9484,9608,9604,166,204,9600,211,223,212,210,245,213,181,254,222,218,219,217,253,221,175,180,173,177,8215,190,182,167,247,184,176,168,183,185,179,178,9632,160}
local function utf8char(n)
    if n<128 then return string.char(n) end
    if n<2048 then return string.char(192+floor(n/64),128+n%64) end
    return string.char(224+floor(n/4096),128+floor(n/64)%64,128+n%64)
end
local function text_utf8(s)
    return (s:gsub('[\128-\255]',function(c) return utf8char(cp850[c:byte()-127]) end))
end
-- TXT has two independent u16 offset tables: dialogue (speaker byte and '$'
-- terminator) and NUL-terminated object labels. Offsets are relative to each table.
local function text_table(s,start,finish,dialogue)
    assert(start+1<=finish,'Missing TXT table')
    local first=u16(s,start);assert(first%2==0 and first>=2 and start+first<=finish+1,'Invalid TXT directory')
    local out={}
    for i=0,first/2-1 do
        local o=start+u16(s,start+i*2)
        local last=i+1<first/2 and start+u16(s,start+(i+1)*2)-1 or finish
        assert(o>=start+first and last>=o-1 and last<=finish,'Invalid TXT offset')
        local line=s:sub(o,last)
        if dialogue and #line>0 then
            line=string.format('[speaker %d] ',line:byte(1))..line:sub(2):gsub('%$$','')
        else line=line:gsub('%z+$','') end
        out[#out+1]=string.format('%d: %s',i,text_utf8(line))
    end
    return table.concat(out,'\n\n')
end
local function text(s)
    assert(s:sub(1,4)=='TXT\0','Invalid TXT')
    local a,b=u32(s,5)+1,u32(s,9)+1
    if b==1 then b=#s+1 end
    assert(a>=13 and b>=a and b<=#s+1,'Invalid TXT sections')
    local sections={}
    if b>a then sections[#sections+1]='Dialogue\n\n'..text_table(s,a,b-1,true) end
    if b<=#s then sections[#sections+1]='Object labels\n\n'..text_table(s,b,#s,false) end
    return table.concat(sections,'\n\n')
end
local cachedPath,tree,entries,paletteIds,paletteCache
local function index(path)
    if cachedPath==path then return end
    cachedPath=nil;tree={};entries={};paletteIds={};paletteCache={}
    local categories,archives={},{}
    local function cat(key,name)
        if not categories[key] then
            local c={id=key,name=name,type='category',children={}};categories[key]=c;tree[#tree+1]=c
        end
        return categories[key].children
    end
    local function add(parent,id,name,kind,e,extra)
        local item={kind=kind,e=e};for k,v in pairs(extra or {}) do item[k]=v end
        assert(not entries[id],'Duplicate resource ID');entries[id]=item
        local typ=({raw='image',frame='image',anim='animation',pal='palette',wav='sound',pcm='sound',txt='text',plain='text',data='data'})[kind]
        parent[#parent+1]={id=id,name=name,type=typ};return item
    end
    local names=list_files(path);table.sort(names)
    for _,name in ipairs(names) do
        if name:upper():match('%.DAT$') then
            local es=directory(path..'/'..name)
            if es then archives[#archives+1]={name=name,es=es} end
        end
    end
    -- Register palettes first so every frame has a deterministic default.
    for _,arc in ipairs(archives) do for _,e in ipairs(arc.es) do
        local n=e.name:upper()
        if e.size==768 and (n:match('%.PAL$') or n=='BOOKPAL.RAW' or n=='PALETTE.RAW') then
            local id='pal:'..arc.name..':'..e.name
            add(cat('palettes','Palettes'),id,e.name,'pal',e);paletteIds[n]=id
        end
    end end
    for _,arc in ipairs(archives) do
        local dataParent
        for _,e in ipairs(arc.es) do
            local n=e.name:upper();local id=arc.name..':'..e.name
            local head=payload(e,math.min(e.size,65536));local magic=head:sub(1,4)
            local pal=arc.name:upper()=='INSTALL.DAT' and paletteIds['PALETTE.RAW'] or
                arc.name:upper()=='TITLE.DAT' and paletteIds['BOOKPAL.RAW'] or
                paletteIds[(n:match('^(%d%d%d)') or '101')..'DECOR.PAL'] or paletteIds['101DECOR.PAL']
            if entries['pal:'..id] then -- Already listed above.
            elseif (e.size==256000 or (e.size==64000 and n=='BACKGRND.RAW')) and n:match('%.RAW$') and magic~='SPR\0' then
                add(cat('backgrounds','Backgrounds and Screens'),id,e.name,'raw',e,{w=e.size==64000 and 320 or 640,h=e.size==64000 and 200 or 400,pal=paletteIds[n:gsub('%.RAW$','.PAL')] or pal})
            elseif magic=='SPR\0' then
                local fs=sprites(head,e.size)
                if n=='CLOSEUP.SPR' or n:match('^MISCDAT[EFG]%.SPR$') then
                    for _,f in ipairs(fs) do f.legacyPalette=true end
                end
                local key='sprites:'..arc.name;local parent=cat(key,'Sprites / '..arc.name)
                local bank={id='bank:'..id,name=e.name..' ('..#fs..' frames)',type='category',children={}};parent[#parent+1]=bank
                add(bank.children,'anim:'..id,'Frame bank preview (up to 60 frames)','anim',e,{frames=fs,pal=pal})
                for i,f in ipairs(fs) do add(bank.children,id..':'..i,string.format('Frame %04d',i-1),'frame',e,{frame=f,pal=pal}) end
            elseif magic=='RIFF' then
                add(cat(arc.name:upper()=='SPEECH.DAT' and 'speech' or 'sounds',arc.name:upper()=='SPEECH.DAT' and 'Speech' or 'Sound and Music'),id,e.name,'wav',e)
            elseif magic=='CMB1' then
                local nSounds=u16(head,5);assert(6+nSounds*8<=e.size,'Invalid CMB1 directory')
                for i=0,nSounds-1 do
                    local o,z=u32(head,7+i*8),u32(head,11+i*8)
                    assert(o>=6+nSounds*8 and z>=10 and o+z<=e.size,'Invalid CMB1 sound')
                    add(cat('sounds','Sound and Music'),id..':'..i,e.name..' / '..i,'pcm',
                        {path=e.path,name=e.name,offset=e.offset+o,size=z})
                end
            elseif magic=='TXT\0' then
                add(cat('text:'..arc.name,'Dialogue and Labels / '..arc.name),id,e.name,'txt',e)
            elseif n:match('%.TXT$') or (arc.name:upper()=='INSTALL.DAT' and n=='INSTALL.DAT') then
                add(cat('text:install','Installer Text'),id,e.name,'plain',e)
            else
                if not dataParent then dataParent=cat('data:'..arc.name,'Data / '..arc.name) end
                add(dataParent,id,e.name,'data',e)
            end
        end
    end
    for _,name in ipairs(names) do
        if name:upper():match('%.WAV$') then
            local f=file_open(path..'/'..name)
            if f then local z=file_size(f);file_close(f);add(cat('sounds','Sound and Music'),'loose:'..name,name,'wav',{path=path..'/'..name,name=name,offset=0,size=z}) end
        elseif name:upper():match('%.IMX$') then
            local f=file_open(path..'/'..name)
            if f then local z=file_size(f);file_close(f);add(cat('movies','Movies (metadata)'),'loose:'..name,name,'data',{path=path..'/'..name,name=name,offset=0,size=z}) end
        end
    end
    cachedPath=path
end
function engine.get_resources(path) index(path);return tree end
function engine.default_palette(path,id) index(path);return entries[id] and entries[id].pal end
local function palette(id)
    if paletteCache[id] then return paletteCache[id] end
    local e=entries[id];assert(e and e.kind=='pal','Missing palette')
    local s=payload(e.e);local p={};assert(#s==768,'Invalid palette')
    for i=1,768 do assert(s:byte(i)<=63,'Invalid VGA palette');p[i]=s:byte(i)*4 end
    paletteCache[id]=p;return p
end
function engine.load_resource(path,id,override)
    index(path);local r=entries[id];if not r then return nil end
    local e=r.e;local desc=e.name..' / '..e.size..' bytes'
    if r.kind=='data' then
        local s=payload(e,256);local out={desc,'Preview of undecoded data (first 256 bytes):'}
        if s:sub(1,4)=='IMAX' then out[#out+1]=string.format('IMAX: %d frames, %d fps. Movie playback is not implemented.',u32(s,5),u16(s,9)) end
        for p=1,#s,16 do
            local row={};for j=p,math.min(p+15,#s) do row[#row+1]=string.format('%02X',s:byte(j)) end
            out[#out+1]=string.format('%08X  %s',p-1,table.concat(row,' '))
        end
        return {type='text',text=table.concat(out,'\n'),description=desc}
    end
    local s=payload(e)
    if r.kind=='wav' then return {type='sound',sound=wav(s),description=desc}
    elseif r.kind=='pcm' then
        local z=u32(s,1);assert(z==#s-10,'Invalid CMB1 PCM length')
        return {type='sound',sound=pcm(u16(s,5),u16(s,7),u16(s,9),s:sub(11)),description=desc}
    elseif r.kind=='txt' then return {type='text',text=text(s),description=desc..' / DOS CP850'}
    elseif r.kind=='plain' then return {type='text',text=text_utf8(s),description=desc..' / DOS CP850'} end
    local pal=palette(r.kind=='pal' and id or override or r.pal)
    if r.kind=='pal' then
        local px={};for y=0,255 do for x=0,255 do px[#px+1]=floor(y/16)*16+floor(x/16) end end
        return {type='image',image=image_create_indexed(256,256,px,pal),palette=pal,description=desc}
    elseif r.kind=='raw' then
        local px={};assert(#s==r.w*r.h,'Invalid raw image');for i=1,#s do px[i]=s:byte(i) end
        return {type='image',image=image_create_indexed(r.w,r.h,px,pal),description=desc,palette=pal}
    elseif r.kind=='frame' then
        local w,h,px,x,y=pixels(s,r.frame)
        if not override then pal=frame_palette(s,r.frame,pal) end
        return {type='image',image=image_create_indexed(w,h,px,pal),palette=pal,
            description=string.format('%s / %dx%d / stored anchor (%d,%d)',desc,w,h,x,y)}
    elseif r.kind=='anim' then
        -- A bounded frame-bank overview, not the game's scripted sequence.
        local handles,total={},0
        for _,f in ipairs(r.frames) do
            local w,h,px=pixels(s,f)
            if #handles>=60 or total+w*h>4000000 then break end
            handles[#handles+1]=image_create_indexed(w,h,px,override and pal or frame_palette(s,f,pal));total=total+w*h
        end
        return {type='animation',image=handles[1],animation=animation_create(handles,100),frames=handles,palette=pal,
            description=desc..' / stored frame bank, 100 ms preview; script order, timing and placement are not reconstructed'}
    end
end
return engine

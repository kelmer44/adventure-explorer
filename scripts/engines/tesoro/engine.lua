-- El Tesoro de la Isla Alcachofa (Alcachofa Soft, 2000).
-- TRE records index size-prefixed DAT resources. ANM banks contain variable
-- frame records and RGB565 scanline spans; LVL embeds sequential ANM banks.
local engine = {id="tesoro", name="El Tesoro de la Isla Alcachofa", version="1.0",
    description="Alcachofa Soft: Tesoro backgrounds, sprites, animations, speech and scripts"}
local floor = math.floor
local function u16(s,p) return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function read(path,offset,size)
    local f=file_open(path); if not f then return nil end
    local n=file_size(f)
    if offset<0 or size<0 or offset+size>n then file_close(f); return nil end
    local d=file_read(f,offset,size); file_close(f)
    return d and #d==size and d or nil
end
local function resolve(path,name)
    for _,n in ipairs(list_files(path) or {}) do if n:upper()==name then return path.."/"..n end end
end
local function latin1(s)
    return (s:gsub("[\128-\255]",function(c)
        local b=c:byte(); return string.char(192+floor(b/64),128+b%64)
    end))
end
local function strings(s)
    local out={}
    for v in s:gmatch("[%w%p \128-\255][%w%p \128-\255][%w%p \128-\255][%w%p \128-\255]+") do
        out[#out+1]=latin1(v)
    end
    return table.concat(out,"\n")
end
local function parse_index(t,dat_size)
    if not t or #t<28 or #t%28~=0 then return nil end
    local out={}
    for p=1,#t-27,28 do
        local flag=t:byte(p+8)
        if floor(flag/4)%2==1 then
            -- Each record starts with offset/size, then flags and a 19-byte name.
            local name=t:sub(p+9,p+27):match("^[^%z]*")
            local off,size=u32(t,p),u32(t,p+4)
            if name~="" and off+4+size<=dat_size then
                out[#out+1]={name=name,offset=off,size=size,index=(p-1)/28}
            end
        end
    end
    return out
end
local function bank(s,p)
    if p+27>#s or (s:sub(p,p+3)~="ANM\1" and s:sub(p,p+3)~="ANM\0") then return nil end
    local nf,ni=u16(s,p+4),u16(s,p+8)
    if nf>10000 or ni>10000 then return nil end
    local font=s:byte(p+3)==0
    local name=not font and s:sub(p+12,p+23):match("^[^%z]*") or "Font glyphs"
    local q=p+28
    for _=1,nf do
        if q+23>#s then return nil end
        q=q+24+u16(s,q+22)
        if q>#s+1 then return nil end
    end
    local images={}
    for _=1,ni do
        if q+19>#s then return nil end
        local size=u32(s,q); local base=q+4
        local w,h,typ=u16(s,base+8),u16(s,base+10),u16(s,base+12)
        if size<16+h*8 or base+size-1>#s or w<1 or h<1 or w>4096 or h>4096
            or w*h>8388608 or typ<1 or typ>3 then return nil end
        images[#images+1]={base=base,size=size,width=w,height=h,kind=typ}
        q=base+size
    end
    return {name=name,images=images,frames=nf,font=font},q
end
local function banks(s)
    local out={}; local p,n=1,1
    if s:sub(1,4)=="LVL\1" then
        if #s<16 then return nil end
        n=u32(s,9);p=17
        if n>10000 then return nil end
    end
    for _=1,n do
        local b,q=bank(s,p); if not b then return nil end
        out[#out+1]=b;p=q
    end
    return out,p
end
local function rgb(v)
    return floor(floor(v/2048)*255/31),floor(floor(v/32)%64*255/63),floor(v%32*255/31)
end
local function decode_image(s,im)
    local b,sz,w,h=im.base,im.size,im.width,im.height
    if b+sz-1>#s then return nil end
    local pixel_start=u32(s,b)
    if pixel_start<16+h*8 or pixel_start>sz then return nil end
    local pixels={}; for i=1,w*h*3 do pixels[i]=0 end
    for y=0,h-1 do
        local row=b+16+y*8;local off,count=u32(s,row),u16(s,row+4)
        if off<16+h*8 or off+count*8>pixel_start then return nil end
        local x=0
        for j=0,count-1 do
            local sp=b+off+j*8;local value,skip,len=u32(s,sp),u16(s,sp+4),u16(s,sp+6)
            x=x+skip
            if x+len>w then return nil end
            if im.kind==1 and (value<pixel_start or value+len*2>sz) then return nil end
            for k=0,len-1 do
                local r,g,blue
                if im.kind==2 then r=floor(value%32*255/31);g=r;blue=r
                else r,g,blue=rgb(im.kind==1 and u16(s,b+value+k*2) or value%65536) end
                local dst=(y*w+x+k)*3+1;pixels[dst]=r;pixels[dst+1]=g;pixels[dst+2]=blue
            end
            x=x+len
        end
    end
    return pixels
end
local function wav(s)
    if #s<12 or s:sub(1,4)~="RIFF" or s:sub(9,12)~="WAVE" then return nil end
    local finish=u32(s,5)+8
    if finish>#s then return nil end
    local p,fmt,pcm=13
    while p+7<=finish do
        local n=u32(s,p+4);if p+7+n>finish then return nil end
        local tag=s:sub(p,p+3)
        if tag=="fmt " and n>=16 then
            fmt={codec=u16(s,p+8),channels=u16(s,p+10),rate=u32(s,p+12),align=u16(s,p+20),bits=u16(s,p+22)}
        elseif tag=="data" then pcm=s:sub(p+8,p+7+n) end
        p=p+8+n+n%2
    end
    if not fmt or not pcm or fmt.codec~=1 or (fmt.bits~=8 and fmt.bits~=16)
        or fmt.channels<1 or fmt.channels>2 or fmt.rate<1
        or fmt.align~=fmt.channels*fmt.bits/8 or #pcm%fmt.align~=0 then return nil end
    return sound_create_pcm(fmt.rate,fmt.bits,fmt.channels,fmt.bits==16,pcm)
end
local cache={}
local function catalog(path)
    if cache.path==path then return cache end
    cache={path=path,entries={}}
    cache.dat=resolve(path,"TESORO.DAT");local tre=resolve(path,"TESORO.TRE")
    if not cache.dat or not tre then return cache end
    local f=file_open(cache.dat);if not f then return cache end
    local size=file_size(f);file_close(f)
    f=file_open(tre);if not f then return cache end
    local t=file_read(f,0,file_size(f));file_close(f)
    cache.list=parse_index(t,size) or {}
    return cache
end
local function payload(c,e) return read(c.dat,e.offset+4,e.size) end
function engine.detect(path)
    return resolve(path,"TESORO.TRE")~=nil and resolve(path,"TESORO.DAT")~=nil
end
function engine.get_resources(path)
    local c=catalog(path);c.entries={}
    local groups={};local order={"Scenes","Player animations","Fonts","Speech and sounds","Scripts and data","Empty entries"}
    for _,n in ipairs(order) do groups[n]={} end
    for _,e in ipairs(c.list or {}) do
        local id="entry_"..e.index; c.entries[id]=e
        local ext=e.name:lower():match("%.(%w+)$"); local nodes=groups["Scripts and data"]
        local node={id=id,name=e.name,type="text"}
        if e.size==0 then nodes=groups["Empty entries"]
        elseif ext=="wav" then nodes=groups["Speech and sounds"];node.type="sound"
        elseif ext=="lvl" or ext=="anm" or ext=="an" then
            nodes=groups[ext=="lvl" and "Scenes" or (e.name:upper()=="FUENTES.ANM" and "Fonts" or "Player animations")]
            local s=payload(c,e);local bs=s and banks(s)
            node.id="resource_"..e.index;node.type="category";node.children={{id=id,name="Resource information",type="text"}}
            for bi,b in ipairs(bs or {}) do
                local children={}
                for ii,im in ipairs(b.images) do
                    local iid=id.."_"..bi.."_"..ii
                    c.entries[iid]={source=e,bank=bi,image=ii}
                    children[#children+1]={id=iid,name=string.format("Image %d (%dx%d)%s",ii,im.width,im.height,im.kind==2 and " - shadow mask" or ""),type="image"}
                end
                if #b.images>1 and not b.font then
                    local aid=id.."_"..bi.."_anim";c.entries[aid]={source=e,bank=bi,animation=true}
                    children[#children+1]={id=aid,name="Animation preview (100 ms per image)",type="animation"}
                end
                if #children>0 then node.children[#node.children+1]={id=id.."_bank_"..bi,name=b.name~="" and b.name or "Bank "..bi,type="category",children=children} end
            end
        end
        nodes[#nodes+1]=node
    end
    local tree={}
    for i,n in ipairs(order) do if #groups[n]>0 then tree[#tree+1]={id="group_"..i,name=n,type="category",children=groups[n]} end end
    return tree
end
function engine.load_resource(path,id)
    local c=catalog(path);if not next(c.entries) then engine.get_resources(path) end
    local e=c.entries[id];if not e then return nil end
    if e.source then
        local s=payload(c,e.source);local bs=s and banks(s);local b=bs and bs[e.bank]
        if not b then return nil end
        if e.animation then
            local handles={}
            for _,im in ipairs(b.images) do
                local px=decode_image(s,im);if not px then return nil end
                handles[#handles+1]=image_create_rgb(im.width,im.height,px)
            end
            return {type="animation",animation=animation_create(handles,100),image=handles[1],description=e.source.name.." - image sequence, uniform preview timing"}
        end
        local im=b.images[e.image];local px=im and decode_image(s,im)
        if not px then return nil end
        return {type="image",image=image_create_rgb(im.width,im.height,px),description=e.source.name.." - "..im.width.."x"..im.height}
    end
    if e.size==0 then return {type="text",text=e.name.."\nEmpty archive entry."} end
    local s=payload(c,e);if not s then return nil end
    if e.name:lower():match("%.wav$") then
        local snd=wav(s);return snd and {type="sound",sound=snd,description=e.name} or nil
    end
    local text=string.format("%s\nDAT offset: %d\nPayload size: %d bytes\n",e.name,e.offset+4,e.size)
    if e.name:lower():match("%.txt$") then text=latin1(s)
    else text=text.."\nReadable strings:\n"..strings(s) end
    return {type="text",text=text,description=e.name}
end
return engine

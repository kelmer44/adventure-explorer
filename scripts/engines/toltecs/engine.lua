-- WESTERN resource browser. Format reference: ScummVM engines/toltecs.
local engine = {id="toltecs", name="3 Skulls of the Toltecs", version="1.0",
    description="3 Skulls of the Toltecs (1996, Revistronic)"}
local floor = math.floor
local function u16(s,p) return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function read(path,off,size)
    if size==0 then return "" end
    local f=assert(file_open(path),"Missing WESTERN archive")
    local s=file_read(f,off,size);file_close(f)
    assert(s and #s==size,"Truncated WESTERN archive")
    return s
end
local function locate(path)
    if file_exists(path.."/WESTERN") then return path.."/WESTERN" end
    -- CD releases put the archive in a language .PDI directory.
    local names=list_files(path) or {};table.sort(names)
    for _,n in ipairs(names) do
        if n:upper():match("%.PDI$") and file_exists(path.."/"..n.."/WESTERN") then
            return path.."/"..n.."/WESTERN"
        end
    end
end
local function directory(path)
    local f=assert(file_open(path));local size=file_size(f)
    local h=file_read(f,0,4)
    if not h or #h<4 then file_close(f);error("Truncated WESTERN header") end
    local first=u32(h,1)
    if first<8 or first%4~=0 or first>262144 or first>size then
        file_close(f);error("Invalid WESTERN directory size")
    end
    local s=file_read(f,0,first);file_close(f)
    assert(s and #s==first,"Truncated WESTERN directory")
    local offsets={}
    for p=1,#s,4 do
        local off=u32(s,p)
        -- Original media has one final non-offset word after the last offset.
        if off<first then
            assert(p==#s-3,"Invalid WESTERN offset")
        else
            assert(off<=size and (#offsets==0 or off>=offsets[#offsets]),"Invalid WESTERN offset")
            offsets[#offsets+1]=off
        end
    end
    if offsets[#offsets]<size then offsets[#offsets+1]=size end
    local entries={}
    for i=1,#offsets-1 do
        entries[i]={index=i-1,offset=offsets[i],size=offsets[i+1]-offsets[i]}
    end
    return entries,size,first
end
local function vga(s,p,n)
    if p+n-1>#s then return false end
    for i=p,p+n-1 do if s:byte(i)>63 then return false end end
    return true
end
local function dimensions(w,h) return w>0 and h>0 and w<=4096 and h<=1200 and w*h<=2097152 end
-- Scene/GUI: high bit indicates a run of next-byte+2 pixels.
local function rle(s,p,last,w,h,base,emit)
    local pixels,n={},0
    while n<w*h do
        assert(p<=last,"Truncated image RLE")
        local b=s:byte(p);p=p+1;local count=1
        if b>=128 then
            assert(p<=last,"Truncated image run")
            b=b-128;count=s:byte(p)+2;p=p+1
        end
        assert(n+count<=w*h,"Invalid image run")
        if emit then for j=1,count do pixels[n+j]=(b+base)%256 end end
        n=n+count
    end
    return pixels,p
end
local function sprite_headers(s)
    if #s<12 then return end
    local first=u32(s,9)
    if first<12 or first%12~=0 or first>#s or first/12>4096 then return end
    local frames={}
    for p=1,first,12 do
        local h,w,off=u16(s,p+4),u16(s,p+6),u32(s,p+8)
        if not dimensions(w,h) or off<first or off>=#s then return end
        if #frames>0 and off<=frames[#frames].offset then return end
        frames[#frames+1]={w=w,h=h,offset=off}
    end
    return frames
end
local function sprite_pixels(s,frame,last,mode,emit)
    local pixels,p,n={},frame.offset+1,0
    for y=1,frame.h do
        local x=0
        while x<frame.w do
            assert(p<=last,"Truncated sprite")
            local b=s:byte(p);p=p+1;local color,count
            if mode==16 then color=floor(b/16);count=b%16
            elseif mode==256 then
                assert(p<=last,"Truncated sprite run")
                color=b;count=s:byte(p);p=p+1
            else color=b>=128 and 255 or 0;count=b%128 end
            assert(x+count<=frame.w,"Sprite row overrun")
            if emit then for j=1,count do pixels[n+j]=color end end
            x=x+count;n=n+count
        end
    end
    assert(p==last+1,"Sprite payload size mismatch")
    return pixels
end
local function sprite_mode(s,frames)
    for _,mode in ipairs({16,256,1}) do
        local ok=pcall(function()
            for i,f in ipairs(frames) do
                sprite_pixels(s,f,frames[i+1] and frames[i+1].offset or #s,mode,false)
            end
        end)
        if ok then return mode end
    end
end
-- Animation packets are (count,nibble-swapped color); zero count skips pixels.
local function delta(s,p,last,pixels,total)
    local n=0
    while n<total do
        assert(p+1<=last,"Truncated animation RLE")
        local count,b=s:byte(p,p+1);p=p+2
        if count==0 then count=b
        else
            b=(b%16)*16+floor(b/16)
            assert(n+count<=total,"Animation run overrun")
            for j=1,count do pixels[n+j]=b end
        end
        assert(count>0 and n+count<=total,"Invalid animation skip")
        n=n+count
    end
    assert(p==last+1,"Animation payload size mismatch")
end
local function animation_frames(s,w,h,count)
    local frames,p={},775
    while #frames<count+1 and p+3<=#s do
        local size=u32(s,p);p=p+4
        assert(p+math.max(1,size)-1<=#s,"Truncated animation frame")
        if size>1 then
            frames[#frames+1]={offset=p,size=size}
        else
            assert(#frames>0,"Animation starts with a hold")
            local hold=s:byte(p);assert(hold>0,"Empty animation hold")
            for _=1,math.min(hold,count+1-#frames) do frames[#frames+1]=frames[#frames] end
        end
        p=p+math.max(1,size)
    end
    assert(#frames==count+1 and p==#s+1,"Animation frame count mismatch")
    return frames
end
local cache
local function catalog(path)
    if cache and cache.path==path then return cache end
    local archive=assert(locate(path),"No WESTERN archive found")
    local entries,size,first=directory(archive)
    local c={path=path,archive=archive,entries=entries,byid={}}
    -- Raw sounds have no header. These ranges are verified only for this Spanish CD.
    local spanish=size==308391018 and first==19364 and #entries==4840
    for _,e in ipairs(entries) do
        e.kind="data";e.id="toltecs/"..e.index
        local s=read(archive,e.offset,math.min(e.size,778))
        if s:sub(1,4)=="MThd" or (s:sub(1,4)=="FORM" and s:sub(9,12)=="XDIR") then e.kind="music"
        elseif spanish and e.size>0 and ((e.index>=936 and e.index<=4800) or (e.index>=4819 and e.index<=4822)) then e.kind="sound"
        elseif #s>=392 and u32(s,1)>=388 and u32(s,1)+4<=e.size
            and dimensions(u16(s,7),u16(s,5)) and vga(s,9,384) then
            e.kind="scene";e.w=u16(s,7);e.h=u16(s,5)
        elseif #s>=778 and dimensions(u16(s,3),u16(s,1)) and u16(s,5)>0 and u16(s,5)<=5000 and vga(s,7,768) then
            e.kind="animation";e.w=u16(s,3);e.h=u16(s,1)
            e.frames=animation_frames(read(archive,e.offset,e.size),e.w,e.h,u16(s,5))
        elseif e.size>=3 and e.size<=768 and e.size%3==0 and vga(s,1,e.size) then e.kind="palette"
        else
            local frames=sprite_headers(s)
            -- Header tables can be larger than the sniff buffer.
            if not frames and #s>=12 and u32(s,9)>=12 and u32(s,9)%12==0 and u32(s,9)<=e.size and u32(s,9)<=49152 then
                frames=sprite_headers(read(archive,e.offset,e.size))
            end
            if frames then
                local full=read(archive,e.offset,e.size);local mode=sprite_mode(full,frames)
                if mode then e.kind="sprite";e.frames=frames;e.mode=mode end
            end
            if e.kind=="data" and #s>=4 and u16(s,1)==4 and s:byte(3)>0 and s:byte(4)>0 then
                local full=read(archive,e.offset,e.size)
                if pcall(rle,full,5,#full,s:byte(3),s:byte(4),224,false) then
                    e.kind="gui";e.w=s:byte(3);e.h=s:byte(4)
                end
            end
        end
        c.byid[e.id]=e
    end
    cache=c;return c
end
function engine.detect(path)
    local archive=locate(path)
    if not archive then return false end
    return pcall(directory,archive)
end
local function node(id,name,kind) return {id=id,name=name,type=kind} end
function engine.get_resources(path)
    local c=catalog(path);local tree,cats={},{}
    for _,item in ipairs({{"scene","Backgrounds"},{"sprite","Sprites"},{"gui","Interface images"},
        {"animation","Animations"},{"palette","Palettes"},{"sound","Speech and sound"},{"music","Music"},{"data","Scripts and data"}}) do
        local cat=node("toltecs/"..item[1],item[2],"category");cat.children={};cats[item[1]]=cat;tree[#tree+1]=cat
    end
    for _,e in ipairs(c.entries) do
        local name=string.format("Resource %04d",e.index)
        if e.kind=="sprite" then
            local cat=node(e.id,name.." ("..#e.frames.." frames)","category");cat.children={}
            for i,f in ipairs(e.frames) do
                cat.children[#cat.children+1]=node(e.id.."/frame/"..i,string.format("Frame %d (%dx%d)",i,f.w,f.h),"image")
            end
            cats.sprite.children[#cats.sprite.children+1]=cat
        elseif e.kind=="animation" then
            local cat=node(e.id,name.." ("..#e.frames.." frames)","category");cat.children={}
            local batch=math.min(100,math.max(1,floor(8000000/(e.w*e.h))))
            for i=1,#e.frames,batch do
                local last=math.min(#e.frames,i+batch-1)
                cat.children[#cat.children+1]=node(e.id.."/anim/"..i.."/"..last,string.format("Frames %d-%d",i,last),"animation")
            end
            cats.animation.children[#cats.animation.children+1]=cat
        else
            local kind=({scene="image",gui="image",palette="palette",sound="sound",music="midi",data="text"})[e.kind]
            cats[e.kind].children[#cats[e.kind].children+1]=node(e.id,name.." ("..e.size.." bytes)",kind)
        end
        if e.kind=="scene" or e.kind=="animation" then
            cats.palette.children[#cats.palette.children+1]=node(e.id.."/palette",name.." embedded palette","palette")
        end
    end
    return tree
end
local function palette(c,id)
    local pal={};for i=0,255 do for j=1,3 do pal[i*3+j]=i end end
    if not id then return pal end
    local e=c.byid[id:gsub("/palette$","")];assert(e,"Unknown palette")
    local off,n,start=0,e.size,0
    if e.kind=="scene" then off=8;n=384
    elseif e.kind=="animation" then off=6;n=768
    else
        assert(e.kind=="palette","Resource is not a palette")
        if e.index==9 and n==96 then start=224*3 end
    end
    local s=read(c.archive,e.offset+off,n)
    for i=1,#s do pal[start+i]=s:byte(i)*4 end
    return pal
end
function engine.default_palette(path,id)
    local c=catalog(path);local base=id:match("^(toltecs/%d+)");local e=c.byid[base]
    if e and (e.kind=="scene" or e.kind=="animation") then return e.id.."/palette" end
    if e and e.kind=="gui" and c.entries[10] and c.entries[10].kind=="palette" then return c.entries[10].id end
end
function engine.load_resource(path,id,palette_id)
    local c=catalog(path);local base=id:match("^(toltecs/%d+)");local e=assert(c.byid[base],"Unknown resource")
    local desc=string.format("WESTERN resource %d, offset %d, %d bytes",e.index,e.offset,e.size)
    if e.kind=="palette" or id:match("/palette$") then
        local pal=palette(c,id);local pixels={}
        for y=0,127 do for x=0,127 do pixels[#pixels+1]=floor(y/8)*16+floor(x/8) end end
        return {type="image",image=image_create_indexed(128,128,pixels,pal),description=desc}
    end
    local s=read(c.archive,e.offset,e.kind=="data" and math.min(e.size,8192) or e.size)
    if e.kind=="sound" then return {type="sound",sound=sound_create_pcm(22050,8,1,false,s),description=desc} end
    if e.kind=="music" then return {type="midi",midi=midi_create_auto(s),description=desc} end
    local pal=palette(c,palette_id or engine.default_palette(path,id))
    if e.kind=="scene" or e.kind=="gui" then
        local pixels=rle(s,e.kind=="scene" and 393 or 5,e.kind=="scene" and u32(s,1)+4 or #s,e.w,e.h,e.kind=="scene" and 0 or 224,true)
        return {type="image",image=image_create_indexed(e.w,e.h,pixels,pal),description=desc}
    elseif e.kind=="sprite" then
        local i=assert(tonumber(id:match("/frame/(%d+)$")),"Select a sprite frame")
        local f=assert(e.frames[i],"Unknown sprite frame")
        if not palette_id and e.mode==16 then
            for color=0,15 do for j=1,3 do pal[color*3+j]=color*17 end end
        end
        local pixels=sprite_pixels(s,f,e.frames[i+1] and e.frames[i+1].offset or #s,e.mode,true)
        return {type="image",image=image_create_indexed(f.w,f.h,pixels,pal),description=desc.."; "..(e.mode==1 and "shadow mask" or tostring(e.mode).."-color sprite; select a palette fragment for colors")}
    elseif e.kind=="animation" then
        local a,b=id:match("/anim/(%d+)/(%d+)$");a=assert(tonumber(a));b=assert(tonumber(b))
        assert(a>=1 and b>=a and b<=#e.frames and b-a<100 and (b-a+1)*e.w*e.h<=8000000,"Invalid animation range")
        local pixels,handles={},{};for i=1,e.w*e.h do pixels[i]=0 end
        local previous
        for i=1,b do
            local frame=e.frames[i]
            if frame~=previous then delta(s,frame.offset,frame.offset+frame.size-1,pixels,e.w*e.h) end
            previous=frame
            if i>=a then handles[#handles+1]=image_create_indexed(e.w,e.h,pixels,pal) end
        end
        return {type="animation",animation=animation_create(handles,100),image=handles[1],frames=handles,description=desc.."; stored frames and holds at 100 ms"}
    end
    local lines={desc,"Scripts, fonts, cursor data, scene logic and movies are not interpreted.","Hex preview (first 8192 bytes):"}
    for p=1,#s,16 do
        local hex,ascii={},{}
        for i=p,math.min(p+15,#s) do local v=s:byte(i);hex[#hex+1]=string.format("%02X",v);ascii[#ascii+1]=(v>=32 and v<127) and string.char(v) or "." end
        lines[#lines+1]=string.format("%04X  %-47s  %s",p-1,table.concat(hex," "),table.concat(ascii))
    end
    return {type="text",text=table.concat(lines,"\n"),description=desc}
end
return engine

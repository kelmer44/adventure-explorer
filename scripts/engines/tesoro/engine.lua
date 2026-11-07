-- El Tesoro de la Isla Alcachofa (Alcachofa Soft, 2000).
-- TRE records index size-prefixed DAT resources. ANM banks contain variable
-- frame records and RGB565 scanline spans; LVL embeds sequential ANM banks.
local engine = {id="tesoro", name="El Tesoro de la Isla Alcachofa", version="1.1",
    description="Alcachofa Soft: Tesoro rooms, sprites, step animations, speech text and scripts"}
local floor = math.floor
local function u16(s,p) return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function s16(s,p) local v=u16(s,p); return v>=32768 and v-65536 or v end
local function s32(s,p) local v=u32(s,p); return v>=2147483648 and v-4294967296 or v end
local function gcd(a,b) while b>0 do a,b=b,a%b end return a end
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
-- Game text is DOS code page 850 ("est\160" is "est\225"), converted to UTF-8 for display.
local cp850={199,252,233,226,228,224,229,231,234,235,232,239,238,236,196,197,201,230,198,244,246,242,251,249,255,214,220,248,163,216,215,402,225,237,243,250,241,209,170,186,191,174,172,189,188,161,171,187,9617,9618,9619,9474,9508,193,194,192,169,9571,9553,9559,9565,162,165,9488,9492,9524,9516,9500,9472,9532,227,195,9562,9556,9577,9574,9568,9552,9580,164,240,208,202,203,200,305,205,206,207,9496,9484,9608,9604,166,204,9600,211,223,212,210,245,213,181,254,222,218,219,217,253,221,175,180,173,177,8215,190,182,167,247,184,176,168,183,185,179,178,9632,160}
local function utf8char(cp)
    if cp<0x800 then return string.char(192+floor(cp/64),128+cp%64) end
    return string.char(224+floor(cp/4096),128+floor(cp/64)%64,128+cp%64)
end
local function dos_text(s)
    return (s:gsub("[\128-\255]",function(c) return utf8char(cp850[c:byte()-127]) end))
end
local function strings(s)
    local out={}
    for v in s:gmatch("[%w%p \128-\255][%w%p \128-\255][%w%p \128-\255][%w%p \128-\255]+") do
        out[#out+1]=dos_text(v)
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
                out[#out+1]={name=name,offset=off,size=size,index=floor((p-1)/28)}
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
    local steps={}
    for k=1,nf do
        if q+23>#s then return nil end
        steps[k]={ix=s16(s,q),iy=s16(s,q+2),x=s16(s,q+4),y=s16(s,q+6),dur=u16(s,q+8),img=s16(s,q+10),
            hx=s16(s,q+12),hy=s16(s,q+14),hw=s16(s,q+16),hh=s16(s,q+18),typ=u16(s,q+20)}
        q=q+24+u16(s,q+22)
        if q>#s+1 then return nil end
    end
    -- Step movement is stored absolute; the game uses it relative to the first step.
    if steps[1] then
        local x0,y0=steps[1].x,steps[1].y
        for k=2,#steps do steps[k].x=steps[k].x-x0;steps[k].y=steps[k].y-y0 end
        steps[1].x=0;steps[1].y=0
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
    return {name=name,images=images,frames=nf,font=font,steps=steps},q
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
    local alpha={}; for i=1,w*h do alpha[i]=0 end
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
                local px=y*w+x+k;local dst=px*3+1;pixels[dst]=r;pixels[dst+1]=g;pixels[dst+2]=blue;alpha[px+1]=255
            end
            x=x+len
        end
    end
    return pixels,alpha
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

-- Speech: OBJETOS/ANIMS/CONVERS/ICONS.TXT hold `ID, "text".` lines; ID.WAV is the voice clip.
local speech_files={OBJETOS=true,ANIMS=true,CONVERS=true,ICONS=true}
local function speech_table(c)
    if c.speech then return c.speech end
    local t={}
    for _,e in ipairs(c.list or {}) do
        local base=e.name:upper():match("^(%w+)%.TXT$")
        if base and speech_files[base] and e.size>0 then
            local s=payload(c,e)
            if s then
                for key,text in s:gmatch('([%w_]+)%s*,%s*"([^"]*)"') do
                    local k=key:upper(); local clean=text:gsub("%s+"," "):match("^%s*(.-)%s*$")
                    if not t[k] and clean~="" then t[k]=dos_text(clean) end
                end
            end
        end
    end
    c.speech=t
    return t
end
local function spoken(c,name)
    local id=name:upper():match("^(.-)%.WAV$")
    return id and speech_table(c)[id] or nil
end
local function clip(text,n)
    if #text<=n then return text end
    local cut=text:sub(1,n)
    -- Do not cut inside a UTF-8 sequence produced by dos_text().
    cut=cut:gsub("[\192-\255][\128-\191]*$","")
    return cut.."..."
end
-- Dialogue scripts list `ID, speaker.` lines; show what is said next to them.
local function annotate_script(c,s)
    local sp=speech_table(c)
    local text=dos_text((s:gsub("\r","")))
    return (text:gsub("[^\n]+",function(line)
        local id=line:match("^%s*([%w_]+)%s*,%s*%d+%s*$")
        local said=id and sp[id:upper()]
        return said and (line.."    // "..said) or line
    end))
end

-- Animation steps -------------------------------------------------------
-- A bank is a list of steps (image index, draw offset, duration, hit box, ...);
-- runs of consecutive steps with images are what the game plays as one animation.
local function runs(b)
    local out,cur={},nil
    for k,st in ipairs(b.steps) do
        if st.img>=0 and st.img<#b.images then
            if not cur then cur={first=k,last=k};out[#out+1]=cur else cur.last=k end
        else cur=nil end
    end
    return out
end
-- Draw position of a step image, relative to the object origin, in screen axes (y down).
local function step_place(st) return st.x+st.ix,-st.y-st.iy end
local function image_cache(s,b)
    local cached={}
    return function(i)
        local d=cached[i]
        if d==nil then
            local im=b.images[i+1]
            local px,al
            if im then px,al=decode_image(s,im) end
            d=px and {w=im.width,h=im.height,px=px,alpha=al,kind=im.kind} or false
            cached[i]=d
        end
        return d or nil
    end
end
local function make_image(d) return image_create_rgb(d.w,d.h,d.px,d.alpha) end
local MAX_DIM,MAX_FRAMES,MAX_HOLD=2048,300,1000
-- Lay out a run's steps on one canvas without decoding any pixels.
local function run_layout(b,r)
    local items={}
    for k=r.first,r.last do
        local st=b.steps[k];local im=b.images[st.img+1];if not im then return nil end
        local px,py=step_place(st)
        items[#items+1]={st=st,w=im.width,h=im.height,px=px,py=py,dur=math.min(st.dur,MAX_HOLD)}
    end
    local function bounds()
        local x0,y0,x1,y1
        for _,it in ipairs(items) do
            x0=math.min(x0 or it.px,it.px);y0=math.min(y0 or it.py,it.py)
            x1=math.max(x1 or it.px+it.w,it.px+it.w);y1=math.max(y1 or it.py+it.h,it.py+it.h)
        end
        return x0,y0,x1,y1
    end
    local x0,y0,x1,y1=bounds()
    -- Some steps are parked far off screen; drop the ones that stretch the canvas most.
    local dropped=0
    while (x1-x0>MAX_DIM or y1-y0>MAX_DIM) and #items>2 and dropped<8 do
        local best,gain
        for i=1,#items do
            local keep=table.remove(items,i)
            local a,b2,c2,d2=bounds()
            local area=(c2-a)*(d2-b2)
            table.insert(items,i,keep)
            if not gain or area<gain then best,gain=i,area end
        end
        table.remove(items,best);dropped=dropped+1
        x0,y0,x1,y1=bounds()
    end
    local W,H=x1-x0,y1-y0
    if #items<2 or W>MAX_DIM or H>MAX_DIM or W*H>MAX_DIM*MAX_DIM/4 then return nil end
    return items,x0,y0,W,H,dropped
end
local function run_frames(s,b,r)
    local get=image_cache(s,b)
    local items,x0,y0,W,H,dropped=run_layout(b,r)
    if not items then return nil end
    for _,it in ipairs(items) do it.d=get(it.st.img);if not it.d then return nil end end
    -- Choose a uniform frame delay so every step keeps its duration.
    local g,total=0,0
    for _,it in ipairs(items) do g=gcd(g,it.dur);total=total+it.dur end
    if g<10 then g=10 end
    if total/g>MAX_FRAMES then g=math.ceil(total/MAX_FRAMES) end
    local frames,made={},{}
    for _,it in ipairs(items) do
        local d=it.d
        local key=it.st.img..","..it.px..","..it.py
        local handle=made[key]
        if not handle then
            local rgb,al={},{}
            for i=1,W*H*3 do rgb[i]=0 end
            for i=1,W*H do al[i]=0 end
            local ox,oy=it.px-x0,it.py-y0
            for y=0,d.h-1 do
                for x=0,d.w-1 do
                    local si=y*d.w+x;local di=(oy+y)*W+ox+x
                    if d.alpha[si+1]>0 then
                        al[di+1]=255
                        rgb[di*3+1]=d.px[si*3+1];rgb[di*3+2]=d.px[si*3+2];rgb[di*3+3]=d.px[si*3+3]
                    end
                end
            end
            handle=image_create_rgb(W,H,rgb,al);made[key]=handle
        end
        for _=1,math.max(1,floor(it.dur/g+0.5)) do frames[#frames+1]=handle end
    end
    return frames,g,total,dropped
end

-- Levels ----------------------------------------------------------------
local kind_names={[0]="Object",[1]="Camera frame",[2]="Item group",[3]="Sprite",[4]="Shadow sprite",[5]="Character",
    [6]="Exit door",[7]="Walk floor",[8]="Path",[10]="Cursor",[11]="Inventory strip",[13]="Inventory item",
    [14]="Depth zone",[15]="Click catcher",[16]="Path sprite",[19]="Map place",[21]="Board column",
    [22]="Menu button",[23]="Slot label",[24]="Note",[25]="Menu item"}
local function level_rooms(s,p)
    local rooms,count={},u32(s,5)
    if count>1000 then return nil end
    for r=0,count-1 do
        if p+0x27>#s then return nil end
        local oc,extent=u16(s,p+0x20),u16(s,p+0x22)
        local room={index=r,background=s32(s,p+0x24),extent=extent,objects={}}
        p=p+0x28
        for _=1,oc do
            if p+0x1f>#s then return nil end
            local extra=u32(s,p+0x1c);local nb=s:byte(p+11)
            if extra>4096 or p+0x20+extra+nb-1>#s then return nil end
            local ob={x=s32(s,p),y=s32(s,p+4),sort=s16(s,p+8),name=s:sub(p+12,p+23):match("^[^%z]*"),
                kind=u32(s,p+0x18),data=s:sub(p+0x20,p+0x1f+extra),banks={}}
            for k=1,nb do ob.banks[k]=s:byte(p+0x1f+extra+k) end
            room.objects[#room.objects+1]=ob
            p=p+0x20+extra+nb
        end
        rooms[#rooms+1]=room
    end
    return rooms
end
local function level_data(s)
    local bs,p=banks(s); if not bs then return nil end
    return bs,level_rooms(s,p) or {}
end
local function describe_level(name,bs,rooms)
    local out={name,string.format("%d room(s), %d animation bank(s)",#rooms,#bs),""}
    for i,b in ipairs(bs) do
        out[#out+1]=string.format("Bank %d: %s - %d steps, %d images",i-1,b.name~="" and b.name or "unnamed",#b.steps,#b.images)
    end
    for _,r in ipairs(rooms) do
        out[#out+1]="";out[#out+1]=string.format("Room %d: %d objects, depth extent %d, background value %d",r.index,#r.objects,r.extent,r.background)
        for _,ob in ipairs(r.objects) do
            local kn=kind_names[ob.kind] or ("Kind "..ob.kind)
            local d={};for k=1,math.min(#ob.data,8) do d[k]=ob.data:byte(k) end
            out[#out+1]=string.format("  %-12s %-12s at (%d,%d) depth %d banks [%s] data %d bytes%s",ob.name,kn,ob.x,ob.y,ob.sort,
                table.concat(ob.banks,","),#ob.data,#d>0 and (" ["..table.concat(d," ").."...]") or "")
        end
    end
    return table.concat(out,"\n")
end
local function describe_banks(name,bs)
    local out={name,string.format("%d bank(s)",#bs)}
    for i,b in ipairs(bs) do
        out[#out+1]="";out[#out+1]=string.format("Bank %d: %s - %d steps, %d images",i,b.name~="" and b.name or "unnamed",#b.steps,#b.images)
        for k,st in ipairs(b.steps) do
            if k>200 then out[#out+1]="  ...";break end
            out[#out+1]=string.format("  step %3d: image %3d offset (%d,%d) move (%d,%d) %4d ms hit (%d,%d %dx%d)",
                k-1,st.img,st.ix,st.iy,st.x,st.y,st.dur,st.hx,st.hy,st.hw,st.hh)
        end
    end
    return table.concat(out,"\n")
end
local function room_composite(s,bs,room,name)
    local get,layers={},{}
    for i,b in ipairs(bs) do get[i]=image_cache(s,b) end
    local list={}
    for i,ob in ipairs(room.objects) do
        if ob.kind==0 or ob.kind==3 then
            local b=bs[(ob.banks[1] or -1)+1]
            local first,mode=0,1
            if ob.kind==3 then first,mode=ob.data:byte(1) or 0,ob.data:byte(2) or 0 end
            local st=b and b.steps[first+1]
            if st and st.img>=0 then
                local d=get[ob.banks[1]+1](st.img)
                if d then
                    local mx,my=0,0
                    if mode>=2 or ob.kind==0 then mx,my=st.x,st.y end
                    list[#list+1]={ob=ob,d=d,order=i,
                        x=ob.x+mx+st.ix+320,y=240-ob.y-st.iy-my,depth=ob.sort+5,
                        visible=mode~=0}
                end
            end
        end
    end
    -- A lower depth value is nearer the viewer: draw the deepest first.
    table.sort(list,function(a,b) if a.depth~=b.depth then return a.depth>b.depth end return a.order<b.order end)
    -- The canvas follows the biggest visible picture layer (the background; solid-colour fades are ignored) and is at least one 640x480 screen;
    -- drifting sprites that start off screen are clipped, but stay in the layer list.
    local x0,y0,x1,y1=0,0,640,480
    local main
    for _,l in ipairs(list) do
        if l.visible and l.d.kind~=3 and (not main or l.d.w*l.d.h>main.d.w*main.d.h) then main=l end
    end
    if main then
        x0=math.min(x0,main.x);y0=math.min(y0,main.y);x1=math.max(x1,main.x+main.d.w);y1=math.max(y1,main.y+main.d.h)
    end
    for _,l in ipairs(list) do
        layers[#layers+1]={name=string.format("%s (%s)",l.ob.name,kind_names[l.ob.kind] or "Object"),image=make_image(l.d),
            x=l.x-x0,y=l.y-y0,group=kind_names[l.ob.kind] or "Objects",visible=l.visible}
    end
    if #layers==0 then return nil end
    return {type="composite",width=x1-x0,height=y1-y0,layers=layers,
        description=string.format("%s room %d - %d of %d objects drawn; hidden sprites are off by default",name,room.index,#layers,#room.objects)}
end

function engine.detect(path)
    return resolve(path,"TESORO.TRE")~=nil and resolve(path,"TESORO.DAT")~=nil
end
function engine.get_resources(path)
    local c=catalog(path);c.entries={}
    local groups={};local order={"Scenes","Player animations","Fonts","Speech and sounds","Dialogue scripts","Scripts and data","Empty entries"}
    for _,n in ipairs(order) do groups[n]={} end
    for _,e in ipairs(c.list or {}) do
        local id="entry_"..e.index; c.entries[id]=e
        local ext=e.name:lower():match("%.(%w+)$"); local nodes=groups["Scripts and data"]
        local node={id=id,name=e.name,type="text"}
        if e.size==0 then nodes=groups["Empty entries"]
        elseif ext=="wav" then
            nodes=groups["Speech and sounds"];node.type="sound"
            local said=spoken(c,e.name); if said and said~="" then node.name=e.name.." - "..clip(said,48) end
        elseif ext=="dlg" then nodes=groups["Dialogue scripts"]
        elseif ext=="lvl" or ext=="anm" or ext=="an" then
            nodes=groups[ext=="lvl" and "Scenes" or (e.name:upper()=="FUENTES.ANM" and "Fonts" or "Player animations")]
            local s=payload(c,e)
            local bs,rooms
            if ext=="lvl" then bs,rooms=level_data(s or "") else bs=s and banks(s) end
            node.id="resource_"..e.index;node.type="category";node.children={{id=id,name="Resource information",type="text"}}
            for ri,r in ipairs(rooms or {}) do
                local rid=id.."_room_"..ri
                c.entries[rid]={source=e,room=ri}
                node.children[#node.children+1]={id=rid,name=string.format("Room %d composite (%d objects)",r.index,#r.objects),type="composite"}
            end
            for bi,b in ipairs(bs or {}) do
                local children={}
                for ii,im in ipairs(b.images) do
                    local iid=id.."_"..bi.."_"..ii
                    c.entries[iid]={source=e,bank=bi,image=ii}
                    children[#children+1]={id=iid,name=string.format("Image %d (%dx%d)%s",ii,im.width,im.height,im.kind==2 and " - shadow mask" or ""),type="image"}
                end
                if not b.font then
                    local rs=runs(b);local any=false
                    for ri,r in ipairs(rs) do
                        if r.last>r.first and run_layout(b,r) then
                            local aid=id.."_"..bi.."_run"..ri;any=true
                            c.entries[aid]={source=e,bank=bi,run=r}
                            children[#children+1]={id=aid,name=string.format("Animation steps %d-%d",r.first-1,r.last-1),type="animation"}
                        end
                    end
                    if not any and #b.images>1 then
                        local aid=id.."_"..bi.."_anim";c.entries[aid]={source=e,bank=bi,animation=true}
                        children[#children+1]={id=aid,name="Animation preview (100 ms per image)",type="animation"}
                    end
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
        local s=payload(c,e.source);if not s then return nil end
        if e.room then
            local bs,rooms=level_data(s);local room=rooms and rooms[e.room]
            return room and bs and room_composite(s,bs,room,e.source.name) or nil
        end
        local bs=banks(s);local b=bs and bs[e.bank]
        if not b then return nil end
        if e.run then
            local frames,delay,total,dropped=run_frames(s,b,e.run)
            if not frames then return nil end
            return {type="animation",animation=animation_create(frames,delay),image=frames[1],
                description=string.format("%s - steps %d-%d, %d ms (holds capped at 1 s, frame delay %d ms)%s",e.source.name,e.run.first-1,e.run.last-1,total,delay,
                    dropped>0 and string.format(", %d off-screen step(s) omitted",dropped) or "")}
        end
        if e.animation then
            local handles={}
            for _,im in ipairs(b.images) do
                local px,al=decode_image(s,im);if not px then return nil end
                handles[#handles+1]=image_create_rgb(im.width,im.height,px,al)
            end
            return {type="animation",animation=animation_create(handles,100),image=handles[1],description=e.source.name.." - image sequence, uniform preview timing"}
        end
        local im=b.images[e.image];local px,al
        if im then px,al=decode_image(s,im) end
        if not px then return nil end
        return {type="image",image=image_create_rgb(im.width,im.height,px,al),description=e.source.name.." - "..im.width.."x"..im.height}
    end
    if e.size==0 then return {type="text",text=e.name.."\nEmpty archive entry."} end
    local s=payload(c,e);if not s then return nil end
    local lower=e.name:lower()
    if lower:match("%.wav$") then
        local snd=wav(s)
        if not snd then return nil end
        local said=spoken(c,e.name)
        return {type="sound",sound=snd,description=said and said~="" and (e.name..' - "'..said..'"') or e.name}
    end
    if lower:match("%.lvl$") then
        local bs,rooms=level_data(s)
        if bs then return {type="text",text=describe_level(e.name,bs,rooms),description=e.name} end
    elseif lower:match("%.an[m]?$") then
        local bs=banks(s)
        if bs then return {type="text",text=describe_banks(e.name,bs),description=e.name} end
    end
    local text=string.format("%s\nDAT offset: %d\nPayload size: %d bytes\n",e.name,e.offset+4,e.size)
    if lower:match("%.txt$") then text=dos_text(s)
    elseif lower:match("%.dlg$") then text=annotate_script(c,s)
    else text=text.."\nReadable strings:\n"..strings(s) end
    return {type="text",text=text,description=e.name}
end
return engine

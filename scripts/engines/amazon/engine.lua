-- Amazon: Guardians of Eden. Format reference: ScummVM engines/access.
local engine={id="amazon",name="Amazon: Guardians of Eden",version="1.0",
    description="Amazon: Guardians of Eden (1992, Access Software)"}
local floor=math.floor
local function u16(s,p) return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function read(path)
    local f=assert(file_open(path),"Missing "..path);local n=file_size(f)
    local s=n>0 and file_read(f,0,n) or "";file_close(f)
    assert(s and #s==n,"Truncated "..path);return s
end
local function dbe(s)
    if s:sub(1,3)~="DBE" then return s end
    assert(#s>=16,"Truncated DBE header")
    local size=u32(s,5);assert(size<=8388608,"DBE output too large")
    local pos,bits,acc,width,nextCode=17,0,0,9,258
    local dict,old,out,total={},nil,{},0
    for i=0,255 do dict[i]=string.char(i) end
    local function code()
        while bits<width do
            assert(pos<=#s,"Truncated DBE stream")
            acc=acc+s:byte(pos)*2^bits;bits=bits+8;pos=pos+1
        end
        local n=acc%2^width;acc=floor(acc/2^width);bits=bits-width;return n
    end
    while true do
        local n=code();if n==257 then break end
        local value
        if n==256 then
            width=9;nextCode=258;n=code();assert(n<256,"Invalid DBE reset")
            value=dict[n];old=nil
        else
            assert(old and n<=nextCode,"Invalid DBE code")
            value=n==nextCode and old..old:sub(1,1) or dict[n]
            assert(value,"Missing DBE dictionary entry")
            assert(nextCode<8192,"DBE dictionary overflow")
            dict[nextCode]=old..value:sub(1,1);nextCode=nextCode+1
            if nextCode>=2^width and width<=12 then width=width+1 end
        end
        total=total+#value;assert(total<=size,"DBE output overrun")
        out[#out+1]=value;old=value
    end
    assert(total==size,"DBE output size mismatch")
    return table.concat(out)
end
local function offsets(s)
    if #s<6 then return end
    local n=u16(s,1);if n<1 or n>4096 or 2+n*4>#s then return end
    local off={}
    for i=1,n do
        local v=u32(s,3+(i-1)*4)
        if v>#s or (i==1 and v~=2+n*4) or (i>1 and v<off[i-1]) then return end
        off[i]=v
    end
    off[n+1]=#s;return off
end
local function dimensions(w,h) return w>0 and h>0 and w<=4096 and h<=1200 and w*h<=2097152 end
local function vga(s,p,n)
    if p+n-1>#s then return false end
    for i=p,p+n-1 do if s:byte(i)>63 then return false end end
    return true
end
local function sprite(s,a,b,emit)
    assert(a+3<=b,"Truncated sprite header")
    local w,h=u16(s,a),u16(s,a+2);assert(dimensions(w,h),"Invalid sprite dimensions")
    local pixels,p={},a+4
    if emit then for i=1,w*h do pixels[i]=0 end end
    for y=0,h-1 do
        assert(p+1<=b,"Truncated sprite row")
        local x,n=s:byte(p,p+1);p=p+2
        assert(x+n<=w and p+n-1<=b,"Invalid sprite row")
        if emit then for i=0,n-1 do pixels[y*w+x+i+1]=s:byte(p+i) end end
        p=p+n
    end
    -- Access pads bank frames to 16-byte boundaries with arbitrary bytes.
    assert(p<=b+1 and b+1-p<16,"Unexpected sprite trailing data")
    return pixels,w,h
end
local function sprites(s)
    local off=offsets(s);if not off then return end
    for i=1,#off-1 do if not pcall(sprite,s,off[i]+1,off[i+1],false) then return end end
    return off
end
local function playfield(s)
    if #s<784 then return end
    local w,h,n=s:byte(1,3)
    if w==0 or h==0 or n==0 or not dimensions(w*16,h*16) or s:byte(4)>w or s:byte(5)>h or not vga(s,17,768) then return end
    local matrix=785+n*256
    if matrix+w*h-1>#s then return end
    for p=matrix,matrix+w*h-1 do if s:byte(p)>=n then return end end
    return {w=w*16,h=h*16,tw=w,th=h,tiles=n,matrix=matrix}
end
local function screen(s)
    if not vga(s,1,768) then return end
    local raw=dbe(s:sub(769));local sizes={[64000]={320,200},[256000]={640,400},[307200]={640,480}}
    local dim=sizes[#raw];if dim then return {w=dim[1],h=dim[2],raw=raw} end
end
local function video_delta(s,a,b,pixels,total)
    local p,n=a,0
    while p<=b do
        local code=s:byte(p);p=p+1;local count=code%128
        assert(n+count<=total,"Video pixel overrun")
        if code<128 then
            assert(p+count-1<=b,"Truncated video literal")
            if pixels then for j=1,count do pixels[n+j]=s:byte(p+j-1) end end
            p=p+count
        end
        n=n+count
    end
end
local function video(s)
    if #s<10 then return end
    local n,w,h,flags=u16(s,1),u16(s,3),u16(s,5),u16(s,7)
    if n<3 or n>10000 or w<1 or w>640 or h<1 or h>480 or (flags~=0 and flags~=256) then return end
    local frames,p={},9
    for i=1,n-1 do
        if p+1>#s then return end
        local size=u16(s,p);p=p+2
        if p+size-1>#s then return end
        local raw=i==1 and flags==256
        if raw then if size~=w*h then return end
        elseif not pcall(video_delta,s,p,p+size-1,nil,w*h) then return end
        frames[i]={a=p,b=p+size-1,raw=raw};p=p+size
    end
    if p~=#s+1 then return end
    return {w=w,h=h,frames=frames}
end
local function classify(e)
    local s=e.data;e.kind="data"
    if s:sub(1,4)=="MThd" or s:sub(1,4)=="FORM" then e.kind="music";return end
    if s:sub(1,5)=="STEVE" then
        assert(#s>=32 and u16(s,8)+32<=#s and s:byte(6)>=1 and s:byte(6)<=4,"Invalid STEVE sound")
        e.kind="sound";return
    end
    local room=playfield(s)
    if room then e.kind="room";e.image=room;e.palpos=17;return end
    local pic=screen(s)
    if pic then e.kind="screen";e.image=pic;e.palpos=1;return end
    if #s==768 and vga(s,1,768) then e.kind="palette";e.palpos=1;return end
    local off=sprites(s)
    if off then e.kind="sprites";e.offsets=off;return end
    if pcall(sprite,s,1,#s,false) then e.kind="frame";return end
    local vid=video(s)
    if vid then e.kind="video";e.image=vid end
end
local cache
local function catalog(path)
    if cache and cache.path==path then return cache end
    local c={path=path,entries={},byid={},palettes={}}
    local names=list_files(path) or {};table.sort(names)
    for _,name in ipairs(names) do
        local upper=name:upper()
        if upper:match("%.AP$") or upper:match("%.LZ$") or upper:match("%.BLK$") or upper=="ETEXT.DAT" then
            local s=dbe(read(path.."/"..name));local off=upper:match("%.AP$") and offsets(s)
            assert(not upper:match("%.AP$") or off,"Invalid AP directory: "..name)
            local count=off and #off-1 or 1
            for i=1,count do
                local data=off and dbe(s:sub(off[i]+1,off[i+1])) or s
                local id="amazon/"..upper.."/"..(i-1)
                local e={id=id,file=upper,index=i-1,data=data}
                classify(e);c.entries[#c.entries+1]=e;c.byid[id]=e
                if e.palpos then c.palettes[#c.palettes+1]=e end
            end
        end
    end
    -- Sprites and videos inherit a runtime palette. Suggest the only picture in
    -- their archive; users can override this choice.
    for _,e in ipairs(c.entries) do
        if e.kind=="sprites" or e.kind=="frame" or e.kind=="video" then
            local candidates={}
            for _,p in ipairs(c.palettes) do if p.file==e.file then candidates[#candidates+1]=p end end
            if #candidates==1 then e.palette=candidates[1].id.."/palette" end
        end
    end
    cache=c;return c
end
function engine.detect(path)
    return file_exists(path.."/AMAZON.EXE") and file_exists(path.."/S00.AP") and file_exists(path.."/C00.AP")
end
local function node(id,name,kind) return {id=id,name=name,type=kind} end
function engine.get_resources(path)
    local c=catalog(path);local tree,groups={},{}
    for _,e in ipairs(c.entries) do
        local group=groups[e.file]
        if not group then group=node("amazon/"..e.file,e.file,"category");group.children={};groups[e.file]=group;tree[#tree+1]=group end
        local label=string.format("%d - %s",e.index,e.kind)
        if e.kind=="sprites" then
            local bank=node(e.id,label.." ("..(#e.offsets-1).." frames)","category");bank.children={}
            for i=1,#e.offsets-1 do bank.children[#bank.children+1]=node(e.id.."/frame/"..i,"Frame "..i,"image") end
            group.children[#group.children+1]=bank
        elseif e.kind=="video" then
            local vid=e.image;local bank=node(e.id,label.." ("..#vid.frames.." stored frames)","category");bank.children={}
            local batch=math.min(100,math.max(1,floor(8000000/(vid.w*vid.h))))
            for a=1,#vid.frames,batch do
                local b=math.min(a+batch-1,#vid.frames)
                bank.children[#bank.children+1]=node(e.id.."/video/"..a.."/"..b,"Stored frames "..a.."-"..b,"animation")
            end
            group.children[#group.children+1]=bank
        else
            local kind=({room="image",screen="image",frame="image",sound="sound",music="midi",palette="palette",data="text"})[e.kind]
            group.children[#group.children+1]=node(e.id,label,kind)
        end
    end
    local pals=node("amazon/palettes","Palettes","category");pals.children={}
    for _,e in ipairs(c.palettes) do pals.children[#pals.children+1]=node(e.id.."/palette",e.file.." #"..e.index,"palette") end
    tree[#tree+1]=pals;return tree
end
local function palette(c,id)
    local pal={};for i=0,255 do for j=1,3 do pal[i*3+j]=i end end
    if id then
        local e=assert(c.byid[id:gsub("/palette$","")],"Unknown palette");assert(e.palpos,"Resource has no palette")
        for i=1,768 do pal[i]=floor(e.data:byte(e.palpos+i-1)*255/63) end
    end
    return pal
end
function engine.default_palette(path,id)
    local e=catalog(path).byid[id:match("^(amazon/[^/]+/%d+)")]
    return e and (e.palpos and e.id.."/palette" or e.palette)
end
function engine.load_resource(path,id,palette_id)
    local c=catalog(path);local e=assert(c.byid[id:match("^(amazon/[^/]+/%d+)")],"Unknown Amazon resource")
    local s=e.data;local desc=e.file.." #"..e.index.." ("..#s.." decoded bytes)"
    if e.kind=="sound" then
        local rates={16666,8334,5525,4150};local n=u16(s,8)
        -- ScummVM passes flags=0: signed 8-bit mono samples.
        return {type="sound",sound=sound_create_pcm(rates[s:byte(6)],8,1,true,s:sub(33,32+n)),description=desc}
    elseif e.kind=="music" then return {type="midi",midi=midi_create_auto(s),description=desc} end
    local pal=palette(c,palette_id or engine.default_palette(path,id))
    if id:match("/palette$") or e.kind=="palette" then
        local p={};for y=0,127 do for x=0,127 do p[#p+1]=floor(y/8)*16+floor(x/8) end end
        return {type="image",image=image_create_indexed(128,128,p,pal),description=desc}
    elseif e.kind=="screen" then
        local pic=e.image;local pixels={};for i=1,#pic.raw do pixels[i]=pic.raw:byte(i) end
        return {type="image",image=image_create_indexed(pic.w,pic.h,pixels,pal),description=desc}
    elseif e.kind=="room" then
        local pic=e.image;local pixels={}
        for y=0,pic.h-1 do for x=0,pic.w-1 do
            local tile=s:byte(pic.matrix+floor(y/16)*pic.tw+floor(x/16))
            pixels[#pixels+1]=s:byte(785+tile*256+(y%16)*16+x%16)
        end end
        return {type="image",image=image_create_indexed(pic.w,pic.h,pixels,pal),description=desc}
    elseif e.kind=="sprites" or e.kind=="frame" then
        local a,b=1,#s
        if e.offsets then
            local i=assert(tonumber(id:match("/frame/(%d+)$")),"Select a frame")
            assert(i>=1 and i<#e.offsets,"Unknown frame");a=e.offsets[i]+1;b=e.offsets[i+1]
        end
        local pixels,w,h=sprite(s,a,b,true)
        return {type="image",image=image_create_indexed(w,h,pixels,pal),description=desc.."; runtime palette suggested where available; select a palette to override"}
    elseif e.kind=="video" then
        local a,b=id:match("/video/(%d+)/(%d+)$");a=assert(tonumber(a));b=assert(tonumber(b))
        local vid=e.image
        assert(a>=1 and b>=a and b<=#vid.frames and b-a<100 and (b-a+1)*vid.w*vid.h<=8000000,"Invalid video range")
        local pixels,handles={},{};for i=1,vid.w*vid.h do pixels[i]=0 end
        for i=1,b do
            local frame=vid.frames[i]
            if frame.raw then for j=1,vid.w*vid.h do pixels[j]=s:byte(frame.a+j-1) end
            else video_delta(s,frame.a,frame.b,pixels,vid.w*vid.h) end
            if i>=a then handles[#handles+1]=image_create_indexed(vid.w,vid.h,pixels,pal) end
        end
        return {type="animation",animation=animation_create(handles,100),image=handles[1],frames=handles,description=desc.."; all stored video packets at 100 ms; runtime palette suggested where available"}
    end
    local lines={desc,"Scripts, animation commands and driver data are not interpreted.","Hex/ASCII preview (first 8192 bytes):"}
    for p=1,math.min(#s,8192),16 do
        local hex,ascii={},{}
        for j=p,math.min(p+15,#s) do local v=s:byte(j);hex[#hex+1]=string.format("%02X",v);ascii[#ascii+1]=v>=32 and v<127 and string.char(v) or "." end
        lines[#lines+1]=string.format("%04X  %-47s  %s",p-1,table.concat(hex," "),table.concat(ascii))
    end
    return {type="text",text=table.concat(lines,"\n"),description=desc}
end
return engine

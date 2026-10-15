-- Capstone's Manley & Associates / Synergistic formats. These are unrelated to Genus GXL.
-- All offsets below are zero-based; binary string accessors translate to Lua.
local engine = {id="capstone", name="Capstone Adventures", version="1.0",
    description="Fievel Goes West, The Beverly Hillbillies, L.A. Law"}
local floor = math.floor
local function u16(d,p) return d:byte(p+1)+d:byte(p+2)*256 end
local function u32(d,p) return u16(d,p)+u16(d,p+2)*65536 end
local function be16(d,p) return d:byte(p+1)*256+d:byte(p+2) end
local function be32(d,p) return be16(d,p)*65536+be16(d,p+2) end
local function read(path)
    local f=file_open(path); if not f then return nil end
    local d=file_read(f,0,file_size(f)); file_close(f); return d
end
local function bytes(t)
    local s={}
    for p=1,#t,4096 do s[#s+1]=string.char(table.unpack(t,p,math.min(p+4095,#t))) end
    return table.concat(s)
end
local function valid_size(n) return n>0 and n<=8*1024*1024 end
local function packbits(d,limit)
    local out,p={},1
    while p<=#d and #out<limit do
        local c=d:byte(p); p=p+1
        if c<128 then
            if p+c>#d then return nil end
            for _=0,c do out[#out+1]=d:byte(p); p=p+1 end
        elseif c>128 then
            local v=d:byte(p); if not v then return nil end; p=p+1
            for _=1,257-c do out[#out+1]=v end
        end
        if #out>limit then return nil end
    end
    return bytes(out)
end
-- Beverly Hillbillies: byte flags, LSB first; 10-bit distance, 6-bit length.
local function bhb_lz(d,limit)
    local out,p={},1
    while p<=#d do
        local flags=d:byte(p); p=p+1
        for _=1,8 do
            if p>#d then break end
            if flags%2==1 then out[#out+1]=d:byte(p); p=p+1
            else
                local a,b=d:byte(p,p+1); if not b then return nil end; p=p+2
                local distance=b*4+floor(a/64); local count=a%64+3
                if distance==0 then return bytes(out) end
                if distance>#out or #out+count>limit then return nil end
                for _=1,count do out[#out+1]=out[#out-distance+1] end
            end
            flags=floor(flags/2)
            if #out>limit then return nil end
        end
    end
    return bytes(out)
end
-- LA Law: word flags, MSB first; 10-bit distance-minus-one, 6-bit length.
local function law_lz(d,limit)
    local out,p={},1
    while p+1<=#d do
        local flags=u16(d,p-1); p=p+2
        for bit=15,0,-1 do
            if floor(flags/2^bit)%2==1 then
                if p>#d or #out>=limit then return nil end
                out[#out+1]=d:byte(p); p=p+1
            else
                if p+1>#d then return nil end
                local v=u16(d,p-1); p=p+2
                if v==0 then return #out==limit and bytes(out) or nil end
                local distance=v%1024+1; local count=floor(v/1024)+3
                if distance>#out or #out+count>limit then return nil end
                for _=1,count do out[#out+1]=out[#out-distance+1] end
            end
        end
    end
    return nil
end
-- Fievel: LH1 (LZHUF), 314 adaptive symbols, 4 KiB space-filled window.
-- Tree reconstruction at frequency 0x8000 is required for the larger pictures.
local function lzh(d,limit)
    if not valid_size(limit) then return nil end
    local N,T,R=314,627,626
    local freq,son,parent={},{},{}
    for i=0,N-1 do freq[i]=1; son[i]=i+T; parent[i+T]=i end
    local i=0
    for j=N,R do freq[j]=freq[i]+freq[i+1]; son[j]=i; parent[i]=j; parent[i+1]=j; i=i+2 end
    freq[T]=65535; parent[R]=0
    local pos=0
    local function bits(n)
        local v=0
        for _=1,n do
            local b=d:byte(floor(pos/8)+1); if not b then error("Truncated LH1 stream") end
            v=v*2+floor(b/2^(7-pos%8))%2; pos=pos+1
        end
        return v
    end
    local out,window={},{}; local r=4036
    for j=0,4095 do window[j]=32 end
    local function emit(v) out[#out+1]=v; window[r]=v; r=(r+1)%4096 end
    while #out<limit do
        local c=son[R]
        while c<T do c=son[c+bits(1)] end
        c=c-T
        if freq[R]==32768 then
            local j=0
            for k=0,T-1 do
                if son[k]>=T then freq[j]=floor((freq[k]+1)/2); son[j]=son[k]; j=j+1 end
            end
            i=0
            for k=N,T-1 do
                local f=freq[i]+freq[i+1]; local a=k
                while a>0 and f<freq[a-1] do freq[a]=freq[a-1]; son[a]=son[a-1]; a=a-1 end
                freq[a]=f; son[a]=i; i=i+2
            end
            for k=0,T-1 do
                local a=son[k]; parent[a]=k; if a<T then parent[a+1]=k end
            end
        end
        local a=parent[c+T]
        repeat
            freq[a]=freq[a]+1; local f=freq[a]; local b=a+1
            if f>freq[b] then
                repeat b=b+1 until f<=freq[b]
                b=b-1; freq[a]=freq[b]; freq[b]=f
                local x=son[a]; parent[x]=b; if x<T then parent[x+1]=b end
                local y=son[b]; son[b]=x; parent[y]=a; if y<T then parent[y+1]=a end
                son[a]=y; a=b
            end
            a=parent[a]
        until a==0
        if c<256 then emit(c)
        else
            -- Canonical position prefix: 1/3/8/12/24/16 codes at lengths 3..8.
            local code=bits(3); local upper
            if code==0 then upper=0
            else
                code=code*2+bits(1)
                if code<5 then upper=code-1
                else
                    code=code*2+bits(1)
                    if code<18 then upper=code-6
                    else
                        code=code*2+bits(1)
                        if code<48 then upper=code-24
                        else
                            code=code*2+bits(1)
                            if code<120 then upper=code-72
                            else upper=code*2+bits(1)-192 end
                        end
                    end
                end
            end
            local distance=upper*64+bits(6); local off=(r-distance-1)%4096
            for k=0,c-254 do
                if #out==limit then break end
                emit(window[(off+k)%4096])
            end
        end
    end
    return bytes(out)
end
-- Read LZEXE 0.91 data without executing DOS code. Used for BHB's two palettes.
local function unpack_exe(d)
    if not d or #d<32 or d:sub(1,2)~="MZ" then return nil end
    local header=u16(d,8)*16
    if d:sub(29,32)~="LZ91" then return d:sub(header+1) end
    local special=header+u16(d,22)*16
    if special+10>#d then return nil end
    local p=special-u16(d,special+8)*16+1
    local flags,left=0,0
    local function refill() flags=u16(d,p-1); p=p+2; left=16 end
    local function bit()
        if left==0 then refill() end
        local b=flags%2; flags=floor(flags/2); left=left-1
        if left==0 then refill() end
        return b
    end
    local out={}
    while p<=special and #out<1024*1024 do
        if bit()==1 then out[#out+1]=d:byte(p); p=p+1
        else
            local distance,count
            if bit()==0 then
                count=bit()*2+bit()+2; distance=256-d:byte(p); p=p+1
            else
                local a,b=d:byte(p,p+1); if not b then return nil end; p=p+2
                distance=8192-(floor(b/8)*256+a); count=b%8+2
                if b%8==0 then
                    local v=d:byte(p); p=p+1
                    if v==0 then return bytes(out) end
                    if v==1 then count=0 else count=v+1 end
                end
            end
            if distance>#out then return nil end
            for _=1,count do out[#out+1]=out[#out-distance+1] end
        end
    end
    return nil
end
local function palette(d,p,n,scale)
    if p+n*3>#d then return nil end
    local pal={}
    for i=0,767 do pal[i+1]=i<n*3 and d:byte(p+i+1)*scale or 0 end
    return pal
end
local function image(w,h,pixels,pal,description)
    return {type="image",image=image_create_indexed(w,h,pixels,pal),width=w,height=h,description=description}
end
local function swatch(pal,description)
    local px={}
    for y=0,127 do for x=0,127 do px[#px+1]=floor(y/8)*16+floor(x/8) end end
    return image(128,128,px,pal,description)
end
local function planar(d,p,w,h,planes,row_interleaved)
    if w<1 or h<1 or w>2048 or h>2048 or planes<1 or planes>8 then return nil end
    local stride=floor((w+15)/16)*2
    if p+stride*h*planes>#d then return nil end
    local px={}
    for y=0,h-1 do
        for x=0,w-1 do
            local v=0
            for b=0,planes-1 do
                local off=row_interleaved and ((y*planes+b)*stride) or ((b*h+y)*stride)
                v=v+floor(d:byte(p+off+floor(x/8)+1)/2^(7-x%8))%2*2^b
            end
            px[#px+1]=v
        end
    end
    return px
end
local cp850={
    "Ç","ü","é","â","ä","à","å","ç","ê","ë","è","ï","î","ì","Ä","Å",
    "É","æ","Æ","ô","ö","ò","û","ù","ÿ","Ö","Ü","ø","£","Ø","×","ƒ",
    "á","í","ó","ú","ñ","Ñ","ª","º","¿","®","¬","½","¼","¡","«","»",
    "░","▒","▓","│","┤","Á","Â","À","©","╣","║","╗","╝","¢","¥","┐",
    "└","┴","┬","├","─","┼","ã","Ã","╚","╔","╩","╦","╠","═","╬","¤",
    "ð","Ð","Ê","Ë","È","ı","Í","Î","Ï","┘","┌","█","▄","¦","Ì","▀",
    "Ó","ß","Ô","Ò","õ","Õ","µ","þ","Þ","Ú","Û","Ù","ý","Ý","¯","´",
    "­","±","‗","¾","¶","§","÷","¸","°","¨","·","¹","³","²","■"," "
}
local function dos_text(d)
    return (d:gsub("[\128-\255]",function(c) return cp850[c:byte()-127] end):gsub("%z","\n"))
end
local function metadata(d,title)
    local lines={title,string.format("%d decoded bytes",#d),""}
    for p=1,math.min(#d,4096),16 do
        local hex,ascii={},{}
        for j=p,math.min(p+15,#d) do
            local b=d:byte(j); hex[#hex+1]=string.format("%02X",b); ascii[#ascii+1]=b>=32 and b<127 and string.char(b) or "."
        end
        lines[#lines+1]=string.format("%06X  %-47s  %s",p-1,table.concat(hex," "),table.concat(ascii))
    end
    return {type="text",text=table.concat(lines,"\n")}
end
local state={}
local function identify(path)
    if file_exists(path.."/AMTAIL.EXE") then
        local d=read(path.."/MANLEY.PIC")
        if d and (d:sub(1,4)=="LZPX" or d:sub(1,4)=="UNCP") then return "fievel" end
    elseif file_exists(path.."/HB.EXE") then
        local d=read(path.."/SCENES.RES")
        if d and #d>=16 and u32(d,0)==16 and u32(d,4)<#d then return "bhb" end
    elseif file_exists(path.."/LALAW.EXE") then
        local d=read(path.."/DISK1.RES")
        if d and d:sub(1,4)=="LZSS" then return "law" end
    end
end
function engine.detect(path) return identify(path)~=nil end
local function node(id,name,typ) return {id=id,name=name,type=typ} end
local function category(id,name) return {id=id,name=name,type="category",children={}} end
local function add(cat,entry) cat.children[#cat.children+1]=entry end
local function register(cat,id,name,typ,record)
    state.entries[id]=record; add(cat,node(id,name,typ))
end
local function fv_streams(d)
    if #d<8 or (d:sub(1,4)~="LZPX" and d:sub(1,4)~="UNCP") then return nil end
    local first=u32(d,4)
    if first<8 or first%4~=0 or first>#d-4 then return nil end
    local streams={first}
    for p=8,first-1,4 do
        local off=u32(d,p)
        if off<=streams[#streams] or off>#d-4 then return nil end
        streams[#streams+1]=off
    end
    return streams
end
local function fv_picture(e)
    local key=e.file..":"..e.offset
    if state.picture_key==key then return state.picture_raw end
    local d=read(state.path.."/"..e.file); if not d then return nil end
    local last=e.finish or #d; local n=u32(d,e.offset)
    if not valid_size(n) then return nil end
    local raw=d:sub(e.offset+5,last)
    if d:sub(1,4)=="LZPX" then raw=lzh(raw,n) else raw=raw:sub(1,n) end
    if not raw or #raw<1542 then return nil end
    state.picture_key=key; state.picture_raw=raw
    return raw
end
local function fv_actor(file)
    if state.actor_file==file then return state.actor_data end
    local d=read(state.path.."/"..file); if not d or #d<14 then return nil end
    local raw=lzh(d:sub(15),u32(d,10)); if not raw then return nil end
    state.actor_file=file; state.actor_data=raw
    return raw
end
local function actor_frames(d)
    local frames,p={},0
    while p+16<=#d do
        local w,h=u16(d,p),u16(d,p+2); w=math.max(w,u16(d,p+6)+1); local m,n=u16(d,p+12),u16(d,p+14)
        if w<1 or h<1 or w>640 or h>480 or p+16+m+n>#d then break end
        frames[#frames+1]={offset=p,width=w,height=h,mask=m,count=n}; p=p+16+m+n
    end
    return frames,p
end
local function bhb_entries(d)
    if #d<16 or u32(d,0)~=16 then return nil end
    local off=u32(d,4); if off+30>#d then return nil end
    local groups=u16(d,off+20); local p=off+30; local result={}
    if d:sub(p+1,p+4)=="PAMM" then
        -- MMAP nests image directories. Flatten the validated IMAG references.
        for q=p+8,#d-7,2 do
            if u16(d,q+2)==65535 then
                local packed=u32(d,q+4); local pos=16+packed%16777216
                if pos+4<=off then
                    local size=u32(d,pos)
                    if pos+4+size<=off then
                        result[#result+1]={kind="GAMI",id=u16(d,q),offset=pos,size=size,flags=floor(packed/16777216)}
                    end
                end
            end
        end
        return result
    end
    if groups>32 then return nil end
    for _=1,groups do
        if p+8>#d then return nil end
        local typ=d:sub(p+1,p+4); local count=u16(d,p+4)+1; local extra=u16(d,p+6); p=p+8
        -- MMAP is a grouping header containing another resource type header.
        if typ~="PAMM" then
            if extra~=10 or p+count*12-4>#d then return nil end
            for _=1,count do
                local id=u16(d,p); local packed=u32(d,p+4)
                local pos=16+packed%16777216; local flags=floor(packed/16777216)
                if pos+4>off then return nil end
                local size=u32(d,pos)
                if pos+4+size>off then return nil end
                result[#result+1]={kind=typ,id=id,offset=pos,size=size,flags=flags}
                p=p+12
            end
        end
    end
    return result
end
local function bhb_data(e)
    local f=file_open(state.path.."/"..e.file); if not f then return nil end
    local d=file_read(f,e.offset+4,e.size); file_close(f)
    if not d or #d~=e.size then return nil end
    if e.flags%2==1 or floor(e.flags/128)%2==1 then
        if #d<4 then return nil end
        local n=u32(d,0); if not valid_size(n) then return nil end
        if e.flags%2==1 then d=packbits(d:sub(5),n) else d=bhb_lz(d:sub(5),n) end
        if not d or #d~=n then return nil end
    end
    return d
end
local function bhb_palettes()
    if state.bhb_pal then return state.bhb_pal end
    local raw=unpack_exe(read(state.path.."/HB.EXE")); if not raw then return nil end
    -- Startup sets DS from its first MOV DX; the palettes are DS:A09 and DS:D09.
    if #raw<3 or raw:byte(1)~=186 then return nil end
    local base=u16(raw,1)*16
    local a=palette(raw,base+0xa09,256,4); local b=palette(raw,base+0xd09,256,4)
    if not a or not b then return nil end
    state.bhb_pal={a,b}; return state.bhb_pal
end
local function law_entries(d)
    local out,p={},0
    while p+14<=#d do
        local magic=d:sub(p+1,p+4); if magic~="LZSS" and magic~="NONE" then break end
        local packed,raw=u32(d,p+6),u32(d,p+10)
        if not valid_size(raw) or packed<1 or p+14+packed>#d then break end
        out[#out+1]={offset=p,size=packed,raw=raw,compressed=magic=="LZSS"}; p=p+14+packed
    end
    return out
end
local function law_data(e)
    local f=file_open(state.path.."/"..e.file); if not f then return nil end
    local d=file_read(f,e.offset+14,e.size); file_close(f)
    if e.compressed then return law_lz(d,e.raw) end
    return d
end
function engine.get_resources(path)
    state={path=path,game=identify(path),entries={}}
    local tree={}; local files=list_files(path) or {}; table.sort(files)
    local pals=category("palettes","Palettes")
    for _,name in ipairs(files) do
        local upper=name:upper(); local d
        if state.game=="fievel" and upper:sub(-4)==".PIC" then
            d=read(path.."/"..name); local streams=d and fv_streams(d)
            if streams then
                local cat=category("pic_"..name,name)
                for i,off in ipairs(streams) do
                    local e={file=name,offset=off,finish=streams[i+1] or #d,kind="pic"}
                    local id="pic_"..name.."_"..i
                    register(cat,id,"Picture "..i,"image",e)
                    if not state.default_fv_pal or (upper=="AT2.PIC" and i==1) then state.default_fv_pal="pal_"..id end
                    register(pals,"pal_"..id,name.." / "..i,"palette",{kind="fvpal",picture=id})
                    register(pals,"fade_"..id,name.." / "..i.." (fade)","palette",{kind="fvpal",picture=id,fade=true})
                end
                tree[#tree+1]=cat
            end
        elseif state.game=="fievel" and upper:sub(-4)==".ACT" then
            d=read(path.."/"..name)
            if d and #d>=14 and (d:sub(1,4)=="LZST" or d:sub(1,4)=="LZSP") then
                local count=u16(d,4)
                if count>0 and count<2048 then
                    local cat=category("actor_"..name,name)
                    register(cat,"anim_"..name,"All "..count.." frames","animation",{kind="actor",file=name})
                    for i=1,count do register(cat,"actor_"..name.."_"..i,"Frame "..i,"image",{kind="actor",file=name,frame=i}) end
                    tree[#tree+1]=cat
                end
            end
        elseif state.game=="fievel" and upper:sub(-4)==".CMP" then
            local cat=category("script_"..name,name)
            register(cat,"script_"..name.."_data","Decoded scene data","text",{kind="cmp",file=name})
            tree[#tree+1]=cat
        elseif state.game=="bhb" and upper:sub(-4)==".RES" then
            d=read(path.."/"..name); local entries=d and bhb_entries(d)
            if entries then
                local cat=category("res_"..name,name)
                for _,e in ipairs(entries) do
                    e.file=name
                    if name:upper()=="MAP.RES" and e.kind=="GAMI" then
                        local raw=bhb_data(e)
                        if not raw or #raw<6 or not planar(raw,6,be16(raw,2),be16(raw,0),be16(raw,4),true) then e.kind="PAMM" end
                    end
                    local typ=e.kind=="GAMI" and "image" or "text"
                    register(cat,"res_"..name.."_"..e.kind.."_"..e.id,
                        string.format("%s %d",e.kind:reverse(),e.id),typ,e)
                end
                tree[#tree+1]=cat
            end
        elseif state.game=="law" and upper:match("^DISK%d+%.RES$") then
            d=read(path.."/"..name); local entries=d and law_entries(d)
            if entries then
                local cat=category("disk_"..name,name)
                for i,e in ipairs(entries) do
                    e.file=name; e.kind="law"
                    register(cat,"disk_"..name.."_"..i,"Image "..i,"image",e)
                end
                tree[#tree+1]=cat
            end
        elseif state.game=="law" and upper:sub(-4)==".ABT" then
            local cat=category("speech_file_"..name,name)
            register(cat,"speech_"..name,"Speech data (driver encoding)","text",{kind="speech",file=name}); tree[#tree+1]=cat
        elseif state.game=="law" and upper:sub(-4)==".LBM" then
            local cat=category("lbm_file_"..name,name)
            register(cat,"lbm_"..name,name,"image",{kind="lbm",file=name}); tree[#tree+1]=cat
        end
    end
    if state.game=="bhb" then
        register(pals,"pal_bhb_game","Game palette","palette",{kind="bhbpal",index=2})
        register(pals,"pal_bhb_intro","Introduction palette","palette",{kind="bhbpal",index=1})
    end
    if #pals.children>0 then tree[#tree+1]=pals end
    local music,text=category("music","Music"),category("text","Text")
    for _,name in ipairs(files) do
        local upper=name:upper()
        if upper:sub(-4)==".XMI" then register(music,"music_"..name,name,"midi",{kind="music",file=name}) end
        if upper:sub(-4)==".TXT" then register(text,"text_"..name,name,"text",{kind="text",file=name}) end
    end
    if #music.children>0 then tree[#tree+1]=music end
    if #text.children>0 then tree[#tree+1]=text end
    return tree
end
local function fv_palette(id)
    state.fv_palettes=state.fv_palettes or {}
    if state.fv_palettes[id or ""] then return state.fv_palettes[id] end
    local e=state.entries[id or ""]
    if not e or e.kind~="fvpal" then return nil end
    local raw=fv_picture(state.entries[e.picture]); if not raw then return nil end
    local pal=palette(raw,e.fade and 772 or 4,256,4)
    state.fv_palettes[id]=pal; return pal
end
function engine.default_palette(path,id)
    local e=state.entries[id]; if not e then return nil end
    if state.game=="bhb" and e.kind=="GAMI" then return "pal_bhb_game" end
    if e.kind=="pic" then return "pal_"..id end
    if e.kind=="actor" then
        -- Actor files carry indices, with the active scene supplying the palette.
        return state.default_fv_pal
    end
end
local function load_lbm(d,name)
    if not d or #d<12 or d:sub(1,4)~="FORM" or d:sub(9,12)~="ILBM" then return nil end
    local p=12; local header,pal,body
    while p+8<=#d do
        local tag=d:sub(p+1,p+4); local n=be32(d,p+4)
        if p+8+n>#d then return nil end
        local chunk=d:sub(p+9,p+8+n)
        if tag=="BMHD" then header=chunk elseif tag=="CMAP" then pal=palette(chunk,0,floor(n/3),1) elseif tag=="BODY" then body=chunk end
        p=p+8+n+n%2
    end
    if not header or #header<20 or not body or not pal then return nil end
    local w,h=be16(header,0),be16(header,2); local planes=header:byte(9); local mask=header:byte(10)
    if mask==1 then planes=planes+1 end
    local size=floor((w+15)/16)*2*h*planes
    if header:byte(11)==1 then body=packbits(body,size) end
    if not body then return nil end
    local px=planar(body,0,w,h,planes,true); if not px then return nil end
    if mask==1 then for i,v in ipairs(px) do px[i]=v%2^(planes-1) end end
    return image(w,h,px,pal,name)
end
local function load(path,id,palette_id)
    if state.path~=path then engine.get_resources(path) end
    local e=state.entries[id]; if not e then return nil end
    if e.kind=="pic" then
        local d=fv_picture(e); if not d then return nil end
        local w,h=u16(d,0),u16(d,2)
        if w<1 or h<1 or w>2048 or h>2048 then return nil end
        local pal=fv_palette(palette_id) or palette(d,4,256,4)
        local px,p={},1543
        while #px<w*h and p<=#d do
            local c=d:byte(p); p=p+1
            if c>=128 then
                local v=d:byte(p); if not v then return nil end; p=p+1
                for _=1,math.min(257-c,w*h-#px) do px[#px+1]=v end
            else
                if p+c>#d then return nil end
                for _=0,c do if #px<w*h then px[#px+1]=d:byte(p) end; p=p+1 end
            end
        end
        if #px~=w*h then return nil end
        return image(w,h,px,pal,e.file)
    elseif e.kind=="fvpal" then
        local pal=fv_palette(id); return pal and swatch(pal,id) or nil
    elseif e.kind=="actor" then
        local d=fv_actor(e.file); if not d then return nil end
        local frames=actor_frames(d)
        local pal=fv_palette(palette_id or engine.default_palette(path,id)); if not pal then return nil end
        local handles={}
        local first=e.frame or 1; local last=e.frame or #frames
        for i=first,last do
            local f=frames[i]; if not f then return nil end
            local px={}; for j=1,f.width*f.height do px[j]=0 end
            local x,y=0,0; local src=f.offset+16+f.mask+1; local endsrc=src+f.count
            for p=f.offset+17,f.offset+16+f.mask do
                local c=d:byte(p)
                if c>=128 then y=y+1; x=0; c=c-128 end
                if c>=64 then
                    for _=1,c-64 do
                        if src>=endsrc or x>=f.width or y>=f.height then return nil end
                        px[y*f.width+x+1]=d:byte(src); src=src+1; x=x+1
                    end
                else x=x+c end
            end
            if src~=endsrc then return nil end
            handles[#handles+1]=image_create_indexed(f.width,f.height,px,pal)
        end
        if e.frame then return {type="image",image=handles[1],description=e.file.." / frame "..e.frame} end
        if #handles==0 then return nil end
        return {type="animation",animation=animation_create(handles,100),image=handles[1],frames=handles,
            description=e.file.." ("..#handles.." frames; preview sequence, scene palette selectable)"}
    elseif e.kind=="cmp" then
        local d=read(path.."/"..e.file); if not d or #d<4 then return nil end
        local raw=lzh(d:sub(5),u32(d,0)); return raw and metadata(raw,e.file.." - scene bytecode") or nil
    elseif e.kind=="bhbpal" then
        local pals=bhb_palettes(); return pals and swatch(pals[e.index],id) or nil
    elseif e.kind=="GAMI" then
        local d=bhb_data(e); local pals=bhb_palettes(); if not d or #d<6 or not pals then return nil end
        local h,w,planes=be16(d,0),be16(d,2),be16(d,4)
        local px=planar(d,6,w,h,planes,true); if not px then return nil end
        local p=state.entries[palette_id or "pal_bhb_game"]
        local pal=p and p.kind=="bhbpal" and pals[p.index] or pals[2]
        return image(w,h,px,pal,e.file.." / IMAG "..e.id)
    elseif e.kind=="law" then
        local d=law_data(e); if not d or #d<16 then return nil end
        local w,h,stride,colors=u16(d,6),u16(d,8),u16(d,10),u16(d,12)
        if w<1 or h<1 or w>2048 or h>2048 or stride<w or colors>256 or colors<1 then return nil end
        local pal=palette(d,14,colors,4); local off=14+colors*3
        if not pal or off+stride*h>#d then return nil end
        local px={}
        for y=0,h-1 do for x=0,w-1 do px[#px+1]=d:byte(off+y*stride+x+1) end end
        return image(w,h,px,pal,e.file..string.format(" @ 0x%X",e.offset))
    elseif e.kind=="speech" then
        local d=read(path.."/"..e.file); return d and metadata(d,e.file.." - driver-encoded speech; playback not implemented") or nil
    elseif e.kind=="lbm" then return load_lbm(read(path.."/"..e.file),e.file)
    elseif e.kind=="music" then
        local d=read(path.."/"..e.file); if not d then return nil end
        local handle=midi_create_from_xmi(d)
        return handle and {type="midi",midi=handle,description=e.file} or nil
    elseif e.kind=="text" then
        local d=read(path.."/"..e.file); return d and {type="text",text=dos_text(d)} or nil
    else
        local d=bhb_data(e); if not d then return nil end
        if e.kind=="RTSC" then return {type="text",text=dos_text(d:gsub("%z+$",""))} end
        return metadata(d,e.file.." / "..e.kind:reverse().." "..e.id)
    end
end
function engine.load_resource(path,id,palette_id)
    local ok,result=pcall(load,path,id,palette_id)
    if not ok then log_warn("Capstone: "..tostring(result)); return nil end
    return result
end
return engine

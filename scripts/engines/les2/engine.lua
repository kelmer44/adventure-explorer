-- Les Manley in: Lost in L.A. (Accolade, DOS).
-- EXE contains 14-byte resource directory records (hash, letter, pad, offset,
-- size). 'ILBM' is a proprietary 19-byte BMHD + BODY wrapper, not Amiga ILBM:
-- pixels are chunky GIF-style LZW, with consecutive frames of width*height.
local engine={id="les2",name="Les Manley 2: Lost in L.A.",version="1.0",
    description="Les Manley 2 scenes, sprites, animation previews, palettes and text"}
local floor=math.floor
local function u16(s,p) return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function be16(s,p) return s:byte(p)*256+s:byte(p+1) end
local function be32(s,p) return be16(s,p)*65536+be16(s,p+2) end
local function read(path,off,size)
    local f=file_open(path);if not f then return nil end
    local n=file_size(f)
    if off<0 or size<0 or off+size>n then file_close(f);return nil end
    local s=file_read(f,off,size);file_close(f);return s and #s==size and s or nil
end
-- Position-weighted filename hash, coefficients recovered from EXE.EXE.
local weights={31676129,199371,5134167,410371,5713,3751,431,9437,39123,1711,41,971,318491,1773,811,1209251,17,4991,7882993,31819023}
local function hash(name)
    if #name>#weights then return nil end
    local v=0;for i=1,#name do v=(v+name:byte(i)*weights[i])%4294967296 end
    return v
end
local function lzw(src,limit)
    limit=limit or 8388608
    local pos,bits,nxt,old,out,len=0,9,258,nil,{},0
    local dict={};for i=0,255 do dict[i]=string.char(i) end
    while pos+bits<=#src*8 do
        local p=floor(pos/8)+1
        local v=floor(((src:byte(p) or 0)+(src:byte(p+1) or 0)*256+(src:byte(p+2) or 0)*65536)/2^(pos%8))%2^bits
        pos=pos+bits
        if v==256 then
            dict={};for i=0,255 do dict[i]=string.char(i) end
            bits=9;nxt=258;old=nil
        elseif v==257 then return table.concat(out)
        else
            local s=dict[v]
            if not s then
                if v~=nxt or not old then return nil end
                s=old..old:sub(1,1)
            end
            len=len+#s;if len>limit then return nil end
            out[#out+1]=s
            if old and nxt<4096 then
                dict[nxt]=old..s:sub(1,1);nxt=nxt+1
                if nxt==2^bits and bits<12 then bits=bits+1 end
            end
            old=s
        end
    end
    return nil
end
local function picture(s)
    if #s<47 or s:sub(1,4)~="FORM" or s:sub(9,16)~="ILBMBMHD"
        or be32(s,17)~=20 or s:sub(40,43)~="BODY" then return nil end
    local w,h=be16(s,21),be16(s,23);local size=be32(s,44)
    if w<1 or h<1 or w>2048 or h>2048 or w*h>4194304 or size+47>#s then return nil end
    local raw=lzw(s:sub(48,47+size))
    if not raw or #raw==0 or #raw%(w*h)~=0 then return nil end
    return {width=w,height=h,raw=raw,count=#raw/(w*h)}
end
local function directory(exe,files)
    local best,start,count={},nil,0
    for p=1,#exe-13 do
        local letter=exe:sub(p+4,p+4);local f=files[letter]
        if f and exe:byte(p+5)==0 then
            local off,size=u32(exe,p+6),u32(exe,p+10)
            if size>0 and off+size<=f.size then
                local prev=best[p-14]
                best[p]=(prev or 0)+1
                if best[p]>count then count=best[p];start=p-(count-1)*14 end
            end
        end
    end
    if count<20 then return nil end
    local out={}
    for i=0,count-1 do
        local p=start+i*14;local letter=exe:sub(p+4,p+4)
        out[#out+1]={hash=u32(exe,p),letter=letter,offset=u32(exe,p+6),size=u32(exe,p+10),file=files[letter].path}
    end
    return out
end
local cache={}
local function catalog(path)
    if cache.path==path then return cache end
    cache={path=path,entries={},files={},byhash={},palettes={}}
    local exe
    for _,n in ipairs(list_files(path) or {}) do
        local letter=n:upper():match("^DATA([A-Z])%.DAT$")
        if letter then
            local f=file_open(path.."/"..n)
            if f then cache.files[letter:lower()]={path=path.."/"..n,size=file_size(f)};file_close(f) end
        elseif n:upper()=="EXE.EXE" then exe=path.."/"..n end
    end
    if not exe then return cache end
    local f=file_open(exe);if not f then return cache end
    local s=file_read(f,0,file_size(f));file_close(f)
    cache.list=directory(s,cache.files) or {}
    for _,e in ipairs(cache.list) do
        cache.byhash[e.hash]=e
        e.id=string.format("res_%s_%d",e.letter,e.offset);cache.entries[e.id]=e
        if e.size==768 and (e.letter=="a" or e.letter=="z") then
            cache.palettes[#cache.palettes+1]=e
        end
    end
    return cache
end
local function data(e) return read(e.file,e.offset,e.size) end
local function palette(c,id)
    local e=id and c.entries[id] or c.byhash[hash("256.pal")] or c.palettes[1]
    local s=e and e.size==768 and data(e)
    if not s then return nil end
    local pal={};for i=1,768 do pal[i]=s:byte(i) end;return pal
end
-- DOS text is CP850. Convert explicitly before passing it to LuaJ's UTF-8 UI.
local cp850={"Ç","ü","é","â","ä","à","å","ç","ê","ë","è","ï","î","ì","Ä","Å","É","æ","Æ","ô","ö","ò","û","ù","ÿ","Ö","Ü","ø","£","Ø","×","ƒ","á","í","ó","ú","ñ","Ñ","ª","º","¿","®","¬","½","¼","¡","«","»","░","▒","▓","│","┤","Á","Â","À","©","╣","║","╗","╝","¢","¥","┐","└","┴","┬","├","─","┼","ã","Ã","╚","╔","╩","╦","╠","═","╬","¤","ð","Ð","Ê","Ë","È","ı","Í","Î","Ï","┘","┌","█","▄","¦","Ì","▀","Ó","ß","Ô","Ò","õ","Õ","µ","þ","Þ","Ú","Û","Ù","ý","Ý","¯","´","­","±","‗","¾","¶","§","÷","¸","°","¨","·","¹","³","²","■"," "}
local function text(s)
    return (s:gsub("[\128-\255]",function(c) return cp850[c:byte()-127] end))
end
local function strings(s)
    local out={}
    for v in s:gmatch("[%w%p \128-\255][%w%p \128-\255][%w%p \128-\255][%w%p \128-\255]+") do out[#out+1]=text(v) end
    return table.concat(out,"\n")
end
function engine.detect(path)
    local files={};for _,n in ipairs(list_files(path) or {}) do files[n:upper()]=true end
    return files["DATAA.DAT"] and files["DATAB.DAT"] and files["EXE.EXE"] and files["OOPS.OOP"] or false
end
function engine.get_resources(path)
    local c=catalog(path);local scenes={};local names={}
    -- Scene sources retain original image names. On disk their extensions are
    -- .lsc and .pic; palette names use .pal. The hash is case sensitive.
    for _,e in ipairs(c.list or {}) do
        if e.letter~="a" and e.letter~="z" and e.size<12000 then
            local s=data(e);local raw=s and lzw(s,1048576)
            if raw and raw:sub(1,4)==".SCN" then
                local name=raw:match("^%.SCN[^%z]*%z([^%z]+)")
                if name then
                    e.name=name..".lsc";e.decoded=raw
                    local pe=c.byhash[hash(name..".pal")]
                    if not pe then pe=c.byhash[hash((name:gsub("[b-z]$","a"))..".pal")] end
                    if pe and pe.size~=768 then pe=nil end
                    scenes[#scenes+1]={offset=e.offset,letter=e.letter,name=name,palette=pe and pe.id}
                    for image in raw:gmatch("([%w_]+)%.lbm") do names[hash(image..".pic")]=image..".pic" end
                    if pe then pe.name=name..".pal" end
                end
            end
        end
    end
    local images,anims,metadata,pals={},{},{},{}
    local current
    for _,e in ipairs(c.list or {}) do
        e.name=names[e.hash] or e.name or string.format("%08X @ DATA%s:%d",e.hash,e.letter:upper(),e.offset)
        local s=data(e)
        if s and #s>=47 and s:sub(1,4)=="FORM" and s:sub(9,12)=="ILBM" then
            local w,h=be16(s,21),be16(s,23)
            -- A background immediately precedes its scene descriptor. Subsequent
            -- sprites inherit that scene's palette until the next background.
            if w==320 and h==200 then
                current=nil
                for _,sc in ipairs(scenes) do if sc.letter==e.letter and sc.offset==e.offset+e.size then current=sc;break end end
            end
            e.palette=current and current.palette
            local pic=picture(s)
            e.pic=pic and {width=pic.width,height=pic.height,count=pic.count}
            if pic then
                local node={id=e.id,name=string.format("%s (%dx%d%s)",e.name,w,h,pic.count>1 and ", "..pic.count.." frames" or ""),type=pic.count>1 and "animation" or "image"}
                local target=pic.count>1 and anims or images;target[#target+1]=node
            else
                e.error="Image LZW stream could not be decoded."
                metadata[#metadata+1]={id=e.id,name=e.name.." (undecoded image)",type="text"}
            end
        elseif e.size==768 and (e.letter=="a" or e.letter=="z") then
            pals[#pals+1]={id=e.id,name=e.name,type="palette"}
        else metadata[#metadata+1]={id=e.id,name=e.name,type="text"} end
    end
    local tree={}
    for i,g in ipairs({{"Images",images},{"Animations",anims},{"Palettes",pals},{"Scripts and data",metadata}}) do
        if #g[2]>0 then tree[#tree+1]={id="group_"..i,name=g[1].." ("..#g[2]..")",type="category",children=g[2]} end
    end
    c.ready=true;return tree
end
function engine.default_palette(path,id)
    local c=catalog(path);if not c.ready then engine.get_resources(path) end
    local e=c.entries[id];return e and e.palette
end
function engine.load_resource(path,id,palette_id)
    local c=catalog(path);if not c.ready then engine.get_resources(path) end
    local e=c.entries[id];if not e then return nil end
    local s=data(e);if not s then return nil end
    if e.pic then
        local pic=picture(s);local pal=palette(c,palette_id or e.palette)
        if not pic or not pal then return nil end
        local handles={};local n=pic.width*pic.height
        for f=0,pic.count-1 do
            local pixels={};for i=1,n do pixels[i]=pic.raw:byte(f*n+i) end
            handles[#handles+1]=image_create_indexed(pic.width,pic.height,pixels,pal)
        end
        local desc=e.name..(not e.palette and not palette_id and " - palette unassigned; select a palette" or "")
        if #handles==1 then return {type="image",image=handles[1],description=desc} end
        return {type="animation",animation=animation_create(handles,100),image=handles[1],description=desc.." - uniform 100 ms preview timing"}
    elseif e.size==768 and (e.letter=="a" or e.letter=="z") then
        local pal=palette(c,id);local pixels={}
        for y=0,127 do for x=0,127 do pixels[#pixels+1]=floor(y/8)*16+floor(x/8) end end
        return {type="image",image=image_create_indexed(128,128,pixels,pal),description=e.name}
    end
    local raw=e.decoded or lzw(s,1048576) or s
    local output=string.format("%s\nDATA%s.DAT offset %d, %d bytes\n%s\n",e.name,e.letter:upper(),e.offset,e.size,e.error or "")
    if e.letter=="a" and e.offset==576 then output=output..text(raw)
    else output=output.."\nReadable text / metadata:\n"..strings(raw):gsub("|","\n") end
    return {type="text",text=output,description=e.name}
end
return engine

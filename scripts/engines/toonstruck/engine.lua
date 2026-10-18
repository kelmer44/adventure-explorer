-- Toonstruck: PAK pictures/CAF sprites, RNC masks, palettes, TRE dialogue,
-- indexed SVL speech / SEL effects, and standalone MUS music.
local engine = {name='Toonstruck', id='toonstruck', version='3.0',
    description='Toonstruck (1996, Burst Studios / Virgin Interactive)'}
local rnc_unpack = require('toon_rnc')
local function u16le(d,p) return d:byte(p) + d:byte(p+1)*256 end
local function u32le(d,p) return u16le(d,p) + u16le(d,p+2)*65536 end
local function u32be(d,p) return d:byte(p)*16777216+d:byte(p+1)*65536+d:byte(p+2)*256+d:byte(p+3) end
local function read(path,offset,size)
    local f=file_open(path); if not f then return nil end
    local d=file_read(f,offset or 0,size or file_size(f)); file_close(f); return d
end
local function root(path)
    if file_exists(path..'/LOCAL.PAK') then return path end
    return path..'/MISC'
end
local function scan(path,prefix,out)
    for _,name in ipairs(list_files(path)) do
        local rel=prefix..name
        if name:upper():match('%.PAK$') or name:upper():match('%.MUS$') or name:upper():match('%.CAF$') then
            out[#out+1]=rel
        elseif #list_files(path..'/'..name)>0 then scan(path..'/'..name,rel..'/',out) end
    end
end
local function parse_pak_directory(f)
    local total=file_size(f)
    local first=file_read(f,0,4)
    if not first or #first<4 then return {} end
    local dirsize=u32le(first,1)
    if dirsize<5 or dirsize>total or dirsize>4000000 then return {} end
    local d=file_read(f,0,dirsize); local p=1; local entries={}
    while p+4<=#d do
        local off=u32le(d,p); local last=d:find('\0',p+4,true)
        if not last then return {} end
        local name=d:sub(p+4,last-1)
        if name=='' then break end
        if off<dirsize or off>total then return {} end
        entries[#entries+1]={name=name,offset=off}; p=last+1
    end
    for i,e in ipairs(entries) do
        local ending=entries[i+1] and entries[i+1].offset or total
        if ending<e.offset then return {} end
        e.size=ending-e.offset
    end
    return entries
end

-- LZSS flags are LSB first. A final oversized token escapes to raw bytes.
local function decompress_lzss(d,size)
    if size<1 or size>32000000 then return nil end
    local out,n,p={},0,1
    while n<size do
        if p>#d then return nil end
        local flags=d:byte(p)+256; p=p+1
        while flags~=1 and n<size do
            local count,dist
            if flags%2==1 then
                if p+1>#d then return nil end
                local word=u16le(d,p); p=p+2
                count=math.floor(word/4096)+3; dist=4096-word%4096
            else
                count=1
                while math.floor(flags/2)%2==0 do count=count+1; flags=math.floor(flags/2) end
            end
            if count>size-n then count=size-n; dist=nil end
            if dist then
                if dist>n then return nil end
                for _=1,count do n=n+1; out[n]=out[n-dist] end
            else
                if p+count-1>#d then return nil end
                for _=1,count do n=n+1; out[n]=d:byte(p); p=p+1 end
            end
            flags=math.floor(flags/2)
        end
    end
    return out,n
end
local function decompress_spcn(d,size)
    if size<1 or size>1024000 or #d==0 then return nil end
    local out,n,p={},0,1
    if d:byte(1)<128 then p=2 end -- optional stream marker, not a token
    while n<size do
        if p>#d then return nil end
        local v=d:byte(p); p=p+1
        local count,dist,fill
        if v<128 then
            if p>#d then return nil end
            count=math.floor(v/16)+3; dist=v%16*256+d:byte(p); p=p+1
        elseif v<192 then count=v%64
        elseif v==254 then
            if p+2>#d then return nil end
            count=u16le(d,p); fill=d:byte(p+2); p=p+3
        else
            if v==255 then
                if p+1>#d then return nil end
                count=u16le(d,p); p=p+2
            else count=v%64+3 end
            if p+1>#d then return nil end
            dist=u16le(d,p); p=p+2
        end
        -- Some shipped MSC masks end with a run up to 100 bytes past the screen.
        if count>size-n+100 or (dist and (dist<1 or dist>n)) then return nil end
        count=math.min(count,size-n)
        if not dist and not fill and p+count-1>#d then return nil end
        for _=1,count do
            n=n+1
            if dist then out[n]=out[n-dist]
            elseif fill then out[n]=fill
            else out[n]=d:byte(p); p=p+1 end
        end
    end
    return out,n
end
local function gray()
    local pal={}; for i=0,255 do pal[i*3+1]=i; pal[i*3+2]=i; pal[i*3+3]=i end; return pal
end
local function palette_swatch(pal)
    local pixels={}
    for y=0,255 do for x=0,255 do pixels[y*256+x+1]=math.floor(y/16)*16+math.floor(x/16) end end
    return image_create_indexed(256,256,pixels,pal)
end
local function put_palette(pal,data,start,count,from)
    for i=0,count*3-1 do
        local v=type(data)=='string' and data:byte((from or 1)+i) or data[(from or 1)+i]
        pal[start*3+i+1]=math.min(255,v*4)
    end
end
local function picture(raw)
    if #raw<8 then return nil end
    local magic=raw:sub(1,4); local pixels,size,pal,count
    if magic=='LZSS' then
        size=u32le(raw,5); pixels=decompress_lzss(raw:sub(9),size)
        if not pixels then return nil end
        local bytes=size%2048; count=math.floor(bytes/3)
        if count>256 then return nil end
        size=size-bytes; pal=gray()
        if count>0 then put_palette(pal,pixels,count==256 and 0 or 1,count,size+1) end
    elseif magic=='SPCN' then
        if #raw<16 then return nil end
        size=u32le(raw,11); local bytes=u16le(raw,15); count=math.floor(bytes/3)
        if bytes%3~=0 or count>256 or #raw<16+bytes then return nil end
        pal=gray(); put_palette(pal,raw,count==256 and 0 or 1,count,17)
        pixels=decompress_spcn(raw:sub(17+bytes),size)
    elseif magic=='RNC\1' or magic=='RNC\2' then
        pixels,size=rnc_unpack(raw); pal=gray(); count=0
    end
    if not pixels then return nil end
    -- RIC files are hotspot tables, not screen images.
    if size~=256000 and size~=512000 then return nil end
    return {pixels=pixels,width=size/400,height=400,palette=pal,colors=count}
end

local cached_path,tree,entries,palettes
local function index(path)
    path=root(path)
    if cached_path==path then return tree end
    tree={}; entries={}; palettes={}
    local files={}; scan(path,'',files); table.sort(files)
    for _,rel in ipairs(files) do
        if not rel:upper():match('%.PAK$') then
            local kind=rel:upper():match('%.CAF$') and 'animation' or 'sound'
            local id='file:'..rel; entries[id]={file=rel,kind=kind,name=rel}
            tree[#tree+1]={id=id,name=rel,type=kind}
        else
            local f=file_open(path..'/'..rel)
            local directory=f and parse_pak_directory(f) or {}; if f then file_close(f) end
            local groups,order={},{}
            local function add(group,id,name,kind,e)
                if not groups[group] then groups[group]={}; order[#order+1]=group end
                e.kind=kind; e.name=name; entries[id]=e
                groups[group][#groups[group]+1]={id=id,name=name,type=kind}
            end
            for _,e in ipairs(directory) do
                local ext=e.name:upper():match('%.([^%.]+)$'); local id='pak:'..rel..':'..e.name
                e.file=rel
                local kind,group='data','Data'
                if ext=='CPS' then kind='image'; group='Backgrounds and screens'
                elseif ext=='CAF' then kind='animation'; group='Sprites and animations'
                elseif ext=='MSC' then kind='image'; group='Masks'
                elseif ext=='PAL' or ext=='NPP' or ext=='NP2' or ext=='CUP' then kind='palette'; group='Palettes'
                elseif ext=='TRE' then kind='text'; group='Dialogue text'
                elseif ext=='SEL' then kind='sound'; group='Sound effects' end
                if ext~='SEL' then add(group,id,e.name,kind,e) end
                if ext=='CPS' then
                    local pid='palette:'..rel..':'..e.name
                    local pe={file=rel,offset=e.offset,size=e.size,picture=true,source_name=e.name}
                    add('Palettes',pid,e.name..' palette','palette',pe)
                    palettes[rel]=palettes[rel] or pid
                end
                if ext=='CPS' then
                    local cup=e.name:gsub('%.[^.]+$','.CUP')
                    for _,other in ipairs(directory) do
                        if other.name:upper()==cup:upper() then
                            for _,view in ipairs({'normal','closeup'}) do
                                add('Backgrounds and screens','view:'..rel..':'..e.name..':'..view,
                                    e.name..' ('..view..')','image',
                                    {file=rel,offset=e.offset,size=e.size,view=view,source_name=e.name})
                            end
                        end
                    end
                end
                -- SVI/SEI are arrays of offsets into SVL/SEL streams, with a final sentinel.
                if ext=='SVI' or ext=='SEI' then
                    local offsets=read(path..'/'..rel,e.offset,e.size)
                    local streamname=e.name:sub(1,-2)..'L'; local stream
                    if ext=='SVI' then stream={file=(rel:match('^(.*[/])') or '')..streamname}
                    else
                        for _,other in ipairs(directory) do
                            if other.name:upper()==streamname:upper() then stream={file=rel,offset=other.offset,size=other.size} end
                        end
                    end
                    if stream and file_exists(path..'/'..stream.file) then
                        local f2=file_open(path..'/'..stream.file); local limit=stream.size or file_size(f2); file_close(f2)
                        for j=1,#offsets-7,4 do
                            local a,b=u32le(offsets,j),u32le(offsets,j+4)
                            if b>a and b<=limit then
                                add(ext=='SVI' and 'Speech' or 'Sound effects','audio:'..rel..':'..e.name..':'..((j-1)/4),
                                    streamname..' # '..((j-1)/4),'sound',
                                    {file=stream.file,offset=(stream.offset or 0)+a,size=b-a})
                            end
                        end
                    end
                end
            end
            local children={}
            for _,group in ipairs(order) do children[#children+1]={id=rel..':'..group,name=group..' ('..#groups[group]..')',type='category',children=groups[group]} end
            if #children>0 then tree[#tree+1]={id='pak_'..rel,name=rel,type='category',children=children} end
        end
    end
    cached_path=path; return tree
end
function engine.detect(path)
    path=root(path)
    return file_exists(path..'/LOCAL.PAK') and (file_exists(path..'/DREW.PAK') or file_exists(path..'/ONETIME.PAK'))
end
function engine.get_resources(path) return index(path) end
function engine.default_palette(path,id)
    index(path); local e=entries[id]
    if e and e.name:upper():match('%.CAF$') then
        local header=read(root(path)..'/'..e.file,e.offset,68)
        if header and #header>=68 and u32le(header,65)==0 then return palettes[e.file] end
    end
end
local function entry_data(path,e) return read(root(path)..'/'..e.file,e.offset,e.size) end
local function complete_palette(path,e,pic)
    local pal=pic.palette
    if pic.colors>0 and pic.colors<256 then
        for _,name in ipairs({'FLUX.PAL','UNIVERSE.PAL'}) do
            local shared=entries['pak:ONETIME.PAK:'..name]
            if shared then
                local data=entry_data(path,shared)
                if data then put_palette(pal,data,name=='FLUX.PAL' and 192 or 200,#data/3) end
            end
        end
        local npp=entries['pak:'..e.file..':'..(e.source_name or e.name):gsub('%.[^.]+$','.NPP')]
        if npp then local data=entry_data(path,npp); if data then put_palette(pal,data,232,#data/3) end end
    end
    return pal
end
local function resource_palette(path,id)
    local e=entries[id]; if not e then return nil end
    local d=entry_data(path,e); if not d then return nil end
    if e.picture then
        local pic=picture(d); if not pic then return nil end
        local info=pic.colors==256 and '256 embedded colors (6-bit VGA)'
            or pic.colors==0 and 'No embedded palette; grayscale fallback'
            or string.format('%d embedded colors at indices 1–%d (6-bit VGA); shared room colors included',pic.colors,pic.colors)
        return complete_palette(path,e,pic),info
    end
    local pal=gray(); local start=0; local name=e.name:upper()
    if name:match('%.NP[2P]$') then start=232
    elseif name=='FLUX.PAL' then start=192
    elseif name=='UNIVERSE.PAL' then start=200
    elseif name:match('%.CUP$') then start=1 end
    if #d%3~=0 or #d/3+start>256 then return nil end
    put_palette(pal,d,start,#d/3)
    return pal,string.format('%d stored colors at indices %d–%d (6-bit VGA)',#d/3,start,start+#d/3-1)
end
local steps={7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767}
local adjust={-1,-1,-1,-1,2,4,6,8}
local function audio(raw,name)
    if #raw<16 or raw:sub(1,2)~='\34\86' then return nil end
    local p,sample,stepindex=9,0,0; local pcm={}; local total=0
    while p+7<=#raw do
        local packed,unpacked=u16le(raw,p),u16le(raw,p+2); p=p+8
        if packed==0 or unpacked>packed*4+2 or unpacked%2~=0 or p+packed-1>#raw then return nil end
        -- Final packets can declare one extra sample without a corresponding
        -- nibble. Emit only samples present in the compressed payload.
        local chunk={}; local n=0
        for i=0,packed*2-1 do
            local b=raw:byte(p+math.floor(i/2)); local code=i%2==0 and b%16 or math.floor(b/16)
            local value=code%8; local step=steps[stepindex+1]; local delta=math.floor(step/8)
            if value>=4 then delta=delta+step end
            if math.floor(value/2)%2==1 then delta=delta+math.floor(step/2) end
            if value%2==1 then delta=delta+math.floor(step/4) end
            sample=math.max(-32768,math.min(32767,sample+(code>=8 and -delta or delta)))
            stepindex=math.max(0,math.min(88,stepindex+adjust[value+1]))
            if i*2<unpacked then
                local word=sample%65536; n=n+1; chunk[n]=string.char(word%256,math.floor(word/256))
            end
        end
        pcm[#pcm+1]=table.concat(chunk); p=p+packed; total=total+unpacked
        if total>64000000 then return nil end
    end
    if #pcm==0 or p~=#raw+1 then return nil end
    return {type='sound',sound=sound_create_pcm(22100,16,1,true,table.concat(pcm)),description=name..' — IMA ADPCM, 22100 Hz mono'}
end
local function decode_caf_image(raw,name,selected_palette)
    local header_size=u32le(raw,17)
    local unpacked,packed,count=u32le(raw,21),u32le(raw,25),u32le(raw,29)
    local fps,pal_size=u32le(raw,61),u32le(raw,65)
    if count<1 or count>10000 or header_size<32 or unpacked>32000000 or pal_size>768
        or pal_size%3~=0 or 68+pal_size+math.min(packed,unpacked)>#raw then return nil end
    local pal=selected_palette or gray()
    if not selected_palette and pal_size>0 then
        -- CAF stores full-range RGB, unlike CPS/NPP VGA palettes.
        for i=1,pal_size do pal[i]=raw:byte(68+i) end
    end
    local data=raw:sub(69+pal_size,68+pal_size+math.min(packed,unpacked))
    if packed<unpacked then
        local pixels=decompress_lzss(data,unpacked); if not pixels then return nil end
        local chunks={}
        for i=1,#pixels,4096 do
            local chunk={}; for j=i,math.min(i+4095,#pixels) do chunk[#chunk+1]=string.char(pixels[j]) end
            chunks[#chunks+1]=table.concat(chunk)
        end
        data=table.concat(chunks)
    elseif #data<unpacked then return nil end
    local function signed(d,p)
        local value=u32le(d,p); return value>=2147483648 and value-4294967296 or value
    end
    local frames,p={},1
    local left,top,right,bottom=math.huge,math.huge,-math.huge,-math.huge
    for i=1,count do
        if p+header_size-1>#data or u32le(data,p)~=0x12345678 then return nil end
        local ref,comp,dec=u32le(data,p+4),u32le(data,p+8),u32le(data,p+12)
        local x,y,x2,y2=signed(data,p+16),signed(data,p+20),signed(data,p+24),signed(data,p+28)
        local w,h=x2-x,y2-y; p=p+header_size
        if w<0 or h<0 or w*h>4000000 or p+comp-1>#data then return nil end
        local pixels
        if ref==0xFFFFFFFF and dec>0 then
            if dec<w*h then return nil end
            if comp<dec then pixels=decompress_lzss(data:sub(p,p+comp-1),dec)
            else
                pixels={}; for j=1,w*h do pixels[j]=data:byte(p+j-1) end
            end
            if not pixels then return nil end
        end
        frames[i]={ref=ref,pixels=pixels,x=x,y=y,w=w,h=h}
        left=math.min(left,x); top=math.min(top,y); right=math.max(right,x2); bottom=math.max(bottom,y2)
        p=p+comp
    end
    local width,height=right-left,bottom-top
    if width==0 or height==0 then
        for _,f in ipairs(frames) do if f.pixels then return nil end end
        return {type='text',description=name..' — CAF (empty placeholder)',
            text=string.format('%s contains %d empty CAF frames and no pixel data.',name,count)}
    end
    if width<1 or height<1 or width*height*count>32000000 then return nil end
    local images={}
    for i,f in ipairs(frames) do
        local source=f; local seen={}
        while not source.pixels and source.ref~=0xFFFFFFFF do
            if seen[source.ref] then return nil end
            seen[source.ref]=true; source=frames[source.ref+1]
            if not source then return nil end
        end
        local pixels={}; for j=1,width*height do pixels[j]=0 end
        if source.pixels then
            if #source.pixels<f.w*f.h then return nil end
            for y=0,f.h-1 do for x=0,f.w-1 do
                pixels[(y+f.y-top)*width+x+f.x-left+1]=source.pixels[y*f.w+x+1]
            end end
        end
        images[i]=image_create_indexed(width,height,pixels,pal,0)
    end
    local desc=string.format('%s — CAF, %d frames, %dx%d, %d fps',name,count,width,height,fps)
    if count==1 then return {type='image',image=images[1],palette_image=palette_swatch(pal),description=desc} end
    return {type='animation',palette_image=palette_swatch(pal),animation=animation_create(images,fps>0 and math.max(1,math.floor(1000/fps)) or 100),description=desc}
end

-- Western releases use Windows-1252 text bytes; LuaJ expects UTF-8 strings.
local cp1252={8364,129,8218,402,8222,8230,8224,8225,710,8240,352,8249,338,141,381,143,144,8216,8217,8220,8221,8226,8211,8212,732,8482,353,8250,339,157,382,376}
local function text_utf8(text)
    return (text:gsub('[\128-\255]',function(c)
        local n=c:byte(); if n<160 then n=cp1252[n-127] end
        if n<2048 then return string.char(192+math.floor(n/64),128+n%64) end
        return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64)
    end):gsub('\r','\n'))
end
function engine.load_resource(path,id,palette_id)
    index(path); local e=entries[id]; if not e then return nil end
    if e.kind=='palette' then
        local pal,info=resource_palette(path,id); if not pal then return nil end
        return {type='image',image=palette_swatch(pal),description=e.name..' — '..info}
    end
    local raw=entry_data(path,e); if not raw then return nil end
    if e.kind=='sound' then return audio(raw,e.name) end
    if raw:sub(1,12)=='KevinAguilar' and #raw>=68 then
        local selected=palette_id and resource_palette(path,palette_id)
        -- Embedded CAF palettes take precedence over the room default.
        if not selected and u32le(raw,65)==0 then
            local pid=engine.default_palette(path,id); selected=pid and resource_palette(path,pid)
        end
        return decode_caf_image(raw,e.name,selected)
    end
    if e.kind=='image' then
        local pic=picture(raw); if not pic then return nil end
        local pal=palette_id and resource_palette(path,palette_id) or pic.palette
        if not palette_id then pal=complete_palette(path,e,pic) end
        local cup=entries['pak:'..e.file..':'..(e.source_name or e.name):gsub('%.[^.]+$','.CUP')]
        local closepal
        if pic.width==1280 and cup and not palette_id then
            closepal={}; for i=1,768 do closepal[i]=pal[i] end
            local data=entry_data(path,cup)
            if not data or #data~=384 then return nil end
            put_palette(closepal,data,1,128)
            local np2=entries['pak:'..e.file..':'..(e.source_name or e.name):gsub('%.[^.]+$','.NP2')]
            if np2 then local data2=entry_data(path,np2); if data2 then put_palette(closepal,data2,232,#data2/3) end end
        end
        local width=pic.width; local pixels=pic.pixels; local image
        if e.view then
            if width~=1280 then return nil end
            pixels={}; local offset=e.view=='closeup' and 640 or 0
            for y=0,399 do for x=0,639 do pixels[y*640+x+1]=pic.pixels[y*1280+x+offset+1] end end
            width=640; if e.view=='closeup' then pal=closepal or pal end
        elseif closepal then
            -- The game flips palettes when scrolling to its stored close-up.
            local rgb={}
            for y=0,399 do for x=0,1279 do
                local colors=x<640 and pal or closepal
                local color=pic.pixels[y*1280+x+1]*3
                local out=(y*1280+x)*3
                rgb[out+1]=colors[color+1]; rgb[out+2]=colors[color+2]; rgb[out+3]=colors[color+3]
            end end
            image=image_create_rgb(width,400,rgb)
        end
        return {type='image',image=image or image_create_indexed(width,pic.height,pixels,pal),
            palette_image=(not closepal or e.view) and palette_swatch(pal) or nil,
            description=string.format('%s — %dx%d, %s%s',e.name,width,pic.height,raw:sub(1,4),closepal and ', normal / close-up palettes' or '')}
    end
    if e.name:upper():match('%.TRE$') and #raw>=2 then
        local count=u16le(raw,1); local lines={}
        if 2+count*4>#raw then return nil end
        for i=0,count-1 do
            local textid=u16le(raw,3+i*2); local off=u16le(raw,3+count*2+i*2)+1
            if off>#raw then return nil end
            local ending=raw:find('\0',off,true) or (#raw+1)
            lines[#lines+1]=string.format('[%d] %s',textid,text_utf8(raw:sub(off,ending-1)))
        end
        return {type='text',text=table.concat(lines,'\n'),description=e.name..' — '..count..' dialogue entries'}
    end
    local lines={e.name..' — '..#raw..' bytes'}
    for p=1,math.min(#raw,1024),16 do
        local bytes={}; for j=p,math.min(p+15,#raw) do bytes[#bytes+1]=string.format('%02X',raw:byte(j)) end
        lines[#lines+1]=string.format('%06X  %s',p-1,table.concat(bytes,' '))
    end
    return {type='text',text=table.concat(lines,'\n'),description=e.name..' — data'}
end
engine._debug={lzss=decompress_lzss,spcn=decompress_spcn,picture=picture,audio=audio,rnc=rnc_unpack,caf=decode_caf_image,text=text_utf8}
return engine

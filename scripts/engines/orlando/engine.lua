-- Jack Orlando original PC archives. See RESEARCH_REPORT.md for format findings.
local engine={id='orlando',name='Jack Orlando',version='1.0',
    description='Jack Orlando (1997, Toontraxx / TopWare), original PC edition'}
local floor=math.floor
local catalogHandles
local function u16(s,p) assert(p>0 and p+1<=#s,'Truncated word');return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function read(e,off,n)
    off=off or 0;n=n or e.size
    assert(off>=0 and n>=0 and off+n<=e.size,'Read outside resource')
    if n==0 then return '' end
    local f=catalogHandles and catalogHandles[e.path]
    if not f then f=assert(file_open(e.path),'Missing '..e.path);if catalogHandles then catalogHandles[e.path]=f end end
    local s=file_read(f,e.offset+off,n);if not catalogHandles then file_close(f) end
    assert(s and #s==n,'Truncated '..e.name);return s
end
local function whole(path)
    local f=file_open(path);if not f then return end
    local n=file_size(f);file_close(f);return {path=path,name=path:match('[^/]+$'),offset=0,size=n}
end
local function directory(e)
    assert(e.size>=4,'Short archive')
    local size=u32(read(e,0,4),1)
    assert(size>=4 and size<=e.size and size<=1048576 and (size-4)%21==0,'Invalid archive directory')
    local s=read(e,0,size);local entries={}
    for p=5,size,21 do
        local off,n=u32(s,p),u32(s,p+4)
        local name=s:sub(p+8,p+20):match('^[^%z]*')
        assert(name~='' and off>=size and off+n<=e.size,'Invalid archive entry')
        entries[#entries+1]={path=e.path,offset=e.offset+off,size=n,name=name}
    end
    return entries
end
local function dims(s)
    if #s<4 then return end
    local w,h=u16(s,1),u16(s,3)
    if w>0 and h>0 and w<=4096 and h<=2048 and w*h<=2097152 then return w,h end
end
local function rgb565(v)
    local r,g,b=floor(v/2048),floor(v/32)%64,v%32
    return r*8+floor(r/4),g*4+floor(g/16),b*8+floor(b/4)
end
local function palette(s,pos,n)
    local pal={}
    for i=0,255 do
        local r,g,b=0,0,0
        if i<n then r,g,b=rgb565(u16(s,pos+i*2)) end
        pal[#pal+1]=r;pal[#pal+1]=g;pal[#pal+1]=b
    end
    return pal
end
local function packed(s)
    local w,h=dims(s);assert(w and #s>=260,'Invalid packed image')
    local pal=palette(s,5,128);local pixels={};local p=261
    while #pixels<w*h do
        assert(p<=#s,'Truncated packed image');local v=s:byte(p);p=p+1
        local count=1
        if v%2==1 then assert(p<=#s,'Truncated image run');count=s:byte(p);p=p+1 end
        assert(count>0 and #pixels+count<=w*h,'Invalid image run')
        for _=1,count do pixels[#pixels+1]=floor(v/2) end
    end
    -- Some small frames retain unused bytes from the encoder's output buffer.
    return w,h,pixels,pal
end
local function bitmap(s)
    local w,h=dims(s);assert(w and #s==4+w*h*2,'Invalid RGB565 image')
    local rgb={}
    for p=5,#s,2 do
        local r,g,b=rgb565(u16(s,p));rgb[#rgb+1]=r;rgb[#rgb+1]=g;rgb[#rgb+1]=b
    end
    return w,h,rgb
end
local function flx(s)
    assert(s:sub(1,4)=='FLX\0' and #s>=20,'Invalid FLX')
    local total,w,h,fps=u16(s,5),u16(s,7),u16(s,9),u16(s,11)
    assert(w>0 and h>0 and w*h<=2097152 and total>0 and fps>0 and fps<=100,'Invalid FLX dimensions/timing')
    local limit=math.min(total,60,math.max(1,floor(8000000/(w*h))))
    local pix,pal,frames={},{},{}
    for i=1,w*h do pix[i]=0 end
    for i=1,768 do pal[i]=0 end
    local p=21
    while #frames<limit and p<=#s do
        local kind,size=u16(s,p),u32(s,p+2)
        assert(size>=6 and p+size-1<=#s,'Invalid FLX chunk')
        local data=s:sub(p+6,p+size-1);p=p+size
        if kind==4 then
            if #data==512 then pal=palette(data,1,256)
            elseif #data==768 then pal={data:byte(1,768)}
            else error('Unsupported FLX palette') end
        elseif kind<=2 then
            local q,offset=1,0
            if #data>0 then
                if kind==2 then
                    local expected=u32(data,1);offset=u32(data,5);local out={};q=9
                    assert(expected>=8 and expected<=w*h*4+8,'Invalid FLX expansion size')
                    local count=0
                    while q<=#data do
                        local b=data:byte(q);q=q+1
                        if b==255 then
                            assert(q+1<=#data,'Truncated FLX RLE')
                            local v,n=data:byte(q,q+1);q=q+2;count=count+n
                            assert(count<=expected-8,'FLX expansion overflow');out[#out+1]=string.rep(string.char(v),n)
                        else count=count+1;assert(count<=expected-8,'FLX expansion overflow');out[#out+1]=string.char(b) end
                    end
                    data=table.concat(out);assert(#data==expected-8,'FLX expansion mismatch');q=1
                elseif kind==1 then offset=u32(data,1);q=5 end
                assert(offset<=w*h,'Invalid FLX offset')
                while q+1<=#data and offset<w*h do
                    assert(q+1<=#data,'Truncated FLX packet')
                    local skip,n=data:byte(q,q+1);q=q+2;offset=offset+skip
                    -- Encoders leave terminal skip packets after the last pixel.
                    if offset>=w*h and n==0 then break end
                    n=math.min(n,#data-q+1)
                    assert(q+n-1<=#data and offset+n<=w*h,'FLX packet overflow')
                    for i=0,n-1 do local v=data:byte(q+i);if v~=0 then pix[offset+i+1]=v end end
                    offset=offset+n;q=q+n
                end
            end
            frames[#frames+1]=assert(image_create_indexed(w,h,pix,pal))
        end
    end
    assert(#frames>0,'FLX contains no image frames')
    return frames,math.max(1,floor(1000/fps)),total
end
local function wav(s)
    assert(s:sub(1,4)=='RIFF' and s:sub(9,12)=='WAVE','Invalid WAVE')
    local finish=u32(s,5)+8;assert(finish<=#s,'Truncated WAVE')
    local p,fmt,pcm=13
    while p+7<=finish do
        local n=u32(s,p+4);assert(p+7+n<=finish,'Invalid WAVE chunk')
        local tag=s:sub(p,p+3)
        if tag=='fmt ' then assert(n>=16,'Short PCM format');fmt=s:sub(p+8,p+7+n)
        elseif tag=='data' then pcm=s:sub(p+8,p+7+n) end
        p=p+8+n+n%2
    end
    assert(fmt and pcm and u16(fmt,1)==1,'Unsupported WAVE encoding')
    local ch,rate,bits=u16(fmt,3),u32(fmt,5),u16(fmt,15)
    assert((ch==1 or ch==2) and rate>0 and rate<=192000 and (bits==8 or bits==16) and #pcm%(ch*bits/8)==0,'Invalid PCM')
    return sound_create_pcm(rate,bits,ch,bits==16,pcm)
end
local cp850={"Ç","ü","é","â","ä","à","å","ç","ê","ë","è","ï","î","ì","Ä","Å","É","æ","Æ","ô","ö","ò","û","ù","ÿ","Ö","Ü","ø","£","Ø","×","ƒ","á","í","ó","ú","ñ","Ñ","ª","º","¿","®","¬","½","¼","¡","«","»","░","▒","▓","│","┤","Á","Â","À","©","╣","║","╗","╝","¢","¥","┐","└","┴","┬","├","─","┼","ã","Ã","╚","╔","╩","╦","╠","═","╬","¤","ð","Ð","Ê","Ë","È","ı","Í","Î","Ï","┘","┌","█","▄","¦","Ì","▀","Ó","ß","Ô","Ò","õ","Õ","µ","þ","Þ","Ú","Û","Ù","ý","Ý","¯","´","­","±","‗","¾","¶","§","÷","¸","°","¨","·","¹","³","²","■"," "}
local function text(s,encrypted)
    local out={}
    for i=1,#s do
        local b=s:byte(i);if encrypted then b=(262-b)%256 end
        out[#out+1]=b<128 and string.char(b) or cp850[b-127]
    end
    return table.concat(out)
end
local cachePath,tree,entries
local help=[[Open the original PC Jack Orlando folder containing DATA.PAK, MENU.PAK and ACTION.
No installation or extraction is needed. Installed GLOBAL.PAK layouts also work.

BM images use RGB565. PBM sprites have their own 128-color RGB565 palette.
Numbered image extensions are detected by their dimensions and stored size.
FLX previews show up to 60 stored frames / eight million pixels.
Scripts are decoded as DOS CP850. Script execution and scene composition are not reconstructed.
PCM WAVE and raw SND effects play/export. Raw SND previews assume 15360 Hz mono.
Compressed speech, MUS music, DLG subtitles, fonts and AVX movies currently have metadata/hex previews.
Director's Cut PHK/PH2 archives and other editions are unverified.]]
local scriptExt={CCG=true,MCC=true,ACI=true,DCN=true,DCG=true,ACE=true,ICS=true,SSD=true,PCS=true,FCC=true,FCM=true}
local function catalog(path)
    entries={};tree={{id='help',name='How to open this game',type='text'}}
    local groups,folders={},{}
    for _,g in ipairs({{'backgrounds','Backgrounds and Screens'},{'sprites','Sprites and Images'}, {'animations','Animation Previews'},
        {'palettes','Palettes'},{'sounds','Speech and Sound'},{'scripts','Scripts and Text'},{'data','Data and Undecoded Media'}}) do
        local node={id=g[1],name=g[2],type='category',children={}};tree[#tree+1]=node;groups[g[1]]=node
    end
    local serial=0
    local function add(e,archive,depth)
        local ext=e.name:upper():match('%.([^%.]+)$') or ''
        if (ext=='PAK' or ext=='PA2') and e.size>=4 and depth<3 then
            for _,child in ipairs(directory(e)) do add(child,archive..' / '..e.name,depth+1) end
            return
        end
        local head=read(e,0,math.min(e.size,280));local w,h=dims(head)
        local group,typ='data','text';e.kind='data'
        if w and e.size==4+w*h*2 then
            e.kind='rgb';typ='image';group=w>=320 and h>=200 and 'backgrounds' or 'sprites'
        elseif w and e.size>=260 and (ext=='PBM' or ext=='BM') then
            e.kind='packed';typ='image';group='sprites'
        elseif ext=='FLX' and head:sub(1,4)=='FLX\0' then e.kind='flx';typ='animation';group='animations'
        elseif ext=='COL' and e.size==768 then e.kind='palette';typ='palette';group='palettes'
        elseif ext=='BMX' and w and e.size==24+w*h then e.kind='bmx';typ='image';group='sprites';e.archive=archive
        elseif ext=='SND' and head:sub(1,4)=='RIFF' then e.kind='wav';typ='sound';group='sounds'
        elseif ext=='SND' and e.size>=12 and u32(head,1)==e.size-12 and head:sub(5,12)==string.rep('\0',8) then
            e.kind='pcm';typ='sound';group='sounds'
        elseif scriptExt[ext] and e.size>0 then e.kind='script';group='scripts'
        elseif ext=='TXT' or ext=='INI' or ext=='BAT' then e.kind='text';group='scripts' end
        serial=serial+1;e.id=group..'_'..serial;entries[e.id]=e
        local key=group..'/'..archive
        if not folders[key] then
            local node={id='archive_'..serial,name=archive,type='category',children={}}
            folders[key]=node;groups[group].children[#groups[group].children+1]=node
        end
        local name=e.name
        if e.kind=='data' then name=name..' ('..e.size..' bytes)' end
        folders[key].children[#folders[key].children+1]={id=e.id,name=name,type=typ}
    end
    local rootNames={}
    for _,n in ipairs(list_files(path) or {}) do rootNames[n:upper()]=n end
    for _,dir in ipairs({'','ACTION','RESOURCE','MOVIES'}) do
        local folder=path..(dir=='' and '' or '/'..(rootNames[dir] or dir))
        local names=list_files(folder) or {};table.sort(names,function(a,b) return a:upper()<b:upper() end)
        for _,name in ipairs(names) do
            local ext=name:upper():match('%.([^%.]+)$')
            if ext and ext~='EXE' and ext~='PIF' then
                local e=whole(folder..'/'..name)
                if e then
                    if (ext=='PAK' or ext=='PA2') and e.size>0 then
                        for _,child in ipairs(directory(e)) do add(child,(dir=='' and '' or dir..'/')..name,1) end
                    elseif ext~='PAK' and ext~='PA2' then add(e,dir=='' and 'Root Files' or dir,1) end
                end
            end
        end
    end
    -- BMX files use the menu's named COL palettes.
    for _,e in pairs(entries) do
        if e.kind=='bmx' then
            local wanted=e.name:upper()=='ERROR.BMX' and 'ERROR.COL' or 'PALETA.COL'
            for _,p in pairs(entries) do if p.kind=='palette' and p.name:upper()==wanted then e.pal=p.id;break end end
        end
    end
    cachePath=path
end
local function build(path)
    if path==cachePath then return end
    catalogHandles={}
    local ok,err=pcall(catalog,path)
    for _,f in pairs(catalogHandles) do file_close(f) end
    catalogHandles=nil
    if not ok then cachePath=nil;error(err) end
end
function engine.detect(path)
    local e=whole(path..'/MENU.PAK')
    if not e or not (file_exists(path..'/JACK95.EXE') or file_exists(path..'/GED.EXE')) then return false end
    local ok,es=pcall(directory,e);if not ok then return false end
    for _,r in ipairs(es) do if r.name:upper()=='JACK2.BM' then return true end end
    return false
end
function engine.get_resources(path) build(path);return tree end
function engine.default_palette(path,id) build(path);return entries[id] and entries[id].pal end
function engine.load_resource(path,id,paletteId)
    build(path)
    if id=='help' then return {type='text',text=help} end
    local e=entries[id];if not e then return end
    local s=read(e,0,e.kind=='data' and math.min(e.size,256) or e.size);local desc=e.name..' ('..e.size..' bytes)'
    if e.kind=='rgb' then local w,h,rgb=bitmap(s);return {type='image',image=image_create_rgb(w,h,rgb),description=desc..' - RGB565'} end
    if e.kind=='packed' or e.kind=='bmx' or e.kind=='palette' then
        local w,h,pix,pal
        if e.kind=='packed' then w,h,pix,pal=packed(s)
        elseif e.kind=='bmx' then
            w,h=dims(s);pix={};for i=25,24+w*h do pix[#pix+1]=s:byte(i) end
        else w,h,pix=128,128,{};for y=0,127 do for x=0,127 do pix[#pix+1]=floor(y/8)*16+floor(x/8) end end end
        local pe=entries[paletteId or e.pal or '']
        if e.kind=='palette' then pe=e end
        if pe and pe.kind=='palette' then local ps=read(pe);pal={ps:byte(1,768)} end
        if not pal then pal={};for i=0,255 do for _=1,3 do pal[#pal+1]=i end end end
        return {type='image',image=image_create_indexed(w,h,pix,pal),description=desc,palette=pal}
    end
    if e.kind=='flx' then
        local frames,delay,total=flx(s)
        return {type='animation',animation=animation_create(frames,delay),description=desc..' - '..#frames..' of '..total..' frames',delay_ms=delay}
    end
    if e.kind=='wav' or e.kind=='pcm' then
        local sound=e.kind=='wav' and wav(s) or sound_create_pcm(15360,8,1,false,s:sub(13))
        return {type='sound',sound=sound,description=desc..(e.kind=='pcm' and ' - assumed 15360 Hz, 8-bit mono' or '')}
    end
    if e.kind=='script' or e.kind=='text' then return {type='text',text=text(s,e.kind=='script'),description=desc} end
    local lines={desc,'Source: '..e.path,'Offset: '..e.offset,'','Undecoded resource. First 256 bytes:'}
    for p=1,math.min(#s,256),16 do
        local hex={};for i=p,math.min(p+15,#s) do hex[#hex+1]=string.format('%02X',s:byte(i)) end
        lines[#lines+1]=string.format('%04X  ',p-1)..table.concat(hex,' ')
    end
    return {type='text',text=table.concat(lines,'\n'),description=desc}
end
return engine

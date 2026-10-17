-- Grim Fandango (1998). Formats verified against ScummVM engines/grim:
-- lab.cpp, bitmap.cpp, material.cpp, colormap.cpp, localize.cpp,
-- imuse/imuse_{mcmp_mgr,sndmgr}.cpp and movie/codecs/vima.cpp.
local engine = {id='grim', name='Grim Fandango', version='1.0',
    description='Grim Fandango (1998, LucasArts) - original PC LAB resources'}
local floor = math.floor
local function check(ok, msg) if not ok then error(msg or 'Truncated or invalid resource', 0) end end
local function u16(s,p) check(p>=1 and p+1<=#s);return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function be16(s,p) check(p>=1 and p+1<=#s);return s:byte(p)*256+s:byte(p+1) end
local function be32(s,p) return be16(s,p)*65536+be16(s,p+2) end
local function signed(n) return n>=32768 and n-65536 or n end
local function read(path,off,len)
    local f=file_open(path);if not f then return nil end
    local size=file_size(f)
    if off<0 or len<0 or off+len>size then file_close(f);return nil end
    local s=len==0 and '' or file_read(f,off,len);file_close(f)
    if s and #s==len then return s end
end
local function directory(path)
    local h=read(path,0,16);if not h or h:sub(1,4)~='LABN' then return nil end
    -- Original Grim LAB version. EMI's different directory is deliberately excluded.
    if u32(h,5)~=0x10000 then return nil end
    local n,sz=u32(h,9),u32(h,13)
    if n==0 or n>100000 or sz>16000000 then return nil end
    local raw=read(path,16,n*16+sz);if not raw then return nil end
    local names=raw:sub(n*16+1);local entries={}
    local f=file_open(path);if not f then return nil end
    local size=file_size(f);file_close(f)
    for i=0,n-1 do
        local p=i*16+1;local no,off,len=u32(raw,p),u32(raw,p+4),u32(raw,p+8)
        local stop=names:find('\0',no+1,true)
        if no>=sz or not stop or stop==no+1 or off<16+n*16+sz or off+len>size then return nil end
        entries[#entries+1]={name=names:sub(no+1,stop-1),offset=off,size=len,path=path}
    end
    return entries
end
local function locations(path)
    local dirs={path}
    for _,name in ipairs(list_files(path) or {}) do
        if name:lower()=='grimdata' then dirs[#dirs+1]=path..'/'..name end
    end
    return dirs
end
local function archives(path)
    local out={}
    for _,dir in ipairs(locations(path)) do
        for _,name in ipairs(list_files(dir) or {}) do
            if name:lower():match('%.lab$') then out[#out+1]={path=dir..'/'..name,name=name} end
        end
    end
    table.sort(out,function(a,b) return a.path:lower()<b.path:lower() end)
    return out
end
function engine.detect(path)
    for _,a in ipairs(archives(path)) do
        if a.name:lower():match('^data00[0-4]%.lab$') then
            local entries=directory(a.path)
            if entries then
                for _,e in ipairs(entries) do
                    if e.name:lower():match('%.bm$') and read(e.path,e.offset,8)=='BM  F\0\0\0' then return true end
                end
            end
        end
    end
    return false
end
local function dimensions(w,h)
    check(w>0 and h>0 and w<=8192 and h<=8192 and w*h<=8000000,'Invalid image dimensions')
end
local function bitmap_info(s)
    check(#s>=136 and s:sub(1,8)=='BM  F\0\0\0','Invalid BM header')
    local codec,n,fmt,bpp=u32(s,9),u32(s,17),u32(s,33),u32(s,37)
    check((codec==0 or codec==3) and n>0 and n<=4096 and bpp==16,'Unsupported BM encoding')
    return codec,n,fmt
end
local cached_path,cached
local function catalog(path)
    if cached_path==path then return cached end
    local c={entries={},tree={},palettes={}}
    c.tree[1]={id='grim/help',name='How to open this game',type='text'}
    for ai,a in ipairs(archives(path)) do
        local entries=directory(a.path)
        if entries then
            local groups={};local root={id='grim/archive/'..ai,name=a.name,type='category',children={}}
            c.tree[#c.tree+1]=root
            local function node(e,kind,label,frame)
                local id='grim/'..tostring(#c.entries+1)
                c.entries[#c.entries+1]={entry=e,kind=kind,frame=frame}
                if not groups[kind] then
                    groups[kind]={id=root.id..'/'..kind,name=label,type='category',children={}}
                    root.children[#root.children+1]=groups[kind]
                end
                local typ=kind=='model' and 'model' or kind=='palette' and 'palette' or ((kind=='bitmap' or kind=='depth' or kind=='texture') and 'image' or ((kind=='speech' or kind=='music' or kind=='sound') and 'sound' or 'text'))
                groups[kind].children[#groups[kind].children+1]={id=id,name=e.name..(frame and (' [image '..frame..']') or ''),type=typ}
                if kind=='palette' then c.palettes[#c.palettes+1]=id end
            end
            for _,e in ipairs(entries) do
                local ext=e.name:lower():match('%.([^%.]+)$');local h=read(e.path,e.offset,math.min(e.size,140)) or ''
                local ok,err=pcall(function()
                    if ext=='bm' or ext=='zbm' then
                        local _,n=bitmap_info(h)
                        for i=1,n do node(e,ext=='zbm' and 'depth' or 'bitmap',ext=='zbm' and 'Depth masks' or 'Bitmaps',i) end
                    elseif ext=='mat' then
                        check(h:sub(1,4)=='MAT ' and #h>=80)
                        local n=u32(h,13);check(n>0 and n<=4096)
                        for i=1,n do node(e,'texture','Textures',i) end
                    elseif ext=='cmp' then node(e,'palette','Palettes')
                    elseif ext=='wav' then node(e,a.name:lower():match('^vox') and 'speech' or 'sound',a.name:lower():match('^vox') and 'Speech' or 'Sound effects')
                    elseif ext=='imu' or ext=='imc' then node(e,'music','Music')
                    elseif ext=='txt' or ext=='set' then node(e,'text','Text and scene definitions')
                    elseif ext=='3do' then node(e,'model','3D Models')
                    elseif ext=='snm' then node(e,'video','Movies (metadata)')
                    else node(e,'data','Scripts, models and data') end
                end)
                if not ok then node(e,'data','Scripts, models and data') end
            end
        end
    end
    for _,dir in ipairs(locations(path)) do
        for _,name in ipairs(list_files(dir) or {}) do
            if name:lower()=='grim.tab' then
                local f=file_open(dir..'/'..name)
                if f then
                    local size=file_size(f);file_close(f)
                    c.entries[#c.entries+1]={entry={name=name,path=dir..'/'..name,offset=0,size=size},kind='tab'}
                    c.tree[#c.tree+1]={id='grim/'..#c.entries,name=name..' (dialogue)',type='text'}
                end
            end
        end
    end
    cached_path,cached=path,c;return c
end
function engine.get_resources(path) return catalog(path).tree end
-- Codec 3: interleaved 16-bit LSB control words and LZ byte references.
local function codec3(s,expected)
    local pos,word,left=3,u16(s,1),16;local out={};local n=0
    local function byte() check(pos<=#s);local b=s:byte(pos);pos=pos+1;return b end
    local function bit()
        local b=word%2;word=floor(word/2);left=left-1
        if left==0 then word=u16(s,pos);pos=pos+2;left=16 end
        return b
    end
    while true do
        if bit()==1 then
            check(n<expected,'BM output overflow');n=n+1;out[n]=byte()
        else
            local len,off
            if bit()==0 then local a=bit();local b=bit();len=a*2+b+3;off=byte()-256
            else
                local a,b=byte(),byte();off=a+floor(b/16)*256-4096;len=b%16+3
                if len==3 then len=byte()+1;if len==1 then break end end
            end
            check(n+off>=0 and n+len<=expected,'Invalid BM back-reference')
            for _=1,len do n=n+1;out[n]=out[n+off];check(out[n]~=nil) end
        end
    end
    check(n==expected,'Incomplete BM output');return out
end
local function bitmap(s,index,depth)
    local codec,n,fmt=bitmap_info(s);check(index>=1 and index<=n)
    local p=129
    for i=1,index do
        local w,h=u32(s,p),u32(s,p+4);dimensions(w,h);p=p+8
        local size=w*h*2;local pixels
        if codec==0 then
            check(p+size-1<=#s);if i==index then pixels={};for j=0,size-1 do pixels[j+1]=s:byte(p+j) end end
            p=p+size
        else
            local len=u32(s,p);p=p+4;check(p+len-1<=#s)
            if i==index then pixels=codec3(s:sub(p,p+len-1),size) end;p=p+len
        end
        if i==index then
            local rgb={}
            for j=0,w*h-1 do
                local v=pixels[j*2+1]+pixels[j*2+2]*256
                if depth or fmt==5 then local gray=floor(v/257);rgb[#rgb+1]=gray;rgb[#rgb+1]=gray;rgb[#rgb+1]=gray
                else rgb[#rgb+1]=floor(v/2048)*255/31;rgb[#rgb+1]=floor(v/32)%64*255/63;rgb[#rgb+1]=v%32*255/31 end
            end
            return {type='image',image=image_create_rgb(w,h,rgb),description=string.format('%dx%d, image %d/%d, %s',w,h,index,n,(depth or fmt==5) and '16-bit depth (grayscale)' or 'RGB565')}
        end
    end
end
local function palette(s)
    check(s:sub(1,4)=='CMP ' and #s>=832,'Invalid CMP palette')
    local pal={};for i=65,832 do pal[#pal+1]=s:byte(i) end;return pal
end
local function texture(s,index,pal)
    check(s:sub(1,4)=='MAT ' and #s>=80,'Invalid MAT header')
    local n=u32(s,13);check(n>0 and n<=4096 and index>=1 and index<=n)
    local extra=u32(s,77);check(extra==0 or extra==8,'Unsupported MAT layout')
    local p=61+n*40+(extra==8 and 16 or 0)
    for i=1,index do
        local w,h=u32(s,p),u32(s,p+4);dimensions(w,h);p=p+24;check(p+w*h-1<=#s)
        if i==index then
            local pixels={};for j=0,w*h-1 do pixels[j+1]=s:byte(p+j) end
            return {type='image',image=image_create_indexed(w,h,pixels,pal),description=string.format('%dx%d indexed texture %d/%d. Select a CMP palette; palette assignment is scene-dependent.',w,h,index,n)}
        end
        p=p+w*h
    end
end
local steps = {
	  7,     8,     9,    10,    11,    12,    13,    14,    16,    17,
	 19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
	 50,    55,    60,    66,    73,    80,    88,    97,   107,   118,
	130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
	337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
	876,   963,  1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
	2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,
	5894,  6484,  7132,  7845,  8630,  9493, 10442, 11487, 12635, 13899,
	15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
}
local widths = {
	4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
	4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
	4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5,
	5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
	6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7
}
local adjustments = {
{
	-1, 4, -1, 4
},
{
	-1, -1, 2, 6, -1, -1, 2, 6
},
{
	-1, -1, -1, -1, 1, 2, 4, 6,
	-1, -1, -1, -1, 1, 2, 4, 6
},
{
	-1, -1, -1, -1, -1, -1, -1, -1,
	1, 1, 1, 2, 2, 4, 5, 6,
	-1, -1, -1, -1, -1, -1, -1, -1,
	1, 1, 1, 2, 2, 4, 5, 6
},
{
	-1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1,
	 1, 1, 1, 1, 1, 2, 2, 2,
	 2, 4, 4, 4, 5, 5, 6, 6,
	-1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1,
	 1, 1, 1, 1, 1, 2, 2, 2,
	 2, 4, 4, 4, 5, 5, 6, 6
},
{
	-1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1,
	 1, 1, 1, 1, 1, 1, 1, 1,
	 1, 1, 2, 2, 2, 2, 2, 2,
	 2, 2, 4, 4, 4, 4, 4, 4,
	 5, 5, 5, 5, 6, 6, 6, 6,
	-1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1,
	 1, 1, 1, 1, 1, 1, 1, 1,
	 1, 1, 2, 2, 2, 2, 2, 2,
	 2, 2, 4, 4, 4, 4, 4, 4,
	 5, 5, 5, 5, 6, 6, 6, 6
},
}
local function clamp(v,lo,hi) return math.max(lo,math.min(hi,v)) end
local function pcm(samples)
    local out={}
    for i,v in ipairs(samples) do v=v%65536;out[i]=string.char(v%256,floor(v/256)) end
    return table.concat(out)
end
-- Precompute adaptive deltas once, avoiding six bit tests per audio sample.
local vima_deltas={}
for idx=0,88 do
    local row={};vima_deltas[idx+1]=row
    local width,step=widths[idx+1],steps[idx+1]
    for val=0,2^(width-1)-2 do
        local mask=val*2^(7-width);local d=0
        for bit=5,0,-1 do if floor(mask/2^bit)%2==1 then d=d+floor(step/2^(5-bit)) end end
        if val~=0 then d=d+floor(step/2^(width-1)) end
        row[val+1]=d
    end
end
local function vima(s,size)
    check(#s>=4 and size>0 and size<=8192 and size%2==0,'Invalid VIMA block')
    local indices={s:byte(1)};local channels=1;local values={signed(be16(s,2))};local p=4
    if indices[1]>=128 then
        channels=2;indices[1]=255-indices[1];indices[2]=s:byte(4);values[2]=signed(be16(s,5));p=7
    end
    check(size%(2*channels)==0);local count=size/(2*channels);local output={}
    local function byte() check(p<=#s,'Truncated VIMA block');local v=s:byte(p);p=p+1;return v end
    if s:sub(p,p+3)=='IMA4' then
        p=p+4;local word,idx,step=0,0,7;local packed
        local deltas={-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8}
        for i=0,count-1 do
            local nibble
            if i%2==0 then packed=byte();nibble=floor(packed/16) else nibble=packed%16 end
            idx=clamp(idx+deltas[nibble+1],0,88)
            local d=floor(step/8)
            if floor(nibble/4)%2==1 then d=d+step end
            if floor(nibble/2)%2==1 then d=d+floor(step/2) end
            if nibble%2==1 then d=d+floor(step/4) end
            word=clamp(word+(nibble>=8 and -d or d),-32768,32767)
            if idx>0 then step=steps[idx+1] end
            for c=1,channels do output[i*channels+c]=word end
        end
    else
        -- MSB bitstream, with independent predictor and index per channel.
        local acc,bits=0,0
        local function take(n)
            while bits<n do acc=acc*256+byte();bits=bits+8 end
            bits=bits-n;local v=floor(acc/2^bits);acc=acc%2^bits;return v
        end
        for c=1,channels do
            local idx,word=indices[c],values[c];check(idx and idx<=88,'Invalid VIMA predictor')
            for i=0,count-1 do
                local width=widths[idx+1];local code=take(width);local sign=2^(width-1);local val=code%sign
                if val==sign-1 then word=signed(take(16))
                else
                    local d=vima_deltas[idx+1][val+1]
                    word=clamp(word+(code>=sign and -d or d),-32768,32767)
                end
                output[i*channels+c]=word
                idx=clamp(idx+adjustments[width-1][val+1],0,88)
            end
        end
    end
    return pcm(output),channels
end
local function sound_header(s)
    local rate,bits,channels,start,length,big
    if s:sub(1,4)=='RIFF' and s:sub(9,12)=='WAVE' then
        local p=13
        while p+7<=#s do
            local tag,len=s:sub(p,p+3),u32(s,p+4);local q=p+8
            if tag=='fmt ' then
                check(len>=16 and u16(s,q)==1,'Only PCM WAVE is supported')
                channels,rate,bits=u16(s,q+2),u32(s,q+4),u16(s,q+14)
            elseif tag=='data' then start=q;length=len;break end
            p=q+len+len%2
        end
    elseif s:sub(1,4)=='iMUS' then
        local p=17;big=true
        while p+7<=#s do
            local tag,len=s:sub(p,p+3),be32(s,p+4);local q=p+8
            if tag=='FRMT' then check(len>=20);bits,rate,channels=be32(s,q+8),be32(s,q+12),be32(s,q+16)
            elseif tag=='DATA' then start=q;length=len;break end
            check(q+len-1<=#s);p=q+len
        end
    end
    check(start and rate and rate>=4000 and rate<=192000 and (bits==8 or bits==16) and (channels==1 or channels==2),'Unsupported audio header')
    return rate,bits,channels,start,length,big
end
local function sound(s)
    local audio,rate,bits,channels
    if s:sub(1,4)=='MCMP' then
        local n=be16(s,5);check(n>=2 and n<=65535)
        local p=7+n*9;local codecs=be16(s,p);local header_start=p+2+codecs
        local header_len=be32(s,12);check(header_len<=1000000 and header_start+header_len-1<=#s)
        local header=s:sub(header_start,header_start+header_len-1)
        rate,bits,channels=sound_header(header);check(bits==16,'VIMA requires 16-bit PCM')
        local off=header_start+header_len;local blocks={};local total=0
        for i=1,n-1 do
            local q=7+i*9;local codec=s:byte(q);local dec,comp=be32(s,q+1),be32(s,q+5)
            check(dec<=8192 and off+comp-1<=#s and total+dec<=64000000,'Invalid MCMP block')
            if dec>0 then
                local raw=s:sub(off,off+comp-1)
                if codec==0 then check(comp==dec);blocks[#blocks+1]=raw
                elseif codec==1 then
                    local decoded,nch=vima(raw,dec);check(nch==channels,'VIMA channel mismatch');blocks[#blocks+1]=decoded
                else error('Unsupported MCMP codec '..codec,0) end
            end
            off=off+comp;total=total+dec
        end
        audio=table.concat(blocks)
    else
        local start,length,big
        rate,bits,channels,start,length,big=sound_header(s)
        check(length<=64000000 and start+length-1<=#s,'Truncated PCM data')
        audio=s:sub(start,start+length-1)
        if big and bits==16 then audio=audio:gsub('(.)(.)','%2%1') end
    end
    check(#audio>0 and #audio%(channels*bits/8)==0,'Invalid PCM length')
    return {type='sound',sound=sound_create_pcm(rate,bits,channels,bits==16,audio),
        description=string.format('%d Hz, %d-bit, %d channel(s). Linear resource playback; iMUSE jumps/loops are not executed.',rate,bits,channels)}
end
local function utf8_text(s)
    local cp={ [128]=8364,[130]=8218,[131]=402,[132]=8222,[133]=8230,[134]=8224,[135]=8225,[136]=710,[137]=8240,[138]=352,[139]=8249,[140]=338,[142]=381,[145]=8216,[146]=8217,[147]=8220,[148]=8221,[149]=8226,[150]=8211,[151]=8212,[152]=732,[153]=8482,[154]=353,[155]=8250,[156]=339,[158]=382,[159]=376 }
    return (s:gsub('[\128-\255]',function(c)
        local n=cp[c:byte()] or c:byte()
        if n<2048 then return string.char(192+floor(n/64),128+n%64) end
        return string.char(224+floor(n/4096),128+floor(n/64)%64,128+n%64)
    end))
end
local function metadata(e,s)
    local lines={e.name,string.format('%d bytes, archive offset 0x%X',e.size,e.offset),'',
        'Binary resource preview (first 1024 bytes). Costumes, Lua bytecode, keyframes and movies are not rendered.',''}
    for p=1,math.min(#s,1024),16 do
        local row=s:sub(p,p+15);local hex=row:gsub('.',function(c) return string.format('%02X ',c:byte()) end)
        lines[#lines+1]=string.format('%06X  %-48s %s',p-1,hex,(row:gsub('[^ -~]','.')))
    end
    return {type='text',text=table.concat(lines,'\n')}
end
local function model_palette(c,e)
    local stem=e.name:lower():gsub('%.3do$','')
    for _,pid in ipairs(c.palettes) do
        local pe=c.entries[tonumber(pid:match('(%d+)$'))].entry
        if pe.name:lower()==stem..'.cmp' then return pid end
        if (stem:match('^manny') or stem:match('^m_') or stem:match('^md_')) and pe.name:lower()=='suit.cmp' then return pid end
    end
    for _,pid in ipairs(c.palettes) do
        local pe=c.entries[tonumber(pid:match('(%d+)$'))].entry
        if pe.name:lower()=='item.cmp' then return pid end
    end
    return c.palettes[1]
end
function engine.default_palette(path,id)
    local c=catalog(path);local record=c.entries[tonumber(id:match('^grim/(%d+)$'))]
    if record and record.kind=='model' then return model_palette(c,record.entry) end
end
function engine.load_resource(path,id,palette_id,texture_id)
    if id=='grim/help' then return {type='text',text='Open the original PC game folder containing DATA000.LAB (or other DATA00x.LAB files), or a disc root containing GRIMDATA. Each disc can be browsed separately. To browse all years together, copy the LAB files from both discs into one folder; include GRIM.TAB for dialogue. No installation or cabinet extraction is needed.\n\nBitmaps are RGB565; depth masks use grayscale. Each stored bitmap/texture image is separately accessible. Textures require a manually selected CMP palette (grayscale by default). Audio plays the stored PCM/VIMA stream linearly. Models use their named MAT textures in a default pose; select a CMP palette or texture override. Scene composition, scripted animation, iMUSE transitions and movie playback are not implemented. Remastered and Escape from Monkey Island archives are unverified.'} end
    local c=catalog(path);local record=c.entries[tonumber(id:match('^grim/(%d+)$'))]
    if not record then return nil end
    local e=record.entry
    local ok,result=pcall(function()
        local limit=(record.kind=='data' or record.kind=='video') and 1024 or 64000000
        check(e.size<=limit or limit==1024,'Resource exceeds preview size limit')
        local s=read(e.path,e.offset,math.min(e.size,limit));check(s~=nil,'Cannot read resource')
        if record.kind=='model' then
            if not model_decode_grim or not model_set_textures then
                return {type='text',text='Rebuild and restart Adventure Explorer to use the model preview scripts.'}
            end
            local model=model_decode_grim(s);local materials=model_materials(model)
            local options,byname={},{}
            for i,tr in ipairs(c.entries) do
                if tr.kind=='texture' then
                    local tid='grim/'..i
                    options[#options+1]={id=tid,name=tr.entry.name..' [image '..tr.frame..']',type='image'}
                    local key=tr.entry.name:lower()
                    if tr.frame==1 and (not byname[key] or tr.entry.path==e.path) then byname[key]=tid end
                end
            end
            table.sort(options,function(a,b) return a.name<b.name end)
            local textures={};local loaded={};local missing={}
            local palid=palette_id or model_palette(c,e)
            if texture_id~='__none__' then
                for slot,name in ipairs(materials) do
                    local tid=texture_id or byname[name:lower()]
                    if tid then
                        if not loaded[tid] then
                            local decoded=engine.load_resource(path,tid,palid)
                            loaded[tid]=decoded and decoded.type=='image' and decoded.image or false
                        end
                        if loaded[tid] then textures[#textures+1]={slot=slot-1,image=loaded[tid]} else missing[#missing+1]=name end
                    else missing[#missing+1]=name end
                end
            end
            model_set_textures(model,textures)
            return {type='model',model=model,texture_options=options,texture_id=texture_id,
                description='Default pose; '..#textures..' textured materials'..(#missing>0 and ('; '..#missing..' unavailable materials') or '')}
        elseif record.kind=='bitmap' or record.kind=='depth' then return bitmap(s,record.frame,record.kind=='depth')
        elseif record.kind=='texture' then
            local pal={};for i=0,255 do pal[#pal+1]=i;pal[#pal+1]=i;pal[#pal+1]=i end
            if palette_id then
                local pr=c.entries[tonumber(palette_id:match('^grim/(%d+)$'))]
                if pr and pr.kind=='palette' then local pe=pr.entry;pal=palette(assert(read(pe.path,pe.offset,math.min(pe.size,832)))) end
            end
            return texture(s,record.frame,pal)
        elseif record.kind=='palette' then
            local pal=palette(s);local pixels={};for i=0,255 do pixels[#pixels+1]=i end
            return {type='palette',image=image_create_indexed(16,16,pixels,pal),palette=pal}
        elseif record.kind=='sound' or record.kind=='speech' or record.kind=='music' then return sound(s)
        elseif record.kind=='tab' then
            if s:sub(1,4)=='RCNE' then
                s=s:sub(5):gsub('.',function(ch)
                    local a,b,v=ch:byte(),221,0;local bit=1
                    for _=1,8 do if a%2~=b%2 then v=v+bit end;a=floor(a/2);b=floor(b/2);bit=bit*2 end
                    return string.char(v)
                end)
            else s=s:sub(5) end
            return {type='text',text=utf8_text(s)}
        elseif record.kind=='text' then return {type='text',text=utf8_text(s)} end
        return metadata(e,s)
    end)
    if not ok then
        if tostring(result):find('Model has no visible geometry',1,true) then
            return {type='text',text=e.name..'\nModel has no visible geometry (empty helper object).',description=e.name}
        end
        return {type='text',text=e.name..'\nUnable to preview: '..tostring(result)}
    end
    result.description=e.name..(result.description and (' - '..result.description) or '')
    return result
end
return engine

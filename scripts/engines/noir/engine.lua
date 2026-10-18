-- Discworld Noir (Tinsel 3, Windows 3CD). Format reference: ScummVM
-- engines/tinsel/{handle,graphics,strres,sound,music}.cpp and noir/lzss.cpp.
local engine = {id="noir", name="Discworld Noir",
    description="Discworld Noir (1999, Perfect Entertainment)", version="1.0"}
local function u16(s,p) return s:byte(p)+s:byte(p+1)*256 end
local function i16(s,p) local n=u16(s,p); return n<32768 and n or n-65536 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function read(path,offset,length)
    local f=file_open(path); if not f then return nil end
    local size=file_size(f)
    offset=offset or 0; length=length or size
    local data
    if offset>=0 and length>=0 and offset+length<=size then data=file_read(f,offset,length) end
    file_close(f); return data
end
local function filesize(path)
    local f=file_open(path); if not f then return 0 end
    local size=file_size(f); file_close(f); return size
end
local function roots(path)
    local out,seen={},{}
    local function add(p) if not seen[p] and file_exists(p) then seen[p]=true; out[#out+1]=p end end
    path=path:gsub('/+$',''); add(path)
    for n=1,3 do add(path..'/cd'..n) end
    local parent=path:match('^(.*)/cd[123]$')
    if parent then for n=1,3 do add(parent..'/cd'..n) end end
    -- Only discover other mounted CDs when opening this disc set itself.
    if path:match('^/Volumes/DWN_ENG_[123]$') or path:match('^/Volumes/DWN_ENG_[123]/cd[123]$') then
        for n=1,3 do add('/Volumes/DWN_ENG_'..n..'/cd'..n) end
    end
    return out
end
local function locate(dirs,name)
    for _,dir in ipairs(dirs) do if file_exists(dir..'/'..name) then return dir..'/'..name end end
end
function engine.detect(path)
    local dirs=roots(path)
    return locate(dirs,'dw3.scn')~=nil and locate(dirs,'index')~=nil
end
local state
local function scene(st,slot)
    if st.cacheSlot==slot then return st.cache end
    local entry=st.entries[slot]
    if not entry or not entry.path then return nil end
    local data=read(entry.path)
    if data and math.floor(entry.flags/268435456)%2==1 then data=noir_unpack(data,entry.size) end
    if not data or #data~=entry.size then return nil end
    st.cacheSlot,st.cache=slot,data
    return data
end
local function chunks(data)
    local out,seen={},{}; local off=0
    while off+8<=#data and not seen[off] do
        seen[off]=true
        local kind,nextoff=u32(data,off+1),u32(data,off+5)
        local last=nextoff==0 and #data or nextoff
        if kind<0x33340001 or kind>0x33340100 or last<off+8 or last>#data then return {} end
        out[#out+1]={kind=kind,first=off+8,last=last}
        if nextoff==0 then break end
        off=nextoff
    end
    return out
end
local names={[1]='Strings / pixels',[2]='Bitmap',[6]='Images',[7]='Frame lists',
    [8]='Films',[9]='Fonts',[10]='Pcode',[11]='Entrances',[12]='Polygons',
    [13]='Actors',[14]='Processes',[15]='Scene',[19]='Objects',[25]='CD graphics',
    [27]='CD filename',[28]='Music filename',[29]='Music scripts',[30]='Music segments',
    [32]='Timestamps',[49]='Game',[50]='Scene data 50',[51]='Scene data 51'}
local function category(id,name) return {id=id,name=name,type='category',children={}} end
local function add(st,cat,id,name,kind,record)
    record.kind=kind; st.resources[id]=record
    cat.children[#cat.children+1]={id=id,name=name,type=kind}
end
local function build(path)
    local dirs=roots(path)
    local st={path=path,entries={},resources={},dirs=dirs}
    local raw=read(locate(dirs,'index') or '')
    if not raw or #raw%24~=0 or #raw>24000 then return st,{} end
    for p=1,#raw,24 do
        local name=raw:sub(p,p+11):match('^[^%z]+')
        if name and not name:find('[/\\]') then
            st.entries[(p-1)/24]={name=name,size=u32(raw,p+12),flags=u32(raw,p+20),path=locate(dirs,name)}
        end
    end
    local bg=category('backgrounds','Backgrounds and Screens')
    local sprites=category('sprites','Sprites and Overlays')
    local music=category('music','Music')
    local speech=category('speech','Speech and Sound')
    local texts=category('texts','Text')
    local dataCat=category('data','Scene and File Data')
    local info={'Discworld Noir - Tinsel 3','Data directories: '..table.concat(dirs,', '),
        'RGB565 raw and word RLE; magenta is transparent.',
        'Movies (BMV), 3D actor models and scripted animation playback are not decoded.'}
    for slot=0,#raw/24-1 do
        local entry=st.entries[slot]
        if entry and entry.name:lower():match('%.scn$') then
            local data=scene(st,slot)
            if not data then info[#info+1]='Unavailable: '..entry.name else
                local cs=chunks(data)
                local bgroup=category('bgfile_'..slot,entry.name)
                local sgroup=category('spritefile_'..slot,entry.name)
                local dgroup=category('datafile_'..slot,entry.name)
                for ci,c in ipairs(cs) do
                    add(st,dgroup,'chunk_'..slot..'_'..c.first,
                        string.format('%s (0x%08X, %d bytes)',names[c.kind-0x33340000] or 'Chunk',c.kind,c.last-c.first),
                        'text',{slot=slot,first=c.first,last=c.last,chunk=c.kind})
                    if c.kind==0x33340006 then
                        for off=c.first,c.last-16,16 do
                            local w,h=i16(data,off+1),u16(data,off+3)
                            local bits=u32(data,off+9)
                            if w>0 and w<=4096 and h>0 and h<=4096 and w*h<=4194304 and bits~=0 then
                                local owner=math.floor(bits/33554432)
                                local img={slot=slot,owner=owner,offset=bits%33554432,w=w,h=h,
                                    rle=i16(data,off+13)~=0,flags=u16(data,off+15),x=i16(data,off+5),y=i16(data,off+7)}
                                local group=(w>=600 and h>=200) and bgroup or sgroup
                                add(st,group,'image_'..slot..'_'..off,
                                    string.format('Image %d (%dx%d, %s)',(off-c.first)/16,w,h,img.rle and 'RLE' or 'raw'), 'image',img)
                            end
                        end
                    elseif c.kind==0x3334001e then
                        local mus=locate(dirs,entry.name:gsub('%.[sS][cC][nN]$','.mus'))
                        local size=mus and filesize(mus) or 0
                        for off=c.first,c.last-8,8 do
                            local length,offset=u32(data,off+1),u32(data,off+5)
                            if length>0 and offset+length<=size then
                                add(st,music,'music_'..slot..'_'..off,
                                    string.format('%s - segment %d',entry.name,(off-c.first)/8),'sound',
                                    {file=mus,offset=offset,length=length})
                            end
                        end
                    end
                end
                if #bgroup.children>0 then bg.children[#bg.children+1]=bgroup end
                if #sgroup.children>0 then sprites.children[#sprites.children+1]=sgroup end
                if #dgroup.children>0 then dataCat.children[#dataCat.children+1]=dgroup end
            end
        end
    end
    local files={}
    for _,dir in ipairs(dirs) do
        for _,name in ipairs(list_files(dir) or {}) do
            local lower=name:lower()
            if not files[lower] then files[lower]=dir..'/'..name end
        end
    end
    local sorted={}; for name in pairs(files) do sorted[#sorted+1]=name end; table.sort(sorted)
    for _,name in ipairs(sorted) do
        local file=files[name]
        if name:match('%.txt$') then
            local text=read(file)
            if text then
                local group=category('textfile_'..name,name)
                for ci,c in ipairs(chunks(text)) do
                    if c.kind==0x33340001 or c.kind==0x33340022 then
                        add(st,group,'text_'..name..'_'..ci,'Strings '..((ci-1)*64)..'-'..(ci*64-1),
                            'text',{file=file,first=c.first,last=c.last,strings=true,base=(ci-1)*64})
                    end
                end
                if #group.children>0 then texts.children[#texts.children+1]=group end
            end
        elseif name:match('%.idx$') then
            local smp=files[name:gsub('%.idx$','.smp')]
            local idx=read(file); local size=smp and filesize(smp) or 0
            if idx and #idx%4==0 and #idx<=1048576 and size>0 then
                local group=category('speechfile_'..name,name)
                local f=file_open(smp)
                for p=5,#idx,4 do
                    local offset=u32(idx,p); local id=(p-1)/4
                    if offset>0 and offset+4<=size then
                        local header=file_read(f,offset,4); local length=u32(header,1)
                        local count=1
                        if length>=2147483648 then count=length-2147483648; offset=offset+4 end
                        if count>0 and count<=256 then
                            for sub=0,count-1 do
                                if offset+4>size then break end
                                local len=u32(file_read(f,offset,4),1); offset=offset+4
                                if len==0 or len>16777216 or offset+len>size then break end
                                add(st,group,'speech_'..name..'_'..id..'_'..sub,
                                    string.format('Sample %d.%d',id,sub),'sound',{file=smp,offset=offset,length=len})
                                offset=offset+len
                            end
                        end
                    end
                end
                file_close(f)
                if #group.children>0 then speech.children[#speech.children+1]=group end
            end
        elseif name:match('%.bmv$') or name:match('%.gbl$') or name:match('%.rbh$') or name:match('%.pal$') or name:match('%.vmc$') or name:match('%.h$') then
            add(st,dataCat,'file_'..name,name..' (metadata / hex)','text',{file=file,length=filesize(file),metadata=true})
        end
    end
    add(st,dataCat,'noir_info','Disc set and format information','text',{info=table.concat(info,'\n')})
    st.cacheSlot,st.cache=nil,nil
    local tree={}; for _,c in ipairs({bg,sprites,music,speech,texts,dataCat}) do
        if #c.children>0 then tree[#tree+1]=c end
    end
    return st,tree
end
function engine.get_resources(path)
    local tree; state,tree=build(path); return tree
end
local function hex(data)
    local lines={}
    for off=0,math.min(#data,4096)-1,16 do
        local bytes={}; for p=off+1,math.min(off+16,#data) do bytes[#bytes+1]=string.format('%02X',data:byte(p)) end
        lines[#lines+1]=string.format('%08X  %s',off,table.concat(bytes,' '))
    end
    return table.concat(lines,'\n')
end
-- European Windows dialogue bytes become UTF-8 for the host text viewer.
local cp1252={8364,129,8218,402,8222,8230,8224,8225,710,8240,352,8249,338,141,381,143,
    144,8216,8217,8220,8221,8226,8211,8212,732,8482,353,8250,339,157,382,376}
local function text_utf8(s)
    return (s:gsub('[\128-\255]',function(c)
        local n=c:byte(); if n<160 then n=cp1252[n-127] end
        if n<2048 then return string.char(192+math.floor(n/64),128+n%64) end
        return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64)
    end))
end
local function strings(data,base)
    local p,lines=1,{}
    local function one()
        if p>#data then return nil end
        local n=data:byte(p); p=p+1
        if n==128 or n==144 then
            if p>#data then return nil end
            local extra=n==144 and 256 or 0; n=data:byte(p)+extra; p=p+1
        end
        if p+n-1>#data then return nil end
        local s=data:sub(p,p+n-1); p=p+n; return s
    end
    for i=0,63 do
        if p>#data then break end
        local tag=data:byte(p)
        local subs=1
        if tag>128 and tag~=144 then subs=tag-128; p=p+1 end
        for sub=0,subs-1 do
            local s=one(); if not s then return table.concat(lines,'\n')..'\n[Truncated string]' end
            lines[#lines+1]=string.format('%d.%d: %s',base+i,sub,text_utf8(s))
        end
    end
    return table.concat(lines,'\n')
end
function engine.load_resource(path,id)
    if not state or state.path~=path then engine.get_resources(path) end
    local r=state.resources[id]; if not r then return nil end
    if r.kind=='image' then
        local data=scene(state,r.owner); if not data then return nil end
        local img=noir_image(data,r.offset,r.w,r.h,r.rle); if not img then return nil end
        return {type='image',image=img,description=string.format(
            'Discworld Noir RGB565 %dx%d; %s; origin %d,%d; color flags %d (unblended preview)',
            r.w,r.h,r.rle and 'word RLE' or 'raw',r.x,r.y,r.flags)}
    elseif r.kind=='sound' then
        local data=read(r.file,r.offset,r.length); if not data then return nil end
        local sound=sound_create_encoded(data); if not sound then return nil end
        return {type='sound',sound=sound,description=r.file..' - MPEG audio'}
    elseif r.info then return {type='text',text=r.info}
    elseif r.strings then
        local data=read(r.file,r.first,r.last-r.first)
        return data and {type='text',text=strings(data,r.base)} or nil
    elseif r.metadata then
        local data=read(r.file,0,math.min(r.length,4096))
        return data and {type='text',text=r.file..'\n'..r.length..' bytes\nDecoder not implemented for this file type.\n\n'..hex(data)} or nil
    else
        local data=scene(state,r.slot); if not data then return nil end
        return {type='text',text=string.format('%s\nChunk 0x%08X at 0x%X (%d bytes)\nHex preview (first 4096 bytes):\n\n',
            state.entries[r.slot].name,r.chunk,r.first,r.last-r.first)..hex(data:sub(r.first+1,math.min(r.last,r.first+4096)))}
    end
end
return engine

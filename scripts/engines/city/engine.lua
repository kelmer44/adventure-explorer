-- City of Lost Children PC resources. See engine-sources.md for verified layouts.
local engine = {id='city', name='The City of Lost Children', version='1.0',
    description='The City of Lost Children (1997, Psygnosis) - PC CRSL archives'}
local floor, min = math.floor, math.min
local function u16(s,p)
    assert(p>=1 and p+1<=#s,'Truncated word')
    return s:byte(p)+s:byte(p+1)*256
end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function range(path,offset,length)
    local f=assert(file_open(path),'Cannot open '..path)
    local size=file_size(f)
    if offset<0 or length<0 or offset+length>size then file_close(f);error('Invalid file range') end
    local s=length>0 and file_read(f,offset,length) or '';file_close(f)
    assert(s and #s==length,'Truncated file');return s
end
local function child(path,name)
    for _,n in ipairs(list_files(path)) do if n:lower()==name:lower() then return path..'/'..n end end
end
local function datadir(path)
    if child(path,'CITE1.DAT') then return path end
    return child(path,'DATAS')
end
local function archive(path)
    local f=assert(file_open(path));local size=file_size(f);file_close(f)
    local s=range(path,0,8)
    assert(s:sub(1,6)=='CRSL\1\0','Invalid CRSL archive')
    local n=u16(s,7);assert(n>0 and 8+n*28<=size,'Invalid archive directory')
    s=range(path,8,n*28);local entries={}
    for i=0,n-1 do
        local p=i*28+1;local stored,unpacked,offset=u32(s,p),u32(s,p+4),u32(s,p+8)
        assert(offset>=8+n*28 and offset+stored<=size,'Invalid archive entry range')
        -- Filename is 12 bytes; the final four bytes are flags, not name data.
        local name=s:sub(p+12,p+23):match('^[^%z]*')
        assert(#name>0,'Empty archive filename')
        entries[#entries+1]={file=path,offset=offset,size=stored,unpacked=unpacked,name=name}
    end
    return entries
end
local function bytes(e,limit) return range(e.file,e.offset or 0,min(e.size,limit or e.size)) end

-- CRP/ZBF RLE: low-bit packets store tag+1 literal bytes; high-bit
-- packets repeat the next byte tag-126 times (including 0x80 => two).
local function rle(s,p,count)
    assert(count>0 and count<=16000000,'Invalid image size')
    local out={};local n=0
    while n<count do
        local tag=s:byte(p);assert(tag,'Truncated RLE packet');p=p+1
        local run=tag<128 and tag+1 or tag-126
        assert(n+run<=count,'RLE output overflow')
        if tag>=128 then
            local v=s:byte(p);assert(v,'Missing RLE repeat byte');p=p+1
            for _=1,run do n=n+1;out[n]=v end
        else
            assert(p+run-1<=#s,'Truncated RLE literal')
            for _=1,run do n=n+1;out[n]=s:byte(p);p=p+1 end
        end
    end
    assert(p==#s+1,'Trailing RLE data');return out
end
local function crp(s)
    if #s==307200 and s:sub(1,4)~='CRSL' then
        local out={};for i=1,#s do out[i]=s:byte(i) end;return 640,480,out
    end
    assert(s:sub(1,7)=='CRSL\1\2\1','Unsupported CRP header')
    local w,h=u16(s,8),u16(s,10)
    assert(u32(s,12)==#s-15,'Invalid CRP payload size')
    return w,h,rle(s,16,w*h)
end
local function zbf(s)
    assert(u32(s,1)==2,'Unsupported depth mask')
    local w,h=u16(s,17),u16(s,19)
    assert(w*h==u32(s,21) and u32(s,25)==#s-28,'Invalid depth mask sizes')
    return w,h,rle(s,29,w*h)
end
local function palette(s)
    assert(#s==776 and s:sub(1,8)=='CRSL\1\1\0\1','Unsupported CPA palette')
    local pal={};for i=1,768 do local v=s:byte(i+8);assert(v<=63,'Invalid VGA color');pal[i]=v*4 end
    return pal
end
local gray={};for i=0,255 do for _=1,3 do gray[#gray+1]=i end end
local function frm(s)
    local n=u16(s,1);local w,h=u16(s,15),u32(s,17);local size=u32(s,29)
    assert(n>0 and n<=4096 and w>0 and h>0 and w*h==size and size<=16000000,'Invalid FRM atlas')
    assert(40+size+n*14<=#s,'Truncated FRM atlas')
    local rects={}
    for i=0,n-1 do
        local p=41+size+i*14
        local r={x=u16(s,p+6),y=u16(s,p+8),w=u16(s,p+10),h=u16(s,p+12)}
        assert(r.w>0 and r.h>0 and r.x+r.w<=w and r.y+r.h<=h,'Invalid FRM rectangle')
        rects[#rects+1]=r
    end
    return {w=w,h=h,rects=rects}
end
local function snw(s)
    local n=u32(s,1);assert(n<=4096 and 8+n*16<=#s,'Invalid SNW directory')
    assert(u32(s,5)==#s-8-n*16,'Invalid SNW data size')
    local clips={};local ending=8+n*16
    for i=0,n-1 do
        local p=9+i*16;local size,offset=u32(s,p),u32(s,p+4)
        assert(offset==ending and offset+size<=#s,'Invalid SNW clip range')
        assert(u32(s,p+8)==0 and u32(s,p+12)==0,'Unsupported SNW flags')
        clips[#clips+1]={offset=offset,size=size};ending=offset+size
    end
    assert(ending==#s,'Trailing SNW data');return clips
end
local function wav(s)
    assert(s:sub(1,4)=='RIFF' and s:sub(9,12)=='WAVE','Invalid WAVE')
    local ending=u32(s,5)+8;assert(ending<=#s,'Truncated RIFF')
    local p,fmt,data=13
    while p+7<=ending do
        local n=u32(s,p+4);assert(p+7+n<=ending,'Truncated WAVE chunk')
        local tag=s:sub(p,p+3)
        if tag=='fmt ' then fmt=s:sub(p+8,p+7+n) elseif tag=='data' then data=s:sub(p+8,p+7+n) end
        p=p+8+n+n%2
    end
    assert(fmt and #fmt>=16 and data and u16(fmt,1)==1,'Unsupported WAVE encoding')
    local ch,rate,bits=u16(fmt,3),u32(fmt,5),u16(fmt,15)
    assert((ch==1 or ch==2) and rate>0 and (bits==8 or bits==16),'Invalid PCM format')
    assert(u16(fmt,13)==ch*bits/8 and #data%(ch*bits/8)==0,'Invalid PCM alignment')
    return sound_create_pcm(rate,bits,ch,bits==16,data)
end

local cp850={199,252,233,226,228,224,229,231,234,235,232,239,238,236,196,197,201,230,198,244,246,242,251,249,255,214,220,248,163,216,215,402,225,237,243,250,241,209,170,186,191,174,172,189,188,161,171,187,9617,9618,9619,9474,9508,193,194,192,169,9571,9553,9559,9565,162,165,9488,9492,9524,9516,9500,9472,9532,227,195,9562,9556,9577,9574,9568,9552,9580,164,240,208,202,203,200,305,205,206,207,9496,9484,9608,9604,166,204,9600,211,223,212,210,245,213,181,254,222,218,219,217,253,221,175,180,173,177,8215,190,182,167,247,184,176,168,183,185,179,178,9632,160}
local function utf8(n)
    if n<128 then return string.char(n) elseif n<2048 then return string.char(192+floor(n/64),128+n%64)
    else return string.char(224+floor(n/4096),128+floor(n/64)%64,128+n%64) end
end
local function text850(s) return (s:gsub('[\128-\255]',function(c) return utf8(cp850[c:byte()-127]) end)) end
local function dialogue(s)
    local n=u32(s,1);assert(n>0 and n<=10000,'Invalid dialogue count')
    local names=u32(s,9);assert(names==8+(n+1)*4 and names+n*4<=#s,'Invalid dialogue table')
    local lines={text850(s:sub(5,7))..' dialogue - DOS CP850'}
    for i=1,n do
        local p=u32(s,9+i*4)+1;local ending=i<n and u32(s,13+i*4) or #s
        assert(p>=names+n*4+1 and ending>=p-1 and ending<=#s,'Invalid dialogue range')
        local code=s:sub(names+(i-1)*4+1,names+(i-1)*4+3)
        local out={}
        while p<=ending do
            assert(p+2<=ending,'Truncated dialogue line')
            -- u16 horizontal position, u8 speaker/style flag, then text.
            p=p+3;local q=p
            while q<=ending and s:byte(q)~=0 and s:byte(q)~=12 do q=q+1 end
            assert(q<=ending,'Unterminated dialogue line')
            out[#out+1]=text850(s:sub(p,q-1));local separator=s:byte(q);p=q+1
            if separator==0 then break end
        end
        lines[#lines+1]=string.format('%03d [%s] %s',i-1,code,table.concat(out,'\n    '))
    end
    return table.concat(lines,'\n')
end
local cache={}
local instructions=[[Open the CITY folder containing DATAS, LANGS, GLOBS and MOVS.
The DATAS folder containing CITE1.DAT and CITEG.DAT can also be opened directly;
choose CITY to include speech and movies. No installation or extraction is needed.

CRP pictures/fonts, CPA palettes, ZBF depth masks and FRM texture atlases/crops
are decoded. SNW effects and loose PCM WAVE speech are playable. Dialogue is
shown in all five stored languages. Use the palette selector to recolor an image.
Scene sprites use the matching SCENE palette; unassigned images use grayscale.

TMM models have interactive textured previews; characters use their first stored
ANI pose assembled with SKL/ENV data. Choose a texture atlas and palette when needed.
FRM crops are stored texture/sprite rectangles, without scene composition.
YOP movies, TRACK2.RAW CD music, game scripts and scene composition are not decoded.]]
function engine.detect(path)
    local dir=datadir(path);if not dir then return false end
    for _,name in ipairs({'CITE1.DAT','CITEG.DAT'}) do
        local p=child(dir,name);if not p then return false end
        local ok,s=pcall(range,p,0,8)
        if not ok or s:sub(1,6)~='CRSL\1\0' then return false end
    end
    return true
end
local function build(path)
    if cache.path==path then return cache.tree end
    cache={path=path,entries={},tree={}}
    local tree,entries=cache.tree,cache.entries
    tree[1]={id='city_help',name='How to open this game',type='text'}
    local dir=assert(datadir(path),'Missing DATAS folder')
    local archives={}
    for _,name in ipairs(list_files(dir)) do
        if name:upper():match('^CITE.*%.DAT$') then archives[#archives+1]=name end
    end
    table.sort(archives)
    for ai,name in ipairs(archives) do
        local list=archive(dir..'/'..name);local groups={};local pals={}
        local members={};for _,entry in ipairs(list) do members[entry.name:upper()]=true end
        local root={id='city_archive_'..ai,name=name,type='category',children={}};tree[#tree+1]=root
        for i,e in ipairs(list) do
            e.id='city_'..ai..'_'..i
            if e.name:upper():match('%.CPA$') and e.size==e.unpacked then pals[e.name:upper()]=e.id end
            entries[e.id]=e
        end
        local function add(group,node)
            if not groups[group] then
                groups[group]={id=root.id..'_'..group,name=group,type='category',children={}}
                root.children[#root.children+1]=groups[group]
            end
            local dest=groups[group].children;dest[#dest+1]=node
        end
        for _,e in ipairs(list) do
            local ext=e.name:upper():match('%.([^.]*)$') or ''
            local typ,group='text','Data and 3D Models'
            e.kind='data'
            if e.size==e.unpacked then
                local stem=e.name:upper():gsub('%.[^.]*$','')
                e.pal=pals[stem..'.CPA'] or pals[(stem:match('^%d%d%d') or '')..'SCENE.CPA']
                if not e.pal and stem:match('^CIFONT') then e.pal=pals['DEFAULTS.CPA'] end
                if ext=='CPA' then e.kind='palette';typ='palette';group='Palettes'
                elseif ext=='TMM' then e.kind='model';e.has_skeleton=members[stem..'.SKL'];typ='model';group='3D Models'
                elseif ext=='CRP' then e.kind='crp';typ='image';group='Pictures and Fonts'
                elseif ext=='ZBF' then e.kind='zbf';typ='image';group='Depth Masks'
                elseif ext:match('^TX[FEGIS]$') then e.kind='dialogue';group='Dialogue'
                elseif ext=='FRM' then
                    local atlas=frm(bytes(e));e.kind='atlas';e.atlas=atlas
                    local nodes={{id=e.id,name='Texture atlas',type='image'}}
                    for i,r in ipairs(atlas.rects) do
                        local id=e.id..'_crop_'..i
                        entries[id]={file=e.file,offset=e.offset,size=e.size,name=e.name,kind='crop',pal=e.pal,atlas=atlas,rect=r}
                        nodes[#nodes+1]={id=id,name=string.format('Rectangle %d (%dx%d)',i-1,r.w,r.h),type='image'}
                    end
                    add('Textures and Sprites',{id=e.id..'_bank',name=e.name,type='category',children=nodes})
                elseif ext=='SNW' then
                    local clips=snw(bytes(e));local nodes={};e.kind='data'
                    for i,c in ipairs(clips) do
                        local id=e.id..'_clip_'..i
                        entries[id]={file=e.file,offset=e.offset+c.offset,size=c.size,name=e.name..' clip '..(i-1),kind='pcm'}
                        nodes[#nodes+1]={id=id,name='Effect '..(i-1),type='sound'}
                    end
                    nodes[#nodes+1]={id=e.id,name='Bank metadata',type='text'}
                    add('Sound Effects',{id=e.id..'_bank',name=e.name,type='category',children=nodes})
                end
            end
            if ext~='FRM' and ext~='SNW' or e.size~=e.unpacked then
                add(group,{id=e.id,name=e.name,type=typ})
            end
        end
    end
    local function loose(folder,depth)
        local nodes={};local names=list_files(folder);table.sort(names)
        for _,name in ipairs(names) do
            if name:sub(1,1)~='.' then
                local full=folder..'/'..name
                local f=file_open(full)
                if f then
                    local size=file_size(f);file_close(f)
                    local id='city_file_'..full:sub(#path+2);local iswav=name:upper():match('%.WAV$')
                    entries[id]={file=full,size=size,name=name,kind=iswav and 'wav' or 'data'}
                    nodes[#nodes+1]={id=id,name=name,type=iswav and 'sound' or 'text'}
                elseif depth>0 then
                    local children=loose(full,depth-1)
                    if #children>0 then nodes[#nodes+1]={id='city_folder_'..full,name=name,type='category',children=children} end
                end
            end
        end
        return nodes
    end
    for _,name in ipairs({'LANGS','GLOBS','MOVS'}) do
        local folder=child(path,name)
        if folder then tree[#tree+1]={id='city_loose_'..name,name=name=='MOVS' and 'Movies (metadata)' or name..' Speech',type='category',children=loose(folder,2)} end
    end
    local misc={}
    for _,name in ipairs(list_files(path)) do
        if name:upper():match('^TEXTDATA%.TX[FEGIS]$') or name:upper()=='TRACK2.RAW' then
            local full=path..'/'..name;local f=assert(file_open(full));local size=file_size(f);file_close(f)
            local id='city_file_'..name
            entries[id]={file=full,size=size,name=name,kind=name:upper():match('^TEXTDATA') and 'text' or 'data'}
            misc[#misc+1]={id=id,name=name,type='text'}
        end
    end
    if #misc>0 then tree[#tree+1]={id='city_misc',name='Installer Text and CD Music Metadata',type='category',children=misc} end
    return tree
end
function engine.get_resources(path) return build(path) end
local function model_names()
    local names={}
    for _,e in pairs(cache.entries) do
        if e.kind~='crop' and e.kind~='pcm' then names[e.name:upper()]=e end
    end
    return names
end
function engine.default_palette(path,id)
    build(path);local e=cache.entries[id]
    if e and e.kind=='model' then
        local names=model_names()
        local pal=names[(e.name:match('^(%d%d%d)') or '101')..'SCENE.CPA'] or names['MIETTE.CPA']
        return pal and pal.id
    end
    if e and (e.kind=='crp' or e.kind=='atlas' or e.kind=='crop') then return e.pal end
end
function engine.load_resource(path,id,paletteId,textureId)
    build(path)
    if id=='city_help' then return {type='text',text=instructions} end
    local e=cache.entries[id];if not e then return nil end
    local desc=e.name
    if e.kind=='model' then
        if not model_decode_city or not model_set_textures or not model_pose_city then
            return {type='text',text='The running app is older than the model preview scripts. Rebuild and restart Adventure Explorer to open 3D models.',description=desc}
        end
        local ok,result=pcall(function()
            local names=model_names();local model=model_decode_city(bytes(e))
            local stem=e.name:upper():gsub('%.TMM$','')
            local pose='Static mesh'
            if e.has_skeleton then
                local skl,env,ani=names[stem..'.SKL'],names[stem..'.ENV'],names[stem..'.ANI']
                assert(skl and env and ani,'Missing character skeleton, envelope or animation')
                model_pose_city(model,bytes(skl),bytes(env),bytes(ani));pose='First stored character pose'
            end
            local options={}
            for _,entry in pairs(cache.entries) do
                if entry.kind=='atlas' then options[#options+1]={id=entry.id,name=entry.name,type='image'} end
            end
            table.sort(options,function(a,b) return a.name<b.name end)
            local room=e.name:match('^(%d%d%d)')
            local automatic=names[(room or '')..'SCTEX.FRM'] or names['CITEXFR.FRM']
            local chosen=textureId and cache.entries[textureId] or automatic
            local status='Untextured'
            if textureId~='__none__' and chosen and chosen.kind=='atlas' then
                local pal=gray
                local pe=cache.entries[paletteId or engine.default_palette(path,id) or '']
                if pe and pe.kind=='palette' then pal=palette(bytes(pe)) end
                local miette=names['MIETTE.CPA']
                if miette and (not paletteId or paletteId==engine.default_palette(path,id)) then local fixed=palette(bytes(miette));for i=208*3+1,768 do pal[i]=fixed[i] end end
                local a=chosen.atlas;local raw=bytes(chosen);local pixels={}
                for i=1,a.w*a.h do pixels[i]=raw:byte(40+i) end
                model_set_textures(model,{{slot=0,image=image_create_indexed(a.w,a.h,pixels,pal)}})
                status=chosen.name
            end
            return {type='model',model=model,texture_options=options,texture_id=textureId,
                description=desc..' - '..pose..'; texture: '..status}
        end)
        if ok then return result end
        return {type='text',text=desc..'\nUnable to preview model: '..tostring(result),description=desc}
    elseif e.kind=='pcm' then
        -- CITE.EXE file offset 0x28680: AIL_set_sample_type(handle,0,0),
        -- then 0x28691: AIL_set_sample_playback_rate(handle,11025).
        return {type='sound',sound=sound_create_pcm(11025,8,1,false,bytes(e)),description=desc..' - unsigned 8-bit mono, 11025 Hz'}
    elseif e.kind=='wav' then return {type='sound',sound=wav(bytes(e)),description=desc}
    elseif e.kind=='dialogue' then return {type='text',text=dialogue(bytes(e)),description=desc}
    elseif e.kind=='text' then return {type='text',text=text850(bytes(e)),description=desc} end
    if e.kind=='data' then
        local s=bytes(e,1024)
        local lines={desc..'\n'..e.size..' stored bytes; '..(e.unpacked or e.size)..' unpacked bytes.',
            'Metadata/hex preview. Skeleton poses, animation, scripts, movie playback and CD music are not interpreted.'}
        for p=1,#s,16 do
            local row=s:sub(p,p+15);local hex={};for i=1,#row do hex[i]=string.format('%02X',row:byte(i)) end
            lines[#lines+1]=string.format('%08X  %-47s  %s',p-1,table.concat(hex,' '),row:gsub('[^ -~]','.'))
        end
        return {type='text',text=table.concat(lines,'\n'),description=desc}
    end
    local pal=gray;local chosen=cache.entries[paletteId or ''] or cache.entries[e.pal or '']
    if chosen and chosen.kind=='palette' and e.kind~='zbf' then pal=palette(bytes(chosen)) end
    local s=bytes(e);local w,h,pixels
    if e.kind=='palette' then
        pal=palette(s);w,h,pixels=128,128,{}
        for y=0,127 do for x=0,127 do pixels[#pixels+1]=floor(y/8)*16+floor(x/8) end end
    elseif e.kind=='crp' then w,h,pixels=crp(s)
    elseif e.kind=='zbf' then w,h,pixels=zbf(s);desc=desc..' - grayscale depth values'
    else
        local a=e.atlas;local r=e.rect or {x=0,y=0,w=a.w,h=a.h}
        w,h,pixels=r.w,r.h,{}
        for y=0,h-1 do for x=0,w-1 do pixels[#pixels+1]=s:byte(41+(r.y+y)*a.w+r.x+x) end end
        desc=desc..' - stored texture pixels; no 3D scene composition'
    end
    return {type='image',image=image_create_indexed(w,h,pixels,pal),description=desc}
end
return engine

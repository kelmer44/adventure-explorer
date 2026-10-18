-- Interplay DOS Star Trek archives. Format research: ScummVM startrek
-- resource.cpp, lzss.cpp, bitmap.cpp, actors.cpp; verified against both games.
local engine={id='startrek',name='Star Trek',version='1.0',
    description='Star Trek: 25th Anniversary / Judgment Rites (DOS)'}
local floor=math.floor
local function u16(s,p) assert(p>=1 and p+1<=#s,'Truncated word');return s:byte(p)+256*s:byte(p+1) end
local function s16(s,p) local n=u16(s,p);return n>=32768 and n-65536 or n end
local function u24(s,p) return u16(s,p)+65536*assert(s:byte(p+2),'Truncated offset') end
local function read(path,off,size)
    local f=file_open(path);assert(f,'Cannot open '..path)
    local d=file_read(f,off or 0,size or file_size(f));file_close(f);return d
end
local function lzss(s,n)
    assert(n>=0 and n<=65535,'Invalid expanded size')
    local out,hist={},{};local p,b=1,0
    local function put(v) assert(#out<n,'LZSS output overflow');out[#out+1]=v;hist[b]=v;b=(b+1)%4096 end
    while #out<n do
        local flags=assert(s:byte(p),'Truncated LZSS flags');p=p+1
        for i=0,7 do
            if #out==n then break end
            if floor(flags/2^i)%2==1 then put(assert(s:byte(p),'Truncated LZSS literal'));p=p+1
            else
                local t=u16(s,p);p=p+2;local src=(b-floor(t/16))%4096
                for j=0,t%16+2 do put(hist[(src+j)%4096] or 0) end
            end
        end
    end
    local chunks={};for i=1,#out,2048 do chunks[#chunks+1]=string.char(table.unpack(out,i,math.min(i+2047,#out))) end
    return table.concat(chunks)
end
local function bitmap(s,offset)
    offset=offset or 0
    assert(#s>=offset+8,'Empty or truncated bitmap')
    local w,h=u16(s,offset+5),u16(s,offset+7)
    assert(w>0 and h>0 and w*h<=64000 and #s==offset+8+w*h,'Invalid bitmap dimensions')
    return {w=w,h=h,x=s16(s,offset+1),y=s16(s,offset+3),data=s:sub(offset+9)}
end
local function palette(s)
    assert(#s>=768,'Truncated palette');local p={}
    for i=1,768 do local v=s:byte(i);assert(v<64,'Invalid VGA palette');p[i]=v*4 end
    return p
end
local function text(s)
    -- The supplied Spanish DOS editions store Western text in Latin-1.
    return (s:gsub('%z','\n'):gsub('[\128-\255]',function(c)
        local b=c:byte();return string.char(192+floor(b/64),128+b%64)
    end))
end
local function hex(s)
    local lines={};for p=1,math.min(#s,4096),16 do
        local row={};for q=p,math.min(p+15,#s) do row[#row+1]=string.format('%02X',s:byte(q)) end
        lines[#lines+1]=string.format('%06X  %s',p-1,table.concat(row,' '))
    end
    if #s>4096 then lines[#lines+1]='[Hex preview limited to 4096 bytes]' end
    return table.concat(lines,'\n')
end
local current,items,tree,byname,pals
local function payload(path,e)
    if e.external then return read(path..'/'..e.external) end
    local h=read(path..'/'..e.pack..'.001',e.offset,4)
    assert(#h==4,'Truncated resource header');local n,z=u16(h,1),u16(h,3)
    local s=read(path..'/'..e.pack..'.001',e.offset+4,z)
    assert(#s==z,'Truncated packed resource');return lzss(s,n)
end
function engine.detect(path)
    return file_exists(path..'/DATA.DIR') and file_exists(path..'/DATA.001') and
        file_exists(path..'/DATA.RUN') and (file_exists(path..'/STARTREK.EXE') or file_exists(path..'/RITES.EXE'))
end
local function index(path)
    if current==path then return end
    items,tree,byname,pals={},{},{},{}
    local groups={};local entries={}
    local function add(cat,label,id,name,kind,e)
        local g=groups[cat]
        if not g then g={id=cat,name=label,type='category',children={}};groups[cat]=g;tree[#tree+1]=g end
        local pack=e.pack or 'UNCOMP';local key=cat..'/'..pack
        local sub=groups[key];if not sub then sub={id=key,name=pack,type='category',children={}};groups[key]=sub;g.children[#g.children+1]=sub end
        items[id]={kind=kind,e=e};sub.children[#sub.children+1]={id=id,name=name,type=kind=='palette' and 'palette' or
            (kind=='bitmap' or kind=='background' or kind=='mask') and 'image' or kind=='animation' and 'animation' or
            kind=='sound' and 'sound' or kind=='music' and 'midi' or 'text'}
        return items[id]
    end
    local files=list_files(path);table.sort(files)
    for _,file in ipairs(files) do
        local pack=file:match('^(.*)%.[Dd][Ii][Rr]$')
        if pack and file_exists(path..'/'..pack..'.001') and file_exists(path..'/'..pack..'.RUN') then
            local d,r=read(path..'/'..file),read(path..'/'..pack..'.RUN')
            assert(#d%14==0,'Invalid archive directory size')
            for p=1,#d,14 do
                local base=d:sub(p,p+7):match('^[^%z]*');local ext=d:sub(p+8,p+10):match('^[^%z]*')
                if base~='' then
                    local v=u24(d,p+11);local count,offset=1,v;local rp
                    if v>=8388608 then count=floor(v/65536)%128;rp=v%65536+1;offset=u24(r,rp);assert(count>0,'Empty run') end
                    local set={}
                    for i=0,count-1 do
                        local h=read(path..'/'..pack..'.001',offset,4)
                        assert(#h==4,'Invalid resource offset')
                        local e={pack=pack,name=(base..'.'..ext):upper(),base=base:upper(),ext=ext:upper(),
                            offset=offset,size=u16(h,1),packed=u16(h,3),frame=i,count=count,set=set}
                        e.id=pack..':'..e.name..':'..i;set[#set+1]=e;entries[#entries+1]=e
                        if rp and i<count-1 then offset=offset+u16(r,rp+3+i*2) end
                    end
                    byname[pack..':'..(base..'.'..ext):upper()]=set
                end
            end
        end
    end
    for _,name in ipairs(list_files(path..'/UNCOMP')) do
        local ext=name:upper():match('%.([A-Z0-9]+)$')
        if ext then entries[#entries+1]={external='UNCOMP/'..name,pack='UNCOMP',name=name:upper(),base=name:upper():gsub('%.[^.]+$',''),ext=ext,id='UNCOMP:'..name:upper(),frame=0,count=1} end
    end
    local function find(e,name)
        return byname[e.pack..':'..name] or byname['DATA:'..name]
    end
    for _,e in ipairs(entries) do
        local name=e.name..(e.count>1 and string.format(' / frame %02d',e.frame) or '')
        add('data','Resource Data (metadata and hex)','data:'..e.id,name,'data',e)
        if e.ext=='PAL' or e.ext=='BGD' then
            local id='pal:'..e.id;local r=add('palettes','Palettes',id,name..(e.ext=='BGD' and ' (embedded)' or ''),'palette',e)
            pals[id]=r
        end
        if (e.ext=='BMP' or e.ext=='SHP' or e.ext=='BM') and e.name~='STARS.SHP' and e.size~=0 then
            local screen=e.size==64008
            add(screen and 'backgrounds' or 'sprites',screen and 'Backgrounds and Screens' or 'Sprites',e.id,name,'bitmap',e)
            if e.count>1 and e.frame==0 then add('animations','Animation Previews','run:'..e.id,e.name..' (stored frames)','animation',e).run=e.set end
        elseif e.ext=='BGD' then add('backgrounds','Backgrounds and Screens',e.id,name,'background',e)
        elseif e.ext=='PRI' then add('masks','Priority Masks',e.id,name,'mask',e)
        elseif e.ext=='TXT' or e.ext=='DB' or e.ext=='DSC' then add('text','Text',e.id,name,'text',e)
        elseif e.ext=='VOC' then add('sounds','Sound and Speech',e.id,name,'sound',e)
        elseif e.ext=='MT' or e.ext=='GM' then
            local s=payload(path,e)
            -- Expose each XMIDI EVNT separately: the host converter plays one sequence.
            local sequence=0
            local function chunks(a,b)
                local p=a
                while p+7<=b do
                    local tag=s:sub(p,p+3);local n=s:byte(p+4)*16777216+s:byte(p+5)*65536+s:byte(p+6)*256+s:byte(p+7)
                    assert(p+7+n<=b,'Truncated XMIDI chunk')
                    if tag=='EVNT' then
                        sequence=sequence+1
                        local id='music:'..e.id..':'..p
                        add('music','Music (XMIDI sequences)',id,name..' / sequence '..sequence,'music',e).evnt=s:sub(p,p+7+n)
                    elseif tag=='FORM' or tag=='CAT ' then chunks(p+12,p+7+n) end
                    p=p+8+n+n%2
                end
            end
            chunks(1,#s)
        end
    end
    -- Resolve ordinary ANM frame names, including sequential filename aliases.
    local function resolve(e,name)
        name=name:upper():match('^[^%z ]+') or '';name=name:gsub('%.BMP$','')
        local set=find(e,name..'.BMP');if set then return set[1] end
        for i=#name,1,-1 do
            local c=name:byte(i)
            if i==#name and ((c>=49 and c<=57) or (c>=66 and c<=90)) then
                local prev=name:sub(1,-2)..string.char(c-1)
                local n=1
                while n<128 do
                    set=find(e,prev..'.BMP');if set then return set[n+1] end
                    c=prev:byte(-1);if c==48 or c==65 then break end
                    prev=prev:sub(1,-2)..string.char(c-1);n=n+1
                end
            end
            break
        end
    end
    for _,e in ipairs(entries) do
        if e.ext=='ANM' then
            local s=payload(path,e);local frames={};local complete=#s>0 and #s%22==0
            if complete then for p=1,#s,22 do
                local ref=resolve(e,s:sub(p,p+9))
                if not ref then complete=false;break end
                frames[#frames+1]={e=ref,x=s16(s,p+10),y=s16(s,p+12),ticks=u16(s,p+16)}
            end end
            if complete then add('animations','Animation Previews','anm:'..e.id,e.name..' (record order)','animation',e).frames=frames end
        end
    end
    local backgrounds={}
    for _,candidate in ipairs(entries) do
        if candidate.ext=='BGD' and candidate.frame==0 then
            backgrounds[candidate.pack]=backgrounds[candidate.pack] or {}
            table.insert(backgrounds[candidate.pack],candidate)
        end
    end
    for id,r in pairs(items) do
        local e=r.e
        if r.kind=='bitmap' or r.kind=='animation' then
            local same=find(e,e.base..'.PAL');local bg=find(e,e.base..'.BGD')
            if not bg then
                local best=1
                for _,candidate in ipairs(backgrounds[e.pack] or {}) do
                    if #candidate.base>best and e.base:sub(1,#candidate.base)==candidate.base then
                        bg={candidate};best=#candidate.base
                    end
                end
            end
            local shared=find(e,'PALETTE.PAL')
            if e.base:match('^BRID') or e.base:match('^TITLE') or e.ext=='SHP' then shared=find(e,'BRIDGE.PAL') or shared end
            if e.base:match('^GOLD') or e.base=='LOGO' then shared=find(e,'GOLD.PAL') or shared end
            local pr=same or bg
            if not pr and e.pack~='DATA' then
                if backgrounds[e.pack] then pr={backgrounds[e.pack][1]} end
            end
            pr=pr or shared
            r.pal=pr and ('pal:'..pr[1].id) or nil
            r.paletteSource=same and 'matching palette' or bg and 'matching background palette' or 'preview palette (scene may differ)'
        elseif r.kind=='background' then r.pal='pal:'..e.id end
    end
    current=path
end
function engine.get_resources(path) index(path);return tree end
function engine.default_palette(path,id) index(path);return items[id] and items[id].pal end
local function image(pic,pal,transparent)
    local px={}
    for i=1,#pic.data do px[i]=pic.data:byte(i) end
    return image_create_indexed(pic.w,pic.h,px,pal,transparent and 0 or nil)
end
function engine.load_resource(path,id,override)
    index(path);local r=items[id];if not r then return nil end
    local e=r.e;local ok,s=pcall(payload,path,e)
    local desc=e.pack..' / '..e.name..' / frame '..(e.frame or 0)
    if not ok then return {type='text',text='Cannot decode resource: '..s,description=desc..' / damaged resource'} end
    if r.kind=='data' then return {type='text',text=desc..'\n'..#s..' unpacked bytes\n'..
        (e.offset and string.format('Archive offset %d; %d packed bytes\n',e.offset,e.packed) or 'External file\n')..
        (e.ext=='ANM' and 'ANM records reference bitmaps; unresolved/virtual actor frames and scripted branches are not replayed.\n' or '')..'\n'..hex(s),description=desc} end
    if r.kind=='text' then return {type='text',text=text(s),description=desc..' / Latin-1 text'} end
    if r.kind=='sound' then return {type='sound',sound=sound_create_encoded(s),description=desc} end
    if r.kind=='music' then return {type='midi',midi=midi_create_from_xmi(r.evnt),description=desc..' / XMIDI sequence; original MT-32 mapping retained'} end
    local pal
    if r.kind=='mask' then pal={};for i=0,255 do for j=1,3 do pal[#pal+1]=math.min(255,i*17) end end
    else
        local pr=r.kind=='palette' and r or pals[override or r.pal]
        assert(pr,'No palette available');pal=palette(payload(path,pr.e))
        if r.kind~='palette' then desc=desc..' / '..(override or r.pal)..' / '..(override and override~=r.pal and 'manual override' or r.paletteSource or 'embedded palette') end
    end
    if r.kind=='palette' then
        local px={};for y=0,127 do for x=0,127 do px[#px+1]=floor(y/8)*16+floor(x/8) end end
        return {type='image',image=image_create_indexed(128,128,px,pal),palette=pal,description=desc}
    elseif r.kind=='animation' then
        local frames=r.frames or {};if r.run then for _,ref in ipairs(r.run) do frames[#frames+1]={e=ref,x=0,y=0} end end
        local pics={};local minx,miny,maxx,maxy=0,0,0,0
        for _,f in ipairs(frames) do
            local pic=bitmap(payload(path,f.e));pic.left=f.x-pic.x;pic.top=f.y-pic.y
            minx=math.min(minx,pic.left);miny=math.min(miny,pic.top);maxx=math.max(maxx,pic.left+pic.w);maxy=math.max(maxy,pic.top+pic.h);pics[#pics+1]=pic
        end
        local w,h=maxx-minx,maxy-miny;assert(w*h<=1000000,'Animation canvas too large')
        local handles={};for _,pic in ipairs(pics) do
            local px={};for i=1,w*h do px[i]=0 end
            for y=0,pic.h-1 do for x=0,pic.w-1 do px[(y+pic.top-miny)*w+x+pic.left-minx+1]=pic.data:byte(y*pic.w+x+1) end end
            handles[#handles+1]=image_create_indexed(w,h,px,pal,0)
        end
        return {type='animation',animation=animation_create(handles,100),description=desc..' / stored record order, 100 ms preview cadence; no scripted branches or game timing'}
    elseif r.kind=='mask' then
        assert(#s==32000,'Invalid priority mask');local px={}
        for i=1,#s do local b=s:byte(i);px[#px+1]=floor(b/16);px[#px+1]=b%16 end
        return {type='image',image=image_create_indexed(320,200,px,pal),description=desc..' / high nibble first'}
    end
    local pic=bitmap(s,r.kind=='background' and 768 or 0)
    return {type='image',image=image(pic,pal,r.kind=='bitmap' and pic.w*pic.h~=64000),palette=pal,
        description=desc..string.format(' / %dx%d / origin %d,%d',pic.w,pic.h,pic.x,pic.y)}
end
engine._debug={lzss=lzss,bitmap=bitmap,palette=palette,text=text}
return engine

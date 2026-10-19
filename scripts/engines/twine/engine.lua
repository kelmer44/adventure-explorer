-- Little Big Adventure 1/2. Format references are recorded in engine-sources.md.
local engine={id='twine',name='Little Big Adventure 1 & 2',version='1.0',
    description='Little Big Adventure (1994) / Twinsen\'s Odyssey (1997, Adeline)'}
local floor=math.floor
local function u16(s,p) assert(p>=1 and p+1<=#s,'Truncated word');return s:byte(p)+s:byte(p+1)*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function read(path,offset,n)
    local f=assert(file_open(path),'Cannot open '..path)
    local s=file_read(f,offset or 0,n or file_size(f));file_close(f);return s
end
local function unpack_hqr(s,n,mode)
    assert(n>=0 and n<=16777216,'Oversized HQR entry')
    if mode==0 then assert(#s>=n,'Truncated raw entry');return s:sub(1,n) end
    assert(mode==1 or mode==2,'Unsupported HQR compression')
    local out={};local p=1
    while #out<n do
        local flags=assert(s:byte(p),'Truncated HQR flags');p=p+1
        for bit=0,7 do
            if floor(flags/2^bit)%2==1 then out[#out+1]=assert(s:byte(p),'Truncated literal');p=p+1
            else
                local v=u16(s,p);p=p+2;local count=v%16+mode+1;local distance=floor(v/16)+1
                assert(distance<=#out and #out+count<=n,'Invalid HQR reference')
                for _=1,count do out[#out+1]=out[#out-distance+1] end
            end
            if #out==n then break end
        end
    end
    local chunks={}
    for i=1,#out,4096 do chunks[#chunks+1]=string.char(table.unpack(out,i,math.min(i+4095,#out))) end
    return table.concat(chunks)
end
local function archive(path,name)
    local f=assert(file_open(path..'/'..name));local size=file_size(f)
    local h=file_read(f,0,4);local first=u32(h,1)
    assert(first>=4 and first%4==0 and first<=size and first<=1048576,'Invalid HQR directory')
    local offsets=file_read(f,0,first);local entries={}
    -- Some archives include an EOF sentinel, others only real offsets. Zero slots are holes.
    for i=0,first/4-1 do
        local o=u32(offsets,i*4+1)
        if o>=first and o+10<=size then
            local head=file_read(f,o,10);local n,c,m=u32(head,1),u32(head,5),u16(head,9)
            assert(n<=16777216 and m<=2 and o+10+c<=size,'Invalid HQR entry '..name..':'..i)
            if n>0 then entries[i]={file=name,index=i,offset=o,size=n,packed=c,mode=m} end
        else assert(o==0 or o==size,'Invalid archive offset') end
    end
    local positions={size};for _,e in pairs(entries) do positions[#positions+1]=e.offset end;table.sort(positions)
    local ends={};for i=1,#positions-1 do if positions[i]<positions[i+1] then ends[positions[i]]=positions[i+1] end end
    for _,e in pairs(entries) do e.boundary=ends[e.offset] or size end
    file_close(f);return entries,size
end
local function payload(path,e)
    return unpack_hqr(read(path..'/'..e.file,e.offset+10,e.packed),e.size,e.mode)
end
local function sprite(s,offset)
    local p=(offset or u32(s,1))+1
    local w,h,x,y=s:byte(p,p+3);assert(y and w>0 and h>0,'Invalid sprite header');p=p+4
    local px={};for i=1,w*h do px[i]=0 end
    for row=0,h-1 do
        local runs=assert(s:byte(p),'Truncated sprite row');p=p+1;local col=0
        for _=1,runs do
            local b=assert(s:byte(p),'Truncated sprite run');p=p+1
            local n,t=b%64+1,floor(b/64);assert(col+n<=w,'Sprite row overflow')
            if t==1 then
                for i=0,n-1 do px[row*w+col+i+1]=assert(s:byte(p),'Truncated sprite pixels');p=p+1 end
            elseif t>=2 then
                local v=assert(s:byte(p),'Truncated sprite fill');p=p+1
                for i=0,n-1 do px[row*w+col+i+1]=v end
            end
            col=col+n
        end
    end
    return {w=w,h=h,x=x,y=y,px=px}
end
local function palette(s)
    assert(#s==768,'Invalid RGB palette');local p={};for i=1,768 do p[i]=s:byte(i) end;return p
end
-- Text is DOS code page 850, including the supplied Spanish edition.
local cp850={
    [128]='Ç',
    [129]='ü',
    [130]='é',
    [131]='â',
    [132]='ä',
    [133]='à',
    [134]='å',
    [135]='ç',
    [136]='ê',
    [137]='ë',
    [138]='è',
    [139]='ï',
    [140]='î',
    [141]='ì',
    [142]='Ä',
    [143]='Å',
    [144]='É',
    [145]='æ',
    [146]='Æ',
    [147]='ô',
    [148]='ö',
    [149]='ò',
    [150]='û',
    [151]='ù',
    [152]='ÿ',
    [153]='Ö',
    [154]='Ü',
    [155]='ø',
    [156]='£',
    [157]='Ø',
    [158]='×',
    [159]='ƒ',
    [160]='á',
    [161]='í',
    [162]='ó',
    [163]='ú',
    [164]='ñ',
    [165]='Ñ',
    [166]='ª',
    [167]='º',
    [168]='¿',
    [169]='®',
    [170]='¬',
    [171]='½',
    [172]='¼',
    [173]='¡',
    [174]='«',
    [175]='»',
    [176]='░',
    [177]='▒',
    [178]='▓',
    [179]='│',
    [180]='┤',
    [181]='Á',
    [182]='Â',
    [183]='À',
    [184]='©',
    [185]='╣',
    [186]='║',
    [187]='╗',
    [188]='╝',
    [189]='¢',
    [190]='¥',
    [191]='┐',
    [192]='└',
    [193]='┴',
    [194]='┬',
    [195]='├',
    [196]='─',
    [197]='┼',
    [198]='ã',
    [199]='Ã',
    [200]='╚',
    [201]='╔',
    [202]='╩',
    [203]='╦',
    [204]='╠',
    [205]='═',
    [206]='╬',
    [207]='¤',
    [208]='ð',
    [209]='Ð',
    [210]='Ê',
    [211]='Ë',
    [212]='È',
    [213]='ı',
    [214]='Í',
    [215]='Î',
    [216]='Ï',
    [217]='┘',
    [218]='┌',
    [219]='█',
    [220]='▄',
    [221]='¦',
    [222]='Ì',
    [223]='▀',
    [224]='Ó',
    [225]='ß',
    [226]='Ô',
    [227]='Ò',
    [228]='õ',
    [229]='Õ',
    [230]='µ',
    [231]='þ',
    [232]='Þ',
    [233]='Ú',
    [234]='Û',
    [235]='Ù',
    [236]='ý',
    [237]='Ý',
    [238]='¯',
    [239]='´',
    [240]='­',
    [241]='±',
    [242]='‗',
    [243]='¾',
    [244]='¶',
    [245]='§',
    [246]='÷',
    [247]='¸',
    [248]='°',
    [249]='¨',
    [250]='·',
    [251]='¹',
    [252]='³',
    [253]='²',
    [254]='■',
    [255]=' ',
}
local function text(s) return (s:gsub('[\128-\255]',function(c) return cp850[c:byte()] end)) end
local function hex(s)
    local lines={};for i=1,math.min(#s,2048),16 do
        local row={};for j=i,math.min(i+15,#s) do row[#row+1]=string.format('%02X',s:byte(j)) end
        lines[#lines+1]=string.format('%06X  %s',i-1,table.concat(row,' '))
    end
    if #s>2048 then lines[#lines+1]='[Preview limited to 2048 bytes]' end
    return table.concat(lines,'\n')
end
local current,items,tree,packs,lba2,bkg
function engine.detect(path)
    return file_exists(path..'/RESS.HQR') and file_exists(path..'/BODY.HQR') and file_exists(path..'/SCENE.HQR') and
        (file_exists(path..'/LBA_GRI.HQR') or file_exists(path..'/LBA_BKG.HQR'))
end
local function index(path)
    if current==path then return end
    current=nil;items,tree,packs={},{},{};lba2=file_exists(path..'/LBA_BKG.HQR');bkg=nil
    local groups={}
    local function add(cat,label,kind,e,suffix)
        local g=groups[cat];if not g then g={id=cat,name=label,type='category',children={}};tree[#tree+1]=g;groups[cat]=g end
        local key=cat..'/'..e.file
        local sub=groups[key];if not sub then sub={id=key,name=e.file,type='category',children={}};g.children[#g.children+1]=sub;groups[key]=sub end
        local id=cat..':'..e.file..':'..e.index..(suffix or '')
        local r={kind=kind,e=e,pal='palettes:RESS.HQR:0'};items[id]=r
        sub.children[#sub.children+1]={id=id,name=string.format('%04d',e.index)..(suffix or ''),type=kind}
        return r,id
    end
    local files={}
    for _,name in ipairs(list_files(path)) do
        local ext=name:upper():match('%.([A-Z0-9]+)$')
        if ext=='HQR' or ext=='ILE' or ext=='OBL' then files[#files+1]=name end
    end
    for _,dir in ipairs({'VOX'}) do
        for _,name in ipairs(list_files(path..'/'..dir)) do
            if name:upper():match('%.VOX$') or name:upper():match('%.HQR$') then files[#files+1]=dir..'/'..name end
        end
    end
    table.sort(files)
    for _,name in ipairs(files) do packs[name:upper()]=archive(path,name) end
    if packs['LBA_BKG.HQR'] then
        local s=payload(path,packs['LBA_BKG.HQR'][0])
        bkg={grid=u16(s,1),fragment=u16(s,3),library=u16(s,5),brick=u16(s,7),count=u16(s,9)}
    end
    for _,name in ipairs(files) do
        local upper=name:upper();local es=packs[upper];local indices={}
        for i in pairs(es) do indices[#indices+1]=i end;table.sort(indices)
        for _,i in ipairs(indices) do
            local e=es[i];add('data','Resource Data (metadata and hex)','text',e)
            if lba2 and (upper=='BODY.HQR' or upper=='OBJFIX.HQR' or upper:match('%.OBL$')) then
                local body=payload(path,e)
                if u32(body,65)>0 or u32(body,73)>0 or u32(body,81)>0 then add('models','3D Models','model',e) end
            elseif (upper=='RESS.HQR' or upper=='SCREEN.HQR' or upper=='HOLOMAP.HQR') and e.size==768 then
                add('palettes','Palettes','palette',e)
            elseif (upper=='RESS.HQR' or upper=='SCREEN.HQR') and e.size==307200 then
                local r=add('screens','Screens','image',e);r.screen=true
                if es[i+1] and es[i+1].size==768 then r.pal='palettes:'..name..':'..(i+1) end
            elseif upper=='SPRITES.HQR' or (upper=='RESS.HQR' and not lba2 and i==4) then
                add('sprites','Sprites','image',e)
                local data=payload(path,e);local second=u32(data,5)
                if second>=8 and second+8<#data then add('sprites','Sprites','image',e,' / second image').spriteOffset=second end
            elseif upper=='LBA_BRK.HQR' or (upper=='LBA_BKG.HQR' and i>=bkg.brick and i<bkg.brick+bkg.count) then
                add('bricks','Scenery Bricks','image',e).brick=true
            elseif upper=='LBA_GRI.HQR' or (upper=='LBA_BKG.HQR' and i>=bkg.grid and i<bkg.fragment) then
                add('grids','Isometric Scenery (static grids)','image',e).grid=true
            elseif upper=='TEXT.HQR' and i%2==1 and es[i-1] then
                add('dialogue','Dialogue and Interface Text','text',e).textIndex=es[i-1]
            elseif upper=='SAMPLES.HQR' or upper:match('%.VOX$') then
                -- Speech has additional HQR records between indexed offsets.
                local f=assert(file_open(path..'/'..name));local limit=e.boundary
                local o=e.offset;local part=0
                while o+10<=limit do
                    local h=file_read(f,o,10);local n,c,m=u32(h,1),u32(h,5),u16(h,9)
                    if n==0 or n>16777216 or c==0 or m>2 or o+10+c>limit then break end
                    local clip={file=name,index=i,offset=o,size=n,packed=c,mode=m}
                    local r=add(upper=='SAMPLES.HQR' and 'sounds' or 'speech',upper=='SAMPLES.HQR' and 'Sound Effects' or 'Speech','sound',clip,part>0 and (' / part '..part) or nil)
                    r.audio=true;o=o+10+c;part=part+1
                end
                file_close(f)
            elseif upper=='MIDI_MI.HQR' or upper=='MIDI_SB.HQR' then
                local s=payload(path,e)
                if s:sub(1,4)=='MThd' or s:sub(1,4)=='FORM' then add('music','Music','midi',e) end
            end
        end
    end
    for _,name in ipairs(list_files(path..'/MUSIC')) do
        if name:upper():match('%.WAV$') then
            local e={file='MUSIC/'..name,index=0,external=true};add('music','Music','sound',e).audio=true
        end
    end
    current=path
end
local function get(path,file,i) return payload(path,assert(packs[file] and packs[file][i],'Missing '..file..':'..i)) end
local function grid(path,e)
    local s=payload(path,e);local base=lba2 and 34 or 0
    local lib=get(path,lba2 and 'LBA_BKG.HQR' or 'LBA_BLL.HQR',lba2 and bkg.library+s:byte(1) or e.index)
    local layouts={};local n=u32(lib,1)/4;assert(n<=256 and n%1==0,'Invalid block library')
    for i=1,n do
        local p=u32(lib,(i-1)*4+1)+1;local x,y,z=lib:byte(p,p+2);assert(z,'Truncated layout')
        local bricks={};for j=1,x*y*z do bricks[j]=u16(lib,p+3+(j-1)*4+2) end;layouts[i]=bricks
    end
    local sprites={};local draws={};local minx,miny,maxx,maxy=0,0,0,0
    for z=0,63 do for x=0,63 do
        local p=base+u16(s,base+2*(z*64+x)+1)+1;local runs=assert(s:byte(p),'Invalid grid offset');p=p+1;local y=0
        for _=1,runs do
            local flag=assert(s:byte(p),'Truncated column');p=p+1
            local count,kind=flag%64+1,floor(flag/64);assert(y+count<=25,'Grid column overflow')
            local v;if kind>=2 then v=u16(s,p);p=p+2 end
            for _=1,count do
                local cell=v or 0;if kind==1 then cell=u16(s,p);p=p+2 end
                if cell%256>0 then
                    local layout=assert(layouts[cell%256],'Invalid layout reference')
                    local brick=assert(layout[floor(cell/256)+1],'Invalid block reference')
                    if brick>0 then
                        local pic=sprites[brick]
                        if not pic then pic=sprite(get(path,lba2 and 'LBA_BKG.HQR' or 'LBA_BRK.HQR',brick-1+(lba2 and bkg.brick or 0)),0);sprites[brick]=pic end
                        local left,top=(x-z)*24+pic.x,(x+z)*12-y*15+pic.y
                        draws[#draws+1]={pic=pic,x=left,y=top}
                        minx=math.min(minx,left);miny=math.min(miny,top);maxx=math.max(maxx,left+pic.w);maxy=math.max(maxy,top+pic.h)
                    end
                end
                y=y+1
            end
        end
    end end
    local w,h=maxx-minx,maxy-miny;assert(w>0 and h>0 and w*h<=8000000,'Empty or oversized grid')
    local px={};for i=1,w*h do px[i]=0 end
    for _,d in ipairs(draws) do local pic=d.pic
        for y=0,pic.h-1 do for x=0,pic.w-1 do local v=pic.px[y*pic.w+x+1]
            if v~=0 then px[(d.y-miny+y)*w+d.x-minx+x+1]=v end
        end end
    end
    return {w=w,h=h,px=px},#draws
end
function engine.get_resources(path) index(path);return tree end
function engine.default_palette(path,id) index(path);return items[id] and items[id].pal end
function engine.load_resource(path,id,override)
    index(path);local r=items[id];if not r then return nil end
    local e=r.e;local desc=e.file..' / entry '..e.index
    local ok,result=pcall(function()
        local s=e.external and read(path..'/'..e.file) or payload(path,e)
        if r.audio then
            if s:sub(2,19)=='reative Voice File' then s='C'..s:sub(2)
            elseif s:sub(2,4)=='IFF' then s='R'..s:sub(2) end
            local sound=assert(sound_create_encoded(s),'Unsupported audio encoding')
            return {type='sound',sound=sound,description=desc}
        elseif r.kind=='midi' then return {type='midi',midi=assert(midi_create_auto(s),'Unsupported MIDI'),description=desc}
        elseif r.textIndex then
            local ids=payload(path,r.textIndex);local lines={}
            for i=0,#ids/2-1 do
                local a,b=u16(s,i*2+1),u16(s,i*2+3)
                if lba2 then a=a+1 end
                assert(a<=b and b<=#s,'Invalid text offsets')
                lines[#lines+1]=string.format('[%d] %s',u16(ids,i*2+1),text(s:sub(a+1,b-1):match('^[^%z]*')))
                if b>=#s then break end
            end
            return {type='text',text=table.concat(lines,'\n\n'),description=desc..' / DOS CP850'}
        elseif r.kind=='text' then
            return {type='text',text=desc..'\n'..#s..' unpacked bytes\n'..string.format('Archive offset %d; %d packed bytes; mode %d\n\n',e.offset,e.packed,e.mode)..hex(s),description=desc}
        end
        local pal=palette(payload(path,assert(items[r.kind=='palette' and id or override or r.pal],'Unknown palette').e))
        if r.kind=='model' then
            if not model_decode_lba2 then return {type='text',text='Rebuild and restart Adventure Explorer to load LBA2 model previews.',description=desc} end
            local textureData=get(path,'RESS.HQR',6)
            if e.file:upper():match('%.OBL$') then
                local ile=e.file:upper():gsub('%.OBL$','.ILE')
                textureData=packs[ile] and get(path,ile,2) or nil
            end
            return {type='model',model=model_decode_lba2(s,pal,textureData),
                description=desc..' / rest pose; original palette and textures; spheres approximated as meshes; no animation or game material effects'}
        end
        local pic,transparent
        if r.kind=='palette' then
            pic={w=128,h=128,px={}};for y=0,127 do for x=0,127 do pic.px[#pic.px+1]=floor(y/8)*16+floor(x/8) end end
        elseif r.grid then
            local count;pic,count=grid(path,e);desc=desc..' / '..count..' bricks; static scenery, no actors or ceiling overlays'
        elseif r.screen then pic={w=640,h=480,px={}};for i=1,#s do pic.px[i]=s:byte(i) end
        else pic=sprite(s,r.brick and 0 or r.spriteOffset);transparent=0;desc=desc..string.format(' / origin %d,%d',pic.x,pic.y) end
        return {type='image',image=image_create_indexed(pic.w,pic.h,pic.px,pal,transparent),palette=pal,
            description=desc..' / '..(override or r.pal)}
    end)
    if ok then return result end
    return {type='text',text='Cannot decode resource: '..tostring(result),description=desc..' / decode diagnostic'}
end
engine._debug={unpack=unpack_hqr,sprite=sprite,palette=palette,text=text}
return engine

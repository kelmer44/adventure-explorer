-- Another World, original DOS BANKxx / MEMLIST.BIN edition.
-- Format reference: ScummVM engines/awe/{resource,unpack,video,script}.cpp.
local engine = {id='anotherworld', name='Another World',
    description='Another World / Out of This World (1991, Delphine Software), DOS', version='1.0'}
local floor = math.floor
local function u16(s,p)
    assert(p>=1 and p+1<=#s,'Truncated word')
    return s:byte(p)*256+s:byte(p+1)
end
local function u32(s,p) return u16(s,p)*65536+u16(s,p+2) end
local function read(path,off,size)
    local f=assert(file_open(path),'Cannot open '..path)
    local length=file_size(f);off=off or 0;size=size or length
    if off<0 or size<0 or off+size>length or size>1048576 then file_close(f);error('Invalid file range') end
    local s=size==0 and '' or file_read(f,off,size);file_close(f)
    assert(s and #s==size,'Truncated file');return s
end
local function directory(path)
    local s=read(path..'/MEMLIST.BIN');local es={}
    for p=1,#s,20 do
        if s:byte(p)==255 then assert(#es>0,'Empty MEMLIST');return es end
        assert(p+19<=#s and #es<178,'Invalid MEMLIST')
        local e={num=#es,kind=s:byte(p+1),bank=s:byte(p+7),offset=u32(s,p+8),packed=u32(s,p+12),size=u32(s,p+16)}
        assert(e.kind<=6 and e.bank>0 and e.bank<=255 and e.size<=1048576 and e.packed<=1048576,'Invalid resource record')
        assert((e.size==0 and e.packed==0) or (e.size>0 and e.packed>0),'Invalid empty resource')
        es[#es+1]=e
    end
    error('Missing MEMLIST sentinel')
end
function engine.detect(path)
    local ok,es=pcall(directory,path)
    if not ok or #es<32 then return false end
    -- Standard DOS part table and planar bitmap distinguish this from other banks.
    if es[0x14+1].kind~=3 or es[0x15+1].kind~=4 or es[0x16+1].kind~=5 or es[0x12+1].kind~=2 then return false end
    local banks={}
    for _,e in ipairs(es) do
        if e.size>0 and not banks[e.bank] then
            local f=file_open(path..string.format('/BANK%02X',e.bank));if not f then return false end
            banks[e.bank]=file_size(f);file_close(f)
        end
        if e.size>0 and e.offset+e.packed>banks[e.bank] then return false end
    end
    return true
end
local function bxor(a,b)
    local v,p=0,1
    for _=1,32 do if a%2~=b%2 then v=v+p end;a=floor(a/2);b=floor(b/2);p=p*2 end
    return v
end
local function unpack_bank(s,size)
    assert(#s>=12 and u32(s,#s-3)==size and size>0 and size<=1048576,'Invalid ByteKiller trailer')
    local pos=#s-11;local bits=u32(s,pos);local crc=bxor(u32(s,#s-7),bits);pos=pos-4
    local function bit()
        local b=bits%2;bits=floor(bits/2)
        if bits==0 then
            assert(pos>=1,'Truncated ByteKiller stream')
            local word=u32(s,pos);pos=pos-4;crc=bxor(crc,word)
            b=word%2;bits=floor(word/2)+2147483648
        end
        return b
    end
    local function get(n) local v=0;for _=1,n do v=v*2+bit() end;return v end
    local out={};local dst=size
    while dst>0 do
        local count,offset
        if bit()==0 then
            if bit()==0 then count=get(3)+1 else count=2;offset=get(8) end
        else
            local code=get(2)
            if code==3 then count=get(8)+9
            elseif code==2 then count=get(8)+1;offset=get(12)
            else count=code+3;offset=get(code+9) end
        end
        count=math.min(count,dst) -- The original decoder clamps the final run.
        if offset then assert(offset>0 and dst+offset<=size,'Invalid ByteKiller reference') end
        for _=1,count do
            out[dst]=offset and assert(out[dst+offset],'Unwritten ByteKiller reference') or get(8)
            dst=dst-1
        end
    end
    assert(crc==0,'ByteKiller checksum mismatch')
    local chunks={}
    for p=1,size,4096 do local t={};for i=p,math.min(size,p+4095) do t[#t+1]=string.char(out[i]) end;chunks[#chunks+1]=table.concat(t) end
    return table.concat(chunks)
end
local parts={
    {0x14,0x15,0x16,0,'Protection and titles'}, {0x17,0x18,0x19,0,'Introduction'},
    {0x1a,0x1b,0x1c,0x11,'Water'}, {0x1d,0x1e,0x1f,0x11,'Jail'},
    {0x20,0x21,0x22,0x11,'City'}, {0x23,0x24,0x25,0,'Arena'},
    {0x26,0x27,0x28,0x11,'Palace'}, {0x29,0x2a,0x2b,0x11,'Finale'},
    {0x7d,0x7e,0x7f,0,'Password screen'}
}
local periods={1076,1016,960,906,856,808,762,720,678,640,604,570,538,508,480,453,428,404,381,360,
    339,320,302,285,269,254,240,226,214,202,190,180,170,160,151,143,135,127,120,113}
local opnames={'movConst','mov','add','addConst','call','ret','yield','jmp','installTask','jmpIfVar','condJmp',
    'setPalette','changeTasksState','selectPage','fillPage','copyPage','updateDisplay','removeTask','drawString',
    'sub','and','or','shl','shr','playSound','updateResources','playMusic'}
local lengths={4,3,3,4,3,1,1,3,4,4,0,3,4,2,3,3,2,1,6,3,4,4,4,4,6,3,6}
-- Follow both branch arms, calls and installed tasks. Never execute game code.
local function disassemble(s)
    local queue={0};local head=1;local seen={};local rows={};local draws={};local rates={};local loads={}
    while head<=#queue do
        local pc=queue[head];head=head+1
        assert(pc>=0 and pc<#s,'Script target outside bank')
        while pc<#s and not seen[pc] do
            assert(pc>=0,'Invalid script target');seen[pc]=true
            local p=pc+1;local op=s:byte(p);local len,name
            if op>=128 then
                len=4;name='drawShape';assert(p+len-1<=#s,'Truncated draw')
                draws[#draws+1]={offset=((op*256+s:byte(p+1))*2)%65536,shared=false}
            elseif op>=64 then
                len=5
                if floor(op/32)%2==0 and floor(op/16)%2==0 then len=len+1 end
                if floor(op/8)%2==0 and floor(op/4)%2==0 then len=len+1 end
                if op%4==1 or op%4==2 then len=len+1 end
                name='drawShape';assert(p+len-1<=#s,'Truncated draw')
                draws[#draws+1]={offset=(u16(s,p+1)*2)%65536,shared=op%4==3}
            else
                assert(op<=26,'Unknown script opcode');name=opnames[op+1];len=lengths[op+1]
                if op==10 then
                    local flags=assert(s:byte(p+1),'Truncated conditional')
                    len=(flags<128 and flags>=64) and 7 or 6
                end
                assert(p+len-1<=#s,'Truncated instruction')
                if op==4 or op==7 then queue[#queue+1]=u16(s,p+1)
                elseif op==8 or op==9 then queue[#queue+1]=u16(s,p+2)
                elseif op==10 then queue[#queue+1]=u16(s,p+len-2)
                elseif op==24 then
                    local res=u16(s,p+1);local period=math.min(39,s:byte(p+3))
                    rates[res]=rates[res] or {};rates[res][floor(7159092/(periods[period+1]*2))]=true
                elseif op==25 then loads[u16(s,p+1)]=true end
            end
            local hex={};for i=p,p+len-1 do hex[#hex+1]=string.format('%02X',s:byte(i)) end
            rows[pc]=string.format('%04X  %-23s %s',pc,table.concat(hex,' '),name)
            if op==5 or op==7 or op==17 then break end
            pc=pc+len
        end
    end
    local keys={};for k in pairs(rows) do keys[#keys+1]=k end;table.sort(keys)
    local text={};for _,k in ipairs(keys) do text[#text+1]=rows[k] end
    return draws,rates,loads,table.concat(text,'\n')
end
local cachedPath,entries,tree,items,cache
local function payload(path,e)
    if cache[e.num] then return cache[e.num] end
    local s=read(path..string.format('/BANK%02X',e.bank),e.offset,e.packed)
    if e.packed~=e.size then s=unpack_bank(s,e.size) end
    cache[e.num]=s;return s
end
local ega={0x000000,0x0000aa,0x00aa00,0x00aaaa,0xaa0000,0xaa00aa,0xaa5500,0xaaaaaa,
    0x555555,0x5555ff,0x55ff55,0x55ffff,0xff5555,0xff55ff,0xffff55,0xffffff}
local function palette(s,slot,isEga)
    assert(slot>=0 and slot<32 and #s==2048,'Invalid palette bank')
    local pal={};for i=1,768 do pal[i]=0 end
    for c=0,15 do
        local v=u16(s,slot*32+c*2+1+(isEga and 1024 or 0));local r,g,b
        if isEga then v=ega[floor(v/4096)+1];r=floor(v/65536);g=floor(v/256)%256;b=v%256
        else r=floor(v/256)%16*17;g=floor(v/16)%16*17;b=v%16*17 end
        pal[c*3+1]=r;pal[c*3+2]=g;pal[c*3+3]=b
    end
    return pal
end
local function bitmap(s)
    assert(#s==32000,'Invalid planar bitmap');local px={}
    for i=0,7999 do
        for b=7,0,-1 do
            local c=0
            for plane=0,3 do c=c+floor(s:byte(plane*8000+i+1)/2^b)%2*2^plane end
            px[#px+1]=c
        end
    end
    return px
end
-- Flatten one script-referenced shape, retaining composite child placement.
local function polygons(s,offset)
    local out,active={},{};local count=0
    local function visit(off,x,y,color,depth)
        count=count+1;assert(depth<=32 and count<=8192 and not active[off],'Cyclic or excessive shape hierarchy')
        local p=off+1;local op=assert(s:byte(p),'Shape outside bank');active[off]=true
        if op>=192 then
            assert(p+3<=#s,'Truncated polygon')
            local w,h,n=s:byte(p+1,p+3)
            assert(n>=4 and n<=70 and n%2==0 and p+3+n*2<=#s,'Invalid polygon vertices')
            local poly={color=color>=128 and op%64 or color,points={}}
            assert(poly.color<=17,'Invalid polygon color')
            x=x-floor(w/2);y=y-floor(h/2)
            for i=0,n-1 do poly.points[#poly.points+1]={x+s:byte(p+4+i*2),y+s:byte(p+5+i*2)} end
            out[#out+1]=poly
        else
            assert(op%64==2 and p+3<=#s,'Invalid shape opcode')
            local dx,dy,n=s:byte(p+1,p+3);p=p+4
            for _=0,n do
                local ref=u16(s,p);assert(p+3<=#s,'Truncated shape child')
                local cx,cy=x-dx+s:byte(p+2),y-dy+s:byte(p+3);p=p+4;local c=255
                if ref>=32768 then assert(p+1<=#s,'Truncated child color');c=s:byte(p)%128;p=p+2 end
                visit(ref%32768*2,cx,cy,c,depth+1)
            end
        end
        active[off]=nil
    end
    visit(offset,0,0,255,0);return out
end
local function render(polys)
    local x0,y0,x1,y1=0,0,0,0
    for _,p in ipairs(polys) do for _,v in ipairs(p.points) do x0=math.min(x0,v[1]);y0=math.min(y0,v[2]);x1=math.max(x1,v[1]);y1=math.max(y1,v[2]) end end
    local w,h=x1-x0+3,y1-y0+3
    assert(w<=2048 and h<=2048 and w*h<=1048576,'Excessive shape bounds')
    local px={};for i=1,w*h do px[i]=0 end
    local function put(x,y,c)
        local i=(y-y0+1)*w+(x-x0+1)+1
        if c==16 then px[i]=px[i]%8+8 elseif c==17 then px[i]=0 else px[i]=c end
    end
    for _,poly in ipairs(polys) do
        local points=poly.points
        for y=y0,y1 do
            local crosses={}
            for i,a in ipairs(points) do
                local b=points[i%#points+1]
                if (a[2]<=y and b[2]>y) or (b[2]<=y and a[2]>y) then
                    crosses[#crosses+1]=a[1]+(y-a[2])*(b[1]-a[1])/(b[2]-a[2])
                end
            end
            table.sort(crosses)
            for i=1,#crosses-1,2 do for x=math.ceil(crosses[i]),floor(crosses[i+1]) do put(x,y,poly.color) end end
        end
        -- The format's degenerate four-vertex polygons encode individual dots.
        local a=points[1];local same=true
        for _,b in ipairs(points) do if b[1]~=a[1] or math.abs(b[2]-a[2])>1 then same=false end end
        if same then put(a[1],a[2],poly.color) end
    end
    return w,h,px
end
local function hex(s)
    local out={}
    for p=1,math.min(#s,4096),16 do
        local row={};for i=p,math.min(#s,p+15) do row[#row+1]=string.format('%02X',s:byte(i)) end
        out[#out+1]=string.format('%04X  %s',p-1,table.concat(row,' '))
    end
    if #s>4096 then out[#out+1]='[Preview limited to first 4096 decompressed bytes]' end
    return table.concat(out,'\n')
end
local function index(path)
    if cachedPath==path then return end
    cachedPath=nil;entries=directory(path);tree={};items={};cache={}
    local cats={}
    local function cat(id,name)
        if not cats[id] then local n={id=id,name=name,type='category',children={}};tree[#tree+1]=n;cats[id]=n.children end
        return cats[id]
    end
    local function add(parent,id,name,kind,r)
        assert(not items[id],'Duplicate resource ID');r=r or {};r.kind=kind;items[id]=r
        parent[#parent+1]={id=id,name=name,type=kind=='palette' and 'palette' or (kind=='bitmap' or kind=='shape') and 'image' or kind=='sound' and 'sound' or 'data'}
    end
    local rates,bitmapParts={},{}
    local defaultPals={}
    for _,e in ipairs(entries) do
        if e.kind==3 then
            local data=payload(path,e);local slot=0
            -- Palette zero can be a black fade frame. Use the first visible VGA
            -- palette for isolated artwork; the original VM chooses these at runtime.
            for candidate=0,31 do
                local pal=palette(data,candidate,false);local visible=false
                for i=1,48 do if pal[i]~=0 then visible=true;break end end
                if visible then slot=candidate;break end
            end
            defaultPals[e.num]=string.format('pal_%02x_%02x_vga',e.num,slot)
        end
    end
    for _,part in ipairs(parts) do
        local code=entries[part[2]+1]
        if code and code.kind==4 then
            local draws,rs,loads,text=disassemble(payload(path,code))
            add(cat('scripts','Scripts (static disassembly)'),'script_'..code.num,part[5],'script',{entry=code,text=text})
            for num,rr in pairs(rs) do rates[num]=rates[num] or {};for hz in pairs(rr) do rates[num][hz]=true end end
            for num in pairs(loads) do if not bitmapParts[num] then bitmapParts[num]=part[1] end end
            local seen={}
            for _,d in ipairs(draws) do
                local num=d.shared and part[4] or part[3]
                if num~=0 then
                    local id=string.format('shape_%02x_%04x_%02x',num,d.offset,part[1])
                    if not seen[id] then
                        seen[id]=true
                        -- Validate referenced roots only, without guessing bank offsets.
                        polygons(payload(path,entries[num+1]),d.offset)
                        add(cat('shapes_'..part[3],'Polygon Artwork / '..part[5]),id,string.format('Resource %02X / offset %04X',num,d.offset),'shape',
                            {entry=entries[num+1],offset=d.offset,pal=defaultPals[part[1]]})
                    end
                end
            end
        end
    end
    for _,e in ipairs(entries) do
        local name=string.format('Resource %02X / BANK%02X / %d bytes',e.num,e.bank,e.size)
        if e.kind==3 then
            local parent=cat('palettes','Palettes (VGA and EGA)')
            for _,mode in ipairs({'vga','ega'}) do for slot=0,31 do
                add(parent,string.format('pal_%02x_%02x_%s',e.num,slot,mode),string.format('%02X / %s palette %02d',e.num,mode:upper(),slot),'palette',{entry=e,slot=slot,ega=mode=='ega'})
            end end
        elseif e.kind==2 then
            -- Use the visible ends of the protection bytecode's logo fade sequences; other screens
            -- default to the loading part's first visible palette; all are selectable.
            local pal=defaultPals[bitmapParts[e.num] or 0x17]
            if e.num==0x12 then pal='pal_14_04_vga'
            elseif e.num==0x13 then pal='pal_14_09_vga'
            elseif e.num==0x47 then pal='pal_14_0f_vga'
            elseif e.num==0x53 then pal='pal_14_09_vga' end
            local labels={[0x12]='Interplay logo',[0x13]='Out of This World title',
                [0x47]='Delphine Software logo',[0x53]='Another World title'}
            add(cat('bitmaps','Bitmaps and Screens'),'bitmap_'..e.num,(labels[e.num] and labels[e.num]..' / ' or '')..name,'bitmap',{entry=e,pal=pal})
        elseif e.kind==0 and e.size>8 then
            local rr=rates[e.num] or {[9943]=true};local sorted={};for hz in pairs(rr) do sorted[#sorted+1]=hz end;table.sort(sorted)
            for _,hz in ipairs(sorted) do
                add(cat('sounds','Sound Samples'),'sound_'..e.num..'_'..hz,name..' / '..hz..' Hz'..(rates[e.num] and '' or ' (preview rate)'), 'sound',{entry=e,rate=hz})
            end
        end
        add(cat(e.kind==1 and 'music' or 'data',e.kind==1 and 'Music Modules (metadata)' or 'Resource Data (metadata and hex)'),
            'data_'..e.num,name,'data',{entry=e})
    end
    cachedPath=path
end
function engine.get_resources(path) index(path);return tree end
function engine.default_palette(path,id) index(path);return items[id] and items[id].pal end
function engine.load_resource(path,id,override)
    index(path);local r=items[id];if not r then return nil end
    local e=r.entry;local s=payload(path,e)
    local desc=string.format('Another World / resource %02X / BANK%02X / offset %d / %d packed, %d unpacked bytes',e.num,e.bank,e.offset,e.packed,e.size)
    if r.kind=='script' then return {type='text',text=r.text,description=desc..' / static reachable instructions; no VM execution'} end
    if r.kind=='data' then
        local info=string.format('%s\nResource type: %d\n\n',desc,e.kind)
        if e.kind==1 and #s>=192 then info=info..string.format('Music module: delay %d, %d orders. Playback is not implemented.\n\n',u16(s,1),s:byte(64)) end
        return {type='text',text=info..hex(s),description=desc}
    end
    if r.kind=='sound' then
        assert(#s>=8,'Truncated sound header');local n,loop=u16(s,1)*2,u16(s,3)*2
        assert(n+loop>0 and n+loop<=#s-8,'Invalid sample length')
        return {type='sound',sound=sound_create_pcm(r.rate,8,1,true,s:sub(9,8+n+loop)),description=desc..' / signed PCM; loop segment played once'}
    end
    local pr=r.kind=='palette' and r or items[override or r.pal]
    assert(pr and pr.kind=='palette','Invalid palette selection')
    local pal=palette(payload(path,pr.entry),pr.slot,pr.ega)
    local w,h,px
    if r.kind=='palette' then
        w,h=256,16;px={};for y=0,15 do for x=0,255 do px[#px+1]=floor(x/16) end end
    elseif r.kind=='bitmap' then w,h,px=320,200,bitmap(s)
    else w,h,px=render(polygons(s,r.offset));desc=desc..' / isolated polygon artwork; preview palette; no scene/page composition' end
    return {type='image',image=image_create_indexed(w,h,px,pal),palette=pal,description=desc}
end
return engine

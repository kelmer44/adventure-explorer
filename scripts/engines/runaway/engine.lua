-- Runaway: A Road Adventure. Pendulo's RESOURCE format, RGB565 generation.
-- Offsets are zero-based throughout; Lua string positions are adjusted in helpers.
local engine={id="runaway",name="Runaway: A Road Adventure",version="1.0",
    description="Pendulo Studios - RGB565 scenes, sprite banks, masks and PCM audio"}
local floor=math.floor
local function u16(d,p) return d:byte(p+1)+d:byte(p+2)*256 end
local function u32(d,p) return u16(d,p)+u16(d,p+2)*65536 end
local function s16(d,p) local n=u16(d,p); return n<32768 and n or n-65536 end
local function join(a,b) return a.."/"..b end
local function read(path,offset,size)
    local f=file_open(path); if not f then return nil end
    local d=file_read(f,offset or 0,size or file_size(f)); file_close(f); return d
end
local function file_length(path)
    local f=file_open(path); if not f then return nil end
    local n=file_size(f); file_close(f); return n
end
local function find_dir(path,name)
    for _,candidate in ipairs(list_files(path) or {}) do
        if candidate:upper()==name:upper() then return join(path,candidate) end
    end
    return join(path,name)
end
local function resource_dir(path)
    for _,name in ipairs(list_files(path) or {}) do
        if name:upper():match("^RESOURCE%.[A-I]%d%d$") then return path end
    end
    return find_dir(path,"RESOURCE")
end
local function scene_table(path)
    local size=file_length(path); if not size or size<320 then return nil end
    local head=read(path,0,4); if not head or #head~=4 then return nil end
    local first=u32(head,0)
    if first~=320 and first~=400 then return nil end
    head=read(path,0,first); if not head or #head~=first then return nil end
    local count=first/8; local entries={}; local previous=first
    for i=0,count-1 do
        local off,n=u32(head,i*4),u32(head,count*4+i*4)
        if off~=0 or n~=0 then
            if off<previous or n<1 or off+n>size then return nil end
            entries[i]={offset=off,size=n}; previous=off+n
        end
    end
    return entries
end
-- Backgrounds carry no dimensions. Most rooms are 600 rows high. These scrolling
-- scenes have independently verified dimensions, selected only on an exact size.
local special_dimensions={
    D03={1200,670},D06={1760,1200},E10={1880,700},F37={1444,800},H37={1444,800},
    G01={1400,760},G02={1640,800},G03={1520,900},I01={2048,900},I03={1024,2062}
}
local function dimensions(scene,size)
    local special=special_dimensions[scene]
    if special and special[1]*special[2]*2==size then return special[1],special[2] end
    if size%1200==0 then
        local w=size/1200
        if w>=320 and w<=8192 then return w,600 end
    end
    return nil
end
function engine.detect(path)
    local dir=resource_dir(path); local hits=0
    for _,name in ipairs(list_files(dir) or {}) do
        local scene=name:upper():match("^RESOURCE%.([A-I]%d%d)$")
        if scene then
            local entries=scene_table(join(dir,name))
            if entries and entries[0] and entries[2] and entries[2].size==1536 and dimensions(scene,entries[0].size) then
                hits=hits+1; if hits==2 then return true end
            end
        end
    end
    return false
end
local function descriptors(raw,full_validation)
    local frames={}; local previous=-1
    while #frames<8192 do
        local p=#frames*14; if p+14>#raw then break end
        local off,x,w,top,bottom,count=u32(raw,p),s16(raw,p+4),s16(raw,p+6),s16(raw,p+8),s16(raw,p+10),u16(raw,p+12)
        if off<previous or off>=#raw or w<1 or w>4096 or x<=-8192 or x>=8192
            or top>bottom or top< -8192 or bottom>8192 or bottom-top>=4096 or count>20000 then break end
        frames[#frames+1]={relative=off,x=x,width=w,y=top,height=bottom-top+1,count=count}
        previous=off
    end
    if #frames==0 or frames[1].relative~=0 then return nil end
    local base=#frames*14
    -- Confirm first/last frame boundaries when indexing; each selected frame is
    -- checked when loaded. Full validation is available to the regression scan.
    for i,f in ipairs(frames) do
        local p=base+f.relative
        if full_validation or i==1 or i==#frames then
        for _=1,f.count do
            if p+5>#raw then return nil end
            local x,y,n=s16(raw,p),s16(raw,p+2),raw:byte(p+5); p=p+5
            if x<f.x or x+n>f.x+f.width or y<f.y or y>=f.y+f.height or p+n*2>#raw then return nil end
            p=p+n*2
        end
        local finish=i<#frames and base+frames[i+1].relative or #raw
        if p~=finish then return nil end
        end
        f.offset=base+f.relative
    end
    return frames
end
-- Standalone RGB565 strips: u16 count, then x/y/length u16 + length pixels.
-- Mask strips use the same header/coordinates but do not carry pixel data.
local function spans(raw,mask)
    if #raw<2 then return nil end
    local count=u16(raw,0); if count<1 or count>60000 then return nil end
    if mask and #raw~=2+count*6 then return nil end
    local p=2; local result={}; local left,top,right,bottom=8192,8192,0,0
    for _=1,count do
        if p+6>#raw then return nil end
        local x,y,n=s16(raw,p),s16(raw,p+2),u16(raw,p+4); p=p+6
        if x<0 or y<0 or n<1 or x+n>8192 or y>=8192 then return nil end
        if not mask and p+n*2>#raw then return nil end
        result[#result+1]={x=x,y=y,length=n,offset=p}
        left=math.min(left,x); top=math.min(top,y); right=math.max(right,x+n); bottom=math.max(bottom,y+1)
        if not mask then p=p+n*2 end
    end
    if p~=#raw or (right-left)*(bottom-top)>8000000 then return nil end
    return {runs=result,x=left,y=top,width=right-left,height=bottom-top}
end
local function rle_size(raw)
    if #raw%3~=0 then return nil end
    local n=0
    for p=0,#raw-1,3 do n=n+u16(raw,p+1) end
    return n
end
local state={}
local function category(id,name) return {id=id,name=name,type="category",children={}} end
local function add(cat,id,name,typ,e)
    cat.children[#cat.children+1]={id=id,name=name,type=typ}
    state.entries[id]=e
end
local function block_data(e)
    if state.cached_path==e.path and state.cached_offset==e.offset then return state.cached_data end
    local d=read(e.path,e.offset,e.size)
    if not d or #d~=e.size then return nil end
    state.cached_path=e.path; state.cached_offset=e.offset; state.cached_data=d
    return d
end
local function audio_nodes(tree,folder,pattern,kind,table_size,bits,channels)
    local files=list_files(folder) or {}; table.sort(files)
    for _,name in ipairs(files) do
        if name:upper():match(pattern) then
            local path=join(folder,name); local size=file_length(path)
            local data=size and size>=table_size and read(path,0,table_size)
            if data and #data==table_size and u32(data,0)==0 and u32(data,4)==table_size then
                local cat=category("file_"..name,name.." - "..kind)
                for i=1,table_size/4-2 do
                    local first,last=u32(data,i*4),u32(data,(i+1)*4)
                    if first>=table_size and last>first and last<=size then
                        local id=kind.."_"..name.."_"..i
                        add(cat,id,"Cue "..i,"sound",{kind="sound",path=path,offset=first,size=last-first,bits=bits,channels=channels})
                    end
                end
                if #cat.children>0 then tree[#tree+1]=cat end
            end
        end
    end
end
function engine.get_resources(path)
    state={path=path,entries={}}
    local tree={}; local dir=resource_dir(path); local files=list_files(dir) or {}; table.sort(files)
    for _,name in ipairs(files) do
        local scene=name:upper():match("^RESOURCE%.([A-I]%d%d)$")
        local file=join(dir,name)
        local entries=scene and scene_table(file)
        if name:upper():match("^RESOURCE%.00%d$") then
            local shared=category("shared_"..name,name.." - shared engine data")
            local size=file_length(file)
            add(shared,"shared_data_"..name,"Archive data (metadata)","text",{kind="data",path=file,offset=0,size=size,scene=name,block=0})
            tree[#tree+1]=shared
        end
        if entries and entries[0] then
            local cat=category("scene_"..scene,name)
            local w,h=dimensions(scene,entries[0].size)
            for i=0,49 do
                local b=entries[i]
                if b then
                    local id=scene.."_"..i
                    local record={path=file,offset=b.offset,size=b.size,scene=scene,block=i}
                    if i==0 and w then
                        record.kind="background"; record.width=w; record.height=h
                        add(cat,"bg_"..scene,"Background ("..w.." x "..h..")","image",record)
                    else
                        local raw=read(file,b.offset,b.size)
                        local frames=raw and descriptors(raw)
                        local strips=not frames and raw and spans(raw,false)
                        local mask=not frames and not strips and raw and spans(raw,true)
                        if frames then
                            local bank=category("bank_"..id,"Block "..i.." - "..#frames.." frames")
                            -- Short batches keep preview memory bounded even for 1,000-frame banks.
                            for first=1,#frames,32 do
                                local last=math.min(first+31,#frames)
                                add(bank,"anim_"..id.."_"..first,"Preview "..first.."-"..last,"animation",
                                    {kind="animation",block=record,frames=frames,first=first,last=last})
                            end
                            for n,f in ipairs(frames) do
                                add(bank,"frame_"..id.."_"..n,"Frame "..n.." ("..f.width.." x "..f.height..")","image",
                                    {kind="frame",block=record,frame=f})
                            end
                            cat.children[#cat.children+1]=bank
                        elseif strips or mask then
                            record.kind=mask and "mask_strips" or "strips"; record.strips=strips or mask
                            add(cat,(mask and "mask_" or "sprite_")..id,"Block "..i..(mask and " - mask" or " - overlay"),"image",record)
                        elseif raw and w and rle_size(raw)==w*h then
                            record.kind="rle"; record.width=w; record.height=h
                            add(cat,"mask_"..id,"Block "..i.." - depth/walk mask","image",record)
                        else
                            record.kind="data"
                            add(cat,"data_"..id,"Block "..i.." ("..b.size.." bytes)","text",record)
                        end
                    end
                end
            end
            tree[#tree+1]=cat
        end
    end
    audio_nodes(tree,dir,"^RESOURCE%.M%d%d$","music",400,16,2)
    audio_nodes(tree,dir,"^RESOURCE%.S%d%d$","effects",4000,16,1)
    local data_dir=find_dir(path,"DATAA")
    -- Also accept an installed RESOURCE folder selected directly.
    if dir==path then data_dir=find_dir(join(path,".."),"DATAA") end
    audio_nodes(tree,data_dir,"^DATAACA%d+%.000$","speech",48000,8,1)
    local cabinets=find_dir(path,"CAB")
    if #(list_files(cabinets) or {})>0 then
        local info=category("installation","Installation files")
        add(info,"installation_info","Additional resources in installer cabinets","text",{kind="installation"})
        tree[#tree+1]=info
    end
    return tree
end
-- Use exact 5/6-bit expansion, with no scene-specific palette or gamma correction.
local function color(v)
    return floor(floor(v/2048)*255/31),floor(floor(v/32)%64*255/63),floor(v%32*255/31)
end
local function rgb_image(w,h,pixels,description)
    return {type="image",image=image_create_rgb(w,h,pixels),width=w,height=h,description=description}
end
local function raw_image(d,w,h,description)
    if #d~=w*h*2 then return nil end
    local px={}; local n=0
    for p=0,#d-1,2 do
        local r,g,b=color(u16(d,p)); px[n+1]=r; px[n+2]=g; px[n+3]=b; n=n+3
    end
    return rgb_image(w,h,px,description)
end
local function canvas(w,h)
    if w<1 or h<1 or w*h>8000000 then return nil end
    local px={}; for i=1,w*h*3 do px[i]=0 end; return px
end
local function paint(px,w,x,y,raw,p,count,mask)
    local dest=(y*w+x)*3
    for j=0,count-1 do
        local r,g,b=255,255,255
        if not mask then r,g,b=color(u16(raw,p+j*2)) end
        px[dest+1]=r; px[dest+2]=g; px[dest+3]=b; dest=dest+3
    end
end
local function frame_image(raw,f,description)
    local px=canvas(f.width,f.height); if not px then return nil end
    local p=f.offset
    for _=1,f.count do
        if p+5>#raw then return nil end
        local x,y,n=s16(raw,p)-f.x,s16(raw,p+2)-f.y,raw:byte(p+5); p=p+5
        if x<0 or x+n>f.width or y<0 or y>=f.height or p+n*2>#raw then return nil end
        paint(px,f.width,x,y,raw,p,n,false); p=p+n*2
    end
    return rgb_image(f.width,f.height,px,description)
end
local function data_preview(d,e)
    local lines={e.scene.." / block "..e.block,string.format("%d bytes at 0x%X",e.size,e.offset),
        "Uninterpreted engine data", ""}
    for p=1,math.min(#d,2048),16 do
        local hex={}
        for q=p,math.min(p+15,#d) do hex[#hex+1]=string.format("%02X",d:byte(q)) end
        lines[#lines+1]=string.format("%06X  %s",p-1,table.concat(hex," "))
    end
    return {type="text",text=table.concat(lines,"\n")}
end
local function load(path,id)
    if state.path~=path then engine.get_resources(path) end
    local e=state.entries[id]; if not e then return nil end
    if e.kind=="installation" then
        return {type="text",text="This folder contains the Runaway installation media. Loose RESOURCE and DATAA files can be browsed directly.\n\nAdditional scenes, shared resources, speech and videos remain in Cab/*.cab. To browse those resources, use an installed game folder or extract the cabinets with scripts/prepare-runaway.py.\n\nBink cutscenes and scene logic are not played by this resource explorer."}
    elseif e.kind=="sound" then
        local d=read(e.path,e.offset,e.size); if not d or #d~=e.size then return nil end
        local alignment=e.bits/8*e.channels
        if #d%alignment~=0 then return nil end
        return {type="sound",sound=sound_create_pcm(16000,e.bits,e.channels,e.bits==16,d),
            description=string.format("%s - 16000 Hz, %d-bit, %s PCM",id,e.bits,e.channels==2 and "stereo" or "mono")}
    elseif e.kind=="frame" or e.kind=="animation" then
        local raw=block_data(e.block); if not raw then return nil end
        if e.kind=="frame" then return frame_image(raw,e.frame,id) end
        local handles={}
        for i=e.first,e.last do
            local result=frame_image(raw,e.frames[i],id); if not result then return nil end
            handles[#handles+1]=result.image
        end
        return {type="animation",animation=animation_create(handles,100),image=handles[1],frames=handles,delay_ms=100,
            description=id.." - stored frame order, 100 ms preview timing"}
    end
    local raw=e.kind=="data" and read(e.path,e.offset,math.min(e.size,2048)) or block_data(e)
    if not raw then return nil end
    if e.kind=="background" then return raw_image(raw,e.width,e.height,id)
    elseif e.kind=="strips" or e.kind=="mask_strips" then
        local s=e.strips; local px=canvas(s.width,s.height); if not px then return nil end
        for _,run in ipairs(s.runs) do paint(px,s.width,run.x-s.x,run.y-s.y,raw,run.offset,run.length,e.kind=="mask_strips") end
        return rgb_image(s.width,s.height,px,string.format("%s at (%d, %d)",id,s.x,s.y))
    elseif e.kind=="rle" then
        local px={}
        for p=0,#raw-1,3 do
            local v=raw:byte(p+1); local n=u16(raw,p+1)
            for _=1,n do px[#px+1]=v end
        end
        if #px~=e.width*e.height then return nil end
        local pal={}; for i=0,255 do
            -- Semantic mask values occupy the low indices; use distinct colours.
            pal[#pal+1]=(i*73)%256; pal[#pal+1]=(i*151)%256; pal[#pal+1]=(i*211)%256
        end
        return {type="image",image=image_create_indexed(e.width,e.height,px,pal),width=e.width,height=e.height,description=id}
    else return data_preview(raw,e) end
end
function engine.load_resource(path,id)
    local ok,result=pcall(load,path,id)
    if not ok then log_warn("Runaway: "..tostring(result)); return nil end
    return result
end
return engine

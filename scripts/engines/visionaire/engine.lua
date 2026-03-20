-- ============================================================================
-- Adventure Explorer - Engine Script: Visionaire Engine
-- ============================================================================
-- Daedalic Entertainment, 2005-2015.  Images stored as PNG inside encrypted,
-- ZLib-compressed VIS3/VIS5 archives (.vis, .vs*, .vc* files).
--
-- Archive structure:
--   [4 bytes] 'VIS3' or 'VIS5' magic
--   [4 bytes] NumFiles (u32, auto-detected endianness)
--   [NumFiles*16 + 6 bytes] Encrypted directory: 'HDR' + entries + 'END'
--     Each TDirEntry (16 bytes): Offset + CompSize + UncompSize + Flags (all u32)
--   [file data area] Files at DirEntry.Offset from data_area_start,
--     ZLib-compressed, may have encrypted first bytes (PNG/WebP headers).
--
-- Flags constants:
--   Flag_MainXML    = 0x00000011  main game XML/VBIN
--   Flag_CryptDef   = 0x00000002  body encrypted with game key
--   Flag_CryptImage = 0x00000008  PNG/WebP header XOR'd with game key
--
-- Encryption: XOR with cycling game-specific key (from vis.key or hardcoded).
-- New host API used: zlib_decompress(data, size), image_load_png(data), xor_bytes(data,key)
-- ============================================================================

local engine = {}
engine.name        = "Visionaire Engine"
engine.id          = "visionaire"
engine.description = "Visionaire Engine Games (Daedalic, 2005-2015)"
engine.version     = "1.0"

-- ============================================================================
-- Binary helpers
-- ============================================================================

local function u8(data, pos) return data:byte(pos) end
local function u32le(data, pos)
    return data:byte(pos)
         + data:byte(pos + 1) * 256
         + data:byte(pos + 2) * 65536
         + data:byte(pos + 3) * 16777216
end
local function u32be(data, pos)
    return data:byte(pos) * 16777216
         + data:byte(pos + 1) * 65536
         + data:byte(pos + 2) * 256
         + data:byte(pos + 3)
end

-- ============================================================================
-- Encryption key loading
-- Keys are read from vis.key in the game folder, or game-specific defaults.
-- vis.key format (one entry per line): ID;GameName;Key
-- ============================================================================

local function load_vis_key(game_path)
    local keys = {}
    local f = file_open(game_path .. "/vis.key")
    if not f then return keys end
    local sz = file_size(f)
    local data = file_read(f, 0, sz)
    file_close(f)
    if not data then return keys end

    for line in (data .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if #line > 0 then
            -- Format: ID;Name;Key
            local parts = {}
            for p in (line .. ";"):gmatch("([^;]*);") do
                parts[#parts + 1] = p
            end
            if #parts >= 3 and #parts[3] > 0 then
                keys[#keys + 1] = parts[3]
            end
        end
    end
    return keys
end

-- ============================================================================
-- VIS archive parser
-- Returns: { num_files, dir_size, data_start, entries[] }
--   Each entry: { offset, comp_size, uncomp_size, flags }
-- Returns nil if decryption fails; entries[] may be empty if no files.
-- ============================================================================

local FLAG_MAIN_XML1 = 1       -- 0x00000001
local FLAG_CRYPT_DEF = 2       -- 0x00000002
local FLAG_CRYPT_IMG = 8       -- 0x00000008
local FLAG_MAIN_XML2 = 16      -- 0x00000010

-- Check whether a single-bit flag is set in val (no bit32 needed)
local function has_flag(val, flag)
    -- flag must be a power of 2; use (val // flag) % 2 == 1
    return math.floor(val / flag) % 2 == 1
end

local function parse_vis_dir(dir_data, num_files)
    -- dir_data starts with 'HDR' (3 bytes), then entries, then 'END' (3 bytes)
    if #dir_data < 6 then return nil end
    if dir_data:sub(1, 3) ~= "HDR" then return nil end
    if dir_data:sub(#dir_data - 2) ~= "END" then return nil end

    local entries = {}
    for i = 0, num_files - 1 do
        local b = 4 + i * 16  -- 1-based, after 'HDR'
        if b + 15 > #dir_data then break end
        entries[#entries + 1] = {
            offset     = u32le(dir_data, b),
            comp_size  = u32le(dir_data, b + 4),
            uncomp_size= u32le(dir_data, b + 8),
            flags      = u32le(dir_data, b + 12)
        }
    end
    return entries
end

-- Try to decrypt dir_data with key, check for HDR/END, return entries or nil
local function try_decrypt(encrypted_dir, num_files, key)
    local decrypted
    if key and #key > 0 then
        decrypted = xor_bytes(encrypted_dir, key)
    else
        decrypted = encrypted_dir
    end
    return parse_vis_dir(decrypted, num_files)
end

-- Open and parse a VIS archive, returning metadata table or nil
local function open_vis(game_path, vis_name, extra_keys)
    local fh = file_open(game_path .. "/" .. vis_name)
    if not fh then return nil end

    local sz = file_size(fh)
    -- Read enough for header + directory
    -- Max directory = 100000 * 16 + 6 = 1.6 MB; add 8 for header
    local max_read = math.min(sz, 8 + 100000 * 16 + 6)
    local raw = file_read(fh, 0, max_read)
    file_close(fh)
    if not raw or #raw < 10 then return nil end

    -- Check magic: 'VIS3' or 'VIS5'
    local magic = raw:sub(1, 4)
    if magic ~= "VIS3" and magic ~= "VIS5" then return nil end

    -- Determine endianness for NumFiles
    local le_val = u32le(raw, 5)
    local be_val = u32be(raw, 5)
    local num_files = (le_val < be_val) and le_val or be_val
    if num_files == 0 or num_files > 100000 then return nil end

    local dir_size   = num_files * 16 + 6  -- HDR + entries + END
    local dir_start  = 9   -- 1-based (after 8-byte header)
    local data_start = 8 + dir_size  -- 0-based absolute offset of data area

    if dir_start + dir_size - 1 > #raw then return nil end
    local encrypted_dir = raw:sub(dir_start, dir_start + dir_size - 1)

    -- Try keys in order: no-key first, then provided keys
    local all_keys = { "" }  -- empty string = no XOR (try unencrypted)
    for _, k in ipairs(extra_keys or {}) do all_keys[#all_keys + 1] = k end

    local entries = nil
    for _, key in ipairs(all_keys) do
        entries = try_decrypt(encrypted_dir, num_files, key)
        if entries then break end
    end

    if not entries then return nil end

    return {
        name       = vis_name,
        num_files  = num_files,
        data_start = data_start,
        entries    = entries
    }
end

-- ============================================================================
-- Categorise entries into images and other
-- ============================================================================

local PNG_SIG  = "\137PNG"    -- first 4 bytes of a PNG file
local WEBP_SIG = "RIFF"       -- WebP starts with RIFF....WEBP

local function guess_entry_type(flags)
    -- Main XML/VBIN entries
    if has_flag(flags, FLAG_MAIN_XML1) or has_flag(flags, FLAG_MAIN_XML2) then
        return "xml"
    end
    return "data"
end

-- ============================================================================
-- Detection: look for any .vis / .vs* / .vc* file whose first 4 bytes are VIS3/VIS5
-- ============================================================================

function engine.detect(game_path)
    local files = list_files(game_path)
    if not files then return false end

    for _, name in ipairs(files) do
        local lower = name:lower()
        -- Match .vis extensions and multi-part archives (.vs000, .vc000, etc.)
        if lower:match("%.vis$") or lower:match("%.vs%d+$") or lower:match("%.vc%d+$")
           or lower:match("^data%.vis$") or lower:match("^game%.vis$") then
            local fh = file_open(game_path .. "/" .. name)
            if fh then
                local hdr = file_read(fh, 0, 4)
                file_close(fh)
                if hdr == "VIS3" or hdr == "VIS5" then return true end
            end
        end
    end
    return false
end

-- ============================================================================
-- Resource tree
-- ============================================================================

function engine.get_resources(game_path)
    local files = list_files(game_path)
    if not files then return {} end

    -- Load encryption keys from vis.key
    local keys = load_vis_key(game_path)

    -- Collect VIS archives (main .vis first, then multi-part)
    local vis_files = {}
    for _, name in ipairs(files) do
        local lower = name:lower()
        if lower:match("%.vis$") or lower:match("%.vs%d+$") or lower:match("%.vc%d+$") then
            vis_files[#vis_files + 1] = name
        end
    end
    table.sort(vis_files, function(a, b)
        -- .vis before .vs000/.vc000
        local a_main = a:lower():match("%.vis$") and 0 or 1
        local b_main = b:lower():match("%.vis$") and 0 or 1
        if a_main ~= b_main then return a_main < b_main end
        return a:lower() < b:lower()
    end)

    local resources = {}

    for _, vis_name in ipairs(vis_files) do
        local vis = open_vis(game_path, vis_name, keys)
        if vis then
            local data_items = {}
            local xml_items  = {}

            for i, e in ipairs(vis.entries) do
                local entry_type = guess_entry_type(e.flags)
                local label = string.format("File %04d", i)
                if entry_type == "xml" then
                    xml_items[#xml_items + 1] = { idx = i, entry = e, label = label }
                else
                    data_items[#data_items + 1] = { idx = i, entry = e, label = label }
                end
            end

            local encrypted = false
            for _, e in ipairs(vis.entries) do
                if has_flag(e.flags, FLAG_CRYPT_DEF) or has_flag(e.flags, FLAG_CRYPT_IMG) then
                    encrypted = true; break
                end
            end

            local desc = string.format("%s (%d files%s)", vis_name, vis.num_files,
                encrypted and ", encrypted" or "")

            local cat = { id = "vis|" .. vis_name, name = desc,
                          type = "category", children = {} }

            if #xml_items > 0 then
                cat.children[#cat.children + 1] = {
                    id   = "visi|" .. vis_name .. "|xml",
                    name = string.format("Game Data (%d XML/VBIN)", #xml_items),
                    type = "image"
                }
            end

            for _, item in ipairs(data_items) do
                cat.children[#cat.children + 1] = {
                    id   = "visi|" .. vis_name .. "|" .. tostring(item.idx),
                    name = item.label,
                    type = "image"
                }
            end

            resources[#resources + 1] = cat
        else
            -- Could not decrypt/parse the archive
            resources[#resources + 1] = {
                id   = "vis_err|" .. vis_name,
                name = vis_name .. " (encrypted - vis.key needed)",
                type = "category",
                children = {{
                    id   = "vis_info|" .. vis_name,
                    name = "Archive info",
                    type = "image"
                }}
            }
        end
    end

    return resources
end

-- ============================================================================
-- Resource loading
-- ============================================================================

function engine.load_resource(game_path, resource_id, palette_id)
    local prefix = resource_id:match("^([^|]+)|")
    if not prefix then return nil end

    if prefix == "vis_info" then
        local vis_name = resource_id:match("^vis_info|(.+)$")
        return {
            type = "text",
            text = vis_name .. "\n\nThis Visionaire archive is encrypted.\n"
                .. "To browse its contents, place a vis.key file in the game folder.\n\n"
                .. "vis.key format (one entry per line):\n  ID;Game Name;EncryptionKey\n\n"
                .. "The encryption key can be extracted with VISExt /force."
        }
    end

    if prefix == "visi" then
        -- visi|<vis_name>|<index or 'xml'>
        local vis_name, idx_str = resource_id:match("^visi|([^|]+)|(.+)$")
        if not vis_name then return nil end

        local keys = load_vis_key(game_path)
        local vis  = open_vis(game_path, vis_name, keys)
        if not vis then
            return { type = "text", text = vis_name .. "\n\nCould not open or decrypt archive." }
        end

        if idx_str == "xml" then
            -- Describe all XML/VBIN entries
            local lines = { vis_name .. " - Game Data / XML Entries\n" }
            for i, e in ipairs(vis.entries) do
                local t = guess_entry_type(e.flags)
                if t == "xml" then
                    lines[#lines + 1] = string.format(
                        "  Entry %04d: comp=%d uncomp=%d flags=0x%08x",
                        i, e.comp_size, e.uncomp_size, e.flags)
                end
            end
            return { type = "text", text = table.concat(lines, "\n") }
        end

        local idx = tonumber(idx_str)
        if not idx then return nil end
        local e = vis.entries[idx]
        if not e then return nil end

        -- Read the file from the VIS archive
        local fh = file_open(game_path .. "/" .. vis_name)
        if not fh then return nil end
        local abs_offset = vis.data_start + e.offset
        local raw = file_read(fh, abs_offset, e.comp_size)
        file_close(fh)
        if not raw then return nil end

        -- Decompress with ZLib
        local decompressed = zlib_decompress(raw, e.uncomp_size)
        if not decompressed then
            return {
                type = "text",
                text = string.format(
                    "File %04d in %s\n\nCould not decompress (ZLib error).\n"
                    .. "comp_size=%d, uncomp_size=%d, flags=0x%08x",
                    idx, vis_name, e.comp_size, e.uncomp_size, e.flags)
            }
        end

        -- Check if it looks like a PNG
        local sig4 = decompressed:sub(1, 4)
        if sig4 == PNG_SIG then
            local img = image_load_png(decompressed)
            if img then
                return {
                    type        = "image",
                    image       = img,
                    description = string.format("File %04d in %s - PNG image", idx, vis_name)
                }
            end
        end

        -- Check if it looks like a WebP
        if sig4 == WEBP_SIG then
            return {
                type = "text",
                text = string.format(
                    "File %04d in %s\n\nWebP image (%d bytes decompressed).\n"
                    .. "WebP display requires an additional library.",
                    idx, vis_name, #decompressed)
            }
        end

        -- Generic binary: show info
        return {
            type = "text",
            text = string.format(
                "File %04d in %s\n\ncomp_size=%d, uncomp_size=%d, flags=0x%08x\n"
                .. "Decompressed: %d bytes\nFirst bytes: %s",
                idx, vis_name, e.comp_size, e.uncomp_size, e.flags,
                #decompressed,
                decompressed:sub(1, 16):gsub(".", function(c)
                    return string.format("%02x ", c:byte())
                end))
        }
    end

    return nil
end

return engine

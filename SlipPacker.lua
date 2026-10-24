--#   ,-.       _,---._ __  / \
--#  /  )    .-'       `./ /   \
--# (  (   ,'            `/    /|
--#  \  `-"             \'\   / |
--#   `.              ,  \ \ /  |
--#    /`.          ,'-`----Y   |
--#   (            ;        |   '
--#   |  ,-.    ,-'         |  /
--#   |  | (   |   Meechie  | /
--#   )  |  \  `.___________|/

--================================================================================
-- SlipPacker LUA - v1.0.0 Date: 2026-10-24
--================================================================================

_addon.name     = 'SlipPacker'
_addon.author   = 'Meechie'
_addon.version  = '1.0.0'
_addon.commands = {'slippacker', 'sp'}

require('pack')
require('lists')
require('coroutine')
bit   = require('bit')
res   = require('resources')
slips = require('slips')

-- ===========================================================================
--  Constants
-- ===========================================================================

local INVENTORY   = 0
local ALL_BAGS    = { 0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }
local PORTER_NAME = 'Porter Moogle'
local RANGE_SQ    = 36
local TRADE_SLOTS = 8
local AUG_SLIP    = 13
local WRAP        = 100

local PKT_MENU_OPEN  = 0x034
local PKT_MENU_CLOSE = 0x052
local PKT_TRADE      = 0x036
local PKT_MENU_REPLY = 0x05B
local MENU_CLOSE     = 0x40000000

local OFF_NPC_ID    = 0x04
local OFF_NPC_INDEX = 0x28
local OFF_ZONE_MENU = 0x2A
local OFF_GATE      = 0x0C

local TRADE_TIMEOUT   = 9
local POLL            = 0.025
local LAND_POLLS      = 30
local LAND_POLLS_LATE = 10
local LAND_POLL       = 0.1
local RETRY_PAUSE     = 1.0
local AFTER_TRADE     = 0.3
local TRIES           = 2
local STREAK_LIMIT    = 6

local COLOR_INFO = 207
local COLOR_GOOD = 158
local COLOR_WARN = 167
local COLOR_DIM  = 160

-- Porter zones
local PORTER_MENUS = {
    [231] = 874,    -- Northern San d'Oria
    [235] = 547,    -- Bastok Markets
    [240] = 870,    -- Port Windurst
    [245] = 10106,  -- Lower Jeuno
    [80]  = 661,    -- Southern San d'Oria [S]
    [87]  = 603,    -- Bastok Markets [S]
    [94]  = 525,    -- Windurst Waters [S]
    [247] = 138,    -- Rabao
    [248] = 1139,   -- Selbina
    [249] = 338,    -- Mhaura
    [250] = 309,    -- Kazham
    [252] = 246,    -- Norg
    [26]  = 621,    -- Tavnazian Safehold
    [50]  = 959,    -- Aht Urhgan Whitegate
    [53]  = 330,    -- Nashmau
    [256] = 43,     -- Western Adoulin
    [280] = 802,    -- Mog Garden
    [298] = 13,     -- Walk of Echoes [P1]
    [279] = 13,     -- Walk of Echoes [P2]
}

-- ===========================================================================
--  State
-- ===========================================================================

local state = {
    packet       = 0,      -- 0 idle | 1 traded | 2 menu patched | 3 closing
    busy         = false,
    gen          = 0,
    cancelled    = false,
    client_close = false,
}

-- ===========================================================================
--  Chat
-- ===========================================================================

local function say(text, color)
    windower.add_to_chat(color or COLOR_INFO, '[SlipPacker] ' .. text)
end

local function warn(text)
    say(text, COLOR_WARN)
end

local function print_wrapped(words, color)
    local line = ''
    for _, word in ipairs(words) do
        if line ~= '' and #line + #word + 2 > WRAP then
            windower.add_to_chat(color or COLOR_DIM, '   ' .. line)
            line = word
        else
            line = line == '' and word or (line .. ', ' .. word)
        end
    end
    if line ~= '' then
        windower.add_to_chat(color or COLOR_DIM, '   ' .. line)
    end
end

-- ===========================================================================
--  Slip data
-- ===========================================================================

local slip_number = {}
local item_slip   = {}

for number, slip_id in ipairs(slips.storages) do
    slip_number[slip_id] = number
    for _, item_id in ipairs(slips.items[slip_id] or {}) do
        item_slip[item_id] = item_slip[item_id] or slip_id
    end
end

local function is_slip(id)
    return slip_number[id] ~= nil
end

local function capacity(slip_id)
    local list = slips.items[slip_id]
    return list and #list or 0
end

local function item_name(id)
    local record = res.items[id]
    return record and record.name or ('Item ' .. id)
end

local function bag_name(bag)
    local record = res.bags[bag]
    return record and record.name or ('Bag ' .. bag)
end

local function names_of(ids)
    local names = {}
    for i, id in ipairs(ids) do
        names[i] = item_name(id)
    end
    table.sort(names)
    return names
end

local function stored_on(slip_item)
    local list = slips.items[slip_item.id]
    local ext  = slip_item.extdata or ''
    local out  = {}
    if not list then
        return out
    end
    for i = 0, math.min(#list, #ext * 8) - 1 do
        local byte = ext:byte(math.floor(i / 8) + 1)
        if math.floor(byte / 2 ^ (i % 8)) % 2 == 1 then
            out[#out + 1] = list[i + 1]
        end
    end
    return out
end

local function as_set(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

local function slips_in(bags)
    local found, seen = {}, {}
    for _, bag in ipairs(bags) do
        for _, item in ipairs(windower.ffxi.get_items(bag) or {}) do
            if is_slip(item.id) and not seen[item.id] then
                seen[item.id] = true
                found[#found + 1] = { item = item, bag = bag }
            end
        end
    end
    table.sort(found, function(a, b) return slip_number[a.item.id] < slip_number[b.item.id] end)
    return found
end

local function find_slip(slip_id, bags)
    for _, entry in ipairs(slips_in(bags)) do
        if entry.item.id == slip_id then
            return entry.item, entry.bag
        end
    end
end

-- ===========================================================================
--  Porter rules
-- ===========================================================================

local function augment_done(ext)
    local stage, final = ext:byte(2), ext:byte(12)
    return stage ~= nil and final ~= nil and stage % 0x80 >= 0x40 and final >= 0x80
end

local function porter_takes(item, slip_id)
    local ext = item.extdata or ''
    if slip_id == slips.storages[AUG_SLIP] then
        return augment_done(ext)
    end
    return ext:byte(1) ~= 2 or augment_done(ext)
end

-- ===========================================================================
--  Inventory scan
-- ===========================================================================

local function scan(only_slip, skip)
    skip = skip or {}

    local held, stored = {}, {}
    for _, entry in ipairs(slips_in({ INVENTORY })) do
        held[entry.item.id]   = entry.item
        stored[entry.item.id] = as_set(stored_on(entry.item))
    end

    local plan = {
        groups  = {},
        order   = {},
        no_slip = {},
        on_slip = {},
        refused = {},
        held    = held,
    }

    local seen = {}
    for _, item in ipairs(windower.ffxi.get_items(INVENTORY) or {}) do
        local slip_id = item.id ~= 0 and item.status == 0 and item_slip[item.id]
        if slip_id and not seen[item.id] and not skip[item.id]
                and (not only_slip or only_slip == slip_id) then
            seen[item.id] = true
            if not held[slip_id] then
                plan.no_slip[slip_id] = plan.no_slip[slip_id] or {}
                table.insert(plan.no_slip[slip_id], item.id)
            elseif stored[slip_id][item.id] then
                plan.on_slip[#plan.on_slip + 1] = item.id
            elseif not porter_takes(item, slip_id) then
                plan.refused[#plan.refused + 1] = item.id
            else
                local group = plan.groups[slip_id]
                if not group then
                    group = { slip = held[slip_id], items = {} }
                    plan.groups[slip_id] = group
                    plan.order[#plan.order + 1] = slip_id
                end
                group.items[#group.items + 1] = item
            end
        end
    end

    table.sort(plan.order, function(a, b) return slip_number[a] < slip_number[b] end)
    return plan
end

-- ===========================================================================
--  Packets
-- ===========================================================================

local function porter_menu(zone, menu)
    local retrieve = PORTER_MENUS[zone]
    if not retrieve then
        return nil
    elseif menu == retrieve - 1 then
        return 'store'
    elseif menu == retrieve then
        return 'retrieve'
    end
end

local function reply(data, option, confirm)
    local npc_id    = data:unpack('I', OFF_NPC_ID + 1)
    local npc_index = data:unpack('H', OFF_NPC_INDEX + 1)
    local zone, menu = data:unpack('H2', OFF_ZONE_MENU + 1)
    windower.packets.inject_outgoing(PKT_MENU_REPLY,
        ('I3H4'):pack(0, npc_id, option, npc_index, confirm, zone, menu))
end

local function close_menu()
    local data = windower.packets.last_incoming(PKT_MENU_OPEN)
    if data and #data >= OFF_ZONE_MENU + 4 then
        local zone, menu = data:unpack('H2', OFF_ZONE_MENU + 1)
        if porter_menu(zone, menu) then
            reply(data, MENU_CLOSE, 0)
        end
    end
    state.packet       = 0
    state.client_close = false
end

local function trade(npc, slip_item, items, limit)
    local batch = { slip_item }
    for i = 1, math.min(#items, limit, TRADE_SLOTS - 1) do
        batch[#batch + 1] = items[i]
    end

    local counts, slots = {}, {}
    for i = 1, TRADE_SLOTS do
        local item = batch[i]
        counts[i] = ('I'):pack(item and item.count or 0)
        slots[i]  = ('C'):pack(item and item.slot or 0)
    end

    state.packet = 1
    windower.packets.inject_outgoing(PKT_TRADE, table.concat {
        ('I2'):pack(0, npc.id),
        table.concat(counts),
        ('I2'):pack(0, 0),
        table.concat(slots),
        ('C2HI'):pack(0, 0, npc.index, #batch),
    })

    local ids = {}
    for i = 2, #batch do
        ids[#ids + 1] = batch[i].id
    end
    return ids
end

windower.register_event('incoming chunk', function(id, data)
    if id == PKT_MENU_OPEN and state.packet == 1 and #data >= OFF_ZONE_MENU + 4 then
        local zone, menu = data:unpack('H2', OFF_ZONE_MENU + 1)
        local kind = porter_menu(zone, menu)
        if kind == 'retrieve' then
            state.packet = 3
            reply(data, MENU_CLOSE, 0)
            return true
        elseif kind == 'store' and data:byte(OFF_GATE + 1) == 0 then
            state.packet       = 2
            state.client_close = true
            return data:sub(1, 8) .. string.char(1, 0, 0, 0, 1) .. data:sub(OFF_GATE + 2)
        end

    elseif id == PKT_MENU_CLOSE and state.packet ~= 0 then
        if state.packet == 3 then
            state.packet       = 0
            state.client_close = false
        elseif state.packet == 2 and not state.client_close and data:byte(5) == 2 then
            state.cancelled = true
            state.packet    = 0
        end
    end
end)

windower.register_event('outgoing chunk', function(id, data, modified, injected)
    if id == PKT_MENU_REPLY and state.packet ~= 0 and not injected then
        state.client_close = false
        state.packet       = 3
    end
end)

windower.register_event('incoming text', function(original, modified, mode)
    if state.busy and (mode == 150 or mode == 151) then
        return (modified:gsub(string.char(0x7F, 0x31), ''))
    end
end)

-- ===========================================================================
--  Waits
-- ===========================================================================

local function wait_idle()
    for _ = 1, math.floor(TRADE_TIMEOUT / POLL) do
        if state.packet == 0 then
            return true
        end
        coroutine.sleep(POLL)
    end
    return state.packet == 0
end

local function wait_landed(slip_id, ids, polls)
    local on = {}
    for _ = 1, polls do
        local slip = find_slip(slip_id, { INVENTORY })
        on = slip and as_set(stored_on(slip)) or {}
        local all = true
        for _, id in ipairs(ids) do
            if not on[id] then
                all = false
                break
            end
        end
        if all then
            return on
        end
        coroutine.sleep(LAND_POLL)
    end
    return on
end

local function wait_settled()
    local last
    for _ = 1, 30 do
        local parts = {}
        for i, item in ipairs(windower.ffxi.get_items(INVENTORY) or {}) do
            parts[i] = item.id .. ':' .. item.count
        end
        local now = table.concat(parts, ',')
        if now == last then
            return
        end
        last = now
        coroutine.sleep(0.05)
    end
end

-- ===========================================================================
--  Checks
-- ===========================================================================

local function find_porter()
    local info = windower.ffxi.get_info()
    if not info or not PORTER_MENUS[info.zone] then
        return nil, 'No Porter Moogle in this zone.'
    end
    local npc = windower.ffxi.get_mob_by_name(PORTER_NAME)
    local ok = npc and npc.valid_target and npc.is_npc
        and npc.distance < RANGE_SQ
        and bit.band(npc.spawn_type, 0xDF) == 2
    if not ok then
        return nil, 'Porter Moogle is not in range.'
    end
    return npc
end

local function player_ready()
    local player = windower.ffxi.get_player()
    if not player then
        return false, 'Not logged in.'
    end
    if player.status ~= 0 then
        return false, 'You need to be idle: not engaged, resting, or in a menu.'
    end
    return true
end

local function slip_arg(arg)
    local number = tonumber(arg)
    local slip_id = number and slips.storages[number]
    if arg and not slip_id then
        warn(('No storage slip %s.'):format(arg))
        return nil, true
    end
    return slip_id
end

local function pack_cmd(only_slip)
    return only_slip and ('//sp pack ' .. slip_number[only_slip]) or '//sp pack'
end

local function report_leftovers(plan)
    local needed = {}
    for slip_id in pairs(plan.no_slip) do
        needed[#needed + 1] = slip_id
    end
    table.sort(needed, function(a, b) return slip_number[a] < slip_number[b] end)

    for _, slip_id in ipairs(needed) do
        local ids = plan.no_slip[slip_id]
        local _, bag = find_slip(slip_id, ALL_BAGS)
        if bag then
            say(('Slip %d is in your %s. Move it to inventory to pack %d item(s):'):format(
                slip_number[slip_id], bag_name(bag), #ids), COLOR_WARN)
        else
            say(('Missing slip %d. You do not have it in any bag. %d item(s) need it:'):format(
                slip_number[slip_id], #ids), COLOR_WARN)
        end
        print_wrapped(names_of(ids))
    end

    if #plan.on_slip > 0 then
        say(('%d item(s) already have a copy on their slip:'):format(#plan.on_slip), COLOR_WARN)
        print_wrapped(names_of(plan.on_slip))
    end
    if #plan.refused > 0 then
        say(('%d item(s) the porter will not take (augment rules):'):format(#plan.refused), COLOR_WARN)
        print_wrapped(names_of(plan.refused))
    end
end

-- ===========================================================================
--  Pack
-- ===========================================================================

local function pack(only_slip)
    if state.busy then
        return warn('Already packing. //sp stop to cancel.')
    end
    local ready, why = player_ready()
    if not ready then
        return warn(why)
    end
    local npc, err = find_porter()
    if not npc then
        return warn(err)
    end

    local first = scan(only_slip)
    if #first.order == 0 then
        if next(first.held) == nil then
            warn('No storage slips in inventory.')
        else
            say('Nothing in inventory to pack.')
        end
        return report_leftovers(first)
    end

    state.gen       = state.gen + 1
    state.busy      = true
    state.cancelled = false
    local gen = state.gen

    local skip, skipped   = {}, {}
    local solo, fails     = {}, {}
    local packed, touched = 0, {}
    local streak          = 0
    local stop_reason

    say('Packing. Do not move until it finishes.')

    while true do
        if state.gen ~= gen then
            break
        end

        local plan = scan(only_slip, skip)
        local slip_id = plan.order[1]
        if not slip_id then
            break
        end

        local ok_player, why_player = player_ready()
        if not ok_player then
            stop_reason = why_player
            break
        end
        npc, err = find_porter()
        if not npc then
            stop_reason = err
            break
        end

        local group = plan.groups[slip_id]
        local ids = trade(npc, group.slip, group.items, solo[slip_id] and 1 or TRADE_SLOTS)

        local answered = wait_idle()
        if not answered then
            close_menu()
        end
        if state.gen ~= gen then
            break
        end
        if state.cancelled then
            stop_reason = 'Porter menu was cancelled.'
            break
        end

        local on = wait_landed(slip_id, ids, answered and LAND_POLLS or LAND_POLLS_LATE)
        local count = 0
        for _, id in ipairs(ids) do
            if on[id] then
                count = count + 1
            end
        end

        if count > 0 then
            packed = packed + count
            touched[slip_id] = (touched[slip_id] or 0) + count
            say(('Slip %d: stored %d'):format(slip_number[slip_id], count), COLOR_GOOD)
            fails[slip_id] = 0
            solo[slip_id]  = nil
            streak = 0
            wait_settled()
            coroutine.sleep(AFTER_TRADE)
        else
            streak = streak + 1
            if not solo[slip_id] and #ids > 1 then
                solo[slip_id] = true
            else
                fails[slip_id] = (fails[slip_id] or 0) + 1
                if fails[slip_id] >= TRIES then
                    fails[slip_id] = 0
                    skip[ids[1]] = true
                    skipped[#skipped + 1] = ids[1]
                end
            end
            if streak >= STREAK_LIMIT then
                stop_reason = 'Porter stopped responding. Zone and try again.'
                skipped = {}
                break
            end
            coroutine.sleep(RETRY_PAUSE)
        end
    end

    if state.gen == gen then
        state.busy   = false
        state.packet = 0
    end

    local slip_count = 0
    for _ in pairs(touched) do
        slip_count = slip_count + 1
    end

    if stop_reason then
        warn(stop_reason)
    end
    say(('Done. Packed %d item(s) onto %d slip(s).'):format(packed, slip_count), COLOR_GOOD)
    if #skipped > 0 then
        warn(('Porter would not take %d item(s):'):format(#skipped))
        print_wrapped(names_of(skipped))
    end

    local after = scan(only_slip, skip)
    local left = 0
    for _, slip_id in ipairs(after.order) do
        left = left + #after.groups[slip_id].items
    end
    if left > 0 then
        warn(('%d item(s) still waiting to pack. %s to continue.'):format(left, pack_cmd(only_slip)))
    end
    report_leftovers(after)
end

-- ===========================================================================
--  Check
-- ===========================================================================

local function check(only_slip)
    local plan = scan(only_slip)
    if next(plan.held) == nil then
        warn('No storage slips in inventory.')
    end
    if #plan.order == 0 then
        say('Nothing in inventory to pack.')
    else
        local total = 0
        for _, slip_id in ipairs(plan.order) do
            local items = plan.groups[slip_id].items
            local ids = {}
            for i, item in ipairs(items) do
                ids[i] = item.id
            end
            total = total + #ids
            say(('Slip %d: %d to pack'):format(slip_number[slip_id], #ids))
            print_wrapped(names_of(ids))
        end
        say(('%d item(s) ready to pack. %s to store them.'):format(total, pack_cmd(only_slip)), COLOR_GOOD)
    end
    report_leftovers(plan)
end

-- ===========================================================================
--  List / Show
-- ===========================================================================

local function list(scope)
    local bags = scope == 'all' and ALL_BAGS or { INVENTORY }
    local found = slips_in(bags)
    if #found == 0 then
        warn(scope == 'all' and 'No storage slips found.' or 'No storage slips in inventory.')
    end
    for _, entry in ipairs(found) do
        local slip_id = entry.item.id
        local where = entry.bag ~= INVENTORY and ('  (' .. bag_name(entry.bag) .. ')') or ''
        say(('Slip %2d: %3d / %d stored%s'):format(
            slip_number[slip_id], #stored_on(entry.item), capacity(slip_id), where))
    end

    local owned = {}
    for _, entry in ipairs(slips_in(ALL_BAGS)) do
        owned[entry.item.id] = entry.bag
    end

    local elsewhere, missing = {}, {}
    for number, slip_id in ipairs(slips.storages) do
        local bag = owned[slip_id]
        if not bag then
            missing[#missing + 1] = tostring(number)
        elseif bag ~= INVENTORY and scope ~= 'all' then
            elsewhere[#elsewhere + 1] = ('%d (%s)'):format(number, bag_name(bag))
        end
    end

    if #elsewhere > 0 then
        say('Not in inventory:', COLOR_WARN)
        print_wrapped(elsewhere)
    end
    if #missing > 0 then
        say(('Missing %d slip(s), not in any bag:'):format(#missing), COLOR_WARN)
        print_wrapped(missing)
    end
end

local function show_one(item, bag)
    local ids = stored_on(item)
    local where = bag ~= INVENTORY and ('  (' .. bag_name(bag) .. ')') or ''
    say(('Slip %d: %d / %d stored%s'):format(
        slip_number[item.id], #ids, capacity(item.id), where), COLOR_GOOD)
    if #ids == 0 then
        windower.add_to_chat(COLOR_DIM, '   (empty)')
    else
        print_wrapped(names_of(ids))
    end
end

local function show(arg)
    if arg == nil or arg == 'all' then
        local found = slips_in(arg == 'all' and ALL_BAGS or { INVENTORY })
        if #found == 0 then
            return warn('No storage slips found.')
        end
        for _, entry in ipairs(found) do
            show_one(entry.item, entry.bag)
        end
        return
    end

    local slip_id, bad = slip_arg(arg)
    if bad then
        return
    end
    local item, bag = find_slip(slip_id, ALL_BAGS)
    if not item then
        return warn(('You do not have slip %s in any bag.'):format(arg))
    end
    show_one(item, bag)
end

local function items(arg)
    if not arg then
        return warn('Usage: //sp items <slip #>')
    end
    local slip_id, bad = slip_arg(arg)
    if bad then
        return
    end

    local all = {}
    for i, id in ipairs(slips.items[slip_id] or {}) do
        all[i] = id
    end

    local item, bag = find_slip(slip_id, ALL_BAGS)
    if not item then
        say(('Slip %d holds %d item(s). You do not have this slip.'):format(
            slip_number[slip_id], #all), COLOR_WARN)
        return print_wrapped(names_of(all))
    end

    local on = as_set(stored_on(item))
    local stored, open = {}, {}
    for _, id in ipairs(all) do
        if on[id] then
            stored[#stored + 1] = id
        else
            open[#open + 1] = id
        end
    end

    local where = bag ~= INVENTORY and ('  (' .. bag_name(bag) .. ')') or ''
    say(('Slip %d holds %d item(s)%s'):format(slip_number[slip_id], #all, where), COLOR_GOOD)
    say(('Stored (%d):'):format(#stored), COLOR_GOOD)
    if #stored == 0 then
        windower.add_to_chat(COLOR_DIM, '   (none)')
    else
        print_wrapped(names_of(stored))
    end
    say(('Not stored (%d):'):format(#open))
    if #open == 0 then
        windower.add_to_chat(COLOR_DIM, '   (none)')
    else
        print_wrapped(names_of(open))
    end
end

-- ===========================================================================
--  Dump
-- ===========================================================================

local function dump()
    local player = windower.ffxi.get_player()
    if not player then
        return
    end
    local found = slips_in(ALL_BAGS)
    if #found == 0 then
        return warn('No storage slips found.')
    end

    local dir = windower.addon_path .. '/data/'
    if not windower.dir_exists(dir) then
        windower.create_dir(dir)
    end
    local path = dir .. player.name .. '_slips.txt'
    local file = io.open(path, 'w')
    if not file then
        return warn('Could not write ' .. path)
    end

    for _, entry in ipairs(found) do
        local ids = stored_on(entry.item)
        file:write(('Slip %d  %d / %d  [%s]\n'):format(
            slip_number[entry.item.id], #ids, capacity(entry.item.id), bag_name(entry.bag)))
        for _, name in ipairs(names_of(ids)) do
            file:write('    ' .. name .. '\n')
        end
        file:write('\n')
    end
    file:close()
    say('Saved to data/' .. player.name .. '_slips.txt', COLOR_GOOD)
end

-- ===========================================================================
--  Stop
-- ===========================================================================

local function stop()
    state.gen = state.gen + 1
    if state.packet ~= 0 then
        close_menu()
    end
    state.busy      = false
    state.cancelled = false
    say('Stopped and reset.')
end

-- ===========================================================================
--  Help
-- ===========================================================================

local function help()
    local lines = {
        '//sp pack [#]      Pack inventory gear into slips in inventory (optional: one slip)',
        '//sp check [#]     Preview what pack would store',
        '//sp list [all]    Slips in inventory with stored counts (all = every bag)',
        '//sp show [#|all]  Items on a slip, or every slip in inventory',
        '//sp items #       Everything a slip can hold, stored and not stored',
        '//sp dump          Write every slip\'s contents to data/<name>_slips.txt',
        '//sp stop          Stop a pack in progress and reset',
    }
    say('Commands:')
    for _, line in ipairs(lines) do
        windower.add_to_chat(COLOR_DIM, '   ' .. line)
    end
end

-- ===========================================================================
--  Events
-- ===========================================================================

windower.register_event('addon command', function(cmd, arg)
    cmd = cmd and cmd:lower() or 'help'
    arg = arg and arg:lower() or nil

    if cmd == 'pack' or cmd == 'p' then
        local slip_id, bad = slip_arg(arg)
        if not bad then
            pack(slip_id)
        end
    elseif cmd == 'check' or cmd == 'c' then
        local slip_id, bad = slip_arg(arg)
        if not bad then
            check(slip_id)
        end
    elseif cmd == 'list' or cmd == 'l' then
        list(arg)
    elseif cmd == 'show' or cmd == 's' then
        show(arg)
    elseif cmd == 'items' or cmd == 'i' then
        items(arg)
    elseif cmd == 'dump' or cmd == 'd' then
        dump()
    elseif cmd == 'stop' or cmd == 'reset' then
        stop()
    else
        help()
    end
end)

windower.register_event('zone change', 'logout', function()
    if state.busy then
        warn('Zoned during a pack. Stopped.')
    end
    state.gen          = state.gen + 1
    state.packet       = 0
    state.busy         = false
    state.cancelled    = false
    state.client_close = false
end)

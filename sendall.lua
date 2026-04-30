require('tables')
local texts = require('texts')
local screen_w = windower.get_windower_settings().ui_x_res
local screen_h = windower.get_windower_settings().ui_y_res
local status_box = texts.new({
    pos = {x = math.floor(screen_w / 3), y = math.floor(screen_h / 1.75)},
    text = {font = 'Consolas', size = 10,
        stroke = {
            alpha = 255,
            red = 0,
            green = 0,
            blue = 0,
            width = 1,
            padding = 1
        }
},
    bg = {alpha = 190, red = 0, green = 65, blue = 90},
    flags = {right = false, bottom = false},
})
status_box:hide()
-- =========================
-- Vars
-- =========================
local scans = {}
local scan_counter = 0
local last_known_count = 1
local max_timeout = 0.15
local quiet_time = 0.03
local pending_confirms = {}
local active_warp_id = nil
current_warp_id = nil
warp_sender = nil
local spinner_frames = {'|', '/', '-', '\\'}
local spinner_index = 1
-- =========================
-- Helper functionators
-- =========================

local function get_spinner()
    local frame = spinner_frames[spinner_index]
    spinner_index = (spinner_index % #spinner_frames) + 1
    return frame
end
local function get_player_name()
    local me = windower.ffxi.get_mob_by_target('me')
    return me and me.name
end

local function make_id()
    return tostring(os.clock()) .. '_' .. tostring(math.random(1000,9999))
end

local function exec(participant, msg)
    windower.send_ipc_message('execute '..participant..' '..msg)
end

local function get_missing_players(entry)
    local missing = {}
    if entry then
        for _, name in ipairs(entry.expected) do
            if not entry.received[name] then
                missing[#missing+1] = name
            end
        end
    end
    return missing
end

-- =========================
-- Send All
-- =========================
function send_all(msg, delay, participants)
    if participants == nil then
        participants = get_participants()
    end

    local total_delay = 0
    local me = get_player_name()

    for _,c in ipairs(participants) do
        if c == me then
            receive_send_all:schedule(total_delay, msg)
        else
            exec:schedule(total_delay, c, msg)
        end
        total_delay = total_delay + delay
    end
end

function receive_send_all(msg)
    print('receive_send_all not overridden! msg: '..msg)
end

-- =========================
-- Scan System
-- =========================
local function start_scan()
    scan_counter = scan_counter + 1
    local id = scan_counter

    local player = get_player_name()
    if not player then return nil end

    scans[id] = {
        participants = {[player] = true}, -- dedup via keys
        start_time = os.clock(),
    }
    
    windower.send_ipc_message('marco '..player..' '..id)
    return id
end

function get_participants()
    local id = start_scan()
    if not id then return T{} end

    if last_known_count >= 7 then quiet_time = 0.06 -- about 6 passes; Increase required time since polo for larger multibox systems.
    elseif last_known_count <= 6 then quiet_time = 0.03 end --atleast 3 passes.
    local start = os.clock()
    local last_increase = os.clock()

    local last_count = 0
    while os.clock() - start < max_timeout do
        local scan = scans[id]
        if not scan then break end

        -- count participants
        local count = 0
        for _ in pairs(scan.participants) do
            count = count + 1
        end

        -- we detect the increase
        if count > last_count then
            last_count = count
            last_increase = os.clock()
        end

        -- early return if no new participants for quiet_time
        if os.clock() - last_increase >= quiet_time then
            local result = T{}
            for name,_ in pairs(scan.participants) do
                result:append(name)
            end

            last_known_count = math.max(last_known_count, count)
            scans[id] = nil
            return result
        end

        coroutine.sleep(0.01)
    end

    -- If we experience an unlikely scenario where responses have came in with delay we build the list after max timeout here.
    local scan = scans[id]
    local result = T{}

    if scan then
        local count = 0
        for name,_ in pairs(scan.participants) do
            result:append(name)
            count = count + 1
        end

        last_known_count = math.max(last_known_count, count)
        scans[id] = nil
    end

    return result
end

function send_all_with_confirm(msg, delay, participants, on_complete, readout)
    if participants == nil then
        participants = get_participants()
    end
    warp_sender = windower.ffxi.get_mob_by_target('me').name
    local warp_id = make_id()
    active_warp_id, current_warp_id = warp_id, warp_id

    pending_confirms[warp_id] = {
        expected = participants,
        received = {},
        callback = on_complete
    }

    local total_delay = 0
    local me = get_player_name()

    for _,c in ipairs(participants) do
        if c == me then
            coroutine.schedule(function()
                receive_send_all(msg)
            end, total_delay)
        else
            coroutine.schedule(function()
                windower.send_ipc_message('execute '..warp_id..' '..c..' '..msg)
            end, total_delay)
        end

        total_delay = total_delay + delay
    end

    -- start completion watcher
    coroutine.schedule(function()
        local timeoutinator = os.clock() + 15
        local complete = true
        while pending_confirms[warp_id] and active_warp_id == warp_id and os.clock() < timeoutinator do
            local entry = pending_confirms[warp_id]
            if readout then
                local missing = entry and get_missing_players(entry)
                if #missing > 0 then
                    status_box:text(
                    string.format(
                        '[ superwarp ] %s \n\nWaiting on (%d/%d)\n  %s ',
                        get_spinner(),
                        #missing,
                        #entry.expected,
                        table.concat(missing, '\n  ')
                    )
                    )
                    status_box:show()
                else
                    status_box:hide()
                end
            end
            complete = true
            for _,name in ipairs(entry.expected) do
                if not entry.received[name] then
                    complete = false
                    break
                end
            end

            if complete then
                if entry.callback then
                    entry.callback(warp_id, entry)
                end
                status_box:hide()
                pending_confirms[warp_id] = nil
                active_warp_id = nil
                break
            end
            coroutine.sleep(0.05)
        end
        if not complete then
            local message = table.concat(get_missing_players(pending_confirms[warp_id]), ', ')
            log('Failed to warp '..message)
        end
        
        status_box:hide()
        pending_confirms = {}
        active_warp_id = nil
    end, 0)
end

function warp_listener(confirm, player)
    if confirm and player == warp_sender and pending_confirms[current_warp_id] then
        local warp_id = current_warp_id
        local entry = pending_confirms[warp_id]
        entry.received[player] = true
    else
        active_warp_id = make_id()
        pending_confirms = {}
    end
end

windower.register_event('ipc message', function(msg)
    local args = msg:split(' ')
    local cmd = args[1]
    args:remove(1)

    local player = get_player_name()

    if cmd == 'marco' then
        local sender = args[1]
        local id = tonumber(args[2])

        if id then
            if player then
                windower.send_ipc_message('polo '..player..' '..id)
            else
                coroutine.schedule(function()
                    local retry_player = get_player_name()
                    if retry_player then
                        windower.send_ipc_message('polo '..retry_player..' '..id)
                    end
                end, 0.1)
            end
        end

    elseif cmd == 'polo' then
        local name = args[1]
        local id = tonumber(args[2])

        local scan = id and scans[id]
        if scan and name then
            scan.participants[name] = true -- dedup safe
        end
    elseif cmd == 'confirm' then
        local warp_id = args[1]
        local name = args[2]
        local entry = pending_confirms[warp_id]
        if entry and name then
            entry.received[name] = true
        end
    elseif cmd == 'execute' then
        local warp_id = args[1]
        local target = args[2]
        if player and target == player then
            args:remove(1)
            args:remove(1)
            local msg = args:concat(' ')
            warp_sender = nil
            current_warp_id = warp_id
            -- execute command
            receive_send_all(msg)
        end
    end
end)
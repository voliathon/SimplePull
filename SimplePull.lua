_addon.name = 'SimplePull'
_addon.author = 'PersonalUse'
_addon.version = '1.0'
_addon.commands = {'simplepull', 'sp'}

require('luau')
local texts = require('texts')
local config = require('config')
local packets = require('packets')
local res = require('resources')

-- Default Per-Character Settings Profile
local defaults = {
    role = 'UNSET',           -- Forces the user to pick a role on first load
    leader_name = 'UNSET',    -- Forces the user to set a leader if assisting
    targets = L{},            -- Windower List to store multiple target names
    pull_cmd = '/ma "Carnage Elegy" <t>',
    pull_delay = 5.0,         -- Seconds to stand still and let magic/abilities cast before running!
    pull_radius = 25,         -- Max scanning range from camp (yalms)
    pull_distance = 15,       -- Max distance to execute pull cmd (yalms)
    engage_distance = 4.5,    -- Melee range threshold (yalms)
    ws_name = 'Savage Blade',
    ws_tp = 1000
}

-- Load settings for the current character
local settings = config.load(defaults)

-- State Variables (Intentionally NOT saved to prevent zone-crash running)
local active = false
local camp = {x = 0, y = 0, z = 0, set = false}
local last_check = 0
local last_target_attempt = 0
local last_pull_attempt = 0
local pull_cast_lockout = 0   
local pulled_mob_id = nil     
local state = 'IDLE'

-- Helper: Save settings locally to the XML tree ensuring per-character profiles
local function save_settings()
    settings:save('all')
end

-- Helper: Instant Target by ID via Packet Injection
local function set_target_by_id(mob)
    if not mob or not mob.id then return end
    local player = windower.ffxi.get_player()
    if not player then return end
    
    local packet = packets.new('incoming', 0x058, {
        ['Player'] = player.id,
        ['Target'] = mob.id,
        ['Player Index'] = player.index,
        ['Target Index'] = mob.index,
    })
    packets.inject(packet)
end

-- Helper: Check if our configured pull action is ready
local function is_pull_ready()
    local cmd = string.lower(settings.pull_cmd)
    local action_name = string.match(settings.pull_cmd, '["\'](.-)["\']')
    
    if not action_name then
        if string.find(cmd, "provoke") then action_name = "Provoke"
        elseif string.find(cmd, "dia ii") or string.find(cmd, "dia 2") then action_name = "Dia II"
        elseif string.find(cmd, "dia") then action_name = "Dia"
        elseif string.find(cmd, "bio ii") or string.find(cmd, "bio 2") then action_name = "Bio II"
        elseif string.find(cmd, "bio") then action_name = "Bio"
        elseif string.find(cmd, "flash") then action_name = "Flash"
        elseif string.find(cmd, "stun") then action_name = "Stun"
        elseif string.find(cmd, "stone") then action_name = "Stone"
        elseif string.find(cmd, "elegy") then action_name = "Carnage Elegy"
        elseif string.find(cmd, "nocturne") then action_name = "Pining Nocturne"
        elseif string.find(cmd, "lullaby") then action_name = "Foe Lullaby"
        elseif string.find(cmd, "requiem") then action_name = "Foe Requiem VII"
        elseif string.find(cmd, "threnody") then action_name = "Fire Threnody"
        else return true end
    end

    if string.find(cmd, "/ja") or string.find(cmd, "provoke") then
        if res and res.job_abilities then
            for _, ab in pairs(res.job_abilities) do
                if string.lower(ab.en) == string.lower(action_name) then
                    local recasts = windower.ffxi.get_ability_recasts()
                    return (recasts[ab.recast_id] or 0) == 0
                end
            end
        end
    elseif string.find(cmd, "/ma") or string.find(cmd, "dia") or string.find(cmd, "bio") or string.find(cmd, "flash") or string.find(cmd, "stun") or string.find(cmd, "stone") or string.find(cmd, "elegy") or string.find(cmd, "threnody") or string.find(cmd, "nocturne") or string.find(cmd, "lullaby") or string.find(cmd, "requiem") then
        if res and res.spells then
            for _, sp in pairs(res.spells) do
                if string.lower(sp.en) == string.lower(action_name) then
                    local recasts = windower.ffxi.get_spell_recasts()
                    return (recasts[sp.recast_id] or 0) == 0
                end
            end
        end
    end
    return true
end

-- Default HUD Display Box Configuration
local hud_config = {
    bg = {visible = true, alpha = 160, red = 0, green = 0, blue = 0},
    text = {size = 10, font = 'Consolas', red = 255, green = 255, blue = 255},
    pos = {x = 700, y = 100}
}
local hud = texts.new(hud_config)

-- Pull Action UI Box Configuration
local pull_hud_config = {
    bg = {visible = true, alpha = 180, red = 10, green = 10, blue = 15},
    text = {size = 10, font = 'Consolas', red = 255, green = 255, blue = 255},
    pos = {x = 350, y = 100}
}
local pull_hud = texts.new(pull_hud_config)

-- Helper: Toggle the Standalone Pull Action UI Box
local function toggle_pull_help(force_show)
    if pull_hud:visible() and not force_show then
        pull_hud:hide()
    else
        local str = "\\cs(0,255,0)=== SimplePull: Available Actions ===\\cr\n"
        str = str .. " Use: \\cs(255,255,0)//sp pull <shortcut>\\cr\n"
        str = str .. "-------------------------------------------\n"
        str = str .. " \\cs(0,255,255)provoke\\cr  -> /ja \"Provoke\" <t>\n"
        str = str .. " \\cs(0,255,255)dia\\cr      -> /ma \"Dia\" <t>       | \\cs(0,255,255)dia2\\cr -> /ma \"Dia II\" <t>\n"
        str = str .. " \\cs(0,255,255)bio\\cr      -> /ma \"Bio\" <t>       | \\cs(0,255,255)bio2\\cr -> /ma \"Bio II\" <t>\n"
        str = str .. " \\cs(0,255,255)flash\\cr    -> /ma \"Flash\" <t>     | \\cs(0,255,255)stun\\cr -> /ma \"Stun\" <t>\n"
        str = str .. " \\cs(0,255,255)elegy\\cr    -> /ma \"Carnage Elegy\" | \\cs(0,255,255)threnody\\cr -> /ma \"Fire Threnody\"\n"
        str = str .. " \\cs(0,255,255)nocturne\\cr -> /ma \"Pining Nocturne\"| \\cs(0,255,255)lullaby\\cr  -> /ma \"Foe Lullaby\"\n"
        str = str .. " \\cs(0,255,255)requiem\\cr  -> /ma \"Foe Requiem VII\"| \\cs(0,255,255)ra\\cr       -> /ra <t> (Ranged)\n"
        str = str .. "-------------------------------------------\n"
        str = str .. " * Or custom: \\cs(255,255,0)//sp pull /ma \"Paralyze\"\\cr\n"
        str = str .. " \\cs(255,0,0)* NOTE: /attack is strictly DISABLED!\\cr\n"
        str = str .. " \\cs(150,150,150)[Type //sp pull to close this window]\\cr"
        pull_hud:text(str)
        pull_hud:show()
    end
end

-- Helper: Update visual HUD layout
local function update_hud()
    -- Initial Setup Intercept HUD
    if settings.role == 'UNSET' or (settings.role == 'assist' and settings.leader_name == 'UNSET') then
        local str = "\\cs(0,255,0)=== SimplePull Initial Setup ===\\cr\n\n"
        if settings.role == 'UNSET' then
            str = str .. " Welcome! To begin, please assign a role to this character:\n\n"
            str = str .. " Type: \\cs(255,255,0)//sp role puller\\cr\n"
            str = str .. "   OR: \\cs(255,255,0)//sp role assist\\cr\n"
        elseif settings.role == 'assist' and settings.leader_name == 'UNSET' then
            str = str .. " Role set to: \\cs(0,255,255)ASSIST\\cr\n\n"
            str = str .. " Please assign your party leader's name:\n\n"
            str = str .. " Type: \\cs(255,255,0)//sp leader <name>\\cr\n"
        end
        str = str .. "\n--------------------------------------------------"
        hud:text(str)
        hud:show()
        return
    end

    -- Normal HUD Display
    local target_list = ""
    for _, name in ipairs(settings.targets) do
        target_list = target_list .. name .. ", "
    end
    if target_list == "" then target_list = "None" else target_list = target_list:sub(1, -3) end

    local str = "\\cs(0,255,0)=== SimplePull Control Suite (v1.0) ===\\cr\n"
    str = str .. " Status      : " .. (active and "\\cs(0,255,0)ACTIVE (RUNNING)" or "\\cs(255,0,0)STOPPED (PAUSED)") .. "\\cr (State: " .. state .. ")\n"
    str = str .. " Role        : " .. settings.role:upper() .. (settings.role == 'assist' and (" (Leader: " .. settings.leader_name .. ")") or "") .. "\n"
    str = str .. " Camp Spot   : " .. (camp.set and ("X: " .. math.floor(camp.x) .. " Y: " .. math.floor(camp.y)) or "\\cs(0,255,255)NOT SET (Roaming Mode)\\cr") .. "\n"
    str = str .. " Target Mobs : " .. target_list .. "\n"
    str = str .. " Weapon Skill: " .. settings.ws_name .. " (at " .. settings.ws_tp .. "+ TP)\n"
    str = str .. " Pull Action : " .. settings.pull_cmd .. " \\cs(255,255,0)(Type //sp pull list)\\cr\n"
    str = str .. " Scan Radius : " .. settings.pull_radius .. "y | Pull Dist: " .. settings.pull_distance .. "y | Melee: " .. settings.engage_distance .. "y\n"
    str = str .. " Pull Delay  : " .. settings.pull_delay .. "s \\cs(200,200,200)(Cast lock before running)\\cr\n"
    str = str .. "--------------------------------------------------\n"
    str = str .. "\\cs(255,255,0)How to Operate & Commands (Auto-Saves):\\cr\n"
    str = str .. " \\cs(0,255,255)START / STOP  : //sp start  |  //sp stop\\cr\n"
    str = str .. " Add/Remove Mob: //sp add|remove <name>\n"
    str = str .. " Set/Reset Camp: //sp camp [reset]\n"
    str = str .. " Toggle Role   : //sp role [puller/assist]\n"
    str = str .. " Set Scan Rad  : //sp radius <yalms> (Default: 25)\n"
    str = str .. " Set Pull Dist : //sp pulldist <yalms> (Default: 15)\n"
    str = str .. " Set Melee Dist: //sp melee <yalms> (Default: 4.5)\n"
    str = str .. " Set Pull Delay: //sp delay <seconds> (Default: 2.0)\n"
    str = str .. " Set WS / Pull : //sp ws|pull <name/shortcut>\n"
    
    hud:text(str)
    hud:show()
end

-- Fast math helper
local function distance(x1, y1, x2, y2)
    return math.sqrt((x1 - x2)^2 + (y1 - y2)^2)
end

-- Corrected Trigonometry Run-To-Camp Function
local function run_to_camp(me)
    if not me or not camp.set then return end
    local dx = camp.x - me.x
    local dy = camp.y - me.y
    local angle = -math.atan2(dy, dx)
    windower.ffxi.run(angle)
end

-- Main Automation Loop
windower.register_event('prerender', function()
    if not active then return end

    local now = os.clock()
    if now - last_check < 0.3 then return end
    last_check = now

    local player = windower.ffxi.get_player()
    local me = windower.ffxi.get_mob_by_target('me')
    if not player or not me or player.status == 2 or player.status == 3 then return end

    local my_target = windower.ffxi.get_mob_by_target('t')

    ----------------------------------------------------
    -- PRIORITY 1: PULLER ENGINE 
    ----------------------------------------------------
    if settings.role == 'puller' then
        
        -- CASTING LOCKOUT GUARD
        if now < pull_cast_lockout then
            local remaining = math.max(0, pull_cast_lockout - now)
            state = 'PULLING: CASTING / WAITING (' .. string.format("%.1f", remaining) .. 's)'
            windower.ffxi.run(false)
            update_hud()
            return
        end

        -- ENGAGED STATE HANDLER
        if player.status == 1 then
            if camp.set then
                if distance(me.x, me.y, camp.x, camp.y) > 4 then
                    state = 'RETURNING (DISENGAGING)'
                    windower.send_command('input /attack off')
                    run_to_camp(me)
                    update_hud()
                    return
                end
            end
            state = 'FIGHTING'
            windower.ffxi.run(false)
            if my_target and my_target.hpp > 2 and player.vitals.tp >= settings.ws_tp then
                windower.send_command('input /ws "' .. settings.ws_name .. '" <t>')
            end
            update_hud()
            return
        end

        -- SINGLE-PASS OPTIMIZED MEMORY SWEEP
        local mobs = windower.ffxi.get_mob_array()
        local aggro_mob = nil
        local mob_to_pull = nil
        local shortest_dist = 9999
        local anchor_x = camp.set and camp.x or me.x
        local anchor_y = camp.set and camp.y or me.y

        -- Retain current target if it's already a valid pull to prevent flickering
        if my_target and my_target.valid_target and my_target.hpp > 0 and my_target.claim_id == 0 then
            if distance(anchor_x, anchor_y, my_target.x, my_target.y) <= settings.pull_radius then
                for _, tname in ipairs(settings.targets) do
                    if string.find(string.lower(my_target.name), string.lower(tname)) then
                        mob_to_pull = my_target
                        shortest_dist = distance(me.x, me.y, my_target.x, my_target.y)
                        break
                    end
                end
            end
        end

        for _, mob in pairs(mobs) do
            if mob.valid_target and mob.hpp > 0 then
                -- 1. Check for Aggro (Priority over pulling)
                if mob.claim_id == me.id or mob.target_index == me.index or (pulled_mob_id and mob.id == pulled_mob_id) then
                    aggro_mob = mob
                    pulled_mob_id = mob.id
                end
                
                -- 2. Scan for Pull Targets
                if not mob_to_pull or mob.id ~= mob_to_pull.id then
                    if mob.claim_id == 0 and distance(anchor_x, anchor_y, mob.x, mob.y) <= settings.pull_radius then
                        local is_match = false
                        for _, tname in ipairs(settings.targets) do
                            if string.find(string.lower(mob.name), string.lower(tname)) then
                                is_match = true
                                break
                            end
                        end
                        if is_match then
                            local dist_to_me = distance(me.x, me.y, mob.x, mob.y)
                            if dist_to_me < shortest_dist then
                                mob_to_pull = mob
                                shortest_dist = dist_to_me
                            end
                        end
                    end
                end
            end
        end

        -- AGGRO HANDLER: Returns to camp or engages
        if aggro_mob then
            if camp.set then
                if distance(me.x, me.y, camp.x, camp.y) > 4 then
                    state = 'RETURNING TO CAMP'
                    if my_target and my_target.id == aggro_mob.id then
                        windower.send_command('input /attack off; input /target <me>')
                    end
                    run_to_camp(me)
                    update_hud()
                    return
                else
                    state = 'ARRIVED: ENGAGING'
                    windower.ffxi.run(false)
                    set_target_by_id(aggro_mob)
                    windower.send_command('input /attack on')
                    pulled_mob_id = nil
                    update_hud()
                    return
                end
            else
                state = 'ENGAGING (ROAMING)'
                windower.ffxi.run(false)
                set_target_by_id(aggro_mob)
                windower.send_command('input /attack on')
                pulled_mob_id = nil
                update_hud()
                return
            end
        end

        -- PULL EXECUTION HANDLER
        if mob_to_pull then
            if not is_pull_ready() then
                state = 'COOLDOWN: WAITING AT CAMP'
                if camp.set and distance(me.x, me.y, camp.x, camp.y) > 4 then
                    run_to_camp(me)
                else
                    windower.ffxi.run(false)
                end
                update_hud()
                return
            end

            state = 'PULLING: ' .. mob_to_pull.name
            
            -- Leash abort
            if camp.set and distance(me.x, me.y, camp.x, camp.y) > settings.pull_radius then
                state = 'LEASH ABORT: TOO FAR'
                windower.ffxi.run(false)
                windower.send_command('input /target <me>')
                run_to_camp(me)
                update_hud()
                return
            end

            if not my_target or my_target.id ~= mob_to_pull.id then
                if now - last_target_attempt > 0.3 then
                    last_target_attempt = now
                    set_target_by_id(mob_to_pull)
                end
            end

            if shortest_dist <= settings.pull_distance then
                windower.ffxi.run(false)
                if now - last_pull_attempt > (settings.pull_delay + 0.5) then
                    last_pull_attempt = now
                    pull_cast_lockout = now + settings.pull_delay
                    pulled_mob_id = mob_to_pull.id
                    
                    if camp.set then
                        windower.send_command('input ' .. settings.pull_cmd .. '; wait ' .. (settings.pull_delay - 0.5) .. '; input /attack off; input /target <me>')
                    else
                        windower.send_command('input ' .. settings.pull_cmd)
                    end
                end
            else
                windower.ffxi.follow(mob_to_pull.index)
            end
            update_hud()
            return
        end

        -- IDLE & RE-CENTER
        if camp.set and distance(me.x, me.y, camp.x, camp.y) > 4 then
            state = 'RESETTING CAMP (NO MOBS)'
            run_to_camp(me)
        else
            state = 'IDLE (SCANNING)'
            windower.ffxi.run(false)
        end
        update_hud()
        return
    end

    ----------------------------------------------------
    -- PRIORITY 2: AUTO-ASSIST ENGINE (Alts)
    ----------------------------------------------------
    if settings.role == 'assist' then
        if player.status == 1 and my_target and my_target.hpp > 2 and math.sqrt(my_target.distance) <= settings.engage_distance then
            state = 'FIGHTING'
            if player.vitals.tp >= settings.ws_tp then
                windower.send_command('input /ws "' .. settings.ws_name .. '" <t>')
            end
            update_hud()
            return
        end

        local leader = nil
        local mobs = windower.ffxi.get_mob_array()
        
        for _, mob in pairs(mobs) do
            if string.lower(mob.name) == string.lower(settings.leader_name) then
                leader = mob
                break
            end
        end

        if leader then
            if leader.status == 1 and leader.target_index and leader.target_index > 0 then
                local leader_target = windower.ffxi.get_mob_by_index(leader.target_index)
                
                if leader_target and leader_target.hpp > 0 and leader_target.is_npc then
                    state = 'ASSISTING'
                    
                    if not my_target or my_target.id ~= leader_target.id then
                        if now - last_target_attempt > 0.4 then
                            last_target_attempt = now
                            set_target_by_id(leader_target)
                        end
                    elseif player.status == 0 then
                        if math.sqrt(leader_target.distance) > settings.engage_distance then
                            windower.ffxi.follow(leader_target.index)
                        else
                            windower.ffxi.run(false)
                            windower.send_command('input /attack on')
                        end
                    end
                    update_hud()
                    return
                end
            end
        end
        
        if player.status == 0 then
            if camp.set and distance(me.x, me.y, camp.x, camp.y) > 4 then
                state = 'RESETTING CAMP'
                run_to_camp(me)
            else
                state = 'IDLE'
                windower.ffxi.run(false)
            end
        end
        update_hud()
    end
end)

-- Command Interface & Instructions Router
windower.register_event('addon command', function(cmd, arg1, ...)
    local args = {...}
    local full_arg = arg1 and (arg1 .. ( #args > 0 and (" " .. table.concat(args, " ")) or "" )) or nil
    cmd = cmd and string.lower(cmd)

    if cmd == 'add' and full_arg then
        local found = false
        for _, t in ipairs(settings.targets) do
            if string.lower(t) == string.lower(full_arg) then found = true end
        end
        if not found then
            settings.targets:append(full_arg)
            save_settings()
            windower.add_to_chat(207, '[SimplePull] Added "' .. full_arg .. '" to targets (Saved).')
        else
            windower.add_to_chat(207, '[SimplePull] Target "' .. full_arg .. '" is already in your list!')
        end
    elseif cmd == 'remove' and full_arg then
        local idx = nil
        for i, t in ipairs(settings.targets) do
            if string.lower(t) == string.lower(full_arg) then idx = i end
        end
        if idx then
            local removed_name = settings.targets[idx]
            settings.targets:remove(idx)
            save_settings()
            windower.add_to_chat(207, '[SimplePull] Removed "' .. removed_name .. '" from targets (Saved).')
        else
            windower.add_to_chat(167, '[SimplePull] Target "' .. full_arg .. '" not found.')
        end
    elseif cmd == 'clear' then
        settings.targets:clear()
        save_settings()
        windower.add_to_chat(207, '[SimplePull] Target filter cleared (Saved).')
    elseif cmd == 'camp' then
        if arg1 and (string.lower(arg1) == 'reset' or string.lower(arg1) == 'clear') then
            camp.x, camp.y, camp.z = 0, 0, 0
            camp.set = false
            windower.add_to_chat(207, '[SimplePull] Camp spot reset! Switched to Roaming Mode.')
        else
            local me = windower.ffxi.get_mob_by_target('me')
            camp.x, camp.y, camp.z = me.x, me.y, me.z
            camp.set = true
            windower.add_to_chat(207, '[SimplePull] Camp locked for this session.')
        end
    elseif cmd == 'role' and arg1 then
        local new_role = string.lower(arg1)
        if new_role == 'puller' or new_role == 'assist' then
            settings.role = new_role
            save_settings()
            windower.add_to_chat(207, '[SimplePull] Role switched to: ' .. settings.role:upper() .. ' (Saved).')
        end
    elseif cmd == 'leader' and arg1 then
        settings.leader_name = arg1
        save_settings()
        windower.add_to_chat(207, '[SimplePull] Leader target updated to: ' .. settings.leader_name .. ' (Saved).')
    elseif cmd == 'ws' and full_arg then
        settings.ws_name = full_arg
        save_settings()
        windower.add_to_chat(207, '[SimplePull] Weapon Skill set to: ' .. settings.ws_name .. ' (Saved).')
    elseif cmd == 'tp' and arg1 and tonumber(arg1) then
        settings.ws_tp = tonumber(arg1)
        save_settings()
        windower.add_to_chat(207, '[SimplePull] WS TP threshold set to: ' .. settings.ws_tp .. ' (Saved).')
    elseif cmd == 'radius' and arg1 and tonumber(arg1) then
        settings.pull_radius = tonumber(arg1)
        save_settings()
        windower.add_to_chat(207, '[SimplePull] Scan Radius set to: ' .. settings.pull_radius .. 'y (Saved).')
    elseif (cmd == 'pulldist' or cmd == 'pdist') and arg1 and tonumber(arg1) then
        settings.pull_distance = tonumber(arg1)
        save_settings()
        windower.add_to_chat(207, '[SimplePull] Pull Distance set to: ' .. settings.pull_distance .. 'y (Saved).')
    elseif (cmd == 'engagedist' or cmd == 'edist' or cmd == 'melee') and arg1 and tonumber(arg1) then
        settings.engage_distance = tonumber(arg1)
        save_settings()
        windower.add_to_chat(207, '[SimplePull] Engage/Melee Distance set to: ' .. settings.engage_distance .. 'y (Saved).')
    elseif (cmd == 'pulldelay' or cmd == 'castdelay' or cmd == 'delay') and arg1 and tonumber(arg1) then
        settings.pull_delay = tonumber(arg1)
        save_settings()
        windower.add_to_chat(207, '[SimplePull] Pull/Cast Delay set to: ' .. settings.pull_delay .. 's (Saved).')
    elseif cmd == 'pull' then
        if not full_arg or string.lower(full_arg) == 'list' or string.lower(full_arg) == 'help' then
            toggle_pull_help()
            return
        end
        
        local clean_arg = string.lower(full_arg):gsub("^%s*(.-)%s*$", "%1")
        
        if string.find(clean_arg, "attack") then
            windower.add_to_chat(167, '[SimplePull] ERROR: /attack cannot be used as a pull action!')
            windower.add_to_chat(167, '[SimplePull] Pulling with /attack breaks camp return logic. Use a spell or ability.')
            toggle_pull_help(true)
            return
        end

        if clean_arg == 'provoke' or clean_arg == '/provoke' then
            full_arg = '/ja "Provoke" <t>'
        elseif clean_arg == 'dia' or clean_arg == '/dia' then
            full_arg = '/ma "Dia" <t>'
        elseif clean_arg == 'dia2' or clean_arg == 'dia ii' or clean_arg == '/dia ii' then
            full_arg = '/ma "Dia II" <t>'
        elseif clean_arg == 'bio' or clean_arg == '/bio' then
            full_arg = '/ma "Bio" <t>'
        elseif clean_arg == 'bio2' or clean_arg == 'bio ii' or clean_arg == '/bio ii' then
            full_arg = '/ma "Bio II" <t>'
        elseif clean_arg == 'flash' or clean_arg == '/flash' then
            full_arg = '/ma "Flash" <t>'
        elseif clean_arg == 'stun' or clean_arg == '/stun' then
            full_arg = '/ma "Stun" <t>'
        elseif clean_arg == 'elegy' or clean_arg == '/elegy' then
            full_arg = '/ma "Carnage Elegy" <t>'
        elseif clean_arg == 'threnody' or clean_arg == '/threnody' then
            full_arg = '/ma "Fire Threnody" <t>'
        elseif clean_arg == 'nocturne' or clean_arg == '/nocturne' then
            full_arg = '/ma "Pining Nocturne" <t>'
        elseif clean_arg == 'lullaby' or clean_arg == '/lullaby' then
            full_arg = '/ma "Foe Lullaby" <t>'
        elseif clean_arg == 'requiem' or clean_arg == '/requiem' then
            full_arg = '/ma "Foe Requiem VII" <t>'
        elseif clean_arg == 'ra' or clean_arg == '/ra' or clean_arg == 'ranged' then
            full_arg = '/ra <t>'
        elseif clean_arg == 'stone' or clean_arg == '/stone' then
            full_arg = '/ma "Stone" <t>'
        else
            if not string.find(full_arg, "<t>") then
                full_arg = full_arg .. ' <t>'
            end
        end
        settings.pull_cmd = full_arg
        save_settings()
        pull_hud:hide()
        windower.add_to_chat(207, '[SimplePull] Pull command set to: ' .. settings.pull_cmd .. ' (Saved).')
    elseif cmd == 'save' then
        save_settings()
        windower.add_to_chat(207, '[SimplePull] Settings manually saved for character!')
    elseif cmd == 'start' then
        -- Prevent starting if the initial setup is not complete!
        if settings.role == 'UNSET' or (settings.role == 'assist' and settings.leader_name == 'UNSET') then
            windower.add_to_chat(167, '[SimplePull] ERROR: Please complete initial setup first!')
            return
        end
        active = true
        windower.add_to_chat(207, '[SimplePull] SUITE STARTED!')
    elseif cmd == 'stop' then
        active = false
        windower.ffxi.run(false)
        state = 'IDLE'
        windower.add_to_chat(207, '[SimplePull] SUITE STOPPED.')
    end
    update_hud()
end)

-- Auto-reload profile settings upon character login or zone switch
windower.register_event('login', 'load', function()
    if windower.ffxi.get_info().logged_in then 
        local player = windower.ffxi.get_player()
        if player then
            config.reload(settings)
        end
        update_hud() 
    end
end)

windower.register_event('unload', function() 
    hud:destroy() 
    pull_hud:destroy()
end)
windower.register_event('logout', function() 
    hud:hide() 
    pull_hud:hide()
end)
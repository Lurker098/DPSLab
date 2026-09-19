addon.name      = 'dpslab';
addon.author    = 'OpenAI / Gaia DPSLab project';
addon.version   = '0.6.0-alpha';
addon.desc      = 'Gaia-themed DPS / TP instrumentation with skillchain attribution, accuracy breakdowns, A/B testing, comparison, and persistent benchmark history for Ashita v4.';
addon.link      = '';

require('common');
local chat = require('chat');
local imgui = require('imgui');
local settings = require('settings');
local packets = require('packet_reader');
local profiles = require('profile_scanner');

local socket_ok, socket = pcall(require, 'socket');
local function now()
    if socket_ok and socket and socket.gettime then
        return socket.gettime();
    end
    return os.clock();
end

local default_settings = T{
    log_self_events = false,
    show_raw_tp_events = false,
    active_timeout = 8.0,
};

local addon_settings = settings.load(default_settings);
local state;

local function settings_update(s)
    if s ~= nil then
        addon_settings = s;
        if state then state.settings = addon_settings; end
    end
    settings.save();
end
settings.register('settings', 'settings_update', settings_update);

state = {
    main_open = T{ true },
    hud_open = T{ true },
    show_hud = T{ true },

    -- Live and Group are independent capture domains.  Both default to capture-on
    -- each time the addon loads; stopping one never freezes the other.
    live = {
        enabled = T{ true },
        elapsed = 0,
        started = now(),
    },
    recording = false,
    run_label = 'Idle',
    run_side = '-',
    run_started = 0,

    profile = {
        path = '',
        source = 'auto',
        job = '',
        sub_job = '',
        error = '',
        command_error = '',
        sets = {},
        commands = {},
        last_scan = 0,
    },

    benchmark = {
        manual_mode = T{ false },
        command_group = T{ 0 },
        option_a = T{ 0 },
        option_b = T{ 1 },
        scope = T{ 0 },
        target_lock = T{ false },
        stop_mode = T{ 0 },
        stop_value = T{ 60 },
        manual_name_a = T{ 'Manual Test A' },
        manual_name_b = T{ 'Manual Test B' },
        manual_command_a = T{ '' },
        manual_command_b = T{ '' },
        runs = { A = nil, B = nil },
        current = nil,
        history = {},
        history_selected = T{ -1 },
        history_error = '',
        history_notice = '',
        history_delete_pending = -1,
        compare_notice = '',
    },

    events = {},
    next_event_id = 1,
    max_events = 160,
    entity_cache = {},
    recent_signatures = {},
    tp_candidates = {},
    pending_ws = nil,
    skillchain = {
        last_ws_by_target = {},
        infer_window = 10.0,
    },

    settings = addon_settings,
    clock = {
        active_seconds = 0,
        tp_observable_seconds = 0,
        tp_capped_seconds = 0,
        last_tick = now(),
        last_activity = nil,
        last_activity_tp_capped = nil,
    },
    log = {
        file = nil,
        path = '',
        error = '',
        lines = 0,
    },

    group = {
        enabled = T{ true },
        elapsed = 0,
        started = now(),
        members = {},
        order = {},
        last_refresh = 0,
        last_poll = 0,
        refresh_interval = 0.50,
        poll_interval = 0.10,
        shared_sc_damage = 0,
        unknown_sc_damage = 0,
    },

    debug = {
        action_packets = 0,
        self_action_packets = 0,
        incoming_action_packets = 0,
        parsed_actions = 0,
        parse_errors = 0,
        duplicates = 0,
        player_update_packets = 0,
        character_update_packets = 0,
        outgoing_ws_packets = 0,
        group_action_packets = 0,
        group_tp_polls = 0,
    },

    tp = {
        current = 0,
        last = nil,
        last_delta = 0,
        last_source = '--',
        total_positive = 0,
        melee = 0,
        ranged = 0,
        ws = 0,
        ability = 0,
        incoming = 0,
        passive_unknown = 0,
    },

    stats = {},
    ws = {},
    round_swings = {},
    last_identity_check = 0,
};

local TEST_SCOPES = { 'Auto', 'Melee / TP', 'Ranged', 'WS', 'All' };
local test_scope_combo = 'Auto\0Melee / TP\0Ranged\0WS\0All\0\0';
local STOP_MODES = { 'Manual', 'Seconds', 'Melee Rounds', 'WS Count' };
local stop_mode_combo = 'Manual\0Seconds\0Melee Rounds\0WS Count\0\0';

-- Gaia-inspired UI palette.  Kept local to DPSLab so it does not alter the user's
-- global Ashita / ImGui theme.  Colors are intentionally high-contrast on FFXI's UI.
local GAIA = {
    gold = { 0.93, 0.76, 0.28, 1.00 },
    teal = { 0.24, 0.78, 0.70, 1.00 },
    green = { 0.43, 0.88, 0.55, 1.00 },
    red = { 0.95, 0.38, 0.34, 1.00 },
    muted = { 0.62, 0.68, 0.69, 1.00 },
    window = { 0.045, 0.065, 0.070, 0.97 },
    child = { 0.060, 0.085, 0.090, 0.96 },
    frame = { 0.090, 0.170, 0.170, 1.00 },
    frame_hover = { 0.120, 0.255, 0.245, 1.00 },
    frame_active = { 0.160, 0.340, 0.310, 1.00 },
    button = { 0.080, 0.285, 0.265, 1.00 },
    button_hover = { 0.110, 0.410, 0.365, 1.00 },
    button_active = { 0.145, 0.515, 0.440, 1.00 },
    header_bg = { 0.105, 0.285, 0.270, 1.00 },
    header_hover = { 0.135, 0.390, 0.350, 1.00 },
    header_active = { 0.165, 0.485, 0.415, 1.00 },
    separator = { 0.34, 0.42, 0.40, 0.78 },
    table_header = { 0.080, 0.210, 0.205, 1.00 },
};

local function push_gaia_theme()
    imgui.PushStyleColor(ImGuiCol_WindowBg, GAIA.window);
    imgui.PushStyleColor(ImGuiCol_ChildBg, GAIA.child);
    imgui.PushStyleColor(ImGuiCol_FrameBg, GAIA.frame);
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered, GAIA.frame_hover);
    imgui.PushStyleColor(ImGuiCol_FrameBgActive, GAIA.frame_active);
    imgui.PushStyleColor(ImGuiCol_Button, GAIA.button);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, GAIA.button_hover);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, GAIA.button_active);
    imgui.PushStyleColor(ImGuiCol_Header, GAIA.header_bg);
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, GAIA.header_hover);
    imgui.PushStyleColor(ImGuiCol_HeaderActive, GAIA.header_active);
    imgui.PushStyleColor(ImGuiCol_Separator, GAIA.separator);
    imgui.PushStyleColor(ImGuiCol_TableHeaderBg, GAIA.table_header);
end

local function pop_gaia_theme()
    imgui.PopStyleColor(13);
end

local function header(text)
    imgui.TextColored(GAIA.gold, text);
end

local function good(text)
    imgui.TextColored(GAIA.green, text);
end

local function warn(text)
    imgui.TextColored(GAIA.gold, text);
end

local function muted(text)
    imgui.TextColored(GAIA.muted, text);
end

local function row3(a, b, c)
    imgui.TableNextRow();
    imgui.TableNextColumn(); imgui.Text(tostring(a));
    imgui.TableNextColumn(); imgui.Text(tostring(b));
    imgui.TableNextColumn(); imgui.Text(tostring(c));
end

local function get_current_tp()
    local mm = AshitaCore:GetMemoryManager();
    if not mm then return 0; end
    local party = mm:GetParty();
    if not party then return 0; end
    return party:GetMemberTP(0) or 0;
end

local function get_player_id()
    local mm = AshitaCore:GetMemoryManager();
    if not mm then return 0; end
    local party = mm:GetParty();
    if not party or party:GetMemberIsActive(0) ~= 1 then return 0; end
    return party:GetMemberServerId(0) or 0;
end

local EQUIP_SLOTS = {
    { id = 0, name = 'Main' }, { id = 1, name = 'Sub' }, { id = 2, name = 'Range' }, { id = 3, name = 'Ammo' },
    { id = 4, name = 'Head' }, { id = 5, name = 'Body' }, { id = 6, name = 'Hands' }, { id = 7, name = 'Legs' },
    { id = 8, name = 'Feet' }, { id = 9, name = 'Neck' }, { id = 10, name = 'Waist' }, { id = 11, name = 'Ear1' },
    { id = 12, name = 'Ear2' }, { id = 13, name = 'Ring1' }, { id = 14, name = 'Ring2' }, { id = 15, name = 'Back' },
};

local function equipment_snapshot()
    local mm = AshitaCore:GetMemoryManager();
    local inv = mm and mm:GetInventory() or nil;
    local rm = AshitaCore:GetResourceManager();
    local snapshot = {};
    if not inv or not rm then return snapshot; end

    for _, slot in ipairs(EQUIP_SLOTS) do
        local name = '--';
        local equipped = inv:GetEquippedItem(slot.id);
        if equipped and equipped.Index and equipped.Index ~= 0 then
            local container = bit.band(equipped.Index, 0xFF00) / 0x0100;
            local index = equipped.Index % 0x0100;
            local item = inv:GetContainerItem(container, index);
            if item and item.Id and item.Id > 0 then
                local res = rm:GetItemById(item.Id);
                if res and res.Name and res.Name[1] and #res.Name[1] > 0 then
                    name = res.Name[1];
                else
                    name = 'Item #' .. tostring(item.Id);
                end
            end
        end
        snapshot[slot.name] = name;
    end
    return snapshot;
end

local function equipment_fingerprint(snapshot)
    local parts = {};
    snapshot = snapshot or {};
    for _, slot in ipairs(EQUIP_SLOTS) do
        table.insert(parts, slot.name .. '=' .. tostring(snapshot[slot.name] or '--'));
    end
    return table.concat(parts, '|');
end

local function serialize_equipment(snapshot)
    return equipment_fingerprint(snapshot);
end

local function deserialize_equipment(text)
    local out = {};
    for pair in tostring(text or ''):gmatch('[^|]+') do
        local k, v = pair:match('^([^=]+)=(.*)$');
        if k then out[k] = v; end
    end
    return out;
end

local function live_elapsed()
    local elapsed = state.live.elapsed or 0;
    if state.live.enabled[1] and state.live.started then
        elapsed = elapsed + math.max(0, now() - state.live.started);
    end
    return elapsed;
end

local function group_elapsed()
    local elapsed = state.group.elapsed or 0;
    if state.group.enabled[1] and state.group.started then
        elapsed = elapsed + math.max(0, now() - state.group.started);
    end
    return elapsed;
end

local function start_live_capture()
    if state.live.enabled[1] then return; end
    state.live.enabled[1] = true;
    state.live.started = now();
    state.clock.last_activity = nil;
    state.clock.last_activity_tp_capped = nil;
    state.tp.last = get_current_tp();
    state.tp.current = state.tp.last;
end

local function stop_live_capture()
    if not state.live.enabled[1] then return; end
    state.live.elapsed = (state.live.elapsed or 0) + math.max(0, now() - (state.live.started or now()));
    state.live.started = nil;
    state.live.enabled[1] = false;
    state.clock.last_activity = nil;
    state.clock.last_activity_tp_capped = nil;
    state.tp_candidates = {};
end

local function start_group_capture()
    if state.group.enabled[1] then return; end
    state.group.enabled[1] = true;
    state.group.started = now();
    for _, member in pairs(state.group.members) do
        member.last_activity = nil;
        member.tp_last = member.tp_current;
    end
end

local function stop_group_capture()
    if not state.group.enabled[1] then return; end
    state.group.elapsed = (state.group.elapsed or 0) + math.max(0, now() - (state.group.started or now()));
    state.group.started = nil;
    state.group.enabled[1] = false;
    for _, member in pairs(state.group.members) do member.last_activity = nil; end
end

local function format_elapsed(seconds)
    seconds = math.max(0, tonumber(seconds) or 0);
    local whole = math.floor(seconds);
    local ms = math.floor((seconds - whole) * 1000 + 0.5);
    if ms >= 1000 then
        whole = whole + 1;
        ms = 0;
    end
    local hours = math.floor(whole / 3600);
    local minutes = math.floor((whole % 3600) / 60);
    local secs = whole % 60;
    if hours > 0 then
        return string.format('%02d:%02d:%02d.%03d', hours, minutes, secs, ms);
    end
    return string.format('%02d:%02d.%03d', minutes, secs, ms);
end

local function format_duration_short(seconds)
    seconds = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5));
    local hours = math.floor(seconds / 3600);
    local minutes = math.floor((seconds % 3600) / 60);
    local secs = seconds % 60;
    if hours > 0 then
        return string.format('%02d:%02d:%02d', hours, minutes, secs);
    end
    return string.format('%02d:%02d', minutes, secs);
end

local function active_timeout()
    local value = tonumber(state.settings.active_timeout) or 8.0;
    return math.max(1.0, math.min(30.0, value));
end

-- 0x028 result.param/value is overloaded.  For damage messages it is HP damage,
-- but for buffs / debuffs it is commonly a status-effect id or another effect value.
-- These message ids are the damage-bearing action-message families used by FFXI.
-- The list is intentionally message-driven so Protect/Shell/Haste and status-only
-- mob skills cannot be mistaken for damage simply because their result value > 0.
local DAMAGE_MESSAGES = {
    [1]=true, [2]=true, [33]=true, [44]=true, [67]=true, [77]=true, [110]=true,
    [132]=true, [157]=true, [161]=true, [185]=true, [187]=true, [196]=true,
    [197]=true, [223]=true, [227]=true, [229]=true, [252]=true, [264]=true,
    [265]=true, [274]=true, [281]=true, [288]=true, [289]=true, [290]=true,
    [291]=true, [292]=true, [293]=true, [294]=true, [295]=true, [296]=true,
    [297]=true, [298]=true, [299]=true, [300]=true, [301]=true, [302]=true,
    [310]=true, [317]=true, [352]=true, [353]=true, [379]=true, [413]=true,
    [522]=true, [536]=true, [576]=true, [577]=true, [648]=true, [650]=true,
    [651]=true, [718]=true, [721]=true, [722]=true, [723]=true, [724]=true,
    [725]=true, [726]=true, [727]=true, [728]=true, [729]=true, [732]=true,
    [735]=true, [736]=true, [747]=true, [748]=true, [749]=true, [767]=true,
    [768]=true, [769]=true, [770]=true, [800]=true, [802]=true, [803]=true,
};

local ADDITIONAL_DAMAGE_MESSAGES = {
    [163]=true, -- Additional effect: damage.
    [229]=true, -- Additional effect: additional damage.
};

-- Skillchains are transmitted in the additional-effect portion of 0x028.
-- 288-301 are the classic SC result messages; 385-398 are alternate message
-- variants seen by clients; 767-770 cover Radiance / Umbra variants.
local SKILLCHAIN_MESSAGES = {
    [288]='Light', [289]='Darkness', [290]='Gravitation', [291]='Fragmentation',
    [292]='Distortion', [293]='Fusion', [294]='Compression', [295]='Liquefaction',
    [296]='Induration', [297]='Reverberation', [298]='Transfixion', [299]='Scission',
    [300]='Detonation', [301]='Impaction',
    [385]='Light', [386]='Darkness', [387]='Gravitation', [388]='Fragmentation',
    [389]='Distortion', [390]='Fusion', [391]='Compression', [392]='Liquefaction',
    [393]='Induration', [394]='Reverberation', [395]='Transfixion', [396]='Scission',
    [397]='Detonation', [398]='Impaction',
    [767]='Radiance', [768]='Umbra', [769]='Radiance', [770]='Umbra',
};

local function result_skillchain(result)
    if not result or not result.has_add_effect then return nil, 0; end
    local name = SKILLCHAIN_MESSAGES[result.add_message or -1];
    local damage = tonumber(result.add_value) or 0;
    if name and damage > 0 then return name, damage; end
    return nil, 0;
end

local function result_is_damage(category, result)
    if not result then return false; end
    -- Auto-attacks and completed ranged attacks carry HP damage directly when they land.
    if category == 1 or category == 2 then
        return result.reaction == 0 and (result.value or 0) > 0;
    end
    return DAMAGE_MESSAGES[result.message or -1] == true;
end

local function additional_is_damage(result)
    return result and result.has_add_effect and ADDITIONAL_DAMAGE_MESSAGES[result.add_message or -1] == true;
end

-- The closing 0x028 packet tells us the SC result and damage, but not the opener.
-- For WS-driven chains we infer ownership from the immediately preceding landed WS
-- on the same target.  Unknown is preserved rather than guessed when confidence is low.
local function classify_skillchains(action)
    local events = {};
    local t = now();
    for _, target in ipairs(action.targets or {}) do
        local previous = state.skillchain.last_ws_by_target[target.id];
        for _, result in ipairs(target.actions or {}) do
            local name, damage = result_skillchain(result);
            if name then
                local ownership = 'unknown';
                local opener_actor_id = 0;
                if previous and (t - (previous.clock or 0)) >= 0 and (t - (previous.clock or 0)) <= (state.skillchain.infer_window or 10.0) then
                    opener_actor_id = previous.actor_id or 0;
                    ownership = opener_actor_id == action.actor_id and 'solo' or 'shared';
                end
                table.insert(events, {
                    target_id = target.id,
                    name = name,
                    damage = damage,
                    ownership = ownership,
                    opener_actor_id = opener_actor_id,
                });
            end
        end
    end
    return events;
end

local function update_skillchain_tracker(action)
    -- Deliberately conservative for now: classic weapon-skill chains are reliable.
    -- Magic / pet-created chains remain visible, but may be marked unknown rather than
    -- being incorrectly assigned to a player.
    if not action or action.category ~= 3 then return; end
    local t = now();
    for _, target in ipairs(action.targets or {}) do
        local landed = false;
        for _, result in ipairs(target.actions or {}) do
            if result.reaction == 0 and result_is_damage(3, result) and (result.value or 0) > 0 then
                landed = true;
                break;
            end
        end
        if landed then
            state.skillchain.last_ws_by_target[target.id] = {
                actor_id = action.actor_id,
                clock = t,
            };
        end
    end
end

local function skillchain_totals(action)
    local total, solo, shared, unknown = 0, 0, 0, 0;
    local labels = {};
    local seen = {};
    for _, sc in ipairs(action.skillchains or {}) do
        local damage = tonumber(sc.damage) or 0;
        total = total + damage;
        if sc.ownership == 'solo' then solo = solo + damage;
        elseif sc.ownership == 'shared' then shared = shared + damage;
        else unknown = unknown + damage; end
        local label = string.format('%s %d (%s)', sc.name or 'SC', damage, sc.ownership or 'unknown');
        if not seen[label] then table.insert(labels, label); seen[label] = true; end
    end
    return total, solo, shared, unknown, table.concat(labels, ', ');
end

local function new_group_member(id, name, slot, job, tp)
    return {
        id = id,
        name = name or ('0x%08X'):format(id or 0),
        slot = slot,
        job = job or 0,
        present = true,
        last_seen = now(),

        melee = 0,
        ranged = 0,
        magic = 0,
        ability = 0,
        proc = 0,
        ws = 0,
        skillchain = 0, -- Solo/self-created SC only; shared SC is kept at group level.
        total = 0,

        melee_attempts = 0,
        melee_hits = 0,
        ranged_attempts = 0,
        ranged_hits = 0,
        ws_attempts = 0,
        ws_hits = 0,
        action_count = 0,
        active_seconds = 0,
        tp_observable_seconds = 0,
        tp_capped_seconds = 0,
        last_activity = nil,
        last_activity_tp_capped = false,

        tp_current = tp or 0,
        tp_last = tp,
        tp_positive = 0,
    };
end

local function refresh_group_members(force)
    local t = now();
    if not force and (t - (state.group.last_refresh or 0)) < (state.group.refresh_interval or 0.50) then
        return;
    end
    state.group.last_refresh = t;

    local mm = AshitaCore:GetMemoryManager();
    local party = mm and mm:GetParty() or nil;
    if not party then return; end

    for _, member in pairs(state.group.members) do
        member.present = false;
    end

    local order = {};
    for slot = 0, 17 do
        if party:GetMemberIsActive(slot) == 1 then
            local id = party:GetMemberServerId(slot) or 0;
            local name = party:GetMemberName(slot) or '';
            if id ~= 0 and name ~= '' then
                local tp = party:GetMemberTP(slot) or 0;
                local job = party:GetMemberMainJob(slot) or 0;
                local member = state.group.members[id];
                if not member then
                    member = new_group_member(id, name, slot, job, tp);
                    state.group.members[id] = member;
                end
                member.name = name;
                member.slot = slot;
                member.job = job;
                member.present = true;
                member.last_seen = t;
                if member.tp_last == nil then member.tp_last = tp; end
                member.tp_current = tp;
                table.insert(order, id);
            end
        end
    end
    state.group.order = order;
end

local function mark_group_activity(member, t)
    if not member then return; end
    t = t or now();
    if member.last_activity then
        local gap = t - member.last_activity;
        if gap >= 0 and gap <= active_timeout() then
            member.active_seconds = member.active_seconds + gap;
            local was_capped = member.last_activity_tp_capped == true;
            local is_capped = (member.tp_current or 0) >= 3000;
            if was_capped or is_capped then
                member.tp_capped_seconds = member.tp_capped_seconds + gap;
            else
                member.tp_observable_seconds = member.tp_observable_seconds + gap;
            end
        end
    end
    member.last_activity = t;
    member.last_activity_tp_capped = (member.tp_current or 0) >= 3000;
end

local function group_member_dps(member)
    if not member or (member.active_seconds or 0) <= 0 then return nil; end
    return (member.total or 0) / member.active_seconds;
end

local function group_member_tpps(member)
    if not member or (member.tp_observable_seconds or 0) <= 0 then return nil; end
    return (member.tp_positive or 0) / member.tp_observable_seconds;
end

local function percent(hits, attempts)
    hits = tonumber(hits) or 0;
    attempts = tonumber(attempts) or 0;
    if attempts <= 0 then return nil; end
    return (hits / attempts) * 100;
end

local function group_member_accuracy(member)
    if not member then return nil; end
    -- Keep this aligned with Live Accuracy: melee + ranged only.
    return percent((member.melee_hits or 0) + (member.ranged_hits or 0),
        (member.melee_attempts or 0) + (member.ranged_attempts or 0));
end

local function poll_group_tp(force)
    refresh_group_members(false);
    local t = now();
    if not force and (t - (state.group.last_poll or 0)) < (state.group.poll_interval or 0.10) then
        return;
    end
    state.group.last_poll = t;
    state.debug.group_tp_polls = state.debug.group_tp_polls + 1;

    local mm = AshitaCore:GetMemoryManager();
    local party = mm and mm:GetParty() or nil;
    if not party then return; end

    for _, id in ipairs(state.group.order) do
        local member = state.group.members[id];
        if member and member.present and member.slot ~= nil then
            local new_tp = party:GetMemberTP(member.slot) or 0;
            if member.tp_last == nil then
                member.tp_last = new_tp;
            elseif new_tp ~= member.tp_last then
                local delta = new_tp - member.tp_last;
                if delta > 0 and state.group.enabled[1] then
                    member.tp_positive = member.tp_positive + delta;
                end
                member.tp_last = new_tp;
            end
            member.tp_current = new_tp;
        end
    end
end

local function record_group_action(action)
    local category = action.category;
    if category ~= 1 and category ~= 2 and category ~= 3 and category ~= 4 and category ~= 6 and category ~= 14 and category ~= 15 then
        return false;
    end

    refresh_group_members(false);
    local member = state.group.members[action.actor_id];
    if not member or not member.present then
        refresh_group_members(true);
        member = state.group.members[action.actor_id];
    end
    if not member or not member.present then return false; end

    local damage = 0;
    local proc_damage = 0;
    local attempts = 0;
    local hits = 0;
    for _, target in ipairs(action.targets) do
        for _, r in ipairs(target.actions) do
            attempts = attempts + 1;
            if result_is_damage(category, r) then
                damage = damage + (r.value or 0);
            end
            if r.reaction == 0 then hits = hits + 1; end
            if additional_is_damage(r) and (r.add_value or 0) > 0 then
                proc_damage = proc_damage + r.add_value;
            end
        end
    end

    local _, solo_sc, shared_sc, unknown_sc = skillchain_totals(action);

    if category == 1 then
        member.melee = member.melee + damage;
        member.melee_attempts = member.melee_attempts + attempts;
        member.melee_hits = member.melee_hits + hits;
    elseif category == 2 then
        member.ranged = member.ranged + damage;
        member.ranged_attempts = member.ranged_attempts + attempts;
        member.ranged_hits = member.ranged_hits + hits;
    elseif category == 3 then
        member.ws = member.ws + damage;
        member.ws_attempts = member.ws_attempts + attempts;
        member.ws_hits = member.ws_hits + hits;
    elseif category == 4 then
        member.magic = member.magic + damage;
    elseif category == 6 or category == 14 or category == 15 then
        member.ability = member.ability + damage;
    end

    member.proc = member.proc + proc_damage;
    member.skillchain = member.skillchain + solo_sc;
    state.group.shared_sc_damage = (state.group.shared_sc_damage or 0) + shared_sc;
    state.group.unknown_sc_damage = (state.group.unknown_sc_damage or 0) + unknown_sc;
    member.total = member.melee + member.ranged + member.magic + member.ability + member.proc + member.ws + member.skillchain;
    member.action_count = member.action_count + 1;
    state.debug.group_action_packets = state.debug.group_action_packets + 1;

    -- Keep the Group self row on the same offensive active-time model as Live:
    -- attack / ranged / WS attempts always count; support actions only count if they dealt damage.
    if category == 1 or category == 2 or category == 3 or damage > 0 or proc_damage > 0 or solo_sc > 0 or shared_sc > 0 or unknown_sc > 0 then
        mark_group_activity(member, now());
    end
    return true;
end

-- Active time is committed only between relevant combat events. Long gaps are
-- discarded instead of being retroactively counted when combat resumes.
local function tick_active_clock()
    -- Kept as a deliberate no-op so TP polling can call it without advancing
    -- the active denominator during idle time.
end

local function mark_activity(t)
    t = t or now();
    if state.clock.last_activity then
        local gap = t - state.clock.last_activity;
        if gap >= 0 and gap <= active_timeout() then
            state.clock.active_seconds = state.clock.active_seconds + gap;
            local was_capped = state.clock.last_activity_tp_capped == true;
            local is_capped = (state.tp.current or 0) >= 3000;
            if was_capped or is_capped then
                state.clock.tp_capped_seconds = state.clock.tp_capped_seconds + gap;
            else
                state.clock.tp_observable_seconds = state.clock.tp_observable_seconds + gap;
            end
        end
    end
    state.clock.last_activity = t;
    state.clock.last_activity_tp_capped = (state.tp.current or 0) >= 3000;
    state.clock.last_tick = t;
end

local function active_time()
    return state.clock.active_seconds or 0;
end

local function tp_observable_time()
    return state.clock.tp_observable_seconds or 0;
end

local function capture_elapsed()
    return live_elapsed();
end

local function csv_escape(value)
    local text = tostring(value == nil and '' or value);
    if text:find('[,"\r\n]') then
        text = '"' .. text:gsub('"', '""') .. '"';
    end
    return text;
end

local function parser_log_directory()
    return AshitaCore:GetInstallPath() .. 'addons\\' .. addon.name .. '\\ParserLogs\\';
end

local function close_log()
    if state.log.file then
        state.log.file:flush();
        state.log.file:close();
        state.log.file = nil;
    end
end

local function open_log()
    close_log();
    state.log.error = '';
    local dir = parser_log_directory();
    if not ashita.fs.exists(dir) then
        if ashita.fs.create_directory(dir) == false and not ashita.fs.exists(dir) then
            state.log.error = 'Could not create ParserLogs folder.';
            return false;
        end
    end

    local ident = profiles.get_identity();
    local player = ident and ident.name or 'Player';
    local job = ident and ident.job or 'JOB';
    local stamp = os.date('%Y%m%d_%H%M%S');
    state.log.path = string.format('%s%s_%s_%s.csv', dir, player, job, stamp);
    local file, err = io.open(state.log.path, 'w');
    if not file then
        state.log.error = tostring(err or 'Could not open parser log.');
        state.log.path = '';
        return false;
    end
    state.log.file = file;
    state.log.lines = 0;
    file:write('event_id,local_time,elapsed,type,action,target_or_source,hits,attempts,damage,additional,skillchain,tp_before,tp_after,tp_delta,tp_class,note\n');
    file:flush();
    return true;
end

local function write_log_event(event)
    if not state.settings.log_self_events then return; end
    if not state.log.file and not open_log() then return; end
    local f = state.log.file;
    local row = {
        event.id or '',
        os.date('%Y-%m-%d %H:%M:%S'),
        string.format('%.3f', event.rel or 0),
        event.type or '',
        event.action or '',
        event.target or '',
        event.hits or '',
        event.attempts or '',
        event.damage or 0,
        event.add_damage or 0,
        event.sc_damage or 0,
        event.tp_before or '',
        event.tp_after or '',
        event.tp_delta or '',
        event.tp_class or '',
        event.reaction_note or '',
    };
    for i = 1, #row do row[i] = csv_escape(row[i]); end
    f:write(table.concat(row, ',') .. '\n');
    f:flush();
    state.log.lines = state.log.lines + 1;
end

local function empty_stats()
    return {
        reset_clock = now(),
        first_action = nil,
        last_action = nil,
        total_damage = 0,
        melee_damage = 0,
        ranged_damage = 0,
        ws_damage = 0,
        magic_damage = 0,
        ability_damage = 0,
        add_damage = 0,
        skillchain_damage = 0,
        skillchain_solo_damage = 0,
        skillchain_shared_damage = 0,
        skillchain_unknown_damage = 0,
        melee_rounds = 0,
        melee_attempts = 0,
        melee_hits = 0,
        ranged_shots = 0,
        ranged_attempts = 0,
        ranged_hits = 0,
        ws_count = 0,
        ws_attempts = 0,
        ws_hits = 0,
        ability_count = 0,
    };
end

local function reset_live_capture()
    state.events = {};
    state.next_event_id = 1;
    state.tp_candidates = {};
    state.pending_ws = nil;
    state.recent_signatures = {};
    state.stats = empty_stats();
    state.ws = {};
    state.round_swings = {};
    state.tp.current = get_current_tp();
    state.tp.last = state.tp.current;
    state.tp.last_delta = 0;
    state.tp.last_source = '--';
    state.tp.total_positive = 0;
    state.tp.melee = 0;
    state.tp.ranged = 0;
    state.tp.ws = 0;
    state.tp.ability = 0;
    state.tp.incoming = 0;
    state.tp.passive_unknown = 0;
    state.clock.active_seconds = 0;
    state.clock.tp_observable_seconds = 0;
    state.clock.tp_capped_seconds = 0;
    state.clock.last_tick = now();
    state.clock.last_activity = nil;
    state.clock.last_activity_tp_capped = nil;
    state.live.elapsed = 0;
    state.live.started = state.live.enabled[1] and now() or nil;
    if state.recording and state.benchmark.current then
        state.run_started = now();
        state.benchmark.current.start_gear = equipment_snapshot();
        state.benchmark.current.gear_counts = {};
        state.benchmark.current.gear_snapshots = {};
        state.benchmark.current.gear_samples = 0;
        state.benchmark.current.target_id = nil;
        state.benchmark.current.target_name = '';
        state.benchmark.current.target_mismatches = 0;
    end
end

local function reset_group_capture()
    state.group.members = {};
    state.group.order = {};
    state.group.last_refresh = 0;
    state.group.last_poll = 0;
    state.group.elapsed = 0;
    state.group.started = state.group.enabled[1] and now() or nil;
    state.group.shared_sc_damage = 0;
    state.group.unknown_sc_damage = 0;
    refresh_group_members(true);
    poll_group_tp(true);
end

local function reset_all_capture()
    reset_live_capture();
    reset_group_capture();
end

reset_all_capture();

local function dps()
    local span = active_time();
    if span <= 0 then return 0; end
    return state.stats.total_damage / span;
end

local function tp_rate(value)
    local span = tp_observable_time();
    if span <= 0 then return 0; end
    return value / span;
end

local function self_generated_tp()
    return (state.tp.melee or 0) + (state.tp.ranged or 0);
end

local function accuracy()
    local value = percent(state.stats.melee_hits + state.stats.ranged_hits,
        state.stats.melee_attempts + state.stats.ranged_attempts);
    return value or 0;
end

local function melee_accuracy()
    return percent(state.stats.melee_hits, state.stats.melee_attempts);
end

local function ranged_accuracy()
    return percent(state.stats.ranged_hits, state.stats.ranged_attempts);
end

local function ws_accuracy()
    return percent(state.stats.ws_hits, state.stats.ws_attempts);
end

local function hits_per_round()
    if state.stats.melee_rounds == 0 then return 0; end
    return state.stats.melee_hits / state.stats.melee_rounds;
end

local function add_event(event)
    event.id = state.next_event_id;
    state.next_event_id = state.next_event_id + 1;
    event.clock = event.clock or now();
    event.rel = capture_elapsed();
    table.insert(state.events, event);
    while #state.events > state.max_events do
        table.remove(state.events, 1);
    end
    write_log_event(event);
    return event;
end

local function find_event(id)
    for _, event in ipairs(state.events) do
        if event.id == id then return event; end
    end
    return nil;
end

local function entity_name(server_id)
    if server_id == nil or server_id == 0 then return '--'; end
    local cached = state.entity_cache[server_id];
    if cached then return cached; end

    for i = 0, 2302 do
        local ent = GetEntity(i);
        if ent and ent.ServerId == server_id then
            local name = ent.Name or string.format('0x%08X', server_id);
            state.entity_cache[server_id] = name;
            return name;
        end
    end

    return string.format('0x%08X', server_id);
end

local function resource_name(category, param)
    local rm = AshitaCore:GetResourceManager();
    if not rm then return nil; end

    local res = nil;
    if category == 3 then
        res = rm:GetAbilityById(param);
    elseif category == 4 then
        res = rm:GetSpellById(param);
    elseif category == 6 or category == 14 or category == 15 then
        res = rm:GetAbilityById(param + 0x200);
    end

    if res and res.Name and res.Name[1] and #res.Name[1] > 0 then
        return res.Name[1];
    end
    return nil;
end

local function action_label(category, param)
    if category == 1 then return 'Attack'; end
    if category == 2 then return 'Ranged Attack'; end
    local name = resource_name(category, param);
    if name then return name; end
    if category == 3 then return 'WS #' .. tostring(param); end
    if category == 4 then return 'Spell #' .. tostring(param); end
    if category == 6 then return 'Ability #' .. tostring(param); end
    return packets.category_name(category) .. ' #' .. tostring(param);
end

local function signature(action)
    local parts = { tostring(action.actor_id), tostring(action.category), tostring(action.param) };
    for _, target in ipairs(action.targets) do
        table.insert(parts, tostring(target.id));
        for _, r in ipairs(target.actions) do
            table.insert(parts, table.concat({ r.reaction, r.animation, r.value, r.message, r.add_value or 0 }, ':'));
        end
    end
    return table.concat(parts, '|');
end

local function is_duplicate(action)
    local sig = signature(action);
    local t = now();
    local last = state.recent_signatures[sig];
    state.recent_signatures[sig] = t;
    return last ~= nil and (t - last) < 0.08;
end

local function update_ws(event)
    local name = event.action;
    local w = state.ws[name];
    if not w then
        w = { count = 0, total = 0, min = nil, max = nil, tp_total = 0, tp_count = 0 };
        state.ws[name] = w;
    end
    w.count = w.count + 1;
    w.total = w.total + event.damage;
    w.min = w.min and math.min(w.min, event.damage) or event.damage;
    w.max = w.max and math.max(w.max, event.damage) or event.damage;
    if event.tp_before ~= nil then
        w.tp_total = w.tp_total + event.tp_before;
        w.tp_count = w.tp_count + 1;
    end
end

local function prune_tp_candidates(t)
    t = t or now();
    local keep = {};
    for _, candidate in ipairs(state.tp_candidates) do
        if (t - candidate.clock) <= 1.20 then
            table.insert(keep, candidate);
        end
    end
    state.tp_candidates = keep;
end

local function register_tp_candidate(event, class)
    if not event then return; end
    prune_tp_candidates(event.clock);
    table.insert(state.tp_candidates, {
        event_id = event.id,
        clock = event.clock,
        class = class,
    });
end

local function select_tp_candidate(t)
    prune_tp_candidates(t);
    local best_index = nil;
    local best_age = nil;
    for i = #state.tp_candidates, 1, -1 do
        local candidate = state.tp_candidates[i];
        local age = t - candidate.clock;
        if age >= 0 and age <= 0.90 and (best_age == nil or age < best_age) then
            best_index = i;
            best_age = age;
        end
    end
    if not best_index then return nil; end
    local candidate = state.tp_candidates[best_index];
    table.remove(state.tp_candidates, best_index);
    return candidate;
end

local function remove_recent_ws_candidate(t)
    for i = #state.tp_candidates, 1, -1 do
        local candidate = state.tp_candidates[i];
        if candidate.class == 'ws' and (t - candidate.clock) >= 0 and (t - candidate.clock) <= 1.20 then
            table.remove(state.tp_candidates, i);
            return candidate;
        end
    end
    return nil;
end

local function get_pending_ws_tp(action_id)
    local pending = state.pending_ws;
    if not pending then return nil, 'incoming fallback', nil, nil; end
    local age = now() - pending.clock;
    if pending.action_id == action_id and age >= 0 and age <= 8.0 then
        local tp = pending.tp;
        local post_tp = pending.post_tp;
        local spend_delta = pending.spend_delta;
        state.pending_ws = nil;
        return tp, 'outgoing 0x1A', post_tp, spend_delta;
    end
    return nil, 'incoming fallback', nil, nil;
end

local function record_self_action(action)
    local category = action.category;
    if category ~= 1 and category ~= 2 and category ~= 3 and category ~= 4 and category ~= 6 and category ~= 14 and category ~= 15 then
        return;
    end

    local attempts = 0;
    local hits = 0;
    local damage = 0;
    local add_damage = 0;
    local reactions = {};
    local target_name = '--';
    local primary_target_id = 0;

    for target_index, target in ipairs(action.targets) do
        if target_index == 1 then target_name = entity_name(target.id); primary_target_id = target.id or 0; end
        for _, r in ipairs(target.actions) do
            attempts = attempts + 1;
            if result_is_damage(category, r) then
                damage = damage + (r.value or 0);
            end
            if r.reaction == 0 then
                hits = hits + 1;
            else
                reactions[packets.reaction_name(r.reaction)] = true;
            end
            if additional_is_damage(r) and (r.add_value or 0) > 0 then
                add_damage = add_damage + r.add_value;
            end
        end
    end

    local sc_damage, solo_sc, shared_sc, unknown_sc, sc_text = skillchain_totals(action);

    if state.recording and state.benchmark.current and state.benchmark.current.target_lock then
        local current = state.benchmark.current;
        local self_id = get_player_id();
        local lockable = primary_target_id ~= 0 and primary_target_id ~= self_id;
        if lockable and current.target_id == nil then
            current.target_id = primary_target_id;
            current.target_name = target_name;
        elseif lockable and current.target_id ~= primary_target_id then
            current.target_mismatches = (current.target_mismatches or 0) + 1;
            return;
        end
    end

    local pre_tp = get_current_tp();
    local pre_tp_source = 'incoming memory';
    local ws_post_tp = nil;
    local ws_spend_delta = nil;
    if category == 3 then
        local outgoing_tp, source, pending_post_tp, pending_spend_delta = get_pending_ws_tp(action.param);
        if outgoing_tp ~= nil then pre_tp = outgoing_tp; end
        pre_tp_source = source;
        ws_post_tp = pending_post_tp;
        ws_spend_delta = pending_spend_delta;
    end

    local notes = {};
    for k, _ in pairs(reactions) do table.insert(notes, k); end
    table.sort(notes);
    if category == 3 then table.insert(notes, 'preTP=' .. pre_tp_source); end
    if sc_text ~= '' then table.insert(notes, 'SC=' .. sc_text); end

    local type_name = packets.category_name(category);
    local event = add_event({
        type = type_name,
        action = action_label(category, action.param),
        target = target_name,
        attempts = attempts,
        hits = hits,
        damage = damage,
        add_damage = add_damage,
        sc_damage = sc_damage,
        sc_solo_damage = solo_sc,
        sc_shared_damage = shared_sc,
        sc_unknown_damage = unknown_sc,
        sc_text = sc_text,
        tp_before = pre_tp,
        tp_before_source = pre_tp_source,
        tp_after = ws_post_tp,
        tp_spend_delta = ws_spend_delta,
        tp_delta = nil,
        tp_class = '',
        reaction_note = table.concat(notes, ','),
    });

    if state.recording and state.benchmark.current then
        local scope = state.benchmark.current.scope or 'all';
        local relevant = scope == 'all'
            or (scope == 'melee' and category == 1)
            or (scope == 'ranged' and category == 2)
            or (scope == 'ws' and category == 3);
        if relevant then
            local snapshot = equipment_snapshot();
            local fp = equipment_fingerprint(snapshot);
            state.benchmark.current.gear_samples = (state.benchmark.current.gear_samples or 0) + 1;
            state.benchmark.current.gear_counts[fp] = (state.benchmark.current.gear_counts[fp] or 0) + 1;
            state.benchmark.current.gear_snapshots[fp] = snapshot;
            event.benchmark_gear = fp;
        end
    end

    local t = event.clock;
    if not state.stats.first_action then state.stats.first_action = t; end
    state.stats.last_action = t;

    -- Use offensive activity for the DPS clock. Incoming damage and support-only
    -- actions no longer lengthen Live's denominator, keeping it comparable to Group.
    if category == 1 or category == 2 or category == 3 or damage > 0 or add_damage > 0 or sc_damage > 0 then
        mark_activity(t);
    end

    if category == 1 then
        state.stats.melee_rounds = state.stats.melee_rounds + 1;
        state.stats.melee_attempts = state.stats.melee_attempts + attempts;
        state.stats.melee_hits = state.stats.melee_hits + hits;
        state.stats.melee_damage = state.stats.melee_damage + damage;
        state.round_swings[attempts] = (state.round_swings[attempts] or 0) + 1;
        register_tp_candidate(event, 'melee');
    elseif category == 2 then
        state.stats.ranged_shots = state.stats.ranged_shots + 1;
        state.stats.ranged_attempts = state.stats.ranged_attempts + attempts;
        state.stats.ranged_hits = state.stats.ranged_hits + hits;
        state.stats.ranged_damage = state.stats.ranged_damage + damage;
        register_tp_candidate(event, 'ranged');
    elseif category == 3 then
        state.stats.ws_count = state.stats.ws_count + 1;
        state.stats.ws_attempts = state.stats.ws_attempts + attempts;
        state.stats.ws_hits = state.stats.ws_hits + hits;
        state.stats.ws_damage = state.stats.ws_damage + damage;
        update_ws(event);
        register_tp_candidate(event, 'ws');
    elseif category == 4 then
        state.stats.magic_damage = state.stats.magic_damage + damage;
    elseif category == 6 or category == 14 or category == 15 then
        state.stats.ability_count = state.stats.ability_count + 1;
        state.stats.ability_damage = state.stats.ability_damage + damage;
        register_tp_candidate(event, 'ability');
    end

    state.stats.add_damage = state.stats.add_damage + add_damage;
    state.stats.skillchain_damage = state.stats.skillchain_damage + sc_damage;
    state.stats.skillchain_solo_damage = state.stats.skillchain_solo_damage + solo_sc;
    state.stats.skillchain_shared_damage = state.stats.skillchain_shared_damage + shared_sc;
    state.stats.skillchain_unknown_damage = state.stats.skillchain_unknown_damage + unknown_sc;

    -- Only confidently self-created SC damage is credited to the local player's DPS.
    -- Shared / unknown SC remains visible on Damage/Group without being assigned to a player.
    state.stats.total_damage = state.stats.melee_damage + state.stats.ranged_damage + state.stats.ws_damage
        + state.stats.magic_damage + state.stats.ability_damage + state.stats.add_damage
        + state.stats.skillchain_solo_damage;
end

local function record_incoming_action(action)
    local self_id = get_player_id();
    if self_id == 0 or action.actor_id == self_id then return false; end
    local category = action.category;
    if category ~= 1 and category ~= 2 and category ~= 3 and category ~= 4 and category ~= 6 and category ~= 11 and category ~= 13 and category ~= 14 and category ~= 15 then
        return false;
    end

    local attempts = 0;
    local hits = 0;
    local damage = 0;
    local add_damage = 0;
    local targeted = false;
    local reactions = {};

    for _, target in ipairs(action.targets) do
        if target.id == self_id then
            targeted = true;
            for _, r in ipairs(target.actions) do
                attempts = attempts + 1;
                if result_is_damage(category, r) then
                    damage = damage + (r.value or 0);
                elseif (r.value or 0) > 0 then
                    -- Preserve the overloaded value for parser diagnostics without
                    -- treating it as HP damage (for example Haste=33, Protect=40, Shell=41).
                    reactions[string.format('msg=%d value=%d', r.message or 0, r.value or 0)] = true;
                end
                if r.reaction == 0 then
                    hits = hits + 1;
                else
                    reactions[packets.reaction_name(r.reaction)] = true;
                end
                if additional_is_damage(r) and (r.add_value or 0) > 0 then
                    add_damage = add_damage + r.add_value;
                end
            end
        end
    end

    if not targeted then return false; end
    state.debug.incoming_action_packets = state.debug.incoming_action_packets + 1;

    local label = action_label(action.category, action.param);
    if action.category == 11 then
        label = 'MobSkill #' .. tostring(action.param);
    end

    local notes = {};
    for k, _ in pairs(reactions) do table.insert(notes, k); end
    table.sort(notes);

    local event = add_event({
        type = 'Incoming',
        action = label,
        target = entity_name(action.actor_id),
        attempts = attempts,
        hits = hits,
        damage = damage,
        add_damage = add_damage,
        tp_before = get_current_tp(),
        tp_delta = nil,
        tp_class = '',
        reaction_note = table.concat(notes, ','),
    });

    if damage > 0 or add_damage > 0 then
        -- Incoming hits can grant TP, but they should not lengthen the local
        -- outgoing-DPS denominator used by Live / Compare.
        if category == 1 or category == 2 or category == 11 then
            register_tp_candidate(event, 'incoming');
        end
    end
    return true;
end

local function handle_tp_value(new_tp, source)
    if new_tp == nil then return; end
    tick_active_clock();

    if not state.live.enabled[1] then
        state.tp.last = new_tp;
        state.tp.current = new_tp;
        return;
    end
    if state.tp.last == nil then
        state.tp.last = new_tp;
        state.tp.current = new_tp;
        return;
    end
    if new_tp == state.tp.last then
        state.tp.current = new_tp;
        return;
    end

    local event_time = now();
    local old = state.tp.last;
    local delta = new_tp - old;
    state.tp.last = new_tp;
    state.tp.current = new_tp;
    state.tp.last_delta = delta;
    state.tp.last_source = source or '--';

    local tp_class = delta > 0 and 'passive/unknown' or 'spend/drop';
    local linked_event_id = nil;
    local linked_event = nil;

    if delta > 0 then
        state.tp.total_positive = state.tp.total_positive + delta;
        local candidate = select_tp_candidate(event_time);
        if candidate then
            linked_event_id = candidate.event_id;
            linked_event = find_event(candidate.event_id);
            tp_class = candidate.class;
            if linked_event then
                linked_event.tp_delta = (linked_event.tp_delta or 0) + delta;
                linked_event.tp_after = new_tp;
                linked_event.tp_class = candidate.class;
            end

            if candidate.class == 'melee' then
                state.tp.melee = state.tp.melee + delta;
            elseif candidate.class == 'ranged' then
                state.tp.ranged = state.tp.ranged + delta;
            elseif candidate.class == 'ws' then
                state.tp.ws = state.tp.ws + delta;
            elseif candidate.class == 'ability' then
                state.tp.ability = state.tp.ability + delta;
            elseif candidate.class == 'incoming' then
                state.tp.incoming = state.tp.incoming + delta;
            else
                state.tp.passive_unknown = state.tp.passive_unknown + delta;
            end
        else
            state.tp.passive_unknown = state.tp.passive_unknown + delta;
        end
    elseif delta < 0 then
        local candidate = remove_recent_ws_candidate(event_time);
        if candidate then
            linked_event_id = candidate.event_id;
            linked_event = find_event(candidate.event_id);
            tp_class = 'ws spend/net';
            if linked_event then
                linked_event.tp_after = new_tp;
                linked_event.tp_spend_delta = delta;
            end
        elseif state.pending_ws and (event_time - state.pending_ws.clock) >= 0 and (event_time - state.pending_ws.clock) <= 2.0 then
            state.pending_ws.post_tp = new_tp;
            state.pending_ws.spend_delta = delta;
            tp_class = 'ws spend/pending';
        end
    end

    local raw_event = add_event({
        type = 'TP',
        action = 'TP update',
        target = source or '--',
        attempts = 0,
        hits = 0,
        damage = 0,
        add_damage = 0,
        tp_before = old,
        tp_after = new_tp,
        tp_delta = delta,
        tp_class = tp_class,
        linked_event_id = linked_event_id,
        reaction_note = linked_event_id and ('linked to #' .. tostring(linked_event_id)) or tp_class,
    });

end

local function combo_string(values)
    if #values == 0 then return 'None found\0\0'; end
    return table.concat(values, '\0') .. '\0\0';
end

local function command_group_names()
    local out = {};
    for _, group in ipairs(state.profile.commands or {}) do
        table.insert(out, group.display or group.key or 'Command');
    end
    return out;
end

local function current_command_group()
    local commands = state.profile.commands or {};
    if #commands == 0 then return nil; end
    local index = math.max(0, math.min(state.benchmark.command_group[1] or 0, #commands - 1));
    state.benchmark.command_group[1] = index;
    return commands[index + 1];
end

local function clamp_benchmark_options(prefer_defaults)
    local group = current_command_group();
    local count = group and #group.options or 0;
    if count <= 0 then
        state.benchmark.option_a[1] = 0;
        state.benchmark.option_b[1] = 0;
        return;
    end
    if state.benchmark.option_a[1] >= count then state.benchmark.option_a[1] = 0; end
    if state.benchmark.option_b[1] >= count then state.benchmark.option_b[1] = math.min(1, count - 1); end
    if prefer_defaults then
        local normal = nil;
        local accuracy = nil;
        for i, option in ipairs(group.options) do
            local key = tostring(option.display or option.value or ''):lower();
            if key == 'normal' then normal = i - 1; end
            if key == 'accuracy' or key == 'acc' then accuracy = i - 1; end
        end
        state.benchmark.option_a[1] = normal or 0;
        state.benchmark.option_b[1] = accuracy or math.min(1, count - 1);
    end
end

local function selected_command_option(which)
    local group = current_command_group();
    if not group then return nil; end
    local index = which == 'B' and state.benchmark.option_b[1] or state.benchmark.option_a[1];
    return group.options[(index or 0) + 1];
end

local function resolve_test_scope(group_key)
    local selected = TEST_SCOPES[(state.benchmark.scope[1] or 0) + 1] or 'Auto';
    if selected == 'Melee / TP' then return 'melee'; end
    if selected == 'Ranged' then return 'ranged'; end
    if selected == 'WS' then return 'ws'; end
    if selected == 'All' then return 'all'; end

    local key = tostring(group_key or ''):lower();
    if key:find('shot', 1, true) or key:find('range', 1, true) then return 'ranged'; end
    if key == 'tp' or key:find('melee', 1, true) then return 'melee'; end
    if key == 'ws' or key:find('weapon', 1, true) then return 'ws'; end
    return 'all';
end

local function selected_test_definition(which)
    if state.benchmark.manual_mode[1] then
        local name = which == 'B' and state.benchmark.manual_name_b[1] or state.benchmark.manual_name_a[1];
        local command = which == 'B' and state.benchmark.manual_command_b[1] or state.benchmark.manual_command_a[1];
        name = tostring(name or ''):trim();
        command = tostring(command or ''):trim();
        if name == '' then name = 'Manual Test ' .. which; end
        if command ~= '' and command:sub(1, 1) ~= '/' then command = '/lac fwd ' .. command; end
        return {
            name = name,
            source = 'Manual',
            command = command,
            group_key = '',
            option = '',
            scope = resolve_test_scope(''),
        };
    end

    local group = current_command_group();
    local option = selected_command_option(which);
    if not group or not option then
        return {
            name = 'Test ' .. which,
            source = 'LAC profile',
            command = '',
            group_key = '',
            option = '',
            scope = resolve_test_scope(''),
        };
    end

    local command = string.format('/lac fwd %s %s', tostring(group.key), tostring(option.value));
    return {
        name = string.format('%s > %s', tostring(group.display or group.key), tostring(option.display or option.value)),
        source = 'LAC profile',
        command = command,
        group_key = tostring(group.key),
        option = tostring(option.value),
        scope = resolve_test_scope(group.key),
    };
end

local function scan_profile(path, source)
    if not path then
        state.profile.path = '';
        state.profile.error = 'No profile path resolved.';
        state.profile.command_error = '';
        state.profile.sets = {};
        state.profile.commands = {};
        return false;
    end

    local sets, set_err = profiles.scan_sets(path);
    local commands, command_err = profiles.scan_commands(path);
    state.profile.path = path;
    state.profile.source = source or state.profile.source;
    state.profile.error = set_err or '';
    state.profile.command_error = command_err or '';
    state.profile.sets = sets or {};
    state.profile.commands = commands or {};
    state.profile.last_scan = now();

    local ident = profiles.get_identity();
    state.profile.job = ident and ident.job or '';
    state.profile.sub_job = ident and ident.sub_job or '';

    if state.benchmark.command_group[1] >= #state.profile.commands then
        state.benchmark.command_group[1] = 0;
    end
    clamp_benchmark_options(true);
    return command_err == nil;
end

local function scan_default_profile()
    local path, err = profiles.resolve_default();
    if not path then
        state.profile.error = err or 'Default profile not found.';
        state.profile.command_error = '';
        state.profile.path = '';
        state.profile.sets = {};
        state.profile.commands = {};
        return false;
    end
    return scan_profile(path, 'auto/current job');
end

local function query_active_lac_profile()
    AshitaCore:GetChatManager():QueueCommand(-1, "/lac exec if gProfile and gProfile.FileName then AshitaCore:GetChatManager():QueueCommand(-1,'/dpslab lacprofile '..gProfile.FileName) end");
end

local function scan_profile_argument(arg, source)
    local path, err = profiles.resolve_like_lac(arg);
    if not path then
        state.profile.error = err or 'Profile not found.';
        return false;
    end
    return scan_profile(path, source or 'manual');
end

local function history_directory()
    return AshitaCore:GetInstallPath() .. 'addons\\' .. addon.name .. '\\History\\';
end

local function history_path()
    return history_directory() .. 'benchmarks.tsv';
end

local HISTORY_FIELDS = {
    'timestamp','date','time','job','sub_job','name','source','command','scope','target','target_mismatches','duration','active_seconds','tp_observable_seconds','tp_capped_seconds',
    'dps','total_damage','self_tpps','total_tpps','melee_tpps','ranged_tpps','accuracy','hits_per_round','melee_damage','ranged_damage','ws_damage',
    'magic_damage','ability_damage','proc_damage','ws_count','avg_ws','avg_ws_tp','melee_rounds','ranged_shots','gear','gear_samples','integrity',
    'skillchain_damage','shared_skillchain_damage'
};

local function history_clean(value)
    return (tostring(value == nil and '' or value):gsub('[\t\r\n]', ' '));
end

local function ensure_history_directory()
    local dir = history_directory();
    if not ashita.fs.exists(dir) then
        if ashita.fs.create_directory(dir) == false and not ashita.fs.exists(dir) then
            state.benchmark.history_error = 'Could not create History folder.';
            return false;
        end
    end
    return true;
end

local function save_history_run(run)
    if not ensure_history_directory() then return false; end
    local path = history_path();
    local exists_already = ashita.fs.exists(path);
    local f, err = io.open(path, 'a');
    if not f then
        state.benchmark.history_error = tostring(err or 'Could not open benchmark history.');
        return false;
    end
    if not exists_already then
        f:write('#DPSLabHistory\tv1\n');
        f:write('#' .. table.concat(HISTORY_FIELDS, '\t') .. '\n');
    end
    local values = {};
    for _, key in ipairs(HISTORY_FIELDS) do table.insert(values, history_clean(run[key])); end
    f:write(table.concat(values, '\t') .. '\n');
    f:close();
    state.benchmark.history_error = '';
    return true;
end

local function rewrite_history()
    if not ensure_history_directory() then return false; end
    local path = history_path();
    local f, err = io.open(path, 'w');
    if not f then
        state.benchmark.history_error = tostring(err or 'Could not rewrite benchmark history.');
        return false;
    end
    f:write('#DPSLabHistory\tv1\n');
    f:write('#' .. table.concat(HISTORY_FIELDS, '\t') .. '\n');
    for _, run in ipairs(state.benchmark.history) do
        local values = {};
        for _, key in ipairs(HISTORY_FIELDS) do table.insert(values, history_clean(run[key])); end
        f:write(table.concat(values, '\t') .. '\n');
    end
    f:close();
    state.benchmark.history_error = '';
    return true;
end

local function delete_history_run(index)
    index = tonumber(index) or -1;
    if index < 1 or index > #state.benchmark.history then return false; end
    local removed = table.remove(state.benchmark.history, index);
    if not rewrite_history() then
        table.insert(state.benchmark.history, index, removed);
        return false;
    end
    state.benchmark.history_selected[1] = -1;
    state.benchmark.history_delete_pending = -1;
    state.benchmark.history_notice = 'Deleted saved history run: ' .. tostring(removed.name or 'Benchmark');
    return true;
end

local NUMERIC_HISTORY_FIELDS = {
    timestamp=true,target_mismatches=true,duration=true,active_seconds=true,tp_observable_seconds=true,tp_capped_seconds=true,dps=true,total_damage=true,self_tpps=true,total_tpps=true,
    melee_tpps=true,ranged_tpps=true,accuracy=true,hits_per_round=true,melee_damage=true,ranged_damage=true,ws_damage=true,magic_damage=true,ability_damage=true,
    proc_damage=true,ws_count=true,avg_ws=true,avg_ws_tp=true,melee_rounds=true,ranged_shots=true,gear_samples=true,
    skillchain_damage=true,shared_skillchain_damage=true,
};

local function load_history()
    state.benchmark.history = {};
    state.benchmark.history_error = '';
    local path = history_path();
    if not ashita.fs.exists(path) then return; end
    local f, err = io.open(path, 'r');
    if not f then state.benchmark.history_error = tostring(err or 'Could not read benchmark history.'); return; end
    for line in f:lines() do
        if line:sub(1,1) ~= '#' and line ~= '' then
            local columns = {};
            local start = 1;
            while true do
                local tab = line:find('\t', start, true);
                if not tab then
                    table.insert(columns, line:sub(start));
                    break;
                end
                table.insert(columns, line:sub(start, tab - 1));
                start = tab + 1;
            end
            local run = {};
            for i, key in ipairs(HISTORY_FIELDS) do
                local value = columns[i] or '';
                run[key] = NUMERIC_HISTORY_FIELDS[key] and (tonumber(value) or 0) or value;
            end
            run.gear_snapshot = deserialize_equipment(run.gear);
            table.insert(state.benchmark.history, run);
        end
    end
    f:close();
end

local function aggregate_ws_summary()
    local total = 0;
    local count = 0;
    local tp_total = 0;
    local tp_count = 0;
    for _, w in pairs(state.ws) do
        total = total + (w.total or 0);
        count = count + (w.count or 0);
        tp_total = tp_total + (w.tp_total or 0);
        tp_count = tp_count + (w.tp_count or 0);
    end
    return count > 0 and (total / count) or 0, tp_count > 0 and (tp_total / tp_count) or 0;
end

local function dominant_gear_sample(current)
    if not current then return {}, 0; end
    local best_fp = nil;
    local best_count = 0;
    for fp, count in pairs(current.gear_counts or {}) do
        if count > best_count then best_fp, best_count = fp, count; end
    end
    if best_fp and current.gear_snapshots then return current.gear_snapshots[best_fp] or {}, best_count; end
    return current.start_gear or equipment_snapshot(), 0;
end

local function build_run_snapshot()
    local current = state.benchmark.current or {};
    local ident = profiles.get_identity();
    local avg_ws, avg_ws_tp = aggregate_ws_summary();
    local gear, dominant_count = dominant_gear_sample(current);
    local duration = live_elapsed();
    local capped = state.clock.tp_capped_seconds or 0;
    local integrity = 'Clean';
    if active_time() <= 0 then integrity = 'Warning: no active combat';
    elseif (current.target_mismatches or 0) > 0 then integrity = 'Warning: off-target actions excluded';
    elseif current.scope ~= 'all' and (current.gear_samples or 0) == 0 then integrity = 'Warning: no scoped gear samples';
    elseif tp_observable_time() > 0 and capped > tp_observable_time() * 0.5 then integrity = 'Warning: heavy TP cap'; end

    return {
        timestamp = os.time(),
        date = os.date('%Y-%m-%d'),
        time = os.date('%H:%M'),
        job = ident and ident.job or state.profile.job or '',
        sub_job = ident and ident.sub_job or state.profile.sub_job or '',
        name = current.name or state.run_label or 'Benchmark',
        source = current.source or '',
        command = current.command or '',
        scope = current.scope or 'all',
        target = current.target_name or '',
        target_mismatches = current.target_mismatches or 0,
        duration = duration,
        active_seconds = active_time(),
        tp_observable_seconds = tp_observable_time(),
        tp_capped_seconds = capped,
        dps = dps(),
        total_damage = state.stats.total_damage or 0,
        self_tpps = tp_rate(self_generated_tp()),
        total_tpps = tp_rate(state.tp.total_positive or 0),
        melee_tpps = tp_rate(state.tp.melee or 0),
        ranged_tpps = tp_rate(state.tp.ranged or 0),
        accuracy = accuracy(),
        hits_per_round = hits_per_round(),
        melee_damage = state.stats.melee_damage or 0,
        ranged_damage = state.stats.ranged_damage or 0,
        ws_damage = state.stats.ws_damage or 0,
        magic_damage = state.stats.magic_damage or 0,
        ability_damage = state.stats.ability_damage or 0,
        proc_damage = state.stats.add_damage or 0,
        skillchain_damage = state.stats.skillchain_solo_damage or 0,
        shared_skillchain_damage = (state.stats.skillchain_shared_damage or 0) + (state.stats.skillchain_unknown_damage or 0),
        ws_count = state.stats.ws_count or 0,
        avg_ws = avg_ws,
        avg_ws_tp = avg_ws_tp,
        melee_rounds = state.stats.melee_rounds or 0,
        ranged_shots = state.stats.ranged_shots or 0,
        gear = serialize_equipment(gear),
        gear_snapshot = gear,
        gear_samples = current.gear_samples or 0,
        dominant_gear_samples = dominant_count,
        integrity = integrity,
    };
end

local stop_run;

local function start_run(side)
    local def = selected_test_definition(side);
    if not state.benchmark.manual_mode[1] and def.command == '' then
        print(chat.header(addon.name):append(chat.error('No discovered LAC command is selected. Choose a command group/option or enable Manual / custom test mode.')));
        return;
    end

    if state.recording then
        -- Never discard an in-progress benchmark. Starting either side first
        -- freezes/saves the current run, then begins the newly requested side.
        stop_run();
    end
    reset_live_capture();
    if not state.live.enabled[1] then start_live_capture(); end
    state.recording = true;
    state.run_side = side;
    state.run_started = now();
    state.run_label = side .. ': ' .. def.name;
    state.benchmark.current = {
        side = side,
        name = def.name,
        source = def.source,
        command = def.command,
        group_key = def.group_key,
        option = def.option,
        scope = def.scope,
        target_lock = state.benchmark.target_lock[1] == true,
        target_id = nil,
        target_name = '',
        target_mismatches = 0,
        start_gear = equipment_snapshot(),
        gear_counts = {},
        gear_snapshots = {},
        gear_samples = 0,
        command_issued = false,
    };

    if def.command ~= '' then
        AshitaCore:GetChatManager():QueueCommand(-1, def.command);
        state.benchmark.current.command_issued = true;
    end
end

stop_run = function()
    if not state.recording then return nil; end
    local side = state.run_side;
    local run = build_run_snapshot();
    if side == 'A' or side == 'B' then
        state.benchmark.runs[side] = run;
        state.benchmark.compare_notice = '';
    end
    table.insert(state.benchmark.history, run);
    save_history_run(run);
    stop_live_capture();
    state.recording = false;
    state.run_label = 'Stopped: ' .. tostring(run.name or 'Benchmark');
    state.run_side = '-';
    state.benchmark.current = nil;
    return run;
end

local function check_benchmark_stop()
    if not state.recording then return; end
    local mode = STOP_MODES[(state.benchmark.stop_mode[1] or 0) + 1] or 'Manual';
    local value = math.max(1, tonumber(state.benchmark.stop_value[1]) or 1);
    if mode == 'Seconds' and live_elapsed() >= value then
        stop_run();
    elseif mode == 'Melee Rounds' and (state.stats.melee_rounds or 0) >= value then
        stop_run();
    elseif mode == 'WS Count' and (state.stats.ws_count or 0) >= value then
        stop_run();
    end
end

local function event_tp_text(e)
    if e.type == 'WS' and e.tp_before ~= nil then
        if e.tp_after ~= nil then
            return string.format('%d->%d', e.tp_before, e.tp_after);
        end
        return string.format('pre %d', e.tp_before);
    end
    if e.tp_delta ~= nil then
        return string.format('%+d', e.tp_delta);
    end
    return '--';
end

local function draw_live_tab()
    header('Live Instrumentation');
    imgui.Text('Solo parser capture is independent from Group and starts automatically when DPSLab loads.');
    imgui.Text('Status: ' .. (state.live.enabled[1] and 'CAPTURING' or 'STOPPED / FROZEN'));
    if imgui.Button('Start Live') then start_live_capture(); end
    imgui.SameLine();
    if imgui.Button('Stop Live') then
        if state.recording then stop_run(); else stop_live_capture(); end
    end
    imgui.SameLine();
    if imgui.Button('Reset Live') then reset_live_capture(); end
    imgui.Separator();

    if imgui.BeginTable('##live_metrics', 3, 0) then
        imgui.TableSetupColumn('Metric');
        imgui.TableSetupColumn('Value');
        imgui.TableSetupColumn('Source');
        imgui.TableHeadersRow();
        row3('DPS (active)', string.format('%.1f', dps()), '0x028 / active clock');
        row3('Total damage', state.stats.total_damage, '0x028');
        row3('Current TP', get_current_tp(), 'memory');
        row3('Capture elapsed', format_elapsed(capture_elapsed()), 'wall clock');
        row3('Active combat time', format_elapsed(active_time()), string.format('gaps > %.1fs discarded', active_timeout()));
        row3('TP observable time', format_elapsed(tp_observable_time()), 'excludes TP cap');
        row3('Self TP/sec', string.format('%.1f', tp_rate(self_generated_tp())), 'melee + ranged');
        row3('Total observed TP/sec', string.format('%.1f', tp_rate(state.tp.total_positive)), 'includes incoming/other');
        row3('Melee TP/sec', string.format('%.1f', tp_rate(state.tp.melee)), 'self melee');
        row3('Ranged TP/sec', string.format('%.1f', tp_rate(state.tp.ranged)), 'self ranged');
        row3('Incoming TP', state.tp.incoming, 'damage taken');
        row3('Accuracy', string.format('%.1f%%', accuracy()), 'melee + ranged');
        row3('Solo SC damage', state.stats.skillchain_solo_damage or 0, 'credited to DPS');
        row3('Shared / unknown SC', (state.stats.skillchain_shared_damage or 0) + (state.stats.skillchain_unknown_damage or 0), 'shown, not player-credited');
        row3('Landed hits / melee round', string.format('%.2f', hits_per_round()), '0x028');
        row3('Melee rounds', state.stats.melee_rounds, '0x028');
        row3('Ranged shots', state.stats.ranged_shots, '0x028');
        row3('Weaponskills', state.stats.ws_count, '0x028');
        imgui.EndTable();
    end

    imgui.Separator();
    header('Packet Health');
    imgui.Text(string.format('0x028 seen: %d | self: %d | incoming-to-self: %d | parsed: %d | dup ignored: %d | parse errors: %d',
        state.debug.action_packets, state.debug.self_action_packets, state.debug.incoming_action_packets,
        state.debug.parsed_actions, state.debug.duplicates, state.debug.parse_errors));
    imgui.Text(string.format('0x037 updates: %d | 0x0DF character updates: %d | outgoing WS snapshots: %d',
        state.debug.player_update_packets, state.debug.character_update_packets, state.debug.outgoing_ws_packets));
    imgui.Text(string.format('Group action packets: %d | Group TP polls: %d',
        state.debug.group_action_packets or 0, state.debug.group_tp_polls or 0));

    imgui.Separator();
    header('Recent Player Events');
    if not state.settings.show_raw_tp_events then
        imgui.SameLine();
        imgui.TextColored({ 0.60, 0.60, 0.60, 1.00 }, '(raw TP rows hidden)');
    end

    if imgui.BeginTable('##event_table', 10, 0) then
        imgui.TableSetupColumn('Elapsed');
        imgui.TableSetupColumn('Type');
        imgui.TableSetupColumn('Action');
        imgui.TableSetupColumn('Target / Source');
        imgui.TableSetupColumn('Hit/A');
        imgui.TableSetupColumn('Dmg');
        imgui.TableSetupColumn('Proc');
        imgui.TableSetupColumn('SC');
        imgui.TableSetupColumn('TP');
        imgui.TableSetupColumn('TP Src');
        imgui.TableHeadersRow();

        local shown = 0;
        for i = #state.events, 1, -1 do
            local e = state.events[i];
            local visible = not e.hidden_helper and (state.settings.show_raw_tp_events or e.type ~= 'TP');
            if visible then
                imgui.TableNextRow();
                imgui.TableNextColumn(); imgui.Text(format_elapsed(e.rel or 0));
                imgui.TableNextColumn(); imgui.Text(e.type or '--');
                imgui.TableNextColumn(); imgui.Text(e.action or '--');
                imgui.TableNextColumn(); imgui.Text(e.target or '--');
                imgui.TableNextColumn();
                if (e.attempts or 0) > 0 then imgui.Text(string.format('%d/%d', e.hits or 0, e.attempts or 0)); else imgui.Text('--'); end
                imgui.TableNextColumn(); imgui.Text(tostring(e.damage or 0));
                imgui.TableNextColumn(); imgui.Text((e.add_damage or 0) > 0 and tostring(e.add_damage) or '--');
                imgui.TableNextColumn(); imgui.Text((e.sc_damage or 0) > 0 and (e.sc_text ~= '' and e.sc_text or tostring(e.sc_damage)) or '--');
                imgui.TableNextColumn(); imgui.Text(event_tp_text(e));
                imgui.TableNextColumn(); imgui.Text((e.tp_class and e.tp_class ~= '') and e.tp_class or '--');
                shown = shown + 1;
                if shown >= 24 then break; end
            end
        end
        imgui.EndTable();
    end
end

local function draw_group_tab()
    header('Group Parser');
    imgui.Text('Party/alliance damage, physical accuracy, observed TP/sec, and skillchain attribution.');
    muted('Accuracy is melee + ranged only, matching the Live tab. Solo SC is credited to its player; shared SC stays separate.');
    imgui.Text('Status: ' .. (state.group.enabled[1] and 'CAPTURING' or 'STOPPED / FROZEN') .. ' | Capture ' .. format_elapsed(group_elapsed()));
    if imgui.Button('Start Group') then start_group_capture(); end
    imgui.SameLine();
    if imgui.Button('Stop Group') then stop_group_capture(); end
    imgui.SameLine();
    if imgui.Button('Reset Group') then reset_group_capture(); end
    imgui.Separator();

    refresh_group_members(false);
    poll_group_tp(false);

    if #state.group.order == 0 then
        imgui.Text('No active party/alliance members detected.');
        return;
    end

    if imgui.BeginTable('##group_parser', 12, 0) then
        imgui.TableSetupColumn('Player');
        imgui.TableSetupColumn('Acc');
        imgui.TableSetupColumn('Melee');
        imgui.TableSetupColumn('Range');
        imgui.TableSetupColumn('Magic');
        imgui.TableSetupColumn('Ability');
        imgui.TableSetupColumn('Proc');
        imgui.TableSetupColumn('WS');
        imgui.TableSetupColumn('SC');
        imgui.TableSetupColumn('TP/s');
        imgui.TableSetupColumn('Total');
        imgui.TableSetupColumn('DPS');
        imgui.TableHeadersRow();

        for _, id in ipairs(state.group.order) do
            local member = state.group.members[id];
            if member and member.present then
                local tpps = group_member_tpps(member);
                local member_dps = group_member_dps(member);
                local member_acc = group_member_accuracy(member);
                local tp_text = '--';
                if tpps then
                    tp_text = string.format('%.1f%s', tpps, (member.tp_capped_seconds or 0) > 0 and '*' or '');
                end
                local dps_text = member_dps and string.format('%.1f', member_dps) or '--';
                local acc_text = member_acc and string.format('%.1f%%', member_acc) or '--';

                imgui.TableNextRow();
                imgui.TableNextColumn(); imgui.Text(member.name or '--');
                imgui.TableNextColumn(); imgui.Text(acc_text);
                imgui.TableNextColumn(); imgui.Text(tostring(member.melee or 0));
                imgui.TableNextColumn(); imgui.Text(tostring(member.ranged or 0));
                imgui.TableNextColumn(); imgui.Text(tostring(member.magic or 0));
                imgui.TableNextColumn(); imgui.Text(tostring(member.ability or 0));
                imgui.TableNextColumn(); imgui.Text(tostring(member.proc or 0));
                imgui.TableNextColumn(); imgui.Text(tostring(member.ws or 0));
                imgui.TableNextColumn(); imgui.Text(tostring(member.skillchain or 0));
                imgui.TableNextColumn(); imgui.Text(tp_text);
                imgui.TableNextColumn(); imgui.Text(tostring(member.total or 0));
                imgui.TableNextColumn(); imgui.Text(dps_text);
            end
        end

        if (state.group.shared_sc_damage or 0) > 0 then
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.TextColored(GAIA.gold, 'Shared SC');
            imgui.TableNextColumn(); imgui.Text('--');
            for _ = 1, 6 do imgui.TableNextColumn(); imgui.Text('--'); end
            imgui.TableNextColumn(); imgui.TextColored(GAIA.gold, tostring(state.group.shared_sc_damage or 0));
            imgui.TableNextColumn(); imgui.Text('--');
            imgui.TableNextColumn(); imgui.Text(tostring(state.group.shared_sc_damage or 0));
            imgui.TableNextColumn(); imgui.Text('--');
        end

        if (state.group.unknown_sc_damage or 0) > 0 then
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.TextColored(GAIA.muted, 'Unresolved SC');
            imgui.TableNextColumn(); imgui.Text('--');
            for _ = 1, 6 do imgui.TableNextColumn(); imgui.Text('--'); end
            imgui.TableNextColumn(); imgui.TextColored(GAIA.muted, tostring(state.group.unknown_sc_damage or 0));
            imgui.TableNextColumn(); imgui.Text('--');
            imgui.TableNextColumn(); imgui.Text(tostring(state.group.unknown_sc_damage or 0));
            imgui.TableNextColumn(); imgui.Text('--');
        end
        imgui.EndTable();
    end

    imgui.Separator();
    header('Live vs Group - You');
    local self_member = state.group.members[get_player_id()];
    if self_member then
        local gdps = group_member_dps(self_member);
        local live_dps = dps();
        local damage_delta = (state.stats.total_damage or 0) - (self_member.total or 0);
        local time_delta = active_time() - (self_member.active_seconds or 0);
        local dps_delta = gdps and (live_dps - gdps) or nil;
        imgui.Text(string.format('Damage: Live %d | Group %d | Delta %+d', state.stats.total_damage or 0, self_member.total or 0, damage_delta));
        if gdps then
            imgui.Text(string.format('DPS:    Live %.1f | Group %.1f | Delta %+.1f', live_dps, gdps, dps_delta));
        else
            imgui.Text(string.format('DPS:    Live %.1f | Group --', live_dps));
        end
        imgui.Text(string.format('Active: Live %.2fs | Group %.2fs | Delta %+.2fs', active_time(), self_member.active_seconds or 0, time_delta));
        imgui.Text(string.format('Capture elapsed: Live %s | Group %s', format_elapsed(live_elapsed()), format_elapsed(group_elapsed())));
        if math.abs(damage_delta) <= 0.5 and math.abs(time_delta) <= 0.05 then
            good('Live and Group self totals are aligned for the current capture window.');
        elseif math.abs(damage_delta) <= 0.5 then
            warn('Damage matches; the DPS delta is denominator/timing related.');
        else
            warn('Damage differs too. Check whether Live and Group were reset/started at different times, or review the event buckets above.');
        end
    else
        muted('Your local Group row is not currently available.');
    end

    imgui.Separator();
    imgui.Text(string.format('Members present: %d | Group action packets: %d | Shared SC: %d | Unresolved SC: %d',
        #state.group.order, state.debug.group_action_packets or 0, state.group.shared_sc_damage or 0, state.group.unknown_sc_damage or 0));
    muted('* TP/s with an asterisk had active time censored while that player was observed at 3000 TP. Negative TP deltas are not subtracted.');
    muted('SC ownership is inferred from the prior landed weapon skill on the same target. If the opener cannot be identified confidently, the damage is kept as Unresolved SC instead of being assigned to a player.');
end

local function draw_test_lab_tab()
    header('Test Lab - LuAshitacast Command Discovery');
    if state.profile.path ~= '' then
        good(string.format('Detected %s/%s profile | %d A/B command groups | %d top-level gear sets (diagnostic only).',
            state.profile.job ~= '' and state.profile.job or 'JOB', state.profile.sub_job ~= '' and state.profile.sub_job or '---',
            #state.profile.commands, #state.profile.sets));
        imgui.TextWrapped('Profile: ' .. state.profile.path);
        imgui.Text('Source: ' .. state.profile.source);
    else
        warn('No LuAshitacast profile detected.');
    end
    if state.profile.command_error ~= '' then warn('Command scan: ' .. state.profile.command_error); end

    if imgui.Button('Query Active LAC Profile') then query_active_lac_profile(); end
    imgui.SameLine();
    if imgui.Button('Rescan Current Path') and state.profile.path ~= '' then scan_profile(state.profile.path, state.profile.source); end
    imgui.SameLine();
    if imgui.Button('Open LAC Set Browser') then AshitaCore:GetChatManager():QueueCommand(-1, '/lac list gui'); end

    imgui.Separator();
    imgui.Checkbox('Manual / custom test mode', state.benchmark.manual_mode);
    imgui.Combo('Capture Scope', state.benchmark.scope, test_scope_combo);
    imgui.Checkbox('Lock benchmark to first enemy target', state.benchmark.target_lock);
    imgui.Combo('Stop Rule', state.benchmark.stop_mode, stop_mode_combo);
    if state.benchmark.stop_mode[1] ~= 0 then imgui.InputInt('Stop Value', state.benchmark.stop_value); end
    if state.benchmark.stop_value[1] < 1 then state.benchmark.stop_value[1] = 1; end
    imgui.TextColored({ 0.60, 0.60, 0.60, 1.00 }, 'Auto maps Shot/Ranged -> ranged actions, TP/Melee -> melee rounds, WS -> weaponskills. Scope controls gear sampling, not damage parsing.');

    if not state.benchmark.manual_mode[1] then
        local groups = command_group_names();
        if #groups == 0 then
            warn('No two-level /lac fwd command families were discovered. Enable Manual / custom test mode for this profile.');
        else
            local old_group = state.benchmark.command_group[1];
            if imgui.Combo('LAC Command Group', state.benchmark.command_group, combo_string(groups)) then
                if old_group ~= state.benchmark.command_group[1] then clamp_benchmark_options(true); end
            end

            local group = current_command_group();
            local options = {};
            if group then
                for _, option in ipairs(group.options) do table.insert(options, option.display or option.value); end
            end
            imgui.Combo('Test A Option', state.benchmark.option_a, combo_string(options));
            imgui.Combo('Test B Option', state.benchmark.option_b, combo_string(options));
            imgui.Text(string.format('%d options discovered under %s.', #options, group and tostring(group.display) or '--'));

            local adef = selected_test_definition('A');
            local bdef = selected_test_definition('B');
            imgui.TextWrapped('A command: ' .. (adef.command ~= '' and adef.command or '--'));
            imgui.TextWrapped('B command: ' .. (bdef.command ~= '' and bdef.command or '--'));
        end
    else
        imgui.TextWrapped('Manual mode keeps full A/B comparison and History functionality. Commands are optional; leave them blank if you are equipping/configuring the test yourself.');
        imgui.InputText('Test A Name', state.benchmark.manual_name_a, 128);
        imgui.InputText('Test A Optional LAC Command', state.benchmark.manual_command_a, 256);
        imgui.InputText('Test B Name', state.benchmark.manual_name_b, 128);
        imgui.InputText('Test B Optional LAC Command', state.benchmark.manual_command_b, 256);
    end

    imgui.Separator();
    header('A/B Capture');
    imgui.TextColored({ 0.60, 0.60, 0.60, 1.00 }, 'Starting A or B while the other test is recording automatically stops and saves the current run first.');
    if imgui.Button('Start A Capture') then start_run('A'); end
    imgui.SameLine();
    if imgui.Button('Start B Capture') then start_run('B'); end
    imgui.SameLine();
    if imgui.Button('Stop Test') then stop_run(); end
    imgui.SameLine();
    if imgui.Button('Reset Live Only') then reset_live_capture(); end

    imgui.Text('State: ' .. (state.recording and 'RECORDING' or 'IDLE') .. ' | ' .. state.run_label);
    if state.recording and state.benchmark.current then
        local current = state.benchmark.current;
        imgui.Text('Requested command: ' .. (current.command ~= '' and current.command or '(manual / no command)'));
        if current.command ~= '' then
            imgui.Text('Command status: ' .. (current.command_issued and 'SENT TO LAC' or 'NOT SENT'));
        end
        imgui.Text(string.format('Scope: %s | scoped equipment samples: %d | target: %s', current.scope or 'all', current.gear_samples or 0, current.target_name ~= '' and current.target_name or '--'));
        imgui.TextColored({ 0.60, 0.60, 0.60, 1.00 }, 'DPSLab records actual equipment during matching self action packets. It does not assume a gear-set name from the profile.');
    end

    imgui.Separator();
    local arun = state.benchmark.runs.A;
    local brun = state.benchmark.runs.B;
    imgui.Text('Saved A: ' .. (arun and string.format('%s | %s | %s', arun.name, format_duration_short(arun.duration), arun.integrity) or '--'));
    imgui.Text('Saved B: ' .. (brun and string.format('%s | %s | %s', brun.name, format_duration_short(brun.duration), brun.integrity) or '--'));
end

local function compare_delta_text(a, b, decimals)
    a = tonumber(a) or 0;
    b = tonumber(b) or 0;
    local delta = b - a;
    local fmt = '%+.' .. tostring(decimals or 1) .. 'f';
    if math.abs(a) > 0.00001 then
        return string.format(fmt .. ' (%+.1f%%)', delta, (delta / a) * 100);
    end
    return string.format(fmt, delta);
end

local function compare_row(label, a, b, decimals, suffix)
    decimals = decimals or 1;
    suffix = suffix or '';
    local fmt = '%.' .. tostring(decimals) .. 'f%s';
    imgui.TableNextRow();
    imgui.TableNextColumn(); imgui.Text(label);
    imgui.TableNextColumn(); imgui.Text(string.format(fmt, tonumber(a) or 0, suffix));
    imgui.TableNextColumn(); imgui.Text(string.format(fmt, tonumber(b) or 0, suffix));
    imgui.TableNextColumn(); imgui.Text(compare_delta_text(a, b, decimals));
end

local function draw_compare_tab()
    header('A/B Solo Comparison');
    imgui.Text('Compare uses only frozen local-player Test A/Test B benchmark runs. Group parser data is never included.');
    if imgui.Button('Reset Compare') then
        state.benchmark.runs.A = nil;
        state.benchmark.runs.B = nil;
        state.benchmark.compare_notice = 'Compare A/B slots cleared.';
        state.benchmark.history_notice = 'Compare A/B slots were cleared.';
    end
    imgui.SameLine();
    if state.benchmark.compare_notice ~= '' then good(state.benchmark.compare_notice); end
    local a = state.benchmark.runs.A;
    local b = state.benchmark.runs.B;
    if not a or not b then
        warn('Complete and stop both Test A and Test B before comparing.');
        imgui.Text('A: ' .. (a and a.name or '--'));
        imgui.Text('B: ' .. (b and b.name or '--'));
        return;
    end

    imgui.Text('A: ' .. a.name .. ' | ' .. tostring(a.integrity or ''));
    imgui.Text('B: ' .. b.name .. ' | ' .. tostring(b.integrity or ''));
    if a.command ~= '' then imgui.TextWrapped('A command: ' .. a.command); end
    if b.command ~= '' then imgui.TextWrapped('B command: ' .. b.command); end
    if (a.target or '') ~= '' or (b.target or '') ~= '' then imgui.Text(string.format('Targets: A %s | B %s', a.target ~= '' and a.target or '--', b.target ~= '' and b.target or '--')); end
    imgui.Separator();

    if imgui.BeginTable('##ab_compare', 4, 0) then
        imgui.TableSetupColumn('Metric');
        imgui.TableSetupColumn('Test A');
        imgui.TableSetupColumn('Test B');
        imgui.TableSetupColumn('B - A');
        imgui.TableHeadersRow();
        compare_row('DPS', a.dps, b.dps, 1);
        compare_row('Total damage', a.total_damage, b.total_damage, 0);
        compare_row('Self TP/sec', a.self_tpps, b.self_tpps, 1);
        compare_row('Melee TP/sec', a.melee_tpps, b.melee_tpps, 1);
        compare_row('Ranged TP/sec', a.ranged_tpps, b.ranged_tpps, 1);
        compare_row('Accuracy', a.accuracy, b.accuracy, 1, '%');
        compare_row('Hits / melee round', a.hits_per_round, b.hits_per_round, 2);
        compare_row('WS count', a.ws_count, b.ws_count, 0);
        compare_row('Average WS', a.avg_ws, b.avg_ws, 1);
        compare_row('Avg pre-WS TP', a.avg_ws_tp, b.avg_ws_tp, 0);
        compare_row('Melee damage', a.melee_damage, b.melee_damage, 0);
        compare_row('Ranged damage', a.ranged_damage, b.ranged_damage, 0);
        compare_row('WS damage', a.ws_damage, b.ws_damage, 0);
        compare_row('Magic damage', a.magic_damage, b.magic_damage, 0);
        compare_row('Ability damage', a.ability_damage, b.ability_damage, 0);
        compare_row('Proc damage', a.proc_damage, b.proc_damage, 0);
        compare_row('Solo skillchain damage', a.skillchain_damage, b.skillchain_damage, 0);
        compare_row('Shared / unknown SC', a.shared_skillchain_damage, b.shared_skillchain_damage, 0);
        compare_row('Active seconds', a.active_seconds, b.active_seconds, 1);
        imgui.EndTable();
    end

    imgui.Separator();
    header('Observed Equipment Differences');
    imgui.Text(string.format('Scoped action gear samples: A %d | B %d', a.gear_samples or 0, b.gear_samples or 0));
    local diffs = 0;
    if imgui.BeginTable('##gear_diff', 3, 0) then
        imgui.TableSetupColumn('Slot'); imgui.TableSetupColumn('Test A'); imgui.TableSetupColumn('Test B'); imgui.TableHeadersRow();
        for _, slot in ipairs(EQUIP_SLOTS) do
            local av = (a.gear_snapshot or {})[slot.name] or '--';
            local bv = (b.gear_snapshot or {})[slot.name] or '--';
            if av ~= bv then
                diffs = diffs + 1;
                imgui.TableNextRow();
                imgui.TableNextColumn(); imgui.Text(slot.name);
                imgui.TableNextColumn(); imgui.Text(av);
                imgui.TableNextColumn(); imgui.Text(bv);
            end
        end
        imgui.EndTable();
    end
    if diffs == 0 then
        warn('No equipment difference was observed in the dominant scoped action snapshots for A vs B.');
    end
end

local function draw_tp_tab()
    header('TP Instrumentation');
    if imgui.BeginTable('##tp_summary', 3, 0) then
        imgui.TableSetupColumn('Metric');
        imgui.TableSetupColumn('Value');
        imgui.TableSetupColumn('Rate');
        imgui.TableHeadersRow();
        row3('Self generated TP', self_generated_tp(), string.format('%.1f/sec', tp_rate(self_generated_tp())));
        row3('Observed positive TP', state.tp.total_positive, string.format('%.1f/sec', tp_rate(state.tp.total_positive)));
        row3('Self melee TP', state.tp.melee, string.format('%.1f/sec', tp_rate(state.tp.melee)));
        row3('Self ranged TP', state.tp.ranged, string.format('%.1f/sec', tp_rate(state.tp.ranged)));
        row3('WS-return attributed', state.tp.ws, string.format('%.1f/sec', tp_rate(state.tp.ws)));
        row3('Ability TP', state.tp.ability, string.format('%.1f/sec', tp_rate(state.tp.ability)));
        row3('Incoming damage TP', state.tp.incoming, string.format('%.1f/sec', tp_rate(state.tp.incoming)));
        row3('Passive / unknown TP', state.tp.passive_unknown, string.format('%.1f/sec', tp_rate(state.tp.passive_unknown)));
        imgui.EndTable();
    end
    imgui.Text(string.format('Last TP change: %+d (%s)', state.tp.last_delta or 0, state.tp.last_source or '--'));
    imgui.Text(string.format('Active combat: %s | TP observable: %s | capped: %s',
        format_elapsed(active_time()), format_elapsed(tp_observable_time()), format_elapsed(state.clock.tp_capped_seconds or 0)));

    imgui.Separator();
    header('Melee Swing Attempts per Round');
    if state.stats.melee_rounds == 0 then
        imgui.Text('No melee rounds captured yet.');
    else
        local keys = {};
        for k, _ in pairs(state.round_swings) do table.insert(keys, k); end
        table.sort(keys);
        for _, swings in ipairs(keys) do
            local count = state.round_swings[swings];
            local pct = (count / state.stats.melee_rounds) * 100;
            imgui.Text(string.format('%d swings: %d rounds (%.1f%%)', swings, count, pct));
        end
    end

    imgui.Separator();
    imgui.TextWrapped('Positive TP changes are matched to the closest recent self melee/ranged/WS/ability action or incoming damaging action. Raw TP rows are retained internally and can be shown from Settings.');
end

local function damage_accuracy_row(label, damage, hits, attempts, accuracy_value)
    imgui.TableNextRow();
    imgui.TableNextColumn(); imgui.Text(label);
    imgui.TableNextColumn(); imgui.Text(tostring(damage or 0));
    imgui.TableNextColumn(); imgui.Text(hits ~= nil and tostring(hits) or '--');
    imgui.TableNextColumn(); imgui.Text(attempts ~= nil and tostring(attempts) or '--');
    imgui.TableNextColumn(); imgui.Text(accuracy_value and string.format('%.1f%%', accuracy_value) or '--');
end

local function draw_damage_tab()
    header('Damage & Accuracy');
    imgui.Text('Damage sources are separated from hit-rate measurements so misses and skillchain damage are easier to audit.');
    muted('Physical accuracy is packet-observed. Magic/ability rows do not claim an accuracy value because resist/land semantics are different.');

    if imgui.BeginTable('##damage_table', 5, 0) then
        imgui.TableSetupColumn('Source');
        imgui.TableSetupColumn('Damage');
        imgui.TableSetupColumn('Hits');
        imgui.TableSetupColumn('Attempts');
        imgui.TableSetupColumn('Accuracy');
        imgui.TableHeadersRow();

        damage_accuracy_row('Melee', state.stats.melee_damage, state.stats.melee_hits, state.stats.melee_attempts, melee_accuracy());
        damage_accuracy_row('Ranged', state.stats.ranged_damage, state.stats.ranged_hits, state.stats.ranged_attempts, ranged_accuracy());
        damage_accuracy_row('Weaponskills', state.stats.ws_damage, state.stats.ws_hits, state.stats.ws_attempts, ws_accuracy());
        damage_accuracy_row('Magic', state.stats.magic_damage, nil, nil, nil);
        damage_accuracy_row('Abilities', state.stats.ability_damage, nil, nil, nil);
        damage_accuracy_row('Additional / proc', state.stats.add_damage, nil, nil, nil);
        damage_accuracy_row('Skillchain - Solo', state.stats.skillchain_solo_damage, nil, nil, nil);
        damage_accuracy_row('Skillchain - Shared', state.stats.skillchain_shared_damage, nil, nil, nil);
        damage_accuracy_row('Skillchain - Unresolved', state.stats.skillchain_unknown_damage, nil, nil, nil);

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.TextColored(GAIA.gold, 'Total credited');
        imgui.TableNextColumn(); imgui.TextColored(GAIA.gold, tostring(state.stats.total_damage or 0));
        imgui.TableNextColumn(); imgui.Text('--');
        imgui.TableNextColumn(); imgui.Text('--');
        imgui.TableNextColumn(); imgui.Text(string.format('%.1f%% overall', accuracy()));
        imgui.EndTable();
    end

    imgui.Separator();
    local uncredited_sc = (state.stats.skillchain_shared_damage or 0) + (state.stats.skillchain_unknown_damage or 0);
    local observed_total = (state.stats.total_damage or 0) + uncredited_sc;
    imgui.Text(string.format('Credited DPS total: %d | Shared/unresolved SC: %d | All observed damage: %d',
        state.stats.total_damage or 0, uncredited_sc, observed_total));
    good('Solo/self-created skillchain damage is included in your Total and DPS.');
    muted('Shared and unresolved skillchain damage stays visible but is not assigned to one player. Incoming damage is never included in player DPS totals.');
end

local function draw_ws_tab()
    header('Weaponskill Capture');
    if next(state.ws) == nil then
        imgui.Text('No weaponskills captured yet.');
        return;
    end

    if imgui.BeginTable('##ws_table', 6, 0) then
        imgui.TableSetupColumn('WS');
        imgui.TableSetupColumn('Count');
        imgui.TableSetupColumn('Average');
        imgui.TableSetupColumn('Min');
        imgui.TableSetupColumn('Max');
        imgui.TableSetupColumn('Avg pre-WS TP');
        imgui.TableHeadersRow();

        local names = {};
        for name, _ in pairs(state.ws) do table.insert(names, name); end
        table.sort(names);
        for _, name in ipairs(names) do
            local w = state.ws[name];
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.Text(name);
            imgui.TableNextColumn(); imgui.Text(tostring(w.count));
            imgui.TableNextColumn(); imgui.Text(string.format('%.1f', w.total / math.max(1, w.count)));
            imgui.TableNextColumn(); imgui.Text(tostring(w.min or 0));
            imgui.TableNextColumn(); imgui.Text(tostring(w.max or 0));
            imgui.TableNextColumn();
            if (w.tp_count or 0) > 0 then imgui.Text(string.format('%.0f', w.tp_total / w.tp_count)); else imgui.Text('--'); end
        end
        imgui.EndTable();
    end
    imgui.Separator();
    imgui.TextWrapped('Pre-WS TP is now snapshotted from the outgoing 0x1A weaponskill request, before the server deducts TP.');
end

local function draw_history_tab()
    header('Benchmark History');
    imgui.Text('One line per completed solo Test Lab run. Newest entries are shown first.');
    if state.benchmark.history_error ~= '' then warn(state.benchmark.history_error); end
    if state.benchmark.history_notice ~= '' then good(state.benchmark.history_notice); end

    if imgui.Button('Reload History') then
        load_history();
        state.benchmark.history_selected[1] = -1;
        state.benchmark.history_delete_pending = -1;
        state.benchmark.history_notice = 'History reloaded from disk.';
    end
    imgui.SameLine();
    imgui.TextWrapped('File: ' .. history_path());
    imgui.Separator();

    local loaded_a = state.benchmark.runs.A;
    local loaded_b = state.benchmark.runs.B;
    imgui.Text('Compare A: ' .. (loaded_a and tostring(loaded_a.name or 'Benchmark') or '--'));
    imgui.SameLine();
    imgui.Text(' | Compare B: ' .. (loaded_b and tostring(loaded_b.name or 'Benchmark') or '--'));
    imgui.Separator();

    if #state.benchmark.history == 0 then
        imgui.Text('No completed benchmark runs saved yet.');
        return;
    end

    for i = #state.benchmark.history, 1, -1 do
        local run = state.benchmark.history[i];
        local job = tostring(run.job or 'JOB');
        local sub = tostring(run.sub_job or '---');
        local line = string.format('%s %s | %s/%s | %s | %s',
            tostring(run.date or ''), tostring(run.time or ''), job, sub, tostring(run.name or 'Benchmark'), format_duration_short(run.duration or 0));
        if imgui.Selectable(line .. '##history_' .. tostring(i), state.benchmark.history_selected[1] == i) then
            state.benchmark.history_selected[1] = i;
            state.benchmark.history_delete_pending = -1;
            state.benchmark.history_notice = 'Selected: ' .. tostring(run.name or 'Benchmark');
        end
    end

    local selected_index = state.benchmark.history_selected[1];
    local selected = selected_index and selected_index > 0 and state.benchmark.history[selected_index] or nil;
    if selected then
        imgui.Separator();
        header('Selected Run');
        imgui.Text(string.format('%s/%s | %s | %s', selected.job or 'JOB', selected.sub_job or '---', selected.name or 'Benchmark', selected.integrity or ''));
        if selected.command and selected.command ~= '' then imgui.TextWrapped('Command: ' .. selected.command); end
        imgui.Text(string.format('DPS %.1f | Self TP/s %.1f | Accuracy %.1f%% | WS %d', selected.dps or 0, selected.self_tpps or 0, selected.accuracy or 0, selected.ws_count or 0));
        if imgui.Button('Load Selected as A') then
            state.benchmark.runs.A = selected;
            state.benchmark.compare_notice = '';
            state.benchmark.history_notice = 'Loaded into Compare A: ' .. tostring(selected.name or 'Benchmark');
        end
        imgui.SameLine();
        if imgui.Button('Load Selected as B') then
            state.benchmark.runs.B = selected;
            state.benchmark.compare_notice = '';
            state.benchmark.history_notice = 'Loaded into Compare B: ' .. tostring(selected.name or 'Benchmark');
        end
        imgui.SameLine();
        if imgui.Button('Delete Selected') then
            state.benchmark.history_delete_pending = selected_index;
            state.benchmark.history_notice = '';
        end

        if state.benchmark.history_delete_pending == selected_index then
            warn('Delete this saved benchmark from History? This rewrites benchmarks.tsv and cannot be undone.');
            if imgui.Button('Confirm Delete') then
                if delete_history_run(selected_index) then return; end
            end
            imgui.SameLine();
            if imgui.Button('Cancel Delete') then
                state.benchmark.history_delete_pending = -1;
                state.benchmark.history_notice = 'Delete canceled.';
            end
        end
    end
end

local function draw_settings_tab()
    header('v0.6.0 Settings / Diagnostics');
    imgui.Checkbox('Show compact HUD', state.show_hud);
    imgui.Text('Live capture: ' .. (state.live.enabled[1] and 'ON' or 'OFF') .. ' | Group capture: ' .. (state.group.enabled[1] and 'ON' or 'OFF'));
    muted('Use Start / Stop / Reset controls on the Live and Group tabs. Both parsers default to ON when the addon loads.');
    good('Gaia theme is active for the DPSLab windows.');

    local raw_tp = T{ state.settings.show_raw_tp_events == true };
    if imgui.Checkbox('Show raw TP update rows in Live feed', raw_tp) then
        state.settings.show_raw_tp_events = raw_tp[1];
        settings.save();
    end

    local disk_log = T{ state.settings.log_self_events == true };
    if imgui.Checkbox('Log player event feed to ParserLogs', disk_log) then
        state.settings.log_self_events = disk_log[1];
        settings.save();
        if disk_log[1] then
            open_log();
        else
            close_log();
            state.log.path = '';
        end
    end
    imgui.TextWrapped('ParserLogs location: ' .. parser_log_directory());
    if state.settings.log_self_events then
        if state.log.path ~= '' then good('Logging: ' .. state.log.path); end
        if state.log.error ~= '' then warn(state.log.error); end
        imgui.Text(string.format('Lines written this feed: %d', state.log.lines or 0));
    else
        muted('Logging is off.');
    end

    imgui.Separator();
    imgui.Text(string.format('Active-combat idle timeout: %.1f seconds', active_timeout()));
    imgui.TextWrapped('The active clock pauses after this many seconds without a relevant combat action. TP-rate time also excludes periods observed at the 3000 TP cap.');
    imgui.Text('Retained in-memory events: ' .. tostring(state.max_events));
    imgui.Separator();
    imgui.Text('Profile commands:');
    imgui.BulletText('/dpslab rescan');
    imgui.BulletText('/dpslab profile auto');
    imgui.BulletText('/dpslab profile <same argument you would pass to /lac load>');
    imgui.BulletText('/dpslab log on|off');
    imgui.Separator();
    imgui.Text('Current profile source: ' .. state.profile.source);
end

local function draw_main_window()
    if not state.main_open[1] then return; end

    push_gaia_theme();
    imgui.SetNextWindowSizeConstraints({ 820, 460 }, { 1800, 1150 });
    if imgui.Begin('DPSLab - Gaia Combat Lab', state.main_open) then
        imgui.TextColored(GAIA.gold, 'GAIA DPSLAB');
        imgui.SameLine();
        imgui.Text('v' .. addon.version);
        imgui.SameLine();
        if state.recording then
            imgui.TextColored(GAIA.red, 'RECORDING ' .. state.run_label);
        else
            imgui.TextColored(GAIA.muted, string.format('Live:%s Group:%s', state.live.enabled[1] and 'ON' or 'OFF', state.group.enabled[1] and 'ON' or 'OFF'));
        end
        imgui.SameLine();
        imgui.Text(string.format('| TP: %d', get_current_tp()));
        imgui.Separator();

        if imgui.BeginTabBar('##dpslab_tabs', ImGuiTabBarFlags_NoCloseWithMiddleMouseButton) then
            if imgui.BeginTabItem('Live', nil) then draw_live_tab(); imgui.EndTabItem(); end
            if imgui.BeginTabItem('Group', nil) then draw_group_tab(); imgui.EndTabItem(); end
            if imgui.BeginTabItem('Test Lab', nil) then draw_test_lab_tab(); imgui.EndTabItem(); end
            if imgui.BeginTabItem('Compare', nil) then draw_compare_tab(); imgui.EndTabItem(); end
            if imgui.BeginTabItem('TP', nil) then draw_tp_tab(); imgui.EndTabItem(); end
            if imgui.BeginTabItem('Damage', nil) then draw_damage_tab(); imgui.EndTabItem(); end
            if imgui.BeginTabItem('WS', nil) then draw_ws_tab(); imgui.EndTabItem(); end
            if imgui.BeginTabItem('History', nil) then draw_history_tab(); imgui.EndTabItem(); end
            if imgui.BeginTabItem('Settings', nil) then draw_settings_tab(); imgui.EndTabItem(); end
            imgui.EndTabBar();
        end
    end
    imgui.End();
    pop_gaia_theme();
end

local function last_combat_event()
    for i = #state.events, 1, -1 do
        local e = state.events[i];
        if not e.hidden_helper and e.type ~= 'TP' then return e; end
    end
    return nil;
end

local function draw_hud()
    if not state.show_hud[1] or not state.hud_open[1] then return; end

    push_gaia_theme();
    if imgui.Begin('DPSLab HUD', state.hud_open, ImGuiWindowFlags_AlwaysAutoResize) then
        if state.recording then
            imgui.TextColored(GAIA.red, '[REC] ' .. state.run_label);
        else
            imgui.TextColored(state.live.enabled[1] and GAIA.teal or GAIA.muted, state.live.enabled[1] and '[LIVE CAPTURE]' or '[LIVE STOPPED]');
        end
        imgui.Text(string.format('DPS      %7.1f   SelfTP/s  %7.1f', dps(), tp_rate(self_generated_tp())));
        imgui.Text(string.format('Hit      %6.1f%%   MeleeTP/s %7.1f', accuracy(), tp_rate(state.tp.melee)));
        imgui.Text(string.format('RngTP/s  %7.1f   Incoming   %7d', tp_rate(state.tp.ranged), state.tp.incoming or 0));
        imgui.Text(string.format('Active %s   TP Obs %s', format_elapsed(active_time()), format_elapsed(tp_observable_time())));
        imgui.Text(string.format('Current TP: %d', get_current_tp()));
        local e = last_combat_event();
        if e then
            local tp_text = e.tp_delta and string.format(' / TP %+d', e.tp_delta) or '';
            local add_text = (e.add_damage or 0) > 0 and string.format(' / Proc %d', e.add_damage) or '';
            local sc_text = (e.sc_damage or 0) > 0 and string.format(' / SC %d', e.sc_damage) or '';
            imgui.Text(string.format('Last: %s %s | %d dmg%s%s%s', e.type, e.action, e.damage or 0, add_text, sc_text, tp_text));
        else
            imgui.Text('Last: --');
        end
    end
    imgui.End();
    pop_gaia_theme();
end

local function print_help()
    print(chat.header(addon.name):append(chat.message('Commands:')));
    print(chat.header(addon.name):append(chat.message('/dpslab - toggle main window')));
    print(chat.header(addon.name):append(chat.message('/dpslab hud - toggle HUD')));
    print(chat.header(addon.name):append(chat.message('/dpslab reset - reset Live and Group data')));
    print(chat.header(addon.name):append(chat.message('/dpslab live start|stop|reset - control solo parser')));
    print(chat.header(addon.name):append(chat.message('/dpslab group start|stop|reset - control group parser')));
    print(chat.header(addon.name):append(chat.message('/dpslab rescan - rescan active/current LuAshitacast profile')));
    print(chat.header(addon.name):append(chat.message('/dpslab lacquery - ask LuAshitacast which profile is actively loaded')));
    print(chat.header(addon.name):append(chat.message('/dpslab profile auto - return to current-job profile detection')));
    print(chat.header(addon.name):append(chat.message('/dpslab profile <name/path> - scan a profile using LuAshitacast-style path resolution')));
    print(chat.header(addon.name):append(chat.message('/dpslab log on|off - enable/disable ParserLogs event feed')));
end

local function handle_capture_domain(domain, action)
    action = tostring(action or ''):lower();
    if domain == 'live' then
        if action == 'start' or action == 'on' then start_live_capture();
        elseif action == 'stop' or action == 'off' then
            if state.recording then stop_run(); else stop_live_capture(); end
        elseif action == 'reset' then reset_live_capture();
        else
            if state.live.enabled[1] then stop_live_capture(); else start_live_capture(); end
        end
    elseif domain == 'group' then
        if action == 'start' or action == 'on' then start_group_capture();
        elseif action == 'stop' or action == 'off' then stop_group_capture();
        elseif action == 'reset' then reset_group_capture();
        else
            if state.group.enabled[1] then stop_group_capture(); else start_group_capture(); end
        end
    end
end

local function handle_dpslab_command(args)
    if #args == 1 then
        state.main_open[1] = not state.main_open[1];
        return;
    end

    local cmd = args[2]:lower();
    if cmd == 'help' then
        print_help();
    elseif cmd == 'show' then
        state.main_open[1] = true;
    elseif cmd == 'hide' then
        state.main_open[1] = false;
    elseif cmd == 'hud' then
        state.show_hud[1] = not state.show_hud[1];
        state.hud_open[1] = state.show_hud[1];
    elseif cmd == 'reset' then
        reset_all_capture();
    elseif cmd == 'live' then
        handle_capture_domain('live', args[3]);
    elseif cmd == 'group' then
        handle_capture_domain('group', args[3]);
    elseif cmd == 'rescan' then
        if state.profile.path ~= '' then scan_profile(state.profile.path, state.profile.source); else scan_default_profile(); end
    elseif cmd == 'lacquery' then
        query_active_lac_profile();
    elseif cmd == 'lacprofile' then
        if #args >= 3 then scan_profile_argument(args[3], 'active LAC query'); end
    elseif cmd == 'profile' then
        if #args < 3 or args[3]:lower() == 'auto' then
            state.profile.source = 'auto/current job';
            scan_default_profile();
        else
            scan_profile_argument(args[3], 'manual /dpslab profile');
        end
    elseif cmd == 'capture' then
        -- Backward-compatible alias for Live capture.
        handle_capture_domain('live', args[3]);
    elseif cmd == 'log' then
        local enabled = (#args >= 3) and (args[3]:lower() ~= 'off') or (not state.settings.log_self_events);
        state.settings.log_self_events = enabled;
        settings.save();
        if enabled then
            open_log();
        else
            close_log();
            state.log.path = '';
        end
    elseif cmd == 'starta' then
        start_run('A');
    elseif cmd == 'startb' then
        start_run('B');
    elseif cmd == 'stop' then
        stop_run();
    else
        print_help();
    end
end

ashita.events.register('load', 'dpslab_load_cb', function ()
    scan_default_profile();
    query_active_lac_profile();
    state.live.enabled[1] = true;
    state.group.enabled[1] = true;
    reset_all_capture();
    load_history();
    if state.settings.log_self_events then open_log(); end
    print(chat.header(addon.name):append(chat.message('Loaded v0.6.0 with Gaia UI, damage accuracy, skillchain attribution, Group accuracy, and Live/Group delta diagnostics.')));
end);

ashita.events.register('unload', 'dpslab_unload_cb', function ()
    close_log();
    settings.save();
end);

ashita.events.register('command', 'dpslab_command_cb', function (e)
    local args = e.command:args();
    if #args == 0 then return; end

    local root = args[1]:lower();
    if root == '/dpslab' then
        e.blocked = true;
        handle_dpslab_command(args);
        return;
    end

    -- Best-effort tracking of custom LuAshitacast loads while DPSLab is running.
    if root == '/lac' or root == '/luashitacast' then
        if #args >= 2 and args[2]:lower() == 'load' then
            if #args >= 3 then
                scan_profile_argument(args[3], 'observed /lac load');
            else
                scan_default_profile();
            end
        elseif #args >= 2 and args[2]:lower() == 'reload' and state.profile.path ~= '' then
            scan_profile(state.profile.path, state.profile.source);
        end
    end
end);

ashita.events.register('packet_out', 'dpslab_packet_out_cb', function (e)
    if not state.live.enabled[1] then return; end
    if e.id ~= 0x1A then return; end
    if type(e.data) ~= 'string' or #e.data < 14 then return; end

    local category = struct.unpack('H', e.data, 0x0A + 1);
    if category ~= 0x07 then return; end

    local action_id = struct.unpack('H', e.data, 0x0C + 1);
    local t = now();
    local pending = state.pending_ws;
    if pending and pending.action_id == action_id and (t - pending.clock) < 0.30 then
        return;
    end

    state.pending_ws = {
        action_id = action_id,
        tp = get_current_tp(),
        clock = t,
        injected = e.injected == true,
    };
    state.debug.outgoing_ws_packets = state.debug.outgoing_ws_packets + 1;
end);

ashita.events.register('packet_in', 'dpslab_packet_in_cb', function (e)
    if e.id == 0x028 then
        state.debug.action_packets = state.debug.action_packets + 1;
        if not state.live.enabled[1] and not state.group.enabled[1] then return; end

        local action, err = packets.parse_action(e.data_modified);
        if not action then
            if err ~= 'zero targets' then state.debug.parse_errors = state.debug.parse_errors + 1; end
            return;
        end
        state.debug.parsed_actions = state.debug.parsed_actions + 1;

        if is_duplicate(action) then
            state.debug.duplicates = state.debug.duplicates + 1;
            return;
        end

        -- Classify any SC result before either parser consumes the action.  The
        -- opener tracker is updated only after both domains see the same snapshot.
        action.skillchains = classify_skillchains(action);

        if state.group.enabled[1] then record_group_action(action); end

        if state.live.enabled[1] then
            local self_id = get_player_id();
            if self_id ~= 0 and action.actor_id == self_id then
                state.debug.self_action_packets = state.debug.self_action_packets + 1;
                record_self_action(action);
            elseif self_id ~= 0 then
                record_incoming_action(action);
            end
        end

        update_skillchain_tracker(action);

    elseif e.id == 0x0C8 or e.id == 0x0DD then
        state.group.last_refresh = 0;

    elseif e.id == 0x037 then
        state.debug.player_update_packets = state.debug.player_update_packets + 1;

    elseif e.id == 0x0DF then
        state.debug.character_update_packets = state.debug.character_update_packets + 1;
        local update = packets.parse_character_update(e.data_modified);
        if update and update.id == get_player_id() then
            handle_tp_value(update.tp, '0x0DF');
        end

    elseif e.id == 0x00A or e.id == 0x00B then
        state.entity_cache = {};
        state.tp_candidates = {};
        state.pending_ws = nil;
        state.group.last_refresh = 0;
        state.group.last_poll = 0;
    end
end);

ashita.events.register('d3d_present', 'dpslab_present_cb', function ()
    -- Polling is a fallback in case self TP is not represented by a usable 0x0DF.
    handle_tp_value(get_current_tp(), 'memory');
    poll_group_tp(false);

    local t = now();
    if (t - state.last_identity_check) > 1.0 then
        state.last_identity_check = t;
        local ident = profiles.get_identity();
        if ident and ident.job ~= state.profile.job then
            -- LuAshitacast auto-loads a new job profile without requiring the user
            -- to type /lac load.  Scan the default immediately, then ask LAC for
            -- the authoritative active filename in case a custom profile is loaded.
            scan_default_profile();
            query_active_lac_profile();
        end
    end

    check_benchmark_stop();
    draw_main_window();
    draw_hud();
end);

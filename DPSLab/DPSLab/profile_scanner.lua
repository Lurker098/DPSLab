local M = {};

local function exists(path)
    return path ~= nil and path ~= '' and ashita.fs.exists(path);
end

local function job_abbr(job_id)
    local job = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', job_id);
    if type(job) == 'string' then
        return job:trimend('\x00');
    end
    return tostring(job_id or 0);
end

local function get_identity()
    local mm = AshitaCore:GetMemoryManager();
    if not mm then return nil; end
    local party = mm:GetParty();
    local player = mm:GetPlayer();
    if not party or not player or party:GetMemberIsActive(0) ~= 1 then
        return nil;
    end

    local job_id = player:GetMainJob();
    local sub_job_id = player:GetSubJob();
    return {
        name = party:GetMemberName(0),
        id = party:GetMemberServerId(0),
        job_id = job_id,
        sub_job_id = sub_job_id,
        job = job_abbr(job_id),
        sub_job = job_abbr(sub_job_id),
    };
end

M.get_identity = get_identity;

function M.resolve_default()
    local ident = get_identity();
    if not ident then
        return nil, 'player identity unavailable';
    end

    local root = AshitaCore:GetInstallPath() .. 'config\\addons\\luashitacast\\';
    local candidates = {
        string.format('%s%s_%u\\%s.lua', root, ident.name, ident.id, ident.job),
        string.format('%s%s_%s.lua', root, ident.name, ident.job),
    };

    for _, path in ipairs(candidates) do
        if exists(path) then
            return path, nil;
        end
    end

    return nil, 'default LuAshitacast profile not found';
end

function M.resolve_like_lac(path_arg)
    if path_arg == nil or path_arg == '' then
        return M.resolve_default();
    end

    local ident = get_identity();
    if not ident then
        return nil, 'player identity unavailable';
    end

    local root = AshitaCore:GetInstallPath() .. 'config\\addons\\luashitacast\\';
    local char_root = string.format('%s%s_%u\\', root, ident.name, ident.id);
    local candidates = {
        path_arg,
        path_arg .. '.lua',
        char_root .. path_arg,
        char_root .. path_arg .. '.lua',
        root .. path_arg,
        root .. path_arg .. '.lua',
    };

    for _, path in ipairs(candidates) do
        if exists(path) then
            return path, nil;
        end
    end

    return nil, 'profile not found: ' .. tostring(path_arg);
end

-- Remove Lua comments while preserving strings.  This is intentionally a scanner,
-- not a Lua evaluator; DPSLab never executes the profile to discover commands.
local function strip_comments(source)
    local out = {};
    local i = 1;
    local quote = nil;
    local escape = false;
    local line_comment = false;
    local block_comment = false;

    while i <= #source do
        local ch = source:sub(i, i);
        local two = source:sub(i, i + 1);
        local four = source:sub(i, i + 3);

        if line_comment then
            if ch == '\n' then
                line_comment = false;
                table.insert(out, ch);
            else
                table.insert(out, ' ');
            end
            i = i + 1;
        elseif block_comment then
            if two == ']]' then
                block_comment = false;
                table.insert(out, '  ');
                i = i + 2;
            else
                table.insert(out, ch == '\n' and '\n' or ' ');
                i = i + 1;
            end
        elseif quote then
            table.insert(out, ch);
            if escape then
                escape = false;
            elseif ch == '\\' then
                escape = true;
            elseif ch == quote then
                quote = nil;
            end
            i = i + 1;
        else
            if four == '--[[' then
                block_comment = true;
                table.insert(out, '    ');
                i = i + 4;
            elseif two == '--' then
                line_comment = true;
                table.insert(out, '  ');
                i = i + 2;
            elseif ch == '\'' or ch == '"' then
                quote = ch;
                table.insert(out, ch);
                i = i + 1;
            else
                table.insert(out, ch);
                i = i + 1;
            end
        end
    end
    return table.concat(out);
end

local function read_source(path)
    if not exists(path) then return nil, 'profile file does not exist'; end
    local file = io.open(path, 'r');
    if not file then return nil, 'unable to open profile file'; end
    local source = file:read('*a');
    file:close();
    return source, nil;
end

-- Legacy set discovery is retained for diagnostics and the LAC set browser, but
-- Test Lab command discovery no longer depends on equipment-set names.
function M.scan_sets(path)
    local source, err = read_source(path);
    if not source then return {}, err; end
    source = strip_comments(source);

    local sets = {};
    local body = source:match('local%s+[sS]ets%s*=%s*{(.-)\n}%s*;')
        or source:match('profile%.Sets%s*=%s*{(.-)\n}%s*;');
    if not body then
        return {}, 'sets table not found in profile';
    end

    -- This remains intentionally top-level and best-effort.
    for name in body:gmatch('\n%s*([%a_][%w_]*)%s*=%s*{') do
        table.insert(sets, name);
    end
    table.sort(sets, function(a, b) return a:lower() < b:lower(); end);
    return sets, nil;
end

local function title_case(value)
    value = tostring(value or '');
    if value == '' then return value; end
    return value:sub(1, 1):upper() .. value:sub(2);
end

local function parse_string_list(body)
    local values = {};
    local seen = {};
    local pos = 1;

    -- Lua patterns do not provide a regex-style quote backreference.  Scan
    -- single- and double-quoted literals independently and preserve source order.
    while pos <= #body do
        local s1, e1, v1 = body:find("'([^']*)'", pos);
        local s2, e2, v2 = body:find('"([^"]*)"', pos);
        local s, e, value;
        if s1 and (not s2 or s1 < s2) then
            s, e, value = s1, e1, v1;
        elseif s2 then
            s, e, value = s2, e2, v2;
        else
            break;
        end
        if value ~= '' and not seen[value] then
            table.insert(values, value);
            seen[value] = true;
        end
        pos = e + 1;
    end
    return values;
end

local function parse_mode_tables(source)
    local lists = {};
    -- Common profile style: local shotModes = { 'Normal', 'Accuracy', 'Attack' };
    for name, body in source:gmatch('local%s+([%a_][%w_]*)%s*=%s*T?%s*{(.-)}%s*;?') do
        local values = parse_string_list(body);
        if #values > 0 then lists[name] = values; end
    end
    return lists;
end

local function extract_handle_command(source)
    local s = source:find('profile%.HandleCommand%s*=%s*function%s*%(%s*args%s*%)');
    if not s then
        return nil;
    end
    local tail = source:sub(s);
    -- Profiles normally define the next callback as profile.<Name> = function.
    -- Cutting there is safer than trying to fully parse arbitrary Lua nesting.
    local after_header = tail:find('\n%s*profile%.[%a_][%w_]*%s*=%s*function', 2);
    if after_header then
        return tail:sub(1, after_header - 1);
    end
    return tail;
end

local function add_option(group, display, command_value)
    if not display or display == '' then return; end
    command_value = command_value or display;
    group._seen = group._seen or {};
    local key = tostring(command_value):lower();
    if group._seen[key] then return; end
    group._seen[key] = true;
    table.insert(group.options, {
        display = display,
        value = command_value,
    });
end

-- Discover command families from HandleCommand(args).  Supported forms include:
--   if args[1] == 'shot' then ... args[2] == 'accuracy' ...
--   local requested = setModeFromArg(shotModes, args[2]);
-- where shotModes is a literal local string list.
function M.scan_commands(path)
    local raw, err = read_source(path);
    if not raw then return {}, err; end
    local source = strip_comments(raw);
    local handle = extract_handle_command(source);
    if not handle then
        return {}, 'profile.HandleCommand(args) not found';
    end

    local mode_lists = parse_mode_tables(source);
    local matches = {};

    local function collect(pattern)
        local pos = 1;
        while true do
            local s, e, value = handle:find(pattern, pos);
            if not s then break; end
            table.insert(matches, { s = s, e = e, value = value });
            pos = e + 1;
        end
    end

    -- args[1] == 'shot' / "shot"
    collect("args%s*%[%s*1%s*%]%s*==%s*'([^']*)'");
    collect('args%s*%[%s*1%s*%]%s*==%s*"([^"]*)"');
    -- 'shot' == args[1] / "shot" == args[1]
    collect("'([^']*)'%s*==%s*args%s*%[%s*1%s*%]");
    collect('"([^"]*)"%s*==%s*args%s*%[%s*1%s*%]');
    -- args[1]:lower() == 'shot'
    collect("args%s*%[%s*1%s*%]%s*:%s*lower%s*%(%s*%)%s*==%s*'([^']*)'");
    collect('args%s*%[%s*1%s*%]%s*:%s*lower%s*%(%s*%)%s*==%s*"([^"]*)"');
    -- string.lower(args[1]) == 'shot'
    collect("string%.lower%s*%(%s*args%s*%[%s*1%s*%]%s*%)%s*==%s*'([^']*)'");
    collect('string%.lower%s*%(%s*args%s*%[%s*1%s*%]%s*%)%s*==%s*"([^"]*)"');

    table.sort(matches, function(a, b) return a.s < b.s; end);

    -- De-duplicate equivalent group comparisons discovered by overlapping forms.
    local unique_matches = {};
    local seen_positions = {};
    for _, match in ipairs(matches) do
        local k = tostring(match.s) .. ':' .. tostring(match.e) .. ':' .. tostring(match.value):lower();
        if match.value ~= '' and not seen_positions[k] then
            table.insert(unique_matches, match);
            seen_positions[k] = true;
        end
    end
    matches = unique_matches;

    local function scan_arg2_literals(branch, group)
        local patterns = {
            "args%s*%[%s*2%s*%]%s*==%s*'([^']*)'",
            'args%s*%[%s*2%s*%]%s*==%s*"([^"]*)"',
            "'([^']*)'%s*==%s*args%s*%[%s*2%s*%]",
            '"([^"]*)"%s*==%s*args%s*%[%s*2%s*%]',
            "args%s*%[%s*2%s*%]%s*:%s*lower%s*%(%s*%)%s*==%s*'([^']*)'",
            'args%s*%[%s*2%s*%]%s*:%s*lower%s*%(%s*%)%s*==%s*"([^"]*)"',
            "string%.lower%s*%(%s*args%s*%[%s*2%s*%]%s*%)%s*==%s*'([^']*)'",
            'string%.lower%s*%(%s*args%s*%[%s*2%s*%]%s*%)%s*==%s*"([^"]*)"',
        };
        for _, pattern in ipairs(patterns) do
            for value in branch:gmatch(pattern) do
                add_option(group, value, value);
            end
        end
    end

    local groups = {};
    local by_key = {};
    for i, match in ipairs(matches) do
        local key = match.value;
        local lower = key:lower();
        local group = by_key[lower];
        if not group then
            group = {
                key = key,
                display = title_case(key),
                options = {},
            };
            by_key[lower] = group;
            table.insert(groups, group);
        end

        local stop = (matches[i + 1] and matches[i + 1].s - 1) or #handle;
        local branch = handle:sub(match.e + 1, stop);
        scan_arg2_literals(branch, group);

        -- Common helper-list pattern used by Gaia profiles.
        for list_name in branch:gmatch('setModeFromArg%s*%(%s*([%a_][%w_]*)%s*,%s*args%s*%[%s*2%s*%]%s*%)') do
            local values = mode_lists[list_name] or {};
            for _, value in ipairs(values) do
                add_option(group, value, value);
            end
        end
    end

    -- A family with no discoverable second-level values is a one-shot command
    -- (for example `status`) rather than an A/B test family, so omit it.
    local filtered = {};
    for _, group in ipairs(groups) do
        group._seen = nil;
        if #group.options > 0 then
            table.insert(filtered, group);
        end
    end

    return filtered, nil;
end

-- Kept for compatibility with older DPSLab code and diagnostic use.
function M.classify(name)
    local n = name:lower();
    if n:match('^tp') or n:find('_tp', 1, true) then
        return 'TP';
    elseif n:match('^ws') then
        return 'WS';
    elseif n:match('^ranged') or n:find('shot', 1, true) or n:find('barrage', 1, true) then
        return 'Ranged';
    elseif n:find('pdt', 1, true) or n:find('mdt', 1, true) or n:find('evasion', 1, true) or n:find('defense', 1, true) then
        return 'Defense';
    end
    return 'Utility';
end

function M.filter_sets(sets, group)
    if group == nil or group == 'All' then
        local copy = {};
        for _, v in ipairs(sets) do table.insert(copy, v); end
        return copy;
    end

    local out = {};
    for _, name in ipairs(sets) do
        if M.classify(name) == group then table.insert(out, name); end
    end
    return out;
end

return M;

local M = {};

local Reader = {};
Reader.__index = Reader;

function Reader.new(data)
    return setmetatable({ data = data or '', byte = 1, bitpos = 0 }, Reader);
end

function Reader:seek_zero_based(byte_offset)
    self.byte = byte_offset + 1;
    self.bitpos = 0;
end

function Reader:read(bits)
    local out = 0;
    for i = 0, bits - 1 do
        local b = string.byte(self.data, self.byte) or 0;
        local bit_value = bit.band(bit.rshift(b, self.bitpos), 1);
        out = bit.bor(out, bit.lshift(bit_value, i));
        self.bitpos = self.bitpos + 1;
        if self.bitpos >= 8 then
            self.bitpos = 0;
            self.byte = self.byte + 1;
        end
    end
    return out;
end

function M.parse_action(data)
    if type(data) ~= 'string' or #data < 10 then
        return nil, 'invalid action packet data';
    end

    local r = Reader.new(data);
    r:seek_zero_based(5);

    local a = {
        actor_id = r:read(32),
        target_count = r:read(6),
        result_count = r:read(4),
        category = r:read(4),
        param = r:read(32),
        recast = r:read(32),
        targets = {},
    };

    if a.target_count == 0 then
        return nil, 'zero targets';
    end

    for _ = 1, a.target_count do
        local target = {
            id = r:read(32),
            action_count = r:read(4),
            actions = {},
        };

        for _ = 1, target.action_count do
            local result = {
                reaction = r:read(3),
                kind = r:read(2),
                animation = r:read(12),
                effect = r:read(5),
                stagger = r:read(5),
                value = r:read(17),
                message = r:read(10),
                unknown = r:read(31),
            };

            if r:read(1) > 0 then
                result.has_add_effect = true;
                result.add_animation = r:read(6);
                result.add_effect = r:read(4);
                result.add_value = r:read(17);
                result.add_message = r:read(10);
            else
                result.has_add_effect = false;
                result.add_animation = 0;
                result.add_effect = 0;
                result.add_value = 0;
                result.add_message = 0;
            end

            if r:read(1) > 0 then
                result.has_spike_effect = true;
                result.spike_animation = r:read(6);
                result.spike_effect = r:read(4);
                result.spike_value = r:read(14);
                result.spike_message = r:read(10);
            else
                result.has_spike_effect = false;
                result.spike_animation = 0;
                result.spike_effect = 0;
                result.spike_value = 0;
                result.spike_message = 0;
            end

            table.insert(target.actions, result);
        end

        table.insert(a.targets, target);
    end

    return a, nil;
end

function M.parse_character_update(data)
    if type(data) ~= 'string' or #data < 24 then
        return nil;
    end

    local r = Reader.new(data);
    r:seek_zero_based(4);
    return {
        id = r:read(32),
        hp = r:read(32),
        mp = r:read(32),
        tp = r:read(32),
        index = r:read(16),
        hpp = r:read(16),
        mpp = r:read(16),
    };
end

function M.category_name(category)
    local names = {
        [0] = 'None',
        [1] = 'Melee',
        [2] = 'Ranged',
        [3] = 'WS',
        [4] = 'Magic',
        [5] = 'Item',
        [6] = 'Ability',
        [7] = 'MobSkillStart',
        [8] = 'MagicStart',
        [9] = 'ItemStart',
        [10] = 'AbilityStart',
        [11] = 'MobSkill',
        [12] = 'RangedStart',
        [13] = 'PetAbility',
        [14] = 'Dancer',
        [15] = 'RuneFencer',
    };
    return names[category] or ('Category' .. tostring(category));
end

function M.reaction_name(reaction)
    local names = {
        [0] = 'hit',
        [1] = 'miss',
        [2] = 'guard',
        [3] = 'parry',
        [4] = 'block',
        [9] = 'evade',
    };
    return names[reaction] or tostring(reaction);
end

return M;

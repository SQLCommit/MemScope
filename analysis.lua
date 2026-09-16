--[[
    MemScope v1.2.0 - Analysis Engine
    Ring buffers, trend analysis, growth/spike observation, addon pool management.

    NOTE: Per-addon memory from /addon list only reflects Lua-tracked memory.
    FFI allocations, ImGui usage, and C++ internals are not included.
    LuaJIT jitting causes normal memory growth patterns that are not leaks.
    (Clarified by atom0s, Feb 2026)
]]--

local analysis = {};

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local HISTORY_SIZE = 3600;        -- one hour at the 1 s minimum interval (was 720 = 1 h at 5 s)
local ADDON_HISTORY_SIZE = 600;   -- ten minutes at 1 s; rings are allocated when a slot is first used
local MAX_TRACKED_ADDONS = 256;   -- matches monitor MAX_CAPTURE; 35 addons was already past half of 64
local ZONE_MARK_SIZE = 64;
local MIN_SAMPLES_FOR_TREND = 3;
local TREND_ALPHA = 0.3;  -- EMA weight: 0.3 = responsive, 0.1 = smooth
local MIN_KB_SENTINEL = 999999;  -- Initial min_kb value (replaced on first real sample)

-------------------------------------------------------------------------------
-- Cached References
-------------------------------------------------------------------------------
local math_max = math.max;
local math_min = math.min;
local os_time = os.time;
local string_format = string.format;
local table_sort = table.sort;

-------------------------------------------------------------------------------
-- Module State (set via init)
-------------------------------------------------------------------------------
local state = nil;

-------------------------------------------------------------------------------
-- Public Constants (for other modules)
-------------------------------------------------------------------------------
analysis.HISTORY_SIZE = HISTORY_SIZE;
analysis.ADDON_HISTORY_SIZE = ADDON_HISTORY_SIZE;
analysis.MAX_TRACKED_ADDONS = MAX_TRACKED_ADDONS;
analysis.ZONE_MARK_SIZE = ZONE_MARK_SIZE;
analysis.MIN_SAMPLES_FOR_TREND = MIN_SAMPLES_FOR_TREND;
analysis.MIN_KB_SENTINEL = MIN_KB_SENTINEL;

-- A time limit supplements the fixed sample caps; it never expands the rings.
function analysis.history_minutes(value)
    local n = tonumber(value);
    if not n or n ~= n or n == math.huge or n == -math.huge then return 60; end
    return math_max(1, math_min(180, math.floor(n)));
end

-- Remove the oldest entries in place; head stays the next write slot. Clear all
-- parallel fields so exports cannot recover expired data through a stale slot.
function analysis.prune_history(now, force)
    if not state or not state.history then return; end
    now = now or os_time();
    local minutes = analysis.history_minutes(state.settings and state.settings.history_minutes);
    if not force and state.history_pruned_at == now and state.history_pruned_minutes == minutes then return; end
    state.history_pruned_at, state.history_pruned_minutes = now, minutes;
    local cutoff = now - minutes * 60;
    local h = state.history;
    while h.count > 0 do
        local idx = (h.head - h.count - 1) % HISTORY_SIZE + 1;
        if h.timestamps[idx] >= cutoff then break; end
        h.working_set[idx], h.pagefile[idx], h.addon_total[idx], h.timestamps[idx] = 0, 0, 0, 0;
        h.count = h.count - 1;
    end
    for _, data in pairs(state.addons) do
        while data.history_count > 0 do
            local idx = (data.history_head - data.history_count - 1) % ADDON_HISTORY_SIZE + 1;
            if data.history_ts[idx] >= cutoff then break; end
            data.history[idx], data.history_ts[idx], data.history_seq[idx] = 0, 0, 0;
            data.history_count = data.history_count - 1;
        end
        if data.history_count == 0 then
            data.last_delta, data.trend_slope, data.alert_active = 0, 0, false;
        end
    end
    while state.zone_mark_count > 0 do
        local idx = (state.zone_mark_head - state.zone_mark_count - 1) % ZONE_MARK_SIZE + 1;
        local m = state.zone_marks[idx];
        if m.t >= cutoff then break; end
        m.t, m.zone_id, m.name = 0, 0, '';
        state.zone_mark_count = state.zone_mark_count - 1;
    end
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------
function analysis.init(shared_state)
    state = shared_state;
    state.history_pruned_at, state.history_pruned_minutes = nil, nil;

    -- Sort state (tracked so prune_and_sort respects current sort)
    state.sort_col = 1;      -- default: Memory
    state.sort_asc = false;   -- default: descending

    -- Pre-allocate process memory history ring buffers
    state.history = {
        working_set = {},
        pagefile = {},
        addon_total = {},
        timestamps = {},
        head = 1,
        count = 0,
    };
    for i = 1, HISTORY_SIZE do
        state.history.working_set[i] = 0;
        state.history.pagefile[i] = 0;
        state.history.addon_total[i] = 0;
        state.history.timestamps[i] = 0;
    end

    -- Addon tracking
    state.addons = {};
    state.addon_order = {};
    state.addon_pool = {};
    state.pool_index = 1;
    state.pool_free = {};       -- Free list: reclaimed pool indices for reuse
    state.pool_free_count = 0;

    -- Pre-allocate addon data pool
    for i = 1, MAX_TRACKED_ADDONS do
        state.addon_pool[i] = {
            name = '',
            memory_kb = 0,
            status = 'Unknown',
            peak_kb = 0,
            min_kb = MIN_KB_SENTINEL,
            last_delta = 0,
            trend_slope = 0,
            history = nil,        -- three parallel rings (value / os.time() / poll seq), allocated on first use:
            history_ts = nil,     -- 256 slots x 600 x 3 would be ~7 MB up front for a memory monitor
            history_seq = nil,
            history_head = 1,
            history_count = 0,
            last_update = 0,
            alert_active = false,
        };
    end

    -- Alerts ring buffer
    -- Zone markers: {t, zone_id, name} per zone change, drawn on the charts and exported
    state.zone_marks = {};
    state.zone_mark_head = 1;
    state.zone_mark_count = 0;
    for i = 1, ZONE_MARK_SIZE do state.zone_marks[i] = { t = 0, zone_id = 0, name = '' }; end

    state.alerts = {};
    state.alert_head = 1;
    state.alert_count = 0;
    state.max_alerts = 20;
    for i = 1, state.max_alerts do
        state.alerts[i] = {
            time = 0,
            addon_name = '',
            alert_type = '',
            message = '',
        };
    end
end

-------------------------------------------------------------------------------
-- Addon Data Management
-------------------------------------------------------------------------------
local function get_or_create_addon_data(name)
    local data = state.addons[name];
    if not data then
        -- Try free list first, then fresh pool slot
        if state.pool_free_count > 0 then
            local idx = state.pool_free[state.pool_free_count];
            state.pool_free[state.pool_free_count] = nil;
            state.pool_free_count = state.pool_free_count - 1;
            data = state.addon_pool[idx];
        elseif state.pool_index <= MAX_TRACKED_ADDONS then
            data = state.addon_pool[state.pool_index];
            state.pool_index = state.pool_index + 1;
        else
            return nil;
        end

        if data.history == nil then
            -- first use of this slot: allocate its rings once (never per frame, never per poll)
            data.history, data.history_ts, data.history_seq = {}, {}, {};
            for j = 1, ADDON_HISTORY_SIZE do
                data.history[j] = 0; data.history_ts[j] = 0; data.history_seq[j] = 0;
            end
        end
        data.name = name;
        data.memory_kb = 0;
        data.status = 'Unknown';
        data.peak_kb = 0;
        data.min_kb = MIN_KB_SENTINEL;
        data.last_delta = 0;
        data.trend_slope = 0;
        data.history_head = 1;
        data.history_count = 0;
        data.last_update = 0;
        data.alert_active = false;

        state.addons[name] = data;
        state.addon_order[#state.addon_order + 1] = name;
    end
    return data;
end

-------------------------------------------------------------------------------
-- Alert System
-------------------------------------------------------------------------------
local function add_alert(addon_name, alert_type, message)
    local alert = state.alerts[state.alert_head];
    alert.time = os_time();
    alert.addon_name = addon_name;
    alert.alert_type = alert_type;
    alert.message = message;

    state.alert_head = state.alert_head % state.max_alerts + 1;
    if state.alert_count < state.max_alerts then
        state.alert_count = state.alert_count + 1;
    end

    if state.settings.alerts_enabled then
        local chat = state.chat;
        if chat then
            print(chat.header('MemScope') .. chat.warning(string_format('%s: %s', addon_name, message)));
        else
            print(string_format('\30\02[MemScope]\30\01 %s: %s', addon_name, message));
        end
    end
end

local function check_addon_alerts(data)
    if not state.settings or not state.settings.alerts_enabled then return; end

    -- Growth observation (sustained increase)
    -- NOTE: LuaJIT jitting and normal Lua VM behavior can cause sustained growth
    -- that is NOT a leak. These alerts are informational only — investigate before
    -- concluding there is an actual problem. (Clarified by atom0s)
    if data.trend_slope > state.settings.growth_threshold then
        if not data.alert_active then
            data.alert_active = true;
            add_alert(data.name, 'growth',
                string_format('Sustained growth: %.2f KB/sec (may be normal LuaJIT behavior)', data.trend_slope));
        end
    else
        data.alert_active = false;
    end

    -- Spike observation (requires both % threshold AND minimum absolute change)
    -- NOTE: LuaJIT hot-path compilation can cause legitimate memory jumps.
    if data.history_count >= 2 then
        -- history_head was already advanced past the just-written current sample
        -- (update_addon pushes then post-increments before calling this), so the
        -- previous sample is at head-3 in this 1-based ring (head-2 is the current).
        local prev_idx = (data.history_head - 3) % ADDON_HISTORY_SIZE + 1;
        local prev = data.history[prev_idx];
        if prev > 0 then
            local abs_change = data.memory_kb - prev;
            local pct_change = (abs_change / prev) * 100;
            local min_abs = state.settings.spike_min_kb or 512;
            if pct_change > state.settings.spike_threshold and abs_change > min_abs then
                add_alert(data.name, 'spike',
                    string_format('Memory jump: %.1f%% increase (%.2f -> %.2f KB)',
                        pct_change, prev, data.memory_kb));
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Public: Update addon tracking data
-------------------------------------------------------------------------------
-- One AddonManager read = one poll. Every sample written during it (including the
-- unload zeros in prune_and_sort) carries this number, so the export can align rows by poll even
-- when two polls land in the same os.time() second (recheck F11).
function analysis.begin_poll()
    analysis.prune_history();
    state.poll_seq = (state.poll_seq or 0) + 1;
    return state.poll_seq;
end

function analysis.update_addon(name, memory_kb, status_val)
    analysis.prune_history();
    local data = get_or_create_addon_data(name);
    if not data then return; end

    local now = os_time();
    local old_memory = data.memory_kb;

    data.memory_kb = memory_kb;
    data.status = status_val;
    data.peak_kb = math_max(data.peak_kb, memory_kb);
    data.min_kb = math_min(data.min_kb, memory_kb);

    if data.history_count > 0 and data.last_update > 0 then
        local dt = now - data.last_update;
        if dt > 0 then
            data.last_delta = (memory_kb - old_memory) / dt;
        end
    end
    data.last_update = now;

    -- Push to per-addon history (value + timestamp, parallel rings)
    data.history[data.history_head] = memory_kb;
    data.history_ts[data.history_head] = now;
    data.history_seq[data.history_head] = state.poll_seq or 0;
    data.history_head = data.history_head % ADDON_HISTORY_SIZE + 1;
    if data.history_count < ADDON_HISTORY_SIZE then
        data.history_count = data.history_count + 1;
    end

    -- Trend: EMA of delta (directly tracks rate of change, very responsive)
    if data.history_count >= MIN_SAMPLES_FOR_TREND then
        data.trend_slope = data.trend_slope * (1 - TREND_ALPHA) + data.last_delta * TREND_ALPHA;
    end

    check_addon_alerts(data);
end

-------------------------------------------------------------------------------
-- Public: Zone markers (ring of ZONE_MARK_SIZE; oldest overwritten)
-------------------------------------------------------------------------------
function analysis.push_zone_mark(t, zone_id, name)
    local m = state.zone_marks[state.zone_mark_head];
    m.t = t; m.zone_id = zone_id; m.name = name or '';
    state.zone_mark_head = state.zone_mark_head % ZONE_MARK_SIZE + 1;
    if state.zone_mark_count < ZONE_MARK_SIZE then state.zone_mark_count = state.zone_mark_count + 1; end
end

--- Iterate zone marks oldest -> newest: for i, m in analysis.zone_marks() do ... end
function analysis.zone_marks()
    local n, head, i = state.zone_mark_count, state.zone_mark_head, 0;
    return function()
        i = i + 1;
        if i > n then return nil; end
        return i, state.zone_marks[(head - n + i - 2) % ZONE_MARK_SIZE + 1];
    end
end

-------------------------------------------------------------------------------
-- Public: Push to process memory history
-------------------------------------------------------------------------------
function analysis.push_history(ws_mb, pf_mb, addon_total_kb)
    analysis.prune_history();
    local h = state.history;
    h.working_set[h.head] = ws_mb;
    h.pagefile[h.head] = pf_mb;
    h.addon_total[h.head] = addon_total_kb;
    h.timestamps[h.head] = os_time();

    h.head = h.head % HISTORY_SIZE + 1;
    if h.count < HISTORY_SIZE then
        h.count = h.count + 1;
    end
end

-------------------------------------------------------------------------------
-- Public: Mark absent addons as Unloaded (preserving history), then sort
-------------------------------------------------------------------------------
function analysis.prune_and_sort(current_names)
    -- Build lookup set from current poll results
    local present = {};
    for i = 1, #current_names do
        present[current_names[i]] = true;
    end

    -- Mark absent addons as Unloaded (keep history for analysis)
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data and not present[name] and data.status ~= 'Unloaded' then
            data.status = 'Unloaded';
            data.memory_kb = 0;
            data.last_delta = 0;
            -- Push 0 to history so the chart shows the unload event
            data.history[data.history_head] = 0;
            data.history_ts[data.history_head] = os_time();
            data.history_seq[data.history_head] = state.poll_seq or 0;
            data.history_head = data.history_head % ADDON_HISTORY_SIZE + 1;
            if data.history_count < ADDON_HISTORY_SIZE then
                data.history_count = data.history_count + 1;
            end
        end
    end

    -- Re-sort using current sort state
    analysis.sort_addons(state.sort_col, state.sort_asc);
end

-------------------------------------------------------------------------------
-- Public: Sort pinned addons first, then by column (unloaded last within each group)
-- col_id: 0=Name, 1=Memory, 2=Status, 3=Delta, 4=Trend
-- ascending: true = A-Z / low-high, false = Z-A / high-low
-------------------------------------------------------------------------------
analysis.SORT_NAME   = 0;
analysis.SORT_MEMORY = 1;
analysis.SORT_STATUS = 2;
analysis.SORT_DELTA  = 3;
analysis.SORT_TREND  = 4;

-- Ashita's merge assigns missing nested tables by reference. Detach star preferences
-- from defaults and other settings objects at each load/reset boundary.
function analysis.copy_pins(pins)
    local copy = {};
    if type(pins) == 'table' then
        for name, pinned in pairs(pins) do
            if type(name) == 'string' and pinned == true then copy[name] = true; end
        end
    end
    return copy;
end

function analysis.is_pinned(name)
    local pins = state.settings and state.settings.pinned_addons;
    return type(pins) == 'table' and pins[name] == true;
end

function analysis.toggle_pin(name)
    if type(state.settings.pinned_addons) ~= 'table' then state.settings.pinned_addons = {}; end
    state.settings.pinned_addons[name] = not analysis.is_pinned(name) or nil;
    state.settings_save_requested = true;
    -- Caller sorts after drawing the table, never while iterating its rows.
end

function analysis.sort_addons(col_id, ascending)
    table_sort(state.addon_order, function(a, b)
        local data_a = state.addons[a];
        local data_b = state.addons[b];
        if not data_a or not data_b then return false; end

        local a_pinned, b_pinned = analysis.is_pinned(a), analysis.is_pinned(b);
        if a_pinned ~= b_pinned then return a_pinned; end

        -- Within each group, unloaded addons stay below loaded ones.
        local a_loaded = data_a.status ~= 'Unloaded';
        local b_loaded = data_b.status ~= 'Unloaded';
        if a_loaded ~= b_loaded then
            return a_loaded;
        end

        local va, vb;
        if col_id == 0 then         -- Name
            va, vb = data_a.name:lower(), data_b.name:lower();
        elseif col_id == 1 then     -- Memory
            va, vb = data_a.memory_kb, data_b.memory_kb;
        elseif col_id == 2 then     -- Status
            va, vb = data_a.status, data_b.status;
        elseif col_id == 3 then     -- Delta
            va, vb = data_a.last_delta, data_b.last_delta;
        elseif col_id == 4 then     -- Trend
            va, vb = data_a.trend_slope, data_b.trend_slope;
        else
            va, vb = data_a.memory_kb, data_b.memory_kb;
        end

        if ascending then
            return va < vb;
        else
            return va > vb;
        end
    end);
end

-------------------------------------------------------------------------------
-- Public: Remove a specific addon from tracking
-------------------------------------------------------------------------------
function analysis.remove_addon(name)
    -- Find pool index for free list reclamation
    local data = state.addons[name];
    if data then
        for i = 1, state.pool_index - 1 do
            if state.addon_pool[i] == data then
                state.pool_free_count = state.pool_free_count + 1;
                state.pool_free[state.pool_free_count] = i;
                break;
            end
        end
    end

    -- Remove from lookup table
    state.addons[name] = nil;

    -- Remove from ordered list
    local new_order = {};
    for _, n in ipairs(state.addon_order) do
        if n ~= name then
            new_order[#new_order + 1] = n;
        end
    end
    state.addon_order = new_order;
end

-------------------------------------------------------------------------------
-- Public: Remove all Unloaded addons from tracking (mirrors remove_addon)
-------------------------------------------------------------------------------
function analysis.clear_unloaded()
    -- Collect first, since remove_addon rebuilds addon_order
    local to_remove = {};
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data and data.status == 'Unloaded' then
            to_remove[#to_remove + 1] = name;
        end
    end
    for i = 1, #to_remove do
        analysis.remove_addon(to_remove[i]);
    end
end

-------------------------------------------------------------------------------
-- Public: Calculate total addon memory
-------------------------------------------------------------------------------
function analysis.get_addon_total_kb()
    local total = 0;
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data and data.status ~= 'Unloaded' then
            total = total + data.memory_kb;
        end
    end
    return total;
end

return analysis;

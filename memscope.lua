--[[
    MemScope v1.2.0 - Memory Monitoring Addon for Ashita v4

    Tracks per-addon Lua memory through Ashita's AddonManager binding, process
    memory via Windows FFI, and provides growth analysis with historical trends.

    NOTE: Per-addon values reflect Lua-tracked memory only. FFI, ImGui,
    and C++ allocations are excluded. Growth alerts are informational —
    LuaJIT jitting causes normal memory increases that are not leaks.

    Commands:
        /memscope              - Toggle the MemScope window
        /memscope show / hide  - Show or hide the window
        /memscope compact      - Toggle compact overlay mode
        /memscope settings     - Open the settings window
        /memscope resetui      - Reset window size and position
        /memscope pause        - Pause/resume data collection
        /memscope snapshot     - Take manual memory snapshot
        /memscope report       - Print memory report to chat
        /memscope export       - Export session data to Excel (.xls)
        /memscope gc           - Force garbage collection (this addon only)
        /memscope trim         - Trim working set (actual vs inflated memory)
        /memscope alerts [on/off] - Toggle growth alerts
        /memscope zones [on/off]  - Toggle zone-change markers on the charts
        /memscope clear        - Remove all unloaded addons from tracking
        /memscope remove <name> - Remove one addon from tracking

    Author: SQLCommit
    Version: 1.2.0
]]--

addon.name    = 'memscope';
addon.author  = 'SQLCommit';
addon.version = '1.2.0';
addon.desc    = 'Memory monitoring and analysis for Ashita addons';
addon.link    = 'https://github.com/SQLCommit/memscope';

require 'common';

local chat     = require 'chat';
local settings = require 'settings';

local analysis = require 'analysis';
local monitor  = require 'monitor';
local ui       = require 'ui';

-------------------------------------------------------------------------------
-- Default Settings
-------------------------------------------------------------------------------
local default_settings = T{
    pinned_addons       = T{},
    theme               = 'dark', -- 'default' follows the current Ashita ImGui theme
    sample_interval     = 5,
    history_minutes     = 60,     -- rolling time limit, in addition to fixed sample caps
    addon_poll_interval = 10,      -- AddonManager reads are cheap (~35 calls); 30 s was the /addon list era
    show_process_memory = true,
    show_addon_breakdown = true,
    show_charts         = true,
    zone_markers        = true,    -- vertical lines on the charts where the zone changed
    chart_height        = 80,
    alerts_enabled      = false,    -- Off by default: most alerts are false positives from LuaJIT jitting
    growth_threshold    = 50.0,    -- Raised from 10 — lower values trigger on normal LuaJIT behavior
    spike_threshold     = 100,
    spike_min_kb        = 512,
    auto_gc_monitoring  = true,
    show_on_load        = true,
    compact_bg_alpha    = 0.8,
    compact_titlebar    = true,
};

-------------------------------------------------------------------------------
-- Shared State
-------------------------------------------------------------------------------
local state = {
    settings = nil,
    chat = nil,

    -- Timing
    last_sample_time = 0,
    last_addon_poll_time = 0,

    -- Current readings (reused table)
    current = {
        working_set_mb = 0,
        peak_working_set_mb = 0,
        pagefile_mb = 0,
        peak_pagefile_mb = 0,
        total_phys_mb = 0,
        avail_phys_mb = 0,
        total_pagefile_mb = 0,
        avail_pagefile_mb = 0,
        total_virtual_mb = 0,
        avail_virtual_mb = 0,
        memory_load_pct = 0,
        own_lua_kb = 0,
        addon_total_kb = 0,
        timestamp = 0,
        ws_delta_mb = 0,      -- change since the previous sample (set in collect_sample)
        pf_delta_mb = 0,
    },

    -- UI state
    ui_selected_addon = nil,

    -- Session
    session_start = 0,

    -- Action flags (decouple UI from logic)
    paused = false,
    addon_source = 'none',      -- 'native' once the AddonManager binding has answered a poll
    last_zone_id = nil,         -- zone markers: the last zone id seen in d3d_present
    force_refresh = false,
    force_gc = false,
    force_trim = false,
    force_export = false,
    remove_addon = nil,
    clear_unloaded = false,
    last_export = nil,    -- { ok=bool, msg=string, t=os.time() } set by export path (B2)
    settings_save_requested = false,

    -- Populated by modules:
    -- state.history (analysis)
    -- state.addons, state.addon_order, state.addon_pool (analysis)
    -- state.alerts, state.alert_head, state.alert_count (analysis)
    -- state.sort_col, state.sort_asc (analysis)
    -- state.gc (monitor)
};

-------------------------------------------------------------------------------
-- Cached References
-------------------------------------------------------------------------------
local os_clock = os.clock;
local os_time = os.time;
local string_format = string.format;
local math_min = math.min;
local collectgarbage = collectgarbage;

-------------------------------------------------------------------------------
-- Helper: Print with addon header
-------------------------------------------------------------------------------
local function msg(text)
    print(chat.header('MemScope') .. chat.message(text));
end

local function msg_warning(text)
    print(chat.header('MemScope') .. chat.warning(text));
end

-------------------------------------------------------------------------------
-- Core: Collect a memory sample
-------------------------------------------------------------------------------
local function collect_sample()
    local c = state.current;
    c.timestamp = os_time();

    -- Sample-to-sample deltas (the UI reads these; a per-frame delta would be 0 on
    -- every frame but the first after a sample). First sample has no predecessor.
    local prev_ws, prev_pf = c.working_set_mb, c.pagefile_mb;
    local first = state.history.count == 0;

    monitor.query_process_memory();
    monitor.query_system_memory();
    monitor.query_lua_memory();
    monitor.monitor_gc();

    c.ws_delta_mb = first and 0 or (c.working_set_mb - prev_ws);
    c.pf_delta_mb = first and 0 or (c.pagefile_mb - prev_pf);

    analysis.push_history(
        state.current.working_set_mb,
        state.current.pagefile_mb,
        state.current.addon_total_kb
    );
end

-------------------------------------------------------------------------------
-- Core: Export session data to XML Spreadsheet (opens in Excel with tabs)
-- Produces a single .xml file with worksheets:
--   Session          - Session info + addon summary snapshot
--   Process Timeline - Full process memory timeline
--   Addons Timeline  - All addons wide-format (one column per addon)
--   <addon_name>     - Per-addon detailed timeline with deltas
-------------------------------------------------------------------------------

--- XML-escape special characters.
local function esc(s)
    return tostring(s):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;');
end

--- Sanitize a worksheet name (max 31 chars, no special chars).
local function sheet_name(s)
    return esc(tostring(s):sub(1, 31):gsub('[\\/%*%?:%[%]]', '_'));
end

--- XML cell helpers (inlined for speed).
local function cell(val, ctype, is_header)
    local style = is_header and ' ss:StyleID="hdr"' or '';
    local content = (ctype == 'String') and esc(val) or tostring(val);
    return string_format('<Cell%s><Data ss:Type="%s">%s</Data></Cell>', style, ctype, content);
end
local function hcell(val) return cell(val, 'String', true) end
local function scell(val) return cell(val, 'String', false) end
local function ncell(val) return cell(val, 'Number', false) end

local function export_session()
    if not state.paused then analysis.prune_history(os_time()); end
    -- Ensure exports/ directory exists
    local base_dir = string_format('%s\\config\\addons\\memscope\\exports', AshitaCore:GetInstallPath());
    ashita.fs.create_directory(base_dir);

    local timestamp = os.date('%Y%m%d_%H%M%S');
    local char_name = 'unknown';
    local player = GetPlayerEntity();
    if player and player.Name and #player.Name > 0 then
        char_name = player.Name;
    end
    local file_path = string_format('%s\\memscope_%s_%s.xls', base_dir, char_name, timestamp);

    local f, err = io.open(file_path, 'w');
    if not f then
        local m = string_format('Failed to create export: %s', tostring(err));
        msg_warning(m);
        state.last_export = { ok = false, msg = m, t = os_time() };
        return;
    end

    local c = state.current;
    local vlimit = math.max(c.total_virtual_mb, 1);
    local is_laa = vlimit > 2200;
    local uptime = os_clock() - (state.session_start or 0);
    local h = state.history;
    local HISTORY_SIZE = analysis.HISTORY_SIZE;
    local ADDON_HISTORY_SIZE = analysis.ADDON_HISTORY_SIZE;
    local sheet_count = 0;

    -- Lua io methods return nil, err on failure (they never raise), so every write goes
    -- through w(), which turns a failed write into an error the pcall below catches.
    local function w(s)
        local ok, e = f:write(s);
        if not ok then error(e or 'write failed', 0); end
    end

    -- Wrap all writes in pcall so f:close() is guaranteed even on error
    local write_ok, write_err = pcall(function()

    -- XML header (SpreadsheetML — opens natively in Excel/LibreOffice with tabs)
    w('<?xml version="1.0" encoding="UTF-8"?>\n');
    w('<?mso-application progid="Excel.Sheet"?>\n');
    w('<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"\n');
    w(' xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">\n');
    w('<Styles>\n');
    w(' <Style ss:ID="Default" ss:Name="Normal"/>\n');
    w(' <Style ss:ID="hdr"><Font ss:Bold="1"/></Style>\n');
    w('</Styles>\n');

    -- ================================================================
    -- Tab 1: Session — info + addon summary
    -- ================================================================
    w('<Worksheet ss:Name="Session"><Table>\n');

    w(string_format('<Row>%s%s</Row>\n', hcell('Property'), hcell('Value')));
    w(string_format('<Row>%s%s</Row>\n', scell('Date'), scell(os.date('%Y-%m-%d %H:%M:%S'))));
    w(string_format('<Row>%s%s</Row>\n', scell('Duration'), scell(string_format('%dm %ds', math.floor(uptime / 60), math.floor(uptime % 60)))));
    w(string_format('<Row>%s%s</Row>\n', scell('Paused'), scell(state.paused and 'Yes' or 'No')));
    w(string_format('<Row>%s%s</Row>\n', scell('Virtual Limit'), scell(string_format('%.0f MB (%s)', vlimit, is_laa and 'LAA' or '32-bit'))));
    w(string_format('<Row>%s%s</Row>\n', scell('System RAM'), scell(string_format('%.0f MB (%d%% used)', c.total_phys_mb, c.memory_load_pct))));
    w(string_format('<Row>%s%s</Row>\n', scell('Working Set'), scell(string_format('%.1f MB (Peak %.1f MB)', c.working_set_mb, c.peak_working_set_mb))));
    w(string_format('<Row>%s%s</Row>\n', scell('Committed'), scell(string_format('%.1f MB (Peak %.1f MB)', c.pagefile_mb, c.peak_pagefile_mb))));
    if state.gc then
        w(string_format('<Row>%s%s</Row>\n', scell('GC Collections'), scell(string_format('%d (freed %.2f KB last)', state.gc.collections, state.gc.freed_kb))));
    end
    w(string_format('<Row>%s%s</Row>\n', scell('Process Samples'), ncell(h.count)));
    w(string_format('<Row>%s%s</Row>\n', scell('Sample Interval'), scell(string_format('%d sec', state.settings.sample_interval))));
    w(string_format('<Row>%s%s</Row>\n', scell('Graph History Limit'), scell(string_format('%d min', analysis.history_minutes(state.settings.history_minutes)))));
    w(string_format('<Row>%s%s</Row>\n', scell('Addon Poll Interval'), scell(string_format('%d sec', state.settings.addon_poll_interval))));

    -- Addon summary table
    w('<Row/>\n');
    local loaded_count = 0;
    local unloaded_count = 0;
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data then
            if data.status == 'Unloaded' then unloaded_count = unloaded_count + 1;
            else loaded_count = loaded_count + 1; end
        end
    end
    w(string_format('<Row>%s%s</Row>\n', hcell('Addon Summary'), scell(string_format('%d loaded, %d unloaded', loaded_count, unloaded_count))));
    w(string_format('<Row>%s%s%s%s%s%s%s%s%s</Row>\n',
        hcell('Name'), hcell('Memory KB'), hcell('Memory MB'), hcell('Status'),
        hcell('Peak KB'), hcell('Min KB'), hcell('Delta KB/s'), hcell('Trend'), hcell('Samples')));
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data then
            local min_kb = data.min_kb == analysis.MIN_KB_SENTINEL and 0 or data.min_kb;
            w(string_format('<Row>%s%s%s%s%s%s%s%s%s</Row>\n',
                scell(data.name),
                ncell(string_format('%.2f', data.memory_kb)),
                ncell(string_format('%.4f', data.memory_kb / 1024)),
                scell(data.status),
                ncell(string_format('%.2f', data.peak_kb)),
                ncell(string_format('%.2f', min_kb)),
                ncell(string_format('%.4f', data.last_delta)),
                ncell(string_format('%.6f', data.trend_slope)),
                ncell(data.history_count)));
        end
    end
    w('</Table></Worksheet>\n');
    sheet_count = sheet_count + 1;

    -- ================================================================
    -- Tab 2: Process Timeline
    -- ================================================================
    if h.count > 0 then
        if (state.zone_mark_count or 0) > 0 then
            w('<Worksheet ss:Name="Zones"><Table>\n');
            w(string_format('<Row>%s</Row>\n', hcell('Epoch') .. hcell('Time') .. hcell('Zone ID') .. hcell('Zone')));
            for _, m in analysis.zone_marks() do
                w(string_format('<Row>%s</Row>\n', ncell(m.t) .. scell(os.date('%H:%M:%S', m.t)) .. ncell(m.zone_id) .. scell(m.name)));
            end
            w('</Table></Worksheet>\n');
        end
        w('<Worksheet ss:Name="Process Timeline"><Table>\n');
        w(string_format('<Row>%s%s%s%s%s%s%s</Row>\n',
            hcell('Sample'), hcell('Epoch'), hcell('Time'),
            hcell('Working Set MB'), hcell('Pagefile MB'),
            hcell('Addon Total KB'), hcell('Addon Total MB')));
        for i = 1, h.count do
            local idx = (h.head - h.count + i - 2) % HISTORY_SIZE + 1;
            local ts = h.timestamps[idx];
            local addon_kb = h.addon_total[idx];
            w(string_format('<Row>%s%s%s%s%s%s%s</Row>\n',
                ncell(i),
                ncell(ts),
                scell(os.date('%H:%M:%S', ts)),
                ncell(string_format('%.2f', h.working_set[idx])),
                ncell(string_format('%.2f', h.pagefile[idx])),
                ncell(string_format('%.2f', addon_kb)),
                ncell(string_format('%.4f', addon_kb / 1024))));
        end
        w('</Table></Worksheet>\n');
        sheet_count = sheet_count + 1;
    end

    -- ================================================================
    -- Tab 3: Addons Timeline — wide format, one column per addon
    -- ================================================================
    -- Rows are keyed by sample TIMESTAMP (the union across addons), so an addon that
    -- unloaded early sits in the early rows and one that loaded late in the late rows.
    -- Aligning by history length cannot tell those two cases apart.
    local active_addons = {};
    local by_ts = {};          -- name -> { [seq] = kb }   (keyed by poll sequence, F11)
    local ts_set = {};
    local ts_list = {};        -- poll sequence numbers, sorted
    local ts_of = {};          -- seq -> os.time() for the Epoch/Time columns
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data and data.history_count > 0 then
            active_addons[#active_addons + 1] = name;
            local map = {};
            for i = 1, data.history_count do
                local idx = (data.history_head - data.history_count + i - 2) % ADDON_HISTORY_SIZE + 1;
                local ts = data.history_seq[idx];
                map[ts] = data.history[idx];
                if not ts_set[ts] then
                    ts_set[ts] = true;
                    ts_list[#ts_list + 1] = ts;
                    ts_of[ts] = data.history_ts[idx];
                end
            end
            by_ts[name] = map;
        end
    end
    table.sort(ts_list);

    if #ts_list > 0 and #active_addons > 0 then
        w('<Worksheet ss:Name="Addons Timeline"><Table>\n');
        -- Header: Sample, Epoch, Time + one column per addon
        local row_str = hcell('Sample') .. hcell('Epoch') .. hcell('Time');
        for _, name in ipairs(active_addons) do
            row_str = row_str .. hcell(state.addons[name].name .. ' KB');
        end
        w(string_format('<Row>%s</Row>\n', row_str));

        -- Data rows (oldest to newest); blank where an addon has no sample at that time
        for row = 1, #ts_list do
            local ts = ts_list[row];
            row_str = ncell(row) .. ncell(ts_of[ts]) .. scell(os.date('%H:%M:%S', ts_of[ts]));
            for _, name in ipairs(active_addons) do
                local kb = by_ts[name][ts];
                if kb == nil then
                    row_str = row_str .. '<Cell><Data ss:Type="String"></Data></Cell>';
                else
                    row_str = row_str .. ncell(string_format('%.2f', kb));
                end
            end
            w(string_format('<Row>%s</Row>\n', row_str));
        end
        w('</Table></Worksheet>\n');
        sheet_count = sheet_count + 1;
    end

    -- ================================================================
    -- Tab 4+: Per-addon detailed timeline (one tab per addon)
    -- ================================================================
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data and data.history_count > 0 then
            w(string_format('<Worksheet ss:Name="%s"><Table>\n', sheet_name(data.name)));

            -- Metadata header
            w(string_format('<Row>%s%s</Row>\n', hcell('Property'), hcell('Value')));
            w(string_format('<Row>%s%s</Row>\n', scell('Addon'), scell(data.name)));
            w(string_format('<Row>%s%s</Row>\n', scell('Status'), scell(data.status)));
            w(string_format('<Row>%s%s</Row>\n', scell('Current KB'), ncell(string_format('%.2f', data.memory_kb))));
            w(string_format('<Row>%s%s</Row>\n', scell('Peak KB'), ncell(string_format('%.2f', data.peak_kb))));
            local min_kb = data.min_kb == analysis.MIN_KB_SENTINEL and 0 or data.min_kb;
            w(string_format('<Row>%s%s</Row>\n', scell('Min KB'), ncell(string_format('%.2f', min_kb))));
            w(string_format('<Row>%s%s</Row>\n', scell('Trend'), ncell(string_format('%.6f', data.trend_slope))));
            w(string_format('<Row>%s%s</Row>\n', scell('Samples'), ncell(data.history_count)));
            w('<Row/>\n');

            -- Timeline with deltas
            w(string_format('<Row>%s%s%s%s%s</Row>\n',
                hcell('Sample'), hcell('Memory KB'), hcell('Memory MB'),
                hcell('Delta KB'), hcell('Change From Start KB')));
            local first_val = nil;
            local prev_val = nil;
            for i = 1, data.history_count do
                local idx = (data.history_head - data.history_count + i - 2) % ADDON_HISTORY_SIZE + 1;
                local val = data.history[idx];
                if not first_val then first_val = val; end
                local delta = prev_val and (val - prev_val) or 0;
                local from_start = val - first_val;
                w(string_format('<Row>%s%s%s%s%s</Row>\n',
                    ncell(i),
                    ncell(string_format('%.2f', val)),
                    ncell(string_format('%.4f', val / 1024)),
                    ncell(string_format('%.2f', delta)),
                    ncell(string_format('%.2f', from_start))));
                prev_val = val;
            end

            w('</Table></Worksheet>\n');
            sheet_count = sheet_count + 1;
        end
    end

    -- Close workbook
    w('</Workbook>\n');

    end); -- pcall

    -- A buffered handle surfaces disk-full at flush/close, so close is checked too.
    local close_ok, close_err = f:close();
    if write_ok and not close_ok then
        write_ok = false;
        write_err = close_err or 'close failed';
    end

    if not write_ok then
        os.remove(file_path);   -- do not leave a truncated workbook behind
        local m = string_format('Export write failed: %s', tostring(write_err));
        msg_warning(m);
        state.last_export = { ok = false, msg = m, t = os_time() };
        return;
    end

    local m = string_format('Exported %d tabs to exports\\memscope_%s_%s.xls',
        sheet_count, char_name, timestamp);
    msg(m);
    state.last_export = { ok = true, msg = m, t = os_time() };
end

-------------------------------------------------------------------------------
-- Core: Poll addons through the AddonManager binding (synchronous)
-------------------------------------------------------------------------------
local function on_addon_inventory(results, count, complete)
    -- An empty inventory cannot be real (MemScope itself is always listed): treat it as a
    -- failed read and leave the previous state intact rather than unloading everything.
    if count == 0 then return; end
    analysis.begin_poll();
    -- Collect current addon names for marking absent ones as Unloaded
    local current_names = {};
    for i = 1, count do
        local entry = results[i];
        if entry.memory_kb ~= nil then
            analysis.update_addon(entry.name, entry.memory_kb, entry.status);
        elseif state.addons[entry.name] then
            -- Preserve the last real sample, extrema and trend until the binding recovers.
            state.addons[entry.name].status = 'Read error';
        end
        current_names[i] = entry.name;
    end
    if complete then
        -- Footer-terminated, not truncated: absence means unloaded (history preserved)
        analysis.prune_and_sort(current_names);
    else
        -- Timed out or overflowed: the lines that arrived are real, absence means nothing
        analysis.sort_addons(state.sort_col, state.sort_asc);
    end
    state.current.addon_total_kb = analysis.get_addon_total_kb();
    state.addon_source = 'native';
end

local binding_warned = false;
local function start_addon_poll()
    -- The AddonManager binding is the only per-addon source: synchronous, byte resolution,
    -- no chat traffic. Nothing else is tried when it is absent.
    if monitor.read_addon_manager(on_addon_inventory) then return; end
    state.addon_source = 'none';
    if not binding_warned then
        binding_warned = true;
        msg_warning('AddonManager binding not available in this Ashita build: no per-addon memory. Process memory is unaffected.');
    end
end

-------------------------------------------------------------------------------
-- Event: Load
-------------------------------------------------------------------------------
ashita.events.register('load', 'memscope_load', function()
    state.settings = settings.load(default_settings);
    state.settings.pinned_addons = analysis.copy_pins(state.settings.pinned_addons);
    state.settings.history_minutes = analysis.history_minutes(state.settings.history_minutes);
    -- Settings removed with the /addon list capture (v1.0.3 -> v1.2.0): drop them from files saved by
    -- the previous build so the settings page and the file agree.
    if state.settings.chat_fallback ~= nil then
        state.settings.chat_fallback = nil;
        state.settings_save_requested = true;
    end
    state.chat = chat;

    state.session_start = os_clock();

    analysis.init(state);
    monitor.init(state);
    ui.init(state, analysis, default_settings);

    -- Apply show_on_load setting
    if (not state.settings.show_on_load) then
        ui.hide();
    end

    collect_sample();

    -- Schedule the first addon poll ~3 seconds from now via d3d_present timing.
    -- All polls use the same d3d_present path — no ashita.tasks.once needed.
    -- The 3-second delay lets the addon list settle after a reload.
    local now = os_clock();
    state.last_sample_time = now;
    state.last_addon_poll_time = now - state.settings.addon_poll_interval + 3;

    msg('v' .. addon.version .. ' loaded. Use /memscope to toggle window.');
end);

-------------------------------------------------------------------------------
-- Event: Unload
-------------------------------------------------------------------------------
ashita.events.register('unload', 'memscope_unload', function()
    pcall(settings.save);
    msg('Unloaded.');
end);

ashita.events.register('command', 'memscope_command', function(e)
    local args = e.command:args();
    if #args == 0 or not args[1]:any('/memscope') then return; end

    e.blocked = true;

    local cmd = (#args >= 2) and args[2]:lower() or 'toggle';

    if cmd == 'toggle' then
        ui.toggle();

    elseif cmd == 'show' then
        ui.show();

    elseif cmd == 'hide' then
        ui.hide();

    elseif cmd == 'snapshot' then
        collect_sample();
        start_addon_poll();
        msg('Snapshot taken.');

    elseif cmd == 'report' then
        msg('Memory Report:');
        msg(string_format('  Process: %.1f MB (peak %.1f MB)',
            state.current.working_set_mb, state.current.peak_working_set_mb));
        msg(string_format('  MemScope Lua: %.2f KB', state.current.own_lua_kb));
        msg(string_format('  All Addons: %.2f KB', state.current.addon_total_kb));
        msg(string_format('  Tracked Addons: %d', #state.addon_order));
        for i = 1, math_min(5, #state.addon_order) do
            local name = state.addon_order[i];
            local data = state.addons[name];
            if data then
                msg(string_format('    %s: %.2f KB (%s)', data.name, data.memory_kb, data.status));
            end
        end

    elseif cmd == 'gc' then
        local before = collectgarbage('count');
        collectgarbage('collect');
        local after = collectgarbage('count');
        msg(string_format('GC freed %.2f KB', before - after));

    elseif cmd == 'trim' then
        state.force_trim = true;

    elseif cmd == 'alerts' then
        local subcmd = (#args >= 3) and args[3]:lower() or 'status';
        if subcmd == 'on' then
            state.settings.alerts_enabled = true;
            state.settings_save_requested = true;
            msg('Alerts enabled.');
        elseif subcmd == 'off' then
            state.settings.alerts_enabled = false;
            state.settings_save_requested = true;
            msg('Alerts disabled.');
        else
            msg(string_format('Alerts: %s', state.settings.alerts_enabled and 'enabled' or 'disabled'));
        end

    elseif cmd == 'export' then
        local ok, err = pcall(export_session);
        if not ok then
            local m = string_format('Export failed: %s', tostring(err));
            msg_warning(m);
            state.last_export = { ok = false, msg = m, t = os_time() };
        end

    elseif cmd == 'settings' then
        ui.open_settings();

    elseif cmd == 'zones' then
        local subcmd = (#args >= 3) and args[3]:lower() or 'status';
        if subcmd == 'on' then
            state.settings.zone_markers = true; state.settings_save_requested = true; msg('Zone markers on.');
        elseif subcmd == 'off' then
            state.settings.zone_markers = false; state.settings_save_requested = true; msg('Zone markers off.');
        else
            msg(string_format('Zone markers: %s (%d recorded this session)', state.settings.zone_markers and 'on' or 'off', state.zone_mark_count or 0));
        end

    elseif cmd == 'pause' then
        state.paused = not state.paused;
        msg(state.paused and 'Paused. Data frozen for review.' or 'Resumed.');

    elseif cmd == 'compact' then
        ui.toggle_compact();

    elseif cmd == 'resetui' or cmd == 'reset' then
        ui.reset_ui();
        msg('UI reset to defaults.');

    elseif cmd == 'clear' then
        -- Command twin of the Clear Unloaded button (drained in d3d_present)
        state.clear_unloaded = true;
        msg('Clearing unloaded addons.');

    elseif cmd == 'remove' then
        -- Command twin of the right-click "Remove from tracking" (drained in d3d_present)
        local wanted = args[3];
        local found = nil;
        if wanted then
            if state.addons[wanted] then
                found = wanted;
            else
                local lower = wanted:lower();
                for _, n in ipairs(state.addon_order) do
                    if n:lower() == lower then found = n; break; end
                end
            end
        end
        if not wanted then
            msg_warning('Usage: /memscope remove <name>');
        elseif not found then
            msg_warning(string_format('Not tracked: %s', wanted));
        else
            state.remove_addon = found;
            msg(string_format('Removed %s from tracking.', found));
        end

    elseif cmd == 'help' then
        msg('Available commands:');
        local cmds = {
            { '/memscope',              'Toggle the MemScope window.' },
            { '/memscope show / hide',  'Show or hide the window.' },
            { '/memscope compact',      'Toggle compact overlay mode.' },
            { '/memscope settings',     'Open the settings window.' },
            { '/memscope resetui / reset', 'Reset window size and position.' },
            { '/memscope pause',        'Pause/resume data collection.' },
            { '/memscope snapshot',     'Take manual memory snapshot.' },
            { '/memscope report',       'Print memory report to chat.' },
            { '/memscope export',       'Export session data to Excel (.xls).' },
            { '/memscope gc',           'Force garbage collection (this addon only).' },
            { '/memscope trim',         'Trim working set (actual vs inflated memory).' },
            { '/memscope alerts [on/off]', 'Toggle growth alerts.' },
            { '/memscope zones [on/off]', 'Toggle zone-change markers on the charts.' },
            { '/memscope clear',        'Remove all unloaded addons from tracking.' },
            { '/memscope remove <name>', 'Remove one addon from tracking.' },
        };
        for _, v in ipairs(cmds) do
            print(chat.header('MemScope') .. chat.success(v[1]) .. chat.message(' - ' .. v[2]));
        end

    else
        msg_warning('Unknown command. Use /memscope help');
    end
end);

-------------------------------------------------------------------------------
-- Event: d3d_present (every frame)
-------------------------------------------------------------------------------
ashita.events.register('d3d_present', 'memscope_render', function()
    local now = os_clock();


    -- Don't collect data or render until character is in a zone
    local player = GetPlayerEntity();
    if (player == nil) then return; end
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return; end
    local party = mem:GetParty();
    if (party == nil) then return; end
    local zone_id = party:GetMemberZone(0) or 0;
    if zone_id == 0 then return; end
    -- Zone markers: record a change after the first observed zone (a mid-session load is not a change)
    if zone_id ~= state.last_zone_id then
        if state.last_zone_id ~= nil then
            local zname = nil;
            local rm = AshitaCore.GetResourceManager and AshitaCore:GetResourceManager();
            if rm then zname = rm:GetString('zones.names', zone_id); end
            analysis.push_zone_mark(os_time(), zone_id, zname or string_format('Zone %d', zone_id));
        end
        state.last_zone_id = zone_id;
    end
    if (state.settings == nil) then return; end

    -- Keep all graphs/exports inside the rolling window, even when hidden or
    -- between slow polls. Pausing freezes history until resume or a manual sample.
    if not state.paused then analysis.prune_history(os_time()); end

    -- Handle action flags from UI
    if state.force_refresh then
        state.force_refresh = false;
        collect_sample();
        start_addon_poll();
    end

    if state.force_gc then
        state.force_gc = false;
        local before = collectgarbage('count');
        collectgarbage('collect');
        local after = collectgarbage('count');
        msg(string_format('GC freed %.2f KB', before - after));
        collect_sample();
    end

    if state.force_trim then
        state.force_trim = false;
        local before_mb, after_mb = monitor.trim_working_set();
        msg(string_format('Working Set trimmed: %.0f MB -> %.0f MB (freed %.0f MB)',
            before_mb, after_mb, before_mb - after_mb));
        collect_sample();
    end

    if state.settings_save_requested then
        state.settings_save_requested = false;
        pcall(settings.save);
    end

    if state.force_export then
        state.force_export = false;
        local ok, err = pcall(export_session);
        if not ok then
            local m = string_format('Export failed: %s', tostring(err));
            msg_warning(m);
            state.last_export = { ok = false, msg = m, t = os_time() };
        end
    end

    if state.remove_addon then
        local name = state.remove_addon;
        state.remove_addon = nil;
        if state.ui_selected_addon == name then
            state.ui_selected_addon = nil;
        end
        analysis.remove_addon(name);
    end

    if state.clear_unloaded then
        state.clear_unloaded = false;
        -- Drop selection if the selected addon is one being cleared
        if state.ui_selected_addon then
            local sel = state.addons[state.ui_selected_addon];
            if sel and sel.status == 'Unloaded' then
                state.ui_selected_addon = nil;
            end
        end
        analysis.clear_unloaded();
    end

    -- Periodic sample collection (skip when paused)
    if not state.paused and now - state.last_sample_time >= state.settings.sample_interval then
        state.last_sample_time = now;
        collect_sample();
    end

    -- Periodic addon polling (skip when paused)
    if not state.paused and now - state.last_addon_poll_time >= state.settings.addon_poll_interval then
        state.last_addon_poll_time = now;
        start_addon_poll();
    end

    -- Render UI
    ui.render();
end);

-------------------------------------------------------------------------------
-- Event: Settings changed externally
-------------------------------------------------------------------------------
settings.register('settings', 'memscope_settings_update', function(s)
    if s then
        state.settings = s;
        state.settings.pinned_addons = analysis.copy_pins(state.settings.pinned_addons);
        state.settings.history_minutes = analysis.history_minutes(state.settings.history_minutes);
        analysis.prune_history(os_time(), true);
        if state.addon_order then analysis.sort_addons(state.sort_col, state.sort_asc); end
    end
end);

-- Headless test hook (tests/stub.lua sets the flag before loading; never set in the client).
if _G.MEMSCOPE_TEST_HOOK then
    _G.memscope_test = {
        state = state,
        export_session = export_session,
        collect_sample = collect_sample,
        start_addon_poll = start_addon_poll,
    };
end

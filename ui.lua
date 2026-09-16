--[[
    MemScope v1.2.0 - UI Module
    ImGui dashboard rendering with correct widget patterns.

    Data accuracy notes (per atom0s, Feb 2026):
    - per-addon memory (AddonManager binding) = Lua-tracked only (excludes FFI, ImGui, C++ internals)
    - Working set on Win10/11 is inflated (OS delays page release)
    - GC monitoring only sees this addon's own Lua state
    - Growth alerts are informational, not confirmed leaks
]]--

local imgui = require 'imgui';

local ui = {};

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local KB_TO_MB = 1 / 1024;
local SETTINGS_ITEM_WIDTH = 160;   -- fixed width for settings sliders (A1)
local LABEL_COL_X = 150;           -- label/value column alignment (C5): the floor; the real column is
                                   -- measured from the widest label each frame so UI scale never overlaps it
local WIDEST_LABEL = 'MemScope Lua State:';
local label_col_x = LABEL_COL_X;
local EXPORT_FEEDBACK_SECS = 5;    -- how long export result stays on screen (B2)

-------------------------------------------------------------------------------
-- Cached References
-------------------------------------------------------------------------------
local math_max = math.max;
local math_min = math.min;
local string_format = string.format;

-------------------------------------------------------------------------------
-- Colors (matching PlayerNotes convention)
-------------------------------------------------------------------------------
local colors = {
    header     = { 1.0, 0.65, 0.26, 1.0 },  -- orange section titles
    muted      = { 0.6, 0.6, 0.6, 1.0 },
    delta_up   = { 1, 0.5, 0.5, 1 },         -- memory growing (red-ish)
    delta_down = { 0.5, 1, 0.5, 1 },         -- memory shrinking (green-ish)
    delta_flat = { 0.7, 0.7, 0.7, 1 },       -- no change (gray)
};

-------------------------------------------------------------------------------
-- Module State
-------------------------------------------------------------------------------
local state = nil;
local analysis = nil;
local defaults = nil;

-- UI-local state (table references for ImGui widgets)
local is_open = { true };
local show_settings = { false };
local compact_mode = false;
local restore_full_size = false;
local reset_pending = false;
local saved_full_size = nil;       -- { w, h } captured before entering compact
local saved_compact_size = nil;    -- { w, h } captured before entering full
local restore_compact_size = false;

-- Pre-allocated chart buffers (filled in-place each frame, no allocation)
local CHART_BUFFER_SIZE = 720;    -- maximum display points resampled across the full time span
local ws_chart = {};
local addon_chart = {};
local addon_detail_chart = {};
for i = 1, CHART_BUFFER_SIZE do
    ws_chart[i] = 0;
    addon_chart[i] = 0;
    addon_detail_chart[i] = 0;
end

-- Pre-allocated ImGui size/position tables (updated in-place, no per-frame allocation)
local plot_padding     = { 0, 0 };
local size_bar         = { -1, 0 };      -- progress bar: full width, auto height
local size_content     = { 0, -26 };     -- scrollable content: full width, reserve footer
local size_chart       = { 0, 0 };       -- chart: { content_width, chart_height }
local size_table       = { 0, 0 };       -- addon table: { 0, table_height }
local size_detail      = { 0, 60 };      -- addon detail chart: { content_width, 60 }
local size_default     = { 754, 520 };   -- default full window size
local pos_default      = { 100, 100 };   -- default full window position
local size_compact_def = { 324, 300 };   -- default compact window size
local size_restore     = { 0, 0 };       -- temp: size restore on mode switch

-- Pre-allocated compact mode style color tables (updated in-place via scaled_color)
local cc_border        = { 0, 0, 0, 0 };
local cc_border_shadow = { 0, 0, 0, 0 };
local cc_grip          = { 0, 0, 0, 0 };
local cc_grip_hover    = { 0, 0, 0, 0 };
local cc_grip_active   = { 0, 0, 0, 0 };

-- Pre-allocated row/button color tables (addon table + toolbar)
local color_unloaded   = { 0.6, 0.6, 0.6, 0.9 };   -- C6: brightened for legibility
local color_alert      = { 1.0, 0.6, 0.2, 1.0 };
local color_self       = { 0.5, 0.8, 0.5, 1.0 };
local color_reset_btn  = { 0.3, 0.3, 0.3, 1.0 };
local color_red        = { 0.85, 0.2, 0.2, 1.0 };  -- C4: high-usage / failure
local color_bar_ok     = { 0.4, 0.5, 0.85, 1.0 };  -- C4: neutral progress bar fill

-- Compact overlay: a restrained dark palette with warm headings and a cool memory trace.
local compact_bg      = { 0.055, 0.070, 0.095, 1 };
local compact_panel   = { 0.085, 0.105, 0.140, 1 };
local compact_hover   = { 0.16, 0.20, 0.27, 1 };
local compact_text    = { 0.90, 0.93, 0.97, 1 };
local compact_muted   = { 0.53, 0.61, 0.71, 1 };
local compact_accent  = { 0.37, 0.80, 0.88, 1 };
local compact_live    = { 0.49, 0.79, 0.63, 1 };
local compact_padding = { 12, 10 };
local compact_spacing = { 8, 5 };
local compact_min     = { 300, 0 };
local compact_content_height = nil;
local compact_max     = { 9999, 9999 };
local compact_graph   = { -1, 32 };
local compact_top     = {};
local theme_selection = { 0 };
local button_normal   = { 0.15, 0.29, 0.38, 1 };
local button_hover    = { 0.22, 0.43, 0.54, 1 };
local button_active   = { 0.12, 0.36, 0.47, 1 };
local button_paused   = { 0.45, 0.28, 0.10, 1 };
local theme_border    = { 0.27, 0.38, 0.47, 0.8 };

-- Scope the same palette to every MemScope window; never modify the host's theme.
local theme_colors = {
    { ImGuiCol_Border, theme_border },
    { ImGuiCol_WindowBg, compact_bg },
    { ImGuiCol_ChildBg, compact_bg },
    { ImGuiCol_PopupBg, compact_panel },
    { ImGuiCol_TitleBg, compact_panel },
    { ImGuiCol_TitleBgActive, compact_panel },
    { ImGuiCol_TitleBgCollapsed, compact_panel },
    { ImGuiCol_Text, compact_text },
    { ImGuiCol_TextDisabled, compact_muted },
    { ImGuiCol_FrameBg, compact_panel },
    { ImGuiCol_FrameBgHovered, compact_hover },
    { ImGuiCol_FrameBgActive, compact_hover },
    { ImGuiCol_Button, button_normal },
    { ImGuiCol_ButtonHovered, button_hover },
    { ImGuiCol_ButtonActive, button_active },
    { ImGuiCol_Header, compact_panel },
    { ImGuiCol_HeaderHovered, compact_hover },
    { ImGuiCol_HeaderActive, compact_hover },
    { ImGuiCol_TableHeaderBg, compact_panel },
    { ImGuiCol_Separator, compact_hover },
    { ImGuiCol_CheckMark, compact_accent },
    { ImGuiCol_SliderGrab, compact_accent },
    { ImGuiCol_SliderGrabActive, colors.header },
    { ImGuiCol_PlotLines, compact_accent },
    { ImGuiCol_PlotLinesHovered, colors.header },
};
local function push_theme()
    if state.settings.theme == 'default' then return false; end
    for _, entry in ipairs(theme_colors) do imgui.PushStyleColor(entry[1], entry[2]); end
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, compact_padding);
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, compact_spacing);
    imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1);
    return true;
end
local function pop_theme(applied)
    -- The picker can change settings during this window; pop what was pushed at entry.
    if not applied then return; end
    imgui.PopStyleVar(5);
    imgui.PopStyleColor(#theme_colors);
end

-- Module-level filter buffer (D1) and confirm flag (E1) - allocated once
local addon_filter     = { '' };
local confirm_restore  = false;

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- Show a tooltip with the given text when the previous item is hovered.
--- SetTooltip printf-processes its text, so every literal '%' is escaped here; callers pass
--- plain text and never write '%%' themselves.
local function tooltip(text) if imgui.IsItemHovered() then imgui.SetTooltip((text:gsub('%%', '%%%%'))) end end

--- Show a (?) help marker with tooltip on hover.
local function help_marker(text)
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    tooltip(text);
end

--- Format memory value: show MB if >= 1024 KB, otherwise KB.
local function fmt_mem(kb)
    if kb >= 1024 then
        return string_format('%.2f MB', kb * KB_TO_MB);
    end
    return string_format('%.2f KB', kb);
end

--- Draw an aligned "label  value" pair; tooltip (if given) attaches to the label (C5).
local function label_value(label, value, tip)
    imgui.Text(label);
    if tip then tooltip(tip); end
    imgui.SameLine(label_col_x);
    imgui.Text(value);
end

--- Measure the label column once per frame (font size follows the UI scale).
local function measure_layout()
    local w = imgui.CalcTextSize(WIDEST_LABEL);
    if type(w) == 'number' then label_col_x = math_max(LABEL_COL_X, w + 16); end
end

--- Right-justify the next text within a fixed-width column (C3, constant math, no alloc).
local function right_align(text, col_width)
    local tw = imgui.CalcTextSize(text);
    local x = imgui.GetCursorPosX();
    local off = col_width - tw - 8;  -- ~8px cell padding
    if off > 0 then imgui.SetCursorPosX(x + off); end
end

--- Push a severity color for a process-memory ProgressBar fill (C4). Caller pops 1.
local function push_bar_color(pct)
    local col;
    if pct > 0.85 then
        col = color_red;
    elseif pct >= 0.6 then
        col = color_alert;
    else
        col = color_bar_ok;
    end
    imgui.PushStyleColor(ImGuiCol_PlotHistogram, col);
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------
function ui.init(shared_state, analysis_mod, default_settings)
    state = shared_state;
    analysis = analysis_mod;
    defaults = default_settings;
end

-------------------------------------------------------------------------------
-- Process Memory Section
-------------------------------------------------------------------------------
local function render_process_memory()
    if not state.settings.show_process_memory then return; end

    local c = state.current;
    local vlimit = math_max(c.total_virtual_mb, 1);
    local is_laa = vlimit > 2200;  -- LAA = ~4096 MB, non-LAA = ~2048 MB
    local laa_label = is_laa and 'LAA' or '32-bit';

    imgui.TextColored(colors.header, string_format('Process Memory (%s, %.0f MB limit)', laa_label, vlimit));
    help_marker(
        'Memory used by the entire FFXI process.\n' ..
        'FFXI is 32-bit: 2 GB limit (4 GB with LAA patch).\n' ..
        'Bars show usage vs the process virtual address limit.\n\n' ..
        'NOTE: Windows 10/11 inflates Working Set values.\n' ..
        'The OS holds onto memory pages aggressively and\n' ..
        'delays releasing them. Actual usage may be much\n' ..
        'lower than reported. Use the Trim button in the\n' ..
        'toolbar to force a working set trim for accurate readings.'
    );
    imgui.Separator();

    -- Deltas are sample-to-sample, computed in collect_sample (not per frame)
    local ws_delta = c.ws_delta_mb or 0;
    local pf_delta = c.pf_delta_mb or 0;

    -- Working Set bar: FFXI usage / process virtual limit
    local ws_pct = c.working_set_mb / vlimit;
    local ws_label = string_format('%.0f / %.0f MB (%.0f%%)', c.working_set_mb, vlimit, ws_pct * 100);
    imgui.Text('Working Set:');
    tooltip(
        'Physical RAM pages mapped into FFXI\'s address space.\n' ..
        'Win10/11 inflates this — OS delays page release.\n' ..
        'Use the Trim button to see actual values.'
    );
    imgui.SameLine();
    push_bar_color(ws_pct);
    imgui.ProgressBar(ws_pct, size_bar, ws_label);
    imgui.PopStyleColor();
    tooltip(string_format(
        'Current: %.1f MB\n' ..
            'Peak: %.1f MB\n' ..
            'Delta: %+.1f MB\n' ..
            'Process Limit: %.0f MB (%s)\n' ..
            'Free Address Space: %.0f MB\n' ..
            '---\n' ..
            'System RAM: %.0f MB (%.0f MB free, %d%% used)',
            c.working_set_mb,
            c.peak_working_set_mb,
            ws_delta,
            vlimit, laa_label,
            c.avail_virtual_mb,
            c.total_phys_mb,
            c.avail_phys_mb,
            c.memory_load_pct
        ));

    -- Page File bar: FFXI committed memory / process virtual limit
    local pf_pct = c.pagefile_mb / vlimit;
    local pf_label = string_format('%.0f / %.0f MB (%.0f%%)', c.pagefile_mb, vlimit, pf_pct * 100);
    imgui.Text('Committed:  ');
    tooltip('Virtual memory committed (RAM + swap reserved for FFXI).');
    imgui.SameLine();
    push_bar_color(pf_pct);
    imgui.ProgressBar(pf_pct, size_bar, pf_label);
    imgui.PopStyleColor();
    tooltip(string_format(
        'Current: %.1f MB\n' ..
        'Peak: %.1f MB\n' ..
        'Delta: %+.1f MB\n' ..
        'Process Limit: %.0f MB (%s)\n' ..
        '---\n' ..
        'System Page File: %.0f MB (%.0f MB free)',
        c.pagefile_mb,
        c.peak_pagefile_mb,
        pf_delta,
        vlimit, laa_label,
        c.total_pagefile_mb,
        c.avail_pagefile_mb
    ));

    imgui.Spacing();
end

-------------------------------------------------------------------------------
-- Lua Memory Section
-------------------------------------------------------------------------------
local function render_lua_memory()
    imgui.TextColored(colors.header, 'Lua Memory');
    help_marker(
        'Memory tracked by Lua addon scripts.\n' ..
        'Each addon runs in its own isolated Lua state.\n' ..
        '"All Addons Total" is the sum over the AddonManager binding.\n\n' ..
        'IMPORTANT: These values only reflect Lua-tracked\n' ..
        'memory. FFI allocations, ImGui resources, and\n' ..
        'C++ internals are NOT included. Actual addon\n' ..
        'memory usage may be higher than shown.'
    );
    imgui.Separator();

    label_value('MemScope Lua State:', fmt_mem(state.current.own_lua_kb or 0),
        'Memory used by this addon\'s own Lua VM.\n' ..
        'Only includes Lua-managed objects (tables, strings,\n' ..
        'functions). Does not include FFI allocations.'
    );

    label_value('All Addons Total:', fmt_mem(state.current.addon_total_kb or 0),
        'Combined Lua-tracked memory of all loaded addons\n' ..
        '(AddonManager binding). This understates actual usage -\n' ..
        'FFI, ImGui, and manual C allocations are excluded.'
    );

    if state.settings.auto_gc_monitoring and state.gc then
        label_value('GC Collections:',
            string_format('%d (freed %s last)', state.gc.collections, fmt_mem(state.gc.freed_kb)),
            'Lua garbage collector activity for MemScope only.\n' ..
            'Each addon has its own isolated GC — this does\n' ..
            'NOT show GC activity of other addons.\n' ..
            'Collections: times GC has reclaimed memory.\n' ..
            'Freed: amount reclaimed in the last cycle.'
        );
    end

    imgui.Spacing();
end

-------------------------------------------------------------------------------
-- Addon Table
-------------------------------------------------------------------------------
local function render_addon_table()
    if not state.settings.show_addon_breakdown then return; end

    imgui.TextColored(colors.header, string_format('Addon Memory (%d tracked)', #state.addon_order));
    help_marker(
        'Click a row for details. Right-click any row for actions.\n\n' ..
        'Values are Lua-tracked memory only (AddonManager binding).\n' ..
        'FFI, ImGui, and C++ allocations are not reflected.\n' ..
        'Trend/delta may show normal LuaJIT jitting behavior.'
    );
    imgui.SameLine();
    if imgui.SmallButton('Clear Unloaded') then       -- D5
        state.clear_unloaded = true;
    end
    tooltip('Remove all unloaded addons from tracking.');
    imgui.Separator();

    -- Filter box (D1): module-level buffer, no per-frame allocation
    imgui.Text('Filter:');
    imgui.SameLine();
    imgui.SetNextItemWidth(SETTINGS_ITEM_WIDTH);
    imgui.InputText('##addonfilter', addon_filter, 256);
    imgui.SameLine();
    if imgui.SmallButton('x##clearfilter') then
        addon_filter[1] = '';
    end
    tooltip('Clear the filter.');
    local filter_lower = (addon_filter[1] ~= '') and addon_filter[1]:lower() or nil;

    -- Use the full content width, not the narrow star cell, for empty-state feedback.
    if #state.addon_order == 0 then
        if state.addon_source ~= 'native' then
            imgui.PushStyleColor(ImGuiCol_Text, color_alert);
            imgui.TextWrapped('AddonManager binding unavailable - no per-addon data');
            imgui.PopStyleColor();
            tooltip('This Ashita build does not expose the AddonManager binding to addons,\nso per-addon memory cannot be read. Process memory still works.');
        else
            imgui.TextWrapped('No addons polled yet - click Refresh.');
        end
        imgui.Spacing();
        return;
    end

    local table_flags = ImGuiTableFlags_Resizable
        + ImGuiTableFlags_RowBg
        + ImGuiTableFlags_BordersInnerV
        + ImGuiTableFlags_SizingFixedFit
        + ImGuiTableFlags_Sortable
        + ImGuiTableFlags_ScrollY;

    -- Cap table height to ~10 rows; scrollbar appears if more addons are tracked
    local row_height = imgui.GetTextLineHeightWithSpacing();
    local max_rows = 10;
    local header_height = row_height + 4;
    local table_height = header_height + (row_height * math.min(#state.addon_order, max_rows));

    size_table[2] = table_height;
    local pins_changed = false;
    -- New identity: the old five-column layout stored Name at index 0 (now the star).
    -- Defaults match the adjusted six-column layout saved on September 14.
    if not imgui.BeginTable('addon_table_starred_v1', 6, table_flags, size_table) then return; end

    imgui.TableSetupScrollFreeze(0, 1);
    imgui.TableSetupColumn('*', ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_NoSort + ImGuiTableColumnFlags_NoResize, 31, 5);
    imgui.TableSetupColumn('Name',   ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 0);
    imgui.TableSetupColumn('Memory', ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_DefaultSort + ImGuiTableColumnFlags_PreferSortDescending, 144, 1);
    imgui.TableSetupColumn('Status', ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortAscending, 87, 2);
    imgui.TableSetupColumn('Delta KB', ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 60, 3);
    imgui.TableSetupColumn('Trend',  ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 50, 4);
    imgui.TableHeadersRow();

    -- Handle sort spec changes (SpecsDirty may not be writable from Lua bindings)
    local sort_specs = imgui.TableGetSortSpecs();
    if sort_specs and sort_specs.SpecsDirty then
        local spec = sort_specs.Specs;
        if spec then
            state.sort_col = spec.ColumnUserID;
            state.sort_asc = spec.SortDirection == ImGuiSortDirection_Ascending;
            analysis.sort_addons(state.sort_col, state.sort_asc);
        end
        -- Note: SpecsDirty assignment may be no-op if read-only in Ashita's binding
        sort_specs.SpecsDirty = false;
    end

    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        -- D1: skip rows that do not match the (case-insensitive) filter
        if data and (not filter_lower or data.name:lower():find(filter_lower, 1, true)) then
            imgui.TableNextRow();

            local is_unloaded = data.status == 'Unloaded';
            local needs_pop = false;
            if is_unloaded then
                imgui.PushStyleColor(ImGuiCol_Text, color_unloaded);
                needs_pop = true;
            elseif data.alert_active then
                imgui.PushStyleColor(ImGuiCol_Text, color_alert);
                needs_pop = true;
            elseif name == addon.name then
                imgui.PushStyleColor(ImGuiCol_Text, color_self);
                needs_pop = true;
            end

            -- ASCII star works with the client's default font as well as custom fonts.
            imgui.TableNextColumn();
            local pinned = analysis.is_pinned(name);
            imgui.PushStyleColor(ImGuiCol_Text, pinned and colors.header or colors.muted);
            if imgui.SmallButton('*##pin_' .. name) then
                analysis.toggle_pin(name);
                pins_changed = true;
            end
            imgui.PopStyleColor();
            tooltip(pinned and 'Unstar addon (return to normal sorting).' or 'Star addon (keep at the top).');

            -- Name (C2: non-color alert glyph; ## keeps the Selectable ID stable)
            imgui.TableNextColumn();
            local display_name = data.alert_active and ('! ' .. data.name) or data.name;
            if imgui.Selectable(display_name .. '##row_' .. name, state.ui_selected_addon == name, 0) then
                if state.ui_selected_addon == name then
                    state.ui_selected_addon = nil;
                else
                    state.ui_selected_addon = name;
                end
            end
            -- D3: context menu on every row
            if imgui.BeginPopupContextItem('ctx_' .. name) then
                if imgui.MenuItem(pinned and 'Unstar addon' or 'Star addon') then
                    analysis.toggle_pin(name);
                    pins_changed = true;
                end
                if imgui.MenuItem('Show details') then
                    state.ui_selected_addon = name;
                end
                if imgui.MenuItem('Copy name') then
                    imgui.SetClipboardText(data.name);
                end
                if is_unloaded and imgui.MenuItem('Remove from tracking') then
                    state.remove_addon = name;
                end
                imgui.EndPopup();
            end

            -- Memory (C3: right-aligned in the 90px column)
            imgui.TableNextColumn();
            local mem_str = fmt_mem(data.memory_kb);
            right_align(mem_str, imgui.GetContentRegionAvail());
            imgui.Text(mem_str);

            -- Status
            imgui.TableNextColumn();
            imgui.Text(data.status);

            -- Delta (C3: right-aligned in the 70px column)
            imgui.TableNextColumn();
            local delta_str = string_format('%+.2f', data.last_delta);
            local delta_color = data.last_delta > 0.1 and colors.delta_up
                or data.last_delta < -0.1 and colors.delta_down
                or colors.delta_flat;
            right_align(delta_str, imgui.GetContentRegionAvail());
            imgui.TextColored(delta_color, delta_str);

            -- Trend (C1: colored by slope sign, same mapping as Delta)
            imgui.TableNextColumn();
            if is_unloaded then
                imgui.Text('---');
            else
                local trend_text;
                local trend_color;
                if data.trend_slope > 0.1 then
                    trend_text = 'UP';
                    trend_color = colors.delta_up;
                elseif data.trend_slope < -0.1 then
                    trend_text = 'DOWN';
                    trend_color = colors.delta_down;
                else
                    trend_text = 'FLAT';
                    trend_color = colors.delta_flat;
                end
                imgui.TextColored(trend_color, trend_text);
            end

            if needs_pop then
                imgui.PopStyleColor();
            end
        end
    end

    imgui.EndTable();
    if pins_changed then analysis.sort_addons(state.sort_col, state.sort_asc); end
    imgui.Spacing();
end

-------------------------------------------------------------------------------
-- Charts
-------------------------------------------------------------------------------

--- Format a time span in seconds to a compact human-readable label.
local function fmt_time(sec)
    if sec >= 3600 then
        return string_format('%.1fh', sec / 3600);
    elseif sec >= 60 then
        return string_format('%dm', math.floor(sec / 60));
    else
        return string_format('%ds', sec);
    end
end

--- Resample onto a uniform TIME axis for PlotLines (which spaces points evenly).
--- Interpolation is only for display; stored readings and exports remain untouched.
local function fill_time_chart(values, times, head, n, capacity, out, scale)
    local function index(i) return (head - n + i - 2) % capacity + 1; end
    local first_ts, last_ts = times[index(1)], times[index(n)];
    local span = math_max(last_ts - first_ts, 0);
    local count = math_min(CHART_BUFFER_SIZE, math_max(n, math.ceil(span) + 1));
    local j, peak = 1, 0;
    for i = 1, count do
        local t = first_ts + span * (i - 1) / math_max(count - 1, 1);
        -- With duplicate timestamps use the newest reading at that time.
        while j < n and times[index(j + 1)] <= t do j = j + 1; end
        local k = index(j);
        local v = values[k];
        if j < n then
            local next_k = index(j + 1);
            local dt = times[next_k] - times[k];
            if dt > 0 then v = v + (values[next_k] - v) * (t - times[k]) / dt; end
        end
        out[i] = v * scale;
        peak = math_max(peak, out[i]);
    end
    return count, first_ts, last_ts, peak;
end

-- Zone names live in the chart tooltip; only marker lines are drawn on the plot.
local zone_mark_color = 0xC0E3B341;
local function draw_zone_marks(first_ts, last_ts)
    if not state.settings.zone_markers or (state.zone_mark_count or 0) == 0 then return; end
    local span = last_ts - first_ts;
    if span <= 0 then return; end
    local x1, y1 = imgui.GetItemRectMin();
    local x2, y2 = imgui.GetItemRectMax();
    if type(x1) ~= 'number' or type(x2) ~= 'number' or type(y1) ~= 'number' or type(y2) ~= 'number' then return; end
    local dl = imgui.GetWindowDrawList();
    if dl == nil then return; end
    for _, m in analysis.zone_marks() do
        if m.t >= first_ts and m.t <= last_ts then
            local x = x1 + (m.t - first_ts) / span * (x2 - x1);
            dl:AddLine({ x, y1 }, { x, y2 }, zone_mark_color, 1);
        end
    end
end

local function render_time_scale(first_ts, content_width)
    local now = os.time();
    imgui.TextDisabled(fmt_time(math_max(now - first_ts, 0)) .. ' ago');
    local right = 'now';
    local nw = imgui.CalcTextSize(right);
    imgui.SameLine(content_width - ((type(nw) == 'number' and nw or 20) + 4));
    imgui.TextDisabled(right);
end

-- Override PlotLines' native two-endpoint/index tooltip with one actual recorded sample.
-- Retain the selected reading while the pointer is still: adding history must not silently
-- change the value the user is inspecting. Each chart owns its own hover snapshot.
local chart_hovers = {};
local function chart_hover(id, values, times, head, n, capacity, scale, title, first_ts, last_ts, zones)
    if zones then draw_zone_marks(first_ts, last_ts); end
    if not imgui.IsItemHovered() then chart_hovers[id] = nil; return; end
    local mx, my = imgui.GetMousePos();
    local x1, y1 = imgui.GetItemRectMin();
    local x2, y2 = imgui.GetItemRectMax();
    if type(mx) ~= 'number' or type(my) ~= 'number' or type(x1) ~= 'number' or type(x2) ~= 'number' then return; end
    if mx < x1 or mx > x2 or my < y1 or my > y2 or x2 <= x1 then chart_hovers[id] = nil; return; end

    -- Zone hit-testing uses current line positions even when the memory sample is held.
    local nearby = {};
    if zones and state.settings.zone_markers and last_ts > first_ts then
        for _, m in analysis.zone_marks() do
            if m.t >= first_ts and m.t <= last_ts then
                local x = x1 + (m.t - first_ts) / (last_ts - first_ts) * (x2 - x1);
                if math.abs(mx - x) <= 5 then
                    nearby[#nearby + 1] = os.date('%H:%M:%S', m.t) .. '  ' .. m.name;
                end
            end
        end
    end
    if #nearby > 0 then
        chart_hovers[id] = nil;
        tooltip('Zone change\n' .. table.concat(nearby, '\n'));
        return;
    end

    local held = chart_hovers[id];
    if not held or held.ts < first_ts or held.title ~= title or held.x ~= mx or held.y ~= my or held.left ~= x1 or held.right ~= x2 then
        local target = first_ts + (last_ts - first_ts) * (mx - x1) / (x2 - x1);
        local nearest, distance;
        for i = 1, n do
            local idx = (head - n + i - 2) % capacity + 1;
            local d = math.abs(times[idx] - target);
            if not distance or d <= distance then nearest, distance = idx, d; end
        end
        if not nearest then return; end
        held = { title = title, ts = times[nearest], x = mx, y = my, left = x1, right = x2,
            text = string_format('%s\n%s  |  %.2f MB',
                title, os.date('%H:%M:%S', times[nearest]), values[nearest] * scale) };
        chart_hovers[id] = held;
    end
    tooltip(held.text);
end

local function render_charts()
    if not state.settings.show_charts then return; end

    local h = state.history;

    imgui.TextColored(colors.header, 'Memory Over Time');
    help_marker('Historical graphs on an elapsed-time axis. Hover for recorded samples or zone names.\nLines interpolate between recorded samples, including pauses.');
    imgui.Separator();

    -- B3: collecting-data placeholder until we have enough samples to plot
    if h.count < 2 then
        imgui.TextDisabled(string_format('Collecting samples... (%d/2)', h.count));
        return;
    end

    local chart_height = state.settings.chart_height;
    local content_width = imgui.GetContentRegionAvail();
    local vlimit = math_max(state.current.total_virtual_mb, 1);
    local count, first_ts, last_ts = fill_time_chart(h.working_set, h.timestamps,
        h.head, h.count, analysis.HISTORY_SIZE, ws_chart, 1);

    size_chart[1] = content_width; size_chart[2] = chart_height;
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, plot_padding);
    imgui.PlotLines('##ws_chart', ws_chart, count, 0,
        string_format('Working Set (%.1f / %.0f MB)', state.current.working_set_mb, vlimit),
        0, vlimit,
        size_chart);
    imgui.PopStyleVar();
    chart_hover('working_set', h.working_set, h.timestamps, h.head, h.count,
        analysis.HISTORY_SIZE, 1, 'Working set', first_ts, last_ts, true);
    render_time_scale(first_ts, content_width);

    local _, _, _, max_addon = fill_time_chart(h.addon_total, h.timestamps,
        h.head, h.count, analysis.HISTORY_SIZE, addon_chart, KB_TO_MB);

    local total_kb = state.current.addon_total_kb or 0;
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, plot_padding);
    imgui.PlotLines('##addon_chart', addon_chart, count, 0,
        string_format('All Addons (%s)', fmt_mem(total_kb)),
        0, math_max(max_addon * 1.1, 0.1),
        size_chart);
    imgui.PopStyleVar();
    chart_hover('addon_total', h.addon_total, h.timestamps, h.head, h.count,
        analysis.HISTORY_SIZE, KB_TO_MB, 'All addons', first_ts, last_ts, true);
    render_time_scale(first_ts, content_width);

    imgui.Spacing();
end

-------------------------------------------------------------------------------
-- Selected Addon Detail
-------------------------------------------------------------------------------
local function render_addon_detail()
    if not state.ui_selected_addon then return; end

    local data = state.addons[state.ui_selected_addon];
    if not data then return; end

    imgui.Separator();
    imgui.Text(string_format('Details: %s', data.name));
    imgui.Indent();

    label_value('Current:', fmt_mem(data.memory_kb),
        'Latest Lua-tracked memory for this addon.');
    label_value('Peak:', fmt_mem(data.peak_kb),
        'Highest Lua-tracked memory observed this session.');
    label_value('Min:', fmt_mem(data.min_kb == analysis.MIN_KB_SENTINEL and 0 or data.min_kb),
        'Lowest Lua-tracked memory observed this session.');
    label_value('Trend:', string_format('%.3f KB/sec', data.trend_slope),
        'Exponential moving average of delta (rate of change).\n' ..
        'Positive = growing, Negative = shrinking.\n' ..
        'Requires 3+ samples for accuracy.\n\n' ..
        'NOTE: Positive trends are often normal. LuaJIT compiles\n' ..
        'hot paths (loops with 56+ iterations, frequent calls)\n' ..
        'into machine code (up to ~2 MB cache). This growth is\n' ..
        'expected behavior, not a leak.');
    label_value('Samples:', string_format('%d', data.history_count),
        string_format('Number of data points collected (max %d).\nOne sample per addon poll interval.', analysis.ADDON_HISTORY_SIZE));

    if data.history_count >= 2 then
        local detail_count, first_ts, last_ts = fill_time_chart(data.history, data.history_ts,
            data.history_head, data.history_count, analysis.ADDON_HISTORY_SIZE, addon_detail_chart, KB_TO_MB);

        local content_width = imgui.GetContentRegionAvail();
        size_detail[1] = content_width;
        imgui.PushStyleVar(ImGuiStyleVar_FramePadding, plot_padding);
        imgui.PlotLines('##addon_detail', addon_detail_chart, detail_count, 0,
            nil,
            math_max(data.min_kb * KB_TO_MB * 0.9, 0), math_max(data.peak_kb * KB_TO_MB * 1.1, 0.01),
            size_detail);
        imgui.PopStyleVar();
        chart_hover('detail', data.history, data.history_ts, data.history_head,
            data.history_count, analysis.ADDON_HISTORY_SIZE, KB_TO_MB, data.name, first_ts, last_ts, true);
        render_time_scale(first_ts, content_width);
    else
        imgui.TextDisabled('Need 2+ samples for a trend chart.');
    end

    imgui.Unindent();
end

-------------------------------------------------------------------------------
-- Settings Window
-------------------------------------------------------------------------------

--- Checkbox bound to a settings key, with optional hover tooltip.
local function checkbox_setting(label, key, tip)
    local v = { state.settings[key] };
    if imgui.Checkbox(label, v) then state.settings[key] = v[1]; state.settings_save_requested = true; end
    if tip then tooltip(tip) end
end

--- Integer slider bound to a settings key, with optional hover tooltip.
local function slider_int_setting(label, key, vmin, vmax, tip)
    imgui.SetNextItemWidth(SETTINGS_ITEM_WIDTH);   -- A1: fixed width
    local v = { state.settings[key] };
    if imgui.SliderInt(label, v, vmin, vmax) then state.settings[key] = v[1]; state.settings_save_requested = true; end
    if tip then tooltip(tip) end
end

--- Float slider bound to a settings key, with optional hover tooltip and default.
local function slider_float_setting(label, key, vmin, vmax, fmt, tip, default)
    imgui.SetNextItemWidth(SETTINGS_ITEM_WIDTH);   -- A1: fixed width
    local v = { state.settings[key] or default };
    if imgui.SliderFloat(label, v, vmin, vmax, fmt) then state.settings[key] = v[1]; state.settings_save_requested = true; end
    if tip then tooltip(tip) end
end

local function render_settings()
    if not show_settings[1] then confirm_restore = false; return; end

    local themed = push_theme();
    if imgui.Begin('MemScope Settings', show_settings, ImGuiWindowFlags_AlwaysAutoResize) then
        imgui.TextColored(colors.header, 'Appearance');
        imgui.Separator();
        theme_selection[1] = state.settings.theme == 'default' and 1 or 0;
        imgui.SetNextItemWidth(SETTINGS_ITEM_WIDTH);
        if imgui.Combo('Theme', theme_selection, 'Dark\0Default\0\0') then
            state.settings.theme = theme_selection[1] == 1 and 'default' or 'dark';
            state.settings_save_requested = true;
        end
        tooltip('Dark: MemScope colors and rounded controls.\nDefault: follow your Ashita ImGui theme.');
        imgui.Spacing();
        imgui.TextColored(colors.header, 'Sampling');
        imgui.Separator();

        local v;

        slider_int_setting('Sample Interval (sec)', 'sample_interval', 1, 30,
            'How often to read process memory (Working Set, Page File).\nTwo Win32 calls per sample; 1 s is fine. The history time limit below applies in addition to the 3,600-sample cap.');

        slider_int_setting('Addon Poll Interval (sec)', 'addon_poll_interval', 1, 120,
            'How often to read every addon\'s memory from the AddonManager binding.\nSynchronous and cheap: no chat command is involved.\n5-10s for active monitoring, 30+ for background use.');

        imgui.Spacing();
        imgui.TextColored(colors.header, 'Graph History');
        imgui.Separator();
        local retention = { analysis.history_minutes(state.settings.history_minutes) };
        imgui.SetNextItemWidth(SETTINGS_ITEM_WIDTH);
        if imgui.SliderInt('Graph History (minutes)', retention, 1, 180, '%d min') then
            state.settings.history_minutes = analysis.history_minutes(retention[1]);
            state.settings_save_requested = true;
            analysis.prune_history(os.time(), true);
        end
        tooltip('Keep at most this much graph history (1-180 minutes). Older samples and zone markers are discarded, including from future exports.\nShortening applies immediately; increasing cannot restore discarded samples.\nFixed limits still apply: 3,600 process samples, 600 per addon, 64 zone markers. Fast polling can retain less time.\nPausing freezes history until resumed or manually refreshed.');
        imgui.TextDisabled('Default: 60 minutes. Older samples are discarded.');
        imgui.Spacing();
        imgui.TextColored(colors.header, 'Display');
        imgui.Separator();

        checkbox_setting('Show Process Memory', 'show_process_memory',
            'Show the Working Set and Page File bars at the top.');

        checkbox_setting('Show Addon Breakdown', 'show_addon_breakdown',
            'Show the per-addon memory table.');

        checkbox_setting('Zone Markers on Charts', 'zone_markers',
            'Draw a line with the zone name on every chart where the zone changed.');
        checkbox_setting('Show Charts', 'show_charts',
            'Show the historical memory graphs.');

        slider_int_setting('Chart Height', 'chart_height', 40, 150,
            'Height in pixels for the memory history charts.\nLarger = more detail, smaller = saves space.');

        checkbox_setting('Auto GC Monitoring', 'auto_gc_monitoring',
            'Track garbage collection events for MemScope\'s own Lua state.\nOther addons have isolated GC — only this addon\'s GC is visible.');

        imgui.Spacing();
        imgui.TextColored(colors.header, 'Startup');
        imgui.Separator();

        checkbox_setting('Open window when addon loads', 'show_on_load',
            'Automatically open the MemScope window when the addon loads.\nUncheck to start hidden (use /memscope to open later).');

        imgui.Spacing();
        imgui.TextColored(colors.header, 'Alerts');
        help_marker(
            'Alerts notify you in chat about unusual memory patterns.\n' ..
            'Growth: sustained increase detected via EMA of delta.\n' ..
            'Spike: sudden large jump between consecutive polls.\n\n' ..
            'IMPORTANT: These alerts are informational only.\n' ..
            'LuaJIT jits code after 56 loop iterations, which\n' ..
            'causes normal memory growth (up to ~2 MB cache).\n' ..
            'Most alerts are NOT actual leaks — investigate first.'
        );
        imgui.Separator();

        checkbox_setting('Enable Alerts', 'alerts_enabled',
            'Print growth/spike alerts to chat.\nOff by default — most alerts are false positives from LuaJIT.');

        slider_float_setting('Growth Threshold (KB/sec)', 'growth_threshold', 1.0, 200.0, '%.1f',
            'Sustained growth rate that triggers an informational alert.\n' ..
            'Measured via EMA of delta (3+ samples).\n' ..
            'Default 50 KB/s. Higher = fewer notifications.\n\n' ..
            'NOTE: LuaJIT jitting causes normal memory growth.\n' ..
            'Most alerts are false positives — investigate\n' ..
            'before assuming a real leak exists.');

        slider_float_setting('Spike Threshold (%)', 'spike_threshold', 25, 200, '%.0f',
            'Percentage increase between polls that triggers a spike alert.\n' ..
            'Default 100% = memory must double in one poll interval.\n' ..
            'Also requires minimum absolute change (see below).');

        slider_float_setting('Spike Min Change (KB)', 'spike_min_kb', 64, 2048, '%.0f',
            'Minimum absolute KB change required for a spike alert.\n' ..
            'Prevents false alarms from small addons with big % swings.\n' ..
            'Default 512 KB.', 512);

        imgui.Spacing();
        imgui.TextColored(colors.header, 'Compact Mode');
        imgui.Separator();

        slider_float_setting('Background Opacity', 'compact_bg_alpha', 0.0, 1.0, '%.2f',
            'Background transparency for compact mode.\n0 = fully transparent, 1 = fully opaque.', 0.8);

        v = { state.settings.compact_titlebar ~= false };
        if imgui.Checkbox('Show Title Bar', v) then
            state.settings.compact_titlebar = v[1];
            state.settings_save_requested = true;
        end
        tooltip('Show or hide the window title bar in compact mode.\nThe window is still draggable without it.');

        imgui.Spacing();
        -- E1: two-click confirm for Restore Defaults
        if defaults then
            if confirm_restore then
                imgui.PushStyleColor(ImGuiCol_Text, color_alert);
                local do_restore = imgui.Button('Restore Defaults? (click again)');
                imgui.PopStyleColor();
                if do_restore then
                    for k, dv in pairs(defaults) do
                        state.settings[k] = k == 'pinned_addons' and analysis.copy_pins(dv) or dv;
                    end
                    analysis.prune_history(os.time(), true);
                    analysis.sort_addons(state.sort_col, state.sort_asc);
                    state.settings_save_requested = true;
                    confirm_restore = false;
                end
            else
                if imgui.Button('Restore Defaults') then
                    confirm_restore = true;
                end
            end
            imgui.SameLine();
        end
        if imgui.Button('Close') then
            confirm_restore = false;
            show_settings[1] = false;
        end
    end
    imgui.End();
    pop_theme(themed);
end

-------------------------------------------------------------------------------
-- Compact Mode Window
-------------------------------------------------------------------------------

--- Read a theme color into a pre-allocated table with alpha scaled.
local function scaled_color(tbl, idx, a)
    local r, g, b, ca = imgui.GetStyleColorVec4(idx);
    tbl[1] = r; tbl[2] = g; tbl[3] = b; tbl[4] = ca * a;
    return tbl;
end

local function render_compact()
    if restore_compact_size and saved_compact_size then
        restore_compact_size = false;
        size_restore[1] = saved_compact_size[1]; size_restore[2] = saved_compact_size[2];
        imgui.SetNextWindowSize(size_restore, ImGuiCond_Always);
    elseif restore_compact_size then
        restore_compact_size = false;
        imgui.SetNextWindowSize(size_compact_def, ImGuiCond_Always);
    else
        imgui.SetNextWindowSize(size_compact_def, ImGuiCond_FirstUseEver);
    end

    -- Keep the chosen width, but fit height to the rendered footer (including font scaling).
    compact_min[1] = math_max(300, imgui.CalcTextSize('Working set    4096.0 MB') + 32);
    compact_min[2] = compact_content_height or 0;
    compact_max[2] = compact_content_height or 9999;
    imgui.SetNextWindowSizeConstraints(compact_min, compact_max);

    -- Configurable background opacity
    local bg_alpha = state.settings.compact_bg_alpha or 0.8;
    imgui.SetNextWindowBgAlpha(bg_alpha);

    -- Scale UI element colors by opacity (pre-allocated tables, updated in-place)
    local a = bg_alpha;
    local style_count = 0;
    imgui.PushStyleColor(ImGuiCol_Border,               scaled_color(cc_border,        ImGuiCol_Border, a));               style_count = style_count + 1;
    imgui.PushStyleColor(ImGuiCol_BorderShadow,         scaled_color(cc_border_shadow, ImGuiCol_BorderShadow, a));         style_count = style_count + 1;
    imgui.PushStyleColor(ImGuiCol_ResizeGrip,           scaled_color(cc_grip,          ImGuiCol_ResizeGrip, a));           style_count = style_count + 1;
    imgui.PushStyleColor(ImGuiCol_ResizeGripHovered,    scaled_color(cc_grip_hover,    ImGuiCol_ResizeGripHovered, a));    style_count = style_count + 1;
    imgui.PushStyleColor(ImGuiCol_ResizeGripActive,     scaled_color(cc_grip_active,   ImGuiCol_ResizeGripActive, a));     style_count = style_count + 1;

    local themed = push_theme();

    -- Window flags: optional title bar
    local win_flags = ImGuiWindowFlags_NoScrollbar;
    if state.settings.compact_titlebar == false then
        win_flags = win_flags + ImGuiWindowFlags_NoTitleBar;
    end

    if imgui.Begin('MemScope', is_open, win_flags) then
        local c = state.current;
        local left = imgui.GetCursorPosX();
        local width = imgui.GetContentRegionAvail();
        local function right_text(text, color)
            local tw = imgui.CalcTextSize(text);
            imgui.SameLine(math_max(left, left + width - tw));
            if color then imgui.TextColored(color, text); else imgui.Text(text); end
        end

        imgui.TextColored(colors.header, 'MEMORY');
        local age = math_max(os.time() - (c.timestamp or 0), 0);
        local status = state.paused and 'PAUSED' or (age > (state.settings.sample_interval + 2) and 'STALE' or 'LIVE');
        right_text(status, status == 'LIVE' and compact_live or color_alert);
        tooltip(string_format('Last process sample: %s ago.', fmt_time(age)));
        imgui.Separator();

        imgui.TextDisabled('Working set');
        right_text(string_format('%.1f MB', c.working_set_mb), compact_accent);
        tooltip(string_format('Resident process memory. Peak: %.1f MB.\nChange since previous sample: %+.1f MB.',
            c.peak_working_set_mb, c.ws_delta_mb or 0));

        local h = state.history;
        if h.count >= 2 then
            local n, first_ts, last_ts, peak = fill_time_chart(h.working_set, h.timestamps,
                h.head, h.count, analysis.HISTORY_SIZE, ws_chart, 1);
            compact_graph[1] = width;
            imgui.PlotLines('##compact_memory', ws_chart, n, 0, '', 0, math_max(peak * 1.12, 1), compact_graph);
            chart_hover('compact', h.working_set, h.timestamps, h.head, h.count,
                analysis.HISTORY_SIZE, 1, 'Working set', first_ts, last_ts, false);
        else
            imgui.TextDisabled('Collecting memory history...');
        end

        imgui.TextDisabled('Committed');
        right_text(string_format('%.1f MB', c.pagefile_mb));
        imgui.TextDisabled('Addon Lua');
        right_text(state.addon_source == 'native' and fmt_mem(c.addon_total_kb or 0) or 'Unavailable',
            state.addon_source == 'native' and colors.header or color_alert);
        tooltip('Lua-tracked addon memory; excludes native and FFI allocations.');
        imgui.Separator();
        imgui.TextDisabled('STARRED / LARGEST ADDONS');

        -- Select the top three without changing the full dashboard's chosen sort order.
        compact_top[1], compact_top[2], compact_top[3] = nil, nil, nil;
        for _, name in ipairs(state.addon_order) do
            local data = state.addons[name];
            if data and data.status ~= 'Unloaded' then
                for rank = 1, 3 do
                    local other = compact_top[rank];
                    local pinned = analysis.is_pinned(data.name);
                    local other_pinned = other and analysis.is_pinned(other.name);
                    if not other or (pinned and not other_pinned)
                        or (pinned == other_pinned and data.memory_kb > other.memory_kb) then
                        for k = 3, rank + 1, -1 do compact_top[k] = compact_top[k - 1]; end
                        compact_top[rank] = data;
                        break;
                    end
                end
            end
        end
        for rank = 1, 3 do
            local data = compact_top[rank];
            if data then
                local value = fmt_mem(data.memory_kb);
                local max_name = math_max(width - imgui.CalcTextSize(value) - 24, 24);
                local name = (analysis.is_pinned(data.name) and '* ' or '') .. data.name;
                if imgui.CalcTextSize(name) > max_name then
                    while #name > 0 and imgui.CalcTextSize(name .. '...') > max_name do name = name:sub(1, -2); end
                    name = name .. '...';
                end
                imgui.Text(name);
                tooltip(data.name .. '\n' .. data.status);
                right_text(value, data.status == 'Read error' and color_alert or nil);
                tooltip(data.status == 'Read error' and 'Last valid reading; the latest memory read failed.'
                    or string_format('Growth trend: %+.2f KB/sec', data.trend_slope));
            else
                imgui.TextDisabled(rank == 1 and 'Waiting for addon readings...' or ' ');
            end
        end
        imgui.Separator();

        if imgui.SmallButton(state.paused and 'Resume' or 'Pause') then state.paused = not state.paused; end
        tooltip(state.paused and 'Resume data collection.' or 'Pause data collection.');
        local button_width = imgui.CalcTextSize('Details') + 16;
        imgui.SameLine(math_max(left, left + width - button_width));
        if imgui.SmallButton('Details') then
            local w, height = imgui.GetWindowSize();
            if not saved_compact_size then saved_compact_size = { 0, 0 }; end
            saved_compact_size[1] = w; saved_compact_size[2] = height;
            chart_hovers = {};
            compact_mode = false;
            restore_full_size = true;
        end
        tooltip('Open the full memory dashboard.');
        local bottom = imgui.GetCursorPosY();
        if type(bottom) == 'number' then compact_content_height = math.ceil(bottom + 8); end
    end
    imgui.End();
    pop_theme(themed);
    imgui.PopStyleColor(style_count);
end

-------------------------------------------------------------------------------
-- Main Window (Full Mode)
-------------------------------------------------------------------------------
local function render_full()
    local themed = push_theme();
    if reset_pending then
        reset_pending = false;
        restore_full_size = false;
        saved_full_size = nil;
        saved_compact_size = nil;
        imgui.SetNextWindowSize(size_default, ImGuiCond_Always);
        imgui.SetNextWindowPos(pos_default, ImGuiCond_Always);
    elseif restore_full_size then
        restore_full_size = false;
        if (saved_full_size) then
            size_restore[1] = saved_full_size[1]; size_restore[2] = saved_full_size[2];
        else
            size_restore[1] = size_default[1]; size_restore[2] = size_default[2];
        end
        saved_full_size = nil;
        imgui.SetNextWindowSize(size_restore, ImGuiCond_Always);
    else
        imgui.SetNextWindowSize(size_default, ImGuiCond_FirstUseEver);
    end

    if imgui.Begin('MemScope', is_open, ImGuiWindowFlags_NoScrollbar + ImGuiWindowFlags_NoScrollWithMouse) then
        measure_layout();
        -- Toolbar: [Pause] [Refresh] | [GC] [Trim] | [Export] [Compact]
        -- B1: tint the Pause button while paused (read the flag first; click flips it)
        local is_paused = state.paused;
        if is_paused then imgui.PushStyleColor(ImGuiCol_Button, themed and button_paused or color_alert); end
        if imgui.Button(state.paused and 'Resume' or 'Pause') then
            state.paused = not state.paused;
        end
        if is_paused then imgui.PopStyleColor(); end
        tooltip(state.paused and 'Resume data collection.' or 'Pause data collection for review.');
        imgui.SameLine();
        if imgui.Button('Refresh') then
            state.force_refresh = true;
        end
        tooltip('Take an immediate snapshot and poll all addons.');
        imgui.SameLine();
        imgui.TextDisabled('|');
        imgui.SameLine();
        if imgui.Button('GC') then
            state.force_gc = true;
        end
        tooltip(
            'Force Lua garbage collection for MemScope only.\n' ..
            'Each addon has its own isolated Lua state —\n' ..
            'this does NOT affect other addons\' memory.'
        );
        imgui.SameLine();
        if imgui.Button('Trim') then
            state.force_trim = true;
        end
        tooltip(
            'Trim the process working set (from atom0s\'s freemem addon).\n' ..
            'Releases pages Windows is holding onto lazily.\n' ..
            'Win10/11 inflates Working Set — trimming shows\n' ..
            'actual memory usage. Safe; OS pages back as needed.'
        );
        imgui.SameLine();
        imgui.TextDisabled('|');
        imgui.SameLine();
        -- E2: disable Export when there is no sampled data yet
        local no_data = state.history.count == 0;
        imgui.BeginDisabled(no_data);
        if imgui.Button('Export') then
            state.force_export = true;
        end
        imgui.EndDisabled();
        if no_data then
            if imgui.IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled) then
                imgui.SetTooltip('No samples to export yet.');
            end
        else
            tooltip('Export session data to Excel workbook (.xls).');
        end
        imgui.SameLine();
        if imgui.Button('Compact') then
            local w, h = imgui.GetWindowSize();
            if (not saved_full_size) then saved_full_size = { 0, 0 }; end
            saved_full_size[1] = w; saved_full_size[2] = h;
            chart_hovers = {};
            compact_mode = true;
            restore_compact_size = true;
        end
        tooltip('Switch to compact overlay.');

        imgui.Separator();

        -- B1: visible paused banner
        if state.paused then
            imgui.TextColored(color_alert, 'PAUSED - data collection stopped');
        end

        -- Scrollable content area (reserves 26px at bottom for status bar)
        imgui.BeginChild('##content', size_content);
            render_process_memory();
            render_lua_memory();
            render_addon_table();
            render_addon_detail();   -- D4: detail directly under the table
            render_charts();
        imgui.EndChild();

        -- Status bar (fixed, outside scroll area) — matches PlayerNotes pattern
        imgui.Separator();
        imgui.TextColored(colors.muted, string_format('%d samples | %d addons', state.history.count, #state.addon_order));
        tooltip('Process memory samples collected this session\nand number of tracked addons.');

        -- Footer buttons are measured, not a fixed 175 px: at UI scale 1.5 they were wider than that
        -- and ran over the status text.
        local sw = imgui.CalcTextSize('Settings'); local rw = imgui.CalcTextSize('Reset UI');
        local btn_w = ((type(sw) == 'number' and sw or 60) + (type(rw) == 'number' and rw or 60)) + 44;
        local avail_w = imgui.GetContentRegionAvail();
        local status_w = imgui.GetCursorPosX();

        -- B2: transient export result feedback (green ok / red failure), only where it fits
        if state.last_export and (os.time() - state.last_export.t) <= EXPORT_FEEDBACK_SECS then
            local em = state.last_export.msg or '';
            if #em > 36 then em = em:sub(1, 36) .. '...'; end
            local mw = imgui.CalcTextSize(em);
            if type(mw) ~= 'number' or status_w + mw + btn_w + 16 <= status_w + avail_w then
                imgui.SameLine();
                imgui.TextColored(state.last_export.ok and colors.delta_down or colors.delta_up, em);
            end
        end

        local cursor_x = imgui.GetCursorPosX();
        avail_w = imgui.GetContentRegionAvail();
        imgui.SameLine(cursor_x + avail_w - btn_w);
        if imgui.Button('Settings') then
            show_settings[1] = not show_settings[1];
        end
        tooltip('Configure sampling, display, and alert thresholds.');
        imgui.SameLine();
        imgui.PushStyleColor(ImGuiCol_Button, themed and button_normal or color_reset_btn);
        if imgui.Button('Reset UI') then
            reset_pending = true;
        end
        imgui.PopStyleColor();
        tooltip('Reset window size and position to defaults.');
    end
    imgui.End();
    pop_theme(themed);
end

-------------------------------------------------------------------------------
-- Main Render Entry Point
-------------------------------------------------------------------------------
function ui.render()
    -- Login gate is handled by d3d_present in memscope.lua — no duplicate check needed here

    if is_open[1] then
        if compact_mode then
            render_compact();
        else
            render_full();
        end
    end

    -- Settings is its own window: reachable from /memscope settings even while the
    -- dashboard is hidden or compact. Returns immediately when not open.
    render_settings();
end

-------------------------------------------------------------------------------
-- Public: Window visibility control
-------------------------------------------------------------------------------
function ui.is_visible()
    return is_open[1];
end

function ui.toggle()
    chart_hovers = {};
    is_open[1] = not is_open[1];
end

function ui.show()
    is_open[1] = true;
end

function ui.hide()
    chart_hovers = {};
    is_open[1] = false;
end

function ui.open_settings()
    show_settings[1] = true;
end

function ui.toggle_compact()
    chart_hovers = {};
    compact_mode = not compact_mode;
    if compact_mode then
        restore_compact_size = true;
    else
        restore_full_size = true;
    end
end

function ui.reset_ui()
    chart_hovers = {};
    compact_mode = false;
    saved_full_size = nil;
    saved_compact_size = nil;
    reset_pending = true;
end

return ui;

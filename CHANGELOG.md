# Changelog

### v1.2.0
- **Per-addon memory is read from the `AddonManager` binding** (`Count()`, `Get(i)`, `GetMemoryUsage(name)` in bytes, `GetState(name)`), which addons.dll installs into every addon's Lua state. Before this, MemScope ran `/addon list` on a timer and scraped the chat output it silently intercepted: a chat command per poll, kilobyte rounding, and a list that could come back partial.
- Removed the capture state machine, the `text_in` listener, debug capture, the `/memscope source|fallback|debug` commands and the `chat_fallback` setting (stale keys are dropped from saved settings on load).
- Star addons to keep them at the top (`*` column or right-click **Star addon**); saved per character, survives unloads; compact mode fills its three slots with starred addons first.
- **Settings > Appearance > Theme**: Dark (MemScope's navy look) or Default (your Ashita ImGui theme).
- Compact mode: height fits its content; redesigned panel with a working-set trend and aligned totals.
- A failed per-addon read keeps the last real value and shows `Read error` instead of recording a zero.
- Charts: elapsed-time axis, static `now` caption, held tooltips with the recorded time, zone markers with hover names (`/memscope zones off`).
- Empty addon list shows its message above the table.
- **Settings > Graph History**: keep 1-180 minutes of chart history (default 60); older samples and zone markers are dropped, including from later exports.

### v1.0.3
- Pre-allocated all ImGui size/position tables, style color tables, and row color constants (eliminates ~20 per-frame table allocations)
- Removed dead `own_memory_kb` field from shared state
- Removed stale `leak_threshold` migration cleanup from load handler
- Added missing settings to README: Show On Load, Background Opacity, Show Title Bar
- Added tooltips to all settings widgets and addon detail items (Chart Height, Show On Load, Enable Alerts, compact Pause/Resume, Current/Peak/Min/Samples)
- Export: added pcall wrapping for guaranteed file handle cleanup on error (matches LootScope pattern)
- Export: added character name to filename (`memscope_<CharName>_<timestamp>.xls`)
- Export: added pcall at both call sites (d3d_present action flag + `/memscope export` command)
- Fixed .gitignore to ignore entire `exports/` directory instead of only `*.xls`
- Fixed README: export path now shows correct config directory location

### v1.0.2
- Pre-allocated delta color constants in addon table (eliminates per-row table creation at 60fps)
- Fixed incorrect "Own Tracked" data source in README (non-existent API method removed)

### v1.0.1
- Renamed `leak_threshold` setting to `growth_threshold` (consistent with reframed "growth" language)
- Added `Auto GC Monitoring` checkbox to Settings UI (was only configurable via settings file)
- Added pool slot reclamation: removed addons free their tracking slot for reuse
- Added pcall guard around text_in handler to prevent stuck reentrancy guard on error
- Added missing state initializations (`force_export`, `remove_addon`, `session_start`)
- Fixed unused pcall error variables, improved sort comparator naming

### v1.0.0
- Split into 4 files (memscope, monitor, analysis, ui)
- Per-addon Lua memory tracking via /addon list capture with silent interception
- Process memory monitoring via Windows FFI (working set, page file)
- EMA trend analysis with growth/spike observation (informational alerts, disabled by default)
- Data accuracy disclaimers throughout UI
- Historical ring buffers (3,600 process samples, 600 per addon; addon rings allocated on first use)
- Compact overlay mode with automatic window size restore on expand
- Pause/resume data collection
- Export to Excel (.xls) with multiple worksheet tabs
- Scrollable addon table (10-row max with frozen headers) with sorting and right-click context menu
- Reset UI button and `/memscope resetui` command
- Debug capture mode for troubleshooting
- Pre-allocated chart buffers, action flag decoupling
- Per-character settings via Ashita's settings module
- Uses Ashita `chat` module for standard colored output

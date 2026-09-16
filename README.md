# MemScope v1.2.0 - Memory Monitoring Addon for Ashita v4.3

A memory monitoring tool that tracks per-addon Lua memory, process memory, and provides growth analysis with historical trends.

## Features

- **Process Memory Tracking** - Working set, page file, and peak usage via Windows APIs (FFI)
- **Per-Addon Memory Breakdown** - Read straight from Ashita's `AddonManager` binding (byte resolution, no chat command)
- **Historical Trends** - Configurable rolling history limit (1–180 minutes, default 60), backed by fixed-size ring buffers
- **Growth Observation** - EMA (exponential moving average) of delta to observe sustained memory changes
- **Spike Observation** - Informational alerts on sudden memory increases (% threshold + minimum absolute change)
- **GC Monitoring** - Track garbage collection events and freed memory (this addon's Lua state only)
- **ImGui Dashboard** - Real-time visualization with charts, sortable tables, and compact mode
- **Zone Markers** - A gold line with the zone name on every chart where you changed zone, so a memory step can be tied to a zone; the export gets a `Zones` sheet
- **Export to Excel** - Session data exported as `.xls` with multiple worksheet tabs
- **Pre-allocated Buffers** - Ring buffers, object pools, cached chart data (zero per-frame allocation)

## Requirements

- Ashita v4.3.2.1
	- This release has only been tested with Ashita v4.3.2.1

## Installation

1. Copy the `memscope` folder to your Ashita `addons` directory
2. Load with `/addon load memscope`

## Commands

| Command | Description |
|---------|-------------|
| `/memscope` | Toggle the main window |
| `/memscope show` | Show the window |
| `/memscope hide` | Hide the window |
| `/memscope compact` | Toggle compact overlay mode |
| `/memscope pause` | Pause/resume data collection |
| `/memscope snapshot` | Take a manual memory snapshot |
| `/memscope report` | Print memory report to chat |
| `/memscope export` | Export session data to Excel (.xls) |
| `/memscope gc` | Force garbage collection (this addon only) |
| `/memscope trim` | Trim working set (shows actual vs inflated memory) |
| `/memscope zones [on/off]` | Toggle zone-change markers on the charts (status with no argument) |
| `/memscope alerts [on/off]` | Toggle growth/spike alerts |
| `/memscope clear` | Remove all unloaded addons from tracking (same as the Clear Unloaded button) |
| `/memscope remove <name>` | Remove one addon from tracking (same as right-click > Remove from tracking) |
| `/memscope resetui` | Reset window size and position to defaults |
| `/memscope help` | Show command help |

## File Structure

```
memscope/
  memscope.lua   -- Entry point, events, commands, state, export
  monitor.lua    -- FFI + AddonManager binding reads + GC monitoring
  analysis.lua   -- Ring buffers, trend/growth/spike analysis, addon pool
  ui.lua         -- ImGui dashboard rendering
```

Settings are managed by Ashita's settings module and saved per-character under `config/addons/memscope/<CharName>_<ID>/settings.lua`.

Export files are written to `config/addons/memscope/exports/` (created at runtime).

## Dashboard Sections

### Process Memory
- **Working Set** - Physical RAM pages mapped into the process
- **Committed** - Virtual memory committed (RAM + swap reserved)
- Progress bars show usage vs the process virtual address limit (2 GB or 4 GB with LAA)
- Hover for peak values, deltas, and system memory info

### Lua Memory
- MemScope's own Lua state memory (this addon only)
- All loaded addons combined total (from the AddonManager binding — Lua-tracked memory only, see Data Accuracy below)
- GC collection statistics (count and last freed amount — MemScope's own GC only)

### Addon Breakdown
Sortable, scrollable table (click column headers to sort). Displays up to 10 rows before scrolling, with frozen header row:
- **Name** - Addon name (color-coded: orange=growth alert, green=self)
- **Memory** - Current Lua-tracked memory (excludes FFI/ImGui/C++ allocations)
- **Status** - Running/Ok/Unloaded
- **Delta** - Memory change per second (green=decreasing, red=increasing)
- **Trend** - UP/DOWN/FLAT based on EMA of delta (may reflect normal LuaJIT behavior)

Click any row for detailed stats and mini-chart. Right-click unloaded addons to remove from tracking.

### Memory Charts
- Process working set over time
- All addons combined total over time (displayed in MB)
- Time scale shown below each chart

### Compact Mode
Minimal overlay showing just the working set bar, top 3 addons, and pause/expand buttons. Toggle via the Compact button or `/memscope compact`. Window size restores automatically when expanding back to full mode.

## Alert System

**Alerts are disabled by default** because most triggers are false positives from normal LuaJIT behavior (see Data Accuracy below). Enable them in Settings if you want informational notifications during addon development.

### Growth Observation
Triggers when an addon shows sustained memory increase:
- Default threshold: 50.0 KB/sec (raised to reduce false positives)
- Uses EMA (exponential moving average) of delta for responsive trend tracking
- Requires 3+ samples before trend calculation begins
- **NOTE**: LuaJIT compiles hot paths into machine code, which increases Lua memory. This is normal and expected — not a leak.

### Spike Observation
Triggers on sudden memory jumps:
- Default threshold: 100% increase between polls
- Also requires minimum absolute change (default 512 KB)
- Prevents false alarms from small addons with large percentage swings
- **NOTE**: LuaJIT hot-path compilation can cause legitimate one-time jumps.

## Export

Export path: `config/addons/memscope/exports/memscope_<CharName>_YYYYMMDD_HHMMSS.xls`

`/memscope export` creates a SpreadsheetML `.xls` file with pcall-guarded writes (file handle is always closed, even on error). Opens natively in Excel and LibreOffice with multiple worksheet tabs:

- **Session** - Metadata (date, duration, LAA status, system RAM) + addon summary table
- **Process Timeline** - Full process memory history with timestamps
- **Addons Timeline** - Wide format, one row per poll timestamp, one column per addon (blank where an addon had no sample at that time)
- **Per-Addon Tabs** - One tab per addon with metadata header, timeline, deltas, and change-from-start

## Graph history retention

Use **Settings → Graph History → Graph History (minutes)** to keep at most 1–180 minutes of graph history (default **60 minutes**). This applies to process charts, the compact chart, addon detail charts, zone markers, and the history included in future exports. Lowering the limit discards older entries immediately; raising it allows new history to accumulate and cannot restore discarded samples.

History was already bounded by fixed buffers, not an ever-growing log. Those caps remain: **3,600 process samples, 600 samples per addon, and 64 zone markers**. Frequent sampling can fill a buffer before the selected time limit: at a one-second addon poll interval, addon history holds about ten minutes. No additional history is allocated to meet a longer time setting.

Paused history stays frozen until monitoring resumes or you take a manual sample; changing the retention setting explicitly still applies immediately while paused. Current readings and session peak/minimum statistics remain available when graph samples expire. Already exported files are unchanged.

## Data Accuracy

- Per-Addon Memory (Understated)
	- The per-addon memory values only reflect **Lua-tracked memory** — what the Lua VM allocates for tables, strings, functions, and other Lua objects. The following are **NOT included**:
		- **FFI allocations** (`ffi.new`, `ffi.C.*` calls) — allocated outside the Lua GC
		- **ImGui resources** — textures, fonts, draw lists managed by the Addons plugin
		- **Manual C allocations** — anything allocated by native code on behalf of the addon
		- **Addons plugin internals** — the Addons plugin's own overhead per loaded addon
	- This means actual addon memory usage is typically **higher** than what MemScope reports.
- Working Set (Overstated on Win10/11)
	- Windows 10 and 11 **inflate Working Set values** compared to actual usage. The OS holds onto memory pages aggressively and delays releasing them, even when the process no longer needs them. Use the **Trim** button in the toolbar (or `/memscope trim`) to force a working set trim — actual usage is typically much lower. This uses the same `SetProcessWorkingSetSize(-1, -1)` technique from atom0s's `freemem` addon. The OS will page memory back in as needed — trimming is safe and non-destructive.
- GC Monitoring (MemScope Only)
	- Each Ashita addon runs in its own **isolated Lua state** with a separate garbage collector. The GC statistics shown by MemScope only reflect MemScope's own Lua VM. There is no way to trigger or observe GC in other addons from Lua.
- Growth Alerts (Informational Only)
	- LuaJIT compiles frequently-executed Lua code ("hot paths") into machine code. A loop or function call becomes "hot" after **56 iterations** (configurable via `hotloop`), at which point LuaJIT records and compiles a trace. The compiled machine code cache can grow up to **~2 MB** (`maxmcode = 2048 KB`). This JIT compilation **increases Lua memory usage** as compiled traces are stored. This is normal, expected behavior — not a memory leak. Since every addon running in `d3d_present` at 60fps will trigger JIT compilation quickly, most growth alerts from MemScope are false positives. The alerts are disabled by default for this reason. (See [LuaJIT Running](https://luajit.org/running.html) for full JIT parameters.)

## Technical Notes

### Per-Addon Memory Source

Per-addon memory is read from the `AddonManager` binding that addons.dll installs into every addon's Lua state — `AddonManager:Count()`, `Get(i)` (0-based name), `GetMemoryUsage(name)` (bytes, as a number), `GetState(name)` (1 = running, 3 = loading). Measured 2026-09-07 with `addons/amprobe` on Ashita 4.3. Every poll is one synchronous walk of that list into a pre-allocated buffer: no chat command, no chat listener, byte resolution, and the inventory is complete by construction so an addon that disappears is marked Unloaded on the next poll. If a build ever lacks the binding, MemScope shows "AddonManager binding unavailable" and tracks process memory only.

### Memory Data Sources

| Metric | Source | Scope |
|--------|--------|-------|
| Working Set | K32GetProcessMemoryInfo (FFI) | Entire FFXI process |
| Page File | K32GetProcessMemoryInfo (FFI) | Entire FFXI process |
| System RAM | GlobalMemoryStatusEx (FFI) | System-wide |
| Own Lua State | collectgarbage('count') | This addon's Lua VM only |
| Per-Addon | `AddonManager:GetMemoryUsage(name)` (bytes) | All loaded addons |

## Version History

See [CHANGELOG.md](CHANGELOG.md).

## Thanks

- **Ashita Team** - atom0s, thorny, and the [Ashita Discord](https://discord.gg/Ashita) community

## License

MIT License - See LICENSE file
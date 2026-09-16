--[[
    MemScope v1.2.0 - Monitor Module
    FFI for Windows memory APIs, the AddonManager binding (per-addon memory), GC monitoring.
]]--

local ffi = require 'ffi';

local monitor = {};

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local BYTES_TO_MB = 1 / (1024 * 1024);
local BYTES_TO_KB = 1 / 1024;
local CAPTURE_TIMEOUT = 2.0;
local MAX_ADDONS = 256;    -- pre-allocated inventory slots; more than this is reported incomplete

-------------------------------------------------------------------------------
-- Cached References
-------------------------------------------------------------------------------
local collectgarbage = collectgarbage;
local tonumber = tonumber;
local os_clock = os.clock;

-------------------------------------------------------------------------------
-- Module State (set via init)
-------------------------------------------------------------------------------
local state = nil;
local process_handle = nil;
local mem_counters = nil;
local ffi_available = false;

-- Pre-allocated inventory entries, reused by every read (no per-poll allocation)
local results = {};
for i = 1, MAX_ADDONS do
    results[i] = { name = '', status = '', memory_kb = 0 };
end

-------------------------------------------------------------------------------
-- FFI Definitions (Windows Memory APIs)
-------------------------------------------------------------------------------
local mem_status = nil;
local mem_status_available = false;

local function define_ffi()
    local ok, err = pcall(function()
        ffi.cdef[[
            typedef unsigned long DWORD;
            typedef unsigned long long DWORDLONG;
            typedef size_t SIZE_T;
            typedef void* HANDLE;
            typedef int BOOL;

            typedef struct {
                DWORD  cb;
                DWORD  PageFaultCount;
                SIZE_T PeakWorkingSetSize;
                SIZE_T WorkingSetSize;
                SIZE_T QuotaPeakPagedPoolUsage;
                SIZE_T QuotaPagedPoolUsage;
                SIZE_T QuotaPeakNonPagedPoolUsage;
                SIZE_T QuotaNonPagedPoolUsage;
                SIZE_T PagefileUsage;
                SIZE_T PeakPagefileUsage;
            } PROCESS_MEMORY_COUNTERS;

            typedef struct {
                DWORD     dwLength;
                DWORD     dwMemoryLoad;
                DWORDLONG ullTotalPhys;
                DWORDLONG ullAvailPhys;
                DWORDLONG ullTotalPageFile;
                DWORDLONG ullAvailPageFile;
                DWORDLONG ullTotalVirtual;
                DWORDLONG ullAvailVirtual;
                DWORDLONG ullAvailExtendedVirtual;
            } MEMORYSTATUSEX;

            HANDLE GetCurrentProcess(void);
            BOOL K32GetProcessMemoryInfo(HANDLE Process, PROCESS_MEMORY_COUNTERS* ppsmemCounters, DWORD cb);
            BOOL GlobalMemoryStatusEx(MEMORYSTATUSEX* lpBuffer);

            // Working set trim — from atom0s's freemem addon.
            // Passing (-1, -1) tells Windows to trim the working set to its minimum,
            // releasing pages the OS is holding onto lazily. Shows actual memory usage
            // vs Win10/11 inflated values.
            BOOL SetProcessWorkingSetSize(HANDLE hProcess, SIZE_T dwMinimumWorkingSetSize, SIZE_T dwMaximumWorkingSetSize);
        ]];
    end);
    return ok;
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------
function monitor.init(shared_state)
    state = shared_state;

    -- Initialize FFI with safety
    local ok = define_ffi();
    if ok then
        local pok, _ = pcall(function()
            process_handle = ffi.C.GetCurrentProcess();
            mem_counters = ffi.new('PROCESS_MEMORY_COUNTERS');
            mem_counters.cb = ffi.sizeof('PROCESS_MEMORY_COUNTERS');
        end);
        ffi_available = pok;
    end

    -- Initialize system memory query struct
    if ffi_available then
        local sok, _ = pcall(function()
            mem_status = ffi.new('MEMORYSTATUSEX');
            mem_status.dwLength = ffi.sizeof('MEMORYSTATUSEX');
        end);
        mem_status_available = sok;
    end

    -- Initialize GC state
    state.gc = {
        last_count = collectgarbage('count'),
        collections = 0,
        freed_kb = 0,
    };
end

-------------------------------------------------------------------------------
-- Process Memory Query (FFI)
-------------------------------------------------------------------------------
function monitor.query_process_memory()
    if not ffi_available then return false; end

    if ffi.C.K32GetProcessMemoryInfo(process_handle, mem_counters, mem_counters.cb) ~= 0 then
        state.current.working_set_mb = tonumber(mem_counters.WorkingSetSize) * BYTES_TO_MB;
        state.current.peak_working_set_mb = tonumber(mem_counters.PeakWorkingSetSize) * BYTES_TO_MB;
        state.current.pagefile_mb = tonumber(mem_counters.PagefileUsage) * BYTES_TO_MB;
        state.current.peak_pagefile_mb = tonumber(mem_counters.PeakPagefileUsage) * BYTES_TO_MB;
        return true;
    end
    return false;
end

-------------------------------------------------------------------------------
-- System Memory Query (FFI)
-------------------------------------------------------------------------------
function monitor.query_system_memory()
    if not mem_status_available then return false; end

    if ffi.C.GlobalMemoryStatusEx(mem_status) ~= 0 then
        state.current.total_phys_mb = tonumber(mem_status.ullTotalPhys) * BYTES_TO_MB;
        state.current.avail_phys_mb = tonumber(mem_status.ullAvailPhys) * BYTES_TO_MB;
        state.current.total_pagefile_mb = tonumber(mem_status.ullTotalPageFile) * BYTES_TO_MB;
        state.current.avail_pagefile_mb = tonumber(mem_status.ullAvailPageFile) * BYTES_TO_MB;
        state.current.total_virtual_mb = tonumber(mem_status.ullTotalVirtual) * BYTES_TO_MB;
        state.current.avail_virtual_mb = tonumber(mem_status.ullAvailVirtual) * BYTES_TO_MB;
        state.current.memory_load_pct = tonumber(mem_status.dwMemoryLoad);
        return true;
    end
    return false;
end

-------------------------------------------------------------------------------
-- Lua Memory Query
-------------------------------------------------------------------------------
function monitor.query_lua_memory()
    -- This addon's own Lua state only (not global)
    state.current.own_lua_kb = collectgarbage('count');
end

-------------------------------------------------------------------------------
-- Working Set Trim
-- Technique from atom0s's freemem addon (Ashita built-in).
-- SetProcessWorkingSetSize(-1, -1) forces Windows to release pages it is
-- holding onto lazily. Win10/11 inflates Working Set values — trimming shows
-- the actual memory footprint. Safe to call; the OS will page back in as needed.
-------------------------------------------------------------------------------
function monitor.trim_working_set()
    if not ffi_available then return 0, 0; end

    -- Read working set before trim (bail on failure so we don't report bogus MB)
    if (ffi.C.K32GetProcessMemoryInfo(process_handle, mem_counters, mem_counters.cb) == 0) then return 0, 0; end
    local before_mb = tonumber(mem_counters.WorkingSetSize) * BYTES_TO_MB;

    -- Trim. (SIZE_T)-1 / (SIZE_T)-1 tells Windows to trim as much as possible.
    ffi.C.SetProcessWorkingSetSize(process_handle, ffi.cast('SIZE_T', -1), ffi.cast('SIZE_T', -1));

    -- Read working set after trim; if that read fails, report no change rather than garbage
    if (ffi.C.K32GetProcessMemoryInfo(process_handle, mem_counters, mem_counters.cb) == 0) then return before_mb, before_mb; end
    local after_mb = tonumber(mem_counters.WorkingSetSize) * BYTES_TO_MB;

    return before_mb, after_mb;
end

-------------------------------------------------------------------------------
-- GC Monitoring
-------------------------------------------------------------------------------
function monitor.monitor_gc()
    if not state.settings.auto_gc_monitoring then return; end

    local current_count = collectgarbage('count');
    if current_count < state.gc.last_count then
        state.gc.collections = state.gc.collections + 1;
        state.gc.freed_kb = state.gc.last_count - current_count;
    end
    state.gc.last_count = current_count;
end

-------------------------------------------------------------------------------
-- Native source: the AddonManager Lua binding (measured 2026-09-07 with addons/amprobe)
--
-- addons.dll binds a live `AddonManager` userdata into every addon: Count(), Get(i) (0-based
-- name), GetMemoryUsage(name) -> BYTES as a number, GetState(name) -> number (1 = running,
-- 3 = still loading), IsLoaded(name). Reading it is synchronous, costs no chat traffic, and
-- gives byte resolution. It is the ONLY per-addon source: there is no chat-command fallback.
-------------------------------------------------------------------------------
local STATE_NAMES = { [1] = 'Ok', [3] = 'Loading' };
function monitor.addon_manager_available()
    local ok, n = pcall(function() return AddonManager:Count(); end);
    return ok and type(n) == 'number';
end

--- Read every addon straight from the AddonManager binding and hand `callback`
--- (results, count, complete). Returns false (and calls nothing) when the binding is not usable.
function monitor.read_addon_manager(callback)
    local ok, n = pcall(function() return AddonManager:Count(); end);
    if not ok or type(n) ~= 'number' then return false; end
    local count = 0;
    local complete = true;
    for i = 0, n - 1 do
        local okn, name = pcall(function() return AddonManager:Get(i); end);
        if not (okn and type(name) == 'string' and name ~= '') then
            complete = false;   -- a name we could not read is not an addon that went away
        else
            if count >= MAX_ADDONS then complete = false; break; end
            local okm, mem = pcall(function() return AddonManager:GetMemoryUsage(name); end);
            local oks, st  = pcall(function() return AddonManager:GetState(name); end);
            local mem_kb = nil;
            if okm then
                if type(mem) == 'number' then
                    mem_kb = mem * BYTES_TO_KB;
                elseif type(mem) == 'string' then
                    -- defensive: a build that formats the value as text ('3.10 MB')
                    local v, u = mem:match('^%s*([%d%.]+)%s*(%a+)%s*$');
                    local units = { B = BYTES_TO_KB, KB = 1, MB = 1024 };
                    local scale = u and units[u:upper()];
                    v = tonumber(v);
                    if v and scale then mem_kb = v * scale; end
                end
            end
            -- A failed/invalid read is missing data, never a measured zero. Keep the
            -- name in the inventory so a complete poll can still prune absent addons.
            if mem_kb and (mem_kb ~= mem_kb or mem_kb < 0 or mem_kb == math.huge) then
                mem_kb = nil;
            end
            count = count + 1;
            local entry = results[count];
            entry.name = name;
            entry.memory_kb = mem_kb;
            entry.status = (oks and type(st) == 'number' and (STATE_NAMES[st] or ('State ' .. tostring(st)))) or 'Unknown';
        end
    end
    callback(results, count, complete);
    return true;
end

return monitor;

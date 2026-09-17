-- Offline logic test for firmware.lua. Stubs the Enapter Virtual UCM runtime
-- (enapter/scheduler/storage/http/system) well enough to exercise the real
-- state machine end-to-end without any real hardware or cloud connection.

package.path = package.path .. ';./?.lua'

-- ---------------------------------------------------------------- clock ---
local NOW = 1000.0
system = {
  uptime = function() return NOW end,
  delay = function() end,
}

-- -------------------------------------------------------------- storage ---
local STORE = {}
storage = {
  write = function(k, v) STORE[k] = v; return 0 end,
  read = function(k) if STORE[k] then return STORE[k], 0 else return nil, 1 end end,
  remove = function(k) STORE[k] = nil; return 0 end,
  err_to_str = function(e) return 'err' .. tostring(e) end,
}

-- ------------------------------------------------------------- enapter  ---
TEST_HANDLERS = {}
TEST_TELEMETRY_LOG = {}
LAST_TELEMETRY = nil
LAST_PROPERTIES = nil
VERBOSE = os.getenv('VERBOSE') == '1'

enapter = {
  register_command_handler = function(name, fn) TEST_HANDLERS[name] = fn end,
  send_telemetry = function(data)
    LAST_TELEMETRY = data
    table.insert(TEST_TELEMETRY_LOG, data)
    if VERBOSE then
      io.write(string.format(
        '[telemetry] t=%-6.1f status=%-10s test=%-12s step=%d/%d mode=%-4s V=%-7.2f I=%-7.2f P=%-8.1f out=%-5s alerts=%s\n',
        NOW, data.status, data.test_type, data.step_index, data.step_total,
        data.controller_mode, data.bus_voltage_v, data.load_current_a, data.load_power_w,
        tostring(data.output_on), table.concat(data.alerts or {}, ',')))
    end
    return 0
  end,
  send_properties = function(data) LAST_PROPERTIES = data; return 0 end,
  log = function(text, severity, persist)
    if VERBOSE then print('[log:' .. tostring(severity or 'info') .. '] ' .. text) end
  end,
  err_to_str = function(e) return 'err' .. tostring(e) end,
  get_connection_status = function() return true end,
}

-- ----------------------------------------------------------------- http ---
-- BRIDGE is the fake device: controllable canned /status, and a call log of
-- everything firmware.lua POSTs to it so we can assert on outgoing commands.
BRIDGE = {
  reachable = true,
  regatron_connected = true,
  has_errors = false,
  has_warnings = false,
  output_on = false,
  voltage_v = 46.0,
  current_a = 0.0,
  power_w = 0.0,
  last_incident = '',
  calls = {},   -- list of {method=, path=, body=}
}

local function bridge_status_json()
  BRIDGE.power_w = BRIDGE.voltage_v * BRIDGE.current_a
  return string.format(
    '{"connected":true,"regatron_connected":%s,"serial_number":"2433GV697","has_errors":%s,' ..
    '"has_warnings":%s,"output_on":%s,"controller_mode":"idle","voltage_v":%f,"current_a":%f,' ..
    '"power_w":%f,"last_incident":"%s"}',
    tostring(BRIDGE.regatron_connected), tostring(BRIDGE.has_errors), tostring(BRIDGE.has_warnings),
    tostring(BRIDGE.output_on), BRIDGE.voltage_v, BRIDGE.current_a, BRIDGE.power_w, BRIDGE.last_incident)
end

local function parse_path(url)
  return url:match('http://[^/]+(/.*)')
end

http = {
  request = function(method, url, body)
    local req = { method = method, url = url, body = body, headers = {} }
    function req:set_header(k, v) self.headers[k] = v end
    return req, nil
  end,
  client = function(opts)
    local client = {}
    function client:do_request(req)
      if not BRIDGE.reachable then
        return nil, 'connection refused (simulated)'
      end
      local path = parse_path(req.url)
      table.insert(BRIDGE.calls, { method = req.method, path = path, body = req.body })
      if path == '/status' and req.method == 'GET' then
        return { code = 200, body = bridge_status_json() }, nil
      elseif path == '/setpoint' and req.method == 'POST' then
        BRIDGE.output_on = true
        return { code = 200, body = '{}' }, nil
      elseif path == '/output' and req.method == 'POST' then
        if req.body:find('"on"') then BRIDGE.output_on = true
        elseif req.body:find('"off"') then BRIDGE.output_on = false; BRIDGE.current_a = 0 end
        return { code = 200, body = '{}' }, nil
      elseif path == '/estop' and req.method == 'POST' then
        BRIDGE.output_on = false
        BRIDGE.current_a = 0
        return { code = 200, body = '{}' }, nil
      elseif path == '/clear_errors' and req.method == 'POST' then
        BRIDGE.has_errors = false
        return { code = 200, body = '{}' }, nil
      else
        return { code = 404, body = '{"error":"not found"}' }, nil
      end
    end
    return client
  end,
}

-- ------------------------------------------------------------ scheduler ---
-- Capture jobs instead of actually running a timer; the harness advances
-- the fake clock and calls them manually so tests are deterministic.
SCHED_JOBS = {}
scheduler = {
  add = function(period_ms, fn)
    table.insert(SCHED_JOBS, { period_ms = period_ms, fn = fn })
    return #SCHED_JOBS
  end,
  remove = function(id) SCHED_JOBS[id] = nil end,
}

-- -------------------------------------------------------------------------
-- Load the real firmware under test.
dofile('../firmware.lua')

local CONTROL_JOB = SCHED_JOBS[1].fn -- poll_and_control, added first in main()

-- ------------------------------------------------------------- helpers ---
local function tick(seconds_advance)
  NOW = NOW + (seconds_advance or 1.0)
  CONTROL_JOB()
end

local function ticks(n, seconds_each)
  for _ = 1, n do tick(seconds_each) end
end

local function header(title)
  print('\n===== ' .. title .. ' =====')
end

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format('FAIL [%s]: expected %s, got %s', label, tostring(expected), tostring(actual)))
  else
    print(string.format('  ok  [%s] = %s', label, tostring(actual)))
  end
end

local function assert_true(cond, label)
  if not cond then error('FAIL [' .. label .. ']: expected true') end
  print('  ok  [' .. label .. '] true')
end

local function count_calls(path, method)
  local n = 0
  for _, c in ipairs(BRIDGE.calls) do
    if c.path == path and (method == nil or c.method == method) then n = n + 1 end
  end
  return n
end

print('=== harness loaded OK, handlers registered: ===')
local names = {}
for k in pairs(TEST_HANDLERS) do table.insert(names, k) end
table.sort(names)
print(table.concat(names, ', '))

-- =========================================================================
-- SCENARIO 1: bridge not configured yet -> setpoint commands must not crash
-- =========================================================================
header('1. Unconfigured bridge: CC command should fail gracefully, no crash')
tick(1)
assert_eq(LAST_TELEMETRY.bridge_online, false, 'bridge_online before config')
assert_eq(LAST_TELEMETRY.status, 'disconnected', 'status before config')

-- =========================================================================
-- SCENARIO 2: configure bridge + fuel cell, then run a CC test
-- =========================================================================
header('2. Configure bridge + fuel cell bank (2x FCM802 parallel, 4800W/48V)')
local ok, err = pcall(TEST_HANDLERS.configure_bridge, { log = function() end }, {
  bridge_ip = '127.0.0.1', bridge_port = 8765, bridge_token = '',
})
assert_true(ok, 'configure_bridge did not error: ' .. tostring(err))
assert_eq(LAST_PROPERTIES.bridge_address, 'http://127.0.0.1:8765', 'bridge_address property')

ok, err = pcall(TEST_HANDLERS.configure_fuel_cell, { log = function() end }, {
  fc_model = 'Intelligent Energy FCM 802', fc_units = 2, fc_wiring = 'parallel',
  fc_rated_power_w = 4800, fc_nominal_voltage_v = 48, fc_min_voltage_v = 38,
  ramp_rate_a_per_s = 5,
})
assert_true(ok, 'configure_fuel_cell did not error: ' .. tostring(err))

local errctx = { log = function() end, error = function(m) error('ctx.error: ' .. tostring(m)) end }
ok, err = pcall(TEST_HANDLERS.acknowledge_precharge, errctx, {})
assert_true(ok, 'acknowledge_precharge did not error: ' .. tostring(err))

tick(1)
assert_eq(LAST_TELEMETRY.bridge_online, true, 'bridge_online after config')
assert_eq(LAST_TELEMETRY.regatron_connected, true, 'regatron_connected after config')
assert_eq(LAST_TELEMETRY.status, 'idle', 'status after config (no test running)')
assert_eq(LAST_TELEMETRY.precharge_acknowledged, true, 'precharge_acknowledged telemetry reflects the ack')

header('2b. start_cc_test at 50% of rated (4800W/48V = 100A rated -> 50A target), 4s hold')
BRIDGE.current_a = 0
ok, err = pcall(TEST_HANDLERS.start_cc_test, errctx, {
  percent_of_rated = 50, duration_s = 4,
})
assert_true(ok, 'start_cc_test did not error: ' .. tostring(err))
assert_eq(count_calls('/output', 'POST'), 1, 'one /output ON call issued on test start')
tick(1)
assert_eq(LAST_TELEMETRY.test_type, 'cc', 'test_type == cc')

-- Ramp rate is 5 A/s, target is 25A -> should take 5 ticks to fully ramp.
-- Simulate the bridge's measured current tracking whatever we command it to
-- (a simple plant model: measured current snaps to the last /setpoint value).
local function drive_plant_from_last_setpoint()
  for i = #BRIDGE.calls, 1, -1 do
    local c = BRIDGE.calls[i]
    if c.path == '/setpoint' then
      local v = tonumber(c.body:match('"value":([%-%d%.]+)'))
      if v then BRIDGE.current_a = v end
      break
    end
  end
end

header('2c. Ramp-up ticks (5 A/s toward 50 A -> ~10 ticks)')
for k = 1, 11 do
  drive_plant_from_last_setpoint()
  tick(1)
  print(string.format('  tick %2d: setpoint=%6.2f A, measured=%6.2f A, status=%s',
    k, LAST_TELEMETRY.setpoint_value, LAST_TELEMETRY.load_current_a, LAST_TELEMETRY.status))
end
assert_true(LAST_TELEMETRY.setpoint_value >= 49.9, 'current ramped up to ~50A target')
assert_eq(LAST_TELEMETRY.status, 'holding', 'status is holding once target reached')

header('2d. Hold for dwell (4s), then expect auto-stop back to idle')
for k = 1, 6 do
  drive_plant_from_last_setpoint()
  tick(1)
end
assert_eq(LAST_TELEMETRY.test_type, 'none', 'test cleared after dwell completes')
assert_true(LAST_TELEMETRY.status == 'idle' or LAST_TELEMETRY.status == 'stopping',
  'status back to idle/stopping after test completion')
-- run a few more ticks so the ramp-down to 0 actually finishes
for k = 1, 8 do
  drive_plant_from_last_setpoint()
  tick(1)
  if LAST_TELEMETRY.status == 'idle' then break end
end
assert_eq(LAST_TELEMETRY.status, 'idle', 'status fully idle after ramp-down')
assert_eq(LAST_TELEMETRY.output_on, false, 'output off after graceful stop')

-- =========================================================================
-- SCENARIO 3: polarization sweep, 10% -> 30% step 10%, short dwell
-- =========================================================================
header('3. Polarization sweep 10%->30% step 10%, 2s dwell per point')
BRIDGE.current_a = 0
ok, err = pcall(TEST_HANDLERS.start_polarization_curve, errctx, {
  from_percent = 10, to_percent = 30, step_percent = 10, dwell_s = 2,
})
assert_true(ok, 'start_polarization_curve did not error: ' .. tostring(err))
tick(1)
assert_eq(LAST_TELEMETRY.step_total, 3, 'polarization has 3 steps (10/20/30%)')

local seen_steps = {}
for k = 1, 40 do
  drive_plant_from_last_setpoint()
  tick(1)
  seen_steps[LAST_TELEMETRY.step_index] = true
  if LAST_TELEMETRY.test_type == 'none' then break end
end
assert_true(seen_steps[1] and seen_steps[2] and seen_steps[3], 'all 3 polarization steps were visited')
assert_eq(LAST_TELEMETRY.test_type, 'none', 'polarization test auto-completed')

-- =========================================================================
-- SCENARIO 4: emergency stop mid-test
-- =========================================================================
header('4. Emergency stop mid CC-test cuts output immediately, no ramp-down wait')
BRIDGE.current_a = 0
TEST_HANDLERS.start_cc_test(errctx, { percent_of_rated = 80, duration_s = 300 })
tick(1)
drive_plant_from_last_setpoint()
tick(1)
local calls_before_estop = count_calls('/estop', 'POST')
TEST_HANDLERS.emergency_stop(errctx, {})
tick(1)
assert_eq(LAST_TELEMETRY.status, 'fault', 'status is fault immediately after e-stop')
assert_eq(count_calls('/estop', 'POST'), calls_before_estop + 1, '/estop POSTed exactly once')
local has_forced_off = false
for _, a in ipairs(LAST_TELEMETRY.alerts) do if a == 'output_forced_off' then has_forced_off = true end end
assert_true(has_forced_off, 'output_forced_off alert present')

header('4b. clear_fault brings the bench back to idle')
TEST_HANDLERS.clear_fault(errctx, {})
tick(1)
assert_eq(LAST_TELEMETRY.status, 'idle', 'status idle after clear_fault')

-- =========================================================================
-- SCENARIO 5: hardware overvoltage trip during a hold
-- =========================================================================
header('5. Software safety: overvoltage trip forces e-stop')
BRIDGE.current_a = 10
TEST_HANDLERS.start_cc_test(errctx, { percent_of_rated = 20, duration_s = 300 })
tick(1)
BRIDGE.voltage_v = 81.0 -- exceeds regatron_max_voltage_v (80V)
local calls_before = count_calls('/estop', 'POST')
tick(1)
assert_eq(LAST_TELEMETRY.status, 'fault', 'status fault on overvoltage')
assert_true(count_calls('/estop', 'POST') > calls_before, '/estop fired on overvoltage')
local has_ov = false
for _, a in ipairs(LAST_TELEMETRY.alerts) do if a == 'overvoltage' then has_ov = true end end
assert_true(has_ov, 'overvoltage alert present')
BRIDGE.voltage_v = 46.0
TEST_HANDLERS.clear_fault(errctx, {})

-- =========================================================================
-- SCENARIO 6: bridge goes unreachable mid-test -> fault after stale timeout
-- =========================================================================
header('6. Bridge goes unreachable mid-test -> fault after BRIDGE_STALE_S')
BRIDGE.current_a = 5
TEST_HANDLERS.start_cc_test(errctx, { percent_of_rated = 20, duration_s = 300 })
tick(1)
BRIDGE.reachable = false
tick(2)
tick(2)
tick(2) -- >5s stale window total
assert_eq(LAST_TELEMETRY.status, 'fault', 'status fault after bridge stale timeout')
BRIDGE.reachable = true
TEST_HANDLERS.clear_fault(errctx, {})

-- =========================================================================
-- SCENARIO 7: software CP loop holds power as bus voltage sags
-- =========================================================================
header('7. CP loop: hold 1200 W while FC voltage sags 48 V -> 42 V')
BRIDGE.current_a = 0
BRIDGE.voltage_v = 48.0
TEST_HANDLERS.start_cp_test(errctx, { power_w = 1200, duration_s = 600 })
tick(1)
assert_eq(LAST_TELEMETRY.test_type, 'cp', 'test_type == cp')
assert_eq(LAST_TELEMETRY.controller_mode, 'cc', 'CP is driven through CC mode on the bridge')

for k = 1, 12 do
  drive_plant_from_last_setpoint()
  tick(1)
end
local i_at_48 = LAST_TELEMETRY.setpoint_value
print(string.format('  at 48.0 V: setpoint=%.2f A -> %.0f W', i_at_48, i_at_48 * 48.0))
assert_true(math.abs(i_at_48 * 48.0 - 1200) < 60, 'CP holds ~1200 W at 48 V (target 25.0 A)')

-- now sag the stack voltage; the loop should raise current to keep power
BRIDGE.voltage_v = 42.0
for k = 1, 12 do
  drive_plant_from_last_setpoint()
  tick(1)
end
local i_at_42 = LAST_TELEMETRY.setpoint_value
print(string.format('  at 42.0 V: setpoint=%.2f A -> %.0f W', i_at_42, i_at_42 * 42.0))
assert_true(i_at_42 > i_at_48, 'CP loop raised current as voltage sagged')
assert_true(math.abs(i_at_42 * 42.0 - 1200) < 60, 'CP still holds ~1200 W at 42 V (target 28.6 A)')
TEST_HANDLERS.stop_test(errctx, {})
for k = 1, 12 do drive_plant_from_last_setpoint(); tick(1) end
BRIDGE.voltage_v = 46.0

-- =========================================================================
-- SCENARIO 8: fuel cell voltage floor trip (the one that protects the stack)
-- =========================================================================
header('8. Voltage floor: bus sags to 37 V (floor 38 V), qualified over 3s -> abort + output off')
BRIDGE.current_a = 0
BRIDGE.voltage_v = 46.0
TEST_HANDLERS.start_cc_test(errctx, { percent_of_rated = 40, duration_s = 600 })
tick(1)
drive_plant_from_last_setpoint()
tick(1)
BRIDGE.voltage_v = 37.0 -- below the configured 38 V floor
local estops_before = count_calls('/estop', 'POST')
tick(1)
assert_true(LAST_TELEMETRY.status ~= 'fault',
  'a brief dip below the floor does NOT trip instantly - qualification window protects against blips')
tick(1)
assert_true(LAST_TELEMETRY.status ~= 'fault', 'still not tripped partway through the 3s qualify window')
tick(3) -- now comfortably past fc_undervoltage_qualify_s (3s)
assert_eq(LAST_TELEMETRY.status, 'fault', 'status fault once the sag is sustained past the qualify window')
assert_eq(LAST_TELEMETRY.output_on, false, 'output off when voltage floor breached')
assert_true(count_calls('/estop', 'POST') > estops_before, '/estop fired on voltage floor')
local has_floor = false
for _, a in ipairs(LAST_TELEMETRY.alerts) do if a == 'fc_voltage_floor' then has_floor = true end end
assert_true(has_floor, 'fc_voltage_floor alert present')
print('  fault_reason: ' .. LAST_TELEMETRY.fault_reason)
BRIDGE.voltage_v = 46.0
TEST_HANDLERS.clear_fault(errctx, {})
tick(1)

header('8b. A brief dip that recovers before qualifying never trips at all')
BRIDGE.current_a = 0
BRIDGE.voltage_v = 46.0
TEST_HANDLERS.start_cc_test(errctx, { percent_of_rated = 40, duration_s = 600 })
tick(1)
drive_plant_from_last_setpoint()
tick(1)
BRIDGE.voltage_v = 37.0
tick(1)
tick(1) -- 2s into the dip, still under the 3s qualify window
BRIDGE.voltage_v = 46.0 -- recovers before qualifying
tick(1)
tick(1)
tick(1)
assert_true(LAST_TELEMETRY.status ~= 'fault', 'a dip that recovers before 3s never trips at all')
TEST_HANDLERS.stop_test(errctx, {})
for k = 1, 20 do drive_plant_from_last_setpoint(); tick(1); if LAST_TELEMETRY.status == 'idle' then break end end

header('8c. FC overvoltage ceiling (54V default), also qualified')
TEST_HANDLERS.configure_fuel_cell(errctx, {
  fc_model = 'Intelligent Energy FCM 802', fc_units = 2, fc_wiring = 'parallel',
  fc_rated_power_w = 4800, fc_nominal_voltage_v = 52, fc_min_voltage_v = 48,
  fc_max_voltage_v = 54, fc_overvoltage_qualify_s = 2, ramp_rate_a_per_s = 25,
})
BRIDGE.current_a = 0
BRIDGE.voltage_v = 52.0
TEST_HANDLERS.start_cc_test(errctx, { percent_of_rated = 20, duration_s = 600 })
for k = 1, 5 do drive_plant_from_last_setpoint(); tick(1) end
BRIDGE.voltage_v = 55.0 -- above the 54V FC ceiling (well under the 80V hardware one)
local estops_before_ov = count_calls('/estop', 'POST')
tick(1)
assert_true(LAST_TELEMETRY.status ~= 'fault', 'does not trip instantly - qualified over 2s')
tick(3)
assert_eq(LAST_TELEMETRY.status, 'fault', 'trips once sustained past fc_overvoltage_qualify_s')
local has_fc_ov = false
for _, a in ipairs(LAST_TELEMETRY.alerts) do if a == 'fc_overvoltage' then has_fc_ov = true end end
assert_true(has_fc_ov, 'fc_overvoltage alert present (distinct from the hardware-level overvoltage)')
assert_true(count_calls('/estop', 'POST') > estops_before_ov, '/estop fired on FC overvoltage')
BRIDGE.voltage_v = 46.0
TEST_HANDLERS.clear_fault(errctx, {})
tick(1)

header('8d. FC combined overcurrent ceiling (160A default), also qualified')
TEST_HANDLERS.configure_fuel_cell(errctx, {
  fc_model = 'Intelligent Energy FCM 802', fc_units = 2, fc_wiring = 'parallel',
  fc_rated_power_w = 4800, fc_nominal_voltage_v = 52, fc_min_voltage_v = 48,
  fc_max_current_a = 160, fc_overcurrent_qualify_s = 2, ramp_rate_a_per_s = 60,
})
BRIDGE.current_a = 0
BRIDGE.voltage_v = 52.0
TEST_HANDLERS.start_cc_test(errctx, { current_a = 100, duration_s = 600 })
for k = 1, 5 do drive_plant_from_last_setpoint(); tick(1) end
BRIDGE.current_a = 165.0 -- above the 160A FC ceiling, still well under 338A hardware
local estops_before_oc = count_calls('/estop', 'POST')
tick(1)
assert_true(LAST_TELEMETRY.status ~= 'fault', 'does not trip instantly - qualified over 2s')
tick(3)
assert_eq(LAST_TELEMETRY.status, 'fault', 'trips once sustained past fc_overcurrent_qualify_s')
local has_fc_oc = false
for _, a in ipairs(LAST_TELEMETRY.alerts) do if a == 'fc_overcurrent' then has_fc_oc = true end end
assert_true(has_fc_oc, 'fc_overcurrent alert present (distinct from the hardware-level overcurrent)')
assert_true(count_calls('/estop', 'POST') > estops_before_oc, '/estop fired on FC overcurrent')
BRIDGE.current_a = 0
TEST_HANDLERS.clear_fault(errctx, {})
tick(1)
-- restore the values the rest of the suite expects
TEST_HANDLERS.configure_fuel_cell(errctx, {
  fc_model = 'Intelligent Energy FCM 802', fc_units = 2, fc_wiring = 'parallel',
  fc_rated_power_w = 4800, fc_nominal_voltage_v = 48, fc_min_voltage_v = 38,
  fc_max_voltage_v = 54, fc_max_current_a = 160,
  fc_undervoltage_qualify_s = 3, fc_overvoltage_qualify_s = 15, fc_overcurrent_qualify_s = 3,
  ramp_rate_a_per_s = 5,
})

-- =========================================================================
-- SCENARIO 9: load step test alternates low/high for N cycles
-- =========================================================================
header('9. Load step 20%/60%, 2s dwells, 2 cycles -> 4 steps, alternating')
BRIDGE.current_a = 0
TEST_HANDLERS.start_load_step(errctx, {
  low_percent = 20, high_percent = 60, low_dwell_s = 2, high_dwell_s = 2, cycles = 2,
})
tick(1)
assert_eq(LAST_TELEMETRY.step_total, 4, 'load step has 4 steps (2 cycles x low/high)')

local step_targets = {}
for k = 1, 120 do
  drive_plant_from_last_setpoint()
  tick(1)
  local idx = LAST_TELEMETRY.step_index
  if idx > 0 and LAST_TELEMETRY.status == 'holding' or LAST_TELEMETRY.status == 'stepping' then
    step_targets[idx] = LAST_TELEMETRY.setpoint_value
  end
  if LAST_TELEMETRY.test_type == 'none' then break end
end
print(string.format('  step targets: 1=%.1fA 2=%.1fA 3=%.1fA 4=%.1fA',
  step_targets[1] or -1, step_targets[2] or -1, step_targets[3] or -1, step_targets[4] or -1))
assert_true(step_targets[2] > step_targets[1], 'step 2 (high) draws more than step 1 (low)')
assert_true(step_targets[3] < step_targets[2], 'step 3 returns to low')
assert_true(step_targets[4] > step_targets[3], 'step 4 returns to high')
assert_eq(LAST_TELEMETRY.test_type, 'none', 'load step test auto-completed')
for k = 1, 20 do drive_plant_from_last_setpoint(); tick(1); if LAST_TELEMETRY.status == 'idle' then break end end

-- =========================================================================
-- SCENARIO 10: CV test requires a current ceiling, and holds voltage
-- =========================================================================
header('10. CV test: missing current ceiling is rejected; valid one holds voltage')
local rejected = false
local strictctx = { log = function() end, error = function(m) rejected = true; error(m, 0) end }
pcall(TEST_HANDLERS.start_cv_test, strictctx, { voltage_v = 44 }) -- no ceiling
assert_true(rejected, 'start_cv_test rejects a missing current_ceiling_a')

BRIDGE.current_a = 0
BRIDGE.voltage_v = 48.0
TEST_HANDLERS.start_cv_test(errctx, { voltage_v = 44, current_ceiling_a = 60, duration_s = 3 })
tick(1)
assert_eq(LAST_TELEMETRY.test_type, 'cv', 'test_type == cv')
assert_eq(LAST_TELEMETRY.controller_mode, 'cv', 'controller_mode == cv')
assert_eq(LAST_TELEMETRY.setpoint_value, 44, 'CV setpoint is 44 V')
-- The bus is still at 48 V, so the step is commanded but NOT yet settled.
assert_eq(LAST_TELEMETRY.status, 'ramping', 'CV waits for the bus to settle before holding')
-- Now let the bus actually reach the commanded 44 V.
BRIDGE.voltage_v = 44.0
tick(1)
assert_eq(LAST_TELEMETRY.status, 'holding', 'CV holds once the measured voltage converges')
for k = 1, 8 do tick(1); if LAST_TELEMETRY.test_type == 'none' then break end end
assert_eq(LAST_TELEMETRY.test_type, 'none', 'CV test auto-completed after dwell')
BRIDGE.voltage_v = 46.0

header('10b. CV that cannot reach target (current-limited) still settles at the ceiling')
BRIDGE.voltage_v = 47.0
BRIDGE.current_a = 60.0 -- pinned at the ceiling, bus will not come down
TEST_HANDLERS.start_cv_test(errctx, { voltage_v = 40, current_ceiling_a = 60, duration_s = 2 })
tick(1)
assert_eq(LAST_TELEMETRY.status, 'holding', 'CV at the current ceiling counts as settled')
for k = 1, 8 do tick(1); if LAST_TELEMETRY.test_type == 'none' then break end end
assert_eq(LAST_TELEMETRY.test_type, 'none', 'current-limited CV test still completes')
BRIDGE.voltage_v = 46.0
BRIDGE.current_a = 0

header('10c. Total under-delivery reads as a suspected POC, then escalates to a fault')
BRIDGE.current_a = 0
BRIDGE.voltage_v = 46.0
TEST_HANDLERS.start_cc_test(errctx, { current_a = 40, duration_s = 2 })
-- Deliberately DO NOT drive the plant: measured current stays at 0 A the
-- whole time. From the detector's point of view that is indistinguishable
-- from a stuck POC, so it should back off first, then escalate to a real
-- poc_timeout fault once poc_max_duration_s (20s) passes with no recovery -
-- NOT silently "accept the point and continue" the way a merely-unreached
-- (but still substantially delivering) point would.
local saw_poc_backoff = false
local faulted_at = nil
for k = 1, 40 do
  tick(1)
  if LAST_TELEMETRY.status == 'poc_backoff' then saw_poc_backoff = true end
  if LAST_TELEMETRY.status == 'fault' then faulted_at = k; break end
end
assert_true(saw_poc_backoff, 'total shortfall is treated as a suspected POC first, not ignored')
assert_true(faulted_at ~= nil, 'it escalates to a fault after poc_max_duration_s with no recovery')
local has_timeout = false
for _, a in ipairs(LAST_TELEMETRY.alerts) do if a == 'poc_timeout' then has_timeout = true end end
assert_true(has_timeout, 'poc_timeout alert present')
print(string.format('  faulted at tick %d, reason: %s', faulted_at, LAST_TELEMETRY.fault_reason))
TEST_HANDLERS.clear_fault(errctx, {})
tick(1)

header('10d. Partial (non-POC-shaped) shortfall still uses the plain settle timeout')
-- Cell plateaus at 70% of commanded current - a real but modest limitation,
-- not the >50% cliff the POC detector looks for - so it must NOT be
-- mistaken for a POC, and must still complete via the original "accept the
-- point after 20s and move on" path rather than escalating to a fault.
BRIDGE.current_a = 0
BRIDGE.voltage_v = 46.0
TEST_HANDLERS.start_cc_test(errctx, { current_a = 20, duration_s = 2 })
local saw_poc = false
local completed = false
for k = 1, 35 do
  drive_plant_from_last_setpoint()
  BRIDGE.current_a = math.min(BRIDGE.current_a, 14.0) -- plateau at 70% of 20 A
  tick(1)
  if LAST_TELEMETRY.status == 'poc_backoff' then saw_poc = true end
  if LAST_TELEMETRY.test_type == 'none' then completed = true; break end
end
assert_true(not saw_poc, 'a 70%-of-target plateau is not mistaken for a POC')
assert_true(completed, 'the plain settle timeout still lets a close-but-unreached point complete')
for k = 1, 20 do drive_plant_from_last_setpoint(); tick(1); if LAST_TELEMETRY.status == 'idle' then break end end
BRIDGE.current_a = 0

-- =========================================================================
-- SCENARIO 11: percent-of-rated maths sanity across the board
-- =========================================================================
header('11. Percent maths: 4800 W / 48 V bank -> 100 A rated')
BRIDGE.current_a = 0
TEST_HANDLERS.stop_test(errctx, {})
for k = 1, 20 do drive_plant_from_last_setpoint(); tick(1); if LAST_TELEMETRY.status == 'idle' then break end end
TEST_HANDLERS.set_manual_cc(errctx, { percent_of_rated = 30 })
for k = 1, 12 do drive_plant_from_last_setpoint(); tick(1) end
assert_true(math.abs(LAST_TELEMETRY.setpoint_value - 30.0) < 0.1, '30% of rated = 30.0 A')
assert_eq(LAST_TELEMETRY.test_type, 'manual', 'manual jog reports test_type manual')
assert_eq(LAST_TELEMETRY.status, 'holding', 'manual jog holds indefinitely')
TEST_HANDLERS.set_manual_cp(errctx, { percent_of_rated = 25 }) -- 25% of 4800 W = 1200 W
for k = 1, 15 do drive_plant_from_last_setpoint(); tick(1) end
print(string.format('  manual CP 25%%: setpoint=%.2f A at %.1f V -> %.0f W',
  LAST_TELEMETRY.setpoint_value, LAST_TELEMETRY.bus_voltage_v,
  LAST_TELEMETRY.setpoint_value * LAST_TELEMETRY.bus_voltage_v))
assert_true(math.abs(LAST_TELEMETRY.setpoint_value * LAST_TELEMETRY.bus_voltage_v - 1200) < 60,
  'manual CP 25% holds ~1200 W')
TEST_HANDLERS.output_off(errctx, {})
for k = 1, 20 do drive_plant_from_last_setpoint(); tick(1); if LAST_TELEMETRY.status == 'idle' then break end end
assert_eq(LAST_TELEMETRY.output_on, false, 'output off after manual output_off')

-- =========================================================================
-- SCENARIO 12: config survives a firmware restart (storage round-trip)
-- =========================================================================
header('12. Config persists across restart (storage round-trip)')
assert_true(STORE['regatron_fc_config'] ~= nil, 'config was written to storage')
print('  stored: ' .. STORE['regatron_fc_config']:sub(1, 120) .. '...')
local reparsed = require('json').decode(STORE['regatron_fc_config'])
assert_eq(reparsed.fc_rated_power_w, 4800, 'persisted fc_rated_power_w')
assert_eq(reparsed.fc_min_voltage_v, 38, 'persisted fc_min_voltage_v')
assert_eq(reparsed.bridge_ip, '127.0.0.1', 'persisted bridge_ip')

-- =========================================================================
-- SCENARIO 13: a real, transient POC - dip, backoff, recovery, resume
-- =========================================================================
header('13. Transient POC during a steady hold: back off, then resume the real target')
BRIDGE.current_a = 0
BRIDGE.voltage_v = 46.0
TEST_HANDLERS.start_cc_test(errctx, { current_a = 40, duration_s = 600 })

-- Ramp up to the 40A target and let it settle into a genuine steady hold.
for k = 1, 20 do
  drive_plant_from_last_setpoint()
  tick(1)
  if LAST_TELEMETRY.status == 'holding' then break end
end
assert_eq(LAST_TELEMETRY.status, 'holding', 'reached a real steady hold before the POC hits')
assert_true(math.abs(LAST_TELEMETRY.load_current_a - 40) < 1, 'holding at ~40 A prior to the POC')

-- Now the module dips hard for a few seconds, exactly like a POC - current
-- collapses independent of anything the bench commanded.
print('  ...FCM starts a POC (current collapses independent of the bench)...')
BRIDGE.current_a = 1.5
local backoff_seen = false
for k = 1, 3 do
  tick(1) -- do NOT drive_plant_from_last_setpoint - the dip is the FCM's doing
  if LAST_TELEMETRY.status == 'poc_backoff' then backoff_seen = true end
end
assert_true(backoff_seen, 'bench status flips to poc_backoff during the dip')
local has_poc_alert = false
for _, a in ipairs(LAST_TELEMETRY.alerts) do if a == 'poc_window' then has_poc_alert = true end end
assert_true(has_poc_alert, 'poc_window alert raised')
print(string.format('  backing off, 3 ticks in: setpoint=%.1f A (ramping down from 40 at 5A/s)',
  LAST_TELEMETRY.setpoint_value))
assert_true(LAST_TELEMETRY.setpoint_value < 40, 'setpoint is already dropping toward the backoff level')

-- Give the 5A/s ramp enough ticks to actually reach the 8A backoff level
-- ((40-8)/5 = 6.4 ticks) before checking convergence - not an instant snap.
for k = 1, 10 do
  tick(1)
  if math.abs(LAST_TELEMETRY.setpoint_value - 8) < 0.5 then break end
end
print(string.format('  converged: setpoint=%.1f A (configured poc_backoff_current_a=8)',
  LAST_TELEMETRY.setpoint_value))
assert_true(LAST_TELEMETRY.setpoint_value <= 8.5, 'setpoint converges to the configured 8 A, not the original 40 A')
assert_true(LAST_TELEMETRY.load_current_a >= 0, 'measured current stays non-negative through the backoff')

-- Module recovers; current should be able to track a real command again.
print('  ...FCM recovers...')
for k = 1, 4 do
  drive_plant_from_last_setpoint()
  tick(1)
end
-- give it the confirm window plus a little
local resumed = false
for k = 1, 15 do
  drive_plant_from_last_setpoint()
  tick(1)
  if LAST_TELEMETRY.status == 'holding' and math.abs(LAST_TELEMETRY.load_current_a - 40) < 1 then
    resumed = true
    break
  end
end
assert_true(resumed, 'bench resumes ramping back to the original 40 A target and re-settles')
assert_eq(LAST_TELEMETRY.poc_event_count, 1, 'exactly one POC event recorded for this test')
assert_true(LAST_TELEMETRY.poc_last_duration_s > 0, 'a POC duration was recorded')
print(string.format('  recorded POC event: count=%d duration=%.1fs',
  LAST_TELEMETRY.poc_event_count, LAST_TELEMETRY.poc_last_duration_s))

local no_poc_alert = true
for _, a in ipairs(LAST_TELEMETRY.alerts) do if a == 'poc_window' then no_poc_alert = false end end
assert_true(no_poc_alert, 'poc_window alert cleared after recovery')

TEST_HANDLERS.stop_test(errctx, {})
for k = 1, 20 do drive_plant_from_last_setpoint(); tick(1); if LAST_TELEMETRY.status == 'idle' then break end end
BRIDGE.current_a = 0

-- =========================================================================
-- SCENARIO 14: poc_backoff_enabled = false restores the old direct behavior
-- =========================================================================
header('14. POC backoff can be disabled (real battery/PSU present on the bench)')
TEST_HANDLERS.configure_fuel_cell(errctx, {
  fc_model = 'Intelligent Energy FCM 802', fc_units = 2, fc_wiring = 'parallel',
  fc_rated_power_w = 4800, fc_nominal_voltage_v = 48, fc_min_voltage_v = 38,
  ramp_rate_a_per_s = 25, poc_backoff_enabled = false,
})
BRIDGE.current_a = 0
BRIDGE.voltage_v = 46.0
TEST_HANDLERS.start_cc_test(errctx, { current_a = 20, duration_s = 300 })
for k = 1, 10 do drive_plant_from_last_setpoint(); tick(1) end
BRIDGE.current_a = 1.0 -- would look like a POC, but backoff is now disabled
local saw_backoff_disabled_test = false
for k = 1, 5 do
  tick(1)
  if LAST_TELEMETRY.status == 'poc_backoff' then saw_backoff_disabled_test = true end
end
assert_true(not saw_backoff_disabled_test, 'with backoff disabled, the bench keeps commanding the real target through a dip')
assert_true(math.abs(LAST_TELEMETRY.setpoint_value - 20) < 0.5,
  'setpoint stays at the original 20 A target rather than backing off')
TEST_HANDLERS.stop_test(errctx, {})
for k = 1, 20 do drive_plant_from_last_setpoint(); tick(1); if LAST_TELEMETRY.status == 'idle' then break end end
-- restore defaults for anything appended after this in the future
TEST_HANDLERS.configure_fuel_cell(errctx, {
  fc_model = 'Intelligent Energy FCM 802', fc_units = 2, fc_wiring = 'parallel',
  fc_rated_power_w = 4800, fc_nominal_voltage_v = 48, fc_min_voltage_v = 38,
  ramp_rate_a_per_s = 5, poc_backoff_enabled = true,
})

-- =========================================================================
-- SCENARIO 15: probe fails once, retreats to backoff, then succeeds -
-- exactly the path that broke the old design (recovery judged against a
-- target we were no longer asking for) and the reason for the redesign.
-- =========================================================================
header('15. Multi-cycle POC: probe fails and retreats before eventually recovering')
TEST_HANDLERS.configure_fuel_cell(errctx, {
  fc_model = 'Intelligent Energy FCM 802', fc_units = 2, fc_wiring = 'parallel',
  fc_rated_power_w = 4800, fc_nominal_voltage_v = 48, fc_min_voltage_v = 38,
  ramp_rate_a_per_s = 20, poc_backoff_current_a = 8, poc_backoff_hold_s = 2,
  poc_max_duration_s = 30,
})
BRIDGE.current_a = 0
BRIDGE.voltage_v = 46.0
TEST_HANDLERS.start_cc_test(errctx, { current_a = 40, duration_s = 600 })
for k = 1, 10 do
  drive_plant_from_last_setpoint()
  tick(1)
  if LAST_TELEMETRY.status == 'holding' then break end
end
assert_eq(LAST_TELEMETRY.status, 'holding', 'reached steady hold before the POC hits')

print('  ...POC hits, bench backs off...')
BRIDGE.current_a = 1.0 -- do NOT drive the plant - module is down
local saw_backoff = false
for k = 1, 4 do
  tick(1)
  if LAST_TELEMETRY.status == 'poc_backoff' then saw_backoff = true end
end
assert_true(saw_backoff, 'entered backoff on the initial dip')

print('  ...hold elapses (2s), first probe begins, setpoint should climb...')
local saw_setpoint_climb = false
for k = 1, 5 do
  tick(1) -- still not driving the plant: the module has NOT actually recovered
  if LAST_TELEMETRY.setpoint_value > 15 then saw_setpoint_climb = true end
end
assert_true(saw_setpoint_climb, 'first probe attempt ramps the setpoint back up toward 40 A')

print('  ...module still down, probe should fail and retreat back toward 8 A...')
local saw_retreat = false
for k = 1, 6 do
  tick(1)
  if LAST_TELEMETRY.setpoint_value <= 9 then saw_retreat = true end
end
assert_true(saw_retreat, 'failed probe retreats the setpoint back down to the backoff level')
assert_eq(LAST_TELEMETRY.poc_event_count, 0, 'still mid-episode - no event counted yet after just one failed probe')
assert_eq(LAST_TELEMETRY.status, 'poc_backoff', 'still shows poc_backoff (backoff or probe are indistinguishable externally by design)')

print('  ...module genuinely recovers now...')
local recovered = false
for k = 1, 20 do
  drive_plant_from_last_setpoint()
  tick(1)
  if LAST_TELEMETRY.status == 'holding' and math.abs(LAST_TELEMETRY.load_current_a - 40) < 1 then
    recovered = true
    break
  end
end
assert_true(recovered, 'eventually recovers and resettles at the original 40 A target')
assert_eq(LAST_TELEMETRY.poc_event_count, 1, 'the whole multi-cycle episode counts as exactly ONE POC event')
print(string.format('  episode duration: %.1fs (includes the failed probe + retry)',
  LAST_TELEMETRY.poc_last_duration_s))
assert_true(LAST_TELEMETRY.poc_last_duration_s > 2, 'episode duration reflects the full multi-cycle time, not just the last successful probe')

TEST_HANDLERS.stop_test(errctx, {})
for k = 1, 20 do drive_plant_from_last_setpoint(); tick(1); if LAST_TELEMETRY.status == 'idle' then break end end
-- restore defaults for anything appended after this
TEST_HANDLERS.configure_fuel_cell(errctx, {
  fc_model = 'Intelligent Energy FCM 802', fc_units = 2, fc_wiring = 'parallel',
  fc_rated_power_w = 4800, fc_nominal_voltage_v = 48, fc_min_voltage_v = 38,
  ramp_rate_a_per_s = 5, poc_backoff_current_a = 8, poc_backoff_hold_s = 13,
  poc_max_duration_s = 20,
})

print('\n=== ALL SCENARIOS PASSED ===')

-- End-to-end integration test: the REAL firmware.lua driving a REAL
-- regatron_bridge.py over REAL HTTP (via curl), running a full polarization
-- sweep against the simulated fuel cell. No stubbed transport.
--
--   usage:  lua5.4 integration.lua <port>

package.path = package.path .. ';./?.lua'
local PORT = arg[1] or '8768'
local BASE = 'http://127.0.0.1:' .. PORT

-- ---------------------------------------------------------------- clock ---
local NOW = 0.0
system = { uptime = function() return NOW end, delay = function() end }

-- -------------------------------------------------------------- storage ---
local STORE = {}
storage = {
  write = function(k, v) STORE[k] = v; return 0 end,
  read = function(k) if STORE[k] then return STORE[k], 0 else return nil, 1 end end,
  remove = function(k) STORE[k] = nil; return 0 end,
  err_to_str = function(e) return 'err' .. tostring(e) end,
}

-- -------------------------------------------------------------- enapter ---
HANDLERS = {}
LAST_TELEMETRY = nil
enapter = {
  register_command_handler = function(n, f) HANDLERS[n] = f end,
  send_telemetry = function(d) LAST_TELEMETRY = d; return 0 end,
  send_properties = function() return 0 end,
  log = function(t, s) if os.getenv('VERBOSE') == '1' then print('[' .. tostring(s) .. '] ' .. t) end end,
  err_to_str = function(e) return 'err' .. tostring(e) end,
  get_connection_status = function() return true end,
}

-- ------------------------------------------------------------ scheduler ---
JOBS = {}
scheduler = { add = function(p, f) table.insert(JOBS, f); return #JOBS end, remove = function() end }

-- ------------------------------------------------- REAL http over curl ---
local function shell_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

http = {
  request = function(method, url, body)
    local r = { method = method, url = url, body = body, headers = {} }
    function r:set_header(k, v) self.headers[k] = v end
    return r, nil
  end,
  client = function(opts)
    local c = {}
    function c:do_request(req)
      local cmd = { 'curl -s -m 5 -w "\\n%{http_code}"' }
      table.insert(cmd, '-X ' .. req.method)
      for k, v in pairs(req.headers) do
        table.insert(cmd, '-H ' .. shell_quote(k .. ': ' .. v))
      end
      if req.body and req.body ~= '' then
        table.insert(cmd, '--data-binary ' .. shell_quote(req.body))
      end
      table.insert(cmd, shell_quote(req.url))
      local pipe = io.popen(table.concat(cmd, ' '), 'r')
      local out = pipe:read('a')
      pipe:close()
      local body, code = out:match('^(.*)\n(%d+)%s*$')
      if not code then return nil, 'curl failed: ' .. tostring(out) end
      return { code = tonumber(code), body = body }, nil
    end
    return c
  end,
}

-- -------------------------------------------------------- load firmware ---
dofile('../firmware.lua')
local TICK = JOBS[1]

local function tick(dt)
  dt = dt or 1.0
  NOW = NOW + dt
  TICK()
  -- The bridge's fast sampler now converges the plant on REAL wall-clock
  -- time (an independent 20Hz thread - see regatron_bridge.py fast_sample_
  -- loop), decoupled from however fast this test races through fake ticks.
  -- A short real sleep per tick lets it make genuine progress, same as a
  -- real deployment where Lua's poll loop runs at a real ~1Hz pace too.
  os.execute('sleep 0.2')
end

local ctx = { log = function() end, error = function(m) error(m, 0) end }

local function fail(msg) error('FAIL: ' .. msg, 0) end

print('======================================================================')
print(' END-TO-END: real firmware.lua  <--HTTP-->  real regatron_bridge.py')
print('======================================================================')

-- 1. configure -------------------------------------------------------------
HANDLERS.configure_bridge(ctx, { bridge_ip = '127.0.0.1', bridge_port = tonumber(PORT), bridge_token = '' })
HANDLERS.configure_fuel_cell(ctx, {
  fc_model = 'Intelligent Energy FCM 802', fc_units = 2, fc_wiring = 'parallel',
  fc_rated_power_w = 4800, fc_nominal_voltage_v = 48, fc_min_voltage_v = 30,
  ramp_rate_a_per_s = 25,
})
HANDLERS.acknowledge_precharge(ctx, {})
tick(1)
if not LAST_TELEMETRY.bridge_online then fail('bridge not reachable on ' .. BASE) end
print(string.format('\n[1] Bridge online. SN=%s  V_oc=%.2f V  status=%s',
  LAST_TELEMETRY.regatron_connected and 'connected' or '?',
  LAST_TELEMETRY.bus_voltage_v, LAST_TELEMETRY.status))

-- 2. polarization sweep ----------------------------------------------------
print('\n[2] Running polarization sweep 20% -> 100% in 20% steps (1s dwell)')
print('    (rated current = 4800 W / 48 V = 100 A, so % maps 1:1 to amps)')
HANDLERS.start_polarization_curve(ctx, {
  from_percent = 20, to_percent = 100, step_percent = 20, dwell_s = 5,
})

local curve = {}
local last_step = 0
for n = 1, 200 do
  tick(1)
  local t = LAST_TELEMETRY
  if t.status == 'holding' or t.status == 'stepping' then
    curve[t.step_index] = { v = t.bus_voltage_v, i = t.load_current_a, p = t.load_power_w, sp = t.setpoint_value }
  end
  if t.step_index ~= last_step and t.step_index > 0 then
    last_step = t.step_index
  end
  if t.test_type == 'none' then break end
end

print('\n    step   setpoint      V         I         P')
print('    ---------------------------------------------------')
local pts = 0
for idx = 1, 5 do
  local c = curve[idx]
  if c then
    pts = pts + 1
    print(string.format('    %2d     %6.1f A   %6.2f V  %6.2f A  %7.1f W', idx, c.sp, c.v, c.i, c.p))
  end
end
if pts < 5 then fail('expected 5 sweep points, captured ' .. pts) end

-- the physics check: voltage must fall as current rises
for idx = 2, 5 do
  if curve[idx].v >= curve[idx - 1].v then
    fail(string.format('polarization curve not monotonic at step %d (%.2f V >= %.2f V)',
      idx, curve[idx].v, curve[idx - 1].v))
  end
end
print('\n    OK: V falls monotonically as I rises - valid polarization shape.')

-- 3. shut down cleanly -----------------------------------------------------
for n = 1, 30 do
  tick(1)
  if LAST_TELEMETRY.status == 'idle' then break end
end
if LAST_TELEMETRY.output_on then fail('output still on after sweep completed') end
print(string.format('[3] Swept down and output off. status=%s output_on=%s',
  LAST_TELEMETRY.status, tostring(LAST_TELEMETRY.output_on)))

-- 4. CP hold ---------------------------------------------------------------
print('\n[4] CP test: hold 2000 W for 3 s against the real plant model')
HANDLERS.start_cp_test(ctx, { power_w = 2000, duration_s = 5 })
local best
for n = 1, 60 do
  tick(1)
  local t = LAST_TELEMETRY
  if t.status == 'holding' then best = t end
  if t.test_type == 'none' then break end
end
if not best then fail('CP test never reached holding') end
print(string.format('    held: %.2f V x %.2f A = %.0f W  (target 2000 W)',
  best.bus_voltage_v, best.load_current_a, best.load_power_w))
if math.abs(best.load_power_w - 2000) > 200 then
  fail(string.format('CP loop off target: %.0f W', best.load_power_w))
end
print('    OK: software CP loop converged on target against real measurements.')

for n = 1, 30 do tick(1); if LAST_TELEMETRY.status == 'idle' then break end end

-- 5. emergency stop --------------------------------------------------------
print('\n[5] Emergency stop over real HTTP')
HANDLERS.start_cc_test(ctx, { percent_of_rated = 60, duration_s = 300 })
tick(1); tick(1)
HANDLERS.emergency_stop(ctx, {})
tick(1)
if LAST_TELEMETRY.status ~= 'fault' then fail('status not fault after e-stop') end
if LAST_TELEMETRY.output_on then fail('output still on after e-stop') end
print(string.format('    status=%s  output_on=%s  reason="%s"',
  LAST_TELEMETRY.status, tostring(LAST_TELEMETRY.output_on), LAST_TELEMETRY.fault_reason))

HANDLERS.clear_fault(ctx, {})
tick(1)
print(string.format('[6] clear_fault -> status=%s', LAST_TELEMETRY.status))

print('\n======================================================================')
print(' END-TO-END PASSED - firmware and bridge work together over real HTTP')
print('======================================================================')

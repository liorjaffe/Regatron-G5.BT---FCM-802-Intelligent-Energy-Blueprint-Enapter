--[[
=============================================================================
  Regatron G5 Fuel Cell Load Bank - firmware.lua  (Enapter Virtual UCM)
=============================================================================
Talks to regatron_bridge.py over plain HTTP (the bridge is the only thing
that speaks the Regatron.G5.Api.dll protocol). This script owns:

  * a 1 Hz poll/control loop (bridge status in, setpoint out)
  * CC / CV / CP setpoints, plus multi-step polarization and load-step tests
  * a software safety envelope independent of the bridge's own limits
  * the Enapter Cloud telemetry / properties / command surface

Everything here is a single non-blocking tick driven by `scheduler`, because
Enapter scheduled functions get 10s max runtime each and run one at a time -
there is no room for a blocking while-loop like a desktop test script would
use. See poll_and_control() at the bottom of the state-machine section.
=============================================================================
]]--

local json = require('json')

-- =========================================================================
-- CONSTANTS
-- =========================================================================
local CONTROL_PERIOD_MS   = 1000     -- main tick: poll bridge, drive tests
local PROPERTIES_PERIOD_MS = 20000   -- slow-changing config re-announce
local HTTP_TIMEOUT_S      = 3
local BRIDGE_STALE_S      = 5.0      -- no good bridge answer for this long
                                      -- while a test is running -> fault
local REACH_TOLERANCE_A   = 0.05
local CP_TOLERANCE_A      = 0.10

-- A step is only "settled" once the MEASURED value has converged on the
-- commanded one, not merely when the commanded ramp has finished. Dwell time
-- therefore means real steady-state time at that operating point, which is
-- what a polarization curve needs - otherwise each recorded point is the
-- previous step's response and the curve is shifted by one step.
local SETTLE_FRACTION     = 0.03   -- 3% of target...
local SETTLE_MIN_A        = 0.5    -- ...but never tighter than this in amps
local SETTLE_MIN_V        = 0.3    -- ...or this in volts
local SETTLE_MIN_W        = 25.0   -- ...or this in watts
-- If the cell physically cannot reach the commanded point (starved, degraded,
-- current-limited) we must not wait forever: after this long we accept the
-- step, log it, and move on so the sweep still completes.
local SETTLE_TIMEOUT_S    = 20.0
local CONFIG_STORAGE_KEY  = 'regatron_fc_config'

-- POC (Performance Optimisation Cycle) detection/recovery tuning. Detection
-- itself is a heuristic - a sharp current dip with no setpoint change behind
-- it - because the FCM exposes no dedicated POC flag over what this bench
-- can see (Table 2: "POC must be inferred from the current signature").
local POC_DETECT_FRACTION    = 0.5   -- measured < commanded * this => suspect POC
local POC_PROBE_CONFIRM_S    = 2.0   -- probe must hold clean this long before
                                      -- declaring the episode over, not a blip

-- =========================================================================
-- STATE
-- =========================================================================
local S = {
  -- bridge connection
  bridge_ip = nil,
  bridge_port = 8765,
  bridge_token = '',

  -- identity (properties)
  regatron_model = 'G5.BT.9.80.338.M',
  regatron_serial_number = '',

  -- fuel cell bank configuration (properties)
  --
  -- Numbers below reflect the 2026-09-16 parameter brief: 2x FCM-802 (48V
  -- factory configuration) in parallel with a battery on one common 48V
  -- nominal bus; FCM regulates the bus to a Target Output Voltage of 52V.
  -- CONFIRM the installed modules' actual configuration before relying on
  -- these - "Target Output Voltage" and the thresholds below are all
  -- factory-settable and the brief itself says to verify them.
  fc_model = 'Intelligent Energy FCM 802',
  fc_units = 2,
  fc_wiring = 'parallel',
  fc_rated_power_w = 4800,      -- 2x 2.4 kW/50A per module (BOL, 25C, <1500m)
                                 -- combined 4.8kW is UNTESTED - two-module
                                 -- current sharing not yet characterized
  fc_nominal_voltage_v = 52,    -- Target Output Voltage the FCM regulates to
  fc_min_voltage_v = 48,        -- Delayed Start Under-Voltage / "abort on bus
                                 -- undervoltage <~48V sustained" per brief
  fc_undervoltage_qualify_s = 3,  -- must sag this long before it counts as
                                   -- "sustained" and trips - not an instant
                                   -- blip (POC current dips are handled
                                   -- separately below and shouldn't collapse
                                   -- bus voltage since the battery covers them)
  fc_max_voltage_v = 54,        -- Delayed Stop Over-Voltage (60s qualification
                                 -- on the FCM's own side) - trip before that
  fc_overvoltage_qualify_s = 15,  -- comfortably inside the FCM's own 60s
  fc_max_current_a = 160,       -- combined FC capability ceiling: 2 x 80A
                                 -- configured Output Current Limit per module
  fc_overcurrent_qualify_s = 3,
  low_current_warning_a = 6,    -- soft warning only: FCM enters standby
                                 -- below 4A for 20s: warn near that line
                                 -- rather than block deliberate standby tests
  ramp_rate_a_per_s = 5,

  -- Fault-qualification timer bookkeeping (not config, just state)
  fc_undervoltage_since = nil,
  fc_overvoltage_since = nil,
  fc_overcurrent_since = nil,

  -- Precharge / isolation contactor gate. NOT persisted across a restart on
  -- purpose - "precharge + isolation contactor required before connecting
  -- to live bus" (brief) is a per-session physical step, so every fresh
  -- connection to this blueprint should re-require it.
  precharge_acknowledged = false,

  -- POC (Performance Optimisation Cycle) backoff. On the deployed hybrid
  -- bus a battery covers the load while an FCM's power dips to zero for up
  -- to ~12s during its own POC (load command stays unchanged, battery
  -- covers it, <15 events/hour running, several in quick succession at
  -- startup); on a standalone bench (Regatron + FCM, no battery) nothing
  -- does that unless we make the Regatron do it. See README "Hybrid system".
  poc_backoff_enabled = true,
  poc_backoff_current_a = 8,   -- held during a suspected POC - comfortably
                                -- above the FCM-802's 4A/20s under-current
                                -- delayed-stop (standby entry) threshold
  poc_backoff_hold_s = 13,     -- how long to hold the backoff level before
                                -- probing again - just past the ~12s spec
  poc_max_duration_s = 20,     -- episode-wide: longer than this (possibly
                                -- across several backoff/probe cycles) is
                                -- NOT a normal POC - escalate to a fault
  poc_state = 'normal',        -- 'normal' | 'backoff' | 'probe'
  poc_event_count = 0,
  poc_last_duration_s = 0,
  poc_episode_started_at = 0,  -- when this POC episode first began
  poc_phase_started_at = 0,    -- when the CURRENT backoff/probe phase began
  poc_pre_backoff_target = 0,

  -- Regatron G5.BT.9.80.338 absolute hardware envelope (-9..9kW, 0..80V,
  -- -338..338A) - this blueprint only ever sinks, so we work in magnitudes.
  regatron_max_voltage_v = 80,
  regatron_max_current_a = 338,
  regatron_max_power_w = 9000,

  -- live telemetry
  --
  -- These three are what the REGATRON measures at its own sense leads - on
  -- the deployed hybrid bus that is the shared bus the load sits on, not
  -- the FCM's own terminals, and the battery can also be feeding or
  -- covering that same bus. They are the load/bus side of the system, not
  -- a direct measurement of fuel-cell output - see README "Hybrid system".
  status = 'disconnected',
  bridge_online = false,
  regatron_connected = false,
  regatron_has_errors = false,
  regatron_has_warnings = false,
  output_on = false,
  controller_mode = 'idle',
  bus_voltage_v = 0.0,
  load_current_a = 0.0,
  load_power_w = 0.0,
  setpoint_kind = 'none',
  setpoint_value = 0.0,
  fault_reason = '',
  last_incident = '',

  -- test / setpoint sequencer
  test = nil,                  -- active plan table, or nil
  test_type = 'none',
  step_index = 0,
  step_total = 0,
  test_started_at = 0,
  step_started_at = 0,
  step_hold_started_at = nil,
  step_commanded_at = nil,
  settle_warned = false,
  applied_current_a = 0.0,
  ramp_down = false,

  -- bookkeeping
  last_tick_at = nil,
  last_bridge_ok_at = 0,
  active_alerts = {},
}

-- =========================================================================
-- LOW-LEVEL HELPERS (no dependencies on anything defined below them)
-- =========================================================================

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function clamp_current(a)
  return clamp(math.abs(a or 0), 0, S.regatron_max_current_a)
end

local function clamp_voltage(v)
  return clamp(v or 0, 0, S.regatron_max_voltage_v)
end

local function resolve_voltage_floor(v)
  if v == nil then return S.fc_min_voltage_v end
  return v
end

-- Either the absolute value or a percentage may be given; absolute wins.
local function resolve_amount(percent_val, absolute_val, pct_to_abs_fn)
  if absolute_val ~= nil then
    return absolute_val
  elseif percent_val ~= nil then
    return pct_to_abs_fn(percent_val)
  end
  return nil
end

local function fc_rated_current_a()
  if S.fc_nominal_voltage_v == nil or S.fc_nominal_voltage_v <= 0 then
    return 0
  end
  return S.fc_rated_power_w / S.fc_nominal_voltage_v
end

local function pct_to_current(pct) return ((pct or 0) / 100.0) * fc_rated_current_a() end
local function pct_to_power(pct)   return ((pct or 0) / 100.0) * S.fc_rated_power_w end
local function pct_to_voltage(pct) return ((pct or 0) / 100.0) * S.fc_nominal_voltage_v end

-- Moves `current_val` toward `desired_val` by at most rate*dt per tick, so
-- current-based setpoints never jump instantly - gentler on the stack than
-- a hard step, and it doubles as the closed loop for software CP.
local function step_toward(current_val, desired_val, dt_s, rate_a_s)
  local max_delta = math.max(rate_a_s or 5, 0.01) * math.max(dt_s or 1, 0.001)
  local delta = desired_val - current_val
  if delta > max_delta then delta = max_delta end
  if delta < -max_delta then delta = -max_delta end
  return current_val + delta
end

-- ---- minimal flat JSON encoder for outgoing bridge requests --------------
-- We only ever POST small flat objects (numbers/strings/booleans, maybe one
-- array of strings), so a full encoder isn't needed and we avoid depending
-- on an unconfirmed json.encode - only json.decode is used, which is
-- confirmed to exist in the Enapter Lua runtime.
local function json_escape(s)
  s = tostring(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  return s
end

local function json_encode_flat(tbl)
  local parts = {}
  for k, v in pairs(tbl) do
    local key = '"' .. json_escape(k) .. '"'
    local val
    local t = type(v)
    if t == 'number' or t == 'boolean' then
      val = tostring(v)
    elseif t == 'table' then
      local items = {}
      for _, item in ipairs(v) do
        if type(item) == 'number' or type(item) == 'boolean' then
          table.insert(items, tostring(item))
        else
          table.insert(items, '"' .. json_escape(item) .. '"')
        end
      end
      val = '[' .. table.concat(items, ',') .. ']'
    elseif v == nil then
      val = 'null'
    else
      val = '"' .. json_escape(v) .. '"'
    end
    table.insert(parts, key .. ':' .. val)
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

-- =========================================================================
-- PERSISTENT CONFIG (storage)
-- =========================================================================

local function save_config()
  local cfg = {
    bridge_ip = S.bridge_ip,
    bridge_port = S.bridge_port,
    bridge_token = S.bridge_token,
    regatron_model = S.regatron_model,
    regatron_serial_number = S.regatron_serial_number,
    fc_model = S.fc_model,
    fc_units = S.fc_units,
    fc_wiring = S.fc_wiring,
    fc_rated_power_w = S.fc_rated_power_w,
    fc_nominal_voltage_v = S.fc_nominal_voltage_v,
    fc_min_voltage_v = S.fc_min_voltage_v,
    fc_undervoltage_qualify_s = S.fc_undervoltage_qualify_s,
    fc_max_voltage_v = S.fc_max_voltage_v,
    fc_overvoltage_qualify_s = S.fc_overvoltage_qualify_s,
    fc_max_current_a = S.fc_max_current_a,
    fc_overcurrent_qualify_s = S.fc_overcurrent_qualify_s,
    low_current_warning_a = S.low_current_warning_a,
    ramp_rate_a_per_s = S.ramp_rate_a_per_s,
    poc_backoff_enabled = S.poc_backoff_enabled,
    poc_backoff_current_a = S.poc_backoff_current_a,
    poc_backoff_hold_s = S.poc_backoff_hold_s,
    poc_max_duration_s = S.poc_max_duration_s,
  }
  local res = storage.write(CONFIG_STORAGE_KEY, json_encode_flat(cfg))
  if res ~= 0 then
    enapter.log('storage.write failed: ' .. storage.err_to_str(res), 'warning')
  end
end

local function load_config()
  local value, res = storage.read(CONFIG_STORAGE_KEY)
  if res ~= 0 or value == nil then
    return
  end
  local ok, decoded = pcall(json.decode, value)
  if not ok or type(decoded) ~= 'table' then
    enapter.log('stored config could not be parsed, using defaults', 'warning')
    return
  end
  for k, v in pairs(decoded) do
    S[k] = v
  end
end

-- =========================================================================
-- ALERTS  (the `alerts` telemetry attribute is implicit - array of strings)
-- =========================================================================

local function add_alert(name)
  S.active_alerts[name] = true
end

local function clear_alert(name)
  S.active_alerts[name] = nil
end

local function alerts_list()
  local list = {}
  for name, _ in pairs(S.active_alerts) do
    table.insert(list, name)
  end
  return list
end

-- =========================================================================
-- BRIDGE HTTP CLIENT
-- =========================================================================

local function bridge_address()
  if S.bridge_ip == nil or S.bridge_ip == '' then return '' end
  return 'http://' .. S.bridge_ip .. ':' .. tostring(S.bridge_port)
end

local function bridge_request(method, path, body_str)
  if S.bridge_ip == nil or S.bridge_ip == '' then
    return nil, 'bridge not configured - run Configure Bridge first'
  end
  local url = bridge_address() .. path
  local req, rerr = http.request(method, url, body_str or '')
  if rerr then
    return nil, 'could not build request: ' .. tostring(rerr)
  end
  req:set_header('Content-Type', 'application/json')
  if S.bridge_token ~= nil and S.bridge_token ~= '' then
    req:set_header('Authorization', 'Bearer ' .. S.bridge_token)
  end
  local client = http.client({ timeout = HTTP_TIMEOUT_S })
  local resp, err = client:do_request(req)
  if err then
    return nil, err
  end
  if resp.code ~= 200 then
    return nil, 'HTTP ' .. tostring(resp.code) .. ': ' .. tostring(resp.body)
  end
  if resp.body == nil or resp.body == '' then
    return {}, nil
  end
  local ok, decoded = pcall(json.decode, resp.body)
  if not ok then
    return nil, 'bad JSON from bridge'
  end
  return decoded, nil
end

local function bridge_get(path)
  return bridge_request('GET', path, '')
end

local function bridge_post(path, tbl)
  return bridge_request('POST', path, json_encode_flat(tbl or {}))
end

-- =========================================================================
-- SETPOINT APPLICATION
-- =========================================================================

-- Commands the Regatron output and mirrors the new state locally right away,
-- so telemetry published at the end of this same tick isn't a tick stale.
local function command_output(state)
  local _, err = bridge_post('/output', { state = state })
  if err then
    enapter.log('output ' .. state .. ' post failed: ' .. tostring(err), 'warning')
    return false
  end
  S.output_on = (state == 'on')
  return true
end

local function apply_cc_setpoint(target_a, voltage_floor)
  target_a = clamp_current(target_a)
  voltage_floor = clamp_voltage(resolve_voltage_floor(voltage_floor))
  local _, err = bridge_post('/setpoint', { mode = 'cc', value = target_a, limit = voltage_floor })
  if err then
    enapter.log('CC setpoint post failed: ' .. tostring(err), 'warning')
    return false
  end
  S.setpoint_kind = 'current_a'
  S.setpoint_value = target_a
  S.controller_mode = 'cc'
  return true
end

local function apply_cv_setpoint(target_v, current_ceiling)
  target_v = clamp_voltage(target_v)
  current_ceiling = clamp_current(current_ceiling)
  local _, err = bridge_post('/setpoint', { mode = 'cv', value = target_v, limit = current_ceiling })
  if err then
    enapter.log('CV setpoint post failed: ' .. tostring(err), 'warning')
    return false
  end
  S.setpoint_kind = 'voltage_v'
  S.setpoint_value = target_v
  S.controller_mode = 'cv'
  return true
end

-- =========================================================================
-- FAULT / STOP HANDLING
-- =========================================================================

-- Immediate, no ramp - used for hardware safety trips and manual E-stop.
local function trigger_estop(reason)
  S.test = nil
  S.test_type = 'none'
  S.step_index = 0
  S.step_total = 0
  S.ramp_down = false
  S.applied_current_a = 0
  S.setpoint_kind = 'none'
  S.controller_mode = 'idle'
  S.status = 'fault'
  S.fault_reason = reason or ''
  S.poc_state = 'normal'
  clear_alert('poc_window')
  add_alert('output_forced_off')
  bridge_post('/estop', { reason = reason or 'emergency stop' })
  S.output_on = false
  enapter.log('EMERGENCY STOP: ' .. tostring(reason), 'error', true)
end

local function trigger_fault(alert_name, reason)
  add_alert(alert_name)
  trigger_estop(reason)
end

-- Graceful stop: ramp current to zero first if we were current-controlled,
-- otherwise (CV, or already idle) just cut the output directly.
local function stop_test_gracefully(reason)
  enapter.log('Stopping: ' .. tostring(reason), 'info', true)
  S.test = nil
  S.test_type = 'none'
  S.step_index = 0
  S.step_total = 0
  S.step_hold_started_at = nil
  if S.controller_mode == 'cc' and math.abs(S.applied_current_a or 0) > 0.01 then
    S.status = 'stopping'
    S.ramp_down = true
  else
    command_output('off')
    S.setpoint_kind = 'none'
    S.controller_mode = 'idle'
    S.status = 'idle'
    S.ramp_down = false
  end
end

-- =========================================================================
-- TEST / SETPOINT SEQUENCER
--
-- Every "start_*" command (manual jog, timed CC/CV/CP hold, polarization
-- sweep, load step) builds a plan of {mode, target, dwell_s} steps and hands
-- it to start_test(). Manual jogs are just a one-step plan with dwell_s =
-- math.huge, so a single engine drives everything below.
-- =========================================================================

local function begin_step(test, now)
  local step = test.steps[test.index]
  S.step_index = test.index
  S.step_started_at = now
  S.step_commanded_at = nil
  S.settle_warned = false
  if step.mode == 'cv' then
    -- CV has no ramp phase of its own - dwell starts immediately.
    S.step_hold_started_at = now
  else
    S.step_hold_started_at = nil -- set once the ramp/CP loop converges
  end
end

local function start_test(kind, steps, voltage_floor)
  local now = system.uptime()
  S.test = { kind = kind, steps = steps, index = 1, voltage_floor = voltage_floor or S.fc_min_voltage_v }
  S.test_type = kind
  S.step_total = #steps
  S.test_started_at = now
  S.ramp_down = false
  S.poc_state = 'normal'
  S.poc_event_count = 0
  S.poc_last_duration_s = 0
  clear_alert('output_forced_off')
  clear_alert('poc_window')
  if S.status == 'fault' then
    S.status = 'idle'
    S.fault_reason = ''
  end

  local first = steps[1]
  if first.mode == 'cc' or first.mode == 'cp' then
    S.applied_current_a = 0
    apply_cc_setpoint(0, S.test.voltage_floor)
  end
  command_output('on')
  begin_step(S.test, now)
  S.status = 'ramping'
  enapter.log('Started ' .. kind .. ' (' .. tostring(#steps) .. ' step(s))', 'info', true)
end

local function settle_band(target, fraction, minimum)
  local band = math.abs(target) * fraction
  if band < minimum then band = minimum end
  return band
end

-- Bench-side substitute for the battery that covers the load on the real
-- hybrid bus while an FCM's own POC is in progress. Given the current
-- (cc/cp) target this tick would otherwise be commanding, returns the
-- current to actually command, plus a "give up, escalate" flag.
--
-- Recovery can't be judged by "has measured current climbed back up",
-- because we deliberately stop asking for much current while backing off -
-- it would never climb on its own. So this holds the reduced current for
-- poc_backoff_hold_s, then PROBES by resuming the real target; if the FCM
-- still can't deliver, the shortfall shows up again immediately and it
-- retreats back to backoff (poc_event_count only increments once the whole
-- episode - possibly several backoff/probe cycles - clears, matching "one
-- POC" from an operator's point of view even if the FCM is still stumbling
-- through startup, where the brief says several can happen in quick
-- succession).
--
-- Returns (effective_target_a, escalate_to_fault)
local function apply_poc_backoff(nominal_target, now)
  if not S.poc_backoff_enabled then
    S.poc_state = 'normal'
    return nominal_target, false
  end

  local measured = math.abs(S.load_current_a or 0)
  local applied = S.applied_current_a or 0
  local shortfall = applied > 1.0 and measured < applied * POC_DETECT_FRACTION

  if S.poc_state == 'normal' or S.poc_state == nil then
    if not shortfall then
      return nominal_target, false
    end
    S.poc_state = 'backoff'
    S.poc_episode_started_at = now
    S.poc_phase_started_at = now
    S.poc_pre_backoff_target = nominal_target
    add_alert('poc_window')
    enapter.log(string.format(
      'POC suspected (commanded %.1f A, measured %.1f A) - backing the load off to ' ..
      '%.1f A. No battery on this bench to cover it the way the deployed hybrid bus ' ..
      'would - see README "Hybrid system".', applied, measured, S.poc_backoff_current_a),
      'info', true)
  end

  -- Episode-wide timeout spans any internal backoff/probe cycling below -
  -- far longer than this is not a normal POC (~12s spec) - escalate.
  if (now - S.poc_episode_started_at) > S.poc_max_duration_s then
    S.poc_state = 'normal'
    return nil, true
  end

  if S.poc_state == 'backoff' then
    if (now - S.poc_phase_started_at) >= S.poc_backoff_hold_s then
      S.poc_state = 'probe'
      S.poc_phase_started_at = now
      enapter.log('POC backoff hold elapsed - probing whether the real target is deliverable again',
        'info', true)
      return nominal_target, false
    end
    return math.min(S.poc_backoff_current_a, nominal_target), false
  end

  -- S.poc_state == 'probe': ask for the real target again. If the FCM is
  -- still down, the shortfall reappears almost immediately as current ramps
  -- up past what it can actually supply - retreat back to backoff rather
  -- than waiting out a fixed confirm window while over-drawing a stack that
  -- has not recovered.
  if shortfall and (now - S.poc_phase_started_at) > 0.5 then
    S.poc_state = 'backoff'
    S.poc_phase_started_at = now
    return math.min(S.poc_backoff_current_a, nominal_target), false
  end
  if (now - S.poc_phase_started_at) >= POC_PROBE_CONFIRM_S then
    S.poc_state = 'normal'
    S.poc_event_count = (S.poc_event_count or 0) + 1
    S.poc_last_duration_s = now - S.poc_episode_started_at
    clear_alert('poc_window')
    enapter.log(string.format('POC cleared after %.1fs total - resuming the %.1f A target',
      S.poc_last_duration_s, S.poc_pre_backoff_target), 'info', true)
  end
  return nominal_target, false
end

local function poc_in_progress()
  return S.poc_state == 'backoff' or S.poc_state == 'probe'
end

local function advance_test(now, dt)
  local test = S.test
  if test == nil then return end
  local step = test.steps[test.index]

  local commanded = false   -- the setpoint ramp has arrived at the target
  local settled = false     -- the MEASURED value has converged on it too

  if step.mode == 'cc' then
    local effective, poc_escalate = apply_poc_backoff(step.target_a, now)
    if poc_escalate then
      trigger_fault('poc_timeout', string.format(
        'no recovery within %.0fs of a suspected POC - treating as a real fault, not a normal POC',
        S.poc_max_duration_s))
      return
    end
    S.applied_current_a = step_toward(S.applied_current_a or 0, effective, dt, S.ramp_rate_a_per_s)
    apply_cc_setpoint(S.applied_current_a, test.voltage_floor)
    commanded = math.abs(S.applied_current_a - effective) < REACH_TOLERANCE_A
    settled = commanded and not poc_in_progress() and
      math.abs(S.load_current_a - step.target_a) <= settle_band(step.target_a, SETTLE_FRACTION, SETTLE_MIN_A)

  elseif step.mode == 'cv' then
    apply_cv_setpoint(step.target_v, step.current_ceiling)
    commanded = true
    -- Either the bus has reached the commanded voltage, or we are sitting on
    -- the current ceiling and physically cannot pull it any lower. Both are
    -- legitimate steady states for a CV step. (POC backoff does not apply to
    -- CV - see README: use CC/CP for automated sequences, CV sparingly.)
    local at_voltage = math.abs(S.bus_voltage_v - step.target_v) <=
      settle_band(step.target_v, SETTLE_FRACTION, SETTLE_MIN_V)
    local at_ceiling = step.current_ceiling > 0 and
      S.load_current_a >= step.current_ceiling * 0.98
    settled = at_voltage or at_ceiling

  elseif step.mode == 'cp' then
    local v = math.max(S.bus_voltage_v, 1.0)
    local desired_i = step.target_w / v
    local effective, poc_escalate = apply_poc_backoff(desired_i, now)
    if poc_escalate then
      trigger_fault('poc_timeout', string.format(
        'no recovery within %.0fs of a suspected POC - treating as a real fault, not a normal POC',
        S.poc_max_duration_s))
      return
    end
    S.applied_current_a = step_toward(S.applied_current_a or 0, effective, dt, S.ramp_rate_a_per_s)
    apply_cc_setpoint(S.applied_current_a, test.voltage_floor)
    commanded = math.abs(S.applied_current_a - effective) < CP_TOLERANCE_A
    -- For CP the thing that must converge is POWER, not current: the current
    -- target legitimately keeps moving as the stack voltage sags.
    settled = commanded and not poc_in_progress() and
      math.abs(S.load_power_w - step.target_w) <= settle_band(step.target_w, SETTLE_FRACTION, SETTLE_MIN_W)
  end

  -- Track how long we have been waiting for the measurement to catch up, so a
  -- point the cell simply cannot deliver doesn't stall the whole sweep.
  if commanded then
    if S.step_commanded_at == nil then S.step_commanded_at = now end
  else
    S.step_commanded_at = nil
  end

  local settle_timed_out = false
  if commanded and not settled and not poc_in_progress() and S.step_commanded_at ~= nil then
    if (now - S.step_commanded_at) >= SETTLE_TIMEOUT_S then
      settle_timed_out = true
      if not S.settle_warned then
        enapter.log(string.format(
          'step %d did not settle within %ds (measured %.2f V / %.2f A / %.0f W) - ' ..
          'accepting the point and continuing', test.index, SETTLE_TIMEOUT_S,
          S.bus_voltage_v, S.load_current_a, S.load_power_w), 'warning', true)
        S.settle_warned = true
      end
    end
  end

  local holding = settled or settle_timed_out

  if poc_in_progress() and step.mode ~= 'cv' then
    S.status = 'poc_backoff'
  elseif step.mode == 'cv' then
    S.status = holding and 'holding' or 'ramping'
  else
    if not commanded then
      S.status = 'ramping'
    elseif not holding then
      S.status = 'ramping'   -- commanded, still waiting on the cell to settle
    else
      S.status = (S.step_total > 1) and 'stepping' or 'holding'
    end
  end

  if holding then
    if S.step_hold_started_at == nil then
      S.step_hold_started_at = now
    end
    if (now - S.step_hold_started_at) >= step.dwell_s then
      test.index = test.index + 1
      if test.index > #test.steps then
        stop_test_gracefully('test completed')
        return
      end
      begin_step(test, now)
    end
  else
    S.step_hold_started_at = nil
  end
end

-- =========================================================================
-- SAFETY
-- =========================================================================

-- Keeps `status` honest as disconnected/idle whenever nothing else (a test,
-- a ramp-down, or a latched fault) already owns it.
local function update_connectivity_status()
  if S.status == 'fault' or S.ramp_down or S.test ~= nil then
    return
  end
  if S.bridge_online and S.regatron_connected then
    S.status = 'idle'
  else
    S.status = 'disconnected'
  end
end

-- Returns true once `condition` has been continuously true for at least
-- `qualify_s`, tracking the start time in S[since_field]. A brief transient
-- or measurement blip never trips anything - it only fires once the
-- condition has genuinely persisted.
local function qualified(condition, since_field, qualify_s, now)
  if not condition then
    S[since_field] = nil
    return false
  end
  if S[since_field] == nil then
    S[since_field] = now
  end
  return (now - S[since_field]) >= qualify_s
end

local function safety_check(now)
  local v, i, p = S.bus_voltage_v, S.load_current_a, S.load_power_w

  -- Outermost backstop: the Regatron's own absolute hardware envelope
  -- (-9..9kW, 0..80V, -338..338A). Instant trip, no qualification - this is
  -- the last line of defense regardless of what the FC-specific config says.
  if v >= S.regatron_max_voltage_v then
    trigger_fault('overvoltage', string.format(
      'bus voltage %.2f V >= Regatron hardware max %.2f V', v, S.regatron_max_voltage_v))
    return
  end
  if math.abs(i) >= S.regatron_max_current_a * 1.02 then
    trigger_fault('overcurrent', string.format(
      'bus current %.2f A >= Regatron hardware max %.2f A', i, S.regatron_max_current_a))
    return
  end
  if math.abs(p) >= S.regatron_max_power_w * 1.02 then
    trigger_fault('overpower', string.format(
      'bus power %.1f W >= Regatron hardware max %.1f W', p, S.regatron_max_power_w))
    return
  end

  -- FC-specific envelope (2026-09-16 parameter brief), only meaningful while
  -- actually testing/energized. Qualified rather than instant, so a brief
  -- transient doesn't abort an otherwise-fine test - a real POC current dip
  -- is handled separately by the backoff logic and shouldn't collapse bus
  -- voltage, since the battery covers it on the deployed hybrid bus.
  if S.test ~= nil then
    if qualified(v > 0 and v <= S.fc_min_voltage_v, 'fc_undervoltage_since',
                 S.fc_undervoltage_qualify_s, now) then
      trigger_fault('fc_voltage_floor', string.format(
        'bus voltage %.2f V <= %.2f V for >=%.0fs (sustained undervoltage)',
        v, S.fc_min_voltage_v, S.fc_undervoltage_qualify_s))
      return
    end
    if qualified(v >= S.fc_max_voltage_v, 'fc_overvoltage_since',
                 S.fc_overvoltage_qualify_s, now) then
      trigger_fault('fc_overvoltage', string.format(
        "bus voltage %.2f V >= %.2f V for >=%.0fs (ahead of the FCM's own 60s stop)",
        v, S.fc_max_voltage_v, S.fc_overvoltage_qualify_s))
      return
    end
    if qualified(math.abs(i) >= S.fc_max_current_a, 'fc_overcurrent_since',
                 S.fc_overcurrent_qualify_s, now) then
      trigger_fault('fc_overcurrent', string.format(
        'load current %.2f A >= combined FC capability ceiling %.2f A for >=%.0fs',
        i, S.fc_max_current_a, S.fc_overcurrent_qualify_s))
      return
    end
  else
    S.fc_undervoltage_since = nil
    S.fc_overvoltage_since = nil
    S.fc_overcurrent_since = nil
  end

  if S.regatron_has_errors then
    add_alert('regatron_incident')
  else
    clear_alert('regatron_incident')
  end
end

-- =========================================================================
-- TELEMETRY / PROPERTIES
-- =========================================================================

local function send_properties_now()
  local result = enapter.send_properties({
    regatron_model = S.regatron_model,
    regatron_serial_number = S.regatron_serial_number,
    bridge_address = bridge_address(),
    fc_model = S.fc_model,
    fc_units = S.fc_units,
    fc_wiring = S.fc_wiring,
    fc_rated_power_w = S.fc_rated_power_w,
    fc_nominal_voltage_v = S.fc_nominal_voltage_v,
    fc_min_voltage_v = S.fc_min_voltage_v,
    fc_max_voltage_v = S.fc_max_voltage_v,
    fc_max_current_a = S.fc_max_current_a,
    ramp_rate_a_per_s = S.ramp_rate_a_per_s,
    poc_backoff_enabled = S.poc_backoff_enabled,
    poc_backoff_current_a = S.poc_backoff_current_a,
    poc_max_duration_s = S.poc_max_duration_s,
  })
  if result ~= 0 then
    enapter.log('send_properties failed: ' .. enapter.err_to_str(result), 'debug')
  end
end

local function send_telemetry_now()
  local now = system.uptime()
  local result = enapter.send_telemetry({
    status = S.status,
    bridge_online = S.bridge_online,
    regatron_connected = S.regatron_connected,
    regatron_has_errors = S.regatron_has_errors,
    regatron_has_warnings = S.regatron_has_warnings,
    output_on = S.output_on,
    controller_mode = S.controller_mode,
    precharge_acknowledged = S.precharge_acknowledged,
    bus_voltage_v = S.bus_voltage_v,
    load_current_a = S.load_current_a,
    load_power_w = S.load_power_w,
    setpoint_kind = S.setpoint_kind,
    setpoint_value = S.setpoint_value,
    test_type = S.test_type,
    step_index = S.step_index,
    step_total = S.step_total,
    step_elapsed_s = (S.test ~= nil) and (now - S.step_started_at) or 0,
    test_elapsed_s = (S.test ~= nil) and (now - S.test_started_at) or 0,
    fault_reason = S.fault_reason or '',
    last_incident = S.last_incident or '',
    poc_active = poc_in_progress(),
    poc_event_count = S.poc_event_count,
    poc_last_duration_s = S.poc_last_duration_s,
    alerts = alerts_list(),
  })
  if result ~= 0 then
    enapter.log('send_telemetry failed: ' .. enapter.err_to_str(result), 'debug')
  end
end

-- =========================================================================
-- MAIN TICK
-- =========================================================================

local function poll_and_control()
  local now = system.uptime()
  local dt = S.last_tick_at and (now - S.last_tick_at) or (CONTROL_PERIOD_MS / 1000)
  if dt <= 0 then dt = CONTROL_PERIOD_MS / 1000 end
  S.last_tick_at = now

  local data, err = bridge_get('/status')
  if err then
    S.bridge_online = false
    add_alert('bridge_unreachable')
    if S.test ~= nil and (now - (S.last_bridge_ok_at or 0)) > BRIDGE_STALE_S then
      trigger_fault('bridge_unreachable',
        'bridge unreachable for >' .. tostring(BRIDGE_STALE_S) .. 's during an active test: ' .. tostring(err))
    end
  else
    S.bridge_online = true
    clear_alert('bridge_unreachable')
    S.last_bridge_ok_at = now
    S.regatron_connected = data.regatron_connected and true or false
    S.regatron_has_errors = data.has_errors and true or false
    S.regatron_has_warnings = data.has_warnings and true or false
    S.output_on = data.output_on and true or false
    S.bus_voltage_v = tonumber(data.voltage_v) or 0
    S.load_current_a = tonumber(data.current_a) or 0
    S.load_power_w = tonumber(data.power_w) or (S.bus_voltage_v * S.load_current_a)
    S.last_incident = data.last_incident or ''
    if data.serial_number and data.serial_number ~= '' and data.serial_number ~= S.regatron_serial_number then
      S.regatron_serial_number = data.serial_number
    end
  end

  update_connectivity_status()
  if S.bridge_online then
    safety_check(now)
  end

  if S.ramp_down then
    S.applied_current_a = step_toward(S.applied_current_a or 0, 0, dt, S.ramp_rate_a_per_s)
    apply_cc_setpoint(S.applied_current_a, 0)
    if math.abs(S.applied_current_a) < 0.1 then
      command_output('off')
      S.ramp_down = false
      S.setpoint_kind = 'none'
      S.controller_mode = 'idle'
      if S.status ~= 'fault' then S.status = 'idle' end
    end
  elseif S.test ~= nil then
    advance_test(now, dt)
  end

  send_telemetry_now()
end

-- =========================================================================
-- COMMAND HANDLERS
-- =========================================================================

-- "Precharge + isolation contactor required before connecting to live bus"
-- (brief) is a per-session physical step, not something software can verify
-- actually happened - this just makes sure it was consciously acknowledged
-- before any command that would energize the load, once per blueprint
-- session (S.precharge_acknowledged is deliberately not persisted).
local function require_precharge(ctx)
  if not S.precharge_acknowledged then
    ctx.error('Precharge / isolation contactor not acknowledged this session - ' ..
      'run "Acknowledge Precharge Complete" first (Safety group).')
  end
end

-- Soft warning only - never blocks. FCM-802 enters standby below 4A for
-- 20s; deliberately testing that boundary is a legitimate use case, so this
-- just flags it rather than refusing the command.
local function warn_if_low_current(ctx, target_a)
  if target_a ~= nil and target_a > 0 and target_a < S.low_current_warning_a then
    ctx.log(string.format(
      'target %.1f A is below the low-current warning line (%.1f A) - the FCM-802 ' ..
      'enters standby under 4A for 20s. Fine if that is what you are testing.',
      target_a, S.low_current_warning_a), 'warning')
  end
end

local function acknowledge_precharge_command(ctx, args)
  S.precharge_acknowledged = true
  ctx.log('Precharge / isolation contactor acknowledged for this session.')
end

local function emergency_stop_command(ctx, args)
  trigger_estop('manual emergency stop command')
end

local function clear_fault_command(ctx, args)
  for name, _ in pairs(S.active_alerts) do
    if name ~= 'poc_window' then
      clear_alert(name)
    end
  end
  bridge_post('/clear_errors', {})
  S.fault_reason = ''
  if S.bridge_online and S.regatron_connected then
    S.status = 'idle'
  end
  ctx.log('Fault cleared, Regatron errors acknowledged.')
end

local function set_manual_cc_command(ctx, args)
  require_precharge(ctx)
  local target = resolve_amount(args.percent_of_rated, args.current_a, pct_to_current)
  if target == nil then ctx.error('give percent_of_rated or current_a') end
  warn_if_low_current(ctx, target)
  local floor = resolve_voltage_floor(args.voltage_floor_v)
  start_test('manual', { { mode = 'cc', target_a = target, dwell_s = math.huge } }, floor)
end

local function set_manual_cv_command(ctx, args)
  require_precharge(ctx)
  local target = resolve_amount(args.percent_of_nominal, args.voltage_v, pct_to_voltage)
  if target == nil then ctx.error('give percent_of_nominal or voltage_v') end
  if args.current_ceiling_a == nil then ctx.error('current_ceiling_a is required') end
  start_test('manual',
    { { mode = 'cv', target_v = target, current_ceiling = args.current_ceiling_a, dwell_s = math.huge } },
    S.fc_min_voltage_v)
end

local function set_manual_cp_command(ctx, args)
  require_precharge(ctx)
  local target = resolve_amount(args.percent_of_rated, args.power_w, pct_to_power)
  if target == nil then ctx.error('give percent_of_rated or power_w') end
  local floor = resolve_voltage_floor(args.voltage_floor_v)
  start_test('manual', { { mode = 'cp', target_w = target, dwell_s = math.huge } }, floor)
end

local function output_off_command(ctx, args)
  stop_test_gracefully('manual output off command')
end

local function start_cc_test_command(ctx, args)
  require_precharge(ctx)
  local target = resolve_amount(args.percent_of_rated, args.current_a, pct_to_current)
  if target == nil then ctx.error('give percent_of_rated or current_a') end
  warn_if_low_current(ctx, target)
  local floor = resolve_voltage_floor(args.voltage_floor_v)
  start_test('cc', { { mode = 'cc', target_a = target, dwell_s = args.duration_s or 300 } }, floor)
end

local function start_cv_test_command(ctx, args)
  require_precharge(ctx)
  local target = resolve_amount(args.percent_of_nominal, args.voltage_v, pct_to_voltage)
  if target == nil then ctx.error('give percent_of_nominal or voltage_v') end
  if args.current_ceiling_a == nil then ctx.error('current_ceiling_a is required') end
  start_test('cv',
    { { mode = 'cv', target_v = target, current_ceiling = args.current_ceiling_a, dwell_s = args.duration_s or 300 } },
    S.fc_min_voltage_v)
end

local function start_cp_test_command(ctx, args)
  require_precharge(ctx)
  local target = resolve_amount(args.percent_of_rated, args.power_w, pct_to_power)
  if target == nil then ctx.error('give percent_of_rated or power_w') end
  local floor = resolve_voltage_floor(args.voltage_floor_v)
  start_test('cp', { { mode = 'cp', target_w = target, dwell_s = args.duration_s or 300 } }, floor)
end

local function start_polarization_curve_command(ctx, args)
  require_precharge(ctx)
  local from_p = args.from_percent or 10
  local to_p = args.to_percent or 100
  local step_p = math.abs(args.step_percent or 10)
  local dwell = args.dwell_s or 90
  local floor = resolve_voltage_floor(args.voltage_floor_v)
  if step_p <= 0 then ctx.error('step_percent must be > 0') end
  warn_if_low_current(ctx, pct_to_current(math.min(from_p, to_p)))

  local ascending = {}
  if from_p <= to_p then
    local p = from_p
    while p <= to_p + 0.001 do
      table.insert(ascending, { mode = 'cc', target_a = pct_to_current(p), dwell_s = dwell })
      p = p + step_p
    end
  else
    local p = from_p
    while p >= to_p - 0.001 do
      table.insert(ascending, { mode = 'cc', target_a = pct_to_current(p), dwell_s = dwell })
      p = p - step_p
    end
  end
  if #ascending == 0 then ctx.error('no steps generated - check from/to/step percent') end

  local steps = ascending
  -- "sweep up AND down (check hysteresis near limits)" - brief. Mirror the
  -- same points back in reverse order (skipping the shared turning point so
  -- it isn't dwelled on twice) so one command captures both directions on
  -- one common timebase, ready to compare against each other.
  if args.round_trip then
    steps = {}
    for idx = 1, #ascending do table.insert(steps, ascending[idx]) end
    for idx = #ascending - 1, 1, -1 do table.insert(steps, ascending[idx]) end
  end

  start_test('polarization', steps, floor)
end

local function start_load_step_command(ctx, args)
  require_precharge(ctx)
  local low_p = args.low_percent or 20
  local high_p = args.high_percent or 80
  local low_dwell = args.low_dwell_s or 60
  local high_dwell = args.high_dwell_s or 60
  local cycles = args.cycles or 5
  local floor = resolve_voltage_floor(args.voltage_floor_v)
  warn_if_low_current(ctx, pct_to_current(low_p))

  local steps = {}
  for _ = 1, cycles do
    table.insert(steps, { mode = 'cc', target_a = pct_to_current(low_p), dwell_s = low_dwell })
    table.insert(steps, { mode = 'cc', target_a = pct_to_current(high_p), dwell_s = high_dwell })
  end
  start_test('load_step', steps, floor)
end

local function stop_test_command(ctx, args)
  stop_test_gracefully('user requested stop')
end

local function configure_bridge_command(ctx, args)
  S.bridge_ip = args.bridge_ip
  S.bridge_port = args.bridge_port or 8765
  S.bridge_token = args.bridge_token or ''
  save_config()
  send_properties_now()
  ctx.log('Bridge configured: ' .. bridge_address())
end

local function configure_fuel_cell_command(ctx, args)
  S.fc_model = args.fc_model or S.fc_model
  S.fc_units = args.fc_units or S.fc_units
  S.fc_wiring = args.fc_wiring or S.fc_wiring
  S.fc_rated_power_w = args.fc_rated_power_w or S.fc_rated_power_w
  S.fc_nominal_voltage_v = args.fc_nominal_voltage_v or S.fc_nominal_voltage_v
  S.fc_min_voltage_v = args.fc_min_voltage_v or S.fc_min_voltage_v
  S.fc_undervoltage_qualify_s = args.fc_undervoltage_qualify_s or S.fc_undervoltage_qualify_s
  S.fc_max_voltage_v = args.fc_max_voltage_v or S.fc_max_voltage_v
  S.fc_overvoltage_qualify_s = args.fc_overvoltage_qualify_s or S.fc_overvoltage_qualify_s
  S.fc_max_current_a = args.fc_max_current_a or S.fc_max_current_a
  S.fc_overcurrent_qualify_s = args.fc_overcurrent_qualify_s or S.fc_overcurrent_qualify_s
  S.low_current_warning_a = args.low_current_warning_a or S.low_current_warning_a
  S.ramp_rate_a_per_s = args.ramp_rate_a_per_s or S.ramp_rate_a_per_s
  if args.poc_backoff_enabled ~= nil then
    S.poc_backoff_enabled = args.poc_backoff_enabled
  end
  S.poc_backoff_current_a = args.poc_backoff_current_a or S.poc_backoff_current_a
  S.poc_backoff_hold_s = args.poc_backoff_hold_s or S.poc_backoff_hold_s
  S.poc_max_duration_s = args.poc_max_duration_s or S.poc_max_duration_s
  if S.fc_wiring == 'series' and S.fc_nominal_voltage_v > S.regatron_max_voltage_v then
    ctx.log('WARNING: nominal voltage ' .. tostring(S.fc_nominal_voltage_v) ..
      ' V exceeds the Regatron 80 V window - check your series wiring.', 'warning')
  end
  if S.poc_backoff_current_a <= 4.0 then
    ctx.log('WARNING: poc_backoff_current_a <= 4 A risks tripping the FCM-802\'s own ' ..
      '4A/20s under-current delayed stop while backing off. Consider a higher value.',
      'warning')
  end
  if S.poc_backoff_hold_s >= S.poc_max_duration_s then
    ctx.error('poc_backoff_hold_s must be less than poc_max_duration_s, or a single ' ..
      'backoff phase alone could exceed the episode timeout')
  end
  if S.fc_max_voltage_v <= S.fc_min_voltage_v then
    ctx.error('fc_max_voltage_v must be greater than fc_min_voltage_v')
  end
  if S.fc_max_current_a > S.regatron_max_current_a then
    ctx.log('WARNING: fc_max_current_a exceeds the Regatron hardware max - the hardware ' ..
      'limit will bind first.', 'warning')
  end
  save_config()
  send_properties_now()
  ctx.log('Fuel cell bank configured: ' .. tostring(S.fc_rated_power_w) .. ' W @ ' ..
    tostring(S.fc_nominal_voltage_v) .. ' V nominal, window ' ..
    tostring(S.fc_min_voltage_v) .. '-' .. tostring(S.fc_max_voltage_v) .. ' V.')
end

local function read_configuration_command(ctx, args)
  return {
    bridge_ip = S.bridge_ip,
    bridge_port = S.bridge_port,
    bridge_token = S.bridge_token,
    fc_model = S.fc_model,
    fc_units = S.fc_units,
    fc_wiring = S.fc_wiring,
    fc_rated_power_w = S.fc_rated_power_w,
    fc_nominal_voltage_v = S.fc_nominal_voltage_v,
    fc_min_voltage_v = S.fc_min_voltage_v,
    fc_undervoltage_qualify_s = S.fc_undervoltage_qualify_s,
    fc_max_voltage_v = S.fc_max_voltage_v,
    fc_overvoltage_qualify_s = S.fc_overvoltage_qualify_s,
    fc_max_current_a = S.fc_max_current_a,
    fc_overcurrent_qualify_s = S.fc_overcurrent_qualify_s,
    low_current_warning_a = S.low_current_warning_a,
    ramp_rate_a_per_s = S.ramp_rate_a_per_s,
    poc_backoff_enabled = S.poc_backoff_enabled,
    poc_backoff_current_a = S.poc_backoff_current_a,
    poc_backoff_hold_s = S.poc_backoff_hold_s,
    poc_max_duration_s = S.poc_max_duration_s,
  }
end

-- =========================================================================
-- ENTRY POINT
-- =========================================================================

local function main()
  load_config()
  enapter.register_command_handler('emergency_stop', emergency_stop_command)
  enapter.register_command_handler('clear_fault', clear_fault_command)
  enapter.register_command_handler('acknowledge_precharge', acknowledge_precharge_command)
  enapter.register_command_handler('set_manual_cc', set_manual_cc_command)
  enapter.register_command_handler('set_manual_cv', set_manual_cv_command)
  enapter.register_command_handler('set_manual_cp', set_manual_cp_command)
  enapter.register_command_handler('output_off', output_off_command)
  enapter.register_command_handler('start_cc_test', start_cc_test_command)
  enapter.register_command_handler('start_cv_test', start_cv_test_command)
  enapter.register_command_handler('start_cp_test', start_cp_test_command)
  enapter.register_command_handler('start_polarization_curve', start_polarization_curve_command)
  enapter.register_command_handler('start_load_step', start_load_step_command)
  enapter.register_command_handler('stop_test', stop_test_command)
  enapter.register_command_handler('configure_bridge', configure_bridge_command)
  enapter.register_command_handler('configure_fuel_cell', configure_fuel_cell_command)
  enapter.register_command_handler('read_configuration', read_configuration_command)

  scheduler.add(CONTROL_PERIOD_MS, poll_and_control)
  scheduler.add(PROPERTIES_PERIOD_MS, send_properties_now)
  send_properties_now()
end

main()

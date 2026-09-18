# Regatron G5 Fuel Cell Load Bank — Enapter Blueprint

Turns your Regatron TopCon G5.BT (0–80 V, ±338 A, ±9 kW) into a
programmable test bench for two **Intelligent Energy FCM 802** modules
sharing a hybrid DC bus with a battery, driven from the Enapter Cloud.

Supported test modes: **CC**, **CV**, **CP**, **polarization sweep** (with
optional up/down hysteresis), and **load-step / transient**, all settable as
a percentage of the bank's rated output.

Numbers throughout reflect the **2026-09-16 parameter brief**. Anything
marked CONFIRM is a factory-settable value on the FCM side that needs
checking against your installed modules before you trust it.

---

## Hybrid system: what this blueprint actually measures

The deployment isn't "Regatron sinks directly from a fuel cell." It's:

```
     FCM-802 #1 ──┐
     FCM-802 #2 ──┼── shared 48 V nominal DC bus ── Regatron (the load)
     Battery ─────┘
```

Two FCM-802 modules, a battery, and the Regatron all sit in **parallel** on
one bus. The FCM regulates the bus to a **Target Output Voltage of 52 V**
(48 V is only the factory default for that parameter — confirm your
installed modules are actually set to 52 V). The battery is what's supposed
to cover the load while an FCM's own power dips during its periodic
Performance Optimisation Cycle (POC) — the load command is meant to stay
unchanged while that happens.

That has two consequences for this blueprint:

- **What the Regatron measures is bus/load-side, not FCM output.**
  `bus_voltage_v` and `load_current_a` are what the Regatron itself sees —
  demand, not fuel-cell output. On the real hybrid bus, the battery can also
  be sourcing or absorbing current on the same bus, so never treat
  `load_current_a` as "the fuel cell's output." True FCM branch current
  needs a separate current sensor per module, outside this blueprint's
  reach (see **Logging** below).
- **On a standalone bench (Regatron + FCM, no battery), nothing covers the
  load during a POC unless the bench does it itself.** That's what the POC
  backoff behaviour below is for — a software stand-in for the battery,
  only relevant when you're testing without one. If you *do* have a real
  battery or bench PSU in parallel during testing, turn it off
  (`poc_backoff_enabled: false`) and let the real hardware do the job it's
  meant to do.

---

## Why there is a Python file in an Enapter blueprint

Your existing `V2_1_Regatron_Control.py` drives the G5 through
`Regatron.G5.Api.dll` — a .NET assembly, over a 921600-baud virtual COM port.

Enapter's Lua sandbox can speak Modbus TCP, CAN, HTTP, OPC UA, SNMP and DIO.
It **cannot** load a .NET DLL or open that serial link. So a pure
copy-paste-Lua blueprint cannot drive this device, no matter how it's written.

`regatron_bridge.py` closes that gap. It runs on the PC that has the
Regatron driver, keeps the exact .NET calls from your working script, and
re-exposes them as HTTP endpoints the blueprint polls at 1 Hz — while an
independent background thread samples the hardware at up to ~20 Hz for local
logging and safety checks, decoupled from however often Enapter happens to
poll (see **Logging** and **Safety**).

```
Enapter Cloud
     │
     │  (Enapter Gateway, Virtual UCM)
     ▼
firmware.lua  ──── HTTP, ~1 Hz ────►  regatron_bridge.py
 test sequencing                       ├─ Flask: /status /setpoint /output ...
 safety envelope (qualified)           ├─ fast_sample_loop: ~20 Hz, independent
 POC backoff/probe                     │  thread → cache + local CSV + direction
 dashboard                             │  check
                                        └─ Regatron.G5.Api.dll
                                              │
                                              ▼
                                       Regatron G5 ──► shared bus ◄── FCM ×2, battery
```

---

## Files

| File | Goes where | What it is |
|---|---|---|
| `manifest.yml` | Enapter blueprint editor | Device model: telemetry, properties, commands, alerts |
| `firmware.lua` | Enapter blueprint editor | Control loop, test sequencer, safety envelope |
| `regatron_bridge.py` | The PC with the Regatron | HTTP↔.NET bridge, fast sampler, local CSV log |
| `test/harness.lua` | (dev only) | Offline logic test, 15 scenarios |
| `test/integration.lua` | (dev only) | Real firmware ↔ real bridge over real HTTP |
| `test/test_bridge.py` | (dev only) | Bridge-side unit tests (direction check, fast log) |

---

## Install

### 1. Bridge, on the PC with the Regatron driver

```bash
pip install pythonnet flask

# real hardware — COM port number only, not the string "COM3"
python regatron_bridge.py --com-port 3 --token choose-a-secret

# or, to try the whole system with no hardware attached:
python regatron_bridge.py --simulate --token choose-a-secret
```

`--simulate` runs a polarization plant model (52 V OCV, ohmic slope, mass
transport knee) so you can validate the blueprint, the dashboard, and your
test recipes before anything is wired to a real stack. **Do this first.**

Useful flags: `--fast-log-hz 20` (local sample/log rate, default 20),
`--no-fast-log` (keep the fast sampler for safety checks and `/status`
freshness, skip the CSV file). Check the firewall allows inbound TCP on 8765
from the Gateway, and note the PC's LAN IP.

### 2. Blueprint, in Enapter

1. Enapter Cloud → **Blueprints** → **New blueprint** → device blueprint.
2. Paste `manifest.yml` and `firmware.lua` into their respective tabs.
3. Upload it to a **Virtual UCM** on your Gateway.

### 3. Configure and acknowledge, from the device page

Run these once per session:

- **Configure Bridge** — bridge IP, port `8765`, and the same token you passed
  to `--token`.
- **Configure Fuel Cell Bank** — see below.
- **Acknowledge Precharge Complete** — required once per blueprint session
  before any command that energizes the load will run (not persisted across
  a restart, on purpose — see **Safety**).

Within a second or two `Bench Status` should go to `idle` and `Bridge
Reachable` to true.

---

## Configuring the bank

Defaults assume **two FCM-802 in parallel, 48 V factory configuration**:

| Setting | Default | Source |
|---|---|---|
| Combined rated power | 4800 W | 2.4 kW / 50 A per module (>95% duty, 25°C, BOL, <1500 m). **Combined 4.8 kW is UNTESTED** — two-module current sharing not yet characterized |
| Nominal bus voltage | 52 V | Target Output Voltage the FCM regulates to (48 V is only the factory *default* for this parameter — CONFIRM) |
| Voltage floor | 48 V, 3 s qualify | Delayed Start Under-Voltage / "abort on sustained undervoltage" |
| Voltage ceiling | 54 V, 15 s qualify | Ahead of the FCM's own Delayed Stop Over-Voltage (60 s qualification there) |
| Combined current ceiling | 160 A, 3 s qualify | 2 × 80 A configured Output Current Limit per module (48 V config — **not** the 60 A/24 V figure) |
| Low-current warning | 6 A (soft) | FCM-802 enters standby below 4 A for 20 s |
| POC backoff current | 8 A | Comfortably above the 4 A standby threshold |
| POC backoff hold | 13 s | Just past the ~12 s POC spec |
| POC episode timeout | 20 s | Longer than one hold+probe cycle is not a normal POC |

**If you wire the two units in series**, nominal becomes ~104 V (2×52V) —
past the Regatron's 80 V window. The blueprint warns about this but parallel
is what the deployed system actually is.

**The qualify times matter.** A brief undervoltage/overvoltage/overcurrent
blip doesn't trip anything — only a sustained one does. This is deliberate:
a real POC current dip shouldn't collapse bus voltage (the battery covers
it on the real hybrid bus), so a genuine sustained bus excursion is more
likely a real problem and is worth reacting to, while a momentary
measurement blip shouldn't abort an otherwise-fine test.

---

## Running tests

All test commands take **either** a percentage **or** an absolute value; the
absolute value wins if you give both. All energizing commands require
**Acknowledge Precharge Complete** to have been run this session.

| Command | What it does |
|---|---|
| **Start CC Test** | Holds a fixed current for a duration |
| **Start CV Test** | Holds a fixed voltage, current-limited (ceiling required) |
| **Start CP Test** | Holds a fixed power (software loop, see below) |
| **Start Polarization Sweep** | Steps current A%→B%, dwelling at each point; `round_trip` sweeps back down after, for the hysteresis check the brief asks for |
| **Start Load Step** | Alternates low/high for N cycles — transient response |
| **Manual CC/CV/CP** | Jog to a setpoint and hold indefinitely |
| **Stop Test** | Ramps current to zero, then output off |
| **EMERGENCY STOP** | Cuts output immediately and latches a fault |
| **Acknowledge Precharge Complete** | Required once per session before energizing anything |

A polarization sweep at 10→100% in 10% steps with 90 s dwell and
`round_trip: true` takes about 30 minutes and gives you a full up-and-down
V–I curve for checking hysteresis near the limits.

### Dwell means *settled* time

Each step waits for the **measured** value to converge before the dwell
clock starts — not just for the commanded ramp to finish. Without this, a
recorded polarization point would actually be the *previous* step's
response, shifted by one. If a point genuinely can't be reached (starved
stack, current-limited, degraded cell — not a POC-shaped shortfall), it's
accepted after 20 s with a logged warning so a sweep still completes.

---

## POC backoff — the "another power supply" stand-in

On the deployed hybrid bus, a battery covers the load while an FCM's power
drops to zero for up to ~12 s during its own POC — the load command stays
unchanged, and several POCs can happen in quick succession during startup.
On a standalone bench there's nothing to do that unless the bench does it.

The backoff runs as a small state machine, because recovery can't be judged
by "has current climbed back up" — during backoff we're deliberately not
asking for much, so it never would:

1. **Detect**: measured current drops below 50% of commanded while holding.
2. **Backoff**: hold at `poc_backoff_current_a` (default 8 A, safely above
   the 4A/20s standby threshold) for `poc_backoff_hold_s` (default 13 s).
3. **Probe**: resume the real target. If the FCM still can't deliver, the
   shortfall reappears almost immediately and it retreats back to backoff.
   If it holds clean for a couple of seconds, the episode is declared over.
4. **Episode timeout**: if backoff/probe keeps cycling past
   `poc_max_duration_s` (default 20 s total) with no clean probe, that's not
   a normal POC anymore — it escalates to a real `poc_timeout` fault.

A multi-cycle episode (backoff → failed probe → backoff → successful probe)
still counts as **one** POC event with the total episode duration — matching
"several POCs in quick succession" reading as one real-world event, not
several. `poc_event_count` and `poc_last_duration_s` are per-test telemetry;
the alert `poc_window` is informational while backing off, not a fault —
**the code must not read a POC dip as fuel-cell derating.**

This is a mitigation, not equivalent to a real battery: it still interrupts
the intended test current for a few seconds. If you have a real battery or
bench PSU in parallel while testing standalone, turn `poc_backoff_enabled`
off and let it do the job.

---

## Two things about fuel cells worth knowing

**CV mode fights the module's regulator.** The FCM 802 is a *regulated*
module with its own DC-DC holding the bus near 52 V — not a bare stack.
Commanding Regatron-CV against it means two voltage regulators arguing over
the same bus. Every CV command requires an explicit current ceiling for
exactly this reason, and the direction check (below) applies to CV too. For
polarization work, **CC is the mode you want**: sweep current, measure
voltage.

**CP is a software loop.** The G5's API exposes Current-controlled and
Voltage-controlled modes only. CP is implemented by recomputing the current
target every tick as `P / V_measured` and driving CC — verified holding
2000 W within a few watts against the plant model, correctly raising current
as bus voltage sags. It's a ~1 Hz loop, so it tracks slow sag well and won't
catch fast transients.

---

## Safety — four independent layers, in order of authority

1. **The G5 itself.** Every setpoint call re-asserts the max/min voltage,
   current and power window into the device. The hardware enforces these
   even if the PC dies mid-test.
2. **The bridge's direction check.** "Verify it cannot source/regenerate
   current back into the bus" — every fast sample checks the measured
   current's sign against the sink direction commanded; a mismatch cuts the
   output immediately, not on the Lua side's next ~1 Hz poll. Covers both
   CC and CV mode.
3. **The bridge's dead-man watchdog.** If the blueprint stops polling for
   5 s while the output is live, the output is cut without being asked.
4. **The blueprint's Lua envelope.** Voltage floor/ceiling and combined
   overcurrent, all qualified (brief blips don't trip; sustained ones do),
   plus the precharge gate and an abort if the bridge goes unreachable
   mid-test.

E-stop and the bridge's own faults (direction, watchdog) latch: setpoints
and output-on are refused with HTTP 409 until **Clear Fault** is run. That's
deliberate — a latched stop shouldn't clear itself because a poll succeeded.

**What this blueprint cannot see or protect against:** battery over-discharge
(no battery branch sensor in its reach), FCM internal faults and their
Enable-off-5s→Enable-on→Run-on reset sequence (that belongs to the separate
FCM CAN/relay blueprint controlling the module itself), and — always —
precharge/isolation-contactor procedure, hydrogen safety, ventilation, leak
detection, and a physical emergency stop. None of this is a substitute for
hardware protection.

---

## Logging

The brief is explicit: *"common clock across all channels; 10-100+ Hz local
logging minimum ... never rely on Enapter cloud for fast events."* Enapter's
own polling is ~1 Hz — nowhere near fast enough for load-step transients.

`regatron_bridge.py` runs an independent background thread
(`fast_sample_loop`) at `--fast-log-hz` (default 20 Hz), decoupled from
whatever rate the Lua side happens to poll at. Every sample — **commanded
setpoint and measured V/I, with a real timestamp** — is appended to
`bridge_logs/regatron_fastlog_<timestamp>.csv`. `/status` reads this same
cache rather than hitting hardware fresh on every Enapter poll.

This bridge only covers the **G5.BT's own channel**. FCM branch V/I
(independent reference), battery branch V/I, bus voltage from a separate
sensor, ambient temperature, and FCM CAN telemetry are outside its reach —
separate instruments/blueprints. If you need one fully correlated dataset,
those need to land on the same clock some other way (a shared NTP-synced
timestamp is enough; they don't need to share this process). Do **not** try
to reconstruct fast transients from Enapter Cloud's own telemetry history —
that's still only ~1 Hz, same limitation the brief calls out.

---

## What was tested, and what wasn't

Verified by running it:

- 15 scenarios / 70+ assertions in `test/harness.lua` — CC, CV, CP,
  polarization (including round-trip), load step, e-stop, fault recovery,
  qualified undervoltage/overvoltage/overcurrent (both the "doesn't trip on
  a blip" and "does trip when sustained" paths), the POC backoff/probe
  cycle including a multi-cycle retreat-and-retry, precharge gating, config
  persistence.
- 7 bridge-side unit tests in `test/test_bridge.py` — direction check fires
  on reversed sign (CC and CV), stays quiet on correct direction and on
  near-zero current, `power_w` uses magnitude while `current_signed_a`
  carries direction, fast-log CSV rows are well-formed.
- End-to-end (`test/integration.lua`): the real `firmware.lua` driving a
  real `regatron_bridge.py` over real HTTP, real wall-clock timing (the
  bridge's fast sampler runs on a real 20 Hz thread, so the test now sleeps
  between ticks rather than racing through fake time — an early version of
  this test raced ahead of the plant model and produced a false POC
  detection, which is itself a useful reminder that fake-clock tests and a
  real background thread don't mix for free). Produced a monotonic 5-point
  polarization curve (49.47 V@20A → 41.16 V@100A) and a CP hold landing
  exactly on 2000 W.
- Watchdog (output cut ~5.8 s after simulated bridge/network loss), power
  clamp, auth rejection, e-stop latching — against the live service.
- `manifest.yml` parses; every command has a handler; every declared
  telemetry attribute is actually sent (checked automatically after every
  change).

```bash
cd test
lua5.4 harness.lua                        # offline logic
python3 test_bridge.py                    # bridge-side unit tests
python3 ../regatron_bridge.py --simulate --port 8900 --fast-log-hz 20 &
lua5.4 integration.lua 8900               # end-to-end, real HTTP
```

Not verified, and needing your attention:

- **The .NET calls have never run against your hardware from this file.**
  Transcribed from your working `V2_1_Regatron_Control.py`
  (`G5System.CreateSystem` / `GetReferenceValues` / `GetCommands` /
  `GetActualValues`) — should be right, but first connection is the moment
  to watch. All of them live in `RegatronDriver`, one class.
- **`CURRENT_SIGN_SINK = -1.0`** at the top of the bridge, and whether CV
  mode's sign assumption holds for your wiring. Confirm at low current
  before trusting automation — the direction check will now catch a
  persistent reversal, but verify it the first time by watching, not by
  relying on the check to save you.
- **`fc_nominal_voltage_v = 52`** — confirm the installed modules' actual
  Target Output Voltage configuration, not just the factory default.
- **Combined 4.8 kW / two-module current sharing** — explicitly untested
  per the brief. Approach a first combined-module run incrementally.
- `SENSE_VOLTAGE_OFFSET_V` defaults to 0 — set it if your sense leads have
  measurable drop.
- Negative earthing / G5.BT isolation compatibility, and that the G5.BT
  cannot source/regenerate into the bus beyond what the direction check
  catches in software — both called out in the brief as things to verify on
  the bench, not something this code can confirm for you.

### First run on hardware

Simulate first. Then, on the real bench: **Manual CC at 2–3 A**, confirm the
current sign and that voltage moves the right way, confirm E-stop cuts
output, *then* start a sweep.

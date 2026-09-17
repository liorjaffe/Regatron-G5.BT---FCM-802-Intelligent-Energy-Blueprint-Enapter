#!/usr/bin/env python3
"""
regatron_bridge.py - HTTP bridge between the Enapter blueprint and a
Regatron TopCon G5 (G5.BT.9.80.338.M) bidirectional DC source/sink.

WHY THIS EXISTS
---------------
Enapter's Lua sandbox can speak Modbus TCP, CAN, HTTP, OPC UA and SNMP - it
cannot load Regatron.G5.Api.dll or open the G5's 921600-baud virtual COM
port. So this small service runs on the Windows PC that already has the
Regatron driver installed, keeps the exact .NET calls from the existing
V2_1_Regatron_Control.py, and re-exposes them as five HTTP endpoints the
blueprint polls once a second.

    GET  /status         -> live measurements + device state (from cache -
                             see FAST SAMPLING below, not a fresh hardware
                             read on every call)
    POST /setpoint       -> {"mode":"cc"|"cv", "value":<A|V>, "limit":<V|A>}
    POST /output         -> {"state":"on"|"off"}
    POST /estop          -> {"reason":"..."}   immediate output off + latch
    POST /clear_errors   -> acknowledge latched G5 incidents

FAST SAMPLING + LOCAL LOGGING (2026-09-16 parameter brief)
------------------------------------------------------------
The brief is explicit: "common clock across all channels; 10-100+ Hz local
logging minimum ... never rely on Enapter cloud for fast events." Enapter's
own polling is ~1 Hz, nowhere near fast enough for load-step transients. So
a dedicated background thread (fast_sample_loop) samples the G5 at
FAST_LOG_HZ independently of any HTTP traffic, updates the cache /status
reads from, and appends every sample - commanded setpoint AND measured V/I,
with a real timestamp - to a local CSV under bridge_logs/. This bridge only
covers the G5.BT's own channel; FCM branch V/I, battery branch V/I and
ambient temperature are separate instruments/CAN telemetry outside its
reach - see README "Logging" for how to correlate them on one clock.

SAFETY MODEL - four independent layers, in order of authority
--------------------------------------------------------------
 1. The G5 itself. Every setpoint call pushes the max/min voltage, current
    and power window into the device via SetMaximum*/SetMinimum*. The
    hardware enforces these even if this script hangs or the PC dies.
 2. This bridge's direction check. Every fast sample verifies the measured
    current's sign matches the sink direction we commanded - "VERIFY it
    cannot source/regenerate current back into the bus" (brief). A mismatch
    cuts the output immediately, not on the Lua side's next 1Hz poll.
 3. This bridge's dead-man watchdog: if the Enapter blueprint stops polling
    for WATCHDOG_TIMEOUT_S while the output is live, the output is switched
    off unconditionally.
 4. The blueprint's Lua safety envelope (voltage floor/ceiling, overcurrent,
    overpower, all with qualification timers). Highest level, easiest to
    change, least authoritative.

Run with --simulate to exercise the whole chain, including the Enapter
dashboard, with no hardware attached.

USAGE
    pip install pythonnet flask
    python regatron_bridge.py --com-port 3 --token mysecret
    python regatron_bridge.py --simulate          # no hardware needed
"""

import argparse
import csv
import logging
import os
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional, Tuple

try:
    from flask import Flask, jsonify, request
except ImportError:
    sys.exit("Flask is required:  pip install flask")

# =============================================================================
# CONFIGURATION - edit the defaults here or pass them on the command line
# =============================================================================

# Regatron G5.BT.9.80.338 nameplate: -9..9 kW, 0..80 V, -338..338 A.
# This bench only ever SINKS from the fuel cell, so the current setpoints
# below are magnitudes and the sign convention is handled in one place
# (see CURRENT_SIGN_SINK).
HW_MAX_VOLTAGE_V = 80.0
HW_MAX_CURRENT_A = 338.0
HW_MAX_POWER_W = 9000.0

# Sign the G5 needs in order to SINK current out of the fuel cell. In the
# original script a positive current charges the cell and a negative one
# discharges it, so drawing power out of a fuel cell is the negative
# direction. Flip this to +1.0 only if your wiring/convention is reversed.
CURRENT_SIGN_SINK = -1.0

# Measured voltage correction: V_true = V_regatron + SENSE_VOLTAGE_OFFSET_V.
# Carried over from the original script - set it from a DMM comparison at
# rest if your sense leads have measurable drop.
SENSE_VOLTAGE_OFFSET_V = 0.0

# Dead-man timer. If the blueprint stops polling /status for this long while
# the output is on, cut the output. Must be comfortably longer than the
# blueprint's 1 s control period, short enough to matter.
WATCHDOG_TIMEOUT_S = 5.0

# Independent fast sampler (see module docstring). 20 Hz is a reasonable
# starting point; the real ceiling depends on the G5's own serial round-trip
# time at 921600 baud - lower this if the CSV timestamps start drifting or
# sample_age_s in /status grows instead of staying near 1/FAST_LOG_HZ.
FAST_LOG_HZ = 20.0
FAST_LOG_DIR = "bridge_logs"

# Direction check deadband: ignore sign near zero current, where it is noise
# rather than a real source/sink signal.
DIRECTION_CHECK_DEADBAND_A = 2.0

DEFAULT_PORT = 8765
DEFAULT_BAUDRATE = 921600

log = logging.getLogger("regatron_bridge")


# =============================================================================
# DRIVER LAYER
# =============================================================================

class RegatronDriver:
    """Thin wrapper over Regatron.G5.Api.dll.

    Every .NET call in this project lives in this class and nowhere else, so
    if Regatron changes the API surface there is exactly one file to fix.
    The call names match the working V2_1_Regatron_Control.py exactly:
      G5System.CreateSystem() / Connect / IsConnected / GetConnectedDevice
      GetReferenceValues -> SetControllerMode/SetVoltage/SetCurrent/SetMaximum*
      GetCommands        -> SetVoltageOn/SetVoltageOff/ClearErrors
      GetActualValues    -> GetSenseVoltage/GetOutputCurrent
      GetState           -> GetState/HasErrors/HasWarnings/GetIncidents
    """

    def __init__(self, com_port: int, baudrate: int = DEFAULT_BAUDRATE,
                 dll_path: Optional[str] = None):
        self.com_port = com_port
        self.baudrate = baudrate
        self.dll_path = dll_path
        self.g5 = None
        self.connected = False
        self.serial_number = ""
        self._output_on = False
        self._ControllerMode = None
        self._G5ApiException = Exception
        # What we last commanded - used by the direction check (expected
        # sink sign only applies once a mode is actually active) and the
        # fast log ("commanded setpoint AND measured V/I", per the brief).
        self.mode = "idle"
        self.setpoint_value = None
        self.setpoint_limit = None

    # ------------------------------------------------------------- lifecycle
    def _load_assembly(self):
        import clr  # pythonnet

        dll = self.dll_path
        if dll:
            dll_dir = os.path.dirname(os.path.abspath(dll))
            # Put the DLL's own directory on the path so its sibling
            # dependencies resolve; clr.AddReference alone does not.
            if dll_dir not in sys.path:
                sys.path.append(dll_dir)
            os.environ["PATH"] = dll_dir + os.pathsep + os.environ.get("PATH", "")
            clr.AddReference(os.path.splitext(dll)[0])
        else:
            clr.AddReference("Regatron.G5.Api")

        from Regatron.G5.Api import G5ApiException
        from Regatron.G5.Api.System import G5System
        from Regatron.G5.Common import ControllerMode

        self._G5ApiException = G5ApiException
        self._ControllerMode = ControllerMode
        return G5System

    def connect(self) -> bool:
        try:
            G5System = self._load_assembly()
            self.g5 = G5System.CreateSystem()
            log.info("Connecting to Regatron G5 on COM%s @ %s baud ...",
                     self.com_port, self.baudrate)
            self.g5.Connect(self.com_port, self.baudrate)
            time.sleep(1.0)
            if not self.g5.IsConnected():
                raise RuntimeError("Connection could not be established.")
            device = self.g5.GetConnectedDevice()
            self.serial_number = str(device.GetInformation().GetSerialNumber())
            self.connected = True
            log.info("Connected | SN %s | State %s",
                     self.serial_number, device.GetState().GetState())
            return True
        except Exception as exc:
            log.error("Regatron connection failed: %s", exc)
            self.connected = False
            return False

    def disconnect(self):
        try:
            self.output_off()
        except Exception:
            pass
        self.connected = False
        if self.g5 is not None:
            try:
                self.g5.Disconnect()
            except Exception:
                pass

    # ----------------------------------------------------------- measurement
    def measure(self) -> Tuple[Optional[float], Optional[float], Optional[float]]:
        """Returns (corrected_voltage, raw_voltage, current)."""
        if not self.connected:
            return None, None, None
        try:
            values = self.g5.GetActualValues()
            if values is None:
                return None, None, None
            raw = float(values.GetSenseVoltage())
            current = float(values.GetOutputCurrent())
            return raw + SENSE_VOLTAGE_OFFSET_V, raw, current
        except Exception as exc:
            log.warning("Measurement failed: %s", exc)
            return None, None, None

    def device_state(self) -> dict:
        if not self.connected:
            return {"state": "", "has_errors": False, "has_warnings": False,
                    "last_incident": ""}
        try:
            state = self.g5.GetConnectedDevice().GetState()
            incident_text = ""
            try:
                for incident in state.GetIncidents():
                    incident_text = (f"code={incident.Code} "
                                     f"group={incident.Group} "
                                     f"type={incident.Type}")
                    break  # the most recent one is enough for the dashboard
            except Exception:
                pass
            return {
                "state": str(state.GetState()),
                "has_errors": bool(state.HasErrors()),
                "has_warnings": bool(state.HasWarnings()),
                "last_incident": incident_text,
            }
        except Exception as exc:
            log.warning("State read failed: %s", exc)
            return {"state": "", "has_errors": False, "has_warnings": False,
                    "last_incident": ""}

    # -------------------------------------------------------------- setpoints
    def _apply_limits(self, reference):
        """Push the hardware safety window into the G5 on every setpoint.

        This is the layer that still protects the stack if this script hangs,
        so it is re-asserted every single time rather than once at startup.
        """
        reference.SetMaximumVoltage(float(HW_MAX_VOLTAGE_V - SENSE_VOLTAGE_OFFSET_V))
        reference.SetMinimumVoltage(float(0.0))
        reference.SetMaximumCurrent(float(HW_MAX_CURRENT_A))
        reference.SetMinimumCurrent(float(-HW_MAX_CURRENT_A))
        reference.SetMaximumPower(float(HW_MAX_POWER_W))
        reference.SetMinimumPower(float(-HW_MAX_POWER_W))

    def set_cc(self, current_a: float, voltage_limit_v: float):
        """Current controlled: current is the setpoint, voltage is the limit
        the device falls back to (the automatic CC-to-CV transition)."""
        if not self.connected:
            return
        reference = self.g5.GetReferenceValues()
        reference.SetControllerMode(self._ControllerMode.CurrentControlled)
        self._apply_limits(reference)
        reference.SetVoltage(float(voltage_limit_v - SENSE_VOLTAGE_OFFSET_V))
        reference.SetCurrent(float(CURRENT_SIGN_SINK * abs(current_a)))
        self.mode = "cc"
        self.setpoint_value = abs(current_a)
        self.setpoint_limit = voltage_limit_v

    def set_cv(self, voltage_v: float, current_limit_a: float):
        """Voltage controlled: hold the voltage, current limited."""
        if not self.connected:
            return
        reference = self.g5.GetReferenceValues()
        reference.SetControllerMode(self._ControllerMode.VoltageControlled)
        self._apply_limits(reference)
        reference.SetVoltage(float(voltage_v - SENSE_VOLTAGE_OFFSET_V))
        reference.SetCurrent(float(abs(current_limit_a)))
        self.mode = "cv"
        self.setpoint_value = voltage_v
        self.setpoint_limit = current_limit_a

    # ---------------------------------------------------------- output control
    def output_on(self) -> bool:
        """Enable the output, clearing one pending incident if needed.

        The G5 refuses to switch on while an old incident is latched, which
        happens routinely after a previous test ended on a limit. One
        automatic ClearErrors and a retry saves a trip to the front panel.
        """
        if not self.connected:
            return False
        if self._output_on:
            return True
        try:
            self.g5.GetCommands().SetVoltageOn()
            self._output_on = True
            return True
        except self._G5ApiException:
            try:
                self.g5.GetCommands().ClearErrors()
                time.sleep(0.5)
                self.g5.GetCommands().SetVoltageOn()
                self._output_on = True
                return True
            except Exception as exc:
                log.error("Failed to enable the output: %s", exc)
                return False

    def output_off(self):
        if not self.connected:
            self._output_on = False
            self.mode = "idle"
            return
        try:
            self.g5.GetCommands().SetVoltageOff()
        except Exception as exc:
            log.warning("Output off failed: %s", exc)
        self._output_on = False
        self.mode = "idle"

    def clear_errors(self) -> bool:
        if not self.connected:
            return False
        try:
            self.g5.GetCommands().ClearErrors()
            time.sleep(0.5)
            return True
        except Exception as exc:
            log.error("ClearErrors failed: %s", exc)
            return False


# =============================================================================
# SIMULATED DRIVER - same interface, crude fuel-cell plant model
# =============================================================================

class SimulatedDriver:
    """Stands in for RegatronDriver so the blueprint, dashboard and test
    sequencing can be validated end-to-end with no hardware.

    The plant is a first-order polarization model of a 48 V / 2.4 kW class
    module bank: V = Voc - i*R - activation/concentration terms. Good enough
    to make the dashboard move sensibly; not a physics claim.
    """

    OCV_V = 52.0           # open-circuit
    R_OHMIC = 0.055        # ohmic slope
    I_LIMIT_A = 110.0      # mass-transport knee

    def __init__(self, *_args, **_kwargs):
        self.connected = False
        self.serial_number = "SIM-2433GV697"
        self._output_on = False
        self.mode = "idle"
        self.setpoint_value = None
        self.setpoint_limit = None
        self._target_i = 0.0
        self._target_v = 0.0
        self._limit = 0.0
        self._i = 0.0
        self._errors = False
        # Test hook only: flips the sign convention so bridge_test.py /
        # integration tests can prove the direction check actually fires,
        # without needing real hardware wired backwards to do it.
        self.force_wrong_direction = False

    def connect(self) -> bool:
        self.connected = True
        log.info("SIMULATION MODE - no hardware will be touched.")
        return True

    def disconnect(self):
        self._output_on = False
        self.connected = False

    def _polarization_v(self, i: float) -> float:
        i = max(0.0, min(i, self.I_LIMIT_A * 0.999))
        act = 2.6 * (i / self.I_LIMIT_A) ** 0.35 if i > 0.01 else 0.0
        conc = 5.0 * (i / self.I_LIMIT_A) ** 6
        return max(0.0, self.OCV_V - act - i * self.R_OHMIC - conc)

    def measure(self):
        if not self.connected:
            return None, None, None
        if not self._output_on:
            self._i = 0.0
            return self.OCV_V, self.OCV_V, 0.0
        if self.mode == "cc":
            target = self._target_i
        elif self.mode == "cv":
            # solve crudely for the current that lands on the target voltage
            target = 0.0
            for cand in [x * 0.5 for x in range(0, 240)]:
                if self._polarization_v(cand) <= self._target_v:
                    target = cand
                    break
            target = min(target, self._limit)
        else:
            target = 0.0
        # first-order lag toward the commanded current
        self._i += (target - self._i) * 0.45
        v = self._polarization_v(self._i)
        # Sink convention: negative, matching CURRENT_SIGN_SINK on the real
        # driver, so /status.current_signed_a behaves the same in --simulate
        # as it does on real hardware.
        signed_i = self._i if self.force_wrong_direction else -self._i
        return v, v, signed_i

    def device_state(self):
        return {"state": "READY" if self.connected else "",
                "has_errors": self._errors, "has_warnings": False,
                "last_incident": ""}

    def set_cc(self, current_a, voltage_limit_v):
        self.mode = "cc"
        self._target_i = abs(current_a)
        self._limit = voltage_limit_v
        self.setpoint_value = abs(current_a)
        self.setpoint_limit = voltage_limit_v

    def set_cv(self, voltage_v, current_limit_a):
        self.mode = "cv"
        self._target_v = voltage_v
        self._limit = abs(current_limit_a)
        self.setpoint_value = voltage_v
        self.setpoint_limit = current_limit_a
    def output_on(self):
        self._output_on = True
        return True

    def output_off(self):
        self._output_on = False
        self.mode = "idle"
        self._target_i = 0.0

    def clear_errors(self):
        self._errors = False
        return True


# =============================================================================
# BRIDGE STATE + WATCHDOG
# =============================================================================

@dataclass
class BridgeState:
    driver: object
    token: str = ""
    last_poll_at: float = field(default_factory=time.monotonic)
    estop_latched: bool = False
    estop_reason: str = ""
    lock: threading.Lock = field(default_factory=threading.Lock)

    # Fast-sample cache. /status reads THIS, not the hardware directly - see
    # fast_sample_loop(). Updated at FAST_LOG_HZ, independent of how often
    # Enapter happens to poll.
    cache_voltage_v: float = 0.0
    cache_raw_voltage_v: float = 0.0
    cache_current_signed_a: float = 0.0
    cache_power_w: float = 0.0
    cache_device_state: dict = field(default_factory=dict)
    cache_sampled_at: float = 0.0

    # Local fast CSV log (None if disabled via --no-fast-log).
    csv_file: object = None
    csv_writer: object = None
    csv_row_count: int = 0


STATE: Optional[BridgeState] = None


def clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def watchdog_loop():
    """Dead-man timer. If the blueprint stops polling while the output is
    live, cut the output. This is the layer that saves the stack when the
    gateway, the network or the Lua script dies mid-test."""
    while True:
        time.sleep(1.0)
        if STATE is None:
            continue
        with STATE.lock:
            stale = time.monotonic() - STATE.last_poll_at
            output_live = getattr(STATE.driver, "_output_on", False)
            if output_live and stale > WATCHDOG_TIMEOUT_S:
                log.error("WATCHDOG: no poll for %.1fs with the output live - "
                          "switching off.", stale)
                try:
                    STATE.driver.output_off()
                except Exception as exc:
                    log.error("Watchdog output_off failed: %s", exc)
                STATE.estop_latched = True
                STATE.estop_reason = (f"watchdog: no control poll for "
                                      f"{stale:.1f}s")


def _direction_check(driver, current_signed: float):
    """"VERIFY it cannot source/regenerate current back into the bus" (brief).

    We always command a sink: CC mode picks the sign explicitly
    (CURRENT_SIGN_SINK), and CV mode is only ever meant to pull the bus down
    toward a setpoint at or below the FC's own regulated voltage, never push
    it up. If the measured current's sign contradicts that - beyond a small
    deadband, so idle noise near zero doesn't trip it - something is
    seriously wrong: possible backfeed into the fuel cell. Cut the output
    immediately here rather than waiting for the Lua side's next 1Hz poll.
    """
    if not getattr(driver, "_output_on", False):
        return
    if abs(current_signed) < DIRECTION_CHECK_DEADBAND_A:
        return
    mode = getattr(driver, "mode", "idle")
    if mode not in ("cc", "cv"):
        return
    expected_sign = -1.0 if CURRENT_SIGN_SINK < 0 else 1.0
    actual_sign = 1.0 if current_signed > 0 else -1.0
    if actual_sign == expected_sign:
        return
    reason = (f"WRONG DIRECTION: measured {current_signed:.2f} A does not match the "
              f"expected sink sign ({'negative' if expected_sign < 0 else 'positive'}) - "
              f"possible source/backfeed into the bus. Output cut immediately.")
    log.error(reason)
    try:
        driver.output_off()
    except Exception as exc:
        log.error("direction-fault output_off failed: %s", exc)
    STATE.estop_latched = True
    STATE.estop_reason = reason


def _init_fast_log(enabled: bool, hz: float):
    """Opens the local CSV log fast_sample_loop appends to. Disabled bridges
    still run the fast sampler (for /status freshness and the direction
    check) - only the file write is skipped."""
    if not enabled:
        log.info("Fast local logging disabled (--no-fast-log).")
        return None, None
    os.makedirs(FAST_LOG_DIR, exist_ok=True)
    path = os.path.join(FAST_LOG_DIR, f"regatron_fastlog_{time.strftime('%Y%m%dT%H%M%S')}.csv")
    f = open(path, "w", newline="")
    writer = csv.writer(f)
    writer.writerow([
        "timestamp_iso", "epoch_s", "mode", "commanded_value", "commanded_limit",
        "voltage_v", "raw_voltage_v", "current_signed_a", "current_mag_a", "power_w",
        "output_on", "has_errors", "has_warnings", "estop_latched",
    ])
    f.flush()
    log.info("Fast local log: %s (%.0f Hz)", path, hz)
    return f, writer


def _write_fast_log_row(now_wall, driver, voltage, raw, current_signed, power, state):
    if STATE.csv_writer is None:
        return
    try:
        STATE.csv_writer.writerow([
            datetime.fromtimestamp(now_wall).isoformat(timespec="microseconds"),
            f"{now_wall:.6f}",
            getattr(driver, "mode", "idle"),
            getattr(driver, "setpoint_value", ""),
            getattr(driver, "setpoint_limit", ""),
            f"{voltage:.4f}", f"{raw:.4f}", f"{current_signed:.4f}", f"{abs(current_signed):.4f}",
            f"{power:.3f}", bool(getattr(driver, "_output_on", False)),
            state.get("has_errors", False), state.get("has_warnings", False),
            STATE.estop_latched,
        ])
        STATE.csv_row_count += 1
        # Flush roughly every 10s of samples rather than every row - keeps
        # data on disk promptly after a crash without an fsync per sample.
        if STATE.csv_row_count % max(int(FAST_LOG_HZ) * 10, 1) == 0:
            STATE.csv_file.flush()
    except Exception as exc:
        log.warning("fast log write failed: %s", exc)


def fast_sample_loop(hz: float):
    """Independent high-rate sampler + local CSV logger.

    This is the only place that calls driver.measure()/device_state() during
    normal operation; /status just reads the cache this fills. That decouples
    real hardware sampling from however often the Enapter blueprint happens
    to poll - "never rely on the Enapter cloud for fast events" (brief).
    Falls behind gracefully (resyncs rather than spiraling) if a sample takes
    longer than one period, which can happen on a slow serial round-trip.
    """
    period = 1.0 / max(hz, 1.0)
    next_tick = time.monotonic()
    while True:
        next_tick += period
        if STATE is not None:
            with STATE.lock:
                driver = STATE.driver
                voltage, raw, current_signed = driver.measure()
                state = driver.device_state()
                now_wall = time.time()

                voltage = voltage if voltage is not None else 0.0
                raw = raw if raw is not None else 0.0
                current_signed = current_signed if current_signed is not None else 0.0
                # power_w tracks current_a's magnitude convention (positive =
                # drawing power from the FC); current_signed_a is the only
                # field that carries direction, for the check right below.
                power = voltage * abs(current_signed)

                STATE.cache_voltage_v = voltage
                STATE.cache_raw_voltage_v = raw
                STATE.cache_current_signed_a = current_signed
                STATE.cache_power_w = power
                STATE.cache_device_state = state
                STATE.cache_sampled_at = time.monotonic()

                _direction_check(driver, current_signed)
                _write_fast_log_row(now_wall, driver, voltage, raw, current_signed, power, state)

        sleep_for = next_tick - time.monotonic()
        if sleep_for > 0:
            time.sleep(sleep_for)
        else:
            next_tick = time.monotonic()  # fell behind - resync, don't spiral


# =============================================================================
# HTTP API
# =============================================================================

app = Flask(__name__)


def _authorized() -> bool:
    if not STATE.token:
        return True
    header = request.headers.get("Authorization", "")
    return header == f"Bearer {STATE.token}"


@app.before_request
def _check_auth():
    if not _authorized():
        return jsonify({"error": "unauthorized"}), 401
    return None


@app.get("/status")
def status():
    with STATE.lock:
        STATE.last_poll_at = time.monotonic()
        driver = STATE.driver
        # Read the cache fast_sample_loop keeps fresh, rather than hitting
        # the hardware on every Enapter poll - see module docstring
        # "FAST SAMPLING + LOCAL LOGGING".
        voltage = STATE.cache_voltage_v
        raw = STATE.cache_raw_voltage_v
        current_signed = STATE.cache_current_signed_a
        power = STATE.cache_power_w
        state = STATE.cache_device_state or {}
        sample_age = (time.monotonic() - STATE.cache_sampled_at
                      if STATE.cache_sampled_at else None)
        # Report the magnitude for current_a, matching the blueprint's
        # "fuel cell is sourcing X amps" framing; current_signed_a carries
        # the raw sign for anyone checking sink-vs-source directly.
        current_mag = abs(current_signed)
        return jsonify({
            "connected": True,
            "regatron_connected": bool(driver.connected),
            "serial_number": driver.serial_number,
            "has_errors": state.get("has_errors", False) or STATE.estop_latched,
            "has_warnings": state.get("has_warnings", False),
            "output_on": bool(getattr(driver, "_output_on", False)),
            "voltage_v": round(voltage, 4),
            "raw_voltage_v": round(raw, 4),
            "current_a": round(current_mag, 4),
            "current_signed_a": round(current_signed, 4),
            "power_w": round(power, 3),
            "device_state": state.get("state", ""),
            "last_incident": STATE.estop_reason or state.get("last_incident", ""),
            "estop_latched": STATE.estop_latched,
            "sample_age_s": round(sample_age, 3) if sample_age is not None else None,
        })


@app.post("/setpoint")
def setpoint():
    body = request.get_json(silent=True) or {}
    mode = str(body.get("mode", "")).lower()
    value = float(body.get("value", 0.0))
    limit = float(body.get("limit", 0.0))

    with STATE.lock:
        STATE.last_poll_at = time.monotonic()
        if STATE.estop_latched:
            return jsonify({"error": "estop latched - clear it first",
                            "reason": STATE.estop_reason}), 409
        driver = STATE.driver
        if not driver.connected:
            return jsonify({"error": "regatron not connected"}), 503

        if mode == "cc":
            current = clamp(abs(value), 0.0, HW_MAX_CURRENT_A)
            vlimit = clamp(limit, 0.0, HW_MAX_VOLTAGE_V)
            # Never let a CC setpoint exceed the power envelope either.
            if vlimit > 1.0 and current * vlimit > HW_MAX_POWER_W:
                current = HW_MAX_POWER_W / vlimit
            driver.set_cc(current, vlimit)
            return jsonify({"ok": True, "mode": "cc",
                            "current_a": current, "voltage_limit_v": vlimit})

        if mode == "cv":
            voltage = clamp(value, 0.0, HW_MAX_VOLTAGE_V)
            ilimit = clamp(abs(limit), 0.0, HW_MAX_CURRENT_A)
            if voltage > 1.0 and ilimit * voltage > HW_MAX_POWER_W:
                ilimit = HW_MAX_POWER_W / voltage
            driver.set_cv(voltage, ilimit)
            return jsonify({"ok": True, "mode": "cv",
                            "voltage_v": voltage, "current_limit_a": ilimit})

        return jsonify({"error": f"unknown mode '{mode}'"}), 400


@app.post("/output")
def output():
    body = request.get_json(silent=True) or {}
    desired = str(body.get("state", "")).lower()
    with STATE.lock:
        STATE.last_poll_at = time.monotonic()
        driver = STATE.driver
        if desired == "off":
            driver.output_off()
            return jsonify({"ok": True, "output_on": False})
        if desired == "on":
            if STATE.estop_latched:
                return jsonify({"error": "estop latched - clear it first",
                                "reason": STATE.estop_reason}), 409
            if not driver.connected:
                return jsonify({"error": "regatron not connected"}), 503
            ok = driver.output_on()
            return jsonify({"ok": ok, "output_on": ok}), (200 if ok else 500)
        return jsonify({"error": "state must be 'on' or 'off'"}), 400


@app.post("/estop")
def estop():
    body = request.get_json(silent=True) or {}
    reason = str(body.get("reason", "emergency stop"))
    with STATE.lock:
        STATE.last_poll_at = time.monotonic()
        log.error("EMERGENCY STOP: %s", reason)
        try:
            STATE.driver.output_off()
        except Exception as exc:
            log.error("estop output_off failed: %s", exc)
        STATE.estop_latched = True
        STATE.estop_reason = reason
    return jsonify({"ok": True, "estop_latched": True, "reason": reason})


@app.post("/clear_errors")
def clear_errors():
    with STATE.lock:
        STATE.last_poll_at = time.monotonic()
        ok = STATE.driver.clear_errors()
        STATE.estop_latched = False
        STATE.estop_reason = ""
    return jsonify({"ok": ok, "estop_latched": False})


@app.get("/health")
def health():
    return jsonify({"ok": True, "service": "regatron_bridge"})


# =============================================================================
# ENTRY POINT
# =============================================================================

def main():
    global STATE

    parser = argparse.ArgumentParser(description="Regatron G5 <-> Enapter HTTP bridge")
    parser.add_argument("--com-port", type=int, default=1,
                        help="Regatron virtual COM port number (e.g. 3 for COM3)")
    parser.add_argument("--baudrate", type=int, default=DEFAULT_BAUDRATE)
    parser.add_argument("--dll", type=str, default=None,
                        help="Full path to Regatron.G5.Api.dll if it is not on the path")
    parser.add_argument("--host", type=str, default="0.0.0.0",
                        help="Bind address; keep on a trusted lab LAN only")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--token", type=str, default="",
                        help="Shared secret; must match bridge_token in the blueprint")
    parser.add_argument("--simulate", action="store_true",
                        help="Run the fuel-cell plant model instead of real hardware")
    parser.add_argument("--fast-log-hz", type=float, default=FAST_LOG_HZ,
                        help="Local sample/log rate independent of Enapter's ~1Hz poll")
    parser.add_argument("--no-fast-log", action="store_true",
                        help="Still sample at --fast-log-hz for /status freshness "
                             "and the direction check, just skip the CSV file")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s  %(levelname)-7s  %(message)s",
        datefmt="%H:%M:%S")

    if args.simulate:
        driver = SimulatedDriver()
    else:
        driver = RegatronDriver(args.com_port, args.baudrate, args.dll)

    if not driver.connect():
        log.error("Could not connect to the Regatron. Start with --simulate "
                  "to test the blueprint without hardware.")
        sys.exit(1)

    STATE = BridgeState(driver=driver, token=args.token)
    STATE.csv_file, STATE.csv_writer = _init_fast_log(not args.no_fast_log, args.fast_log_hz)

    threading.Thread(target=watchdog_loop, daemon=True).start()
    threading.Thread(target=fast_sample_loop, args=(args.fast_log_hz,), daemon=True).start()

    log.info("Bridge listening on http://%s:%d  (token %s)",
             args.host, args.port, "set" if args.token else "NOT set")
    log.info("Point the blueprint's Configure Bridge command at this address.")

    try:
        app.run(host=args.host, port=args.port, threaded=True)
    finally:
        log.info("Shutting down - switching the output off.")
        driver.disconnect()
        if STATE.csv_file is not None:
            try:
                STATE.csv_file.flush()
                STATE.csv_file.close()
            except Exception:
                pass


if __name__ == "__main__":
    main()

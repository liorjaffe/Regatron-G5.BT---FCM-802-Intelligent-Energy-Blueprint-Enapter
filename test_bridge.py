#!/usr/bin/env python3
"""In-process tests for regatron_bridge.py's new safety/logging pieces:
the direction check, the fast-sample cache, and signed vs magnitude current.
Run directly: python3 test_bridge.py
"""
import importlib
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import regatron_bridge as rb


def check(cond, label):
    status = "ok  " if cond else "FAIL"
    print(f"  {status} {label}")
    if not cond:
        raise SystemExit(f"FAILED: {label}")


print("=== 1. Direction check: correct sink direction never trips it ===")
driver = rb.SimulatedDriver()
driver.connect()
driver.output_on()
driver.set_cc(30.0, 48.0)
for _ in range(20):
    v, raw, i_signed = driver.measure()
rb.STATE = rb.BridgeState(driver=driver)
rb._direction_check(driver, i_signed)
check(rb.STATE.estop_latched is False, "correct sink direction (negative) does not trip")
check(driver._output_on is True, "output stays on")
print(f"  (measured current_signed={i_signed:.2f} A, expected sink sign is negative)")

print("\n=== 2. Direction check: reversed sign trips it immediately ===")
driver2 = rb.SimulatedDriver()
driver2.connect()
driver2.output_on()
driver2.set_cc(30.0, 48.0)
driver2.force_wrong_direction = True  # test-only hook: flips the sign
for _ in range(20):
    v, raw, i_signed = driver2.measure()
check(i_signed > 0, "test hook produced a positive (wrong-direction) reading")
rb.STATE = rb.BridgeState(driver=driver2)
rb._direction_check(driver2, i_signed)
check(rb.STATE.estop_latched is True, "wrong direction trips estop_latched")
check(driver2._output_on is False, "output forced off")
check("WRONG DIRECTION" in rb.STATE.estop_reason, "reason clearly states wrong direction")
print(f"  reason: {rb.STATE.estop_reason}")

print("\n=== 3. Direction check: near-zero current never trips (deadband) ===")
driver3 = rb.SimulatedDriver()
driver3.connect()
driver3.output_on()
driver3.set_cc(1.0, 48.0)  # tiny target, well under DIRECTION_CHECK_DEADBAND_A
driver3.force_wrong_direction = True
for _ in range(5):
    v, raw, i_signed = driver3.measure()
check(abs(i_signed) < rb.DIRECTION_CHECK_DEADBAND_A, "current stayed inside the deadband")
rb.STATE = rb.BridgeState(driver=driver3)
rb._direction_check(driver3, i_signed)
check(rb.STATE.estop_latched is False, "near-zero current does not trip even with wrong-direction hook set")

print("\n=== 4. Direction check: idle mode never trips (nothing commanded) ===")
driver4 = rb.SimulatedDriver()
driver4.connect()
rb.STATE = rb.BridgeState(driver=driver4)
rb._direction_check(driver4, 50.0)  # large "reading" but output is off / idle
check(rb.STATE.estop_latched is False, "idle/output-off state is never flagged")

print("\n=== 5. power_w uses magnitude; current_signed_a carries the sign ===")
driver5 = rb.SimulatedDriver()
driver5.connect()
driver5.output_on()
driver5.set_cc(25.0, 48.0)
for _ in range(30):
    v, raw, i_signed = driver5.measure()
power_should_be = v * abs(i_signed)
check(i_signed < 0, "measured current is negative (sink)")
check(power_should_be > 0, "power computed from magnitude is positive")
print(f"  V={v:.2f} I_signed={i_signed:.2f} -> power={power_should_be:.1f} W")

print("\n=== 6. Fast log: CSV rows are written and well-formed ===")
with tempfile.TemporaryDirectory() as tmp:
    old_dir = rb.FAST_LOG_DIR
    rb.FAST_LOG_DIR = tmp
    try:
        driver6 = rb.SimulatedDriver()
        driver6.connect()
        rb.STATE = rb.BridgeState(driver=driver6)
        rb.STATE.csv_file, rb.STATE.csv_writer = rb._init_fast_log(True, 20.0)
        driver6.output_on()
        driver6.set_cc(15.0, 48.0)
        for _ in range(5):
            v, raw, i_signed = driver6.measure()
            power = v * abs(i_signed)
            state = driver6.device_state()
            rb._write_fast_log_row(time.time(), driver6, v, raw, i_signed, power, state)
        rb.STATE.csv_file.flush()
        rb.STATE.csv_file.close()
        files = os.listdir(tmp)
        check(len(files) == 1, "exactly one CSV file created")
        with open(os.path.join(tmp, files[0])) as f:
            lines = f.readlines()
        check(len(lines) == 6, f"header + 5 rows written (got {len(lines)})")
        header = lines[0].strip()
        check("commanded_value" in header and "current_signed_a" in header,
              "header has the commanded-vs-measured columns the brief asks for")
        first_row = lines[1].strip().split(",")
        check(first_row[2] == "cc", "mode column correctly logged")
        check(float(first_row[3]) == 15.0, "commanded_value column matches the setpoint")
        print(f"  sample row: {lines[1].strip()}")
    finally:
        rb.FAST_LOG_DIR = old_dir

print("\n=== 7. CV mode direction check also applies ===")
driver7 = rb.SimulatedDriver()
driver7.connect()
driver7.output_on()
driver7.set_cv(44.0, 40.0)
driver7.force_wrong_direction = True
for _ in range(20):
    v, raw, i_signed = driver7.measure()
rb.STATE = rb.BridgeState(driver=driver7)
rb._direction_check(driver7, i_signed)
check(rb.STATE.estop_latched is True, "wrong-direction current in CV mode also trips")

print("\nALL BRIDGE UNIT TESTS PASSED")

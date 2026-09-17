#!/usr/bin/env python3
"""
check_regatron_dll_on_mac.py
==============================
Read-only diagnostic: does NOT open a serial port, does NOT touch hardware.
It only tries to load Regatron.G5.Api.dll through pythonnet and answers one
question - can this machine even load the assembly at all?

WHERE TO RUN THIS
------------------
On the Mac itself, in a normal terminal (VS Code's integrated terminal is
fine). You first need to COPY the DLL over from the Windows PC:

  1. On the Windows PC, find Regatron.G5.Api.dll (and everything else in
     the same folder - it likely has sibling DLLs it depends on). Copy the
     WHOLE folder, not just the one file, e.g. via AirDrop, a USB stick, or
     a shared network drive.
  2. On the Mac:
       python3 -m venv regatron_dll_check
       source regatron_dll_check/bin/activate
       pip install pythonnet
  3. pythonnet needs an actual .NET runtime present on macOS (it does not
     bundle one). Install it if you don't have it:
       brew install dotnet
     or download the .NET SDK/Runtime installer for macOS from Microsoft.
  4. Run this script, pointing at wherever you copied the DLL folder:
       python3 check_regatron_dll_on_mac.py "/path/to/copied/dll/folder"

WHAT A RESULT MEANS
--------------------
- Fails at "import clr"          -> pythonnet itself isn't installed/working.
- Fails at "load .NET runtime"   -> no .NET runtime on this Mac (install it).
- Fails at "AddReference"        -> the DLL could not be loaded at all. Often
                                     means it's plain old .NET Framework
                                     (Windows-only), not .NET Standard/Core.
- AddReference succeeds but the type imports fail -> the wrapper loaded, but
  something it depends on (frequently a native Windows driver DLL bundled
  alongside it) did not. This is the "looks fine, secretly still Windows-only"
  case a native serial/USB layer would produce.
- Everything succeeds, including G5System.CreateSystem() -> the DLL itself
  is loadable on macOS. Worth trying for real. This still doesn't prove the
  actual USB/serial communication with the Regatron will work over the
  cable - that's the next thing to test, on the bench, with the real unit.
"""

import platform
import sys

RESULTS = []


def step(label):
    """Small helper so every step prints the same way and failures don't
    kill the whole script - we want to see how FAR it gets, not just pass/fail."""
    def decorator(fn):
        def wrapped(*args, **kwargs):
            try:
                value = fn(*args, **kwargs)
                print(f"  OK    {label}")
                RESULTS.append((label, True, None))
                return value
            except Exception as exc:
                print(f"  FAIL  {label}")
                print(f"        -> {type(exc).__name__}: {exc}")
                RESULTS.append((label, False, str(exc)))
                return None
        return wrapped
    return decorator


def main():
    dll_dir = sys.argv[1] if len(sys.argv) > 1 else None

    print("=" * 70)
    print("Regatron DLL macOS compatibility check (read-only, no hardware)")
    print("=" * 70)
    print(f"Python:   {sys.version.split()[0]}")
    print(f"Platform: {platform.platform()}")
    print(f"Machine:  {platform.machine()}")
    print()

    if platform.system() != "Darwin":
        print("(Not actually running on macOS - that's fine, the checks below")
        print(" still tell you whether the DLL loads on THIS machine.)")
        print()

    print("--- step 1: pythonnet itself -------------------------------------")
    print("(pythonnet defaults to Mono on macOS - regardless of whether .NET/")
    print(" dotnet is installed - so this tries coreclr explicitly first, since")
    print(" that's what `brew install dotnet` gives you, then falls back to Mono,")
    print(" which is worth trying too: Regatron's DLL is more likely built against")
    print(" classic .NET Framework, and Mono is the closer match for that.)")
    print()

    def _try_load(runtime_name):
        from pythonnet import load
        load(runtime_name)
        import clr  # noqa: F401
        return clr

    clr = None
    runtime_used = None
    last_errors = {}
    for runtime_name in ("coreclr", "mono"):
        try:
            clr = _try_load(runtime_name)
            runtime_used = runtime_name
            print(f"  OK    import clr (pythonnet) via '{runtime_name}'")
            RESULTS.append((f"import clr via {runtime_name}", True, None))
            break
        except Exception as exc:
            last_errors[runtime_name] = exc
            print(f"  FAIL  import clr (pythonnet) via '{runtime_name}'")
            print(f"        -> {exc}")

    if clr is None:
        print()
        if isinstance(last_errors.get("coreclr"), ModuleNotFoundError) and \
           isinstance(last_errors.get("mono"), ModuleNotFoundError):
            print("Stopped here. pythonnet itself isn't installed:")
            print("    pip install pythonnet")
        else:
            print("Stopped here. pythonnet is installed, but neither runtime is")
            print("available for it to host. Install ONE of these, then run this")
            print("script again:")
            print()
            print("  .NET (recommended to try first):")
            print("    brew install dotnet")
            print()
            print("  Mono (closer match if the DLL turns out to be classic .NET")
            print("  Framework - worth having as a second option, and note Homebrew's")
            print("  Mono build has known issues on Apple Silicon; if `brew install mono`")
            print("  doesn't fix it, that itself is useful information, not a dead end):")
            print("    brew install mono")
        RESULTS.append(("import clr (pythonnet)", False, str(last_errors)))
        return

    @step("report pythonnet / runtime info")
    def _runtime_info():
        try:
            from pythonnet import get_runtime_info
            info = get_runtime_info()
            print(f"        runtime: {info}")
        except Exception:
            print(f"        (loaded via '{runtime_used}', couldn't introspect further)")

    _runtime_info()

    print()
    print("--- step 2: load the assembly --------------------------------------")

    if dll_dir is None:
        print("  No DLL folder given. Re-run as:")
        print('    python3 check_regatron_dll_on_mac.py "/path/to/dll/folder"')
        print()
        print("Stopping here - steps 1 passed, which already tells you pythonnet")
        print("itself works on this Mac. Come back with a path to finish the check.")
        return

    import os
    dll_path = os.path.join(dll_dir, "Regatron.G5.Api.dll")

    @step(f"find {dll_path}")
    def _find_dll():
        if not os.path.isfile(dll_path):
            raise FileNotFoundError(dll_path)
        return dll_path

    found = _find_dll()
    if found is None:
        print()
        print(f"  Files actually in {dll_dir}:")
        try:
            for name in sorted(os.listdir(dll_dir)):
                print(f"    {name}")
        except Exception as exc:
            print(f"    (couldn't list that folder: {exc})")
        return

    @step("clr.AddReference(Regatron.G5.Api)")
    def _add_reference():
        if dll_dir not in sys.path:
            sys.path.append(dll_dir)
        clr.AddReference(os.path.splitext(dll_path)[0])

    ref_ok = _add_reference()

    print()
    print("--- step 3: import the actual types --------------------------------")

    @step("from Regatron.G5.Api import G5ApiException")
    def _import_exception_type():
        from Regatron.G5.Api import G5ApiException
        return G5ApiException

    @step("from Regatron.G5.Api.System import G5System")
    def _import_system_type():
        from Regatron.G5.Api.System import G5System
        return G5System

    @step("from Regatron.G5.Common import ControllerMode")
    def _import_controller_mode():
        from Regatron.G5.Common import ControllerMode
        return ControllerMode

    _import_exception_type()
    G5System = _import_system_type()
    _import_controller_mode()

    if G5System is not None:
        print()
        print("--- step 4: create a system object (still no hardware access) -----")

        @step("G5System.CreateSystem()")
        def _create_system():
            return G5System.CreateSystem()

        _create_system()

    print()
    print("=" * 70)
    failed = [label for label, ok, _ in RESULTS if not ok]
    if not failed:
        print("ALL CHECKS PASSED. The DLL loads on this Mac.")
        print("Next real test: actually connecting to the Regatron over its USB")
        print("cable from here - that's the part this script deliberately doesn't")
        print("touch, since it needs the real unit connected.")
    else:
        print(f"Stopped at: {failed[0]}")
        print("See the WHAT A RESULT MEANS section at the top of this file for")
        print("what that particular failure usually indicates.")
    print("=" * 70)


if __name__ == "__main__":
    main()

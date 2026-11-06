"""Bounded real-device check using the Mac package's full acquisition pipeline."""
import asyncio
import argparse
from datetime import datetime
from collections import Counter
import json
import multiprocessing as mp
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "KSEEG102_Python_Mac"))
from eeg_python_viewer import PythonAcquisition


async def main(args):
    from bleak import BleakScanner
    found = await BleakScanner.discover(timeout=15, return_adv=True)
    matches = [dev for dev, ad in found.values()
               if dev.address == "A85452DE-6B4B-10B9-3C77-02E31DD14073"]
    if len(matches) != 1:
        print("Known headset not advertising; no connection attempted", flush=True)
        return 2
    acq = PythonAcquisition.__new__(PythonAcquisition)
    acq.loop = asyncio.get_running_loop()
    acq.stop_event = asyncio.Event()
    acq.ble_profile = args.ble_profile
    counts = Counter()
    errors = []
    first_raw = last_raw = None
    raw_max_gap = 0
    output = Path(args.recording)
    started = time.monotonic()
    with output.open("x", encoding="utf-8") as recording:
        def emit(event, value):
            nonlocal first_raw, last_raw, raw_max_gap
            if event == "packet":
                counts[value["kind"]] += 1
                if value["kind"] == "raw":
                    received = datetime.fromisoformat(value["received_at"]).timestamp()
                    if last_raw is not None:
                        raw_max_gap = max(raw_max_gap, received-last_raw)
                    first_raw = received if first_raw is None else first_raw
                    last_raw = received
                recording.write(json.dumps({"source": "ble", **value}, ensure_ascii=False) + "\n")
            else:
                print(event, value, flush=True)
                if event == "algorithm_error" or (event == "status" and "采集失败" in value):
                    errors.append(value)
        acq.emit = emit
        window_completed = False
        ready_at = None
        def finish_window():
            nonlocal window_completed
            window_completed = True
            acq.stop_event.set()
        timer = None
        original_emit = emit
        def timed_emit(event, value):
            nonlocal timer, ready_at
            if event == "ready":
                ready_at = time.monotonic()
                timer = acq.loop.call_later(args.duration, finish_window)
            original_emit(event, value)
        acq.emit = timed_emit
        watchdog = acq.loop.call_later(args.duration + 45, acq.stop_event.set)
        try:
            await acq.session("ble", matches[0], algorithms=True)
        finally:
            if timer:
                timer.cancel()
            watchdog.cancel()
    elapsed = time.monotonic() - started
    last_raw_age = time.time()-last_raw if last_raw is not None else None
    print(json.dumps({"elapsed_s": elapsed, "packets": dict(counts),
                      "accepted": acq.accepted, "processed": acq.processed,
                      "profile": args.ble_profile, "completed_window": window_completed,
                      "ready_elapsed_s": time.monotonic()-ready_at if ready_at else None,
                      "raw_span_s": last_raw-first_raw if first_raw is not None else 0,
                      "raw_max_gap_s": raw_max_gap, "last_raw_age_s": last_raw_age,
                      "errors": errors, "recording": str(output)}), flush=True)
    return 0 if (window_completed and counts["raw"] and not errors
                 and acq.accepted == acq.processed and raw_max_gap <= 5
                 and last_raw_age is not None and last_raw_age <= 5) else 1


if __name__ == "__main__":
    mp.freeze_support()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording")
    parser.add_argument("--duration", type=float, default=60)
    parser.add_argument("--ble-profile", choices=("mac-passive-raw", "sdk-standard"), default="mac-passive-raw")
    raise SystemExit(asyncio.run(main(parser.parse_args())))

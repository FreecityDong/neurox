"""Exercise the real Tk viewer against the known headset; never uses demo data."""
import argparse
import json
import multiprocessing as mp
from pathlib import Path
import sys
import time
import tkinter as tk

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "KSEEG102_Python_Mac"))
from eeg_python_viewer import PythonViewer


def main(args):
    root = tk.Tk()
    viewer = PythonViewer(root)
    viewer.acquisition.ble_profile = "mac-passive-raw"
    viewer.acquisition.monitor_rssi = args.monitor_rssi
    deadline = time.monotonic()+30
    connected = False
    verified = False
    failed = False

    def save_result(result, **fields):
        payload = {"result": result, "source": "ble", "profile": "mac-passive-raw",
                   "raw_packets": viewer.packets, "samples_per_channel": viewer.samples,
                   "status": viewer.status.get(), **fields}
        Path(args.result).write_text(json.dumps(payload, ensure_ascii=False, indent=2)+"\n")
        print(json.dumps(payload, ensure_ascii=False), flush=True)

    def check():
        nonlocal connected, deadline, verified, failed
        now = time.monotonic()
        if not connected:
            if not viewer.scanning:
                matches = [(i, dev) for i, dev in enumerate(viewer.devices)
                           if dev.address == args.address]
                if matches:
                    viewer.device_box.current(matches[0][0])
                    viewer.connect()
                    viewer.recording = Path(args.recording).open("x", encoding="utf-8", buffering=1)
                    viewer.record_label.set("停止录制 ●")
                    connected = True
                    deadline = now+35
                else:
                    failed = True
                    save_result("headset_not_found")
                    viewer.close()
                    return
        elif not verified:
            if viewer.ready_at and now-viewer.ready_at >= args.duration:
                if (viewer.samples >= 256 and viewer.python_bands is not None
                        and viewer.last_raw_at and now-viewer.last_raw_at <= 5 and viewer.active):
                    save_result("passed", ready_seconds=now-viewer.ready_at,
                                metrics=viewer.metrics.get(), scores=viewer.features.get(),
                                algorithms=viewer.algorithm_info.get())
                    verified = True
                    if not args.keep_open:
                        viewer.close()
                        return
                else:
                    failed = True
                    save_result("failed_data_or_algorithms")
                    viewer.close()
                    return
            elif (not viewer.active or (not viewer.ready_at and now>deadline)):
                failed = True
                save_result("failed_connection")
                viewer.close()
                return
        if not verified:
            root.after(250, check)

    def begin():
        viewer.search()
        root.after(250, check)
    root.after(100, begin)
    root.mainloop()
    return 1 if failed or not verified else 0


if __name__ == "__main__":
    mp.freeze_support()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address", default="A85452DE-6B4B-10B9-3C77-02E31DD14073")
    parser.add_argument("--duration", type=float, default=60)
    parser.add_argument("--recording", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--keep-open", action="store_true")
    parser.add_argument("--monitor-rssi", action="store_true", help="Read actual connected RSSI once per second on macOS")
    raise SystemExit(main(parser.parse_args()))

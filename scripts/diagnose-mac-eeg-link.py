"""Real BLE idle-link isolation: discover services, send no EEG commands."""
import argparse
import asyncio
from datetime import datetime
import json
from pathlib import Path
import sys
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "KSEEG102_Python_Mac"))
from kseeg_parser import SERVICE_UUID, NOTIFY_UUIDS


def report(event, **fields):
    print(json.dumps({"at": datetime.now().astimezone().isoformat(),
                      "event": event, **fields}, ensure_ascii=False), flush=True)


async def main(args):
    from bleak import BleakScanner, BleakClient
    report("scan_start", seconds=args.scan_seconds, mode=args.mode)
    devices = await BleakScanner.discover(timeout=args.scan_seconds, return_adv=True)
    match = next((dev for dev, ad in devices.values() if dev.address == args.address), None)
    if match is None:
        report("headset_not_found", devices=len(devices))
        return 2
    report("headset_found", address=match.address, name=match.name)
    loop = asyncio.get_running_loop()
    disconnected = asyncio.Event()
    def on_disconnect(_):
        report("disconnected_callback")
        loop.call_soon_threadsafe(disconnected.set)
    started = time.monotonic()
    raw_count = 0
    first_raw = None
    last_raw = None
    max_gap = 0
    recording = None
    def raw_packet(_, data):
        nonlocal raw_count, first_raw, last_raw, max_gap
        now = time.monotonic()
        raw_count += 1
        if last_raw is not None:
            max_gap = max(max_gap, now-last_raw)
        first_raw = first_raw if first_raw is not None else now
        last_raw = now
        if recording:
            recording.write(json.dumps({"at": datetime.now().astimezone().isoformat(),
                                        "kind": "raw", "hex": bytes(data).hex(),
                                        "source": "ble", "mode": args.mode}) + "\n")
        if raw_count == 1:
            report("first_raw", length=len(data))
    try:
        async with BleakClient(match, services=[SERVICE_UUID], timeout=20,
                               disconnected_callback=on_disconnect) as client:
            ready = time.monotonic()
            report("connected", connection_seconds=ready-started, mtu=client.mtu_size,
                   characteristics=[{"uuid": char.uuid, "properties": char.properties}
                                    for service in client.services for char in service.characteristics])
            if args.mode == "passive-raw":
                if args.recording:
                    recording = Path(args.recording).open("x", encoding="utf-8", buffering=1)
                await client.start_notify(NOTIFY_UUIDS["raw"], raw_packet)
                report("raw_subscribed_no_commands")
            try:
                await asyncio.wait_for(disconnected.wait(), timeout=args.duration)
            except asyncio.TimeoutError:
                report("window_completed", seconds=time.monotonic()-ready, raw_packets=raw_count,
                       raw_max_gap_seconds=max_gap)
                return 0 if args.mode == "idle" or raw_count > 0 else 1
            report("disconnected_early", seconds=time.monotonic()-ready, raw_packets=raw_count,
                   raw_max_gap_seconds=max_gap)
            return 1
    except Exception as exc:
        traceback.print_exc()
        report("connection_failed", error=type(exc).__name__, message=str(exc),
               elapsed=time.monotonic()-started)
        return 1
    finally:
        if recording:
            recording.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address", default="A85452DE-6B4B-10B9-3C77-02E31DD14073")
    parser.add_argument("--duration", type=float, default=30)
    parser.add_argument("--scan-seconds", type=float, default=15)
    parser.add_argument("--mode", choices=["idle", "passive-raw"], default="idle")
    parser.add_argument("--recording")
    raise SystemExit(asyncio.run(main(parser.parse_args())))

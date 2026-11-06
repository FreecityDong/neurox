"""Run the existing eegTest Acquisition.live path for a bounded hardware check."""
from __future__ import annotations

import argparse
import asyncio
from collections import Counter
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'eegTest'))
from eeg_viewer import Acquisition


async def main(seconds: float):
    from bleak import BleakScanner
    print('Scanning for kseeg102 (10 seconds); disconnect Chrome first.', flush=True)
    found = await BleakScanner.discover(timeout=10, return_adv=True)
    matches = [device for device, adv in found.values()
               if 'kseeg102' in (adv.local_name or device.name or '').lower()]
    if len(matches) != 1:
        print(json.dumps({'result': 'selection_required', 'matching_devices': len(matches),
                          'message': 'Use the Python viewer to choose the device.'}), flush=True)
        return 2
    # Reuse the original connection, notification and parsing implementation.
    acquisition = Acquisition.__new__(Acquisition)
    acquisition.stop_event = asyncio.Event()
    acquisition.algorithms = None
    counts, lengths = Counter(), Counter()
    started = time.monotonic()
    last_raw = None
    max_gap = 0.0
    last_report = started

    def emit(event, value):
        nonlocal last_raw, max_gap, last_report
        now = time.monotonic()
        if event == 'packet':
            counts[value['kind']] += 1
            lengths[f"{value['kind']}:{len(value['hex']) // 2}"] += 1
            if value['kind'] == 'raw':
                if last_raw is not None:
                    max_gap = max(max_gap, now - last_raw)
                last_raw = now
            if now - last_report >= 5:
                print(json.dumps({'elapsed_s': round(now-started, 1), 'packets': dict(counts),
                                  'raw_max_gap_s': round(max_gap, 3)}), flush=True)
                last_report = now
        else:
            print(json.dumps({'event': event, 'message': value}, ensure_ascii=False), flush=True)

    acquisition.emit = emit
    timed_out = False
    try:
        await asyncio.wait_for(acquisition.live(matches[0]), timeout=seconds)
    except asyncio.TimeoutError:
        timed_out = True
    summary = {'result': 'completed_window' if timed_out else 'disconnected_early',
               'elapsed_s': round(time.monotonic()-started, 1), 'packets': dict(counts),
               'notification_lengths': dict(lengths), 'samples_per_channel': counts['raw'] * 16,
               'raw_max_gap_s': round(max_gap, 3)}
    print(json.dumps(summary), flush=True)
    return 0 if timed_out and counts['raw'] > 0 else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, default=60)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 600:
        parser.error('--seconds must be between 1 and 600')
    sys.exit(asyncio.run(main(args.seconds)))

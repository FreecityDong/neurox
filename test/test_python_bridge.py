"""Mock GATT tests; these do not prove real hardware connectivity."""
import asyncio
import importlib.util
import json
from pathlib import Path
import queue
import struct
import sys
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('eeg_browser_bridge', Path(__file__).resolve().parents[1] / 'scripts/eeg_browser_bridge.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeClient:
    writes = []
    callbacks = {}

    def __init__(self, device, **kwargs):
        if kwargs.get('services') != [module.SERVICE_UUID]:
            raise AssertionError('EEG service filtering is required')
        self.services = self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass

    def get_characteristic(self, uuid):
        return types.SimpleNamespace(uuid=uuid, properties=['write'])

    async def start_notify(self, char, callback):
        self.callbacks[char.uuid] = callback

    async def write_gatt_char(self, char, data, **kwargs):
        self.writes.append(bytes(data).hex())
        if data == b'\x45':
            payload = b'\0\0\0\x64' + struct.pack('>32H', *([30000, 31000] * 16)) + b'\0'
            for _ in range(16):
                self.callbacks[module.NOTIFY_UUIDS['raw']](None, payload)


class BridgeTests(unittest.TestCase):
    def test_real_path_notifications_algorithms_and_disconnect(self):
        bridge = module.Bridge()
        sink = bridge.attach()
        try:
            with self.assertRaises(RuntimeError):
                bridge.attach()
            FakeClient.writes, FakeClient.callbacks = [], {}
            device = types.SimpleNamespace(address='mock-id', name='kseeg102')
            bridge.devices[device.address] = device
            with patch.dict(sys.modules, {'bleak': types.SimpleNamespace(BleakClient=FakeClient)}):
                asyncio.run_coroutine_threadsafe(bridge.command('connect', {'address': device.address}), bridge.loop).result(3)
                packets, updates = [], []
                while not updates:
                    event = sink.get(timeout=5)
                    if event['type'] == 'packet':
                        packets.append(event)
                    if event['type'] == 'algorithm' and event['updates']:
                        updates.extend(event['updates'])
                self.assertEqual(FakeClient.writes, ['35', '45'])
                self.assertEqual(len(packets), 16)
                self.assertEqual(len(packets[0]['bytes']), 69)
                self.assertEqual(packets[-1]['sequence'], 16)
                self.assertIn('fuzzy_entropy_1', updates[0])
                # All SSE payloads must be strict JSON, even non-finite DLL semantics.
                json.dumps(module.finite_json(updates), allow_nan=False)
                asyncio.run_coroutine_threadsafe(bridge.disconnect(), bridge.loop).result(3)
                self.assertEqual(bridge.phase, 'disconnected')
        finally:
            asyncio.run_coroutine_threadsafe(bridge.disconnect(), bridge.loop).result(3)
            bridge.executor.shutdown(wait=True, cancel_futures=True)
            bridge.loop.call_soon_threadsafe(bridge.loop.stop)
            bridge.thread.join(timeout=3)
            bridge.loop.close()

    def test_nonfinite_json_is_not_emitted_as_invalid_json(self):
        self.assertEqual(module.finite_json({'x': [float('nan'), float('inf'), 1]}), {'x': [None, None, 1]})


if __name__ == '__main__':
    unittest.main()

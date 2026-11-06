"""Local-only Flutter web host and real Bleak/SSE transport (no native DLL)."""
from __future__ import annotations

import argparse
import asyncio
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import math
from pathlib import Path
import queue
import sys
import threading
import time
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'eegTest/EEG_DLL_Analysis/python'))
from eeg_portable import PortableAlgorithms
from kseeg_parser import SERVICE_UUID, WRITE_UUID, NOTIFY_UUIDS, parse_packet


def finite_json(value):
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, dict):
        return {key: finite_json(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [finite_json(item) for item in value]
    return value


class Bridge:
    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()
        self.sinks = set()
        self.lock = threading.Lock()
        self.devices = {}
        self.session = 0
        self.sequence = 0
        self.address = None
        self.phase = 'disconnected'
        self.message = 'Python 蓝牙桥接已就绪，搜索并选择设备'
        self.task = None
        self.scanning = False
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='eeg-algorithms')

    def status(self):
        return dict(supported=True, enabled=True, permissionsGranted=True,
                    permanentlyDenied=False, locationRequired=False, locationEnabled=True,
                    browserPicker=False, pythonBridge=True, simulated=False)

    def emit(self, kind, **fields):
        event = dict(type=kind, **fields)
        with self.lock:
            for sink in tuple(self.sinks):
                try:
                    sink.put_nowait(event)
                except queue.Full:
                    # Stop capture rather than silently discard EEG for a slow client.
                    while not sink.empty():
                        sink.get_nowait()
                    sink.put_nowait(dict(type='error', message='页面接收积压，采集已停止，请重新连接'))
                    self.loop.call_soon_threadsafe(lambda: asyncio.create_task(self.disconnect()))

    def state(self, state, message):
        self.phase, self.message = state, message
        print(f'{state}: {message}', flush=True)
        self.emit('connection', state=state, message=message,
                  address=self.address, session=self.session)

    async def command(self, method, args):
        if method in ('access', 'requestAccess', 'enableBluetooth'):
            return self.status()
        if method == 'scan':
            if self.task and not self.task.done():
                raise RuntimeError('请先断开设备再搜索')
            if self.scanning:
                raise RuntimeError('正在搜索，请稍候')
            from bleak import BleakScanner
            self.scanning = True
            self.emit('scan', scanning=True)
            try:
                found = await BleakScanner.discover(timeout=6, return_adv=True)
                self.devices = {dev.address: dev for dev, _ in found.values()}
                for dev, adv in found.values():
                    self.emit('device', address=dev.address, name=adv.local_name or dev.name or '',
                              rssi=adv.rssi, advertisesService=SERVICE_UUID in adv.service_uuids)
                print(f'scan: {len(self.devices)} devices', flush=True)
            finally:
                self.scanning = False
                self.emit('scan', scanning=False)
            return None
        if method == 'stopScan':
            return None  # Bounded six-second scan; UI remains busy until completion.
        if method == 'connect':
            if self.scanning:
                raise RuntimeError('请等待搜索完成')
            device = self.devices.get(args.get('address'))
            if device is None:
                raise RuntimeError('请先搜索并选择设备')
            await self.disconnect()
            self.address = device.address
            self.session += 1
            self.sequence = 0
            self.task = asyncio.create_task(self.capture(device, self.session))
            return None
        if method == 'disconnect':
            await self.disconnect()
            return None
        raise RuntimeError('此操作由网页处理，或尚不支持：' + method)

    async def disconnect(self):
        task, self.task = self.task, None
        if task and not task.done():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def capture(self, device, session):
        from bleak import BleakClient
        stopped = asyncio.Event()
        pipeline = PortableAlgorithms()
        work = asyncio.Queue(maxsize=1024)
        worker = None

        async def process():
            while True:
                payload = await work.get()
                try:
                    data = parse_packet('raw', payload)
                    result = await self.loop.run_in_executor(
                        self.executor, pipeline.process, data['channel_1'], data['channel_2'])
                    if session == self.session:
                        self.emit('algorithm', address=device.address, session=session,
                                  **finite_json(result), receivedAt=int(time.time() * 1000))
                except Exception as exc:
                    self.emit('error', message=f'还原算法处理失败：{exc}')
                finally:
                    work.task_done()

        def notification(kind, uuid, payload):
            if stopped.is_set() or session != self.session:
                return
            self.sequence += 1
            self.emit('packet', uuid=uuid, bytes=list(payload), receivedAt=int(time.time()*1000),
                      sequence=self.sequence, session=session, address=device.address)
            if kind == 'raw':
                try:
                    work.put_nowait(bytes(payload))
                except asyncio.QueueFull:
                    self.emit('error', message='还原算法队列已满，已停止采集以避免丢弃通知')
                    stopped.set()

        try:
            self.state('connecting', 'Python/Bleak 正在连接 ' + (device.name or '设备'))
            async with BleakClient(device, timeout=20, services=[SERVICE_UUID],
                                   disconnected_callback=lambda _: self.loop.call_soon_threadsafe(stopped.set)) as client:
                self.state('configuring', 'Python 正在核对并订阅 EEG 特征')
                worker = asyncio.create_task(process())
                for kind in ('raw', 'frequency', 'feature'):
                    uuid = NOTIFY_UUIDS[kind]
                    char = client.services.get_characteristic(uuid)
                    if char is None:
                        if kind == 'raw':
                            raise RuntimeError('未找到 KSEEG102 原始 EEG 特征')
                        continue
                    await asyncio.wait_for(client.start_notify(
                        char, lambda _, data, k=kind, u=uuid: notification(k, u, data)), 15)
                    self.emit('log', message=f'Python {kind} 订阅完成')
                write = client.services.get_characteristic(WRITE_UUID)
                if write is None:
                    raise RuntimeError('未找到 KSEEG102 控制特征')
                for command in (b'\x35', b'\x45'):
                    await asyncio.wait_for(client.write_gatt_char(write, command,
                                                                  response='write' in write.properties), 15)
                    self.emit('log', message=f'Python 初始化 {command.hex()} 已写入')
                self.state('ready', 'Python 已连接，等待真实脑电通知')
                await stopped.wait()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.state('error', f'Python 蓝牙失败：{exc}')
        finally:
            stopped.set()
            if worker:
                worker.cancel()
                await asyncio.gather(worker, return_exceptions=True)
            if self.phase != 'error':
                self.state('disconnected', 'Python 蓝牙已断开，采集已停止')

    def attach(self):
        sink = queue.Queue(maxsize=1024)
        with self.lock:
            if self.sinks:
                raise RuntimeError('已有网页控制此桥接，请关闭其它桥接页面后重试')
            self.sinks.add(sink)
        sink.put(dict(type='adapter', **self.status()))
        sink.put(dict(type='connection', state=self.phase, message=self.message,
                      address=self.address, session=self.session))
        return sink

    def detach(self, sink):
        with self.lock:
            self.sinks.discard(sink)

        async def cleanup():
            await asyncio.sleep(3)
            with self.lock:
                empty = not self.sinks
            if empty:
                await self.disconnect()
        asyncio.run_coroutine_threadsafe(cleanup(), self.loop)


class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def allowed(self):
        host = self.headers.get('Host', '')
        origin = self.headers.get('Origin')
        return host in self.server.allowed_hosts and (not origin or origin == f'http://{host}')

    def reply(self, code, value):
        body = json.dumps(finite_json(value), ensure_ascii=False, allow_nan=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.allowed():
            return self.reply(403, {'error': '仅允许本机同源访问'})
        path = urlparse(self.path).path
        if path == '/api/status':
            return self.reply(200, self.server.bridge.status())
        if path != '/api/events':
            return super().do_GET()
        bridge = self.server.bridge
        try:
            sink = bridge.attach()
        except RuntimeError as exc:
            return self.reply(409, {'error': str(exc)})
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
        self.end_headers()
        try:
            while True:
                try:
                    event = sink.get(timeout=1)
                    body = 'data: ' + json.dumps(finite_json(event), ensure_ascii=False, allow_nan=False) + '\n\n'
                except queue.Empty:
                    body = ': heartbeat\n\n'
                self.wfile.write(body.encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            bridge.detach(sink)

    def do_POST(self):
        if not self.allowed():
            return self.reply(403, {'error': '仅允许本机同源访问'})
        if urlparse(self.path).path != '/api/command':
            return self.reply(404, {'error': 'unknown endpoint'})
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 4096:
                raise ValueError('Invalid request size')
            data = json.loads(self.rfile.read(length))
            future = asyncio.run_coroutine_threadsafe(
                self.server.bridge.command(data['method'], data.get('args', {})), self.server.bridge.loop)
            try:
                result = future.result(timeout=30)
            except TimeoutError:
                future.cancel()
                raise RuntimeError('Python 操作超时')
            self.reply(200, {'result': result})
        except Exception as exc:
            self.reply(400, {'error': str(exc)})

    def list_directory(self, path):
        self.send_error(404)
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=7359)
    args = parser.parse_args()
    if not (ROOT / 'build/web/index.html').is_file():
        parser.error('先运行 flutter build web --debug --no-web-resources-cdn')
    bridge = Bridge()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, directory=str(ROOT / 'build/web')))
    server.bridge = bridge
    server.allowed_hosts = {f'127.0.0.1:{args.port}', f'localhost:{args.port}'}
    print(f'NeuroX Python BLE: http://127.0.0.1:{args.port}/?transport=python', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        asyncio.run_coroutine_threadsafe(bridge.disconnect(), bridge.loop).result(timeout=10)
        server.server_close()
        bridge.executor.shutdown(wait=False, cancel_futures=True)
        bridge.loop.call_soon_threadsafe(bridge.loop.stop)


if __name__ == '__main__':
    main()

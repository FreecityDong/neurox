/* KSEEG102 Web Bluetooth transport. Simulation is opt-in and always labelled. */
(() => {
  'use strict';
  const suffix = '-43e6-47b7-9cb0-5fc21d4ae340';
  const ids = {service: '8653000a' + suffix, raw: '8653000b' + suffix,
    write: '8653000c' + suffix, feature: '8653000d' + suffix, frequency: '8653000e' + suffix};
  class NeuroxBleAdapter {
    constructor() {
      this.listener = null;
      this.devices = new Map();
      this.device = null;
      this.listeners = [];
      this.generation = 0;
      this.session = 0;
      this.sequence = 0;
      this.preview = false;
      this.recording = false;
      this.rows = [];
      this.recordBytes = 0;
      this.fileName = null;
      this.timer = null;
      this.phase = 'disconnected';
      this.removeDisconnect = null;
      globalThis.document?.addEventListener('visibilitychange', () => {
        if (this.device) this.emit('log', {message: document.hidden
          ? '页面已切到后台，保留蓝牙连接；浏览器休眠可能暂停采集'
          : '页面已回到前台，蓝牙连接未主动中断'});
      });
      globalThis.addEventListener?.('pagehide', () => this.disconnect('页面已关闭'));
    }
    emit(type, fields = {}) { this.listener?.({type, ...fields}); }
    status() {
      const supported = this.preview || (globalThis.isSecureContext === true && !!globalThis.navigator?.bluetooth?.requestDevice);
      return {supported, enabled: supported, permissionsGranted: this.preview || this.devices.size > 0,
        permanentlyDenied: false, locationRequired: false, locationEnabled: true,
        browserPicker: true, simulated: this.preview};
    }
    listen(callback) { this.listener = callback; this.emit('adapter', this.status()); }
    cancel() { this.listener = null; this.disconnect('页面已关闭'); }
    state(state, message) {
      this.phase = state;
      this.emit('connection', {state, message, session: this.session, address: this.device?.id ?? null});
    }
    failure(error) {
      const name = error?.name ?? '';
      if (name === 'NotFoundError') return '已取消选择或未找到设备，可重新选择。请确认设备已开机且没有被其他 App 占用。';
      if (name === 'SecurityError' || name === 'NotAllowedError') return '浏览器未允许蓝牙访问。请使用本机 Chrome，在设备选择框中授权，并检查电脑的蓝牙隐私权限。';
      if (name === 'NetworkError') return '蓝牙连接中断，请关闭其他占用设备的程序，再重新连接。';
      return error?.message ?? String(error);
    }
    async invoke(method, args = {}) {
      switch (method) {
        case 'access': case 'requestAccess': case 'enableBluetooth': return this.status();
        case 'scan': return this.chooseDevice();
        case 'stopScan': this.emit('scan', {scanning: false}); return null;
        case 'connect': {
          const device = this.preview && args.address === 'preview-kseeg102'
            ? {id: 'preview-kseeg102', name: 'KSEEG102 · 模拟设备'} : this.devices.get(args.address);
          if (!device) throw new Error('请先通过浏览器选择并授权设备');
          this.beginConnect(device); return null;
        }
        case 'disconnect': this.disconnect('已主动断开，采集已停止'); return null;
        case 'openSettings': case 'openLocationSettings':
          throw new Error('请在 Chrome 网站设置和电脑系统的蓝牙隐私设置中允许访问。');
        case 'setPreview':
          this.disconnect('已切换连接模式'); this.preview = args.enabled === true;
          this.emit('adapter', this.status()); return this.status();
        case 'startRecording': {
          if (this.phase !== 'ready') throw new Error('请先连接设备');
          if (this.recording) throw new Error('已在记录中');
          this.rows = []; this.recordBytes = 0; this.recording = true;
          this.fileName = `${this.preview ? 'preview-' : ''}KSEEG102-web-${Date.now()}.jsonl`;
          this.emit('recording', {active: true, name: this.fileName}); return this.fileName;
        }
        case 'stopRecording': this.stopRecording(); return this.fileName;
        case 'exportRecording': {
          if (this.recording) throw new Error('请先停止记录');
          if (!this.fileName) throw new Error('还没有可导出的记录');
          const blob = new Blob(this.rows, {type: 'application/x-ndjson;charset=utf-8'});
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a'); a.href = url; a.download = this.fileName;
          document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 10000);
          return true;
        }
        default: throw new Error(`未知蓝牙操作：${method}`);
      }
    }
    async chooseDevice() {
      if (!this.status().supported) throw new Error('当前浏览器未开放 Web Bluetooth，请用本机 Chrome 打开 localhost 地址。');
      if (this.device) throw new Error('请先断开当前设备');
      this.emit('scan', {scanning: true});
      try {
        let device;
        if (this.preview) {
          await new Promise(resolve => setTimeout(resolve, 350));
          device = {id: 'preview-kseeg102', name: 'KSEEG102 · 模拟设备'};
        } else {
          // This call runs directly from the user's button gesture, before any await.
          // acceptAllDevices retains unnamed / non-service-advertising firmware;
          // the actual EEG service is validated after connection.
          device = await navigator.bluetooth.requestDevice({acceptAllDevices: true, optionalServices: [ids.service]});
          this.devices.set(device.id, device);
        }
        this.emit('device', {address: device.id, name: device.name ?? '', rssi: null,
          advertisesService: false});
        this.emit('adapter', this.status());
        return null;
      } catch (error) { throw new Error(this.failure(error)); }
      finally { this.emit('scan', {scanning: false}); }
    }
    beginConnect(device) {
      this.disconnect('准备连接');
      this.device = device; this.session++; this.sequence = 0;
      const generation = this.generation;
      this.state('connecting', this.preview ? '正在连接模拟设备…' : '正在通过电脑蓝牙连接设备…');
      const current = () => this.generation === generation && this.device === device;
      if (this.preview) { this.startPreview(current); return; }
      const disconnected = () => { if (current()) this.disconnect('设备已断开，采集已停止'); };
      device.addEventListener('gattserverdisconnected', disconnected);
      this.removeDisconnect = () => device.removeEventListener('gattserverdisconnected', disconnected);
      this.connectReal(device, current).catch(error => {
        if (!current()) return;
        const message = this.failure(error);
        this.disconnect(message); this.state('error', message);
      });
    }
    async step(promise, label, current) {
      let timeout;
      try {
        const value = await Promise.race([promise, new Promise((_, reject) => {
          timeout = setTimeout(() => reject(new Error(`${label}超时，请检查设备并重试`)), 15000);
        })]);
        if (!current()) throw new Error('连接已取消');
        return value;
      } finally { clearTimeout(timeout); }
    }
    async connectReal(device, current) {
      const pendingConnection = device.gatt.connect();
      pendingConnection.then(server => { if (!current()) server.disconnect(); }, () => {});
      const server = await this.step(pendingConnection, '连接设备', current);
      this.state('discovering', '正在核对 KSEEG102 EEG 服务…');
      const service = await this.step(server.getPrimaryService(ids.service), '发现 EEG 服务', current);
      this.emit('log', {message: '已核对 KSEEG102 服务 8653000a'});
      const raw = await this.step(service.getCharacteristic(ids.raw), '查找原始 EEG 特征', current);
      const write = await this.step(service.getCharacteristic(ids.write), '查找控制特征', current);
      this.state('configuring', '正在订阅真实设备通知…');
      for (const [kind, id] of [['raw', ids.raw], ['frequency', ids.frequency], ['feature', ids.feature]]) {
        let characteristic;
        if (kind === 'raw') characteristic = raw;
        else {
          try { characteristic = await this.step(service.getCharacteristic(id), '查找设备指标', current); }
          catch (error) {
            if (!current() || error?.name !== 'NotFoundError') throw error;
            this.emit('log', {message: `设备未提供 ${kind} 特征`}); continue;
          }
        }
        const callback = event => {
          if (!current()) return;
          try {
            const value = event.target.value;
            const bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice();
            if (!received) {
              received = true;
              this.emit('log', {message: `首次 ${kind} 通知：${bytes.length} 字节`});
            }
            this.packet(id, bytes);
          } catch (error) {
            this.emit('error', {message: `${kind} 通知处理失败：${this.failure(error)}`});
          }
        };
        let received = false;
        characteristic.addEventListener('characteristicvaluechanged', callback);
        this.listeners.push([characteristic, callback]);
        await this.step(characteristic.startNotifications(), '订阅通知', current);
        this.emit('log', {message: `${kind} 通知订阅完成`});
      }
      // Chrome handles ATT MTU internally and does not expose requestMtu. Do not
      // invent its value. Dart validates every complete notification's length.
      for (const command of [0x35, 0x45]) {
        const data = new Uint8Array([command]);
        if (write.properties.write) await this.step(write.writeValueWithResponse(data), '写入初始化命令', current);
        else if (write.properties.writeWithoutResponse) {
          await this.step(write.writeValueWithoutResponse(data), '发送初始化命令', current);
          await this.step(new Promise(resolve => setTimeout(resolve, 300)), '等待初始化命令', current);
        } else throw new Error('设备控制特征不支持写入');
        this.emit('log', {message: `初始化 0x${command.toString(16)} 已写入（${write.properties.write ? '有响应' : '无响应'}）`});
        // Official Android SDK g() leaves 100 ms between magnify and light.
        if (command === 0x35 && write.properties.write) {
          await this.step(new Promise(resolve => setTimeout(resolve, 100)), '等待设备初始化', current);
        }
      }
      this.state('ready', '已连接并订阅，等待真实脑电数据');
    }
    packet(uuid, bytes, metadata = {}) {
      const receivedAt = metadata.receivedAt ?? Date.now();
      this.sequence = metadata.sequence ?? this.sequence + 1;
      const hex = Array.from(bytes, v => v.toString(16).padStart(2, '0')).join('');
      if (this.recording) {
        const row = JSON.stringify({uuid, hex, receivedAt, received_at: new Date(receivedAt).toISOString(),
          sequence: this.sequence, session: this.session, address: this.device?.id,
          source: this.preview ? 'SIMULATION - NOT DEVICE DATA' : this.pythonBridge ? 'KSEEG102 Python/Bleak' : 'KSEEG102 Web Bluetooth',
          protocol: 'KSEEG102-F-2.1', init_commands: ['35', '45']}) + '\n';
        this.recordBytes += row.length;
        if (this.recordBytes > 25 * 1024 * 1024) {
          this.stopRecording(); this.emit('error', {message: '网页记录已达到内存上限，已停止记录，请导出文件。'});
        } else this.rows.push(row);
      }
      this.emit('packet', {uuid, bytes: Array.from(bytes), receivedAt,
        sequence: this.sequence, session: this.session, address: this.device?.id});
    }
    startPreview(current) {
      this.state('ready', '模拟预览已连接 · 非真实设备数据');
      let index = 0;
      this.timer = setInterval(() => {
        if (!current()) return;
        const raw = new Uint8Array(69); raw[3] = 86; raw[68] = 0;
        const view = new DataView(raw.buffer);
        for (let i = 0; i < 16; i++) {
          const t = (index + i) / 256;
          view.setUint16(4 + i * 4, Math.round(30000 + 3800 * Math.sin(2 * Math.PI * 10 * t) + 1300 * Math.sin(2 * Math.PI * 2 * t)));
          view.setUint16(6 + i * 4, Math.round(30000 + 3200 * Math.sin(2 * Math.PI * 8 * t) + 1000 * Math.sin(2 * Math.PI * 3 * t)));
        }
        this.packet(ids.raw, raw);
        if (index % 256 === 0) {
          this.packet(ids.feature, new Uint8Array([Math.round(65 + 12 * Math.sin(index / 1000)), 68, 24, 62]));
          this.packet(ids.frequency, new Uint8Array([18, 32, 72, 48, 17]));
        }
        index += 16;
      }, 62.5);
    }
    stopRecording() {
      if (this.recording) { this.recording = false; this.emit('recording', {active: false, name: this.fileName}); }
    }
    disconnect(message) {
      this.generation++;
      clearInterval(this.timer); this.timer = null;
      this.removeDisconnect?.(); this.removeDisconnect = null;
      for (const [characteristic, callback] of this.listeners) characteristic.removeEventListener('characteristicvaluechanged', callback);
      this.listeners = [];
      const device = this.device;
      this.stopRecording();
      try { device?.gatt?.disconnect(); } catch (_) { /* best-effort local cleanup */ }
      this.state('disconnected', message); this.device = null;
    }
  }
  globalThis.NeuroxBleAdapter = NeuroxBleAdapter;
  globalThis.neuroxBle = new NeuroxBleAdapter();
})();

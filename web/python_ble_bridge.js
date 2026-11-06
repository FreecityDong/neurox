/* Optional localhost Python/Bleak transport. Direct Web Bluetooth remains default. */
(() => {
  if (new URLSearchParams(globalThis.location.search).get('transport') !== 'python') return;
  class PythonBleAdapter extends globalThis.NeuroxBleAdapter {
    constructor() { super(); this.pythonBridge = true; this.events = null; }
    status() { return {supported: true, enabled: true, permissionsGranted: true,
      permanentlyDenied: false, locationRequired: false, locationEnabled: true,
      browserPicker: false, pythonBridge: true, simulated: false}; }
    listen(callback) {
      this.listener = callback;
      this.emit('adapter', this.status());
      this.events = new EventSource('/api/events');
      this.events.onmessage = message => {
        try {
          const event = JSON.parse(message.data);
          if (event.type === 'connection') {
            this.phase = event.state; this.session = event.session;
            this.device = ['connecting', 'configuring', 'ready'].includes(event.state) ? {id: event.address} : null;
            if (['disconnected', 'error'].includes(event.state)) this.stopRecording();
          }
          if (event.type === 'packet') this.packet(event.uuid, event.bytes, event);
          else this.listener?.(event);
        } catch (error) { this.emit('error', {message: `Python 桥接消息错误：${error.message}`}); }
      };
      this.events.onerror = () => {
        this.stopRecording();
        this.phase = 'error';
        this.emit('connection', {state: 'error', session: this.session, message: 'Python 桥接连接中断，请确认本地服务正在运行，且仅打开一个桥接页面'});
      };
    }
    async invoke(method, args = {}) {
      if (['startRecording', 'stopRecording', 'exportRecording'].includes(method)) return super.invoke(method, args);
      if (method === 'setPreview') throw new Error('Python 桥接只显示真实设备数据');
      const response = await fetch('/api/command', {method: 'POST',
        headers: {'Content-Type': 'application/json'}, body: JSON.stringify({method, args})});
      const result = await response.json();
      if (!response.ok) throw new Error(result.error || 'Python 蓝牙操作失败');
      return result.result;
    }
    disconnect() { return this.invoke('disconnect'); }
    cancel() {
      this.events?.close(); this.events = null;
      this.listener = null; this.stopRecording();
      fetch('/api/command', {method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({method: 'disconnect'}), keepalive: true}).catch(() => {});
    }
  }
  globalThis.PythonBleAdapter = PythonBleAdapter;
  globalThis.neuroxBle = new PythonBleAdapter();
})();

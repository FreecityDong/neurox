const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
test('Python SSE preserves timestamps, recording source, errors and page cleanup', async () => {
  const requests = [], events = [];
  let source;
  class FakeEventSource {
    constructor() { source = this; }
    close() { this.closed = true; }
  }
  const context = vm.createContext({URLSearchParams, location: {search: '?transport=python'},
    Map, Date, Uint8Array, DataView, Blob, setTimeout, clearTimeout, setInterval, clearInterval,
    document: {addEventListener() {}}, EventSource: FakeEventSource,
    fetch: async (url, options) => { requests.push({url, options}); return {ok: true, json: async () => ({result: null})}; }});
  for (const file of ['eeg_ble.js', 'python_ble_bridge.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../web', file), 'utf8'), context);
  }
  const adapter = context.neuroxBle;
  adapter.listen(event => events.push(event));
  assert.equal(adapter.status().pythonBridge, true);
  assert.equal(adapter.status().browserPicker, false);
  source.onmessage({data: JSON.stringify({type: 'connection', state: 'ready', session: 4, address: 'device-id'})});
  await adapter.invoke('startRecording');
  source.onmessage({data: JSON.stringify({type: 'packet', uuid: 'raw', bytes: [1, 2], receivedAt: 1234567, sequence: 7, session: 4})});
  const row = JSON.parse(adapter.rows[0]);
  assert.equal(row.source, 'KSEEG102 Python/Bleak');
  assert.equal(row.receivedAt, 1234567);
  assert.equal(row.sequence, 7);
  assert.equal(row.session, 4);
  source.onerror();
  assert.equal(adapter.recording, false);
  assert.equal(adapter.phase, 'error');
  adapter.cancel();
  assert.equal(source.closed, true);
  assert.equal(requests.at(-1).options.keepalive, true);
});

const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require('node:path').join(__dirname, '../web/eeg_ble.js'), 'utf8');
const suffix = '-43e6-47b7-9cb0-5fc21d4ae340';
const uuid = id => `8653000${id}${suffix}`;
const flush = () => new Promise(resolve => setImmediate(resolve));
async function waitReady(adapter) {
  const until = Date.now() + 2000;
  while (adapter.phase !== 'ready' && Date.now() < until) {
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  assert.equal(adapter.phase, 'ready');
}

function fixture({missingOptional = false, pendingConnect = false} = {}) {
  const order = [], events = [], chars = new Map(), lifecycle = new Map();
  const document = {hidden: false, addEventListener: (name, callback) => lifecycle.set(name, callback)};
  for (const id of ['b', 'c', 'd', 'e']) {
    const callbacks = new Set();
    chars.set(uuid(id), {
      callbacks, properties: {write: true},
      addEventListener: (_, callback) => callbacks.add(callback),
      removeEventListener: (_, callback) => callbacks.delete(callback),
      startNotifications: async () => { order.push(`notify:${id}`); },
      writeValueWithResponse: async bytes => { order.push(`write:${bytes[0]}`); },
    });
  }
  const service = {getCharacteristic: async id => {
    if (missingOptional && [uuid('d'), uuid('e')].includes(id)) {
      throw Object.assign(new Error('missing'), {name: 'NotFoundError'});
    }
    return chars.get(id);
  }};
  let disconnected = 0, resolveConnection;
  const server = {getPrimaryService: async id => {
    assert.equal(id, uuid('a')); return service;
  }, disconnect: () => disconnected++};
  const device = {id: 'opaque-device-id', name: 'KSEEG102',
    addEventListener() {}, removeEventListener() {},
    gatt: {connect: () => pendingConnect ? new Promise(resolve => { resolveConnection = resolve; }) : Promise.resolve(server),
      disconnect: () => disconnected++}};
  let pickerOptions;
  const context = vm.createContext({Uint8Array, DataView, Date, Map, Blob,
    setTimeout, clearTimeout, setInterval, clearInterval,
    isSecureContext: true, document,
    addEventListener: (name, callback) => lifecycle.set(name, callback),
    navigator: {bluetooth: {requestDevice: options => { pickerOptions = options; return Promise.resolve(device); }}}});
  vm.runInContext(source, context);
  const adapter = context.neuroxBle;
  adapter.listen(event => events.push(event));
  return {adapter, events, order, chars, server, device, document, lifecycle,
    get pickerOptions() {return pickerOptions;}, get disconnected() {return disconnected;},
    resolveConnection: () => resolveConnection(server)};
}

test('real picker, serialized subscription and initialization, offset-safe packets and JSONL', async () => {
  const f = fixture();
  assert.equal(f.adapter.preview, false);
  const scan = f.adapter.invoke('scan');
  // requestDevice must execute synchronously in the button gesture.
  assert.equal(f.pickerOptions.acceptAllDevices, true);
  assert.equal(f.pickerOptions.optionalServices[0], uuid('a'));
  await scan;
  assert.equal(f.events.find(e => e.type === 'device').rssi, null);
  await f.adapter.invoke('connect', {address: f.device.id});
  await waitReady(f.adapter);
  assert.deepEqual(f.order, ['notify:b', 'notify:e', 'notify:d', 'write:53', 'write:69']);
  assert.equal(f.adapter.phase, 'ready');
  assert.equal(f.events.filter(e => e.type === 'packet').length, 0);
  await f.adapter.invoke('startRecording');
  const backing = new Uint8Array([99, 10, 20, 30, 88]);
  const callback = [...f.chars.get(uuid('b')).callbacks][0];
  callback({target: {value: new DataView(backing.buffer, 1, 3)}});
  const packet = f.events.find(e => e.type === 'packet');
  assert.deepEqual(Array.from(packet.bytes), [10, 20, 30]);
  const row = JSON.parse(f.adapter.rows[0]);
  assert.equal(row.hex, '0a141e');
  assert.equal(row.source, 'KSEEG102 Web Bluetooth');
  assert.deepEqual(row.init_commands, ['35', '45']);
  await f.adapter.invoke('disconnect');
  assert.equal(f.adapter.recording, false);
  assert.equal(f.chars.get(uuid('b')).callbacks.size, 0);
  callback({target: {value: new DataView(backing.buffer)}});
  assert.equal(f.events.filter(e => e.type === 'packet').length, 1);
});

test('optional metrics may be absent while required raw remains subscribed', async () => {
  const f = fixture({missingOptional: true});
  await f.adapter.invoke('scan');
  await f.adapter.invoke('connect', {address: f.device.id});
  await waitReady(f.adapter);
  assert.equal(f.adapter.phase, 'ready');
  assert.deepEqual(f.order, ['notify:b', 'write:53', 'write:69']);
  f.adapter.cancel();
});

test('cancelled connection cleans up a late GATT connection without becoming ready', async () => {
  const f = fixture({pendingConnect: true});
  await f.adapter.invoke('scan');
  await f.adapter.invoke('connect', {address: f.device.id});
  await f.adapter.invoke('disconnect');
  f.resolveConnection();
  await flush();
  assert.equal(f.adapter.phase, 'disconnected');
  assert.ok(f.disconnected >= 2);
  assert.equal(f.events.some(e => e.state === 'ready'), false);
});

test('simulation requires explicit opt-in and records its provenance', async () => {
  const f = fixture();
  await f.adapter.invoke('setPreview', {enabled: true});
  await f.adapter.invoke('connect', {address: 'preview-kseeg102'});
  assert.equal(f.adapter.status().simulated, true);
  assert.equal(f.pickerOptions, undefined);
  await f.adapter.invoke('startRecording');
  f.adapter.packet(uuid('b'), new Uint8Array([1]));
  assert.match(JSON.parse(f.adapter.rows[0]).source, /SIMULATION/);
  assert.match(f.adapter.fileName, /^preview-/);
  await f.adapter.invoke('setPreview', {enabled: false});
  assert.equal(f.adapter.timer, null);
  assert.equal(f.adapter.status().simulated, false);
});

test('switching windows preserves GATT and notifications; leaving the page disconnects', async () => {
  const f = fixture();
  await f.adapter.invoke('scan');
  await f.adapter.invoke('connect', {address: f.device.id});
  await waitReady(f.adapter);
  f.document.hidden = true;
  f.lifecycle.get('visibilitychange')();
  assert.equal(f.adapter.phase, 'ready');
  assert.equal(f.disconnected, 0);
  const callback = [...f.chars.get(uuid('b')).callbacks][0];
  callback({target: {value: new DataView(new ArrayBuffer(69))}});
  assert.equal(f.events.filter(e => e.type === 'packet').length, 1);
  f.document.hidden = false;
  f.lifecycle.get('visibilitychange')();
  assert.equal(f.adapter.phase, 'ready');
  f.lifecycle.get('pagehide')();
  assert.equal(f.adapter.phase, 'disconnected');
  assert.equal(f.disconnected, 1);
  assert.equal(f.chars.get(uuid('b')).callbacks.size, 0);
});

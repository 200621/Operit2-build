import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const prefix = 'apps/flutter/thirdparty/file_selector_ohos/ohos/src/main/ets/file_selector/';
const source = path => readFileSync(new URL(path, root), 'utf8');
const chunkBytes = 1024 * 1024;

/** Runs the actual native selector implementation against asynchronous URI I/O. */
function fixture() {
  const text = source(`${prefix}FileSelectorApiImpl.ets`);
  const js = stripTypeScriptTypes(text.slice(text.indexOf('const TAG =')).replace('export class', 'class'), { mode: 'transform' });
  const calls = [];
  const handles = new Set();
  let nextFd = 0;
  let failRead = false;
  let readGate = null;
  const fs = {
    OpenMode: { READ_ONLY: 0 },
    async open(path) {
      calls.push(['open', path]);
      const file = { fd: ++nextFd };
      handles.add(file.fd);
      return file;
    },
    async stat(fd) {
      assert.ok(handles.has(fd));
      calls.push(['stat', fd]);
      return { size: 143388128 };
    },
    async read(fd, buffer, { offset, length }) {
      assert.ok(handles.has(fd));
      assert.ok(buffer.byteLength <= chunkBytes);
      assert.equal(buffer.byteLength, length);
      calls.push(['read', fd, offset, length]);
      await readGate;
      if (failRead) throw new Error('READ_FAILED');
      const count = Math.max(0, Math.min(length, 143388128 - offset));
      const bytes = new Uint8Array(buffer);
      for (let i = 0; i < count; i++) bytes[i] = (offset + i) % 251;
      return count;
    },
    async close(file) {
      assert.ok(handles.delete(file.fd), 'Descriptor must be closed exactly once');
      calls.push(['close', file.fd]);
    },
  };
  const channels = new Map();
  class Channel {
    constructor(_messenger, name) { channels.set(name, this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    setMessageHandler(_handler) {}
  }
  class FileResponse {
    constructor(path, mimeType, name, size) { Object.assign(this, { path, mimeType, name, size }); }
  }
  const factory = new Function('fs', 'Log', 'MethodChannel', 'BasicMessageChannel', 'FileSelectorApiCodec', 'FileResponse', `${js}; return FileSelectorApiImpl;`);
  const Api = factory(fs, { e() {}, d() {}, i() {} }, Channel, Channel, { INSTANCE: {} }, FileResponse);
  const api = new Api({});
  api.setup({}, {});
  const input = channels.get('dev.flutter.packages.file_selector_ohos/input');
  const call = (method, args) => new Promise((resolve, reject) => {
    input.handler.onMethodCall({ method, arguments: new Map(Object.entries(args)) }, {
      success: resolve,
      error: (_code, message) => reject(new Error(message)),
      notImplemented: () => reject(new Error('NOT_IMPLEMENTED')),
    });
  });
  return { Api, api, call, calls, handles, channels,
    failReads() { failRead = true; },
    blockRead() { return new Promise(resolve => { readGate = new Promise(release => resolve(release)); }); },
  };
}

test('OHOS picker queries metadata only and releases descriptors, including multi-select', async () => {
  const f = fixture();
  const files = await f.Api.toFileListResponse(['file://large.apk', 'file://other.zip'], '*/*');
  assert.equal(files.length, 2);
  assert.deepEqual({ ...files[0] }, { path: 'file://large.apk', mimeType: '*/*', name: 'large.apk', size: 143388128 });
  assert.deepEqual(f.calls.map(call => call[0]), ['open', 'stat', 'close', 'open', 'stat', 'close']);
  assert.equal(f.handles.size, 0);
});

test('OHOS native stream reads 143 MB with bounded buffers and exact offsets', async () => {
  const f = fixture();
  const token = await f.call('open', { path: 'file://large.apk', start: 0 });
  let offset = 0;
  while (offset < 143388128) {
    const bytes = await f.call('readChunk', { token, maxBytes: chunkBytes });
    assert.ok(bytes.byteLength <= chunkBytes);
    assert.equal(bytes[0], offset % 251);
    assert.equal(bytes.at(-1), (offset + bytes.byteLength - 1) % 251);
    offset += bytes.byteLength;
  }
  assert.equal(offset, 143388128);
  assert.equal((await f.call('readChunk', { token, maxBytes: chunkBytes })).length, 0);
  await f.call('close', { token });
  await f.call('close', { token });
  assert.equal(f.handles.size, 0);
});

test('OHOS rejects oversized native read requests before allocating or reading', async () => {
  const f = fixture();
  const token = await f.call('open', { path: 'file://large.apk', start: 10 });
  for (const maxBytes of [0, -1, chunkBytes + 1, 1.5, NaN]) {
    await assert.rejects(f.call('readChunk', { token, maxBytes }), /Invalid document input read/);
  }
  assert.equal(f.calls.filter(call => call[0] === 'read').length, 0);
  const bytes = await f.call('readChunk', { token, maxBytes: 6 });
  assert.deepEqual([...bytes], [10, 11, 12, 13, 14, 15]);
  await f.call('close', { token });
});

test('OHOS read failure does not poison the close queue', async () => {
  const f = fixture();
  const token = await f.call('open', { path: 'file://large.apk', start: 0 });
  f.failReads();
  await assert.rejects(f.call('readChunk', { token, maxBytes: 8 }), /READ_FAILED/);
  await f.call('close', { token });
  assert.equal(f.handles.size, 0);
});

test('OHOS detach waits for in-flight reads and then closes every descriptor', async () => {
  const f = fixture();
  const token = await f.call('open', { path: 'file://large.apk', start: 0 });
  await f.call('open', { path: 'file://other.apk', start: 5 });
  const release = await f.blockRead();
  const reading = f.call('readChunk', { token, maxBytes: 8 });
  await new Promise(resolve => setImmediate(resolve));
  f.api.closeChannels();
  assert.equal(f.handles.size, 2);
  release();
  await reading;
  await f.api.inputOperations;
  assert.equal(f.handles.size, 0);
  assert.equal(f.channels.get('dev.flutter.packages.file_selector_ohos/input').handler, null);
});

test('OHOS selection protocol contains no full-file content field in Dart or native codecs', () => {
  const dart = source('apps/flutter/thirdparty/file_selector_ohos/lib/src/file_selector_api.g.dart');
  const native = source(`${prefix}GeneratedFileSelectorApi.ets`);
  assert.doesNotMatch(dart, /Uint8List bytes|this\.bytes|result\[4\]/);
  assert.doesNotMatch(native, /getBytes|setBytes|this\.bytes|list\[4\]/);
  assert.doesNotMatch(source(`${prefix}FileSelectorApiImpl.ets`), /new ArrayBuffer\(size\)|getUrisForPaths|fdopenStreamSync/);
});

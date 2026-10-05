import assert from 'node:assert/strict';
import test from 'node:test';
import { captureBrowserScreen, readBrowserLocation, recognizeBrowserText }
  from '../../apps/flutter/app/web/runtime/src/browser_system_capabilities.ts';

/** Installs deterministic browser APIs and restores their original descriptors. */
function installGlobals(context, values) {
  const originals = new Map(Object.keys(values).map(name => [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
  for (const [name, value] of Object.entries(values)) {
    Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
  }
  context.after(() => {
    for (const [name, descriptor] of originals) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    }
  });
}

/** Uses actual provider coordinates and requests a fresh fix with the caller's precision. */
test('browser location returns measured coordinates, not zero placeholders', async context => {
  let options;
  installGlobals(context, { isSecureContext: true, navigator: { geolocation: {
    getCurrentPosition(success, failure, request) {
      options = request;
      success({ coords: { latitude: 31.23, longitude: 121.47, accuracy: 12 }, timestamp: 1234 });
    },
  } } });
  const position = await readBrowserLocation(10, true, false);
  assert.equal(position.latitude, 31.23);
  assert.equal(position.longitude, 121.47);
  assert.equal(position.timestamp, 1234);
  assert.equal(position.provider, 'browser.geolocation');
  assert.deepEqual(options, { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 });
});

/** Reports an explicit provider denial instead of inventing an attachment location. */
test('browser location propagates permission and provider failures', async context => {
  installGlobals(context, { isSecureContext: true, navigator: { geolocation: {
    getCurrentPosition(success, failure) { failure({ code: 1, message: 'permission denied' }); },
  } } });
  await assert.rejects(readBrowserLocation(10, true, false), /permission denied/);
});

/** Rejects invalid fixes and unavailable reverse-geocoding capability. */
test('browser location validates its requested and returned data', async context => {
  installGlobals(context, { isSecureContext: true, navigator: { geolocation: {
    getCurrentPosition(success) {
      success({ coords: { latitude: NaN, longitude: 1, accuracy: 0 }, timestamp: 1234 });
    },
  } } });
  await assert.rejects(readBrowserLocation(10, true, false), /invalid location/);
  assert.throws(() => readBrowserLocation(10, true, true), /does not provide reverse geocoding/);
  assert.throws(() => readBrowserLocation(0, true, false), /timeout must be positive/);
});

/** Refuses screen capture and location access outside a secure browser context. */
test('browser system APIs enforce the real secure-context capability', context => {
  installGlobals(context, { isSecureContext: false, navigator: {} });
  assert.throws(() => readBrowserLocation(10, true, false), /secure context/);
  return assert.rejects(captureBrowserScreen(), /secure context/);
});

/** Provides a deterministic display stream and canvas for capture resource tests. */
function captureFixture(context, failure) {
  const recorded = { stopped: 0, paused: 0, video: null, dimensions: null };
  const video = {
    muted: false, playsInline: false, srcObject: null, videoWidth: 1920, videoHeight: 1080,
    async play() { if (failure) throw new Error('video failed'); },
    pause() { recorded.paused++; },
    requestVideoFrameCallback(callback) { callback(); },
  };
  const canvas = {
    width: 0, height: 0,
    getContext() { return { drawImage() { recorded.dimensions = [canvas.width, canvas.height]; } }; },
    toBlob(callback) { callback(new Blob([new Uint8Array([137, 80, 78, 71])])); },
  };
  const stream = { getTracks() { return [{ stop() { recorded.stopped++; } }]; } };
  installGlobals(context, { isSecureContext: true, navigator: { mediaDevices: {
    async getDisplayMedia(request) { assert.deepEqual(request, { video: true, audio: false }); return stream; },
  } }, document: { createElement(name) { return name === 'video' ? video : canvas; } } });
  recorded.video = video;
  return recorded;
}

/** Transfers real encoded display bytes and ends the screen-sharing tracks immediately. */
test('screen capture returns image bytes and releases the display stream', async context => {
  const recorded = captureFixture(context, false);
  assert.deepEqual(await captureBrowserScreen(), new Uint8Array([137, 80, 78, 71]));
  assert.deepEqual(recorded.dimensions, [1920, 1080]);
  assert.equal(recorded.stopped, 1);
  assert.equal(recorded.paused, 1);
  assert.equal(recorded.video.srcObject, null);
});

/** Ensures failed capture cannot leave screen sharing active. */
test('screen capture releases media tracks after playback failure', async context => {
  const recorded = captureFixture(context, true);
  await assert.rejects(captureBrowserScreen(), /video failed/);
  assert.equal(recorded.stopped, 1);
  assert.equal(recorded.video.srcObject, null);
});

/** Keeps OCR image processing and language downloads within the shipped app assets. */
test('OCR uses bundled assets and preserves the supplied image bytes', async () => {
  let initialized;
  let terminated = 0;
  const engine = { async createWorker(language, mode, options) {
    initialized = { language, mode, options };
    return {
      async recognize(image) {
        assert.deepEqual(new Uint8Array(await image.arrayBuffer()), new Uint8Array([1, 2, 3]));
        return { data: { text: '屏幕文字' } };
      },
      async terminate() { terminated++; },
    };
  } };
  const root = new URL('https://operit.test/runtime/generated/ocr/');
  assert.deepEqual(await recognizeBrowserText(new Uint8Array([1, 2, 3]), 'CHINESE', 'HIGH', engine, root), { text: '屏幕文字' });
  assert.equal(initialized.language, 'chi_sim');
  assert.equal(initialized.mode, 1);
  assert.equal(initialized.options.workerPath, new URL('worker.min.js', root).href);
  assert.equal(initialized.options.corePath, new URL('core/', root).href);
  assert.equal(initialized.options.langPath, new URL('languages', root).href);
  assert.equal(initialized.options.workerBlobURL, false);
  assert.equal(terminated, 1);
});

/** Propagates OCR errors while terminating the worker rather than selecting another engine. */
test('OCR fails explicitly and releases its worker', async () => {
  let terminated = 0;
  const engine = { async createWorker() { return {
    async recognize() { throw new Error('model failure'); },
    async terminate() { terminated++; },
  }; } };
  await assert.rejects(recognizeBrowserText(new Uint8Array([1]), 'LATIN', 'HIGH', engine,
    new URL('https://operit.test/ocr/')), /model failure/);
  assert.equal(terminated, 1);
  await assert.rejects(recognizeBrowserText(new Uint8Array([1]), 'unknown', 'HIGH', engine,
    new URL('https://operit.test/ocr/')), /Unsupported OCR language/);
});

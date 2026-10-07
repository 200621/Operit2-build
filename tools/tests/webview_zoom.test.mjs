import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = path => readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');

// The production helper has a single typed signature. Strip just that signature
// so these tests also run on Node 20, without a TypeScript runtime/loader.
const zoomSource = source('apps/flutter/thirdparty/webview_all_ohos/ohos/src/main/ets/com.abandoft.webview_all_ohos/PageZoomScript.ts');
const zoomSignature = 'export function buildPageZoomScript(factor: number): string {';
assert.ok(zoomSource.includes(zoomSignature));
const buildPageZoomScript = vm.runInNewContext(
  zoomSource.replace(zoomSignature, 'function buildPageZoomScript(factor) {') + '\nbuildPageZoomScript;',
);


function page({ inline = '', priority = '', computed = '1', frame = false, deferred = false } = {}) {
  const values = new Map(inline ? [['zoom', inline]] : []);
  const priorities = new Map(inline ? [['zoom', priority]] : []);
  const root = { style: {
    getPropertyValue: key => values.get(key) ?? '',
    getPropertyPriority: key => priorities.get(key) ?? '',
    setProperty: (key, value, importance) => { values.set(key, value); priorities.set(key, importance); },
    removeProperty: key => { values.delete(key); priorities.delete(key); },
  }};
  const window = {};
  window.top = frame ? {} : window;
  let observerCallback;
  let disconnected = false;
  const document = { documentElement: deferred ? null : root };
  const context = vm.createContext({
    window, document,
    getComputedStyle: () => ({ zoom: values.get('zoom') ?? computed }),
    MutationObserver: class {
      constructor(callback) { observerCallback = callback; }
      observe() {}
      disconnect() { disconnected = true; }
    },
  });
  return {
    values, priorities,
    apply: factor => vm.runInContext(buildPageZoomScript(factor), context),
    attach: () => { document.documentElement = root; observerCallback(); },
    disconnected: () => disconnected,
  };
}

test('ArkWeb content zoom is absolute and restores website CSS zoom', () => {
  const fixture = page({ inline: '1.2', priority: 'important' });
  fixture.apply(1.5);
  assert.ok(Math.abs(Number(fixture.values.get('zoom')) - 1.8) < 1e-9);
  fixture.apply(0.7);
  assert.ok(Math.abs(Number(fixture.values.get('zoom')) - 0.84) < 1e-9);
  fixture.apply(1);
  assert.equal(fixture.values.get('zoom'), '1.2');
  assert.equal(fixture.priorities.get('zoom'), 'important');
});

test('ArkWeb zoom restores stylesheet values rather than replacing them at 1x', () => {
  const fixture = page({ computed: '1.2' });
  fixture.apply(1.5);
  assert.ok(Math.abs(Number(fixture.values.get('zoom')) - 1.8) < 1e-9);
  fixture.apply(1);
  assert.equal(fixture.values.has('zoom'), false);
});

test('document-start zoom waits for the document root and does not double-zoom frames', () => {
  const fixture = page({ deferred: true });
  fixture.apply(1.5);
  assert.equal(fixture.values.has('zoom'), false);
  fixture.attach();
  assert.equal(fixture.values.get('zoom'), '1.5');
  assert.equal(fixture.disconnected(), true);
  const child = page({ frame: true });
  child.apply(1.5);
  assert.equal(child.values.has('zoom'), false);
});

test('invalid page zoom is rejected before generating executable source', () => {
  for (const factor of [0, -1, Infinity, NaN]) {
    assert.throws(() => buildPageZoomScript(factor), /Invalid page zoom/);
  }
});

test('zoom strategy is capability-driven and native content zoom is not applied twice', () => {
  const widget = source('apps/flutter/thirdparty/webview_all/lib/src/webview_widget.dart');
  assert.match(widget, /controller\.requiresNativeApplicationZoom/);
  assert.doesNotMatch(widget, /TargetPlatform\.macOS/);
  const base = source('apps/flutter/thirdparty/webview_flutter_platform_interface/lib/src/platform_webview_controller.dart');
  assert.match(base, /bool get requiresNativeApplicationZoom => false/);
  const linux = source('apps/flutter/thirdparty/webview_all_linux/lib/src/linux_webview_controller.dart');
  assert.match(linux, /bool get requiresNativeApplicationZoom => true/);
  assert.match(linux, /initialPageZoomFactor: _linuxParams\.zoomFactor \?\? 1/);
});

test('OHOS zoom bridge is paired, disposed and survives user-script removal', () => {
  const root = 'apps/flutter/thirdparty/webview_all_ohos/ohos/src/main/ets/com.abandoft.webview_all_ohos';
  const plugin = source(`${root}/WebviewAllOhosPlugin.ets`);
  assert.match(plugin, /new WebViewZoom\(messenger, instanceManager\)/);
  assert.match(plugin, /this\.zoom\?\.dispose\(\)/);
  const channel = source(`${root}/WebViewZoom.ets`);
  assert.match(channel, /'operit\/webview_zoom'/);
  assert.match(channel, /call\.argument\('viewIdentifier'\)/);
  assert.match(channel, /view\.setPageZoomFactor\(factor\)/);
  const view = source(`${root}/WebViewPlatformView.ets`);
  assert.match(view, /scripts\.unshift\(\{ script: buildPageZoomScript\(this\.pageZoomFactor\)/);
  assert.match(view, /removeAllDocumentStartScripts\(\)[\s\S]*?this\.documentStartScripts\.clear\(\);\s*await host\(this\.getDocumentStartScripts\(\)\)/);
});

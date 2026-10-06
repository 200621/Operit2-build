import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../apps/flutter/app/lib/ui/features/packages/screens/ToolPkgComposeDslWebViewBridgeRuntime.dart', import.meta.url), 'utf8');
const descriptors = { ChanzhiHost: ['loadData', 'saveData'] };

/** Extracts the production JavaScript with the same serialized host descriptors. */
function runtime(interfaces = descriptors) {
  const match = source.match(/return '''([\s\S]*?)''';/);
  assert.ok(match);
  return match[1]
    .replaceAll('$hiddenBridgeNameJson', JSON.stringify('__ComposeDslWebViewHostBridge__'))
    .replaceAll('$channelNameJson', JSON.stringify('__ComposeDslWebViewHostBridgeChannel__'))
    .replaceAll('$interfacesJson', JSON.stringify(interfaces));
}

/** Emulates asynchronous host delivery without assuming interface discovery is immediate. */
function page() {
  const messages = [];
  const events = [];
  const context = vm.createContext({
    Event: class { /** Records the event name exposed to page listeners. */ constructor(type) { this.type = type; } },
    dispatchEvent(event) { events.push(event.type); },
    __ComposeDslWebViewHostBridgeChannel__: {
      postMessage(raw) { messages.push(JSON.parse(raw)); },
    },
  });
  context.window = context;
  return { context, messages, events };
}

/** Delivers one successful native response to the production request promise. */
function respond(context, request, data) {
  context.__operitComposeDslWebViewHostReceive({ id: request.id, success: true, data });
}

test('data interfaces exist before the first page script and do not await discovery', async () => {
  const { context, messages, events } = page();
  vm.runInContext(runtime(), context);
  assert.equal(typeof context.ChanzhiHost.loadData, 'function');
  assert.deepEqual(messages, []);
  assert.deepEqual(events, ['operitComposeDslInterfacesReady']);
  const pending = context.ChanzhiHost.loadData();
  assert.equal(messages[0].type, 'invoke');
  assert.equal(messages[0].payload.interfaceName, 'ChanzhiHost');
  assert.equal(messages[0].payload.methodName, 'loadData');
  respond(context, messages[0], { success: true, data: { chanzhi_todos_v1: [{ id: 'existing' }] } });
  assert.equal((await pending).data.chanzhi_todos_v1[0].id, 'existing');
});

test('reinstalling at page completion preserves outstanding read promises and request IDs', async () => {
  const { context, messages } = page();
  vm.runInContext(runtime(), context);
  const pending = context.ChanzhiHost.loadData();
  const receiver = context.__operitComposeDslWebViewHostReceive;
  vm.runInContext(runtime(), context);
  assert.equal(context.__operitComposeDslWebViewHostReceive, receiver);
  respond(context, messages[0], { success: true, data: { chanzhi_todos_v1: ['retained'] } });
  assert.deepEqual(JSON.parse(JSON.stringify(await pending)), { success: true, data: { chanzhi_todos_v1: ['retained'] } });
  const saved = context.ChanzhiHost.saveData({ chanzhi_todos_v1: ['retained'] });
  assert.notEqual(messages[0].id, messages[1].id);
  assert.deepEqual(JSON.parse(messages[1].payload.args), [{ chanzhi_todos_v1: ['retained'] }]);
  respond(context, messages[1], { success: true });
  await saved;
});

test('descriptor refresh adds and removes methods without replacing the host transport', () => {
  const { context } = page();
  vm.runInContext(runtime(), context);
  const receiver = context.__operitComposeDslWebViewHostReceive;
  vm.runInContext(runtime({ ChanzhiHost: ['loadData'], OtherHost: ['ping'] }), context);
  assert.equal(typeof context.ChanzhiHost.loadData, 'function');
  assert.equal(context.ChanzhiHost.saveData, undefined);
  assert.equal(typeof context.OtherHost.ping, 'function');
  vm.runInContext(runtime({}), context);
  assert.equal(context.ChanzhiHost, undefined);
  assert.equal(context.OtherHost, undefined);
  assert.equal(context.__operitComposeDslWebViewHostReceive, receiver);
});

test('startup reads saved todos on each entry instead of writing empty initialization', async () => {
  let file = { chanzhi_todos_v1: [{ id: 'user-todo', text: 'keep this todo' }] };
  for (let entry = 0; entry < 2; entry += 1) {
    const { context, messages } = page();
    vm.runInContext(runtime(), context);
    vm.runInContext(`
      var STORE = {};
      var startup = Promise.resolve(ChanzhiHost.loadData()).then(function(result) {
        STORE = result.data;
        return ChanzhiHost.saveData(STORE);
      });
    `, context);
    assert.equal(messages[0].payload.methodName, 'loadData');
    respond(context, messages[0], { success: true, data: structuredClone(file) });
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(messages[1].payload.methodName, 'saveData');
    file = JSON.parse(messages[1].payload.args)[0];
    assert.equal(file.chanzhi_todos_v1[0].id, 'user-todo');
    respond(context, messages[1], { success: true });
    await context.startup;
  }
});

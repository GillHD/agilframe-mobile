import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {
  createBridgeShimScript,
  createHostMessageScript,
  mapBridgeMessage,
  parseBridgeMessage,
  sanitizeBridgePayload,
  unwrapBridgeEnvelope,
} from '../src/bridge.js';

test('parseBridgeMessage parses ready with capabilities', () => {
  const parsed = parseBridgeMessage(
    JSON.stringify({
      type: 'agil:ready',
      capabilities: { media: true, blur: false, screenShare: true, captions: true, recording: false },
      room: 'r1',
      server: 'https://calls.example.com',
    }),
  );
  assert.deepEqual(parsed, {
    type: 'agil:ready',
    capabilities: { media: true, blur: false, screenShare: true, captions: true, recording: false },
    room: 'r1',
    server: 'https://calls.example.com',
  });
});

test('parseBridgeMessage parses joined/left/chat/state/minimized/fullscreen/pong', () => {
  assert.deepEqual(parseBridgeMessage({ type: 'agil:event', event: 'joined', payload: { id: 'p1' } }), {
    type: 'agil:event',
    event: 'joined',
    payload: { id: 'p1' },
  });
  assert.deepEqual(parseBridgeMessage({ type: 'agil:event', event: 'left' }), {
    type: 'agil:event',
    event: 'left',
    payload: undefined,
  });
  assert.deepEqual(
    parseBridgeMessage({ type: 'agil:chat', message: { text: 'hello', participantName: 'Anna', ts: 1 } }),
    { type: 'agil:chat', message: { text: 'hello', participantName: 'Anna', ts: 1 } },
  );
  assert.deepEqual(parseBridgeMessage({ type: 'agil:state', state: { phase: 'joined', participants: 2 } }), {
    type: 'agil:state',
    state: { phase: 'joined', participants: 2 },
  });
  assert.deepEqual(parseBridgeMessage({ type: 'agil:minimized', minimized: true }), {
    type: 'agil:minimized',
    minimized: true,
  });
  assert.deepEqual(parseBridgeMessage({ type: 'agil:fullscreen', fullscreen: false }), {
    type: 'agil:fullscreen',
    fullscreen: false,
  });
  assert.deepEqual(parseBridgeMessage({ type: 'agil:pong' }), { type: 'agil:pong' });
});

test('parseBridgeMessage rejects malformed, unknown and oversized messages', () => {
  assert.equal(parseBridgeMessage(null), null);
  assert.equal(parseBridgeMessage(undefined), null);
  assert.equal(parseBridgeMessage(42), null);
  assert.equal(parseBridgeMessage([{ type: 'agil:ready' }]), null);
  assert.equal(parseBridgeMessage('{not json'), null);
  assert.equal(parseBridgeMessage({ type: 'other:ready' }), null);
  assert.equal(parseBridgeMessage({ type: 'agil:unknown' }), null);
  assert.equal(parseBridgeMessage({ type: 'agil:event', event: 'Joined' }), null);
  assert.equal(parseBridgeMessage({ type: 'agil:chat', message: { text: 42 } }), null);
  assert.equal(parseBridgeMessage({ type: 'agil:state', state: 'nope' }), null);
  assert.equal(parseBridgeMessage('x'.repeat(300_000)), null);
  assert.equal(parseBridgeMessage('{"type":"agil:pong"}', { maxChars: 5 }), null);
});

test('parseBridgeMessage sanitizes hostile payloads', () => {
  const parsed = parseBridgeMessage({
    type: 'agil:event',
    event: 'joined',
    payload: JSON.parse('{"__proto__":{"polluted":true},"constructor":{"x":1},"safe":{"ok":true}}'),
  });
  assert.ok(parsed && parsed.type === 'agil:event');
  const payload = parsed.payload as Record<string, unknown>;
  assert.equal(Object.prototype.hasOwnProperty.call(payload, '__proto__'), false);
  assert.equal(Object.prototype.hasOwnProperty.call(payload, 'constructor'), false);
  assert.deepEqual(payload.safe, { ok: true });
  assert.equal((Object.prototype as { polluted?: unknown }).polluted, undefined);
});

test('sanitizeBridgePayload enforces depth, collection and string limits', () => {
  let deep: unknown = 'end';
  for (let index = 0; index < 20; index += 1) deep = { next: deep };
  const limited = sanitizeBridgePayload(deep, { maxDepth: 3 });
  assert.doesNotThrow(() => JSON.stringify(limited));
  assert.ok(JSON.stringify(limited).length < 100);

  assert.deepEqual(sanitizeBridgePayload([1, 2, 3, 4], { maxArray: 2 }), [1, 2]);
  assert.deepEqual(sanitizeBridgePayload({ a: 1, b: 2, c: 3 }, { maxKeys: 2 }), { a: 1, b: 2 });
  assert.deepEqual(sanitizeBridgePayload({ s: 'abcdef' }, { maxString: 3 }), { s: 'abc…' });
  assert.deepEqual(sanitizeBridgePayload({ n: Number.NaN, b: 1n, f: () => 1 }), { n: null, b: null });
});

test('sanitizeBridgePayload breaks cycles', () => {
  const value: Record<string, unknown> = { name: 'cycle' };
  value.self = value;
  assert.deepEqual(sanitizeBridgePayload(value), { name: 'cycle', self: null });
});

test('mapBridgeMessage maps ready, joined, left, chat and errors', () => {
  const ready = mapBridgeMessage({
    type: 'agil:ready',
    capabilities: { media: true, blur: true, screenShare: false, captions: false, recording: false },
    room: 'r1',
  });
  assert.deepEqual(ready.events[0], {
    type: 'ready',
    capabilities: { media: true, blur: true, screenShare: false, captions: false, recording: false },
    room: 'r1',
  });

  assert.deepEqual(mapBridgeMessage({ type: 'agil:event', event: 'joined', payload: { id: 'p1' } }).events[0], {
    type: 'joined',
    payload: { id: 'p1' },
  });
  assert.deepEqual(mapBridgeMessage({ type: 'agil:event', event: 'left' }).events[0], {
    type: 'left',
    payload: undefined,
  });
  assert.deepEqual(
    mapBridgeMessage({ type: 'agil:chat', message: { text: 'hi' } }).events[0],
    { type: 'chat', message: { text: 'hi' } },
  );
  assert.deepEqual(mapBridgeMessage({ type: 'agil:event', event: 'quality-changed', payload: { tier: 'poor' } }).events[0], {
    type: 'event',
    name: 'quality-changed',
    payload: { tier: 'poor' },
  });

  const mappedError = mapBridgeMessage({
    type: 'agil:event',
    event: 'error',
    payload: { code: 'room_full', message: 'Room is full' },
  });
  assert.equal(mappedError.error?.code, 'widget-error');
  assert.equal(mappedError.error?.widgetCode, 'room_full');
  assert.equal(mappedError.error?.fatal, false);
  assert.deepEqual(mappedError.events[0], { type: 'error', error: mappedError.error });
  assert.deepEqual(mapBridgeMessage({ type: 'agil:pong' }).events, []);
});

test('createHostMessageScript serializes safely and validates messages', () => {
  const action = createHostMessageScript({ type: 'agil:action', action: 'toggle-mic' });
  assert.ok(action.includes('"agil:action"'));
  assert.ok(action.includes('"toggle-mic"'));
  assert.ok(action.includes('window.location.origin'));
  assert.ok(action.endsWith('true;'));

  const chat = createHostMessageScript({ type: 'agil:chat-send', text: '</script><script>alert(1)</script>' });
  assert.equal(chat.includes('</script>'), false);
  assert.equal(chat.includes('<script>'), false);
  assert.ok(chat.includes('\\u003c'));

  const long = createHostMessageScript({ type: 'agil:chat-send', text: 'x'.repeat(5000) });
  assert.ok(long.includes('x'.repeat(4000)));
  assert.equal(long.includes('x'.repeat(4001)), false);

  assert.throws(() => createHostMessageScript({ type: 'agil:action', action: 'drop-table' as never }), /Unknown/);
  assert.throws(() => createHostMessageScript({ type: 'agil:chat-send', text: '   ' }), /non-empty/);
  assert.throws(() => createHostMessageScript({ type: 'agil:scheme', scheme: 'blue' as never }), /scheme/);
  assert.throws(() => createHostMessageScript({ type: 'agil:nope' } as never), /Unknown bridge message type/);
});

test('createHostMessageScript sanitizes theme/config patches', () => {
  const theme = JSON.parse('{"colors":{"primary":"#fff"},"__proto__":{"polluted":true}}');
  const script = createHostMessageScript({ type: 'agil:theme', theme });
  assert.ok(script.includes('"primary":"#fff"'));
  assert.equal(script.includes('__proto__'), false);
  assert.equal(script.includes('polluted'), false);
});

interface Runtime {
  context: vm.Context;
  window: Record<string, unknown> & {
    postMessage: (message: unknown, targetOrigin: string) => void;
    parent: Runtime['window'];
    ReactNativeWebView?: { postMessage: (data: string) => void };
    __agilRnBridgeInstalled?: boolean;
    __agilRnBridgePostToPage?: (message: unknown, targetOrigin: string) => void;
  };
  nativeMessages: string[];
  pageMessages: Array<{ message: unknown; targetOrigin: string }>;
}

function createRuntime(withBridge = true): Runtime {
  const nativeMessages: string[] = [];
  const pageMessages: Array<{ message: unknown; targetOrigin: string }> = [];
  const windowObject = {
    location: { origin: 'https://calls.example.com' },
    postMessage(message: unknown, targetOrigin: string) {
      pageMessages.push({ message, targetOrigin });
    },
  } as unknown as Runtime['window'];
  windowObject.parent = windowObject;
  if (withBridge) {
    windowObject.ReactNativeWebView = {
      postMessage(data: string) {
        nativeMessages.push(data);
      },
    };
  }
  const context = vm.createContext({ window: windowObject, JSON, console });
  return { context, window: windowObject, nativeMessages, pageMessages };
}

test('bridge shim forwards parent messages to native and preserves same-page dispatch', () => {
  const runtime = createRuntime();
  vm.runInContext(createBridgeShimScript(), runtime.context);
  assert.equal(runtime.window.__agilRnBridgeInstalled, true);

  runtime.window.parent.postMessage({ type: 'agil:ready', capabilities: { media: true } }, '*');
  assert.equal(runtime.nativeMessages.length, 1);
  assert.deepEqual(JSON.parse(runtime.nativeMessages[0] ?? ''), {
    type: 'agil:ready',
    capabilities: { media: true },
  });
  assert.equal(runtime.pageMessages.length, 1);
  assert.deepEqual(runtime.pageMessages[0]?.message, { type: 'agil:ready', capabilities: { media: true } });
  assert.equal(runtime.pageMessages[0]?.targetOrigin, '*');
});

test('bridge shim is idempotent', () => {
  const runtime = createRuntime();
  vm.runInContext(createBridgeShimScript(), runtime.context);
  vm.runInContext(createBridgeShimScript(), runtime.context);
  runtime.window.parent.postMessage({ type: 'agil:pong' }, '*');
  assert.equal(runtime.nativeMessages.length, 1);
  assert.equal(runtime.pageMessages.length, 1);
});

test('host messages use the saved original postMessage and are not echoed to native', () => {
  const runtime = createRuntime();
  vm.runInContext(createBridgeShimScript(), runtime.context);
  const before = runtime.nativeMessages.length;
  vm.runInContext(createHostMessageScript({ type: 'agil:action', action: 'toggle-camera' }), runtime.context);
  assert.equal(runtime.nativeMessages.length, before);
  assert.equal(runtime.pageMessages.length, 1);
  const delivered = runtime.pageMessages[0]?.message as Record<string, unknown>;
  assert.equal(delivered.type, 'agil:action');
  assert.equal(delivered.action, 'toggle-camera');
  assert.equal(runtime.pageMessages[0]?.targetOrigin, 'https://calls.example.com');
});

test('bridge shim is a no-op without ReactNativeWebView', () => {
  const runtime = createRuntime(false);
  const original = runtime.window.postMessage;
  vm.runInContext(createBridgeShimScript(), runtime.context);
  assert.equal(runtime.window.__agilRnBridgeInstalled, undefined);
  assert.equal(runtime.window.postMessage, original);
  vm.runInContext(createHostMessageScript({ type: 'agil:ping' }), runtime.context);
  assert.equal(runtime.pageMessages.length, 1);
});

test('bridge shim is origin-scoped when an origin is supplied', () => {
  const other = createRuntime();
  const original = other.window.postMessage;
  vm.runInContext(createBridgeShimScript('https://other.example'), other.context);
  assert.equal(other.window.__agilRnBridgeInstalled, undefined);
  assert.equal(other.window.postMessage, original);

  const matching = createRuntime();
  vm.runInContext(createBridgeShimScript('https://calls.example.com'), matching.context);
  assert.equal(matching.window.__agilRnBridgeInstalled, true);
});

test('bridge shim tags forwarded messages with the per-load nonce', () => {
  const runtime = createRuntime();
  vm.runInContext(
    createBridgeShimScript('https://calls.example.com', { nonce: 'nonce-1' }),
    runtime.context,
  );
  runtime.window.parent.postMessage({ type: 'agil:ready', capabilities: {} }, '*');
  assert.equal(runtime.nativeMessages.length, 1);
  const envelope = JSON.parse(runtime.nativeMessages[0] ?? '') as Record<string, unknown>;
  assert.equal(envelope.__agilBridgeNonce, 'nonce-1');
  assert.equal(typeof envelope.message, 'string');

  const raw = runtime.nativeMessages[0] ?? '';
  const payload = unwrapBridgeEnvelope(raw, 'nonce-1');
  assert.ok(payload);
  assert.deepEqual(JSON.parse(payload), { type: 'agil:ready', capabilities: {} });
  assert.equal(unwrapBridgeEnvelope(raw, 'nonce-2'), null);
  assert.equal(unwrapBridgeEnvelope({ type: 'agil:ready' }, 'nonce-1'), null);
  assert.equal(unwrapBridgeEnvelope('{"type":"agil:ready"}', 'nonce-1'), null);
  assert.equal(unwrapBridgeEnvelope('{"type":"agil:ready"}'), '{"type":"agil:ready"}');
});

test('mapBridgeMessage redacts tokens from widget error messages', () => {
  const token = 'SECRET-JOIN-TOKEN';
  const mapped = mapBridgeMessage(
    {
      type: 'agil:event',
      event: 'error',
      payload: {
        code: 'mount_failed',
        message: `failed https://calls.example.com/embed.html?token=${token}&room=r1`,
      },
    },
    { secrets: [token] },
  );
  assert.ok(mapped.error);
  assert.equal(mapped.error.message.includes(token), false);
  assert.ok(mapped.error.message.includes('redacted'));
  assert.equal(mapped.error.code, 'widget-error');
});

test('bridge shim survives a missing parent and non-object messages', () => {
  const runtime = createRuntime();
  (runtime.window as { parent: unknown }).parent = null;
  vm.runInContext(createBridgeShimScript(), runtime.context);
  assert.equal(runtime.window.__agilRnBridgeInstalled, undefined);

  const withParent = createRuntime();
  vm.runInContext(createBridgeShimScript(), withParent.context);
  withParent.window.parent.postMessage('plain-string', '*');
  assert.equal(withParent.nativeMessages[0], 'plain-string');
  assert.equal(withParent.pageMessages.length, 1);
});

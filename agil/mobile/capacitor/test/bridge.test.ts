import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  DEFAULT_MAX_BRIDGE_CHARS,
  actionMessage,
  chatMessage,
  parseNativeWidgetMessage,
  parseWidgetMessage,
  redactSecrets,
  redactTokenText,
  sanitizeBridgePayload,
  schemeMessage,
  themeMessage,
  unwrapBridgeEnvelope,
} from '../src/bridge.js';

/** Exact Android shim envelope: `{__agilBridgeNonce, message: "<widget json>"}`. */
function androidEnvelope(message: unknown, nonce = 'nonce-1'): string {
  return JSON.stringify({
    __agilBridgeNonce: nonce,
    message: JSON.stringify(message),
  });
}

test('parseWidgetMessage parses agil:ready', () => {
  const event = parseWidgetMessage(
    JSON.stringify({
      type: 'agil:ready',
      capabilities: { media: true, blur: true, screenShare: false, captions: true, recording: false },
      room: 'daily-sync',
      server: 'https://calls.example.com',
    }),
  );
  assert.ok(event);
  assert.equal(event.type, 'ready');
  if (event.type !== 'ready') return;
  assert.equal(event.capabilities.media, true);
  assert.equal(event.capabilities.blur, true);
  assert.equal(event.capabilities.captions, true);
  assert.equal(event.capabilities.recording, false);
  assert.equal(event.room, 'daily-sync');
  assert.equal(event.server, 'https://calls.example.com');
});

test('parseWidgetMessage maps joined/left/error and generic events', () => {
  const joined = parseWidgetMessage(
    JSON.stringify({ type: 'agil:event', event: 'joined', payload: { id: 'p1' } }),
  );
  assert.deepEqual(joined, { type: 'joined', payload: { id: 'p1' } });

  const left = parseWidgetMessage(JSON.stringify({ type: 'agil:event', event: 'left' }));
  assert.equal(left?.type, 'left');

  const error = parseWidgetMessage(
    JSON.stringify({
      type: 'agil:event',
      event: 'error',
      payload: { code: 'mount_failed', message: 'boom' },
    }),
  );
  assert.ok(error);
  assert.equal(error.type, 'error');
  if (error.type !== 'error') return;
  assert.equal(error.error.code, 'widget-error');
  assert.equal(error.error.widgetCode, 'mount_failed');
  assert.equal(error.error.message, 'boom');
  assert.equal(error.error.fatal, false);

  const generic = parseWidgetMessage(
    JSON.stringify({ type: 'agil:event', event: 'action-denied', payload: { action: 'pip' } }),
  );
  assert.deepEqual(generic, {
    type: 'event',
    name: 'action-denied',
    payload: { action: 'pip' },
  });
});

test('parseWidgetMessage parses chat and state', () => {
  const chat = parseWidgetMessage(
    JSON.stringify({
      type: 'agil:chat',
      message: { text: 'hi', participantName: 'Анна', ts: 1 },
    }),
  );
  assert.ok(chat);
  assert.equal(chat.type, 'chat');
  if (chat.type !== 'chat') return;
  assert.equal(chat.message.text, 'hi');
  assert.equal(chat.message.participantName, 'Анна');

  const state = parseWidgetMessage(
    JSON.stringify({
      type: 'agil:state',
      state: {
        phase: 'joined',
        participants: 3,
        participantIds: ['p1', 'p2'],
        quality: { tier: 'good', score: 4.5 },
        connectionState: 'connected',
        settings: { mic: true, camera: false, blur: 'blur', panel: 'chat' },
      },
    }),
  );
  assert.ok(state);
  assert.equal(state.type, 'state');
  if (state.type !== 'state') return;
  assert.equal(state.state.phase, 'joined');
  assert.equal(state.state.participants, 3);
  // The full array is extracted for the facade digest and stripped from state.
  assert.deepEqual(state.participantIds, ['p1', 'p2']);
  assert.equal(Object.prototype.hasOwnProperty.call(state.state, 'participantIds'), false);
  assert.equal(state.state.connectionState, 'connected');
  assert.deepEqual(state.state.settings, { mic: true, camera: false, blur: 'blur', panel: 'chat' });
});

test('parseWidgetMessage maps minimized/fullscreen and rejects invalid input', () => {
  assert.deepEqual(
    parseWidgetMessage(JSON.stringify({ type: 'agil:minimized', minimized: true })),
    { type: 'minimized', minimized: true },
  );
  assert.deepEqual(
    parseWidgetMessage(JSON.stringify({ type: 'agil:fullscreen', fullscreen: false })),
    { type: 'fullscreen', fullscreen: false },
  );
  assert.equal(parseWidgetMessage(JSON.stringify({ type: 'agil:pong' })), null);
  assert.equal(parseWidgetMessage('not json'), null);
  assert.equal(parseWidgetMessage('{}'), null);
  assert.equal(parseWidgetMessage('{"type":"other:ready"}'), null);
  assert.equal(parseWidgetMessage('{"type":"agil:event","event":"Bad Name"}'), null);
  assert.equal(parseWidgetMessage('{"type":"agil:event","event":"ok"}', { maxChars: 5 }), null);
  assert.ok(DEFAULT_MAX_BRIDGE_CHARS >= 4096);
  assert.equal(parseWidgetMessage(null), null);
  assert.equal(parseWidgetMessage({ type: 'agil:ready' })?.type, 'ready');
});

test('sanitizeBridgePayload masks prototypes, cycles and overlong values', () => {
  const cyclic: Record<string, unknown> = {
    ok: 'value',
    nested: { list: [1, null, true, 'x'] },
  };
  Object.defineProperty(cyclic, '__proto__', {
    value: { polluted: true },
    enumerable: true,
    configurable: true,
    writable: true,
  });
  cyclic.self = cyclic;
  const result = sanitizeBridgePayload(cyclic) as Record<string, unknown>;
  assert.equal(result.ok, 'value');
  assert.equal(Object.prototype.hasOwnProperty.call(result, '__proto__'), false);
  assert.equal(result.self, null);
  assert.deepEqual(result.nested, { list: [1, null, true, 'x'] });

  const deep = sanitizeBridgePayload({ a: { b: { c: { d: 'x' } } } }, { maxDepth: 2 }) as Record<
    string,
    unknown
  >;
  assert.deepEqual(deep, { a: { b: null } });

  assert.deepEqual(sanitizeBridgePayload([1, 2, 3, 4], { maxArray: 2 }), [1, 2]);
  assert.equal(sanitizeBridgePayload('xxxxxxxxxx', { maxString: 4 }), 'xxxx…');
});

test('themeMessage sanitizes patches and rejects empty patches', () => {
  const patch: Record<string, unknown> = { colors: { primary: '#0b5fff' } };
  Object.defineProperty(patch, '__proto__', {
    value: 'x',
    enumerable: true,
    configurable: true,
    writable: true,
  });
  const message = themeMessage(patch);
  assert.equal(message.type, 'agil:theme');
  if (message.type !== 'agil:theme') return;
  assert.deepEqual(message.theme.colors, { primary: '#0b5fff' });
  assert.equal(Object.prototype.hasOwnProperty.call(message.theme, '__proto__'), false);
  assert.throws(() => themeMessage({}), /non-empty/);
});

test('schemeMessage builds agil:scheme', () => {
  assert.deepEqual(schemeMessage('dark'), { type: 'agil:scheme', scheme: 'dark' });
});

test('actionMessage and chatMessage build host commands', () => {
  assert.deepEqual(actionMessage('toggle-mic'), {
    type: 'agil:action',
    action: 'toggle-mic',
  });
  assert.deepEqual(chatMessage('  hi  '), { type: 'agil:chat-send', text: '  hi  ' });
  assert.throws(() => actionMessage('  '), /non-empty/);
  assert.throws(() => chatMessage('   '), /non-empty/);
});

test('parseWidgetMessage redacts tokens from widget errors', () => {
  const token = 'SECRET-JOIN-TOKEN';
  const event = parseWidgetMessage(
    JSON.stringify({
      type: 'agil:event',
      event: 'error',
      payload: {
        code: 'mount_failed',
        message: `failed https://host/embed.html?token=${token}&room=r`,
      },
    }),
    { secrets: [token] },
  );
  assert.ok(event && event.type === 'error');
  if (event?.type !== 'error') return;
  assert.equal(event.error.message.includes(token), false);
  assert.ok(event.error.message.includes('redacted'));
});

test('redaction covers access_token and bare secrets', () => {
  assert.equal(redactTokenText('cb?access_token=SECRET&x=1').includes('SECRET'), false);
  assert.ok(redactTokenText('cb?access_token=SECRET&x=1').includes('access_token=redacted'));
  assert.equal(redactSecrets('token SECRET', ['SECRET']).includes('SECRET'), false);
});

test('unwrapBridgeEnvelope extracts the Android nonce envelope', () => {
  const ready = {
    type: 'agil:ready',
    capabilities: { media: true, blur: true, screenShare: false, captions: true, recording: false },
    room: 'daily-sync',
  };
  const raw = androidEnvelope(ready);
  assert.equal(unwrapBridgeEnvelope(raw), JSON.stringify(ready));
  // The envelope itself is not a widget message and must never be parsed as one.
  assert.equal(parseWidgetMessage(raw), null);
  const event = parseWidgetMessage(unwrapBridgeEnvelope(raw));
  assert.equal(event?.type, 'ready');
});

test('Android envelopes: real ready/chat/state events parse after unwrap', () => {
  const ready = parseNativeWidgetMessage(
    androidEnvelope({
      type: 'agil:ready',
      capabilities: { media: true, blur: false, screenShare: true, captions: false, recording: true },
      room: 'team-sync',
      server: 'https://calls.example.com',
    }),
  );
  assert.ok(ready && ready.type === 'ready');
  if (ready?.type !== 'ready') return;
  assert.equal(ready.capabilities.media, true);
  assert.equal(ready.capabilities.screenShare, true);
  assert.equal(ready.room, 'team-sync');
  assert.equal(ready.server, 'https://calls.example.com');

  const chat = parseNativeWidgetMessage(
    androidEnvelope({ type: 'agil:chat', message: { text: 'hi', participantName: 'Анна' } }),
  );
  assert.ok(chat && chat.type === 'chat');
  if (chat?.type === 'chat') assert.equal(chat.message.text, 'hi');

  const state = parseNativeWidgetMessage(
    androidEnvelope({
      type: 'agil:state',
      state: { phase: 'joined', participants: 2, quality: { tier: 'good' } },
    }),
  );
  assert.ok(state && state.type === 'state');
  if (state?.type === 'state') {
    assert.equal(state.state.phase, 'joined');
    assert.equal(state.state.participants, 2);
  }

  const minimized = parseNativeWidgetMessage(
    androidEnvelope({ type: 'agil:minimized', minimized: true }),
  );
  assert.deepEqual(minimized, { type: 'minimized', minimized: true });

  // Native error notifications are plain JSON (no envelope) and still parse.
  const nativeError = parseNativeWidgetMessage(
    JSON.stringify({
      type: 'agil:event',
      event: 'error',
      payload: { code: 'load_failed', message: 'boom' },
    }),
  );
  assert.ok(nativeError && nativeError.type === 'error');
  if (nativeError?.type === 'error') {
    assert.equal(nativeError.error.code, 'widget-error');
    assert.equal(nativeError.error.widgetCode, 'load_failed');
  }
});

test('unwrapBridgeEnvelope leaves plain messages untouched and rejects bad input', () => {
  // Native error notifications bypass the shim and are plain widget JSON.
  const nativeError = JSON.stringify({
    type: 'agil:event',
    event: 'error',
    payload: { code: 'load_failed', message: 'boom' },
  });
  assert.equal(unwrapBridgeEnvelope(nativeError), nativeError);
  assert.equal(parseWidgetMessage(unwrapBridgeEnvelope(nativeError))?.type, 'error');

  assert.equal(unwrapBridgeEnvelope('not json'), 'not json');
  assert.equal(unwrapBridgeEnvelope('{"type":"agil:ready"}'), '{"type":"agil:ready"}');
  assert.equal(unwrapBridgeEnvelope(null), null);
  assert.equal(unwrapBridgeEnvelope({ type: 'agil:ready' }), null);
  assert.equal(
    unwrapBridgeEnvelope(
      JSON.stringify({ __agilBridgeNonce: 'n', message: { type: 'agil:ready' } }),
    ),
    JSON.stringify({ __agilBridgeNonce: 'n', message: { type: 'agil:ready' } }),
  );
  assert.equal(
    unwrapBridgeEnvelope('x'.repeat(DEFAULT_MAX_BRIDGE_CHARS + 1025)),
    null,
  );
});

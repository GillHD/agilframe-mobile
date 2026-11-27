#!/usr/bin/env node
/**
 * Headless JS smoke test for the injected Android bridge shim.
 *
 * It does not need Android, a browser or a Kotlin toolchain: the script is
 * extracted from `AgilBridgeProtocol.kt` (`AgilBridgeScript.shim`) by
 * substituting the four Kotlin string templates with JSON-quoted values, then
 * evaluated in a `node:vm` context with a fake `window`.
 *
 * What it proves (the contract reviewed by `AgilBridgeScriptTest` /
 * `AgilBridgeEnvelopeTest` on the JVM):
 *   1. the shim installs only in the top frame of the exact widget origin;
 *   2. every forwarded widget message is wrapped in the per-load nonce envelope
 *      `{"__agilBridgeNonce": "<nonce>", "message": "<widget json>"}`;
 *   3. host commands (`agil:action`, `agil:chat-send`, ...) are never echoed to
 *      native;
 *   4. a `message` event whose `source` is not the window is ignored (subframe);
 *   5. without a nonce nothing is forwarded (native bridge stays inert).
 *
 * Usage: node agil/mobile/android/scripts/shim-smoke.mjs
 * Exit code 0 = pass; non-zero = failure with details on stdout.
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
const sourcePath = join(
  here,
  '..',
  'agil-calls',
  'src',
  'main',
  'java',
  'com',
  'agilcalls',
  'sdk',
  'AgilBridgeProtocol.kt',
);

const ORIGIN = 'https://calls.example.com';
const NONCE = 'deadbeef'.repeat(8);

/** Extracts the `shim()` JS template from the Kotlin source and fills it in. */
export function buildShimSource(source, origin = ORIGIN, nonce = NONCE) {
  const start = source.indexOf('fun shim(');
  if (start < 0) throw new Error('AgilBridgeScript.shim(origin, nonce) not found');
  const templateStart = source.indexOf('"""', start);
  const templateEnd = source.indexOf('""".trimIndent()', templateStart);
  if (templateStart < 0 || templateEnd < 0) throw new Error('shim template literal not found');
  let body = source.slice(templateStart + 3, templateEnd);
  // Replace the longer template names first (`$quotedNonceField` vs `$quotedNonce`).
  const values = new Map([
    ['$quotedOrigin', JSON.stringify(origin)],
    ['$quotedNonceField', JSON.stringify('__agilBridgeNonce')],
    ['$quotedMessageField', JSON.stringify('message')],
    ['$quotedNonce', nonce ? JSON.stringify(nonce) : '""'],
  ]);
  for (const [token, value] of values) body = body.split(token).join(value);
  return body;
}

/** Minimal browser-ish window for the shim. */
function createWindow({ origin = ORIGIN, topIsWindow = true, withBridge = true } = {}) {
  const posted = [];
  const listeners = [];
  const window = {
    location: { origin },
    __agilAndroidBridgeInstalled: false,
    addEventListener(type, listener) {
      if (type === 'message') listeners.push(listener);
    },
  };
  if (withBridge) {
    window.AgilCallsBridge = { postMessage: (message) => posted.push(message) };
  }
  // `top` is a separate object when simulating a subframe.
  window.top = topIsWindow ? window : {};
  window.parent = window;
  return { window, posted, listeners };
}

function dispatch(listeners, data, source) {
  for (const listener of listeners) listener({ source, data });
}

function decodeEnvelope(raw, nonce) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!parsed || parsed.__agilBridgeNonce !== nonce) return null;
  if (typeof parsed.message !== 'string') return null;
  try {
    return JSON.parse(parsed.message);
  } catch {
    return null;
  }
}

const failures = [];
function check(condition, message) {
  if (!condition) failures.push(message);
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${message}`);
}

const shimSource = buildShimSource(readFileSync(sourcePath, 'utf8'));

function run(created) {
  const context = vm.createContext({ window: created.window, console });
  vm.runInContext(shimSource, context, { filename: 'agil-shim.js' });
  return created;
}

// 1. Top frame on the widget origin: installs and announces itself.
{
  const created = run(createWindow());
  check(created.listeners.length === 1, 'installs one message listener in the top frame');
  check(created.window.__agilAndroidBridgeInstalled === true, 'marks the shim as installed');
  check(created.posted.length === 1, 'posts the shim-alive beacon');
  const beacon = decodeEnvelope(created.posted[0] ?? '', NONCE);
  check(beacon?.type === 'agil:android-shim', 'beacon is wrapped in the nonce envelope');

  // 2. Widget messages are forwarded inside the envelope.
  dispatch(created.listeners, { type: 'agil:ready', capabilities: { media: true }, room: 'r' }, created.window);
  dispatch(created.listeners, { type: 'agil:event', event: 'joined', payload: {} }, created.window);
  dispatch(created.listeners, { type: 'agil:chat', message: { text: 'hi' } }, created.window);
  dispatch(created.listeners, { type: 'agil:state', state: { phase: 'joined' } }, created.window);
  check(created.posted.length === 5, 'forwards ready/event/chat/state');
  const ready = decodeEnvelope(created.posted[1] ?? '', NONCE);
  check(ready?.type === 'agil:ready' && ready.room === 'r', 'forwarded ready keeps its payload');
  for (const raw of created.posted) {
    const parsed = JSON.parse(raw);
    check(parsed.__agilBridgeNonce === NONCE, 'every posted message carries the load nonce');
    check(typeof parsed.message === 'string', 'every posted message carries a string payload');
  }

  // 3. Host commands must never be echoed back to native.
  const before = created.posted.length;
  dispatch(created.listeners, { type: 'agil:action', action: 'toggle-mic' }, created.window);
  dispatch(created.listeners, { type: 'agil:chat-send', text: 'x' }, created.window);
  dispatch(created.listeners, { type: 'agil:theme', theme: {} }, created.window);
  dispatch(created.listeners, { type: 'agil:ping' }, created.window);
  check(created.posted.length === before, 'filters host commands (action/chat-send/theme/ping)');

  // 4. A message whose source is not this window (a subframe event) is ignored.
  const beforeForeign = created.posted.length;
  dispatch(created.listeners, { type: 'agil:ready', capabilities: {} }, { otherWindow: true });
  check(created.posted.length === beforeForeign, 'ignores messages from another window');
}

// 5. Subframe: the shim must not install at all.
{
  const created = run(createWindow({ topIsWindow: false }));
  check(created.listeners.length === 0, 'does not install in a subframe (top !== window)');
  check(created.posted.length === 0, 'subframe posts nothing');
}

// 6. Wrong top-level origin: no install.
{
  const created = run(createWindow({ origin: 'https://evil.example' }));
  check(created.listeners.length === 0, 'does not install on a foreign origin');
  check(created.posted.length === 0, 'foreign origin posts nothing');
}

// 7. Without a nonce the shim is inert (bridge not armed).
{
  const source = buildShimSource(readFileSync(sourcePath, 'utf8'), ORIGIN, '');
  const created = createWindow();
  const context = vm.createContext({ window: created.window, console });
  vm.runInContext(source, context, { filename: 'agil-shim-empty-nonce.js' });
  check(created.listeners.length === 0, 'does not install without a nonce');
  check(created.posted.length === 0, 'posts nothing without a nonce');
}

// 8. A subframe that calls the injected interface directly is rejected natively:
//    the raw widget JSON has no envelope, so `decodeEnvelope` yields null. This
//    mirrors `AgilBridgeEnvelope.unwrap(raw, nonce)` in Kotlin.
{
  const forged = JSON.stringify({ type: 'agil:ready', capabilities: {} });
  check(decodeEnvelope(forged, NONCE) === null, 'raw forged message is not a valid envelope');
  const wrongNonce = JSON.stringify({ __agilBridgeNonce: 'other', message: forged });
  check(decodeEnvelope(wrongNonce, NONCE) === null, 'envelope with a wrong nonce is rejected');
}

if (failures.length > 0) {
  console.error(`\n${failures.length} shim check(s) failed`);
  process.exit(1);
}
console.log('\nAll shim checks passed (headless, node:vm)');

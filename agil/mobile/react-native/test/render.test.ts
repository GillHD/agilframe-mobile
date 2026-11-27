import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { buildAgilCallRenderState, widgetOrigin } from '../src/render.js';

// A mounted `<AgilCall />` test would need react + react-test-renderer plus the
// native-dependent react-native/react-native-webview runtime; none of those are
// installed here (they are optional peers of this package). The helpers below
// cover the render path that used to crash with a throwing `URL.origin`, and the
// source guard prevents `new URL(` from returning to the component. Mounted
// coverage remains a follow-up on a real RN/Expo host.

test('buildAgilCallRenderState computes the shim origin without URL.origin', () => {
  const OriginalURL = globalThis.URL;
  class ExplodingOriginURL extends OriginalURL {
    override get origin(): string {
      throw new Error('URL.origin is not implemented');
    }
  }
  // Reproduces the React Native URL polyfill: `.origin` throws. The render
  // helper must not touch it.
  (globalThis as { URL: typeof URL }).URL = ExplodingOriginURL as unknown as typeof URL;
  try {
    const state = buildAgilCallRenderState({
      serverUrl: 'https://calls.example.com/calls',
      roomId: 'room 1',
      tenantId: 'acme',
      joinToken: 'token-1',
    });
    assert.equal(state.error, null);
    assert.equal(state.origin, 'https://calls.example.com');
    assert.ok(state.url?.startsWith('https://calls.example.com/calls/embed.html?'));
    assert.equal(widgetOrigin(state.url), 'https://calls.example.com');
  } finally {
    (globalThis as { URL: typeof URL }).URL = OriginalURL;
  }
});

test('buildAgilCallRenderState returns a fatal invalid-config fallback', () => {
  const state = buildAgilCallRenderState({
    serverUrl: 'http://public.example.com',
    roomId: 'r1',
  });
  assert.equal(state.url, null);
  assert.equal(state.origin, null);
  assert.equal(state.error?.code, 'invalid-config');
  assert.equal(state.error?.fatal, true);
});

test('AgilCall component source does not use the global URL parser in render', () => {
  const source = readFileSync(new URL('../src/AgilCall.ts', import.meta.url), 'utf8');
  assert.equal(
    /new\s+URL\s*\(/.test(source),
    false,
    'AgilCall.ts must derive the shim origin via buildAgilCallRenderState/parseAbsoluteUrl',
  );
  assert.ok(source.includes('buildAgilCallRenderState'));
});

test('AgilCall reconnect rotates the nonce and remounts the same URL', () => {
  const source = readFileSync(new URL('../src/AgilCall.ts', import.meta.url), 'utf8');
  // A fresh nonce per document; the URL/token/tenant come from the same
  // `built.url`/configuration, so a reconnect cannot drop the join token.
  assert.match(source, /setBridgeNonce\(createBridgeNonce\(\)\)/);
  assert.match(source, /key: `\$\{built\.url\}#\$\{generation\}`/);
  assert.match(source, /participantsRef\.current\?\.reset\(\)/);
  assert.match(source, /connectionRef\.current\?\.reset\(\)/);
  assert.match(source, /reconnect/);
});

test('AgilCall WebView keeps large-room viewport/scroll/fullscreen flags', () => {
  const source = readFileSync(new URL('../src/AgilCall.ts', import.meta.url), 'utf8');
  assert.match(source, /allowsFullscreenVideo:\s*true/);
  assert.match(source, /allowsPictureInPictureMediaPlayback:\s*true/);
  assert.match(source, /bounces:\s*false/);
  assert.match(source, /overScrollMode:\s*'never'/);
  assert.match(source, /nestedScrollEnabled:\s*true/);
  assert.match(source, /contentInsetAdjustmentBehavior:\s*'never'/);
  assert.match(source, /setBuiltInZoomControls:\s*false/);
  assert.match(source, /showsVerticalScrollIndicator:\s*false/);
});

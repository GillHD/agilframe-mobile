import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  AgilConfigError,
  buildWidgetUrl,
  isAllowedNavigation,
  normalizeServerUrl,
  parseAgilCallLink,
  redactCallUrl,
  redactTokenText,
  serverOrigin,
} from '../src/url.js';

test('normalizeServerUrl trims, lowercases and strips default ports', () => {
  assert.equal(normalizeServerUrl('  HTTPS://Calls.Example.com/  '), 'https://calls.example.com');
  assert.equal(normalizeServerUrl('https://calls.example.com:443/calls/'), 'https://calls.example.com/calls');
  assert.equal(normalizeServerUrl('http://localhost:8787/'), 'http://localhost:8787');
  assert.equal(serverOrigin('https://calls.example.com/calls'), 'https://calls.example.com');
});

test('normalizeServerUrl rejects unsafe or malformed URLs', () => {
  for (const value of [
    '',
    '   ',
    'calls.example.com',
    'javascript:alert(1)',
    'file:///etc/passwd',
    'https://user:pass@calls.example.com',
    'https://calls.example.com?token=leak',
    'https://calls.example.com#frag',
    'https://calls.example.com/\u0000',
  ]) {
    assert.throws(() => normalizeServerUrl(value), AgilConfigError, value);
  }
});

test('buildWidgetUrl builds the documented embed URL', () => {
  const url = buildWidgetUrl({
    serverUrl: 'https://calls.example.com',
    roomId: 'daily-sync',
    joinToken: 'join-token',
    tenantId: 'acme',
    participantName: 'Анна',
    language: 'ru',
    theme: 'dark',
    role: 'guest',
    relayOnly: true,
  });
  assert.ok(url.startsWith('https://calls.example.com/embed.html?'));
  const params = new URL(url).searchParams;
  assert.equal(params.get('server'), 'https://calls.example.com');
  assert.equal(params.get('room'), 'daily-sync');
  assert.equal(params.get('token'), 'join-token');
  assert.equal(params.get('tenant'), 'acme');
  assert.equal(params.get('name'), 'Анна');
  assert.equal(params.get('lang'), 'ru');
  assert.equal(params.get('theme'), 'dark');
  assert.equal(params.get('role'), 'guest');
  assert.equal(params.get('relay'), '1');
});

test('buildWidgetUrl preserves subpaths and supports root-relative widgetPath', () => {
  assert.ok(
    buildWidgetUrl({ serverUrl: 'https://host/calls', roomId: 'r' }).startsWith(
      'https://host/calls/embed.html?',
    ),
  );
  assert.ok(
    buildWidgetUrl({ serverUrl: 'https://host/calls', roomId: 'r', widgetPath: '/embed.html' }).startsWith(
      'https://host/embed.html?',
    ),
  );
});

test('buildWidgetUrl defaults tenant and omits optional params', () => {
  const params = new URL(
    buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r' }),
  ).searchParams;
  assert.equal(params.get('tenant'), 'demo');
  for (const key of ['token', 'name', 'theme', 'lang', 'role', 'relay', 'identity_token']) {
    assert.equal(params.has(key), false, key);
  }
});

test('buildWidgetUrl rejects widgetPath traversal and absolute URLs', () => {
  for (const widgetPath of [
    '../embed.html',
    'a/../embed.html',
    './embed.html',
    'https://evil.example/x',
    '//evil.example/x',
    'embed.html?x=1',
    'calls\\embed.html',
  ]) {
    assert.throws(
      () => buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', widgetPath }),
      AgilConfigError,
      widgetPath,
    );
  }
});

test('buildWidgetUrl requires https outside dev hosts', () => {
  assert.throws(
    () => buildWidgetUrl({ serverUrl: 'http://calls.example.com', roomId: 'r' }),
    AgilConfigError,
  );
  assert.ok(
    buildWidgetUrl({ serverUrl: 'http://localhost:8787', roomId: 'r' }).startsWith(
      'http://localhost:8787/embed.html?',
    ),
  );
  assert.ok(
    buildWidgetUrl({ serverUrl: 'http://10.0.2.2:8787', roomId: 'r' }).startsWith(
      'http://10.0.2.2:8787/embed.html?',
    ),
  );
  assert.ok(
    buildWidgetUrl({ serverUrl: 'http://calls.example.com', roomId: 'r', allowInsecure: true }).startsWith(
      'http://calls.example.com/embed.html?',
    ),
  );
});

test('buildWidgetUrl validates room and token without leaking the token', () => {
  assert.throws(
    () => buildWidgetUrl({ serverUrl: 'https://host', roomId: '' }),
    AgilConfigError,
  );
  try {
    buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', joinToken: 'secret token with spaces' });
    assert.fail('expected AgilConfigError');
  } catch (error) {
    if (!(error instanceof AgilConfigError)) throw error;
    assert.equal(error.field, 'joinToken');
    assert.equal(error.message.includes('secret'), false);
  }
});

test('parseAgilCallLink round-trips a built URL', () => {
  const url = buildWidgetUrl({
    serverUrl: 'https://host/calls',
    roomId: 'team sync',
    joinToken: 'token-1',
    tenantId: 'acme',
    participantName: 'Анна & Co',
    language: 'en',
    theme: 'light',
    role: 'host',
    identityToken: 'id-token',
    relayOnly: true,
  });
  const link = parseAgilCallLink(url);
  assert.ok(link);
  assert.equal(link.kind, 'embed');
  assert.equal(link.serverUrl, 'https://host/calls');
  assert.equal(link.roomId, 'team sync');
  assert.equal(link.joinToken, 'token-1');
  assert.equal(link.tenantId, 'acme');
  assert.equal(link.participantName, 'Анна & Co');
  assert.equal(link.language, 'en');
  assert.equal(link.theme, 'light');
  assert.equal(link.role, 'host');
  assert.equal(link.identityToken, 'id-token');
  assert.equal(link.relayOnly, true);
});

test('parseAgilCallLink rejects cross-origin server parameters and bad links', () => {
  assert.equal(
    parseAgilCallLink(
      'https://calls.corp/embed.html?server=https%3A%2F%2Fevil.example&room=r&token=secret',
    ),
    null,
  );
  assert.equal(parseAgilCallLink('https://host/other.html?room=r'), null);
  assert.equal(parseAgilCallLink('javascript:alert(1)'), null);
  assert.equal(parseAgilCallLink('file:///etc/passwd'), null);
  assert.equal(parseAgilCallLink('https://host/embed.html'), null);
  assert.equal(parseAgilCallLink('https://host/embed.html?room='), null);
  assert.equal(parseAgilCallLink('https://host/embed.html?room=r&token=a%20b'), null);
});

test('parseAgilCallLink honours the origin allowlist for http(s) links', () => {
  const url = buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r' });
  assert.ok(parseAgilCallLink(url, { allowedOrigins: ['https://host'] }));
  assert.equal(parseAgilCallLink(url, { allowedOrigins: ['https://other'] }), null);
});

test('parseAgilCallLink requires trusted origins for custom schemes', () => {
  const link = 'agilcalls://call?server=https%3A%2F%2Fhost&room=r&token=t&tenant=acme';
  assert.equal(parseAgilCallLink(link), null);
  const parsed = parseAgilCallLink(link, { allowedOrigins: ['https://host'] });
  assert.ok(parsed);
  assert.equal(parsed.kind, 'deep-link');
  assert.equal(parsed.serverUrl, 'https://host');
  assert.equal(parsed.roomId, 'r');
  assert.equal(parsed.joinToken, 't');
  assert.equal(parseAgilCallLink(link, { allowedOrigins: ['https://evil.example'] }), null);
  assert.equal(
    parseAgilCallLink(link, { allowedOrigins: ['https://host'], allowedSchemes: ['myapp'] }),
    null,
  );
});

test('parseAgilCallLink rejects public http links but allows loopback', () => {
  assert.equal(parseAgilCallLink('http://calls.example.com/embed.html?room=r'), null);
  assert.ok(parseAgilCallLink('http://localhost:8787/embed.html?room=r'));
});

test('isAllowedNavigation allows the widget origin and extra origins only', () => {
  assert.equal(
    isAllowedNavigation('https://host/calls/embed.html?room=r', { serverUrl: 'https://host/calls' }),
    true,
  );
  assert.equal(
    isAllowedNavigation('https://host/other', {
      serverUrl: 'https://host',
      allowedOrigins: ['https://host'],
    }),
    true,
  );
  assert.equal(
    isAllowedNavigation('https://idp.example/login', {
      serverUrl: 'https://host',
      allowedOrigins: ['https://idp.example'],
    }),
    true,
  );
  assert.equal(isAllowedNavigation('https://evil.example/', { serverUrl: 'https://host' }), false);
  assert.equal(isAllowedNavigation('javascript:alert(1)', { serverUrl: 'https://host' }), false);
  assert.equal(isAllowedNavigation('file:///etc/passwd', { serverUrl: 'https://host' }), false);
  assert.equal(isAllowedNavigation('intent://scan', { serverUrl: 'https://host' }), false);
  assert.equal(isAllowedNavigation('about:blank', { serverUrl: 'https://host' }), true);
  assert.equal(isAllowedNavigation('', { serverUrl: 'https://host' }), false);
});

test('redactCallUrl masks tokens but keeps the room', () => {
  const redacted = redactCallUrl(
    'https://host/embed.html?server=https%3A%2F%2Fhost&room=r&token=secret&identity_token=id&access_token=access',
  );
  assert.equal(redacted.includes('secret'), false);
  assert.equal(redacted.includes('id='), false);
  assert.equal(redacted.includes('access='), false);
  assert.ok(redacted.includes('room=r'));
  assert.ok(redacted.includes('token=redacted'));
  assert.ok(redacted.includes('identity_token=redacted'));
  assert.ok(redacted.includes('access_token=redacted'));
});

test('redactTokenText masks JWT-looking strings and bare tokens', () => {
  const text =
    'failed for token=abc.def and eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature123';
  const redacted = redactTokenText(text);
  assert.equal(redacted.includes('abc.def'), false);
  assert.equal(redacted.includes('eyJhbGciOiJIUzI1NiJ9'), false);
  assert.ok(redacted.includes('redacted'));
});

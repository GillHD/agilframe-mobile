import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizePath,
  parseAbsoluteUrl,
  parseQuery,
  resolveWidgetPath,
  serializeQuery,
  serializeUrl,
} from '../src/url-core.js';
import { buildWidgetUrl, normalizeServerUrl, parseAgilCallLink } from '../src/url.js';

test('parseAbsoluteUrl parses http(s), IPv6, query and fragment', () => {
  const parsed = parseAbsoluteUrl('https://[::1]:8443/calls/embed.html?room=r#frag');
  assert.ok(parsed);
  assert.equal(parsed.scheme, 'https');
  assert.equal(parsed.hostname, '[::1]');
  assert.equal(parsed.port, '8443');
  assert.equal(parsed.pathname, '/calls/embed.html');
  assert.equal(parsed.query, 'room=r');
  assert.equal(parsed.hash, 'frag');
  assert.equal(parsed.origin, 'https://[::1]:8443');
  assert.equal(parsed.userinfo, null);

  const defaultPort = parseAbsoluteUrl('https://Host:443/calls');
  assert.ok(defaultPort);
  assert.equal(defaultPort.port, null);
  assert.equal(defaultPort.origin, 'https://host');
  assert.equal(defaultPort.pathname, '/calls');
});

test('parseAbsoluteUrl rejects malformed and unsafe inputs', () => {
  assert.equal(parseAbsoluteUrl(''), null);
  assert.equal(parseAbsoluteUrl('not a url'), null);
  assert.equal(parseAbsoluteUrl('https://'), null);
  assert.equal(parseAbsoluteUrl('https://host:bad'), null);
  assert.equal(parseAbsoluteUrl('https://host:99999'), null);
  assert.equal(parseAbsoluteUrl('https://host with space'), null);
  assert.equal(parseAbsoluteUrl('javascript:alert(1)'), null);
  assert.equal(parseAbsoluteUrl('file:///etc/passwd'), null);
});

test('query serialization round-trips unicode, spaces and reserved characters', () => {
  const pairs = [
    ['name', 'Анна & Co'],
    ['room', 'team sync'],
    ['token', 'a.b.c'],
  ] as const;
  const raw = serializeQuery([...pairs]);
  assert.equal(raw.includes(' '), false);
  const parsed = parseQuery(raw);
  assert.equal(parsed.get('name')?.[0], 'Анна & Co');
  assert.equal(parsed.get('room')?.[0], 'team sync');
  assert.equal(parsed.get('token')?.[0], 'a.b.c');
  assert.equal(parseQuery('name=Anna+Smith').get('name')?.[0], 'Anna Smith');
  assert.equal(parseQuery('bad=%E0%A4%A').size, 0);
});

test('serializeUrl omits an empty path for custom schemes', () => {
  const url = serializeUrl({
    scheme: 'myapp',
    hostname: 'call',
    port: null,
    pathname: '',
    query: 'room=r1',
    hash: null,
  });
  assert.equal(url, 'myapp://call?room=r1');
});

test('normalizePath and resolveWidgetPath handle dots and subpaths', () => {
  assert.equal(normalizePath('/a/./b/../c'), '/a/c');
  assert.equal(normalizePath('/a//b/'), '/a/b/');
  assert.equal(normalizePath(''), '/');
  assert.equal(resolveWidgetPath('/calls', 'embed.html'), '/calls/embed.html');
  assert.equal(resolveWidgetPath('/calls/', 'meeting/embed.html'), '/calls/meeting/embed.html');
  assert.equal(resolveWidgetPath('/calls', '/embed.html'), '/embed.html');
});

test('normalizeServerUrl normalizes default ports, IPv6 and dot segments', () => {
  assert.equal(normalizeServerUrl('https://host:443/'), 'https://host');
  assert.equal(normalizeServerUrl('http://host:80/calls'), 'http://host/calls');
  assert.equal(normalizeServerUrl('https://[::1]:8443/calls/'), 'https://[::1]:8443/calls');
  assert.equal(normalizeServerUrl('https://host/a/../b'), 'https://host/b');
});

test('parseAgilCallLink decodes + as space in participant names', () => {
  const parsed = parseAgilCallLink('https://host/embed.html?room=r1&name=Anna+Smith');
  assert.ok(parsed);
  assert.equal(parsed.participantName, 'Anna Smith');
});

test('URL helpers do not depend on the global URL/URLSearchParams classes', () => {
  const globals = globalThis as Record<string, unknown>;
  const originalUrl = globals.URL;
  const originalParams = globals.URLSearchParams;
  const disabled = function disabledUrl(): never {
    throw new Error('global URL must not be used');
  };
  globals.URL = disabled;
  globals.URLSearchParams = disabled;
  try {
    assert.equal(
      buildWidgetUrl({ serverUrl: 'https://host/calls', roomId: 'r1', joinToken: 'a.b.c' }),
      'https://host/calls/embed.html?server=https%3A%2F%2Fhost%2Fcalls&room=r1&token=a.b.c&tenant=demo',
    );
    assert.equal(normalizeServerUrl('https://host:443/calls/'), 'https://host/calls');
    assert.equal(parseAgilCallLink('https://host/embed.html?room=r1')?.roomId, 'r1');
  } finally {
    globals.URL = originalUrl;
    globals.URLSearchParams = originalParams;
  }
});

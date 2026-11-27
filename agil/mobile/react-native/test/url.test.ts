import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  AgilConfigError,
  buildCallDeepLink,
  buildWidgetUrl,
  isAllowedNavigation,
  normalizeServerUrl,
  parseAgilCallLink,
  redactCallUrl,
  redactSecrets,
  redactTokenText,
  serverOrigin,
} from '../src/url.js';

test('normalizeServerUrl keeps origin + subpath and strips trailing slashes', () => {
  assert.equal(normalizeServerUrl('https://Calls.Example.com/'), 'https://calls.example.com');
  assert.equal(normalizeServerUrl('http://localhost:8787///'), 'http://localhost:8787');
  assert.equal(normalizeServerUrl('https://host/calls/'), 'https://host/calls');
  assert.equal(normalizeServerUrl('https://host/calls'), 'https://host/calls');
});

test('normalizeServerUrl rejects non-http, credentials, query and fragment', () => {
  assert.throws(() => normalizeServerUrl(''), AgilConfigError);
  assert.throws(() => normalizeServerUrl('javascript:alert(1)'), /http or https/);
  assert.throws(() => normalizeServerUrl('file:///etc/passwd'), /http or https/);
  assert.throws(() => normalizeServerUrl('https://user:pass@host'), /credentials/);
  assert.throws(() => normalizeServerUrl('https://host/?a=1'), /query string or fragment/);
  assert.throws(() => normalizeServerUrl('https://host/#frag'), /query string or fragment/);
  assert.throws(() => normalizeServerUrl('not a url'), /absolute http/);
});

test('buildWidgetUrl builds the documented embed URL', () => {
  const url = new URL(
    buildWidgetUrl({
      serverUrl: 'https://calls.example.com/',
      tenantId: 'acme',
      roomId: 'team sync',
      joinToken: 'header.payload.signature',
      participantName: 'Анна & Co',
      role: 'moderator',
      language: 'en',
      theme: 'dark',
      identityToken: 'id.token.value',
      relayOnly: true,
    }),
  );
  assert.equal(url.origin, 'https://calls.example.com');
  assert.equal(url.pathname, '/embed.html');
  assert.equal(url.searchParams.get('server'), 'https://calls.example.com');
  assert.equal(url.searchParams.get('room'), 'team sync');
  assert.equal(url.searchParams.get('tenant'), 'acme');
  assert.equal(url.searchParams.get('token'), 'header.payload.signature');
  assert.equal(url.searchParams.get('name'), 'Анна & Co');
  assert.equal(url.searchParams.get('role'), 'moderator');
  assert.equal(url.searchParams.get('lang'), 'en');
  assert.equal(url.searchParams.get('theme'), 'dark');
  assert.equal(url.searchParams.get('identity_token'), 'id.token.value');
  assert.equal(url.searchParams.get('relay'), '1');
  assert.equal(url.hash, '');
});

test('buildWidgetUrl defaults tenant to demo and omits empty options', () => {
  const url = new URL(buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r1' }));
  assert.equal(url.searchParams.get('tenant'), 'demo');
  assert.equal(url.searchParams.get('token'), null);
  assert.equal(url.searchParams.get('name'), null);
  assert.equal(url.searchParams.get('lang'), null);
  assert.equal(url.searchParams.get('theme'), null);
});

test('buildWidgetUrl preserves subpath deployments and supports root-relative widgetPath', () => {
  const subpath = new URL(buildWidgetUrl({ serverUrl: 'https://host/calls', roomId: 'r1' }));
  assert.equal(subpath.pathname, '/calls/embed.html');
  assert.equal(subpath.searchParams.get('server'), 'https://host/calls');

  const root = new URL(
    buildWidgetUrl({ serverUrl: 'https://host/calls', roomId: 'r1', widgetPath: '/embed.html' }),
  );
  assert.equal(root.pathname, '/embed.html');
  assert.equal(root.searchParams.get('server'), 'https://host/calls');

  const custom = new URL(
    buildWidgetUrl({ serverUrl: 'https://host/calls/', roomId: 'r1', widgetPath: 'meeting/embed.html' }),
  );
  assert.equal(custom.pathname, '/calls/meeting/embed.html');
});

test('buildWidgetUrl rejects widgetPath escaping the server origin', () => {
  assert.throws(
    () => buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', widgetPath: '//evil.example/embed.html' }),
    AgilConfigError,
  );
  assert.throws(
    () => buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', widgetPath: 'https://evil.example/embed.html' }),
    AgilConfigError,
  );
  assert.throws(
    () => buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', widgetPath: '../embed.html' }),
    /"\." or ".."/,
  );
  assert.throws(
    () => buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', widgetPath: 'embed.html?x=1' }),
    /query string/,
  );
});

test('buildWidgetUrl validates room, token, language, theme and role', () => {
  assert.throws(() => buildWidgetUrl({ serverUrl: 'https://host', roomId: ' ' }), /roomId/);
  assert.throws(
    () => buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', joinToken: ' has space ' }),
    /whitespace/,
  );
  assert.throws(
    () => buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', joinToken: 'x'.repeat(9000) }),
    /too long/,
  );
  assert.throws(
    () => buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', language: 'de' as never }),
    /language/,
  );
  assert.throws(
    () => buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', theme: 'blue' as never }),
    /theme/,
  );
  assert.throws(() => buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', role: 'admin' as never }), /role/);
});

test('buildWidgetUrl errors never contain the token', () => {
  const secret = 'SECRET-TOKEN-VALUE';
  try {
    buildWidgetUrl({ serverUrl: 'https://host', roomId: 'r', joinToken: `${secret} with space` });
    assert.fail('expected an error');
  } catch (error) {
    assert.ok(error instanceof Error);
    assert.equal(error.message.includes(secret), false);
  }
});

test('buildCallDeepLink round-trips through parseAgilCallLink', () => {
  const link = buildCallDeepLink({
    serverUrl: 'https://calls.example.com/calls',
    tenantId: 'acme',
    roomId: 'r1',
    joinToken: 'a.b.c',
    participantName: 'Анна',
    language: 'ru',
    theme: 'auto',
  });
  assert.ok(link.startsWith('agilcalls://call?'));
  const parsed = parseAgilCallLink(link, { allowedOrigins: ['https://calls.example.com'] });
  assert.ok(parsed);
  assert.equal(parsed.kind, 'deep-link');
  assert.equal(parsed.serverUrl, 'https://calls.example.com/calls');
  assert.equal(parsed.tenantId, 'acme');
  assert.equal(parsed.roomId, 'r1');
  assert.equal(parsed.joinToken, 'a.b.c');
  assert.equal(parsed.participantName, 'Анна');
  assert.equal(parsed.language, 'ru');
  assert.equal(parsed.theme, 'auto');
});

test('buildCallDeepLink rejects HTTP and dangerous schemes', () => {
  const options = { serverUrl: 'https://host', roomId: 'r1' };
  assert.throws(() => buildCallDeepLink(options, 'javascript'), /custom app scheme/);
  assert.throws(() => buildCallDeepLink(options, 'https'), /custom app scheme/);
  assert.throws(() => buildCallDeepLink(options, '1bad'), /invalid/);
  const custom = buildCallDeepLink(options, 'myapp');
  assert.ok(custom.startsWith('myapp://call?'));
});

test('parseAgilCallLink parses an embed URL and derives the server', () => {
  const parsed = parseAgilCallLink(
    'https://calls.example.com/embed.html?room=r1&tenant=acme&token=a.b.c&name=Anna&lang=en&theme=dark&role=guest',
  );
  assert.ok(parsed);
  assert.equal(parsed.kind, 'embed');
  assert.equal(parsed.serverUrl, 'https://calls.example.com');
  assert.equal(parsed.tenantId, 'acme');
  assert.equal(parsed.roomId, 'r1');
  assert.equal(parsed.joinToken, 'a.b.c');
  assert.equal(parsed.participantName, 'Anna');
  assert.equal(parsed.language, 'en');
  assert.equal(parsed.theme, 'dark');
  assert.equal(parsed.role, 'guest');
});

test('parseAgilCallLink preserves a subpath and accepts a matching server parameter', () => {
  const parsed = parseAgilCallLink(
    'https://host/calls/embed.html?room=r1&server=https%3A%2F%2Fhost%2Fcalls',
  );
  assert.ok(parsed);
  assert.equal(parsed.serverUrl, 'https://host/calls');
  assert.equal(parsed.kind, 'embed');
});

test('parseAgilCallLink rejects cross-origin and path-confused server parameters', () => {
  assert.equal(
    parseAgilCallLink('https://calls.corp/embed.html?room=r&server=https%3A%2F%2Fevil.example'),
    null,
  );
  assert.equal(
    parseAgilCallLink('https://calls.corp/embed.html?room=r&server=https%3A%2F%2Fcalls.corp%2Fother'),
    null,
  );
  assert.equal(parseAgilCallLink('https://calls.corp/embed.html?room=r&server=javascript%3Aalert(1)'), null);
});

test('parseAgilCallLink rejects public http links but allows loopback', () => {
  assert.equal(parseAgilCallLink('http://calls.example.com/embed.html?room=r'), null);
  assert.ok(parseAgilCallLink('http://localhost:8787/embed.html?room=r'));
  assert.ok(
    parseAgilCallLink('http://calls.example.com/embed.html?room=r', { allowInsecure: true }),
  );
});

test('parseAgilCallLink requires an allowlist for custom-scheme links', () => {
  const deep = buildCallDeepLink({ serverUrl: 'https://calls.corp', roomId: 'r1' });
  assert.equal(parseAgilCallLink(deep), null);
  assert.equal(
    parseAgilCallLink(
      'agilcalls://call?server=https%3A%2F%2Fevil.example&room=r&token=t',
      { allowedOrigins: ['https://calls.corp'] },
    ),
    null,
  );
});

test('buildWidgetUrl rejects public http outside development', () => {
  assert.throws(
    () => buildWidgetUrl({ serverUrl: 'http://calls.example.com', roomId: 'r' }),
    /must use https/,
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
    buildWidgetUrl({
      serverUrl: 'http://calls.example.com',
      roomId: 'r',
      allowInsecure: true,
    }).startsWith('http://calls.example.com/embed.html?'),
  );
  assert.equal(
    serverOrigin('https://calls.example.com/calls'),
    'https://calls.example.com',
  );
  assert.throws(() => serverOrigin('not a url'), AgilConfigError);
});

test('parseAgilCallLink rejects unsafe or malformed links', () => {
  assert.equal(parseAgilCallLink('javascript:alert(1)'), null);
  assert.equal(parseAgilCallLink('file:///tmp/embed.html?room=r'), null);
  assert.equal(parseAgilCallLink('https://host/meeting?room=r'), null);
  assert.equal(parseAgilCallLink('https://host/embed.html'), null);
  assert.equal(parseAgilCallLink('https://host/embed.html?room=r&token=has%20space'), null);
  assert.equal(parseAgilCallLink('not a link'), null);
  assert.equal(parseAgilCallLink('x'.repeat(9000)), null);
  assert.equal(parseAgilCallLink('agilcalls://call?room=r1'), null);
});

test('parseAgilCallLink supports parameter aliases and ignores invalid optional values', () => {
  const parsed = parseAgilCallLink(
    'https://host/embed.html?roomId=r1&tenantId=acme&joinToken=a.b.c&participantName=Anna&language=ru&theme=blue&role=admin',
  );
  assert.ok(parsed);
  assert.equal(parsed.roomId, 'r1');
  assert.equal(parsed.tenantId, 'acme');
  assert.equal(parsed.joinToken, 'a.b.c');
  assert.equal(parsed.participantName, 'Anna');
  assert.equal(parsed.language, 'ru');
  assert.equal(parsed.theme, undefined);
  assert.equal(parsed.role, undefined);
});

test('parseAgilCallLink enforces allowedOrigins for embed and custom links', () => {
  const embed = 'https://calls.corp/embed.html?room=r1';
  assert.equal(parseAgilCallLink(embed, { allowedOrigins: ['https://other.corp'] }), null);
  assert.ok(parseAgilCallLink(embed, { allowedOrigins: ['https://calls.corp'] }));

  const deep = buildCallDeepLink({ serverUrl: 'https://calls.corp', roomId: 'r1' });
  assert.equal(parseAgilCallLink(deep, { allowedOrigins: ['https://evil.example'] }), null);
  assert.ok(parseAgilCallLink(deep, { allowedOrigins: ['https://calls.corp'] }));
});

test('isAllowedNavigation allows only the widget origin, about:blank and explicit origins', () => {
  const policy = { serverUrl: 'https://calls.example.com/calls', allowedOrigins: ['https://idp.example.com'] };
  assert.equal(isAllowedNavigation('about:blank', policy), true);
  assert.equal(isAllowedNavigation('about:srcdoc', policy), true);
  assert.equal(isAllowedNavigation('https://calls.example.com/calls/embed.html?room=r', policy), true);
  assert.equal(isAllowedNavigation('https://calls.example.com/other', policy), true);
  assert.equal(isAllowedNavigation('https://idp.example.com/login', policy), true);
  assert.equal(isAllowedNavigation('https://evil.example/', policy), false);
  assert.equal(isAllowedNavigation('https://calls.example.com.evil.example/', policy), false);
  assert.equal(isAllowedNavigation('javascript:alert(1)', policy), false);
  assert.equal(isAllowedNavigation('file:///etc/passwd', policy), false);
  assert.equal(isAllowedNavigation('data:text/html,hi', policy), false);
  assert.equal(isAllowedNavigation('', policy), false);
  assert.equal(isAllowedNavigation('https://calls.example.com', { serverUrl: 'not a url' }), false);
});

test('redactCallUrl and redactTokenText never leak tokens', () => {
  const redacted = redactCallUrl(
    'https://user:pass@host/embed.html?room=r&token=SECRET&identity_token=ID&name=Anna',
  );
  assert.ok(!redacted.includes('SECRET'));
  assert.ok(!redacted.includes('ID'));
  assert.ok(!redacted.includes('user:pass'));
  assert.ok(redacted.includes('room=r'));
  assert.ok(redacted.includes('name=Anna'));

  const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturevalue';
  const text = redactTokenText(`failed https://host/embed.html?token=${jwt} for ${jwt}`);
  assert.ok(!text.includes(jwt));
  assert.ok(text.includes('token=redacted'));
  assert.equal(redactCallUrl('not a url token=SECRET'), 'not a url token=redacted');
});

test('redactTokenText covers access_token and bare secret values', () => {
  const redacted = redactTokenText('redirect https://host/cb?access_token=SECRET&x=1');
  assert.equal(redacted.includes('SECRET'), false);
  assert.ok(redacted.includes('access_token=redacted'));
  const bare = redactSecrets('failed with SECRET and token=OTHER', ['SECRET', 'OTHER']);
  assert.equal(bare.includes('SECRET'), false);
  assert.equal(bare.includes('OTHER'), false);
  assert.ok(bare.includes('[redacted]'));
});

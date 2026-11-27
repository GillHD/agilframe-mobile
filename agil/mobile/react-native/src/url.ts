/**
 * Pure URL/deep-link helpers for the React Native wrapper.
 *
 * Security invariants (covered by `test/url.test.ts`):
 *  - only `http:`/`https:` server URLs are accepted (no `javascript:`, `file:`);
 *  - credentials, query strings and fragments are rejected in `serverUrl`;
 *  - every user-supplied value is length-limited and control-character checked;
 *  - `parseAgilCallLink()` never trusts a cross-origin `server` parameter, so a
 *    crafted deep link cannot redirect a join token to another host;
 *  - errors never include the token.
 *
 * This module has no React Native imports and does not use the global `URL` /
 * `URLSearchParams` classes (React Native ships partial implementations), so it
 * is safe both in Hermes and in Node unit tests.
 */
import type {
  AgilCallLink,
  AgilLanguage,
  AgilRole,
  AgilThemeScheme,
} from './core-types.js';
import {
  firstQueryValue,
  parseAbsoluteUrl,
  parseQuery,
  resolveWidgetPath,
  serializeQuery,
  serializeUrl,
  type QueryPairs,
} from './url-core.js';

const MAX_URL_LENGTH = 8192;
const MAX_TOKEN_LENGTH = 8192;
const MAX_ROOM_LENGTH = 200;
const MAX_NAME_LENGTH = 120;
const MAX_TENANT_LENGTH = 64;
const MAX_PATH_LENGTH = 200;

// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;
const WIDGET_HTML = '/embed.html';
const DEFAULT_WIDGET_PATH = 'embed.html';

export class AgilConfigError extends Error {
  readonly code = 'invalid-config' as const;
  readonly field?: string;

  constructor(message: string, field?: string) {
    super(message);
    this.name = 'AgilConfigError';
    this.field = field;
  }
}

export interface AgilWidgetUrlOptions {
  serverUrl: string;
  roomId: string;
  joinToken?: string;
  tenantId?: string;
  participantName?: string;
  role?: AgilRole;
  language?: AgilLanguage;
  theme?: AgilThemeScheme;
  identityToken?: string;
  relayOnly?: boolean;
  /** Page path relative to `serverUrl` (`embed.html` by default; `/embed.html` is root-relative). */
  widgetPath?: string;
  /** Allow a non-loopback `http://` server URL. Development only. */
  allowInsecure?: boolean;
}

interface NormalizedOptions {
  serverUrl: string;
  roomId: string;
  joinToken?: string;
  tenantId: string;
  participantName?: string;
  role?: AgilRole;
  language?: AgilLanguage;
  theme?: AgilThemeScheme;
  identityToken?: string;
  relayOnly?: boolean;
  widgetPath: string;
}

/**
 * Validates and normalizes a server base URL. The result has no trailing slash,
 * no query string, no fragment and no credentials.
 */
export function normalizeServerUrl(input: string): string {
  if (typeof input !== 'string' || !input.trim()) {
    throw new AgilConfigError('serverUrl is required', 'serverUrl');
  }
  const raw = input.trim();
  if (raw.length > MAX_URL_LENGTH) {
    throw new AgilConfigError('serverUrl is too long', 'serverUrl');
  }
  if (CONTROL_CHARS.test(raw)) {
    throw new AgilConfigError('serverUrl contains control characters', 'serverUrl');
  }
  const parsed = parseAbsoluteUrl(raw);
  if (!parsed) {
    throw new AgilConfigError('serverUrl must be an absolute http or https URL', 'serverUrl');
  }
  if (parsed.scheme !== 'https' && parsed.scheme !== 'http') {
    throw new AgilConfigError('serverUrl must use http or https', 'serverUrl');
  }
  if (parsed.userinfo) {
    throw new AgilConfigError('serverUrl must not contain credentials', 'serverUrl');
  }
  if (parsed.query !== null || parsed.hash !== null) {
    throw new AgilConfigError('serverUrl must not contain a query string or fragment', 'serverUrl');
  }
  const pathname = parsed.pathname.replace(/\/+$/, '');
  return `${parsed.origin}${pathname === '' || pathname === '/' ? '' : pathname}`;
}

/** `true` for hosts allowed to use plain HTTP during development. */
export function isLoopbackHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[/, '').replace(/\]$/, '');
  return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '10.0.2.2';
}

/** Exact origin of a normalized server URL (never uses the RN global `URL`). */
export function serverOrigin(serverUrl: string): string {
  const parsed = parseAbsoluteUrl(normalizeServerUrl(serverUrl));
  if (!parsed) throw new AgilConfigError('serverUrl could not be parsed', 'serverUrl');
  return parsed.origin;
}

function assertSecure(serverUrl: string, allowInsecure?: boolean): void {
  const parsed = parseAbsoluteUrl(serverUrl);
  if (!parsed) throw new AgilConfigError('serverUrl could not be parsed', 'serverUrl');
  if (parsed.scheme === 'https') return;
  if (allowInsecure === true || isLoopbackHost(parsed.hostname)) return;
  throw new AgilConfigError(
    'serverUrl must use https (pass allowInsecure: true only for local development)',
    'serverUrl',
  );
}

function assertRoomId(value: unknown): string {
  if (typeof value !== 'string') throw new AgilConfigError('roomId is required', 'roomId');
  const room = value.trim();
  if (!room) throw new AgilConfigError('roomId is required', 'roomId');
  if (room.length > MAX_ROOM_LENGTH) throw new AgilConfigError('roomId is too long', 'roomId');
  if (CONTROL_CHARS.test(room)) throw new AgilConfigError('roomId contains control characters', 'roomId');
  return room;
}

function assertToken(value: unknown, field: string): string {
  if (typeof value !== 'string') throw new AgilConfigError(`${field} must be a string`, field);
  if (!value) throw new AgilConfigError(`${field} must not be empty`, field);
  if (value.length > MAX_TOKEN_LENGTH) throw new AgilConfigError(`${field} is too long`, field);
  if (CONTROL_CHARS.test(value) || /\s/.test(value)) {
    throw new AgilConfigError(`${field} must not contain whitespace or control characters`, field);
  }
  return value;
}

function optionalName(value: unknown, field: string, maxLength: number): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'string') throw new AgilConfigError(`${field} must be a string`, field);
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  if (trimmed.length > maxLength) throw new AgilConfigError(`${field} is too long`, field);
  if (CONTROL_CHARS.test(trimmed)) throw new AgilConfigError(`${field} contains control characters`, field);
  return trimmed;
}

function assertTenant(value: unknown): string {
  const tenant = optionalName(value, 'tenantId', MAX_TENANT_LENGTH);
  return tenant ?? 'demo';
}

function assertLanguage(value: unknown): AgilLanguage | undefined {
  if (value === undefined || value === null) return undefined;
  if (value === 'ru' || value === 'en') return value;
  throw new AgilConfigError('language must be "ru" or "en"', 'language');
}

function assertTheme(value: unknown): AgilThemeScheme | undefined {
  if (value === undefined || value === null) return undefined;
  if (value === 'light' || value === 'dark' || value === 'auto') return value;
  throw new AgilConfigError('theme must be "light", "dark" or "auto"', 'theme');
}

function assertRole(value: unknown): AgilRole | undefined {
  if (value === undefined || value === null) return undefined;
  if (value === 'host' || value === 'moderator' || value === 'guest') return value;
  throw new AgilConfigError('role must be "host", "moderator" or "guest"', 'role');
}

function assertWidgetPath(value: unknown): string {
  const raw = optionalName(value, 'widgetPath', MAX_PATH_LENGTH) ?? DEFAULT_WIDGET_PATH;
  if (raw.includes('\\')) throw new AgilConfigError('widgetPath must use forward slashes', 'widgetPath');
  if (raw.includes('?') || raw.includes('#')) {
    throw new AgilConfigError('widgetPath must not contain a query string or fragment', 'widgetPath');
  }
  if (raw.startsWith('//')) throw new AgilConfigError('widgetPath must be a relative path', 'widgetPath');
  if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) {
    throw new AgilConfigError('widgetPath must not be an absolute URL', 'widgetPath');
  }
  const segments = raw.split('/');
  if (segments.some((segment) => segment === '..' || segment === '.')) {
    throw new AgilConfigError('widgetPath must not contain "." or ".." segments', 'widgetPath');
  }
  return raw;
}

function normalizeOptions(options: AgilWidgetUrlOptions): NormalizedOptions {
  if (!options || typeof options !== 'object') {
    throw new AgilConfigError('options are required', 'options');
  }
  const serverUrl = normalizeServerUrl(options.serverUrl);
  assertSecure(serverUrl, options.allowInsecure === true);
  const normalized: NormalizedOptions = {
    serverUrl,
    roomId: assertRoomId(options.roomId),
    tenantId: assertTenant(options.tenantId),
    widgetPath: assertWidgetPath(options.widgetPath),
  };
  if (options.joinToken !== undefined) normalized.joinToken = assertToken(options.joinToken, 'joinToken');
  if (options.identityToken !== undefined) {
    normalized.identityToken = assertToken(options.identityToken, 'identityToken');
  }
  const participantName = optionalName(options.participantName, 'participantName', MAX_NAME_LENGTH);
  if (participantName) normalized.participantName = participantName;
  const language = assertLanguage(options.language);
  if (language) normalized.language = language;
  const theme = assertTheme(options.theme);
  if (theme) normalized.theme = theme;
  const role = assertRole(options.role);
  if (role) normalized.role = role;
  if (options.relayOnly === true) normalized.relayOnly = true;
  return normalized;
}

function toQuery(options: NormalizedOptions): QueryPairs {
  const pairs: QueryPairs = [
    ['server', options.serverUrl],
    ['room', options.roomId],
  ];
  if (options.joinToken) pairs.push(['token', options.joinToken]);
  pairs.push(['tenant', options.tenantId]);
  if (options.language) pairs.push(['lang', options.language]);
  if (options.participantName) pairs.push(['name', options.participantName]);
  if (options.role) pairs.push(['role', options.role]);
  if (options.identityToken) pairs.push(['identity_token', options.identityToken]);
  if (options.theme) pairs.push(['theme', options.theme]);
  if (options.relayOnly) pairs.push(['relay', '1']);
  return pairs;
}

/**
 * Builds the hosted widget URL used by the WebView:
 * `https://calls.example.com/embed.html?server=…&room=…&tenant=…`.
 *
 * Subpath deployments are preserved: `serverUrl: 'https://host/calls'` plus the
 * default widget path produces `https://host/calls/embed.html`. Pass
 * `widgetPath: '/embed.html'` to address the origin root explicitly.
 */
export function buildWidgetUrl(options: AgilWidgetUrlOptions): string {
  const normalized = normalizeOptions(options);
  const base = parseAbsoluteUrl(normalized.serverUrl);
  if (!base) {
    throw new AgilConfigError('serverUrl could not be parsed', 'serverUrl');
  }
  const pathname = resolveWidgetPath(base.pathname, normalized.widgetPath);
  return serializeUrl({
    scheme: base.scheme,
    hostname: base.hostname,
    port: base.port,
    pathname,
    query: serializeQuery(toQuery(normalized)),
    hash: null,
  });
}

/**
 * Builds an app deep link for a call, e.g.
 * `agilcalls://call?server=…&room=…&tenant=…`. The join token is part of the
 * link: use short TTLs and never log the result.
 */
export function buildCallDeepLink(options: AgilWidgetUrlOptions, scheme = 'agilcalls'): string {
  const normalizedScheme = typeof scheme === 'string' ? scheme.trim().toLowerCase() : '';
  if (!/^[a-z][a-z0-9+.-]*$/.test(normalizedScheme)) {
    throw new AgilConfigError('deep-link scheme is invalid', 'scheme');
  }
  if (['http', 'https', 'file', 'javascript', 'data', 'blob', 'about'].includes(normalizedScheme)) {
    throw new AgilConfigError('deep-link scheme must be a custom app scheme', 'scheme');
  }
  const normalized = normalizeOptions(options);
  return serializeUrl({
    scheme: normalizedScheme,
    hostname: 'call',
    port: null,
    pathname: '',
    query: serializeQuery(toQuery(normalized)),
    hash: null,
  });
}

export interface ParseCallLinkOptions {
  /** Exact origins allowed for the link/server (strongly recommended for custom schemes). */
  allowedOrigins?: readonly string[];
  /** Custom schemes accepted by `parseAgilCallLink`; default `['agilcalls']`. */
  allowedSchemes?: readonly string[];
  /** Allow a non-loopback `http://` server URL. Development only. */
  allowInsecure?: boolean;
}

function normalizeOrigin(value: string): string | null {
  const parsed = parseAbsoluteUrl(value.trim());
  if (!parsed) return null;
  if (parsed.scheme !== 'https' && parsed.scheme !== 'http') return null;
  return parsed.origin;
}

function isOriginAllowed(origin: string, allowedOrigins?: readonly string[]): boolean {
  if (!allowedOrigins || allowedOrigins.length === 0) return true;
  return allowedOrigins.some((entry) => normalizeOrigin(entry) === origin);
}

function optionalParam(params: Map<string, string[]>, names: readonly string[]): string | undefined {
  const value = firstQueryValue(params, names);
  return value === null ? undefined : value;
}

function safeOptional<T>(factory: () => T | undefined): T | undefined {
  try {
    return factory();
  } catch {
    return undefined;
  }
}

/**
 * Parses an `https://…/embed.html?…` URL or an `agilcalls://call?…` deep link
 * into props for `<AgilCall />`. Returns `null` for malformed or unsafe links.
 *
 * For http(s) links the `server` parameter must match the link's own origin and
 * path prefix. This prevents a link like
 * `https://calls.corp/embed.html?server=https://evil.example&token=…` from
 * sending a join token to an attacker-controlled host.
 */
export function parseAgilCallLink(
  input: string,
  options: ParseCallLinkOptions = {},
): AgilCallLink | null {
  if (typeof input !== 'string') return null;
  const raw = input.trim();
  if (!raw || raw.length > MAX_URL_LENGTH) return null;
  const parsed = parseAbsoluteUrl(raw);
  if (!parsed) return null;

  const isHttp = parsed.scheme === 'https' || parsed.scheme === 'http';
  const allowedSchemes = (options.allowedSchemes ?? ['agilcalls']).map((scheme) =>
    scheme.trim().toLowerCase().replace(/:$/, ''),
  );
  const isCustom = !isHttp && allowedSchemes.includes(parsed.scheme);
  if (!isHttp && !isCustom) return null;

  const params = parseQuery(parsed.query);
  let kind: AgilCallLink['kind'];
  let expectedServer: string;

  if (isHttp) {
    if (!parsed.pathname.endsWith(WIDGET_HTML)) return null;
    kind = 'embed';
    const basePath = parsed.pathname.slice(0, -WIDGET_HTML.length).replace(/\/+$/, '');
    expectedServer = `${parsed.origin}${basePath}`;
    try {
      expectedServer = normalizeServerUrl(expectedServer);
    } catch {
      return null;
    }
    if (!isOriginAllowed(parsed.origin, options.allowedOrigins)) return null;
  } else {
    kind = 'deep-link';
    // A custom-scheme link is attacker-controllable: require an explicit
    // allowlist instead of trusting the embedded `server` parameter.
    if (!options.allowedOrigins || options.allowedOrigins.length === 0) return null;
    const serverParam = firstQueryValue(params, ['server', 'serverUrl']);
    if (!serverParam) return null;
    try {
      expectedServer = normalizeServerUrl(serverParam);
    } catch {
      return null;
    }
    if (!isOriginAllowed(parseAbsoluteUrl(expectedServer)?.origin ?? '', options.allowedOrigins)) {
      return null;
    }
  }

  try {
    assertSecure(expectedServer, options.allowInsecure === true);
  } catch {
    return null;
  }

  const serverParam = firstQueryValue(params, ['server', 'serverUrl']);
  if (serverParam) {
    let normalizedServer: string;
    try {
      normalizedServer = normalizeServerUrl(serverParam);
    } catch {
      return null;
    }
    if (kind === 'embed' && normalizedServer !== expectedServer) return null;
    expectedServer = normalizedServer;
  }

  let roomId: string;
  try {
    const room = firstQueryValue(params, ['room', 'roomId']);
    if (!room) return null;
    roomId = assertRoomId(room);
  } catch {
    return null;
  }

  let joinToken: string | undefined;
  const token = optionalParam(params, ['token', 'joinToken']);
  if (token !== undefined) {
    try {
      joinToken = assertToken(token, 'joinToken');
    } catch {
      return null;
    }
  }

  let identityToken: string | undefined;
  const identity = optionalParam(params, ['identity_token', 'identityToken', 'id_token']);
  if (identity !== undefined) {
    try {
      identityToken = assertToken(identity, 'identityToken');
    } catch {
      return null;
    }
  }

  const result: AgilCallLink = {
    kind,
    serverUrl: expectedServer,
    roomId,
  };
  const tenantId = safeOptional(() =>
    optionalName(optionalParam(params, ['tenant', 'tenantId']), 'tenantId', MAX_TENANT_LENGTH),
  );
  if (tenantId) result.tenantId = tenantId;
  const participantName = safeOptional(() =>
    optionalName(optionalParam(params, ['name', 'participantName']), 'participantName', MAX_NAME_LENGTH),
  );
  if (participantName) result.participantName = participantName;
  const language = safeOptional(() => assertLanguage(optionalParam(params, ['lang', 'language'])));
  if (language) result.language = language;
  const theme = safeOptional(() => assertTheme(optionalParam(params, ['theme'])));
  if (theme) result.theme = theme;
  const role = safeOptional(() => assertRole(optionalParam(params, ['role'])));
  if (role) result.role = role;
  if (joinToken) result.joinToken = joinToken;
  if (identityToken) result.identityToken = identityToken;
  const relay = firstQueryValue(params, ['relay']);
  if (relay === '1' || relay === 'true') result.relayOnly = true;
  return result;
}

export interface NavigationPolicy {
  serverUrl: string;
  /** Extra exact origins allowed in addition to the widget's own origin. */
  allowedOrigins?: readonly string[];
}

/**
 * Navigation guard for `onShouldStartLoadWithRequest`.
 * Allows `about:blank`/`about:srcdoc`, the widget origin and explicit extra
 * origins; everything else (`javascript:`, `file:`, `intent:`, other hosts) is
 * blocked.
 */
export function isAllowedNavigation(url: string, policy: NavigationPolicy): boolean {
  if (typeof url !== 'string') return false;
  const value = url.trim();
  if (!value) return false;
  if (value === 'about:blank' || value === 'about:srcdoc') return true;
  const parsed = parseAbsoluteUrl(value);
  if (!parsed) return false;
  if (parsed.scheme !== 'https' && parsed.scheme !== 'http') return false;
  if (parsed.userinfo) return false;
  try {
    const server = parseAbsoluteUrl(normalizeServerUrl(policy.serverUrl));
    if (server && parsed.origin === server.origin) return true;
  } catch {
    return false;
  }
  return isOriginAllowed(parsed.origin, policy.allowedOrigins);
}

/** Masks JWT-looking strings and token query parameters in free-form text. */
export function redactTokenText(text: string): string {
  if (typeof text !== 'string') return '';
  return text
    .replace(
      /(^|[?&\s])((?:token|identity_token|id_token|access_token)=)[^&\s#]+/gi,
      '$1$2redacted',
    )
    .replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, 'redacted');
}

/**
 * Redacts both token-shaped text and known secret values (the current join /
 * identity tokens) from an untrusted widget message.
 */
export function redactSecrets(text: string, secrets: readonly string[] = []): string {
  let redacted = redactTokenText(text);
  for (const secret of secrets) {
    if (typeof secret !== 'string' || secret.length < 4) continue;
    redacted = redacted.split(secret).join('[redacted]');
  }
  return redacted;
}

/** URL-safe for logs/errors: strips credentials and masks token parameters. */
export function redactCallUrl(input: string): string {
  if (typeof input !== 'string' || !input) return '';
  const parsed = parseAbsoluteUrl(input);
  if (!parsed) return redactTokenText(input);
  const params = parseQuery(parsed.query);
  const pairs: QueryPairs = [];
  for (const [key, values] of params) {
    for (const value of values) {
      const redacted = [
        'token',
        'joinToken',
        'identity_token',
        'identityToken',
        'id_token',
        'access_token',
      ].includes(key)
        ? 'redacted'
        : value;
      pairs.push([key, redacted]);
    }
  }
  return redactTokenText(
    serializeUrl({
      scheme: parsed.scheme,
      hostname: parsed.hostname,
      port: parsed.port,
      pathname: parsed.pathname,
      query: serializeQuery(pairs),
      hash: parsed.hash,
      userinfo: null,
    }),
  );
}

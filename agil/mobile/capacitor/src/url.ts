/**
 * Pure URL building, validation and redaction for the Capacitor plugin.
 *
 * Security invariants (covered by `test/url.test.ts`):
 *  - only `http:`/`https:` server URLs are accepted; plain HTTP is rejected
 *    outside loopback/dev hosts unless `allowInsecure` is set;
 *  - credentials, query strings and fragments are rejected in `serverUrl`;
 *  - every user-supplied value is length-limited and control-character checked;
 *  - `parseAgilCallLink()` never trusts a cross-origin `server` parameter, so a
 *    crafted link cannot redirect a join token to another host;
 *  - errors and redacted URLs never contain the token.
 *
 * No `@capacitor/core` import: this module is usable from a Node backend (to
 * build links) and from unit tests without the Capacitor runtime.
 */
import type {
  AgilLanguage,
  AgilOpenCallOptions,
  AgilRole,
  AgilThemeScheme,
} from './definitions.js';

const MAX_URL_LENGTH = 8192;
const MAX_TOKEN_LENGTH = 8192;
const MAX_ROOM_LENGTH = 200;
const MAX_NAME_LENGTH = 120;
const MAX_TENANT_LENGTH = 64;
const MAX_PATH_LENGTH = 200;

const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;
const ABSOLUTE_SCHEME = /^[a-z][a-z0-9+.-]*:/i;
const TOKEN_QUERY_VALUE =
  /(^|[?&\s])((?:token|identity_token|id_token|access_token|joinctoken|identitytoken)=)[^&\s#]+/gi;
const JWT_LIKE = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g;
const REDACTED_QUERY_KEYS = new Set([
  'token',
  'joinctoken',
  'identity_token',
  'identitytoken',
  'id_token',
  'access_token',
]);

/** Default page path relative to `serverUrl`. */
export const DEFAULT_WIDGET_PATH = 'embed.html';
/** Path component of the hosted embed page. */
export const WIDGET_HTML_PATH = '/embed.html';

/** Thrown for invalid SDK configuration before anything is opened. */
export class AgilConfigError extends Error {
  readonly code = 'invalid-config' as const;
  readonly field?: string;

  constructor(message: string, field?: string) {
    super(message);
    this.name = 'AgilConfigError';
    this.field = field;
  }
}

/** Options accepted by {@link buildWidgetUrl}. */
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
  widgetPath?: string;
  allowInsecure?: boolean;
}

/** Parsed `agilcalls://call?...` deep link or `/embed.html?...` URL. */
export interface AgilCallLink {
  kind: 'embed' | 'deep-link';
  serverUrl: string;
  roomId: string;
  joinToken?: string;
  tenantId?: string;
  participantName?: string;
  language?: AgilLanguage;
  theme?: AgilThemeScheme;
  role?: AgilRole;
  identityToken?: string;
  relayOnly?: boolean;
}

export interface ParseAgilCallLinkOptions {
  /** Exact origins allowed for the link/server (recommended). */
  allowedOrigins?: readonly string[];
  /** Custom schemes accepted; default `['agilcalls']`. */
  allowedSchemes?: readonly string[];
  /** Allow non-loopback `http://` (development only). */
  allowInsecure?: boolean;
}

export interface NavigationPolicy {
  serverUrl: string;
  /** Extra exact origins allowed in addition to the widget origin. */
  allowedOrigins?: readonly string[];
}

function isRecordLike(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function optionalName(value: unknown, field: string, maxLength: number): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'string') throw new AgilConfigError(`${field} must be a string`, field);
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  if (trimmed.length > maxLength) throw new AgilConfigError(`${field} is too long`, field);
  if (CONTROL_CHARS.test(trimmed)) {
    throw new AgilConfigError(`${field} contains control characters`, field);
  }
  return trimmed;
}

function assertRoomId(value: unknown): string {
  if (typeof value !== 'string') throw new AgilConfigError('roomId is required', 'roomId');
  const room = value.trim();
  if (!room) throw new AgilConfigError('roomId is required', 'roomId');
  if (room.length > MAX_ROOM_LENGTH) throw new AgilConfigError('roomId is too long', 'roomId');
  if (CONTROL_CHARS.test(room)) {
    throw new AgilConfigError('roomId contains control characters', 'roomId');
  }
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

function assertTenant(value: unknown): string {
  return optionalName(value, 'tenantId', MAX_TENANT_LENGTH) ?? 'demo';
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
  if (raw.includes('\\')) {
    throw new AgilConfigError('widgetPath must use forward slashes', 'widgetPath');
  }
  if (raw.includes('?') || raw.includes('#')) {
    throw new AgilConfigError('widgetPath must not contain a query string or fragment', 'widgetPath');
  }
  if (raw.startsWith('//')) {
    throw new AgilConfigError('widgetPath must be a relative path', 'widgetPath');
  }
  if (ABSOLUTE_SCHEME.test(raw)) {
    throw new AgilConfigError('widgetPath must not be an absolute URL', 'widgetPath');
  }
  if (raw.split('/').some((segment) => segment === '..' || segment === '.')) {
    throw new AgilConfigError('widgetPath must not contain "." or ".." segments', 'widgetPath');
  }
  return raw;
}

/** `true` for hosts allowed to use plain HTTP during development. */
export function isLoopbackHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[/, '').replace(/\]$/, '');
  return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '10.0.2.2';
}

function assertSecure(url: URL, allowInsecure: boolean, field: string): void {
  if (url.protocol === 'https:') return;
  if (allowInsecure || isLoopbackHost(url.hostname)) return;
  throw new AgilConfigError(
    `${field} must use https (pass allowInsecure: true only for local development)`,
    field,
  );
}

/** Validates and normalizes a server base URL (no trailing slash, no query). */
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
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new AgilConfigError('serverUrl must be an absolute http or https URL', 'serverUrl');
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    throw new AgilConfigError('serverUrl must use http or https', 'serverUrl');
  }
  if (parsed.username || parsed.password) {
    throw new AgilConfigError('serverUrl must not contain credentials', 'serverUrl');
  }
  if (parsed.search || parsed.hash) {
    throw new AgilConfigError('serverUrl must not contain a query string or fragment', 'serverUrl');
  }
  const pathname = parsed.pathname.replace(/\/+$/, '');
  return `${parsed.origin}${pathname}`;
}

/** Exact origin of a normalized server URL. */
export function serverOrigin(serverUrl: string): string {
  return new URL(normalizeServerUrl(serverUrl)).origin;
}

/**
 * Builds the hosted widget URL:
 * `https://calls.example.com/embed.html?server=…&room=…&tenant=…`.
 *
 * Subpath deployments are preserved: `https://host/calls` + default widget path
 * → `https://host/calls/embed.html`. Pass `widgetPath: '/embed.html'` for the
 * origin root.
 */
export function buildWidgetUrl(options: AgilWidgetUrlOptions): string {
  if (!isRecordLike(options)) {
    throw new AgilConfigError('options are required', 'options');
  }
  const allowed = options.allowInsecure === true;
  const serverUrl = normalizeServerUrl(options.serverUrl);
  const base = new URL(serverUrl);
  assertSecure(base, allowed, 'serverUrl');

  const roomId = assertRoomId(options.roomId);
  const tenantId = assertTenant(options.tenantId);
  const widgetPath = assertWidgetPath(options.widgetPath);
  const joinToken =
    options.joinToken === undefined ? undefined : assertToken(options.joinToken, 'joinToken');
  const identityToken =
    options.identityToken === undefined
      ? undefined
      : assertToken(options.identityToken, 'identityToken');
  const participantName = optionalName(options.participantName, 'participantName', MAX_NAME_LENGTH);
  const language = assertLanguage(options.language);
  const theme = assertTheme(options.theme);
  const role = assertRole(options.role);

  const params = new URLSearchParams();
  params.set('server', serverUrl);
  params.set('room', roomId);
  if (joinToken) params.set('token', joinToken);
  params.set('tenant', tenantId);
  if (language) params.set('lang', language);
  if (participantName) params.set('name', participantName);
  if (role) params.set('role', role);
  if (identityToken) params.set('identity_token', identityToken);
  if (theme) params.set('theme', theme);
  if (options.relayOnly === true) params.set('relay', '1');

  const basePath = base.pathname.replace(/\/+$/, '');
  const path = widgetPath.startsWith('/') ? widgetPath : `${basePath}/${widgetPath}`;
  return `${base.origin}${path}?${params.toString()}`;
}

function normalizeOrigin(value: string): string | null {
  try {
    const parsed = new URL(value.trim());
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null;
    return parsed.origin;
  } catch {
    return null;
  }
}

function isOriginAllowed(origin: string, allowedOrigins: readonly string[] | undefined): boolean {
  if (!allowedOrigins || allowedOrigins.length === 0) return true;
  return allowedOrigins.some((entry) => normalizeOrigin(entry) === origin);
}

function firstParam(params: URLSearchParams, names: readonly string[]): string | undefined {
  for (const name of names) {
    const value = params.get(name);
    if (value !== null && value.trim() !== '') return value;
  }
  return undefined;
}

function safeOptional<T>(factory: () => T | undefined): T | undefined {
  try {
    return factory();
  } catch {
    return undefined;
  }
}

/**
 * Parses an `https://…/embed.html?…` URL or an `agilcalls://call?…` deep link.
 *
 * For http(s) links the `server` parameter must match the link's own origin and
 * path prefix. For custom schemes `allowedOrigins` is the only trust anchor, so
 * an empty list rejects the link.
 */
export function parseAgilCallLink(
  input: string,
  options: ParseAgilCallLinkOptions = {},
): AgilCallLink | null {
  if (typeof input !== 'string') return null;
  const raw = input.trim();
  if (!raw || raw.length > MAX_URL_LENGTH) return null;
  if (CONTROL_CHARS.test(raw)) return null;

  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    return null;
  }
  if (parsed.username || parsed.password) return null;

  const scheme = parsed.protocol.replace(/:$/, '').toLowerCase();
  const isHttp = scheme === 'https' || scheme === 'http';
  const allowedSchemes = (options.allowedSchemes ?? ['agilcalls']).map((entry) =>
    entry.trim().toLowerCase().replace(/:$/, ''),
  );
  const isCustom = !isHttp && allowedSchemes.includes(scheme);
  if (!isHttp && !isCustom) return null;

  const params = parsed.searchParams;
  const serverParam = firstParam(params, ['server', 'serverUrl']);
  let kind: AgilCallLink['kind'];
  let expectedServer: string;

  if (isHttp) {
    if (!parsed.pathname.toLowerCase().endsWith(WIDGET_HTML_PATH)) return null;
    const basePath = parsed.pathname.slice(0, -WIDGET_HTML_PATH.length);
    try {
      expectedServer = normalizeServerUrl(`${parsed.origin}${basePath}`);
    } catch {
      return null;
    }
    kind = 'embed';
    if (!isOriginAllowed(parsed.origin, options.allowedOrigins)) return null;
  } else {
    if (!serverParam) return null;
    // A custom-scheme link is attacker-controllable: require an explicit
    // allowlist instead of trusting the embedded `server` parameter.
    if (!options.allowedOrigins || options.allowedOrigins.length === 0) return null;
    try {
      expectedServer = normalizeServerUrl(serverParam);
    } catch {
      return null;
    }
    kind = 'deep-link';
    const origin = normalizeOrigin(expectedServer);
    if (!origin || !isOriginAllowed(origin, options.allowedOrigins)) return null;
  }

  try {
    assertSecure(new URL(expectedServer), options.allowInsecure === true, 'serverUrl');
  } catch {
    return null;
  }

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

  const roomValue = firstParam(params, ['room', 'roomId']);
  if (!roomValue) return null;

  let roomId: string;
  try {
    roomId = assertRoomId(roomValue);
  } catch {
    return null;
  }

  let joinToken: string | undefined;
  const token = firstParam(params, ['token', 'joinToken']);
  if (token !== undefined) {
    try {
      joinToken = assertToken(token, 'joinToken');
    } catch {
      return null;
    }
  }

  let identityToken: string | undefined;
  const identity = firstParam(params, ['identity_token', 'identityToken', 'id_token']);
  if (identity !== undefined) {
    try {
      identityToken = assertToken(identity, 'identityToken');
    } catch {
      return null;
    }
  }

  const result: AgilCallLink = { kind, serverUrl: expectedServer, roomId };
  const tenantId = safeOptional(() =>
    optionalName(firstParam(params, ['tenant', 'tenantId']), 'tenantId', MAX_TENANT_LENGTH),
  );
  if (tenantId) result.tenantId = tenantId;
  const participantName = safeOptional(() =>
    optionalName(firstParam(params, ['name', 'participantName']), 'participantName', MAX_NAME_LENGTH),
  );
  if (participantName) result.participantName = participantName;
  const language = safeOptional(() =>
    assertLanguage(firstParam(params, ['lang', 'language'])),
  );
  if (language) result.language = language;
  const theme = safeOptional(() => assertTheme(firstParam(params, ['theme'])));
  if (theme) result.theme = theme;
  const role = safeOptional(() => assertRole(firstParam(params, ['role'])));
  if (role) result.role = role;
  if (joinToken) result.joinToken = joinToken;
  if (identityToken) result.identityToken = identityToken;
  const relay = firstParam(params, ['relay']);
  if (relay === '1' || relay === 'true') result.relayOnly = true;
  return result;
}

/**
 * Navigation guard: allows `about:blank`/`about:srcdoc`, the widget origin and
 * explicit extra origins; everything else is blocked.
 */
export function isAllowedNavigation(url: string, policy: NavigationPolicy): boolean {
  if (typeof url !== 'string') return false;
  const value = url.trim();
  if (!value) return false;
  const lower = value.toLowerCase();
  if (lower === 'about:blank' || lower === 'about:srcdoc') return true;
  if (CONTROL_CHARS.test(value)) return false;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  if (parsed.username || parsed.password) return false;
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return false;
  try {
    const server = new URL(normalizeServerUrl(policy.serverUrl));
    if (parsed.origin === server.origin) return true;
  } catch {
    return false;
  }
  return (policy.allowedOrigins ?? []).some((entry) => normalizeOrigin(entry) === parsed.origin);
}

/** Masks JWT-looking strings and token query parameters in free-form text. */
export function redactTokenText(text: string): string {
  if (typeof text !== 'string') return '';
  return text
    .replace(TOKEN_QUERY_VALUE, '$1$2redacted')
    .replace(JWT_LIKE, 'redacted');
}

/** URL-safe for logs/errors: strips credentials and masks token parameters. */
export function redactCallUrl(input: string): string {
  if (typeof input !== 'string' || !input) return '';
  let parsed: URL;
  try {
    parsed = new URL(input);
  } catch {
    return redactTokenText(input);
  }
  const pairs: Array<[string, string]> = [];
  for (const [key, value] of parsed.searchParams) {
    pairs.push([key, REDACTED_QUERY_KEYS.has(key.toLowerCase()) ? 'redacted' : value]);
  }
  const params = new URLSearchParams();
  for (const [key, value] of pairs) params.append(key, value);
  const query = params.toString();
  return redactTokenText(
    `${parsed.protocol}//${parsed.host}${parsed.pathname}${query ? `?${query}` : ''}${
      parsed.hash || ''
    }`,
  );
}

/** Validates all URL-relevant fields of `AgilCalls.openCall()` options. */
export function normalizeOpenCallOptions(options: AgilOpenCallOptions): Required<
  Pick<AgilWidgetUrlOptions, 'serverUrl' | 'roomId' | 'tenantId' | 'widgetPath'>
> &
  AgilWidgetUrlOptions {
  if (!isRecordLike(options)) throw new AgilConfigError('options are required', 'options');
  const serverUrl = normalizeServerUrl(options.serverUrl);
  const base = new URL(serverUrl);
  assertSecure(base, options.allowInsecure === true, 'serverUrl');
  return {
    ...options,
    serverUrl,
    roomId: assertRoomId(options.roomId),
    tenantId: assertTenant(options.tenantId),
    widgetPath: assertWidgetPath(options.widgetPath),
  };
}

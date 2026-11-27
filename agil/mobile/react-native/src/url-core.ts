/**
 * Small, dependency-free WHATWG-compatible URL helpers.
 *
 * React Native ships a partial `URL`/`URLSearchParams` implementation (some
 * getters throw "not implemented", especially on Hermes). The SDK must work on
 * a clean React Native app without a URL polyfill, so URL parsing/serialization
 * for the narrow http(s)/custom-scheme cases is implemented here.
 *
 * This is intentionally not a full WHATWG parser: it supports absolute
 * `scheme://host[:port]/path?query#hash` URLs (including IPv6 hosts), query
 * decoding and dot-segment path normalization. That is the entire URL surface
 * used by the widget bridge and deep links.
 */

export interface ParsedUrl {
  scheme: string;
  hostname: string;
  port: string | null;
  pathname: string;
  query: string | null;
  hash: string | null;
  userinfo: string | null;
  origin: string;
}

const ABSOLUTE_URL = /^([a-z][a-z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/i;
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;
const RAW_WHITESPACE = /\s/;

function parsePort(value: string): string | null {
  if (!value) return null;
  if (!/^\d{1,5}$/.test(value)) return null;
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
  return String(port);
}

/** Parses an absolute URL; returns `null` for relative/invalid/unsupported input. */
export function parseAbsoluteUrl(input: string): ParsedUrl | null {
  if (typeof input !== 'string') return null;
  const raw = input.trim();
  if (!raw || raw.length > 8192) return null;
  if (CONTROL_CHARS.test(raw) || RAW_WHITESPACE.test(raw)) return null;
  const match = ABSOLUTE_URL.exec(raw);
  if (!match) return null;
  const scheme = (match[1] ?? '').toLowerCase();
  let authority = match[2] ?? '';
  const rawPath = match[3] ?? '';
  const query = match[4] === undefined ? null : match[4];
  const hash = match[5] === undefined ? null : match[5];

  let userinfo: string | null = null;
  const at = authority.lastIndexOf('@');
  if (at !== -1) {
    userinfo = authority.slice(0, at);
    authority = authority.slice(at + 1);
  }
  if (!authority) return null;

  let hostname: string;
  let port: string | null = null;
  if (authority.startsWith('[')) {
    const end = authority.indexOf(']');
    if (end === -1) return null;
    hostname = authority.slice(0, end + 1).toLowerCase();
    const rest = authority.slice(end + 1);
    if (rest) {
      if (!rest.startsWith(':')) return null;
      port = parsePort(rest.slice(1));
      if (port === null) return null;
    }
  } else {
    const colon = authority.lastIndexOf(':');
    if (colon !== -1) {
      if (authority.indexOf(':') !== colon) return null;
      hostname = authority.slice(0, colon).toLowerCase();
      port = parsePort(authority.slice(colon + 1));
      if (port === null) return null;
    } else {
      hostname = authority.toLowerCase();
    }
  }
  if (!hostname || /[\s/?#]/.test(hostname)) return null;
  if ((scheme === 'http' && port === '80') || (scheme === 'https' && port === '443')) port = null;
  const origin = `${scheme}://${hostname}${port ? `:${port}` : ''}`;
  const pathname = normalizePath(rawPath || '/');
  return { scheme, hostname, port, pathname, query, hash, userinfo, origin };
}

/**
 * Collapses `.`/`..` segments and duplicate slashes while preserving a leading
 * and trailing slash. Absolute paths never escape the root.
 */
export function normalizePath(input: string): string {
  const leading = input.startsWith('/');
  const trailing = input.length > 1 && input.endsWith('/');
  const stack: string[] = [];
  for (const segment of input.split('/')) {
    if (!segment || segment === '.') continue;
    if (segment === '..') {
      stack.pop();
      continue;
    }
    stack.push(segment);
  }
  let result = `${leading ? '/' : ''}${stack.join('/')}`;
  if (trailing && result !== '/' && !result.endsWith('/')) result += '/';
  return result || '/';
}

/** Resolves a widget page path against the server's base directory. */
export function resolveWidgetPath(basePath: string, widgetPath: string): string {
  const baseDir = basePath.endsWith('/') ? basePath : `${basePath}/`;
  const combined = widgetPath.startsWith('/') ? widgetPath : `${baseDir}${widgetPath}`;
  return normalizePath(combined);
}

/** RFC 3986-style query component encoding (matches URLSearchParams closely). */
export function encodeQueryComponent(value: string): string {
  try {
    return encodeURIComponent(value).replace(/[!'()*]/g, (character) =>
      `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
    );
  } catch {
    // Lone surrogate: drop it rather than throwing while building a call URL.
    return encodeURIComponent(value.replace(/[\uD800-\uDFFF]/g, '')).replace(/[!'()*]/g, (character) =>
      `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
    );
  }
}

export type QueryPairs = Array<readonly [string, string]>;

export function serializeQuery(pairs: QueryPairs): string {
  return pairs.map(([key, value]) => `${encodeQueryComponent(key)}=${encodeQueryComponent(value)}`).join('&');
}

/** Decodes a raw query string into a key → values map (first value wins for `get`). */
export function parseQuery(raw: string | null): Map<string, string[]> {
  const params = new Map<string, string[]>();
  if (!raw) return params;
  for (const part of raw.split('&')) {
    if (!part) continue;
    const equals = part.indexOf('=');
    const rawKey = equals === -1 ? part : part.slice(0, equals);
    const rawValue = equals === -1 ? '' : part.slice(equals + 1);
    let key: string;
    let value: string;
    try {
      key = decodeURIComponent(rawKey.replace(/\+/g, ' '));
      value = decodeURIComponent(rawValue.replace(/\+/g, ' '));
    } catch {
      continue;
    }
    if (!key) continue;
    const existing = params.get(key);
    if (existing) existing.push(value);
    else params.set(key, [value]);
  }
  return params;
}

export function firstQueryValue(
  params: Map<string, string[]>,
  names: readonly string[],
): string | null {
  for (const name of names) {
    const values = params.get(name);
    if (values && values.length > 0) {
      const value = values[0];
      if (typeof value === 'string' && value.trim() !== '') return value.trim();
    }
  }
  return null;
}

export function serializeUrl(parts: {
  scheme: string;
  hostname: string;
  port: string | null;
  pathname: string;
  query?: string | null;
  hash?: string | null;
  userinfo?: string | null;
}): string {
  const authority = `${parts.hostname}${parts.port ? `:${parts.port}` : ''}`;
  const credentials = parts.userinfo ? `${parts.userinfo}@` : '';
  let url = `${parts.scheme}://${credentials}${authority}${parts.pathname}`;
  if (parts.query !== null && parts.query !== undefined && parts.query !== '') url += `?${parts.query}`;
  if (parts.hash !== null && parts.hash !== undefined && parts.hash !== '') url += `#${parts.hash}`;
  return url;
}

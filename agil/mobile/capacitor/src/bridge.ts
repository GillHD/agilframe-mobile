/**
 * Defensive parsing of the `agil:*` widget bridge.
 *
 * Native shells (WKWebView/Android WebView) forward the widget's outgoing
 * messages (ready/event/chat/state/…) to JS. The web fallback (`src/web.ts`)
 * receives them as `postMessage` events. Both paths end up here, so malformed,
 * oversized and hostile payloads are rejected or sanitized in one place.
 */
import type {
  AgilCallError,
  AgilCallEvent,
  AgilCallState,
  AgilCapabilities,
  AgilChatMessage,
} from './definitions.js';
import { LARGE_ROOM_MAX_PARTICIPANTS, extractParticipantIds } from './large-room.js';

/** Query-string keys whose values must never reach host-visible messages. */
const SECRET_QUERY_KEY =
  /(^|[?&\s])((?:token|identity_token|id_token|access_token|joinctoken|identitytoken)=)[^&\s#]+/gi;
const JWT_LIKE = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g;

/** Masks token-shaped text; reused for widget and native error messages. */
export function redactTokenText(text: string): string {
  if (typeof text !== 'string') return '';
  return text.replace(SECRET_QUERY_KEY, '$1$2redacted').replace(JWT_LIKE, 'redacted');
}

/** Masks token-shaped text plus the current join/identity token values. */
export function redactSecrets(text: string, secrets: readonly string[] = []): string {
  let redacted = redactTokenText(text);
  for (const secret of secrets) {
    if (typeof secret !== 'string' || secret.length < 4) continue;
    redacted = redacted.split(secret).join('[redacted]');
  }
  return redacted;
}

/** Characters (not bytes) accepted before JSON parsing. */
export const DEFAULT_MAX_BRIDGE_CHARS = 262_144;

const MAX_WIDGET_TEXT = 500;
const MAX_WIDGET_CODE = 64;

const EVENT_NAME = /^[a-z][a-z0-9-]{0,63}$/;
const FORBIDDEN_KEYS = new Set(['__proto__', 'prototype', 'constructor']);

export interface SanitizeLimits {
  maxDepth?: number;
  maxArray?: number;
  maxKeys?: number;
  maxString?: number;
}

type JsonRecord = Record<string, unknown>;

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function truncated(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

function safeString(value: unknown, max: number): string | undefined {
  return typeof value === 'string' && value.length > 0 ? truncated(value, max) : undefined;
}

/**
 * Converts an untrusted value into a JSON-safe tree: drops functions/symbols/
 * `undefined`, masks prototypes, limits depth/collection sizes, breaks cycles
 * and turns non-finite numbers into `null`.
 */
export function sanitizeBridgePayload(
  value: unknown,
  limits: SanitizeLimits = {},
): unknown {
  const maxDepth = limits.maxDepth ?? 8;
  const maxArray = limits.maxArray ?? 100;
  const maxKeys = limits.maxKeys ?? 100;
  const maxString = limits.maxString ?? 32_768;
  const seen = new WeakSet<object>();

  const walk = (input: unknown, depth: number): unknown => {
    if (input === null) return null;
    const kind = typeof input;
    if (kind === 'string') return truncated(input as string, maxString);
    if (kind === 'number') return Number.isFinite(input as number) ? input : null;
    if (kind === 'boolean') return input;
    if (kind === 'undefined' || kind === 'function' || kind === 'symbol') return undefined;
    if (kind === 'bigint') return null;
    if (kind !== 'object') return null;
    if (depth >= maxDepth) return null;
    const object = input as object;
    if (seen.has(object)) return null;
    seen.add(object);
    try {
      if (Array.isArray(object)) {
        const result: unknown[] = [];
        const length = Math.min(object.length, maxArray);
        for (let index = 0; index < length; index += 1) {
          let item: unknown;
          try {
            item = walk(object[index], depth + 1);
          } catch {
            item = undefined;
          }
          result.push(item === undefined ? null : item);
        }
        return result;
      }
      const result: JsonRecord = {};
      let count = 0;
      for (const key of Object.keys(object)) {
        if (count >= maxKeys) break;
        if (FORBIDDEN_KEYS.has(key)) continue;
        let item: unknown;
        try {
          item = walk((object as JsonRecord)[key], depth + 1);
        } catch {
          item = undefined;
        }
        if (item !== undefined) {
          result[key] = item;
          count += 1;
        }
      }
      return result;
    } finally {
      seen.delete(object);
    }
  };

  return walk(value, 0);
}

function readCapabilities(value: unknown): AgilCapabilities {
  const caps = isRecord(value) ? value : {};
  return {
    media: caps.media === true,
    blur: caps.blur === true,
    screenShare: caps.screenShare === true,
    captions: caps.captions === true,
    recording: caps.recording === true,
  };
}

function widgetError(payload: unknown, secrets: readonly string[] = []): AgilCallError {
  const record = isRecord(payload) ? payload : {};
  const code = redactSecrets(
    safeString(record.code, MAX_WIDGET_CODE) ?? 'widget_error',
    secrets,
  );
  const rawMessage =
    safeString(record.message, MAX_WIDGET_TEXT) ?? 'The widget reported an error';
  return {
    code: 'widget-error',
    message: redactSecrets(rawMessage, secrets),
    fatal: false,
    widgetCode: code,
  };
}

export interface ParseWidgetOptions {
  maxChars?: number;
  /** Current join/identity tokens; redacted from widget error messages. */
  secrets?: readonly string[];
}

/**
 * Extracts the widget payload from the per-load nonce envelope written by the
 * native bridge shims.
 *
 * Android (as well as the React Native and Flutter shims) wraps every forwarded
 * message as `{"__agilBridgeNonce":"…","message":"<widget json>"}` and validates
 * the nonce natively; `parseWidgetMessage()` needs the inner widget object, not
 * the envelope. Plain messages (native `agil:event error`, older shells, the
 * web fallback) are returned unchanged so the parser can reject/accept them as
 * usual. Never throws.
 */
export function unwrapBridgeEnvelope(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  if (raw.length > DEFAULT_MAX_BRIDGE_CHARS + 1024) return null;
  try {
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value)) return raw;
    const nonce = value['__agilBridgeNonce'];
    const message = value['message'];
    if (typeof nonce === 'string' && typeof message === 'string') {
      return message;
    }
    return raw;
  } catch {
    return raw;
  }
}

/**
 * Parses one raw message received on the native `callMessage` channel:
 * unwraps the nonce envelope when present, then applies the widget parser.
 * This is the single entry point used by the facade listener.
 */
export function parseNativeWidgetMessage(
  raw: unknown,
  options: ParseWidgetOptions = {},
): AgilCallEvent | null {
  const payload = unwrapBridgeEnvelope(raw);
  if (payload === null) return null;
  return parseWidgetMessage(payload, options);
}

/**
 * Parses a widget→host message (JSON string or decoded object) into a public
 * `AgilCallEvent`. Returns `null` for `agil:pong` and anything malformed.
 */
export function parseWidgetMessage(
  raw: unknown,
  options: ParseWidgetOptions = {},
): AgilCallEvent | null {
  try {
    let value: unknown = raw;
    if (typeof raw === 'string') {
      if (raw.length > (options.maxChars ?? DEFAULT_MAX_BRIDGE_CHARS)) return null;
      value = JSON.parse(raw);
    }
    if (!isRecord(value)) return null;
    const type = value.type;
    if (typeof type !== 'string' || !type.startsWith('agil:') || type.length > 64) return null;

    switch (type) {
      case 'agil:ready': {
        const event: AgilCallEvent = {
          type: 'ready',
          capabilities: readCapabilities(value.capabilities),
        };
        const room = safeString(value.room, 200);
        if (room) event.room = room;
        const server = safeString(value.server, 2048);
        if (server) event.server = server;
        return event;
      }
      case 'agil:event': {
        const name = value.event;
        if (typeof name !== 'string' || !EVENT_NAME.test(name)) return null;
        const payload = sanitizeBridgePayload(value.payload);
        if (name === 'joined') return { type: 'joined', payload };
        if (name === 'left') return { type: 'left', payload };
        if (name === 'error') {
          return { type: 'error', error: widgetError(payload, options.secrets) };
        }
        return { type: 'event', name, payload };
      }
      case 'agil:chat': {
        const message = sanitizeBridgePayload(value.message);
        if (!isRecord(message) || typeof message.text !== 'string') return null;
        return { type: 'chat', message: message as AgilChatMessage };
      }
      case 'agil:state': {
        // Parse the participant array before the generic 100-item cap; the
        // facade's digest then emits one snapshot + deltas. One extra id is
        // kept so an oversized widget array is flagged as `truncated`.
        const state = sanitizeBridgePayload(value.state, {
          maxArray: LARGE_ROOM_MAX_PARTICIPANTS + 1,
        });
        if (!isRecord(state)) return null;
        // Preserve "ids absent" (count-only summary) vs "ids present but empty"
        // (empty-room snapshot): only the field's absence requests a summary.
        const hasParticipantIds = Array.isArray(state['participantIds']);
        const participantIds = extractParticipantIds(state);
        delete state['participantIds'];
        return {
          type: 'state',
          state: state as AgilCallState,
          ...(hasParticipantIds ? { participantIds } : {}),
        };
      }
      case 'agil:minimized':
        return { type: 'minimized', minimized: value.minimized === true };
      case 'agil:fullscreen':
        return { type: 'fullscreen', fullscreen: value.fullscreen === true };
      default:
        return null;
    }
  } catch {
    return null;
  }
}

/** Host→widget message posted through the WebView/iframe bridge. */
export type HostToWidgetMessage =
  | { type: 'agil:action'; action: string }
  | { type: 'agil:chat-send'; text: string }
  | { type: 'agil:scheme'; scheme: 'light' | 'dark' | 'auto' }
  | { type: 'agil:theme'; theme: Record<string, unknown> }
  | { type: 'agil:config'; config: Record<string, unknown> }
  | { type: 'agil:ping' };

/** `{type:'agil:action', action}`. */
export function actionMessage(action: string): HostToWidgetMessage {
  if (typeof action !== 'string' || !action.trim()) {
    throw new Error('Widget action must be a non-empty string');
  }
  return { type: 'agil:action', action: action.trim() };
}

/** `{type:'agil:chat-send', text}`; trims and caps at 4000 characters. */
export function chatMessage(text: string): HostToWidgetMessage {
  if (typeof text !== 'string' || !text.trim()) {
    throw new Error('Chat text must be a non-empty string');
  }
  return { type: 'agil:chat-send', text: text.slice(0, 4000) };
}

/** `{type:'agil:scheme', scheme}`. */
export function schemeMessage(scheme: 'light' | 'dark' | 'auto'): HostToWidgetMessage {
  return { type: 'agil:scheme', scheme };
}

/** `{type:'agil:theme', theme}`; throws for an empty/non-object patch. */
export function themeMessage(theme: Record<string, unknown>): HostToWidgetMessage {
  if (!isRecord(theme)) throw new Error('Theme patch must be an object');
  const sanitized = sanitizeBridgePayload(theme, {
    maxDepth: 12,
    maxKeys: 500,
    maxArray: 500,
    maxString: 8192,
  });
  if (!isRecord(sanitized) || Object.keys(sanitized).length === 0) {
    throw new Error('Theme patch must be a non-empty object');
  }
  return { type: 'agil:theme', theme: sanitized };
}

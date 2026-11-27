/**
 * Pure postMessage bridge for the AgilFrame hosted widget.
 *
 * The hosted `embed.html` talks to its parent with `agil:*` messages. In a
 * top-level React Native WebView `window.parent === window`, so `embed.html`'s
 * `parent.postMessage()` would only talk to itself. The injected shim
 * (`createBridgeShimScript`) forwards those messages to
 * `window.ReactNativeWebView.postMessage` while keeping the page's own
 * same-document listener working.
 *
 * All parsing is defensive: malformed, oversized and hostile payloads are
 * rejected or sanitized; nothing here trusts the WebView content.
 */
import { AGIL_ACTIONS } from './core-types.js';
import {
  ConnectionDigest,
  LARGE_ROOM_MAX_PARTICIPANTS,
  ParticipantDigest,
  compactCallState,
  extractParticipantIds,
  readConnectionFields,
} from './large-room.js';
import { redactSecrets } from './url.js';
import type {
  AgilAction,
  AgilCallError,
  AgilCallEvent,
  AgilCallState,
  AgilCapabilities,
  AgilChatMessage,
  AgilThemeScheme,
} from './core-types.js';

export const DEFAULT_MAX_BRIDGE_CHARS = 262_144;
const MAX_EVENT_NAME = 64;
const MAX_WIDGET_TEXT = 500;

export interface WidgetReadyMessage {
  type: 'agil:ready';
  capabilities: AgilCapabilities;
  room?: string;
  server?: string;
}

export type WidgetToHostMessage =
  | WidgetReadyMessage
  | { type: 'agil:event'; event: string; payload?: unknown }
  | { type: 'agil:chat'; message: AgilChatMessage }
  | { type: 'agil:state'; state: AgilCallState; participantIds?: string[] }
  | { type: 'agil:minimized'; minimized: boolean }
  | { type: 'agil:fullscreen'; fullscreen: boolean }
  | { type: 'agil:pong' };

export type HostToWidgetMessage =
  | { type: 'agil:action'; action: AgilAction }
  | { type: 'agil:chat-send'; text: string }
  | { type: 'agil:scheme'; scheme: AgilThemeScheme }
  | { type: 'agil:theme'; theme: object }
  | { type: 'agil:config'; config: object }
  | { type: 'agil:ping' };

export interface ParseBridgeOptions {
  /** Characters (not bytes) accepted before JSON parsing; default 262144. */
  maxChars?: number;
}

export interface SanitizeLimits {
  maxDepth?: number;
  maxArray?: number;
  maxKeys?: number;
  maxString?: number;
}

const DEFAULT_LIMITS: Required<SanitizeLimits> = {
  maxDepth: 8,
  maxArray: 100,
  maxKeys: 100,
  maxString: 32_768,
};

const FORBIDDEN_KEYS = new Set(['__proto__', 'prototype', 'constructor']);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function truncated(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

function safeString(value: unknown, max: number): string | undefined {
  return typeof value === 'string' ? truncated(value, max) : undefined;
}

/**
 * Recursively converts an untrusted value into a JSON-safe tree.
 * Drops functions/symbols/`undefined`, masks prototypes, limits depth and
 * collection sizes, and breaks cycles. Numbers that are not finite become
 * `null`.
 */
export function sanitizeBridgePayload(
  value: unknown,
  limits: SanitizeLimits = {},
): unknown {
  const maxDepth = limits.maxDepth ?? DEFAULT_LIMITS.maxDepth;
  const maxArray = limits.maxArray ?? DEFAULT_LIMITS.maxArray;
  const maxKeys = limits.maxKeys ?? DEFAULT_LIMITS.maxKeys;
  const maxString = limits.maxString ?? DEFAULT_LIMITS.maxString;
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
      const result: Record<string, unknown> = {};
      let count = 0;
      for (const key of Object.keys(object)) {
        if (count >= maxKeys) break;
        if (FORBIDDEN_KEYS.has(key)) continue;
        let item: unknown;
        try {
          item = walk((object as Record<string, unknown>)[key], depth + 1);
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

/**
 * Parses a value received from `WebView.onMessage` (`nativeEvent.data`).
 * Accepts a JSON string or an already-parsed object. Returns `null` for
 * anything that is not a well-formed `agil:*` widget message.
 */
export function parseBridgeMessage(
  raw: unknown,
  options: ParseBridgeOptions = {},
): WidgetToHostMessage | null {
  try {
    let value: unknown = raw;
    if (typeof raw === 'string') {
      const maxChars = options.maxChars ?? DEFAULT_MAX_BRIDGE_CHARS;
      if (raw.length > maxChars) return null;
      value = JSON.parse(raw);
    }
    if (!isRecord(value)) return null;
    const type = value.type;
    if (typeof type !== 'string' || !type.startsWith('agil:') || type.length > 64) return null;

    switch (type) {
      case 'agil:ready': {
        const message: WidgetReadyMessage = {
          type,
          capabilities: readCapabilities(value.capabilities),
        };
        const room = safeString(value.room, 200);
        if (room) message.room = room;
        const server = safeString(value.server, 2048);
        if (server) message.server = server;
        return message;
      }
      case 'agil:event': {
        const event = value.event;
        if (typeof event !== 'string' || !/^[a-z][a-z0-9-]{0,63}$/.test(event)) return null;
        return {
          type,
          event: event.slice(0, MAX_EVENT_NAME),
          payload: sanitizeBridgePayload(value.payload),
        };
      }
      case 'agil:chat': {
        const message = sanitizeBridgePayload(value.message);
        if (!isRecord(message) || typeof message.text !== 'string') return null;
        return { type, message: message as AgilChatMessage };
      }
      case 'agil:state': {
        // `participantIds` may hold up to 200 ids; parse it before the generic
        // 100-item array cap would truncate it, then strip it from the state.
        // One extra id is kept so the digest can flag an oversized widget array
        // as `truncated` instead of silently capping at the profile limit.
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
          type,
          state: state as AgilCallState,
          ...(hasParticipantIds ? { participantIds } : {}),
        };
      }
      case 'agil:minimized':
        return { type, minimized: value.minimized === true };
      case 'agil:fullscreen':
        return { type, fullscreen: value.fullscreen === true };
      case 'agil:pong':
        return { type };
      default:
        return null;
    }
  } catch {
    return null;
  }
}

function widgetError(payload: unknown, secrets: readonly string[] = []): AgilCallError {
  const record = isRecord(payload) ? payload : {};
  const code = redactSecrets(safeString(record.code, 64) ?? 'widget_error', secrets);
  const rawMessage =
    safeString(record.message, MAX_WIDGET_TEXT) ?? 'The widget reported an error';
  return {
    code: 'widget-error',
    message: redactSecrets(rawMessage, secrets),
    fatal: false,
    widgetCode: code,
  };
}

export interface MapBridgeOptions {
  /** Current join/identity tokens; redacted from widget error messages. */
  secrets?: readonly string[];
  /**
   * Per-load participant digest. Pass the same instance across messages so the
   * first state is a snapshot and later states are deltas. When omitted, each
   * call behaves as a fresh digest (one snapshot per message).
   */
  participants?: ParticipantDigest;
  /** Per-load connection/reconnect digest (deduplicates transitions). */
  connection?: ConnectionDigest;
}

export interface BridgeMapping {
  events: AgilCallEvent[];
  /** Present when the bridge message was an error (already included in `events`). */
  error?: AgilCallError;
}

/** Maps a parsed widget message to public `<AgilCall />` events. */
export function mapBridgeMessage(
  message: WidgetToHostMessage,
  options: MapBridgeOptions = {},
): BridgeMapping {
  const secrets = options.secrets ?? [];
  switch (message.type) {
    case 'agil:ready': {
      const event: AgilCallEvent = { type: 'ready', capabilities: message.capabilities };
      if (message.room) event.room = message.room;
      if (message.server) event.server = message.server;
      return { events: [event] };
    }
    case 'agil:event': {
      if (message.event === 'error') {
        const error = widgetError(message.payload, secrets);
        return { events: [{ type: 'error', error }], error };
      }
      if (message.event === 'joined' || message.event === 'left') {
        return { events: [{ type: message.event, payload: message.payload }] };
      }
      const events: AgilCallEvent[] = [
        { type: 'event', name: message.event, payload: message.payload },
      ];
      // `connection-state` is the widget's reconnect signal; surface a
      // deduplicated `connection` event with attempt/backoff when present.
      if (message.event === 'connection-state' || message.event === 'connection-changed') {
        const fields = readConnectionFields(
          isRecord(message.payload) ? message.payload : {},
        );
        const digest = options.connection ?? new ConnectionDigest();
        const connection = digest.apply(fields);
        if (connection) events.push({ type: 'connection', connection });
      }
      return { events };
    }
    case 'agil:chat':
      return { events: [{ type: 'chat', message: message.message }] };
    case 'agil:state': {
      const participants = options.participants ?? new ParticipantDigest();
      const connectionDigest = options.connection ?? new ConnectionDigest();
      const participantUpdate = participants.apply({
        participantIds: message.participantIds,
        count: message.state.participants,
      });
      const state = compactCallState(
        message.state as Record<string, unknown>,
        participantUpdate,
      ) as AgilCallState;
      const events: AgilCallEvent[] = [{ type: 'state', state }];
      if (participantUpdate) events.push({ type: 'participants', participants: participantUpdate });
      const fields = readConnectionFields(message.state as Record<string, unknown>);
      const connection = connectionDigest.apply(fields);
      if (connection) {
        events.push({ type: 'connection', connection });
        if (connection.reconnecting) {
          state.reconnect = {
            ...(connection.attempt !== undefined ? { attempt: connection.attempt } : {}),
            ...(connection.delayMs !== undefined ? { delayMs: connection.delayMs } : {}),
          };
        }
      }
      return { events };
    }
    case 'agil:minimized':
      return { events: [{ type: 'minimized', minimized: message.minimized }] };
    case 'agil:fullscreen':
      return { events: [{ type: 'fullscreen', fullscreen: message.fullscreen }] };
    case 'agil:pong':
      return { events: [] };
    default:
      return { events: [] };
  }
}

export function isAgilAction(value: unknown): value is AgilAction {
  return typeof value === 'string' && (AGIL_ACTIONS as readonly string[]).includes(value);
}

function normalizeHostMessage(message: HostToWidgetMessage): HostToWidgetMessage {
  if (!isRecord(message)) {
    throw new Error('Bridge message must be an object');
  }
  switch (message.type) {
    case 'agil:action':
      if (!isAgilAction(message.action)) throw new Error(`Unknown widget action: ${String(message.action)}`);
      return { type: 'agil:action', action: message.action };
    case 'agil:chat-send': {
      if (typeof message.text !== 'string' || !message.text.trim()) {
        throw new Error('Chat text must be a non-empty string');
      }
      return { type: 'agil:chat-send', text: message.text.slice(0, 4000) };
    }
    case 'agil:scheme':
      if (message.scheme !== 'light' && message.scheme !== 'dark' && message.scheme !== 'auto') {
        throw new Error('Unknown theme scheme');
      }
      return { type: 'agil:scheme', scheme: message.scheme };
    case 'agil:theme': {
      const theme = sanitizeBridgePayload(message.theme, { maxDepth: 12, maxKeys: 500, maxArray: 500, maxString: 8192 });
      if (!isRecord(theme)) throw new Error('Theme patch must be an object');
      return { type: 'agil:theme', theme };
    }
    case 'agil:config': {
      const config = sanitizeBridgePayload(message.config, { maxDepth: 12, maxKeys: 500, maxArray: 500, maxString: 8192 });
      if (!isRecord(config)) throw new Error('Config patch must be an object');
      return { type: 'agil:config', config };
    }
    case 'agil:ping':
      return { type: 'agil:ping' };
    default:
      throw new Error('Unknown bridge message type');
  }
}

function jsonForScript(value: unknown): string {
  const json = JSON.stringify(value);
  if (typeof json !== 'string') throw new Error('Bridge message is not JSON-serializable');
  return json
    .replace(/</g, '\\u003c')
    .replace(/>/g, '\\u003e')
    .replace(/&/g, '\\u0026')
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
}

/**
 * Extracts the widget payload from the nonce envelope written by the shim.
 *
 * Every native shell injects its bridge channel globally, so a page outside the
 * widget origin can call `ReactNativeWebView.postMessage` directly. The shim
 * wraps each forwarded message together with a per-load nonce that is only
 * present in the widget-origin page's closure; anything without the current
 * nonce is rejected. With no nonce (legacy/direct use) the raw string is
 * returned unchanged.
 */
export function unwrapBridgeEnvelope(raw: unknown, nonce?: string): string | null {
  if (typeof nonce !== 'string' || !nonce) return typeof raw === 'string' ? raw : null;
  if (typeof raw !== 'string' || raw.length > DEFAULT_MAX_BRIDGE_CHARS + 1024) return null;
  try {
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value)) return null;
    if (value['__agilBridgeNonce'] !== nonce) return null;
    const message = value['message'];
    return typeof message === 'string' ? message : null;
  } catch {
    return null;
  }
}

/**
 * Builds a script for `WebView.injectJavaScript()` that delivers a host message
 * to the page's `window` listener. Uses the shim's saved original
 * `postMessage` when available, so host→widget messages are not echoed to
 * native.
 */
export function createHostMessageScript(message: HostToWidgetMessage): string {
  const safe = normalizeHostMessage(message);
  const json = jsonForScript(safe);
  return `(function(){try{var p=window.__agilRnBridgePostToPage||window.postMessage;if(typeof p!=="function"){return;}p.call(window,${json},window.location.origin);}catch(e){}})();true;`;
}

/**
 * Script injected before page content (and again on load end as a safety net).
 * It forwards `window.parent.postMessage(...)` to the native bridge and keeps
 * the original same-document dispatch working, which `embed.html` relies on for
 * its own `message` listener.
 */
export function createBridgeShimScript(
  origin?: string,
  options: { nonce?: string } = {},
): string {
  const originGuard =
    typeof origin === 'string' && origin
      ? `if(w.location.origin!==${jsonForScript(origin)}){return;}`
      : '';
  const nonce =
    typeof options.nonce === 'string' && options.nonce ? jsonForScript(options.nonce) : 'null';
  return `(function(){try{
var w=window;
${originGuard}
if(!w||!w.parent||w.__agilRnBridgeInstalled){return;}
var bridge=w.ReactNativeWebView;
if(!bridge||typeof bridge.postMessage!=="function"){return;}
var original=w.postMessage;
if(typeof original!=="function"){return;}
var nonce=${nonce};
var forward=function(message,targetOrigin){
  try{
    var text=typeof message==="string"?message:JSON.stringify(message);
    bridge.postMessage(nonce?JSON.stringify({__agilBridgeNonce:nonce,message:text}):text);
  }catch(e){}
  try{return original.call(w,message,targetOrigin||w.location.origin);}catch(e){}
};
var installed=false;
try{w.parent.postMessage=forward;installed=w.parent.postMessage===forward;}catch(e){}
if(!installed){try{Object.defineProperty(w.parent,"postMessage",{value:forward,writable:true,configurable:true});installed=w.parent.postMessage===forward;}catch(e2){}}
if(installed){w.__agilRnBridgePostToPage=original;w.__agilRnBridgeInstalled=true;}
}catch(e){}})();true;`;
}

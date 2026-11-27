/**
 * `@agil/calls-capacitor` — Capacitor plugin for the hosted AgilFrame widget.
 *
 * `AgilCalls.openCall()` validates the options, builds the `/embed.html` URL and
 * hands it to the native shell (WKWebView / Android WebView) or opens the system
 * browser. Widget messages arrive on the native `callMessage` channel as raw
 * JSON and are sanitized/parsed here before reaching host listeners.
 */
import { registerPlugin } from '@capacitor/core';
import type { PluginListenerHandle } from '@capacitor/core';

import { parseNativeWidgetMessage } from './bridge.js';
import {
  ConnectionDigest,
  ParticipantDigest,
  compactCallState,
  normalizeLargeRoomLimits,
  readConnectionFields,
} from './large-room.js';
import {
  AGIL_CALL_ACTIONS,
  type AgilCallAction,
  type AgilCallsNativePlugin,
  type AgilCallsPlugin,
  type AgilCallErrorCode,
  type AgilCallEvent,
  type AgilCallState,
  type AgilNativeCallMessage,
  type AgilOpenCallOptions,
  type AgilOpenCallResult,
  type AgilPermissionReport,
  type AgilSupportResult,
  type AgilThemeOptions,
} from './definitions.js';
import { buildWidgetUrl, normalizeOpenCallOptions } from './url.js';

const PRESENTATIONS = new Set(['auto', 'in-app', 'external']);
const SCHEMES = new Set(['light', 'dark', 'auto']);

/**
 * Native shells report errors as widget-style `agil:event {event:'error'}` raw
 * messages. Map their `widgetCode` back to the public error codes so hosts see
 * `load-failed`/`timeout`/`navigation-blocked` instead of generic
 * `widget-error`.
 */
const NATIVE_ERROR_CODES: Record<string, AgilCallErrorCode> = {
  invalid_config: 'invalid-config',
  permission_denied: 'permission-denied',
  load_failed: 'load-failed',
  http_error: 'http-error',
  navigation_blocked: 'navigation-blocked',
  render_process_gone: 'render-process-gone',
  bridge_error: 'bridge-error',
  widget_error: 'widget-error',
  timeout: 'timeout',
  unsupported: 'unsupported',
};

const native = registerPlugin<AgilCallsNativePlugin>('AgilCalls', {
  web: () => import('./web.js').then((module) => new module.AgilCallsWeb()),
});

class AgilCallsFacade implements AgilCallsPlugin {
  #secrets: readonly string[] = [];
  #participants = new ParticipantDigest();
  #connection = new ConnectionDigest();

  async openCall(options: AgilOpenCallOptions): Promise<AgilOpenCallResult> {
    const normalized = normalizeOpenCallOptions(options);
    const presentation = options.presentation ?? 'auto';
    if (!PRESENTATIONS.has(presentation)) {
      throw new Error('presentation must be "auto", "in-app" or "external"');
    }
    const url = buildWidgetUrl(normalized);
    const largeRoom = normalizeLargeRoomLimits({
      maxParticipants: options.limits?.maxParticipants,
    });
    this.#participants = new ParticipantDigest(largeRoom);
    this.#connection = new ConnectionDigest();
    this.#secrets = [options.joinToken, options.identityToken].filter(
      (value): value is string => typeof value === 'string' && value.length > 0,
    );
    const result = await native.openCall({
      url,
      allowedOrigins: [...(options.allowedOrigins ?? [])],
      permissions: {
        camera: options.permissions?.camera !== false,
        microphone: options.permissions?.microphone !== false,
      },
      presentation,
      limits: { maxParticipants: largeRoom.maxParticipants },
    });
    if (!result || typeof result.callId !== 'string') {
      throw new Error('The native AgilFrame plugin returned an invalid result');
    }
    return { callId: result.callId, mode: result.mode === 'external' ? 'external' : 'in-app' };
  }

  close(): Promise<void> {
    this.#secrets = [];
    this.#participants.reset();
    this.#connection.reset();
    return native.close();
  }

  async sendAction(action: AgilCallAction): Promise<void> {
    if (!(AGIL_CALL_ACTIONS as readonly string[]).includes(action)) {
      throw new Error(`Unknown AgilFrame action: ${String(action)}`);
    }
    await native.sendAction({ action });
  }

  async sendChat(text: string): Promise<void> {
    if (typeof text !== 'string' || !text.trim()) {
      throw new Error('Chat text must be a non-empty string');
    }
    await native.sendChat({ text: text.slice(0, 4000) });
  }

  isSupported(): Promise<AgilSupportResult> {
    return native.isSupported();
  }

  async setTheme(options: AgilThemeOptions): Promise<void> {
    if (!options || typeof options !== 'object') {
      throw new Error('setTheme requires options');
    }
    if (options.scheme !== undefined && !SCHEMES.has(options.scheme)) {
      throw new Error('scheme must be "light", "dark" or "auto"');
    }
    if (options.theme !== undefined) {
      if (
        typeof options.theme !== 'object' ||
        options.theme === null ||
        Array.isArray(options.theme)
      ) {
        throw new Error('theme must be an object');
      }
    }
    if (options.scheme === undefined && options.theme === undefined) return;
    await native.setTheme(options);
  }

  checkPermissions(): Promise<AgilPermissionReport> {
    return native.checkPermissions();
  }

  requestPermissions(): Promise<AgilPermissionReport> {
    return native.requestPermissions();
  }

  async addListener(
    eventName: 'callEvent',
    listener: (event: AgilCallEvent) => void,
  ): Promise<PluginListenerHandle> {
    if (eventName !== 'callEvent') {
      throw new Error(`Unknown AgilFrame event: ${String(eventName)}`);
    }
    const handle = await native.addListener('callMessage', (message: AgilNativeCallMessage) => {
      if (!message || typeof message.raw !== 'string') return;
      // Android forwards `{__agilBridgeNonce,message}` from its shim; the
      // native channel parser unwraps it so ready/chat/state/event still reach
      // host listeners.
      const event = parseNativeWidgetMessage(message.raw, { secrets: this.#secrets });
      if (!event) return;
      this.#deliver(event, listener);
    });
    return {
      remove: () => handle.remove(),
    };
  }

  /**
   * Compacts `state` (one bounded participant snapshot, then deltas) and emits
   * a deduplicated `connection` event. A 200-id array is never forwarded on
   * every tick.
   */
  #deliver(event: AgilCallEvent, listener: (event: AgilCallEvent) => void): void {
    if (event.type === 'error' && event.error.widgetCode) {
      const mapped = NATIVE_ERROR_CODES[event.error.widgetCode.replace(/-/g, '_')];
      if (mapped) event.error.code = mapped;
    }
    if (event.type === 'state') {
      const source = event.state as Record<string, unknown>;
      const update = this.#participants.apply({
        participantIds: event.participantIds,
        count: event.state.participants,
      });
      const state = compactCallState(source, update) as AgilCallState;
      const connection = this.#connection.apply(readConnectionFields(source));
      if (connection) {
        if (connection.reconnecting) {
          state.reconnect = {
            ...(connection.attempt !== undefined ? { attempt: connection.attempt } : {}),
            ...(connection.delayMs !== undefined ? { delayMs: connection.delayMs } : {}),
          };
        }
      }
      listener({ type: 'state', state });
      if (update) listener({ type: 'participants', participants: update });
      if (connection) listener({ type: 'connection', connection });
      return;
    }
    if (
      event.type === 'event' &&
      (event.name === 'connection-state' || event.name === 'connection-changed')
    ) {
      const connection = this.#connection.apply(
        readConnectionFields(
          typeof event.payload === 'object' && event.payload !== null
            ? (event.payload as Record<string, unknown>)
            : {},
        ),
      );
      if (connection) listener({ type: 'connection', connection });
    }
    listener(event);
  }

  removeAllListeners(): Promise<void> {
    return native.removeAllListeners();
  }
}

/** Singleton facade; import it and call `AgilCalls.openCall(options)`. */
export const AgilCalls: AgilCallsPlugin = new AgilCallsFacade();

export type * from './definitions.js';
export { AGIL_CALL_ACTIONS } from './definitions.js';
export { parseNativeWidgetMessage, unwrapBridgeEnvelope } from './bridge.js';
export {
  ConnectionDigest,
  DEFAULT_PARTICIPANT_RESYNC_MIN,
  DEFAULT_PARTICIPANT_RESYNC_RATIO,
  LARGE_ROOM_MAX_PARTICIPANTS,
  ParticipantDigest,
  compactCallState,
  extractParticipantIds,
  normalizeConnectionState,
  normalizeLargeRoomLimits,
  readConnectionFields,
} from './large-room.js';
export type {
  AgilConnectionState,
  AgilReconnectState,
  ConnectionUpdate,
  LargeRoomLimits,
  NormalizedLargeRoomLimits,
  ParticipantInput,
  ParticipantUpdate,
  ParticipantUpdateKind,
} from './large-room.js';
export type {
  AgilCallLink,
  AgilWidgetUrlOptions,
  NavigationPolicy,
  ParseAgilCallLinkOptions,
} from './url.js';
export {
  AgilConfigError,
  DEFAULT_WIDGET_PATH,
  buildWidgetUrl,
  isAllowedNavigation,
  normalizeServerUrl,
  parseAgilCallLink,
  redactCallUrl,
  redactTokenText,
  serverOrigin,
} from './url.js';

/** Package version; keep in sync with package.json. */
export const version = '0.1.0';

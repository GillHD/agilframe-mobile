/**
 * Platform-agnostic public types of `@agil/calls-react-native`.
 *
 * This module intentionally has **no React Native imports**, so URL/bridge
 * helpers (and the `./url` / `./bridge` subpath exports) can be used in Node
 * backends to build deep links or validate tokens without installing React
 * Native.
 */
import type { ConnectionUpdate, ParticipantUpdate } from './large-room.js';

/** UI locale supported by the hosted widget and the `lang` URL parameter. */
export type AgilLanguage = 'ru' | 'en';

/** Theme scheme understood by `embed.html` (`theme=`); the full theme lives on the server. */
export type AgilThemeScheme = 'light' | 'dark' | 'auto';

export type AgilRole = 'host' | 'moderator' | 'guest';

/** Camera/microphone that the host app is willing to use for the call. */
export interface AgilMediaPermissions {
  /** `false` disables the camera request; default `true`. */
  camera?: boolean;
  /** `false` disables the microphone request; default `true`. */
  microphone?: boolean;
}

/** Safe-area insets, e.g. from `react-native-safe-area-context`'s `useSafeAreaInsets()`. */
export interface AgilSafeAreaInsets {
  top?: number;
  right?: number;
  bottom?: number;
  left?: number;
}

/**
 * Large-room limits for the WebView bridge (Stage 3b).
 *
 * `maxParticipants` is the one-room profile cap: 200. The SDK keeps the
 * canonical participant set and sends snapshot/delta updates instead of
 * re-sending the full `participantIds` array on every widget tick.
 */
export interface AgilLimits {
  /** 2..200; values outside the range are clamped to the 200-participant profile. */
  maxParticipants?: number;
}

/**
 * Actions accepted by the widget's iframe bridge (`agil:action`).
 * `embed.html` rejects unknown actions with `agil:event {event:'action-denied'}`.
 */
export const AGIL_ACTIONS = [
  'toggle-mic',
  'toggle-camera',
  'toggle-chat',
  'share-screen',
  'blur-on',
  'blur-off',
  'minimize',
  'restore',
  'pip',
  'fullscreen',
  'newtab',
  'leave',
] as const;

export type AgilAction = (typeof AGIL_ACTIONS)[number];

export interface AgilCapabilities {
  media: boolean;
  blur: boolean;
  screenShare: boolean;
  captions: boolean;
  recording: boolean;
}

/** A chat message emitted by the widget (shape mirrors `@agil/protocol`'s ChatMessage). */
export interface AgilChatMessage {
  text: string;
  id?: string;
  participantId?: string;
  participantName?: string;
  ts?: number;
  [key: string]: unknown;
}

/** Snapshot periodically posted by `embed.html` as `agil:state`. */
export interface AgilCallState {
  phase?: string;
  participants?: number;
  /**
   * Removed by the Stage 3b large-room digest: `state` never carries the full
   * array (use the `participants` snapshot/delta event). Declared `never` so
   * TypeScript hosts that still read or assign it get a compile error.
   */
  participantIds?: never;
  /** Authoritative participant count (large-room digest, Stage 3b). */
  participantCount?: number;
  /** Monotonic revision of the participant digest. */
  participantRevision?: number;
  /** Reconnect details while `connectionState` is `reconnecting`. */
  reconnect?: {
    attempt?: number;
    delayMs?: number;
    since?: number;
  };
  quality?: { tier?: string; score?: number };
  connectionState?: string;
  recording?: boolean;
  minimized?: boolean;
  chatMode?: string;
  fullscreen?: boolean;
  settings?: {
    mic?: boolean;
    camera?: boolean;
    screen?: boolean;
    blur?: string;
    panel?: string;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

export type AgilCallErrorCode =
  | 'invalid-config'
  | 'permission-denied'
  | 'load-failed'
  | 'http-error'
  | 'navigation-blocked'
  | 'render-process-gone'
  | 'bridge-error'
  | 'widget-error'
  | 'timeout';

/**
 * Error delivered to `onError`.
 *
 * `fatal` means the call cannot proceed without a host action (fix config,
 * reload the WebView or grant a permission). Non-fatal errors are informational:
 * the widget usually keeps working (e.g. a denied camera falls back to
 * listen-only mode).
 */
export interface AgilCallError {
  code: AgilCallErrorCode;
  message: string;
  fatal: boolean;
  /** HTTP status for `http-error`. */
  status?: number;
  /** Original widget error code for `widget-error`. */
  widgetCode?: string;
  /** Redacted URL (never contains `token`/`identity_token`). */
  url?: string;
  /** Extra structured details; values are bridge-sanitized. */
  details?: Record<string, unknown>;
}

export type AgilCallEvent =
  | { type: 'ready'; capabilities: AgilCapabilities; room?: string; server?: string }
  | { type: 'joined'; payload?: unknown }
  | { type: 'left'; payload?: unknown }
  | { type: 'chat'; message: AgilChatMessage }
  | { type: 'error'; error: AgilCallError }
  | { type: 'state'; state: AgilCallState }
  /** Compact participant snapshot/delta; replaces the 200-id array in `state`. */
  | { type: 'participants'; participants: ParticipantUpdate }
  /** Connection/reconnect transition, deduplicated by the SDK. */
  | { type: 'connection'; connection: ConnectionUpdate }
  | { type: 'minimized'; minimized: boolean }
  | { type: 'fullscreen'; fullscreen: boolean }
  | { type: 'event'; name: string; payload?: unknown };

/** Imperative handle exposed by `<AgilCall ref={...} />`. */
export interface AgilCallHandle {
  /** Reloads the WebView and restarts the ready watchdog. */
  reload(): void;
  /**
   * Reloads with the same server/room/token while rotating the bridge nonce and
   * resetting the participant digest. Use it after a connection drop.
   */
  reconnect(): void;
  /** Sends a bridged widget action (`toggle-mic`, `leave`, …). */
  sendAction(action: AgilAction): void;
  /** Sends a chat message through the widget's external-chat bridge. */
  sendChat(text: string): void;
  /** Switches light/dark/auto without reloading the WebView. */
  setThemeScheme(scheme: AgilThemeScheme): void;
  /** Applies a partial theme patch through `agil:theme`. */
  applyTheme(theme: object): void;
  /** Applies a tenant-config patch through `agil:config`. */
  applyConfig(config: object): void;
  /** Sends `agil:ping`; the widget answers with `agil:pong`. */
  ping(): void;
}

/** Parsed `agilcalls://call?...` or `/embed.html?...` link. */
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

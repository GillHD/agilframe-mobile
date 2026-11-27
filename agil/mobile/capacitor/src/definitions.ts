/**
 * Public definitions of `@agil/calls-capacitor`.
 *
 * The plugin is a thin native shell around the hosted `/embed.html` widget:
 * media, chat, themes and participant state stay in the web app; the plugin
 * owns presentation (in-app WebView or the system browser), the `AgilBridge`
 * `postMessage` channel and native camera/microphone permissions.
 */
import type { PluginListenerHandle } from '@capacitor/core';
import type { ConnectionUpdate, ParticipantUpdate } from './large-room.js';

/** Large-room bridge limits (Stage 3b): one room up to 200 participants. */
export interface AgilLimits {
  /** 2..200; values outside the range are clamped to the 200-participant profile. */
  maxParticipants?: number;
}

/** UI locale supported by the hosted widget (`lang=`). */
export type AgilLanguage = 'ru' | 'en';

/** Theme scheme understood by `embed.html` (`theme=`). */
export type AgilThemeScheme = 'light' | 'dark' | 'auto';

/** Role for anonymous joins (`role=`). */
export type AgilRole = 'host' | 'moderator' | 'guest';

/** Imperative actions supported by the hosted widget (`agil:action`). */
export type AgilCallAction =
  | 'leave'
  | 'toggle-mic'
  | 'toggle-camera'
  | 'toggle-chat'
  | 'share-screen'
  | 'blur-on'
  | 'blur-off'
  | 'minimize'
  | 'restore'
  | 'pip'
  | 'fullscreen'
  | 'newtab';

/** Every action the facade accepts at runtime. */
export const AGIL_CALL_ACTIONS: readonly AgilCallAction[] = [
  'leave',
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
];

/** Camera/microphone the host app is willing to use. */
export interface AgilMediaPermissions {
  /** `false` disables the camera request; default `true`. */
  camera?: boolean;
  /** `false` disables the microphone request; default `true`. */
  microphone?: boolean;
}

/** How `openCall` presents the call. */
export type AgilPresentation = 'auto' | 'in-app' | 'external';

/** Options accepted by `AgilCalls.openCall()`. */
export interface AgilOpenCallOptions {
  /** Base origin of the AgilFrame server, only `http(s)`; a subpath is preserved. */
  serverUrl: string;
  /** Room id. */
  roomId: string;
  /** Tenant; `demo` by default. */
  tenantId?: string;
  /** Short-lived join token; without it the widget shows its own join screen. */
  joinToken?: string;
  /** Corporate OIDC token (`identity_token`). */
  identityToken?: string;
  /** Display name used by the widget's join screen. */
  participantName?: string;
  /** Role for anonymous joins. */
  role?: AgilRole;
  /** Theme scheme only; the full theme lives on the server. */
  theme?: AgilThemeScheme;
  /** UI locale. */
  language?: AgilLanguage;
  /** Force TURN-only media (`relay=1`). */
  relayOnly?: boolean;
  /** Page path relative to `serverUrl` (`embed.html` by default). */
  widgetPath?: string;
  /** Additional exact origins allowed by the navigation guard (SSO, ...). */
  allowedOrigins?: string[];
  /** Allow non-loopback `http://`; development only. */
  allowInsecure?: boolean;
  /** `auto` (default) uses the in-app WebView when available. */
  presentation?: AgilPresentation;
  /** Media permissions the app intends to use; default both `true`. */
  permissions?: AgilMediaPermissions;
  /**
   * Large-room limits. `maxParticipants` defaults to 200; the facade keeps the
   * canonical participant set and emits compact snapshot/delta events instead
   * of forwarding a 200-id array on every widget tick.
   */
  limits?: AgilLimits;
}

/** Result of `AgilCalls.openCall()`. Never contains the join token. */
export interface AgilOpenCallResult {
  /** Opaque session id, useful for logs/analytics. */
  callId: string;
  /** `in-app` WebView or the system browser. */
  mode: 'in-app' | 'external';
}

/** Result of `AgilCalls.isSupported()`. */
export interface AgilSupportResult {
  /** `true` when the call can be opened at all (in-app or externally). */
  supported: boolean;
  /** `true` when an in-app WKWebView/Android WebView is available. */
  inAppWebView: boolean;
  /** Why in-app mode is unavailable (platform limitation, old WebView, ...). */
  reason?: string;
}

/** Theme commands accepted by `AgilCalls.setTheme()`. */
export interface AgilThemeOptions {
  /** Switches light/dark/auto without reloading the WebView. */
  scheme?: AgilThemeScheme;
  /** Partial theme patch forwarded as `agil:theme`. */
  theme?: Record<string, unknown>;
}

export type AgilPermissionStatus =
  | 'granted'
  | 'denied'
  | 'prompt'
  | 'prompt-with-rationale'
  | 'blocked'
  | 'unavailable'
  | 'not-requested';

/** Camera/microphone permission report. */
export interface AgilPermissionReport {
  camera: AgilPermissionStatus;
  microphone: AgilPermissionStatus;
  /** At least one permission is permanently blocked; open app settings. */
  settingsRequired: boolean;
}

export interface AgilCapabilities {
  media: boolean;
  blur: boolean;
  screenShare: boolean;
  captions: boolean;
  recording: boolean;
}

/** A chat message emitted by the widget (shape mirrors `@agil/protocol`). */
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
   * Removed by the Stage 3b large-room digest: the facade never delivers the
   * full array on `state` (subscribe to `participants`). Declared `never` so
   * TypeScript hosts that still read or assign it get a compile error.
   */
  participantIds?: never;
  /** Authoritative participant count (large-room digest). */
  participantCount?: number;
  /** Monotonic revision of the participant digest. */
  participantRevision?: number;
  reconnect?: { attempt?: number; delayMs?: number; since?: number };
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
  | 'timeout'
  | 'unsupported';

/** Error delivered as a `{type:'error'}` call event. */
export interface AgilCallError {
  code: AgilCallErrorCode;
  message: string;
  fatal: boolean;
  status?: number;
  widgetCode?: string;
  /** Redacted URL (never contains `token`/`identity_token`). */
  url?: string;
  details?: Record<string, unknown>;
}

/** Events delivered to `AgilCalls.addListener('callEvent', ...)`. */
export type AgilCallEvent =
  | { type: 'ready'; capabilities: AgilCapabilities; room?: string; server?: string }
  | { type: 'joined'; payload?: unknown }
  | { type: 'left'; payload?: unknown }
  | { type: 'chat'; message: AgilChatMessage }
  | { type: 'error'; error: AgilCallError }
  | { type: 'state'; state: AgilCallState; participantIds?: string[] }
  | { type: 'participants'; participants: ParticipantUpdate }
  | { type: 'connection'; connection: ConnectionUpdate }
  | { type: 'minimized'; minimized: boolean }
  | { type: 'fullscreen'; fullscreen: boolean }
  | { type: 'event'; name: string; payload?: unknown };

/** Low-level bridge payload; the JS facade builds/validates the widget URL. */
export interface AgilNativeOpenCallOptions {
  /** Fully built `/embed.html?...` URL (contains the join token). */
  url: string;
  /** Exact extra origins allowed by the navigation guard. */
  allowedOrigins?: string[];
  /** Media permissions the app intends to use. */
  permissions?: AgilMediaPermissions;
  /** Presentation preference. */
  presentation?: AgilPresentation;
  /** Normalized large-room limits (native shells may forward them to their view). */
  limits?: AgilLimits;
}

/** Raw widget message forwarded by the native shell; parsed by the JS facade. */
export interface AgilNativeCallMessage {
  /** JSON string of one `agil:*` widget message. */
  raw: string;
}

/** Native plugin surface implemented by Swift/Kotlin and `src/web.ts`. */
export interface AgilCallsNativePlugin {
  openCall(options: AgilNativeOpenCallOptions): Promise<AgilOpenCallResult>;
  close(): Promise<void>;
  isSupported(): Promise<AgilSupportResult>;
  setTheme(options: AgilThemeOptions): Promise<void>;
  /** Sends `agil:action` (toggle-mic, toggle-camera, toggle-chat, leave, …). */
  sendAction(options: { action: AgilCallAction }): Promise<void>;
  /** Sends `agil:chat-send` without closing the WebView. */
  sendChat(options: { text: string }): Promise<void>;
  checkPermissions(): Promise<AgilPermissionReport>;
  requestPermissions(): Promise<AgilPermissionReport>;
  addListener(
    eventName: 'callMessage',
    listener: (message: AgilNativeCallMessage) => void,
  ): Promise<PluginListenerHandle>;
  removeAllListeners(): Promise<void>;
}

/** Public, facade-style API exported as `AgilCalls`. */
export interface AgilCallsPlugin {
  /** Validates options, builds the widget URL and opens the call. */
  openCall(options: AgilOpenCallOptions): Promise<AgilOpenCallResult>;
  /** Closes the in-app WebView (no-op for external browser mode). */
  close(): Promise<void>;
  /** Reports whether in-app WebView or external browser fallback is available. */
  isSupported(): Promise<AgilSupportResult>;
  /** Applies a theme scheme/patch to the running call. */
  setTheme(options: AgilThemeOptions): Promise<void>;
  /** Sends `agil:action` (toggle-mic, toggle-camera, toggle-chat, leave, …). */
  sendAction(action: AgilCallAction): Promise<void>;
  /** Sends `agil:chat-send` without closing the WebView. */
  sendChat(text: string): Promise<void>;
  /** Reports camera/microphone permission state without prompting. */
  checkPermissions(): Promise<AgilPermissionReport>;
  /** Requests camera/microphone permissions (iOS/Android runtime prompt). */
  requestPermissions(): Promise<AgilPermissionReport>;
  /** Subscribes to call events. Remember to remove the returned handle. */
  addListener(
    eventName: 'callEvent',
    listener: (event: AgilCallEvent) => void,
  ): Promise<PluginListenerHandle>;
  /** Removes every listener registered by this plugin instance. */
  removeAllListeners(): Promise<void>;
}

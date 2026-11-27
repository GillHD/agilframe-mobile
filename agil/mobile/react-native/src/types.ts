/**
 * Public surface of `@agil/calls-react-native` with the React Native component
 * props. Platform-agnostic types live in `core-types.ts`; they are re-exported
 * here for a single public import path.
 */
import type { StyleProp, ViewStyle } from 'react-native';
import type {
  AgilCallError,
  AgilCallEvent,
  AgilLanguage,
  AgilLimits,
  AgilMediaPermissions,
  AgilRole,
  AgilSafeAreaInsets,
  AgilThemeScheme,
} from './core-types.js';

export * from './core-types.js';

export interface AgilCallProps {
  /** Base HTTP(S) URL of the AgilFrame server, e.g. `https://calls.example.com`. */
  serverUrl: string;
  /** Room id; required by `/embed.html?room=<id>`. */
  roomId: string;
  /** Join token from `POST /v1/rooms/:roomId/join`; without it the widget shows its join screen. */
  joinToken?: string;
  /** Tenant id; default `demo` (matches the hosted widget). */
  tenantId?: string;
  /** Display name shown by the widget's join screen. */
  participantName?: string;
  role?: AgilRole;
  /** Theme scheme only; full tokens come from the tenant config. */
  theme?: AgilThemeScheme;
  language?: AgilLanguage;
  /** Corporate OIDC token (SSO); passed as `identity_token` in the URL. */
  identityToken?: string;
  /** Forces a TURN-relay-only ICE policy (`relay=1`). */
  relayOnly?: boolean;
  /** Widget page path relative to `serverUrl`; default `embed.html`. */
  widgetPath?: string;
  /**
   * Allows a non-loopback plain-`http://` server URL. Development only: join
   * tokens and media would travel in clear text. Default `false`.
   */
  allowInsecure?: boolean;
  /** Camera/microphone allowed for this call; default both `true`. */
  permissions?: AgilMediaPermissions;
  /**
   * Requests Android runtime camera/mic permissions on mount. Default `true`.
   * iOS uses the WKWebView system prompt and Info.plist usage strings instead.
   */
  requestPermissionsOnMount?: boolean;
  /** Milliseconds to wait for `agil:ready`; default 20000. `0` disables the watchdog. */
  readyTimeoutMs?: number;
  /**
   * Large-room limits (Stage 3b). `maxParticipants` defaults to 200; the SDK
   * tracks that many participant ids and emits snapshot/delta events instead of
   * forwarding the widget's full `participantIds` array on every tick.
   */
  limits?: AgilLimits;
  /** Extra origins allowed for navigation (SSO, corporate links). Exact origins only. */
  allowedOrigins?: readonly string[];
  /** All bridge and host errors. Fired in addition to `onEvent` for widget errors. */
  onError?: (error: AgilCallError) => void;
  /** All call events: ready/joined/left/chat/error/state/… */
  onEvent?: (event: AgilCallEvent) => void;
  /** A navigation outside the widget origin was blocked; host may open it in the system browser. */
  onExternalLink?: (url: string) => void;
  /** Optional safe-area insets; Android WebView does not support CSS `env(safe-area-inset-*)`. */
  safeAreaInsets?: AgilSafeAreaInsets;
  /** Style of the outer container (the WebView fills it). */
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

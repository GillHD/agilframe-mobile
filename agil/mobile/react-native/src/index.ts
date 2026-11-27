/**
 * `@agil/calls-react-native` — React Native WebView wrapper for AgilFrame.
 *
 * ```tsx
 * import { AgilCall } from '@agil/calls-react-native';
 *
 * <AgilCall
 *   serverUrl="https://calls.example.com"
 *   tenantId="acme"
 *   roomId="daily-sync"
 *   joinToken={token}
 *   participantName="Анна"
 *   theme="auto"
 *   language="ru"
 *   onEvent={(event) => console.log(event.type)}
 *   onError={(error) => console.warn(error.code, error.message)}
 * />
 * ```
 */
export { AgilCall } from './AgilCall.js';

export {
  AGIL_ACTIONS,
} from './types.js';
export type {
  AgilAction,
  AgilCallError,
  AgilCallErrorCode,
  AgilCallEvent,
  AgilCallHandle,
  AgilCallLink,
  AgilCallProps,
  AgilCallState,
  AgilCapabilities,
  AgilChatMessage,
  AgilLanguage,
  AgilLimits,
  AgilMediaPermissions,
  AgilRole,
  AgilSafeAreaInsets,
  AgilThemeScheme,
} from './types.js';

export {
  AgilConfigError,
  buildCallDeepLink,
  buildWidgetUrl,
  isAllowedNavigation,
  isLoopbackHost,
  normalizeServerUrl,
  parseAgilCallLink,
  redactCallUrl,
  redactSecrets,
  redactTokenText,
  serverOrigin,
} from './url.js';
export type {
  AgilWidgetUrlOptions,
  NavigationPolicy,
  ParseCallLinkOptions,
} from './url.js';

export {
  DEFAULT_MAX_BRIDGE_CHARS,
  createBridgeShimScript,
  createHostMessageScript,
  isAgilAction,
  mapBridgeMessage,
  parseBridgeMessage,
  sanitizeBridgePayload,
  unwrapBridgeEnvelope,
} from './bridge.js';
export type {
  BridgeMapping,
  HostToWidgetMessage,
  MapBridgeOptions,
  ParseBridgeOptions,
  SanitizeLimits,
  WidgetReadyMessage,
  WidgetToHostMessage,
} from './bridge.js';

export { buildAgilCallRenderState, widgetOrigin } from './render.js';
export type { AgilCallRenderState } from './render.js';

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

export { openAppSettings, requestAgilMediaPermissions } from './permissions.js';
export type { AgilPermissionReport, AgilPermissionStatus } from './permissions.js';

/** Package version; keep in sync with package.json. */
export const version = '0.1.0';

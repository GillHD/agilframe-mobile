/**
 * `<AgilCall />` — React Native WebView shell for the hosted AgilFrame widget.
 *
 * This is intentionally a WebView integration, not a native WebRTC client: the
 * widget (media, chat, themes, permissions) keeps running on the server origin
 * and the app only owns presentation, navigation and native permissions.
 */
import {
  createElement,
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
} from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { WebView } from 'react-native-webview';
import type { WebViewMessageEvent } from 'react-native-webview';
import {
  createBridgeShimScript,
  createHostMessageScript,
  isAgilAction,
  mapBridgeMessage,
  parseBridgeMessage,
  unwrapBridgeEnvelope,
} from './bridge.js';
import type { HostToWidgetMessage } from './bridge.js';
import {
  ConnectionDigest,
  ParticipantDigest,
  normalizeLargeRoomLimits,
} from './large-room.js';
import { requestAgilMediaPermissions } from './permissions.js';
import { buildAgilCallRenderState } from './render.js';
import {
  isAllowedNavigation,
  normalizeServerUrl,
  redactCallUrl,
  redactTokenText,
} from './url.js';
import type { NavigationPolicy } from './url.js';
import type {
  AgilCallError,
  AgilCallEvent,
  AgilCallHandle,
  AgilCallProps,
  AgilThemeScheme,
} from './types.js';

const DEFAULT_READY_TIMEOUT_MS = 20_000;
const MAX_QUEUED_MESSAGES = 50;

/**
 * Random per-mount value. Every page loaded in a WebView shares
 * `ReactNativeWebView`, so the shim tags forwarded messages with this nonce and
 * `handleMessage` rejects anything else (e.g. a direct post from an allowed SSO
 * page that never received the shim).
 */
function createBridgeNonce(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random()
    .toString(36)
    .slice(2)}`;
}

interface AgilWebViewRef {
  injectJavaScript(script: string): void;
  reload(): void;
}

interface WebViewErrorEvent {
  nativeEvent?: {
    description?: string;
    statusCode?: number;
    url?: string;
    [key: string]: unknown;
  };
}

interface WebViewRequestEvent {
  url?: string;
}

function errorText(error: unknown): string {
  if (error instanceof Error) return redactTokenText(error.message).slice(0, 500);
  return 'Unknown bridge error';
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#080d16' },
  webview: { flex: 1, backgroundColor: '#080d16' },
  error: { alignItems: 'center', justifyContent: 'center', padding: 24 },
  errorText: { color: '#f8fafc', fontSize: 15, lineHeight: 20, textAlign: 'center' },
});

export const AgilCall = forwardRef<AgilCallHandle, AgilCallProps>(function AgilCallImpl(props, ref) {
  const {
    serverUrl,
    roomId,
    joinToken,
    tenantId,
    participantName,
    role,
    theme,
    language,
    identityToken,
    relayOnly,
    widgetPath,
    allowInsecure,
    permissions,
    requestPermissionsOnMount = true,
    readyTimeoutMs = DEFAULT_READY_TIMEOUT_MS,
    limits: limitsProp,
    allowedOrigins,
    onError,
    onEvent,
    onExternalLink,
    safeAreaInsets,
    style,
    testID,
  } = props;

  const onEventRef = useRef<AgilCallProps['onEvent']>(undefined);
  const onErrorRef = useRef<AgilCallProps['onError']>(undefined);
  const onExternalLinkRef = useRef<AgilCallProps['onExternalLink']>(undefined);
  useEffect(() => {
    onEventRef.current = onEvent;
    onErrorRef.current = onError;
    onExternalLinkRef.current = onExternalLink;
  }, [onEvent, onError, onExternalLink]);

  const emitError = useCallback((error: AgilCallError) => {
    onErrorRef.current?.(error);
  }, []);

  const allowedOriginsKey = allowedOrigins?.join('\u0000') ?? '';
  const built = useMemo(
    () =>
      buildAgilCallRenderState({
        serverUrl,
        roomId,
        joinToken,
        tenantId,
        participantName,
        role,
        language,
        theme,
        identityToken,
        relayOnly,
        widgetPath,
        allowInsecure,
      }),
    [
      serverUrl,
      roomId,
      joinToken,
      tenantId,
      participantName,
      role,
      theme,
      language,
      identityToken,
      relayOnly,
      widgetPath,
      allowInsecure,
    ],
  );

  const navigationPolicy = useMemo<NavigationPolicy | null>(() => {
    try {
      return { serverUrl: normalizeServerUrl(serverUrl), allowedOrigins };
    } catch {
      return null;
    }
  }, [serverUrl, allowedOriginsKey]);

  const limits = useMemo(
    () => normalizeLargeRoomLimits({ maxParticipants: limitsProp?.maxParticipants }),
    [limitsProp?.maxParticipants],
  );
  const participantsRef = useRef<ParticipantDigest | null>(null);
  if (
    !participantsRef.current ||
    participantsRef.current.maxParticipants !== limits.maxParticipants
  ) {
    participantsRef.current = new ParticipantDigest(limits);
  }
  const connectionRef = useRef<ConnectionDigest | null>(null);
  if (!connectionRef.current) connectionRef.current = new ConnectionDigest();

  const [bridgeNonce, setBridgeNonce] = useState(createBridgeNonce);
  const secrets = useMemo(
    () => [joinToken, identityToken].filter((value): value is string => Boolean(value)),
    [joinToken, identityToken],
  );
  const shimScript = useMemo(
    () => createBridgeShimScript(built.origin ?? undefined, { nonce: bridgeNonce }),
    [built.origin, bridgeNonce],
  );
  const webViewRef = useRef<AgilWebViewRef | null>(null);
  const readyRef = useRef(false);
  const queueRef = useRef<HostToWidgetMessage[]>([]);
  const readyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [generation, setGeneration] = useState(0);

  const flushQueue = useCallback(() => {
    const web = webViewRef.current;
    if (!web) return;
    const queued = queueRef.current;
    queueRef.current = [];
    for (const message of queued) {
      try {
        web.injectJavaScript(createHostMessageScript(message));
      } catch (error) {
        emitError({
          code: 'bridge-error',
          message: errorText(error),
          fatal: false,
        });
      }
    }
  }, [emitError]);

  const send = useCallback(
    (message: HostToWidgetMessage) => {
      if (!built.url) return;
      if (!readyRef.current) {
        if (queueRef.current.length >= MAX_QUEUED_MESSAGES) {
          emitError({
            code: 'bridge-error',
            message: 'Bridge message queue is full; the widget has not signalled ready',
            fatal: false,
          });
          return;
        }
        queueRef.current.push(message);
        return;
      }
      const web = webViewRef.current;
      if (!web) {
        queueRef.current.push(message);
        return;
      }
      try {
        web.injectJavaScript(createHostMessageScript(message));
      } catch (error) {
        emitError({ code: 'bridge-error', message: errorText(error), fatal: false });
      }
    },
    [built.url, emitError],
  );

  const handleMessage = useCallback(
    (event: WebViewMessageEvent) => {
      const raw = event?.nativeEvent?.data;
      // Only messages forwarded by the shim for this document load carry the
      // current nonce. A page outside the widget origin (an SSO page allowed by
      // the navigation guard) cannot read it, so a direct
      // `ReactNativeWebView.postMessage(...)` is rejected here.
      const payload = unwrapBridgeEnvelope(raw, bridgeNonce);
      if (payload === null) {
        if (typeof raw === 'string' && raw.includes('"agil:')) {
          emitError({
            code: 'bridge-error',
            message: 'Ignored a bridge message from an untrusted page',
            fatal: false,
          });
        }
        return;
      }
      const message = parseBridgeMessage(payload);
      if (!message) {
        if (payload.includes('"agil:')) {
          emitError({
            code: 'bridge-error',
            message: 'Ignored a malformed or unsupported bridge message',
            fatal: false,
          });
        }
        return;
      }
      if (message.type === 'agil:ready') {
        readyRef.current = true;
        if (readyTimerRef.current) {
          clearTimeout(readyTimerRef.current);
          readyTimerRef.current = null;
        }
      }
      const mapped = mapBridgeMessage(message, {
        secrets,
        ...(participantsRef.current ? { participants: participantsRef.current } : {}),
        ...(connectionRef.current ? { connection: connectionRef.current } : {}),
      });
      if (message.type === 'agil:ready') flushQueue();
      for (const item of mapped.events) onEventRef.current?.(item);
      if (mapped.error) onErrorRef.current?.(mapped.error);
    },
    [bridgeNonce, emitError, flushQueue, secrets],
  );

  /**
   * Remounts the WebView with the same URL (server, room, token and tenant are
   * preserved) but a fresh bridge nonce and empty participant/connection
   * digests. `reconnect()` additionally announces the reconnect to the host.
   */
  const restart = useCallback(
    (announceReconnect: boolean) => {
      readyRef.current = false;
      queueRef.current = [];
      participantsRef.current?.reset();
      connectionRef.current?.reset();
      setBridgeNonce(createBridgeNonce());
      setGeneration((value) => value + 1);
      if (announceReconnect) {
        onEventRef.current?.({
          type: 'connection',
          connection: { state: 'connecting', reconnecting: true },
        });
      }
    },
    [],
  );

  const reload = useCallback(() => {
    restart(false);
  }, [restart]);

  const reconnect = useCallback(() => {
    restart(true);
  }, [restart]);

  useImperativeHandle(
    ref,
    () => ({
      reload,
      reconnect,
      sendAction(action) {
        if (!isAgilAction(action)) {
          emitError({ code: 'invalid-config', message: `Unknown widget action: ${String(action)}`, fatal: false });
          return;
        }
        send({ type: 'agil:action', action });
      },
      sendChat(text) {
        if (typeof text !== 'string' || !text.trim()) {
          emitError({ code: 'invalid-config', message: 'Chat text must be a non-empty string', fatal: false });
          return;
        }
        send({ type: 'agil:chat-send', text });
      },
      setThemeScheme(scheme: AgilThemeScheme) {
        if (scheme !== 'light' && scheme !== 'dark' && scheme !== 'auto') {
          emitError({ code: 'invalid-config', message: 'Unknown theme scheme', fatal: false });
          return;
        }
        send({ type: 'agil:scheme', scheme });
      },
      applyTheme(themePatch) {
        if (!themePatch || typeof themePatch !== 'object') {
          emitError({ code: 'invalid-config', message: 'Theme patch must be an object', fatal: false });
          return;
        }
        send({ type: 'agil:theme', theme: themePatch });
      },
      applyConfig(configPatch) {
        if (!configPatch || typeof configPatch !== 'object') {
          emitError({ code: 'invalid-config', message: 'Config patch must be an object', fatal: false });
          return;
        }
        send({ type: 'agil:config', config: configPatch });
      },
      ping() {
        send({ type: 'agil:ping' });
      },
    }),
    [emitError, reconnect, reload, send],
  );

  useEffect(() => {
    if (built.error) emitError(built.error);
  }, [built.error, emitError]);

  useEffect(() => {
    if (!built.url || readyTimeoutMs <= 0) return;
    const timer = setTimeout(() => {
      readyTimerRef.current = null;
      if (!readyRef.current) {
        emitError({
          code: 'timeout',
          message: `The call widget did not signal ready within ${readyTimeoutMs} ms`,
          fatal: true,
        });
      }
    }, readyTimeoutMs);
    readyTimerRef.current = timer;
    return () => {
      if (readyTimerRef.current === timer) {
        clearTimeout(timer);
        readyTimerRef.current = null;
      }
    };
  }, [built.url, readyTimeoutMs, generation, emitError]);

  useEffect(() => {
    if (!requestPermissionsOnMount || !built.url) return;
    const camera = permissions?.camera !== false;
    const microphone = permissions?.microphone !== false;
    if (!camera && !microphone) return;
    let cancelled = false;
    void requestAgilMediaPermissions({ camera, microphone })
      .then((report) => {
        if (cancelled) return;
        const denied: string[] = [];
        if (camera && (report.camera === 'denied' || report.camera === 'blocked')) denied.push('camera');
        if (microphone && (report.microphone === 'denied' || report.microphone === 'blocked')) {
          denied.push('microphone');
        }
        if (denied.length > 0) {
          emitError({
            code: 'permission-denied',
            message: `${denied.join(' and ')} permission not granted; the call can continue in listen-only mode`,
            fatal: false,
            details: {
              camera: report.camera,
              microphone: report.microphone,
              settingsRequired: report.settingsRequired,
            },
          });
        }
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        emitError({ code: 'permission-denied', message: errorText(error), fatal: false });
      });
    return () => {
      cancelled = true;
    };
  }, [requestPermissionsOnMount, permissions?.camera, permissions?.microphone, built.url, emitError]);

  const handleLoadStart = useCallback(() => {
    readyRef.current = false;
    // A new document starts a new widget session: the first state is a full
    // (bounded) participant snapshot again.
    participantsRef.current?.reset();
    connectionRef.current?.reset();
  }, []);

  const handleLoadEnd = useCallback(() => {
    // Safety net for platforms where pre-content injection runs late.
    try {
      webViewRef.current?.injectJavaScript(shimScript);
    } catch {
      // The early injection is the primary mechanism; ignore this best-effort retry.
    }
  }, [shimScript]);

  const handleError = useCallback(
    (event: WebViewErrorEvent) => {
      const description = event?.nativeEvent?.description ?? 'The WebView failed to load the call page';
      const url = event?.nativeEvent?.url;
      emitError({
        code: 'load-failed',
        message: redactTokenText(description).slice(0, 500),
        fatal: true,
        ...(url ? { url: redactCallUrl(url) } : {}),
      });
    },
    [emitError],
  );

  const handleHttpError = useCallback(
    (event: WebViewErrorEvent) => {
      const status = event?.nativeEvent?.statusCode;
      const url = event?.nativeEvent?.url;
      emitError({
        code: 'http-error',
        message: `The call page returned HTTP ${typeof status === 'number' ? status : 'error'}`,
        fatal: true,
        ...(typeof status === 'number' ? { status } : {}),
        ...(url ? { url: redactCallUrl(url) } : {}),
      });
    },
    [emitError],
  );

  const handleTerminate = useCallback(() => {
    emitError({
      code: 'render-process-gone',
      message: 'The WebView render process was terminated; call reload() to recover',
      fatal: true,
    });
  }, [emitError]);

  const handleShouldStart = useCallback(
    (request: WebViewRequestEvent): boolean => {
      const url = request?.url ?? '';
      if (!navigationPolicy || !isAllowedNavigation(url, navigationPolicy)) {
        if (onExternalLinkRef.current && /^https?:\/\//i.test(url)) {
          try {
            onExternalLinkRef.current(url);
          } catch {
            // Host callback failures must not crash the navigation guard.
          }
        }
        emitError({
          code: 'navigation-blocked',
          message: `Blocked navigation to ${redactCallUrl(url) || 'an unsupported URL'}`,
          fatal: false,
          ...(url ? { url: redactCallUrl(url) } : {}),
        });
        return false;
      }
      return true;
    },
    [navigationPolicy, emitError],
  );

  const insetsStyle = useMemo(
    () => ({
      paddingTop: safeAreaInsets?.top ?? 0,
      paddingRight: safeAreaInsets?.right ?? 0,
      paddingBottom: safeAreaInsets?.bottom ?? 0,
      paddingLeft: safeAreaInsets?.left ?? 0,
    }),
    [safeAreaInsets?.top, safeAreaInsets?.right, safeAreaInsets?.bottom, safeAreaInsets?.left],
  );

  if (built.error) {
    return createElement(
      View,
      { style: [styles.container, styles.error, style], testID },
      createElement(Text, { style: styles.errorText }, `AgilFrame: ${built.error.message}`),
    );
  }

  const denyMediaCapture = permissions?.camera === false && permissions?.microphone === false;

  return createElement(
    View,
    { style: [styles.container, style, insetsStyle], testID },
    createElement(WebView, {
      key: `${built.url}#${generation}`,
      ref: webViewRef,
      source: { uri: built.url },
      style: styles.webview,
      originWhitelist: ['http://*', 'https://*'],
      javaScriptEnabled: true,
      domStorageEnabled: true,
      allowsInlineMediaPlayback: true,
      mediaPlaybackRequiresUserAction: false,
      mediaCapturePermissionGrantType: denyMediaCapture ? 'deny' : 'grant',
      allowsFullscreenVideo: true,
      allowsPictureInPictureMediaPlayback: true,
      // The widget owns the participant-list scroll container. Keep the outer
      // WebView free of rubber-banding, zoom and its own safe-area insets; the
      // host passes `safeAreaInsets` as container padding instead.
      bounces: false,
      overScrollMode: 'never',
      nestedScrollEnabled: true,
      contentInsetAdjustmentBehavior: 'never',
      setBuiltInZoomControls: false,
      setDisplayZoomControls: false,
      scalesPageToFit: false,
      showsVerticalScrollIndicator: false,
      showsHorizontalScrollIndicator: false,
      javaScriptCanOpenWindowsAutomatically: false,
      setSupportMultipleWindows: false,
      allowFileAccess: false,
      allowUniversalAccessFromFileURLs: false,
      mixedContentMode: 'never',
      injectedJavaScriptBeforeContentLoaded: shimScript,
      injectedJavaScriptBeforeContentLoadedForMainFrameOnly: true,
      onMessage: handleMessage,
      onLoadStart: handleLoadStart,
      onLoadEnd: handleLoadEnd,
      onError: handleError,
      onHttpError: handleHttpError,
      onShouldStartLoadWithRequest: handleShouldStart,
      onContentProcessDidTerminate: handleTerminate,
      onRenderProcessGone: handleTerminate,
    }),
  );
});

AgilCall.displayName = 'AgilCall';

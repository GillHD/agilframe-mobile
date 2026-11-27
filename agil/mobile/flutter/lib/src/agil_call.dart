/// `<AgilCall />` — Flutter WebView shell for the hosted AgilFrame widget.
///
/// This is intentionally a WebView integration, not a native WebRTC client:
/// media, chat, themes and permissions keep running in the hosted widget and
/// the Flutter app only owns presentation, navigation and the `AgilBridge`
/// `postMessage` channel.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as android;
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'bridge.dart';
import 'types.dart';
import 'url.dart';

/// Receives every call event (`ready`, `joined`, `left`, `chat`, `error`,
/// `state`, …).
typedef AgilCallEventCallback = void Function(AgilCallEvent event);

/// Receives load/bridge/navigation errors. Widget-reported errors also arrive
/// as [AgilErrorEvent] in [AgilCallEventCallback].
typedef AgilCallErrorCallback = void Function(AgilCallError error);

/// Called for a navigation blocked by the origin guard, so the app can open it
/// in the system browser.
typedef AgilExternalLinkCallback = void Function(String url);

/// Random value embedded in the injected shim only on the widget-origin page.
String _createBridgeNonce() {
  final Random random = Random();
  final String time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return '$time-${random.nextInt(1 << 32).toRadixString(36)}-'
      '${random.nextInt(1 << 32).toRadixString(36)}';
}

/// Imperative handle for a mounted [AgilCall].
///
/// Commands are no-ops until the widget is mounted; messages sent before
/// `agil:ready` are buffered (up to [agilBridgeMaxQueuedMessages]) and flushed
/// afterwards. Invalid input (e.g. empty chat text) is reported through the
/// widget's `onError` callback instead of throwing.
class AgilCallController {
  AgilCallController();

  _AgilCallState? _state;

  /// `true` when attached to a mounted [AgilCall].
  bool get isAttached => _state != null;

  /// `true` after the widget signalled `agil:ready`.
  bool get isReady => _state?._ready ?? false;

  /// Requests Android app permissions from an explicit host-app action, such
  /// as a device setup button. May be called before the WebView is mounted.
  /// Returns whether all requested permissions are granted. Other platforms
  /// leave the request to their WebView and return true here.
  Future<bool> requestAndroidMediaPermissions({bool camera = true, bool microphone = true}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    final List<Permission> permissions = <Permission>[
      if (camera) Permission.camera,
      if (microphone) Permission.microphone,
    ];
    if (permissions.isEmpty) return true;
    try {
      final Map<Permission, PermissionStatus> statuses = await permissions.request();
      return permissions.every((Permission permission) => statuses[permission] == PermissionStatus.granted);
    } catch (_) {
      return false;
    }
  }

  /// Toggles the microphone (`agil:action toggle-mic`).
  void toggleMute() => _state?._sendAction(AgilAction.toggleMic);

  /// Toggles the camera (`agil:action toggle-camera`).
  void toggleCamera() => _state?._sendAction(AgilAction.toggleCamera);

  /// Toggles the widget chat panel (`agil:action toggle-chat`).
  void toggleChat() => _state?._sendAction(AgilAction.toggleChat);

  /// Leaves the call (`agil:action leave`).
  void leave() => _state?._sendAction(AgilAction.leave);

  /// Sends any widget action (`toggle-mic`, `share-screen`, `pip`, …).
  void sendAction(AgilAction action) => _state?._sendAction(action);

  /// Sends a chat message through `agil:chat-send`.
  void sendChat(String text) => _state?._sendChat(text);

  /// Switches light/dark/auto without reloading the WebView (`agil:scheme`).
  void setTheme(AgilThemeScheme scheme) => _state?._sendMessage(AgilBridge.schemeMessage(scheme));

  /// Applies a partial theme patch through `agil:theme`.
  void applyTheme(Map<String, Object?> patch) => _state?._sendThemePatch(patch);

  /// Applies a tenant-config patch through `agil:config`.
  void applyConfig(Map<String, Object?> patch) => _state?._sendConfigPatch(patch);

  /// Sends `agil:ping`; the widget answers with `agil:pong` (no public event).
  void ping() => _state?._sendMessage(AgilBridge.pingMessage());

  /// Reloads the WebView and restarts the ready watchdog.
  void reload() => _state?._reload();
}

/// Hosted AgilFrame widget inside a WebView.
///
/// The component validates [serverUrl]/[roomId]/[joinToken] before loading. On
/// a configuration error it renders a text fallback and reports
/// `invalid-config` (fatal) through [onError]; the token never appears in the
/// message. HTTPS is required except for loopback/dev hosts or when
/// [allowInsecure] is set (development only).
class AgilCall extends StatefulWidget {
  const AgilCall({
    super.key,
    required this.serverUrl,
    required this.roomId,
    this.tenantId = 'demo',
    this.joinToken,
    this.identityToken,
    this.participantName,
    this.role,
    this.theme,
    this.language,
    this.relayOnly = false,
    this.widgetPath = defaultWidgetPath,
    this.allowedOrigins = const <String>[],
    this.safeArea = true,
    this.allowInsecure = false,
    this.readyTimeout = const Duration(seconds: 20),
    this.controller,
    this.onEvent,
    this.onError,
    this.onExternalLink,
    this.backgroundColor = const Color(0xFF080D16),
  });

  /// Base origin of the AgilFrame server, e.g. `https://calls.example.com`.
  /// A subpath (`https://host/calls`) is preserved.
  final String serverUrl;

  /// Room id.
  final String roomId;

  /// Tenant; defaults to `demo`.
  final String tenantId;

  /// Short-lived join token; without it the widget shows its own join screen.
  final String? joinToken;

  /// Corporate OIDC token (`identity_token`).
  final String? identityToken;

  /// Display name used by the widget's join screen.
  final String? participantName;

  /// Role for anonymous joins.
  final AgilRole? role;

  /// Theme scheme only; the full theme comes from the server.
  final AgilThemeScheme? theme;

  /// UI locale.
  final AgilLanguage? language;

  /// Force TURN-only media (`relay=1`).
  final bool relayOnly;

  /// Page path relative to [serverUrl]; `/embed.html` is root-relative.
  final String widgetPath;

  /// Additional exact origins allowed by the navigation guard (SSO, …).
  final List<String> allowedOrigins;

  /// Wraps the WebView in [SafeArea] (Android WebView ignores CSS
  /// `env(safe-area-inset-*)`).
  final bool safeArea;

  /// Allows plain `http://` for non-loopback hosts. Development only.
  final bool allowInsecure;

  /// How long to wait for `agil:ready`; [Duration.zero] disables the watchdog.
  final Duration readyTimeout;

  /// Optional imperative handle.
  final AgilCallController? controller;

  /// All call events.
  final AgilCallEventCallback? onEvent;

  /// Load/bridge/navigation/permission errors. Widget errors arrive here and
  /// as [AgilErrorEvent] through [onEvent].
  final AgilCallErrorCallback? onError;

  /// Called when the WebView tries to navigate outside the widget origin.
  final AgilExternalLinkCallback? onExternalLink;

  /// WebView background behind the widget (`#080d16` — the widget shell color).
  final Color backgroundColor;

  @override
  State<AgilCall> createState() => _AgilCallState();
}

class _AgilCallState extends State<AgilCall> with WidgetsBindingObserver {
  WebViewController? _webView;
  android.InAppWebViewController? _androidView;
  int _androidViewRevision = 0;
  bool get _usesAndroidView => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  String? _url;
  String? _origin;
  AgilCallError? _configError;
  AgilCallError? _reportedConfigError;

  bool _ready = false;
  bool _disposed = false;
  final String _bridgeNonce = _createBridgeNonce();
  final List<Map<String, Object?>> _queue = <Map<String, Object?>>[];
  Timer? _readyTimer;
  Timer? _shimRetry;

  @override
  void initState() {
    super.initState();
    if (_usesAndroidView) WidgetsBinding.instance.addObserver(this);
    _applyWidgetConfig();
    widget.controller?._state = this;
    if (_configError != null) {
      _reportConfigError();
    } else {
      _createWebView();
      _startReadyTimer();
    }
  }

  @override
  void didUpdateWidget(AgilCall oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      if (identical(oldWidget.controller?._state, this)) oldWidget.controller?._state = null;
      widget.controller?._state = this;
    }
    final String? previousUrl = _url;
    _applyWidgetConfig();
    _reportConfigError();
    if (_url != previousUrl) {
      _ready = false;
      _queue.clear();
      _androidView = null;
      _androidViewRevision += 1;
      if (_url == null) {
        _webView = null;
      } else {
        _createWebView();
        _startReadyTimer();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_usesAndroidView) WidgetsBinding.instance.removeObserver(this);
    _readyTimer?.cancel();
    _shimRetry?.cancel();
    if (identical(widget.controller?._state, this)) widget.controller?._state = null;
    _queue.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final android.InAppWebViewController? controller = _androidView;
    if (state == AppLifecycleState.resumed && controller != null && _isCurrentAndroidView(controller)) {
      unawaited(_resumeAndroidView(controller));
    }
  }

  Future<void> _resumeAndroidView(android.InAppWebViewController controller) async {
    // Resume the platform view without rebuilding the page or the active call.
    try {
      await controller.resume();
    } catch (error) {
      if (_isCurrentAndroidView(controller)) {
        debugPrint('AgilFrame Android WebView resume failed (${error.runtimeType}).');
      }
    }
  }

  /// Validates the configuration and builds the widget URL.
  void _applyWidgetConfig() {
    try {
      _url = buildWidgetUrl(
        AgilCallUrlOptions(
          serverUrl: widget.serverUrl,
          roomId: widget.roomId,
          joinToken: widget.joinToken,
          tenantId: widget.tenantId,
          participantName: widget.participantName,
          role: widget.role,
          language: widget.language,
          theme: widget.theme,
          identityToken: widget.identityToken,
          relayOnly: widget.relayOnly,
          widgetPath: widget.widgetPath,
          allowInsecure: widget.allowInsecure,
        ),
      );
      _origin = serverOrigin(widget.serverUrl);
      _configError = null;
    } on AgilConfigException catch (error) {
      _url = null;
      _origin = null;
      _configError = AgilCallError(
        code: AgilCallErrorCode.invalidConfig,
        message: error.message,
        fatal: true,
        details: error.field == null ? const <String, Object?>{} : <String, Object?>{'field': error.field},
      );
    }
  }

  /// Emits a configuration error once per distinct failed configuration.
  void _reportConfigError() {
    final AgilCallError? error = _configError;
    if (error == null) {
      _reportedConfigError = null;
      return;
    }
    final AgilCallError? reported = _reportedConfigError;
    if (reported != null && reported.code == error.code && reported.message == error.message) {
      return;
    }
    _reportedConfigError = error;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _emitError(error);
    });
  }

  void _createWebView() {
    if (_usesAndroidView) return;
    unawaited(_setUpWebView());
  }

  Widget _buildAndroidView(String url) {
    final String shim = AgilBridge.createShimScript(origin: _origin, nonce: _bridgeNonce);
    return android.InAppWebView(
      key: ValueKey<int>(_androidViewRevision),
      initialSettings: android.InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        useShouldOverrideUrlLoading: true,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        isInspectable: kDebugMode,
      ),
      initialUserScripts: UnmodifiableListView<android.UserScript>(<android.UserScript>[
        android.UserScript(
          // Buffer the first events until the Android handler becomes available.
          source: 'if(location.origin===${jsonEncode(_origin)}){'
              'var agilPending=[];'
              'window.AgilBridge={postMessage:function(message){'
              'if(window.flutter_inappwebview&&typeof window.flutter_inappwebview.callHandler==="function"){'
              'window.flutter_inappwebview.callHandler("AgilBridge",message);'
              '}else if(agilPending.length<32){agilPending.push(message);}}};'
              'window.addEventListener("flutterInAppWebViewPlatformReady",function(){'
              'agilPending.splice(0).forEach(window.AgilBridge.postMessage);},{once:true});'
              '$shim}',
          injectionTime: android.UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
        ),
      ]),
      onWebViewCreated: (android.InAppWebViewController controller) {
        if (_disposed || url != _url) return;
        _androidView = controller;
        controller.addJavaScriptHandler(handlerName: 'AgilBridge', callback: (List<dynamic> args) {
          if (identical(_androidView, controller) && args.length == 1 && args.first is String) {
            _handleChannelPayload(args.first as String);
          }
        });
        unawaited(_load(url));
      },
      shouldOverrideUrlLoading: (_, android.NavigationAction action) async {
        final NavigationDecision decision = _handleNavigationRequest(NavigationRequest(
          url: action.request.url?.toString() ?? '',
          isMainFrame: action.isForMainFrame,
        ));
        return decision == NavigationDecision.navigate
            ? android.NavigationActionPolicy.ALLOW
            : android.NavigationActionPolicy.CANCEL;
      },
      onLoadStart: (android.InAppWebViewController controller, android.WebUri? page) {
        if (_isCurrentAndroidView(controller)) _ready = false;
      },
      onReceivedError: (_, android.WebResourceRequest request, android.WebResourceError error) {
        if (request.isForMainFrame != true || url != _url) return;
        _emitError(AgilCallError(
          code: AgilCallErrorCode.loadFailed,
          message: _truncate(redactTokenText(error.description), 500),
          url: redactCallUrl(request.url.toString()),
          fatal: true,
        ));
      },
      onReceivedHttpError: (_, android.WebResourceRequest request, android.WebResourceResponse response) {
        if (request.isForMainFrame != true || url != _url) return;
        _emitError(AgilCallError(
          code: AgilCallErrorCode.httpError,
          message: 'The call page returned HTTP ${response.statusCode ?? 'error'}',
          status: response.statusCode,
          url: redactCallUrl(request.url.toString()),
          fatal: true,
        ));
      },
      onPermissionRequest: _handleAndroidPermission,
    );
  }

  bool _isCurrentAndroidView(android.InAppWebViewController controller) =>
      !_disposed && identical(_androidView?.platform, controller.platform);

  Future<android.PermissionResponse> _handleAndroidPermission(
    android.InAppWebViewController controller,
    android.PermissionRequest request,
  ) async {
    const android.PermissionResponseAction denied = android.PermissionResponseAction.DENY;
    final Map<android.PermissionResourceType, Permission> capture = <android.PermissionResourceType, Permission>{
      android.PermissionResourceType.CAMERA: Permission.camera,
      android.PermissionResourceType.MICROPHONE: Permission.microphone,
    };
    String? originOf(String? value) => value == null ? null : Uri.tryParse(value)?.origin;
    final String? expected = _origin;
    try {
      if (expected != null && _isCurrentAndroidView(controller) && originOf(request.origin.toString()) == expected &&
          originOf((await controller.getUrl())?.toString()) == expected &&
          request.resources.isNotEmpty && request.resources.every(capture.containsKey)) {
        final Map<Permission, PermissionStatus> status =
            await request.resources.map((android.PermissionResourceType type) => capture[type]!).toSet().toList().request();
        if (_isCurrentAndroidView(controller) && originOf((await controller.getUrl())?.toString()) == expected) {
          final List<android.PermissionResourceType> granted = request.resources
              .where((android.PermissionResourceType type) => status[capture[type]] == PermissionStatus.granted)
              .toList();
          if (granted.isNotEmpty) {
            return android.PermissionResponse(resources: granted, action: android.PermissionResponseAction.GRANT);
          }
        }
      }
    } catch (_) {
      // Failure to verify the origin or obtain platform permission denies capture.
    }
    return android.PermissionResponse(action: denied);
  }

  /// Creates the platform WebView and installs the bridge/channel *before*
  /// loading the page: the JavaScript channel must exist when the widget's
  /// first script runs.
  Future<void> _setUpWebView() async {
    final String? url = _url;
    if (url == null) return;
    final WebViewController controller = WebViewController();
    _webView = controller;
    try {
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(widget.backgroundColor);
      await controller.addJavaScriptChannel('AgilBridge', onMessageReceived: _handleChannelMessage);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _handleNavigationRequest,
          onPageStarted: _handlePageStarted,
          onPageFinished: _handlePageFinished,
          onWebResourceError: _handleResourceError,
          onHttpError: _handleHttpError,
        ),
      );
    } catch (error) {
      _emitError(
        AgilCallError(
          code: AgilCallErrorCode.bridgeError,
          message: redactTokenText(_errorText(error)),
          fatal: true,
        ),
      );
      return;
    }
    if (_disposed || _url != url) return;
    await _load(url);
  }

  Future<void> _load(String url) async {
    final WebViewController? web = _webView;
    final android.InAppWebViewController? androidView = _androidView;
    try {
      if (androidView != null) {
        await androidView.loadUrl(urlRequest: android.URLRequest(url: android.WebUri(url)));
      } else if (web != null) {
        await web.loadRequest(Uri.parse(url));
      }
    } catch (error) {
      _emitError(
        AgilCallError(
          code: AgilCallErrorCode.loadFailed,
          message: redactTokenText(_errorText(error)),
          fatal: true,
        ),
      );
    }
  }

  void _startReadyTimer() {
    _readyTimer?.cancel();
    if (widget.readyTimeout <= Duration.zero) return;
    _readyTimer = Timer(widget.readyTimeout, () {
      if (_disposed || _ready) return;
      _emitError(
        AgilCallError(
          code: AgilCallErrorCode.timeout,
          message: 'The call widget did not signal ready within '
              '${widget.readyTimeout.inMilliseconds} ms',
          fatal: true,
        ),
      );
    });
  }

  void _markReady() {
    if (_ready) return;
    _ready = true;
    _readyTimer?.cancel();
    _readyTimer = null;
    _flushQueue();
  }

  void _flushQueue() {
    if (_queue.isEmpty) return;
    final List<Map<String, Object?>> queued = List<Map<String, Object?>>.of(_queue);
    _queue.clear();
    for (final Map<String, Object?> message in queued) {
      _runScript(AgilBridge.createHostMessageScript(message));
    }
  }

  void _sendMessage(Map<String, Object?> message) {
    if (_url == null) return;
    if (!_ready) {
      if (_queue.length >= agilBridgeMaxQueuedMessages) {
        _emitError(
          const AgilCallError(
            code: AgilCallErrorCode.bridgeError,
            message: 'Bridge message queue is full; the widget has not signalled ready',
          ),
        );
        return;
      }
      _queue.add(message);
      return;
    }
    _runScript(AgilBridge.createHostMessageScript(message));
  }

  void _sendAction(AgilAction action) => _sendMessage(AgilBridge.actionMessage(action));

  void _sendChat(String text) {
    try {
      _sendMessage(AgilBridge.chatMessage(text));
    } on ArgumentError catch (error) {
      _emitError(
        AgilCallError(
          code: AgilCallErrorCode.invalidConfig,
          message: '${error.message}',
        ),
      );
    }
  }

  void _sendThemePatch(Map<String, Object?> patch) {
    try {
      _sendMessage(AgilBridge.themeMessage(patch));
    } on ArgumentError catch (error) {
      _emitError(
        AgilCallError(code: AgilCallErrorCode.invalidConfig, message: '${error.message}'),
      );
    }
  }

  void _sendConfigPatch(Map<String, Object?> patch) {
    try {
      _sendMessage(AgilBridge.configMessage(patch));
    } on ArgumentError catch (error) {
      _emitError(
        AgilCallError(code: AgilCallErrorCode.invalidConfig, message: '${error.message}'),
      );
    }
  }

  void _reload() {
    if (_url == null) return;
    _ready = false;
    _queue.clear();
    final WebViewController? web = _webView;
    final android.InAppWebViewController? androidView = _androidView;
    if (androidView != null) {
      unawaited(_reloadView(androidView.reload));
    } else if (web == null) {
      _createWebView();
    } else {
      unawaited(_reloadView(web.reload));
    }
    _startReadyTimer();
  }

  Future<void> _reloadView(Future<void> Function() reload) async {
    try {
      await reload();
    } catch (error) {
      _emitError(
        AgilCallError(
          code: AgilCallErrorCode.loadFailed,
          message: redactTokenText(_errorText(error)),
          fatal: true,
        ),
      );
    }
  }

  void _runScript(String script) {
    final WebViewController? web = _webView;
    final android.InAppWebViewController? androidView = _androidView;
    if (web == null && androidView == null) return;
    final Future<void> run = androidView != null
        ? androidView.evaluateJavascript(source: script).then<void>((_) {})
        : web!.runJavaScript(script);
    unawaited(
      run.catchError((Object error) {
        _emitError(
          AgilCallError(
            code: AgilCallErrorCode.bridgeError,
            message: redactTokenText(_errorText(error)),
          ),
        );
      }),
    );
  }

  void _injectShim() {
    _runScript(AgilBridge.createShimScript(origin: _origin, nonce: _bridgeNonce));
  }

  List<String> get _secrets => <String>[
        if (widget.joinToken != null && widget.joinToken!.isNotEmpty) widget.joinToken!,
        if (widget.identityToken != null && widget.identityToken!.isNotEmpty)
          widget.identityToken!,
      ];

  void _handleChannelMessage(JavaScriptMessage message) => _handleChannelPayload(message.message);

  void _handleChannelPayload(String raw) {
    // The channel is page-global; only the widget-origin shim knows the
    // per-load nonce. Direct posts from an allowed SSO page are rejected.
    final String? payload = AgilBridge.unwrapBridgeEnvelope(raw, _bridgeNonce);
    if (payload == null) {
      if (raw.contains('"agil:')) {
        _emitError(
          const AgilCallError(
            code: AgilCallErrorCode.bridgeError,
            message: 'Ignored a bridge message from an untrusted page',
          ),
        );
      }
      return;
    }
    final AgilCallEvent? event =
        AgilBridge.parseWidgetMessage(payload, secrets: _secrets);
    if (event == null) {
      if (payload.contains('"agil:')) {
        _emitError(
          const AgilCallError(
            code: AgilCallErrorCode.bridgeError,
            message: 'Ignored a malformed or unsupported bridge message',
          ),
        );
      }
      return;
    }
    // Any bridge message proves the shim is alive; flush buffered commands even
    // if `agil:ready` itself was posted before the shim was installed.
    _markReady();
    if (event is AgilErrorEvent) {
      _emitError(event.error);
    }
    if (!_disposed) widget.onEvent?.call(event);
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    final String url = request.url;
    if (isAllowedNavigation(
      url,
      serverUrl: widget.serverUrl,
      allowedOrigins: widget.allowedOrigins,
    )) {
      return NavigationDecision.navigate;
    }
    final String redacted = redactCallUrl(url);
    if (request.isMainFrame) {
      final String lower = url.toLowerCase();
      if (lower.startsWith('http://') || lower.startsWith('https://')) {
        try {
          widget.onExternalLink?.call(url);
        } catch (_) {
          // A host callback failure must not crash the navigation guard.
        }
      }
      _emitError(
        AgilCallError(
          code: AgilCallErrorCode.navigationBlocked,
          message: 'Blocked navigation to ${redacted.isEmpty ? 'an unsupported URL' : redacted}',
          url: redacted.isEmpty ? null : redacted,
        ),
      );
    }
    return NavigationDecision.prevent;
  }

  void _handlePageStarted(String url) {
    _ready = false;
    _injectShim();
    _shimRetry?.cancel();
    _shimRetry = Timer(const Duration(milliseconds: 250), () {
      if (!_disposed) _injectShim();
    });
  }

  void _handlePageFinished(String url) {
    // Safety net for platforms where the page-start injection ran before the
    // document existed.
    _injectShim();
  }

  void _handleResourceError(WebResourceError error) {
    if (error.isForMainFrame == false) return;
    final String? url = error.url == null ? null : redactCallUrl(error.url!);
    _emitError(
      AgilCallError(
        code: AgilCallErrorCode.loadFailed,
        message: _truncate(redactTokenText(error.description), 500),
        fatal: true,
        url: url,
        details: <String, Object?>{'errorCode': error.errorCode},
      ),
    );
  }

  void _handleHttpError(HttpResponseError error) {
    final int? status = error.response?.statusCode;
    final Uri? uri = error.response?.uri;
    _emitError(
      AgilCallError(
        code: AgilCallErrorCode.httpError,
        message: 'The call page returned HTTP ${status ?? 'error'}',
        fatal: true,
        status: status,
        url: uri == null ? null : redactCallUrl(uri.toString()),
      ),
    );
  }

  void _emitError(AgilCallError error) {
    if (_disposed) return;
    try {
      widget.onError?.call(error);
    } catch (_) {
      // Host callbacks must never break the bridge/guard.
    }
  }

  @override
  Widget build(BuildContext context) {
    final AgilCallError? configError = _configError;
    if (configError != null) {
      return ColoredBox(
        color: widget.backgroundColor,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'AgilFrame: ${configError.message}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFF8FAFC), fontSize: 15, height: 1.4),
            ),
          ),
        ),
      );
    }
    final WebViewController? web = _webView;
    final String? url = _url;
    if (_usesAndroidView && url != null) {
      final Widget view = ColoredBox(color: widget.backgroundColor, child: _buildAndroidView(url));
      return widget.safeArea ? SafeArea(child: view) : view;
    }
    if (web == null) {
      return ColoredBox(color: widget.backgroundColor, child: const SizedBox.expand());
    }
    final Widget view = ColoredBox(
      color: widget.backgroundColor,
      child: WebViewWidget(controller: web),
    );
    return widget.safeArea ? SafeArea(child: view) : view;
  }
}

String _errorText(Object error) => error.toString();

String _truncate(String value, int max) =>
    value.length > max ? '${value.substring(0, max)}…' : value;

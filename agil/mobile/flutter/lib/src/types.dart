/// Public, platform-agnostic types of the `agil_calls` Flutter SDK.
///
/// Everything in this file is pure Dart: no `flutter`, no `webview_flutter`.
/// The URL builder/parser ([url.dart]) and the bridge ([bridge.dart]) use these
/// types, so the security-critical logic can be unit-tested without a device.
///
/// The wire contract mirrors the hosted widget `/embed.html` (see
/// `docs/contract.md` §7) and `@agil/calls-react-native`:
///   out: `agil:ready`, `agil:event`, `agil:chat`, `agil:state`,
///        `agil:minimized`, `agil:fullscreen`, `agil:pong`;
///   in:  `agil:action`, `agil:chat-send`, `agil:scheme`, `agil:theme`,
///        `agil:config`, `agil:ping`.
library;

/// UI locale supported by the hosted widget (`lang=` URL parameter).
enum AgilLanguage {
  ru('ru'),
  en('en');

  const AgilLanguage(this.wire);

  /// Value written to the `lang` query parameter.
  final String wire;

  /// Parses a widget/link value; returns `null` for anything unsupported.
  static AgilLanguage? tryParse(Object? value) {
    return switch (value) {
      'ru' => AgilLanguage.ru,
      'en' => AgilLanguage.en,
      _ => null,
    };
  }
}

/// Theme scheme understood by `embed.html` (`theme=`); the full theme lives on
/// the server and can be patched at runtime through `agil:theme`.
enum AgilThemeScheme {
  light('light'),
  dark('dark'),
  auto('auto');

  const AgilThemeScheme(this.wire);

  /// Value written to the `theme` query parameter and to `agil:scheme`.
  final String wire;

  static AgilThemeScheme? tryParse(Object? value) {
    return switch (value) {
      'light' => AgilThemeScheme.light,
      'dark' => AgilThemeScheme.dark,
      'auto' => AgilThemeScheme.auto,
      _ => null,
    };
  }
}

/// Role used for anonymous (token-less) joins (`role=`).
enum AgilRole {
  host('host'),
  moderator('moderator'),
  guest('guest');

  const AgilRole(this.wire);

  final String wire;

  static AgilRole? tryParse(Object? value) {
    return switch (value) {
      'host' => AgilRole.host,
      'moderator' => AgilRole.moderator,
      'guest' => AgilRole.guest,
      _ => null,
    };
  }
}

/// Actions accepted by the widget's iframe bridge (`agil:action`).
///
/// `embed.html` answers unknown/forbidden actions with
/// `agil:event {event:'action-denied'}`.
enum AgilAction {
  toggleMic('toggle-mic'),
  toggleCamera('toggle-camera'),
  toggleChat('toggle-chat'),
  shareScreen('share-screen'),
  blurOn('blur-on'),
  blurOff('blur-off'),
  minimize('minimize'),
  restore('restore'),
  pip('pip'),
  fullscreen('fullscreen'),
  newtab('newtab'),
  leave('leave');

  const AgilAction(this.wire);

  final String wire;

  static AgilAction? tryParse(Object? value) {
    if (value is! String) return null;
    for (final action in AgilAction.values) {
      if (action.wire == value) return action;
    }
    return null;
  }
}

/// Capability flags reported by the widget in `agil:ready`.
class AgilCapabilities {
  const AgilCapabilities({
    this.media = false,
    this.blur = false,
    this.screenShare = false,
    this.captions = false,
    this.recording = false,
  });

  /// Reads capabilities defensively: anything that is not `true` is `false`.
  factory AgilCapabilities.fromJson(Object? value) {
    final map = value is Map<Object?, Object?> ? value : const <Object?, Object?>{};
    bool flag(String key) => map[key] == true;
    return AgilCapabilities(
      media: flag('media'),
      blur: flag('blur'),
      screenShare: flag('screenShare'),
      captions: flag('captions'),
      recording: flag('recording'),
    );
  }

  final bool media;
  final bool blur;
  final bool screenShare;
  final bool captions;
  final bool recording;

  Map<String, Object?> toJson() => <String, Object?>{
        'media': media,
        'blur': blur,
        'screenShare': screenShare,
        'captions': captions,
        'recording': recording,
      };

  @override
  String toString() => 'AgilCapabilities(media: $media, blur: $blur, '
      'screenShare: $screenShare, captions: $captions, recording: $recording)';
}

/// One chat message emitted by the widget (`agil:chat`).
///
/// The shape mirrors `@agil/protocol`'s `ChatMessage`; extra fields are kept
/// in [raw] after bridge sanitization.
class AgilChatMessage {
  const AgilChatMessage({
    required this.text,
    this.id,
    this.participantId,
    this.participantName,
    this.ts,
    this.raw = const <String, Object?>{},
  });

  /// Returns `null` when the payload has no usable text.
  static AgilChatMessage? fromJson(Object? value) {
    if (value is! Map<Object?, Object?>) return null;
    final text = value['text'];
    if (text is! String || text.isEmpty) return null;
    final raw = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String && key != '__proto__' && key != 'constructor' && key != 'prototype') {
        raw[key] = entry.value;
      }
    }
    return AgilChatMessage(
      text: text,
      id: _stringOrNull(value['id']),
      participantId: _stringOrNull(value['participantId']),
      participantName: _stringOrNull(value['participantName']),
      ts: _numOrNull(value['ts']),
      raw: raw,
    );
  }

  final String text;
  final String? id;
  final String? participantId;
  final String? participantName;
  final num? ts;

  /// Sanitized payload as received (may contain extra tenant-specific fields).
  final Map<String, Object?> raw;
}

/// Snapshot periodically posted by `embed.html` as `agil:state`.
///
/// Only stable, documented fields are typed; the full payload stays in [raw].
class AgilCallSnapshot {
  const AgilCallSnapshot({
    this.phase,
    this.participants,
    this.participantIds = const <String>[],
    this.qualityTier,
    this.qualityScore,
    this.connectionState,
    this.recording = false,
    this.minimized = false,
    this.chatMode,
    this.fullscreen = false,
    this.micEnabled,
    this.cameraEnabled,
    this.screenSharing,
    this.blurMode,
    this.panel,
    this.raw = const <String, Object?>{},
  });

  static AgilCallSnapshot? fromJson(Object? value) {
    if (value is! Map<Object?, Object?>) return null;
    final quality = value['quality'];
    final settings = value['settings'];
    Map<Object?, Object?> asMap(Object? input) =>
        input is Map<Object?, Object?> ? input : const <Object?, Object?>{};
    final qualityMap = asMap(quality);
    final settingsMap = asMap(settings);
    final raw = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String) raw[key] = entry.value;
    }
    return AgilCallSnapshot(
      phase: _stringOrNull(value['phase']),
      participants: _intOrNull(value['participants']),
      participantIds: _stringList(value['participantIds']),
      qualityTier: _stringOrNull(qualityMap['tier']),
      qualityScore: _numOrNull(qualityMap['score']),
      connectionState: _stringOrNull(value['connectionState']),
      recording: value['recording'] == true,
      minimized: value['minimized'] == true,
      chatMode: _stringOrNull(value['chatMode']),
      fullscreen: value['fullscreen'] == true,
      micEnabled: _boolOrNull(settingsMap['mic']),
      cameraEnabled: _boolOrNull(settingsMap['camera']),
      screenSharing: _boolOrNull(settingsMap['screen']),
      blurMode: _stringOrNull(settingsMap['blur']),
      panel: _stringOrNull(settingsMap['panel']),
      raw: raw,
    );
  }

  final String? phase;
  final int? participants;
  final List<String> participantIds;
  final String? qualityTier;
  final num? qualityScore;
  final String? connectionState;
  final bool recording;
  final bool minimized;
  final String? chatMode;
  final bool fullscreen;

  /// `settings.mic` — microphone on, as reported by the widget.
  final bool? micEnabled;

  /// `settings.camera` — camera on, as reported by the widget.
  final bool? cameraEnabled;

  /// `settings.screen` — screen sharing on, as reported by the widget.
  final bool? screenSharing;

  /// `settings.blur` — `off`, `blur` or `replace`.
  final String? blurMode;

  /// `settings.panel` — open side panel, if any.
  final String? panel;

  final Map<String, Object?> raw;
}

/// Error categories surfaced to the host app.
enum AgilCallErrorCode {
  invalidConfig('invalid-config'),
  permissionDenied('permission-denied'),
  loadFailed('load-failed'),
  httpError('http-error'),
  navigationBlocked('navigation-blocked'),
  renderProcessGone('render-process-gone'),
  bridgeError('bridge-error'),
  widgetError('widget-error'),
  timeout('timeout');

  const AgilCallErrorCode(this.wire);

  /// Stable machine-readable code (same strings as `@agil/calls-react-native`).
  final String wire;
}

/// Error delivered to `onError`.
///
/// [fatal] means the call cannot proceed without a host action (fix config,
/// reload the WebView or grant a permission). Non-fatal errors are
/// informational: the widget usually keeps working (a denied camera falls back
/// to listen-only mode).
class AgilCallError {
  const AgilCallError({
    required this.code,
    required this.message,
    this.fatal = false,
    this.status,
    this.widgetCode,
    this.url,
    this.details = const <String, Object?>{},
  });

  final AgilCallErrorCode code;
  final String message;
  final bool fatal;

  /// HTTP status for [AgilCallErrorCode.httpError].
  final int? status;

  /// Original widget error code for [AgilCallErrorCode.widgetError].
  final String? widgetCode;

  /// Redacted URL (never contains `token`/`identity_token`).
  final String? url;

  /// Extra structured details; values are bridge-sanitized.
  final Map<String, Object?> details;

  @override
  String toString() => 'AgilCallError(${code.wire}, fatal: $fatal): $message';
}

/// Base class of all call events delivered to `onEvent`.
sealed class AgilCallEvent {
  const AgilCallEvent();
}

/// Widget mounted and the bridge is alive (`agil:ready`).
final class AgilReadyEvent extends AgilCallEvent {
  const AgilReadyEvent({required this.capabilities, this.room, this.server});

  final AgilCapabilities capabilities;
  final String? room;
  final String? server;
}

/// Participant joined the room (`agil:event {event:'joined'}`).
final class AgilJoinedEvent extends AgilCallEvent {
  const AgilJoinedEvent({this.payload});

  final Object? payload;
}

/// Participant left the room (`agil:event {event:'left'}`).
final class AgilLeftEvent extends AgilCallEvent {
  const AgilLeftEvent({this.payload});

  final Object? payload;
}

/// Chat message received (`agil:chat`).
final class AgilChatEvent extends AgilCallEvent {
  const AgilChatEvent({required this.message});

  final AgilChatMessage message;
}

/// The widget reported an error (`agil:event {event:'error'}`).
final class AgilErrorEvent extends AgilCallEvent {
  const AgilErrorEvent({required this.error});

  final AgilCallError error;
}

/// Call state snapshot (`agil:state`).
final class AgilStateEvent extends AgilCallEvent {
  const AgilStateEvent({required this.state});

  final AgilCallSnapshot state;
}

/// Mini-mode changed (`agil:minimized`).
final class AgilMinimizedEvent extends AgilCallEvent {
  const AgilMinimizedEvent({required this.minimized});

  final bool minimized;
}

/// Fullscreen changed (`agil:fullscreen`).
final class AgilFullscreenEvent extends AgilCallEvent {
  const AgilFullscreenEvent({required this.fullscreen});

  final bool fullscreen;
}

/// Any other `agil:event` (`participant-joined`, `quality-changed`,
/// `connection-state`, `action-denied`, …).
final class AgilGenericEvent extends AgilCallEvent {
  const AgilGenericEvent({required this.name, this.payload});

  final String name;
  final Object? payload;
}

/// Parsed `agilcalls://call?...` deep link or `https://…/embed.html?...` URL.
class AgilCallLink {
  const AgilCallLink({
    required this.kind,
    required this.serverUrl,
    required this.roomId,
    this.joinToken,
    this.tenantId,
    this.participantName,
    this.language,
    this.theme,
    this.role,
    this.identityToken,
    this.relayOnly = false,
  });

  /// `embed` for an http(s) widget URL, `deep-link` for a custom app scheme.
  final String kind;
  final String serverUrl;
  final String roomId;
  final String? joinToken;
  final String? tenantId;
  final String? participantName;
  final AgilLanguage? language;
  final AgilThemeScheme? theme;
  final AgilRole? role;
  final String? identityToken;
  final bool relayOnly;
}

String? _stringOrNull(Object? value) => value is String && value.isNotEmpty ? value : null;

num? _numOrNull(Object? value) => value is num ? value : null;

int? _intOrNull(Object? value) => value is int ? value : (value is double ? value.toInt() : null);

bool? _boolOrNull(Object? value) => value is bool ? value : null;

List<String> _stringList(Object? value) {
  if (value is! List<Object?>) return const <String>[];
  return <String>[
    for (final item in value)
      if (item is String && item.isNotEmpty) item,
  ];
}

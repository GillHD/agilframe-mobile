/// Defensive postMessage bridge for the hosted AgilFrame widget.
///
/// The hosted `/embed.html` talks to its parent with `agil:*` messages. In a
/// top-level Flutter WebView `window.parent === window`, so the page's
/// `parent.postMessage(...)` would only talk to itself. The injected shim
/// ([AgilBridge.createShimScript]) forwards those messages to the platform
/// JavaScript channel `AgilBridge` (see `AgilBridge.postMessage` in the script)
/// while keeping the page's own same-document listener working.
///
/// All parsing is defensive: malformed, oversized and hostile payloads are
/// rejected or sanitized; nothing here trusts WebView content.
///
/// Pure Dart: no Flutter imports, so the parser is unit-testable on a VM.
library;

import 'dart:convert';

import 'types.dart';
import 'url.dart';

/// Characters (not bytes) accepted before JSON parsing.
const int agilBridgeMaxChars = 262144;

/// Host→widget messages buffered until the widget reports `agil:ready`.
const int agilBridgeMaxQueuedMessages = 50;

/// Maximum chat message length accepted by `agil:chat-send`.
const int agilBridgeMaxChatChars = 4000;

const int _maxWidgetText = 500;
const int _maxWidgetCode = 64;

const Set<String> _forbiddenKeys = <String>{'__proto__', 'prototype', 'constructor'};

final RegExp _eventName = RegExp(r'^[a-z][a-z0-9-]{0,63}$');

/// Sentinel for values that must be dropped (functions, symbols, cycles).
class _Undefined {
  const _Undefined();
}

const _Undefined _undefined = _Undefined();

/// The two-way widget bridge: parser, host-message builders and injected JS.
abstract final class AgilBridge {
  /// Parses a value received from the `AgilBridge` JavaScript channel.
  ///
  /// Accepts a JSON string or an already-decoded map. Returns `null` for
  /// anything that is not a well-formed `agil:*` widget message (including
  /// `agil:pong`, which carries no host-visible event).
  static AgilCallEvent? parseWidgetMessage(
    Object? raw, {
    int maxChars = agilBridgeMaxChars,
    List<String> secrets = const <String>[],
  }) {
    try {
      Object? value = raw;
      if (raw is String) {
        if (raw.length > maxChars) return null;
        value = jsonDecode(raw);
      }
      if (value is! Map<Object?, Object?>) return null;
      final Object? type = value['type'];
      if (type is! String || !type.startsWith('agil:') || type.length > 64) return null;

      switch (type) {
        case 'agil:ready':
          return AgilReadyEvent(
            capabilities: AgilCapabilities.fromJson(value['capabilities']),
            room: _safeString(value['room'], 200),
            server: _safeString(value['server'], 2048),
          );
        case 'agil:event':
          return _parseWidgetEvent(value, secrets);
        case 'agil:chat':
          final AgilChatMessage? message =
              AgilChatMessage.fromJson(sanitizeBridgePayload(value['message']));
          return message == null ? null : AgilChatEvent(message: message);
        case 'agil:state':
          final AgilCallSnapshot? snapshot =
              AgilCallSnapshot.fromJson(sanitizeBridgePayload(value['state']));
          return snapshot == null ? null : AgilStateEvent(state: snapshot);
        case 'agil:minimized':
          return AgilMinimizedEvent(minimized: value['minimized'] == true);
        case 'agil:fullscreen':
          return AgilFullscreenEvent(fullscreen: value['fullscreen'] == true);
        default:
          // `agil:pong` and unknown/future message types carry no public event.
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Converts an untrusted value into a JSON-safe tree.
  ///
  /// Drops functions/symbols/`undefined`, masks prototypes, limits depth and
  /// collection sizes, breaks cycles and turns non-finite numbers into `null`.
  static Object? sanitizeBridgePayload(
    Object? value, {
    int maxDepth = 8,
    int maxArray = 100,
    int maxKeys = 100,
    int maxString = 32768,
  }) {
    final Set<Object> seen = <Object>{};

    Object? walk(Object? input, int depth) {
      if (input == null) return null;
      if (input is String) {
        return input.length > maxString ? '${input.substring(0, maxString)}…' : input;
      }
      if (input is num) {
        if (input is double && !input.isFinite) return null;
        return input;
      }
      if (input is bool) return input;
      if (depth >= maxDepth) return null;
      if (input is List<Object?>) {
        if (!seen.add(input)) return null;
        try {
          final int length = input.length < maxArray ? input.length : maxArray;
          return <Object?>[
            for (int index = 0; index < length; index += 1)
              _nullForUndefined(walk(input[index], depth + 1)),
          ];
        } finally {
          seen.remove(input);
        }
      }
      if (input is Map<Object?, Object?>) {
        if (!seen.add(input)) return null;
        try {
          final Map<String, Object?> result = <String, Object?>{};
          int count = 0;
          for (final MapEntry<Object?, Object?> entry in input.entries) {
            if (count >= maxKeys) break;
            final Object? key = entry.key;
            if (key is! String || _forbiddenKeys.contains(key)) continue;
            final Object? item = walk(entry.value, depth + 1);
            if (!identical(item, _undefined)) {
              result[key] = item;
              count += 1;
            }
          }
          return result;
        } finally {
          seen.remove(input);
        }
      }
      return _undefined;
    }

    final Object? result = walk(value, 0);
    return identical(result, _undefined) ? null : result;
  }

  /// `{type:'agil:action', action:'toggle-mic'}`.
  static Map<String, Object?> actionMessage(AgilAction action) =>
      <String, Object?>{'type': 'agil:action', 'action': action.wire};

  /// `{type:'agil:chat-send', text}`.
  ///
  /// Throws [ArgumentError] for empty/oversized input (programming error, not a
  /// widget error); the widget also truncates at 4000 characters server-side.
  static Map<String, Object?> chatMessage(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(text, 'text', 'Chat text must be a non-empty string');
    }
    final String value = text.length > agilBridgeMaxChatChars
        ? text.substring(0, agilBridgeMaxChatChars)
        : text;
    return <String, Object?>{'type': 'agil:chat-send', 'text': value};
  }

  /// `{type:'agil:scheme', scheme:'light'|'dark'|'auto'}`.
  static Map<String, Object?> schemeMessage(AgilThemeScheme scheme) =>
      <String, Object?>{'type': 'agil:scheme', 'scheme': scheme.wire};

  /// `{type:'agil:theme', theme:{…}}` — a partial theme patch.
  static Map<String, Object?> themeMessage(Map<String, Object?> patch) {
    final Object? sanitized = sanitizeBridgePayload(
      patch,
      maxDepth: 12,
      maxKeys: 500,
      maxArray: 500,
      maxString: 8192,
    );
    if (sanitized is! Map<String, Object?> || sanitized.isEmpty) {
      throw ArgumentError.value(patch, 'patch', 'Theme patch must be a non-empty object');
    }
    return <String, Object?>{'type': 'agil:theme', 'theme': sanitized};
  }

  /// `{type:'agil:config', config:{…}}` — a partial tenant-config patch.
  static Map<String, Object?> configMessage(Map<String, Object?> patch) {
    final Object? sanitized = sanitizeBridgePayload(
      patch,
      maxDepth: 12,
      maxKeys: 500,
      maxArray: 500,
      maxString: 8192,
    );
    if (sanitized is! Map<String, Object?> || sanitized.isEmpty) {
      throw ArgumentError.value(patch, 'patch', 'Config patch must be a non-empty object');
    }
    return <String, Object?>{'type': 'agil:config', 'config': sanitized};
  }

  /// `{type:'agil:ping'}`; the widget answers with `agil:pong`.
  static Map<String, Object?> pingMessage() => <String, Object?>{'type': 'agil:ping'};

  /// Builds a script that delivers a host message to the page's
  /// `message` listener through the shim's saved original `postMessage`.
  static String createHostMessageScript(Map<String, Object?> message) {
    final String json = _jsonForScript(message);
    return '(function(){try{'
        'var p=window.__agilFlutterPostToPage||window.postMessage;'
        'if(typeof p!=="function"){return;}'
        'p.call(window,$json,window.location.origin);'
        '}catch(e){}})();true;';
  }

  /// Script injected into the page (on start and as a load-finished retry).
  ///
  /// It overrides `window.parent.postMessage` so the widget's outgoing
  /// `agil:*` messages reach the native `AgilBridge.postMessage` channel, while
  /// the original same-document dispatch keeps working (the widget's own
  /// `message` listener relies on it). It is idempotent and does nothing when
  /// the channel is missing (plain browser usage).
  static String createShimScript({String? origin, String? nonce}) {
    final String originGuard = origin == null || origin.isEmpty
        ? ''
        : 'if(w.location.origin!==${_jsonForScript(origin)}){return;}';
    final String nonceLiteral =
        nonce == null || nonce.isEmpty ? 'null' : _jsonForScript(nonce);
    return '(function(){try{'
        'var w=window;'
        '$originGuard'
        'if(!w||w.__agilFlutterBridgeInstalled){return;}'
        'var channel=w.AgilBridge;'
        'if(!channel||typeof channel.postMessage!=="function"){return;}'
        'var nonce=$nonceLiteral;'
        'var original=w.parent.postMessage;'
        'if(typeof original!=="function"){return;}'
        'var forward=function(message,targetOrigin){'
        'try{'
        'var text=typeof message==="string"?message:JSON.stringify(message);'
        'channel.postMessage(nonce?JSON.stringify({__agilBridgeNonce:nonce,message:text}):text);'
        '}catch(e){}'
        'try{return original.call(w.parent,message,targetOrigin||w.location.origin);}catch(e){}'
        '};'
        'var installed=false;'
        'try{w.parent.postMessage=forward;installed=w.parent.postMessage===forward;}catch(e){}'
        'if(!installed){try{Object.defineProperty(w.parent,"postMessage",'
        '{value:forward,writable:true,configurable:true});'
        'installed=w.parent.postMessage===forward;}catch(e2){}}'
        'if(installed){w.__agilFlutterPostToPage=original;w.__agilFlutterBridgeInstalled=true;}'
        '}catch(e){}})();true;';
  }

  static AgilCallEvent? _parseWidgetEvent(
    Map<Object?, Object?> value,
    List<String> secrets,
  ) {
    final Object? event = value['event'];
    if (event is! String || !_eventName.hasMatch(event)) return null;
    final Object? payload = sanitizeBridgePayload(value['payload']);
    switch (event) {
      case 'joined':
        return AgilJoinedEvent(payload: payload);
      case 'left':
        return AgilLeftEvent(payload: payload);
      case 'error':
        return AgilErrorEvent(error: _widgetError(payload, secrets));
      default:
        // The event name is already validated and length-limited by `_eventName`.
        return AgilGenericEvent(name: event, payload: payload);
    }
  }

  static AgilCallError _widgetError(Object? payload, List<String> secrets) {
    final Map<Object?, Object?> record =
        payload is Map<Object?, Object?> ? payload : const <Object?, Object?>{};
    final String code =
        redactSecrets(_safeString(record['code'], _maxWidgetCode) ?? 'widget_error', secrets);
    final String message = redactSecrets(
      _safeString(record['message'], _maxWidgetText) ?? 'The widget reported an error',
      secrets,
    );
    return AgilCallError(
      code: AgilCallErrorCode.widgetError,
      message: message,
      widgetCode: code,
    );
  }

  /// Extracts the widget payload from the nonce envelope written by the shim.
  ///
  /// Every JavaScript channel is page-global. The shim embeds a per-load nonce
  /// that is not reachable from other origins/pages, so a direct
  /// `AgilBridge.postMessage(...)` from an allowed SSO page is rejected.
  static String? unwrapBridgeEnvelope(Object? raw, String? nonce) {
    if (nonce == null || nonce.isEmpty) return raw is String ? raw : null;
    if (raw is! String || raw.length > agilBridgeMaxChars + 1024) return null;
    try {
      final Object? value = jsonDecode(raw);
      if (value is! Map<Object?, Object?>) return null;
      if (value['__agilBridgeNonce'] != nonce) return null;
      final Object? message = value['message'];
      return message is String ? message : null;
    } catch (_) {
      return null;
    }
  }
}

Object? _nullForUndefined(Object? value) => identical(value, _undefined) ? null : value;

String? _safeString(Object? value, int max) {  if (value is! String || value.isEmpty) return null;
  return value.length > max ? value.substring(0, max) : value;
}

String _jsonForScript(Object? value) {
  final String json = jsonEncode(value);
  return json
      .replaceAll('<', r'\u003c')
      .replaceAll('>', r'\u003e')
      .replaceAll('&', r'\u0026')
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');
}

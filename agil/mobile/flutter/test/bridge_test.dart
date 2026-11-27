import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:agil_calls/src/bridge.dart';
import 'package:agil_calls/src/types.dart';

void main() {
  group('parseWidgetMessage', () {
    test('parses agil:ready with capabilities and room metadata', () {
      final AgilCallEvent? event = AgilBridge.parseWidgetMessage(
        jsonEncode(<String, Object?>{
          'type': 'agil:ready',
          'capabilities': <String, Object?>{
            'media': true,
            'blur': true,
            'screenShare': false,
            'captions': true,
            'recording': false,
          },
          'room': 'daily-sync',
          'server': 'https://calls.example.com',
        }),
      );
      expect(event, isA<AgilReadyEvent>());
      final AgilReadyEvent ready = event! as AgilReadyEvent;
      expect(ready.capabilities.media, isTrue);
      expect(ready.capabilities.blur, isTrue);
      expect(ready.capabilities.screenShare, isFalse);
      expect(ready.capabilities.captions, isTrue);
      expect(ready.room, 'daily-sync');
      expect(ready.server, 'https://calls.example.com');
    });

    test('parses joined/left/error events', () {
      final AgilCallEvent joined = AgilBridge.parseWidgetMessage(
        '{"type":"agil:event","event":"joined","payload":{"id":"p1"}}',
      )!;
      expect(joined, isA<AgilJoinedEvent>());
      expect((joined as AgilJoinedEvent).payload, <String, Object?>{'id': 'p1'});

      final AgilCallEvent left = AgilBridge.parseWidgetMessage(
        '{"type":"agil:event","event":"left"}',
      )!;
      expect(left, isA<AgilLeftEvent>());

      final AgilCallEvent error = AgilBridge.parseWidgetMessage(
        '{"type":"agil:event","event":"error","payload":{"code":"mount_failed","message":"boom"}}',
      )!;
      expect(error, isA<AgilErrorEvent>());
      final AgilCallError callError = (error as AgilErrorEvent).error;
      expect(callError.code, AgilCallErrorCode.widgetError);
      expect(callError.widgetCode, 'mount_failed');
      expect(callError.message, 'boom');
      expect(callError.fatal, isFalse);
    });

    test('parses chat and rejects chat without text', () {
      final AgilCallEvent event = AgilBridge.parseWidgetMessage(
        '{"type":"agil:chat","message":{"text":"hi","participantName":"Анна","ts":1}}',
      )!;
      expect(event, isA<AgilChatEvent>());
      final AgilChatMessage message = (event as AgilChatEvent).message;
      expect(message.text, 'hi');
      expect(message.participantName, 'Анна');
      expect(message.ts, 1);

      expect(AgilBridge.parseWidgetMessage('{"type":"agil:chat","message":{}}'), isNull);
    });

    test('parses state snapshots and settings', () {
      final AgilCallEvent event = AgilBridge.parseWidgetMessage(
        jsonEncode(<String, Object?>{
          'type': 'agil:state',
          'state': <String, Object?>{
            'phase': 'joined',
            'participants': 3,
            'participantIds': <String>['p1', 'p2'],
            'quality': <String, Object?>{'tier': 'good', 'score': 4.5},
            'connectionState': 'connected',
            'recording': true,
            'minimized': false,
            'chatMode': 'external',
            'fullscreen': false,
            'settings': <String, Object?>{
              'mic': true,
              'camera': false,
              'screen': false,
              'blur': 'blur',
              'panel': 'chat',
            },
          },
        }),
      )!;
      expect(event, isA<AgilStateEvent>());
      final AgilCallSnapshot state = (event as AgilStateEvent).state;
      expect(state.phase, 'joined');
      expect(state.participants, 3);
      expect(state.participantIds, <String>['p1', 'p2']);
      expect(state.qualityTier, 'good');
      expect(state.qualityScore, 4.5);
      expect(state.connectionState, 'connected');
      expect(state.recording, isTrue);
      expect(state.micEnabled, isTrue);
      expect(state.cameraEnabled, isFalse);
      expect(state.blurMode, 'blur');
      expect(state.panel, 'chat');
    });

    test('maps minimized/fullscreen and generic events', () {
      expect(
        AgilBridge.parseWidgetMessage('{"type":"agil:minimized","minimized":true}'),
        isA<AgilMinimizedEvent>(),
      );
      expect(
        AgilBridge.parseWidgetMessage('{"type":"agil:fullscreen","fullscreen":false}'),
        isA<AgilFullscreenEvent>(),
      );
      final AgilCallEvent generic = AgilBridge.parseWidgetMessage(
        '{"type":"agil:event","event":"action-denied","payload":{"action":"pip"}}',
      )!;
      expect(generic, isA<AgilGenericEvent>());
      expect((generic as AgilGenericEvent).name, 'action-denied');
      expect(generic.payload, <String, Object?>{'action': 'pip'});
    });

    test('returns null for pong, bad envelopes, bad JSON and oversized input', () {
      expect(AgilBridge.parseWidgetMessage('{"type":"agil:pong"}'), isNull);
      expect(AgilBridge.parseWidgetMessage('not json'), isNull);
      expect(AgilBridge.parseWidgetMessage('{}'), isNull);
      expect(AgilBridge.parseWidgetMessage('{"type":"other:ready"}'), isNull);
      expect(AgilBridge.parseWidgetMessage('{"type":"agil:event","event":"Bad Name"}'), isNull);
      expect(AgilBridge.parseWidgetMessage('{"type":"agil:event","event":"ok"}', maxChars: 5), isNull);
      expect(AgilBridge.parseWidgetMessage(null), isNull);
      expect(AgilBridge.parseWidgetMessage(<String, Object?>{'type': 'agil:ready'}), isA<AgilReadyEvent>());
    });
  });

  group('sanitizeBridgePayload', () {
    test('drops forbidden keys, functions and cycles', () {
      final Map<String, Object?> payload = <String, Object?>{
        'ok': 'value',
        '__proto__': <String, Object?>{'polluted': true},
        'nested': <String, Object?>{
          'list': <Object?>[1, null, true, 'x'],
        },
      };
      payload['self'] = payload;
      final Object? result = AgilBridge.sanitizeBridgePayload(payload);
      expect(result, isA<Map<String, Object?>>());
      final Map<String, Object?> map = result! as Map<String, Object?>;
      expect(map['ok'], 'value');
      expect(map.containsKey('__proto__'), isFalse);
      // Cycles are reported as null (the key stays present), matching the
      // React Native bridge.
      expect(map.containsKey('self'), isTrue);
      expect(map['self'], isNull);
      expect(map['nested'], isA<Map<String, Object?>>());
    });

    test('limits depth, array length and string size', () {
      final Object? deep = AgilBridge.sanitizeBridgePayload(
        <String, Object?>{
          'a': <String, Object?>{
            'b': <String, Object?>{
              'c': <String, Object?>{'d': 'too deep'},
            },
          },
        },
        maxDepth: 2,
      );
      final Map<String, Object?> map = deep! as Map<String, Object?>;
      final Map<String, Object?> a = map['a']! as Map<String, Object?>;
      expect(a, <String, Object?>{'b': null});

      final List<Object?> list =
          AgilBridge.sanitizeBridgePayload(<Object?>[1, 2, 3, 4], maxArray: 2)! as List<Object?>;
      expect(list, <Object?>[1, 2]);

      final String long = 'x' * 10;
      final String truncated =
          AgilBridge.sanitizeBridgePayload(long, maxString: 4)! as String;
      expect(truncated.startsWith('xxxx'), isTrue);
      expect(truncated.length, 5);
    });
  });

  group('host message builders', () {
    test('builds widget actions, chat, scheme and ping messages', () {
      expect(AgilBridge.actionMessage(AgilAction.toggleMic), <String, Object?>{
        'type': 'agil:action',
        'action': 'toggle-mic',
      });
      expect(AgilBridge.schemeMessage(AgilThemeScheme.dark), <String, Object?>{
        'type': 'agil:scheme',
        'scheme': 'dark',
      });
      expect(AgilBridge.chatMessage('  hi  '), <String, Object?>{
        'type': 'agil:chat-send',
        'text': '  hi  ',
      });
      expect(AgilBridge.pingMessage(), <String, Object?>{'type': 'agil:ping'});
      expect(() => AgilBridge.chatMessage('   '), throwsArgumentError);
    });

    test('sanitizes theme/config patches and rejects empty patches', () {
      final Map<String, Object?> message = AgilBridge.themeMessage(<String, Object?>{
        'colors': <String, Object?>{'primary': '#0b5fff'},
        '__proto__': 'x',
      });
      expect(message['type'], 'agil:theme');
      final Map<String, Object?> theme = message['theme']! as Map<String, Object?>;
      expect(theme['colors'], isA<Map<String, Object?>>());
      expect(theme.containsKey('__proto__'), isFalse);
      expect(() => AgilBridge.themeMessage(<String, Object?>{}), throwsArgumentError);
      expect(() => AgilBridge.configMessage(<String, Object?>{}), throwsArgumentError);
    });

    test('escapes script-sensitive JSON in injected scripts', () {
      final String script = AgilBridge.createHostMessageScript(<String, Object?>{
        'type': 'agil:chat-send',
        'text': '</script><img src=x onerror=alert(1)>&\u2028',
      });
      expect(script, contains('\\u003c/script\\u003e'));
      expect(script, isNot(contains('</script>')));
      expect(script, contains('window.__agilFlutterPostToPage'));
      expect(script.startsWith('(function(){try{'), isTrue);
      expect(script.endsWith('true;'), isTrue);
    });

    test('shim forwards parent.postMessage to the AgilBridge channel', () {
      final String shim = AgilBridge.createShimScript(origin: 'https://calls.example.com');
      expect(shim, contains('AgilBridge'));
      expect(shim, contains('postMessage'));
      expect(shim, contains('__agilFlutterBridgeInstalled'));
      expect(shim, contains('"https://calls.example.com"'));
      expect(shim, contains('Object.defineProperty'));
      expect(shim.endsWith('true;'), isTrue);
    });

    test('shim tags forwarded messages with the per-load nonce', () {
      final String shim = AgilBridge.createShimScript(
        origin: 'https://calls.example.com',
        nonce: 'nonce-1',
      );
      expect(shim, contains('var nonce="nonce-1";'));
      expect(shim, contains('__agilBridgeNonce'));

      final String raw = jsonEncode(<String, Object?>{
        '__agilBridgeNonce': 'nonce-1',
        'message': '{"type":"agil:ready"}',
      });
      expect(AgilBridge.unwrapBridgeEnvelope(raw, 'nonce-1'), '{"type":"agil:ready"}');
      expect(AgilBridge.unwrapBridgeEnvelope(raw, 'nonce-2'), isNull);
      expect(AgilBridge.unwrapBridgeEnvelope('{"type":"agil:ready"}', 'nonce-1'), isNull);
      expect(
        AgilBridge.unwrapBridgeEnvelope('{"type":"agil:ready"}', null),
        '{"type":"agil:ready"}',
      );
    });

    test('parseWidgetMessage redacts tokens from widget errors', () {
      const String token = 'SECRET-JOIN-TOKEN';
      final AgilCallEvent event = AgilBridge.parseWidgetMessage(
        '{"type":"agil:event","event":"error","payload":{"code":"mount_failed",'
        '"message":"failed https://host/embed.html?token=$token&room=r"}}',
        secrets: const <String>[token],
      )!;
      expect(event, isA<AgilErrorEvent>());
      final AgilCallError error = (event as AgilErrorEvent).error;
      expect(error.message, isNot(contains(token)));
      expect(error.message, contains('redacted'));
    });
  });
}

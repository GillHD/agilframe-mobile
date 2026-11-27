/// Flutter SDK for the hosted AgilFrame widget.
///
/// ```dart
/// import 'package:agil_calls/agil_calls.dart';
///
/// AgilCall(
///   serverUrl: 'https://calls.example.com',
///   tenantId: 'acme',
///   roomId: 'daily-sync',
///   joinToken: token,
///   onEvent: (event) => debugPrint('$event'),
/// )
/// ```
library;

export 'src/agil_call.dart';
export 'src/bridge.dart'
    show
        AgilBridge,
        agilBridgeMaxChars,
        agilBridgeMaxChatChars,
        agilBridgeMaxQueuedMessages;
export 'src/types.dart';
export 'src/url.dart';

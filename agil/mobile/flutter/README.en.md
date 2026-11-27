# agil_calls for Flutter

[Русский](README.md) · English

Embed AgilFrame calls in a Flutter app with the `AgilCall` widget. It opens
the hosted `/embed.html` page in a WebView, forwards events through the
`AgilBridge` postMessage bridge, and exposes commands for the microphone,
camera, chat, and theme through `AgilCallController`.

> **P1 status · WebView integration.** The AgilFrame web widget handles media,
> chat, themes, and access permissions. The Flutter app owns the screen,
> navigation, and the `AgilBridge` channel. See the [Flutter SDK guide (Russian)](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/flutter-sdk.md)
> for platform limitations and the planned native WebRTC integration.

## Package layout

| File | Purpose |
| --- | --- |
| [`lib/src/agil_call.dart`](lib/src/agil_call.dart) | `AgilCall` stateful widget and `AgilCallController` |
| [`lib/src/url.dart`](lib/src/url.dart) | Builds embed URLs, parses call links, guards navigation, and redacts tokens |
| [`lib/src/bridge.dart`](lib/src/bridge.dart) | Parses and sanitizes `agil:*` messages, builds injected scripts, and implements the `AgilBridge` shim |
| [`lib/src/types.dart`](lib/src/types.dart) | Events, errors, capabilities, and state snapshots |
| [`test/url_test.dart`](test/url_test.dart), [`test/bridge_test.dart`](test/bridge_test.dart) | Dart tests for URL handling and the bridge |
| [`example/lib/main.dart`](example/lib/main.dart) | Sample app with a join form, call controls, and an event log |

## Requirements

- Flutter **3.24 or later** and Dart **3.5 or later**.
- The Android integration uses `flutter_inappwebview` and `permission_handler`. The iOS integration uses `webview_flutter` **4.10 or later**.
- An AgilFrame server that serves `/embed.html` and the web widget assets. The package uses existing server endpoints.
- iOS **14 or later** for WebRTC in WKWebView. Android **8 or later** with an updatable AndroidX WebView. WebView 90 or later is recommended.
- HTTPS in production. For development, HTTP is allowed for `localhost`, `127.0.0.1`, `::1`, and the Android emulator address `10.0.2.2`. Use `allowInsecure: true` for other development hosts.

## Installation

Add the package from a local clone of `agilframe-mobile` or use a Git dependency.

```yaml
# The application's pubspec.yaml
dependencies:
  flutter:
    sdk: flutter
  agil_calls:
    path: ../agilframe-mobile/agil/mobile/flutter
    # Or use Git:
    # git:
    #   url: https://github.com/GillHD/agilframe-mobile.git
    #   path: agil/mobile/flutter
```

```bash
flutter pub get
```

## Quick start

```dart
import 'package:agil_calls/agil_calls.dart';
import 'package:flutter/material.dart';

class CallScreen extends StatelessWidget {
  const CallScreen({super.key, required this.token});

  final String token;

  @override
  Widget build(BuildContext context) {
    return AgilCall(
      serverUrl: 'https://calls.example.com',
      tenantId: 'acme',
      roomId: 'daily-sync',
      joinToken: token,
      participantName: 'Anna',
      theme: AgilThemeScheme.auto,
      language: AgilLanguage.en,
      onEvent: (event) {
        switch (event) {
          case AgilReadyEvent(:final capabilities):
            debugPrint('widget ready media=${capabilities.media}');
          case AgilJoinedEvent():
            debugPrint('joined');
          case AgilLeftEvent():
            debugPrint('left');
          case AgilChatEvent(:final message):
            debugPrint('chat ${message.participantName}: ${message.text}');
          case AgilStateEvent(:final state):
            debugPrint('peers=${state.participants}');
          case AgilErrorEvent(:final error):
            debugPrint('widget error ${error.code.wire}: ${error.message}');
          default:
            debugPrint('event $event');
        }
      },
      onError: (error) => debugPrint('${error.code.wire} fatal=${error.fatal}: ${error.message}'),
    );
  }
}
```

When you supply `joinToken`, the widget attempts to join as soon as it loads.
Without a token, the widget displays the join screen with name, camera, and
microphone controls.

### Request a join token

Call `POST /v1/rooms/:roomId/join` from your backend. [API reference (Russian)](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/api.md#4-join-и-пароли)

```bash
curl -s -X POST https://calls.example.com/v1/rooms/daily-sync/join \
  -H 'content-type: application/json' \
  -d '{"name":"Anna","locale":"en"}'
# → { "token":"eyJ...", "expiresAt":..., "participant":{...}, "permissions":[...] }
```

Use a short-lived join token. Keep the admin API key on your backend. Exclude
join URLs and tokens from application logs, including `debugPrint`.

## Widget parameters

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `serverUrl` | `String` (required) | — | HTTP(S) base URL for REST, WebSocket signaling, and assets. A subpath is preserved, so `https://host/calls` resolves to `/calls/embed.html`. |
| `roomId` | `String` (required) | — | Room ID. |
| `joinToken` | `String?` | — | Join token. When omitted, the widget displays its join screen. |
| `tenantId` | `String` | `demo` | Tenant ID. |
| `participantName` | `String?` | — | Name shown on the join screen. |
| `role` | `AgilRole?` | — | Role for anonymous joins: `host`, `moderator`, or `guest`. |
| `theme` | `AgilThemeScheme?` | — | Color scheme: `light`, `dark`, or `auto`. The server provides the full theme. |
| `language` | `AgilLanguage?` | From configuration | Widget locale, `ru` or `en`. |
| `identityToken` | `String?` | — | Enterprise OIDC token, passed as `identity_token`. |
| `relayOnly` | `bool` | `false` | Restricts media to TURN relays through `relay=1`. |
| `widgetPath` | `String` | `embed.html` | Path relative to `serverUrl`. Use `/embed.html` to resolve from the origin root. |
| `allowedOrigins` | `List<String>` | `[]` | Additional exact origins for navigation, for example SSO. |
| `safeArea` | `bool` | `true` | Wraps the WebView in Flutter's `SafeArea` to account for system insets on Android. |
| `allowInsecure` | `bool` | `false` | Allows `http://` beyond the default development hosts. Use only for development. |
| `readyTimeout` | `Duration` | `20s` | Time to wait for `agil:ready`. Set `Duration.zero` to disable the watchdog. |
| `controller` | `AgilCallController?` | — | Controller for issuing commands. |
| `onEvent` | `void Function(AgilCallEvent)` | — | Receives all call events. |
| `onError` | `void Function(AgilCallError)` | — | Receives loading, bridge, and navigation errors. Widget errors also arrive as `AgilErrorEvent`. |
| `onExternalLink` | `void Function(String url)` | — | Handles a blocked navigation URL. The host app can open it in an external browser. |
| `backgroundColor` | `Color` | `#080D16` | WebView background color. |

The component validates its parameters before loading the WebView. If
configuration is invalid, it displays a text fallback and calls `onError`
with `{ code: invalid-config, fatal: true }`. The error does not include
the token.

## Events

| Event | Payload | Trigger |
| --- | --- | --- |
| `AgilReadyEvent` | `capabilities`, `room?`, `server?` | The widget is mounted and the bridge is ready. |
| `AgilJoinedEvent` | `payload?` | A participant joins the room. |
| `AgilLeftEvent` | `payload?` | A participant leaves the room. |
| `AgilChatEvent` | `message` | A new chat message arrives, including messages from external chat. |
| `AgilErrorEvent` | `error` | The widget reports an error with code `widget-error`. |
| `AgilStateEvent` | `state` | The widget emits an updated state snapshot. |
| `AgilMinimizedEvent` / `AgilFullscreenEvent` | `bool` | The minimized or fullscreen state changes. |
| `AgilGenericEvent` | `name`, `payload?` | Other events, including `participant-joined`, `quality-changed`, and `action-denied`. |

Loading, HTTP, timeout, and navigation errors outside the widget go to
`onError`. The bridge queues up to 50 outgoing messages while it initializes
and sends them once it is ready.

## Controller commands

```dart
final controller = AgilCallController();

AgilCall(
  serverUrl: 'https://calls.example.com',
  roomId: 'daily-sync',
  controller: controller,
  // ...
);

controller.toggleMute();          // agil:action toggle-mic
controller.toggleCamera();        // agil:action toggle-camera
controller.toggleChat();          // agil:action toggle-chat
controller.sendChat('Hello');      // agil:chat-send
controller.setTheme(AgilThemeScheme.dark); // agil:scheme, without reloading
controller.applyTheme({'colors': {'primary': '#0b5fff'}}); // agil:theme
controller.applyConfig({'layout': {'controlsStyle': 'minimal'}}); // agil:config
controller.ping();                // agil:ping, agil:pong produces no event
controller.reload();              // Reloads WebView and restarts the watchdog
controller.isReady;               // true once the bridge is ready
```

## URLs, deep links, and security

```dart
import 'package:agil_calls/agil_calls.dart';

// Build an embed URL using the same options as the call widget.
final url = buildWidgetUrl(AgilCallUrlOptions(
  serverUrl: 'https://calls.example.com',
  roomId: 'daily-sync',
  joinToken: token,
  tenantId: 'acme',
));

// Parse an incoming email, QR, or push notification link.
final link = parseAgilCallLink(
  incoming,
  allowedOrigins: const ['https://calls.example.com'],
  allowedSchemes: const ['myapp'],
);
```

- `buildWidgetUrl` rejects `javascript:` and `file:` URLs, credentials and query strings or fragments in `serverUrl`, path traversal through `widgetPath`, and tokens containing spaces or control characters.
- For HTTP(S) call links, `parseAgilCallLink` checks that the `server` parameter matches the link's origin and deployment path. Links using a custom scheme require a nonempty `allowedOrigins` list.
- `redactCallUrl`, `redactTokenText`, and `redactSecrets` mask `token`, `identity_token`, `access_token`, `id_token`, and JWT-like strings. Widget errors are redacted before delivery to `onError` and `onEvent`.
- The shim adds a per-load nonce to forwarded messages. Direct `AgilBridge.postMessage` calls from an allowed SSO origin fail validation.
- WebView navigation is restricted to the `serverUrl` origin and the origins explicitly listed in `allowedOrigins`.

## Platform configuration

### iOS with WKWebView

Add the camera and microphone usage descriptions to `Info.plist` before your
first `getUserMedia` request.

```xml
<key>NSCameraUsageDescription</key>
<string>Camera access is used for video calls.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is used for calls.</string>
```

WKWebView displays the system permission prompt. Screen sharing through
`getDisplayMedia` is unavailable in the WKWebView integration.

### Android with AndroidX WebView

Add these declarations to `AndroidManifest.xml`.

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-feature android:name="android.hardware.camera" android:required="false" />
```

- `AgilCall` handles camera and microphone requests forwarded by Android WebView. Declare the system permissions in the host app manifest.
- The host app can ask for permissions in response to an explicit user action. The sample app's camera and microphone button calls `await controller.requestAndroidMediaPermissions()`. Pass `camera: false` or `microphone: false` to request access to just one device. A participant can still join and listen after denying permission.
- The SDK compares the request origin and the open page's origin against `serverUrl`. Additional navigation origins, including SSO origins, do not get media capture access. If Android denies the request, the widget indicates that the camera or microphone is unavailable.
- Use HTTPS in production. For development, enable HTTP through `android:usesCleartextTraffic="true"` or an Android Network Security Configuration.
- In the Android emulator, use `serverUrl: 'http://10.0.2.2:8787'`. On a physical device use the development machine's local IP address, with `allowInsecure: true` for HTTP.

## Build and test

From the repository root, run the package checks.

```bash
cd agil/mobile/flutter
flutter pub get
flutter analyze
flutter test
```

From the repository root, prepare and run the Android sample app.

```bash
cd agil/mobile/flutter/example
flutter create --platforms=android --project-name agil_calls_example .
flutter pub get
flutter build apk --debug
flutter run -d <android-device>
```

After generating the Android project, add the permissions listed above to
`android/app/src/main/AndroidManifest.xml`. To reach local Core from a physical
device connected over USB, run `adb reverse tcp:8787 tcp:8787` and use
`http://localhost:8787`. Limit cleartext traffic to debug builds.

## Limitations

- Calls run inside a Chromium WebView or WKWebView. The hosted widget provides UI, media, and access rules. Native LiveKit with CallKit or ConnectionService is planned.
- On Android, the bridge is injected at document start. On iOS, `webview_flutter` 4.x does not provide `injectJavaScriptBeforeContentLoaded`. The shim is injected in `onPageStarted` and `onPageFinished`, with a retry after 250 ms. If the shim misses the initial `agil:ready` event, the first `agil:state` or `agil:event` releases queued commands. The call can still work while the bridge initializes.
- The OS can suspend the WebView when the app goes into the background. Incoming-call push notifications, background call support, and native system call UI are unavailable in this integration.
- Screen sharing is unavailable in the mobile WebView integration.
- The join token is visible in the WebView URL and history. Use HTTPS and short-lived tokens, exclude URLs from logs, and clear WebView data on sign-out.
- Use one active call per screen. Avoid mounting multiple `AgilCall` instances on devices with limited resources.
- The host app registers its deep links. The package parses and validates incoming call URLs.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| `timeout` in `onError` | The widget may have failed to load because of CSP, certificate errors, a wrong `serverUrl`, or HTTP restrictions on iOS. Open the URL in a browser and check the network response. |
| Video works but events are missing | The bridge may have missed `agil:ready`. Check your `webview_flutter` version, use `WebViewWidget` for the iOS integration, and verify that JavaScript is enabled. |
| `permission-denied` on Android | Check the manifest and the app's camera and microphone permissions in Android settings. |
| The iOS app crashes on join | Check that `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` are present in `Info.plist`. |
| The call screen stays black | Check for blocked HTTP or mixed content and certificate errors. Use HTTPS with a trusted certificate in production. |
| `navigation-blocked` | Add the trusted destination to `allowedOrigins` if it must open inside the WebView, or handle it through `onExternalLink`. |
| Audio stops in the background | The OS may have suspended the WebView. Continuous background audio requires a native audio integration. |

[Full Flutter SDK guide (Russian)](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/flutter-sdk.md)

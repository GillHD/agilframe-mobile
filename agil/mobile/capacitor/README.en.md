# @agil/calls-capacitor

[Русский](README.md) · English

The AgilFrame Capacitor plugin opens the hosted `/embed.html` widget on iOS,
Android, and the web. `openCall()` presents the call in an in-app WKWebView or
Android WebView, in an iframe on the web, or in the system browser. The
plugin relays events through `AgilBridge` and manages camera and microphone
permissions.

> **Status — P1 WebView integration.** The hosted widget handles media, chat,
> themes, and participant state. The plugin owns presentation, navigation,
> the bridge, and permission requests. The
> [Capacitor integration guide](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/capacitor.md)
> covers platform constraints and plans for a native WebRTC stack.

## Project layout

| Path | Purpose |
|---|---|
| `src/definitions.ts` | Public types and interfaces for the native plugin and the `AgilCalls` facade |
| `src/index.ts` | Facade, option validation, URL construction, and plugin registration |
| `src/url.ts` | Widget URLs, link parsing, navigation checks, and token redaction |
| `src/bridge.ts` | Parsing and sanitizing `agil:*` messages |
| `src/web.ts` | Full-screen iframe and `postMessage` for web hosts |
| `ios/Sources/AgilCallsPlugin` | Swift plugin and `AgilCallViewController` (WKWebView) |
| `android/src/main/java/com/agil/calls` | Kotlin plugin, Activity, and bridge |
| `AgilCalls.podspec`, `android/build.gradle` | Native build configuration |
| `test/url.test.ts`, `test/bridge.test.ts`, `test/native-source.test.ts` | URL, bridge, and native-source regression tests |

## Requirements

- Capacitor **6 or later**. `@capacitor/core` is a peer dependency.
- iOS **14 or later** for WKWebView/WebRTC. Android **minSdk 22** or higher.
  An up-to-date Android System WebView, version 90 or later, is recommended.
- An AgilFrame server that serves `/embed.html` and the widget assets. The
  plugin uses the existing server endpoints.
- HTTPS in production. HTTP is available for development on
  `localhost`, `127.0.0.1`, `::1`, and `10.0.2.2`, or when you set
  `allowInsecure: true`.

## Install

Build the package from source. Run these commands from the root of your
`agilframe-mobile` checkout.

```bash
npm ci
npm run build --workspace @agil/calls-capacitor
npm pack --workspace @agil/calls-capacitor
```

Install the archive from the root of your Capacitor app. Replace the example
path with the path to the archive reported by `npm pack`.

```bash
npm install /path/to/agilframe-mobile/agil-calls-capacitor-0.1.0.tgz
npx cap sync
```

Capacitor registers the plugin automatically using
`"capacitor": { "ios": { "src": "ios" }, "android": { "src": "android" } }` in
`package.json`. For individual platforms, run `npx cap sync ios` or
`npx cap sync android`. On iOS, you can also run `pod install` in `ios/App`.

## Quick start

```ts
import { AgilCalls } from '@agil/calls-capacitor';
import type { AgilCallEvent } from '@agil/calls-capacitor';

const listener = await AgilCalls.addListener('callEvent', (event: AgilCallEvent) => {
  switch (event.type) {
    case 'ready':
      console.log('widget ready', event.capabilities);
      break;
    case 'joined':
      console.log('joined');
      break;
    case 'left':
      console.log('left');
      break;
    case 'chat':
      console.log('chat', event.message.text);
      break;
    case 'error':
      console.warn('widget error', event.error.code, event.error.message);
      break;
    case 'state':
      console.log('participants', event.state.participants);
      break;
    case 'participants':
      // A participant snapshot includes up to 200 IDs. Updates arrive as deltas.
      // The compact state exposes participantCount and participantRevision.
      console.log(event.participants.kind, event.participants.count);
      break;
    case 'connection':
      console.log(event.connection.state, event.connection.attempt);
      break;
    default:
      console.log(event.type);
  }
});

const support = await AgilCalls.isSupported();
if (!support.inAppWebView) {
  console.warn(support.reason);
}

await AgilCalls.requestPermissions();

const call = await AgilCalls.openCall({
  serverUrl: 'https://calls.example.com',
  tenantId: 'acme',
  roomId: 'daily-sync',
  joinToken: token, // Short-lived token issued by your backend.
  participantName: 'Anna',
  theme: 'auto',
  language: 'en',
  limits: { maxParticipants: 200 }, // Uses snapshots and deltas for participant IDs.
  presentation: 'auto', // 'auto' | 'in-app' | 'external'
});

console.log(call.mode); // 'in-app' | 'external'

await AgilCalls.setTheme({ scheme: 'dark' });
// ...
await AgilCalls.close();
await listener.remove();
```

With a `joinToken`, the widget joins the call after loading. If you omit the
token, the widget opens its own join screen.

### Obtain a join token

Use the existing `POST /v1/rooms/:roomId/join` endpoint. Obtain short-lived
tokens on your backend, keep the admin API key on the server, and redact URLs
before logging them. See [REST and WebSocket API](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/api.md#post-v1roomsroomidjoin).

## API

### `AgilCalls.openCall(options)`

Returns `{ callId, mode }`. The result excludes the URL and join token.

| Option | Type | Default | Description |
|---|---|---|---|
| `serverUrl` | `string` (required) | — | HTTP(S) server URL. Any base path is preserved. |
| `roomId` | `string` (required) | — | Room ID. |
| `tenantId` | `string` | `demo` | Tenant ID. |
| `joinToken` | `string` | — | Join token. Omit it to show the join screen. |
| `identityToken` | `string` | — | OIDC identity token (`identity_token`). |
| `participantName` | `string` | — | Display name on the join screen. |
| `role` | `'host' \| 'moderator' \| 'guest'` | — | Role for an anonymous join. |
| `theme` | `'light' \| 'dark' \| 'auto'` | — | Theme scheme. |
| `language` | `'ru' \| 'en'` | Server configuration | Interface language. |
| `relayOnly` | `boolean` | `false` | Uses TURN relay only (`relay=1`). |
| `widgetPath` | `string` | `embed.html` | Path relative to `serverUrl`. |
| `allowedOrigins` | `string[]` | `[]` | Additional exact origins allowed for navigation. |
| `allowInsecure` | `boolean` | `false` | Allows non-loopback HTTP in development. |
| `presentation` | `'auto' \| 'in-app' \| 'external'` | `auto` | Selects an in-app view or the system browser. |
| `permissions` | `{ camera?, microphone? }` | Both `true` | Indicates which media permissions the app can grant. |
| `limits` | `{ maxParticipants?: number }` | `200` participants | Configures the participant limit for bridge snapshots and deltas. |

All methods return a `Promise`, including `close(): Promise<void>` and
`setTheme(): Promise<void>`. The package entry point exports `version`.

### `AgilCalls.close()`

Closes the in-app view or Activity. In external mode, the user closes the
system browser.

### `AgilCalls.isSupported()`

Returns `{ supported, inAppWebView, reason? }`. On the web, `inAppWebView`
indicates iframe availability. On iOS and Android, it indicates whether a
host view controller or Activity is available.

### `AgilCalls.setTheme({ scheme?, theme? })`

Switches the color scheme via `agil:scheme`, applies a partial theme update
via `agil:theme`, or does both in the same call. The page stays loaded.

### `AgilCalls.sendAction(action)`

Sends an `agil:action` message to the open WebView. `AGIL_CALL_ACTIONS` lists
the accepted values, including `toggle-mic`, `toggle-camera`, `toggle-chat`,
`share-screen`, `leave`, `minimize`, `restore`, `pip`, `fullscreen`,
`newtab`, `blur-on`, and `blur-off`.

While the widget loads, the plugin queues up to 20 actions in the order
received and sends them after the first accepted widget message, typically
`agil:ready`. It discards the queue when the call closes. If the queue fills,
the next `sendAction` call rejects.

### `AgilCalls.sendChat(text)`

Sends `agil:chat-send` with non-empty text of up to 4,000 characters. During
loading, chat messages use the same queue as `sendAction`.

### `AgilCalls.checkPermissions()` and `AgilCalls.requestPermissions()`

Return `{ camera, microphone, settingsRequired }`. Permission states include
`granted`, `denied`, `prompt`, `prompt-with-rationale`, `blocked`,
`unavailable`, and `not-requested`. iOS uses `AVCaptureDevice`, Android
uses runtime permissions, and the web uses the Permissions API and
`getUserMedia`.

### `AgilCalls.addListener('callEvent', listener)`

Emits `ready`, `joined`, `left`, `chat`, `error`, `state`,
`participants`, `connection`, `minimized`, `fullscreen`, and `event`.
The returned subscription handle provides `remove()`.

## URLs and security

```ts
import {
  buildWidgetUrl,
  parseAgilCallLink,
  redactCallUrl,
  redactTokenText,
} from '@agil/calls-capacitor/url';

const url = buildWidgetUrl({
  serverUrl: 'https://calls.example.com',
  roomId: 'daily-sync',
  joinToken: token,
});

const link = parseAgilCallLink(incoming, {
  allowedOrigins: ['https://calls.example.com'],
  allowedSchemes: ['myapp'],
});
```

- `buildWidgetUrl` rejects `javascript:` and `file:` URLs, credentials or
  query strings or fragments in `serverUrl`, parent directory segments in
  `widgetPath`, and tokens that contain whitespace or control characters.
- For HTTP(S), `parseAgilCallLink` checks the `server` parameter against
  the link origin and path. Custom schemes require a non-empty
  `allowedOrigins` list.
- Use `redactCallUrl` and `redactTokenText` before logging. They mask
  tokens and JWTs.
- The WebView can navigate to the `serverUrl` origin and the origins in
  `allowedOrigins`. It opens other HTTP(S) links in the system browser
  and blocks other schemes.
- `src/bridge.ts` parses and sanitizes widget messages from Swift, Kotlin,
  and iframes. It redacts `token`, `identity_token`, `access_token`, and
  JWT values in widget errors, including native `error.description` text.
- The `agil:*` channel is bound to the widget. On iOS, the plugin checks
  `WKFrameInfo.securityOrigin` and normalizes a reported port of `0` to
  `443` or `80`. On Android, the shim receives a fresh nonce for each page
  load. An allowed SSO origin cannot send valid widget messages. The Android
  bridge unwraps `{__agilBridgeNonce,message}` before calling the JavaScript
  parser so listeners receive the inner event.

## Native configuration

### iOS

Add usage descriptions to the app's `Info.plist`.

```xml
<key>NSCameraUsageDescription</key>
<string>Allow camera access for video calls</string>
<key>NSMicrophoneUsageDescription</key>
<string>Allow microphone access for calls</string>
```

`AgilCallViewController` installs its `WKUserScript` at `.atDocumentStart`
to receive `agil:ready`. `AgilOriginNormalizer` treats the `WKSecurityOrigin`
port `0` as the default for the scheme. In HTTPS, `https://host`,
`https://host:443`, and an HTTPS security origin with port `0` therefore
refer to the same origin.

On iOS 15 and later, `WKUIDelegate.requestMediaCapturePermissionFor` rejects
requests for a disabled media type. WebKit expects a single decision for
`.cameraAndMicrophone`, so the plugin denies that combined request if either
media type is disabled.

### Android

The plugin declares permissions in `android/src/main/AndroidManifest.xml`.
They merge into the host app's manifest. Call
`AgilCalls.requestPermissions()` for the runtime request. The permission
aliases are `camera` and `microphone`.

`AgilCallActivity` applies the following controls.

- `WebChromeClient.onPermissionRequest` filters audio and video separately.
  With `camera: false`, it can grant `RESOURCE_AUDIO_CAPTURE`. With
  `microphone: false`, it can grant only video capture.
- `WebViewClient.shouldOverrideUrlLoading` checks the target origin and
  delegates external HTTP(S) links to the system browser.
- `BridgeInterface` checks the per-load nonce and unwraps
  `{__agilBridgeNonce,message}`, forwarding only the inner widget message
  to JavaScript.
- The plugin injects the shim in `onPageStarted` and `onPageFinished`.
- `mixedContentMode = MIXED_CONTENT_NEVER_ALLOW` blocks mixed content,
  and `allowFileAccess = false` blocks access to local files.

To use cleartext HTTP in development, configure
`android:usesCleartextTraffic="true"` or a network security configuration in
the host app. Use HTTPS for production deployments.

### Web

`src/web.ts` mounts a full-screen iframe with
`allow="camera; microphone; fullscreen; display-capture; autoplay; clipboard-write"`.
The parent checks both `event.source === iframe.contentWindow` and
`event.origin === widgetOrigin`. If an iframe is unavailable or
`presentation: 'external'` is selected, the call opens in a new tab.

## Build and test

```bash
cd agil/mobile/capacitor

npm run typecheck   # tsc --noEmit for src and test. Requires @capacitor/core.
npm test            # Unit tests via tsx --test
npm run build       # dist/ (ESM) and dist/cjs/ (CommonJS)
npm pack --dry-run  # List files included in the package
```

- `test/native-source.test.ts` runs as part of `npm test`. It checks the
  Swift and Kotlin sources for default-port normalization, unwrapping of the
  nonce envelope, and queuing before `agil:ready`.
- `ios/Tests/AgilCallsPluginTests/AgilOriginNormalizerTests.swift` contains
  XCTest coverage for the origin normalizer. To execute it, add the tests to
  an Xcode test target. The repository does not include an `.xcodeproj` for
  running them.

From a Capacitor app with Xcode and the Android SDK configured, run the
commands for the platforms you target.

```bash
npx cap sync ios       # Includes AgilCalls.podspec.
npx cap open ios       # Build and run in Xcode.
npx cap sync android
npx cap open android   # Build and run in Android Studio.
```

Local verification with `@capacitor/core@6` passed type checking and all
42 tests. The JavaScript suite checks URL construction, validation, bridge
parsing, and selected Swift and Kotlin source safeguards without starting a
Capacitor runtime. Building and running native modules requires the
respective platform toolchains.

## Limitations

- The WebView hosts WebRTC, chat, and theming. Native LiveKit, CallKit, and
  Android ConnectionService are planned.
- Background operation, incoming call push notifications, and CallKit are
  unavailable. The operating system may suspend the WebView in the
  background.
- Screen sharing depends on `getDisplayMedia`, which is unavailable in
  mobile WebViews.
- On Android, `agil:ready` can arrive before the shim is installed.
  `sendAction` and `sendChat` queue up to 20 entries and flush them in order
  after the first accepted widget message. Closing the call clears any
  pending entries.
- The join token appears in the WebView URL and may appear in its history.
  Use a short expiry and HTTPS, redact logs, and clear WebView data at
  sign-out.
- Some browsers require a user gesture or additional permission to use the
  camera in an iframe. For native mobile apps, use the iOS or Android target.
- With `presentation: 'external'`, the call opens in the system browser.
  The app cannot receive `callEvent` messages from that browser.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `openCall` rejects with `invalid-config` | Check `serverUrl` and `roomId`. The URL must use an allowed scheme and omit credentials and query parameters. Error messages redact tokens. |
| Events do not arrive | Check whether the shim received `agil:ready` and that the native build has been synchronized with `npx cap sync`. External browser mode does not relay events. |
| `permission-denied` | Call `requestPermissions()`. If the permissions are blocked, open the app's system settings. |
| iOS exits when joining a call | Check `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` in `Info.plist`. |
| Android opens a blank page | Cleartext HTTP may be blocked. Use HTTPS in production. |
| `navigation-blocked` | Verify that the destination is trusted before adding its exact origin to `allowedOrigins`. |
| The camera is unavailable in a web iframe | Check cross-origin media permissions or use a native target. |

For deployment and integration details, see the
[Capacitor integration guide](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/capacitor.md).

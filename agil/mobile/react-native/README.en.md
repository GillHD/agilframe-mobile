# @agil/calls-react-native

[Русский](README.md) · **English**

The AgilFrame wrapper for React Native on iOS and Android. `<AgilCall />`
opens the hosted `/embed.html` widget in a WebView, forwards events through
a `postMessage` bridge, and manages camera and microphone permissions.

The hosted widget handles media, chat, themes, and access rules. The React
Native app owns the call screen, navigation, and platform permissions. See the
integration guide for the current limitations and plans for the native
LiveKit React Native integration. [Mobile integration guide](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/mobile.md)

## Package layout

| Path | Purpose |
|---|---|
| `src/AgilCall.ts` | `<AgilCall />` component built on `react-native-webview` |
| `src/url.ts` | Widget URLs, deep links, link parsing, and navigation policy |
| `src/url-core.ts` | Hermes-compatible URL and query parser that works without global `URL` or `URLSearchParams` |
| `src/bridge.ts` | Parsing and sanitization of `agil:*` messages, injected scripts, and the shim for a top-level WebView |
| `src/permissions.ts` | Android runtime permissions, iOS permission prompts, and opening app settings |
| `src/types.ts` | Public TypeScript types |
| `expo/withAgilCall.cjs` | Expo config plugin for `Info.plist` and `AndroidManifest.xml` |
| `test/` | Unit tests for URLs, the bridge, and rendering with `tsx --test` in Node.js |

## Requirements

- React Native **0.71+**, React **18+**, and `react-native-webview` **13+**.
- The package includes a Hermes-compatible URL parser. You can use it without
  a `URL` or `URLSearchParams` polyfill.
- An AgilFrame server that serves `/embed.html` and the widget assets. The
  wrapper uses the existing server endpoints.
- iOS **14.3+** for WebRTC in WKWebView, or Android **8+** with an updatable
  AndroidX WebView. WebView 90 or later is recommended.
- HTTPS in production. For local development, the Android emulator can reach
  the host at `http://10.0.2.2:8787`, and the iOS simulator can use
  `http://localhost:8787`.

## Installation

```bash
npm install @agil/calls-react-native react-native-webview
# Expo:
npx expo install react-native-webview
```

The app supplies `react`, `react-native`, and `react-native-webview` as peer
dependencies. They are marked optional so monorepo and CI installs can run
without pulling in React Native. Make sure your app has all three.

## Quick start

This example uses `useSafeAreaInsets()` from `react-native-safe-area-context`.
Set up that library in your app if you want to pass insets to the widget.

```tsx
import { useRef } from 'react';
import { SafeAreaView } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { AgilCall, type AgilCallHandle, type AgilCallEvent } from '@agil/calls-react-native';

export function CallScreen() {
  const call = useRef<AgilCallHandle>(null);
  const insets = useSafeAreaInsets();

  const onEvent = (event: AgilCallEvent) => {
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
      default:
        console.log(event.type);
    }
  };

  return (
    <SafeAreaView style={{ flex: 1 }}>
      <AgilCall
        ref={call}
        serverUrl="https://calls.example.com"
        tenantId="acme"
        roomId="daily-sync"
        joinToken="<join-token>"
        participantName="Anna"
        theme="auto"
        language="en"
        permissions={{ camera: true, microphone: true }}
        safeAreaInsets={insets}
        onEvent={onEvent}
        onError={(error) => console.warn(error.code, error.message, error.fatal)}
        style={{ flex: 1 }}
      />
    </SafeAreaView>
  );
}
```

With a `joinToken`, the widget joins the call after it loads. Omit the token
to display the widget's join screen with name, camera, and microphone controls.

### Obtain a join token

Use the existing `POST /v1/rooms/:roomId/join` endpoint. See section 4 of
the [API reference](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/api.md).

```bash
curl -s -X POST https://calls.example.com/v1/rooms/daily-sync/join \
  -H 'content-type: application/json' \
  -d '{"name":"Anna","locale":"en"}'
# → { "token":"eyJ...", "expiresAt":..., "participant":{...}, "permissions":[...] }
```

Obtain the short-lived token from your backend and pass it as `joinToken`. Keep
the admin API key on the backend and keep the token out of logs. For a
password-protected room or a room with a waiting room, handle the
`400`, `401`, and `202` responses before opening the call screen.

## Props

| Prop | Type | Default | Description |
|---|---|---|---|
| `serverUrl` | `string` (required) | — | Base HTTP(S) URL for REST, WebSocket, and static assets. Path prefixes are preserved. For example, `https://host/calls` resolves to `/calls/embed.html`. |
| `roomId` | `string` (required) | — | Room ID. |
| `joinToken` | `string` | — | Short-lived join token. Omit it to display the widget's join screen. |
| `tenantId` | `string` | `demo` | Tenant ID. |
| `participantName` | `string` | — | Display name on the join screen. |
| `role` | `'host' \| 'moderator' \| 'guest'` | — | Role for anonymous entry. |
| `theme` | `'light' \| 'dark' \| 'auto'` | — | Color scheme. The full theme comes from the server. |
| `language` | `'ru' \| 'en'` | From configuration | Widget locale. |
| `identityToken` | `string` | — | Corporate OIDC token passed in the `identity_token` URL parameter. |
| `relayOnly` | `boolean` | `false` | Require TURN relay connectivity (`relay=1`). |
| `widgetPath` | `string` | `embed.html` | Path relative to `serverUrl`. A leading slash resolves from the domain root. |
| `allowInsecure` | `boolean` | `false` | Allow plain HTTP for non-loopback hosts during development. By default, plain HTTP is permitted only for loopback or `10.0.2.2`. |
| `permissions` | `{ camera?: boolean; microphone?: boolean }` | Both `true` | Media permission preferences. Android requests runtime permissions and WKWebView uses the iOS system prompt. |
| `requestPermissionsOnMount` | `boolean` | `true` | Request Android permissions when the component mounts. |
| `readyTimeoutMs` | `number` | `20000` | Milliseconds to wait for `agil:ready`. Set `0` to disable the timeout. |
| `limits` | `{ maxParticipants?: number }` | `{ maxParticipants: 200 }` | Limit on tracked participant IDs. The SDK emits a snapshot and subsequent deltas. |
| `allowedOrigins` | `readonly string[]` | `[]` | Additional exact origins for navigation, such as a corporate SSO endpoint. |
| `onEvent` | `(event: AgilCallEvent) => void` | — | Receives call events. |
| `onError` | `(error: AgilCallError) => void` | — | Receives bridge, loading, permission, and widget errors. Widget errors also reach `onEvent`. |
| `onExternalLink` | `(url: string) => void` | — | Receives blocked external HTTP(S) links. The host app can open them in the system browser. |
| `safeAreaInsets` | `{ top?, right?, bottom?, left? }` | — | Safe-area insets, for example from `useSafeAreaInsets()`. Android WebView does not support CSS `env(safe-area-inset-*)`. |
| `style` | `StyleProp<ViewStyle>` | — | Style for the outer container. |
| `testID` | `string` | — | Identifier for automated tests. |

`permissions` expresses the app's requested media access. Platform and browser
permission rules still apply. If you disable both camera and microphone, the
component sets `mediaCapturePermissionGrantType="deny"`. For mixed requests,
`react-native-webview` cannot grant only one of the requested streams, so the
component leaves the decision to the WebView. Verify this behavior in your
app and widget. The Capacitor plugin handles permissions separately on
Android and rejects a combined request on iOS if one permission is denied.

The component validates its props before loading the WebView. Invalid
configuration renders a text fallback and calls `onError` with
`{ code: 'invalid-config', fatal: true }`. The error message omits the token.

## Events

| `event.type` | Payload | When it fires |
|---|---|---|
| `ready` | `capabilities`, `room?`, `server?` | The widget is mounted and the bridge is ready. |
| `joined` | `payload?` | A participant joined the room. |
| `left` | `payload?` | A participant left the room. |
| `chat` | `message: AgilChatMessage` | A chat message arrived, including through external chat. |
| `error` | `error: AgilCallError` | The widget reported an error with `code: 'widget-error'`. |
| `state` | `state: AgilCallState` | Periodic state snapshot. Participant state is represented by `participantCount` and `participantRevision`. |
| `participants` | `participants: ParticipantUpdate` | One initial snapshot per load (up to 200 IDs with default settings), followed by `added` and `removed` deltas. |
| `connection` | `connection: ConnectionUpdate` | A deduplicated reconnect update with `state`, `previous`, `attempt`, and `delayMs`. |
| `minimized` / `fullscreen` | `boolean` | The minimized or fullscreen state changed. |
| `event` | `name`, `payload?` | Other widget events, including `participant-joined`, `quality-changed`, `connection-state`, and `action-denied`. |

Failures outside the widget reach `onError` only. These include load, HTTP,
timeout, navigation, and permission errors.

## Imperative API

```tsx
const call = useRef<AgilCallHandle>(null);

call.current?.sendAction('toggle-mic');      // toggle-mic | toggle-camera | leave | …
call.current?.sendChat('Hello');
call.current?.setThemeScheme('dark');       // Apply without reloading the WebView.
call.current?.applyTheme({ colors: { primary: '#0b5fff' } });
call.current?.applyConfig({ layout: { controlsStyle: 'minimal' } });
call.current?.ping();
call.current?.reload();                     // Recover after a renderer or network error.
call.current?.reconnect();                  // Reload, emit a connection event, and rotate the nonce.
```

The bridge queues up to 50 actions before `ready` and sends them after
`agil:ready`. Unknown actions and invalid themes are reported through `onError`.

## Deep links

```ts
import { Linking } from 'react-native';
import { buildCallDeepLink, parseAgilCallLink } from '@agil/calls-react-native';

// A link for email, QR codes, or push notifications. It carries a short-lived join token.
const url = buildCallDeepLink(
  { serverUrl: 'https://calls.example.com', tenantId: 'acme', roomId: 'daily-sync', joinToken: token },
  'myapp',
);
// myapp://call?server=…&room=daily-sync&tenant=acme&token=…

const initial = await Linking.getInitialURL();
const link = initial
  ? parseAgilCallLink(initial, { allowedOrigins: ['https://calls.example.com'], allowedSchemes: ['myapp'] })
  : null;

if (link) {
  // Pass the relevant fields to <AgilCall />. The result contains
  // { kind, serverUrl, roomId, joinToken?, tenantId?, … }.
}
```

`parseAgilCallLink` accepts `/embed.html?…` and `myapp://call?…`. For
HTTP(S) links, the `server` parameter must match the link's origin and path
so the join token stays on the intended host. The parser rejects
`javascript:`, `file:`, unknown schemes, missing `room` values, overly
long parameters, and control characters. Always pass an
`allowedOrigins` list of trusted servers when parsing a custom scheme.

The component restricts WebView navigation to `serverUrl` and
`allowedOrigins`. The app can open a blocked HTTP(S) link in the system
browser through `onExternalLink` and `Linking.openURL`.

For server-side scripts that generate notifications, email, or QR codes, use
the URL subpath to avoid importing React Native.

```ts
import { buildCallDeepLink, buildWidgetUrl } from '@agil/calls-react-native/url';
```

## Native configuration

### iOS and WKWebView

Add the usage descriptions to `Info.plist` before requesting camera or
microphone access. iOS terminates an app that requests these resources without
the corresponding descriptions.

```xml
<key>NSCameraUsageDescription</key>
<string>Allow camera access for video calls.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Allow microphone access for calls.</string>
```

- WKWebView shows the system permission prompt. The `permissions` prop
  reflects the app's media preferences.
- The component sets `allowsInlineMediaPlayback` and
  `mediaPlaybackRequiresUserAction={false}`. Its standard capture policy is
  `mediaCapturePermissionGrantType="grant"`.
- The web widget uses CSS `env(safe-area-inset-*)`. For more reliable insets,
  pass `safeAreaInsets` from `react-native-safe-area-context`.
- WKWebView does not expose screen sharing through `getDisplayMedia`.

### Android and AndroidX WebView

Add the following declarations to `AndroidManifest.xml`.

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-feature android:name="android.hardware.camera" android:required="false" />
```

- The component requests `CAMERA` and `RECORD_AUDIO` through
  `PermissionsAndroid` on mount when `requestPermissionsOnMount` is enabled.
- The WebView must handle `onPermissionRequest` for
  `RESOURCE_VIDEO_CAPTURE` and `RESOURCE_AUDIO_CAPTURE`.
  `react-native-webview` 13+ handles these requests after the app receives
  runtime permissions. A custom WebView needs its own
  `WebChromeClient.onPermissionRequest` implementation.
- For autoplay, the component enables `allowsInlineMediaPlayback` and sets
  `mediaPlaybackRequiresUserAction={false}`.
- For HTTP during development, use `android:usesCleartextTraffic="true"`
  or a development network security configuration. Use HTTPS in production.
- From the emulator, use `serverUrl: 'http://10.0.2.2:8787'`. From a physical
  device, use the host machine's LAN address and configure the corresponding
  app and network settings.

### Expo config plugin

```json
{
  "expo": {
    "scheme": "myapp",
    "plugins": [
      [
        "@agil/calls-react-native/expo-plugin",
        {
          "cameraPermission": "Allow camera access for video calls.",
          "microphonePermission": "Allow microphone access for calls."
        }
      ]
    ]
  }
}
```

The config plugin adds the iOS usage descriptions and the Android
`uses-permission` and `uses-feature` declarations. It ships without native
binaries. Expo Go uses its standard WebView and usage descriptions. Your
custom descriptions take effect in development and production builds made with
`expo prebuild` or EAS Build.

## Build and test

Run the workspace commands from the mobile repository root.

```bash
npm run typecheck -w @agil/calls-react-native   # tsc --noEmit for source and tests
npm test -w @agil/calls-react-native            # URL, bridge, and rendering tests
npm run build -w @agil/calls-react-native       # dist/ (ESM) and dist/cjs/ (CJS)
npm pack --dry-run -w @agil/calls-react-native  # Inspect the files included in the package.
```

The build emits ESM at `dist/index.js`, CommonJS for Metro and older
resolvers at `dist/cjs/index.js`, and declarations at `dist/index.d.ts`.
React, React Native, and WebView remain peer dependencies.

## Publish

```bash
npm run build -w @agil/calls-react-native
# Publish to an internal registry:
npm publish -w @agil/calls-react-native --access restricted
# For a public registry, use --access public when the applicable license permits it.
```

Before publishing, update `version` in `package.json` and in `src/index.ts`,
then run type checks, tests, and `npm pack --dry-run` for the workspace.
The wrapper itself requires no additional CocoaPods or Gradle plugin. See
the project license for distribution terms. [License](../../../LICENSE)

## Limitations

- Calls run in Chromium WebView or WKWebView. The web widget provides call UI,
  media, and access rules. Native LiveKit integration, CallKit, and push
  notifications are future work.
- iOS and Android can suspend the WebView when the app enters the background.
  Incoming calls and system call UI require native integration.
- Mobile WebViews do not expose screen sharing through `getDisplayMedia`.
- Recording downloads and the file picker require native handling in the host app.
- Older Android WebView releases or custom device firmware may lack WebRTC,
  `enumerateDevices`, or autoplay support. Test on your target devices.
- Pages in the WebView can see `ReactNativeWebView`. The shim attaches a nonce
  to forwarded messages so direct `postMessage` calls from an SSO origin
  are rejected. The bridge redacts `token`, `identity_token`,
  `access_token`, and JWTs from widget errors.
- Join tokens can appear in WebView URLs and history. Use a short TTL and
  HTTPS, keep URLs out of logs, and clear WebView data at sign-out.
- Opening a deep link starts a new call screen. Obtain a fresh token after
  the operating system stops the app process.
- Keep one active call screen on lower-powered devices.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `timeout` in `onError` | Open `/embed.html` in a browser. Check `serverUrl`, the TLS certificate, CSP, and `onHttpError`. The WebView may have failed to inject the bridge. |
| Video works and events are missing | Update `react-native-webview`. The component also injects `createBridgeShimScript()` after `onLoadEnd` if the initial injection fails. |
| `permission-denied` on Android | Check the manifest and runtime permissions. Use `openAppSettings()` if permission is blocked. |
| The app closes when joining on iOS | Check `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`. |
| Black screen | Check plain HTTP, mixed content, and self-signed certificates. Serve production calls over HTTPS. |
| `navigation-blocked` | Add the target origin to `allowedOrigins` if it is trusted, or handle `onExternalLink` in the host app. |
| No audio in the background | Background audio requires native media integration. |

See the guide for the broader mobile integration, test coverage, and platform
limitations. [Mobile integration guide](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/mobile.md)

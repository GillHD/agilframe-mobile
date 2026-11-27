# AGIL Mobile

Native and hybrid wrappers around the hosted widget (`/embed.html`). Call media
runs in the system WebView; the wrapper only builds a safe URL and bridges
`postMessage` events/actions.

```
mobile/
├─ react-native   @agil/calls-react-native   RN WebView wrapper + Expo plugin
├─ capacitor      @agil/calls-capacitor      Capacitor plugin (iOS/Android)
├─ ios            native Swift package (AgilCall), no npm package.json
├─ android        native Android library (Kotlin), no npm package.json
└─ flutter        Flutter plugin, no npm package.json
```

`ios`, `android` and `flutter` are intentionally outside npm workspaces (the
root `agil/mobile/*` glob only picks up directories with a `package.json`).
They are built by their native toolchains (`swift build`, Gradle, `flutter test`).

## Commands (from the repository root)

```bash
npm run build:mobile              # @agil/calls-react-native
npm run build:capacitor           # @agil/calls-capacitor
npm test -w @agil/calls-react-native
npm test -w @agil/calls-capacitor
```

Native wrappers must stay on the published embed contract:
`agil/core/docs/contract.md` §7 and `agil/websdk/embed/src/bridge.ts`.

## Large rooms (Stage 3b)

WebView shells support up to 200 participants without forwarding the widget's
full `participantIds` array on every tick: the SDK keeps the set and exposes one
bounded snapshot plus deltas, and deduplicates reconnect transitions. See
[`agil/core/docs/webview-large-rooms.md`](../core/docs/webview-large-rooms.md).

Static native checks (no Xcode/Android toolchain required):

```bash
node agil/mobile/ios/scripts/webview-large-rooms-check.mjs
node agil/mobile/android/scripts/webview-large-rooms-check.mjs
```

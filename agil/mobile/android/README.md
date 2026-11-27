# AgilFrame — Android SDK (`agil-calls`)

Tier-1 Android module for the hosted AgilFrame widget: a native `AgilCallView`
around `/embed.html`, typed events/commands, a hardened origin guard and a small
join API. **WebView integration, not native WebRTC.**

- Core library: `com.agilcalls:agil-calls:0.1.0` (Kotlin, minSdk 26, compileSdk 35)
- Optional Compose wrapper: `com.agilcalls:agil-calls-compose:0.1.0`
- Example app: `:example`
- Full guide: [`agil/core/docs/android-sdk.md`](../../core/docs/android-sdk.md)

## Quick start

```kotlin
val call = AgilCallView(activity).apply {
    listener = AgilCallEventListener { event ->
        when (event) {
            is AgilCallEvent.Ready -> Unit
            is AgilCallEvent.Joined -> Unit
            is AgilCallEvent.Left -> Unit
            is AgilCallEvent.Chat -> Unit
            is AgilCallEvent.State -> Unit
            is AgilCallEvent.Participants -> Unit   // snapshot/delta, ≤200 id
            is AgilCallEvent.Connection -> Unit     // reconnect state
            is AgilCallEvent.Error -> showError(event.error)
            is AgilCallEvent.Generic -> Unit
        }
    }
    externalLinkHandler = { url -> openInBrowser(url) }
    load(
        AgilCallConfig(
            serverUrl = "https://calls.example.com",
            room = "team-sync",
            token = joinToken,       // short-lived; never log it
        ),
    )
}
setContentView(call)
```

Forward Activity lifecycle and permissions:

```kotlin
override fun onResume() { super.onResume(); call.onResume() }
override fun onPause() { call.onPause(); super.onPause() }
override fun onDestroy() { call.release(); super.onDestroy() }

override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray,
) {
    if (!call.onRequestPermissionsResult(requestCode, permissions, grantResults)) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}

override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    if (!call.onActivityResult(requestCode, resultCode, data)) {
        super.onActivityResult(requestCode, resultCode, data)
    }
}
```

Import `android.content.Intent` for the document picker callback. The call can
open the Android picker for chat attachments and custom camera backgrounds.

Need a token? `AgilClient` performs `POST /v1/rooms/{room}/join` on an executor:

```kotlin
val client = AgilClient(AgilClientConfig("https://calls.example.com"))
client.join("team-sync", AgilJoinRequest(name = "Anna"), object : AgilJoinCallback {
    override fun onJoined(result: AgilJoinResult) {
        when (result) {
            is AgilJoinResult.Joined ->
                call.load(AgilCallConfig("https://calls.example.com", "team-sync", result.token))
            // Waiting room enabled on the tenant: HTTP 202, no token yet.
            is AgilJoinResult.Pending -> showLobby(result.requestId, result.pollAfterMillis)
        }
    }
    override fun onError(error: AgilJoinException) = showError(error.message)
})
```

OIDC/SSO tenants pass `AgilJoinRequest(identityToken = …)` and/or
`AgilCallConfig(identityToken = …)`; `role = AgilRole.MODERATOR` adds the
documented `role=` hint. Tokens are never logged and are masked in
`toString()`/`redactedUrl`.

## Bluetooth headsets

The SDK declares `BLUETOOTH` through Android 11 for WebView calls with paired
headsets. On Android 12 and later, a host app that supports paired Bluetooth
headsets must declare `BLUETOOTH_CONNECT` and request Nearby devices access
from the user before opening a call with the headset.

## System bars and fullscreen

The example activity draws behind the Android system bars and pads controls
for the cutout, navigation and keyboard insets. The bars use the hosted call's
resolved light or dark scheme. The system bars are hidden when the user opens
native fullscreen and return after leaving it. In an app using the SDK,
`nativeFullscreenListener` signals the native transition,
`exitNativeFullscreen()` handles a host Back action and `readRenderedTheme()`
reads the call's current scheme for host chrome.

The example keeps routine diagnostic events out of the call viewport.
Add `--ez show-call-diagnostics true` to the ADB activity command to display
the status row for QA.

## Build

No Gradle wrapper is committed. Use JDK 17 and Gradle 8.9+:

```bash
cd agil/mobile/android
gradle :agil-calls:testDebugUnitTest
gradle :agil-calls:assembleRelease
gradle :agil-calls-compose:assembleRelease
gradle :example:assembleDebug
gradle :agil-calls:publishToMavenLocal
```

Set `JAVA_HOME` to JDK 17 and `ANDROID_HOME`/`sdk.dir` to an SDK with platform
35 and build-tools 35.0.0. AGP 8.7.3 + Kotlin 2.1.0.

> This checkout's environment has JDK 8, no Gradle 8 and only Android platform
> 31, so the Gradle/AGP build was **not** run here. The sources were compiled
> manually with a cached Kotlin 1.6 compiler against `android-31/android.jar`,
> and 68 pure-JVM JUnit tests pass. The injected bridge shim was executed
> headlessly in Node (`node agil/mobile/android/scripts/shim-smoke.mjs`); the Compose wrapper was
> type-checked against minimal Compose API stubs (not a real Compose compile).
> See the verification note in [`agil/core/docs/android-sdk.md`](../../core/docs/android-sdk.md).

## What it does

| Area | Behavior |
|---|---|
| URL | `https://host[/subpath]/embed.html?server&room&token&identity_token&tenant&role&lang&name&theme&relay`; validated, token-free errors |
| Events | ready, joined, left, chat, state, error, generic events (main thread) |
| Commands | mic/camera/chat/screen-share/blur/minimize/restore/pip/fullscreen/new-tab/leave/raise/reaction, chat, theme/config patches, ping, reload |

Use `AgilCallEvent.Ready.capabilities.screenShare` to decide whether to show a host
control for starting screen capture. The room's screen sharing permissions still
apply. If the room allows sharing but the WebView has no display-capture API,
`toggleScreenShare()` reports a non-fatal `AgilCallError.ActionDenied` with action
`share-screen` and reason `screen-share-unavailable`. The view can still play a
screen shared by another participant.
| Security | HTTPS except numeric dev hosts; exact origin allowlist; per-load nonce bridge envelope; TLS errors cancelled; mixed content off; no logs; token redaction |
| Permissions | `WebChromeClient.onPermissionRequest` + Activity runtime prompt + grant/deny (widget origin only) |
| UI | safe-area/window-inset padding, autoplay setting, dark background |
| Join API | `HttpURLConnection` + executor, 200 `Joined` / 202 `Pending`, `identityToken`, timeouts, cancellation, typed `AgilJoinException` |
| ProGuard | consumer rules keep public API and `@JavascriptInterface` methods |

## Limitations

- Not native WebRTC; media runs in the Android WebView.
- `Ready` capabilities can be missed if the widget posts `agil:ready` before
  the injected shim (recovered via ping/pong for commands).
- Screen share/PiP are unsupported in WebView; `raise-hand`/`reaction` are
  extension actions that a hosted page may answer with `action-denied`.
- A partial camera/microphone grant denies both resources.
- Token/identity token are in the `/embed.html` query string (embed contract):
  HTTPS + short TTL.
- No instrumentation/device tests were executed here.

## Layout

```
agil/mobile/android/
  settings.gradle.kts, build.gradle.kts, gradle.properties
  agil-calls/              core AAR (Kotlin, no runtime deps)
  agil-calls-compose/      optional AgilCall composable
  example/                 example Activity app
```

License: proprietary (AgilFrame); see the repository owner.

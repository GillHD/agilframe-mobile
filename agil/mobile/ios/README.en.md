# AgilCallsSDK for iOS

[Русский](README.md) · **English**

The iOS SDK hosts AgilFrame's `/embed.html` widget in `WKWebView`. It provides the `ready`, `joined`, `left`, `chat`, `error`, and `state` events, commands for microphone, camera, chat, theme, and leaving a call, and an `AgilClient` for `POST /v1/rooms/:id/join`. The package includes SwiftUI and UIKit views and a privacy manifest.

The hosted widget handles media, chat, themes, and participants. The SDK manages the screen, WebView bridge, navigation, permissions, and the REST join request. [iOS SDK guide](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/ios-sdk.md)

## Requirements

- iOS 14.3 or later and Xcode 15 or later.
- Swift 5.7 or later and Swift Package Manager.
- The system frameworks `WebKit`, `AVFoundation`, `SwiftUI`, and `UIKit`.
- HTTPS in production. HTTP is available for loopback or with an explicit development flag.

## Install

In Xcode, choose **File → Add Package Dependencies → Add Local**. Select `agil/mobile/ios` from the Mobile SDK checkout and add the `AgilCallsSDK` product to your application target.

## Quick start

```swift
import AgilCallsSDK

let configuration = try AgilCallConfiguration(
    serverURL: URL(string: "https://calls.example.com")!,
    tenantId: "acme",
    roomId: "support-42",
    joinToken: joinToken,          // Issued by your integration backend.
    participantName: "Alice",
    theme: .dark,
    language: "en"
)

// SwiftUI
AgilCall(configuration: configuration) { event in
    if case .joined = event { print("joined") }
}
.ignoresSafeArea()

// UIKit
let controller = AgilCallViewController(configuration: configuration)
controller.dismissOnLeave = true
controller.present(from: self)
```

Use `AgilClient` to join rooms that allow joining through the public API. Keep administrative API keys on your integration backend.

```swift
let client = try AgilClient(serverURL: URL(string: "https://calls.example.com")!)
switch try await client.join(roomId: "support-42", name: "Alice") {
case .joined(let result):
    let configuration = try AgilCallConfiguration(
        serverURL: client.serverURL,
        tenantId: result.room.tenantId ?? "acme",
        roomId: result.room.id,
        joinToken: result.joinToken
    )
case .waitingRoom(let ticket):
    print("lobby", ticket.requestId)
}
```

Add `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` to the application's `Info.plist`.

`language` accepts BCP 47 tags and normalizes them to `ru` or `en`. For example, `en-US` becomes `en`. `identityToken` is sent to `/embed.html` as the `identity_token` query parameter. Use short-lived tokens and avoid logging the embed URL. [Embed contract](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/contract.md)

### Large rooms

The default `maxParticipants: 200` enables the large-room participant digest. The SDK tracks participant IDs and emits one bounded `AgilCallEvent.participants` snapshot per load, followed by `added` and `removed` deltas. `AgilCallEvent.connection` deduplicates reconnect events using `state`, `attempt`, and `delayMs`. `reload()` and `reconnect()` retain the server, room, and participant token and rotate the bridge nonce. [Large-room WebView behavior](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/webview-large-rooms.md)

## Package contents

| File or directory | Purpose |
| --- | --- |
| `AgilCallConfiguration.swift`, `AgilValidation.swift` | Validated configuration, URL and origin checks, and token-free configuration errors |
| `AgilWidgetURL.swift`, `AgilRedaction.swift` | Embed URL construction, navigation allowlist, and token redaction |
| `AgilBridge.swift` | `agil:*` event parsing and sanitization, commands, and the JavaScript bridge |
| `AgilClient.swift` | Async REST join and typed errors |
| `AgilPermissions.swift` | Camera and microphone permission checks through AVFoundation |
| `AgilCallView.swift` | UIKit WebView host, events and commands, and safe-area handling |
| `AgilCallViewController.swift` | Fullscreen UIKit controller |
| `AgilCall.swift` | SwiftUI `UIViewRepresentable` wrapper |
| `PrivacyInfo.xcprivacy` | Privacy manifest for the SDK package |
| `Tests/AgilCallsSDKTests` | XCTest coverage for configuration, URLs, redaction, bridge, client, and JSON |
| [SwiftUI example](Example/README.md) | Demo application and XcodeGen specification |
| [Changelog](CHANGELOG.md) | Package history |

## Build and test on macOS

Run the repository's build and simulator test script with Xcode and a matching simulator installed.

```sh
cd agil/mobile/ios
bash scripts/ci.sh
```

The script describes the package, builds for a generic iOS device with signing disabled, and runs the tests in the simulator. Set `SCHEME=AgilCallsSDK-Package` if Xcode exposes the scheme with that suffix. Use `SIMULATOR` to select another installed device.

The previous Windows verification used a temporary Foundation-only Swift package on Linux. It recorded 63 passing XCTest cases, a JavaScript bridge test with Node.js, and syntax checks of the UI files. An iOS build and simulator run require macOS and Xcode.

## Security and permissions

- In production, use HTTPS for `serverURL` and every entry in `allowedOrigins`. Use the insecure HTTP override only for development. The allowlist matches exact origins. Credentials, query strings, and fragments are rejected in origin values.
- The SDK redacts tokens from errors, configuration descriptions, JavaScript source, and logs. The hosted widget's URL carries `token` and `identity_token`, so use short-lived tokens and omit that URL from logs.
- Commands use the exact widget origin. Incoming `agil:*` messages must come from the main frame, match the widget origin, and contain the current load's nonce. The bridge sanitizes the payload.
- The WebView uses `WKWebsiteDataStore.nonPersistent()` by default. External navigation and popups are blocked.
- On iOS 15 or later, the WebView can apply the SDK's media capture policy to requests from the trusted origin. On iOS 14.3 through 14.x, WebKit uses the system prompt. Supply the usage strings and check permissions in the application. [iOS SDK guide](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/ios-sdk.md)

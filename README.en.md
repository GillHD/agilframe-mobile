# AgilFrame Mobile SDK

[Русский](README.md) · **English**

Mobile components for embedding AgilFrame calls in an application. They open the `/embed.html` widget hosted by Core in a system WebView and relay commands and events between the application and the widget.

[Project overview](https://github.com/GillHD/agilframe) · [AgilFrame Core](https://github.com/GillHD/agilframe-core) · [Integration guide](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/mobile.md)

## Components

| Platform | What to integrate |
| --- | --- |
| [Android](agil/mobile/android/README.md) | Kotlin libraries for Android Views and Jetpack Compose |
| [iOS](agil/mobile/ios/README.en.md) | The `AgilCallsSDK` Swift package and a SwiftUI example |
| [Flutter](agil/mobile/flutter/README.en.md) | The `agil_calls` plugin |
| [Capacitor](agil/mobile/capacitor/README.en.md) | The `@agil/calls-capacitor` plugin |
| [React Native](agil/mobile/react-native/README.en.md) | The `@agil/calls-react-native` component and Expo config plugin |

To start a call, pass the Core URL, room details, and a participant token to the application. [Original component revision](https://github.com/GillHD/agilframe-core/commit/85f084e1c12e63a56be718622f568170b6c0f9b8)

## Build and test

For React Native and Capacitor, install Node.js 22 or later and run these commands from the repository root.

```sh
npm ci
npm run build
npm run typecheck
npm test
```

For Android, use JDK 17, Gradle 8.9, and Android SDK 35. Build from `agil/mobile/android`. [Android commands](agil/mobile/android/README.md) · [CI configuration](.github/workflows/ci-android.yml)

For Flutter, run `flutter pub get`, `flutter analyze`, and `flutter test` from `agil/mobile/flutter`. For iOS, use Xcode. [Flutter guide](agil/mobile/flutter/README.en.md) · [iOS guide](agil/mobile/ios/README.en.md)

## Contributing and license

[Contributing](CONTRIBUTING.en.md) · [Security](SECURITY.en.md) · [License](LICENSE) · [Notices](NOTICE)

# AgilCallsSDK (iOS)

Нативный iOS-модуль AgilFrame уровня P1: `WKWebView`-обёртка
hosted-виджета `/embed.html`, события `ready/joined/left/chat/error/state`,
команды mute/camera/chat/theme/leave, `AgilClient` для
`POST /v1/rooms/:id/join`, SwiftUI/UIKit-интеграция и privacy manifest.

> **Это не нативный WebRTC-клиент.** Медиа, чат, темы и участники выполняются
> hosted-виджетом на домене AgilFrame. SDK владеет экраном, мостом, навигацией,
> разрешениями и REST join-запросом. Ограничения — в
> [`agil/core/docs/ios-sdk.md`](../../core/docs/ios-sdk.md).

## Требования

- iOS **14.3+** (первая версия с `getUserMedia` в WKWebView), Xcode 15+;
- Swift 5.7+ (async/await), SwiftPM;
- только системные фреймворки: `WebKit`, `AVFoundation`, `SwiftUI`, `UIKit`;
- HTTPS в продакшене (HTTP — только loopback или явный dev-флаг).

## Установка

SwiftPM (Xcode → File → Add Package Dependencies → Add Local…):

```swift
// Package.swift приложения
dependencies: [
    .package(path: "../VideoCalls/packages/ios") // или git URL + from: "0.1.0"
],
targets: [
    .target(name: "App", dependencies: ["AgilCallsSDK"])
]
```

## Быстрый старт

```swift
import AgilCallsSDK

let configuration = try AgilCallConfiguration(
    serverURL: URL(string: "https://calls.example.com")!,
    tenantId: "acme",
    roomId: "support-42",
    joinToken: joinToken,          // выпускается на вашем backend
    participantName: "Alice",
    theme: .dark,
    language: "ru"
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

Токен через REST (токен выпускается сервером, в приложении не должно быть
admin API key):

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

`Info.plist` приложения обязан содержать `NSCameraUsageDescription` и
`NSMicrophoneUsageDescription`.

`language` принимает BCP-47, но нормализуется к `ru`/`en` (например, `en-US` →
`en`). `identityToken` передаётся в URL страницы как `identity_token` — это
контракт `/embed.html` (`agil/core/docs/contract.md` §7); используйте короткоживущие
токены и не логируйте URL.

### Large rooms (до 200 участников)

`maxParticipants: 200` (по умолчанию) включает large-room digest: SDK держит
набор id и отдаёт `AgilCallEvent.participants` — один ограниченный snapshot за
загрузку и дальше только `delta` (`added`/`removed`), а не 200-id массив на
каждый `agil:state`. `AgilCallEvent.connection` дедуплицирует reconnect
(`state`, `attempt`, `delayMs`); `reload()`/`reconnect()` сохраняют
server/room/join-token, но ротируют bridge nonce. Подробнее:
[`agil/core/docs/webview-large-rooms.md`](../../core/docs/webview-large-rooms.md).

## Что внутри

| Файл | Назначение |
|---|---|
| `AgilCallConfiguration.swift` | валидированный конфиг + token-free `AgilConfigurationError` |
| `AgilValidation.swift` | чистая валидация URL/полей/origin, канонизация |
| `AgilWidgetURL.swift` | сборка `/embed.html?...` и navigation allowlist |
| `AgilRedaction.swift` | маскирование токенов/JWT в логах и ошибках |
| `AgilBridge.swift` | парсер/санитайзер `agil:*`, команды, JS-шим `AgilBridge` |
| `AgilClient.swift` | async/await `POST /v1/rooms/:id/join`, typed errors |
| `AgilPermissions.swift` | AVFoundation preflight камеры/микрофона |
| `AgilCallView.swift` | `UIView` + `WKWebView`, события, команды, safe-area |
| `AgilCallViewController.swift` | полноэкранный UIKit-контроллер |
| `AgilCall.swift` | SwiftUI `UIViewRepresentable` |
| `PrivacyInfo.xcprivacy` | privacy manifest: no tracking / no data collection |
| `Tests/AgilCallsSDKTests` | XCTest конфигурация/URL/redaction/мост/клиент/JSON |
| `CHANGELOG.md` | изменения 0.1.0 (unreleased); `LICENSE` пока нет — добавьте для standalone-репозитория |
| `Example` | SwiftUI demo + XcodeGen spec (`path: ..`) |

## Сборка и тесты (macOS)

```bash
cd agil/mobile/ios
swift package describe
xcodebuild -list -json
xcodebuild -scheme AgilCallsSDK -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme AgilCallsSDK -destination 'platform=iOS Simulator,name=iPhone 15' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

Если Xcode сгенерировал суффиксный scheme: `-scheme AgilCallsSDK-Package`.
Готовый скрипт: `bash agil/mobile/ios/scripts/ci.sh`.

**Проверка в текущем окружении.** Windows-хост без Xcode/Apple SDK, поэтому
UIKit/WebKit/SwiftUI-слой не собирался. Foundation-only ядро собрано Swift
5.10.1 на Linux (временный SwiftPM-пакет), **63/63 XCTest прошли**
(14 `AgilCallConfiguration`, 13 `URL/redaction`, 21 `AgilBridge`,
14 `AgilClient`, 1 `AgilJSONValue`), JS-шим проверен Node.js-харнессом.
UI-файлы прошли `swiftc -parse`. Команды выше — для macOS/CI; iOS-сборка и
симуляторные тесты обязательны перед публикацией.

## Безопасность (кратко)

- только `http(s)`; HTTPS обязателен для `serverURL` и `allowedOrigins`, кроме
  loopback или явного `allowsInsecureHTTP`;
- exact-origin allowlist (без `*`), credentials/query/fragment запрещены;
- токены не попадают в ошибки, описания, JS-исходники и логи SDK;
- `token`/`identity_token` передаются в URL страницы, потому что это контракт
  embed (`agil/core/docs/contract.md` §7); используйте короткоживущие токены;
- host → page команды используют точный `window.location.origin`, никогда `*`;
- входящие `agil:*` сообщения принимаются только из main frame с
  `frameInfo.securityOrigin == widgetOrigin` и только с текущим per-load nonce
  (allowlisted SSO origin не может подделать события), payload санитайзится;
- WebView по умолчанию использует `WKWebsiteDataStore.nonPersistent()`;
- внешняя навигация и popup блокируются; камера/микрофон выдаются только
  доверенному origin в рамках `AgilMediaCapture` на iOS 15+. На iOS 14.3–14.x
  delegate-хука нет: `allowedMediaCapture` не отменяет системный prompt —
  нужны usage strings и проверка разрешений в приложении.

Подробно: [`agil/core/docs/ios-sdk.md`](../../core/docs/ios-sdk.md).

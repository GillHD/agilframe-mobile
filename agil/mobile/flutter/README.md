# agil_calls (Flutter)

Flutter-обёртка AgilFrame: `AgilCall` открывает hosted-виджет `/embed.html` в
WebView, прокидывает события через `postMessage`-мост `AgilBridge` и даёт
императивный `AgilCallController` для команд (микрофон, камера, чат, тема).

> **Статус: P1, WebView-интеграция.** Это не нативный WebRTC-клиент. Медиа, чат,
> темы и права выполняет веб-виджет на домене AgilFrame; приложение владеет
> только экраном, навигацией и каналом `AgilBridge`. Ограничения и план перехода
> на нативный стек — в `agil/core/docs/flutter-sdk.md` (репозиторий AgilFrame).

## Что внутри

| Файл | Назначение |
|---|---|
| `lib/src/agil_call.dart` | `AgilCall` (StatefulWidget) + `AgilCallController` |
| `lib/src/url.dart` | сборка `/embed.html?...`, разбор ссылок, navigation guard, редакция токенов |
| `lib/src/bridge.dart` | парсинг/санитайзинг `agil:*`, инжект-скрипты, шим `AgilBridge` |
| `lib/src/types.dart` | события, ошибки, capabilities, снимок состояния |
| `test/url_test.dart`, `test/bridge_test.dart` | 33 чистых Dart-тестов (URL/мост) |
| `example/lib/main.dart` | демо-приложение: форма входа, кнопки, лог событий |

## Требования

- Flutter **3.24+**, Dart **3.5+**;
- Android использует `flutter_inappwebview` и `permission_handler`,
  iOS использует `webview_flutter` **4.10+**;
- сервер AgilFrame, отдающий `/embed.html` и статику виджета (новых endpoint'ов
  не требуется);
- iOS **14+** (WebRTC в WKWebView), Android **8+** с обновляемым AndroidX
  WebView (рекомендуется WebView 90+);
- HTTPS в продакшене. HTTP допускается только для `localhost`, `127.0.0.1`,
  `::1`, `10.0.2.2` (Android-эмулятор) или при `allowInsecure: true`
  (исключительно для локальной разработки).

## Установка

Пакет не опубликован в pub.dev. Подключите его путём или git-зависимостью:

```yaml
# pubspec.yaml приложения
dependencies:
  flutter:
    sdk: flutter
  agil_calls:
    path: ../packages/flutter        # локальная копия монорепозитория
    # или:
    # git:
    #   url: https://github.com/agil/video-calls.git
    #   path: agil/mobile/flutter
```

```bash
flutter pub get
```

## Быстрый старт

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
      participantName: 'Анна',
      theme: AgilThemeScheme.auto,
      language: AgilLanguage.ru,
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

Без `joinToken` виджет показывает свой экран входа (имя, камера, микрофон). С
токеном звонок стартует сразу после загрузки.

### Откуда взять joinToken

Нового серверного endpoint'а нет. Используйте существующий
`POST /v1/rooms/:roomId/join` (см. `agil/core/docs/api.md` §4) на своём backend:

```bash
curl -s -X POST https://calls.example.com/v1/rooms/daily-sync/join \
  -H 'content-type: application/json' \
  -d '{"name":"Анна","locale":"ru"}'
# → { "token":"eyJ...", "expiresAt":..., "participant":{...}, "permissions":[...] }
```

Токен короткоживущий: не храните admin API key в приложении, не логируйте URL и
не передавайте токен через `debugPrint`.

## Props

| Prop | Тип | По умолчанию | Описание |
|---|---|---|---|
| `serverUrl` | `String` (обяз.) | — | База REST/WS и статики, только `http(s)`. Подпуть сохраняется: `https://host/calls` → `/calls/embed.html`. |
| `roomId` | `String` (обяз.) | — | id комнаты. |
| `joinToken` | `String?` | — | Join-token; без него виджет показывает экран входа. |
| `tenantId` | `String` | `demo` | Тенант. |
| `participantName` | `String?` | — | Имя на экране входа. |
| `role` | `AgilRole?` | — | `host` / `moderator` / `guest` для анонимного входа. |
| `theme` | `AgilThemeScheme?` | — | Только схема (`light`/`dark`/`auto`); полная тема приходит с сервера. |
| `language` | `AgilLanguage?` | из конфига | Локаль UI (`ru`/`en`). |
| `identityToken` | `String?` | — | Корпоративный OIDC-токен (`identity_token`). |
| `relayOnly` | `bool` | `false` | Только TURN (`relay=1`). |
| `widgetPath` | `String` | `embed.html` | Путь относительно `serverUrl`; `/embed.html` — от корня домена. |
| `allowedOrigins` | `List<String>` | `[]` | Дополнительные точные origin для навигации (SSO и т.п.). |
| `safeArea` | `bool` | `true` | Обернуть WebView в `SafeArea` (Android WebView не понимает CSS `env(safe-area-inset-*)`). |
| `allowInsecure` | `bool` | `false` | Разрешить `http://` вне loopback. Только для разработки. |
| `readyTimeout` | `Duration` | `20s` | Ожидание `agil:ready`; `Duration.zero` отключает watchdog. |
| `controller` | `AgilCallController?` | — | Императивные команды. |
| `onEvent` | `void Function(AgilCallEvent)` | — | Все события звонка. |
| `onError` | `void Function(AgilCallError)` | — | Ошибки загрузки/моста/навигации; ошибки виджета дополнительно приходят как `AgilErrorEvent`. |
| `onExternalLink` | `void Function(String url)` | — | Навигация за пределы виджета заблокирована; здесь URL можно открыть в браузере. |
| `backgroundColor` | `Color` | `#080D16` | Фон WebView. |

Компонент валидирует props до загрузки WebView. При ошибке конфигурации
рисуется текстовый fallback, а `onError` получает
`{ code: invalid-config, fatal: true }`; токен в сообщения не попадает.

## События

| Событие | Payload | Когда |
|---|---|---|
| `AgilReadyEvent` | `capabilities`, `room?`, `server?` | Виджет смонтирован, мост работает. |
| `AgilJoinedEvent` | `payload?` | Участник вошёл в комнату. |
| `AgilLeftEvent` | `payload?` | Участник вышел. |
| `AgilChatEvent` | `message` | Новое сообщение чата (в т.ч. внешний чат). |
| `AgilErrorEvent` | `error` | Виджет сообщил об ошибке (`widget-error`). |
| `AgilStateEvent` | `state` | Периодический снимок состояния. |
| `AgilMinimizedEvent` / `AgilFullscreenEvent` | `bool` | Мини-режим / fullscreen. |
| `AgilGenericEvent` | `name`, `payload?` | Остальные события: `participant-joined`, `quality-changed`, `action-denied`, … |

Ошибки вне виджета (загрузка, HTTP, таймаут, навигация) приходят только в
`onError`. Сообщения, отправленные до `agil:ready`, буферизуются (до 50) и
уходят после готовности моста.

## Команды

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
controller.sendChat('Привет');    // agil:chat-send
controller.setTheme(AgilThemeScheme.dark);        // agil:scheme, без перезагрузки
controller.applyTheme({'colors': {'primary': '#0b5fff'}}); // agil:theme
controller.applyConfig({'layout': {'controlsStyle': 'minimal'}}); // agil:config
controller.ping();                // agil:ping (ответ agil:pong событий не даёт)
controller.reload();              // перезагрузка WebView + watchdog
controller.isReady;               // true после agil:ready
```

## URL, deep links и безопасность

```dart
import 'package:agil_calls/agil_calls.dart';

// Собрать URL так же, как это делает виджет:
final url = buildWidgetUrl(AgilCallUrlOptions(
  serverUrl: 'https://calls.example.com',
  roomId: 'daily-sync',
  joinToken: token,
  tenantId: 'acme',
));

// Разобрать входящую ссылку (email/QR/push):
final link = parseAgilCallLink(
  incoming,
  allowedOrigins: const ['https://calls.example.com'],
  allowedSchemes: const ['myapp'],
);
```

- `buildWidgetUrl` отклоняет `javascript:`/`file:`, credentials, query/fragment в
  `serverUrl`, `..` в `widgetPath`, токены с пробелами/control-символами;
- `parseAgilCallLink` для http(s) требует, чтобы `server` совпадал с origin и
  путём самой ссылки (нельзя увести токен на чужой хост), а для custom scheme
  **требует** непустой `allowedOrigins`;
- `redactCallUrl`/`redactTokenText`/`redactSecrets` маскируют `token`,
  `identity_token`, `access_token`, `id_token` и JWT-подобные строки; ошибки
  виджета редактируются до `onError`/`onEvent`;
- шим тегирует пересланные сообщения per-load nonce, поэтому прямой
  `AgilBridge.postMessage` со страницы разрешённого SSO-origin’а отклоняется;
- WebView блокирует навигацию за пределы `serverUrl` + `allowedOrigins`.

## Нативная конфигурация

### iOS (WKWebView)

`Info.plist` — без этих строк приложение падает при первом `getUserMedia`:

```xml
<key>NSCameraUsageDescription</key>
<string>Разрешите доступ к камере для видеозвонков</string>
<key>NSMicrophoneUsageDescription</key>
<string>Разрешите доступ к микрофону для звонков</string>
```

WKWebView сам показывает системный prompt; демонстрация экрана
(`getDisplayMedia`) в WKWebView недоступна.

### Android (AndroidX WebView)

`AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-feature android:name="android.hardware.camera" android:required="false" />
```

- `AgilCall` обрабатывает запросы камеры и микрофона, которые Android WebView
  передаёт приложению. Укажите системные разрешения в манифесте приложения.
- Хост может запросить системный доступ заранее по явному действию
  пользователя. В примере для этого есть кнопка «Разрешить камеру и микрофон».
  Она вызывает `await controller.requestAndroidMediaPermissions()`.
  Передайте `camera: false` или `microphone: false`, если нужен доступ только
  к одному устройству. После отказа можно войти и слушать собеседников.
- SDK сверяет origin самого запроса и открытой страницы с `serverUrl`.
  Дополнительные origin для навигации, например SSO, не получают доступ к захвату.
  При отказе Android виджет покажет недоступность камеры или микрофона.
- HTTP только для dev: `android:usesCleartextTraffic="true"` (или
  network-security-config). В проде — HTTPS;
- эмулятор: `serverUrl: 'http://10.0.2.2:8787'`, физическое устройство — IP
  машины в локальной сети.

## Сборка и тесты

```bash
cd agil/mobile/flutter
flutter pub get
flutter analyze
flutter test
```

Пример:

```bash
cd agil/mobile/flutter/example
flutter create --platforms=android --project-name agil_calls_example .
flutter pub get
flutter build apk --debug
flutter run -d <android-device>
```

После генерации Android-хоста добавьте разрешения из примера выше в его
`android/app/src/main/AndroidManifest.xml`. Для локального Core и физического
устройства через USB используйте `adb reverse tcp:8787 tcp:8787` и адрес
`http://localhost:8787`. Разрешение cleartext задайте только для debug-сборки.

## Ограничения

- **Не нативный WebRTC.** Звонок идёт в Chromium WebView/WKWebView; UI, медиа и
  права — веб-виджет. Нативный LiveKit + CallKit/ConnectionService — следующий
  этап.
- **Инъекция шима.** На Android мост подключается в начале загрузки документа.
  На iOS `webview_flutter` 4.x не предоставляет
  `injectJavaScriptBeforeContentLoaded`, поэтому шим ставится в
  `onPageStarted` + `onPageFinished` + повтор через 250 мс. Сообщение
  `agil:ready`, отправленное до установки шима, может быть потеряно (тогда
  команды разбудятся первым же `agil:state`/`agil:event`); сама сессия при этом
  работает.
- **Нет фонового режима/CallKit/push.** При уходе в фон ОС может приостановить
  WebView; входящие звонки и системный Call UI не поддерживаются.
- **Нет screen share** (`getDisplayMedia` недоступен в WKWebView/мобильном
  WebView).
- **Токен в URL.** Join-token виден в URL/истории WebView: короткий TTL, HTTPS,
  не логировать URL, очищать данные WebView при выходе из аккаунта.
- **Один активный звонок на экран.** Не монтируйте несколько `AgilCall`
  одновременно на слабых устройствах.
- **Deep links** приложение регистрирует само; пакет предоставляет только
  безопасный разбор ссылки.

## Troubleshooting

| Симптом | Причина/решение |
|---|---|
| `timeout` в `onError` | `/embed.html` не загрузился: CSP/сертификат, неверный `serverUrl`, HTTP на iOS. Проверьте URL в браузере. |
| Событий нет, видео идёт | Шим не установился до `agil:ready`; обновите `webview_flutter`, проверьте, что используется `WebViewWidget` и JavaScript включён. |
| `permission-denied` на Android | Проверьте манифест и разрешения камеры и микрофона в настройках приложения. |
| Падение iOS при входе | Нет `NSCameraUsageDescription`/`NSMicrophoneUsageDescription`. |
| Чёрный экран | HTTP/mixed content/self-signed сертификат; в проде — HTTPS. |
| `navigation-blocked` | Ссылка ведёт на другой origin; добавьте его в `allowedOrigins` или откройте через `onExternalLink`. |
| Нет звука в фоне | Ограничение WebView/ОС; нужен нативный аудио-стек/CallKit. |

Полное руководство: `agil/core/docs/flutter-sdk.md` в репозитории AgilFrame.

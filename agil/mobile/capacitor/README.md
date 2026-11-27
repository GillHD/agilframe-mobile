# @agil/calls-capacitor

Capacitor-плагин AgilFrame для iOS, Android и Web: `openCall()` открывает
hosted-виджет `/embed.html` во встроенном WKWebView/Android WebView (или в
системном браузере), прокидывает события через `AgilBridge` и управляет
разрешениями камеры/микрофона.

> **Статус: P1, WebView-интеграция.** Это не нативный WebRTC-клиент: медиа, чат,
> темы и участники остаются в веб-виджете на домене AgilFrame. Плагин владеет
> только экраном, навигацией, мостом и разрешениями. Ограничения и план перехода
> на нативный стек — в `agil/core/docs/capacitor.md` (репозиторий AgilFrame).

## Что внутри

| Файл | Назначение |
|---|---|
| `src/definitions.ts` | публичные типы, native-интерфейс и фасад `AgilCalls` |
| `src/index.ts` | фасад: валидация опций, сборка URL, регистрация плагина |
| `src/url.ts` | `/embed.html?...`, разбор ссылок, navigation guard, редакция токенов |
| `src/bridge.ts` | парсинг/санитайзинг `agil:*` сообщений |
| `src/web.ts` | web-fallback: full-screen iframe + `postMessage` |
| `ios/Sources/AgilCallsPlugin` | Swift-плагин и `AgilCallViewController` (WKWebView) |
| `android/src/main/java/com/agil/calls` | Kotlin-плагин, Activity и bridge |
| `AgilCalls.podspec`, `android/build.gradle` | сборка нативных таргетов |
| `test/url.test.ts`, `test/bridge.test.ts`, `test/native-source.test.ts` | 33 JS-теста URL/моста и нативных guard'ов |

## Требования

- Capacitor **6+** (`@capacitor/core` — peer dependency);
- iOS **14+** (WKWebView/WebRTC), Android **minSdk 22+** (рекомендуется
  обновляемый AndroidX WebView 90+);
- сервер AgilFrame, отдающий `/embed.html` и статику виджета (новых endpoint'ов
  не требуется);
- HTTPS в продакшене. HTTP допускается только для `localhost`/`127.0.0.1`/`::1`/
  `10.0.2.2` или при `allowInsecure: true` (только разработка).

## Установка

```bash
npm install @agil/calls-capacitor
npx cap sync
```

Плагин регистрируется автоматически: `package.json` содержит секцию
`"capacitor": { "ios": { "src": "ios" }, "android": { "src": "android" } }`.
Для iOS выполните `npx cap sync ios` (или `pod install` в `ios/App`), для
Android — `npx cap sync android`.

## Быстрый старт

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
      // snapshot (≤200 id) or delta; state.participantIds is gone — use
      // event.state.participantCount / participantRevision for the compact state.
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
  joinToken: token, // короткоживущий, выпускается на вашем backend
  participantName: 'Анна',
  theme: 'auto',
  language: 'ru',
  limits: { maxParticipants: 200 }, // large-room профиль: snapshot/delta, не 200 id каждый тик
  presentation: 'auto', // 'auto' | 'in-app' | 'external'
});

console.log(call.mode); // 'in-app' | 'external'

await AgilCalls.setTheme({ scheme: 'dark' });
// ...
await AgilCalls.close();
await listener.remove();
```

Без `joinToken` виджет показывает свой экран входа. С токеном звонок стартует
сразу после загрузки.

### Откуда взять joinToken

Нового endpoint'а нет: используйте существующий `POST /v1/rooms/:roomId/join`
(см. `agil/core/docs/api.md` §4). Токен выпускайте на своём backend, не храните admin API
key в приложении и не логируйте URL.

## API

### `AgilCalls.openCall(options)`

Возвращает `{ callId, mode }`. URL с join-token никогда не возвращается в JS.

| Опция | Тип | По умолчанию | Описание |
|---|---|---|---|
| `serverUrl` | `string` (обяз.) | — | База сервера, только `http(s)`; подпуть сохраняется. |
| `roomId` | `string` (обяз.) | — | id комнаты. |
| `tenantId` | `string` | `demo` | Тенант. |
| `joinToken` | `string` | — | Join-token; без него — экран входа. |
| `identityToken` | `string` | — | OIDC-токен (`identity_token`). |
| `participantName` | `string` | — | Имя на экране входа. |
| `role` | `'host' \| 'moderator' \| 'guest'` | — | Роль для анонимного входа. |
| `theme` | `'light' \| 'dark' \| 'auto'` | — | Схема темы. |
| `language` | `'ru' \| 'en'` | из конфига | Локаль UI. |
| `relayOnly` | `boolean` | `false` | Только TURN (`relay=1`). |
| `widgetPath` | `string` | `embed.html` | Путь относительно `serverUrl`. |
| `allowedOrigins` | `string[]` | `[]` | Дополнительные точные origin для навигации. |
| `allowInsecure` | `boolean` | `false` | Разрешить `http://` вне loopback (dev). |
| `presentation` | `'auto' \| 'in-app' \| 'external'` | `auto` | Встроенный WebView или системный браузер. |
| `permissions` | `{ camera?, microphone? }` | оба `true` | Намерение приложения; влияет на `onPermissionRequest`. |

Все методы возвращают `Promise` (например, `close(): Promise<void>`,
`setTheme(): Promise<void>`); `version` экспортируется из точки входа.

### `AgilCalls.close()`

Закрывает встроенный WebView/Activity. Для `mode: 'external'` — no-op (браузер
закрывает пользователь).

### `AgilCalls.isSupported()`

`{ supported, inAppWebView, reason? }`. На web `inAppWebView` — наличие iframe;
на iOS/Android — наличие host view controller/Activity.

### `AgilCalls.setTheme({ scheme?, theme? })`

Меняет схему (`agil:scheme`) и/или применяет частичный патч темы
(`agil:theme`) без перезагрузки.

### `AgilCalls.sendAction(action)`

Отправляет `agil:action` без закрытия WebView: `toggle-mic`, `toggle-camera`,
`toggle-chat`, `share-screen`, `leave`, `minimize`, `restore`, `pip`,
`fullscreen`, `newtab`, `blur-on`, `blur-off`. Допустимые значения —
`AGIL_CALL_ACTIONS`.

Если виджет ещё не прислал `agil:ready` (страница грузится), команда не
теряется: она ставится в ограниченную очередь (20 команд, порядок сохраняется)
и уходит в WebView после первого принятого сообщения виджета. Если страница так
и не поднялась, очередь отбрасывается при закрытии звонка; при переполнении
`sendAction` отклоняется.

### `AgilCalls.sendChat(text)`

Отправляет `agil:chat-send` (непустой текст, ≤4000 символов). До готовности
страницы ставится в ту же очередь, что и `sendAction`.

### `AgilCalls.checkPermissions()` / `AgilCalls.requestPermissions()`

`{ camera, microphone, settingsRequired }`; статусы `granted`, `denied`,
`prompt`, `prompt-with-rationale`, `blocked`, `unavailable`, `not-requested`.
На iOS запросы идут через `AVCaptureDevice`, на Android — runtime permissions,
на web — Permissions API/`getUserMedia`.

### `AgilCalls.addListener('callEvent', listener)`

События: `ready`, `joined`, `left`, `chat`, `error`, `state`, `minimized`,
`fullscreen`, `event`. Возвращает handle с `remove()`.

## URL и безопасность

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

- `buildWidgetUrl` отклоняет `javascript:`/`file:`, credentials, query/fragment в
  `serverUrl`, `..` в `widgetPath`, токены с пробелами/control-символами;
- `parseAgilCallLink` для http(s) сверяет `server` с origin/путём ссылки, а для
  custom scheme требует непустой `allowedOrigins`;
- `redactCallUrl`/`redactTokenText` маскируют токены и JWT — используйте в логах;
- навигация WebView ограничена `serverUrl` + `allowedOrigins`; внешние http(s)
  ссылки открываются в системном браузере, остальные блокируются;
- сообщения виджета парсятся и санитайзятся в JS (`src/bridge.ts`) независимо от
  того, пришли они из Swift/Kotlin или из iframe; ошибки виджета редактируются
  (`token`/`identity_token`/`access_token`/JWT), включая нативные
  `error.description`;
- входящие `agil:*` привязаны к origin виджета: iOS проверяет
  `WKFrameInfo.securityOrigin` (порт `0`, который WebKit отдаёт для
  `https://host`/`http://host`, нормализуется к 443/80), Android — per-load
  nonce, известный только шиму на странице виджета; разрешённые SSO-origin’ы не
  могут форджить сообщения. Android-конверт
  `{__agilBridgeNonce,message}` разворачивается до JS-парсера, поэтому
  `ready/chat/state/event` доходят до слушателей.

## Нативная конфигурация

### iOS

`Info.plist` приложения:

```xml
<key>NSCameraUsageDescription</key>
<string>Разрешите доступ к камере для видеозвонков</string>
<key>NSMicrophoneUsageDescription</key>
<string>Разрешите доступ к микрофону для звонков</string>
```

`AgilCallViewController` ставит `WKUserScript` на `.atDocumentStart` — `agil:ready`
не теряется. Origin сравнивается через чистый `AgilOriginNormalizer`: порт `0`
из `WKSecurityOrigin` (так WebKit представляет дефолтный порт) трактуется как
443/80, поэтому `https://host`, `https://host:443` и `securityOrigin.port == 0`
дают один и тот же origin. На iOS 15+ реализован
`WKUIDelegate.requestMediaCapturePermissionFor`: запрос отклоняется, если
отключён запрошенный тип. Для комбинированного `.cameraAndMicrophone` решение
одно на запрос — при отключённой камере или микрофоне он отклоняется целиком
(ограничение WebKit).

### Android

Разрешения уже объявлены в `android/src/main/AndroidManifest.xml` плагина и
смержатся в манифест приложения. Runtime-запрос выполняет
`AgilCalls.requestPermissions()` (алиасы `camera`/`microphone`).

`AgilCallActivity`:

- `WebChromeClient.onPermissionRequest` фильтрует ресурсы по отдельности:
  при `camera:false` выдаётся только `RESOURCE_AUDIO_CAPTURE` и наоборот;
- `WebViewClient.shouldOverrideUrlLoading` — origin-guard + внешний браузер;
- `BridgeInterface` проверяет per-load nonce и разворачивает конверт
  `{__agilBridgeNonce,message}`, передавая в JS только внутреннее сообщение
  виджета;
- шим ставится в `onPageStarted` и `onPageFinished` (у Android нет
  document-start инжекта);
- `mixedContentMode = MIXED_CONTENT_NEVER_ALLOW`, `allowFileAccess = false`.

HTTP только для dev: `android:usesCleartextTraffic="true"` (или
network-security-config) в манифесте приложения.

### Web

`src/web.ts` монтирует full-screen iframe с
`allow="camera; microphone; fullscreen; display-capture; autoplay; clipboard-write"`.
Родитель проверяет `event.source === iframe.contentWindow` и
`event.origin === widgetOrigin`. Без iframe (или при `presentation: 'external'`)
открывается новая вкладка.

## Сборка и тесты

```bash
cd agil/mobile/capacitor

npm run typecheck   # tsc --noEmit (src + test), нужен @capacitor/core
npm test            # 33 unit-теста (Node tsx --test)
npm run build       # dist/ (ESM) + dist/cjs/ (CommonJS)
npm pack --dry-run  # состав публикуемого пакета
```

Нативные проверки:

- `test/native-source.test.ts` — статические guard'ы для Swift/Kotlin
  (нормализация origin с портом `0`, разворачивание nonce-конверта, очередь до
  `agil:ready`); запускаются в общем `npm test`;
- `ios/Tests/AgilCallsPluginTests/AgilOriginNormalizerTests.swift` — чистые
  XCTest для нормализатора (готовы для Xcode test target; .xcodeproj в
  репозитории нет, а на этом хосте нет Swift/Xcode, поэтому здесь они
  проверяются статически).

Для нативных таргетов (в этом окружении нет Xcode/Android SDK):

```bash
npx cap sync ios       # подтянет AgilCalls.podspec
npx cap open ios       # Xcode: build/run
npx cap sync android
npx cap open android   # Android Studio: build/run
```

> **Проверено в этом окружении:** `tsc --noEmit` в изолированном проекте с
> `@capacitor/core@6` — без ошибок; `tsc -p tsconfig.build.json` собирает
> `dist/`; `tsx --test` — **33/33 passed**. Нативные модули (Swift/Kotlin/Gradle/
> podspec) не компилировались: здесь нет macOS/Xcode и Android SDK. Мобильные
> JS-тесты поднимают URL/валидацию/парсер и статически проверяют нативные
> guard'ы без Capacitor runtime.

## Ограничения

- **Не нативный WebRTC.** Медиа, чат и темы — в веб-виджете; нативный
  LiveKit + CallKit/ConnectionService — следующий этап.
- **Нет фонового режима/push/CallKit.** При уходе в фон WebView может быть
  приостановлен; входящие звонки не поддерживаются.
- **Нет screen share** (`getDisplayMedia` недоступен в мобильных WebView).
- **Android: инжект шима после старта страницы.** `agil:ready`, отправленный
  раньше установки шима, может быть потерян. Команды `sendAction`/`sendChat`,
  отправленные до первого принятого сообщения виджета (обычно `agil:ready`),
  стоят в ограниченной очереди (20, порядок сохраняется) и доставляются, когда
  страница подтвердит готовность; если виджет не поднялся, очередь
  отбрасывается при закрытии звонка.
- **Токен в URL.** Join-token виден в URL/истории WebView; короткий TTL, HTTPS,
  отсутствие логов, очистка данных WebView при выходе из аккаунта.
- **Web-режим — iframe.** Некоторые браузеры блокируют камеру в iframe без
  user gesture/разрешений; для продакшена используйте нативные таргеты.
- **`presentation: 'external'`** открывает системный браузер и не даёт событий
  `callEvent` (виджет живёт вне приложения).

## Troubleshooting

| Симптом | Причина/решение |
|---|---|
| `openCall` бросает `invalid-config` | Неверный `serverUrl` (`http` вне dev, credentials, query) или `roomId`; сообщение не содержит токен. |
| Событий нет | Шим не установился до `agil:ready`; проверьте, что используется нативная сборка (`npx cap sync`), а не web-заглушка. |
| `permission-denied` | Разрешения не выданы/заблокированы: `requestPermissions()`, затем настройки приложения. |
| Падение iOS при входе | Нет `NSCameraUsageDescription`/`NSMicrophoneUsageDescription`. |
| Чёрный экран Android | Cleartext HTTP заблокирован; в проде — HTTPS. |
| `navigation-blocked` | Ссылка ведёт на чужой origin; добавьте его в `allowedOrigins`. |
| iframe на web без камеры | Ограничение браузера для cross-origin iframe; используйте нативную сборку. |

Полное руководство: `agil/core/docs/capacitor.md` в репозитории AgilFrame.

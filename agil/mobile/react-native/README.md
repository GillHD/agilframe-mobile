# @agil/calls-react-native

React Native-обёртка AgilFrame для iOS и Android: `<AgilCall />` открывает
hosted-виджет `/embed.html` в WebView, прокидывает события через
`postMessage`-мост и управляет нативными разрешениями камеры/микрофона.

> **Статус: P1, WebView-интеграция.** Это не нативный WebRTC-клиент. Медиа,
> чат, темы и права выполняет веб-виджет на домене AgilFrame; приложение
> владеет только экраном, навигацией и разрешениями. Ограничения и план
> перехода на нативный LiveKit RN — в `agil/core/docs/mobile.md` (репозиторий AgilFrame).

## Что внутри

| Файл | Назначение |
|---|---|
| `src/AgilCall.ts` | `<AgilCall />` на `react-native-webview` |
| `src/url.ts` | сборка `/embed.html?...`, deep-link, разбор ссылок, navigation guard |
| `src/url-core.ts` | Hermes-safe парсер URL/query (без глобальных `URL`/`URLSearchParams`) |
| `src/bridge.ts` | парсинг/санитайзинг `agil:*`, инжект-скрипты, шим для top-level WebView |
| `src/permissions.ts` | Android runtime-разрешения, iOS system prompt, открытие Settings |
| `src/types.ts` | публичные TS-типы |
| `expo/withAgilCall.cjs` | Expo config plugin: Info.plist + AndroidManifest |
| `test/` | unit-тесты URL/моста/рендер-хелпера (52 теста, Node `tsx --test`) |

## Требования

- React Native **0.71+**, React **18+**;
- `react-native-webview` **13+**;
- URL/`URLSearchParams`-полифилл **не требуется**: пакет использует собственный
  парсер, совместимый с Hermes (React Native’s `URL` неполный);
- сервер AgilFrame, отдающий `/embed.html` и статику виджета (никаких новых
  endpoint’ов не требуется);
- iOS **14.3+** (WebRTC в WKWebView), Android **8+** с обновляемым AndroidX
  WebView (рекомендуется WebView 90+);
- HTTPS в продакшене. HTTP допустим только для локальной разработки
  (`http://10.0.2.2:8787` из Android-эмулятора, `http://localhost:8787` из
  симулятора iOS).

## Установка

```bash
npm install @agil/calls-react-native react-native-webview
# Expo:
npx expo install react-native-webview
```

`react`, `react-native`, `react-native-webview` — peer dependencies; в бандл
пакета они не попадают. В `peerDependenciesMeta` они помечены `optional`, чтобы
монорепозиторий и CI не тянули React Native; **приложение обязано установить их
явно** (см. команду выше).

## Быстрый старт

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
        participantName="Анна"
        theme="auto"
        language="ru"
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

Без `joinToken` виджет покажет собственный экран входа (имя, камера,
микрофон). С токеном звонок стартует сразу после загрузки.

### Откуда взять joinToken

Нового серверного endpoint’а нет. Используйте существующий
`POST /v1/rooms/:roomId/join` (см. `agil/core/docs/api.md` §4):

```bash
curl -s -X POST https://calls.example.com/v1/rooms/daily-sync/join \
  -H 'content-type: application/json' \
  -d '{"name":"Анна","locale":"ru"}'
# → { "token":"eyJ...", "expiresAt":..., "participant":{...}, "permissions":[...] }
```

Токен короткоживущий. Выпускайте его на своём backend (не храните admin API
key в приложении), передавайте в `joinToken` и не логируйте. Если комната
защищена паролем/включён waiting room, обработайте `400/401/202` на своей
стороне до открытия звонка.

## Props

| Prop | Тип | По умолчанию | Описание |
|---|---|---|---|
| `serverUrl` | `string` (обяз.) | — | База REST/WS и статики, только `http(s)`. Подпуть сохраняется: `https://host/calls` → `/calls/embed.html`. |
| `roomId` | `string` (обяз.) | — | id комнаты. |
| `joinToken` | `string` | — | Join-token; без него виджет показывает экран входа. |
| `tenantId` | `string` | `demo` | Тенант. |
| `participantName` | `string` | — | Имя на экране входа. |
| `role` | `'host' \| 'moderator' \| 'guest'` | — | Роль для анонимного входа. |
| `theme` | `'light' \| 'dark' \| 'auto'` | — | Только схема; полная тема приходит с сервера. |
| `language` | `'ru' \| 'en'` | из конфига | Локаль UI. |
| `identityToken` | `string` | — | Корпоративный OIDC-токен (`identity_token` в URL). |
| `relayOnly` | `boolean` | `false` | Только TURN (`relay=1`). |
| `widgetPath` | `string` | `embed.html` | Путь относительно `serverUrl`; `/embed.html` — от корня домена. |
| `allowInsecure` | `boolean` | `false` | Разрешить публичный `http://` (только разработка; по умолчанию HTTP разрешён лишь для loopback/`10.0.2.2`). |
| `permissions` | `{ camera?: boolean; microphone?: boolean }` | оба `true` | Какие медиа разрешать. На Android вызывает runtime-запрос, на iOS — системный prompt WKWebView. |
| `requestPermissionsOnMount` | `boolean` | `true` | Запрашивать Android-разрешения при монтировании. |
| `readyTimeoutMs` | `number` | `20000` | Ожидание `agil:ready`; `0` отключает watchdog. |
| `limits` | `{ maxParticipants?: number }` | `{ maxParticipants: 200 }` | Large-room профиль: до 200 участников; SDK хранит набор id и отдаёт snapshot/delta вместо массива на 200 id каждый тик. |
| `allowedOrigins` | `readonly string[]` | `[]` | Дополнительные exact-origin для навигации (SSO и т.п.). |
| `onEvent` | `(event: AgilCallEvent) => void` | — | Все события звонка. |
| `onError` | `(error: AgilCallError) => void` | — | Ошибки моста/загрузки/разрешений. Для ошибок виджета вызывается **вместе** с `onEvent`. |
| `onExternalLink` | `(url: string) => void` | — | Навигация за пределы виджета заблокирована; здесь можно открыть ссылку в системном браузере. |
| `safeAreaInsets` | `{ top?, right?, bottom?, left? }` | — | Отступы (например, из `useSafeAreaInsets()`); Android WebView не поддерживает CSS `env(safe-area-inset-*)`. |
| `style` | `StyleProp<ViewStyle>` | — | Стиль внешнего контейнера. |
| `testID` | `string` | — | Для e2e/тестов. |

`permissions` — декларация намерения приложения, а не жёсткий ACL: на Android
она запускает runtime-запрос, на iOS WKWebView всё равно показывает системный
prompt. Если запретить оба медиа (`{ camera: false, microphone: false }`),
компонент выставляет `mediaCapturePermissionGrantType="deny"`. Ограничение
`react-native-webview`: нельзя выдать частичный capture в одном запросе,
поэтому при запрете только одного типа компонент оставляет решение WebView;
проверяйте такой сценарий в приложении/виджете. Capacitor-плагин на Android
выдаёт каждый тип независимо, на iOS отклоняет комбинированный запрос.

Компонент валидирует props до загрузки WebView. При ошибке конфигурации
рисуется текстовый fallback, а `onError` получает
`{ code: 'invalid-config', fatal: true }`; токен в сообщения не попадает.

## События

| `event.type` | Payload | Когда |
|---|---|---|
| `ready` | `capabilities`, `room?`, `server?` | Виджет смонтирован, мост работает. |
| `joined` | `payload?` | Участник вошёл в комнату. |
| `left` | `payload?` | Участник вышел. |
| `chat` | `message: AgilChatMessage` | Новое сообщение чата (в т.ч. при внешнем чате). |
| `error` | `error: AgilCallError` | Виджет сообщил об ошибке (`code: 'widget-error'`). |
| `state` | `state: AgilCallState` | Периодический снимок состояния (без массива `participantIds`: только `participantCount`/`participantRevision`). |
| `participants` | `participants: ParticipantUpdate` | Компактный snapshot (≤200 id, один раз за загрузку) или delta (`added`/`removed`) для больших комнат. |
| `connection` | `connection: ConnectionUpdate` | Дедуплицированный reconnect: `state`, `previous`, `attempt`, `delayMs`. |
| `minimized` / `fullscreen` | `boolean` | Мини-режим / fullscreen. |
| `event` | `name`, `payload?` | Остальные события: `participant-joined`, `quality-changed`, `connection-state`, `action-denied`, … |

Ошибки, возникшие вне виджета (загрузка, HTTP, таймаут, навигация,
разрешения), приходят только в `onError`.

## Императивный handle

```tsx
const call = useRef<AgilCallHandle>(null);

call.current?.sendAction('toggle-mic');     // toggle-mic | toggle-camera | leave | …
call.current?.sendChat('Привет');
call.current?.setThemeScheme('dark');        // без перезагрузки WebView
call.current?.applyTheme({ colors: { primary: '#0b5fff' } });
call.current?.applyConfig({ layout: { controlsStyle: 'minimal' } });
call.current?.ping();
call.current?.reload();                      // после render-process-gone/сетевой ошибки
call.current?.reconnect();                   // reload + событие connection, nonce ротируется
```

Действия, отправленные до `ready`, буферизуются (до 50 сообщений) и уходят
после `agil:ready`. Неизвестные действия/темы отклоняются с `onError`.

## Deep links

```ts
import { Linking } from 'react-native';
import { buildCallDeepLink, parseAgilCallLink } from '@agil/calls-react-native';

// ссылка для письма/QR/пуш-уведомления (содержит join-token — короткий TTL)
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
  // link: { kind, serverUrl, roomId, joinToken?, tenantId?, … } — можно передать в <AgilCall />
}
```

`parseAgilCallLink`:

- принимает `/embed.html?...` и `myapp://call?...`;
- для http(s) требует, чтобы параметр `server` совпадал с origin и путём самой
  ссылки — нельзя увести join-token на чужой хост;
- отклоняет `javascript:`, `file:`, неизвестные схемы, ссылки без `room`,
  слишком длинные значения и control-символы;
- для custom scheme **всегда** передавайте `allowedOrigins` (список доверенных
  origin сервера).

Компонент дополнительно блокирует любую навигацию WebView за пределы
`serverUrl` + `allowedOrigins`; `onExternalLink` получает заблокированный
`http(s)`-адрес, чтобы приложение могло открыть его через `Linking.openURL`.

Для backend/скриптов (push, письма, QR) URL-билдер доступен отдельным
subpath без импорта React Native:

```ts
import { buildCallDeepLink, buildWidgetUrl } from '@agil/calls-react-native/url';
```

## Нативная конфигурация

### iOS (WKWebView)

`Info.plist` (без этих строк приложение падает при первом `getUserMedia`):

```xml
<key>NSCameraUsageDescription</key>
<string>Разрешите доступ к камере для видеозвонков</string>
<key>NSMicrophoneUsageDescription</key>
<string>Разрешите доступ к микрофону для звонков</string>
```

- WKWebView открывает системный prompt сам; `permissions` на iOS не
  пре-грантит доступ, а только отражает намерение приложения.
- Компонент выставляет `allowsInlineMediaPlayback`,
  `mediaPlaybackRequiresUserAction={false}`,
  `mediaCapturePermissionGrantType="grant"`.
- Safe area: виджет использует `env(safe-area-inset-*)`, но надёжнее передать
  `safeAreaInsets` из `react-native-safe-area-context`.
- Демонстрация экрана (`getDisplayMedia`) в WKWebView недоступна.

### Android (AndroidX WebView)

`AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-feature android:name="android.hardware.camera" android:required="false" />
```

- Компонент сам запрашивает `CAMERA`/`RECORD_AUDIO` через
  `PermissionsAndroid` при монтировании (`requestPermissionsOnMount`).
- WebView должен отдавать `onPermissionRequest` для
  `RESOURCE_VIDEO_CAPTURE`/`RESOURCE_AUDIO_CAPTURE`. `react-native-webview` 13+
  делает это для приложения, уже получившего runtime-разрешения; кастомный
  WebView требует явного `WebChromeClient.onPermissionRequest`.
- Автоплей: компонент ставит `mediaPlaybackRequiresUserAction={false}` и
  `allowsInlineMediaPlayback`.
- HTTP только для dev: `android:usesCleartextTraffic="true"` (или
  network-security-config). В проде — HTTPS.
- Эмулятор: `serverUrl: 'http://10.0.2.2:8787'`, физическое устройство —
  IP машины в локальной сети.

### Expo config plugin

```json
{
  "expo": {
    "scheme": "myapp",
    "plugins": [
      [
        "@agil/calls-react-native/expo-plugin",
        {
          "cameraPermission": "Разрешите доступ к камере для видеозвонков",
          "microphonePermission": "Разрешите доступ к микрофону для звонков"
        }
      ]
    ]
  }
}
```

Плагин добавляет iOS usage strings и Android `uses-permission`/`uses-feature`.
Он не содержит нативных бинарников. В Expo Go используется стандартный
WebView, но кастомные usage strings применяются только в dev/prod build
(`expo prebuild` / EAS Build).

## Сборка и тесты

```bash
npm run typecheck -w @agil/calls-react-native   # tsc --noEmit (src + test)
npm test -w @agil/calls-react-native            # 52 unit-тест URL/bridge/render
npm run build -w @agil/calls-react-native       # dist/ (ESM) + dist/cjs/ (CJS)
npm pack --dry-run                              # состав публикуемого пакета
```

`dist/index.js` — ESM, `dist/cjs/index.js` — CommonJS (Metro/старые резолверы),
`dist/index.d.ts` — типы. React/React Native/WebView остаются peer-зависимостями.

## Публикация

```bash
npm run build -w @agil/calls-react-native
# внутренний реестр (проприетарная лицензия репозитория):
npm publish -w @agil/calls-react-native --access restricted
# публичный реестр — только если это разрешено лицензией: --access public
```

Перед публикацией: поднимите `version` в `package.json`, обновите `version` в
`src/index.ts`, прогоните `typecheck`/`test`/`pack --dry-run`. Пакет не содержит
нативных модулей, поэтому `pod install`/Gradle-плагины не нужны.

## Ограничения

- **Не нативный WebRTC.** Звонок идёт в Chromium WebView/WKWebView; UI, медиа и
  права — веб-виджет. Нативный LiveKit RN SDK + CallKit/Push — следующий этап.
- **Нет фонового режима/CallKit.** При уходе приложения в фон iOS/Android могут
  приостановить WebView; входящие звонки и системный Call UI не поддерживаются.
- **Нет screen share.** `getDisplayMedia` недоступен в WKWebView и мобильном
  WebView; кнопка демонстрации экрана не работает.
- **Загрузка файлов/записи.** Скачивание записи и file picker внутри WebView
  требуют отдельной нативной обработки; по умолчанию не настроены.
- **Зависимость от WebView.** Старый Android WebView/кастомные прошивки могут
  не поддерживать WebRTC, `enumerateDevices` или autoplay; проверяйте на
  целевых устройствах.
- **Границы моста.** `ReactNativeWebView` виден всем страницам WebView, поэтому
  шим тегирует пересланные сообщения одноразовым nonce; прямой `postMessage`
  со страницы SSO-origin’а отклоняется. Ошибки виджета редактируются
  (`token`/`identity_token`/`access_token`/JWT).
- **Токен в URL.** Join-token виден в URL/истории WebView; используйте
  короткий TTL, HTTPS, не логируйте URL, очищайте WebView data при выходе из
  аккаунта.
- **Deep link запускает новый экран.** Компонент не «восстанавливает» звонок
  после kill процесса; token нужно перевыпустить.
- **Один активный звонок на экран.** Не монтируйте несколько `<AgilCall />`
  одновременно на слабых устройствах.

## Troubleshooting

| Симптом | Причина/решение |
|---|---|
| `timeout` в `onError` | `/embed.html` не загрузился, CSP/сертификат, неверный `serverUrl`, WebView не выполнил инжект. Проверьте URL в браузере и `onHttpError`. |
| Событий нет, видео идёт | Ранний инжект шима не сработал. Обновите `react-native-webview`; `createBridgeShimScript()` также инжектится после `onLoadEnd`. |
| `permission-denied` на Android | Разрешения не выданы/заблокированы; проверьте manifest, вызовите `openAppSettings()`. |
| На iOS приложение падает при входе | Нет `NSCameraUsageDescription`/`NSMicrophoneUsageDescription`. |
| Чёрный экран | HTTP на iOS/Android, mixed content, self-signed сертификат; в проде — HTTPS. |
| `navigation-blocked` | Ссылка ведёт на другой origin; добавьте его в `allowedOrigins` или обработайте `onExternalLink`. |
| Нет звука в фоне | Ограничение WebView/ОС; нужен нативный аудио-стек/CallKit. |

Полное руководство по интеграции, матрица проверок и ограничения:
`agil/core/docs/mobile.md` в репозитории AgilFrame.

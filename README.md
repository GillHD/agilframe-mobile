# AgilFrame Mobile SDK

**Русский** · [English](README.en.md)

Мобильные компоненты для встраивания звонка AgilFrame в приложение. Они открывают размещённый на Core виджет `/embed.html` в системном WebView и передают между приложением и виджетом команды и события.

[Общий проект](https://github.com/GillHD/agilframe) · [AgilFrame Core](https://github.com/GillHD/agilframe-core) · [Руководство по интеграции](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/mobile.md)

## Компоненты

| Платформа | Что подключается |
| --- | --- |
| [Android](agil/mobile/android/README.md) | Библиотеки Kotlin для View и Jetpack Compose |
| [iOS](agil/mobile/ios/README.md) | Swift-пакет `AgilCallsSDK` и пример на SwiftUI |
| [Flutter](agil/mobile/flutter/README.md) | Плагин `agil_calls` |
| [Capacitor](agil/mobile/capacitor/README.md) | Плагин `@agil/calls-capacitor` |
| [React Native](agil/mobile/react-native/README.md) | Компонент `@agil/calls-react-native` и плагин конфигурации Expo |

Для звонка передайте приложению URL Core, данные комнаты и токен участника. [Исходная версия компонентов](https://github.com/GillHD/agilframe-core/commit/85f084e1c12e63a56be718622f568170b6c0f9b8)

## Сборка и проверка

Для React Native и Capacitor установите Node.js 22 или новее и выполните из корня репозитория:

```sh
npm ci
npm run build
npm run typecheck
npm test
```

Для Android используйте JDK 17, Gradle 8.9 и Android SDK 35. Сборка выполняется из `agil/mobile/android`. [Команды Android](agil/mobile/android/README.md) · [Настройки CI](.github/workflows/ci-android.yml)

Для Flutter выполните `flutter pub get`, `flutter analyze` и `flutter test` из `agil/mobile/flutter`. Для iOS используйте Xcode. [Руководство Flutter](agil/mobile/flutter/README.md) · [Руководство iOS](agil/mobile/ios/README.md)

## Вклад и лицензия

[Правила участия](CONTRIBUTING.md) · [Безопасность](SECURITY.md) · [Лицензия](LICENSE) · [Уведомления](NOTICE)

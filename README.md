# AgilFrame Mobile SDK

Android, iOS, Flutter, React Native и Capacitor.

[AgilFrame](https://github.com/users/GillHD/projects/1) · [Core и документация](https://github.com/GillHD/agilframe-core)

Исходная версия компонентов: [85f084e](https://github.com/GillHD/agilframe-core/commit/85f084e1c12e63a56be718622f568170b6c0f9b8). [Лицензия](LICENSE) · [Уведомления](NOTICE)

## Компоненты

| Платформа | Папка |
| --- | --- |
| Android | [agil/mobile/android](agil/mobile/android/) |
| iOS | [agil/mobile/ios](agil/mobile/ios/) |
| Flutter | [agil/mobile/flutter](agil/mobile/flutter/) |
| Capacitor | [agil/mobile/capacitor](agil/mobile/capacitor/) |
| React Native | [agil/mobile/react-native](agil/mobile/react-native/) |

Для JS-обёрток выполните `npm ci`, `npm run build`, `npm run typecheck` и `npm test`. Для Android используйте JDK 17, Gradle 8.9 и SDK 35. Для Flutter выполните `flutter analyze` и `flutter test` в каталоге плагина. Для сборки Swift-пакета нужна среда Xcode.

Для живого звонка обёрткам нужен URL Core и данные участника. [Интеграция](https://github.com/GillHD/agilframe-core/blob/main/agil/core/docs/mobile.md)

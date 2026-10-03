# TV Remote: Cast & Mirror (Remote Pro)

Название в App Store: **TV Remote: Cast & Mirror** (зарегистрировано). Подпись под иконкой: «TV Remote».

Нативное iOS-приложение (SwiftUI, iPhone, iOS 17+):

- пульт для телевизоров Samsung Tizen, LG webOS и Android TV / Google TV;
- ввод текста с клавиатуры iPhone;
- быстрый запуск приложений ТВ;
- показ фото и видео через DLNA;
- собственный повтор экрана через браузер ТВ (ReplayKit Broadcast Upload Extension);
- покупки StoreKit 2 (месяц $8.99 / год $59.99 с 3-дневным trial / lifetime $199.00);
- бесплатная проверка совместимости, помощь и поддержка;
- бонусная кампания (выключена до готовности), Firebase Analytics / Crashlytics / Messaging с согласием;
- 5 языков: en, es, ru, de, fr.

> **Статус честно:** код собирается, 136 юнит-тестов и 5 UI-тестов проходят в симуляторе. **Ни один телевизор физически не проверялся**, Sandbox-покупки и push не проверялись, выпуск требует Xcode 26+. Подробности — [Documentation/REPORT.md](Documentation/REPORT.md).

## Требования
- macOS с Xcode 16.4+ для разработки. **Для загрузки в App Store — Xcode 26+** (требование Apple с 28.04.2026).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.4x (`brew install xcodegen`) — проект генерируется из `project.yml`.
- Python 3 — генерация и проверка локализаций.
- Сеть при первой сборке: Swift Package `firebase-ios-sdk` 12.19.2.

## Запуск
```bash
xcodegen generate
open TVRemoteScreenMirroring.xcodeproj    # схема TVRemoteScreenMirroring, StoreKit config подключён к Run
```
Или из терминала (симулятор):
```bash
Tools/build.sh
```
Если `xcode-select` указывает на Command Line Tools: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` или используйте `DEVELOPER_DIR` (так делает `Tools/build.sh`).

Тесты:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project TVRemoteScreenMirroring.xcodeproj \
  -scheme TVRemoteScreenMirroring -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

Для работы с реальными ТВ нужен **физический iPhone** в одной сети с телевизором: в симуляторе нет local network privacy, ReplayKit broadcast и ваших ТВ. Для подписи задайте `DEVELOPMENT_TEAM` и зарегистрируйте App Group `group.app.TVRemoteScreenMirroring`.

DEBUG-сборка с аргументом запуска `-DemoTV` подключает **симулированный** ТВ (только для UI-тестов и визуальной проверки; в Release не компилируется).

## Конфигурация владельца
`TVRemoteScreenMirroring/Resources/AppConfig.plist`: product IDs, лимиты бесплатной проверки, контакты поддержки, юридические URL, бонусная кампания, сервер push. Пустые значения означают «не настроено»: соответствующие кнопки скрыты, фиктивных адресов нет. Полный список — [RELEASE_CHECKLIST.md](Documentation/RELEASE_CHECKLIST.md).

Firebase включается, когда в `Resources/` лежит настоящий `GoogleService-Info.plist` ([FIREBASE.md](Documentation/FIREBASE.md)).

## Локализация
Строки редактируются в `Tools/Localization/strings_*.py` (кортежи en/es/ru/de/fr, plural-формы), затем:
```bash
python3 Tools/Localization/generate_catalog.py          # пишет Localizable.xcstrings и InfoPlist.xcstrings
python3 Tools/Localization/generate_catalog.py --check  # только проверка (для CI)
```
Генератор падает, если не хватает языка, не совпадают плейсхолдеры, нет ключа, используемого в Swift, или неполно динамическое семейство ключей. Переключение языка внутри приложения — Settings → Language. Системные окна следуют языку iOS.

## Структура
См. [ARCHITECTURE.md](Documentation/ARCHITECTURE.md). Кратко: `App/`, `Core/`, `TVAdapters/` (Samsung, LG, Android TV, UPnP), `Services/`, `Features/`, `Shared/` (общий с расширением код), `BroadcastUpload/`, `Tests/`, `Server/offer-codes` (эталонный сервис бонусных кодов, не развёрнут), `Tools/`.

## Зависимости
| Зависимость | Версия | Лицензия | Зачем |
|---|---|---|---|
| firebase-ios-sdk (`FirebaseCore`, `FirebaseAnalyticsCore`, `FirebaseCrashlytics`, `FirebaseMessaging`) и её транзитивные пакеты | 12.19.2 | Apache-2.0 (Analytics — бинарный, Google Terms) | Аналитика, сбои, push |

Протоколы ТВ, protobuf, X.509/DER, SSDP, UPnP, HTTP- и WebSocket-серверы реализованы в проекте. Спецификации протоколов изучены по открытым проектам (androidtvremote2 — Apache-2.0, samsungtvws — LGPL-3.0, aiowebostv — Apache-2.0, ConnectSDK — Apache-2.0); их код не копировался.

## Документация
| Файл | Содержание |
|---|---|
| [REPORT.md](Documentation/REPORT.md) | Итоговый отчёт: что сделано, проверено, заблокировано |
| [COMPATIBILITY.md](Documentation/COMPATIBILITY.md) | Матрица совместимости и журнал физических проверок |
| [ARCHITECTURE.md](Documentation/ARCHITECTURE.md) | Адаптеры, сессии, возможности, поток доступа, трансляция |
| [MONETIZATION.md](Documentation/MONETIZATION.md) | Продукты, состояния доступа, paywall, смена тарифов, lifetime |
| [TESTING.md](Documentation/TESTING.md) | Команды, результаты, сценарии физических проверок |
| [PRIVACY.md](Documentation/PRIVACY.md) | Данные, разрешения, сетевые потоки, privacy labels |
| [RELEASE_CHECKLIST.md](Documentation/RELEASE_CHECKLIST.md) | Подпись, App Store Connect, данные владельца, блокеры |
| [SUPPORT.md](Documentation/SUPPORT.md) | Каналы, состав диагностики, хранение обращений |
| [OFFERS.md](Documentation/OFFERS.md) | Бонусная кампания, offer codes, сервис кодов |
| [EXPERIMENTS.md](Documentation/EXPERIMENTS.md) | Гипотезы, метрики, правила экспериментов |
| [FIREBASE.md](Documentation/FIREBASE.md), [NOTIFICATIONS.md](Documentation/NOTIFICATIONS.md) | Firebase, согласия, push |
| [APP_STORE.md](Documentation/APP_STORE.md) | Тексты App Store на 5 языках, review notes |
| [REVIEW.md](Documentation/REVIEW.md) | Ревью кода: найденные ошибки и что исправлено |
| [HOME_TEST_CHECKLIST.md](Documentation/HOME_TEST_CHECKLIST.md) | Пошаговая проверка на Samsung и Xiaomi дома |
| [BRAND_ASSETS.md](Documentation/BRAND_ASSETS.md) | Логотипы сервисов: источники, требования, подключение |
| [Screenshots/](Documentation/Screenshots/) | QA-скриншоты с DEBUG-демо-ТВ (не для App Store) |

# Пробник BLE-фона (одноразовый, 06.08.2026)

Измерительный прибор для оценки транспорта «телефон↔телефон»
(`docs/reports/phone_transport_estimate_2026-08-06.md`, пункт 2 брифа).
**Не продукт**: отдельный проект, в основной таргет не входит, после
снятия замеров можно удалить целиком. UUID сервиса — свой, продуктовый
`BleLink` не задевается.

## Состав

- `Probe/` + `project.yml` — iPhone-приложение: одновременно маяк
  (реклама сервиса) и сканер (поиск того же сервиса). Каждое событие —
  строка журнала с меткой времени, состоянием (перед/фон), остатком
  фонового времени, зарядом и признаком Low Power Mode. При обнаружении
  соседа — подключается, передаёт маленький пакет, показывает локальное
  уведомление. Журнал пишется сразу в `Documents/probe_log.jsonl`.
- `mac/blescan.swift` — вторая сторона на Маке:
  `./blescan scan` — ждать сервис пробника; `./blescan scan-all` —
  сырой обзор эфира (что видит посторонний); `./blescan advertise` —
  рекламировать сервис (реклама переднего плана) и принимать пакеты;
  `./blescan connect` — подключиться и записать пакет.

## Как собрать и поставить

```
cd tools/probe && xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project ChappeProbe.xcodeproj -scheme ChappeProbe \
  -destination "id=<iPhone>" -allowProvisioningUpdates -derivedDataPath build
xcrun devicectl device install app --device <iPhone> \
  build/Build/Products/Debug-iphoneos/ChappeProbe.app
cd mac && swiftc -O blescan.swift -o blescan
```

## Как снять журнал с телефона

```
xcrun devicectl device copy from --device <iPhone> \
  --domain-type appDataContainer --domain-identifier com.chappe.probe \
  --source Documents/probe_log.jsonl --destination probe_log.jsonl
```

Протокол замеров (какие сценарии в каком порядке) — в отчёте,
раздел «Стенд и протокол замеров».

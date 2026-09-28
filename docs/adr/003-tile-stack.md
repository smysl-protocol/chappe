# ADR 003 — Тайловый стек слоя карты

Дата: 28.07.2026. Статус: принято (ночная задача, ветка `feat/map-layer`).
Владелец утвердил рендер и версию до начала ночи; способ офлайна выбран здесь.

## Контекст

Офлайн — условие задачи, а не режим. MapKit исключён: Apple не даёт
легального офлайн-кэша тайлов. Правила: никаких API-ключей и платных
сервисов (правило №4 ночного брифа), тема только тёмная, атрибуция OSM
видима на экране карты.

## Решение

| Слой | Выбор |
|---|---|
| Рендер | **MapLibre Native iOS**, SPM `maplibre-gl-native-distribution` **6.28.0**, правило `6.28.0 ..< 7.0.0` (утверждено владельцем, WP1) |
| Офлайн | **Штатные offline packs: `MLNOfflineStorage` + `MLNOfflinePack`** (наследник `MGLOfflineStorage`), регион = `MLNTilePyramidOfflineRegion` (bbox + диапазон зумов) |
| Тайлы | **OpenFreeMap** (`tiles.openfreemap.org`) — векторные тайлы, немодифицированная схема OpenMapTiles; без ключа, без регистрации, без лимитов, коммерческое использование разрешено |
| Стиль | **`https://tiles.openfreemap.org/styles/dark`** — готовый тёмный стиль; перекраска отдельных слоёв на лету доступна через runtime styling (`MLNStyle.layers`, NSExpression-свойства) без перекачки тайлов |
| Атрибуция | Требуемая формулировка OpenFreeMap: «OpenFreeMap © OpenMapTiles Data from OpenStreetMap» (часть «OpenFreeMap» опциональна); OSMF допускает «© OpenStreetMap contributors». Ставим постоянную подпись «© OpenStreetMap contributors | OpenFreeMap © OpenMapTiles» в углу экрана карты + штатная кнопка `attributionButton` MLNMapView (прятать её запрещено докой) |

## Проверенные факты (все — тег `ios-v6.28.0`, если не сказано иное)

1. `Package.swift` дистрибутива 6.28.0 — binaryTarget без `platforms`;
   фактический минимум зашит в фреймворк: `MinimumOSVersion = 12.0`
   (Info.plist официального `MapLibre.dynamic.xcframework.zip` релиза).
   Наш deployment target iOS 26.5 — совместимо.
   <https://raw.githubusercontent.com/maplibre/maplibre-gl-native-distribution/6.28.0/Package.swift>
2. `MLNOfflineStorage.h`: `addPack(for:withContext:completionHandler:)`
   (строка 310), возобновление через `MLNOfflinePack.resume`, прогресс через
   `MLNOfflinePackProgressChangedNotification`, side-loading готовой базы —
   `addContentsOfFile` (строка 237).
   <https://raw.githubusercontent.com/maplibre/maplibre-native/ios-v6.28.0/platform/darwin/src/MLNOfflineStorage.h>
3. Лимит `setMaximumAllowedMapboxTiles` действует **только** на тайлы с
   canonical-URL (`mapbox://`): `offline_database.cpp:1454–1457` — обычные
   https-тайлы OpenFreeMap под лимит не попадают.
   <https://github.com/maplibre/maplibre-native/blob/ios-v6.28.0/platform/default/src/mbgl/storage/offline_database.cpp>
4. PMTiles поддержан нативно (не только в web): PR #2882 (merged 07.01.2025),
   в iOS-релизе с **6.10.0**, схема `pmtiles://` + полный URL
   (`pmtiles://file:///…`); символы pmtiles подтверждены strings-проверкой
   бинарника 6.28.0. **Но: offline packs поверх pmtiles-источников не
   работают**; с 6.27.0 есть только ambient cache (#4290).
   <https://github.com/maplibre/maplibre-native/pull/2882>,
   <https://github.com/maplibre/maplibre-native/blob/main/platform/ios/CHANGELOG.md>
5. MBTiles поддержан нативно с 5.10.0: `mbtiles:///абсолютный/путь` (в
   бинарнике: «MBTilesFileSource only supports absolute path urls»).
6. Runtime styling в 6.28.0: `MLNStyle.layers`, `layerWithIdentifier:`
   (`MLNStyle.h:157,166`), `MLNFillStyleLayer.fillColor` изменяем.
7. Ambient cache и offline packs живут в одной SQLite-базе (`databaseURL`);
   `resetDatabase` сносит и то и другое; `clearAmbientCache` не трогает
   ресурсы offline-регионов.
8. OpenFreeMap: «There's no registration, no user database, no API keys, and
   no cookies», «there are no limits on the number of map views or requests»,
   коммерческое использование — «Yes», еженедельные полные выгрузки планеты
   (Btrfs/MBTiles) для self-hosting. Стили: liberty, positron, bright,
   **dark**, fiord. <https://openfreemap.org>, <https://openfreemap.org/quick_start/>
9. Атрибуция OSMF: «© OpenStreetMap contributors» приемлема; постоянная
   видимость не строго обязательна (допустимо сворачивание), но пользователь
   обязан иметь возможность найти лицензию.
   <https://osmfoundation.org/wiki/Licence/Attribution_Guidelines>

## Отвергнутые варианты

- **(б) PMTiles одним файлом.** Поддержка в 6.28.0 есть и проверена, но:
  offline packs с pmtiles-источниками не работают (факт 4) — «скачать регион»
  пришлось бы реализовывать самим: либо готовые региональные .pmtiles на
  своём хостинге (инфраструктура, которой нет), либо собственный экстрактор
  bbox из планетарного файла по HTTP range (свой парсер формата PMTiles на
  Swift — заметный объём нового кода с риском ошибок). Плюс glyphs/sprites
  всё равно нужно кэшировать отдельно. Отклонён по стоимости, не по
  принципиальной невозможности; абстракция `MapTileStore` оставляет дверь
  открытой.
- **(в) MBTiles через локальную отдачу.** Рендер локального файла работает,
  но пути «выбрал bbox в приложении → получил .mbtiles» без своего сервера
  не существует вовсе; генерация регионов остаётся вне устройства. Отклонён.
- **MapKit** — отклонён до ночи (нет легального офлайна).
- **Protomaps basemap style** — совместим с native (style spec общий), есть
  flavor dark (CC0), но схема слоёв Protomaps ≠ OpenMapTiles: к тайлам
  OpenFreeMap его стиль не подходит, а тайлы Protomaps — это либо свой
  хостинг planet.pmtiles, либо их платный API с ключом. Отклонён вместе с
  вариантом (б).

## Почему (а) offline packs

1. Произвольный bbox + диапазон зумов из коробки
   (`MLNTilePyramidOfflineRegion`) — ровно сценарий «перед выходом» из WP2.
2. Пауза/возобновление/прогресс — штатные (`suspend`/`resume`/notification),
   не самописные.
3. Pack скачивает **все** ресурсы региона: тайлы, style JSON, glyphs,
   sprites — авиарежим после скачивания работает без доработок.
4. Лимит Mapbox-тайлов на OpenFreeMap не распространяется (факт 3).
5. Ноль новых кодовых зависимостей и ноль ключей.

## Риски

- **Зависимость от доброй воли OpenFreeMap** (бесплатный сервис). Митигация:
  схема OpenMapTiles немодифицированная — self-hosting их же публичных
  выгрузок или любой OpenMapTiles-сервер подставляется сменой одного URL
  в конфиге; абстракция MapTileStore не даёт этому URL расползтись по коду.
- Вес региона зависит от зума 14 (векторные тайлы OpenMapTiles на z14 —
  основная масса). Фактический замер (28.07, dev-бенч `--bench-map-region`,
  симулятор): Гибралтарский пролив 50×50 км, z0–14, 1058 тайлов —
  **11.7 МБ на диске, скачан за 13.2 с**; средний тайл ~11 КБ (в bbox
  много моря — плотная суша будет тяжелее). Оценщик в UI с дефолтом
  45 КБ/тайл сознательно перезакладывается ×4 — безопаснее для дискового
  бюджета; калибровка — открытый вопрос в REPORT_map_night.md.
- Одна SQLite-база на кэш и регионы: удаление региона освобождает место
  не мгновенно (VACUUM по политике библиотеки). Отражено в UI как
  «размер базы», а не сумма регионов.
- `MinimumOSVersion 12.0` — запас огромный, риска нет.

## Обратимость

Экран и модель данных зависят только от протокола `MapTileStore` (WP2).
Смена offline packs → PMTiles (если появится штатный offline для pmtiles
или свой экстрактор) — замена реализации протокола и конфига, не экрана.

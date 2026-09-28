import Foundation

// ============================================================================
// Единственная дверь для координаты в эфир (WP4, docs/map_layer.md §4).
//
// Гарантия КОДА, а не интерфейса — тот же принцип, что у шёпота Софи:
// исходящий LOCATION-пакет строится только из DisclosedPosition, а
// DisclosedPosition умеет создавать только эта политика (fileprivate init).
// Любой другой путь координаты в Outbox не компилируется по типам —
// кроме исторических SOS/BEACON (грубые координаты по явному действию,
// существовали до слоя карты; перечень путей — в REPORT_map_night.md).
//
// Правила:
//   - нет активного гранта → DisclosureError, ничего не уходит;
//   - .coarse(n) → загрубление ПРИ КОДИРОВАНИИ: в эфир идёт центр ячейки
//     геохеша, восстановить точность из байтов невозможно;
//   - отзыв мгновенный: следующий вызов disclose проваливается.
//
// Время всюду явное (now:) — правила детерминированы и тестируемы
// подкруткой времени.
// ============================================================================

nonisolated enum DisclosureError: Error, Equatable, LocalizedError {
    case noGrant(contactID: String)
    case expired(contactID: String)
    case invalidCoordinate

    var errorDescription: String? {
        switch self {
        case .noGrant(let id): "нет гранта на раскрытие позиции контакту \(id)"
        case .expired(let id): "грант контакту \(id) истёк"
        case .invalidCoordinate: "координата вне допустимого диапазона"
        }
    }
}

/// Позиция, разрешённая к отправке. Создать может ТОЛЬКО
/// LocationDisclosurePolicy (fileprivate init) — это и есть «единственная
/// дверь»: очередь принимает координаты только в этом типе.
nonisolated struct DisclosedPosition: Sendable {
    let contactID: String
    /// Координаты ПОСЛЕ применения точности гранта (для .coarse —
    /// центр ячейки геохеша, не исходная точка).
    let lat: Double
    let lon: Double
    /// Канонические 6 байт эфира (Envelope §5) — уже загрублённые.
    let payload: [UInt8]
    let precision: PositionPrecision
    /// Когда позиция была измерена (не когда раскрыта).
    let measuredAt: Date

    fileprivate init(contactID: String, lat: Double, lon: Double,
                     payload: [UInt8], precision: PositionPrecision,
                     measuredAt: Date) {
        self.contactID = contactID
        self.lat = lat
        self.lon = lon
        self.payload = payload
        self.precision = precision
        self.measuredAt = measuredAt
    }
}

nonisolated enum LocationDisclosurePolicy {

    // MARK: Управление грантами

    /// Выдать грант. Один активный грант на контакт: повторная выдача
    /// заменяет прежний (обновлённые TTL/точность действуют сразу).
    @discardableResult
    static func grant(to contactID: String, precision: PositionPrecision,
                      ttlSeconds: TimeInterval, now: Date,
                      storage: any GrantStorage = DiskGrantStorage()) -> ShareGrant {
        let g = ShareGrant(contactID: contactID, precision: precision,
                           grantedAt: now, ttlSeconds: max(0, ttlSeconds))
        var all = storage.load().filter { $0.contactID != contactID }
        all.append(g)
        storage.save(all)
        return g
    }

    /// Мгновенный односторонний отзыв: следующий маячок не уходит.
    static func revoke(contactID: String,
                       storage: any GrantStorage = DiskGrantStorage()) {
        storage.save(storage.load().filter { $0.contactID != contactID })
    }

    /// Активный грант для контакта (истёкшие не считаются).
    static func activeGrant(for contactID: String, now: Date,
                            storage: any GrantStorage = DiskGrantStorage()) -> ShareGrant? {
        storage.load()
            .first { $0.contactID == contactID && $0.isActive(now: now) }
    }

    /// Все активные гранты — для индикатора «делюсь позицией».
    static func activeGrants(now: Date,
                             storage: any GrantStorage = DiskGrantStorage()) -> [ShareGrant] {
        storage.load().filter { $0.isActive(now: now) }
    }

    // MARK: Дверь

    /// Единственный способ получить DisclosedPosition. Проверяет грант,
    /// применяет точность гранта (не запрошенную кем-то ещё) и кодирует
    /// байты эфира. Загрубление происходит здесь — до очереди, до UI.
    static func disclose(_ fix: PositionFix, to contactID: String,
                         now: Date,
                         storage: any GrantStorage = DiskGrantStorage()) throws -> DisclosedPosition {
        guard let g = storage.load()
            .first(where: { $0.contactID == contactID }) else {
            throw DisclosureError.noGrant(contactID: contactID)
        }
        guard g.isActive(now: now) else {
            throw DisclosureError.expired(contactID: contactID)
        }

        let effective: PositionFix
        switch g.precision {
        case .exact:
            effective = fix
        case .coarse(let length):
            effective = Geohash.coarsen(fix, toLength: length)
        }

        guard let payload = try? PositionCodec.encode(lat: effective.lat,
                                                      lon: effective.lon) else {
            throw DisclosureError.invalidCoordinate
        }
        return DisclosedPosition(contactID: contactID,
                                 lat: effective.lat,
                                 lon: effective.lon,
                                 payload: payload,
                                 precision: g.precision,
                                 measuredAt: fix.timestamp)
    }
}

// Вход в исходящую очередь — ТОЛЬКО LocationTransport.send(_:), который
// принимает исключительно DisclosedPosition (создаётся политикой выше).
// Ограничение wire-формата LOCATION (открытые байты §5 без отправителя,
// шифрование спекой заявлено, но не определено) описано в
// LocationTransport.swift и REPORT_map_night.md.

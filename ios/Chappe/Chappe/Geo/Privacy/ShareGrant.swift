import Foundation

// ============================================================================
// Грант на раскрытие позиции (WP4, docs/map_layer.md §4).
//
// Шеринг выключен по умолчанию: нет гранта — нет раскрытия. Грант всегда
// адресный (конкретный контакт), всегда с TTL и всегда с уровнем точности.
// Отзыв мгновенный и односторонний.
// ============================================================================

/// Миграции полей — только аддитивные optional (правило хранилищ).
nonisolated struct ShareGrant: Codable, Identifiable, Hashable, Sendable {
    /// Один активный грант на контакт — id совпадает с Contact.id.
    var id: String { contactID }

    let contactID: String
    let precision: PositionPrecision
    let grantedAt: Date
    /// Время жизни, секунды («делюсь 4 часа»). Бессрочных грантов нет.
    let ttlSeconds: TimeInterval

    var expiresAt: Date { grantedAt.addingTimeInterval(ttlSeconds) }

    /// Активность считается от явного «сейчас» — тесты подкручивают время.
    func isActive(now: Date) -> Bool {
        now >= grantedAt && now < expiresAt
    }

    /// Остаток жизни для индикатора «делюсь ещё 3 ч 12 мин».
    func remainingSeconds(now: Date) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(now))
    }
}

/// Абстракция хранилища грантов: диск в приложении, память в тестах —
/// тесты гоняются параллельно и не должны делить один файл.
nonisolated protocol GrantStorage: Sendable {
    func load() -> [ShareGrant]
    func save(_ grants: [ShareGrant])
}

/// Боевое хранилище (диск).
nonisolated struct DiskGrantStorage: GrantStorage {
    func load() -> [ShareGrant] { ShareGrantStore.load() }
    func save(_ grants: [ShareGrant]) { ShareGrantStore.save(grants) }
}

/// In-memory хранилище для тестов: изолировано и детерминировано.
nonisolated final class MemoryGrantStorage: GrantStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [ShareGrant] = []

    func load() -> [ShareGrant] {
        lock.lock(); defer { lock.unlock() }
        return grants
    }

    func save(_ grants: [ShareGrant]) {
        lock.lock(); defer { lock.unlock() }
        self.grants = grants
    }
}

/// Хранилище грантов — JSON в Application Support, по образцу contacts.json
/// (SafeHistoryDecoder: битые записи скипаются, файл в карантин).
nonisolated enum ShareGrantStore {

    static func url() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("share_grants.json")
    }

    static func load() -> [ShareGrant] {
        guard let url = try? url(),
              let data = try? Data(contentsOf: url) else { return [] }
        guard let grants = SafeHistoryDecoder.decodeArray(
            ShareGrant.self, from: data, label: "share_grants") else {
            SafeHistoryDecoder.quarantine(url)
            return []
        }
        return grants
    }

    static func save(_ grants: [ShareGrant]) {
        guard let url = try? url(),
              let data = try? JSONEncoder().encode(grants) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

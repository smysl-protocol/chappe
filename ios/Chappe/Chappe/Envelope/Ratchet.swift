import Foundation
import CryptoKit

// ============================================================================
// Рэтчет Б — симметричные эпохи с ре-ключами (ADR 007, принят 02.08).
//
// Эпоха = общий seed 32 Б, переданный рукопожатием (sealed, кодек 3
// v2-рамки). Из seed выводятся:
//   tagKey   = HMAC(seed, "tag")   — вращающиеся теги, фиксирован на эпоху;
//   цепочка A = HMAC(seed, "init") — сообщения инициатора;
//   цепочка B = HMAC(seed, "resp") — сообщения ответчика.
// Ключ сообщения n: mk = HMAC(ck,1), nonce = HMAC(ck,3)[0..12],
// ck' = HMAC(ck,2) — вывод вперёд на любую глубину в пределах потолка.
//
// Провод кодека 4: [4][тег 4][счётчик 2 LE][ct][AEAD-тег 16],
// открытый текст ct: [unix-минуты 4][внутренний кодек][данные].
// Ни ключей, ни nonce, ни отправителя на проводе нет: отправитель
// следует из сессии (поглощение варианта В).
//
// Замечание к ADR (самостоятельное решение, отчёт п.9): в ADR тег
// записан как HMAC(chain_key, счётчик); здесь tagKey фиксирован на
// эпоху — иначе окно кандидатов требовало бы прокрутки цепочки, а
// безопасность не меняется (tagKey секретен и от ключей сообщений
// независим — обе величины выводятся из seed односторонне).
// ============================================================================

nonisolated enum Ratchet {

    static let maxSkip = 128                       // потолок пропусков
    static let skippedTTL: TimeInterval = 14 * 86400
    static let rekeyEvery = 100                    // K из ADR 007
    /// Маркер ratchet-init внутри sealed (вместо внутреннего кодека).
    static let handshakeMarker: UInt8 = 0xF5

    // MARK: Криптопримитивы

    static func hmac(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(
            for: Data(data), using: SymmetricKey(data: Data(key))))
    }

    static func tagKey(seed: [UInt8]) -> [UInt8] {
        hmac(seed, Array("tag".utf8))
    }
    static func chainStart(seed: [UInt8], initiator: Bool) -> [UInt8] {
        hmac(seed, Array(initiator ? "init".utf8 : "resp".utf8))
    }

    /// Вращающийся тег: направление + счётчик, усечение до 4 Б.
    static func tag(tagKey: [UInt8], initiator: Bool,
                    counter: UInt16) -> [UInt8] {
        Array(hmac(tagKey, [initiator ? 1 : 0,
                            UInt8(counter & 0xFF),
                            UInt8(counter >> 8)]).prefix(EnvelopeV2.tagLength))
    }

    /// Сравнение секретно-выведенных байтов за константное время (WP5):
    /// обычное == выходит на первом расхождении — таймингом можно
    /// подбирать байты. XOR-свёртка трогает все байты всегда.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    struct MessageKey: Codable, Equatable {
        var key: [UInt8]       // 32
        var nonce: [UInt8]     // 12
        var storedAt: Date     // для TTL отставших
    }

    static func messageKey(ck: [UInt8], at date: Date = Date()) -> MessageKey {
        MessageKey(key: hmac(ck, [1]),
                   nonce: Array(hmac(ck, [3]).prefix(12)),
                   storedAt: date)
    }
    static func nextChain(_ ck: [UInt8]) -> [UInt8] { hmac(ck, [2]) }

    // MARK: AEAD одного сообщения

    static func seal(plaintext: [UInt8], mk: MessageKey,
                     ad: [UInt8]) throws -> [UInt8] {
        let box = try ChaChaPoly.seal(
            Data(plaintext), using: SymmetricKey(data: Data(mk.key)),
            nonce: ChaChaPoly.Nonce(data: Data(mk.nonce)),
            authenticating: Data(ad))
        return Array(box.ciphertext + box.tag)     // nonce НЕ на проводе
    }

    static func open(wire: [UInt8], mk: MessageKey,
                     ad: [UInt8]) throws -> [UInt8] {
        guard wire.count >= 16 else {
            throw EnvelopeError.tooShort("session: шифртекст короче тега")
        }
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: Data(mk.nonce)),
            ciphertext: Data(wire.dropLast(16)),
            tag: Data(wire.suffix(16)))
        return Array(try ChaChaPoly.open(
            box, using: SymmetricKey(data: Data(mk.key)),
            authenticating: Data(ad)))
    }
}

// MARK: - Состояние эпохи

/// Ошибки, требующие обновления сеанса — пользователь видит одно
/// сообщение, приложение автоматически переигрывает рукопожатие.
nonisolated enum RatchetError: Error, LocalizedError, Equatable {
    case sessionRefreshNeeded(String)   // дыра > потолка, TTL, потеря состояния
    case duplicate                      // ветвление радио+релей — уже читали
    case notForUs                       // тег не совпал ни с одной сессией

    var errorDescription: String? {
        switch self {
        case .sessionRefreshNeeded:
            "Сеанс обновлён — попросите собеседника отправить ещё раз"
        case .duplicate: "повтор уже принятого сообщения"
        case .notForUs: "сообщение не для этого устройства"
        }
    }
}

/// Одна эпоха. Codable — состояние переживает перезапуск.
nonisolated struct RatchetEpoch: Codable, Equatable {
    var seedFingerprint: [UInt8]   // SHA256(seed)[0..8] — идентификация, не секрет
    var tagKey: [UInt8]
    /// Отправка: моя цепочка.
    var sendCK: [UInt8]
    var sendCounter: UInt16 = 0
    var iAmInitiator: Bool
    /// Приём: цепочка собеседника.
    var recvCK: [UInt8]
    var recvNext: UInt16 = 0
    /// Отставшие ключи: счётчик → ключ (потолок Ratchet.maxSkip, TTL 14 дней).
    var skipped: [UInt16: Ratchet.MessageKey] = [:]
    /// Собеседник доказал, что умеет v2 (прислал любой v2-пакет).
    /// До этого исходящие идут v1 — деградация WP3: probe-эпоха
    /// инициатора не переключает отправку, пока нет подтверждения.
    var peerConfirmedV2: Bool = false

    init(seed: [UInt8], iAmInitiator: Bool) {
        self.seedFingerprint = Array(
            Data(SHA256.hash(data: Data(seed))).prefix(8))
        self.tagKey = Ratchet.tagKey(seed: seed)
        self.iAmInitiator = iAmInitiator
        self.sendCK = Ratchet.chainStart(seed: seed, initiator: iAmInitiator)
        self.recvCK = Ratchet.chainStart(seed: seed, initiator: !iAmInitiator)
    }

    // MARK: Отправка

    /// Собирает поток кодека 4: [4][тег][счётчик][ct][AEAD 16].
    /// Открытый текст: [unix-минуты 4][внутренний кодек][данные].
    mutating func sealMessage(innerCodec: UInt8, data: [UInt8],
                              sentAtMinutes: UInt32,
                              now: Date = Date()) throws -> [UInt8] {
        let counter = sendCounter
        let tag = Ratchet.tag(tagKey: tagKey, initiator: iAmInitiator,
                              counter: counter)
        let mk = Ratchet.messageKey(ck: sendCK, at: now)
        sendCK = Ratchet.nextChain(sendCK)
        sendCounter &+= 1

        let ts = sentAtMinutes
        let plaintext = [UInt8(ts & 0xFF), UInt8((ts >> 8) & 0xFF),
                         UInt8((ts >> 16) & 0xFF), UInt8(ts >> 24)]
                        + [innerCodec] + data
        let ad = [EnvelopeV2.codecSession] + tag
            + [UInt8(counter & 0xFF), UInt8(counter >> 8)]
        let ct = try Ratchet.seal(plaintext: plaintext, mk: mk, ad: ad)
        return ad + ct      // ad и есть префикс провода
    }

    var shouldRekey: Bool { sendCounter >= Ratchet.rekeyEvery }

    // MARK: Приём

    /// Теги-кандидаты для окна [recvNext, recvNext+maxSkip) + отставшие.
    /// Сравнение тегов — константное время (WP5): тег выведен из
    /// секретного tagKey, разница времени сравнения не должна помогать
    /// подбирать его байты.
    func candidateCounter(for tag: [UInt8]) -> UInt16? {
        for c in skipped.keys
        where Ratchet.constantTimeEqual(
            Ratchet.tag(tagKey: tagKey, initiator: !iAmInitiator,
                        counter: c), tag) {
            return c
        }
        for offset in 0..<Ratchet.maxSkip {
            let c = recvNext &+ UInt16(offset)
            if Ratchet.constantTimeEqual(
                Ratchet.tag(tagKey: tagKey, initiator: !iAmInitiator,
                            counter: c), tag) {
                return c
            }
        }
        return nil
    }

    /// Открывает поток кодека 4. Возвращает (unix-минуты, кодек, данные).
    mutating func openMessage(stream: [UInt8], now: Date = Date())
    throws -> (sentAtMinutes: UInt32, innerCodec: UInt8, data: [UInt8]) {
        guard stream.count > 1 + EnvelopeV2.tagLength + 2 + 16,
              stream[0] == EnvelopeV2.codecSession else {
            throw EnvelopeError.malformed("это не session-поток")
        }
        let tag = Array(stream[1...(EnvelopeV2.tagLength)])
        let counter = UInt16(stream[5]) | UInt16(stream[6]) << 8
        let ct = Array(stream.dropFirst(7))
        let ad = Array(stream.prefix(7))

        // чистка протухших отставших ключей (TTL 14 дней)
        skipped = skipped.filter {
            now.timeIntervalSince($0.value.storedAt) < Ratchet.skippedTTL
        }

        let mk: Ratchet.MessageKey
        if let waiting = skipped[counter] {
            // отставшее — ключ ждал своего сообщения
            guard Ratchet.constantTimeEqual(
                Ratchet.tag(tagKey: tagKey, initiator: !iAmInitiator,
                            counter: counter), tag) else {
                throw RatchetError.notForUs
            }
            mk = waiting
            skipped[counter] = nil
        } else if counter >= recvNext,
                  Ratchet.constantTimeEqual(
                    Ratchet.tag(tagKey: tagKey, initiator: !iAmInitiator,
                                counter: counter), tag) {
            // впереди: вывести цепочку вперёд, отставшие ключи сохранить
            let gap = Int(counter) - Int(recvNext)
            guard gap < Ratchet.maxSkip else {
                throw RatchetError.sessionRefreshNeeded(
                    "дыра \(gap) глубже потолка \(Ratchet.maxSkip)")
            }
            guard skipped.count + gap <= Ratchet.maxSkip else {
                throw RatchetError.sessionRefreshNeeded(
                    "хранилище отставших ключей переполнено")
            }
            var ck = recvCK
            for c in recvNext..<counter {
                skipped[c] = Ratchet.messageKey(ck: ck, at: now)
                ck = Ratchet.nextChain(ck)
            }
            mk = Ratchet.messageKey(ck: ck, at: now)
            recvCK = Ratchet.nextChain(ck)
            recvNext = counter &+ 1
        } else if counter < recvNext {
            // позади и ключа нет: либо дубль (радио+релей), либо TTL съел
            throw RatchetError.duplicate
        } else {
            throw RatchetError.notForUs
        }

        let plain: [UInt8]
        do {
            plain = try Ratchet.open(wire: ct, mk: mk, ad: ad)
        } catch {
            throw RatchetError.sessionRefreshNeeded(
                "ключ не подошёл — состояние сессий разошлось")
        }
        guard plain.count >= 5 else {
            throw EnvelopeError.malformed("session: открытый текст короче метки")
        }
        let ts = UInt32(plain[0]) | UInt32(plain[1]) << 8
            | UInt32(plain[2]) << 16 | UInt32(plain[3]) << 24
        return (ts, plain[4], Array(plain.dropFirst(5)))
    }
}

// MARK: - Рукопожатие (sealed кодек 3, v2-рамка)

/// Внутренность sealed в v2: [unix-минуты 4][pubkey отправителя 32]
/// [байт кодека ИЛИ 0xF5=ratchet-init]. Для init дальше:
/// [seed 32][внутренний кодек][данные первого сообщения (может быть пусто)].
nonisolated enum RatchetHandshake {

    struct Accepted {
        var senderPub: [UInt8]
        var sentAtMinutes: UInt32
        var epoch: RatchetEpoch      // мы — ответчик
        var innerCodec: UInt8
        var data: [UInt8]            // пусто = чистая проба (probe)
    }

    /// Собирает sealed-поток рукопожатия (кодек 3): seed новой эпохи
    /// + первое сообщение (или пустая проба).
    static func make(seed: [UInt8],
                     to recipient: Curve25519.KeyAgreement.PublicKey,
                     myPub: [UInt8],
                     innerCodec: UInt8, data: [UInt8],
                     sentAtMinutes: UInt32) throws -> [UInt8] {
        let ts = sentAtMinutes
        let inner = [UInt8(ts & 0xFF), UInt8((ts >> 8) & 0xFF),
                     UInt8((ts >> 16) & 0xFF), UInt8(ts >> 24)]
                    + myPub + [Ratchet.handshakeMarker] + seed
                    + [innerCodec] + data
        return try E2ESeal.seal(payload: inner, to: recipient)
    }

    /// Принимает sealed-поток; ratchet-init → эпоха (мы ответчик).
    static func accept(sealed: [UInt8],
                       identity: Curve25519.KeyAgreement.PrivateKey)
    throws -> Accepted {
        let opened = try E2ESeal.open(sealed: sealed, identity: identity)
        guard opened.count >= 4 + 32 + 1 + 32 + 1,
              opened[36] == Ratchet.handshakeMarker else {
            throw EnvelopeError.malformed("это не ratchet-init")
        }
        let ts = UInt32(opened[0]) | UInt32(opened[1]) << 8
            | UInt32(opened[2]) << 16 | UInt32(opened[3]) << 24
        let senderPub = Array(opened[4..<36])
        let seed = Array(opened[37..<69])
        return Accepted(senderPub: senderPub, sentAtMinutes: ts,
                        epoch: RatchetEpoch(seed: seed, iAmInitiator: false),
                        innerCodec: opened[69],
                        data: Array(opened.dropFirst(70)))
    }
}

// MARK: - Хранилище сессий (по контакту)

/// Состояние рэтчета на диске: App Support/Ratchet/<contactID>.json.
/// Файлы защищены Data Protection iOS; вынос в Keychain — отдельным
/// решением (отчёт). Потеря файла = потеря сессии, лечится
/// рукопожатием — это ожидаемое поведение (forward secrecy), не баг.
/// Ревизия параллелизма 06.08: `nonisolated` снят — состояние сессии
/// изолировано MainActor (умолчание проекта). Компилятор больше не
/// молчит на фоновом доступе: цена молчаливой гонки здесь — потеря
/// счётчика рэтчета, то есть нерасшифруемые сообщения у собеседника.
enum RatchetStore {

    /// Единственная безопасная форма «прочитать-изменить-записать».
    /// Атомарность даётся КОНСТРУКЦИЕЙ: изоляция MainActor исключает
    /// параллельные входы, а СИНХРОННОЕ замыкание не даёт вставить
    /// `await` внутрь критической секции (это ошибка компиляции).
    /// nil в замыкании — эпохи ещё нет; присвоение nil — удалить.
    @discardableResult
    static func update<T>(contactID: String,
                          _ body: (inout RatchetEpoch?) -> T) -> T {
        var epoch = load(contactID: contactID)
        let result = body(&epoch)
        if let epoch {
            save(epoch, contactID: contactID)
        } else {
            drop(contactID: contactID)
        }
        return result
    }

    static func url(contactID: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        var dir = base.appendingPathComponent("Ratchet", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        // WP3 (05.08): состояние рэтчета НЕ уезжает в iCloud-бэкап —
        // восстановленное старое состояние это рассинхрон сессии и
        // откат forward secrecy (счётчики назад). Потеря при переносе
        // устройства ожидаема: сессия лечится рукопожатием.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir.appendingPathComponent("session_\(contactID).json")
    }

    static func load(contactID: String) -> RatchetEpoch? {
        guard let url = try? url(contactID: contactID),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RatchetEpoch.self, from: data)
    }

    static func save(_ epoch: RatchetEpoch, contactID: String) {
        guard let url = try? url(contactID: contactID),
              let data = try? JSONEncoder().encode(epoch) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func drop(contactID: String) {
        guard let url = try? url(contactID: contactID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

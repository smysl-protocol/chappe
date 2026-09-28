import Foundation
import CryptoKit

// ============================================================================
// HTTP-клиент релея (rm-relay). Спека: docs/relay_spec_v0.md,
// docs/relay_ops.md §WP4.2 (таблица кодов), rm-relay/internal/api.
//
// Правила, ради которых клиент написан именно так:
//  - КАЖДЫЙ код ответа релея — отдельный исход с отдельным поведением
//    и отдельной строкой человеку. «Ошибка отправки» без причины —
//    та же тихая потеря, что у узла Meshtastic 03.08.
//  - Ключ личности релею не предъявляется НИКОГДА: чтение ящика
//    подписывается box-ключом эпохи (RelayBoxKey), который выводится
//    из тех же данных, что и dst.
//  - Челлендж одноразовый, живёт 60 с и привязан к своему dst —
//    на каждый GET и каждый DELETE берётся СВЕЖИЙ челлендж, подпись
//    не переиспользуется.
//  - Таймаут/обрыв — «неизвестно», не успех: повтор безопасен,
//    дедуп релея по (dst, msgID, фрагмент, SHA-256) идемпотентен.
// ============================================================================

// MARK: - Box-ключ эпохи

/// Зеркало rm-relay/internal/boxkey (Go). Порядок и разделители
/// зафиксированы обеими реализациями; кросс-вектор — RelayBoxKeyTests
/// (ожидания сгенерированы Go-реализацией, не этим кодом).
nonisolated enum RelayBoxKey {

    /// Ключ ящика на эпоху: seed = SHA-256("rm-mailbox-read-v1" ‖
    /// pub получателя ‖ ключ пары ‖ эпоха LE32). Считается одинаково
    /// на обоих концах пары; релей видит только открытую часть.
    static func derive(recipientPub: Data, pairKey: Data,
                       epoch: Int) -> Curve25519.Signing.PrivateKey {
        var input = Data("rm-mailbox-read-v1".utf8)
        input.append(recipientPub)
        input.append(pairKey)
        let v = UInt32(clamping: epoch)
        input.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                                  UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
        let seed = Data(SHA256.hash(data: input))
        // 32 байта SHA-256 — всегда валидный seed Ed25519
        return try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    /// Данные подписи челленджа: "rm-box-challenge-v1" ‖ nonce ‖
    /// issued_at BE64. Метка времени входит в подпись — иначе окно
    /// повтора растяжимо (boxkey.go, signedData).
    static func challengeData(nonce: Data, issuedAt: Int64) -> Data {
        var data = Data("rm-box-challenge-v1".utf8)
        data.append(nonce)
        let ts = UInt64(bitPattern: issuedAt)
        data.append(contentsOf: (0..<8).reversed().map {
            UInt8((ts >> ($0 * 8)) & 0xFF)
        })
        return data
    }

    static func signChallenge(key: Curve25519.Signing.PrivateKey,
                              nonce: Data, issuedAt: Int64) throws -> Data {
        try key.signature(for: challengeData(nonce: nonce, issuedAt: issuedAt))
    }
}

// MARK: - Клиент

nonisolated struct RelayClient: Sendable {

    let baseURL: URL
    /// Отдельная сессия с коротким таймаутом: телефон в плохой сети не
    /// должен минуту висеть на каждом запросе насоса.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // релей не должен получать язык/куки системы
        config.httpAdditionalHeaders = [:]
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    init?(urlString: String) {
        guard let url = URL(string: urlString), url.host != nil else {
            return nil
        }
        baseURL = url
    }

    // MARK: Исходы PUT — полная таблица кодов relay_ops WP4.2

    enum PutOutcome: Equatable, Sendable {
        case stored(duplicate: Bool)      // 200, после fsync релея
        case expiredUndelivered           // 410: надгробие — не дойдёт
        case boxFull                      // 507: ящик получателя полон
        case tooLarge                     // 413: кадр больше предела
        case badFrame                     // 400: битый кадр — не повторять
        case foreignKey                   // 409: за ящиком чужой ключ
        case rateLimited(retryAfter: Int) // 429
        case storageDown                  // 503: диск релея
        case serverError                  // 500: сбой релея
        case unreachable                  // сеть: таймаут/обрыв = «неизвестно»

        /// Строка человеку — у каждого кода своя (требование WP1).
        var human: String {
            switch self {
            case .stored(true): "в ящике у получателя (повтор)"
            case .stored(false): "в ящике у получателя"
            case .expiredUndelivered:
                "не доставлено: получатель не забрал за 48 ч"
            case .boxFull: "ящик получателя полон — повторю позже"
            case .tooLarge: "сообщение больше предела сервера"
            case .badFrame: "сервер не принял сообщение (ошибка формата)"
            case .foreignKey: "ящик занят чужим ключом"
            case .rateLimited: "сервер просит помедленнее — повторю"
            case .storageDown: "хранилище сервера недоступно — повторю"
            case .serverError: "сбой сервера — повторю"
            case .unreachable: "сервер недоступен — повторю"
            }
        }

        /// Повторять ли PUT этого же кадра.
        var retryable: Bool {
            switch self {
            case .stored, .expiredUndelivered, .tooLarge, .badFrame,
                 .foreignKey: false
            case .boxFull, .rateLimited, .storageDown, .serverError,
                 .unreachable: true
            }
        }
    }

    /// PUT кадра в ящик. 200 отдаётся релеем только после fsync —
    /// .stored означает «на диске», не «в буфере».
    func put(frame: [UInt8], dstHex: String,
             boxPublic: Data) async -> PutOutcome {
        var request = URLRequest(url: baseURL.appendingPathComponent("box")
            .appendingPathComponent(dstHex))
        request.httpMethod = "PUT"
        request.httpBody = Data(frame)
        request.setValue(boxPublic.base64EncodedString(),
                         forHTTPHeaderField: "X-Box-Key")
        guard let (_, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .unreachable
        }
        switch http.statusCode {
        case 200: return .stored(duplicate: false)
        case 400: return .badFrame
        case 409: return .foreignKey
        case 410: return .expiredUndelivered
        case 413: return .tooLarge
        case 429: return .rateLimited(retryAfter: Int(
            http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60)
        case 503: return .storageDown
        case 507: return .boxFull
        default: return .serverError
        }
    }

    // MARK: Чтение ящика

    struct BoxedFrame: Sendable, Equatable {
        let id: Int64
        let body: [UInt8]
    }

    enum FetchOutcome: Sendable, Equatable {
        case frames([BoxedFrame])
        case denied          // 401: подпись не принята
        case rateLimited(retryAfter: Int)
        case unavailable     // 5xx
        case unreachable
    }

    /// Челлендж → подпись box-ключом → GET. Челлендж свежий на каждый
    /// вызов: одноразовость — сторона релея, мы просто не жадничаем.
    func fetch(dstHex: String,
               key: Curve25519.Signing.PrivateKey) async -> FetchOutcome {
        guard let ch = await challenge(dstHex: dstHex) else {
            return .unreachable
        }
        guard let sig = try? RelayBoxKey.signChallenge(
            key: key, nonce: ch.nonce, issuedAt: ch.issuedAt) else {
            return .denied
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("box")
            .appendingPathComponent(dstHex))
        request.setValue(ch.id, forHTTPHeaderField: "X-Challenge-Id")
        request.setValue(sig.base64EncodedString(),
                         forHTTPHeaderField: "X-Signature")
        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .unreachable
        }
        switch http.statusCode {
        case 200:
            guard let parsed = try? JSONDecoder().decode(
                FramesEnvelope.self, from: data) else { return .unavailable }
            return .frames(parsed.frames.compactMap { f in
                Data(base64Encoded: f.body).map {
                    BoxedFrame(id: f.id, body: Array($0))
                }
            })
        case 401: return .denied
        case 429: return .rateLimited(retryAfter: Int(
            http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60)
        default: return .unavailable
        }
    }

    /// DELETE = подтверждение получения (at-least-once: строка ящика
    /// умирает только здесь). Свой свежий челлендж — старый уже потрачен.
    @discardableResult
    func delete(dstHex: String, frameID: Int64,
                key: Curve25519.Signing.PrivateKey) async -> Bool {
        guard let ch = await challenge(dstHex: dstHex),
              let sig = try? RelayBoxKey.signChallenge(
                key: key, nonce: ch.nonce, issuedAt: ch.issuedAt) else {
            return false
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("box")
            .appendingPathComponent(dstHex)
            .appendingPathComponent(String(frameID)))
        request.httpMethod = "DELETE"
        request.setValue(ch.id, forHTTPHeaderField: "X-Challenge-Id")
        request.setValue(sig.base64EncodedString(),
                         forHTTPHeaderField: "X-Signature")
        guard let (_, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: Челлендж

    private struct ChallengeEnvelope: Decodable {
        let id: String
        let nonce: String
        let issued_at: Int64
    }
    private struct FramesEnvelope: Decodable {
        struct F: Decodable {
            let id: Int64
            let body: String
        }
        let frames: [F]
    }

    private func challenge(dstHex: String)
    async -> (id: String, nonce: Data, issuedAt: Int64)? {
        let url = baseURL.appendingPathComponent("box")
            .appendingPathComponent(dstHex)
            .appendingPathComponent("challenge")
        guard let (data, response) = try? await Self.session.data(
                from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONDecoder().decode(ChallengeEnvelope.self,
                                                     from: data),
              let nonce = Data(base64Encoded: parsed.nonce) else {
            return nil
        }
        return (parsed.id, nonce, parsed.issued_at)
    }
}

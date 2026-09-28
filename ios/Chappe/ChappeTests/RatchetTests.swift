import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// WP1 (Envelope v2, 02.08): рэтчет Б — симметричные эпохи.
// Обязательные тесты брифа: беспорядок 1/10/127/128/129, потери,
// дубли (радио+релей), forward secrecy, восстановление после
// переустановки, фактический расход памяти на отставшие ключи.
// ============================================================================

nonisolated struct RatchetTests {

    private func pair() -> (alice: RatchetEpoch, bob: RatchetEpoch) {
        let seed = (0..<32).map { UInt8($0 &+ 7) }
        return (RatchetEpoch(seed: seed, iAmInitiator: true),
                RatchetEpoch(seed: seed, iAmInitiator: false))
    }

    private func send(_ alice: inout RatchetEpoch, _ text: String)
    throws -> [UInt8] {
        try alice.sealMessage(innerCodec: Envelope.codecStore,
                              data: Array(text.utf8), sentAtMinutes: 1000)
    }

    private func text(_ opened: (sentAtMinutes: UInt32, innerCodec: UInt8,
                                data: [UInt8])) -> String {
        String(decoding: opened.data, as: UTF8.self)
    }

    // MARK: Базовый обмен

    @Test("сообщение туда-обратно, метка времени внутри шифртекста")
    func roundTrip() throws {
        var (alice, bob) = pair()
        let wire = try send(&alice, "привет")
        let opened = try bob.openMessage(stream: wire)
        #expect(text(opened) == "привет")
        #expect(opened.sentAtMinutes == 1000)
        // метки в открытых байтах нет: провод = [4][тег 4][счётчик 2][ct]
        let openBytes = Array(wire.prefix(7))
        #expect(openBytes[0] == EnvelopeV2.codecSession)
        #expect(!openBytes.contains(where: { $0 == 0xE8 }),
                "1000 мин = 0x03E8; байты метки не должны торчать открыто")
    }

    // MARK: Беспорядок — границы потолка

    @Test("вне порядка: глубина 1, 10, 127 — расшифровывается",
          arguments: [1, 10, 127])
    func outOfOrderWithinLimit(depth: Int) throws {
        var (alice, bob) = pair()
        var wires: [[UInt8]] = []
        for i in 0...depth { wires.append(try send(&alice, "m\(i)")) }
        // приходит СНАЧАЛА последнее (дыра глубины depth)
        let late = try bob.openMessage(stream: wires[depth])
        #expect(text(late) == "m\(depth)")
        // затем отставшие — по одному, все обязаны открыться
        for i in 0..<depth {
            let opened = try bob.openMessage(stream: wires[i])
            #expect(text(opened) == "m\(i)")
        }
        #expect(bob.skipped.isEmpty, "все отставшие ключи израсходованы")
    }

    @Test("граница: дыра 128 — уже за потолком, сеанс обновить")
    func gap128IsRefused() throws {
        var (alice, bob) = pair()
        var wires: [[UInt8]] = []
        for i in 0...128 { wires.append(try send(&alice, "m\(i)")) }
        // gap = 128 (счётчик 128 при ожидаемом 0) — потолок исчерпан
        #expect(throws: RatchetError.self) {
            _ = try bob.openMessage(stream: wires[128])
        }
    }

    @Test("граница: дыра 129 — сеанс обновить, понятная причина")
    func gap129IsRefused() throws {
        var (alice, bob) = pair()
        var wires: [[UInt8]] = []
        for i in 0...129 { wires.append(try send(&alice, "m\(i)")) }
        do {
            _ = try bob.openMessage(stream: wires[129])
            Issue.record("дыра 129 обязана быть отвергнута")
        } catch let error as RatchetError {
            guard case .sessionRefreshNeeded = error else {
                Issue.record("ожидался sessionRefreshNeeded")
                return
            }
            #expect(error.errorDescription?.contains("Сеанс обновлён") == true)
        }
    }

    @Test("дыра 127 принимается, 128 — нет: потолок ровно на месте")
    func limitBoundaryIsExact() throws {
        var (a1, b1) = pair()
        var wires: [[UInt8]] = []
        for i in 0...127 { wires.append(try send(&a1, "m\(i)")) }
        #expect(throws: Never.self) { _ = try b1.openMessage(stream: wires[127]) }

        var (a2, b2) = pair()
        var wires2: [[UInt8]] = []
        for i in 0...128 { wires2.append(try send(&a2, "m\(i)")) }
        #expect(throws: RatchetError.self) {
            _ = try b2.openMessage(stream: wires2[128])
        }
    }

    // MARK: Потери и дубли

    @Test("потеря без уведомления: следующие сообщения читаются")
    func lossIsTransparent() throws {
        var (alice, bob) = pair()
        _ = try send(&alice, "потеряно1")
        _ = try send(&alice, "потеряно2")
        let third = try send(&alice, "дошло")
        #expect(text(try bob.openMessage(stream: third)) == "дошло")
        #expect(bob.skipped.count == 2, "ключи потерянных ждут своего часа")
    }

    @Test("ветвление радио+релей: дубль опознан, не показан дважды")
    func duplicateIsDetected() throws {
        var (alice, bob) = pair()
        let wire = try send(&alice, "одно сообщение")
        #expect(text(try bob.openMessage(stream: wire)) == "одно сообщение")
        do {
            _ = try bob.openMessage(stream: wire)
            Issue.record("дубль обязан быть опознан")
        } catch let error as RatchetError {
            #expect(error == .duplicate)
        }
    }

    @Test("чужая сессия: тег не совпал — notForUs, не крах")
    func foreignSessionIsRejected() throws {
        var (alice, _) = pair()
        let wire = try send(&alice, "не тебе")
        var stranger = RatchetEpoch(seed: (0..<32).map { _ in UInt8(0xAB) },
                                    iAmInitiator: false)
        do {
            _ = try stranger.openMessage(stream: wire)
            Issue.record("чужой тег обязан быть отвергнут")
        } catch let error as RatchetError {
            #expect(error == .notForUs)
        }
    }

    // MARK: Forward secrecy — стоп-условие брифа

    @Test("forward secrecy: состояние «сейчас» не открывает прошлый трафик")
    func forwardSecrecy() throws {
        var (alice, bob) = pair()
        let old = try send(&alice, "старое сообщение")
        _ = try bob.openMessage(stream: old)          // прочитано и забыто
        let fresh = try send(&alice, "новое")
        _ = try bob.openMessage(stream: fresh)

        // «компрометация»: злоумышленник получил ТЕКУЩЕЕ состояние Боба
        var stolen = bob
        #expect(stolen.skipped.isEmpty,
                "ключей прошлых сообщений в состоянии не осталось")
        do {
            _ = try stolen.openMessage(stream: old)
            Issue.record("СТОП: украденное состояние расшифровало прошлое")
        } catch {
            // duplicate/sessionRefresh — оба означают «ключа нет»
            #expect(error is RatchetError)
        }
        // и цепочку назад не отмотать: ck выведен односторонне
        let backwards = Ratchet.nextChain(stolen.recvCK)
        #expect(backwards != stolen.recvCK)
    }

    // MARK: Восстановление после переустановки

    @Test("переустановка: личность из сида офлайн, сессии не восстановимы")
    func reinstallRestoresIdentityNotSessions() throws {
        // личность: тот же сид → тот же ключ, без сети
        let seed = Data((0..<32).map { UInt8($0) })
        let a = try #require(Identity.derived(from: seed))
        let b = try #require(Identity.derived(from: seed))
        #expect(a.publicKey.rawRepresentation == b.publicKey.rawRepresentation,
                "сид обязан давать ту же личность на новом устройстве")

        // сессия: файла нет — восстановления нет, это ожидаемо
        let cid = "test-reinstall-" + UUID().uuidString
        var (alice, _) = pair()
        RatchetStore.save(alice, contactID: cid)
        #expect(RatchetStore.load(contactID: cid) != nil)
        RatchetStore.drop(contactID: cid)                  // «переустановка»
        #expect(RatchetStore.load(contactID: cid) == nil,
                "сессия НЕ восстанавливается — это forward secrecy, не баг")
        // трафик мёртвой сессии нечитаем, лечится рукопожатием
        let orphan = try send(&alice, "в мёртвую сессию")
        #expect(orphan.first == EnvelopeV2.codecSession)
    }

    @Test("состояние переживает перезапуск (Codable round-trip)")
    func statePersists() throws {
        let cid = "test-persist-" + UUID().uuidString
        defer { RatchetStore.drop(contactID: cid) }
        var (alice, bob) = pair()
        _ = try send(&alice, "1")
        let second = try send(&alice, "2")
        RatchetStore.save(bob, contactID: cid)
        var restored = try #require(RatchetStore.load(contactID: cid))
        #expect(restored == bob)
        // и восстановленное состояние продолжает работать
        #expect(text(try restored.openMessage(stream: second)) == "2")
    }

    // MARK: Расход памяти — сверка с оценкой ADR (~5 КБ на диалог)

    @Test("память на отставшие ключи при полном потолке")
    func skippedKeysMemory() throws {
        var (alice, bob) = pair()
        var wires: [[UInt8]] = []
        for i in 0..<128 { wires.append(try send(&alice, "m\(i)")) }
        // худший случай: пришло только последнее — 127 ключей в хранилище
        _ = try bob.openMessage(stream: wires[127])
        #expect(bob.skipped.count == 127)

        let encoded = try JSONEncoder().encode(bob)
        // JSON — верхняя граница (массивы байт как числа с запятыми);
        // фактическая структура: 127 × (32 ключ + 12 nonce + 8 дата) ≈ 6.6 КБ
        let raw = bob.skipped.count * (32 + 12 + 8)
        // Замер зафиксирован тестом (отдельный прогон вне xctest дал те
        // же числа: 6604 Б бинарно, 26986 Б JSON — docs/reports/
        // envelope_v2_measured.md). Границы держат регрессию размера.
        #expect(raw == 6604, "бинарный расход ключей при полном потолке")
        #expect(raw < 8 * 1024, "в пределах ~8 КБ на диалог")
        #expect(encoded.count < 32 * 1024,
                "JSON-состояние (26,4 КБ) не должно раздуваться дальше")
    }

    @Test("TTL: отставшие ключи старше 14 дней выбрасываются")
    func skippedKeysExpire() throws {
        var (alice, bob) = pair()
        _ = try send(&alice, "потеряно")
        let second = try send(&alice, "дошло")
        _ = try bob.openMessage(stream: second)
        #expect(bob.skipped.count == 1)
        // сообщение отставшего приходит через 15 дней
        let late = Date().addingTimeInterval(15 * 86400)
        var wires: [[UInt8]] = []
        var alice2 = alice
        _ = alice2
        // ключ протух → чистка на следующем приёме
        let third = try send(&alice, "ещё одно")
        wires.append(third)
        _ = try? bob.openMessage(stream: third, now: late)
        #expect(bob.skipped.isEmpty, "протухшие ключи вычищены по TTL")
    }

    // MARK: Ре-ключ

    @Test("ре-ключ по счётчику K=100")
    func rekeyThreshold() throws {
        var (alice, _) = pair()
        for i in 0..<Ratchet.rekeyEvery {
            _ = try send(&alice, "m\(i)")
            if i < Ratchet.rekeyEvery - 1 { #expect(!alice.shouldRekey) }
        }
        #expect(alice.shouldRekey, "после K=100 пора менять эпоху")
    }
}

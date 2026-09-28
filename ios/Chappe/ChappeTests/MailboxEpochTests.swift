import Foundation
import Testing
import CryptoKit
@testable import Chappe

// ============================================================================
// ЭПОХИ ЯЩИКА со сдвигом от ключа пары (решение владельца 04.08).
//
// Было: граница суток псевдонима — полночь UTC. Проблема (найдена
// разбором приватности, docs/relay_privacy.md): для Вьетнама/Бали
// ротация приходится на 7-8 утра — человеческий день ложится в два
// dst и сшивается активным диалогом.
//
// Отклонён вариант «постоянный сдвиг из ключа пары»: постоянная ФАЗА
// ротации сама становится отпечатком пары — релей за пару недель
// вычисляет сдвиг и связывает псевдонимы МЕЖДУ сутками, ломая ровно
// ту несвязываемость, ради которой dst вращается.
//
// Принято: сдвиг ПСЕВДОСЛУЧАЙНЫЙ на каждую эпоху —
// shift(e) = HMAC-SHA256(ключ пары, "mailbox-shift" ‖ e) mod 86400.
// Оба конца считают одинаково; для релея граница каждый раз в новом
// месте — фазы-отпечатка нет.
//
// Требование владельца: окно приёма обязано покрывать соседние эпохи
// НЕ ХУЖЕ нынешних −2…+1 суток — сообщение, отправленное в момент
// смены границы, теряться не должно.
// ============================================================================

nonisolated struct MailboxEpochTests {

    /// Ключ пары в тестах — фиксированный, чтобы вектора были
    /// воспроизводимы (в бою выводится из X25519 общего секрета).
    private static let pairKey = Data(repeating: 0x5A, count: 32)
    private static let otherKey = Data(repeating: 0xA5, count: 32)

    // MARK: сдвиг

    @Test("сдвиг лежит внутри суток и зависит от эпохи")
    func shiftInRange() {
        for epoch in 20000...20010 {
            let s = MailboxID.shift(pairKey: Self.pairKey, epoch: epoch)
            #expect(s >= 0 && s < 86400)
        }
        // разные эпохи — разные сдвиги (фазы-отпечатка нет)
        let shifts = Set((20000...20030).map {
            MailboxID.shift(pairKey: Self.pairKey, epoch: $0)
        })
        #expect(shifts.count >= 25,
                "сдвиг обязан гулять по эпохам, иначе это постоянная фаза")
    }

    @Test("у разных пар сдвиг разный")
    func shiftDiffersByPair() {
        let a = MailboxID.shift(pairKey: Self.pairKey, epoch: 20000)
        let b = MailboxID.shift(pairKey: Self.otherKey, epoch: 20000)
        #expect(a != b)
    }

    // MARK: границы и монотонность

    @Test("границы эпох строго возрастают")
    func boundariesMonotonic() {
        var previous = -Double.infinity
        for epoch in 20000...20100 {
            let b = MailboxID.boundary(pairKey: Self.pairKey, epoch: epoch)
            #expect(b > previous, "граница эпохи \(epoch) не возросла")
            previous = b
        }
    }

    @Test("момент времени попадает ровно в свою эпоху")
    func epochContainsItsInstant() {
        for epoch in 20000...20050 {
            let start = MailboxID.boundary(pairKey: Self.pairKey, epoch: epoch)
            let next = MailboxID.boundary(pairKey: Self.pairKey,
                                          epoch: epoch + 1)
            for t in [start, start + 1, (start + next) / 2, next - 1] {
                let got = MailboxID.epoch(pairKey: Self.pairKey,
                                          at: Date(timeIntervalSince1970: t))
                #expect(got == epoch,
                        "t=\(t) отнесено к эпохе \(got), ожидалась \(epoch)")
            }
        }
    }

    // MARK: окно приёма — требование владельца

    @Test("окно приёма покрывает 48 ч назад и 24 ч вперёд")
    func windowCoversRequiredSpan() {
        let now = Date(timeIntervalSince1970: 20000 * 86400 + 12345)
        let epochs = MailboxID.acceptedEpochs(pairKey: Self.pairKey, now: now)
        // всякий момент внутри [-48 ч, +24 ч] обязан принадлежать
        // эпохе из окна — иначе сообщение потеряется
        for offset in stride(from: -48.0 * 3600, through: 24.0 * 3600,
                             by: 600) {
            let t = now.addingTimeInterval(offset)
            let e = MailboxID.epoch(pairKey: Self.pairKey, at: t)
            #expect(epochs.contains(e),
                    "момент \(offset / 3600) ч от сейчас выпал из окна")
        }
    }

    @Test("сообщение, отправленное в момент смены границы, принимается")
    func boundaryCrossingNotLost() {
        // отправитель на своей границе эпохи, получатель — на секунду
        // раньше и на секунду позже: dst обязан приниматься в обоих
        let pub = Data(repeating: 0x2A, count: 32)
        for epoch in 20000...20020 {
            let edge = MailboxID.boundary(pairKey: Self.pairKey, epoch: epoch)
            let sent = MailboxID.dstForSending(
                recipientPub: pub, pairKey: Self.pairKey,
                now: Date(timeIntervalSince1970: edge))
            for delta in [-1.0, 0.0, 1.0, 60.0, -60.0] {
                let at = Date(timeIntervalSince1970: edge + delta)
                #expect(MailboxID.isMine(sent, myPub: pub,
                                         pairKey: Self.pairKey, now: at),
                        "на границе эпохи \(epoch) (Δ\(delta) с) потерялось")
            }
        }
    }

    @Test("вчерашний и позавчерашний dst ещё принимаются, трёхдневный — нет")
    func windowEdges() {
        let pub = Data(repeating: 0x2A, count: 32)
        let now = Date(timeIntervalSince1970: 20000 * 86400 + 40000)
        for hoursAgo in [1.0, 24.0, 47.0] {
            let sent = MailboxID.dstForSending(
                recipientPub: pub, pairKey: Self.pairKey,
                now: now.addingTimeInterval(-hoursAgo * 3600))
            #expect(MailboxID.isMine(sent, myPub: pub, pairKey: Self.pairKey,
                                     now: now),
                    "\(hoursAgo) ч назад обязано приниматься (релей хранит 48 ч)")
        }
        let ancient = MailboxID.dstForSending(
            recipientPub: pub, pairKey: Self.pairKey,
            now: now.addingTimeInterval(-96 * 3600))
        #expect(!MailboxID.isMine(ancient, myPub: pub, pairKey: Self.pairKey,
                                  now: now),
                "четырёхдневный псевдоним обязан отвергаться")
    }

    // MARK: разные пары — разные ящики

    @Test("разные пары пишут в разные ящики одному получателю")
    func distinctBoxesPerPair() {
        let pub = Data(repeating: 0x2A, count: 32)
        let now = Date(timeIntervalSince1970: 20000 * 86400 + 1000)
        let fromA = MailboxID.dstForSending(recipientPub: pub,
                                            pairKey: Self.pairKey, now: now)
        let fromB = MailboxID.dstForSending(recipientPub: pub,
                                            pairKey: Self.otherKey, now: now)
        #expect(fromA != fromB,
                "иначе релей видит всех корреспондентов в одном ящике")
    }

    // MARK: ключ пары

    @Test("ключ пары одинаков с обоих концов")
    func pairKeySymmetric() throws {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let fromA = try MailboxID.pairKey(myPrivate: a,
                                          peerPublic: b.publicKey)
        let fromB = try MailboxID.pairKey(myPrivate: b,
                                          peerPublic: a.publicKey)
        #expect(fromA == fromB)
        #expect(fromA.count == 32)
    }

    // MARK: golden — воспроизводимость (посчитано независимо, python)

    @Test("golden: сдвиг и dst воспроизводимы по фиксированным входам")
    func goldenEpochVectors() {
        // HMAC-SHA256(0x5A×32, "mailbox-shift" ‖ 20000 LE32)[0..4] BE mod 86400
        #expect(MailboxID.shift(pairKey: Self.pairKey, epoch: 20000)
                == MailboxEpochGolden.shift20000)
        let pub = Data(repeating: 0x2A, count: 32)
        #expect(MailboxID.dst(recipientPub: pub, pairKey: Self.pairKey,
                              epoch: 20000)
                .map { String(format: "%02x", $0) }.joined()
                == MailboxEpochGolden.dst20000)
    }
}

/// Эталоны, посчитанные ВНЕ приложения (python, hmac+hashlib) — внешнее
/// ожидание по правилу CLAUDE.md №4: тест обязан содержать ожидание,
/// не выводимое из проверяемого кода.
nonisolated enum MailboxEpochGolden {
    // python: hmac.new(0x5A*32, b"mailbox-shift"+pack("<I",20000),
    //         sha256).digest()[:4] BE % 86400
    static let shift20000 = 79192
    // python: sha256(0x2A*32 ‖ 0x5A*32 ‖ pack("<I",20000)).digest()[:8]
    static let dst20000 = "59ae83f55101efb4"
}

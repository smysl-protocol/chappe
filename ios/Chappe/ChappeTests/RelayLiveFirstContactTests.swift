import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// ЖИВОЙ прогон первоконтактного пути против БОЕВОГО релея (форензика
// 29.09: интро после пересканирования QR не образует чат; кадры лежат
// в ящике незабранными, надгробий 0). Тест играет ОБЕ стороны
// продуктовым кодом: sendTarget → put → acceptedDsts → fetch → delete.
//
// В сюиту не входит: ходит в сеть (боевой relay.chappe.me), гоняется
// только явно с TEST_RUNNER_RM_RELAY_LIVE=1. Ключи — свежие случайные:
// боевому релею это неотличимо от нового пользователя, мусор за собой
// убираем (delete), 256-байтовый бакет не нарушаем.
// ============================================================================

struct RelayLiveFirstContactTests {

    /// Файл-флаг вместо env: TEST_RUNNER_-переменные теряются на клонах
    /// симулятора, а /tmp Мака виден из тестового процесса напрямую.
    private var live: Bool {
        FileManager.default.fileExists(atPath: "/tmp/rm_relay_live")
    }

    @Test("первый контакт: put отправителя виден и забираем получателем")
    func firstContactRoundtripAgainstLiveRelay() async throws {
        guard live else { return }   // сюита в сеть не ходит

        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let recipientPub = recipient.publicKey.rawRepresentation
        let client = try #require(RelayClient(
            urlString: RelayTransport.defaultURL))

        // --- Отправитель: адрес и PUT (продуктовые формулы) ---
        let target = FirstContactMailbox.sendTarget(recipientPub: recipientPub)
        var frame: [UInt8] = [0x02]                    // маркер v2 не важен
        frame.append(contentsOf: (1...255).map { UInt8($0 % 251) })  // 256 Б
        let putOutcome = await client.put(
            frame: frame,
            dstHex: RelayTransport.hex(target.dst),
            boxPublic: target.boxPublic)
        #expect(putOutcome == .stored(duplicate: false),
                "PUT обязан лечь: \(putOutcome)")

        // --- Получатель: свои первоконтактные dst и забор ---
        var got = 0
        var matchedDst = false
        for (dst, epoch) in FirstContactMailbox.acceptedDsts(myPub: recipientPub) {
            if dst == target.dst { matchedDst = true }
            let key = FirstContactMailbox.boxKey(recipientPub: recipientPub,
                                                 epoch: epoch)
            switch await client.fetch(dstHex: RelayTransport.hex(dst), key: key) {
            case .frames(let frames):
                for f in frames where Array(f.body) == frame {
                    got += 1
                    await client.delete(dstHex: RelayTransport.hex(dst),
                                        frameID: f.id, key: key)
                }
            case .rateLimited, .denied, .unavailable, .unreachable:
                continue
            }
        }
        #expect(matchedDst, Comment(rawValue:
                "dst отправителя обязан быть среди acceptedDsts получателя — "
                + "иначе стороны считают РАЗНЫЕ ящики (вот и незабранные кадры)"))
        #expect(got == 1, Comment(rawValue:
                "кадр обязан быть виден и забираем подписью получателя; "
                + "got=\(got): 0 при matchedDst=true означает 401 — ключ "
                + "ящика дерайвится по-разному"))
    }
}

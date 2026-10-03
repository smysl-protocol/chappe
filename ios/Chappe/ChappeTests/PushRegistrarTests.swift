import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Пуш-подписки (relay_push_spec §4.2–4.4, сборка 34). Внешние
// ожидания: golden-байты формата подписи собраны руками из спеки;
// K=7/back=2 — числа решений §9; подпись проверяется независимым
// Ed25519-verify по derived-публичному ключу.
// ============================================================================

struct PushRegistrarTests {

    @Test("байты подписи подписки — по спеке, руками")
    func subSignedDataGolden() {
        let got = PushRegistrar.subSignedData(
            nonce: Data([0xAA, 0xBB]),
            token: Data([0x01, 0x02, 0x03]),
            dst: [0xD1, 0xD2])
        let want = Data("rm-push-sub-v1".utf8)
            + Data([0xAA, 0xBB, 0x01, 0x02, 0x03, 0xD1, 0xD2])
        #expect(got == want, Comment(rawValue:
                "формат разошёлся со спекой §4.2 — релей отвергнет все "
                + "подписки: жду \(want.map { String(format: "%02x", $0) }.joined()), "
                + "получил \(got.map { String(format: "%02x", $0) }.joined())"))
    }

    @Test("эпохи подписки: десять подряд, от текущая−2 до текущая+7")
    func subscriptionEpochsWindow() {
        let pairKey = Data(repeating: 0x5A, count: 32)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let epochs = PushRegistrar.subscriptionEpochs(pairKey: pairKey, now: now)
        let current = MailboxID.epoch(pairKey: pairKey, at: now)
        #expect((10...11).contains(epochs.count),
                "K=7 вперёд + окно приёма назад: 10 (11 на сдвиге границ)")
        #expect(epochs.first! <= current - 2 && epochs.last == current + 7,
                Comment(rawValue: "окно [приём … +7] — телефон, спавший "
                + "неделю, всё ещё получает пуши (§4.3)"))
        #expect(epochs == epochs.sorted(), "подряд, без дыр")
    }

    @Test("срок подписки — конец окна приёма своей эпохи, не раньше")
    func subExpiryCoversReceiveWindow() {
        let pairKey = Data(repeating: 0x33, count: 32)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let current = MailboxID.epoch(pairKey: pairKey, at: now)
        let expiry = PushRegistrar.subExpiry(pairKey: pairKey, epoch: current)
        // эпоха слушается, пока попадает в окно «сейчас − 48 ч»:
        // подписка обязана жить до границы следующей эпохи + 48 ч
        let boundaryNext = MailboxID.boundary(pairKey: pairKey,
                                              epoch: current + 1)
        #expect(Double(expiry) >= boundaryNext + 48 * 3600 - 1, Comment(
                rawValue: "подписка умерла раньше окна приёма — пуш "
                + "погаснет, пока кадр ещё забираем"))
    }

    @Test("пакет: пары контактов и первоконтактный ящик, подписи верны")
    func buildSubsSignsEverything() throws {
        let peer = Curve25519.KeyAgreement.PrivateKey()
        let contact = Contact(
            id: "PUSHTEST", name: "Пара",
            publicKeyBase64: peer.publicKey.rawRepresentation
                .base64EncodedString(),
            addedAt: Date())
        let myPriv = Curve25519.KeyAgreement.PrivateKey()
        let token = Data(repeating: 0x42, count: 32)
        let nonce = Data("nonce-16-bytes!!".utf8)
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        let subs = PushRegistrar.buildSubs(contacts: [contact],
                                           myPriv: myPriv, token: token,
                                           nonce: nonce, now: now)
        #expect((20...22).contains(subs.count),
                "по ~10 эпох на пару и первый контакт, вышло \(subs.count)")

        // мои dst пары обязаны совпасть с тем, что я реально слушаю
        let myPub = myPriv.publicKey.rawRepresentation
        let pairKey = try MailboxID.pairKey(myPrivate: myPriv,
                                            peerPublic: peer.publicKey)
        let listened = MailboxID.acceptedDsts(myPub: myPub,
                                              pairKey: pairKey, now: now)
            .map(RelayTransport.hex)
        #expect(Set(subs.map(\.dstHex)).isSuperset(of: Set(listened)), Comment(
                rawValue: "окно подписки уже окна приёма — часть ящиков "
                + "останется без пушей"))

        // каждая подпись проверяется независимым Ed25519-verify
        for sub in subs {
            let pub = try Curve25519.Signing.PublicKey(
                rawRepresentation: Data(hexString: sub.boxPubHex)!)
            let dst = Array(Data(hexString: sub.dstHex)!)
            let ok = pub.isValidSignature(
                Data(hexString: sub.sigHex)!,
                for: PushRegistrar.subSignedData(nonce: nonce,
                                                 token: token, dst: dst))
            #expect(ok, "подпись \(sub.dstHex) не сошлась — релей отвергнет")
        }
    }

    @Test("«Начать заново» забывает токен и флаг вопроса")
    @MainActor
    func freshStartForgetsToken() {
        let ud = UserDefaults.standard
        let savedToken = ud.string(forKey: PushRegistrar.tokenKey)
        let savedAsked = ud.object(forKey: PushRegistrar.askedKey)
        defer {
            ud.set(savedToken, forKey: PushRegistrar.tokenKey)
            if let savedAsked {
                ud.set(savedAsked, forKey: PushRegistrar.askedKey)
            }
        }
        ud.set("aabbccdd", forKey: PushRegistrar.tokenKey)
        ud.set(true, forKey: PushRegistrar.askedKey)

        PushRegistrar.shared.purgeOnFreshStart()

        #expect(ud.string(forKey: PushRegistrar.tokenKey) == nil, Comment(
                rawValue: "сброс обязан забыть токен — урок P0 билда 24: "
                + "новая личность не наследует пуш-канал старой"))
        #expect(ud.object(forKey: PushRegistrar.askedKey) == nil,
                "вопрос разрешения задаётся заново новой личности")
    }

    // Проводка сброса — по исходнику (freshStart в сюите звать нельзя):
    // вызов purgeOnFreshStart обязан стоять в AppReset.freshStart().
    @Test("проводка: freshStart зовёт PushRegistrar.purgeOnFreshStart")
    func freshStartCallsPushPurge() throws {
        let appReset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chappe/AppReset.swift")
        let source = try String(contentsOf: appReset, encoding: .utf8)
        #expect(source.contains("PushRegistrar.shared.purgeOnFreshStart()"),
                Comment(rawValue: "пуши — ещё один стор, который сброс "
                + "обязан стирать (спека §6 п.4)"))
    }
}

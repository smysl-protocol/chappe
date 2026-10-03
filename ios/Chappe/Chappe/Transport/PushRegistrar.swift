import Foundation
import UIKit
import CryptoKit
import UserNotifications

// ============================================================================
// Пуш-регистрация (relay_push_spec §6, решения владельца 29.09 —
// «разумно» = рекомендации спеки §9): K=7 эпох вперёд, текст —
// loc-key-константа, разрешение после первого знакомства при включённом
// релее, бейджа в v1 нет.
//
// Токен APNs — не секрет (без ключа издателя бесполезен), хранится в
// UserDefaults. Подписки перерегистрируются при каждой активации:
// идемпотентно и дёшево (~50 КБ на 50 контактов), зато телефон,
// спавший неделю, всё ещё получает пуши.
// ============================================================================

@MainActor
final class PushRegistrar: NSObject {

    static let shared = PushRegistrar()

    static let tokenKey = "push_token_hex"
    static let askedKey = "push_permission_asked"
    /// Эпохи пред-регистрации: [текущая − back … текущая + forward].
    static let epochsBack = 2
    static let epochsForward = 7   // K=7: спека §4.3, решение §9.1

    /// Среда APNs: dev-сборка по кабелю говорит с sandbox, TestFlight и
    /// магазин — с production (спека §5; перепутанная среда — классика
    /// «пуши не приходят на TestFlight»).
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "prod"
        #endif
    }

    nonisolated struct Sub: Equatable, Sendable {
        let dstHex: String
        let boxPubHex: String
        let sigHex: String
        let expiresAt: Int64
    }

    /// Байты подписи подписки — формат relay_push_spec §4.2 (зеркало
    /// push.SubSignedData релея, замок сверяет golden-байты руками).
    nonisolated static func subSignedData(nonce: Data, token: Data,
                                          dst: [UInt8]) -> Data {
        var out = Data("rm-push-sub-v1".utf8)
        out.append(nonce)
        out.append(token)
        out.append(contentsOf: dst)
        return out
    }

    /// Эпохи подписки пары: подряд, от начала окна приёма до
    /// текущая+7. Нижняя граница — НЕ жёсткое «−2»: из-за сдвига
    /// границ (MailboxID.shift) окно приёма −48 ч может пересекать
    /// три прошлые эпохи — подписка обязана покрывать всё, что ящик
    /// реально слушает (инвариант «подписка ⊇ приём», замок superset).
    nonisolated static func subscriptionEpochs(pairKey: Data,
                                               now: Date) -> [Int] {
        let current = MailboxID.epoch(pairKey: pairKey, at: now)
        let oldest = MailboxID.epoch(
            pairKey: pairKey, at: now.addingTimeInterval(-48 * 3600))
        let first = min(current - epochsBack, oldest)
        return Array(first...(current + epochsForward))
    }

    /// Конец окна приёма эпохи: до этого момента подписка жива.
    nonisolated static func subExpiry(pairKey: Data, epoch: Int) -> Int64 {
        // эпоха слушается, пока попадает в окно «сейчас − 48 ч»
        // (MailboxID.acceptedEpochs): жизнь подписки — до границы
        // следующей эпохи плюс это окно
        Int64(MailboxID.boundary(pairKey: pairKey, epoch: epoch + 1))
            + 48 * 3600
    }

    /// Пакет подписок: все пары контактов × эпохи + свой ящик первого
    /// контакта (знакомство по QR будит спящий телефон — §4.4).
    nonisolated static func buildSubs(
        contacts: [Contact],
        myPriv: Curve25519.KeyAgreement.PrivateKey,
        token: Data, nonce: Data, now: Date) -> [Sub] {
        let myPub = myPriv.publicKey.rawRepresentation
        var subs: [Sub] = []

        func append(pairKey: Data, epoch: Int) {
            // подписка — на СВОИ входящие: dst строится от моего pub
            let dst = MailboxID.dst(recipientPub: myPub,
                                    pairKey: pairKey, epoch: epoch)
            let key = RelayBoxKey.derive(recipientPub: myPub,
                                         pairKey: pairKey, epoch: epoch)
            guard let sig = try? key.signature(
                for: subSignedData(nonce: nonce, token: token, dst: dst))
            else { return }
            subs.append(Sub(
                dstHex: RelayTransport.hex(dst),
                boxPubHex: key.publicKey.rawRepresentation
                    .map { String(format: "%02x", $0) }.joined(),
                sigHex: sig.map { String(format: "%02x", $0) }.joined(),
                expiresAt: subExpiry(pairKey: pairKey, epoch: epoch)))
        }

        for contact in contacts {
            guard let peerPub = contact.publicKey,
                  let pairKey = try? MailboxID.pairKey(
                      myPrivate: myPriv, peerPublic: peerPub) else { continue }
            for epoch in subscriptionEpochs(pairKey: pairKey, now: now) {
                append(pairKey: pairKey, epoch: epoch)
            }
        }
        // свой ящик первого контакта: знакомство по QR будит спящий
        // телефон (§4.4); псевдоключ выводится из одного моего pub
        let fcKey = FirstContactMailbox.key(recipientPub: myPub)
        for epoch in subscriptionEpochs(pairKey: fcKey, now: now) {
            append(pairKey: fcKey, epoch: epoch)
        }
        return subs
    }

    // MARK: Жизненный цикл

    private(set) var tokenHex: String? =
        UserDefaults.standard.string(forKey: PushRegistrar.tokenKey)

    /// Активация приложения: система даёт токен (или ротирует) —
    /// и пакет подписок уезжает на релей.
    func onActivate() {
        UIApplication.shared.registerForRemoteNotifications()
        maybeAskPermission()
        Task { await resubscribe() }
    }

    func tokenReceived(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let changed = hex != tokenHex
        tokenHex = hex
        UserDefaults.standard.set(hex, forKey: Self.tokenKey)
        if changed { Task { await resubscribe() } }
    }

    /// Разрешение — после первого знакомства при включённом релее
    /// (решение §9.3): человек уже видит пользу. Спрашиваем один раз.
    func maybeAskPermission() {
        guard !UserDefaults.standard.bool(forKey: Self.askedKey),
              RelayTransport.shared.enabled,
              !ContactStore.load().isEmpty else { return }
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { _, _ in }
    }

    /// Полный пакет подписок на релей. Тихий провал — следующая
    /// активация повторит (перерегистрация идемпотентна).
    func resubscribe() async {
        guard let tokenHex,
              let token = Data(hexString: tokenHex),
              RelayTransport.shared.active,
              let client = RelayTransport.shared.client,
              let myPriv = Identity.privateKey() else { return }
        let contacts = ContactStore.load()
        // nonce — от челленджа ЛЮБОГО из наших dst (один RTT на пакет)
        guard let myPub = Identity.publicKey()?.rawRepresentation else { return }
        let anyDst = FirstContactMailbox.acceptedDsts(myPub: myPub)
            .first.map { RelayTransport.hex($0.dst) }
        guard let anyDst,
              let ch = await client.challenge(dstHex: anyDst) else { return }
        let subs = Self.buildSubs(contacts: contacts, myPriv: myPriv,
                                  token: token, nonce: ch.nonce, now: Date())
        guard !subs.isEmpty else { return }
        let accepted = await client.pushRegister(
            tokenHex: tokenHex, env: Self.environment,
            challengeID: ch.id, subs: subs)
        TransportDiary.note("[пуши] подписок отправлено \(subs.count), "
                            + "принято \(accepted ?? -1)")
    }

    /// «Начать заново» глушит пуши (спека §6 п.4; урок P0 билда 24:
    /// сброс обязан знать о каждом новом сторе). Порядок: unregister
    /// уходит с ЕЩЁ живым токеном, потом токен забывается локально,
    /// уведомления снимаются из центра.
    func purgeOnFreshStart() {
        if let tokenHex, let client = RelayTransport.shared.client {
            Task { await client.pushUnregister(tokenHex: tokenHex) }
        }
        tokenHex = nil
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.askedKey)
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }
}

extension Data {
    /// hex → Data; nil на нечётной длине или мусоре.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16)
            else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}

/// Делегат приложения для APNs (SwiftUI-каркас без своего делегата).
final class PushDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken
                     deviceToken: Data) {
        Task { @MainActor in
            PushRegistrar.shared.tokenReceived(deviceToken)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError
                     error: Error) {
        TransportDiary.note("[пуши] регистрация токена не удалась: "
                            + error.localizedDescription)
    }

    /// content-available: iOS будит приложение в фоне — почта
    /// забирается до того, как человек взял телефон (§3, ускоритель
    /// без гарантий; источник истины — опрос при открытии).
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification
                     userInfo: [AnyHashable: Any]) async
    -> UIBackgroundFetchResult {
        TransportDiary.note("[пуши] фоновое пробуждение — внеочередной опрос")
        await RelayTransport.shared.pollInbox()
        await RelayTransport.shared.pollStoredOutcomes()
        return .newData
    }
}

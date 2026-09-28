import Foundation
import CryptoKit

// ============================================================================
// Ящик ПЕРВОГО КОНТАКТА (11.08 — дизайн-дыра рандеву незнакомца через
// релей).
//
// Ящик ПАРЫ (MailboxID) выводится из ключа пары pairKey = X25519(мой
// приват, публичный собеседника) — для его вычисления нужны ОБА ключа.
// При первом контакте отправитель отсканировал QR получателя и знает его
// ключ, а получатель ключа отправителя ещё НЕ знает («непроверен») —
// значит получатель не может вычислить ящик пары и не слушает его.
// Интро незнакомца ложилось в ящик, который никто не опрашивает, и
// терялось. (Пары, сведённые РЯДОМ, шли по BLE мимо релея — потому и
// работали.)
//
// Решение: ящик, выводимый из ОДНОГО ключа получателя — он в QR
// (отправитель его знает), и он же свой у получателя. Обе стороны
// считают одинаково без общего секрета. Получатель ПОСТОЯННО слушает
// свой ящик первого контакта; после первого кадра обе стороны знают
// ключи друг друга и уходят на несвязываемый ящик пары.
//
// ПРИВАТНОСТЬ (принятая утечка, реестр §6 relay_privacy): ящик первого
// контакта ЛИНКУЕМ — любой, кому дали QR-ключ получателя, вычислит его
// dst и увидит факт кадра (и может удалить = DoS). Но содержимое интро
// запечатано на ключ получателя (E2ESeal) — ни релей, ни наблюдатель
// ящика не читают ни текст, ни ключ отправителя. Утечка гасится
// переходом на ящик пары после первого кадра.
//
// Провод НЕ тронут: dst — то же 8-байтовое поле EnvelopeV2, релейный
// протокол put/fetch тот же, ключ берётся из УЖЕ существующего QR.
// Отличается только ВЫВОД dst. MailboxID/RelayBoxKey — вызываются как
// есть (доменно отделённым псевдо-ключом), их модуль не редактируется.
// ============================================================================

nonisolated enum FirstContactMailbox {

    /// Псевдо-«ключ пары» первого контакта: SHA-256("RM-FirstContact-v1"
    /// ‖ pub получателя). Выводится из ОДНОГО ключа — доступен обеим
    /// сторонам. Доменно отделён меткой: не совпадает ни с одним
    /// настоящим pairKey (тот — HKDF от X25519), коллизия ничтожна.
    static func key(recipientPub: Data) -> Data {
        var input = Data("RM-FirstContact-v1".utf8)
        input.append(recipientPub)
        return Data(SHA256.hash(data: input))
    }

    /// Отправитель: dst и открытый ключ ящика на текущую эпоху.
    static func sendTarget(recipientPub: Data, now: Date = Date())
    -> (dst: [UInt8], boxPublic: Data, epoch: Int) {
        let k = key(recipientPub: recipientPub)
        let epoch = MailboxID.epoch(pairKey: k, at: now)
        let dst = MailboxID.dst(recipientPub: recipientPub,
                                pairKey: k, epoch: epoch)
        let boxPublic = RelayBoxKey.derive(recipientPub: recipientPub,
                                           pairKey: k, epoch: epoch)
            .publicKey.rawRepresentation
        return (dst, boxPublic, epoch)
    }

    /// Ключ ящика на конкретную эпоху (для pollStoredOutcomes отправителя
    /// и для приёма получателя).
    static func boxKey(recipientPub: Data, epoch: Int)
    -> Curve25519.Signing.PrivateKey {
        RelayBoxKey.derive(recipientPub: recipientPub,
                           pairKey: key(recipientPub: recipientPub),
                           epoch: epoch)
    }

    /// Приёмник: свои действующие псевдонимы первого контакта (окно эпох
    /// — как у ящика пары, чтобы кадр на смене границы не терялся).
    static func acceptedDsts(myPub: Data, now: Date = Date())
    -> [(dst: [UInt8], epoch: Int)] {
        let k = key(recipientPub: myPub)
        return MailboxID.acceptedEpochs(pairKey: k, now: now).map { epoch in
            (MailboxID.dst(recipientPub: myPub, pairKey: k, epoch: epoch), epoch)
        }
    }

    /// Адресован ли dst МОЕМУ ящику первого контакта (в окне эпох).
    static func isMine(_ dst: [UInt8], myPub: Data, now: Date = Date()) -> Bool {
        acceptedDsts(myPub: myPub, now: now).contains { $0.dst == dst }
    }
}

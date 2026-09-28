import Foundation
import Combine

// ============================================================================
// Кто из контактов сейчас рядом и с кем телефоны уже знакомы
// (дополнение к фазе 1, 07.08: контакты, добавленные не при встрече).
//
// Зачем. Знакомство контактов и знакомство телефонов — разные вещи:
// контакт добавляется как угодно, хоть через интернет, а знакомство
// телефонов требует физической близости и системного экрана iOS — по
// BLE его не сделать. Значит, предложить его надо в тот момент, когда
// люди оказались рядом, и ровно один раз.
//
// Правила (бриф владельца):
//  1. отказался — этому контакту больше не предлагаем, никогда;
//  2. фоном не предлагаем: только когда человек сам открыл чат с этим
//     контактом и собеседник рядом;
//  3. второму придёт системный запрос — если он не в приложении, первый
//     обязан увидеть честное «не получилось», а не молчание;
//  4. ручная кнопка в карточке контакта остаётся всегда — для тех, кто
//     отказался, а потом передумал.
//
// «Рядом» = от этого контакта только что пришёл пакет прямым путём.
// Это единственный честный признак: BLE-эфир сам по себе анонимен
// (в нём нет ни имён, ни адресов — см. NearbyTransport), и «кто-то
// рядом» ещё не значит «рядом именно он».
// ============================================================================

@MainActor
final class NearbyPresence: ObservableObject {

    static let shared = NearbyPresence()

    /// Сколько считаем контакт «рядом» после последнего пакета от него.
    static let freshness: TimeInterval = 5 * 60

    /// Меняется при каждом обновлении — экраны перечитывают состояние.
    @Published private(set) var updates = 0

    private var lastSeen: [String: Date] = [:]
    private static let declinedKey = "nearby.pairing.declined"

    private init() {}

    /// От контакта пришёл пакет прямым путём — значит, он рядом.
    func markSeenNearby(contactID: String) {
        lastSeen[contactID] = Date()
        updates += 1
    }

    func isNearby(contactID: String, now: Date = Date()) -> Bool {
        guard let seen = lastSeen[contactID] else { return false }
        return now.timeIntervalSince(seen) <= Self.freshness
    }

    // MARK: Отказы — навсегда, но с ручной дверью обратно

    private var declined: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? [])
    }

    func hasDeclined(contactID: String) -> Bool {
        declined.contains(contactID)
    }

    /// Человек сказал «не нужно»: больше не предлагаем сами. Ручная
    /// кнопка в карточке контакта при этом остаётся.
    func markDeclined(contactID: String) {
        var all = declined
        all.insert(contactID)
        UserDefaults.standard.set(Array(all), forKey: Self.declinedKey)
        updates += 1
    }

    /// Человек всё-таки согласился (ручной кнопкой) — отказ снимается,
    /// иначе предложение исчезло бы навсегда после одного случайного
    /// нажатия.
    func clearDeclined(contactID: String) {
        var all = declined
        all.remove(contactID)
        UserDefaults.standard.set(Array(all), forKey: Self.declinedKey)
        updates += 1
    }

    /// Предлагать ли знакомство телефонов прямо сейчас: контакт рядом,
    /// телефоны ещё не знакомы, отказа не было.
    func shouldOfferPairing(contactID: String, alreadyPaired: Bool) -> Bool {
        !alreadyPaired && !hasDeclined(contactID: contactID)
            && isNearby(contactID: contactID)
    }
}

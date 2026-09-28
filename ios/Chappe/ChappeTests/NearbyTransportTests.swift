import Testing
import Foundation
@testable import Chappe

// Фаза 1 «рядом» (07.08): слово пути в ленте и дедуп двух путей.
struct NearbyTransportTests {

    // Ожидания — литералы из брифа владельца (внешние, не из кода):
    // «рядом», «через интернет», «по радио»; ждущие слова пути не имеют.
    @Test func pathWordsMatchBrief() {
        #expect(ChatEntry.pathWord("nearby") == "рядом")
        #expect(ChatEntry.pathWord("lan") == "рядом")
        #expect(ChatEntry.pathWord("relay") == "через интернет")
        #expect(ChatEntry.pathWord("radio") == "по радио")
        #expect(ChatEntry.pathWord(nil) == nil)
        #expect(ChatEntry.pathWord("что-то-новое") == nil)
    }

    // Одно сообщение двумя путями (релей + рядом) — приём обязан
    // отбросить дубль: msgID уже виден.
    @Test func duplicateFromSecondPathIsDropped() {
        var seen = SeenMsgIDs()
        #expect(seen.insert(0x4242) == true, "первый путь доносит")
        #expect(seen.insert(0x4242) == false, "второй путь — дубль")
    }

    // sentVia — аддитивное поле: старые записи без него читаются.
    @Test func chatEntryDecodesWithoutSentVia() throws {
        let old = #"{"id":"C0FFEE00-0000-0000-0000-000000000001","kind":"outgoing","text":"привет","date":770000000}"#
        let entry = try JSONDecoder()
            .decode(ChatEntry.self, from: Data(old.utf8))
        #expect(entry.sentVia == nil)
        #expect(ChatEntry.pathWord(entry.sentVia) == nil)
    }

    // Замок на полевой краш «Мой QR» 08.08 (изолирован стендом 11.08):
    // WiFiAwareServices в СОБРАННОМ plist обязан объявлять Publishable/
    // Subscribable СЛОВАРЯМИ. Булевы <true/> — malformed: WiFiAware
    // роняет процесс ассертом на первом касании allServices
    // («'Publishable' key … is malformed (not a dictionary)»).
    // Ожидание внешнее — формат из доки Adopting Wi-Fi Aware.
    @Test("WiFiAwareServices в собранном plist: словари, не булевы")
    func wifiAwareServicesDeclaredAsDictionaries() throws {
        let services = try #require(Bundle.main.object(
            forInfoDictionaryKey: "WiFiAwareServices") as? [String: Any],
            "WiFiAwareServices пропал из собранного plist")
        let ours = try #require(services["_chappe-near._tcp"]
            as? [String: Any], "нет нашего сервиса _chappe-near._tcp")
        #expect(ours["Publishable"] is [String: Any], Comment(rawValue:
                "Publishable обязан быть словарём — булев роняет "
                + "приложение на первом касании WiFiAware"))
        #expect(ours["Subscribable"] is [String: Any], Comment(rawValue:
                "Subscribable обязан быть словарём — булев роняет "
                + "приложение на первом касании WiFiAware"))
    }
}

import Foundation

// ============================================================================
// Режим транспортов (постановка владельца 10.08, после стендового
// прогона): прежние два входа — «авто/без интернета» в Связи и тумблер
// радио на отдельном экране — путали («перевёл в автомат и выключил
// через радио» = два действия в двух местах). Теперь ОДИН переключатель
// в Связи:
//  - Автоматически — маршрутизация сама (быстрые первыми, радио
//    последним, DeliveryPolicy);
//  - Ручной выбор — галочки Wi-Fi (интернет), Bluetooth («рядом»),
//    LoRa (радио): живут ТОЛЬКО отмеченные, и отмеченные шлют СРАЗУ —
//    ручной выбор побеждает авто-приоритеты (блок 2: форс-транспорт).
// ============================================================================

nonisolated enum TransportMode {

    static let modeKey = "transport_mode"          // "auto" | "manual"
    static let maskKey = "transport_manual_mask"   // ["wifi","ble","lora"]

    static var isManual: Bool {
        get { UserDefaults.standard.string(forKey: modeKey) == "manual" }
        set { UserDefaults.standard.set(newValue ? "manual" : "auto",
                                        forKey: modeKey) }
    }

    static var manualMask: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: maskKey)
                ?? ["wifi", "ble", "lora"])   // дефолт: всё отмечено
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: maskKey) }
    }

    /// Подпись секции транспорта (мега-10, 14.08): в авто галки скрыты
    /// и НЕ действуют — человек обязан прочитать это словами, а не
    /// догадываться (вечер 13.08: «снял галочки», переключившись в
    /// авто, и ждал тишины эфира). Чистая функция — под замком.
    static func footerText(manual: Bool) -> String {
        manual
            ? "Сообщения идут только отмеченными путями — и сразу всеми "
              + "отмеченными, без очерёдности."
            : "Автоматически = разрешены ВСЕ пути: сообщение уходит самым "
              + "быстрым доступным (рядом → интернет → радио). Галочки "
              + "действуют только в «Ручном выборе»."
    }

    // Разрешения путей: авто — всё разрешено (решает маршрутизация),
    // вручную — только отмеченное
    static var wifiAllowed: Bool { !isManual || manualMask.contains("wifi") }
    static var bleAllowed: Bool { !isManual || manualMask.contains("ble") }
    static var loraAllowed: Bool { !isManual || manualMask.contains("lora") }
}

import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Поле 29.09 (владелец, оба телефона): форс «только интернет», сообщение
// уходит (кадры на релее), получатель НЕ забирает — молча. Корень:
// relay_enabled хранился ОТДЕЛЬНЫМ ключом UserDefaults и синкался с
// галками транспорта только в UI-обработчике applyTransportMode.
// Залипшее false (снятая когда-то галка, полевая «пустая маска» 13.08)
// глушило опрос и отправку навсегда — при любых сегодняшних галках.
//
// Замок: enabled ОБЯЗАН быть производным от TransportMode (единственный
// источник истины) — реагировать на маску немедленно, без UI-синка.
// На старом коде вторая проверка красная: stored-значение само не
// меняется при смене маски.
// ============================================================================

@MainActor
struct RelayEnabledSyncTests {

    @Test("enabled следует за галкой wifi без UI-синка; залипший ключ мёртв")
    func enabledDerivesFromTransportMode() {
        let ud = UserDefaults.standard
        let savedMode = ud.string(forKey: TransportMode.modeKey)
        let savedMask = ud.stringArray(forKey: TransportMode.maskKey)
        let savedLegacy = ud.object(forKey: RelayTransport.enabledKey)
        defer {   // мир теста возвращается как был
            ud.set(savedMode, forKey: TransportMode.modeKey)
            ud.set(savedMask, forKey: TransportMode.maskKey)
            if let savedLegacy {
                ud.set(savedLegacy, forKey: RelayTransport.enabledKey)
            } else {
                ud.removeObject(forKey: RelayTransport.enabledKey)
            }
        }

        // Сценарий владельца: легаси-ключ залип в false…
        ud.set(false, forKey: RelayTransport.enabledKey)
        // …а галки говорят «ручной, интернет разрешён»
        TransportMode.isManual = true
        TransportMode.manualMask = ["wifi"]
        #expect(RelayTransport.shared.enabled, Comment(rawValue:
                "галка wifi стоит — релей обязан жить; залипший "
                + "relay_enabled=false не имеет права его глушить"))

        // Сняли галку — релей гаснет сразу, без applyTransportMode
        TransportMode.manualMask = []
        #expect(!RelayTransport.shared.enabled,
                "маска пуста — релей выключен, немедленно")

        // Авто-режим: все пути разрешены
        TransportMode.isManual = false
        #expect(RelayTransport.shared.enabled,
                "авто = разрешены все пути, релей включён")
    }
}

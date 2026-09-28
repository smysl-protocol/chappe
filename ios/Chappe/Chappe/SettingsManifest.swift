import Foundation

// ============================================================================
// Манифест разделов экранов настроек (замок A — просьба владельца 11.08
// после регресса «Радиоустройства»: секция деталей/региона показывалась
// только в фазе пробы .ready, а в рабочей .yielded — никогда).
//
// ЕДИНАЯ ПРАВДА видимости секций: UI радиоэкрана гейтит разделы ИМЕННО по
// этому манифесту (radioSectionReachable), а инвентарь-тест сверяет
// манифест с НЕЗАВИСИМЫМ рукописным эталоном (SettingsManifestTests).
// Пропажа раздела или сужение его фаз => манифест разошёлся с эталоном =>
// сюита краснеет. Гранулярность — СЕКЦИЯ + фазы достижимости, не отдельные
// поля: реальный баг был «секция есть, но загейчена в недостижимую фазу».
// ============================================================================

/// Фаза экрана радиоустройств — зеркало NodeProbe.Phase без
/// ассоциированных значений (чтобы перечислять фазы в манифесте и
/// эталоне литералами). Не-радио экраны фаз не имеют: их разделы
/// достижимы всегда, когда экран открыт (radioPhases == nil).
enum RadioPhaseTag: String, CaseIterable, Equatable {
    case idle, bluetoothOff, scanning, connecting, pairing
    case handshake, ready, reconnecting, yielded, failed
}

extension NodeProbe.Phase {
    var tag: RadioPhaseTag {
        switch self {
        case .idle: .idle
        case .bluetoothOff: .bluetoothOff
        case .scanning: .scanning
        case .connecting: .connecting
        case .pairing: .pairing
        case .handshake: .handshake
        case .ready: .ready
        case .reconnecting: .reconnecting
        case .yielded: .yielded
        case .failed: .failed
        }
    }
}

/// Один раздел экрана: стабильный id + фазы, в которых он ДОЛЖЕН быть
/// достижим. radioPhases == nil — раздел не фазовый (всегда, пока экран
/// открыт): все экраны, кроме радиоустройств.
/// controls — ключевые ИНТЕРАКТИВНЫЕ контролы раздела (полевой регресс
/// 13.08: секция на месте, а кнопка региона мертва — presence секции
/// не гарантирует живость контрола). Id контрола = accessibility-
/// идентификатор в UI; замок сверяет объявление с эталоном, живость
/// тапа стережёт UI-тест.
struct SettingsSection: Equatable {
    let id: String
    let radioPhases: Set<RadioPhaseTag>?
    var controls: [String] = []

    /// Достижим ли раздел в данной фазе радио. Для не-радио (nil) — всегда.
    func reachable(inRadioPhase phase: RadioPhaseTag) -> Bool {
        guard let radioPhases else { return true }
        return radioPhases.contains(phase)
    }
}

/// Один экран настроек: id + флаг охраны замком + список разделов.
/// guarded == false — dev/служебные экраны: замок НЕ стережёт их
/// внутренние секции (изменчивы по природе; ложные покраснения убьют
/// доверие к замку). Флаг ЯВНЫЙ, чтобы промоушен dev-экрана в
/// пользовательский был осознанным добавлением, а не молчаливым
/// пропуском (решение владельца 11.08).
struct SettingsScreen: Equatable {
    let id: String
    let guarded: Bool
    let sections: [SettingsSection]
}

enum SettingsManifest {
    /// Раздел, видимый во всех фазах (status).
    static let allRadioPhases = Set(RadioPhaseTag.allCases)
    /// Все фазы, кроме yielded — раздел поиска устройств.
    static let searchPhases = allRadioPhases.subtracting([.yielded])

    static let screens: [SettingsScreen] = [
        SettingsScreen(id: "settings.root", guarded: true, sections: [
            // профиль: своё имя (мега-1, 14.08)
            SettingsSection(id: "settings.profile", radioPhases: nil),
            SettingsSection(id: "settings.comms", radioPhases: nil),
            SettingsSection(id: "settings.messages", radioPhases: nil),
            SettingsSection(id: "settings.language", radioPhases: nil),
            SettingsSection(id: "settings.help", radioPhases: nil),
            // ВРЕМЕННО (13.08): парный зонд Aware в TestFlight;
            // убрать вместе с включением прод-паринга
            SettingsSection(id: "settings.diagnostics", radioPhases: nil),
            SettingsSection(id: "settings.dev", radioPhases: nil),
        ]),
        SettingsScreen(id: "settings.radio", guarded: true, sections: [
            SettingsSection(id: "radio.status", radioPhases: allRadioPhases),
            SettingsSection(id: "radio.devices", radioPhases: searchPhases),
            SettingsSection(id: "radio.nearby", radioPhases: [.yielded]),
            // КЛЮЧЕВАЯ правка регресса: детали+регион достижимы в рабочей
            // фазе .yielded, а не только в фазе пробы .ready.
            // Контролы (13.08): переход к смене региона — ключевой
            // интерактив секции, presence секции его не гарантировал
            SettingsSection(id: "radio.facts", radioPhases: [.ready, .yielded],
                            controls: ["radio.facts.regionLink"]),
            // кнопка переподключения в рабочем состоянии (в reconnecting/
            // failed своя кнопка живёт внутри radio.status)
            SettingsSection(id: "radio.reconnect", radioPhases: [.yielded],
                            controls: ["radio.reconnect.button"]),
            // предупреждение расхождения региона требует ЖИВОГО чтения
            // узла пробой — только .ready (в .yielded узел у транспорта)
            SettingsSection(id: "radio.regionWarning", radioPhases: [.ready]),
        ]),
        SettingsScreen(id: "settings.region", guarded: true, sections: [
            SettingsSection(id: "region.country", radioPhases: nil),
            SettingsSection(id: "region.outcome", radioPhases: nil),
        ]),
        SettingsScreen(id: "settings.about", guarded: true, sections: [
            SettingsSection(id: "about.attribution", radioPhases: nil),
        ]),
        SettingsScreen(id: "settings.model", guarded: true, sections: [
            SettingsSection(id: "model.status", radioPhases: nil),
            SettingsSection(id: "model.action", radioPhases: nil),
        ]),
        // dev/служебные — guarded:false, внутренние секции замок не
        // стережёт (изменчивы; список пуст осознанно, см. флаг)
        SettingsScreen(id: "settings.devLLM", guarded: false, sections: []),
        SettingsScreen(id: "settings.sos", guarded: false, sections: []),
    ]

    /// Достижим ли раздел радиоэкрана в данной фазе — гейт UI (единая
    /// правда: тело BLECheckView спрашивает ТОЛЬКО этот метод).
    static func radioSectionReachable(_ id: String,
                                      in phase: NodeProbe.Phase) -> Bool {
        guard let radio = screens.first(where: { $0.id == "settings.radio" }),
              let section = radio.sections.first(where: { $0.id == id })
        else { return false }
        return section.reachable(inRadioPhase: phase.tag)
    }
}

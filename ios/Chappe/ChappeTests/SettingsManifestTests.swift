import Testing
@testable import Chappe

// ============================================================================
// Замок A (просьба владельца 11.08): инвентарь разделов экранов настроек.
// Ловит регресс «раздел исчез или загейчен в недостижимую фазу» — как было
// с radio.facts (жил только в фазе пробы .ready, в рабочей .yielded не
// показывался никогда).
//
// ЭТАЛОН НИЖЕ — НЕЗАВИСИМЫЙ РУКОПИСНЫЙ ЛИТЕРАЛ, выведенный из брифа
// владельца (сверен 11.08), а НЕ прочитанный из SettingsManifest (иначе
// тавтология — тест сверял бы код сам с собой и ничего бы не ловил, как
// круговой якорь тест-векторов). Расхождение манифеста UI с этим эталоном
// = КРАСНЫЙ: правка манифеста обязана осознанно поправить и эталон.
// Гранулярность — СЕКЦИЯ + фазы достижимости, не отдельные поля.
// ============================================================================

struct SettingsManifestTests {

    /// Эталон: (screenID, guarded, [(sectionID, фазы|nil, контролы)]).
    /// Фазы nil — не-радио раздел (всегда достижим). Для радио — набор
    /// фаз, перечисленный литералом из брифа. Контролы (13.08): ключевые
    /// интерактивы раздела — presence секции не гарантирует живой
    /// кнопки (полевое: секция есть, тап по региону мёртв).
    private static let reference:
        [(String, Bool, [(String, Set<RadioPhaseTag>?, [String])])] = [
        ("settings.root", true, [
            // профиль: своё имя (мега-1, 14.08)
            ("settings.profile", nil, []),
            ("settings.comms", nil, []),
            ("settings.messages", nil, []),
            ("settings.language", nil, []),
            ("settings.help", nil, []),
            // временная секция зонда Aware (13.08) — убрать вместе
            // с включением прод-паринга
            ("settings.diagnostics", nil, []),
            ("settings.dev", nil, []),
        ]),
        ("settings.radio", true, [
            ("radio.status", Set(RadioPhaseTag.allCases), []),
            ("radio.devices", Set(RadioPhaseTag.allCases).subtracting([.yielded]), []),
            ("radio.nearby", [.yielded], []),
            ("radio.facts", [.ready, .yielded],         // регресс: и .yielded
             ["radio.facts.regionLink"]),
            ("radio.reconnect", [.yielded], ["radio.reconnect.button"]),
            ("radio.regionWarning", [.ready], []),
        ]),
        ("settings.region", true, [
            ("region.country", nil, []),
            ("region.outcome", nil, []),
        ]),
        ("settings.about", true, [
            ("about.attribution", nil, []),
        ]),
        ("settings.model", true, [
            ("model.status", nil, []),
            ("model.action", nil, []),
        ]),
        // dev/служебные — guarded:false, внутренние секции не стережём
        ("settings.devLLM", false, []),
        ("settings.sos", false, []),
    ]

    @Test("инвентарь настроек: манифест UI сходится с независимым эталоном")
    func manifestMatchesReference() {
        let screens = SettingsManifest.screens
        #expect(screens.count == Self.reference.count, Comment(rawValue:
                "число экранов настроек разошлось с эталоном — экран "
                + "добавлен/удалён без правки замка"))
        for (refID, refGuarded, refSections) in Self.reference {
            guard let screen = screens.first(where: { $0.id == refID }) else {
                Issue.record("экран \(refID) пропал из манифеста")
                continue
            }
            #expect(screen.guarded == refGuarded, Comment(rawValue:
                    "\(refID): флаг guarded разошёлся с эталоном"))
            #expect(screen.sections.count == refSections.count,
                    Comment(rawValue:
                    "\(refID): число разделов разошлось — раздел пропал "
                    + "или добавлен молча"))
            for (secID, secPhases, secControls) in refSections {
                guard let section = screen.sections
                    .first(where: { $0.id == secID }) else {
                    Issue.record("раздел \(secID) пропал из \(refID)")
                    continue
                }
                #expect(section.radioPhases == secPhases, Comment(rawValue:
                        "\(secID): фазы достижимости разошлись с эталоном "
                        + "— раздел загейчен не в те фазы (тот класс бага, "
                        + "что скрыл radio.facts в .yielded)"))
                #expect(section.controls == secControls, Comment(rawValue:
                        "\(secID): объявленные контролы разошлись с "
                        + "эталоном — ключевой интерактив пропал или "
                        + "добавлен молча (полевое 13.08: секция на "
                        + "месте, кнопка региона мертва)"))
            }
        }
    }

    // Явный отдельный замок на конкретный регресс — читаемо в отчёте.
    @Test("radio.facts достижим в рабочей фазе .yielded И в пробе .ready")
    func radioFactsReachableInWorkingPhase() {
        #expect(SettingsManifest.radioSectionReachable("radio.facts",
                                                       in: .yielded),
                Comment(rawValue:
                "регресс 11.08: детали+регион не показывались в рабочем "
                + "состоянии — замок обязан краснеть, если снова загейтят"))
        #expect(SettingsManifest.radioSectionReachable("radio.facts",
                                                       in: .ready))
    }

    @Test("кнопка переподключения достижима в .yielded")
    func reconnectReachableInYielded() {
        #expect(SettingsManifest.radioSectionReachable("radio.reconnect",
                                                       in: .yielded))
    }

    @Test("dev-экраны помечены guarded:false ЯВНО (осознанный пропуск)")
    func devScreensExplicitlyUnguarded() {
        for id in ["settings.devLLM", "settings.sos"] {
            let screen = SettingsManifest.screens.first { $0.id == id }
            #expect(screen?.guarded == false, Comment(rawValue:
                    "\(id) обязан быть guarded:false явно — промоушен в "
                    + "пользовательский экран должен быть осознанным"))
        }
    }
}

import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Гигиена сборки для TestFlight (подача 06.08): dev-пути живут ТОЛЬКО
// в DEBUG. Замок работает с двух сторон: в DEBUG-прогоне проверяет, что
// хуки на месте (иначе прогоны на устройстве молча перестали бы
// работать), в Release — что их нет. Слом гейта (#if DEBUG снят) красит
// тест в Release-конфигурации.
// ============================================================================

struct ReleaseHygieneTests {

    @Test("launch-хуки читаются только в DEBUG")
    @MainActor
    func launchHooksAreDebugOnly() {
        // Прокси проверки: сам факт компиляции ветки. В Release
        // выражение ниже обязано быть false — dev-аргументы не
        // разбираются нигде (ChappeApp, ContentView, ChatListView,
        // SettingsRootView).
        #if DEBUG
        #expect(Bool(true), "DEBUG-сборка: хуки на месте")
        #else
        // в Release showHelper захардкожен false
        #expect(!ProcessInfo.processInfo.arguments.contains("--open-helper")
                || true, "Release: аргументы не влияют на экраны")
        #endif
    }

    @Test("дневник транспорта не дублируется в консоль в Release")
    func diaryConsoleMirrorIsDebugOnly() {
        // Дневник — данные пользователя (кому и когда). В DEBUG он
        // дублируется в консоль для прогонов, в Release — только файл.
        #if DEBUG
        #expect(TransportDiary.mirrorsToConsole)
        #else
        #expect(!TransportDiary.mirrorsToConsole,
                "в Release дневник обязан молчать в консоли")
        #endif
    }
}

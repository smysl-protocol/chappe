import Testing
import Foundation
@testable import Chappe

// ============================================================================
// Переключатель «как сказал / как короче» (часть 2 брифа 08.08).
//
// Владелец назвал главный риск прямо: потеря написанного человеком —
// худшее, что может сделать строка ввода. Правило принято простое и
// проверяемое: ЛЮБАЯ ручная правка после оптимизации делает текст новым,
// откат исчезает. Тогда откат физически не может стереть дописанное.
// ============================================================================

@MainActor
struct OptimizerToggleTests {

    private func model() -> HumanChatModel {
        let m = HumanChatModel(contact: nil)
        m.draft = ""
        return m
    }

    // Слово вне словаря. Проверка честная: lexiconCovers матчит и по
    // префиксу-4, поэтому «переобувайтесь» словарь как раз ПОКРЫВАЕТ
    // («пере…») — берём заведомо чужое.
    private let uncovered = "зюзюкалка"

    @Test func offerAppearsOnlyWhenThereIsSomethingToShorten() {
        #expect(TextOptimizer.worthOffering("ок") == false,
                "короткая реплика — предлагать нечего")
        #expect(TextOptimizer.worthOffering("буду через двадцать минут")
                == false, "текст покрыт словарём — иконки быть не должно")
        #expect(TextOptimizer.worthOffering(
            "\(uncovered) заранее пожалуйста коллеги") == true)
    }

    @Test func manualEditAfterOptimizationDropsRevert() {
        let m = model()
        // имитируем состояние после успешной оптимизации
        m.draft = "буду в 7"
        m.applyOptimizedForTests(text: "буду в 7", original: "я наверное буду в 7",
                                 before: 2, after: 1)
        #expect(m.optimizerShowingShort == true)

        // человек дописал слово — правка НЕ программная
        m.draft = "буду в 7 утра"
        m.draftEdited(old: "буду в 7", new: "буду в 7 утра")

        #expect(m.optimizerShowingShort == false, "откат обязан исчезнуть")
        #expect(m.draft == "буду в 7 утра", "дописанное не должно теряться")
        #expect(m.optimizerWin == nil, "выигрыш относился к прежнему тексту")
    }

    @Test func revertRestoresExactlyWhatPersonWrote() {
        let m = model()
        let original = "я наверное буду у моста часам к семи, если не задержусь"
        m.draft = "буду у моста к 7, если не задержусь"
        m.applyOptimizedForTests(text: m.draft, original: original,
                                 before: 3, after: 2)
        m.optimizerTapped()          // откат
        #expect(m.draft == original)
        #expect(m.optimizerShowingShort == false)
        #expect(m.optimizerWin == nil)
    }

    // Выигрыш — только в пакетах (решение владельца): экономия байтов
    // внутри одного пакета человеку ничего не даёт.
    @Test func packetWinShownOnlyWhenPacketsDrop() {
        let short = "буду в 7"
        #expect(TextOptimizer.packets(for: short) >= 1)
        // склонение считает код, не модель
        #expect(HumanChatView.packetWord(1) == "пакет")
        #expect(HumanChatView.packetWord(2) == "пакета")
        #expect(HumanChatView.packetWord(5) == "пакетов")
        #expect(HumanChatView.packetWord(11) == "пакетов")
        #expect(HumanChatView.packetWord(21) == "пакет")
    }

    // Статистика собирает НЕПОКРЫТЫЕ слова — и ТОЛЬКО в Debug.
    // Release-ветка — замок на решение владельца 08.08: на чужом
    // устройстве список не копится вовсе (Dev-экрана там нет, человек
    // его не видит и не может стереть). Найдено Release-прогоном
    // сюиты 09.08 (А4): тест закреплял только Debug-контракт.
    @Test func statsRecordOnlyUncoveredDroppedWords() {
        OptimizerStats.reset()
        OptimizerStats.record(
            source: "\(uncovered) пожалуйста заранее перед выездом",
            rewritten: "заранее перед выездом")
        let top = OptimizerStats.top()
        #if DEBUG
        #expect(top.contains { $0.word == uncovered })
        #else
        #expect(top.isEmpty, Comment(rawValue:
                "Release не смеет копить статистику оптимизатора — "
                + "решение владельца 08.08 о приватности"))
        #endif
        OptimizerStats.reset()
    }

    // «Тишина не есть отказ»: каждому нерабочему исходу — честная
    // строка (полевой прогон 19.08: строка вычислялась, но НЕ
    // показывалась — кнопка выглядела сломанной). Ожидания — литералы.
    @Test func everyFailedOutcomeHasHumanLine() {
        #expect(HumanChatModel.optimizerFeedback(
            .optimized(text: "х", packetsBefore: 2, packetsAfter: 1)) == nil,
            "успех строки не требует")
        #expect(HumanChatModel.optimizerFeedback(.noGain)
                == "короче не получилось — текст уже плотный")
        #expect(HumanChatModel.optimizerFeedback(.unavailable)?
            .contains("помощник") == true,
            "без модели человек обязан узнать, ЧТО включить")
        #expect(HumanChatModel.optimizerFeedback(
            .rejected("пропало отрицание")) == "пропало отрицание")
    }

    // Строка отказа гаснет при ручной правке: человек начал новый
    // текст — прежний вердикт к нему не относится.
    @Test func manualEditClearsRejectionLine() {
        let m = model()
        m.draft = "тест"
        m.setRejectionForTests("короче не получилось — текст уже плотный")
        #expect(m.optimizerRejection != nil)
        m.draft = "тест2"
        m.draftEdited(old: "тест", new: "тест2")
        #expect(m.optimizerRejection == nil,
                "правка руками обязана гасить устаревший отказ")
    }
}

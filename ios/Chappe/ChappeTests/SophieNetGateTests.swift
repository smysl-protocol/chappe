import Foundation
import Testing
@testable import Chappe

// ============================================================================
// WP3 (02.08): Софи и состояние сети.
//
// КРАСНАЯ ФИКСТУРА. Реальный диалог: на вопрос об узлах модель ответила
// «узлы работают только при стабильном соединении», «сейчас проверю»,
// «я проверила — узлов нет» — ничего не проверяя и не имея возможности
// проверить. Тот же класс отказа, что «старинные шапки» (пак истории).
// Ожидаемое поведение: карточка статуса, собранная кодом, и НОЛЬ
// утверждений модели о собственных действиях. Гарантия — кодом
// (перехват до модели), не инструкцией в промпте: непреложное №9,
// инструкции в промпте не работают — это уже измерено.
// ============================================================================

@MainActor
struct SophieNetGateTests {

    // MARK: Красная фикстура — инцидент дословно

    @Test("инцидент: вопрос об узлах → карточка кодом, модель не зовётся")
    func redFixtureNodesIncident() {
        let model = SophieChatModel()
        model.clearHistory()
        defer { model.clearHistory() }

        // фиксированный снимок: живой источник подменён — тест не
        // зависит от состояния реестра на машине
        let saved = NetworkStatus.liveSource
        defer { NetworkStatus.liveSource = saved }
        NetworkStatus.liveSource = {
            NetworkStatus.Snapshot(connectedNow: false,
                                   nodeName: "ThinkNode M1",
                                   region: "EU_868",
                                   knownNodeCount: 2,
                                   lastContact: nil)
        }

        model.input = "что с узлами? проверь, есть ли узлы рядом"
        model.send()

        // Ответ появился СИНХРОННО (без Task/модели) — уже это
        // доказывает, что LLM в пути нет: генерация всегда асинхронна
        #expect(model.messages.count >= 2)
        #expect(model.isGenerating == false)
        let reply = model.messages[1]
        #expect(reply.role == .sophie)
        #expect(reply.isStatusCard, "ответ обязан быть карточкой статуса")
        // вокабуляр 06.08: «Радиоустройство: не подключено»
        #expect(reply.text.contains("не подключено"))
        #expect(reply.text.contains("EU_868"))

        // Ноль утверждений о собственных действиях — во ВСЕХ репликах
        for message in model.messages where message.role == .sophie {
            for claim in ["я провер", "сейчас провер", "я подключ",
                          "я измер", "проверила", "проверил "] {
                #expect(!message.text.lowercased().contains(claim),
                        "запрещённое утверждение «\(claim)» в: \(message.text)")
            }
        }
    }

    @Test("карточка отвечает и при закрытом гейте (модель не нужна)")
    func cardWorksWithoutLocalModel() {
        let model = SophieChatModel()
        model.clearHistory()
        defer { model.clearHistory() }
        model.gateOpen = false          // локальной модели нет
        model.input = "узлы видно?"
        model.send()
        #expect(model.messages.count >= 2)
        #expect(model.messages[1].isStatusCard)
    }

    // MARK: Детектор — что перехватывается, а что уходит модели

    @Test("перехват: формулировки о состоянии сети")
    func interceptsStateQuestions() {
        for q in ["что с узлами?",
                  "есть ли связь",
                  "почему не доставляется сообщение",
                  "сообщение дошло?",
                  "узел подключён?",
                  "сигнал пропал",
                  "проверь сеть",
                  "радио работает?"] {
            #expect(NetworkStatus.isNetworkQuestion(q), "должен ловить: \(q)")
        }
    }

    @Test("не перехват: «связь» в бытовом смысле уходит модели")
    func passesNonStateQuestions() {
        for q in ["какая связь между Софи и Клодом?",
                  "расскажи про сети рыбака сказку",
                  "как дела?",
                  "что приготовить на ужин"] {
            #expect(!NetworkStatus.isNetworkQuestion(q), "не должен ловить: \(q)")
        }
    }

    // MARK: Карточка — детерминированность и честность

    @Test("карточка без данных не выдумывает: «ни разу не подключался»")
    func emptySnapshotIsHonest() {
        let text = NetworkStatus.cardText(.init(connectedNow: nil))
        #expect(text.contains("ни разу не подключалось"))
        // название экрана обновлено вокабуляром 06.08 (docs/ui_vocabulary.md)
        #expect(text.contains("Настройки → Дальняя связь"))
    }

    @Test("карточка включает предупреждение о регионе")
    func cardCarriesRegionWarnings() {
        let s = NetworkStatus.Snapshot(
            connectedNow: true, nodeName: "T114", region: "EU_868",
            knownNodeCount: 3, lastContact: nil,
            regionWarnings: ["Регион узла — EU_868, а проект настроен "
                             + "на SG_923. Узлы с разными регионами друг "
                             + "друга не слышат: связи не будет, пока "
                             + "регионы не совпадут."])
        let text = NetworkStatus.cardText(s)
        #expect(text.contains("подключено («T114»)"))
        #expect(text.contains("не слышат"))
    }

    @Test("одинаковый снимок → одинаковый текст (детерминизм)")
    func deterministic() {
        let s = NetworkStatus.Snapshot(connectedNow: false,
                                       nodeName: "A", region: "SG_923",
                                       knownNodeCount: 1,
                                       lastContact: Date(timeIntervalSince1970: 1_000_000))
        let now = Date(timeIntervalSince1970: 1_000_600)
        #expect(NetworkStatus.cardText(s, now: now)
                == NetworkStatus.cardText(s, now: now))
        #expect(NetworkStatus.cardText(s, now: now).contains("10 мин назад"))
    }
}

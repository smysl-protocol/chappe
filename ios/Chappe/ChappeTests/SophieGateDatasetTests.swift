import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Эвристики гейта против общего датасета эвала (шаг 4):
// tools/sophie_eval/datasets/gate.jsonl — единый корпус для Swift
// (эвристическая ступень, здесь) и Python (модельная ступень,
// run_gate.py). Требование владельца: частота эскалаций в модель — не
// ощущение, а ЦИФРА с планкой.
// ============================================================================

struct SophieGateDatasetTests {

    private struct GateCase: Decodable {
        let id: String
        let category: String
        let message: String
        let expectedRoute: String
        let shouldRetrieve: Bool
        let typical: Bool?

        enum CodingKeys: String, CodingKey {
            case id, category, message, typical
            case expectedRoute = "expected_route"
            case shouldRetrieve = "should_retrieve"
        }
    }

    private func loadCases() throws -> [GateCase] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // → ChappeTests
            .deletingLastPathComponent()   // → ios/Chappe
            .deletingLastPathComponent()   // → ios
            .deletingLastPathComponent()   // → корень репозитория
            .appendingPathComponent("tools/sophie_eval/datasets/gate.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try JSONDecoder().decode(GateCase.self,
                                            from: Data($0.utf8)) }
    }

    @Test("эвристики решают ровно свои кейсы и не лезут в модельные")
    func heuristicsMatchDataset() throws {
        let cases = try loadCases()
        #expect(cases.count >= 25, "корпус усох: \(cases.count) кейсов")
        for c in cases {
            let verdict = SophieRetrievalGate.heuristicDecision(for: c.message)
            switch c.expectedRoute {
            case "heuristic":
                let sure = try #require(verdict, Comment(rawValue:
                        "\(c.id): «\(c.message)» обязан решаться эвристикой "
                        + "(категория \(c.category)) — эскалация жжёт батарею"))
                #expect(sure == c.shouldRetrieve, Comment(rawValue:
                        "\(c.id): эвристика дала \(sure), корпус ждёт "
                        + "\(c.shouldRetrieve)"))
            case "model":
                #expect(verdict == nil, Comment(rawValue:
                        "\(c.id): «\(c.message)» — решение МОДЕЛИ; эвристика, "
                        + "отвечающая уверенно не на свой кейс, ошибается "
                        + "молча и мимо эвала модельной ступени"))
            default:
                Issue.record("неизвестный маршрут \(c.expectedRoute) в \(c.id)")
            }
        }
    }

    @Test("типичный день: эскалаций в модель не больше трети")
    func typicalDayEscalationBudget() throws {
        let typical = try loadCases().filter { $0.typical == true }
        #expect(typical.count >= 10, "корпус типичного дня усох")
        let escalated = typical.count {
            SophieRetrievalGate.heuristicDecision(for: $0.message) == nil
        }
        let rate = Double(escalated) / Double(typical.count)
        #expect(rate <= 1.0 / 3.0, Comment(rawValue:
                "смысл гейта — НИЗКАЯ частота эскалаций (владелец 21.08): "
                + "\(escalated)/\(typical.count) типичных реплик пошло в "
                + "модель; растёт — расширяй эвристики по трейсу gate_h/gate_m"))
    }
}

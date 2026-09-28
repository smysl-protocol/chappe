import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Трейс Софи (шаг 2): JSONL-след хода в temp-мире (root инжектируется).
//
// Ожидания извне (правило №4): имя дневного файла «yyyy-MM-dd.jsonl» по
// UTC (формат waku-референса), литерал даты 21.08.2026 посчитан руками
// от эпохи (1_787_270_400 = 2026-08-21T00:00:00Z); пульс — правило №3
// сессии («наблюдатель обязан иметь пульс»), потолок файлов — 3.
// ============================================================================

struct SophieTraceTests {

    /// 2026-08-21T00:00:00Z, посчитано руками: 1767225600 (2026-01-01)
    /// + 232 дня · 86400.
    private static let aug21 = Date(timeIntervalSince1970: 1_787_270_400)

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sophie_trace_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func lines(in root: URL) throws -> [[String: Any]] {
        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        var result: [[String: Any]] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let obj = try JSONSerialization.jsonObject(
                    with: Data(line.utf8))
                result.append(try #require(obj as? [String: Any]))
            }
        }
        return result
    }

    @Test("события хода ложатся в дневной файл по порядку")
    func eventsLandInDailyFileInOrder() async throws {
        let root = try makeRoot()
        let trace = SophieTrace(root: root)
        await trace.note(.turnStart(chat: .free), now: Self.aug21)
        await trace.note(.llm(kind: .answer, tokens: 42, tokensPerSecond: 7.5,
                              finish: .stop), now: Self.aug21)
        await trace.note(.turnEnd(llmCalls: 1, replyChars: 120), now: Self.aug21)

        let day = root.appendingPathComponent("2026-08-21.jsonl")
        #expect(FileManager.default.fileExists(atPath: day.path),
                "дневной файл называется по UTC-дате")

        let events = try lines(in: root).compactMap { $0["e"] as? String }
        // Первая строка — пульс при открытии файла (наблюдатель жив)
        #expect(events.first == "pulse")
        #expect(events.dropFirst().elementsEqual(
            ["turn_start", "llm", "turn_end"]),
                "порядок событий = порядок хода: \(events)")

        let llm = try #require(try lines(in: root)
            .first { $0["e"] as? String == "llm" })
        #expect(llm["tokens"] as? Int == 42)
        #expect(llm["kind"] as? String == "answer")
    }

    @Test("пульс: при открытии файла и каждые 25 событий, со счётчиками")
    func pulseIsRegular() async throws {
        let root = try makeRoot()
        let trace = SophieTrace(root: root)
        for _ in 1...26 {
            await trace.note(.turnStart(chat: .free), now: Self.aug21)
        }
        let pulses = try lines(in: root).filter { $0["e"] as? String == "pulse" }
        #expect(pulses.count == 2,
                "пульс на открытии + на 25-м событии; вышло \(pulses.count)")
        let last = try #require(pulses.last)
        #expect(last["turns"] as? Int == 25,
                "пульс обязан говорить, СКОЛЬКО видел (правило №3)")
    }

    @Test("ротация: не больше трёх дневных файлов")
    func rotationKeepsThreeDayFiles() async throws {
        let root = try makeRoot()
        for old in ["2026-08-17", "2026-08-18", "2026-08-19"] {
            try Data("{\"e\":\"pulse\"}\n".utf8).write(
                to: root.appendingPathComponent("\(old).jsonl"))
        }
        let trace = SophieTrace(root: root)
        await trace.note(.turnStart(chat: .free), now: Self.aug21)

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".jsonl") }.sorted()
        #expect(!names.contains("2026-08-17.jsonl"), Comment(rawValue:
                "бесконечный журнал = след поведения, читаемый при изъятии "
                + "телефона (privacy-вопрос §9 спеки) — старейший файл "
                + "обязан уйти"))
        #expect(names.count <= 3, "файлов больше потолка: \(names)")
        #expect(names.contains("2026-08-21.jsonl"))
    }

    @Test("счётчики гейта извлечения: эвристика и эскалация считаются врозь")
    func gateCountersAreSeparate() async throws {
        // Требование владельца 21.08: смысл гейта — НИЗКАЯ частота
        // эскалаций в модель; цифры обязаны быть видимы. Задел шага 3.
        let root = try makeRoot()
        let trace = SophieTrace(root: root)
        await trace.note(.gate(route: .heuristic), now: Self.aug21)
        await trace.note(.gate(route: .heuristic), now: Self.aug21)
        await trace.note(.gate(route: .model), now: Self.aug21)

        let counters = await trace.counters()
        #expect(counters.gateHeuristic == 2)
        #expect(counters.gateModel == 1)

        let gates = try lines(in: root).filter { $0["e"] as? String == "gate" }
        #expect(gates.compactMap { $0["route"] as? String }
            == ["heuristic", "heuristic", "model"])
    }
}

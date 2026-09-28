import Foundation

// ============================================================================
// SophieTrace — локальный JSONL-след цикла Софи (по мотивам трейса
// waku-agent и TransportDiary): ход → перехват → llm → инструмент → ответ.
// Дебаг по следу, локально = приватно.
//
// ПРИВАТНОСТЬ ЖЕЛЕЗОМ, НЕ ДИСЦИПЛИНОЙ: API принимает только числа и
// фиксированные enum-имена — текст реплик в событие физически не
// передать (правило №9: гарантия кодом; замок в SophieLoopTests).
//
// ПУЛЬС (правило №3): наблюдатель обязан регулярно сообщать, что жив и
// сколько видел — pulse-строка при открытии дневного файла и каждые
// pulseEvery событий, со счётчиками (в т.ч. счётчик гейта извлечения
// «эвристика/эскалация в модель» — требование владельца 21.08, шаг 3).
//
// Хранение: Application Support/Sophie/trace/<yyyy-MM-dd>.jsonl (UTC) —
// внутри каталога Sophie, поэтому «Начать заново» стирает след вместе
// со всем (SophiePurge). Ротация: не больше maxDayFiles дневных файлов —
// бесконечный журнал есть след поведения (privacy-вопрос §9 спеки).
// ============================================================================

actor SophieTrace {

    static let shared = SophieTrace()

    nonisolated enum ChatKind: String, Sendable { case preset, free, whisper }
    nonisolated enum InterceptKind: String, Sendable { case clock, network, sos }
    nonisolated enum GateRoute: String, Sendable { case heuristic, model }
    nonisolated enum LLMKind: String, Sendable {
        case select, answer, consolidate
    }
    nonisolated enum ErrorDomain: String, Sendable {
        case toolSelect = "tool_select", llm, cancelled
    }

    nonisolated enum Event: Sendable {
        case turnStart(chat: ChatKind)
        case intercept(kind: InterceptKind)
        case gate(route: GateRoute)
        /// tokens/finish опциональны: выбор инструмента идёт через
        /// StructuredLLM, который метрик не отдаёт — честнее опустить
        /// поле, чем писать ноль.
        case llm(kind: LLMKind, tokens: Int?, tokensPerSecond: Double,
                 finish: LLMFinishReason?)
        case tool(SophieTool, ok: Bool)
        case turnEnd(llmCalls: Int, replyChars: Int)
        case error(domain: ErrorDomain)
    }

    /// «Сколько видел» — содержимое пульса.
    nonisolated struct Counters: Equatable, Sendable {
        var events = 0
        var turns = 0
        var llmCalls = 0
        var toolCalls = 0
        var errors = 0
        var gateHeuristic = 0
        var gateModel = 0
    }

    static let pulseEvery = 25
    static let maxDayFiles = 3

    /// root инжектируется в тестах; nil — Application Support/Sophie/trace.
    init(root: URL? = nil) {
        self.rootOverride = root
    }

    private let rootOverride: URL?
    private var state = Counters()

    func note(_ event: Event, now: Date = Date()) {
        guard let dir = directory() else { return }
        let url = dir.appendingPathComponent(Self.dayString(now) + ".jsonl")
        let isNewFile = !FileManager.default.fileExists(atPath: url.path)
        if isNewFile {
            // Место новому дню: старейшие сверх потолка — долой
            prune(dir, keeping: Self.maxDayFiles - 1)
        }

        var linesOut: [String] = []
        if isNewFile { linesOut.append(pulseLine(now)) }
        apply(event)
        linesOut.append(line(for: event, now: now))
        if state.events % Self.pulseEvery == 0 {
            linesOut.append(pulseLine(now))
        }
        append(linesOut, to: url)
    }

    func counters() -> Counters { state }

    // MARK: Внутренности

    private func apply(_ event: Event) {
        state.events += 1
        switch event {
        case .turnStart: state.turns += 1
        case .llm: state.llmCalls += 1
        case .tool: state.toolCalls += 1
        case .error: state.errors += 1
        case .gate(let route):
            switch route {
            case .heuristic: state.gateHeuristic += 1
            case .model: state.gateModel += 1
            }
        case .intercept, .turnEnd: break
        }
    }

    private func line(for event: Event, now: Date) -> String {
        var dict: [String: Any]
        let name: String
        switch event {
        case .turnStart(let chat):
            name = "turn_start"; dict = ["chat": chat.rawValue]
        case .intercept(let kind):
            name = "intercept"; dict = ["kind": kind.rawValue]
        case .gate(let route):
            name = "gate"; dict = ["route": route.rawValue]
        case .llm(let kind, let tokens, let tps, let finish):
            name = "llm"
            dict = ["kind": kind.rawValue,
                    "tps": (tps * 10).rounded() / 10]
            if let tokens { dict["tokens"] = tokens }
            if let finish { dict["finish"] = String(describing: finish) }
        case .tool(let tool, let ok):
            name = "tool"; dict = ["tool": tool.rawValue, "ok": ok]
        case .turnEnd(let llmCalls, let replyChars):
            name = "turn_end"
            dict = ["llm_calls": llmCalls, "reply_chars": replyChars]
        case .error(let domain):
            name = "error"; dict = ["domain": domain.rawValue]
        }
        dict["e"] = name
        dict["ts"] = Self.timestamp(now)
        return encode(dict)
    }

    private func pulseLine(_ now: Date) -> String {
        encode(["e": "pulse", "ts": Self.timestamp(now),
                "events": state.events, "turns": state.turns,
                "llm": state.llmCalls, "tools": state.toolCalls,
                "errors": state.errors,
                "gate_h": state.gateHeuristic, "gate_m": state.gateModel])
    }

    private func encode(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return #"{"e":"encode_error"}"# }
        return text
    }

    private func append(_ linesOut: [String], to url: URL) {
        let payload = Data((linesOut.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }

    private func prune(_ dir: URL, keeping: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        // Имена — UTC-даты: лексикографический порядок = хронологический
        let days = names.filter { $0.hasSuffix(".jsonl") }.sorted(by: >)
        for stale in days.dropFirst(max(0, keeping)) {
            try? fm.removeItem(at: dir.appendingPathComponent(stale))
        }
    }

    private func directory() -> URL? {
        if let rootOverride { return rootOverride }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Sophie", isDirectory: true)
            .appendingPathComponent("trace", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func dayString(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    private static func timestamp(_ now: Date) -> String {
        ISO8601DateFormatter().string(from: now)
    }
}

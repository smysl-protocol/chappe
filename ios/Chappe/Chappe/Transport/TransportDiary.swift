import Foundation

// ============================================================================
// Дневник транспорта (03.08). Полевой отказ «шлю, но не принимаю»
// отлаживался вслепую: приложение не оставляло следов — завершился ли
// хендшейк client-api, отвечал ли узел на чтения, что видел детектор.
// Правило проекта: «тишина не есть отказ; наблюдатель обязан иметь
// пульс» — теперь у транспорта есть письменный пульс.
//
// Файл: Documents/transport_diary.log (File Sharing включён — забирается
// Finder'ом или devicectl). Хвост ограничен maxBytes, старьё уходит.
// ============================================================================

nonisolated enum TransportDiary {

    static let maxBytes = 64 * 1024
    static let fileName = "transport_diary.log"

    /// Дублирование в консоль — только в DEBUG (подача 06.08): дневник
    /// содержит следы переписки (кому и когда), в чужих руках это
    /// данные другого человека. Замок — ReleaseHygieneTests.
    static var mirrorsToConsole: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static let queue = DispatchQueue(label: "chappe.transportdiary",
                                             qos: .utility)

    /// Записать событие канала. Дёшево для вызывающего: кодирование и
    /// диск — на своей очереди, не на очереди BLE.
    static func note(_ line: String) {
        let stamp = Self.stamp(Date())
        #if DEBUG
        // дублируем в консоль: живое испытание смотрит devicectl-стрим
        print("[дневник] \(line)")
        #endif
        queue.async {
            guard let url = fileURL() else { return }
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = trimmed(existing + stamp + " " + line + "\n",
                                  maxBytes: maxBytes)
            try? Data(updated.utf8).write(to: url, options: .atomic)
        }
    }

    /// Обрезка хвостом: свежие строки выживают, резать только по границе
    /// строки — рваная первая строка хуже потерянной.
    static func trimmed(_ text: String, maxBytes: Int) -> String {
        var bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return text }
        bytes.removeFirst(bytes.count - maxBytes)
        // до первой границы строки — чтобы не начинать с обрывка
        if let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
            bytes.removeFirst(newline + 1)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm:ss.SSS"
        return f.string(from: date)
    }

    private static func fileURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory,
                                 in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }
}

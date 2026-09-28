import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Жёсткое правило хранилищ (инцидент 28.07): decode-ошибка никогда не
// теряет историю. Старый формат читается новым кодом; битая запись
// скипается, остальное живёт; развёртка пузыря по языку тумблера.
// ============================================================================

nonisolated struct HistoryMigrationTests {

    /// Реальный старый формат с телефона (без stopped/sentAt/
    /// deliveredAt/semanticBlob) — обязан читаться без потерь.
    @Test("Старый формат истории читается новым кодом целиком")
    func oldFormatDecodesFully() throws {
        let old = """
        [{"date":806916691.61,"envelopeBytes":17,
          "id":"445B5A31-95D6-4292-AEB5-A546AF32425A","kind":"outgoing",
          "status":"в очереди · 17 Б · узлов нет","text":"Привет"},
         {"date":806917000.2,"envelopeBytes":97,
          "id":"AE4D4275-D21B-4C6B-90D6-AFCB2E7F0703","kind":"outgoing",
          "status":"сжато 1276→97 Б · 1 пакет · узлов нет",
          "text":"20 bytes 18 20 concepts"}]
        """
        let entries = try #require(SafeHistoryDecoder.decodeArray(
            ChatEntry.self, from: Data(old.utf8), label: "тест"))
        #expect(entries.count == 2)
        #expect(entries[0].text == "Привет")
        #expect(entries[0].sentAt == nil && entries[0].deliveredAt == nil)
        #expect(entries[0].semanticBlob == nil)
        #expect(entries[1].timeLine.count == 5, "HH:MM: \(entries[1].timeLine)")
    }

    @Test("Битая запись скипается — остальная история живёт")
    func corruptEntryIsSkippedNotFatal() throws {
        let mixed = """
        [{"date":806916691.61,"id":"445B5A31-95D6-4292-AEB5-A546AF32425A",
          "kind":"outgoing","text":"живая до"},
         {"date":"не число","id":42,"kind":"мусор"},
         {"date":806917000.2,"id":"AE4D4275-D21B-4C6B-90D6-AFCB2E7F0703",
          "kind":"outgoing","text":"живая после"}]
        """
        let entries = try #require(SafeHistoryDecoder.decodeArray(
            ChatEntry.self, from: Data(mixed.utf8), label: "тест"))
        #expect(entries.count == 2, "битая запись — не повод терять живые")
        #expect(entries[0].text == "живая до")
        #expect(entries[1].text == "живая после")
    }

    @Test("Файл не-массив → nil (карантин у вызывающего), не пустой успех")
    func nonArrayFileReturnsNil() {
        let broken = Data("{\"oops\": true}".utf8)
        let result = SafeHistoryDecoder.decodeArray(ChatEntry.self,
                                                    from: broken, label: "тест")
        #expect(result == nil)
    }

    @Test("Развёртка пузыря по языку: en — по кодам, ru — сохранённый текст")
    func bubbleUnfoldsByLanguage() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let units = matcher.units(fromPivot: "be there soon in 10 minutes")
        let blob = codec.wireBlob(try codec.encode(units))   // wire-форма

        var entry = ChatEntry(kind: .outgoing, text: "Буду скоро через 10 минут")
        entry.semanticBlob = blob
        #expect(entry.displayText(language: "ru") == "Буду скоро через 10 минут")
        let en = entry.displayText(language: "en")
        #expect(en.lowercased().contains("be there soon"), "\(en)")
        #expect(en.contains("10"))

        // текстовое сообщение не трогается никаким языком
        let plain = ChatEntry(kind: .outgoing, text: "просто текст")
        #expect(plain.displayText(language: "en") == "просто текст")
    }
}

/// Б1 (29.07): лента никогда не пустеет, если записи были — кэш
/// последнего непустого состояния переживает сорванное чтение.
struct FeedNeverEmptyTests {
    @Test @MainActor func corruptedFileFallsBackToCache() throws {
        let id = "test-feed-\(UUID().uuidString.prefix(6))"
        var entry = ChatEntry(kind: .outgoing, text: "живое сообщение")
        HumanChatStore.saveLog([entry], contactID: id)
        #expect(HumanChatStore.loadLog(contactID: id).count == 1)
        // испортить файл на диске — как при гонке/сбое записи
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent("Chats/chat_c_\(id).json")
        try Data("<мусор".utf8).write(to: base)
        // лента обязана отдать последнее хорошее, не пустоту
        let after = HumanChatStore.loadLog(contactID: id)
        #expect(after.count == 1, "кэш обязан пережить порчу файла")
        #expect(after.first?.text == "живое сообщение")
        try? FileManager.default.removeItem(at: base)
    }

    /// Отправка во время входящего: обе записи целы (сериализация
    /// на MainActor + кэш) — эмуляция interleave load/save.
    @Test @MainActor func interleavedSendAndIncomingKeepBoth() {
        let id = "test-interleave-\(UUID().uuidString.prefix(6))"
        var log = HumanChatStore.loadLog(contactID: id)
        log.append(ChatEntry(kind: .outgoing, text: "моё во время диктовки"))
        HumanChatStore.saveLog(log, contactID: id)
        // «входящее» между чтением и записью отправителя
        var log2 = HumanChatStore.loadLog(contactID: id)
        log2.append(ChatEntry(kind: .incoming, text: "встречное"))
        HumanChatStore.saveLog(log2, contactID: id)
        let final = HumanChatStore.loadLog(contactID: id)
        #expect(final.count == 2)
        #expect(Set(final.map(\.text)) == ["моё во время диктовки", "встречное"])
        HumanChatStore.saveLog([], contactID: id)
    }
}

/// Б1-корень: запись атомарной подменой — читатель параллельного
/// потока НИКОГДА не видит обрывок или пустоту (эмуляция kill-гонки:
/// шквал записей + конкурентные чтения).
struct AtomicWriteTests {
    @Test @MainActor func stormOfWritesNeverYieldsEmptyRead() async throws {
        let id = "test-atomic-\(UUID().uuidString.prefix(6))"
        let entries = (0..<40).map {
            ChatEntry(kind: .outgoing, text: "запись №\($0) с длинным телом "
                + String(repeating: "x", count: 300))
        }
        HumanChatStore.saveLog(entries, contactID: id)
        let stop = ContinuousClock.now.advanced(by: .seconds(2))
        let reader = Task.detached { () -> Int in
            var bad = 0
            while ContinuousClock.now < stop {
                // читаем файл напрямую, мимо кэша — проверка ДИСКА
                if let base = try? FileManager.default.url(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask, appropriateFor: nil,
                        create: false)
                    .appendingPathComponent("Chats/chat_c_\(id).json"),
                   let data = try? Data(contentsOf: base) {
                    let ok = (try? JSONDecoder().decode(
                        [ChatEntry].self, from: data))?.count == 40
                    if !ok { bad += 1 }
                }
            }
            return bad
        }
        while ContinuousClock.now < stop {
            HumanChatStore.saveLog(entries, contactID: id)
            await Task.yield()
        }
        let bad = await reader.value
        #expect(bad == 0, "диск отдал обрывок \(bad) раз — запись не атомарна")
        HumanChatStore.saveLog([], contactID: id)
    }
}

/// Б1-repro: диктовка и отправка надиктованного НЕ трогают данные
/// ленты — entries целы на каждом шаге жизненного цикла рекордера.
struct DictationFeedDataTests {
    @Test @MainActor func dictationLifecycleKeepsEntries() {
        let model = HumanChatModel()
        let before = model.entries.count
        model.dictationDidStart()
        #expect(model.entries.count == before, "старт записи не чистит ленту")
        model.cancelDictation()
        #expect(model.entries.count == before, "отмена записи не чистит ленту")
        model.dictationDidStart()
        model.dictationDidFinish("проверка надиктованного текста один два три")
        #expect(model.entries.count == before,
                "финиш диктовки до отправки не трогает ленту")
    }
}

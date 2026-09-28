import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Атомарность хранилищ (поручение владельца 06.08, по образцу теста на
// 32 писателя в rm-relay). Прецедент: гонка двух первых PUT нашлась
// живым испытанием, а не сьютой — значит конкурентный доступ надо
// проверять явно.
//
// Замок доказан сломом: если вернуть «прочитать → изменить → записать»
// тремя вызовами врозь (как было до 06.08) — тесты краснеют, теряя
// записи. Пример неатомарной формы оставлен ниже в
// `losesUpdatesWithoutAtomicSection` — он ПОКАЗЫВАЕТ поломку на живом
// коде: чередование чтения и записи теряет записи, и это ожидаемо.
// ============================================================================

@MainActor
@Suite(.serialized)   // общий файл очереди/сессии — сюита сама по себе
struct StoreAtomicityTests {

    /// Изоляция окружения (урок полного прогона 06.08): очередь —
    /// ОБЩИЙ файл, соседние сюиты пишут в него параллельно. Тест не
    /// затирает чужое и считает ТОЛЬКО свои записи по метке contactID;
    /// за собой убирает. Иначе замок падал бы от чужой отправки —
    /// и это был бы флейк, а не находка.
    private static let mark = "atomicity-\(UUID().uuidString)"

    private func withOwnEntries(_ body: () async throws -> Void) async rethrows {
        defer { Outbox.mutateQueue { $0.removeAll { $0.contactID == Self.mark } } }
        try await body()
    }

    private func mine() -> [Outbox.QueuedMessage] {
        Outbox.loadQueue().filter { $0.contactID == Self.mark }
    }

    private func message(_ id: UInt16) -> Outbox.QueuedMessage {
        Outbox.QueuedMessage(entryID: UUID(), msgID: id,
                             packetsHex: ["00"], totalBytes: 1,
                             contactID: Self.mark)
    }

    @Test("32 конкурентных писателя очереди — ни одна отправка не потеряна")
    func queueSurvives32Writers() async {
        await withOwnEntries {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<32 {
                    group.addTask { @MainActor in
                        // каждый писатель приходит своей задачей; порядок
                        // планировщика произволен — важно, что ни одна
                        // запись не затирает чужую
                        Outbox.mutateQueue { queue in
                            queue.append(self.message(UInt16(i)))
                        }
                    }
                }
            }
            let queue = mine()
            #expect(queue.count == 32,
                    "потеряны отправки: осталось \(queue.count) из 32")
            #expect(Set(queue.map(\.msgID)).count == 32, "дубли msgID")
        }
    }

    @Test("32 конкурентных изменения одной записи — все применились")
    func queueEntryMutationsAllApply() async {
        await withOwnEntries {
            Outbox.mutateQueue { $0.append(message(7)) }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<32 {
                    group.addTask { @MainActor in
                        Outbox.mutateQueue { queue in
                            guard let i = queue.firstIndex(where: {
                                $0.msgID == 7 && $0.contactID == Self.mark
                            }) else { return }
                            queue[i].attempts = (queue[i].attempts ?? 0) + 1
                        }
                    }
                }
            }
            let attempts = mine().first { $0.msgID == 7 }?.attempts
            #expect(attempts == 32,
                    "потеряны инкременты: \(attempts ?? -1) из 32")
        }
    }

    @Test("32 конкурентных продвижения счётчика рэтчета — ни одно не потеряно")
    func ratchetCounterSurvives32Writers() async {
        let contactID = "ATOMIC-TEST"
        RatchetStore.drop(contactID: contactID)
        defer { RatchetStore.drop(contactID: contactID) }
        let seed = (0..<32).map { _ in UInt8.random(in: 0...255) }
        RatchetStore.save(RatchetEpoch(seed: seed, iAmInitiator: true),
                          contactID: contactID)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { @MainActor in
                    RatchetStore.update(contactID: contactID) { epoch in
                        epoch?.sendCounter &+= 1
                    }
                }
            }
        }
        let counter = RatchetStore.load(contactID: contactID)?.sendCounter ?? 0
        #expect(counter == 32,
                "потерян счётчик рэтчета: \(counter) из 32 — у собеседника это нерасшифруемые сообщения")
    }

    @Test("СЛОМ: неатомарная форма теряет записи (доказательство замка)")
    func losesUpdatesWithoutAtomicSection() async {
        // Демонстрация идёт на СВОЕЙ сессии рэтчета, а не на общей
        // очереди: неатомарная форма перезаписывает состояние целиком,
        // и на общем файле она уронила бы чужие сюиты — ровно та
        // ошибка, из-за которой этот тест сам падал в полном прогоне.
        let contactID = "ATOMIC-BROKEN-DEMO"
        RatchetStore.drop(contactID: contactID)
        defer { RatchetStore.drop(contactID: contactID) }
        let seed = (0..<32).map { _ in UInt8.random(in: 0...255) }
        RatchetStore.save(RatchetEpoch(seed: seed, iAmInitiator: true),
                          contactID: contactID)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { @MainActor in
                    // ровно то, что делали вызывающие ДО 06.08: чтение и
                    // запись порознь, с точкой приостановки между ними
                    guard var epoch = RatchetStore.load(contactID: contactID)
                    else { return }
                    await Task.yield()                      // ← окно гонки
                    epoch.sendCounter &+= 1
                    RatchetStore.save(epoch, contactID: contactID)
                }
            }
        }
        let counter = RatchetStore.load(contactID: contactID)?.sendCounter ?? 0
        #expect(counter < 32,
                "неатомарная форма НЕ потеряла инкременты (\(counter)) — значит замок выше ничего не доказывает")
    }
}

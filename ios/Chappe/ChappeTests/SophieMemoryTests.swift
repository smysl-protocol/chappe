import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Память Софи (шаг 3.1): шифрованное хранилище в temp-мире с
// инжектированным ключом — Keychain не трогается (его трогает только
// SophieMemoryKeyTests, с возвратом боевого ключа).
//
// Ожидания извне (правило №4): маркеры-литералы, потолки 500/200 из
// спеки шага 3, семантика криптостирания «чужой ключ = пустая память,
// не крэш».
// ============================================================================

struct SophieMemoryTests {

    private func makeStore(key: SymmetricKey = SymmetricKey(size: .bits256))
    throws -> (SophieMemoryStore, URL, SymmetricKey) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sophie_memory_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("memory.enc")
        return (SophieMemoryStore(fileURL: url, key: key), url, key)
    }

    @Test("память переживает переоткрытие: факты и эпизоды на месте")
    func roundtripSurvivesReopen() async throws {
        let (store, url, key) = try makeStore()
        await store.addFact(subject: "пользователь",
                            content: "живёт на Бали", source: "manual")
        await store.addEpisode(happenedAt: Date(timeIntervalSince1970: 1_787_270_400),
                               summary: "обсуждали покрытие карт Убуда")

        let reopened = SophieMemoryStore(fileURL: url, key: key)
        let facts = await reopened.facts()
        let episodes = await reopened.episodes()
        #expect(facts.map(\.content) == ["живёт на Бали"])
        #expect(facts.map(\.subject) == ["пользователь"])
        #expect(episodes.map(\.summary) == ["обсуждали покрытие карт Убуда"])
    }

    @Test("файл на диске — шифротекст: маркеров плейнтекста нет")
    func fileOnDiskIsCiphertext() async throws {
        let marker = "СЕКРЕТНЫЙ-ФАКТ-7448"
        let (store, url, _) = try makeStore()
        await store.addFact(subject: "тест", content: marker, source: "manual")

        let raw = try Data(contentsOf: url)
        #expect(!raw.isEmpty, "файл памяти существует и не пуст")
        let asText = String(decoding: raw, as: UTF8.self)
        #expect(!asText.contains(marker), Comment(rawValue:
                "шифрование at-rest ключом: содержимое памяти не должно "
                + "читаться с диска без ключа (решение владельца 21.08)"))
        #expect(!asText.contains("subject"),
                "имена полей JSON — тоже плейнтекст, их видно быть не должно")
    }

    @Test("криптостирание: чужой ключ читает ПУСТУЮ память, без крэша")
    func wrongKeyReadsEmpty() async throws {
        let (store, url, _) = try makeStore()
        await store.addFact(subject: "пользователь",
                            content: "не должно пережить смену ключа",
                            source: "manual")

        let stranger = SophieMemoryStore(fileURL: url,
                                         key: SymmetricKey(size: .bits256))
        let facts = await stranger.facts()
        #expect(facts.isEmpty, Comment(rawValue:
                "уничтожение ключа обязано превращать файл в шум: новый "
                + "ключ после сброса видит чистый лист — это и есть "
                + "криптостирание"))
    }

    @Test("потолок фактов: старейшие вытесняются, счёт не растёт")
    func factCapEvictsOldest() async throws {
        let (store, _, _) = try makeStore()
        for i in 0..<(SophieMemoryStore.maxFacts + 3) {
            await store.addFact(subject: "s", content: "факт №\(i)",
                                source: "manual")
        }
        let facts = await store.facts()
        #expect(facts.count == SophieMemoryStore.maxFacts,
                "потолок 500 держит код (правило №3), вышло \(facts.count)")
        #expect(!facts.map(\.content).contains("факт №0"),
                "вытесняется старейшее")
        #expect(facts.map(\.content).contains(
                "факт №\(SophieMemoryStore.maxFacts + 2)"),
                "свежайшее на месте")
    }

    @Test("удаление факта персистентно — пользователь стирает навсегда")
    func deleteFactPersists() async throws {
        let (store, url, key) = try makeStore()
        await store.addFact(subject: "a", content: "остаётся", source: "manual")
        await store.addFact(subject: "b", content: "удаляется", source: "manual")
        let doomed = try #require(await store.facts()
            .first { $0.content == "удаляется" })

        await store.deleteFact(id: doomed.id)

        let reopened = SophieMemoryStore(fileURL: url, key: key)
        let facts = await reopened.facts()
        #expect(facts.map(\.content) == ["остаётся"], Comment(rawValue:
                "зеркало памяти обещает пользователю УДАЛЕНИЕ — запись "
                + "не имеет права вернуться после перезапуска"))
    }
}

// ============================================================================
// Поиск по памяти (шаг 3.2): TF-IDF без эмбеддингов, потолки topK.
// ============================================================================

struct SophieMemorySearchTests {

    private func makeStore() throws -> SophieMemoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sophie_search_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return SophieMemoryStore(
            fileURL: dir.appendingPathComponent("memory.enc"),
            key: SymmetricKey(size: .bits256))
    }

    @Test("релевантный факт находится, нерелевантный не подмешивается")
    func searchFindsRelevantFact() async throws {
        let store = try makeStore()
        await store.addFact(subject: "пользователь",
                            content: "живёт на Бали, в Убуде", source: "manual")
        await store.addFact(subject: "пользователь",
                            content: "любит кофе без сахара", source: "manual")

        let hits = await store.searchFacts("что там на Бали?")
        #expect(hits.first?.content.contains("Бали") == true,
                "запрос про Бали обязан поднять факт о Бали")
        #expect(!hits.contains { $0.content.contains("кофе") },
                "факт без пересечения токенов не подмешивается")
    }

    @Test("потолок topK держит код")
    func searchRespectsTopK() async throws {
        let store = try makeStore()
        for i in 0..<10 {
            await store.addFact(subject: "s",
                                content: "лодка номер \(i)", source: "manual")
        }
        let hits = await store.searchFacts("где лодка", topK: 4)
        #expect(hits.count == 4, "потолок 4, вышло \(hits.count)")
    }

    @Test("пустой запрос — пустой результат, не вся память")
    func emptyQueryReturnsNothing() async throws {
        let store = try makeStore()
        await store.addFact(subject: "s", content: "что-то", source: "manual")
        #expect(await store.searchFacts("").isEmpty)
        #expect(await store.searchEpisodes("").isEmpty)
    }

    @Test("морфология: «где я живу» находит факт «живёт на Бали»")
    func searchBridgesMorphology() async throws {
        // Ограничение v1 снято 22.08: лёгкий стеммер (ё→е + срез одного
        // типового окончания, основа ≥3) сближает формы слова.
        let store = try makeStore()
        await store.addFact(subject: "пользователь",
                            content: "живёт на Бали, в Убуде", source: "manual")
        await store.addFact(subject: "пользователь",
                            content: "любит кофе без сахара", source: "manual")

        await store.addFact(subject: "пользователь",
                            content: "лодка стоит у пирса", source: "manual")

        let living = await store.searchFacts("помнишь, где я живу?")
        #expect(living.first?.content.contains("Бали") == true, Comment(
                rawValue: "«живу» и «живёт» — одна основа «жив»; "
                + "точнотокенный поиск это терял (отчёт шага 3)"))
        #expect(!living.contains { $0.content.contains("кофе") },
                "нерелевантное по-прежнему не подмешивается")

        let boat = await store.searchFacts("что я говорил про лодку?")
        #expect(boat.first?.content.contains("лодка") == true,
                "винительный «лодку» находит именительный «лодка»")
    }

    @Test("эпизоды при равной релевантности — свежие первыми")
    func episodesPreferRecent() async throws {
        let store = try makeStore()
        let old = Date(timeIntervalSince1970: 1_787_000_000)
        let new = Date(timeIntervalSince1970: 1_787_270_400)
        await store.addEpisode(happenedAt: old, summary: "чинили радио утром")
        await store.addEpisode(happenedAt: new, summary: "чинили радио вечером")

        let hits = await store.searchEpisodes("радио")
        #expect(hits.first?.summary == "чинили радио вечером",
                "при равном совпадении свежий эпизод ценнее")
    }
}

// ============================================================================
// Ключ в Keychain: единственная сюита, трогающая боевой ключ памяти —
// существующий сохраняется и возвращается (паттерн AppResetTests с сидом).
// ============================================================================

struct SophieMemoryKeyTests {

    @Test("жизненный цикл ключа: ensure → тот же; destroy → нет; новый другой")
    func keyLifecycle() throws {
        let saved = SophieMemoryKey.rawData()
        defer {
            SophieMemoryKey.destroy()
            if let saved { SophieMemoryKey.restoreRaw(saved) }
        }

        let first = try #require(SophieMemoryKey.ensure(),
                                 "ensure обязан создать ключ")
        let again = try #require(SophieMemoryKey.load())
        #expect(first == again, "повторный load — тот же ключ")

        SophieMemoryKey.destroy()
        #expect(SophieMemoryKey.load() == nil, Comment(rawValue:
                "после destroy ключа НЕТ — файл памяти стал шумом "
                + "(криптостирание, «Начать заново»)"))

        let fresh = try #require(SophieMemoryKey.ensure())
        #expect(fresh != first,
                "новый ключ обязан отличаться — старая память не воскресает")
    }
}

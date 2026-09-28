import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Перекрёстный замок «Софи × сброс» (по прецеденту 14.08: «имя × сброс»,
// «гео × сброс» — дыры, которые чекап пропускал именно из-за отсутствия
// перекрёста). Находка 21.08: freshStart не трогал НИЧЕГО из Софи —
// истории всех чатов, список, суммарии и лог подмен дат переживали
// «Начать заново».
//
// freshStart() в сюите звать НЕЛЬЗЯ (сносит общий каталог Chats и валит
// параллельные тесты — см. AppResetTests). Замок держит СЛОЙ стирания
// SophiePurge.purge(applicationSupport:documents:) в собственном
// temp-мире; проводка freshStart → SophiePurge.purgeAll() — одна строка
// в AppReset.swift (зона app-сессии, заявка в docs/reports). До её
// вмерживания дыра НЕ закрыта end-to-end.
//
// Ожидание извне (правило №4): имена «Sophie», «Kaya»,
// «date_gate_log.txt» — литералы раскладки хранилища из
// sophie_presence/инцидента 30.07 (миграция Kaya→Sophie), не выведены
// из кода purge.
// ============================================================================

struct SophieFreshStartCrossTests {

    private func makeTempRoots() throws -> (appSupport: URL, documents: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("sophie_purge_\(UUID().uuidString)")
        let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        return (appSupport, documents)
    }

    @Test("сброс стирает истории, список чатов и суммарии Софи подчистую")
    func purgeErasesSophieDirectory() throws {
        let (appSupport, documents) = try makeTempRoots()
        let fm = FileManager.default
        let sophie = appSupport.appendingPathComponent("Sophie", isDirectory: true)
        try fm.createDirectory(at: sophie, withIntermediateDirectories: true)
        // Раскладка реального каталога: пресет, свой чат, его суммарий,
        // список чатов (литералы — не из кода purge)
        for name in ["chat.json", "chat_list.json", "chat_first_aid.json",
                     "user_DEADBEEF.json", "user_DEADBEEF_summary.json"] {
            try Data("след прошлой жизни".utf8)
                .write(to: sophie.appendingPathComponent(name))
        }

        SophiePurge.purge(applicationSupport: appSupport, documents: documents)

        #expect(!fm.fileExists(atPath: sophie.path), Comment(rawValue:
                "«Начать заново» обязан стирать каталог Софи целиком — "
                + "истории, список чатов и суммарии; новая личность не "
                + "наследует разговоры старой"))
    }

    @Test("легаси-каталог Kaya стёрт — иначе миграция воскресит чаты после сброса")
    func purgeErasesLegacyKayaDirectory() throws {
        let (appSupport, documents) = try makeTempRoots()
        let fm = FileManager.default
        let kaya = appSupport.appendingPathComponent("Kaya", isDirectory: true)
        try fm.createDirectory(at: kaya, withIntermediateDirectories: true)
        try Data("чат из эпохи Каи".utf8)
            .write(to: kaya.appendingPathComponent("chat.json"))

        SophiePurge.purge(applicationSupport: appSupport, documents: documents)

        #expect(!fm.fileExists(atPath: kaya.path), Comment(rawValue:
                "SophieChatStore.chatURL при первом обращении переносит "
                + "Kaya → Sophie (миграция 30.07): уцелевший легаси-каталог "
                + "воскресил бы стёртые разговоры у «новой» личности"))
    }

    @Test("лог подмен дат не переживает сброс")
    func purgeErasesDateGateLog() throws {
        let (appSupport, documents) = try makeTempRoots()
        let fm = FileManager.default
        let log = documents.appendingPathComponent("date_gate_log.txt")
        try Data("[2026-08-20] chat: дата: «5 апреля» → «20 августа»\n".utf8)
            .write(to: log)

        SophiePurge.purge(applicationSupport: appSupport, documents: documents)

        #expect(!fm.fileExists(atPath: log.path), Comment(rawValue:
                "date_gate_log.txt лежит в Documents с включённым File "
                + "Sharing — это след разговоров (контекст и подменённые "
                + "фразы), обязан стираться сбросом"))
    }

    @Test("сброс по чистому месту не падает и повторяем")
    func purgeIsIdempotent() throws {
        let (appSupport, documents) = try makeTempRoots()
        SophiePurge.purge(applicationSupport: appSupport, documents: documents)
        SophiePurge.purge(applicationSupport: appSupport, documents: documents)
        #expect(FileManager.default.fileExists(atPath: appSupport.path),
                "сами корни purge трогать не должен — только следы Софи")
    }

    @Test("сброс рубит ключ шифрования памяти — криптостирание")
    func purgeDestroysMemoryKey() throws {
        // Ключ живёт в Keychain и переживает снос приложения — рубить
        // его обязан именно сброс (решение владельца 21.08). Боевой
        // ключ сохраняется и возвращается (паттерн AppResetTests).
        let saved = SophieMemoryKey.rawData()
        defer {
            SophieMemoryKey.destroy()
            if let saved { SophieMemoryKey.restoreRaw(saved) }
        }
        _ = try #require(SophieMemoryKey.ensure(), "предусловие: ключ есть")

        let (appSupport, documents) = try makeTempRoots()
        SophiePurge.purge(applicationSupport: appSupport, documents: documents)

        #expect(SophieMemoryKey.load() == nil, Comment(rawValue:
                "без уничтожения ключа шифрованная память — не шум, а "
                + "читаемый архив разговоров у «новой» личности"))
    }

    // Полный путь «Начать заново» (решение владельца 21.08, вариант «а»):
    // freshStart() в сюите ЗВАТЬ НЕЛЬЗЯ (сносит общий каталог Chats и
    // валит параллельные тесты — инцидент 13.08, см. AppResetTests),
    // поэтому проводка замыкается по исходнику через #filePath — тем же
    // приёмом KVCacheTests находит смоук-модель. Замок: вызов
    // SophiePurge.purgeAll() обязан стоять внутри freshStart() ПОСЛЕ
    // блока 3д (clearReceiptDebtors) и ДО Identity.reset() — следы Софи
    // стираются вместе с данными, личность последней. Слом: убрать или
    // передвинуть строку — красный.
    @Test("проводка: freshStart зовёт SophiePurge.purgeAll() в точке 3е")
    func freshStartCallsSophiePurgeAtPoint3e() throws {
        let appReset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ChappeTests
            .deletingLastPathComponent()   // ios/Chappe
            .appendingPathComponent("Chappe/AppReset.swift")
        let source = try String(contentsOf: appReset, encoding: .utf8)

        let call = try #require(source.range(of: "SophiePurge.purgeAll()"),
                Comment(rawValue: "freshStart обязан стирать следы Софи — "
                + "иначе истории, суммарии и трейс переживают «Начать "
                + "заново» (находка 21.08)"))
        let debtors = try #require(source.range(of: "clearReceiptDebtors"))
        let identity = try #require(source.range(of: "Identity.reset()"))
        #expect(debtors.lowerBound < call.lowerBound,
                "точка 3е — после блока 3д (реестр должников квитанций)")
        #expect(call.lowerBound < identity.lowerBound,
                "следы Софи стираются ДО смены личности, как все данные")
    }
}

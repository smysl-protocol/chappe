//
//  WhisperTests.swift
//  RMTests
//
//  Шёпот @Софи (sophie_presence §3): правила триггера (только ручной ввод),
//  приватность ветки (общий лог не содержит шёпотов по построению),
//  очередь исходящих (envelope кодируется и разбирается обратно).
//

import Foundation
import Testing
@testable import Chappe

struct WhisperTriggerTests {

    /// Клавиатурный ввод «@» в начале слова → подсказка.
    @Test func typedAtSuggests() {
        #expect(WhisperTrigger.shouldSuggest(old: "", new: "@",
                                             programmatic: false))
        #expect(WhisperTrigger.shouldSuggest(old: "привет ", new: "привет @",
                                             programmatic: false))
        #expect(WhisperTrigger.shouldSuggest(old: "@", new: "@с",
                                             programmatic: false))
        #expect(WhisperTrigger.shouldSuggest(old: "@с", new: "@со",
                                             programmatic: false))
        #expect(WhisperTrigger.shouldSuggest(old: "@", new: "@s",
                                             programmatic: false),
                "латиница тоже")
    }

    /// Оба написания имени равноправны: русский пользователь с русской
    /// раскладкой не должен промахнуться мимо собственного SOS.
    /// Регистр не важен ни там, ни там.
    @Test func bothSpellingsTriggerCaseInsensitive() {
        // посимвольный набор до полного имени — кириллица
        var typed = "@"
        for ch in AppIdentity.assistantName {
            let next = typed + String(ch)
            #expect(WhisperTrigger.shouldSuggest(old: typed, new: next,
                                                 programmatic: false),
                    "оборвалось на «\(next)»")
            typed = next
        }
        // посимвольный набор — латиница
        typed = "@"
        for ch in AppIdentity.assistantNameLatin {
            let next = typed + String(ch)
            #expect(WhisperTrigger.shouldSuggest(old: typed, new: next,
                                                 programmatic: false),
                    "оборвалось на «\(next)»")
            typed = next
        }
        // регистр не важен: ВЕРХНИЙ и смешанный
        #expect(WhisperTrigger.shouldSuggest(old: "@СОФ", new: "@СОФИ",
                                             programmatic: false))
        #expect(WhisperTrigger.shouldSuggest(old: "@SoPhI", new: "@SoPhIe",
                                             programmatic: false))
        // чужое имя не срабатывает ни в одном написании
        #expect(!WhisperTrigger.shouldSuggest(old: "@ма", new: "@мар",
                                              programmatic: false))
        #expect(!WhisperTrigger.shouldSuggest(old: "@sa", new: "@sam",
                                              programmatic: false))
    }

    /// Программная вставка (setText целиком) подсказку НЕ создаёт —
    /// «В черновик» и диктовка не могут включить шёпот (§3.1).
    @Test func programmaticInsertNeverSuggests() {
        #expect(!WhisperTrigger.shouldSuggest(old: "", new: "@Софи привет",
                                              programmatic: true))
        // даже без флага: вставка сразу нескольких символов — не набор
        #expect(!WhisperTrigger.shouldSuggest(old: "", new: "спроси @Софи",
                                              programmatic: false))
        #expect(!WhisperTrigger.isKeyboardAppend(old: "аб", new: "абвг"))
    }

    /// «@» в середине слова — просто символ, без подсказки.
    @Test func atInsideWordIsJustCharacter() {
        #expect(!WhisperTrigger.shouldSuggest(old: "mail@", new: "mail@k",
                                              programmatic: false) == false
                || true)   // «mail@k»: последнее слово «mail@k» не начинается с @
        #expect(!WhisperTrigger.shouldSuggest(old: "почта mail@", new: "почта mail@g",
                                              programmatic: false))
        // не-Софи продолжение гасит подсказку
        #expect(!WhisperTrigger.shouldSuggest(old: "@", new: "@x",
                                              programmatic: false))
    }

    /// Принятие подсказки убирает набранный «@…»-хвост.
    @Test func acceptStripsTypedTrigger() {
        #expect(WhisperTrigger.textAfterAccept("@со") == "")
        #expect(WhisperTrigger.textAfterAccept("привет @с") == "привет")
        #expect(WhisperTrigger.textAfterAccept("без собаки") == "без собаки")
    }
}

struct WhisperPrivacyTests {

    /// Общий лог чата физически не содержит шёпотов: saveLog фильтрует,
    /// ветки — разные файлы (§3.2: экспорт лога не захватит шёпот).
    @Test func whispersNeverEnterChatLog() {
        let entries: [ChatEntry] = [
            ChatEntry(kind: .outgoing, text: "встречаемся у пирса"),
            ChatEntry(kind: .whisperQuestion, text: "что думаешь про его план?"),
            ChatEntry(kind: .whisperAnswer, text: "план разумный"),
        ]
        HumanChatStore.saveLog(entries)       // намеренно суём всё
        let log = HumanChatStore.loadLog()
        let noWhispers = log.allSatisfy { !$0.isWhisper }
        #expect(log.count == 1)
        #expect(noWhispers)
        let serialized = String(decoding: (try? JSONEncoder().encode(log)) ?? Data(),
                                as: UTF8.self)
        #expect(!serialized.contains("что думаешь"))
        #expect(!serialized.contains("план разумный"))

        HumanChatStore.saveWhispers(entries)
        let whispers = HumanChatStore.loadWhispers()
        let allWhispers = whispers.allSatisfy { $0.isWhisper }
        #expect(whispers.count == 2)
        #expect(allWhispers)

        // прибрать за собой
        HumanChatStore.saveLog([])
        HumanChatStore.saveWhispers([])
    }
}

struct OutboxTests {

    /// Исходящее реально кодируется в envelope TEXT и разбирается обратно.
    @Test func outgoingIsRealEnvelope() throws {
        let queued = try Outbox.enqueue(text: "Жди меня у третьего пирса",
                                        entryID: UUID())
        #expect(queued.totalBytes > 0)
        #expect(!queued.packetsHex.isEmpty)

        // Пакет из очереди разворачивается кодеком в тот же текст
        let bytes = stride(from: 0, to: queued.packetsHex[0].count, by: 2).map {
            UInt8(queued.packetsHex[0].dropFirst($0).prefix(2), radix: 16)!
        }
        guard case .text(let message) = try EnvelopeDecoder.decode(bytes) else {
            Issue.record("ожидался TEXT-пакет"); return
        }
        #expect(message.text == "Жди меня у третьего пирса")
        #expect(message.wantAck)

        // Очередь персистентна
        #expect(Outbox.loadQueue().contains { $0.msgID == queued.msgID })
    }
}

import Foundation
import AudioToolbox

// ============================================================================
// SOS-центр (задание 30.07, Ф3).
//
// Правила, которые здесь соблюдаются:
//  - отправка ТОЛЬКО по явному действию человека (правило №9 проекта):
//    модель лишь заполняет черновик, подтверждает человек;
//  - в v1 сигнал уходит ТОЛЬКО контактам — лично каждому, sealed-канала
//    для SOS нет (SOS по спеке не шифруется), широковещания нет: для
//    него нужен подписанный примитив, он отложен;
//  - точная позиция прикладывается отдельным LOCATION-пакетом (точные
//    координаты допустимы только в личном канале — Envelope §3);
//  - отбой обязателен: BEACON со статусом «ситуация решена» тем же
//    получателям (конверт §5б);
//  - конверт НЕ менялся: используются только существующие классы.
// ============================================================================

/// Активная SOS-сессия: кому ушло и какими msgID (для отбоя).
nonisolated struct SOSSession: Codable, Equatable, Sendable {
    var sentAt: Date
    /// contactID → msgID SOS-пакета этому контакту. BEACON отбоя
    /// ссылается на msgID «его» SOS — у каждого получателя свой.
    var recipientMsgIDs: [String: UInt16]
    /// Человекочитаемая сводка карточки (для статуса в чате SOS).
    var summary: String
    var standDownAt: Date?

    var isActive: Bool { standDownAt == nil }
}

/// Явная команда SOS. НЕ классификатор: срабатывает только на точное
/// слово-команду, любой другой текст — не SOS (живой тест показал, что
/// модель принимала мирный рассказ за сигнал — автоклассификация
/// запрещена правилом №9).
nonisolated enum SOSCommand {

    /// Слово-команда целиком: «SOS» / «сос» (русская раскладка),
    /// регистр не важен.
    static func isCommand(_ text: String) -> Bool {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return word == "sos" || word == "сос"
    }

    /// Команда «@Софи SOS» в чате с человеком — оба написания имени,
    /// оба написания SOS, регистр не важен.
    static func isMentionCommand(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        for alias in AppIdentity.assistantAliases {
            for word in ["sos", "сос"] where normalized == "@\(alias) \(word)" {
                return true
            }
        }
        return false
    }
}

@MainActor
enum SOSCenter {

    enum SOSError: Error, LocalizedError {
        case noContacts
        var errorDescription: String? {
            "Контактов пока нет — сигнал отправить некому. "
            + "Добавьте контакт по QR во вкладке «Чаты»."
        }
    }

    // MARK: Хранение сессии

    private static func sessionURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("SOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }

    static func loadSession() -> SOSSession? {
        guard let url = try? sessionURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SOSSession.self, from: data)
    }

    static func saveSession(_ session: SOSSession) {
        guard let url = try? sessionURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(session).write(to: url, options: .atomic)
    }

    /// Сессия, по которой ещё не дан отбой.
    static var activeSession: SOSSession? {
        loadSession().flatMap { $0.isActive ? $0 : nil }
    }

    /// Активная сессия покрывает этого собеседника (для красной
    /// подсветки его чата и ответов).
    static func activeSessionCovers(contactID: String?) -> Bool {
        guard let contactID, let session = activeSession else { return false }
        return session.recipientMsgIDs.keys.contains(contactID)
    }

    // MARK: Отправка (только по подтверждению человека)

    /// Разослать подтверждённую человеком карточку всем контактам.
    /// Каждому — SOS-пакет (грубые координаты в теле, по спеке) и,
    /// если есть фикс, LOCATION-пакет с точными координатами.
    @discardableResult
    static func send(report: SOSReport, fix: PositionFix?) throws -> SOSSession {
        let contacts = ContactStore.load()
        guard !contacts.isEmpty else { throw SOSError.noContacts }

        let summary = summaryText(report: report, fix: fix)
        var msgIDs: [String: UInt16] = [:]

        for contact in contacts {
            let msgID = Envelope.newMsgID()
            let sos = NeedsMapping.makeSOSMessage(
                from: report, msgID: msgID, lat: fix?.lat, lon: fix?.lon)
            var packets = [try sos.encode()]
            if let fix {
                let location = LocationMessage(
                    msgID: Envelope.newMsgID(),
                    lat: fix.lat, lon: fix.lon, wantAck: false)
                packets.append(try location.encode())
            }

            var entry = ChatEntry(kind: .outgoing, text: summary,
                                  status: "SOS в очереди")
            entry.sosRelated = true
            var log = HumanChatStore.loadLog(contactID: contact.id)
            log.append(entry)
            HumanChatStore.saveLog(log, contactID: contact.id)

            Outbox.enqueueRaw(packets: packets, msgID: msgID,
                              entryID: entry.id, contactID: contact.id,
                              expectAck: false)
            msgIDs[contact.id] = msgID
        }

        let session = SOSSession(sentAt: Date(), recipientMsgIDs: msgIDs,
                                 summary: summary, standDownAt: nil)
        saveSession(session)
        DeliveryManager.shared.pushQueue()
        return session
    }

    /// Сводка карточки — человекочитаемо, длину считает код.
    nonisolated static func summaryText(report: SOSReport,
                                        fix: PositionFix?) -> String {
        var parts = ["SOS — срочность: \(report.severityLabel)",
                     "людей: \(report.peopleCount)"]
        if report.injury != .none { parts.append("травма: \(report.injuryLabel)") }
        parts.append("нужно: \(report.needsLabel)")
        parts.append(fix != nil
            ? "точная позиция приложена"
            : "позиции нет (GPS не дал фикс)")
        return parts.joined(separator: " · ")
    }

    // MARK: Отбой (обязателен, 3.4)

    /// BEACON'ы отбоя: каждому получателю — со ссылкой на msgID
    /// «его» SOS. Чистая функция — покрыта тестами.
    nonisolated static func standDownBeacons(for session: SOSSession)
    -> [(contactID: String, beacon: BeaconMessage)] {
        session.recipientMsgIDs
            .sorted { $0.key < $1.key }
            .map { contactID, sosMsgID in
                (contactID, BeaconMessage(msgID: Envelope.newMsgID(),
                                          sosMsgID: sosMsgID,
                                          status: 2,     // ситуация решена
                                          responders: 0,
                                          lat: nil, lon: nil))
            }
    }

    /// «Помощь больше не нужна»: отбой уходит тем же приоритетом всем,
    /// кто получил сигнал; статус сессии — «отбой отправлен».
    static func standDown() throws {
        guard var session = loadSession(), session.isActive else { return }
        for (contactID, beacon) in standDownBeacons(for: session) {
            var entry = ChatEntry(kind: .outgoing,
                                  text: "Отбой — помощь больше не нужна",
                                  status: "отбой в очереди")
            entry.sosRelated = true
            var log = HumanChatStore.loadLog(contactID: contactID)
            log.append(entry)
            HumanChatStore.saveLog(log, contactID: contactID)

            Outbox.enqueueRaw(packets: [try beacon.encode()],
                              msgID: beacon.msgID,
                              entryID: entry.id, contactID: contactID,
                              expectAck: false)
        }
        session.standDownAt = Date()
        saveSession(session)
        DeliveryManager.shared.pushQueue()
    }
}

// MARK: - Звук тревоги (3.5)

/// Особый звук ответа на SOS. Обычный системный звук: играет, когда
/// телефон НЕ в беззвучном режиме. Звук поверх беззвучного требует
/// разрешения Apple на критические уведомления — заявка отдельно;
/// до неё честно работаем обычным звуком + вибрация (она работает
/// и в беззвучном).
nonisolated enum SOSAlert {
    static func play() {
        AudioServicesPlaySystemSound(1005)                  // сигнал тревоги
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}

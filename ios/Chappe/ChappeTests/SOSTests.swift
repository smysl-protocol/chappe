//
//  SOSTests.swift
//  RMTests
//
//  Ф3 (задание 30.07): команда SOS — явное действие, не классификатор;
//  отбой — BEACON со статусом «решена» каждому получателю; сводка честная.
//

import Foundation
import Testing
@testable import Chappe

struct SOSCommandTests {

    /// Слово-команда: оба алфавита, любой регистр, обрезка пробелов.
    @Test func commandWordBothAlphabetsAnyCase() {
        #expect(SOSCommand.isCommand("sos"))
        #expect(SOSCommand.isCommand("SOS"))
        #expect(SOSCommand.isCommand(" Sos "))
        #expect(SOSCommand.isCommand("сос"))
        #expect(SOSCommand.isCommand("СОС"))
    }

    /// НЕ классификатор (правило №9): любой текст, кроме точной
    /// команды, — не SOS. Мирный рассказ живой тест уже принимал за
    /// сигнал — этой дорогой не ходим.
    @Test func arbitraryTextIsNeverCommand() {
        #expect(!SOSCommand.isCommand("мы отлично сходили в поход"))
        #expect(!SOSCommand.isCommand("sos123"))
        #expect(!SOSCommand.isCommand("у нас всё сос едом"))
        #expect(!SOSCommand.isCommand("нужна помощь с лодкой"))
        #expect(!SOSCommand.isCommand(""))
    }

    /// «@Софи SOS» в чате с человеком: оба написания имени, оба
    /// написания SOS, регистр и лишние пробелы не важны.
    @Test func mentionCommandBothSpellings() {
        #expect(SOSCommand.isMentionCommand("@Софи SOS"))
        #expect(SOSCommand.isMentionCommand("@софи сос"))
        #expect(SOSCommand.isMentionCommand("@Sophie SOS"))
        #expect(SOSCommand.isMentionCommand("@SOPHIE sos"))
        #expect(SOSCommand.isMentionCommand("  @Софи   SOS  "))
        // а вот это — не команда
        #expect(!SOSCommand.isMentionCommand("@Софи привет"))
        #expect(!SOSCommand.isMentionCommand("@Мария SOS"))
        #expect(!SOSCommand.isMentionCommand("Софи SOS"))
        #expect(!SOSCommand.isMentionCommand("@Софи SOS завтра"))
    }
}

struct SOSStandDownTests {

    /// Отбой: каждому получателю — BEACON со статусом «ситуация решена»
    /// (2) и ссылкой на msgID ЕГО SOS-пакета; кодируется и разбирается
    /// обратно замороженным конвертом.
    @Test func standDownBeaconsReferenceEachRecipientsSOS() throws {
        let session = SOSSession(
            sentAt: Date(),
            recipientMsgIDs: ["contactA": 0x3BA7, "contactB": 0x1122],
            summary: "SOS — тест",
            standDownAt: nil)
        let beacons = SOSCenter.standDownBeacons(for: session)
        #expect(beacons.count == 2)
        #expect(beacons.map(\.contactID).sorted() == ["contactA", "contactB"])
        for (contactID, beacon) in beacons {
            #expect(beacon.status == 2, "отбой — всегда «ситуация решена»")
            #expect(beacon.sosMsgID == session.recipientMsgIDs[contactID])
            // roundtrip через конверт
            let packet = try beacon.encode()
            let header = try Envelope.decodeHeader(packet)
            #expect(header.msgClass == Envelope.classBeacon)
            let decoded = try BeaconMessage.decodeBody(flags: header.flags,
                                                       msgID: header.msgID,
                                                       packet: packet)
            #expect(decoded.status == 2)
            #expect(decoded.sosMsgID == beacon.sosMsgID)
        }
    }

    /// Сессия: активна до отбоя, после — нет; переживает сериализацию.
    @Test func sessionLifecycle() throws {
        var session = SOSSession(sentAt: Date(),
                                 recipientMsgIDs: ["c": 7],
                                 summary: "s", standDownAt: nil)
        #expect(session.isActive)
        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(SOSSession.self, from: data)
        #expect(restored == session)
        session.standDownAt = Date()
        #expect(!session.isActive)
    }

    /// Сводка честная: нет фикса — так и написано, ничего не выдумано.
    @Test func summaryIsHonestAboutMissingFix() {
        let report = SOSReport(type: .sos, severity: .critical,
                               peopleCount: 3, injury: .bleeding,
                               needs: [.bandages, .boat])
        let without = SOSCenter.summaryText(report: report, fix: nil)
        #expect(without.contains("позиции нет"))
        #expect(without.contains("критично"))
        #expect(without.contains("бинты"))
        let fix = PositionFix(lat: 8.71, lon: 115.17,
                              horizontalAccuracy: 5,
                              timestamp: Date(), source: .own,
                              precision: .exact)
        let with = SOSCenter.summaryText(report: report, fix: fix)
        #expect(with.contains("точная позиция приложена"))
    }

    /// Старые записи чата без поля sosRelated читаются как обычные.
    @Test func chatEntryWithoutSOSFieldDecodes() throws {
        let old = #"{"id":"6F1C1A3E-2B10-4B5A-9E3C-000000000003","kind":"incoming","text":"привет","date":770000000}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entry = try decoder.decode(ChatEntry.self, from: Data(old.utf8))
        #expect(!entry.isSOSRelated)
    }
}

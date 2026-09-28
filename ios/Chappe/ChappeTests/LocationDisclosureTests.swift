//
//  LocationDisclosureTests.swift
//  RMTests
//
//  Злые тесты единственной двери (WP4): без гранта — отказ; истёкший —
//  отказ; .coarse — в байтах нет точных координат; отзыв мгновенный.
//  Гранты и очередь Outbox персистентные, поэтому каждый тест прибирает
//  за собой (snapshot очереди + revoke своих грантов).
//

import Foundation
import CryptoKit
import Testing
@testable import Chappe

/// Уникальные ID, чтобы тесты не пересекались с реальными данными и друг
/// с другом при параллельном прогоне.
private func freshID(_ tag: String) -> String { "test-\(tag)-\(UUID().uuidString.prefix(8))" }

private let t0 = Date(timeIntervalSince1970: 1_753_700_000)

private func fix(lat: Double = 36.1408, lon: Double = -5.3536,
                 accuracy: Double = 8, at: Date = t0) -> PositionFix {
    PositionFix(lat: lat, lon: lon, horizontalAccuracy: accuracy,
                timestamp: at, source: .own, precision: .exact)
}

@Suite(.serialized)
struct LocationDisclosureTests {

    // MARK: Дверь заперта по умолчанию

    @Test func noGrantMeansNoDisclosure() {
        let storage = MemoryGrantStorage()
        let id = freshID("nogrant")
        #expect(throws: DisclosureError.noGrant(contactID: id)) {
            _ = try LocationDisclosurePolicy.disclose(fix(), to: id, now: t0,
                                                      storage: storage)
        }
    }

    @Test func expiredGrantIsRefused() {
        let storage = MemoryGrantStorage()
        let id = freshID("expired")
        LocationDisclosurePolicy.grant(to: id, precision: .exact,
                                       ttlSeconds: 4 * 3600, now: t0,
                                       storage: storage)
        // Подкрутка времени: 4 часа и 1 секунда спустя
        let later = t0.addingTimeInterval(4 * 3600 + 1)
        #expect(throws: DisclosureError.expired(contactID: id)) {
            _ = try LocationDisclosurePolicy.disclose(fix(), to: id, now: later,
                                                      storage: storage)
        }
        // Ровно на границе TTL — тоже отказ (полуинтервал [granted, expires))
        let boundary = t0.addingTimeInterval(4 * 3600)
        #expect(throws: DisclosureError.expired(contactID: id)) {
            _ = try LocationDisclosurePolicy.disclose(fix(), to: id, now: boundary,
                                                      storage: storage)
        }
    }

    @Test func revokeIsImmediate() throws {
        let storage = MemoryGrantStorage()
        let id = freshID("revoke")
        LocationDisclosurePolicy.grant(to: id, precision: .exact,
                                       ttlSeconds: 3600, now: t0,
                                       storage: storage)
        _ = try LocationDisclosurePolicy.disclose(fix(), to: id,
                                                  now: t0.addingTimeInterval(60),
                                                  storage: storage)
        // Отзыв во время активной сессии → следующий маячок не уходит
        LocationDisclosurePolicy.revoke(contactID: id, storage: storage)
        #expect(throws: DisclosureError.noGrant(contactID: id)) {
            _ = try LocationDisclosurePolicy.disclose(
                fix(), to: id, now: t0.addingTimeInterval(120),
                storage: storage)
        }
    }

    // MARK: Точность — часть гранта, загрубление при кодировании

    @Test func exactGrantEncodesExactBytes() throws {
        let storage = MemoryGrantStorage()
        let id = freshID("exact")
        LocationDisclosurePolicy.grant(to: id, precision: .exact,
                                       ttlSeconds: 3600, now: t0,
                                       storage: storage)
        let d = try LocationDisclosurePolicy.disclose(fix(), to: id, now: t0,
                                                      storage: storage)
        #expect(d.payload == (try PositionCodec.encode(lat: 36.1408, lon: -5.3536)))
        #expect(d.precision == .exact)
        #expect(d.measuredAt == t0)
    }

    @Test func coarseBytesContainNoExactCoordinates() throws {
        let storage = MemoryGrantStorage()
        let id = freshID("coarse")
        LocationDisclosurePolicy.grant(to: id,
                                       precision: .coarse(geohashLength: 5),
                                       ttlSeconds: 3600, now: t0,
                                       storage: storage)
        let exact = fix()
        let d = try LocationDisclosurePolicy.disclose(exact, to: id, now: t0,
                                                      storage: storage)

        // В эфир уходит центр ячейки, не исходная точка
        let cell = Geohash.cell(lat: exact.lat, lon: exact.lon, length: 5)
        #expect(d.payload == (try PositionCodec.encode(lat: cell.centerLat,
                                                       lon: cell.centerLon)))
        #expect(d.payload != (try PositionCodec.encode(lat: exact.lat,
                                                       lon: exact.lon)))

        // Восстановить точность из байтов невозможно: декодированная точка
        // отстоит от истинной на сотни метров (уровень 5 ≈ 4.9 км)
        let (dlat, dlon) = try PositionCodec.decode(d.payload)
        let drift = GeoMath.distanceMeters(lat1: exact.lat, lon1: exact.lon,
                                           lat2: dlat, lon2: dlon)
        #expect(drift > 200)
    }

    @Test func regrantReplacesPrecisionAndTTL() throws {
        let storage = MemoryGrantStorage()
        let id = freshID("regrant")
        LocationDisclosurePolicy.grant(to: id, precision: .exact,
                                       ttlSeconds: 3600, now: t0,
                                       storage: storage)
        LocationDisclosurePolicy.grant(to: id,
                                       precision: .coarse(geohashLength: 4),
                                       ttlSeconds: 60, now: t0,
                                       storage: storage)
        let d = try LocationDisclosurePolicy.disclose(fix(), to: id, now: t0,
                                                      storage: storage)
        #expect(d.precision == .coarse(geohashLength: 4))
        // одна запись на контакт, не две
        #expect(storage.load().filter { $0.contactID == id }.count == 1)
    }

    // MARK: Очередь принимает координаты только через дверь (шов п.5)

    // ПЕРЕСМОТРЕН 14.08 (мега-4, подпись шва п.6): позиция больше НЕ
    // ходит открытым классом 0x5 — едет внутренним кодеком 7 sealed-
    // путём, собеседник обязан подтвердить рев B.
    @MainActor
    @Test func transportSendBuildsCanonicalPacket() throws {
        let storage = MemoryGrantStorage()
        let snapshot = Outbox.loadQueueRaw()
        defer { Outbox.saveQueueRaw(snapshot) }   // не засоряем реальную очередь

        let peerPriv = Curve25519.KeyAgreement.PrivateKey()
        let id = Identity.fingerprint(of: peerPriv.publicKey)
        ContactStore.upsert(Contact(
            id: id, name: "Гео-пир",
            publicKeyBase64: peerPriv.publicKey.rawRepresentation
                .base64EncodedString(),
            addedAt: t0, verified: false))
        PeerCaps.markRevB(contactID: id)
        defer {
            ContactStore.remove(id: id)
            PeerCaps.purge(contactID: id)
            SeqStore.purge(contactID: id)
            HumanChatStore.saveLog([], contactID: id)
        }

        LocationDisclosurePolicy.grant(to: id, precision: .exact,
                                       ttlSeconds: 3600, now: t0,
                                       storage: storage)
        let d = try LocationDisclosurePolicy.disclose(fix(), to: id, now: t0,
                                                      storage: storage)
        let entryID = UUID()
        // contacts.json общий у параллельных сюит (shared_test_state):
        // чужой read-modify-write может стереть свежий контакт между
        // upsert и send — ре-апсерт с повтором держит замок устойчивым
        var sent = false
        for _ in 0..<3 where !sent {
            ContactStore.upsert(Contact(
                id: id, name: "Гео-пир",
                publicKeyBase64: peerPriv.publicKey.rawRepresentation
                    .base64EncodedString(),
                addedAt: t0, verified: false))
            PeerCaps.markRevB(contactID: id)
            sent = LocationTransport.shared.send(d, entryID: entryID,
                                                 pushImmediately: false)
        }
        #expect(sent)

        let queued = try #require(Outbox.loadQueueRaw()
            .first { $0.entryID == entryID })
        #expect(queued.contactID == id)
        #expect(queued.positionBeacon == true, "маячок помечен для вытеснения")
        #expect(queued.expectsAck == false, "маячок не аккается (подпись)")
        // координат ОТКРЫТЫМ классом 0x5 в эфире больше нет
        let packet = Outbox.bytes(fromHex: queued.packetsHex.first ?? "")
        if let header = try? Envelope.decodeHeader(packet) {
            #expect(header.msgClass != Envelope.classLocation, Comment(
                rawValue: "позиция обязана ехать sealed-путём, не 0x5"))
        }
        // содержимое — sealed2 с внутренним кодеком 7 (вскрываем как пир)
        let stream = Outbox.bytes(fromHex: queued.relayStreamHex ?? "")
        let opened = try E2ESeal2.open(
            sealed: stream, identity: peerPriv,
            senderPub: try #require(Identity.publicKey()))
        let prefix = try RevBPrefix.decode(opened)
        #expect(prefix.innerCodec == EnvelopeRevB.codecPosition)
        let pos = try PositionPayload.decode([prefix.innerCodec] + prefix.data)
        #expect(abs(pos.lat - fix().lat) < 0.001)
    }

    @MainActor
    @Test func newBeaconReplacesUndeliveredOne() throws {
        // Нет истории перемещений: в очереди максимум ОДНА позиция на
        // контакт — новый недоставленный маячок вытесняет старый.
        // Пересмотрен 14.08: очередь несёт sealed-маячки (кодек 7).
        let storage = MemoryGrantStorage()
        let snapshot = Outbox.loadQueueRaw()
        defer { Outbox.saveQueueRaw(snapshot) }

        let peerPriv = Curve25519.KeyAgreement.PrivateKey()
        let id = Identity.fingerprint(of: peerPriv.publicKey)
        ContactStore.upsert(Contact(
            id: id, name: "Гео-вытеснение",
            publicKeyBase64: peerPriv.publicKey.rawRepresentation
                .base64EncodedString(),
            addedAt: t0, verified: false))
        PeerCaps.markRevB(contactID: id)
        defer {
            ContactStore.remove(id: id)
            PeerCaps.purge(contactID: id)
            SeqStore.purge(contactID: id)
            HumanChatStore.saveLog([], contactID: id)
        }

        LocationDisclosurePolicy.grant(to: id, precision: .exact,
                                       ttlSeconds: 3600, now: t0,
                                       storage: storage)
        let first = try LocationDisclosurePolicy.disclose(
            fix(lat: 36.01, lon: -5.60), to: id, now: t0, storage: storage)
        let second = try LocationDisclosurePolicy.disclose(
            fix(lat: 36.02, lon: -5.61), to: id,
            now: t0.addingTimeInterval(600), storage: storage)
        // та же гонка contacts.json — ре-апсерт с повтором
        func sendResilient(_ d: DisclosedPosition) -> Bool {
            for _ in 0..<3 {
                ContactStore.upsert(Contact(
                    id: id, name: "Гео-вытеснение",
                    publicKeyBase64: peerPriv.publicKey.rawRepresentation
                        .base64EncodedString(),
                    addedAt: t0, verified: false))
                PeerCaps.markRevB(contactID: id)
                if LocationTransport.shared.send(d, pushImmediately: false) {
                    return true
                }
            }
            return false
        }
        #expect(sendResilient(first))
        #expect(sendResilient(second))

        let mine = Outbox.loadQueueRaw().filter {
            $0.contactID == id && $0.positionBeacon == true
        }
        #expect(mine.count == 1, "в очереди ровно одна позиция на контакт")
        // и это именно вторая (свежая) позиция — вскрываем как пир
        let stream = Outbox.bytes(fromHex: mine.first?.relayStreamHex ?? "")
        let opened = try E2ESeal2.open(
            sealed: stream, identity: peerPriv,
            senderPub: try #require(Identity.publicKey()))
        let prefix = try RevBPrefix.decode(opened)
        let pos = try PositionPayload.decode([prefix.innerCodec] + prefix.data)
        #expect(abs(pos.lat - 36.02) < 0.001, Comment(rawValue:
                "остаться обязана СВЕЖАЯ позиция — старая вытеснена"))
    }

    @MainActor
    @Test func transportIngestAttributesOnlyWithSingleContact() {
        let store = PeerPositionStore(persisted: false)
        let contact1 = Contact(id: "c1", name: "Сергей",
                               publicKeyBase64: "", addedAt: t0)
        let contact2 = Contact(id: "c2", name: "Анна",
                               publicKeyBase64: "", addedAt: t0)
        let packet = (try? Envelope.encodeHeader(msgClass: Envelope.classLocation,
                                                 flags: Envelope.flagHasCoords,
                                                 msgID: 7)
                      + Envelope.encodeFineCoords(lat: 36.01, lon: -5.60)) ?? []
        let header = (msgClass: Envelope.classLocation,
                      flags: Envelope.flagHasCoords, msgID: UInt16(7))

        // один контакт → позиция атрибутирована
        #expect(LocationTransport.shared.ingest(packet: packet, header: header,
                                                receivedAt: t0,
                                                contacts: [contact1],
                                                store: store))
        #expect(store.position(for: "c1") != nil)

        // несколько контактов → честный отказ, не угадывание
        let store2 = PeerPositionStore(persisted: false)
        #expect(!LocationTransport.shared.ingest(packet: packet, header: header,
                                                 receivedAt: t0,
                                                 contacts: [contact1, contact2],
                                                 store: store2))
        #expect(store2.positions.isEmpty)
    }

    // MARK: Индикатор активных грантов

    @Test func activeGrantsReflectTTL() {
        let storage = MemoryGrantStorage()
        let id = freshID("indicator")
        LocationDisclosurePolicy.grant(to: id, precision: .exact,
                                       ttlSeconds: 100, now: t0,
                                       storage: storage)
        let active = LocationDisclosurePolicy.activeGrants(
            now: t0.addingTimeInterval(50), storage: storage)
        #expect(active.contains { $0.contactID == id })
        #expect(active.first { $0.contactID == id }?
            .remainingSeconds(now: t0.addingTimeInterval(50)) == 50)
        let gone = LocationDisclosurePolicy.activeGrants(
            now: t0.addingTimeInterval(101), storage: storage)
        #expect(!gone.contains { $0.contactID == id })
    }
}

// MARK: - Хранилище позиций собеседников

@MainActor
struct PeerPositionStoreTests {

    @Test func ingestStoresLastFixPerContact() {
        let store = PeerPositionStore(persisted: false)
        let id = "peer-1"
        #expect(store.ingest(contactID: id, lat: 10.0, lon: 20.0, receivedAt: t0))
        #expect(store.ingest(contactID: id, lat: 11.0, lon: 21.0,
                             receivedAt: t0.addingTimeInterval(60)))
        // хранится ровно последний фикс
        let fix = store.position(for: id)
        #expect(fix?.lat == 11.0)
        #expect(fix?.timestamp == t0.addingTimeInterval(60))
        #expect(fix?.source == .peer(id))
    }

    @Test func ingestRejectsGarbageCoordinates() {
        let store = PeerPositionStore(persisted: false)
        #expect(!store.ingest(contactID: "x", lat: 91, lon: 0, receivedAt: t0))
        #expect(!store.ingest(contactID: "x", lat: 0, lon: 181, receivedAt: t0))
        #expect(store.position(for: "x") == nil)
    }

    @Test func removeForgetsContact() {
        let store = PeerPositionStore(persisted: false)
        store.ingest(contactID: "y", lat: 1, lon: 2, receivedAt: t0)
        store.removePosition(for: "y")
        #expect(store.position(for: "y") == nil)
    }
}

import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Веха, фаза 3: sealed-очередь → рамка envelope → расшифровка
// получателем (сквозной путь без сети) + LanLink через локальный TCP.
// ============================================================================

struct TransportTests {

    /// Полный путь: enqueueSealed → пакеты → сборка → open → развёртка.
    @Test @MainActor func sealedQueueRoundtrip() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let contact = Contact(
            id: Identity.fingerprint(of: recipient.publicKey),
            name: "Тест-узел",
            publicKeyBase64: recipient.publicKey.rawRepresentation
                .base64EncodedString(),
            addedAt: Date())
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let units = matcher.units(fromPivot: "be there soon in 10 minutes",
                                  allowProtected: false)
        let blob = codec.wireBlob(try codec.encode(units))   // wire: [хеш][блоб]

        let entryID = UUID()
        let queued = try Outbox.enqueueSealed(innerCodec: Envelope.codecSemantic,
                                              data: blob, to: contact,
                                              entryID: entryID)
        defer {   // не сорить в очередь тестового хоста
            Outbox.saveQueueRaw(Outbox.loadQueueRaw()
                .filter { $0.entryID != entryID })
        }
        #expect(queued.contactID == contact.id)

        // собрать payload из пакетов (с фрагментами, если были)
        let packets = queued.packetsHex.map(Outbox.bytes(fromHex:))
        var payload: [UInt8] = []
        for packet in packets {
            let header = try Envelope.decodeHeader(packet)
            var body = Array(packet[Envelope.headerSize...])
            if header.flags & Envelope.flagFragmented != 0 {
                body = Array(body.dropFirst(2))
            }
            payload += body
        }
        // v1 (Ф5): первые 4 байта потока — метка отправки
        payload = Array(payload.dropFirst(4))
        #expect(payload.first == E2ESeal.codecSealed,
                "на проводе — только sealed, плейнтекста нет")
        // в шифртексте не должно быть сырого блоба
        #expect(!payload.dropFirst().starts(with: blob))

        let opened = try E2ESeal.open(sealed: payload, identity: recipient)
        let senderPub = try #require(Identity.publicKey())
        #expect(Array(opened[0..<32]) == Array(senderPub.rawRepresentation),
                "внутри — pubkey отправителя")
        #expect(opened[32] == Envelope.codecSemantic)
        #expect(Array(opened[33...]) == blob)
        let text = try TextCodec.decompress(Array(opened[33...]),
                                            codec: Envelope.codecSemantic)
        #expect(text.contains("10"), "развёртка: \(text)")
    }

    /// LanLink: локальный TCP — кадр доходит байт в байт.
    @Test func lanLinkLoopbackDelivers() async throws {
        let port = UInt16.random(in: 40000..<60000)
        let link = LanLink(port: port)
        defer { link.stop() }

        let received = ReceivedBox()
        link.onReceive = { packet in received.set(packet) }
        link.start()
        try await Task.sleep(for: .milliseconds(300))   // listener поднялся

        let packet: [UInt8] = Array(0..<200)
        let outcome = OutcomeBox()
        link.send(packet, toHost: "127.0.0.1") { ok in outcome.set(ok) }

        for _ in 0..<50 {
            if received.get() != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(received.get() == packet, "кадр обязан дойти байт в байт")
        #expect(outcome.get() == true, "успешная передача — completion(true)")
    }

    /// Честное «отправлено»: никто не слушает — completion(false).
    @Test func lanLinkReportsFailureWhenNobodyListens() async throws {
        let port = UInt16.random(in: 40000..<60000)
        let link = LanLink(port: port)   // start() НЕ зовём — порт мёртв

        let outcome = OutcomeBox()
        link.send([1, 2, 3], toHost: "127.0.0.1") { ok in outcome.set(ok) }

        for _ in 0..<70 {
            if outcome.get() != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(outcome.get() == false,
                "мёртвый адресат обязан дать completion(false), не молчание")
    }

    /// Бэкофф повторов: растёт и упирается в потолок 60 с.
    @Test func retryBackoffGrowsToCap() {
        #expect(DeliveryManager.retryDelay(afterAttempts: 1) == 4)
        #expect(DeliveryManager.retryDelay(afterAttempts: 2) == 8)
        #expect(DeliveryManager.retryDelay(afterAttempts: 3) == 16)
        #expect(DeliveryManager.retryDelay(afterAttempts: 4) == 32)
        #expect(DeliveryManager.retryDelay(afterAttempts: 5) == 60)
        #expect(DeliveryManager.retryDelay(afterAttempts: 99) == 60)
    }

    /// Срок повтора: первая попытка сразу; свежая попытка — ждём бэкофф;
    /// отлежавшаяся — снова в канал.
    @Test func retryDueRespectsBackoff() {
        var item = Outbox.QueuedMessage(entryID: UUID(), msgID: 7,
                                        packetsHex: [], totalBytes: 0,
                                        contactID: "X")
        let now = Date()
        #expect(DeliveryManager.isDue(item, now: now), "новое — сразу")
        item.attempts = 1
        item.lastAttemptAt = now
        #expect(!DeliveryManager.isDue(item, now: now.addingTimeInterval(1)),
                "1 с после попытки — рано (бэкофф 4 с)")
        #expect(DeliveryManager.isDue(item, now: now.addingTimeInterval(5)),
                "5 с после попытки — пора")
    }

    /// Дедуп входящих: дубль не проходит, кольцо не растёт бесконечно.
    @Test func seenMsgIDsDeduplicateAndCap() {
        var seen = SeenMsgIDs()
        let first = seen.insert(42)
        let second = seen.insert(42)
        #expect(first, "первый раз — свежий")
        #expect(!second, "второй раз — дубль")
        for id in 100..<200 { _ = seen.insert(UInt16(id)) }
        #expect(seen.ids.count == SeenMsgIDs.capacity, "кольцо ограничено")
        let evicted = seen.insert(42)
        #expect(evicted, "вытесненный из кольца снова свежий")
    }
}

/// Потокобезопасная коробка для исхода отправки.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Потокобезопасная коробка для принятого пакета.
private final class ReceivedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [UInt8]?
    func set(_ v: [UInt8]) { lock.lock(); value = v; lock.unlock() }
    func get() -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return value }
}

/// BLE-Ф1: фрагментация под MTU и сборка — чистые функции.
struct BleFragmentationTests {
    @Test func fragmentAndAssembleRoundTrip() {
        let blob: [UInt8] = Array(0..<200)
        let frags = BleLink.fragment(blob, mtu: 23, tag: 9)
        #expect(frags.count == 10, "200 Б при mtu 23 (20 полезных) → 10")
        #expect(frags.allSatisfy { $0.count <= 23 })
        var asm: [UInt8: (total: Int, chunks: [Int: [UInt8]])] = [:]
        var out: [UInt8]?
        for f in frags.shuffled() {                 // порядок любой
            out = BleLink.assemble(into: &asm, fragment: f) ?? out
        }
        #expect(out == blob, "сборка байт в байт")
    }

    @Test func duplicateAndForeignFragmentsAreSafe() {
        let blob: [UInt8] = Array(1...50)
        let frags = BleLink.fragment(blob, mtu: 23, tag: 3)
        var asm: [UInt8: (total: Int, chunks: [Int: [UInt8]])] = [:]
        _ = BleLink.assemble(into: &asm, fragment: frags[0])
        _ = BleLink.assemble(into: &asm, fragment: frags[0])   // дубль
        _ = BleLink.assemble(into: &asm, fragment: [7, 0, 1])  // чужой tag
        var out: [UInt8]?
        for f in frags.dropFirst() {
            out = BleLink.assemble(into: &asm, fragment: f) ?? out
        }
        #expect(out == blob)
    }
}

/// Ф3: мини-протобаф ToRadio/FromRadio — номера полей по mesh.proto
/// (сверено 29.07.2026), наш блоб внутри непрозрачными байтами.
struct MeshtasticProtoTests {
    @Test func toRadioRoundTripsThroughFromRadioParser() {
        let payload: [UInt8] = [1, 0, 1] + Array(10...80)
        let toRadio = MiniProto.toRadio(payload: payload, packetID: 4242)
        // мок узла «ретранслирует»: ToRadio.packet=1 → FromRadio.packet=2
        let mesh = MiniProto.fields(toRadio)[1]!.first!
        let fromRadio = MiniProto.lenField(2, mesh)
        let parsed = MiniProto.fromRadioPayload(fromRadio)
        #expect(parsed?.portnum == 256, "PRIVATE_APP из portnums.proto")
        #expect(parsed?.payload == payload, "блоб непрозрачен: байт в байт")
    }

    @Test func meshPacketCarriesIDAndWantAck() {
        let toRadio = MiniProto.toRadio(payload: [9, 9], packetID: 77)
        let mesh = MiniProto.fields(toRadio)[1]!.first!
        let f = MiniProto.fields(mesh)
        // to и id — fixed32 (wire 5), НЕ varint: с varint узел молча
        // выбрасывал пакет и в эфир не уходило ничего (живой тест 02.08).
        // Прежняя редакция теста закрепляла ошибку.
        func le32(_ bytes: [UInt8]) -> UInt32 {
            UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        }
        #expect(f[6]?.first.map(le32) == 77, "id — fixed32")
        #expect(f[10]?.first.flatMap { MiniProto.readVarint($0) } == 1,
                "want_ack: узел вернёт подтверждение")
        #expect(f[2]?.first.map(le32) == 0xFFFF_FFFF,
                "to = broadcast, fixed32")
    }

    @Test func foreignPortnumIsIgnoredByParser() {
        // чужой пакет (текстовый канал, portnum=1) — не наш блоб
        let dataMsg = MiniProto.varField(1, 1)
            + MiniProto.lenField(2, [104, 105])
        let mesh = MiniProto.lenField(4, dataMsg)
        let fromRadio = MiniProto.lenField(2, mesh)
        let parsed = MiniProto.fromRadioPayload(fromRadio)
        #expect(parsed?.portnum == 1, "portnum читается — фильтр выше")
    }

    @Test func varintBoundaries() {
        for v: UInt64 in [0, 1, 127, 128, 300, 0xFFFF_FFFF] {
            let enc = MiniProto.varint(v)
            #expect(MiniProto.readVarint(enc) == v)
        }
    }
}

/// Ф3: дьюти-цикл честный — бюджет режет отправку, окно скользящее.
struct AirtimeBudgetTests {
    @Test func budgetBlocksWhenSpent() {
        var b = AirtimeBudget(config: MeshConfig())
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var sent = 0
        while b.canSend(bytes: 200, now: t0) {
            b.record(bytes: 200, now: t0)
            sent += 1
            if sent > 1000 { break }
        }
        #expect(sent > 5 && sent < 100,
                "бюджет конечен и разумен: \(sent) пакетов")
        let blocked = !b.canSend(bytes: 200, now: t0)
        #expect(blocked, "потолок держит")
        // через час окно скользит — эфир снова наш
        let freed = b.canSend(bytes: 200,
                              now: t0.addingTimeInterval(3700))
        #expect(freed)
    }
}

/// Ф3: приоритет очереди — SOS (класс 0x1) раньше всего остального.
struct MeshPriorityTests {
    @Test func sosOutranksText() {
        let sos: [UInt8] = [0x11, 0, 1, 2]      // версия 1, класс SOS
        let text: [UInt8] = [0x12, 0, 3, 4]     // класс TEXT
        #expect(MeshtasticLink.priority(of: sos)
                < MeshtasticLink.priority(of: text))
    }
}

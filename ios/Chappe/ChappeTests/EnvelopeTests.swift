//
//  EnvelopeTests.swift
//  RMTests
//
//  Главный критерий готовности Swift-кодека: побайтовое совпадение
//  с общими тест-векторами tests/envelope_test_vectors.json — теми же,
//  что проходит Python-реализация (sim/envelope.py). Плюс round-trip
//  каждого класса, сборщик фрагментов и сверка needs-маппинга
//  с tests/needs_mapping.json.
//

import Foundation
import Testing
@testable import Chappe

// MARK: - Загрузка общих файлов из репозитория

/// Тесты гоняются на Маке (симулятор), поэтому файлы репозитория доступны
/// напрямую: путь строится от этого исходника (#filePath).
private func repoFile(_ relative: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)          // .../ios/RM/RMTests/EnvelopeTests.swift
        .deletingLastPathComponent()                    // RMTests
        .deletingLastPathComponent()                    // RM
        .deletingLastPathComponent()                    // ios
        .deletingLastPathComponent()                    // корень репозитория
    return try Data(contentsOf: root.appendingPathComponent(relative))
}

private func hexBytes(_ hex: String) -> [UInt8] {
    let clean = hex.replacingOccurrences(of: " ", with: "")
    var out: [UInt8] = []
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

// Разобранный файл векторов
private struct Vectors {
    let json: [String: Any]
    var packets: [[String: Any]] { json["packets"] as! [[String: Any]] }
    var coarse: [[String: Any]] { json["coarse_coords"] as! [[String: Any]] }
    var fine: [[String: Any]] { json["fine_coords"] as! [[String: Any]] }
    var needsMasks: [[String: Any]] { json["needs_masks"] as! [[String: Any]] }

    static func load() throws -> Vectors {
        let data = try repoFile("tests/envelope_test_vectors.json")
        return Vectors(json: try JSONSerialization.jsonObject(with: data) as! [String: Any])
    }
}

private func msgID(_ fields: [String: Any], _ key: String = "msg_id_hex") -> UInt16 {
    UInt16(fields[key] as! String, radix: 16)!
}

/// Собирает сообщение из полей вектора и кодирует. nil — если direction=decode.
private func encodeVector(_ vector: [String: Any]) throws -> [UInt8]? {
    if vector["direction"] as? String == "decode" { return nil }
    let fields = vector["fields"] as! [String: Any]
    let cls = vector["class"] as! String

    switch cls {
    case "SOS":
        var msg = SOSMessage(msgID: msgID(fields),
                             severity: fields["severity"] as! Int,
                             peopleCount: fields["people_count"] as! Int,
                             injury: fields["injury"] as! Int,
                             hopsLeft: fields["hops_left"] as! Int)
        msg.needs = Set(fields["needs"] as! [Int])
        msg.lat = fields["lat"] as? Double
        msg.lon = fields["lon"] as? Double
        msg.textTail = fields["text_tail"] as? String
        msg.tailCodec = UInt8(fields["tail_codec"] as? Int ?? 0)
        return try msg.encode()
    case "ACK":
        return AckMessage(msgID: msgID(fields),
                          ackMsgID: msgID(fields, "ack_msg_id_hex")).encode()
    case "BEACON":
        return try BeaconMessage(msgID: msgID(fields),
                                 sosMsgID: msgID(fields, "sos_msg_id_hex"),
                                 status: fields["status"] as! Int,
                                 responders: fields["responders"] as! Int,
                                 lat: fields["lat"] as? Double,
                                 lon: fields["lon"] as? Double).encode()
    case "LOCATION":
        return try LocationMessage(msgID: msgID(fields),
                                   lat: fields["lat"] as? Double,
                                   lon: fields["lon"] as? Double,
                                   wantAck: fields["want_ack"] as? Bool ?? false).encode()
    case "TEXT":
        let packets = try TextEncoder.encode(msgID: msgID(fields),
                                             text: fields["text"] as! String,
                                             codec: UInt8(fields["codec"] as? Int ?? 0),
                                             wantAck: fields["want_ack"] as? Bool ?? false,
                                             sentAtMinutes: 0)
        #expect(packets.count == 1, "вектор TEXT должен помещаться в один пакет")
        return packets[0]
    default:
        Issue.record("неизвестный класс вектора: \(cls)")
        return nil
    }
}

// MARK: - Тесты

struct EnvelopeVectorTests {

    /// ГЛАВНЫЙ ТЕСТ: каждый вектор кодируется в те же байты, что у Python.
    @Test func packetsEncodeByteForByte() throws {
        let vectors = try Vectors.load()
        for vector in vectors.packets {
            let name = vector["name"] as! String
            guard let encoded = try encodeVector(vector) else { continue }
            let expected = hexBytes(vector["bytes_hex"] as! String)
            #expect(encoded == expected,
                    "\(name): получилось \(hexString(encoded)), ожидалось \(hexString(expected))")
        }
    }

    /// Каждый вектор (включая decode-only) разбирается обратно в те же поля.
    @Test func packetsDecode() throws {
        let vectors = try Vectors.load()
        for vector in vectors.packets {
            let name = vector["name"] as! String
            let bytes = hexBytes(vector["bytes_hex"] as! String)
            let fields = vector["fields"] as! [String: Any]
            let message = try EnvelopeDecoder.decode(bytes)

            switch message {
            case .sos(let m):
                #expect(m.msgID == msgID(fields), "\(name): msgID")
                #expect(m.severity == fields["severity"] as! Int, "\(name): severity")
                #expect(m.peopleCount == fields["people_count"] as! Int, "\(name): people")
                #expect(m.injury == fields["injury"] as! Int, "\(name): injury")
                #expect(m.needs == Set(fields["needs"] as! [Int]), "\(name): needs")
                #expect(m.textTail == fields["text_tail"] as? String, "\(name): tail")
                #expect((m.lat != nil) == (fields["lat"] != nil), "\(name): наличие координат")
            case .ack(let m):
                #expect(m.msgID == msgID(fields), "\(name): msgID")
                #expect(m.ackMsgID == msgID(fields, "ack_msg_id_hex"), "\(name): ackMsgID")
            case .beacon(let m):
                #expect(m.msgID == msgID(fields), "\(name): msgID")
                #expect(m.sosMsgID == msgID(fields, "sos_msg_id_hex"), "\(name): sosMsgID")
                #expect(m.status == fields["status"] as! Int, "\(name): status")
                #expect(m.responders == fields["responders"] as! Int, "\(name): responders")
            case .location(let m):
                #expect(m.msgID == msgID(fields), "\(name): msgID")
                #expect(m.wantAck == (fields["want_ack"] as? Bool ?? false), "\(name): wantAck")
                #expect((m.lat != nil) == (fields["lat"] != nil), "\(name): наличие координат")
            case .text(let m):
                #expect(m.msgID == msgID(fields), "\(name): msgID")
                #expect(m.text == fields["text"] as! String, "\(name): text")
                #expect(m.wantAck == (fields["want_ack"] as? Bool ?? false), "\(name): wantAck")
            case .textFragment(let m):
                #expect(m.msgID == msgID(fields), "\(name): msgID")
                #expect(m.index == fields["index"] as! Int, "\(name): index")
                #expect(m.total == fields["total"] as! Int, "\(name): total")
                #expect(m.chunk == hexBytes(fields["chunk_hex"] as! String), "\(name): chunk")
            }
        }
    }

    /// Векторы координат: кодирование побайтово + обратное с допуском.
    @Test func coordinateVectors() throws {
        let vectors = try Vectors.load()
        for v in vectors.coarse {
            let name = v["name"] as! String
            let encoded = try Envelope.encodeCoarseCoords(lat: v["lat"] as! Double,
                                                          lon: v["lon"] as! Double)
            #expect(encoded == hexBytes(v["bytes_hex"] as! String), "грубые: \(name)")
            let (lat, lon) = Envelope.decodeCoarseCoords(encoded[0...])
            let tol = v["tolerance"] as! Double
            #expect(abs(lat - (v["decoded_lat"] as! Double)) <= tol, "грубые decode lat: \(name)")
            #expect(abs(lon - (v["decoded_lon"] as! Double)) <= tol, "грубые decode lon: \(name)")
        }
        for v in vectors.fine {
            let name = v["name"] as! String
            let encoded = try Envelope.encodeFineCoords(lat: v["lat"] as! Double,
                                                        lon: v["lon"] as! Double)
            #expect(encoded == hexBytes(v["bytes_hex"] as! String), "точные: \(name)")
            let (lat, lon) = Envelope.decodeFineCoords(encoded[0...])
            let tol = v["tolerance"] as! Double
            #expect(abs(lat - (v["decoded_lat"] as! Double)) <= tol, "точные decode lat: \(name)")
            #expect(abs(lon - (v["decoded_lon"] as! Double)) <= tol, "точные decode lon: \(name)")
        }
    }

    /// Векторы масок needs.
    @Test func needsMaskVectors() throws {
        let vectors = try Vectors.load()
        for v in vectors.needsMasks {
            let name = v["name"] as! String
            let needs = Set(v["needs"] as! [Int])
            let encoded = try Envelope.encodeNeeds(needs)
            #expect(encoded == hexBytes(v["bytes_hex"] as! String), "маска: \(name)")
            #expect(Envelope.decodeNeeds(encoded[0...]) == needs, "маска decode: \(name)")
        }
    }
}

struct EnvelopeRoundTripTests {

    /// Round-trip каждого класса: encode → decode → те же поля.
    @Test func sosRoundTrip() throws {
        let original = SOSMessage(msgID: 0x1234, severity: 2, peopleCount: 7,
                                  injury: 4, hopsLeft: 2, lat: 10.762, lon: 106.66,
                                  needs: [1, 5, 13], textTail: "за мостом",
                                  tailCodec: Envelope.codecStore)
        guard case .sos(let decoded) = try EnvelopeDecoder.decode(try original.encode()) else {
            Issue.record("SOS не распознался"); return
        }
        #expect(decoded.severity == original.severity)
        #expect(decoded.peopleCount == original.peopleCount)
        #expect(decoded.injury == original.injury)
        #expect(decoded.needs == original.needs)
        #expect(decoded.textTail == original.textTail)
        #expect(abs(decoded.lat! - original.lat!) < 0.005)   // грубые: ~300 м
        #expect(abs(decoded.lon! - original.lon!) < 0.005)
    }

    @Test func sosZlibTailRoundTrip() throws {
        let tail = String(repeating: "вода и лодка, быстрее! ", count: 4)
        let original = SOSMessage(msgID: 1, severity: 3, peopleCount: 1, injury: 1,
                                  needs: [0], textTail: tail,
                                  tailCodec: Envelope.codecZlib)
        guard case .sos(let decoded) = try EnvelopeDecoder.decode(try original.encode()) else {
            Issue.record("SOS не распознался"); return
        }
        #expect(decoded.textTail == tail)
        #expect(decoded.tailCodec == Envelope.codecZlib)
    }

    /// Принцип П5: слишком длинный хвост отбрасывается, но SOS уходит.
    @Test func sosLongTailDropped() throws {
        let original = SOSMessage(msgID: 2, severity: 3, peopleCount: 1, injury: 1,
                                  needs: [0], textTail: String(repeating: "х", count: 400))
        let packet = try original.encode()
        #expect(packet.count == 12, "хвост должен быть отброшен целиком")
        guard case .sos(let decoded) = try EnvelopeDecoder.decode(packet) else {
            Issue.record("SOS не распознался"); return
        }
        #expect(decoded.textTail == nil)
    }

    @Test func beaconRoundTrip() throws {
        let original = BeaconMessage(msgID: 5, sosMsgID: 0x3BA7, status: 1,
                                     responders: 4, lat: 8.71, lon: 115.17)
        guard case .beacon(let decoded) = try EnvelopeDecoder.decode(try original.encode()) else {
            Issue.record("BEACON не распознался"); return
        }
        #expect(decoded.sosMsgID == original.sosMsgID)
        #expect(decoded.status == original.status)
        #expect(decoded.responders == original.responders)
        #expect(abs(decoded.lat! - original.lat!) < 0.005)
    }

    @Test func ackRoundTrip() throws {
        let original = AckMessage(msgID: 7, ackMsgID: 0xABCD)
        guard case .ack(let decoded) = try EnvelopeDecoder.decode(original.encode()) else {
            Issue.record("ACK не распознался"); return
        }
        #expect(decoded == original)
    }

    @Test func locationRoundTrip() throws {
        let original = LocationMessage(msgID: 9, lat: -8.4095, lon: 115.1889, wantAck: true)
        guard case .location(let decoded) = try EnvelopeDecoder.decode(try original.encode()) else {
            Issue.record("LOCATION не распознался"); return
        }
        #expect(decoded.wantAck)
        #expect(abs(decoded.lat! - original.lat!) < 0.0001)  // точные: ~1-2 м
        #expect(abs(decoded.lon! - original.lon!) < 0.0001)
    }

    @Test func textSinglePacketRoundTrip() throws {
        let packets = try TextEncoder.encode(msgID: 11, text: "Привет, мир!", wantAck: true)
        #expect(packets.count == 1)
        guard case .text(let decoded) = try EnvelopeDecoder.decode(packets[0]) else {
            Issue.record("TEXT не распознался"); return
        }
        #expect(decoded.text == "Привет, мир!")
        #expect(decoded.wantAck)
    }

    /// Каноничность (ТВ-3): два вызова encode дают байт в байт одно и то же,
    /// как бы ни заполнялся набор needs.
    @Test func canonicalSerialization() throws {
        var a = SOSMessage(msgID: 0x3BA7, severity: 3, peopleCount: 3, injury: 1)
        a.needs = [0, 3]                     // порядок добавления...
        var b = SOSMessage(msgID: 0x3BA7, severity: 3, peopleCount: 3, injury: 1)
        b.needs = [3]; b.needs.insert(0)     // ...другой
        #expect(try a.encode() == b.encode())
    }
}

struct FragmentationTests {

    private let longText = String(repeating:
        "Тропа к водопаду размыта после ливня, переходить реку вброд опасно. ", count: 12)

    @Test func longTextFragmentsAndReassembles() throws {
        let packets = try TextEncoder.encode(msgID: 0x77A1, text: longText)
        #expect(packets.count > 1, "текст обязан порезаться")
        #expect(packets.allSatisfy { $0.count <= Envelope.maxPayload },
                "каждый фрагмент в лимите LoRa")

        // ТВ-4: перемешанный порядок + дубликат — собирается байт в байт.
        // Дубликат вставляется сразу после первого элемента: он гарантированно
        // приходит ДО завершения сборки при любом перемешивании (фрагмент,
        // пришедший после сборки, законно открывает новую запись с тем же
        // msg_id — это отдельное поведение, не этот тест).
        let reassembler = Reassembler()
        var result: String?
        var sequence = packets.shuffled()
        sequence.insert(sequence[0], at: 1)   // дубликат
        for raw in sequence {
            guard case .textFragment(let fragment) = try EnvelopeDecoder.decode(raw) else {
                Issue.record("ожидался фрагмент"); return
            }
            if let text = try reassembler.add(fragment) { result = text }
        }
        #expect(result == longText)
        #expect(reassembler.pendingCount == 0)
    }

    @Test func missingFragmentBlocksAssembly() throws {
        let packets = try TextEncoder.encode(msgID: 0x77A2, text: longText)
        let reassembler = Reassembler()
        var result: String?
        for raw in packets.dropFirst() {     // потеряли первый
            guard case .textFragment(let fragment) = try EnvelopeDecoder.decode(raw) else { return }
            result = try reassembler.add(fragment) ?? result
        }
        #expect(result == nil, "без фрагмента собираться не должно")
        // Досылаем потерянный — собирается
        guard case .textFragment(let first) = try EnvelopeDecoder.decode(packets[0]) else { return }
        #expect(try reassembler.add(first) == longText)
    }

    @Test func staleMessagePurged() throws {
        let packets = try TextEncoder.encode(msgID: 0x77A3, text: longText)
        let reassembler = Reassembler()
        guard case .textFragment(let fragment) = try EnvelopeDecoder.decode(packets[0]) else { return }
        _ = try reassembler.add(fragment, now: 0)
        #expect(reassembler.pendingCount == 1)
        // Через 11 минут недособранное сообщение выброшено (§7: 10 минут)
        guard case .textFragment(let f2) = try EnvelopeDecoder.decode(packets[1]) else { return }
        _ = try reassembler.add(f2, now: 700)
        #expect(reassembler.pendingCount == 1, "старое выброшено, новое началось заново")
    }
}

struct NeedsMappingTests {

    /// Каждое enum-значение модели обязано иметь бит (задача маппинга 1-в-1).
    @Test func everyModelNeedHasBit() {
        for need in SOSReport.Need.allCases {
            #expect(NeedsMapping.modelToBit[need] != nil,
                    "у \(need.rawValue) нет бита в маске needs")
        }
    }

    /// Swift-таблица совпадает с общим tests/needs_mapping.json
    /// (Python сверяется с ним же — значит, все три источника едины).
    @Test func mappingMatchesSharedFile() throws {
        let data = try repoFile("tests/needs_mapping.json")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let shared = json["model_to_bit"] as! [String: Int]
        #expect(shared.count == NeedsMapping.modelToBit.count)
        for (key, bit) in shared {
            let need = SOSReport.Need(rawValue: key)
            #expect(need != nil, "в общем файле лишний ключ: \(key)")
            if let need {
                #expect(NeedsMapping.modelToBit[need] == bit,
                        "\(key): в Swift бит \(String(describing: NeedsMapping.modelToBit[need])), в общем файле \(bit)")
            }
        }
    }

    /// Сквозной маппинг: результат модели → пакет → обратно.
    @Test func reportToPacketAndBack() throws {
        let report = SOSReport(type: .sos, severity: .critical, peopleCount: 3,
                               injury: .bleeding, needs: [.bandages, .boat, .shelter])
        let msg = NeedsMapping.makeSOSMessage(from: report, msgID: 0x3BA7,
                                              lat: 8.71, lon: 115.17)
        guard case .sos(let decoded) = try EnvelopeDecoder.decode(try msg.encode()) else {
            Issue.record("SOS не распознался"); return
        }
        #expect(decoded.severity == 3)
        #expect(decoded.injury == 1)
        #expect(decoded.needs == [0, 3, 13])
        #expect(decoded.peopleCount == 3)
    }
}

struct TransportSimulatorTests {

    /// Один seed → один результат (воспроизводимость).
    @Test func deterministicWithSeed() {
        func run(seed: UInt64) -> (delivered: Int, lost: Int) {
            let channel = LoRaChannel(loss: 0.3, duplicate: 0.1, reorder: 0.2, seed: seed)
            for i in 0..<50 { channel.send([UInt8(i)]) }
            _ = channel.deliverAll()
            return (channel.stats.delivered, channel.stats.lost)
        }
        let a = run(seed: 2026), b = run(seed: 2026)
        #expect(a == b)
    }

    /// Идеальный канал доставляет всё и по порядку.
    @Test func perfectChannelDeliversInOrder() {
        let channel = LoRaChannel(delayMin: 0.5, delayMax: 0.5, seed: 1)
        let packets: [[UInt8]] = (0..<10).map { [UInt8($0)] }
        for p in packets { channel.send(p) }
        #expect(channel.deliverAll() == packets)
        #expect(channel.stats.lost == 0)
    }

    /// Пакет больше лимита радио не принимает.
    @Test func oversizeRejected() {
        let channel = LoRaChannel(seed: 1)
        #expect(!channel.send([UInt8](repeating: 0, count: 250)))
        #expect(channel.stats.oversize == 1)
        #expect(channel.deliverAll().isEmpty)
    }

    /// При 100% потерь не доходит ничего, статистика честная.
    @Test func totalLoss() {
        let channel = LoRaChannel(loss: 1.0, seed: 7)
        for _ in 0..<10 { channel.send([1, 2, 3]) }
        #expect(channel.deliverAll().isEmpty)
        #expect(channel.stats.lost == 10)
    }
}

/// Ф5 v1.1: метка времени отправки в конверте — относительное время
/// рендерится ОТ метки, а не от момента распаковки.
struct SentTimeTests {
    @Test func relativeTimeRendersFromSenderClock() throws {
        // отправитель: 14:00 UTC, «выхожу через 1 час»
        let sentAt = UInt32(29761320)   // k суток + 14:00 UTC в минутах
        let text = "Выхожу через 1 час"
        // распаковка «через 4 часа» — функция чистая, от текущего
        // времени не зависит: рендер обязан дать время отправителя
        let rendered = RMCodec.applySentTime(text, sentAtMinutes: sentAt,
                                             lang: "ru",
                                             timeZone: TimeZone(identifier: "UTC")!)
        #expect(rendered.contains("(к 15:00)"), Comment(rawValue: rendered))
        // нулевая метка (v0-пакет) — текст не трогается
        #expect(RMCodec.applySentTime(text, sentAtMinutes: 0, lang: "ru")
                == text)
    }

    @Test func textPacketCarriesTimestamp() throws {
        let packets = try TextEncoder.encodePackets(
            msgID: 42, payload: [2, 7, 7], sentAtMinutes: 12345)
        #expect(packets.count == 1)
        let p = packets[0]
        #expect(p[0] >> 4 == 1, "версия конверта 1")
        let ts = UInt32(p[4]) | UInt32(p[5]) << 8
               | UInt32(p[6]) << 16 | UInt32(p[7]) << 24
        #expect(ts == 12345)
        #expect(Array(p[8...]) == [2, 7, 7], "нагрузка после метки")
    }
}

/// Живой прогон 29.07: «in 1 hour» рендерился «в 1 час» и метка не
/// цеплялась — правило рендера переводит цепочку в «через 1 час».
struct RelativeTimeRenderTests {
    @Test func inNHourRendersAsRelative() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let units = matcher.units(fromPivot: "i leave in 1 hour.",
                                  allowProtected: false)
        let ru = codec.render(units)
        #expect(ru.contains("через 1 час"), Comment(rawValue: ru))
        let stamped = RMCodec.applySentTime(ru,
            sentAtMinutes: UInt32(20667 * 1440 + 840), lang: "ru",
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(stamped.contains("через 1 час (к 15:00)"),
                Comment(rawValue: stamped))
    }
}

/// Б3: одна метка, одно место (рендер) — все формы.
struct SentTimeFormsTests {
    @Test func allFormsAndIdempotency() {
        let base = UInt32(20667 * 1440 + 840)   // 14:00 UTC
        let utc = TimeZone(identifier: "UTC")!
        func st(_ t: String) -> String {
            RMCodec.applySentTime(t, sentAtMinutes: base, lang: "ru",
                                  timeZone: utc)
        }
        #expect(st("Выхожу через час") == "Выхожу через час (к 15:00)")
        #expect(st("Буду через 20 минут") == "Буду через 20 минут (к 14:20)")
        // относительные дни и части суток НЕ трогаются
        #expect(st("Приеду послезавтра вечером") == "Приеду послезавтра вечером")
        // идемпотентность: повторное применение не дублирует метку
        let once = st("Выхожу через 1 час")
        #expect(st(once) == once, Comment(rawValue: st(once)))
    }
}

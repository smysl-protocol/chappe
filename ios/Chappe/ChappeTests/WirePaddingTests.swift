import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Замки №7 (решение владельца 09.08): быстрые транспорты паддятся в
// бакеты, LoRa — нет. Ожидания — байты и границы, посчитанные руками
// из спеки обёртки ([0xAD][длина u16 LE][кадр][случайный хвост],
// бакет 256), не выведенные из кода.
//
// ЧЕСТНО (пометка владельца): паддинг закрывает ДЛИНУ кадра, не
// тайминги и не частоту — это записано и в модуле, и здесь.
// ============================================================================

@Suite
struct WirePaddingTests {

    @Test("быстрый транспорт: размер кратен бакету, раскладка руками")
    func paddedFrameLayoutByHand() {
        let packet: [UInt8] = [0x21, 0x00, 0x07, 0x00, 0xDE, 0xAD]
        let wire = WirePadding.pad(packet)
        // руками: 3 (обёртка) + 6 (кадр) = 9 → бакет 256
        #expect(wire.count == 256, Comment(rawValue:
                "кадр 6 Б обязан уехать бакетом 256 Б: наблюдатель "
                + "быстрого канала не должен видеть длину сообщения"))
        #expect(wire[0] == 0xAD, "маркер обёртки — 0xAD по спеке")
        #expect(wire[1] == 6 && wire[2] == 0, "длина 6 = [0x06, 0x00] LE")
        #expect(Array(wire[3..<9]) == packet, "кадр лежит сразу за обёрткой")

        // границы бакетов, посчитанные руками: 3+253=256 — впритык в
        // первый; 3+254=257 — уже второй
        #expect(WirePadding.pad([UInt8](repeating: 1, count: 253))
                .count == 256)
        #expect(WirePadding.pad([UInt8](repeating: 1, count: 254))
                .count == 512)
    }

    @Test("обёртка снимается: что западдили, то и вернулось")
    func roundtrip() {
        for size in [1, 6, 200, 253, 254, 600] {
            let packet = (0..<size).map { _ in
                UInt8.random(in: .min ... .max)
            }
            let wire = WirePadding.pad(packet)
            #expect(wire.count % 256 == 0, "итог всегда кратен бакету")
            #expect(WirePadding.unwrap(wire) == packet, Comment(rawValue:
                    "снятие обёртки обязано вернуть кадр байт в байт — "
                    + "иначе AEAD ниже по тракту не сойдётся"))
        }
        // хвост случайный: две обёртки одного кадра различаются
        let packet: [UInt8] = [1, 2, 3]
        #expect(WirePadding.pad(packet) != WirePadding.pad(packet),
                Comment(rawValue: "детерминированный хвост был бы вторым "
                        + "каналом — хвост обязан быть случайным"))
    }

    @Test("битая обёртка и чужие байты — nil, не мусор в тракт")
    func brokenWrapRejected() {
        #expect(WirePadding.unwrap([]) == nil)
        #expect(WirePadding.unwrap([0xAD]) == nil, "короче заголовка")
        // заявлено 10 байт, лежит 2 — обрезанный кадр не отдаём
        #expect(WirePadding.unwrap([0xAD, 10, 0, 1, 2]) == nil)
        // не наш маркер — не обёртка (v2-пакет начинается с 0x2X)
        #expect(WirePadding.unwrap([0x21, 3, 0, 1, 2, 3]) == nil)
    }

    @Test("НА LORA ПАДДИНГА НЕТ: mesh уходит голым, быстрые — бакетом")
    func loRaIsNeverPadded() {
        let packet: [UInt8] = [0x21, 0x00, 0x07, 0x00, 0xDE, 0xAD]
        // решение владельца 09.08: на LoRa каждый байт — эфирное время,
        // паддинг и кодек так не пересекаются. Слом (паддинг в mesh) —
        // красный именно здесь.
        #expect(!WirePadding.applies(toTransport: "mesh"))
        #expect(WirePadding.outbound(packet, transport: "mesh") == packet,
                Comment(rawValue:
                "LoRa-кадр обязан уходить голым: бакет 256 съел бы весь "
                + "бюджет эфира (кадр ≤ 200 Б) ради скрытия длины, "
                + "которое там не заказано"))
        for fast in ["lan", "demo", "relay", "nearby"] {
            let wire = WirePadding.outbound(packet, transport: fast)
            #expect(wire.count % 256 == 0 && wire.count >= 256,
                    Comment(rawValue: "быстрый транспорт «\(fast)» обязан "
                            + "паддиться в бакет"))
            #expect(WirePadding.unwrap(wire) == packet)
        }
    }
}

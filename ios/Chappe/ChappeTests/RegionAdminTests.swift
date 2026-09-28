import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Замок на кадр смены региона (UX-проход 06.08).
//
// Ожидание извне (правило 4): байты эталона посчитаны ВРУЧНУЮ по
// mesh.proto/admin.proto/config.proto, а не выведены из кода. Слом
// проверен: верни varint вместо fixed32 для to/id (исторический баг
// 02.08 — узел молча выбрасывал пакет) — тест краснеет.
// ============================================================================

struct RegionAdminTests {

    @Test("Кадр смены региона байт в байт — эталон посчитан вручную")
    func frameMatchesHandComputedBytes() {
        // LoRaConfig узла: use_preset=true (поле 1 varint) — то, что
        // НЕ должно потеряться при смене региона
        let rawLoRa: [UInt8] = [0x08, 0x01]
        let frame = NodeProbe.regionAdminFrame(
            rawLoRa: rawLoRa, code: 18,           // SG_923
            nodeNum: 0x1122_3344, packetID: 0xAABB_CCDD)

        // Рукой, изнутри наружу:
        // lora   = 08 01 | 38 12            (старые байты + region=18)
        // config = 32 04 lora               (Config.lora=6, wire 2)
        // admin  = 92 02 06 config          (set_config=34: ключ 34<<3|2=274)
        // data   = 08 06 | 12 09 admin      (portnum=6 ADMIN_APP, payload)
        // mesh   = 15 44 33 22 11           (to=2, fixed32 LE)
        //        | 22 0D data
        //        | 35 DD CC BB AA           (id=6, fixed32 LE)
        //        | 50 01                    (want_ack=10)
        // frame  = 0A 1B mesh               (ToRadio.packet=1, длина 27)
        let expected: [UInt8] = [
            0x0A, 0x1B,
            0x15, 0x44, 0x33, 0x22, 0x11,
            0x22, 0x0D,
            0x08, 0x06,
            0x12, 0x09,
            0x92, 0x02, 0x06,
            0x32, 0x04,
            0x08, 0x01, 0x38, 0x12,
            0x35, 0xDD, 0xCC, 0xBB, 0xAA,
            0x50, 0x01,
        ]
        #expect(frame == expected,
                "кадр разошёлся с ручным эталоном: \(frame) != \(expected)")
    }

    @Test("Старый регион в конфиге не мешает: последнее значение побеждает")
    func lastRegionWins() throws {
        // Узел с EU_868 (region=3 уже в конфиге) переводится в SG_923.
        // set_config шлёт конфиг ЦЕЛИКОМ, регион дописывается в хвост —
        // по правилам protobuf у скалярного поля побеждает последнее.
        let rawLoRa: [UInt8] = [0x08, 0x01, 0x38, 0x03, 0x20, 0x2A]
        let frame = NodeProbe.regionAdminFrame(
            rawLoRa: rawLoRa, code: 18, nodeNum: 7, packetID: 1)

        // разобрать кадр обратно и дойти до LoRaConfig
        let toRadio = MiniProto.fields(frame)
        let mesh = try #require(toRadio[1]?.first)
        let meshFields = MiniProto.fields(mesh)
        let data = try #require(meshFields[4]?.first)
        let dataFields = MiniProto.fields(data)
        #expect(dataFields[1]?.first.flatMap { MiniProto.readVarint($0) } == 6,
                "portnum обязан быть ADMIN_APP=6")
        let admin = try #require(dataFields[2]?.first)
        let config = try #require(MiniProto.fields(admin)[34]?.first)
        let lora = try #require(MiniProto.fields(config)[6]?.first)
        let regions = MiniProto.fields(lora)[7] ?? []
        #expect(regions.count == 2, "оба значения региона должны быть в кадре")
        #expect(regions.last.flatMap { MiniProto.readVarint($0) } == 18,
                "последним (побеждающим) обязан идти новый регион")
        // соседние поля конфига не потеряны
        #expect(MiniProto.fields(lora)[1]?.first != nil, "use_preset пропал")
        #expect(MiniProto.fields(lora)[4]?.first != nil, "поле 4 пропало")
    }
}

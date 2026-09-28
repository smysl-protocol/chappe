import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Разбор фактов узла из FromRadio (бриф 02.08) — на синтетических
// кадрах, собранных тем же MiniProto (номера полей — mesh.proto/
// config.proto, сверены 02.08). Bluetooth в тестах не нужен.
// ============================================================================

@MainActor
struct NodeProbeTests {

    private func lenField(_ field: Int, _ inner: [UInt8]) -> [UInt8] {
        MiniProto.lenField(field, inner)
    }
    private func varField(_ field: Int, _ v: UInt64) -> [UInt8] {
        MiniProto.key(field, wire: 0) + MiniProto.varint(v)
    }

    @Test("Факты узла собираются из конфиг-потока")
    func factsFromConfigStream() {
        let probe = NodeProbe()

        // FromRadio{ my_info=3: MyNodeInfo{ my_node_num=1: 7 } }
        probe.ingest(lenField(3, varField(1, 7)))
        // чужой узел в NodeDB
        probe.ingest(lenField(4, varField(1, 42)))
        // свой узел с именем: NodeInfo{ num=1:7, user=2: User{ long_name=2 } }
        let userMsg = lenField(2, Array("Node Alpha".utf8))   // User
        probe.ingest(lenField(4, varField(1, 7) + lenField(2, userMsg)))
        // конфиг: Config{ lora=6: LoRaConfig{ region=7: SG_923(18) } }
        probe.ingest(lenField(5, lenField(6, varField(7, 18))))
        // metadata: DeviceMetadata{ firmware_version=1 }
        probe.ingest(lenField(13, lenField(1, Array("2.5.1".utf8))))

        #expect(probe.facts.longName == "Node Alpha")
        #expect(probe.facts.region == "SG_923")
        #expect(probe.facts.firmware == "2.5.1")
        #expect(probe.facts.nodeCount == 2)

        // config_complete_id=7 → факты собраны, фаза ready
        probe.ingest(varField(7, 123))
        #expect(probe.phase == .ready)
    }

    @Test("Имя берётся только у СВОЕГО узла")
    func nameOnlyFromOwnNode() {
        let probe = NodeProbe()
        probe.ingest(lenField(3, varField(1, 7)))
        // чужой узел с именем — не наше имя
        let strangerUser = lenField(2, Array("Stranger".utf8))
        probe.ingest(lenField(4, varField(1, 99) + lenField(2, strangerUser)))
        #expect(probe.facts.longName == nil)
        #expect(probe.facts.nodeCount == 1)
    }

    @Test("Мусорные байты не роняют разбор")
    func garbageIsIgnored() {
        let probe = NodeProbe()
        probe.ingest([0xFF, 0xFF, 0xFF])
        probe.ingest([])
        #expect(probe.facts.nodeCount == 0)
        #expect(probe.phase == .idle)
    }
}

// ============================================================================
// Живые факты РАБОЧЕГО линка (полевой регресс 13.08: «Имя —, Страна —»
// при зелёном «радиоканал готов» — факты умел собирать только probe,
// а узел был у транспорта). Линк читает тот же конфиг-дамп — профиль
// обязан собираться и у него. Слом: перестать звать harvestFacts из
// didUpdateValue / вернуть только-probe — liveFacts пуст, тест красный.
// ============================================================================

struct MeshLinkLiveFactsTests {

    private func lenField(_ field: Int, _ inner: [UInt8]) -> [UInt8] {
        MiniProto.lenField(field, inner)
    }
    private func varField(_ field: Int, _ v: UInt64) -> [UInt8] {
        MiniProto.key(field, wire: 0) + MiniProto.varint(v)
    }

    @Test("линк собирает профиль узла из конфиг-дампа (имя/регион/счёт)")
    func linkHarvestsFactsFromConfigDump() {
        let link = MeshtasticLink()
        // FromRadio{ my_info=3: MyNodeInfo{ my_node_num=1: 7 } }
        link.harvestFacts(lenField(3, varField(1, 7)))
        // чужой узел — только счёт
        link.harvestFacts(lenField(4, varField(1, 42)))
        // свой узел с именем
        let userMsg = lenField(2, Array("Node Alpha".utf8))
        link.harvestFacts(lenField(4, varField(1, 7) + lenField(2, userMsg)))
        // конфиг с регионом SG_923 (код 18)
        link.harvestFacts(lenField(5, lenField(6, varField(7, 18))))

        #expect(link.liveFacts.longName == "Node Alpha", Comment(rawValue:
                "рабочий линк обязан знать имя своего узла — иначе профиль "
                + "на радиоэкране пуст при живом канале (поле 13.08)"))
        #expect(link.liveFacts.region == "SG_923")
        #expect(link.liveFacts.nodeCount == 2, "видит оба узла из дампа")
    }
}

// Дедуп радио-строк дневника (13.08): пульс каждые 2 с флудил
// fromNum/«пусто — дочитано» — 64-КБ дневник терял историю за ~2 часа,
// полевые окна вырезались. Слом: вернуть безусловное логирование
// (убрать дедуп из didUpdateValue) — замок не задействуется; сама
// структура стережёт правила «смена счётчика» и «переход данные→пусто».
struct RadioDiaryDedupTests {

    @Test("fromNum пишется только при смене счётчика")
    func fromNumOnlyOnChange() {
        var dedup = RadioDiaryDedup()
        let first = dedup.fromNumChanged(5)
        let repeat1 = dedup.fromNumChanged(5)
        let repeat2 = dedup.fromNumChanged(5)
        let changed = dedup.fromNumChanged(6)
        #expect(first, "первое значение — событие")
        #expect(!repeat1 && !repeat2, "повтор счётчика — молчание")
        #expect(changed, "смена счётчика — событие")
    }

    @Test("«пусто — дочитано» — только на переходе данные→пусто")
    func emptyReadOnlyOnTransition() {
        var dedup = RadioDiaryDedup()
        let coldEmpty = dedup.emptyReadTransition()
        dedup.noteDataRead()
        let afterData = dedup.emptyReadTransition()
        let repeated = dedup.emptyReadTransition()
        #expect(!coldEmpty,
                "пустое чтение без данных до него — молчание (пульс-опрос)")
        #expect(afterData, "данные→пусто — событие")
        #expect(!repeated,
                "повторное пустое — молчание, дневник не флудится")
    }
}

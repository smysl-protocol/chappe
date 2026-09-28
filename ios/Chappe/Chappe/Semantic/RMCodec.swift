import Foundation

// ============================================================================
// RMCodec — битовый кодек словаря R+M. Порт tools/semdict/rm_codec.py:
// Swift обязан сходиться с rm_codec_testvectors.json ПОБАЙТОВО.
//
// Поток: [varint: число единиц][битстрим канонического Хаффмана MSB-first
// + escape-нагрузки с выравниванием на байт].
//
// Детерминизм: канонические коды строятся ТОЛЬКО из поля bits словаря
// (сортировка по (bits, code)) — одинаково на любом железе и языке.
// ============================================================================

nonisolated final class RMCodec: @unchecked Sendable {

    enum Unit: Equatable, Sendable {
        case code(Int)
        case num(Int)
        case lit(String)
        case name(String)
        /// Сумма денег: число + валюта ISO-субсета (esc_amount).
        case amount(Int, String)
        /// Время суток в минутах 0-1439 (esc_time), рендер HH:MM.
        case time(Int)
        /// Фраза-ритуал v1.1: payload esc_local, [esc_local][id 1 байт].
        /// Теги: 0x00-0x7F — фраза, 0x80 — эмодзи, 0x81 — резерв registry.
        case phrase(Int)
        /// Резерв будущих кодов v1.2: [esc_extension][12 бит индекса].
        case ext(Int)
        /// Эмодзи v1.1: [esc_local][0x80][индекс top-255]. Отдельное
        /// пространство: рендерится символом, никогда словом.
        case emoji(String)
    }

    struct PhraseV11: Decodable, Sendable {
        let id: Int
        let ru: String
        let en: String
        let match: [String]
    }

    // Полная таблица валют ISO 4217 alpha-3, АЛФАВИТНЫЙ порядок
    // (синхронно с rm_codec.py). ЗАМОРОЖЕНА с v1: индекс байта летит по
    // проводу, менять и вставлять нельзя; новые валюты — только в хвост.
    // Индекс 255 зарезервирован: валюта литералом (3 байта ASCII).
    static let currencies = [
        "AED","AFN","ALL","AMD","ANG","AOA","ARS","AUD","AWG","AZN",
        "BAM","BBD","BDT","BGN","BHD","BIF","BMD","BND","BOB","BRL",
        "BSD","BTN","BWP","BYN","BZD","CAD","CDF","CHF","CLP","CNY",
        "COP","CRC","CUP","CVE","CZK","DJF","DKK","DOP","DZD","EGP",
        "ERN","ETB","EUR","FJD","FKP","GBP","GEL","GHS","GIP","GMD",
        "GNF","GTQ","GYD","HKD","HNL","HTG","HUF","IDR","ILS","INR",
        "IQD","IRR","ISK","JMD","JOD","JPY","KES","KGS","KHR","KMF",
        "KPW","KRW","KWD","KYD","KZT","LAK","LBP","LKR","LRD","LSL",
        "LYD","MAD","MDL","MGA","MKD","MMK","MNT","MOP","MRU","MUR",
        "MVR","MWK","MXN","MYR","MZN","NAD","NGN","NIO","NOK","NPR",
        "NZD","OMR","PAB","PEN","PGK","PHP","PKR","PLN","PYG","QAR",
        "RON","RSD","RUB","RWF","SAR","SBD","SCR","SDG","SEK","SGD",
        "SHP","SLE","SOS","SRD","SSP","STN","SVC","SYP","SZL","THB",
        "TJS","TMT","TND","TOP","TRY","TTD","TWD","TZS","UAH","UGX",
        "USD","UYU","UZS","VES","VND","VUV","WST","XAF","XCD","XOF",
        "XPF","YER","ZAR","ZMW","ZWG",
    ]
    static let currencyRaw: UInt8 = 255
    // Человеческие имена — только у ходовых; остальное — ISO-кодом.
    static let currencyRU: [String: String] = [
        "USD": "долларов", "EUR": "евро", "RUB": "рублей", "VND": "донгов",
        "IDR": "рупий", "AED": "дирхамов", "THB": "батов",
        "GBP": "фунтов", "INR": "рупий (инд.)", "CNY": "юаней",
        "JPY": "иен", "KZT": "тенге", "TRY": "лир", "UAH": "гривен",
    ]
    static let currencyEN: [String: String] = [
        "USD": "dollars", "EUR": "euro", "RUB": "rubles", "VND": "dong",
        "IDR": "rupiah", "AED": "dirhams", "THB": "baht",
        "GBP": "pounds", "INR": "rupees", "CNY": "yuan", "JPY": "yen",
        "KZT": "tenge", "TRY": "lira", "UAH": "hryvnia",
    ]
    /// Слова пивота → ISO (матчер клеит «число + валюта» в amount).
    static let currencyWords: [String: String] = [
        "dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD",
        "euro": "EUR", "euros": "EUR",
        "ruble": "RUB", "rubles": "RUB", "rouble": "RUB", "roubles": "RUB",
        "rur": "RUB",
        "dong": "VND", "dongs": "VND",
        "rupiah": "IDR", "rupiahs": "IDR",
        "dirham": "AED", "dirhams": "AED",
        "baht": "THB", "bahts": "THB",
    ]

    struct Entry: Sendable {
        let code: Int
        let en: String
        let ru: String?
        let layer: String
        let bits: Int
    }

    /// Общий экземпляр (словарь из бандла); nil — словаря нет.
    static let shared: RMCodec? = try? RMCodec()

    let version: String
    let entries: [Int: Entry]
    let byEn: [String: Int]
    private var enc: [Int: (bits: Int, value: UInt32)] = [:]
    private var dec: [UInt64: Int] = [:]      // (bits<<32 | value) -> code
    let escNum: Int
    let escLit: Int
    let escName: Int
    let escAmount: Int?
    let escTime: Int?
    let escLocal: Int?
    let escExt: Int?
    /// internal — отпечаток litchars сторожит FingerprintFreezeTests.
    var charEnc: [Int: (bits: Int, value: UInt32)] = [:]
    private var charDec: [UInt64: Int] = [:]
    let phrases: [Int: PhraseV11]
    let emojiTable: [String]
    let emojiIndex: [String: Int]

    init() throws {
        guard let url = Bundle.main.url(forResource: "rm_dict_core_v0",
                                        withExtension: "json",
                                        subdirectory: "sophie_kb")
                ?? Bundle.main.url(forResource: "rm_dict_core_v0",
                                   withExtension: "json") else {
            throw LLMError.generationFailed(reason: "rm_dict_core_v0.json нет в бандле")
        }
        struct RawEntry: Decodable {
            let code: Int; let en: String; let ru: String?
            let layer: String; let bits: Int
        }
        struct RawDict: Decodable {
            let version: String; let entries: [RawEntry]
        }
        let raw = try JSONDecoder().decode(RawDict.self,
                                           from: Data(contentsOf: url))
        version = raw.version
        var map: [Int: Entry] = [:]
        var names: [String: Int] = [:]
        for e in raw.entries {
            map[e.code] = Entry(code: e.code, en: e.en, ru: e.ru,
                                layer: e.layer, bits: e.bits)
            names[e.en] = e.code
        }
        entries = map
        byEn = names

        // Канонический Хаффман из длин: sort (bits, code)
        var canon: UInt32 = 0
        var prevLen = 0
        for e in raw.entries.sorted(by: { ($0.bits, $0.code) < ($1.bits, $1.code) }) {
            canon <<= UInt32(e.bits - prevLen)
            prevLen = e.bits
            enc[e.code] = (e.bits, canon)
            dec[UInt64(e.bits) << 32 | UInt64(canon)] = e.code
            canon += 1
        }

        guard let n = names["esc_number"], let l = names["esc_literal"],
              let m = names["esc_name"] else {
            throw LLMError.generationFailed(reason: "в словаре нет escape-кодов")
        }
        escNum = n; escLit = l; escName = m
        escAmount = names["esc_amount"]
        escTime = names["esc_time"]
        escLocal = names["esc_local"]
        escExt = names["esc_extension"]
        // фразы-ритуалы v1.1 (данные, замораживаются со словарём)
        struct PhraseFile: Decodable { let phrases: [PhraseV11] }
        if let purl = Bundle.main.url(forResource: "phrases_v11",
                                      withExtension: "json",
                                      subdirectory: "sophie_kb")
            ?? Bundle.main.url(forResource: "phrases_v11",
                               withExtension: "json"),
           let pf = try? JSONDecoder().decode(PhraseFile.self,
                                              from: Data(contentsOf: purl)) {
            phrases = Dictionary(uniqueKeysWithValues:
                                    pf.phrases.map { ($0.id, $0) })
        } else {
            phrases = [:]
        }
        struct EmojiFile: Decodable { let emoji: [String] }
        if let eurl = Bundle.main.url(forResource: "emoji_v11",
                                      withExtension: "json",
                                      subdirectory: "sophie_kb")
            ?? Bundle.main.url(forResource: "emoji_v11",
                               withExtension: "json"),
           let ef = try? JSONDecoder().decode(EmojiFile.self,
                                              from: Data(contentsOf: eurl)) {
            emojiTable = ef.emoji
            emojiIndex = Dictionary(uniqueKeysWithValues:
                ef.emoji.enumerated().map { ($0.element, $0.offset) })
        } else {
            emojiTable = []
            emojiIndex = [:]
        }

        // Байт-отпечаток таблицы Хаффмана (FNV-1a 32, синхронно с
        // rm_codec.py): первый байт семантического payload на проводе —
        // приёмник с другой таблицей узнаёт об этом честно, а не
        // декодирует мусор. Совместимость версий (п.5, 28.07).
        // 03.08: в отпечаток добавлена ВЕРСИЯ словаря. Причина —
        // измеренная коллизия: v1.2.0 (1555 записей) и v1.3.0 (1580)
        // дали ОДИН И ТОТ ЖЕ байт 0xEE при разных таблицах. Один байт
        // сам по себе даёт 1/256 на любую пару версий, и мы в неё
        // попали с первого раза; узел со старым словарём принял бы
        // чужие коды за свои и молча раскодировал бы их неверно.
        // Версия в затравке гарантирует различие ХОТЯ БЫ между
        // версиями (полное решение — расширить поле, решение владельца).
        var h: UInt32 = 2_166_136_261
        for b in "v\(raw.version);".utf8 {
            h = (h ^ UInt32(b)) &* 16_777_619
        }
        for e in raw.entries.sorted(by: { ($0.bits, $0.code) < ($1.bits, $1.code) }) {
            for b in "\(e.code):\(e.bits);".utf8 {
                h = (h ^ UInt32(b)) &* 16_777_619
            }
        }
        // tableHash присваивается НИЖЕ, после построения litchars:
        // с 03.08 (вечер, решение владельца) канонические длины litchars
        // входят в отпечаток провода — иначе при совпадающем словаре и
        // разных litchars литералы декодировались МОЛЧА неверно (тот же
        // класс, что коллизия однобайтового отпечатка). Порядок строк —
        // возрастание cp (rm_wire_bitspec.md §4). Зеркало rm_codec.py.

        // 3б (v1.2): канонический Хаффман по символам литералов
        struct CharRow: Decodable { let cp: Int; let freq: Int }
        struct CharFile: Decodable { let chars: [CharRow] }
        if let curl = Bundle.main.url(forResource: "litchars_v12",
                                      withExtension: "json",
                                      subdirectory: "sophie_kb")
            ?? Bundle.main.url(forResource: "litchars_v12",
                               withExtension: "json"),
           let cf = try? JSONDecoder().decode(CharFile.self,
                                              from: Data(contentsOf: curl)) {
            let lengths = Self.charHuffmanLengths(
                cf.chars.map { ($0.cp, $0.freq) })
            var canon: UInt32 = 0
            var prev = 0
            for (cp, bits) in lengths.sorted(by: { ($0.1, $0.0) < ($1.1, $1.0) }) {
                canon <<= UInt32(bits - prev)
                prev = bits
                charEnc[cp] = (bits, canon)
                charDec[UInt64(bits) << 32 | UInt64(canon)] = cp
                canon += 1
            }
        }
        for b in "litchars;".utf8 {
            h = (h ^ UInt32(b)) &* 16_777_619
        }
        for (cp, bv) in charEnc.sorted(by: { $0.key < $1.key }) {
            for b in "\(cp):\(bv.bits);".utf8 {
                h = (h ^ UInt32(b)) &* 16_777_619
            }
        }
        tableHash = h          // 4 байта: см. комментарий выше
    }

    private static func charHuffmanLengths(_ items: [(Int, Int)]) -> [(Int, Int)] {
        struct Node { var freq: Int; var order: Int; var keys: [Int] }
        var heap = items.enumerated().map {
            Node(freq: $0.element.1, order: $0.offset, keys: [$0.element.0])
        }
        var depth: [Int: Int] = [:]
        var next = heap.count
        func popMin() -> Node {
            var best = 0
            for i in heap.indices
            where (heap[i].freq, heap[i].order) < (heap[best].freq, heap[best].order) {
                best = i
            }
            return heap.remove(at: best)
        }
        while heap.count > 1 {
            let a = popMin(), b = popMin()
            for k in a.keys + b.keys { depth[k, default: 0] += 1 }
            heap.append(Node(freq: a.freq + b.freq, order: next,
                             keys: a.keys + b.keys))
            next += 1
        }
        return depth.map { ($0.key, $0.value) }
    }

    /// Отпечаток таблицы для сверки версий на проводе.
    /// Отпечаток таблицы, 4 байта (решение владельца 03.08).
    /// Один байт дал коллизию с первой же попытки (v1.2.0 и v1.3.0
    /// совпали на 0xEE), два байта — та же лотерея, только реже, а
    /// цена ошибки — МОЛЧАЛИВОЕ неверное декодирование чужих кодов.
    /// Четыре байта: вероятность совпадения 1/4·10⁹ вместо 1/256.
    let tableHash: UInt32

    /// Байты отпечатка на проводе (big-endian, как читается глазом).
    var tableHashBytes: [UInt8] {
        [UInt8(tableHash >> 24 & 0xFF), UInt8(tableHash >> 16 & 0xFF),
         UInt8(tableHash >> 8 & 0xFF), UInt8(tableHash & 0xFF)]
    }

    /// Провод: [tableHash][units-блоб].
    func wireBlob(_ blob: [UInt8]) -> [UInt8] { tableHashBytes + blob }

    /// units-блоб из провода; nil — таблица другой версии (фоллбэк
    /// на текст решает вызывающий, декодировать нельзя — будет мусор).
    func unwrapWire(_ data: [UInt8]) -> [UInt8]? {
        guard data.count >= 4, Array(data.prefix(4)) == tableHashBytes
        else { return nil }
        return Array(data.dropFirst(4))
    }

    // MARK: Битовый писатель/читатель (порт _W/_R)

    private struct Writer {
        var buf: [UInt8] = []
        var acc: UInt64 = 0
        var n = 0

        mutating func bits(_ value: UInt32, _ width: Int) {
            acc = (acc << UInt64(width)) | UInt64(value & ((1 << UInt32(width)) - 1))
            n += width
            while n >= 8 {
                n -= 8
                buf.append(UInt8((acc >> UInt64(n)) & 0xFF))
            }
        }

        mutating func bytesAligned(_ data: [UInt8]) {
            if n > 0 { bits(0, 8 - n) }       // выравнивание нулями
            buf.append(contentsOf: data)
        }

        mutating func done() -> [UInt8] {
            if n > 0 { bits(0, 8 - n) }
            return buf
        }
    }

    private struct Reader {
        let d: [UInt8]
        var pos = 0                           // позиция в битах

        mutating func bits(_ width: Int) throws -> UInt32 {
            var v: UInt32 = 0
            for _ in 0..<width {
                let byteIndex = pos >> 3
                guard byteIndex < d.count else {
                    throw LLMError.generationFailed(reason: "битстрим оборван")
                }
                v = (v << 1) | UInt32((d[byteIndex] >> (7 - (pos & 7))) & 1)
                pos += 1
            }
            return v
        }

        mutating func bytesAligned(_ n: Int) throws -> [UInt8] {
            if pos & 7 != 0 { pos = (pos + 7) & ~7 }
            let start = pos >> 3
            pos += n * 8
            guard start + n <= d.count else {
                throw LLMError.generationFailed(reason: "нагрузка оборвана")
            }
            return Array(d[start..<start + n])
        }
    }

    static func varint(_ n: Int) -> [UInt8] {
        var n = n
        var out: [UInt8] = []
        while true {
            let b = UInt8(n & 0x7F)
            n >>= 7
            out.append(b | (n != 0 ? 0x80 : 0))
            if n == 0 { return out }
        }
    }

    private static func readVarint(_ rd: inout Reader) throws -> Int {
        var n = 0, shift = 0
        while true {
            let b = try rd.bytesAligned(1)[0]
            n |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { return n }
            shift += 7
        }
    }

    // MARK: API

    func encode(_ units: [Unit]) throws -> [UInt8] {
        var w = Writer()
        for unit in units {
            switch unit {
            case .code(let code):
                guard let (bits, v) = enc[code] else {
                    throw LLMError.generationFailed(reason: "нет кода \(code) в словаре")
                }
                w.bits(v, bits)
            case .num(let value):
                let (bits, v) = enc[escNum]!
                w.bits(v, bits)
                w.bytesAligned(Self.varint(value))
            case .amount(let value, let iso):
                guard let escAmount, let (bits, v) = enc[escAmount] else {
                    throw LLMError.generationFailed(reason: "esc_amount вне словаря")
                }
                w.bits(v, bits)
                let payload: [UInt8]
                if let index = Self.currencies.firstIndex(of: iso) {
                    payload = [UInt8(index)]
                } else {
                    // резерв 255: валюта литералом, ровно 3 байта ASCII
                    var ascii = Array(iso.uppercased().utf8.prefix(3))
                    while ascii.count < 3 { ascii.append(0x3F) }   // "?"
                    payload = [Self.currencyRaw] + ascii
                }
                w.bytesAligned(payload + Self.varint(value))
            case .time(let minutes):
                guard let escTime, let (bits, v) = enc[escTime] else {
                    throw LLMError.generationFailed(reason: "esc_time вне словаря")
                }
                w.bits(v, bits)
                w.bytesAligned(Self.varint(minutes))
            case .phrase(let id):
                // Валидные id — только 0x00–0x7F: тег 0x80 занят
                // маркером эмодзи, phrase(128) уходил в байты эмодзи с
                // рассинхроном остатка потока (тихая порча, аудит
                // пределов 03.08; спека rm_wire_bitspec.md §3).
                guard let escLocal, let (bits, v) = enc[escLocal],
                      (0...127).contains(id) else {
                    throw LLMError.generationFailed(reason: "esc_local/фраза вне диапазона")
                }
                w.bits(v, bits)
                w.bytesAligned([UInt8(id)])
            case .emoji(let symbol):
                guard let escLocal, let (bits, v) = enc[escLocal],
                      let index = emojiIndex[symbol] else {
                    throw LLMError.generationFailed(reason: "эмодзи вне таблицы v1.1")
                }
                // Индекс эмодзи пишется ОДНИМ байтом: сейчас таблица
                // ровно 255 записей (макс. индекс 254) и влезает впритык.
                // Без этой проверки расширение таблицы дало бы не ошибку,
                // а ПАДЕНИЕ на UInt8(index) (аудит однобайтовых длин 03.08).
                guard index <= 255 else {
                    throw LLMError.generationFailed(
                        reason: "индекс эмодзи \(index) не влезает в байт — "
                              + "таблица выросла за 256, нужен новый escape")
                }
                w.bits(v, bits)
                w.bytesAligned([0x80, UInt8(index)])
            case .lit(let s), .name(let s):
                let escCode = { if case .lit = unit { escLit } else { escName } }()
                let (bits, v) = enc[escCode]!
                w.bits(v, bits)
                // v1.2: Хаффман символов — [len симв. 1Б][битстрим];
                // символ вне таблицы: код cp=0 + 21 бит скаляра.
                // КАНОНИЧНОСТЬ (02.08): длина и обрезка — в СКАЛЯРАХ
                // Unicode, как в декоде и в python. Считать графемами
                // нельзя: «❤️» = 1 графема, 2 скаляра — декод бился.
                guard !charEnc.isEmpty else {
                    throw LLMError.generationFailed(
                        reason: "litchars-таблица не загружена — литерал "
                              + "кодировать нельзя (тихая потеря запрещена)")
                }
                // Длина литерала — один байт: больше 255 скаляров не
                // влезает. Раньше лишнее молча обрезалось и сообщение
                // уходило короче написанного (синтетический стресс
                // 03.08). Тихая потеря запрещена — бросаем, конвейер
                // откатится в текст.
                guard s.unicodeScalars.count <= 255 else {
                    throw LLMError.generationFailed(
                        reason: "литерал \(s.unicodeScalars.count) символов "
                              + "не помещается в байт длины (максимум 255) "
                              + "— отправляем текстом")
                }
                let scalars = Array(s.unicodeScalars)
                w.bytesAligned([UInt8(scalars.count)])
                for scalar in scalars {
                    if let (cb, cv) = charEnc[Int(scalar.value)] {
                        w.bits(cv, cb)
                    } else if let (eb, ev) = charEnc[0] {
                        w.bits(ev, eb)
                        w.bits(UInt32(scalar.value), 21)
                    }
                }
            case .ext(let index):
                // 4095 зарезервирован под 16-битный каскад (реестр
                // ext_registry.json, решение владельца 03.08): кодировать
                // нельзя, пока каскада нет; декод терпим — заглушка.
                guard let escExt, let (bits, v) = enc[escExt],
                      (0..<4095).contains(index) else {
                    throw LLMError.generationFailed(reason: "esc_extension вне диапазона")
                }
                w.bits(v, bits)
                w.bits(UInt32(index), 12)
            }
        }
        return Self.varint(units.count) + w.done()
    }

    func decode(_ data: [UInt8]) throws -> [Unit] {
        var rd = Reader(d: data)
        let count = try Self.readVarint(&rd)
        var units: [Unit] = []
        units.reserveCapacity(count)
        for _ in 0..<count {
            var bits = 0
            var v: UInt32 = 0
            var code: Int
            while true {                      // канонический Хаффман: наращиваем
                v = (v << 1) | (try rd.bits(1))
                bits += 1
                if let hit = dec[UInt64(bits) << 32 | UInt64(v)] {
                    code = hit
                    break
                }
                if bits > 24 {
                    throw LLMError.generationFailed(reason: "битый поток кодека")
                }
            }
            if code == escNum {
                units.append(.num(try Self.readVarint(&rd)))
            } else if let escAmount, code == escAmount {
                let index = try rd.bytesAligned(1)[0]
                let iso: String
                if index == Self.currencyRaw {
                    iso = String(decoding: try rd.bytesAligned(3),
                                 as: UTF8.self)
                } else if Int(index) < Self.currencies.count {
                    iso = Self.currencies[Int(index)]
                } else {
                    throw LLMError.generationFailed(reason: "битый код валюты")
                }
                units.append(.amount(try Self.readVarint(&rd), iso))
            } else if let escTime, code == escTime {
                units.append(.time(try Self.readVarint(&rd)))
            } else if let escLocal, code == escLocal {
                let tag = try rd.bytesAligned(1)[0]
                if tag == 0x80 {
                    let index = Int(try rd.bytesAligned(1)[0])
                    guard index < emojiTable.count else {
                        throw LLMError.generationFailed(reason: "битый индекс эмодзи")
                    }
                    units.append(.emoji(emojiTable[index]))
                } else {
                    units.append(.phrase(Int(tag)))
                }
            } else if code == escLit || code == escName {
                let len = Int(try rd.bytesAligned(1)[0])
                var scalars: [Unicode.Scalar] = []
                for _ in 0..<len {
                    var cbits = 0
                    var cv: UInt32 = 0
                    while true {
                        cv = (cv << 1) | (try rd.bits(1))
                        cbits += 1
                        if let cp = charDec[UInt64(cbits) << 32 | UInt64(cv)] {
                            if cp == 0 {
                                let raw = try rd.bits(21)
                                scalars.append(Unicode.Scalar(raw)
                                               ?? Unicode.Scalar(63)!)
                            } else {
                                scalars.append(Unicode.Scalar(UInt32(cp))!)
                            }
                            break
                        }
                        if cbits > 24 {
                            throw LLMError.generationFailed(reason: "битый литерал")
                        }
                    }
                }
                var text = ""
                text.unicodeScalars.append(contentsOf: scalars)
                units.append(code == escLit ? .lit(text) : .name(text))
            } else if let escExt, code == escExt {
                units.append(.ext(Int(try rd.bits(12))))
            } else {
                units.append(.code(code))
            }
        }
        return units
    }

    // MARK: Разворот на русский (порт render)

    static let ruDrop: Set<String> = [
        "the", "a", "an", "of", "is", "are", "am", "was", "were", "be", "been",
        "will", "would", "do", "does", "did", "to", "it", "this is", "that is",
        "it is", "there is", "of the",
    ]

    /// Язык разворота кодов (Dev-тумблер «Разворот: RU / EN»,
    /// фаза «взгляд англичанина»). Влияет только на показ — байты те же.
    nonisolated static var unfoldLanguage: String {
        get { UserDefaults.standard.string(forKey: "unfold_language") ?? "ru" }
        set { UserDefaults.standard.set(newValue, forKey: "unfold_language") }
    }

    /// Человечные EN-имена protected-кодов для разворота — display-карта,
    /// в словарь не лезем.
    static let enDisplay: [String: String] = [
        "sos_active": "SOS ALERT",
        "sos_cancel": "SOS cancelled",
    ]

    /// ru-строки словаря пишут варианты слова через «/» («ушёл/налево»,
    /// «иди/еду домой») — рендер берёт ПЕРВЫЙ вариант каждого такого
    /// слова, оба не печатает (синхронно с rm_codec.py).
    static func firstVariant(_ ru: String) -> String {
        ru.split(separator: " ").map { token in
            token.contains("/")
                ? String(token.prefix(while: { $0 != "/" }))
                : String(token)
        }.joined(separator: " ")
    }

    /// Пунктуация v1.1: запятые — ноль бит, ЯЗЫКОВАЯ таблица правил
    /// рендера (у каждого языка свои); заглавная после терминала — там же.
    static let commaBefore: [String: Set<String>] = [
        "ru": ["если", "но", "потому", "чтобы", "когда", "хотя", "иначе",
               "который", "которая"],
        "en": ["but", "because", "although", "otherwise", "which"],
    ]
    static let boundaryMark: [String: String] = [
        "sent_end": ".", "sent_question": "?", "sent_exclaim": "!",
    ]
    /// Display-подмены грамматики: слой отображения, словарь не трогаем.
    static let opDisplay: [String: [String: String]] = [
        "ru": ["op_emphasis": "точно"],
        "en": ["op_emphasis": "for sure"],
    ]

    /// Ф5: относительные времена рендерятся ОТ метки отправки —
    /// в store-and-forward «через час» у получателя значит не то, что
    /// у отправителя. «через 1 час» → «через 1 час (к HH:MM)».
    /// Чистая функция: от текущего времени НЕ зависит (тест +4ч).
    nonisolated static func applySentTime(_ text: String,
                                          sentAtMinutes: UInt32,
                                          lang: String,
                                          timeZone: TimeZone = .current) -> String {
        guard sentAtMinutes > 0 else { return text }
        let sent = Date(timeIntervalSince1970: Double(sentAtMinutes) * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func clock(_ offsetMinutes: Int) -> String {
            let d = sent.addingTimeInterval(Double(offsetMinutes) * 60)
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        // идемпотентность: уже проставленную метку не дублируем
        if text.contains("(к ") { return text }
        let patterns: [(NSRegularExpression, Int)] = [
            (try! NSRegularExpression(pattern:
                lang == "en" ? #"in (\d+) hours?"# : #"через (\d+) час[а-яё]*"#), 60),
            (try! NSRegularExpression(pattern:
                lang == "en" ? #"in (\d+) minutes?"# : #"через (\d+) минут[а-яё]*"#), 1),
        ]
        // «через час» без числа (диктовка) — час один
        if lang == "ru", let bare = try? NSRegularExpression(
                pattern: #"через час(?!\S)"#) {
            let matches = bare.matches(in: text,
                range: NSRange(text.startIndex..., in: text)).reversed()
            var patched = text
            for m in matches {
                guard let r = Range(m.range, in: patched) else { continue }
                patched.replaceSubrange(r, with:
                    patched[r] + " (к " + clock(60) + ")")
            }
            if patched != text { return patched }
        }
        var result = text
        for (regex, unit) in patterns {
            let matches = regex.matches(in: result,
                range: NSRange(result.startIndex..., in: result)).reversed()
            for m in matches {
                guard let full = Range(m.range, in: result),
                      let g = Range(m.range(at: 1), in: result),
                      let n = Int(result[g]) else { continue }
                result.replaceSubrange(full, with:
                    result[full] + " (к " + clock(n * unit) + ")")
            }
        }
        return result
    }

    /// Языковое правило: [in][num][hour/minute] — относительное время,
    /// по-русски «через N …», не «в N …» (живой прогон 29.07).
    private static let relTimeUnits: Set<String> = ["hour", "hours",
                                                    "minute", "minutes"]

    private func markRelativeTime(_ units: [Unit],
                                  lang: String) -> [Unit] {
        guard lang == "ru", units.count >= 3 else { return units }
        var out = units
        for i in 0..<(out.count - 2) {
            if case .code(let a) = out[i], entries[a]?.en == "in",
               case .num = out[i + 1],
               case .code(let c) = out[i + 2],
               let en = entries[c]?.en, Self.relTimeUnits.contains(en) {
                out[i] = .lit("через")
            }
        }
        return out
    }

    func render(_ units: [Unit], lang: String = "ru") -> String {
        let units = markRelativeTime(units, lang: lang)
        var out: [String] = []
        for unit in units {
            switch unit {
            case .code(let code):
                guard let e = entries[code] else { continue }
                if let mark = Self.boundaryMark[e.en] {
                    out.append(mark)   // границы — знаком в любом языке
                    continue
                }
                if let sub = Self.opDisplay[lang]?[e.en] {
                    out.append(sub)
                    continue
                }
                if lang == "en" {
                    // EN-разворот: en-имена и есть английские слова;
                    // RU_DROP-аналог не нужен. Протекты — человечно:
                    // подчёркивания в пробелы, display-карта для SOS
                    out.append(Self.enDisplay[e.en]
                        ?? e.en.replacingOccurrences(of: "_", with: " "))
                    continue
                }
                // Служебные глотаются ВСЕГДА, даже если у них есть ru
                // (правило нового rm_codec.py)
                if Self.ruDrop.contains(e.en) { continue }
                out.append(e.ru.map(Self.firstVariant) ?? e.en)
            case .num(let n):
                out.append(String(n))
            case .amount(let n, let iso):
                let names = lang == "ru" ? Self.currencyRU : Self.currencyEN
                out.append("\(n) \(names[iso] ?? iso)")   // экзотика — ISO-кодом
            case .time(let minutes):
                out.append(String(format: "%02d:%02d",
                                  minutes / 60, minutes % 60))
            case .phrase(let id):
                if let p = phrases[id] {
                    out.append(lang == "en" ? p.en : p.ru)
                } else {
                    out.append("фраза#\(id)")   // рассинхрон таблиц фраз
                }
            case .emoji(let symbol):
                out.append(symbol)     // символом, никогда словом
            case .ext(let index):
                // будущий код, неизвестный этой версии: честный фоллбэк
                out.append("⟨расширение \(index)⟩")
            case .lit(let s):
                out.append(s)
            case .name(let s):
                // имя всегда с заглавной — независимо от регистра в блобе
                // (ферма 28.07: имена доходили строчными)
                out.append(s.prefix(1).uppercased() + s.dropFirst())
            }
        }
        var text = out.joined(separator: " ")
        // терминальные знаки клеятся к предыдущему слову
        for mark in [".", "?", "!"] {
            text = text.replacingOccurrences(of: " " + mark, with: mark)
        }
        // запятые по языковой таблице (не в начале предложения)
        let comma = Self.commaBefore[lang] ?? []
        var words = text.split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
        for index in words.indices where index > 0 {
            let bare = words[index].lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,"))
            let prev = words[index - 1]
            if comma.contains(bare), let last = prev.last,
               !".?!,".contains(last) {
                words[index - 1] = prev + ","
            }
        }
        text = words.joined(separator: " ")
        // заглавная в начале и после каждого терминального знака
        var result = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch != " " {
                // как python: поднимается первый СИМВОЛ сегмента
                // (цифра — no-op), а не первая буква
                result.append(ch.isLetter ? Character(ch.uppercased()) : ch)
                capitalizeNext = false
            } else {
                result.append(ch)
            }
            if ch == "." || ch == "?" || ch == "!" { capitalizeNext = true }
        }
        return result
    }
}

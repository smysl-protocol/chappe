import Foundation
import CryptoKit

// ============================================================================
// Демо-чат с человеком + приватная ветка шёпота (sophie_presence §3, фаза 2б).
//
// Мессенджера ещё нет (узлы не подключены), но механика честная:
//  - исходящее сообщение реально кодируется в envelope TEXT и встаёт в
//    персистентную очередь со статусом «в очереди» — уйдёт, когда появится
//    транспорт (offline-first семантика transport_manager.md);
//  - шёпоты живут в ОТДЕЛЬНОМ файле (приватная локальная ветка §3.2):
//    общий лог чата их не содержит по построению — экспорт/пересылка лога
//    физически не может захватить шёпот.
// ============================================================================

// ============================================================================
// ЖЁСТКОЕ ПРАВИЛО ХРАНИЛИЩ ИСТОРИИ (после инцидента 28.07.2026):
// 1. Ошибка декода НИКОГДА не приводит к потере или пересозданию
//    истории: битые записи скипаются поэлементно с логом, остальное
//    живёт (SafeHistoryDecoder).
// 2. Файл, не разобравшийся целиком, СНАЧАЛА копируется в *.corrupt-*
//    и только потом лента продолжает с тем, что удалось прочесть.
// 3. Миграции полей — ТОЛЬКО аддитивные и optional с дефолтами
//    (пример: stopped/sentAt/deliveredAt читаются как nil из старых
//    записей). Переименование/удаление полей запрещено.
// ============================================================================

/// Поэлементный декод массивов истории: одна битая запись не роняет всё.
nonisolated enum SafeHistoryDecoder {

    /// nil — данные вообще не JSON-массив (файл повреждён целиком).
    static func decodeArray<T: Decodable>(_ type: T.Type, from data: Data,
                                          label: String) -> [T]? {
        let decoder = JSONDecoder()
        if let whole = try? decoder.decode([T].self, from: data) {
            return whole                       // быстрый путь
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let array = raw as? [Any] else {
            print("[история] \(label): файл не разобрался как массив")
            return nil
        }
        var out: [T] = []
        var dropped = 0
        for element in array {
            if let elementData = try? JSONSerialization.data(withJSONObject: element),
               let value = try? decoder.decode(T.self, from: elementData) {
                out.append(value)
            } else {
                dropped += 1
            }
        }
        if dropped > 0 {
            print("[история] \(label): пропущено битых записей: \(dropped), "
                + "живых: \(out.count)")
        }
        return out
    }

    /// Файл не разобрался целиком → копия в сторонку, оригинал не трогаем.
    static func quarantine(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.copyItem(at: url, to: copy)
        print("[история] повреждённый файл скопирован: \(copy.lastPathComponent)")
    }
}

/// Запись ленты демо-чата.
/// Миграции полей — только аддитивные optional (правило выше).
nonisolated struct ChatEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case outgoing          // своё сообщение человеку (через envelope)
        case incoming          // принято от собеседника (веха, фаза 3)
        case whisperQuestion   // шёпот: вопрос Софи (видно только вам)
        case whisperAnswer     // шёпот: ответ Софи (видно только вам)
    }
    let id: UUID
    let kind: Kind
    var text: String
    /// created: момент записи/одобрения человеком.
    let date: Date
    /// Для outgoing: статус доставки и размер envelope-пакета(ов).
    var status: String?
    var envelopeBytes: Int?
    var stopped: Bool?
    /// Постановка в эфир (транспорт реально отправил). nil — ещё в
    /// очереди. Если > created на минуту — лента показывает оба времени.
    var sentAt: Date?
    /// Подтверждение получателя. nil — не доставлено. Появится с
    /// транспортом; поле и рендер готовы заранее.
    var deliveredAt: Date?
    /// Смысловые коды отправленного (Smysl-blob) — для развёртки
    /// пузыря на выбранном языке (Dev-тумблер RU/EN). nil — текстовое.
    var semanticBlob: [UInt8]?
    /// Запись связана с SOS (мой сигнал, отбой, ответ на мой сигнал,
    /// принятый чужой сигнал) — красная подсветка пузыря. Красный
    /// зарезервирован только под SOS и тревогу. Optional — старые
    /// записи читаются как nil (= false).
    var sosRelated: Bool?
    /// Момент ПРИХОДА входящего на это устройство (полевой дефект
    /// 13.08): `date` — время ОТПРАВКИ с полом минуты, оно бывает
    /// РАНЬШЕ последнего открытия чата (пол минуты, задержка релея) —
    /// счёт непрочитанного по нему молчал. Непрочитанное и подъём
    /// чата в списке считаются по приходу; лента — по-прежнему по
    /// отправке. Аддитивный optional — старые записи читаются как nil.
    var receivedAt: Date?
    /// Каким каналом входящее ПРИШЛО («radio»/«nearby»/«relay»/«lan»)
    /// — честная метка транспорта на каждом входящем (поле 13.08,
    /// build 19: метки не было вовсе). Аддитивный optional.
    var receivedVia: String?

    /// `date` — для ВХОДЯЩИХ время ОТПРАВКИ из пакета (полевой прогон
    /// 10.08: залповая разгрузка приходила вперемешку — «500м, 350м,
    /// 750м и последним 700м», лента строилась по времени прихода).
    init(kind: Kind, text: String, status: String? = nil,
         envelopeBytes: Int? = nil, date: Date = Date()) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.date = date
        self.status = status
        self.envelopeBytes = envelopeBytes
        self.stopped = nil
        self.sentAt = nil
        self.deliveredAt = nil
        self.semanticBlob = nil
        self.sosRelated = nil
        self.receivedAt = nil
        self.receivedVia = nil
    }

    var isSOSRelated: Bool { sosRelated == true }

    /// Текст пузыря на языке развёртки: для семантических — развёртка
    /// кодов словарём (получательский взгляд, в т.ч. loopback-эхо своих
    /// пузырей); ru — сохранённый текст (финал петли богаче машинной
    /// развёртки). Отправка от языка не зависит — коды одни.
    func displayText(language: String) -> String {
        guard language != "ru", let blob = semanticBlob,
              let codec = RMCodec.shared,
              let raw = codec.unwrapWire(blob),   // сверка версии словаря
              let units = try? codec.decode(raw) else { return text }
        return codec.render(units, lang: language)
    }

    /// Зеркало получателя: свой блоб через ПРИЁМНЫЙ путь — чистая
    /// развёртка таблицей, без смысловой петли. Показывает расхождение
    /// «гладкий русский у меня — пиджин у него» прямо в пузыре.
    /// nil — сообщение текстовое (дойдёт дословно) или блоб не читается.
    func receiverMirror(language: String = "ru") -> String? {
        guard let blob = semanticBlob,
              let codec = RMCodec.shared,
              let raw = codec.unwrapWire(blob),   // сверка версии словаря
              let units = try? codec.decode(raw) else { return nil }
        return codec.render(units, lang: language)
    }

    var isWhisper: Bool { kind == .whisperQuestion || kind == .whisperAnswer }
    var isStopped: Bool { stopped == true }

    /// Строка времени под пузырём: created HH:MM; лежало в очереди
    /// дольше минуты до эфира — «записано HH:MM · отправлено HH:MM».
    /// Входящее, ПРИШЕДШЕЕ спустя минуту и больше после отправки
    /// (BLE-пачки, релейный ящик), несёт «· получено HH:MM» — просьба
    /// владельца 13.08: иначе задержка доставки невидима.
    var timeLine: String {
        let created = Self.hhmm(date)
        if let sentAt, sentAt.timeIntervalSince(date) > 60 {
            return "записано \(created) · отправлено \(Self.hhmm(sentAt))"
        }
        if kind == .incoming, let receivedAt,
           receivedAt.timeIntervalSince(date) > 60 {
            return "\(created) · получено \(Self.hhmm(receivedAt))"
        }
        return created
    }

    /// Строка под ВХОДЯЩИМ пузырём: слово канала прихода + время
    /// (поле 13.08, build 19: у входящих не было метки транспорта).
    var incomingTimeLine: String {
        guard let word = Self.pathWord(receivedVia) else { return timeLine }
        return word + " · " + timeLine
    }

    /// Честный хинт недоставки (мега-3, 14.08): исходящее ушло в канал,
    /// но подтверждения нет дольше минуты — пузырь говорит об этом
    /// словами, а не молчит жёлтой отметкой. Доставленных и свежих
    /// не касается; чистая функция — под замком.
    func undeliveredHint(now: Date = Date()) -> String? {
        guard kind == .outgoing, deliveredAt == nil, sentAt != nil,
              now.timeIntervalSince(sentAt ?? now) > 60 else { return nil }
        return "пока не доставлено — ждём собеседника"
    }

    /// Хвост статусной строки доставки: «доставлено HH:MM».
    var deliveredLine: String? {
        deliveredAt.map { "доставлено \(Self.hhmm($0))" }
    }

    /// Прочитано получателем (приходит отметкой класса READ).
    var readAt: Date?
    /// msgID конверта — по нему сопоставляются ACK и отметка прочтения.
    var wireMsgID: Int?
    /// Каким путём фактически ушло (фаза 1 «рядом», 07.08): "nearby" /
    /// "relay" / "radio" / "lan". Аддитивный optional — старые записи
    /// читаются как nil и слова пути не показывают. Это ФАКТ доставки,
    /// не выбор пользователя — выбора в интерфейсе не существует.
    var sentVia: String?

    /// Слово пути для ленты: транспортных терминов в UI нет — только
    /// «как ушло» человеческим словом. lan — репетиция «рядом» по сети.
    static func pathWord(_ via: String?) -> String? {
        switch via {
        case "nearby", "lan": "рядом"
        case "relay": "через интернет"
        case "radio": "по радио"
        default: nil
        }
    }

    /// Две отметки по схеме владельца (02.08): «время отправки /
    /// время доставки». Цвет несёт состояние, как две галочки:
    /// жёлтая отправка → серая, когда доставлено; жёлтая доставка →
    /// зелёная, когда прочитано.
    /// Время пузыря НЕИЗМЕННО — момент нажатия (блок 1, 10.08):
    /// раньше показывался sentAt, и удавшийся позже другой путь
    /// перештамповывал пузырь новым временем («через интернет·10:11»
    /// превращалось в «по радио·10:14», полевой разбор 09.08).
    var stampSent: String { Self.hhmm(date) }
    var stampDelivered: String? { deliveredAt.map(Self.hhmm) }
    enum StampState { case queued, sent, delivered, read }
    var stampState: StampState {
        if readAt != nil { return .read }
        if deliveredAt != nil { return .delivered }
        if sentAt != nil { return .sent }
        return .queued
    }

    static func hhmm(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute],
                                                    from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

nonisolated enum HumanChatStore {

    private static func url(_ name: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Chats", isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Полное стирание ВСЕЙ переписки (начать заново, 12.08): удаляет
    /// весь каталог Chats и забывает кэш lastGood — ни один чат не
    /// воскреснет. Зовётся из AppReset вместе со сбросом личности.
    static func purgeEverything() {
        lastGood.clearAll()
        if let dir = try? url("x").deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
        UserDefaults.standard.removeObject(forKey: readKey)
    }

    /// Файлы истории: nil — демо-собеседник (прежние имена),
    /// иначе — по отпечатку контакта (веха, фаза 2).
    static func logFile(_ contactID: String?) -> String {
        contactID.map { "chat_c_\($0).json" } ?? "chat_demo.json"
    }
    static func whispersFile(_ contactID: String?) -> String {
        contactID.map { "chat_c_\($0)_whispers.json" } ?? "chat_demo_whispers.json"
    }

    // Общий лог чата (только outgoing) и приватная ветка шёпота —
    // РАЗНЫЕ файлы: изоляция ветки — свойство хранилища, не UI.
    static func loadLog(contactID: String? = nil) -> [ChatEntry] {
        load(logFile(contactID))
    }
    static func saveLog(_ entries: [ChatEntry], contactID: String?) {
        save(entries.filter { !$0.isWhisper }, logFile(contactID))
    }
    static func loadWhispers(contactID: String? = nil) -> [ChatEntry] {
        load(whispersFile(contactID))
    }
    static func saveWhispers(_ entries: [ChatEntry], contactID: String?) {
        save(entries.filter(\.isWhisper), whispersFile(contactID))
    }

    // WP1 (02.08, регрессия «пропадает история»): единственная безопасная
    // запись для владельцев СНИМКА (вью-модель чата) — слияние по id с
    // тем, что на диске СЕЙЧАС. Полная перезапись файла снимком стирала
    // всё, что параллельно дописал DeliveryManager (входящие, статусы
    // доставки): последний пишущий побеждал. Прошлый фикс (24eb201)
    // закрывал потерю на ЧТЕНИИ (битый файл) — эта дыра была на записи.

    /// Вставить или обновить одну запись лога, не трогая остальные.
    static func upsertLog(_ entry: ChatEntry, contactID: String?) {
        guard !entry.isWhisper else { return }
        var log = loadLog(contactID: contactID)
        if let i = log.firstIndex(where: { $0.id == entry.id }) {
            log[i] = entry
        } else {
            log.append(entry)
            log.sort { $0.date < $1.date }
        }
        saveLog(log, contactID: contactID)
    }

    /// То же для приватной ветки шёпота.
    static func upsertWhisper(_ entry: ChatEntry, contactID: String?) {
        guard entry.isWhisper else { return }
        var log = loadWhispers(contactID: contactID)
        if let i = log.firstIndex(where: { $0.id == entry.id }) {
            log[i] = entry
        } else {
            log.append(entry)
            log.sort { $0.date < $1.date }
        }
        saveWhispers(log, contactID: contactID)
    }

    // MARK: Непрочитанные и порядок чатов (замечание владельца 02.08)

    private static let readKey = "chat.lastReadAt"

    /// Момент, когда чат последний раз открывали.
    static func lastReadAt(contactID: String?) -> Date {
        let key = contactID ?? "demo"
        let all = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Double]
        return Date(timeIntervalSince1970: all?[key] ?? 0)
    }

    static func markRead(contactID: String?) {
        let key = contactID ?? "demo"
        var all = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Double] ?? [:]
        all[key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(all, forKey: readKey)
    }

    /// Полное стирание переписки контакта (удаление = чистый лист,
    /// 12.08): основной лог + шёпоты + отметка прочтения. КЛЮЧЕВОЕ:
    /// забыть кэш lastGood и УДАЛИТЬ файлы, а НЕ писать пусто — иначе
    /// load() сочтёт пустой файл порчей и вернёт историю из кэша
    /// (корень воскрешения удалённого чата). Ключи/рэтчет/позиции/
    /// очередь чистит ContactPurge отдельно (разные сторы).
    static func purge(contactID: String) {
        for name in [logFile(contactID), whispersFile(contactID)] {
            lastGood.forget(name)                 // без этого кэш воскрешает
            if let url = try? url(name) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        var all = UserDefaults.standard.dictionary(forKey: readKey)
            as? [String: Double] ?? [:]
        all[contactID] = nil
        UserDefaults.standard.set(all, forKey: readKey)
    }

    /// Сколько ВХОДЯЩИХ пришло после последнего открытия чата.
    /// Счёт по моменту ПРИХОДА (receivedAt), не по дате отправки:
    /// date — пол минуты отправителя и бывает РАНЬШЕ последнего
    /// открытия чата — счётчик молчал (полевой дефект 13.08,
    /// «ни уведомления, ни индикатора»). Старые записи без receivedAt
    /// читаются по date, как раньше.
    static func unreadCount(contactID: String?) -> Int {
        let since = lastReadAt(contactID: contactID)
        return loadLog(contactID: contactID)
            .filter { $0.kind == .incoming
                && ($0.receivedAt ?? $0.date) > since }
            .count
    }

    /// Время последней активности чата — по нему список сортируется.
    /// Тоже по ПРИХОДУ: запоздалое сообщение поднимает чат сейчас,
    /// а не «час назад» (лента внутри чата — по-прежнему по отправке).
    static func lastActivity(contactID: String?) -> Date? {
        loadLog(contactID: contactID)
            .map { $0.receivedAt ?? $0.date }
            .max()
    }

    /// Переезд истории при смене ключа контакта (WP1 05.08): id чата =
    /// отпечаток ключа, новый ключ = новый id — без переезда переписка
    /// становилась недостижимой. Слияние по id записей, не перезапись.
    static func migrateHistory(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        for entry in loadLog(contactID: oldID) {
            upsertLog(entry, contactID: newID)
        }
        for entry in loadWhispers(contactID: oldID) {
            upsertWhisper(entry, contactID: newID)
        }
        saveLog([], contactID: oldID)
        saveWhispers([], contactID: oldID)
        // отметка прочтения переезжает, непрочитанные не «вспыхивают»
        var all = UserDefaults.standard.dictionary(forKey: readKey)
            as? [String: Double] ?? [:]
        if let read = all[oldID], all[newID] == nil {
            all[newID] = read
            UserDefaults.standard.set(all, forKey: readKey)
        }
    }

    /// Удаление записи шёпота («Скрыть») — тоже через диск, не снимок.
    static func removeWhisper(id: UUID, contactID: String?) {
        var log = loadWhispers(contactID: contactID)
        log.removeAll { $0.id == id }
        saveWhispers(log, contactID: contactID)
    }

    static func loadLog() -> [ChatEntry] { load("chat_demo.json") }
    static func saveLog(_ entries: [ChatEntry]) {
        save(entries.filter { !$0.isWhisper }, "chat_demo.json")
    }

    static func loadWhispers() -> [ChatEntry] { load("chat_demo_whispers.json") }
    static func saveWhispers(_ entries: [ChatEntry]) {
        save(entries.filter(\.isWhisper), "chat_demo_whispers.json")
    }

    /// Черновик — свой на чат (решение дизайн-сессии).
    static var draft: String {
        get { UserDefaults.standard.string(forKey: "chat_demo_draft") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "chat_demo_draft") }
    }

    /// Последнее непустое состояние каждого файла: лента НИКОГДА не
    /// показывает пусто, если в хранилище есть записи (баг 29.07:
    /// экран пустел на минуту во время обмена). Защита от читающих
    /// гонок; маркер в лог — для поимки корня в поле.
    private static let lastGood = LastGoodCache()

    private static func load(_ name: String) -> [ChatEntry] {
        guard let url = try? url(name) else { return [] }
        for attempt in 0..<2 {
            guard let data = try? Data(contentsOf: url) else { break }
            if let entries = SafeHistoryDecoder.decodeArray(
                    ChatEntry.self, from: data, label: name) {
                if !entries.isEmpty { lastGood.set(name, entries) }
                if entries.isEmpty, let cached = lastGood.get(name) {
                    lastGood.bumpMarker()
                    DictationDebugLog.stage(
                        "история: пустой декод при непустом кэше (\(name))")
                    return cached
                }
                return entries
            }
            if attempt == 0 { continue }   // микро-гонка atomic-replace
            // файл не разобрался и после повтора — карантин, но ленте
            // отдаём последнее хорошее состояние, не пустоту
            SafeHistoryDecoder.quarantine(url)
        }
        if let cached = lastGood.get(name) {
            lastGood.bumpMarker()
            DictationDebugLog.stage("история: чтение сорвалось, кэш (\(name))")
            return cached
        }
        return []
    }

    /// Сколько раз лента спасалась кэшем (Dev-экран: обязан молчать).
    static var emptyReadMarkers: Int { lastGood.markers }

    /// Потокобезопасный кэш последних непустых историй.
    private final class LastGoodCache: @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: [ChatEntry]] = [:]
        private var markerCount = 0
        var markers: Int { lock.lock(); defer { lock.unlock() }
                           return markerCount }
        func bumpMarker() { lock.lock(); markerCount += 1; lock.unlock() }
        func set(_ key: String, _ value: [ChatEntry]) {
            lock.lock(); store[key] = value; lock.unlock()
        }
        func get(_ key: String) -> [ChatEntry]? {
            lock.lock(); defer { lock.unlock() }; return store[key]
        }
        /// Забыть «последнее хорошее» — при НАСТОЯЩЕМ стирании чата
        /// (удаление контакта). Иначе пустой файл считается порчей и
        /// история воскресает из кэша (корень воскрешения 12.08).
        func forget(_ key: String) {
            lock.lock(); store[key] = nil; lock.unlock()
        }
        /// Забыть весь кэш — «начать заново» (AppReset).
        func clearAll() {
            lock.lock(); store.removeAll(); lock.unlock()
        }
    }

    private static func save(_ entries: [ChatEntry], _ name: String) {
        guard let url = try? url(name) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        // Б1-корень (29.07): запись НИКОГДА не идёт поверх боевого
        // файла — временный в ТОМ ЖЕ каталоге + атомарная подмена
        // replaceItemAt: читатель в любой момент видит либо старую,
        // либо новую версию целиком, никогда обрывок.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-" + url.lastPathComponent
                                    + "-" + UUID().uuidString)
        do {
            try data.write(to: tmp, options: [])
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            // деградация: старое поведение лучше потери записи
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Очередь исходящих (offline-first)

/// Исходящее кодируется в envelope TEXT сразу; пакеты ждут транспорт.
/// Когда подключатся узлы, очередь начнёт разгружаться менеджером
/// доставки (transport_manager.md) — статусная строка уже честная.
// Ревизия параллелизма 06.08: `nonisolated` снят — очередь отправки
// изолирована MainActor (умолчание проекта). Компилятор больше не
// молчит: фоновый вызов теперь ошибка сборки, а не молчаливая гонка,
// цена которой — потеря или дубль отправки.
enum Outbox {

    struct QueuedMessage: Codable, Sendable {
        let entryID: UUID
        let msgID: UInt16
        var packetsHex: [String]
        let totalBytes: Int
        /// Адресат (веха, фаза 3): nil — демо (никуда не шлём).
        var contactID: String?
        /// Хотя бы раз реально ушло в канал (ждём ack).
        /// Аддитивные optional-поля — миграции только вперёд.
        var sent: Bool?
        /// Надёжность доставки: попытки передачи и время последней —
        /// повтор с растущей паузой, пока не придёт ack.
        var attempts: Int?
        var lastAttemptAt: Date?
        /// false — ack не ожидается (SOS/BEACON: конверт не несёт для
        /// них ack-флага): запись покидает очередь после первой
        /// успешной передачи. nil = true (старые записи ждут ack).
        var expectAck: Bool?

        // — Релейный путь (05.08). Все поля аддитивные optional:
        //   миграции только вперёд, старые очереди читаются как есть.
        /// v2-поток для релея (hex). Рамка с dst собирается В МОМЕНТ
        /// отправки — псевдоним живёт эпоху, сообщение в очереди дольше.
        var relayStreamHex: String?
        /// Куда лёг кадр (для наблюдения судьбы): псевдоним, эпоха,
        /// момент 200-го ответа и сами кадры (сверка «ещё лежит?»).
        var relayDstHex: String?
        var relayEpoch: Int?
        var relayStoredAt: Date?
        var relayFramesHex: [String]?
        /// Релейный путь завершён (доставлено/410/невозможно) —
        /// больше не трогать.
        var relayDone: Bool?
        /// Момент ПЕРВОЙ попытки по живому пути (блок 1, 10.08):
        /// от него радио отсчитывает буксовку быстрых путей.
        /// Аддитивный optional — миграции только вперёд.
        var firstAttemptAt: Date?
        /// Позиционный маячок рев B (кодек 7 внутри sealed): новый
        /// вытесняет недоставленный старый — прошлые позиции в очереди
        /// не копятся. Аддитивный optional.
        var positionBeacon: Bool?
        /// Сколько раз канал ПОДТВЕРДИЛ передачу (didWriteValueFor и
        /// т.п.) без ответного ack (мега-8: собеседник со сброшенной
        /// личностью принимает байты, но расшифровать не может — ack
        /// не родится никогда). Аддитивный optional.
        var confirmedSends: Int?

        var expectsAck: Bool { expectAck != false }
    }

    /// Готовые envelope-пакеты (SOS, BEACON, LOCATION) — в очередь
    /// контакту как есть, без sealed-обёртки: SOS по спеке не шифруется.
    @discardableResult
    static func enqueueRaw(packets: [[UInt8]], msgID: UInt16,
                           entryID: UUID, contactID: String?,
                           expectAck: Bool) -> QueuedMessage {
        let queued = QueuedMessage(
            entryID: entryID,
            msgID: msgID,
            packetsHex: packets.map {
                $0.map { String(format: "%02x", $0) }.joined()
            },
            totalBytes: packets.reduce(0) { $0 + $1.count },
            contactID: contactID,
            expectAck: expectAck)
        var all = loadQueue()
        all.append(queued)
        saveQueue(all)
        return queued
    }

    /// Запечатанное адресное исходящее (веха, фаза 3): payload =
    /// sealed([мой pubkey 32][кодек][данные]) — на проводе только байты.
    ///
    /// Envelope v2 (02.08): при ПОДТВЕРЖДЁННОЙ сессии рэтчета уходит
    /// кодек 4 (v2-рамка, −70 Б обвязки); подтверждения нет — v1 как
    /// раньше (деградация WP3) плюс, единожды, отдельный probe-пакет
    /// рукопожатия: старый получатель его явно отвергнет на заголовке,
    /// новый — примет эпоху и следующим же ответом подтвердит v2.
    /// Содержимое всегда едет v1 — probe ничего не теряет.
    static func enqueueSealed(innerCodec: UInt8, data: [UInt8],
                              to contact: Contact,
                              entryID: UUID,
                              wantAck: Bool = true,
                              positionBeacon: Bool = false) throws
    -> QueuedMessage {
        // маячок: недоставленный старый вытесняется новым (подпись п.6;
        // эфир не тратится на устаревшие точки)
        if positionBeacon {
            mutateQueue { queue in
                queue.removeAll { $0.contactID == contact.id
                    && $0.positionBeacon == true }
            }
        }
        guard let recipientKey = contact.publicKey,
              let myKey = Identity.publicKey() else {
            throw EnvelopeError.badValue("нет ключей для запечатывания")
        }
        let nowMinutes = UInt32(Date().timeIntervalSince1970 / 60)

        // ── Ревизия B (подпись шва, п.1/п.5): выбор кодека ─────────────
        // 6 — живая сессия, собеседник доказал session2-кадром;
        // 5 — известная пара без сессии, собеседник доказал рев B;
        // 3 — первый кадр новой пары / рукопожатие (заморожен);
        // иначе — старый путь (v1 + probe / кодек 4) без изменений.
        // seq присваивается ЗДЕСЬ вместе с msgID и не перештамповывается
        // (повторы шлют те же байты) — подпись п.2.
        let caps = PeerCaps.load(contactID: contact.id)
        let nowSeconds = UInt32(clamping: Int(Date().timeIntervalSince1970))

        if caps.session2, var epoch = RatchetStore.load(contactID: contact.id) {
            let msgID = Envelope.newMsgID()
            if epoch.shouldRekey {
                // ре-ключ: рукопожатие (кодек 3, заморожен) несёт сообщение
                let seed = Self.randomSeed()
                var fresh = RatchetEpoch(seed: seed, iAmInitiator: true)
                fresh.peerConfirmedV2 = true
                let stream = try RatchetHandshake.make(
                    seed: seed, to: recipientKey,
                    myPub: Array(myKey.rawRepresentation),
                    innerCodec: innerCodec, data: data,
                    sentAtMinutes: nowMinutes)
                let packets = try EnvelopeV2.encodePackets(
                    msgID: msgID, stream: stream, wantAck: wantAck)
                RatchetStore.save(fresh, contactID: contact.id)
                return enqueuePackets(packets, entryID: entryID,
                                      contactID: contact.id, msgID: msgID,
                                      relayStreamHex: hex(stream),
                                      wantAck: wantAck,
                                      positionBeacon: positionBeacon)
            }
            let seq = SeqStore.next(contactID: contact.id)
            do {
                let stream = try epoch.sealMessage2(
                    innerCodec: innerCodec, data: data,
                    sentAtSeconds: nowSeconds, seq: seq)
                RatchetStore.save(epoch, contactID: contact.id)
                let packets = try EnvelopeV2.encodePackets(
                    msgID: msgID, stream: stream, wantAck: wantAck)
                return enqueuePackets(packets, entryID: entryID,
                                      contactID: contact.id, msgID: msgID,
                                      relayStreamHex: hex(stream),
                                      wantAck: wantAck,
                                      positionBeacon: positionBeacon)
            } catch RatchetError.sessionRefreshNeeded {
                // потолок счётчика (замок п.4 ревью): эпоха переигрывается
                // рукопожатием, сообщение едет в нём
                let seed = Self.randomSeed()
                var fresh = RatchetEpoch(seed: seed, iAmInitiator: true)
                fresh.peerConfirmedV2 = true
                let stream = try RatchetHandshake.make(
                    seed: seed, to: recipientKey,
                    myPub: Array(myKey.rawRepresentation),
                    innerCodec: innerCodec, data: data,
                    sentAtMinutes: nowMinutes)
                let packets = try EnvelopeV2.encodePackets(
                    msgID: msgID, stream: stream, wantAck: true)
                RatchetStore.save(fresh, contactID: contact.id)
                return enqueuePackets(packets, entryID: entryID,
                                      contactID: contact.id, msgID: msgID,
                                      relayStreamHex: hex(stream))
            }
        }

        if caps.revB, let myPriv = Identity.privateKey() {
            // известная пара без сессии: sealed2 (кодек 5), тег Т1
            let msgID = Envelope.newMsgID()
            let seq = SeqStore.next(contactID: contact.id)
            let pairKey = try MailboxID.pairKey(myPrivate: myPriv,
                                                peerPublic: recipientKey)
            let epochNum = MailboxID.epoch(pairKey: pairKey, at: Date())
            let plaintext = RevBPrefix(sentAtSeconds: nowSeconds, seq: seq,
                                       innerCodec: innerCodec,
                                       data: data).encode()
            let stream = try E2ESeal2.seal(
                plaintext: plaintext, sender: myPriv, to: recipientKey,
                tag: E2ESeal2.senderTag(pairKey: pairKey, epoch: epochNum))
            let packets = try EnvelopeV2.encodePackets(
                msgID: msgID, stream: stream, wantAck: wantAck)
            guard Self.bigMessageAllowed(chunks: packets.count,
                                         peerRevB: caps.revB) else {
                throw EnvelopeError.badValue(
                    "сообщение слишком длинное для сборки собеседника — "
                    + "попросите его обновить приложение")
            }
            let queued = enqueuePackets(packets, entryID: entryID,
                                        contactID: contact.id, msgID: msgID,
                                        relayStreamHex: hex(stream),
                                        wantAck: wantAck,
                                        positionBeacon: positionBeacon)
            // сессии ещё нет — probe рукопожатия как на старом пути
            if RatchetStore.load(contactID: contact.id) == nil {
                enqueueProbe(to: recipientKey, myKey: myKey,
                             contactID: contact.id, nowMinutes: nowMinutes)
            }
            return queued
        }
        // ── конец ветки рев B ──────────────────────────────────────────

        if var epoch = RatchetStore.load(contactID: contact.id),
           epoch.peerConfirmedV2 {
            // msgID ЕДИН для пакетов «рядом»/радио и записи очереди:
            // релей рамкует поток item.msgID, и если он не совпадает с
            // msgID пакетов, дедуп получателя не гасит вторую копию, а
            // ack не находит запись очереди (полевой дубль 08.08:
            // один текст пришёл как 14678 и 25298)
            let msgID = Envelope.newMsgID()
            let packets: [[UInt8]]
            let stream: [UInt8]
            if epoch.shouldRekey {
                // ре-ключ K=100: новое рукопожатие несёт сообщение;
                // собеседник уже доказал v2 — подтверждение наследуется
                let seed = Self.randomSeed()
                var fresh = RatchetEpoch(seed: seed, iAmInitiator: true)
                fresh.peerConfirmedV2 = true
                stream = try RatchetHandshake.make(
                    seed: seed,
                    to: recipientKey,
                    myPub: Array(myKey.rawRepresentation),
                    innerCodec: innerCodec, data: data,
                    sentAtMinutes: nowMinutes)
                packets = try EnvelopeV2.encodePackets(
                    msgID: msgID, stream: stream, wantAck: true)
                RatchetStore.save(fresh, contactID: contact.id)
            } else {
                stream = try epoch.sealMessage(innerCodec: innerCodec,
                                               data: data,
                                               sentAtMinutes: nowMinutes)
                RatchetStore.save(epoch, contactID: contact.id)
                packets = try EnvelopeV2.encodePackets(
                    msgID: msgID, stream: stream, wantAck: true)
            }
            // релей возит тот же поток: те же байты обоими путями →
            // дубль гасится счётчиком рэтчета у получателя
            return enqueuePackets(packets, entryID: entryID,
                                  contactID: contact.id, msgID: msgID,
                                  relayStreamHex: hex(stream))
        }

        // v1-путь (как был) …
        let inner = Array(myKey.rawRepresentation) + [innerCodec] + data
        let sealed = try E2ESeal.seal(payload: inner, to: recipientKey)
        let msgID = Envelope.newMsgID()
        let packets = try TextEncoder.encodePackets(msgID: msgID,
                                                    payload: sealed,
                                                    wantAck: true)
        // Релей принимает только v2-рамки, поэтому для него то же
        // содержимое пакуется v2-sealed'ом ([ts][pub][кодек][данные]
        // под кодеком 3) С ТЕМ ЖЕ msgID: если дойдут оба варианта,
        // получатель погасит второй по msgID. Сессию это не трогает —
        // на session-кодек переходим только когда собеседник доказал,
        // что ЭПОХА у него есть (прислал session-сообщение).
        let ts = nowMinutes
        let relayInner: [UInt8] = [UInt8(ts & 0xFF), UInt8((ts >> 8) & 0xFF),
                                   UInt8((ts >> 16) & 0xFF), UInt8(ts >> 24)]
            + Array(myKey.rawRepresentation) + [innerCodec] + data
        // легаси-пир: >255 кусков не собрать — честный отказ (16≠255)
        guard Self.bigMessageAllowed(chunks: packets.count, peerRevB: false)
        else {
            throw EnvelopeError.badValue(
                "сообщение слишком длинное для сборки собеседника — "
                + "попросите его обновить приложение")
        }
        let relayStream = try? E2ESeal.seal(payload: relayInner,
                                            to: recipientKey)
        let queued = enqueuePackets(packets, entryID: entryID,
                                    contactID: contact.id, msgID: msgID,
                                    relayStreamHex: relayStream.map(hex))

        // … + однократный probe нового сеанса (эпоха без подтверждения).
        // Probe — уже v2-поток, релей возит его как есть: собеседник,
        // приняв его, получает эпоху и отвечает session-кодеком — тот же
        // путь схождения v1 → v2, что и по радио.
        if RatchetStore.load(contactID: contact.id) == nil {
            enqueueProbe(to: recipientKey, myKey: myKey,
                         contactID: contact.id, nowMinutes: nowMinutes)
        }
        return queued
    }

    /// Гейт больших сообщений (закрытие FRAG «16≠255», мега-4):
    /// >255 кусков = FRAG2 (бит 5), старые приёмники его честно
    /// отвергают — слать можно только собеседнику с доказанным рев B.
    /// Находка ревизии: v2-тракт старых сборок (все полевые ≥9) капа
    /// 16 НЕ имеет — «режут на 16» относилось к v1-декодеру; разрыв
    /// 17…255 кусков не существует, гейтится только FRAG2.
    nonisolated static func bigMessageAllowed(chunks: Int,
                                              peerRevB: Bool) -> Bool {
        chunks <= EnvelopeV2.maxFragmentsU8 || peerRevB
    }

    /// Пустая проба рукопожатия (общая для v1-пути и ветки кодека 5):
    /// собеседник получает эпоху и отвечает session-кодеком.
    private static func enqueueProbe(
        to recipientKey: Curve25519.KeyAgreement.PublicKey,
        myKey: Curve25519.KeyAgreement.PublicKey,
        contactID: String, nowMinutes: UInt32) {
        let seed = Self.randomSeed()
        let epoch = RatchetEpoch(seed: seed, iAmInitiator: true)
        if let probe = try? RatchetHandshake.make(
            seed: seed, to: recipientKey,
            myPub: Array(myKey.rawRepresentation),
            innerCodec: Envelope.codecStore, data: [],   // пустая проба
            sentAtMinutes: nowMinutes),
           let probePackets = try? EnvelopeV2.encodePackets(
            msgID: Envelope.newMsgID(), stream: probe) {
            RatchetStore.save(epoch, contactID: contactID)
            _ = enqueuePackets(probePackets, entryID: UUID(),
                               contactID: contactID,
                               relayStreamHex: hex(probe))
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Сид эпохи рэтчета — криптографический секрет. WP5 (05.08):
    /// раньше сбой SecRandom игнорировался — в шифрование ушёл бы
    /// НУЛЕВОЙ сид. Теперь при сбое — CSPRNG CryptoKit (независимый
    /// источник; сам не возвращает ошибок).
    static func randomSeed() -> [UInt8] {
        var seed = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &seed)
                == errSecSuccess else {
            return SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
        }
        return seed
    }

    private static func enqueuePackets(_ packets: [[UInt8]], entryID: UUID,
                                       contactID: String,
                                       msgID: UInt16? = nil,
                                       relayStreamHex: String? = nil,
                                       wantAck: Bool = true,
                                       positionBeacon: Bool = false)
    -> QueuedMessage {
        var queued = QueuedMessage(
            entryID: entryID,
            msgID: msgID ?? Envelope.newMsgID(),
            packetsHex: packets.map {
                $0.map { String(format: "%02x", $0) }.joined()
            },
            totalBytes: packets.reduce(0) { $0 + $1.count },
            contactID: contactID,
            expectAck: wantAck ? nil : false,
            relayStreamHex: relayStreamHex)
        queued.positionBeacon = positionBeacon ? true : nil
        var all = loadQueue()
        all.append(queued)
        saveQueue(all)
        return queued
    }

    // Доступ менеджера доставки (фаза 3)
    static func loadQueueRaw() -> [QueuedMessage] { loadQueue() }
    static func saveQueueRaw(_ queue: [QueuedMessage]) { saveQueue(queue) }

    /// Выбросить из очереди все недоставленные исходящие контакта
    /// (удаление = чистый лист, 12.08): иначе насос повторов продолжал
    /// бы досылать сообщения удалённого собеседника.
    static func removeAll(contactID: String) {
        mutateQueue { queue in
            queue.removeAll { $0.contactID == contactID }
        }
    }
    static func bytes(fromHex hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            guard let end = hex.index(start, offsetBy: 2,
                                      limitedBy: hex.endIndex) else { return nil }
            return UInt8(hex[start..<end], radix: 16)
        }
    }

    /// Семантическое исходящее: TEXT-пакет с кодеком 2 (коды словаря).
    /// Всегда один пакет — по построению blob крошечный (десятки байт).
    static func enqueueSemantic(blob: [UInt8], entryID: UUID) throws -> QueuedMessage {
        let msgID = Envelope.newMsgID()
        let payload = [Envelope.codecSemantic] + blob
        guard Envelope.headerSize + payload.count <= Envelope.maxPayload else {
            throw EnvelopeError.badValue(
                "семантический пакет не влез: \(payload.count) байт")
        }
        let packet = Envelope.encodeHeader(msgClass: Envelope.classText,
                                           flags: Envelope.flagAckRequest,
                                           msgID: msgID) + payload
        let queued = QueuedMessage(
            entryID: entryID,
            msgID: msgID,
            packetsHex: [packet.map { String(format: "%02x", $0) }.joined()],
            totalBytes: packet.count)
        var all = loadQueue()
        all.append(queued)
        saveQueue(all)
        return queued
    }

    static func enqueue(text: String, entryID: UUID) throws -> QueuedMessage {
        let msgID = Envelope.newMsgID()
        // гейт размера: до 05.08 кодек по умолчанию (store) слал
        // длинный широковещательный текст в эфир вообще без сжатия
        let codec = TextCodec.best(text).codec
        let packets = try TextEncoder.encode(msgID: msgID, text: text,
                                             codec: codec, wantAck: true)
        let queued = QueuedMessage(
            entryID: entryID,
            msgID: msgID,
            packetsHex: packets.map { $0.map { String(format: "%02x", $0) }.joined() },
            totalBytes: packets.reduce(0) { $0 + $1.count })
        var all = loadQueue()
        all.append(queued)
        saveQueue(all)
        return queued
    }

    /// Единственная безопасная форма «прочитать-изменить-записать»
    /// (ревизия параллелизма 06.08). Атомарность даётся КОНСТРУКЦИЕЙ:
    ///  1) тип изолирован MainActor (см. объявление) — параллельных
    ///     входов не бывает;
    ///  2) замыкание СИНХРОННОЕ: вставить `await` внутрь критической
    ///     секции — ошибка компиляции, а не забытая дисциплина.
    /// Раньше вызывающие делали loadQueueRaw → правка → saveQueueRaw
    /// врозь: пока все были на главном акторе, это работало, но первый
    /// же фоновый вызов терял бы отправку или порождал дубль (тот же
    /// класс, что гонка первых PUT на релее, отчёт 05.08).
    @discardableResult
    static func mutateQueue<T>(_ body: (inout [QueuedMessage]) -> T) -> T {
        var queue = loadQueue()
        let result = body(&queue)
        saveQueue(queue)
        return result
    }

    static func loadQueue() -> [QueuedMessage] {
        guard let url = try? queueURL(),
              let data = try? Data(contentsOf: url) else { return [] }
        guard let queue = SafeHistoryDecoder.decodeArray(
            QueuedMessage.self, from: data, label: "outbox") else {
            SafeHistoryDecoder.quarantine(url)
            return []
        }
        return queue
    }

    private static func saveQueue(_ queue: [QueuedMessage]) {
        guard let url = try? queueURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(queue).write(to: url, options: .atomic)
    }

    private static func queueURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Chats", isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir.appendingPathComponent("outbox.json")
    }
}

// MARK: - Триггер шёпота (§3.1) — чистая логика, покрыта тестами

/// Правила: токен создаётся только РУЧНЫМ вводом («@» в начале слова →
/// подсказка; принятие — явный тап). Программные вставки текста
/// («В черновик») подсказку не создают. Удаление чипа мгновенно
/// возвращает обычный режим. «@» в середине слова — просто символ.
nonisolated enum WhisperTrigger {

    /// Изменение похоже на клавиатурный набор: текст дополнен с конца
    /// одним символом. Программная вставка (setText целиком) — нет.
    static func isKeyboardAppend(old: String, new: String) -> Bool {
        new.count == old.count + 1 && new.hasPrefix(old)
    }

    /// Показывать ли подсказку «@Софи»: последнее слово нового текста —
    /// «@», «@с», «@со»… или «@s», «@so»… — оба написания имени
    /// (AppIdentity.assistantAliases), регистр не важен: русский
    /// пользователь с русской раскладкой не должен промахнуться.
    /// Изменение обязано прийти с клавиатуры.
    static func shouldSuggest(old: String, new: String,
                              programmatic: Bool) -> Bool {
        guard !programmatic, isKeyboardAppend(old: old, new: new) else {
            return false
        }
        guard let lastWord = new.split(separator: " ",
                                       omittingEmptySubsequences: false).last,
              lastWord.hasPrefix("@") else { return false }
        let tail = lastWord.dropFirst().lowercased()
        // «@» без хвоста — уже подсказка; дальше хвост обязан быть
        // префиксом одного из написаний имени.
        return tail.isEmpty
            || AppIdentity.assistantAliases.contains { $0.hasPrefix(tail) }
    }

    /// Принятие подсказки: убрать набранный «@…»-хвост из текста
    /// (чип становится отдельным элементом композера).
    static func textAfterAccept(_ text: String) -> String {
        guard let range = text.range(of: "@", options: .backwards) else {
            return text
        }
        return String(text[..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
    }
}

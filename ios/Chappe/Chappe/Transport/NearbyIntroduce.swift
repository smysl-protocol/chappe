import Foundation
import Combine
import CryptoKit

// ============================================================================
// Знакомство одним баннером (решение владельца 08.08, «пять находок» п.3).
//
// Вместо двух сканирований QR: один человек открывает экран «Мой QR» —
// и пока экран открыт, его карточка (имя + публичный ключ) объявляется
// в BLE-эфир телефонам рядом. У соседа с открытым приложением всплывает
// баннер «Рядом кто-то с именем "X"». Согласие → контакт добавлен и в
// ответ уходит своя карточка; на открытом экране знакомства первый
// видит встречный баннер — и оба знакомы за одно нажатие каждый.
//
// Границы, зафиксированные владельцем:
//  - контакт из баннера рождается «непроверен» — эфир не защищён от
//    подмены при первом контакте; сверка отпечатков остаётся отдельным
//    действием и превращает «непроверен» в «проверен»;
//  - имя в баннере — то, что удалённая сторона САМА о себе заявила;
//    формулировка обязана это отражать;
//  - объявление карточки — ТОЛЬКО при открытом экране знакомства;
//    вне его в эфире лишь service UUID (паспорт приватности);
//  - отказ — навсегда для этого ключа: больше не предлагаем;
//  - баннер не всплывает поверх набора сообщения и диктовки —
//    придерживается и показывается позже;
//  - QR остаётся путём высокого доверия.
// ============================================================================

/// Проводной формат объявления:
///  - объявление: [магия "RMINTR1"][0][payload]
///  - ответ:      [магия "RMINTR1"][1][отпечаток адресата 8Б][payload]
/// Payload — тот же base64-конверт карточки, что в QR и буфере
/// (ContactStore.ExchangePayload): один разбор, одни проверки.
/// Ответ АДРЕСНЫЙ (вопрос владельца 08.08 про асимметрию): адресат
/// покажет баннер, когда бы ответ ни дошёл, а случайный третий телефон
/// чужой обмен молча отбросит — окно «после маяка» больше не нужно.
nonisolated enum IntroduceWire {

    /// Магия отличает объявление от envelope-пакета до всякого разбора.
    static let magic: [UInt8] = Array("RMINTR1".utf8)
    /// Вид кадра: объявление с экрана знакомства / ответ на согласие.
    static let kindOffer: UInt8 = 0
    static let kindReply: UInt8 = 1
    /// Отпечаток ключа — 8 символов base32 (см. Contact.id).
    static let replyTargetLength = 8
    /// Потолок кадра (непреложное №3): имя длиннее не нужно никому.
    static let maxBytes = 600

    static func frame(kind: UInt8, payloadBase64: String,
                      target: String? = nil) -> [UInt8]? {
        let targetBytes = Array((target ?? "").utf8)
        if kind == kindReply, targetBytes.count != replyTargetLength {
            return nil
        }
        let frame = magic + [kind] + targetBytes + Array(payloadBase64.utf8)
        return frame.count <= maxBytes ? frame : nil
    }

    /// Моя карточка как объявление (экран знакомства открыт).
    static func myOffer() -> [UInt8]? {
        ContactStore.myPayloadBase64().flatMap {
            frame(kind: kindOffer, payloadBase64: $0)
        }
    }

    // Строителя v1-ответа (myReply) больше НЕТ — намеренно: единственный
    // путь ответа — sealedReply, и принудить эту сборку ответить v1
    // (открытой карточкой) невозможно по построению. Компилятор — замок.

    // MARK: Ответ v2 — эфемерный ключ + запечатанная карточка (B1)

    /// Магия ответа v2 (ревизия B, 09.08): [магия][вид][эфемерный pub
    /// X25519 32Б][ChaChaPoly(карточка)]. Ключ шифрования выводится из
    /// DH(эфемерный, ключ адресата) — эфемерная пара свежая на каждый
    /// ответ и каждый повтор, кадры несвязываемы; карточка согласившегося
    /// больше НЕ лежит в эфире открытой. Отдельной метки адресата нет
    /// (решение владельца 09.08, хвост №2): DH обязателен в любом
    /// варианте, а чужой кадр отбраковывает сам AEAD-тег при вскрытии —
    /// метка не окупала свои 8 Б. Оффер остаётся открытым НАМЕРЕННО:
    /// его смысл — быть прочитанным незнакомцем.
    static let magic2: [UInt8] = Array("RMINTR2".utf8)
    static let ephemeralLength = 32
    static let keyInfo = Data("rm-intro-key".utf8)

    /// Срок снятия ПРИЁМА v1-ответов (совместимость со сборкой 6, где
    /// ответная карточка летела открытой): 2026-11-01 00:00 UTC — две
    /// TestFlight-итерации, дольше держать поверхность даунгрейда
    /// незачем. После срока v1-ответ гасится КОДОМ (правило 9). Оффер
    /// v1 остаётся — это формат маяка, он открытый по смыслу.
    static let v1ReplySunset = Date(timeIntervalSince1970: 1_793_491_200)

    /// Запечатать мою карточку адресату (его ключ у согласившегося
    /// уже на руках — из оффера).
    static func sealedReply(to target: Curve25519.KeyAgreement.PublicKey)
        -> [UInt8]? {
        guard let payload = ContactStore.myPayloadBase64() else { return nil }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        guard let secret = try? ephemeral.sharedSecretFromKeyAgreement(
            with: target) else { return nil }
        let sealKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: keyInfo,
            outputByteCount: 32)
        guard let box = try? ChaChaPoly.seal(Data(payload.utf8),
                                             using: sealKey) else {
            return nil
        }
        var frame = magic2
        frame.append(kindReply)
        frame += Array(ephemeral.publicKey.rawRepresentation)
        frame += Array(box.combined)
        return frame.count <= maxBytes ? frame : nil
    }

    /// Вскрыть ответ v2 СВОИМ ключом. nil — не наш формат, не нам
    /// адресовано или битое. Адресность доказывает AEAD: чужой кадр
    /// не вскроется моим ключом — отдельной метки не нужно.
    static func openSealedReply(_ blob: [UInt8]) -> Contact? {
        let headLen = magic2.count + 1 + ephemeralLength
        guard blob.count > headLen, blob.count <= maxBytes,
              Array(blob.prefix(magic2.count)) == magic2,
              blob[magic2.count] == kindReply,
              let myPriv = Identity.privateKey() else { return nil }
        let ephStart = magic2.count + 1
        guard let ephPub = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(blob[ephStart..<ephStart + ephemeralLength])),
              let secret = try? myPriv.sharedSecretFromKeyAgreement(
                with: ephPub) else { return nil }
        let sealKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: keyInfo,
            outputByteCount: 32)
        guard let box = try? ChaChaPoly.SealedBox(
                combined: Data(blob[headLen...])),
              let payload = try? ChaChaPoly.open(box, using: sealKey),
              var contact = ContactStore.parse(
                String(decoding: payload, as: UTF8.self)) else { return nil }
        contact.verified = false
        return contact
    }

    /// Разбор чужого кадра. Не наш формат — nil (пакет пойдёт путём
    /// конверта). Карточка из эфира ВСЕГДА «непроверена»: канал без
    /// визуальной сверки, подмена в радиусе возможна.
    static func decode(_ blob: [UInt8])
        -> (contact: Contact, isReply: Bool, replyTarget: String?)? {
        guard blob.count > magic.count + 1, blob.count <= maxBytes,
              Array(blob.prefix(magic.count)) == magic else { return nil }
        let kind = blob[magic.count]
        var rest = blob.dropFirst(magic.count + 1)
        var target: String?
        if kind == kindReply {
            guard rest.count > replyTargetLength else { return nil }
            target = String(decoding: rest.prefix(replyTargetLength),
                            as: UTF8.self)
            rest = rest.dropFirst(replyTargetLength)
        } else if kind != kindOffer {
            return nil
        }
        let payload = String(decoding: rest, as: UTF8.self)
        guard var contact = ContactStore.parse(payload) else { return nil }
        contact.verified = false
        return (contact, kind == kindReply, target)
    }
}

/// Центр знакомства: маяк на открытом экране «Мой QR», приём чужих
/// объявлений, баннер и решения человека.
@MainActor
final class IntroduceCenter: ObservableObject {

    static let shared = IntroduceCenter()

    struct Offer: Equatable {
        let contact: Contact
        let isReply: Bool
    }

    /// Текущий баннер (nil — не показывается).
    @Published private(set) var offer: Offer?
    /// Честная строка после согласия, если добавить нельзя (подмена).
    @Published var notice: String?

    /// Набор сообщения или диктовка: баннер придерживается
    /// (условие владельца — не прерывать человека посреди действия).
    var inputBusy = false {
        didSet { if !inputBusy { promotePending() } }
    }

    private var pending: Offer?
    private(set) var modeOpen = false
    /// Когда экран знакомства закрылся. Ответу это ничего не запрещает
    /// (адресность заменила окно) — точка нужна замку позднего ответа:
    /// слом таймер-гейтом обязан краснить lateReplyStillBanners.
    private(set) var modeClosedAt: Date?
    private var beaconTask: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?

    /// Сколько согласившийся телефон дошлёт ответную карточку сам,
    /// повторами (асимметрия из вопроса владельца 08.08: первый мог
    /// закрыть экран или приложение — карточка ждёт его возвращения).
    static let replyRetrySeconds: TimeInterval = 600
    /// Через сколько безуспешных секунд честно сказать «пока не дошла».
    static let replyWarnAfterSeconds: TimeInterval = 12

    private static let declinedKey = "nearby.introduce.declined"

    private init() {}

    // MARK: Маяк — только пока открыт экран знакомства

    func setModeOpen(_ on: Bool) {
        guard on != modeOpen else { return }
        modeOpen = on
        beaconTask?.cancel()
        beaconTask = nil
        guard on else {
            modeClosedAt = Date()
            TransportDiary.note("[знакомство] объявление карточки остановлено")
            return
        }
        TransportDiary.note("[знакомство] объявление карточки в эфир (экран открыт)")
        beaconTask = Task { [weak self] in
            while let self, self.modeOpen, !Task.isCancelled {
                // соседей нет — молчим: NearbyTransport сам найдёт,
                // маяк догонит следующим тиком
                if NearbyTransport.shared.peerCount > 0,
                   let frame = IntroduceWire.myOffer() {
                    NearbyTransport.shared.send(frame) { _ in }
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: Приём

    /// true — кадр наш (объявление), дальше по пути конверта не идёт.
    /// `now` — инъекция часов для замков (поздний ответ, срок v1).
    func handleIncoming(_ blob: [UInt8], now: Date = Date()) -> Bool {
        // Ответ v2 (B1): вскрытие своим ключом само доказывает
        // адресность; чужой/битый кадр v2 гасится молча
        if blob.count > IntroduceWire.magic2.count,
           Array(blob.prefix(IntroduceWire.magic2.count))
               == IntroduceWire.magic2 {
            guard let contact = IntroduceWire.openSealedReply(blob) else {
                return true
            }
            // Двустороннее согласие (мега-2, 14.08): если этому ключу
            // МЫ уже отправляли приглашение — его карточка в ответ
            // означает «принял со своей стороны»: чат создаётся БЕЗ
            // второго баннера, круг замкнулся у обоих.
            if completePendingInvite(with: contact) { return true }
            present(contact: contact, isReply: true,
                    target: Identity.myFingerprint())
            return true
        }
        guard let (contact, isReply, target) = IntroduceWire.decode(blob)
        else { return false }
        // Поверхность даунгрейда ограничена сроком: v1-ответ (открытая
        // карточка) принимается только ради живых сборок 6 и только до
        // v1ReplySunset; после — гасится кодом, как чужой обмен
        if isReply, now >= IntroduceWire.v1ReplySunset {
            TransportDiary.note("[знакомство] v1-ответ после срока снятия"
                                + " — погашен")
            return true
        }
        present(contact: contact, isReply: isReply, target: target)
        return true
    }

    /// Общий хвост приёма: решение о показе и придержка.
    private func present(contact: Contact, isReply: Bool, target: String?) {
        guard Self.shouldPresent(candidate: contact, isReply: isReply,
                                 replyTarget: target,
                                 myID: Identity.myFingerprint(),
                                 contacts: ContactStore.load(),
                                 declined: declined) else { return }
        let fresh = Offer(contact: contact, isReply: isReply)
        guard fresh != offer, fresh != pending else { return }
        if inputBusy || offer != nil {
            pending = fresh
        } else {
            offer = fresh
            // пульс без имени: эфирные имена в дневник не пишем
            TransportDiary.note("[знакомство] карточка рядом: \(contact.id)"
                                + (isReply ? " (ответ)" : ""))
        }
    }

    /// Чистое решение «показывать ли баннер» — закрыто замком.
    nonisolated static func shouldPresent(candidate: Contact, isReply: Bool,
                                          replyTarget: String?,
                                          myID: String?,
                                          contacts: [Contact],
                                          declined: Set<String>) -> Bool {
        if isReply && (replyTarget == nil || replyTarget != myID) {
            return false                                  // чужой обмен
        }
        if candidate.id == myID { return false }          // своё эхо
        if declined.contains(candidate.id) { return false } // отказ навсегда
        if contacts.contains(where: { $0.id == candidate.id }) {
            return false   // уже знакомы (повтор с ТЕМ ЖЕ ключом —
                           // законный, но баннер не нужен: молчание)
        }
        return true
    }

    // MARK: Двустороннее согласие (мега-2, 14.08)
    //
    // Раньше «Познакомиться» создавало чат сразу у согласившегося —
    // в людном месте непонятно, от кого приглашение, плодились
    // односторонние случайные чаты. Теперь чат создаётся только когда
    // согласились ОБА: принявший оффер шлёт свою карточку (приглашение)
    // и ЖДЁТ; хозяин оффера, принимая её, создаёт чат у себя и шлёт
    // свою карточку обратно; ждавший по ней создаёт чат без второго
    // баннера. Провод не тронут: те же sealed-reply кадры.

    /// Отправленные приглашения, ждущие согласия второй стороны:
    /// id ключа → payload карточки (переживает перезапуск).
    static let pendingInvitesKey = "nearby.introduce.pendingInvites"

    private var pendingInvites: [String: String] {
        get {
            (UserDefaults.standard.dictionary(forKey: Self.pendingInvitesKey)
                as? [String: String]) ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue,
                                      forKey: Self.pendingInvitesKey)
        }
    }

    /// Ответная карточка от ключа, которому МЫ слали приглашение, —
    /// вторая сторона согласилась: чат создаётся здесь, без баннера.
    /// true — кадр поглощён этим путём.
    private func completePendingInvite(with contact: Contact) -> Bool {
        guard pendingInvites[contact.id] != nil else { return false }
        var confirmed = contact
        confirmed.verified = false
        switch ContactStore.upsertGuarded(confirmed) {
        case .saved:
            pendingInvites[contact.id] = nil
            notice = "«\(confirmed.name)» принял приглашение — чат создан."
            TransportDiary.note("[знакомство] обоюдное согласие, чат "
                                + "создан: \(confirmed.id)")
        case .keyChangeSuspected(let existing, _):
            pendingInvites[contact.id] = nil
            notice = "Имя «\(confirmed.name)» уже есть в контактах, но "
                + "ключ другой (\(existing.id) → \(confirmed.id)) — так "
                + "выглядит подмена. Чат не создан: сверьтесь по QR."
            TransportDiary.note(
                "[знакомство] обоюдное согласие отклонено гейтом подмены")
        }
        return true
    }

    /// Стереть ожидающие приглашения («начать заново»).
    func clearPendingInvites() {
        UserDefaults.standard.removeObject(forKey: Self.pendingInvitesKey)
    }

    // MARK: Решения человека

    /// Согласие. Оффер: чат НЕ создаётся — уходит приглашение (своя
    /// карточка), ждём согласия второй стороны. Ответ: вторая сторона
    /// уже согласилась — чат создаётся и наша карточка едет обратно,
    /// чтобы у неё чат тоже замкнулся.
    func accept() {
        guard let current = offer else { return }
        var contact = current.contact
        contact.verified = false
        if !current.isReply {
            // приглашение: без чата до обоюдного согласия (мега-2)
            pendingInvites[contact.id] = contact.name
            deliverReply(to: contact)
            notice = "Приглашение отправлено. Чат создастся, когда "
                + "собеседник примет его со своей стороны."
            TransportDiary.note("[знакомство] приглашение отправлено, "
                                + "ждём второй стороны: \(contact.id)")
            offer = nil
            promotePending()
            return
        }
        switch ContactStore.upsertGuarded(contact) {
        case .saved:
            TransportDiary.note(
                "[знакомство] контакт добавлен (непроверен): \(contact.id)")
            // встречное подтверждение: у пригласившего чат замкнётся
            // нашей карточкой (без него он ждал бы вечно)
            deliverReply(to: contact)
        case .keyChangeSuspected(let existing, _):
            // гейт подмены (WP1) сильнее удобства: через баннер такой
            // контакт не добавляется вовсе
            notice = "Имя «\(contact.name)» уже есть в ваших контактах, "
                + "но ключ другой (\(existing.id) → \(contact.id)) — так "
                + "выглядит подмена. Через баннер такое не добавляется: "
                + "сверьте карточку по QR при встрече."
            TransportDiary.note(
                "[знакомство] отклонено гейтом подмены: \(contact.id)")
        }
        offer = nil
        promotePending()
    }

    /// Отказ: этому ключу больше не предлагаем — навсегда.
    func decline() {
        guard let current = offer else { return }
        var all = declined
        all.insert(current.contact.id)
        UserDefaults.standard.set(Array(all), forKey: Self.declinedKey)
        TransportDiary.note(
            "[знакомство] отказ, больше не предлагаем: \(current.contact.id)")
        offer = nil
        promotePending()
    }

    /// Доставка ответной карточки с повторами (асимметрия, 08.08):
    /// первый мог закрыть экран или приложение — карточка ждёт и
    /// дошлётся сама, пока наше приложение живо. Долгая неудача — не
    /// молчание, а честная строка (правило 3).
    private func deliverReply(to target: Contact) {
        let targetID = target.id
        // ключ адресата — из его же оффера; без ключа v2-ответ не
        // построить (v1 с открытой карточкой больше не шлём)
        guard let targetPub = target.publicKey else { return }
        replyTask?.cancel()
        replyTask = Task { [weak self] in
            let started = Date()
            var warned = false
            while !Task.isCancelled,
                  Date().timeIntervalSince(started) < Self.replyRetrySeconds {
                let ok = await withCheckedContinuation { cont in
                    // свежая эфемерная пара на каждую попытку — метки
                    // повторов тоже несвязываемы
                    guard let frame = IntroduceWire.sealedReply(to: targetPub)
                    else { cont.resume(returning: false); return }
                    NearbyTransport.shared.send(frame) {
                        cont.resume(returning: $0)
                    }
                }
                if ok {
                    TransportDiary.note(
                        "[знакомство] ответная карточка ушла: \(targetID)")
                    if warned {
                        self?.notice = "Ответная карточка дошла — "
                            + "собеседник увидит баннер."
                    }
                    return
                }
                if !warned,
                   Date().timeIntervalSince(started)
                       > Self.replyWarnAfterSeconds {
                    warned = true
                    self?.notice = "Контакт добавлен, но ответная карточка "
                        + "пока не дошла — рядом нет принимающего телефона. "
                        + "Попросите собеседника открыть приложение: "
                        + "карточка дошлётся сама, пока вы в приложении. "
                        + "Или сверьтесь по QR."
                }
                try? await Task.sleep(for: .seconds(5))
            }
            if !Task.isCancelled {
                TransportDiary.note(
                    "[знакомство] ответная карточка НЕ дошла за "
                    + "\(Int(Self.replyRetrySeconds)) с: \(targetID)")
            }
        }
    }

    private var declined: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? [])
    }

    /// Придержанный баннер показывается, когда человек освободился.
    private func promotePending() {
        guard offer == nil, !inputBusy, let next = pending else { return }
        pending = nil
        // пока ждали, контакт мог добавиться или получить отказ;
        // адресность ответа уже проверена при приёме
        guard Self.shouldPresent(candidate: next.contact,
                                 isReply: next.isReply,
                                 replyTarget: Identity.myFingerprint(),
                                 myID: Identity.myFingerprint(),
                                 contacts: ContactStore.load(),
                                 declined: declined) else { return }
        offer = next
    }

    // MARK: Для тестов

    /// Сброс живого состояния (не трогает отказы в UserDefaults).
    func resetForTests() {
        offer = nil
        pending = nil
        notice = nil
        inputBusy = false
        modeOpen = false
        modeClosedAt = nil
        beaconTask?.cancel()
        beaconTask = nil
        replyTask?.cancel()
        replyTask = nil
        clearPendingInvites()
    }

    /// Снять отказ (тесты и ручная дверь обратно, если понадобится).
    func clearDeclined(id: String) {
        var all = declined
        all.remove(id)
        UserDefaults.standard.set(Array(all), forKey: Self.declinedKey)
    }

    // MARK: Обратимость отказов (А5, поручение владельца 09.08)

    /// Сколько ключей получили «не нужно» — для строки на экране
    /// знакомства.
    var declinedCount: Int { declined.count }

    /// Сброс всех отказов: «навсегда» перестало быть приговором —
    /// человек передумал, баннеры этих ключей смогут прийти снова.
    func clearAllDeclined() {
        UserDefaults.standard.removeObject(forKey: Self.declinedKey)
        TransportDiary.note("[знакомство] отказы сброшены человеком")
    }
}

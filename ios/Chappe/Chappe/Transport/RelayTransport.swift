import Foundation
import Combine
import UIKit
import CryptoKit
import Network

// ============================================================================
// Релейный путь доставки (сессия 05.08). Равноправен радио, не запасной:
// есть интернет — сообщение уходит через релей; радио работает своим
// чередом; одно сообщение МОЖЕТ уйти обоими путями — дедуп на приёме
// уже существует (счётчик рэтчета + SeenMsgIDs по msgID).
//
// Судьба кадра по релею и её события (правило 5 — успех подтверждается
// СВОИМ событием):
//   PUT 200      → «в ящике у получателя» (200 релей отдаёт после fsync);
//   кадр исчез из ящика до TTL → «получатель забрал» (его DELETE —
//                  единственное, что убирает строку ящика; обе стороны
//                  пары умеют читать ящик — принятая утечка спеки №2);
//   PUT 410      → «не доставлено: получатель не забрал за 48 ч» —
//                  честное «сдаюсь» с основанием, не по счётчику;
//   прочие коды  → см. RelayClient.PutOutcome: у каждого своё поведение.
//
// dst и box-ключ вычисляются В МОМЕНТ отправки (не при постановке в
// очередь): псевдоним живёт эпоху, а сообщение в очереди — сколько
// придётся. Приёмное окно получателя покрывает 48 ч назад, поэтому
// смена эпохи между отправкой и забором ничего не теряет.
// ============================================================================

@MainActor
final class RelayTransport: ObservableObject {

    static let shared = RelayTransport()

    static let enabledKey = "relay_enabled"
    static let urlKey = "relay_url"
    /// Боевой адрес (домен chappe.me — решение владельца 05.08); на
    /// сегодня не развёрнут — до развёртывания каждая отправка честно
    /// получает «релей недоступен — повторю», а по потолку попыток —
    /// «не дошло», не вечное «отправляется». Для местного испытания
    /// адрес меняется в Dev.
    static let defaultURL = "https://relay.chappe.me"
    /// Дефолт до 05.08 — заменяется молча при чтении настроек:
    /// домен chappe.app проекту не принадлежит.
    static let retiredDefaultURL = "https://relay.chappe.app"

    /// Включённость релея ВЫВОДИТСЯ из режима транспортов — единственный
    /// источник истины (поле 29.09: собственный ключ relay_enabled залипал
    /// в false, синкаясь с галками только в UI-обработчике, и молча глушил
    /// опрос с отправкой при стоящей галке wifi; залипание закладывалось
    /// ещё полевой «пустой маской» 13.08). Легаси-ключ игнорируется.
    var enabled: Bool { TransportMode.wifiAllowed }

    /// Dev-хуки (--relay-on/off, тумблер Dev) управляют релеем ЧЕРЕЗ
    /// источник истины, не мимо него: «выключить» = ручной режим без
    /// wifi; «включить» = вернуть wifi в маску (в авто он и так разрешён).
    static func setEnabled(_ on: Bool) {
        if on {
            if TransportMode.isManual {
                TransportMode.manualMask.insert("wifi")
            }
        } else {
            TransportMode.isManual = true
            TransportMode.manualMask.remove("wifi")
        }
    }
    @Published var urlString: String {
        didSet { UserDefaults.standard.set(urlString, forKey: Self.urlKey) }
    }
    /// Есть ли интернет (NWPathMonitor). Радиоустройство тут ни при чём.
    @Published private(set) var internetUp = false

    /// Каким каналом идёт интернет — для честной строки «сейчас через…»
    /// (UX-проход 06.08: человек должен видеть путь, а не гадать).
    enum PathKind: String { case wifi, cellular, other, none }
    @Published private(set) var pathKind: PathKind = .none
    /// Пульс наблюдателя (правило 3): опросы обязаны быть видимы.
    @Published private(set) var pulse = "ещё не опрашивал"
    private var pollsDone = 0
    private var framesSeen = 0

    private let monitor = NWPathMonitor()
    private var pollTask: Task<Void, Never>?
    /// 429/недоступность: до этого момента к релею не ходим.
    private var backoffUntil: Date?

    var client: RelayClient? { RelayClient(urlString: urlString) }
    var active: Bool {
        enabled && internetUp && client != nil
            && (backoffUntil.map { $0 <= Date() } ?? true)
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.urlKey)
        // миграция отставного дефолта: chappe.app не наш домен
        urlString = (stored == nil || stored == Self.retiredDefaultURL)
            ? Self.defaultURL : stored!
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            let kind: PathKind = !up ? .none
                : path.usesInterfaceType(.wifi) ? .wifi
                : path.usesInterfaceType(.cellular) ? .cellular : .other
            Task { @MainActor in
                self?.internetUp = up
                self?.pathKind = kind
            }
        }
        monitor.start(queue: DispatchQueue(label: "chappe.relay.path"))
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let active = UIApplication.shared.applicationState == .active
                try? await Task.sleep(for: Self.pollInterval(appActive: active))
                await self?.pollInbox()
                await self?.pollStoredOutcomes()
            }
        }
        // Активация приложения = опрос НЕМЕДЛЕННО, не ждём такта
        // (человек открыл апп — ящик проверяется сразу)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                TransportDiary.note("[relay] активация — внеочередной опрос")
                await self?.pollInbox()
                await self?.pollStoredOutcomes()
            }
        }
    }

    /// Период опроса ящиков. P0 поле 14.08: плоские 12 с давали
    /// 10–25 с на доставку при обоих онлайн (дневник: укладка
    /// 20:59:28 → забор 20:59:42) — в ФОРГРАУНДЕ релей обязан быть
    /// секундами. Фон — прежние 12 с (APNs и фоновая политика — позже).
    nonisolated static func pollInterval(appActive: Bool) -> Duration {
        appActive ? .seconds(3) : .seconds(12)
    }

    // MARK: Отправка (зовётся насосом DeliveryManager)

    /// Отправить сообщение очереди через релей. Вызывающий уже проверил
    /// active и что item ещё не лежит в ящике.
    func send(_ item: Outbox.QueuedMessage) {
        guard let client,
              let streamHex = item.relayStreamHex,
              let contact = Self.contact(of: item),
              let peerPub = contact.publicKey,
              let myPriv = Identity.privateKey(),
              let pairKey = try? MailboxID.pairKey(myPrivate: myPriv,
                                                   peerPublic: peerPub)
        else { return }

        let peerRaw = peerPub.rawRepresentation
        // Первый контакт: собеседник ещё не доказал, что имеет НАШУ
        // эпоху (peerConfirmedV2), — значит он не знает наш ключ и НЕ
        // слушает ящик пары. Кладём в ящик ПЕРВОГО КОНТАКТА, выводимый
        // из его ключа (он в QR): его собеседник постоянно слушает.
        // После подтверждения — несвязываемый ящик пары (как раньше).
        let confirmed = RatchetStore.load(contactID: contact.id)?
            .peerConfirmedV2 == true
        let epoch: Int
        let dst: [UInt8]
        let boxPub: Data
        if confirmed {
            epoch = MailboxID.epoch(pairKey: pairKey, at: Date())
            dst = MailboxID.dst(recipientPub: peerRaw, pairKey: pairKey,
                                epoch: epoch)
            boxPub = RelayBoxKey.derive(recipientPub: peerRaw,
                                        pairKey: pairKey, epoch: epoch)
                .publicKey.rawRepresentation
        } else {
            let target = FirstContactMailbox.sendTarget(recipientPub: peerRaw)
            epoch = target.epoch
            dst = target.dst
            boxPub = target.boxPublic
            TransportDiary.note("[relay] первый контакт → ящик получателя "
                                + "(до подтверждения пары)")
        }
        let dstHex = Self.hex(dst)
        let stream = Outbox.bytes(fromHex: streamHex)
        guard let bare = try? EnvelopeV2.encodePackets(
            msgID: item.msgID, stream: stream, dst: dst) else { return }
        // №7: релей — быстрый транспорт, кадры в ящике лежат бакетами;
        // дальше по коду ходят ОБЁРНУТЫЕ кадры, чтобы pollStoredOutcomes
        // сравнивал framesHex с тем, что реально лежит в ящике
        let frames = bare.map(WirePadding.pad)

        Task { [weak self] in
            var worst: RelayClient.PutOutcome = .stored(duplicate: false)
            for frame in frames {
                let outcome = await client.put(frame: frame, dstHex: dstHex,
                                               boxPublic: boxPub)
                if case .stored = outcome { continue }
                worst = outcome
                break
            }
            await self?.finishSend(item, outcome: worst, dstHex: dstHex,
                                   epoch: epoch, frames: frames)
        }
    }

    private func finishSend(_ item: Outbox.QueuedMessage,
                            outcome: RelayClient.PutOutcome,
                            dstHex: String, epoch: Int,
                            frames: [[UInt8]]) {
        switch outcome {
        case .stored:
            DeliveryManager.shared.relayStored(
                item, dstHex: dstHex, epoch: epoch,
                framesHex: frames.map(Self.hex))
            TransportDiary.note("[relay] положено в ящик, кадров \(frames.count)")
        case .expiredUndelivered:
            DeliveryManager.shared.relayTerminal(item, status: outcome.human)
            TransportDiary.note("[relay] 410: истёк недоставленным")
        case .badFrame, .tooLarge, .foreignKey:
            DeliveryManager.shared.relayTerminal(item, status: outcome.human)
            TransportDiary.note("[relay] отказ без повтора: \(outcome.human)")
        case .rateLimited(let after):
            backoffUntil = Date().addingTimeInterval(Double(after))
            DeliveryManager.shared.relayNote(item, status: outcome.human)
        case .boxFull, .storageDown, .serverError, .unreachable:
            DeliveryManager.shared.relayNote(item, status: outcome.human)
        }
    }

    /// Адрес служебного кадра (ack/квитанция) для контакта: ящик ПАРЫ
    /// на текущую эпоху — исходный отправитель слушает пары всех своих
    /// контактов. nil — пары ещё нет (рукопожатие не принято) или ключи
    /// недоступны.
    nonisolated static func serviceTarget(peerPub: Data, myPriv:
        Curve25519.KeyAgreement.PrivateKey, now: Date = Date())
    -> (dstHex: String, boxPublic: Data)? {
        guard let key = try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: peerPub),
              let pairKey = try? MailboxID.pairKey(myPrivate: myPriv,
                                                   peerPublic: key)
        else { return nil }
        let epoch = MailboxID.epoch(pairKey: pairKey, at: now)
        let dst = MailboxID.dst(recipientPub: peerPub, pairKey: pairKey,
                                epoch: epoch)
        let boxPublic = RelayBoxKey.derive(recipientPub: peerPub,
                                           pairKey: pairKey, epoch: epoch)
            .publicKey.rawRepresentation
        return (Self.hex(dst), boxPublic)
    }

    /// Служебный пакет (v1 ack/отметка) в ящик пары контакта. Тихий
    /// провал — служебный кадр вправе потеряться: отправитель повторит
    /// сообщение (ack уйдёт снова), чат повторит отметку при открытии.
    /// confirm(true) — только после 200 релея (замок А3: штамп по
    /// подтверждению канала).
    func sendService(_ packet: [UInt8], contactID: String,
                     confirm: @escaping @Sendable (Bool) -> Void = { _ in }) {
        guard active, let client,
              let contact = ContactStore.load()
                  .first(where: { $0.id == contactID }),
              let peerPub = contact.publicKey,
              let myPriv = Identity.privateKey(),
              let target = Self.serviceTarget(
                  peerPub: peerPub.rawRepresentation, myPriv: myPriv)
        else { confirm(false); return }
        let frame = WirePadding.pad(packet)
        Task {
            let outcome = await client.put(frame: frame,
                                           dstHex: target.dstHex,
                                           boxPublic: target.boxPublic)
            if case .stored = outcome {
                TransportDiary.note("[relay] служебный кадр в ящике пары")
                confirm(true)
            } else {
                confirm(false)
            }
        }
    }

    // MARK: Приём — опрос своих ящиков

    /// Все действующие псевдонимы по каждому контакту. Окно эпох
    /// покрывает 48 ч назад и 24 ч вперёд (расхождение часов),
    /// поэтому смена эпохи между отправкой и забором не теряет кадров.
    func pollInbox() async {
        guard active, let client,
              let myPriv = Identity.privateKey(),
              let myPub = Identity.publicKey() else { return }
        let myRaw = myPub.rawRepresentation
        var seen = 0
        for contact in ContactStore.load() {
            guard let peerPub = contact.publicKey,
                  let pairKey = try? MailboxID.pairKey(
                    myPrivate: myPriv, peerPublic: peerPub) else { continue }
            for epoch in MailboxID.acceptedEpochs(pairKey: pairKey) {
                let dst = MailboxID.dst(recipientPub: myRaw,
                                        pairKey: pairKey, epoch: epoch)
                let key = RelayBoxKey.derive(recipientPub: myRaw,
                                             pairKey: pairKey, epoch: epoch)
                switch await client.fetch(dstHex: Self.hex(dst), key: key) {
                case .frames(let frames):
                    for frame in frames {
                        DeliveryManager.shared.ingest(frame.body)
                        seen += 1
                        // подтверждение ПОСЛЕ обработки: обрыв между
                        // выдачей и DELETE = повторная выдача, дубль
                        // гасится приёмником (at-least-once)
                        await client.delete(dstHex: Self.hex(dst),
                                            frameID: frame.id, key: key)
                    }
                case .rateLimited(let after):
                    backoffUntil = Date().addingTimeInterval(Double(after))
                    notePulse(extra: "429, пауза \(after) с")
                    return
                case .denied, .unavailable, .unreachable:
                    continue
                }
            }
        }
        // Свой ящик ПЕРВОГО КОНТАКТА — слушается ВСЕГДА, без известного
        // контакта: сюда незнакомец кладёт интро (дизайн-дыра 11.08).
        // Выводится из моего ключа, поэтому доступен без ключа отправителя.
        for (dst, epoch) in FirstContactMailbox.acceptedDsts(myPub: myRaw) {
            let key = FirstContactMailbox.boxKey(recipientPub: myRaw,
                                                 epoch: epoch)
            switch await client.fetch(dstHex: Self.hex(dst), key: key) {
            case .frames(let frames):
                for frame in frames {
                    DeliveryManager.shared.ingest(frame.body)
                    seen += 1
                    await client.delete(dstHex: Self.hex(dst),
                                        frameID: frame.id, key: key)
                }
                if !frames.isEmpty {
                    TransportDiary.note("[relay] интро первого контакта "
                                        + "принято из своего ящика: \(frames.count)")
                }
            case .rateLimited(let after):
                backoffUntil = Date().addingTimeInterval(Double(after))
                notePulse(extra: "429, пауза \(after) с")
                return
            case .denied, .unavailable, .unreachable:
                continue
            }
        }
        framesSeen += seen
        pollsDone += 1
        if seen > 0 {
            TransportDiary.note("[relay] принято из ящика: \(seen)")
        }
        notePulse(extra: seen > 0 ? "принято \(seen)" : nil)
    }

    /// Стереть релейный ЯЩИК ПАРЫ при удалении контакта (чистый лист,
    /// 12.08): без этого повторное знакомство ТЕМ ЖЕ ключом даёт тот же
    /// ящик, и старые недоставленные кадры из него переотдаются —
    /// переписка «воскресает» после удаления (opsec-дыра + грязь в
    /// тестах первого контакта). Чистим оба конца пары (мои входящие +
    /// мои недоставленные к нему): я член пары, ключи ящиков у меня
    /// есть. Best-effort: без сети чистка не произойдёт, но локальный
    /// purge при этом уже состоялся.
    func purgeMailbox(for contact: Contact) {
        guard let client,
              let peerPub = contact.publicKey,
              let myPriv = Identity.privateKey(),
              let myPub = Identity.publicKey(),
              let pairKey = try? MailboxID.pairKey(myPrivate: myPriv,
                                                   peerPublic: peerPub)
        else { return }
        let myRaw = myPub.rawRepresentation
        let peerRaw = peerPub.rawRepresentation
        Task { [weak self] in
            for epoch in MailboxID.acceptedEpochs(pairKey: pairKey) {
                // мой ящик пары (кадры собеседника ко мне, ещё не забраны)
                await self?.drainSlot(
                    dst: MailboxID.dst(recipientPub: myRaw,
                                       pairKey: pairKey, epoch: epoch),
                    key: RelayBoxKey.derive(recipientPub: myRaw,
                                            pairKey: pairKey, epoch: epoch),
                    client: client)
                // ящик собеседника (мои недоставленные кадры к нему)
                await self?.drainSlot(
                    dst: MailboxID.dst(recipientPub: peerRaw,
                                       pairKey: pairKey, epoch: epoch),
                    key: RelayBoxKey.derive(recipientPub: peerRaw,
                                            pairKey: pairKey, epoch: epoch),
                    client: client)
            }
            TransportDiary.note("[relay] ящик пары стёрт при удалении контакта")
        }
    }

    /// Забрать и удалить ВСЕ кадры слота, не обрабатывая их (чистка).
    private func drainSlot(dst: [UInt8],
                           key: Curve25519.Signing.PrivateKey,
                           client: RelayClient) async {
        guard case .frames(let frames) = await client.fetch(
            dstHex: Self.hex(dst), key: key) else { return }
        for frame in frames {
            await client.delete(dstHex: Self.hex(dst),
                                frameID: frame.id, key: key)
        }
    }

    // MARK: Судьба положенных кадров

    /// «Получатель забрал» = наш кадр исчез из ящика до TTL. Ящик пары
    /// умеют читать обе стороны (спека v0 №2, принятая утечка) — этим
    /// отправитель и пользуется, чтобы увидеть DELETE получателя.
    func pollStoredOutcomes() async {
        guard active, let client,
              let myPriv = Identity.privateKey() else { return }
        let stored = Outbox.loadQueueRaw().filter {
            $0.relayStoredAt != nil && $0.relayDone != true
        }
        for item in stored {
            guard let contact = Self.contact(of: item),
                  let peerPub = contact.publicKey,
                  let pairKey = try? MailboxID.pairKey(
                    myPrivate: myPriv, peerPublic: peerPub),
                  let dstHex = item.relayDstHex,
                  let epoch = item.relayEpoch,
                  let mineHex = item.relayFramesHex,
                  let storedAt = item.relayStoredAt else { continue }
            // Ключ ящика: у подтверждённой пары — из pairKey; у первого
            // контакта кадр лежит в ящике получателя, ключ выводится из
            // его же ключа (иначе отправитель не увидит DELETE и слал бы
            // повторы дольше нужного — доставку это не ломает, но пул
            // засоряется).
            let confirmed = RatchetStore.load(contactID: contact.id)?
                .peerConfirmedV2 == true
            let key = confirmed
                ? RelayBoxKey.derive(recipientPub: peerPub.rawRepresentation,
                                     pairKey: pairKey, epoch: epoch)
                : FirstContactMailbox.boxKey(
                    recipientPub: peerPub.rawRepresentation, epoch: epoch)
            guard case .frames(let inBox) = await client.fetch(
                dstHex: dstHex, key: key) else { continue }
            let bodies = Set(inBox.map { Self.hex($0.body) })
            let stillThere = mineHex.contains { bodies.contains($0) }
            if stillThere { continue }
            // кадра нет: до горизонта TTL это мог сделать только DELETE
            // получателя; у самой границы — неотличимо от уборки, тогда
            // честнее худшее прочтение
            if Date().timeIntervalSince(storedAt) < 47 * 3600 {
                DeliveryManager.shared.relayDelivered(item)
                TransportDiary.note("[relay] получатель забрал кадр")
            } else {
                DeliveryManager.shared.relayTerminal(
                    item,
                    status: "не доставлено: получатель не забрал за 48 ч")
            }
        }
    }

    // MARK: Мелочи

    private func notePulse(extra: String?) {
        pulse = "опросов \(pollsDone), кадров \(framesSeen)"
            + (extra.map { " · \($0)" } ?? "")
    }

    private static func contact(of item: Outbox.QueuedMessage) -> Contact? {
        guard let id = item.contactID else { return nil }
        return ContactStore.load().first { $0.id == id }
    }

    nonisolated static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

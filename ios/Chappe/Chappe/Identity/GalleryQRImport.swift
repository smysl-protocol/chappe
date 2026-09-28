import SwiftUI
import PhotosUI
import Vision
import CryptoKit

// ============================================================================
// Импорт карточки контакта из галереи (30.07.2026) — основной путь
// УДАЛЁННОГО обмена: скриншот или картинка, присланная любым способом.
//
// - Выбор изображения — системный photos picker (PHPicker под капотом):
//   он НЕ требует доступа к фотоплёнке — ни нового entitlement, ни
//   purpose string. UIImagePickerController с запросом доступа не
//   используем сознательно (лишнее разрешение на ревью).
// - Распознавание — Vision (VNDetectBarcodesRequest), целиком на
//   устройстве: изображение никуда не уходит.
// - Несколько QR на картинке → выбор человеком, первый молча не берём.
// - Не распознан / не наша схема rm:// → честная ошибка, не тишина.
//
// ДОВЕРИЕ: карточка пришла по непроверенному каналу и могла быть
// подменена по дороге — контакт помечается НЕПРОВЕРЕННЫМ (verified =
// false). «Проверен» ставится только после сверки отпечатка голосом
// или лично — никогда при импорте.
// ============================================================================

nonisolated enum GalleryQRDecoder {

    enum Outcome: Equatable {
        /// QR на изображении не найден.
        case noQR
        /// QR есть, но ни один — не карточка нашей схемы.
        case foreignQR(count: Int)
        /// Валидные карточки (все уже помечены verified = false).
        case contacts([Contact])
    }

    /// Распознавание локально, синхронно (картинки маленькие).
    static func decode(image: UIImage) -> Outcome {
        guard let cg = image.cgImage else { return .noQR }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        // Основной путь — Vision
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cg,
                                            orientation: orientation)
        try? handler.perform([request])
        var found = (request.results ?? []).compactMap(\.payloadStringValue)

        // Фолбэк — CIDetector: в СИМУЛЯТОРЕ Vision-баркоды не
        // детектятся (проверено 30.07: тот же код на Маке находит,
        // в симуляторе пусто); на устройстве это страховка. Тоже
        // целиком локально.
        if found.isEmpty {
            let detector = CIDetector(
                ofType: CIDetectorTypeQRCode, context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            let ci = CIImage(cgImage: cg).oriented(orientation)
            found = (detector?.features(in: ci) ?? [])
                .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        }

        // Дедуп payload'ов с сохранением порядка на картинке
        var seenPayloads = Set<String>()
        let payloads = found.filter { seenPayloads.insert($0).inserted }
        guard !payloads.isEmpty else { return .noQR }

        var seenIDs = Set<String>()
        let contacts: [Contact] = payloads.compactMap { text in
            guard var contact = ContactStore.parse(text),
                  seenIDs.insert(contact.id).inserted else { return nil }
            contact.verified = false   // непроверенный канал — явно
            return contact
        }
        return contacts.isEmpty ? .foreignQR(count: payloads.count)
                                : .contacts(contacts)
    }

    /// Человекочитаемая ошибка для «нечестных» исходов.
    static func errorText(for outcome: Outcome) -> String? {
        switch outcome {
        case .noQR:
            "QR-код на изображении не найден"
        case .foreignQR(let count):
            count == 1
                ? "Это не карточка \(AppIdentity.appName) (ожидается rm://)"
                : "Ни один из \(count) QR — не карточка \(AppIdentity.appName) (ожидается rm://)"
        case .contacts:
            nil
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - Сверка ключа (WP1, 05.08.2026)

/// Сверка по образцу Signal/WhatsApp: 60-значный номер пары (обе
/// стороны видят один и тот же) + взаимная QR-сверка при встрече
/// (каждый показывает свой код и сканирует чужой; совпадение ключа —
/// отметка автоматически). Отметка «проверен» — ТОЛЬКО по явному
/// действию человека или по совпавшему скану, никогда при импорте.
/// Прежняя сверка 8 символов (40 бит) заменена: короткий отпечаток
/// остался локальным id, границей безопасности он не является.
struct ContactVerifySheet: View {
    let contact: Contact
    let onVerified: () -> Void
    let onCancel: () -> Void

    @State private var showScanner = false
    @State private var scanMismatch = false
    /// Ручное знакомство телефонов (07.08).
    @State private var pairingRequested = false
    @ObservedObject private var presence = NearbyPresence.shared

    /// Собеседник рядом = от него только что приходил пакет прямым путём.
    private var contactIsNearby: Bool {
        guard #available(iOS 26.0, *), NearbyPairing.uiEnabled else {
            return false   // выключатель после падения 08.08
        }
        return presence.isNearby(contactID: contact.id)
    }

    private var safetyDigits: String? {
        guard let mine = Identity.publicKey(),
              let theirs = contact.publicKey else { return nil }
        return SafetyNumber.digits(mine, theirs)
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Сверка ключа")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(RMDesign.textPrimary)
            LabeledContent("Имя", value: contact.name)

            if let digits = safetyDigits {
                // 12 групп по 5 цифр, обе стороны видят один номер
                Text(SafetyNumber.display(digits))
                    .font(.system(size: 20, weight: .semibold,
                                  design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 10)
                    .background(RMDesign.surface2,
                                in: RoundedRectangle(cornerRadius: 10))

                Text("У собеседника на этом экране — ТОТ ЖЕ номер. "
                   + "Продиктуйте его друг другу голосом или сверьте "
                   + "лично: совпал до цифры — по дороге никого не "
                   + "подменили.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RMDesign.textSecondary)

                if scanMismatch {
                    Label {
                        Text("КЛЮЧ НЕ СОВПАЛ. Отсканирован код с другим "
                           + "ключом — либо это чужой экран сверки, либо "
                           + "в цепочке подмена. Проверенным не помечать.")
                    } icon: {
                        Image(systemName: "xmark.shield.fill")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(RMDesign.warning)
                }

                // Взаимная QR-сверка при встрече: мой код + скан чужого
                if let mine = Identity.publicKey(),
                   let qr = MyQRView.qrImage(
                       SafetyNumber.verifyPayloadText(for: mine)) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 132, height: 132)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("При встрече: покажите этот код "
                               + "собеседнику и отсканируйте его код — "
                               + "отметка поставится автоматически.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(RMDesign.textSecondary)
                            Button {
                                scanMismatch = false
                                showScanner = true
                            } label: {
                                Label("Сканировать код собеседника",
                                      systemImage: "qrcode.viewfinder")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(RMDesign.accentLight)
                            }
                        }
                    }
                }

                Button {
                    onVerified()
                } label: {
                    Text("Номер совпал — пометить проверенным")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(RMDesign.accentLight)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RMDesign.accentSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else {
                Text("Ключ недоступен: Keychain не отдал личность или "
                   + "карточка контакта повреждена.")
                    .foregroundStyle(RMDesign.warning)
            }
            // Знакомство телефонов вручную (07.08): дверь для тех, кто
            // отказался при встрече или добавил контакт через интернет.
            // Неактивна, пока собеседник не рядом, — и сказано почему.
            Divider().background(RMDesign.textPrimary.opacity(0.12))
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    pairingRequested = true
                } label: {
                    Text("Познакомить телефоны")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(contactIsNearby
                                         ? RMDesign.accentLight
                                         : RMDesign.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(contactIsNearby ? RMDesign.accentSurface
                                                    : RMDesign.surface1)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(!contactIsNearby)
                Text(contactIsNearby
                     ? "Связь рядом станет быстрее. Собеседнику тоже нужно "
                       + "держать приложение открытым."
                     : "Доступно, когда \(contact.name) окажется рядом и "
                       + "откроет приложение: телефоны знакомятся только "
                       + "вблизи, через интернет так нельзя.")
                    .font(.system(size: 12))
                    .foregroundStyle(RMDesign.textSecondary)
            }

            Button {
                onCancel()
            } label: {
                Text("Пока не сверили")
                    .font(.system(size: 14.5))
                    .foregroundStyle(RMDesign.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(18)
        }
        .sheet(isPresented: $pairingRequested) {
            if #available(iOS 26.0, *) {
                VStack(spacing: 0) {
                    NearbyPairingCaption()
                    NearbyPairingPicker { pairingRequested = false }
                }
                .background(RMDesign.background)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RMDesign.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showScanner) {
            ScannerSheet(onFound: { payload in
                showScanner = false
                // сверка строго полным ключом: 32 байта из QR против
                // ключа карточки — совпало, значит подмены нет
                guard let scanned = SafetyNumber.parseVerify(payload),
                      let theirs = contact.publicKey,
                      scanned == theirs.rawRepresentation else {
                    scanMismatch = true
                    return
                }
                onVerified()
            }, onGalleryItem: { _ in
                showScanner = false   // сверка — только живой камерой
            })
            .ignoresSafeArea()
        }
    }
}

import SwiftUI
import CoreImage.CIFilterBuiltins
import AVFoundation
import PhotosUI

// ============================================================================
// Обмен контактами (веха, фаза 2): «мой QR» + сканер + подтверждение
// с отпечатком. В симуляторе камеры нет — вставка из буфера живёт
// в Dev (тот же payload base64).
// ============================================================================

/// Экран «мой QR»: имя + pubkey + версия одним QR; payload можно
/// скопировать (для буферного пути в симулятор).
struct MyQRView: View {
    // QR несёт схему rm://contact/… — самоописываемая карточка;
    // разбор принимает и старый голый base64. Считается на каждую
    // перерисовку: смена имени (мега-1, 14.08) обновляет карточку.
    private var payload: String? {
        _ = nameRefresh
        return ContactStore.myPayloadText()
    }
    /// Редактор своего имени (тап по имени).
    @State private var editName = false
    @State private var nameDraft = ""
    @State private var nameRefresh = 0
    /// Знакомство телефонов (фаза 1 «рядом», 07.08): пока карточка на
    /// экране, телефон готов познакомиться с телефоном собеседника —
    /// это тот же момент встречи, отдельного шага нет. Один раз за всё
    /// время: если телефоны уже знакомы, экран не появится.
    @State private var showPairing = false
    /// Сколько ключей с отказом знакомства — для двери «предлагать снова».

    var body: some View {
        VStack(spacing: 18) {
            if let payload, let image = Self.qrImage(payload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 4) {
                    // имя редактируется тапом (мега-1, 14.08); код-ID
                    // под ним стабилен и не меняется
                    Button {
                        nameDraft = Identity.hasCustomName
                            ? Identity.displayName : ""
                        editName = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(Identity.displayName)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(RMDesign.textPrimary)
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(RMDesign.textTertiary)
                        }
                    }
                    Text("ID: \(Identity.myFingerprint() ?? "—")")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(RMDesign.textSecondary)
                }
                .alert("Ваше имя", isPresented: $editName) {
                    TextField(Identity.unnamedPlaceholder, text: $nameDraft)
                    Button("Сохранить") {
                        Identity.displayName = nameDraft
                        nameRefresh += 1   // перерисовать имя и QR
                    }
                    Button("Отмена", role: .cancel) {}
                } message: {
                    Text("Имя едет в карточке знакомства; код-ID не меняется.")
                }

                // Поделиться приглашением (просьба владельца 12.08):
                // раньше приходилось делать скриншот QR и слать вручную.
                // Share-лист отдаёт PNG-ФАЙЛ с QR — собеседник сохранит
                // его и импортирует «из галереи». Заодно текст-карточка
                // (rm://…) — кто умеет, вставит ссылкой.
                // Именно файл, не SwiftUI Image (полевой отказ 13.08):
                // Image-Transferable в Telegram не материализуется —
                // «Send» молча не отправлял ничего.
                if let inviteFile = Self.inviteFileURL(payload) {
                    ShareLink(
                        item: inviteFile,
                        subject: Text("Приглашение в \(AppIdentity.appName)"),
                        message: Text(payload)
                    ) {
                        Label("Поделиться приглашением",
                              systemImage: "square.and.arrow.up")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(RMDesign.accentLight)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(RMDesign.accentSurface)
                            .clipShape(Capsule())
                    }
                }

                // буферный путь нужен только симулятору (там нет камеры);
                // на телефоне кнопка только смущала (полевой пакет 13.08)
                #if targetEnvironment(simulator)
                Button {
                    UIPasteboard.general.string = payload
                } label: {
                    Label("Скопировать (для симулятора)",
                          systemImage: "doc.on.doc")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(RMDesign.accentLight)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(RMDesign.accentSurface)
                        .clipShape(Capsule())
                }
                #endif

            } else {
                Text("Ключ недоступен — Keychain не отдал личность.")
                    .foregroundStyle(RMDesign.warning)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RMDesign.background)
        .navigationTitle("Мой QR")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // ЗНАКОМСТВО ТЕЛЕФОНОВ ВРЕМЕННО ОТКЛЮЧЕНО (полевой отказ
            // 08.08): системный экран Wi-Fi Aware ронял приложение прямо
            // на «Мой QR», то есть ломал добавление контакта — главный
            // путь знакомства людей. Правило: связь никогда не важнее
            // того, ради чего она нужна. Включим обратно, когда падение
            // будет разобрано на живом телефоне (см. NearbyPairing.uiEnabled).
            guard #available(iOS 26.0, *), NearbyPairing.uiEnabled,
                  await !NearbyPairing.alreadyPaired(),
                  await NearbyPairing.isSupported else { return }
            showPairing = true
        }
        .sheet(isPresented: $showPairing) {
            if #available(iOS 26.0, *) {
                VStack(spacing: 0) {
                    NearbyPairingCaption()
                    NearbyPairingHost()
                }
                .background(RMDesign.background)
            }
        }
    }

    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// PNG-файл приглашения для share-листа. Файловый URL — единственный
    /// вид элемента, который надёжно материализуется во всех сторонних
    /// мессенджерах (полевой отказ 13.08: SwiftUI Image как Transferable
    /// в Telegram давал пустой «Send»). Файл перезаписывается на каждый
    /// вызов — payload мог смениться после «Начать заново».
    static func inviteFileURL(_ text: String) -> URL? {
        guard let image = qrImage(text),
              let png = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Chappe-invite.png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// Подтверждение добавления: имя + отпечаток, добавляет человек.
struct ContactConfirmSheet: View {
    let contact: Contact
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Добавить контакт?")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(RMDesign.textPrimary)
            LabeledContent("Имя", value: contact.name)
            LabeledContent("Отпечаток") {
                Text(contact.id)
                    .font(.system(.body, design: .monospaced))
            }
            if contact.isUnverified {
                // карточка из галереи: канал непроверенный — говорим
                // об этом прямо ДО добавления
                Label {
                    Text("Карточка пришла по непроверенному каналу и "
                       + "могла быть подменена по дороге. Контакт будет "
                       + "помечен «непроверен» — сверьте отпечаток "
                       + "голосом или лично, отметка ставится только "
                       + "после сверки.")
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(RMDesign.warning)
            } else {
                Text("Сверьте отпечаток с собеседником по другому "
                   + "каналу — это защита от подмены ключа.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RMDesign.textSecondary)
            }
            HStack(spacing: 10) {
                Button {
                    onConfirm()
                } label: {
                    Text("Добавить")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(RMDesign.accentLight)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RMDesign.accentSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button {
                    onCancel()
                } label: {
                    Text("Отмена")
                        .font(.system(size: 14.5))
                        .foregroundStyle(RMDesign.textSecondary)
                        .frame(minWidth: 90, minHeight: 48)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(RMDesign.background)
        .preferredColorScheme(.dark)
    }
}

/// Громкое предупреждение о смене ключа (WP1, 05.08.2026): карточка
/// с именем существующего контакта, но ДРУГИМ ключом — главный признак
/// подмены. Молча не принимается (гейт в ContactStore.upsertGuarded);
/// здесь человек решает явно. Безопасный выбор — первым и заметным.
struct KeyChangeWarningSheet: View {
    let prompt: KeyChangePrompt
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Ключ контакта изменился")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(RMDesign.warning)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(RMDesign.warning)
            }
            LabeledContent("Имя", value: prompt.candidate.name)
            LabeledContent("Был ключ") {
                Text(prompt.existing.id)
                    .font(.system(.body, design: .monospaced))
            }
            LabeledContent("Стал ключ") {
                Text(prompt.candidate.id)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(RMDesign.warning)
            }
            Text("Так выглядит подмена собеседника. Ключ честно меняется "
               + "только если человек переустановил приложение или сменил "
               + "устройство — уточните у него ПО ДРУГОМУ КАНАЛУ (голосом, "
               + "лично) прежде чем принимать. Приняв новый ключ, сверьте "
               + "его заново — до сверки контакт будет помечен "
               + "«непроверен».")
                .font(.system(size: 12.5))
                .foregroundStyle(RMDesign.textSecondary)

            Button {
                onReject()
            } label: {
                Text("Не принимать (безопасно)")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(RMDesign.accentLight)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RMDesign.accentSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button {
                onAccept()
            } label: {
                Text("Принять новый ключ — сверить заново")
                    .font(.system(size: 14.5))
                    .foregroundStyle(RMDesign.warning)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RMDesign.background)
        .preferredColorScheme(.dark)
    }
}

/// Экран сканера (Ф5.1): камера + кнопки «из галереи» и «фонарь»
/// внутри. Подписи по-русски — свои, не системные.
struct ScannerSheet: View {
    let onFound: (String) -> Void
    let onGalleryItem: (PhotosPickerItem) -> Void

    @State private var torchOn = false
    @State private var galleryItem: PhotosPickerItem?

    var body: some View {
        ZStack(alignment: .bottom) {
            QRScannerView(torchOn: torchOn, onFound: onFound)
                .ignoresSafeArea()
            HStack(spacing: 14) {
                PhotosPicker(selection: $galleryItem, matching: .images) {
                    Label("Из галереи", systemImage: "photo.on.rectangle")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                Button {
                    torchOn.toggle()
                } label: {
                    Label(torchOn ? "Фонарь вкл" : "Фонарь",
                          systemImage: torchOn
                          ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(torchOn ? .yellow : .white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(.black.opacity(0.55), in: Capsule())
                }
            }
            .padding(.bottom, 28)
        }
        .onChange(of: galleryItem) {
            if let item = galleryItem {
                galleryItem = nil
                onGalleryItem(item)
            }
        }
    }
}

/// QR-сканер (AVFoundation): на устройстве. Найденный payload уходит
/// в onFound; камеры нет/нет доступа — честная подсказка.
struct QRScannerView: UIViewControllerRepresentable {
    var torchOn: Bool = false
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: ScannerController,
                                context: Context) {
        controller.setTorch(on: torchOn)
    }

    final class Coordinator: NSObject,
                             AVCaptureMetadataOutputObjectsDelegate {
        let onFound: (String) -> Void
        private var fired = false
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !fired,
                  let object = objects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr, let text = object.stringValue else { return }
            fired = true
            DispatchQueue.main.async { self.onFound(text) }
        }
    }

    final class ScannerController: UIViewController {
        weak var delegate: AVCaptureMetadataOutputObjectsDelegate?
        private let session = AVCaptureSession()
        private var device: AVCaptureDevice?

        /// Фонарь (Ф5.1): сканирование в темноте — обычный полевой случай.
        func setTorch(on: Bool) {
            guard let device, device.hasTorch,
                  device.torchMode != (on ? .on : .off) else { return }
            try? device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                showHint("Камера недоступна — проверьте разрешение "
                       + "для камеры в Настройках телефона")
                return
            }
            self.device = device
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        private func showHint(_ text: String) {
            let label = UILabel()
            label.text = text
            label.numberOfLines = 0
            label.textColor = .white
            label.textAlignment = .center
            label.frame = view.bounds.insetBy(dx: 24, dy: 24)
            view.addSubview(label)
        }
    }
}

import SwiftUI
import Network
import DeviceDiscoveryUI
import WiFiAware

// ============================================================================
// Парный зонд знакомства телефонов (13.08). Полевой блокер 12.08:
// системный экран паринга поднимается, но ПУСТОЙ («Nearby devices will
// appear here…») — спаривание ни разу не завершилось, а без пары
// Wi-Fi Aware не поднимает data-путь вовсе (API требует WAPairedDevice).
//
// ГИПОТЕЗА (сверено по swiftinterface SDK 13.08): обе руки строятся с
// .allPairedDevices — списком УЖЕ спаренных устройств, который у
// никогда-не-спаренных телефонов пуст by construction. Для ПЕРВИЧНОГО
// знакомства предназначен .userSpecifiedDevices — «устройства, которые
// выберет человек» (системный экран показывает и НОВЫЕ устройства).
//
// Зонд — A/B на двух телефонах: роль (показываю/выбираю) × вариант
// (A: userSpecified — кандидат-фикс; B: allPaired — как в проде,
// контроль). Каждый шаг фиксируется СИНХРОННО в aware_probe.txt
// (дневник пишет async и теряет буфер при краше — урок 11.08) и в
// дневник. Прогон: обе стороны жмут ОДИН вариант, публикующая — раньше.
// ============================================================================

/// Синхронная метка зонда: файл + дневник.
@MainActor
func awareProbeMark(_ s: String) {
    TransportDiary.note("[aware-зонд] " + s)
    if let docs = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask).first {
        let url = docs.appendingPathComponent("aware_probe.txt")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let prev = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? Data((prev + stamp + " " + s + "\n").utf8)
            .write(to: url, options: .atomic)
    }
}

@available(iOS 26.0, *)
struct AwarePairProbeView: View {

    enum Variant: String, CaseIterable, Identifiable {
        case userSpecified = "A: userSpecified (кандидат-фикс)"
        case allPaired = "B: allPaired (как в проде)"
        var id: String { rawValue }
    }

    @State private var variant: Variant = .userSpecified
    @State private var showHost = false
    @State private var showPicker = false
    @State private var log: [String] = []
    @Environment(\.dismiss) private var dismiss

    private func mark(_ s: String) {
        awareProbeMark(s)
        log.append(s)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Вариант (обе стороны жмут ОДИН)") {
                    Picker("Вариант", selection: $variant) {
                        ForEach(Variant.allCases) { v in
                            Text(v.rawValue).tag(v)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Section("Роль этого телефона") {
                    Button("Я ПОКАЗЫВАЮ (публикующая сторона, жать ПЕРВОЙ)") {
                        mark("host: вариант \(variant.rawValue) — открываю "
                             + "системный экран готовности")
                        showHost = true
                    }
                    Button("Я ВЫБИРАЮ (сканирующая сторона, жать ВТОРОЙ)") {
                        mark("picker: вариант \(variant.rawValue) — открываю "
                             + "системный выбор устройства")
                        showPicker = true
                    }
                }
                Section("Статус пар") {
                    Button("Проверить hasPairedDevices") {
                        Task {
                            let paired = await NearbyWiFiChannel
                                .hasPairedDevices()
                            mark("hasPairedDevices = \(paired)")
                        }
                    }
                }
                Section("Журнал (полный — aware_probe.txt)") {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 12,
                                                design: .monospaced))
                    }
                }
            }
            .navigationTitle("Зонд знакомства")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .sheet(isPresented: $showHost) {
                AwareProbeHost(userSpecified: variant == .userSpecified,
                               mark: { awareProbeMark($0) })
            }
            .sheet(isPresented: $showPicker) {
                AwareProbePicker(userSpecified: variant == .userSpecified,
                                 mark: { awareProbeMark($0) },
                                 onFinished: { outcome in
                    mark("picker завершён: \(outcome)")
                    showPicker = false
                    Task {
                        let paired = await NearbyWiFiChannel
                            .hasPairedDevices()
                        mark("после паринга hasPairedDevices = \(paired)")
                    }
                })
            }
            .onAppear { mark("зонд открыт") }
        }
    }
}

/// Публикующая сторона зонда: системный экран готовности к спариванию.
@available(iOS 26.0, *)
private struct AwareProbeHost: UIViewControllerRepresentable {
    let userSpecified: Bool
    let mark: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard let service = WAPublishableService
            .allServices[NearbyWiFiChannel.serviceName] else {
            mark("host: сервис НЕ объявлен — plist?")
            return UIViewController()
        }
        let devices: WAPublisherListener.Devices =
            userSpecified ? .userSpecifiedDevices : .allPairedDevices
        let provider: WAPublisherListener = .wifiAware(
            .connecting(to: service, from: devices))
        let supported = DDDevicePairingViewController.isSupported(provider)
        mark("host: isSupported=\(supported), поднимаю экран")
        return DDDevicePairingViewController(listenerProvider: provider,
                                             access: .permanent)
    }

    func updateUIViewController(_ controller: UIViewController,
                                context: Context) {}
}

/// Сканирующая сторона зонда: системный выбор устройства.
@available(iOS 26.0, *)
private struct AwareProbePicker: UIViewControllerRepresentable {
    let userSpecified: Bool
    let mark: @MainActor (String) -> Void
    let onFinished: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard let service = WASubscribableService
            .allServices[NearbyWiFiChannel.serviceName] else {
            mark("picker: сервис НЕ объявлен — plist?")
            onFinished("нет сервиса")
            return UIViewController()
        }
        let devices: WASubscriberBrowser.Devices =
            userSpecified ? .userSpecifiedDevices : .allPairedDevices
        guard let picker = DDDevicePickerViewController(
            browseDescriptor: WASubscriberBrowser
                .wifiAware(.connecting(to: devices, from: service))
                .makeDescriptor(),
            parameters: nil,
            access: .permanent)
        else {
            mark("picker: DDDevicePickerViewController не создался")
            onFinished("контроллер nil")
            return UIViewController()
        }
        mark("picker: экран поднят, жду выбор/endpoint")
        Task { @MainActor in
            do {
                let endpoint = try await picker.endpoint
                mark("picker: ENDPOINT ПОЛУЧЕН: \(String(describing: endpoint))")
                onFinished("endpoint получен")
            } catch {
                mark("picker: ошибка endpoint: \(error.localizedDescription)")
                onFinished("ошибка: \(error.localizedDescription)")
            }
        }
        return picker
    }

    func updateUIViewController(_ controller: UIViewController,
                                context: Context) {}
}

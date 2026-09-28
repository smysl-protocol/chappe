import SwiftUI
import Combine

// ============================================================================
// Карточка SOS (задание 30.07, Ф3.2–3.3).
//
// SOSInfoCard — постоянная честная карточка в чате SOS: КОМУ уходит
// сигнал (только контактам — широковещания в v1 нет), КАК передаётся
// геопозиция (точная, на момент отправки), ЧЕГО ЖДАТЬ (ответ придёт
// личным сообщением).
//
// SOSDraftSheet — карточка-черновик: модель ЗАПОЛНЯЕТ поля по описанию,
// человек читает, правит и подтверждает. Автоотправки нет и не будет
// (правило №9). Все поля можно заполнить и руками, без модели.
// ============================================================================

struct SOSInfoCard: View {
    let contactCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Как работает SOS", systemImage: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RMDesign.textSecondary)

            infoRow(icon: "person.2",
                    title: "Кому",
                    text: contactCount > 0
                    ? "Вашим контактам (\(contactCount)) — лично каждому. "
                      + "Больше сигнал не уходит никому: широковещания "
                      + "в этой версии нет."
                    : "Пока некому: контактов нет. Добавьте контакт по QR "
                      + "во вкладке «Чаты» — иначе сигнал не уйдёт.")
            infoRow(icon: "location",
                    title: "Позиция",
                    text: "К сигналу прикладывается точная позиция "
                        + "на момент отправки (если GPS даст фикс).")
            infoRow(icon: "arrow.turn.down.left",
                    title: "Чего ждать",
                    text: "Ответ придёт личным сообщением — подсветится "
                        + "красным и прозвучит сигнал.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RMDesign.surface1,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(RMDesign.danger.opacity(0.35)))
    }

    private func infoRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(RMDesign.danger)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RMDesign.textSecondary)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(RMDesign.textPrimary)
            }
        }
    }
}

// MARK: - Черновик

@MainActor
final class SOSDraftModel: ObservableObject {

    @Published var descriptionText: String
    @Published var severity: SOSReport.Severity = .high
    @Published var peopleCount = 1
    @Published var injury: SOSReport.Injury = .none
    @Published var needs: Set<SOSReport.Need> = []

    @Published var isExtracting = false
    @Published var extractHint: String?
    @Published var fix: PositionFix?
    @Published var fixHint = "запрашиваю позицию…"
    @Published var isSending = false
    @Published var errorMessage: String?

    init(context: String = "") {
        descriptionText = context
    }

    /// Точная позиция на момент отправки — запрашивается при открытии
    /// карточки; SOS работает и без неё (честно скажем, что фикса нет).
    func requestPosition() async {
        switch await LocationProvider.shared.requestFix() {
        case .fix(let fix):
            self.fix = fix
            fixHint = String(format: "точная позиция: %.5f, %.5f (±%.0f м)",
                             fix.lat, fix.lon, fix.horizontalAccuracy)
        case .denied:
            fixHint = "нет разрешения на геолокацию — сигнал уйдёт без позиции"
        case .unavailable(let reason):
            fixHint = "позиции нет (\(reason)) — сигнал уйдёт без неё"
        }
    }

    /// Модель заполняет поля по описанию. Только заполнение черновика —
    /// решение и отправка всегда за человеком.
    func fillWithModel() {
        let text = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isExtracting else { return }
        isExtracting = true
        extractHint = nil
        Task {
            defer { isExtracting = false }
            do {
                let request = LLMRequest(prompt: SOSExtraction.prompt(for: text),
                                         maxTokens: 200,
                                         samplingOverride: .extraction)
                let result = try await ModelScheduler.shared
                    .withProvider(.sos) { provider in
                        try await StructuredLLM.callRaw(
                            provider: provider, request: request,
                            spec: SOSExtraction.spec, as: SOSReport.self,
                            validate: SOSReport.validate(_:))
                    }
                let report = result.value
                severity = report.severity
                peopleCount = report.peopleCount
                injury = report.injury
                needs = Set(report.needs)
                extractHint = "Поля заполнены по описанию — проверьте "
                            + "и поправьте перед отправкой."
            } catch {
                extractHint = "Не удалось заполнить автоматически — "
                            + "заполните поля вручную."
            }
        }
    }

    /// Собранный человеком отчёт (needs пустой — «other» не выдумываем,
    /// ставим evacuation как самый общий? Нет: честно требуем выбор).
    var report: SOSReport? {
        guard !needs.isEmpty else { return nil }
        return SOSReport(type: .sos, severity: severity,
                         peopleCount: peopleCount, injury: injury,
                         needs: Array(needs))
    }

    /// Отправка — только этой кнопкой, только человеком.
    func confirmAndSend() -> Bool {
        guard let report else {
            errorMessage = "Отметьте хотя бы одну потребность."
            return false
        }
        do {
            try SOSCenter.send(report: report, fix: fix)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct SOSDraftSheet: View {
    @StateObject private var model: SOSDraftModel
    @Environment(\.dismiss) private var dismiss
    /// Вызывается после фактической отправки (для подсветки чата).
    var onSent: (() -> Void)?

    init(context: String = "", onSent: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: SOSDraftModel(context: context))
        self.onSent = onSent
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SOSInfoCard(contactCount: ContactStore.load().count)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                Section("Что случилось") {
                    TextEditor(text: $model.descriptionText)
                        .frame(minHeight: 80)
                    Button {
                        model.fillWithModel()
                    } label: {
                        if model.isExtracting {
                            HStack {
                                ProgressView()
                                Text("Заполняю поля…")
                            }
                        } else {
                            Label("Заполнить поля по описанию",
                                  systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(model.isExtracting
                              || model.descriptionText.trimmingCharacters(
                                  in: .whitespacesAndNewlines).isEmpty)
                    if let hint = model.extractHint {
                        Text(hint)
                            .font(.system(size: 12))
                            .foregroundStyle(RMDesign.textSecondary)
                    }
                }
                .listRowBackground(RMDesign.surface1)

                Section("Карточка — проверьте и поправьте") {
                    Picker("Срочность", selection: $model.severity) {
                        Text("низкая").tag(SOSReport.Severity.low)
                        Text("средняя").tag(SOSReport.Severity.medium)
                        Text("высокая").tag(SOSReport.Severity.high)
                        Text("критично").tag(SOSReport.Severity.critical)
                    }
                    Stepper("Людей: \(model.peopleCount)",
                            value: $model.peopleCount, in: 0...31)
                    Picker("Травма", selection: $model.injury) {
                        Text("нет").tag(SOSReport.Injury.none)
                        Text("кровотечение").tag(SOSReport.Injury.bleeding)
                        Text("перелом").tag(SOSReport.Injury.fracture)
                        Text("ожог").tag(SOSReport.Injury.burn)
                        Text("травма головы").tag(SOSReport.Injury.head)
                        Text("без сознания").tag(SOSReport.Injury.unconscious)
                        Text("другая").tag(SOSReport.Injury.other)
                    }
                }
                .listRowBackground(RMDesign.surface1)

                Section("Что нужно (хотя бы одно)") {
                    ForEach(SOSReport.Need.allCases, id: \.self) { need in
                        Toggle(needLabel(need), isOn: Binding(
                            get: { model.needs.contains(need) },
                            set: { on in
                                if on {
                                    // потолок из схемы: не больше 4
                                    if model.needs.count < 4 {
                                        model.needs.insert(need)
                                    }
                                } else {
                                    model.needs.remove(need)
                                }
                            }))
                    }
                }
                .listRowBackground(RMDesign.surface1)

                Section {
                    Label(model.fixHint, systemImage: "location")
                        .font(.system(size: 13))
                        .foregroundStyle(RMDesign.textSecondary)
                }
                .listRowBackground(RMDesign.surface1)

                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(RMDesign.danger)
                    }
                    .listRowBackground(RMDesign.surface1)
                }

                Section {
                    // Необратимое действие — текстовая подпись, не иконка
                    Button {
                        if model.confirmAndSend() {
                            onSent?()
                            dismiss()
                        }
                    } label: {
                        Text("Отправить SOS контактам")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RMDesign.danger)
                    .disabled(model.needs.isEmpty)
                    Text("Отправляете вы, не модель. Сигнал уйдёт "
                       + "контактам лично; ответ придёт личным сообщением.")
                        .font(.system(size: 12))
                        .foregroundStyle(RMDesign.textTertiary)
                }
                .listRowBackground(RMDesign.surface1)
            }
            .rmScreenBackground()
            .navigationTitle("Карточка SOS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
            }
            .task { await model.requestPosition() }
        }
        .preferredColorScheme(.dark)
    }

    private func needLabel(_ need: SOSReport.Need) -> String {
        switch need {
        case .bandages: "бинты"
        case .water: "вода"
        case .food: "еда"
        case .boat: "лодка"
        case .vehicle: "транспорт"
        case .doctor: "врач"
        case .medicine: "лекарства"
        case .evacuation: "эвакуация"
        case .fuel: "топливо"
        case .shelter: "укрытие"
        }
    }
}

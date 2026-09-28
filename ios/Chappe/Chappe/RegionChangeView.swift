import SwiftUI

// ============================================================================
// Смена региона радиоузла (UX-проход 06.08). Повод: узел приехал с
// EU_868, проект настроен на SG_923 — приложение честно предупреждало,
// но исправить было нечем, кроме чужого приложения Meshtastic.
//
// Регион — это законность излучения: частоты, разрешённые в стране,
// где человек находится. Поэтому НЕ «исправить в один тап по
// предупреждению», а отдельный экран с явным выбором и подтверждением
// (класс C по спеке Софи: значимое действие — отдельным экраном).
//
// Успех подтверждается СВОИМ событием (правило 5): не записью в
// ToRadio, а регионом, прочитанным заново после перезагрузки узла, —
// узел сохраняет настройку и уходит в ребут, связь рвётся штатно.
// ============================================================================

struct RegionChangeView: View {

    @ObservedObject private var probe = NodeProbe.shared

    /// Регионы Meshtastic с человеческой подсказкой «где это законно».
    /// Коды — enum RegionCode из config.proto (та же таблица, что
    /// NodeProbe.regionNames). «Не задан» в списке отсутствует
    /// намеренно: узел без региона в эфир не выходит.
    static let choices: [(code: UInt64, name: String, hint: String)] = [
        (18, "SG_923", "Сингапур, Вьетнам, Бали"),
        (3,  "EU_868", "Европа"),
        (2,  "EU_433", "Европа, 433 МГц"),
        (1,  "US",     "США, Канада, Мексика"),
        (9,  "RU",     "Россия"),
        (12, "TH",     "Таиланд"),
        (10, "IN",     "Индия"),
        (6,  "ANZ",    "Австралия и Новая Зеландия"),
        (5,  "JP",     "Япония"),
        (7,  "KR",     "Южная Корея"),
        (8,  "TW",     "Тайвань"),
        (4,  "CN",     "Китай"),
        (11, "NZ_865", "Новая Зеландия, 865 МГц"),
        (15, "UA_868", "Украина, 868 МГц"),
        (14, "UA_433", "Украина, 433 МГц"),
        (17, "MY_919", "Малайзия, 919 МГц"),
        (16, "MY_433", "Малайзия, 433 МГц"),
        (13, "2.4 ГГц", "Весь мир, короткая дальность"),
    ]

    @State private var selectedCode: UInt64?
    @State private var confirmApply = false
    /// Имя региона, который отправлен узлу; не nil = ждём подтверждения
    /// перечитанным фактом.
    @State private var appliedName: String?
    /// Узел фактически ушёл в перезагрузку (связь рвалась). До этого
    /// момента сравнивать регион рано: сразу после записи узел ещё
    /// секунды живёт со старым — итог показал бы ложное «не сменился».
    @State private var sawReboot = false
    /// Перезагрузки так и не случилось за отведённое время — узел
    /// команду не принял; молчать нельзя (правило 3).
    @State private var rebootTimedOut = false
    @State private var sendFailed = false

    private var selected: (code: UInt64, name: String, hint: String)? {
        Self.choices.first { $0.code == selectedCode }
    }

    var body: some View {
        List {
            explainSection
            if let appliedName {
                outcomeSection(appliedName)
            }
            if probe.phase != .ready && appliedName == nil {
                notConnectedSection
            }
            choicesSection
            applySection
        }
        .scrollContentBackground(.hidden)
        .rmScreenBackground()
        .navigationTitle("Страна и частоты")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // стартовый выбор — ожидаемый регион проекта, не текущий
            // регион узла: сюда приходят, чтобы привести узел к плану
            if selectedCode == nil {
                selectedCode = Self.choices
                    .first { $0.name == NodeRegistry.expectedRegion() }?.code
            }
        }
    }

    // MARK: Что это и почему это серьёзно

    private var explainSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Здесь выбирается страна, по правилам которой "
                   + "радиоустройство выходит в эфир. Устройства с "
                   + "разными настройками друг друга не слышат.")
                    .font(.system(size: 14))
                    .foregroundStyle(RMDesign.textPrimary)
                Label("Выбирайте страну, где вы находитесь: излучать "
                    + "на чужих частотах может быть незаконно.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(RMDesign.warning)
            }
            .padding(.vertical, 4)
            LabeledContent("Сейчас на устройстве",
                           value: probe.facts.region ?? "не прочитан")
        }
        .listRowBackground(RMDesign.surface1)
    }

    // MARK: Итог применения — по перечитанному факту, не по записи

    @ViewBuilder
    private func outcomeSection(_ applied: String) -> some View {
        Section {
            if sawReboot && probe.phase == .ready {
                // узел перезагрузился и вернулся — регион перечитан
                if probe.facts.region == applied {
                    Label("Готово: устройство работает в регионе \(applied)",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(RMDesign.success)
                } else {
                    Label("Устройство вернулось с регионом "
                        + "\(probe.facts.region ?? "—"), а не \(applied). "
                        + "Попробуйте ещё раз.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(RMDesign.warning)
                }
            } else if rebootTimedOut && !sawReboot {
                Label("Устройство не перезагрузилось — похоже, команду "
                    + "не приняло. Проверьте его прошивку и попробуйте "
                    + "ещё раз.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(RMDesign.warning)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(sawReboot
                             ? "Устройство перезагружается…"
                             : "Команда отправлена — устройство сохраняет "
                             + "настройку и перезагрузится…")
                            .fontWeight(.medium)
                    }
                    Text("Связь прервётся примерно на полминуты — это "
                       + "нормально. Подключусь сам и проверю, что регион "
                       + "сменился.")
                        .font(.caption)
                        .foregroundStyle(RMDesign.textSecondary)
                }
            }
        }
        .listRowBackground(RMDesign.surface1)
        .onChange(of: probe.phase) {
            if appliedName != nil, probe.phase != .ready {
                sawReboot = true
            }
        }
    }

    private var notConnectedSection: some View {
        Section {
            Label("Радиоустройство не подключено — вернитесь на экран "
                + "«Дальняя связь» и подключитесь, тогда настройку "
                + "можно будет сменить.",
                  systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 13.5))
                .foregroundStyle(RMDesign.textSecondary)
        }
        .listRowBackground(RMDesign.surface1)
    }

    // MARK: Выбор

    private var choicesSection: some View {
        Section("Страна") {
            ForEach(Self.choices, id: \.code) { choice in
                Button {
                    selectedCode = choice.code
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.name)
                                .foregroundStyle(RMDesign.textPrimary)
                            Text(choice.hint)
                                .font(.caption)
                                .foregroundStyle(RMDesign.textSecondary)
                        }
                        Spacer()
                        if selectedCode == choice.code {
                            Image(systemName: "checkmark")
                                .foregroundStyle(RMDesign.accentLight)
                        }
                    }
                }
            }
        }
        .listRowBackground(RMDesign.surface1)
    }

    // MARK: Применение — с подтверждением, необратимое словами

    @ViewBuilder
    private var applySection: some View {
        Section {
            Button {
                confirmApply = true
            } label: {
                Label(selected.map { "Перевести устройство на \($0.name)" }
                      ?? "Выберите страну",
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .medium))
            }
            .disabled(selected == nil || probe.phase != .ready)
            if sendFailed {
                Text("Команда не отправилась — устройство не подключено "
                   + "или настройки ещё не прочитаны. Попробуйте ещё раз.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RMDesign.warning)
            }
        } footer: {
            Text("Устройство сохранит настройку и перезагрузится; "
               + "связь прервётся примерно на полминуты. Остальные "
               + "настройки радио не меняются.")
        }
        .listRowBackground(RMDesign.surface1)
        .confirmationDialog(
            selected.map {
                "Перевести устройство на \($0.name) (\($0.hint))?"
            } ?? "",
            isPresented: $confirmApply, titleVisibility: .visible) {
            Button("Сменить регион") { apply() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Убедитесь, что этот регион разрешён там, где вы "
               + "находитесь.")
        }
    }

    private func apply() {
        guard let selected else { return }
        sendFailed = false
        guard probe.setRegion(code: selected.code) else {
            sendFailed = true
            return
        }
        // выбранный регион становится ожидаемым: дальше предупреждения
        // сверяют узлы с НИМ (владелец сменил план, а не ошибся)
        NodeRegistry.setExpectedRegion(selected.name)
        appliedName = selected.name
        sawReboot = false
        rebootTimedOut = false
        // узел уходит в ребут секунд через пять после записи; нет
        // обрыва за 20 с — команда не принята, и это надо сказать
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            if !sawReboot { rebootTimedOut = true }
        }
    }
}

#Preview {
    NavigationStack { RegionChangeView() }
        .preferredColorScheme(.dark)
}

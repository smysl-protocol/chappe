import SwiftUI

// ============================================================================
// «О приложении» (Настройки, задание 30.07): откуда имя, первое сообщение
// оптического телеграфа, версии словаря и протокола, атрибуция.
// Статический выверенный контент — не генерация (правило №5 проекта).
// ============================================================================

struct AboutView: View {

    /// Версия приложения из собранного бандла.
    private var appVersion: String {
        let short = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        case let (nil, b?): return b
        default: return "—"
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppIdentity.appName)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(RMDesign.textPrimary)
                    Text("Мессенджер, которому не нужен интернет: сообщения "
                       + "идут по радио от телефона к телефону.")
                        .font(.system(size: 14))
                        .foregroundStyle(RMDesign.textSecondary)
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(RMDesign.surface1)

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Приложение названо в честь Клода Шаппа — "
                       + "изобретателя оптического телеграфа (1792), первой "
                       + "в мире сети дальней связи без проводов и курьеров. "
                       + "Ассистент носит имя Софи — Sophie Françoise Chappe, "
                       + "сестры изобретателя.")
                        .font(.system(size: 14))
                        .foregroundStyle(RMDesign.textSecondary)

                    Text("В марте 1791 года система Шаппа передала первое "
                       + "сообщение — между Брюлоном и Парсе:")
                        .font(.system(size: 14))
                        .foregroundStyle(RMDesign.textSecondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("«Si vous réussissez, vous serez bientôt "
                           + "couverts de gloire»")
                            .font(.system(size: 15, weight: .medium,
                                          design: .serif))
                            .italic()
                            .foregroundStyle(RMDesign.textPrimary)
                        // UX-проход 06.08: перевод обрезался многоточием
                        // («покроете себя сл…») — фиксируем перенос
                        Text("«Если вы преуспеете, вы вскоре покроете "
                           + "себя славой»")
                            .font(.system(size: 13))
                            .foregroundStyle(RMDesign.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RMDesign.surface2,
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.vertical, 4)
            } header: {
                Text("Откуда имя")
                    .foregroundStyle(RMDesign.textSecondary)
            }
            .listRowBackground(RMDesign.surface1)

            Section {
                LabeledContent("Приложение") { Text(appVersion) }
                LabeledContent("Словарь Smysl") {
                    if let codec = RMCodec.shared {
                        Text("\(codec.version) · отпечаток "
                           + String(format: "0x%02x", codec.tableHash))
                    } else {
                        Text("не загружен")
                    }
                }
                LabeledContent("Протокол") {
                    Text("v\(Envelope.version)")
                }
            } header: {
                Text("Версии")
                    .foregroundStyle(RMDesign.textSecondary)
            }
            .listRowBackground(RMDesign.surface1)
            .foregroundStyle(RMDesign.textPrimary)

            Section {
                Text("Локальная модель: Qwen3-4B-Instruct-2507, лицензия "
                   + "Apache 2.0. © 2024 Alibaba Cloud.")
                Text("Офлайн-справочник мест: данные GeoNames "
                   + "(geonames.org), лицензия CC-BY 4.0.")
                Text("Карта: © OpenStreetMap contributors | OpenFreeMap "
                   + "© OpenMapTiles.")
            } header: {
                Text("Атрибуция")
                    .foregroundStyle(RMDesign.textSecondary)
            }
            .font(.system(size: 13))
            .foregroundStyle(RMDesign.textSecondary)
            .listRowBackground(RMDesign.surface1)
        }
        .scrollContentBackground(.hidden)
        .rmScreenBackground()
        .navigationTitle("О приложении")
    }
}

#Preview {
    NavigationStack { AboutView() }
        .preferredColorScheme(.dark)
}

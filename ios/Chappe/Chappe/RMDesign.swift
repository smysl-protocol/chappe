import SwiftUI

// ============================================================================
// Глобальные дизайн-токены приложения — design/sophie/design_tokens.md.
//
// Продуктовое решение (зафиксировано 27.07.2026): тема ОДНА, тёмная —
// OLED/батарея, ночное использование; вопрос светлой темы закрыт.
//
// Правило двух акцентов: нейтральный акцент приложения #9184d9 — всё,
// кроме Софи; синий #5aaef2 и производные — только элементы Софи
// (см. SophieDesign). Опасность/SOS — #e2564f.
// ============================================================================

nonisolated enum RMDesign {

    // Полотно и поверхности
    static let background = Color(hex: 0x161826)     // фон приложения
    static let surface1 = Color(hex: 0x1c1e2c)       // карточки, поля, строки
    static let surface2 = Color(hex: 0x232532)       // чужой пузырь, hover

    // Текст
    static let textPrimary = Color(hex: 0xe9e9ed)
    static let textSecondary = Color(hex: 0xe9e9ed).opacity(0.55)
    static let textTertiary = Color(hex: 0xe9e9ed).opacity(0.40)

    // Нейтральный акцент приложения (НЕ для Софи)
    static let accent = Color(hex: 0x9184d9)
    static let accentLight = Color(hex: 0xd2cefd)
    static let accentSurface = Color(hex: 0x2b2741)

    // Служебные
    static let danger = Color(hex: 0xe2564f)         // опасность / SOS
    static let success = Color(hex: 0x6fae86)        // успех / прочитано
    static let warning = Color(hex: 0xd6b06a)        // внимание / очередь
}

extension View {
    /// Единый фон экрана со списком/формой: системную подложку прячем,
    /// подставляем полотно из токенов.
    func rmScreenBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(RMDesign.background)
    }
}

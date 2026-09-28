import SwiftUI

// ============================================================================
// Индикаторы диктовки в композере (state-машина: recording/processing).
// recording: слева × (отмена), центр — живая волна + таймер, справа ■
// (стоп) на месте mic. Текста НЕТ ни в каком виде — партиалы копятся
// в буфере SpeechDictation. Чистые вью: значения приходят параметрами,
// поэтому же ими рисуются канон-скриншоты.
// ============================================================================

/// Полоса записи — заменяет поле ввода (высота как у поля, 44pt).
struct DictationRecordingBar: View {
    let levels: [Float]
    let elapsed: TimeInterval
    let accent: Color            // синий в чатах Софи, нейтральный в демо
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RMDesign.textSecondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Отменить диктовку")

            DictationWaveView(levels: levels, color: accent)
                .frame(maxWidth: .infinity)

            Text(Self.timerText(elapsed))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(RMDesign.textSecondary)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(accent)
                    .frame(width: 40, height: 40)   // на месте mic
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Остановить и обработать")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: SophieDesign.controlSize)
        .background(RMDesign.surface1)
        .clipShape(RoundedRectangle(cornerRadius: SophieDesign.fieldRadius))
        .overlay(RoundedRectangle(cornerRadius: SophieDesign.fieldRadius)
            .strokeBorder(accent.opacity(0.45), lineWidth: 1))
    }

    static func timerText(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Волна амплитуды: столбики по последним уровням записи.
struct DictationWaveView: View {
    let levels: [Float]
    let color: Color

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(color.opacity(0.85))
                    .frame(width: 2.5,
                           height: 3 + CGFloat(min(1, levels[i])) * 19)
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.1), value: levels)
        .accessibilityLabel("Идёт запись")
    }
}

/// Спиннер-полоса после ■: «распознаю…» (файл в распознавателе),
/// затем «обрабатываю…» (текст в семантическом конвейере).
struct DictationProcessingBar: View {
    var label = "обрабатываю…"

    var body: some View {
        HStack(spacing: 9) {
            ArcSpinner()
            Text(label)
                .font(.system(size: 13.5))
                .foregroundStyle(RMDesign.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: SophieDesign.controlSize)
        .background(RMDesign.surface1)
        .clipShape(RoundedRectangle(cornerRadius: SophieDesign.fieldRadius))
    }
}

/// Рисованный спиннер: крутится в приложении и честно рендерится
/// в канон-скриншотах (системный ProgressView ImageRenderer не умеет).
struct ArcSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(RMDesign.textSecondary,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 15, height: 15)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false),
                       value: spinning)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}

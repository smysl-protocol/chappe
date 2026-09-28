//
//  DictationScreenshotTests.swift
//  RMTests
//
//  Скрины состояний диктовки (state-машина): recording / processing /
//  review — в design/sophie/screens/. Рисуются теми же вью, что и в
//  приложении (DictationRecordingBar/ProcessingBar — чистые вью).
//

import Foundation
import SwiftUI
import Testing
@testable import Chappe

struct DictationScreenshotTests {

    @MainActor
    private func writePNG(_ view: some View, name: String) throws {
        let content = view
            .frame(width: 390)
            .background(RMDesign.background)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        let image = try #require(renderer.uiImage, "\(name) не отрендерился")
        let png = try #require(image.pngData())
        let out = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("design/sophie/screens/\(name).png")
        try FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: out)
        print("канон: \(out.path) — \(png.count) байт")
        #expect(png.count > 5_000, "подозрительно маленький скриншот \(name)")
    }

    /// Волна — детерминированная фикстура уровней (речь с паузами).
    private var fixtureLevels: [Float] {
        (0..<SpeechDictation.barCount).map { i in
            let phase = Float(i) / 4
            return 0.15 + 0.7 * abs(sin(phase)) * (i % 7 == 0 ? 0.3 : 1)
        }
    }

    @Test @MainActor
    func canonizeDictationStates() throws {
        try writePNG(
            DictationRecordingBar(levels: fixtureLevels, elapsed: 17,
                                  accent: RMDesign.accentLight,
                                  onCancel: {}, onStop: {})
                .padding(12),
            name: "dictation_recording")

        try writePNG(
            DictationProcessingBar(label: "распознаю…").padding(12),
            name: "dictation_recognizing")

        try writePNG(
            DictationProcessingBar().padding(12),
            name: "dictation_processing")

        // review = существующий инлайн-канон одобрения (поле с развёрнутым
        // текстом + бейдж + галочка)
        try writePNG(SendApprovalCanon(), name: "dictation_review")
    }
}

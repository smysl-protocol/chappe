//
//  SendConfirmationScreenshotTests.swift
//  RMTests
//
//  Канонизация потока одобрения отправки: одобрение инлайн в композере,
//  реализация первична, источник semantic_compression.md §4. Скриншот
//  кладётся в design/sophie/screens/send_confirmation.png; изменение вида
//  = обновление скриншота этим же тестом.
//

import Foundation
import SwiftUI
import Testing
@testable import Chappe

struct SendConfirmationScreenshotTests {

    @Test @MainActor
    func canonizeSendConfirmationScreenshot() throws {
        let canon = SendApprovalCanon()
            .frame(width: 390)
            .background(RMDesign.background)
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: canon)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        let image = try #require(renderer.uiImage, "канон не отрендерился")
        let png = try #require(image.pngData())

        let out = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("design/sophie/screens/send_confirmation.png")
        try FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try png.write(to: out)

        print("канон: \(out.path) — \(png.count) байт, "
            + "\(Int(image.size.width))×\(Int(image.size.height))@\(Int(image.scale))x")
        #expect(png.count > 10_000, "подозрительно маленький скриншот")
    }
}

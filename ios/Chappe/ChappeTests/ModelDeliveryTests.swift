//
//  ModelDeliveryTests.swift
//  RMTests
//
//  Ф1 (бриф 31.07): доставка модели. Конфиг загрузки — в файле, не в
//  коде; хеш считается потоково и совпадает с эталоном; установка
//  распознаётся по размеру файла.
//

import Foundation
import Testing
@testable import Chappe

struct ModelDeliveryTests {

    /// Конфиг загрузки лежит в бандле и внятный: URL https, хеш —
    /// 64 hex-символа, размер положительный, имя файла .gguf.
    @Test func downloadSpecShipsInBundleAndIsSane() throws {
        let spec = try #require(ModelDownloadSpec.load())
        #expect(spec.url.hasPrefix("https://"))
        #expect(spec.sha256.count == 64)
        let allHex = spec.sha256.allSatisfy { $0.isHexDigit }
        #expect(allHex)
        #expect(spec.sizeBytes > 1_000_000_000)
        #expect(spec.modelFile.hasSuffix(".gguf"))
        #expect(!spec.displayName.isEmpty)
        #expect(spec.sizeText.contains("ГБ"))
    }

    /// Потоковый SHA-256 совпадает с эталонным значением
    /// (echo -n "chappe" | shasum -a 256).
    @Test func streamingSHA256MatchesKnownDigest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-test-\(UUID().uuidString).bin")
        try Data("chappe".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = try ModelDownloader.sha256Hex(of: url)
        #expect(digest ==
            "160fa9ddd06b5ff36f0670a87c8390a3f2d1b10f3b0b296ddba40699734dc332")
    }

    /// «Установлена» = файл на месте И размер совпал: недокачанный
    /// файл моделью не считается.
    @Test func installedRequiresExactSize() throws {
        var spec = try #require(ModelDownloadSpec.load())
        spec.modelFile = "test-install-\(UUID().uuidString).gguf"
        let dir = try LLMModelConfig.modelsDirectory()
        let url = dir.appendingPathComponent(spec.modelFile)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!ModelDownloader.isInstalled(spec: spec), "файла ещё нет")
        try Data("обрезок".utf8).write(to: url)
        #expect(!ModelDownloader.isInstalled(spec: spec),
                "обрезанный файл — не установленная модель")
    }
}

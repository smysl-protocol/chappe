//
//  SemanticEncoderTests.swift
//  RMTests
//
//  Фаза C: санитайзер сходится с python (sanitize_pivot) на эталоне,
//  цепочка санитайзер→матчер→кодек→render работает без модели.
//

import Foundation
import Testing
@testable import Chappe

struct SemanticEncoderTests {

    /// Санитайзер — как python: эталон sanitizer_reference.json.
    @Test func sanitizerMatchesPython() throws {
        let codec = try #require(RMCodec.shared)
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("sanitizer_reference.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as! [String: Any]
        for c in json["cases"] as! [[String: String]] {
            let got = SemanticEncoder.sanitize(c["input"]!, codec: codec)
            #expect(got == c["output"]!,
                    "вход «\(c["input"]!)»:\n swift: «\(got)»\n python: «\(c["output"]!)»")
        }
    }

    /// Цепочка после модели (пивот уже есть): санитайзер → матчер →
    /// кодек → байты → декод → render. Модель не нужна.
    /// (SOS-коды из этой цепочки убраны — П1: protected недостижим из
    /// чата; SOS-вкладка идёт своим конвейером SOSExtraction.)
    @Test func chainAfterModelWorks() throws {
        let codec = try #require(RMCodec.shared)
        let matcher = try #require(PivotMatcher.shared)
        let pivot = SemanticEncoder.sanitize(
            "EN: be there soon in twenty minutes wait at the pier",
            codec: codec)
        let units = matcher.units(fromPivot: pivot, allowProtected: false)
        let blob = try codec.encode(units)
        #expect(blob.count < 30, "набор обязан быть крошечным: \(blob.count) Б")
        let decoded = try codec.decode(blob)
        #expect(decoded == units)
        let rendered = codec.render(decoded)
        #expect(rendered.contains("20"), "render: \(rendered)")
        #expect(rendered.lowercased().contains("пирс"), "render: \(rendered)")
    }
}

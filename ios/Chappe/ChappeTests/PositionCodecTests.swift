//
//  PositionCodecTests.swift
//  RMTests
//
//  Кодек позиции обязан быть байт-в-байт совместим с Python-эталоном:
//  tests/position_codec_vectors.json генерируется из sim/envelope.py
//  (Envelope v0 §5, fine coords). Здесь же — reject-кейсы: вход вне
//  диапазона это ошибка, а не зажим.
//

import Foundation
import Testing
@testable import Chappe

private func repoFile(_ relative: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // RMTests
        .deletingLastPathComponent()    // RM
        .deletingLastPathComponent()    // ios
        .deletingLastPathComponent()    // корень репозитория
    return try Data(contentsOf: root.appendingPathComponent(relative))
}

private struct CodecVectors: Decodable {
    struct Vector: Decodable {
        let name: String
        let lat: Double
        let lon: Double
        let bytes_hex: String
        let decoded_lat: Double
        let decoded_lon: Double
    }
    struct Reject: Decodable {
        let name: String
        let lat: Double
        let lon: Double
    }
    let vectors: [Vector]
    let reject: [Reject]
}

struct PositionCodecTests {

    private func load() throws -> CodecVectors {
        try JSONDecoder().decode(CodecVectors.self,
                                 from: repoFile("tests/position_codec_vectors.json"))
    }

    @Test func encodesByteForByteAsPython() throws {
        let all = try load()
        #expect(all.vectors.count >= 10)
        for v in all.vectors {
            let bytes = try PositionCodec.encode(lat: v.lat, lon: v.lon)
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            #expect(hex == v.bytes_hex, "\(v.name): \(hex) != \(v.bytes_hex)")
        }
    }

    @Test func decodesToPythonReference() throws {
        for v in try load().vectors {
            var bytes: [UInt8] = []
            var i = v.bytes_hex.startIndex
            while i < v.bytes_hex.endIndex {
                let j = v.bytes_hex.index(i, offsetBy: 2)
                bytes.append(UInt8(v.bytes_hex[i..<j], radix: 16)!)
                i = j
            }
            let (lat, lon) = try PositionCodec.decode(bytes)
            #expect(abs(lat - v.decoded_lat) < 1e-12, "\(v.name)")
            #expect(abs(lon - v.decoded_lon) < 1e-12, "\(v.name)")
        }
    }

    @Test func roundTripIsStable() throws {
        // Повторное кодирование декодированного даёт те же байты — каноничность.
        for v in try load().vectors {
            let bytes = try PositionCodec.encode(lat: v.lat, lon: v.lon)
            let (lat, lon) = try PositionCodec.decode(bytes)
            let again = try PositionCodec.encode(lat: lat, lon: lon)
            #expect(bytes == again, "\(v.name)")
        }
    }

    @Test func rejectsOutOfRange() throws {
        for r in try load().reject {
            #expect(throws: (any Error).self, "\(r.name): ожидалась ошибка") {
                _ = try PositionCodec.encode(lat: r.lat, lon: r.lon)
            }
        }
    }

    @Test func rejectsWrongLength() {
        #expect(throws: (any Error).self) {
            _ = try PositionCodec.decode([0, 1, 2])
        }
    }
}

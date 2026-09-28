import Foundation

// ============================================================================
// SOS-извлечение: схема, промпт и модель данных.
//
// Схема — та же, что в tools/bench_http.py (тест №6) и
// tests/sos_extraction_vectors.json: enum на каждом поле, потолок maxItems
// (правила №2, №3 CLAUDE.md). Промпт перечисляет допустимые значения ВСЕХ
// enum-полей (правило №8 — иначе грамматика захватывает ложный префикс).
//
// ПРАВИЛО №9: это ПОМОЩНИК ЗАПОЛНЕНИЯ ФОРМЫ, не классификатор. Вызывать
// только после явного действия пользователя (кнопка SOS); результат —
// черновик на подтверждение человеком. Прогонять произвольные тексты,
// чтобы «понять, не бедствие ли это», запрещено: схема принуждает
// заполнить needs (minItems=1) даже для мирного текста.
// ============================================================================

nonisolated enum SOSExtraction {

    /// JSON Schema — канонический источник (сервер строит по ней грамматику).
    static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "type":         {"type": "string", "enum": ["sos", "medical", "info"]},
        "severity":     {"type": "string", "enum": ["low", "medium", "high", "critical"]},
        "people_count": {"type": "integer", "minimum": 0, "maximum": 31},
        "injury":       {"type": "string", "enum": ["none", "bleeding", "fracture",
                                                    "burn", "head", "unconscious", "other"]},
        "needs": {
          "type": "array",
          "minItems": 1,
          "maxItems": 4,
          "items": {"type": "string",
                    "enum": ["bandages", "water", "food", "boat", "vehicle",
                             "doctor", "medicine", "evacuation", "fuel", "shelter"]}
        }
      },
      "required": ["type", "severity", "people_count", "injury", "needs"],
      "additionalProperties": false
    }
    """

    static let spec = StructuredSpec(jsonSchema: schemaJSON)

    /// Промпт извлечения. Правило №8 применено ко ВСЕМ enum-полям:
    /// 25.07.2026 на телефоне выпал «shelter» вместо «bandages» — значения
    /// needs не были перечислены. С полным перечислением + temp 0 — 5/5 стабильно.
    static func prompt(for message: String) -> String {
        "Ты обрабатываешь сигнал бедствия. Извлеки факты из сообщения и заполни поля.\n"
        + "Правила: type — одно из: sos, medical, info (sos = нужна срочная помощь). "
        + "severity — одно из: low, medium, high, critical (critical = угроза жизни). "
        + "injury — главная травма, строго одно из значений: none, bleeding, "
        + "fracture, burn, head, unconscious, other (head = травма головы). "
        + "needs — только то, что прямо просят, каждый пункт строго из списка: "
        + "bandages, water, food, boat, vehicle, doctor, medicine, evacuation, "
        + "fuel, shelter.\n\n"
        + "Сообщение: " + message + "\n\nОтвет:"
    }
}

// MARK: - Результат извлечения

/// Swift-enum в полях сам отсекает значения вне допустимого набора
/// при декодировании — вторая линия обороны после грамматики.
nonisolated struct SOSReport: Decodable, Sendable {

    enum Kind: String, Decodable, Sendable {
        case sos, medical, info
    }
    enum Severity: String, Decodable, Sendable {
        case low, medium, high, critical
    }
    enum Injury: String, Decodable, Sendable {
        case none, bleeding, fracture, burn, head, unconscious, other
    }
    enum Need: String, Decodable, Sendable, CaseIterable {
        case bandages, water, food, boat, vehicle,
             doctor, medicine, evacuation, fuel, shelter
    }

    let type: Kind
    let severity: Severity
    let peopleCount: Int
    let injury: Injury
    let needs: [Need]

    enum CodingKeys: String, CodingKey {
        case type, severity, injury, needs
        case peopleCount = "people_count"
    }

    /// Семантическая проверка кодом — потолки и диапазоны считает КОД,
    /// не модель (правила №3, №4). Тексты ошибок понятные: они уходят
    /// модели в repair-промпт.
    static func validate(_ r: SOSReport) throws {
        guard (0...31).contains(r.peopleCount) else {
            throw ValidationError("people_count вне диапазона 0–31: \(r.peopleCount)")
        }
        guard (1...4).contains(r.needs.count) else {
            throw ValidationError("needs должен содержать от 1 до 4 пунктов, "
                                + "сейчас \(r.needs.count)")
        }
    }

    struct ValidationError: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// MARK: - Человекочитаемое представление (для экрана)

extension SOSReport {
    var typeLabel: String {
        switch type {
        case .sos: "SOS"
        case .medical: "медицина"
        case .info: "информация"
        }
    }
    var severityLabel: String {
        switch severity {
        case .low: "низкая"
        case .medium: "средняя"
        case .high: "высокая"
        case .critical: "критично"
        }
    }
    var injuryLabel: String {
        switch injury {
        case .none: "нет"
        case .bleeding: "кровотечение"
        case .fracture: "перелом"
        case .burn: "ожог"
        case .head: "травма головы"
        case .unconscious: "без сознания"
        case .other: "другая"
        }
    }
    var needsLabel: String {
        needs.map { need in
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
        }.joined(separator: ", ")
    }
}

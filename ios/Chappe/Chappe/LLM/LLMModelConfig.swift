import Foundation

// ============================================================================
// Конфигурация модели: КАКОЙ файл, КАКИМ движком, с какими параметрами.
//
// Модель не прибита к коду: приложение читает llm_config.json и работает
// с любой GGUF-моделью подходящей архитектуры. Смена модели = смена файла
// и конфига, без перекомпиляции.
// ============================================================================

/// Параметры сэмплинга. Значения по умолчанию — те же, что в бенчмарках
/// tools/bench_http.py, чтобы поведение на телефоне было сравнимо с Маком.
nonisolated struct SamplingParams: Codable, Sendable {
    var temperature: Double = 0.5
    var topP: Double = 0.85
    var topK: Int = 20
    var minP: Double = 0

    /// Пресет для служебных извлечений (SOS→JSON): ЖАДНОЕ декодирование
    /// (temp 0, top-k 1) — извлечение фактов детерминировано, без лотереи
    /// сэмплинга. Основание: 25.07.2026 при temp 0.2 на телефоне выпал
    /// редкий неверный сэмпл («shelter» вместо «bandages»).
    static let extraction = SamplingParams(temperature: 0, topP: 1,
                                           topK: 1, minP: 0)
}

nonisolated struct LLMModelConfig: Codable, Sendable {
    /// Каким движком открывать модель.
    var providerKind: LLMProviderKind

    /// Путь к весам ОТНОСИТЕЛЬНО каталога моделей приложения
    /// (Application Support/Models). Для GGUF — файл; для MLX — папка.
    var modelFile: String

    /// Человекочитаемое имя для настроек/логов.
    var displayName: String

    var contextLength: Int
    var sampling: SamplingParams

    /// Подсказка для UI: ожидается ли, что движок даст жёсткую схему.
    /// Истина в рантайме — provider.capabilities; это поле нужно, чтобы
    /// настройки могли предупредить о моделях/движках без схемы ДО загрузки.
    var expectsStructuredOutput: Bool

    /// Адрес llama-server для providerKind == .remote,
    /// например "http://192.168.1.113:8080". Для локальных движков — nil.
    /// ВАЖНО: указывать именно IP-адрес, не имя хоста (числовые IP не
    /// попадают под App Transport Security, и HTTP работает без исключений).
    var host: String?

    // MARK: Загрузка конфига

    /// Подмена каталога моделей для тестов (ревизия параллелизма 06.08):
    /// LocalProfileSwitchTests писали НАСТОЯЩИЙ llm_config.json, который
    /// параллельно читали соседние сюиты через ModelScheduler — отсюда
    /// флейк «активация не открыла гейт». Тест уводит себя во временный
    /// каталог, продукт этого поля не трогает (nil).
    nonisolated(unsafe) static var directoryOverride: URL?

    /// Каталог моделей приложения (создаётся при первом обращении).
    static func modelsDirectory() throws -> URL {
        if let override = directoryOverride {
            try FileManager.default.createDirectory(
                at: override, withIntermediateDirectories: true)
            return override
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    /// Абсолютный путь к весам.
    func resolvedModelURL() throws -> URL {
        try Self.modelsDirectory().appendingPathComponent(modelFile)
    }

    /// Читает llm_config.json из Application Support; если его нет —
    /// возвращает конфиг по умолчанию (текущее решение проекта).
    static func loadActive() -> LLMModelConfig {
        if let dir = try? modelsDirectory() {
            let url = dir.appendingPathComponent("llm_config.json")
            if let data = try? Data(contentsOf: url),
               let cfg = try? JSONDecoder().decode(LLMModelConfig.self, from: data) {
                return cfg
            }
        }
        return .defaultConfig
    }

    /// Активировать ЛОКАЛЬНЫЙ профиль с установленной моделью (баг
    /// 02.08: «в настройках переключена» — экран Помощника показывал
    /// установку файла, а активный профиль оставался сетевым; теперь
    /// и гейт Софи, и Помощник переключают профиль этой функцией).
    /// nil — модели на диске нет, профиль не тронут.
    @discardableResult
    static func activateLocalIfInstalled() -> LLMModelConfig? {
        guard let first = ModelStore.installedModels().first else {
            return nil
        }
        var config = localQwen
        config.modelFile = first.lastPathComponent
        config.displayName = "Локально: \(first.lastPathComponent)"
        try? config.saveAsActive()
        return config
    }

    /// Сохранить как активный конфиг.
    func saveAsActive() throws {
        let url = try Self.modelsDirectory().appendingPathComponent("llm_config.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Дефолт — ЛОКАЛЬНАЯ модель на устройстве (переключено 26.07.2026
    /// по итогам фазы 2: пивоты 12/12 с эталоном, скорость выше прогноза —
    /// docs/reports/ondevice_phase2.md). Профиль remoteDev остаётся
    /// доступным через dev-меню для сравнительных прогонов.
    static let defaultConfig = localQwen

    /// Гейт приватности (sophie_presence §3): фичи с обещанием «ноль байт
    /// с устройства» (шёпот Софи) разрешены только на локальном провайдере.
    var allowsPrivateWhisper: Bool { providerKind == .local }

    /// Профиль разработки: модель крутится на Маке, телефон ходит по Wi-Fi.
    static let remoteDev = LLMModelConfig(
        providerKind: .remote,
        modelFile: "Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf",   // информативно: что загружено на сервере
        displayName: "Qwen3-4B via llama-server (Mac)",
        contextLength: 4096,
        sampling: SamplingParams(),
        expectsStructuredOutput: true,
        host: "http://172.20.10.2:8080"   // IP Мака в сети точки доступа телефона
    )

    /// Целевой профиль: модель на устройстве через стоковый llama.cpp.
    /// Решение проекта от 25.07.2026 (docs/model_comparison.md).
    static let localQwen = LLMModelConfig(
        providerKind: .local,
        modelFile: "Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        displayName: "Qwen3-4B-Instruct-2507 (Q4_K_M)",
        contextLength: 4096,
        sampling: SamplingParams(),
        expectsStructuredOutput: true,
        host: nil
    )
}

// MARK: - Фабрика провайдеров

/// Единственное место, где тип движка превращается в конкретный класс.
/// Добавление третьего движка: case в LLMProviderKind + ветка здесь.
nonisolated enum LLMProviderFactory {
    static func make(_ kind: LLMProviderKind) throws -> any LLMProvider {
        switch kind {
        case .local:
            return LlamaCppProvider()
        case .mlx:
            // Задел под MLX-путь (быстрее, но guided generation моложе) —
            // см. docs/llm_architecture.md, раздел «MLXProvider».
            throw LLMError.providerUnavailable(
                reason: "MLXProvider ещё не реализован")
        case .remote:
            return RemoteProvider()
        }
    }
}

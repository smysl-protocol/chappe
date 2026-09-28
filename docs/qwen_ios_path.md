# Qwen3-4B-Instruct-2507 на iOS — пути встраивания и лицензия

Дата исследования: 24.07.2026. Только research — код не писался, ничего не собиралось.
Целевое устройство: iPhone 17 Pro Max (12 ГБ RAM), приложение SwiftUI в `ios/`.

## Краткий ответ

Запустить Qwen3-4B на iOS **можно уже сегодня**, двумя зрелыми путями.
Для нашего критичного требования — **жёсткая JSON-схема для SOS** — надёжнее
всего llama.cpp-путь: GBNF-грамматика работает на уровне ядра сэмплера прямо
в официальной мобильной сборке. Лицензия — чистый Apache 2.0, коммерческое
встраивание без ограничений.

---

## Путь 1: llama.cpp (рекомендуемый для SOS-пути)

**Пакет [mattt/llama.swift](https://github.com/mattt/llama.swift)** — жив и активен
(~1660 коммитов). Это не форк: пакет подтягивает **официальный precompiled
llama.xcframework из релизов ggml-org/llama.cpp** и реэкспортирует C API.
Версия привязана к билдам llama.cpp (сейчас README рекомендует `2.10107.0` =
билд b10107, 2026 год).

- **Откроет ли Q4_K_M Qwen3-4B?** Да: Q4_K_M — стандартный апстримный квант,
  Qwen3 поддерживается llama.cpp с апреля 2025, внутри пакета свежий билд.
  Важно: это **обычный GGUF, форк PrismML не нужен** (форк нужен только для Q1_0 Bonsai).
- **Требования:** Swift 6.0+, **iOS 16.0+**, подключение через SPM, Metal на
  iPhone — да (Apple Silicon в апстриме — first-class citizen).
- **Grammar/схема на устройстве (критично):** `llama_sampler_init_grammar` (GBNF) —
  часть публичного C API ядра, входит в мобильный xcframework. Грамматика
  зануляет логиты недопустимых токенов — жёсткая гарантия формата, не постобработка.
  Нюанс: конвертер json_schema→GBNF живёт в `common/` и в xcframework не входит.
  **Для нас это не проблема: SOS-схема статическая — GBNF генерируется один раз
  офлайн** (скриптом `examples/json_schema_to_grammar.py` из llama.cpp) и
  зашивается в приложение строкой.
- Альтернативные обёртки: ggml-org/llama.cpp сам как SPM-пакет (binaryTarget),
  StanfordBDHG/llama.cpp (SpeziLLM), SwiftLlama, LocalLLMClient.

## Путь 2: MLX (быстрее, но guided generation моложе)

- **Модель в MLX-формате есть:** [mlx-community/Qwen3-4B-Instruct-2507-4bit](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit) —
  **2.26 ГБ**; есть и улучшенный квант `4bit-DWQ-2510`, и 8bit.
- **Библиотека:** LLM-часть переехала из mlx-swift-examples в официальный
  [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (v3.31.3, активен). Qwen — референсные модели MLX.
- **Структурированная генерация:** состояние на 2026 изменилось — в mlx-swift-lm
  появился модуль **MLXGuidedGeneration** (grammar по JSON Schema/EBNF, интеграция
  с `@Generable` требует iOS 26+). Есть и сторонний
  [mlx-swift-structured](https://github.com/petrukha-ivan/mlx-swift-structured) (XGrammar,
  jump-forwarding), но автор сам пишет «ранний этап разработки».
- **Требования:** только реальное устройство (симулятор Metal-путь MLX не
  поддерживает); базовый mlx-swift — iOS 16+, новые фичи завязаны на SDK 26.
- **Скорость:** MLX на Apple Silicon стабильно быстрее llama.cpp на 40–60%.

## Компромисс: AnyLanguageModel

[huggingface/AnyLanguageModel](https://github.com/mattt/AnyLanguageModel) (v0.8.0, iOS 17+, Apache 2.0) —
drop-in замена API Apple FoundationModels (`@Generable`/`@Guide`), под которой
переключаются бэкенды llama.cpp / MLX / Core ML. Guided generation заявлен для
обоих бэкендов. Перед ставкой на него нужно один раз проверить в исходниках,
что ограничение действительно на уровне маскирования логитов (по архитектуре —
да, но агент это не подтвердил чтением кода).

## Память и скорость на iPhone 17 Pro Max

- Файл: GGUF Q4_K_M — 2.5 ГБ; MLX 4bit — 2.26 ГБ.
- Рабочий сет с контекстом 4K: **~3.2–4 ГБ** (KV-кэш Qwen3-4B ≈ 144 КБ/токен ≈ 0.6 ГБ на 4K).
- На 12 ГБ RAM влезает с запасом; entitlement **Increased Memory Limit** включить обязательно.
- Прямых замеров 4B на iPhone 17 нет (неуверенность). Экстраполяция с бенчмарка
  Qwen 2B на iPhone 17 Pro (MLX 61 tok/s, llama.cpp 39 tok/s):
  **~25–35 tok/s MLX, ~18–25 tok/s llama.cpp** для 4B. Владелец зафиксировал
  ~11.5 tok/s на телефоне в стороннем приложении — родная интеграция должна быть быстрее.

## Прочие варианты (отклонены)

- **Apple FoundationModels:** свои веса грузить нельзя (только модель Apple ~3B
  или облако). Core AI с WWDC 2026 — пока developer preview. Но сам API
  `@Generable` стал стандартом интерфейса — его реплицируют AnyLanguageModel и mlx-swift-lm.
- **MediaPipe/LiteRT-LM** — заточен под Gemma; **ONNX Runtime** — ничего заметного
  для Qwen3 на iOS. Оба не рекомендуются.

## Вывод для нашего приложения

1. **Для SOS-пути (жёсткая схема) — llama.cpp через mattt/llama.swift**: самая
   зрелая реализация constrained decoding (GBNF годами в продакшене), iOS 16+,
   статическую SOS-грамматику генерируем офлайн и зашиваем строкой.
2. MLX — кандидат на чат-часть (быстрее в ~1.5 раза), guided generation уже есть,
   но модуль молодой.
3. AnyLanguageModel стоит рассмотреть как единый API над обоими бэкендами —
   после проверки его механизма ограничения.

Ключевое отличие от Bonsai Q1_0: **Qwen3-4B Q4_K_M открывается стоковым
llama.cpp** — не нужен форк PrismML, не нужна кастомная сборка под iPhone.
Это заметно упрощает и путь на устройство, и обновление рантайма.

---

## Лицензия (задача 4)

**Apache 2.0 — подтверждено, коммерческое встраивание без ограничений.**

- Страница [Qwen/Qwen3-4B-Instruct-2507](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507): `license: apache-2.0`;
  файл [LICENSE](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507/blob/main/LICENSE) — стандартный Apache 2.0, «Copyright 2024 Alibaba Cloud». Файла NOTICE нет.
- Никаких обязательств открывать код приложения, никаких порогов по числу
  пользователей (в отличие от Llama), никаких ограничений на выходы модели.
- Отдельные «условия Qwen» (Tongyi Qianwen LICENSE) касались только старых
  Qwen 1/1.5/2 — вся серия Qwen3, включая эту модель, чистый Apache 2.0,
  без gated-доступа.
- **Что сделать в приложении:** экран Licenses/Acknowledgements с текстом
  Apache 2.0 и строкой «Qwen3-4B-Instruct-2507, Copyright 2024 Alibaba Cloud»;
  пометить, что веса модифицированы («quantized to GGUF»), по разделу 4(b).
- GGUF-кванты: unsloth явно apache-2.0; bartowski — производная работа,
  наследует Apache 2.0 базовой модели. Юридически чисто.

**Вывод: лицензионных препятствий для замены Bonsai на Qwen3-4B нет.**

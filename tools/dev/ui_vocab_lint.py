#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Замок словаря интерфейса (docs/ui_vocabulary.md).

Правило проекта: «узел», «LoRa», «mesh», «LLM», «релей», «пивот» и
прочие внутренние термины ЗАПРЕЩЕНЫ в пользовательских строках.
До этого скрипта словарь держался дисциплиной; по правилу №9
(«правила в промпте не работают») такие вещи держатся кодом.

Что проверяется: строковые литералы в Swift-исходниках приложения
(ios/Chappe/Chappe).

Что НЕ проверяется (это не пользовательские строки):
  - комментарии кода;
  - код внутри #if DEBUG — его нет в Release-сборке;
  - dev-экраны из EXCLUDE_FILES (вход в них закрыт #if DEBUG);
  - инженерные журналы: литерал, передаваемый в TransportDiary.note,
    DictationDebugLog.* или print, — журнал, а не интерфейс;
  - промпты модели (переменные *rompt* = "..."): их читает модель;
  - ключи UserDefaults, идентификаторы служб, схемы URL,
    launch-аргументы: латинские термины ловятся только в строках,
    похожих на человеческий текст (кириллица или пробел внутри),
    поэтому "mesh_config", "lora", "meshtastic://" не срабатывают;
  - паки Софи (Resources/sophie_kb) — это контент со своей редакцией,
    и они под замком corpus_guard; их словарь — отдельное решение
    владельца (см. отчёт 06.08).

Запуск:  python3 tools/dev/ui_vocab_lint.py
Выход 0 — чисто; выход 1 — найдены запрещённые слова (список на stdout).

Слом для проверки замка: вернуть «узел» в любую видимую строку —
скрипт обязан покраснеть (проверено при создании, отчёт 06.08).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP_DIR = os.path.join(ROOT, "ios", "Chappe", "Chappe")

# --- Запрещённые термины -------------------------------------------------
# Каждый — (имя, regex, только_в_человеческом_тексте).
# «Человеческий текст» = в литерале есть кириллица или пробел.
# Замены — в docs/ui_vocabulary.md (основная таблица).

def rx(p):
    return re.compile(p, re.IGNORECASE)

RULES = [
    # Русские термины: ловим в любом литерале.
    # «узел» и вся морфология, включая «радиоузел», «узлов».
    ("узел",      rx(r"узел|узл[а-яё]"), False),
    ("лора",      rx(r"\bлор[аыеу]\b|лора-"), False),
    ("меш",       rx(r"\bмеш\b|\bмеш-"), False),  # «мешает», «мешок» не трогаем
    ("релей",     rx(r"\bреле[йяюе]м?\b"), False),
    ("пивот",     rx(r"пивот"), False),
    ("гейт",      rx(r"\bгейт[а-яё]*\b"), False),
    ("рэтчет",    rx(r"р[эа]тчет"), False),
    ("блоб",      rx(r"\bблоб[а-яё]*\b"), False),
    ("нода",      rx(r"\bнод[аыеу]\b|\bнодам?и?\b"), False),
    # «конверт» → «пакет» (по словарю)
    ("конверт",   rx(r"\bконверт[а-яё]*\b"), False),
    # «кадр» → «сообщение» (решение владельца 06.08)
    ("кадр",      rx(r"\bкадр[а-яё]*\b"), False),
    # «пак» → «справочник» («пакет» не матчится: после «пак» нужна граница)
    ("пак",       rx(r"\bпак(ах|ами|ам|ов|и|а|у|е)?\b"), False),
    # Латинские термины: только в строках, похожих на человеческий текст.
    # «LoRa (радио)» разрешено с 10.08: решение владельца после
    # стендового прогона — техноним в скобках помогает опознать
    # коробочку («Радиоустройства (LoRa)», галочка «LoRa (радио)»);
    # запрет остаётся на LoRa БЕЗ пояснения-скобки рядом
    ("LoRa",      rx(r"\blora\b(?!\)|\s*\(радио\))"), True),
    ("mesh",      rx(r"\bmesh\b"), True),   # Meshtastic не матчится (нет границы)
    ("LLM",       rx(r"\bllm\b"), True),
    ("relay",     rx(r"\brelay\b"), True),
    ("pivot",     rx(r"\bpivot\b"), True),
    # Старое имя проекта: в интерфейсе только AppIdentity.appName
    # (полевой прогон 08.08: «Настройках → RM» вёл к несуществующему
    # разделу). Соли провода ("RM-Smysl-v0") не матчатся: латинское
    # правило смотрит только строки с кириллицей или пробелом.
    # «rm://» — схема карточки, не имя: не матчится (за словом ://)
    ("RM",        rx(r"\bRM\b(?!://)"), True),
]

# --- Исключения ----------------------------------------------------------
# Файлы, целиком не попадающие в Release-путь пользователя.
EXCLUDE_FILES = {
    # dev-экраны: вход только из секции «Служебные экраны», закрытой
    # #if DEBUG (SettingsRootView, подача 06.08) — пользователь их не видит
    "DevSettingsView.swift",
    "SOSExtractView.swift",
}

# Точечные исключения: (суффикс пути, фрагмент литерала, {термины}, почему).
# Исключение гасит ТОЛЬКО перечисленные термины: новое запрещённое слово
# в том же литерале всё равно красит скрипт (проверено сломом 06.08).
# Слова, разрешённые словарём (SOS, QR, Bluetooth, Wi-Fi), в RULES не
# входят; Meshtastic (имя чужого приложения) правилами не матчится —
# им исключения не нужны.
ALLOW = [
    # Детектор вопросов о состоянии сети: стемы РАСПОЗНАЮТ слова
    # пользователя («узел», «лора»), но сами никогда не показываются
    ("Sophie/NetworkStatus.swift", "узл", {"узел"},
     "стем распознавания, не вывод"),
    ("Sophie/NetworkStatus.swift", "узел", {"узел"},
     "стем распознавания, не вывод"),
    ("Sophie/NetworkStatus.swift", "узла", {"узел"},
     "стем распознавания, не вывод"),
    ("Sophie/NetworkStatus.swift", "радиоузл", {"узел"},
     "стем распознавания, не вывод"),
    ("Sophie/NetworkStatus.swift", "лора", {"лора"},
     "стем распознавания, не вывод"),
    ("Sophie/NetworkStatus.swift", "мештастик", set(),
     "стем распознавания (термином не матчится — на будущее)"),
    # Корпус ночного прогона: имитация СООБЩЕНИЙ пользователя (контент,
    # не интерфейс); попадает только в бенч-чат при ручном прогоне
    ("ChappeApp.swift", "заставить конверт разбиться", {"конверт"},
     "текст-имитация сообщения в бенч-корпусе"),
    # Пульс наблюдателя релея: показывается только на Dev-экране
    # (DevSettingsView:643, секция под #if DEBUG)
    ("Transport/RelayTransport.swift", "кадров", {"кадр"},
     "пульс наблюдателя, виден только в Dev"),
    # --- БЛОКЕРЫ: нарушения в ЧУЖИХ модулях (таблица владения CLAUDE.md).
    # Строки видны пользователю (бейдж отката HumanChatView:1325 и экран
    # областей карты), но правка — за владельцами модулей. Зафиксировано
    # в отчёте 06.08; после починки владельцем исключение УДАЛИТЬ.
    ("Semantic/SemanticEncoder.swift", "гейт отрицаний: потеряна отмена",
     {"гейт"}, "чужой модуль (семантическая сессия) — блокер"),
    ("Semantic/SemanticEncoder.swift", "гейт отрицаний: отрицание пропало",
     {"гейт"}, "чужой модуль (семантическая сессия) — блокер"),
    ("Semantic/SemanticEncoder.swift", "гейт отрицаний: пропало отрицаемое",
     {"гейт"}, "чужой модуль (семантическая сессия) — блокер"),
    ("Semantic/SemanticEncoder.swift", "гейт сущностей: пивот добавил",
     {"гейт", "пивот"}, "чужой модуль (семантическая сессия) — блокер"),
    ("Semantic/SemanticEncoder.swift", "пивот слишком короткий",
     {"пивот"}, "чужой модуль (семантическая сессия) — блокер"),
    ("Semantic/SemanticEncoder.swift", "пивот пустой",
     {"пивот"}, "чужой модуль (семантическая сессия) — блокер"),
    ("Semantic/SemanticEncoder.swift", "пивот потерял числа",
     {"пивот"}, "чужой модуль (семантическая сессия) — блокер"),
    ("Map/RegionManagerScreen.swift", "повторяет пак",
     {"пак"}, "чужой модуль (сессия карты) — блокер"),
    ("Map/RegionManagerScreen.swift", "один пак. Приблизьте",
     {"пак"}, "чужой модуль (сессия карты) — блокер"),
]


def allowed(relpath, literal, term):
    for suffix, frag, terms, _why in ALLOW:
        if term in terms and relpath.endswith(suffix) and frag in literal:
            return True
    return False


CYRILLIC = re.compile(r"[а-яё]", re.IGNORECASE)

# Литерал уходит в журнал/промпт, если непосредственно перед ним —
# вызов журнала или присваивание промпта…
SINK_CONTEXT = re.compile(
    r"(?:TransportDiary\s*\.\s*note|DictationDebugLog\s*\.\s*\w+"
    r"|(?<![\w.])print)\s*\(\s*$"
    r"|[Pp]rompt\w*\s*=\s*$")
# …или продолжение той же строковой конкатенации («+» в конце контекста).
CONTINUATION = re.compile(r"\+\s*$")


def human_text(s):
    """Похоже ли на текст для человека (а не ключ/идентификатор)."""
    return bool(CYRILLIC.search(s)) or " " in s


# --- Разбор Swift: строковые литералы вне комментариев -------------------
# Понимает: // и /* */ (вложенные), "...", """...""", экранирование \",
# интерполяцию \( ... ) с вложенными строками, #if DEBUG ... #endif.

def swift_literals(src):
    """Генератор (literal, line_no, context_before) по литералам файла."""
    i, n = 0, len(src)
    line = 1
    debug_depth = 0      # вложенность #if внутри региона DEBUG
    in_debug = False

    def at(k):
        return src[k] if k < n else ""

    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        # Директивы условной компиляции
        if c == "#" and src.startswith(("#if", "#endif"), i):
            j = src.find("\n", i)
            directive = src[i:j if j != -1 else n]
            if directive.startswith("#if"):
                if in_debug:
                    debug_depth += 1
                elif re.search(r"#if\s+DEBUG\b", directive):
                    in_debug = True
                    debug_depth = 1
            elif directive.startswith("#endif") and in_debug:
                debug_depth -= 1
                if debug_depth == 0:
                    in_debug = False
            i = j if j != -1 else n
            continue
        # Комментарии
        if c == "/" and at(i + 1) == "/":
            j = src.find("\n", i)
            i = j if j != -1 else n
            continue
        if c == "/" and at(i + 1) == "*":
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i):
                    depth += 1
                    i += 2
                elif src.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    if src[i] == "\n":
                        line += 1
                    i += 1
            continue
        # Строковые литералы
        if c == '"':
            context = src[max(0, i - 120):i]
            triple = src.startswith('"""', i)
            start_line = line
            i += 3 if triple else 1
            buf = []
            while i < n:
                if src[i] == "\n":
                    line += 1
                    if not triple:
                        break  # незакрытая строка — не наше дело
                    buf.append("\n")
                    i += 1
                    continue
                if src[i] == "\\":
                    # интерполяция \( ... ): внутри бывают свои строки
                    if at(i + 1) == "(":
                        depth, j = 1, i + 2
                        inner_start = j
                        while j < n and depth:
                            if src[j] == '"':
                                j += 1
                                while j < n and src[j] != '"':
                                    if src[j] == "\\":
                                        j += 1
                                    if src[j] == "\n":
                                        line += 1
                                    j += 1
                                j += 1
                                continue
                            if src[j] == "(":
                                depth += 1
                            elif src[j] == ")":
                                depth -= 1
                            elif src[j] == "\n":
                                line += 1
                            j += 1
                        inner = src[inner_start:j - 1]
                        if not in_debug:
                            for lit, _ln, ctx in swift_literals(inner):
                                yield lit, start_line, ctx
                        buf.append(" ")  # интерполяция = разрыв слова
                        i = j
                        continue
                    buf.append(at(i + 1))
                    i += 2
                    continue
                if triple and src.startswith('"""', i):
                    i += 3
                    break
                if not triple and src[i] == '"':
                    i += 1
                    break
                buf.append(src[i])
                i += 1
            if not in_debug:
                yield "".join(buf), start_line, context
            continue
        i += 1


def scan_swift(path, relpath, out):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    prev_sink = False
    for literal, line_no, context in swift_literals(src):
        # контекст решает: журнал/промпт или продолжение такого литерала
        ctx = context.replace("\n", " ")
        if SINK_CONTEXT.search(ctx):
            prev_sink = True
        elif CONTINUATION.search(ctx) and prev_sink:
            pass  # хвост конкатенации журнальной/промптовой строки
        else:
            prev_sink = False
        if prev_sink:
            continue
        for name, pattern, only_human in RULES:
            if only_human and not human_text(literal):
                continue
            if pattern.search(literal) and not allowed(relpath, literal, name):
                short = literal if len(literal) <= 70 else literal[:67] + "..."
                out.append((relpath, line_no, name, short))


def main():
    out = []
    for base, _dirs, files in os.walk(APP_DIR):
        for name in sorted(files):
            if not name.endswith(".swift") or name in EXCLUDE_FILES:
                continue
            path = os.path.join(base, name)
            scan_swift(path, os.path.relpath(path, ROOT), out)

    if out:
        print("СЛОВАРЬ НАРУШЕН — запрещённые слова в пользовательских строках:")
        for rel, line_no, term, literal in out:
            print(f"  {rel}:{line_no}  [{term}]  «{literal}»")
        print(f"\nВсего: {len(out)}. Замены — docs/ui_vocabulary.md.")
        sys.exit(1)
    print("Словарь чист: запрещённых слов в пользовательских строках нет.")
    sys.exit(0)


if __name__ == "__main__":
    main()

# -*- coding: utf-8 -*-
"""PreToolUse-хук: защита корпусов и фикстур от записи и удаления.

Повод (WP2, 02.08.2026): tatoeba-корпус утрачен скретчем чужой сессии,
до этого терялась спека паков. Корпуса — единственная база сравнения
замеров, потеря необратима.

Протокол хука Claude Code: JSON вызова на stdin; выход 2 = запрет
(stderr показывается модели), выход 0 = пропустить.

Осознанное изменение корпуса: запуск команды с RM_CORPUS_UNLOCK=1
(только по явной просьбе владельца).
"""
import json
import os
import re
import sys

# Защищаемые области (относительно корня репозитория)
PROTECTED = [
    "tests/",                      # тест-вектора и фикстуры
    "packs/",                      # паки знаний
    "tools/dictation_farm/out/",   # полевой корпус (wav + manifest)
    "tools/dictation_farm/cv_ru/", # голосовой корпус
    "tools/semdict/concepticon.tsv",
    "tools/semdict/en_50k.txt",
]

# Для Bash: пишущие/удаляющие команды (без учёта регистра НЕ ищем —
# «RM_CORPUS_UNLOCK» не должен матчить \brm\b)
DESTRUCTIVE = re.compile(
    r"\b(rm|mv|cp|shred|truncate|tee|touch|dd|ln|rsync)\b|\bsed\s+-i")
# Редиректы: блокируются только когда ЦЕЛЬ — защищённый путь
# (2>/dev/null и запись в скретч не трогаем)
REDIRECT = re.compile(r">{1,2}\s*([^\s;|&)]+)")


def repo_root():
    d = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    return os.path.abspath(d)


def hit(path):
    """Путь попадает в защищённую область?"""
    ap = os.path.abspath(os.path.join(repo_root(), path)) \
        if not os.path.isabs(path) else os.path.abspath(path)
    root = repo_root()
    for p in PROTECTED:
        target = os.path.join(root, p)
        if ap == target.rstrip("/") or ap.startswith(target):
            return p
    return None


def main():
    if os.environ.get("RM_CORPUS_UNLOCK") == "1":
        sys.exit(0)
    try:
        call = json.load(sys.stdin)
    except Exception:
        sys.exit(0)                      # нечитаемый вызов не блокируем
    tool = call.get("tool_name", "")
    inp = call.get("tool_input", {}) or {}

    if tool in ("Write", "Edit", "NotebookEdit"):
        path = inp.get("file_path") or inp.get("notebook_path") or ""
        p = hit(path)
        if p:
            sys.stderr.write(
                f"ЗАПРЕТ: «{path}» — защищённая область корпусов/фикстур "
                f"({p}). Изменение — только по явной просьбе владельца "
                f"(запуск с RM_CORPUS_UNLOCK=1).\n")
            sys.exit(2)

    elif tool == "Bash":
        cmd = inp.get("command", "")
        # осознанная разлочка видна прямо в команде — пропускаем
        if "RM_CORPUS_UNLOCK=1" in cmd:
            sys.exit(0)
        mentions = [p for p in PROTECTED if p.rstrip("/") in cmd]
        redirect_hit = any(hit(t) for t in REDIRECT.findall(cmd))
        if redirect_hit or (mentions and DESTRUCTIVE.search(cmd)):
            sys.stderr.write(
                "ЗАПРЕТ: команда пишет/удаляет в защищённой области "
                f"корпусов ({', '.join(mentions)}). Чтение разрешено; "
                "изменение — только по явной просьбе владельца "
                "(RM_CORPUS_UNLOCK=1).\n")
            sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()

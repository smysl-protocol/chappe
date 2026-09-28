# -*- coding: utf-8 -*-
"""ЗАМОК: пополнение словаря не меняет ни одного существующего кода.

Именно этого теста не хватало, чтобы дефект не дожил до 03.08.2026:
коды назначались по убыванию частоты, поэтому вставка новых слов
сдвигала все последующие — при первом же пополнении 890 смыслов
поменялись местами, хотя шапка build_dict.py обещает «code (навсегда)».
Старые сообщения после такого становятся нечитаемыми.

Тест собирает словарь дважды в ВРЕМЕННОМ каталоге: как есть и с одной
добавленной записью — и требует, чтобы у всех прежних кодов остались
прежние смыслы. Длины в битах меняться ВПРАВЕ (пересборка Хаффмана
неизбежна), это ловится отпечатком таблицы.

Запуск: python3 tools/semdict/test_append_only.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
NEEDED = ["build_dict.py", "curated_data.py", "concepticon.tsv",
          "en_50k.txt", "rm_dict_core_v0.json"]


def build_in(workdir, extra_word=None, version=None):
    """Собрать словарь в копии каталога; вернуть entries."""
    for name in NEEDED:
        shutil.copy(os.path.join(HERE, name), workdir)
    if extra_word:
        path = os.path.join(workdir, "curated_data.py")
        with open(path, "a", encoding="utf-8") as f:
            f.write(f'\nEXPANSION_SINGLES += [{extra_word!r}]\n')
    if version:
        path = os.path.join(workdir, "build_dict.py")
        src = open(path, encoding="utf-8").read()
        src = src.replace('"version": "1.3.0",', f'"version": "{version}",')
        open(path, "w", encoding="utf-8").write(src)
    env = dict(os.environ)
    if version:
        env["RM_DICT_REBUILD"] = version
    result = subprocess.run([sys.executable, "build_dict.py"], cwd=workdir,
                            capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise SystemExit("сборка не удалась:\n" + result.stdout + result.stderr)
    return json.load(open(os.path.join(workdir, "rm_dict_core_v0.json"),
                          encoding="utf-8"))["entries"]


def main():
    base = json.load(open(os.path.join(HERE, "rm_dict_core_v0.json"),
                          encoding="utf-8"))["entries"]
    before = {e["code"]: e["en"] for e in base}

    with tempfile.TemporaryDirectory() as workdir:
        after_entries = build_in(
            workdir,
            extra_word=("append only probe", "проверка добавления", 55000),
            version="1.3.1")
    after = {e["code"]: e["en"] for e in after_entries}

    moved = [(c, before[c], after.get(c)) for c in before
             if after.get(c) != before[c]]
    lost = [c for c in before if c not in after]
    added = sorted(set(after) - set(before))

    print(f"было кодов: {len(before)}, стало: {len(after)}, "
          f"добавлено: {len(added)}")
    if moved:
        print(f"ПРОВАЛ: {len(moved)} существующих кодов сменили смысл")
        for code, was, now in moved[:5]:
            print(f"  код {code}: «{was}» → «{now}»")
        raise SystemExit(1)
    if lost:
        print(f"ПРОВАЛ: потеряно кодов: {len(lost)} (первые {lost[:5]})")
        raise SystemExit(1)
    if not added:
        print("ПРОВАЛ: новая запись не появилась — тест ничего не проверил")
        raise SystemExit(1)
    print(f"ОК: смыслы существующих кодов не изменились; "
          f"новая запись получила код {added[0]} в хвосте")


if __name__ == "__main__":
    main()

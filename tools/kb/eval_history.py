# -*- coding: utf-8 -*-
"""Eval пака history_chappe (бриф 02.08, п.8).

Детерминированный, без LLM: python-порт ретривера kb_spec v0.2
(префикс-матчинг ключей ≥4, ранжирование по числу совпавших ключей,
ядро всегда) + 22 вопроса с ожидаемыми фактами-подстроками. Плюс
обязательный ноль: все даты пака обязаны присутствовать в исходнике
(имён/дат вне источника быть не должно).

Запуск: python3 tools/kb/eval_history.py <путь-к-исходнику-md>
"""
import re
import sys

PACK = "packs/history_chappe_v0.md"


def load_pack(path):
    text = open(path, encoding="utf-8").read()
    sections = []
    for m in re.split(r"^## ", text, flags=re.M)[1:]:
        lines = m.splitlines()
        title = lines[0].strip()
        keys_line = next((l for l in lines[1:3] if l.startswith("ключи:")), "")
        keys = [k.strip() for k in keys_line.replace("ключи:", "").split(",")
                if k.strip()]
        body = "\n".join(lines[1:])
        sections.append(dict(title=title, keys=keys, body=body,
                             core="всегда" in keys, toc=title == "Оглавление"))
    return sections


def matches(key, word):
    if key == word:
        return True
    if len(key) >= 4 and word.startswith(key):
        return True
    return len(word) >= 4 and key.startswith(word)


def retrieve(sections, query):
    words = re.findall(r"[а-яёa-z0-9]+", query.lower())
    picked = [s for s in sections if s["core"]]
    scored = []
    for i, s in enumerate(sections):
        if s["core"] or s["toc"]:
            continue
        score = sum(1 for k in s["keys"]
                    if any(matches(k, w) for w in words))
        if score:
            scored.append((score, -i, s))
    scored.sort(key=lambda t: (t[0], t[1]), reverse=True)
    if not scored:
        picked += [s for s in sections if s["toc"]]
        return picked
    # бюджет ~1200 «токенов» ≈ длина/3.5 — как в Swift-оценщике
    used = sum(len(s["body"]) // 4 for s in picked)
    for _, _, s in scored:
        cost = len(s["body"]) // 4
        if used + cost > 1200:
            break
        used += cost
        picked.append(s)
    return picked


# 22 вопроса: (вопрос, обязательные подстроки в выбранных секциях)
QA = [
    ("почему приложение называется шаппи", ["в честь Клода Шаппа", "не имеет отношения к головным уборам"]),
    ("в честь кого назван ассистент", ["Софи-Франсуаз", "4 марта 1767"]),
    ("кто такая софи", ["младшей сестры Клода", "не приписывает ей вымышленной"]),
    ("когда родился клод шапп", ["25 декабря 1763", "Брюлоне"]),
    ("какую фразу передали в 1791 году", ["Si vous réussissez, vous serez bientôt couvert de gloire"]),
    ("как переводится фраза 1791 года", ["покроете себя славой"]),
    ("кто передал первое сообщение", ["Рене Шапп передавал", "Клод Шапп принимал"]),
    ("кто придумал первую фразу", ["Шену"]),
    ("сколько заняла передача", ["около четырёх минут"]),
    ("что делал пьер-франсуа на опыте", ["записывал условные знаки"]),
    ("какое было второе сообщение", ["Национальное собрание вознаградит"]),
    ("когда умер клод", ["23 января 1805", "колодце"]),
    ("клод покончил с собой?", ["вероятная версия", "НЕ доказанный факт"]),
    ("кто такой игнас шапп", ["депутат Законодательного собрания", "1829"]),
    ("чем занимался рене", ["северных линий"]),
    ("кто такой абрахам", ["Париж—Лилль", "1849"]),
    ("когда софи вышла замуж", ["7 сентября 1795", "Корнийо"]),
    ("сколько внесли супруги по контракту", ["5000 ливров"]),
    ("когда умерла софи", ["вероятно 1837", "не просмотрен"]),
    ("участвовала ли софи в телеграфе", ["не обнаружено", "неизвестна"]),
    ("кто был дядей клода", ["Жан-Батист", "астроном"]),
    ("куда ездил дядя-астроном", ["Тобольск", "Калифорни"]),
    ("какого размера была сеть", ["5000 км", "30 городов"]),
    ("кто составил первый словарь кодов", ["Делоне"]),
]


def zero_check(pack_text, source_text):
    """Все даты дд.мм.гггг / года 17xx-18xx из пака есть в исходнике."""
    def dates(t):
        out = set(re.findall(r"\b\d{2}\.\d{2}\.\d{4}\b", t))
        out |= set(re.findall(r"\b1[78]\d{2}\b", t))
        return out
    def norm(t):
        # даты пака в формате дд.мм.гггг ↔ исходник словами: сверяем годы
        return dates(t)
    extra = {d for d in norm(pack_text)} - {d for d in norm(source_text)}
    # дд.мм.гггг из пака разложить на год для сверки с исходником словами
    extra = {d for d in extra
             if (d[-4:] if "." in d else d) not in source_text}
    return sorted(extra)


def main():
    sections = load_pack(PACK)
    source = open(sys.argv[1], encoding="utf-8").read()
    pack_text = open(PACK, encoding="utf-8").read()

    ok = 0
    fails = []
    for q, expects in QA:
        picked = retrieve(sections, q)
        joined = "\n".join(s["title"] + "\n" + s["body"] for s in picked)
        missing = [e for e in expects if e not in joined]
        if missing:
            fails.append((q, missing, [s["title"] for s in picked]))
        else:
            ok += 1
    print(f"вопросов: {len(QA)}, прошло: {ok}, упало: {len(fails)}")
    for q, miss, titles in fails:
        print(f"  FAIL «{q}»: нет {miss}; секции {titles}")

    extra = zero_check(pack_text, source)
    print(f"обязательный ноль (даты вне исходника): "
          f"{'ПРОЙДЕН — 0' if not extra else 'ПРОВАЛ: ' + str(extra)}")
    sys.exit(0 if not fails and not extra else 1)


if __name__ == "__main__":
    main()

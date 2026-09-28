# -*- coding: utf-8 -*-
"""Сборка отчёта фермы: docs/reports/farm_<дата>.md (п.5).

Читает farm_text_results_en.json, farm_text_results.json (ru),
farm_voice_results.json; шапка — тройка окружения (п.0).
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SEM = os.path.join(HERE, "..", "semdict")
sys.path.insert(0, SEM)
os.chdir(SEM)                # rm_codec читает словарь из cwd
from rm_codec import Codec   # noqa: E402

DATE = "2026-07-28"
MODEL = "../../models/Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf"


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def block(name, s):
    pid = s["latin_tokens"] / s["tokens"] if s["tokens"] else 0
    fr = s["facts_ok"] / s["facts_all"] if s["facts_all"] else 0
    lines = [f"### {name}", "",
             f"- входов: **{s['n']}**, semantic {s['semantic']} / "
             f"text {s['text']}"
             + (f" ({s['semantic']/(s['semantic']+s['text']):.0%} семантикой)"
                if s['semantic'] + s['text'] else ""),
             f"- факты доставлены: **{fr:.1%}** ({s['facts_ok']}/{s['facts_all']})",
             f"- индекс пиджина: **{pid:.1%}** (цель 0)",
             f"- байт на semantic-сообщение: {s['bytes']/max(s['semantic'],1):.1f}"
             f" (сжатие ~{s['utf8']/max(s['bytes'],1):.1f}x), пакетов"
             f" на сообщение: {s['packets']/max(s['semantic'],1):.2f}", "",
             "| категория | доставлено |", "|---|---|"]
    for cat, (ok, al) in sorted(s["by_cat"].items()):
        la, lr = s.get("lost_by_cat", {}).get(cat, [0, 0])
        tail = f" (артефакт {la} / реально {lr})" if la or lr else ""
        lines.append(f"| {cat} | {ok}/{al} = {ok/al:.1%}{tail} |")
    la, lr = s.get("lost_artifact", 0), s.get("lost_real", 0)
    if la or lr:
        lines += ["",
                  f"Потери: **артефакты сверки {la} "
                  f"({la/max(s['facts_all'],1):.1%} — шум метрики, не "
                  f"качество продукта)**, реальные выпадения {lr} "
                  f"({lr/max(s['facts_all'],1):.1%}). Чистая доставка "
                  f"≈ {(s['facts_ok']+la)/max(s['facts_all'],1):.1%}."]
    if s.get("text_reasons"):
        lines += ["", "Причины TEXT: " + ", ".join(
            f"{k} — {v}" for k, v in sorted(s["text_reasons"].items(),
                                            key=lambda kv: -kv[1]))]
    return "\n".join(lines)


def main():
    codec = Codec()
    prompt = open(os.path.join(SEM, "pivot_prompt_chat_v1.txt"),
                  encoding="utf-8").read()
    en = json.load(open(os.path.join(HERE, "farm_text_results_en.json")))
    ru = json.load(open(os.path.join(HERE, "farm_text_results.json")))
    vo = json.load(open(os.path.join(HERE, "farm_voice_results.json")))

    out = [f"# Ферма диктовок — калибровочный прогон {DATE} (после фикса регистра имён)", "",
           "## Окружение (п.0 — без этого прогоны несравнимы)", "",
           f"- Словарь: **v{codec.version}**, sha256 "
           f"`{sha(os.path.join(SEM, 'rm_dict_core_v0.json'))[:16]}…`, "
           f"отпечаток таблицы `0x{codec.table_hash:02x}`",
           f"- Промпт пивота: `pivot_prompt_chat_v1.txt`, sha256 "
           f"`{hashlib.sha256(prompt.encode()).hexdigest()[:16]}…`",
           f"- Модель: Qwen3-4B-Instruct-2507-Q4_K_M, sha256 "
           f"`{sha(MODEL)[:16]}…`, llama-server, temp 0, ctx 8192",
           "- Факт-чекер: fact_extractor.py, валиден 36/36 на ручной "
           "разметке chat-корпуса", "",
           "## Текстовый контур (масштаб; вход сразу в пивот, STT мимо)", ""]
    for name in ("nus_sms", "nps_chat"):
        out += [block(name, en["corpora"][name]), ""]
    out += ["Оговорка: names 0% в EN-контуре — артефакт контура, а не "
            "конвейера: NAME:-маркеры ставит пивот-модель, которой в "
            "этом контуре нет; имена уходят литералами в нижнем "
            "регистре. В RU-контурах эффект тот же (tom, boston в "
            "рендерах живут строчными) — names-метрика систематически "
            "занижена во ВСЕХ контурах; фикс — промпт-твик NAME: + "
            "рендер esc_name с заглавной (кандидат №4 v1.1).", ""]
    out += [block("tatoeba_ru (полный конвейер: прегейт → llama-пивот "
                  "→ гейты)", ru["corpora"]["tatoeba_ru"]), ""]
    out += ["## Голосовой контур — ЗАФИКСИРОВАН НЕВАЛИДНЫМ (п.6)", "",
            "Golos — не чат (прегейт честно режет 52/162 как вне "
            "лексикона), а 12 «эталонных» диктовок оказались TTS "
            "вопреки правилу брифа. Цифры ниже — исторические, для "
            "сравнения; реальный корпус пишет владелец по протоколу "
            "docs/voice_corpus_protocol.md (60 записей, 12 карточек "
            "× 5 условий), импорт — import_recordings.py.", "",
            block(f"golos ({vo['n_input_files']} реальных записей, STT "
                  "SFSpeech с устройства)", vo["voice"]), ""]

    def top(d, n=30):
        return ", ".join(f"{w}·{c}" for w, c in d["residual_top100"][:n])
    out += ["## Топ несловарных смыслов (кандидаты в v1.1)", "",
            "EN (SMS-сленг доминирует — кандидат не словарь, а слой "
            "SMS-нормализации матчера):", "", top(en), "",
            "RU (текст+голос):", "",
            top(ru) or "—", "", top(vo) or "—", ""]
    fork_path = os.path.join(HERE, "farm_fork_results.json")
    if os.path.exists(fork_path):
        fk = json.load(open(fork_path))
        a, b = fk["path_a"], fk["path_b"]
        def line(tag, agg):
            fr = agg["facts_ok"] / max(agg["facts_all"], 1)
            pid = agg["latin"] / max(agg["tokens"], 1)
            return (f"| {tag} | {agg['n']} | {fr:.1%} | {pid:.1%} |")
        out += ["## Развилка (п.5): 200 SMS двумя путями", "",
                "| путь | n | факты | пиджин |", "|---|---|---|---|",
                line("A: напрямую в матчер", a),
                line("B: через пивот-модель (продуктовый)", b), "",
                "Вывод: пивот-модель нормализует сленг сама — пиджин "
                "падает 45.7% → 30.9% (dunno → «не знаю»). «Выигрыш» "
                "пути A по фактам — иллюзия: литералы сверяются сами с "
                "собой (сленг доставлен сленгом). Прямой путь в продукте "
                "не существует; **слой SMS-нормализации матчера НЕ "
                "приоритет** — снят из кандидатов v1.1 в отложенные.", ""]
    out += ["## Время (п.4): классификация худших случаев", "",
            "Разбор всех фикстур с потерей времени показал: 8 из 10 — "
            "«N pm/am» из EN-контура, и это оказался АРТЕФАКТ метрики "
            "(экстрактор не сдвигал pm и не читал русское «N после "
            "полудня»; починено, EN-факты 79.2% → 84.2%). Реальные "
            "остатки: относительные дни («послезавтра» разворачивается "
            "фразой «день после», «вчера вечером» → «последний ночь») — "
            "кандидаты relday-кодов; диапазоны («в 7 или лучше в 7:30») "
            "кодируются двумя time-юнитами и живут. Кандидат esc_time — "
            "в dict_candidates.md; унификация am/pm-маркеров санитайзера "
            "на esc_time — туда же (сейчас два представления времени).",
            ""]
    out += ["## Фикстуры", "",
            f"- EN с потерянными фактами: {len(en['fixtures'])} шт. "
            "(farm_text_results_en.json)",
            f"- RU: {len(ru['fixtures'])} шт., голос: "
            f"{len(vo['fixtures'])} шт.",
            "- Представительный набор — tests/farm_fixtures_2026-07-28.json,"
            " прогоняется сьютом (FarmFixturesTests).", ""]
    path = os.path.join(HERE, "..", "..", "docs", "reports",
                        f"farm_{DATE}.md")
    open(path, "w", encoding="utf-8").write("\n".join(out))
    print("отчёт:", path)


if __name__ == "__main__":
    main()

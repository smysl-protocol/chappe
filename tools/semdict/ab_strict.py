# -*- coding: utf-8 -*-
"""3г: ужесточённое правило пивота «незнакомая сущность = литерал,
синоним запрещён» — A против A-strict на farm-фикстурах (диком RU)."""
import json, os, re, sys, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "dictation_farm"))
os.chdir(HERE)
from rm_codec import Codec
from pipeline import units_from_pivot, sanitize_pivot
from fact_extractor import extract, delivered
codec = Codec()
BASE = open("pivot_prompt_chat_v1.txt").read().strip()
STRICT = open("pivot_prompt_strict_v1.txt").read().strip()

def chat(system, user):
    req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions",
        data=json.dumps({"model": "local", "temperature": 0,
            "max_tokens": 120, "stop": ["\n"],
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": "RU: " + user + "\nEN:"}]}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)["choices"][0]["message"]["content"].strip()

def run(prompt, text):
    piv = sanitize_pivot(chat(prompt, text), codec)
    u = units_from_pivot(piv, codec)
    rendered = codec.render(u)
    toks = [t for t in re.findall(r"[^\W\d_]+", rendered.lower()) if len(t) >= 2]
    latin = sum(1 for t in toks if re.search(r"[a-z]", t))
    checks = delivered(extract(text), extract(rendered))
    ents = [c for c in checks if c[0] == "entities"]
    return dict(f_ok=sum(c[2] for c in checks), f_all=len(checks),
                e_ok=sum(c[2] for c in ents), e_all=len(ents),
                latin=latin, toks=len(toks), blob=len(codec.encode(u)))

fx = (json.load(open(os.path.join(HERE, "..", "dictation_farm",
                                  "farm_text_results.json")))["fixtures"]
      + json.load(open(os.path.join(HERE, "..", "dictation_farm",
                                    "farm_voice_results.json")))["fixtures"])
inputs = [f["input"] for f in fx][:80]
agg = {"base": dict(f=0, fa=0, e=0, ea=0, l=0, t=0, b=0),
       "strict": dict(f=0, fa=0, e=0, ea=0, l=0, t=0, b=0)}
for i, text in enumerate(inputs):
    for tag, prompt in (("base", BASE), ("strict", STRICT)):
        try:
            r = run(prompt, text)
        except Exception:
            continue
        a = agg[tag]
        a["f"] += r["f_ok"]; a["fa"] += r["f_all"]
        a["e"] += r["e_ok"]; a["ea"] += r["e_all"]
        a["l"] += r["latin"]; a["t"] += r["toks"]; a["b"] += r["blob"]
    if (i + 1) % 20 == 0:
        print(f"{i+1}/{len(inputs)}", flush=True)
json.dump(agg, open("ab_strict_results.json", "w"), indent=1)
for tag, a in agg.items():
    print(f"[{tag}] факты {a['f']}/{a['fa']}={a['f']/max(a['fa'],1):.1%} "
          f"entities {a['e']}/{a['ea']}={a['e']/max(a['ea'],1):.1%} "
          f"пиджин {a['l']/max(a['t'],1):.1%} blob/ср {a['b']/len(inputs):.1f}")

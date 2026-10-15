#!/usr/bin/env python3
"""Lee ~/.claude/projects y genera index.html con el uso de tokens por día/proyecto/modelo."""
import json, glob, os, pathlib, re, sys, webbrowser
from datetime import datetime

PREFIX = os.environ.get("CLAUDE_USAGE_PREFIX", "pic")  # solo carpetas que empiezan así; "" = todas
# Claude Code guarda cada carpeta de proyecto con la ruta codificada: todo carácter no alfanumérico pasa a "-"
# (/Users/ana/app -> -Users-ana-app, C:\Users\ana\app -> C--Users-ana-app). Funciona igual en macOS, Linux y Windows.
claude_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
root = os.path.join(claude_dir, "projects")
home_prefix = re.sub(r"[^A-Za-z0-9]", "-", os.path.expanduser("~"))
msgs = {}  # message.id -> registro (los mensajes se repiten al hacer streaming; nos quedamos con el último)
for f in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
    session = os.path.basename(f)
    try:
        for line in open(f, encoding="utf-8", errors="ignore"):
            if '"usage"' not in line: continue
            try: o = json.loads(line)
            except Exception: continue
            m = o.get("message") or {}
            u = m.get("usage")
            if not u or o.get("type") != "assistant" or m.get("model") in (None, "<synthetic>"): continue
            # proyecto = carpeta donde Claude Code guarda la sesión (la carpeta desde la que lo abriste)
            folder = os.path.relpath(f, root).split(os.sep)[0]
            project = folder.removeprefix(home_prefix).lstrip("-") or "~ (home)"
            day = datetime.fromisoformat(o["timestamp"].replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d")
            msgs[m.get("id") or o["uuid"]] = dict(session=session, day=day, project=project, model=m["model"],
                input=u.get("input_tokens", 0), cache_write=u.get("cache_creation_input_tokens", 0),
                cached=u.get("cache_read_input_tokens", 0), output=u.get("output_tokens", 0))
    except Exception as e:
        print("skip", f, e, file=sys.stderr)

agg = {}
for r in msgs.values():
    k = (r["day"], r["project"], r["model"])
    a = agg.setdefault(k, dict(day=k[0], project=k[1], model=k[2], input=0, cache_write=0, cached=0, output=0))
    a["input"] += r["input"]; a["cache_write"] += r["cache_write"]; a["cached"] += r["cached"]; a["output"] += r["output"]

# Histórico: Claude Code borra los logs viejos (por defecto ~30 días), así que guardamos los totales diarios aparte.
# Por cada (día, proyecto, modelo) nos quedamos con el registro más grande, para que un log parcialmente borrado no lo achique.
HIST = os.environ.get("CLAUDE_USAGE_HISTORY") or os.path.join(os.path.expanduser("~"), ".claude-usage", "history.json")
for a in agg.values():
    a["total"] = a["input"] + a["cache_write"] + a["cached"] + a["output"]
merged = {}
try:
    with open(HIST, encoding="utf-8") as h:
        for r in json.load(h): merged[(r["day"], r["project"], r["model"])] = r
except (OSError, ValueError, KeyError):
    pass
for k, a in agg.items():
    if k not in merged or a["total"] >= merged[k]["total"]: merged[k] = a
try:
    os.makedirs(os.path.dirname(HIST), exist_ok=True)
    with open(HIST, "w", encoding="utf-8") as h:
        json.dump([merged[k] for k in sorted(merged)], h, indent=0, sort_keys=True)
except OSError as e:
    print("no pude guardar el histórico:", e, file=sys.stderr)
data = [r for r in merged.values() if not PREFIX or r["project"].startswith(PREFIX)]

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "index.html")
with open(os.path.join(here, "template.html"), encoding="utf-8") as t:
    html = t.read().replace("__DATA__", json.dumps(data))
with open(out, "w", encoding="utf-8") as w:
    w.write(html)
print(f"{len(msgs)} mensajes en los logs, {len({r['day'] for r in data})} días con histórico -> {out}")
if "--open" in sys.argv:
    webbrowser.open(pathlib.Path(out).as_uri())

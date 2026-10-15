#!/usr/bin/env python3
"""Lee ~/.claude/projects y genera index.html con el uso de tokens por día/proyecto/modelo."""
import json, glob, os, sys
from datetime import datetime

PREFIX = os.environ.get("CLAUDE_USAGE_PREFIX", "pic")  # solo carpetas que empiezan así; "" = todas
root = os.path.expanduser("~/.claude/projects")
home_prefix = os.path.expanduser("~").replace("/", "-")
msgs = {}  # message.id -> registro (los mensajes se repiten al hacer streaming; nos quedamos con el último)
for f in glob.glob(f"{root}/**/*.jsonl", recursive=True):
    session = os.path.basename(f)
    try:
        for line in open(f, errors="ignore"):
            if '"usage"' not in line: continue
            try: o = json.loads(line)
            except Exception: continue
            m = o.get("message") or {}
            u = m.get("usage")
            if not u or o.get("type") != "assistant" or m.get("model") in (None, "<synthetic>"): continue
            # proyecto = carpeta donde Claude Code guarda la sesión (la carpeta desde la que lo abriste)
            folder = os.path.relpath(f, root).split(os.sep)[0]
            project = folder.removeprefix(home_prefix).lstrip("-") or "~ (home)"
            if PREFIX and not project.startswith(PREFIX): continue
            day =datetime.fromisoformat(o["timestamp"].replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d")
            msgs[m.get("id") or o["uuid"]] = dict(session=session, day=day, project=project, model=m["model"],
                input=u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0),
                cached=u.get("cache_read_input_tokens", 0), output=u.get("output_tokens", 0))
    except Exception as e:
        print("skip", f, e, file=sys.stderr)

agg = {}
for r in msgs.values():
    k = (r["day"], r["project"], r["model"])
    a = agg.setdefault(k, dict(day=k[0], project=k[1], model=k[2], input=0, cached=0, output=0, sess=set()))
    a["input"] += r["input"]; a["cached"] += r["cached"]; a["output"] += r["output"]; a["sess"].add(r["session"])
data = []
for a in agg.values():
    a["sessions"] = sorted(a.pop("sess"))
    a["total"] = a["input"] + a["cached"] + a["output"]
    data.append(a)

here = os.path.dirname(os.path.abspath(__file__))
html = open(f"{here}/template.html").read().replace("__DATA__", json.dumps(data))
open(f"{here}/index.html", "w").write(html)
print(f"{len(msgs)} mensajes, {len({s for a in data for s in a['sessions']})} sesiones -> {here}/index.html")

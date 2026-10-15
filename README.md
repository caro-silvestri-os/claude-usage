# claude-usage

Dashboard local, estilo calendario de GitHub, con los tokens que usás en Claude Code por proyecto (carpeta), día y modelo.

Lee los logs de `~/.claude/projects`; no sube ni envía nada.

## Uso

```
python3 generate.py
open index.html
```

Por defecto solo cuenta carpetas que empiezan con `pic`. Para cambiarlo:

```
CLAUDE_USAGE_PREFIX=mi-prefijo python3 generate.py   # otro prefijo
CLAUDE_USAGE_PREFIX= python3 generate.py             # todas las carpetas
```

Click en un proyecto de la tabla para filtrar todo el dashboard.

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

## App de barra de menú (macOS)

App nativa en Swift que muestra en la barra de menú los tokens de hoy; al hacer click ves hoy / 7 días / mes / total y el detalle por proyecto.

```
./menubar/build.sh        # compila ClaudeUsage.app (requiere Xcode / Command Line Tools)
open ClaudeUsage.app
```

Se refresca sola cada 60 s. "Abrir dashboard" regenera y abre `index.html`. Usa el mismo filtro `CLAUDE_USAGE_PREFIX`.

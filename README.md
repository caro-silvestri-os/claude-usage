# claude-usage

Dashboard local con el uso de tokens de **Claude Code** por proyecto (carpeta), día y modelo, con un calendario estilo GitHub y un costo estimado. Incluye una app de barra de menú para macOS que muestra los tokens de hoy y abre el dashboard con un click.

Todo corre en tu máquina: lee los logs que Claude Code ya guarda en `~/.claude/projects` y no envía nada a ningún lado.

## Requisitos

- macOS 13 o superior (la barra de menú; el dashboard web funciona en cualquier sistema con Python)
- Python 3 (ya viene con macOS / Xcode Command Line Tools)
- Para compilar la app de barra de menú: Xcode Command Line Tools (`xcode-select --install`)
- Haber usado Claude Code en esa computadora (si no, no hay logs que leer)

## Instalación

```bash
git clone https://github.com/caro-silvestri-os/claude-usage.git
cd claude-usage
```

### Opción A: dashboard en el navegador

```bash
python3 generate.py     # lee tus logs y genera index.html
open index.html
```

Para actualizar los datos, volvé a correr `python3 generate.py` y recargá la página.

### Opción B: app de barra de menú (recomendada)

```bash
./menubar/build.sh      # compila ClaudeUsage.app dentro de la carpeta del repo
open ClaudeUsage.app
```

- **Barra de menú:** muestra los tokens de hoy, por ejemplo `1.9M`.
- **Click izquierdo:** abre el dashboard completo en una ventanita.
- **Click derecho (o ctrl-click):** menú con *Actualizar ahora*, *Abrir en el navegador*, *Abrir al iniciar sesión* y *Salir*.
- Se refresca sola cada 60 segundos y no aparece en el Dock.

La app no está firmada por un desarrollador de Apple. Si macOS la bloquea la primera vez, abrila con click derecho → *Abrir*, o desde *Ajustes del Sistema → Privacidad y seguridad → Abrir igualmente*.

Para que arranque con la compu, usá *Abrir al iniciar sesión* en el menú de click derecho. Si movés la carpeta del repo, volvé a activarlo.

## Qué muestra

- Costo estimado, tokens totales, input, cache read y output.
- Calendario del año completo; se puede medir por tokens, output o costo estimado.
- Tabla por proyecto (click en un proyecto para filtrar todo el dashboard) y tabla por modelo.

Un "proyecto" es la carpeta desde la que abriste Claude Code. Los subagentes cuentan dentro del proyecto de su sesión.

## Configuración

Por defecto solo cuenta carpetas cuyo nombre empieza con `pic`. Para cambiarlo, usá la variable `CLAUDE_USAGE_PREFIX`:

```bash
CLAUDE_USAGE_PREFIX=mi-prefijo python3 generate.py   # otro prefijo
CLAUDE_USAGE_PREFIX= python3 generate.py             # todas las carpetas
```

La app de barra de menú no lee tus variables de terminal. Para cambiar el filtro ahí, editá el valor por defecto en `menubar/main.swift` (buscá `CLAUDE_USAGE_PREFIX`; ponelo en `""` para contar todas las carpetas) y recompilá con `./menubar/build.sh`. Hacé lo mismo en `generate.py` (`PREFIX = ...`) si también usás el dashboard del navegador.

## Sobre el costo estimado

El costo se calcula con los **precios de lista de la API de Anthropic** (USD por millón de tokens):

| Tipo | Precio |
|---|---|
| Input nuevo | precio base del modelo |
| Escritura de caché | 1,25 × input |
| Lectura de caché | 0,1 × input |
| Output | precio de output del modelo |

Es una **referencia, no el cobro real**:

- Si tu empresa tiene un contrato con descuentos, o usás una suscripción de monto fijo, lo que se paga es distinto.
- Los precios están escritos a mano en `template.html` (`PRICE`) y en `menubar/main.swift` (`cost`). Los modelos que no están en la tabla usan $2 / $10 por millón. Actualizalos si cambian o si usás otros modelos.
- Para saber cómo se factura tu uso, corré `/status` en Claude Code.

## Estructura

| Archivo | Qué hace |
|---|---|
| `generate.py` | Lee los logs y genera `index.html` |
| `template.html` | Diseño del dashboard (se comparte con la app) |
| `menubar/main.swift` | App de barra de menú en Swift |
| `menubar/build.sh` | Compila `ClaudeUsage.app` |

`index.html` y `ClaudeUsage.app` se generan en tu máquina y no se suben al repo (el primero tiene tus datos).

## Privacidad

Los logs de `~/.claude/projects` incluyen tus conversaciones. Este proyecto solo lee las cifras de uso (tokens, modelo, fecha y carpeta), pero **no subas `index.html`** si lo vas a compartir: muestra los nombres de tus proyectos y tu consumo.

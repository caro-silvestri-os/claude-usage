# claude-usage

Dashboard local con el uso de tokens de **Claude Code** por proyecto (carpeta), día y modelo, con un calendario estilo GitHub y un costo estimado. Incluye una app de barra de menú para macOS que muestra los tokens de hoy y abre el dashboard con un click.

Todo corre en tu máquina: lee los logs que Claude Code ya guarda en `~/.claude/projects` y no envía nada a ningún lado.

## Requisitos

- **Dashboard en el navegador:** macOS, Linux o Windows, con Python 3.9 o superior.
- **App de barra de menú:** solo macOS 13 o superior, y las Xcode Command Line Tools para compilarla (`xcode-select --install`).
- Haber usado Claude Code en esa computadora (si no, no hay logs que leer)

## Instalación

```bash
git clone https://github.com/caro-silvestri-os/claude-usage.git
cd claude-usage
```

### Opción A: dashboard en el navegador (macOS, Linux y Windows)

```bash
python3 generate.py --open     # lee tus logs, genera index.html y lo abre en el navegador
```

En Windows usá `python` o `py` en vez de `python3`. Sin `--open` solo genera `index.html`; abrilo con doble click.

Para actualizar los datos, volvé a correr el comando (o `python3 generate.py` y recargá la página). Si usás `CLAUDE_CONFIG_DIR` para cambiar dónde guarda Claude Code sus archivos, el script lo respeta.

> Linux y Windows: el script está pensado para esos sistemas (rutas, codificación UTF-8), pero lo probé solo en macOS. Si algo falla, abrí un issue con el error.

La barra de menú no existe en Linux ni Windows. Ahí la alternativa es el dashboard del navegador.

### Opción B: app de barra de menú (solo macOS)

```bash
./menubar/build.sh      # compila ClaudeUsage.app dentro de la carpeta del repo
open ClaudeUsage.app
```

- **Barra de menú:** muestra los tokens de hoy, por ejemplo `1.9M`.
- **Click izquierdo:** ventanita con lo de **hoy**: costo estimado, tokens totales, input, cache read, output y el detalle por proyecto, todo solo del día. El botón **Ver histórico en la web** abre el dashboard completo (calendario, tabla por día, períodos) en el navegador.
- **Click derecho (o ctrl-click):** menú con *Actualizar ahora*, *Ver histórico en la web*, *Abrir al iniciar sesión* y *Salir*.
- Se refresca sola cada 60 segundos y no aparece en el Dock.

La app no está firmada por un desarrollador de Apple. Si macOS la bloquea la primera vez, abrila con click derecho → *Abrir*, o desde *Ajustes del Sistema → Privacidad y seguridad → Abrir igualmente*.

Para que arranque con la compu, usá *Abrir al iniciar sesión* en el menú de click derecho. Si movés la carpeta del repo, volvé a activarlo.

## Qué muestra

- Costo estimado, tokens totales, input, cache read y output.
- Calendario del año completo; se puede medir por tokens, output o costo estimado. Click en un día para ver su detalle por proyecto y modelo.
- Tabla **por día** (el más reciente primero) con tokens y costo estimado.
- Tabla por proyecto (click en un proyecto para filtrar todo el dashboard) y tabla por modelo.
- Selector de **período**: todo el histórico o un año en particular.

## Histórico

Claude Code borra por su cuenta los logs viejos (por defecto, los de más de ~30 días), así que los logs solos no alcanzan para ver meses atrás. Por eso, cada vez que corrés `generate.py` o la app de barra de menú, los totales diarios se guardan en:

```
~/.claude-usage/history.json
```

Desde ese momento los días quedan guardados aunque Claude Code borre los logs. **Los días que ya se borraron antes de la primera ejecución no se pueden recuperar**, así que conviene instalarlo cuanto antes. Si no lo corrés por un tiempo, igual se conservan los últimos ~30 días de logs que haya.

`generate.py` y la app comparten el mismo archivo. Se puede cambiar con `CLAUDE_USAGE_HISTORY=/otra/ruta.json`. Si lo borrás, el histórico empieza de nuevo con lo que haya en los logs.

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

`~/.claude-usage/history.json` guarda nombres de proyecto y consumo por día (sin contenido de conversaciones). Los logs de `~/.claude/projects` sí incluyen tus conversaciones. Este proyecto solo lee las cifras de uso (tokens, modelo, fecha y carpeta), pero **no subas `index.html`** si lo vas a compartir: muestra los nombres de tus proyectos y tu consumo.

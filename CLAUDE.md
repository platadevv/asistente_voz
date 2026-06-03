# Asistente de Voz — Guía para Claude Code

Este archivo describe la arquitectura del proyecto para que Claude Code pueda hacer modificaciones con contexto completo.

## Arquitectura

```
SUPER+Q (pulsar)  →  hablar.sh start  →  socket Unix /tmp/asistente.sock  →  daemon.py
                                                                                  │
                                                                       pw-record graba audio
                                                                                  │
SUPER+Q (soltar)  →  hablar.sh stop   →  socket Unix                     →  daemon.py
                                                                                  │
                                                                     Whisper transcribe (GPU)
                                                                                  │
                                                                          grim → screenshot
                                                                                  │
                                                                   claude -p --continue (headless)
                                                                                  │
                                                                     Piper TTS → paplay
```

## Archivos clave

| Archivo | Función |
|---------|---------|
| `daemon.py` | Demonio principal. Mantiene Whisper en GPU, gestiona el socket, llama a Claude y Piper. |
| `asistente-daemon.sh` | Lanzador. Configura venv y LD_LIBRARY_PATH para CUDA. Lo arranca Hyprland al inicio. |
| `hablar.sh` | Cliente mínimo. Solo manda `start`/`stop`/`quit` al socket. |
| `escritorio.sh` | Helper de control de ventanas. Encapsula la sintaxis Lua de Hyprland 0.55. |
| `install.sh` | Instalador interactivo: venv, Piper, voz, Hyprland config. |
| `skills/*.md` | Conocimiento personalizado que se inyecta en el SYS_PROMPT al arrancar. En .gitignore. |

## Constantes configurables en daemon.py

```python
MODELO = "small"         # Tamaño Whisper: tiny / small / medium / large-v3
MODELO_CLAUDE = "sonnet" # Modelo Claude: haiku (rápido) / sonnet / opus (mejor)
CLAUDE_TIMEOUT = 90      # Segundos máximos de espera para Claude
PIPER_VOICE = f"{BASE}/piper/voces/es_AR-daniela-high.onnx"  # Voz activa
```

## Rutas — todas dinámicas

```python
BASE     = os.path.dirname(os.path.abspath(__file__))  # directorio del proyecto
CONV_DIR = os.path.expanduser("~/.asistente-voz")      # conversación de Claude
```

No hardcodear rutas absolutas. Usar siempre `BASE` o `os.path.expanduser`.

## Sistema de skills

- Archivos `.md` en `skills/` (en .gitignore, contenido personal).
- Se cargan en `_load_skills()` al arrancar el daemon y se añaden al final de `SYS_PROMPT`.
- Para añadir una skill: crear `skills/nombre.md` y reiniciar el daemon.
- Para reiniciar el daemon:
  ```bash
  pgrep -f daemon.py | xargs kill -9; rm -f /tmp/asistente.sock
  setsid -f ./asistente-daemon.sh >/tmp/asistente-daemon.log 2>&1
  ```

## Captura de pantalla

En cada consulta, `take_screenshot()` captura con `grim /tmp/asistente_screenshot.png`.
El path se añade al prompt para que Claude use `Read` si necesita ver la pantalla.
Se borra siempre tras la respuesta en `stop_rec()`.

## Notificaciones

- `notify()` — notificación simple con timeout.
- `_notify_thinking()` — muestra "⏳ Pensando...", devuelve ID con `--print-id`.
- `_notify_response(id, msg)` — reemplaza la notificación con `--replace-id`.
- **IMPORTANTE**: usar `stdout=subprocess.PIPE` + `stderr=subprocess.DEVNULL` por separado. `capture_output=True` con `stderr=DEVNULL` lanza `ValueError` silencioso.

## Hyprland 0.55 — sintaxis Lua (CRÍTICO)

La API antigua de strings **no funciona** en Hyprland 0.55. Usar siempre `escritorio.sh`:

```bash
# CORRECTO
escritorio.sh mover firefox 2

# MAL — no usar directamente
hyprctl dispatch movetoworkspace 2,class:firefox  # roto en 0.55
```

El helper encapsula:
```bash
hyprctl dispatch "hl.dsp.window.move({ window = \"address:0x...\", workspace = \"2\", follow = false })"
```

## Reglas de seguridad del asistente (no modificar sin motivo)

El SYS_PROMPT tiene reglas explícitas que no deben eliminarse:
- No ejecutar comandos destructivos para "probar" sintaxis.
- No encadenar intentos si un comando falla — decirlo en una frase.
- Lanzar GUIs y apps de larga duración siempre con `setsid -f ... >/dev/null 2>&1`.
- Solo texto plano en respuestas (sin markdown, listas ni asteriscos).

## Claude Code headless — cómo funciona

```python
subprocess.run(
    ["claude", "-p", "--continue", prompt,
     "--append-system-prompt", SYS_PROMPT,
     "--dangerously-skip-permissions",
     "--model", MODELO_CLAUDE,
     "--output-format", "text"],
    cwd=CONV_DIR,
    stdout=open(CLAUDE_OUT, "w"),  # fichero, no pipe (evita deadlocks con GUIs)
    start_new_session=True,        # aísla en su propio grupo de procesos
    timeout=CLAUDE_TIMEOUT,
)
```

El stdout va a fichero (no pipe) para evitar que procesos GUI hijos que hereden el descriptor bloqueen el `subprocess.run` indefinidamente.

## Voces Piper disponibles para español

| ID | Género | Calidad | Acento |
|----|--------|---------|--------|
| `es_AR-daniela-high` | Femenina | Alta | Argentina |
| `es_ES-davefx-medium` | Masculina | Media | España |
| `es_MX-claude-high` | Masculina | Alta | México |
| `es_ES-sharvard-medium` | Femenina | Media | España (suena masculina) |

Descargar desde: `https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/{path}`
Paths en: `https://huggingface.co/rhasspy/piper-voices/resolve/main/voices.json`

# Asistente de Voz

Asistente de voz personal para Linux con **push-to-talk**, pensado para Omarchy/Hyprland. Combina tres componentes locales:

- **Whisper** (faster-whisper + GPU) — transcripción de voz a texto en tiempo real
- **Claude Code** (`claude -p --continue`) — cerebro agéntico que puede actuar en el escritorio
- **Piper** (TTS local) — síntesis de voz en español sin dependencias de red

El flujo completo ocurre **sin enviar audio a ningún servidor externo**: el audio se graba localmente, Whisper lo transcribe en GPU, y la respuesta se sintetiza con Piper en local. Solo el texto va a la API de Claude.

---

## Arquitectura

```
SUPER+Q (press)  →  hablar.sh start  →  socket Unix  →  daemon.py
                                                             │
                                                    pw-record graba audio
                                                             │
SUPER+Q (release) →  hablar.sh stop  →  socket Unix  →  daemon.py
                                                             │
                                                  Whisper transcribe (GPU)
                                                             │
                                                   Claude Code (agéntico)
                                                             │
                                                    Piper habla en voz alta
```

El demonio carga Whisper **una sola vez** en GPU al arrancar y queda residente. El cliente `hablar.sh` es un script mínimo que solo manda `start`/`stop` por el socket, sin latencia.

---

## Requisitos del sistema

### Hardware
- GPU NVIDIA con soporte CUDA (probado con RTX 3090)
- Micrófono

### Software base
| Paquete | Propósito |
|---------|-----------|
| `python` ≥ 3.11 | Runtime del demonio |
| `cuda` + drivers NVIDIA | Aceleración GPU para Whisper |
| `pipewire` | Grabación de audio (`pw-record`) y reproducción (`paplay`) |
| `socat` | Comunicación cliente→socket Unix |
| `jq` | Parseo JSON en `escritorio.sh` |
| `hyprctl` | Control de ventanas/escritorios (Hyprland) |
| `omarchy-launch-or-focus` | Lanzar/enfocar apps (parte de Omarchy) |
| `notify-send` | Notificaciones de escritorio |
| `claude` CLI | [Claude Code](https://claude.ai/code) instalado y autenticado |

Instalar en CachyOS/Arch:

```bash
sudo pacman -S python cuda pipewire socat jq hyprland
```

---

## Instalación

### 1. Clonar el repositorio

```bash
git clone git@github.com:platadevv/asistente_voz.git
cd asistente_voz
```

### 2. Crear el entorno virtual e instalar dependencias Python

```bash
python -m venv venv
source venv/bin/activate
pip install faster-whisper
# Paquetes CUDA necesarios para GPU (si no los tienes ya en el sistema):
pip install nvidia-cublas-cu12 nvidia-cudnn-cu12
```

> **Nota:** `faster-whisper` descargará el modelo de Whisper (`small` por defecto) de Hugging Face la primera vez que arranques el demonio. Con GPU NVIDIA se ejecuta en CUDA automáticamente.

### 3. Descargar Piper TTS

Descarga el [binario de Piper](https://github.com/rhasspy/piper/releases) para Linux x86_64 y extráelo en `piper/`:

```bash
mkdir -p piper/voces
# Extraer: piper/, espeak-ng, espeak-ng-data/, libonnxruntime.so*, etc.
```

Descarga la voz española (ejemplo: `es_ES-davefx-medium`):

```bash
# Desde https://huggingface.co/rhasspy/piper-voices
wget -P piper/voces/ \
  "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx" \
  "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx.json"
```

### 4. Crear el directorio de conversación de Claude

```bash
mkdir -p ~/.asistente-voz
```

Este directorio aísla la conversación del asistente del resto de proyectos de Claude Code.

### 5. Ajustar rutas en `asistente-daemon.sh`

Edita `asistente-daemon.sh` y cambia `BASE` a la ruta real del proyecto:

```bash
BASE="/ruta/a/tu/asistente_voz"
```

Lo mismo en `daemon.py` si clonas en una ruta diferente a `/home/abraham/Proyectos/asistente_voz`:

```python
BASE = "/ruta/a/tu/asistente_voz"
CONV_DIR = "/home/tuusuario/.asistente-voz"
```

### 6. Dar permisos de ejecución

```bash
chmod +x asistente-daemon.sh hablar.sh escritorio.sh
```

---

## Configuración en Hyprland

### Autostart del demonio

Añade en `~/.config/hypr/hyprland.conf`:

```ini
exec-once = /ruta/a/asistente_voz/asistente-daemon.sh
```

### Atajo de teclado push-to-talk

```ini
# Grabar mientras se mantiene pulsado SUPER+Q
bind  = SUPER, Q, exec, /ruta/a/asistente_voz/hablar.sh start
bindr = SUPER, Q, exec, /ruta/a/asistente_voz/hablar.sh stop
```

> `bind` se dispara al pulsar, `bindr` al soltar. Así funciona el push-to-talk.

---

## Uso

### Arrancar el demonio manualmente

```bash
./asistente-daemon.sh
```

El demonio imprime su estado por stdout. La primera vez tarda ~10-20 s en cargar Whisper en GPU. Cuando aparece `✅ Modelo listo.` ya puedes usar la tecla.

### Push-to-talk

1. **Mantén pulsado** `SUPER+Q` — escucharás un pitido y aparecerá la notificación `🎤 Escuchando...`
2. **Habla** lo que quieras (en español)
3. **Suelta** `SUPER+Q` — Whisper transcribe, Claude procesa, Piper responde en voz alta

### Detener el demonio

```bash
./hablar.sh quit
```

### Control del escritorio por voz

El asistente puede controlar ventanas y escritorios gracias a `escritorio.sh`. Ejemplos de comandos de voz:

- *"Abre Firefox"*
- *"Mueve Steam al escritorio 3"*
- *"¿En qué escritorio está Discord?"*
- *"Ve al escritorio 2"*

---

## Helper `escritorio.sh`

Encapsula la sintaxis Lua de `hyprctl dispatch` de **Hyprland 0.55** (la API clásica de strings ya no funciona):

```bash
escritorio.sh abrir    <cmd...>              # Lanza app desacoplada
escritorio.sh enfocar  <patrón> [cmd...]     # Enfoca o lanza
escritorio.sh mover    <patrón> <N>          # Mueve ventana al escritorio N
escritorio.sh abrir-en <N> <patrón> [cmd...] # Lanza y deja en escritorio N
escritorio.sh ir       <N>                   # Cambia al escritorio N
escritorio.sh donde    <patrón>              # Dice en qué escritorio está
```

`<patrón>` es una regex (sin distinción de mayúsculas) que casa contra `class` o `title` de la ventana.

---

## Configuración avanzada

Las constantes al principio de `daemon.py` permiten ajustar el comportamiento:

| Variable | Por defecto | Descripción |
|----------|-------------|-------------|
| `MODELO` | `"small"` | Tamaño del modelo Whisper (`tiny`/`small`/`medium`/`large-v3`) |
| `MODELO_CLAUDE` | `"sonnet"` | Modelo de Claude (`haiku` = más rápido, `opus` = más capaz) |
| `CLAUDE_TIMEOUT` | `90` | Segundos máximos de espera para Claude |
| `PIPER_VOICE` | `es_ES-davefx-medium` | Voz de Piper (archivo `.onnx`) |

---

## Estructura del proyecto

```
asistente_voz/
├── daemon.py              # Demonio principal (Whisper + Claude + Piper)
├── asistente-daemon.sh    # Lanzador del demonio (configura venv y LD_LIBRARY_PATH)
├── hablar.sh              # Cliente push-to-talk (envía start/stop/quit al socket)
├── escritorio.sh          # Helper de control de ventanas para Hyprland 0.55
└── piper/                 # Binario Piper + voces + espeak-ng (no incluido en repo)
    ├── piper
    ├── espeak-ng
    ├── espeak-ng-data/
    └── voces/
        └── es_ES-davefx-medium.onnx
```

---

## Solución de problemas

**El demonio no arranca / error de CUDA**
Verifica que los drivers NVIDIA y CUDA están instalados y que el venv tiene los paquetes `nvidia-cublas` y `nvidia-cudnn` correspondientes a tu versión de CUDA.

**`hablar.sh` muestra "Asistente de voz no está activo"**
El demonio no está corriendo. Arráncalo con `./asistente-daemon.sh`.

**Whisper "alucina" frases aunque no hayas hablado**
Es normal si hay mucho ruido ambiente. El filtro VAD (`vad_filter=True`) mitiga esto; puedes probar con un modelo más grande (`MODELO = "medium"`).

**Claude no responde o tarda mucho**
Aumenta `CLAUDE_TIMEOUT` o cambia `MODELO_CLAUDE = "haiku"` para respuestas más rápidas. Asegúrate de que `claude` CLI está autenticado (`claude --version`).

**Piper no habla / error de librería**
Verifica que `LD_LIBRARY_PATH` en `asistente-daemon.sh` incluye la ruta al venv con los paquetes NVIDIA, y que el binario `piper/piper` tiene permisos de ejecución.

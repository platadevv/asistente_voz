#!/usr/bin/env python3
"""Demonio del asistente de voz agentico.

Flujo (push-to-talk con SUPER+Q):
  1. Whisper (cargado UNA vez en GPU) transcribe tu voz.
  2. Claude Code headless (claude -p --continue) recibe el texto, puede ACTUAR
     en el equipo (abrir apps/juegos, etc.) y responde con personalidad.
  3. Piper (TTS local) lee la respuesta en voz alta por los altavoces.

El cliente (hablar.sh) solo manda "start"/"stop" por el socket Unix.
"""
import os
import sys
import time
import signal
import socket
import threading
import subprocess

import numpy as np
from faster_whisper import WhisperModel

BASE = "/home/abraham/Proyectos/asistente_voz"

SOCK = "/tmp/asistente.sock"
AUDIO = "/tmp/asistente_audio.wav"
TTS_WAV = "/tmp/asistente_tts.wav"
MODELO = "small"  # "medium" / "large-v3" para mas precision

# --- Claude Code (cerebro agentico) ---
MODELO_CLAUDE = "sonnet"          # "haiku" = mas rapido, "opus" = mas listo
CONV_DIR = "/home/abraham/.asistente-voz"  # cwd dedicado: aisla la conversacion
SYS_PROMPT = (
    "Eres un asistente de voz personal en espanol. Responde SIEMPRE breve y "
    "conversacional, como si hablaras en voz alta (1-2 frases), con un toque de "
    "humor cuando encaje. Puedes ejecutar acciones en el equipo con bash (abrir "
    "apps, juegos de Steam, mover ventanas entre escritorios, etc.); cuando te lo "
    "pidan, hazlo y confirma en una frase. Para controlar ventanas y escritorios "
    "usa SIEMPRE el helper /home/abraham/Proyectos/asistente_voz/escritorio.sh "
    "(abrir|enfocar|mover|abrir-en|ir|donde); ya tiene la sintaxis correcta de "
    "Hyprland 0.55, no la escribas a mano. SEGURIDAD CRITICA: NUNCA ejecutes "
    "comandos destructivos para experimentar o adivinar sintaxis (nada de "
    "'window.close()', 'killactive', 'kill', 'pkill' a modo de prueba); cerrar o "
    "matar algo solo si el usuario lo pide explicitamente. Si un comando falla, NO "
    "encadenes intentos a ciegas: dilo en una frase. IMPORTANTE: cualquier app "
    "grafica o de larga duracion (Steam, navegadores, juegos, etc.) DEBES lanzarla "
    "SIEMPRE desacoplada con 'setsid -f COMANDO >/dev/null 2>&1'; nunca una GUI en "
    "primer plano ni esperes a que termine. NUNCA uses markdown, listas, asteriscos "
    "ni bloques de codigo: solo texto plano para ser leido en voz."
)

CLAUDE_TIMEOUT = 90       # segundos: tope de seguridad para que el daemon NUNCA se cuelgue
CLAUDE_OUT = "/tmp/asistente_claude.out"  # stdout de claude (fichero, no pipe: evita deadlocks)

# --- Piper (TTS local) ---
PIPER_DIR = f"{BASE}/piper"
PIPER_BIN = f"{PIPER_DIR}/piper"
PIPER_VOICE = f"{PIPER_DIR}/voces/es_ES-davefx-medium.onnx"
PIPER_ESPEAK = f"{PIPER_DIR}/espeak-ng-data"

SONIDOS = "/usr/share/sounds/freedesktop/stereo"
SND_START = f"{SONIDOS}/message-new-instant.oga"  # al empezar a grabar
SND_STOP = f"{SONIDOS}/complete.oga"              # al terminar de grabar

rec_proc = None  # proceso de grabacion en curso (pw-record)

# Serializa las llamadas a Claude: el warmup corre en un hilo aparte y no debe
# pisar a un comando real (mismo CLAUDE_OUT y misma conversacion --continue).
claude_lock = threading.Lock()


def notify(msg):
    subprocess.run(["notify-send", "-t", "1500", msg], stderr=subprocess.DEVNULL)


def beep(path):
    # No bloqueante: el sonido no debe retrasar la grabacion/transcripcion
    subprocess.Popen(["paplay", path], stderr=subprocess.DEVNULL)


def ask_claude(texto, timeout=CLAUDE_TIMEOUT):
    """Envia el texto a Claude Code (headless) y devuelve (respuesta, estado).

    estado es "ok" | "timeout" | "vacio" para que el llamante notifique con
    precision que ha pasado. Usa --continue para mantener el hilo; si no hay
    conversacion previa (primer mensaje), arranca una nueva.
    """
    flags = [
        "--append-system-prompt", SYS_PROMPT,
        "--dangerously-skip-permissions",
        "--model", MODELO_CLAUDE,
        "--output-format", "text",
    ]

    def run(cmd):
        # stdout va a un FICHERO, no a un pipe. Si Claude lanza una GUI (Steam,
        # etc.) que hereda el descriptor, un pipe nunca llegaria a EOF y
        # subprocess.run se colgaria para siempre; con fichero leemos sin bloqueo.
        # start_new_session aisla a Claude en su propio grupo de procesos y
        # timeout es el tope de seguridad para que el daemon nunca se quede pillado.
        with open(CLAUDE_OUT, "w") as out:
            try:
                r = subprocess.run(
                    cmd, cwd=CONV_DIR,
                    stdin=subprocess.DEVNULL, stdout=out,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True, timeout=timeout,
                )
                rc = r.returncode
                timed_out = False
            except subprocess.TimeoutExpired:
                print("⏱  claude timeout", flush=True)
                rc = -1
                timed_out = True
        try:
            with open(CLAUDE_OUT, encoding="utf-8") as f:
                salida = f.read().strip()
        except OSError:
            salida = ""
        return rc, salida, timed_out

    # El lock evita que el warmup (hilo aparte) y un comando real se pisen.
    with claude_lock:
        rc, salida, timed_out = run(["claude", "-p", "--continue", texto] + flags)
        # Solo reintentamos como conversacion nueva si NO fue timeout (un
        # reintento tras timeout volveria a colgarse y doblaria la espera).
        if not timed_out and (rc != 0 or not salida):
            rc, salida, timed_out = run(["claude", "-p", texto] + flags)

    if salida:
        return salida, "ok"
    return "", ("timeout" if timed_out else "vacio")


def warmup_claude():
    """Pre-calienta Claude en segundo plano al arrancar el daemon.

    El PRIMER 'claude -p' tras un reinicio es lento (arranque del CLI de Node +
    conexion al modelo) y puede pasarse del timeout, haciendo que el primer
    comando real falle en silencio. Esta llamada de cortesia paga ese coste por
    adelantado y, ademas, crea la conversacion para que el --continue del primer
    comando real ya tenga hilo que continuar. Timeout holgado: corre en su hilo.
    """
    resp, estado = ask_claude("Responde solo con: listo", timeout=180)
    print(f"🔥 warmup claude: estado={estado} resp={resp!r}", flush=True)


def speak(texto):
    """Sintetiza 'texto' con Piper y lo reproduce por los altavoces."""
    env = {**os.environ, "LD_LIBRARY_PATH": PIPER_DIR}
    subprocess.run(
        [PIPER_BIN, "--model", PIPER_VOICE,
         "--espeak_data", PIPER_ESPEAK, "--output_file", TTS_WAV],
        input=texto.encode("utf-8"), env=env, stderr=subprocess.DEVNULL,
    )
    subprocess.run(["paplay", TTS_WAV], stderr=subprocess.DEVNULL)


def start_rec():
    global rec_proc
    if rec_proc is not None:
        return  # ya estamos grabando
    rec_proc = subprocess.Popen(
        ["pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", AUDIO]
    )
    beep(SND_START)
    notify("🎤 Escuchando...")


def stop_rec(model):
    global rec_proc
    if rec_proc is None:
        return
    rec_proc.terminate()
    try:
        rec_proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        rec_proc.kill()
    rec_proc = None
    beep(SND_STOP)
    time.sleep(0.2)  # margen para que se cierre el WAV

    tam = os.path.getsize(AUDIO) if os.path.exists(AUDIO) else 0
    print(f"⏹  stop: audio={tam} bytes", flush=True)
    if tam == 0:
        return

    # vad_filter recorta el silencio antes de transcribir: evita que Whisper
    # "alucine" frases tipicas (ej. "Subtitulos por la comunidad de Amara.org")
    # cuando no hay voz. condition_on_previous_text=False reduce repeticiones.
    segments, _ = model.transcribe(
        AUDIO,
        beam_size=5,
        language="es",
        vad_filter=True,
        condition_on_previous_text=False,
    )
    texto = "".join(s.text for s in segments).strip()
    try:
        os.remove(AUDIO)
    except OSError:
        pass

    print(f"📝 tu={texto!r}", flush=True)
    if not texto:
        notify("❌ No se detecto voz")
        return

    # 1) Pasar el texto a Claude Code (puede actuar en el equipo)
    notify(f"🗣️ {texto}")
    beep(SND_START)  # ping de "procesando"
    respuesta, estado = ask_claude(texto)
    print(f"🤖 claude={respuesta!r} (estado={estado})", flush=True)

    if not respuesta:
        if estado == "timeout":
            notify(f"⏱️ Claude tardo demasiado (>{CLAUDE_TIMEOUT}s)")
        else:
            notify("❌ Claude no respondio")
        return

    # 2) Leer la respuesta en voz alta
    notify(f"🤖 {respuesta}")
    speak(respuesta)


def cleanup(*_):
    global rec_proc
    if rec_proc is not None:
        rec_proc.terminate()
    if os.path.exists(SOCK):
        os.remove(SOCK)
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    print("🚀 Cargando modelo Whisper...", flush=True)
    model = WhisperModel(MODELO, device="cuda", compute_type="float16")

    # Warmup: forzamos la inicializacion de CUDA con audio en silencio
    # para que la PRIMERA transcripcion real ya sea rapida.
    try:
        list(model.transcribe(np.zeros(16000, dtype=np.float32), language="es")[0])
    except Exception:
        pass
    print("✅ Modelo listo.", flush=True)

    if os.path.exists(SOCK):
        os.remove(SOCK)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    srv.listen(1)
    print(f"👂 Escuchando en {SOCK}", flush=True)
    notify("🟢 Asistente de voz listo")

    # Pre-calentamos Claude en segundo plano: el socket ya acepta comandos
    # mientras tanto (el lock serializa si llega uno antes de terminar).
    threading.Thread(target=warmup_claude, daemon=True).start()

    while True:
        conn, _ = srv.accept()
        with conn:
            cmd = conn.recv(64).decode("utf-8", "ignore").strip()
        if cmd == "start":
            start_rec()
        elif cmd == "stop":
            stop_rec(model)
        elif cmd == "quit":
            break

    cleanup()


if __name__ == "__main__":
    main()

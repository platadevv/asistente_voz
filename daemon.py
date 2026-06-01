#!/usr/bin/env python3
"""Demonio del asistente de voz.

Carga el modelo Whisper UNA sola vez y se queda escuchando órdenes en un
socket Unix. El cliente (hablar.sh) solo manda "start"/"stop", así la
transcripcion es casi instantanea (sin recargar el modelo cada vez).
"""
import os
import sys
import time
import signal
import socket
import subprocess

import numpy as np
from faster_whisper import WhisperModel

SOCK = "/tmp/asistente.sock"
AUDIO = "/tmp/asistente_audio.wav"
MODELO = "small"  # "medium" / "large-v3" para mas precision

SONIDOS = "/usr/share/sounds/freedesktop/stereo"
SND_START = f"{SONIDOS}/message-new-instant.oga"  # al empezar a grabar
SND_STOP = f"{SONIDOS}/complete.oga"              # al terminar de grabar

rec_proc = None  # proceso de grabacion en curso (pw-record)


def notify(msg):
    subprocess.run(["notify-send", "-t", "1500", msg], stderr=subprocess.DEVNULL)


def beep(path):
    # No bloqueante: el sonido no debe retrasar la grabacion/transcripcion
    subprocess.Popen(["paplay", path], stderr=subprocess.DEVNULL)


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

    print(f"📝 texto={texto!r}", flush=True)
    if not texto:
        notify("❌ No se detecto voz")
        return

    rc1 = subprocess.run(["wtype", texto]).returncode
    time.sleep(0.1)
    rc2 = subprocess.run(["wtype", "-k", "Return"]).returncode
    print(f"⌨️  wtype rc={rc1}/{rc2}", flush=True)


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

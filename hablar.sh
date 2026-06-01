#!/bin/bash
# Cliente ligero del asistente de voz: solo envia la orden al demonio por el
# socket Unix. No carga nada, asi que es instantaneo. El demonio (daemon.py)
# es quien graba y transcribe manteniendo el modelo Whisper en memoria.

SOCK="/tmp/asistente.sock"

case "$1" in
  start|stop|quit)
    # socat falla al instante si el demonio no esta arrancado: no bloquea la tecla
    echo -n "$1" | socat - "UNIX-CONNECT:$SOCK" 2>/dev/null \
      || notify-send -t 1500 "⚠️ Asistente de voz no esta activo" 2>/dev/null
    ;;
  *)
    echo "Uso: $0 {start|stop|quit}"
    exit 1
    ;;
esac

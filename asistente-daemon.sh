#!/bin/bash
# Lanzador del demonio del asistente de voz (carga Whisper y mantiene el modelo
# en memoria). Lo usa el autostart de Hyprland y sirve para arrancarlo a mano.

BASE="/home/abraham/Proyectos/asistente_voz"
VENV_PATH="$BASE/venv"
NVIDIA_LIBS="$VENV_PATH/lib/python3.14/site-packages/nvidia/cublas/lib:$VENV_PATH/lib/python3.14/site-packages/nvidia/cudnn/lib"

export LD_LIBRARY_PATH="$NVIDIA_LIBS"
exec "$VENV_PATH/bin/python3" "$BASE/daemon.py"

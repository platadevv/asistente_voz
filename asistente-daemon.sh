#!/bin/bash
# Lanzador del demonio del asistente de voz (carga Whisper y mantiene el modelo
# en memoria). Lo usa el autostart de Hyprland y sirve para arrancarlo a mano.

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PATH="$BASE/venv"
PYTHON_VER="$(ls "$VENV_PATH/lib/" | grep '^python' | head -1)"
NVIDIA_LIBS="$VENV_PATH/lib/$PYTHON_VER/site-packages/nvidia/cublas/lib:$VENV_PATH/lib/$PYTHON_VER/site-packages/nvidia/cudnn/lib"

export LD_LIBRARY_PATH="$NVIDIA_LIBS"
exec "$VENV_PATH/bin/python3" "$BASE/daemon.py"

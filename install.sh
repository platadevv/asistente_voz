#!/bin/bash
# Instalador del Asistente de Voz
# Prepara el entorno, descarga Piper y configura Hyprland.

set -e

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$BASE/venv"
CONV_DIR="$HOME/.asistente-voz"
PIPER_DIR="$BASE/piper"

RESET='\033[0m'
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'

ok()   { echo -e "${GREEN}  ✓ $*${RESET}"; }
info() { echo -e "${CYAN}  → $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${RESET}"; }
fail() { echo -e "${RED}  ✗ $*${RESET}"; exit 1; }
step() { echo -e "\n${BOLD}$*${RESET}"; }

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║     Asistente de Voz — Instalador        ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${RESET}"

# ─── 1. Dependencias del sistema ───────────────────────────────────────────
step "1/6  Comprobando dependencias del sistema..."

MISSING=()
for cmd in python3 socat jq paplay pw-record notify-send grim claude; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd"
    else
        warn "$cmd — NO encontrado"
        MISSING+=("$cmd")
    fi
done

# claude es imprescindible
if ! command -v claude &>/dev/null; then
    echo ""
    echo -e "${RED}${BOLD}  ✗ Claude Code no está instalado o no está en el PATH.${RESET}"
    echo -e "${YELLOW}    Este programa REQUIERE Claude Code con sesión activa."
    echo -e "    Instálalo en: https://claude.ai/code${RESET}"
    echo ""
    fail "Instala Claude Code antes de continuar."
fi

if [ ${#MISSING[@]} -gt 0 ] && [[ " ${MISSING[*]} " != *" claude "* ]]; then
    warn "Dependencias no encontradas: ${MISSING[*]}"
    warn "En CachyOS/Arch: sudo pacman -S socat jq pipewire grim libnotify"
    read -rp "  ¿Continuar de todas formas? [s/N] " yn
    [[ "$yn" =~ ^[sS]$ ]] || exit 1
fi

# ─── 2. Entorno virtual Python ──────────────────────────────────────────────
step "2/6  Creando entorno virtual Python..."

if [ -d "$VENV" ]; then
    info "Ya existe un venv en $VENV, lo reutilizo."
else
    python3 -m venv "$VENV"
    ok "Venv creado en $VENV"
fi

info "Instalando faster-whisper y paquetes CUDA..."
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q faster-whisper nvidia-cublas-cu12 nvidia-cudnn-cu12
ok "Dependencias Python instaladas"

# ─── 3. Piper TTS ───────────────────────────────────────────────────────────
step "3/6  Configurando Piper TTS..."

if [ -f "$PIPER_DIR/piper" ]; then
    info "Piper ya instalado en $PIPER_DIR, salto descarga."
else
    info "Descargando Piper (binario Linux x86_64)..."
    mkdir -p "$PIPER_DIR"
    TMP_TAR="$(mktemp).tar.gz"
    curl -L --progress-bar \
        "https://github.com/rhasspy/piper/releases/latest/download/piper_linux_x86_64.tar.gz" \
        -o "$TMP_TAR"
    tar -xzf "$TMP_TAR" -C "$PIPER_DIR" --strip-components=1
    rm -f "$TMP_TAR"
    chmod +x "$PIPER_DIR/piper"
    ok "Piper instalado"
fi

# ─── 4. Voz de Piper ────────────────────────────────────────────────────────
step "4/6  Selección de voz..."

mkdir -p "$PIPER_DIR/voces"

VOICES_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0"

echo ""
echo "  Voces disponibles en español:"
echo "  1) es_AR-daniela-high    — Femenina, argentina, alta calidad  (recomendada)"
echo "  2) es_ES-davefx-medium   — Masculina, española, calidad media"
echo "  3) es_MX-claude-high     — Masculina, mexicana, alta calidad"
echo "  4) Saltar (ya tengo una voz instalada)"
echo ""
read -rp "  Elige [1-4]: " voice_choice

case "$voice_choice" in
    1)
        VOICE_FILE="es_AR-daniela-high.onnx"
        VOICE_PATH="es/es_AR/daniela/high"
        ;;
    2)
        VOICE_FILE="es_ES-davefx-medium.onnx"
        VOICE_PATH="es/es_ES/davefx/medium"
        ;;
    3)
        VOICE_FILE="es_MX-claude-high.onnx"
        VOICE_PATH="es/es_MX/claude/high"
        ;;
    4)
        info "Saltando descarga de voz."
        VOICE_FILE=""
        ;;
    *)
        warn "Opción inválida, saltando descarga de voz."
        VOICE_FILE=""
        ;;
esac

if [ -n "$VOICE_FILE" ]; then
    if [ -f "$PIPER_DIR/voces/$VOICE_FILE" ]; then
        info "Voz ya descargada, salto."
    else
        info "Descargando $VOICE_FILE..."
        curl -L --progress-bar \
            "$VOICES_BASE/$VOICE_PATH/$VOICE_FILE" \
            -o "$PIPER_DIR/voces/$VOICE_FILE"
        curl -L --progress-bar \
            "$VOICES_BASE/$VOICE_PATH/$VOICE_FILE.json" \
            -o "$PIPER_DIR/voces/$VOICE_FILE.json"
        ok "Voz descargada"
    fi

    # Actualizar PIPER_VOICE en daemon.py
    sed -i "s|^PIPER_VOICE = .*|PIPER_VOICE = f\"{PIPER_DIR}/voces/$VOICE_FILE\"|" "$BASE/daemon.py"
    ok "daemon.py actualizado con la voz seleccionada"
fi

# ─── 5. Directorio de conversación de Claude ────────────────────────────────
step "5/6  Configurando directorio de conversación..."

mkdir -p "$CONV_DIR"
ok "Directorio $CONV_DIR listo"

if [ ! -f "$CONV_DIR/CLAUDE.md" ] && [ -f "$BASE/CLAUDE.md" ]; then
    cp "$BASE/CLAUDE.md" "$CONV_DIR/CLAUDE.md"
    ok "CLAUDE.md copiado a $CONV_DIR"
fi

# ─── 6. Hyprland ────────────────────────────────────────────────────────────
step "6/6  Configuración de Hyprland..."

HYPR_CONF="$HOME/.config/hypr/hyprland.conf"

if [ ! -f "$HYPR_CONF" ]; then
    warn "No encontré $HYPR_CONF — configura Hyprland manualmente (ver README)."
else
    # Autostart
    if grep -q "asistente-daemon" "$HYPR_CONF" 2>/dev/null; then
        info "Autostart ya configurado en hyprland.conf."
    else
        read -rp "  ¿Añadir autostart del daemon a hyprland.conf? [S/n] " yn
        if [[ ! "$yn" =~ ^[nN]$ ]]; then
            echo "" >> "$HYPR_CONF"
            echo "# Asistente de voz" >> "$HYPR_CONF"
            echo "exec-once = $BASE/asistente-daemon.sh" >> "$HYPR_CONF"
            ok "Autostart añadido a hyprland.conf"
        fi
    fi

    # Keybindings
    if grep -q "hablar.sh" "$HYPR_CONF" 2>/dev/null; then
        info "Atajos de teclado ya configurados en hyprland.conf."
    else
        read -rp "  ¿Añadir atajos SUPER+Q (push-to-talk) a hyprland.conf? [S/n] " yn
        if [[ ! "$yn" =~ ^[nN]$ ]]; then
            cat >> "$HYPR_CONF" << EOF

# Asistente de voz — push-to-talk
bind  = SUPER, Q, exec, $BASE/hablar.sh start
bindr = SUPER, Q, exec, $BASE/hablar.sh stop
EOF
            ok "Atajos SUPER+Q añadidos a hyprland.conf"
        fi
    fi
fi

# ─── Permisos ────────────────────────────────────────────────────────────────
chmod +x "$BASE/asistente-daemon.sh" "$BASE/hablar.sh" "$BASE/escritorio.sh"

# ─── Resumen ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}  Instalación completada.${RESET}"
echo ""
echo -e "  Arrancar el daemon:  ${BOLD}$BASE/asistente-daemon.sh${RESET}"
echo -e "  Parar el daemon:     ${BOLD}$BASE/hablar.sh quit${RESET}"
echo -e "  Push-to-talk:        ${BOLD}SUPER+Q${RESET} (si configuraste Hyprland)"
echo ""
echo -e "  Recuerda que ${BOLD}Claude Code debe estar autenticado${RESET} antes de usar el asistente."
echo -e "  Compruébalo con: ${BOLD}claude --version${RESET}"
echo ""

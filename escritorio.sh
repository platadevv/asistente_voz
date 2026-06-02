#!/usr/bin/env bash
# Helper de control de ventanas/escritorios para Hyprland 0.55 (Omarchy).
#
# Existe para que el asistente de voz NUNCA tenga que improvisar la sintaxis de
# 'hyprctl dispatch'. En Hyprland 0.55 los dispatchers son Lua y la forma antigua
# (movetoworkspace 2,class:steam) YA NO funciona: hay que pasar la llamada Lua
# completa como UN solo argumento, p.ej.:
#   hyprctl dispatch "hl.dsp.window.move({ workspace = \"2\" })"
#
# Subcomandos:
#   abrir   <cmd...>              Lanza una app desacoplada (vuelve al instante).
#   enfocar <patron> [cmd...]     Enfoca la app si existe; si no, la lanza.
#   mover   <patron> <N>          Mueve la ventana de esa app al escritorio N
#                                 SIN robar el foco (no molesta a lo que haces).
#   abrir-en <N> <patron> [cmd..] Lanza/enfoca la app y la deja en el escritorio N.
#   ir      <N>                   Cambia al escritorio N.
#   donde   <patron>              Dice en qué escritorio está la app (o "no abierta").
#
# <patron> casa contra class y title de la ventana (regex, sin distinguir mayus).
set -euo pipefail

# Devuelve el address (0x...) de la primera ventana cuyo class o title casa el patron.
_addr() {
  hyprctl clients -j | jq -r --arg p "$1" \
    '.[] | select((.class|test($p;"i")) or (.title|test($p;"i"))) | .address' | head -n1
}

cmd="${1:-}"; shift || true
case "$cmd" in
  abrir)
    [ $# -ge 1 ] || { echo "uso: escritorio.sh abrir <cmd...>" >&2; exit 2; }
    setsid -f "$@" >/dev/null 2>&1
    ;;
  enfocar)
    [ $# -ge 1 ] || { echo "uso: escritorio.sh enfocar <patron> [cmd...]" >&2; exit 2; }
    pat="$1"; shift || true
    if [ $# -ge 1 ]; then
      omarchy-launch-or-focus "$pat" "$*"
    else
      omarchy-launch-or-focus "$pat"
    fi
    ;;
  mover)
    [ $# -eq 2 ] || { echo "uso: escritorio.sh mover <patron> <N>" >&2; exit 2; }
    addr="$(_addr "$1")"
    [ -n "$addr" ] || { echo "no encuentro una ventana que case '$1'" >&2; exit 1; }
    hyprctl dispatch "hl.dsp.window.move({ window = \"address:$addr\", workspace = \"$2\", follow = false })"
    ;;
  abrir-en)
    [ $# -ge 2 ] || { echo "uso: escritorio.sh abrir-en <N> <patron> [cmd...]" >&2; exit 2; }
    ws="$1"; pat="$2"; shift 2 || true
    addr="$(_addr "$pat")"
    if [ -z "$addr" ]; then
      # No esta abierta: la lanzamos y esperamos a que aparezca la ventana.
      if [ $# -ge 1 ]; then setsid -f "$@" >/dev/null 2>&1; else setsid -f "$pat" >/dev/null 2>&1; fi
      for _ in $(seq 1 40); do        # hasta ~10s
        sleep 0.25
        addr="$(_addr "$pat")"
        [ -n "$addr" ] && break
      done
    fi
    [ -n "$addr" ] || { echo "la app no aparecio a tiempo" >&2; exit 1; }
    hyprctl dispatch "hl.dsp.window.move({ window = \"address:$addr\", workspace = \"$ws\", follow = false })"
    ;;
  ir)
    [ $# -eq 1 ] || { echo "uso: escritorio.sh ir <N>" >&2; exit 2; }
    hyprctl dispatch "hl.dsp.focus({ workspace = \"$1\" })"
    ;;
  donde)
    [ $# -eq 1 ] || { echo "uso: escritorio.sh donde <patron>" >&2; exit 2; }
    ws="$(hyprctl clients -j | jq -r --arg p "$1" \
      '.[] | select((.class|test($p;"i")) or (.title|test($p;"i"))) | .workspace.id' | head -n1)"
    [ -n "$ws" ] && echo "$ws" || echo "no abierta"
    ;;
  *)
    echo "subcomando desconocido: '$cmd'. Usa: abrir|enfocar|mover|abrir-en|ir|donde" >&2
    exit 2
    ;;
esac

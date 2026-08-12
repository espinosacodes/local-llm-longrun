#!/bin/bash
# Mantiene el modelo local residente Y SANO.
#
# Con OLLAMA_KEEP_ALIVE=-1 el modelo ya no se descarga solo. Este script cubre
# los dos fallos que sí ocurren:
#   1) arranque en frio (login, reinicio de ollama, crash) -> precarga
#   2) runner "zombi": si Metal se queda sin memoria de GPU, ollama sigue
#      respondiendo HTTP 200 pero con el cuerpo VACIO (eval_count 0) para
#      siempre. Desde fuera parece que el agente "no hace nada". Aqui se
#      detecta y se mata el runner para que ollama lo recree limpio.

MODEL="${QWEN_MODEL:-qwen35-code:latest}"
HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
LOG="$HOME/.qwen-local/logs/keeper.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG"; }

curl -sf --max-time 5 "$HOST/api/version" >/dev/null 2>&1 || { log "ollama no responde"; exit 0; }

preload() {
  local start; start=$(date +%s)
  curl -sf --max-time 300 "$HOST/api/chat" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"messages\":[],\"keep_alive\":-1}" >/dev/null 2>&1
  log "$MODEL residente en $(( $(date +%s) - start ))s"
}

# ¿genera de verdad? (no basta con que /api/ps lo liste)
generates() {
  curl -sf --max-time 120 "$HOST/api/chat" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"stream\":false,\"think\":false,\"keep_alive\":-1,\"options\":{\"num_predict\":4}}" \
    2>/dev/null | grep -q '"eval_count":[1-9]'
}

# Servidores ollama duplicados: la Ollama.app levanta el suyo ademas del de
# launchd, y cada uno carga SU PROPIA copia del modelo (2 x 12 GB en 24 GB de
# RAM). El sistema entra en swap, Metal se queda sin memoria de GPU y el runner
# muere en cada decode. Es la causa #1 de zombis recurrentes.
SERVERS=$(pgrep -f "ollama serve" | wc -l | tr -d ' ')
if [ "$SERVERS" -gt 1 ]; then
  log "AVISO: $SERVERS servidores ollama activos (probable Ollama.app). Cierrala desde la barra de menu; dejo solo el mas antiguo."
  # el mas nuevo suele ser el intruso de la app
  pgrep -f "ollama serve" | tail -n +2 | while read -r pid; do kill "$pid" 2>/dev/null; done
  sleep 2
fi
RUNNERS=$(pgrep -f "llama-server" | wc -l | tr -d ' ')
if [ "$RUNNERS" -gt 1 ]; then
  log "AVISO: $RUNNERS runners llama-server (modelo cargado por duplicado) — matando extras"
  pkill -9 -f llama-server 2>/dev/null; sleep 3
fi

if ! curl -sf --max-time 5 "$HOST/api/ps" 2>/dev/null | grep -q "\"$MODEL\""; then
  log "modelo frio, precargando"
  preload
fi

if ! generates; then
  log "RUNNER ZOMBI (respuesta vacia) — reiniciando runner"
  pkill -9 -f llama-server 2>/dev/null
  sleep 3
  preload
  if generates; then log "recuperado"; else log "SIGUE ROTO: mira ~/.ollama/logs/server.log (busca OutOfMemory)"; fi
fi

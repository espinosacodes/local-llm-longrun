#!/bin/bash
# Instalador. macOS + Apple Silicon + ollama.
#
#   ./install.sh                                   # usa los valores por defecto
#   BASE_MODEL=tu/modelo:IQ2_M ./install.sh        # otro modelo base
#   MODEL_NAME=mi-code NUM_CTX=32768 ./install.sh
#
# No toca nada destructivo sin avisar: hace copia de seguridad del plist de
# ollama antes de reemplazarlo.

set -euo pipefail

BASE_MODEL="${BASE_MODEL:-fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:IQ2_M}"
MODEL_NAME="${MODEL_NAME:-qwen35-code}"
NUM_CTX="${NUM_CTX:-40960}"
STATE="$HOME/.qwen-local"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LA="$HOME/Library/LaunchAgents"

bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; yel=$'\033[33m'; off=$'\033[0m'
step() { echo "${bold}==>${off} $*"; }
warn() { echo "${yel}!${off} $*"; }

[ "$(uname)" = "Darwin" ] || { echo "Este instalador es para macOS."; exit 1; }
command -v ollama   >/dev/null || { echo "Falta ollama: https://ollama.com/download"; exit 1; }
command -v opencode >/dev/null || warn "Falta opencode (brew install sst/tap/opencode). 'qw' funciona igual; 'qtask' no."

mkdir -p "$STATE/logs" "$HOME/.local/bin"

# --- 1. binarios ------------------------------------------------------------
step "instalando qw y qtask en ~/.local/bin"
install -m 755 "$REPO/bin/qw"    "$HOME/.local/bin/qw"
install -m 755 "$REPO/bin/qtask" "$HOME/.local/bin/qtask"
install -m 755 "$REPO/ollama/keeper.sh" "$STATE/keeper.sh"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) warn "~/.local/bin no esta en tu PATH. Anade a ~/.zshrc:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# --- 2. modelo afinado ------------------------------------------------------
step "creando el modelo $MODEL_NAME (ctx $NUM_CTX) sobre $BASE_MODEL"
if ! ollama list | grep -q "^${BASE_MODEL%%:*}"; then
  warn "el modelo base no esta descargado; bajandolo (puede tardar)"
  ollama pull "$BASE_MODEL"
fi
sed -e "s|__BASE_MODEL__|$BASE_MODEL|" -e "s|__NUM_CTX__|$NUM_CTX|" \
    "$REPO/ollama/Modelfile.code" > "$STATE/Modelfile.code"
ollama create "$MODEL_NAME" -f "$STATE/Modelfile.code" >/dev/null
echo "   ${grn}ok${off} — derivar un modelo no duplica el disco: reusa el mismo blob"

# --- 3. ollama como servicio, con el modelo pinneado ------------------------
step "configurando ollama para que mantenga el modelo en memoria"
OLLAMA_BIN="$(command -v ollama)"
[ -x "/Applications/Ollama.app/Contents/Resources/ollama" ] && \
  OLLAMA_BIN="/Applications/Ollama.app/Contents/Resources/ollama"

if [ -f "$LA/ai.ollama.ollama.plist" ] && [ ! -f "$STATE/ai.ollama.ollama.plist.bak" ]; then
  cp "$LA/ai.ollama.ollama.plist" "$STATE/ai.ollama.ollama.plist.bak"
  echo "   copia de seguridad en $STATE/ai.ollama.ollama.plist.bak"
fi
sed "s|__OLLAMA_BIN__|$OLLAMA_BIN|" "$REPO/launchd/ollama.plist.template" > "$LA/ai.ollama.ollama.plist"
plutil -lint "$LA/ai.ollama.ollama.plist" >/dev/null

# La Ollama.app levanta SU PROPIO servidor (en 0.0.0.0, expuesto a la LAN) y
# pelea por el puerto con este. Solo puede mandar uno.
if pgrep -f "Ollama.app/Contents/MacOS" >/dev/null 2>&1; then
  warn "cerrando Ollama.app: levanta un segundo servidor en 0.0.0.0 y entra en conflicto"
  osascript -e 'quit app "Ollama"' 2>/dev/null || true
  sleep 2
fi
launchctl bootout "gui/$(id -u)/ai.ollama.ollama" 2>/dev/null || true
sleep 1; pkill -9 -f llama-server 2>/dev/null || true; sleep 2
launchctl bootstrap "gui/$(id -u)" "$LA/ai.ollama.ollama.plist"
for _ in $(seq 1 25); do
  curl -sf --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
  sleep 2
done

# --- 4. keeper --------------------------------------------------------------
step "instalando el keeper (precarga + deteccion de runner zombi)"
sed -e "s|__HOME__|$HOME|g" -e "s|__MODEL__|$MODEL_NAME:latest|" \
    "$REPO/launchd/keeper.plist.template" > "$LA/local.qwen.keeper.plist"
plutil -lint "$LA/local.qwen.keeper.plist" >/dev/null
launchctl bootout "gui/$(id -u)/local.qwen.keeper" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$LA/local.qwen.keeper.plist"

# --- 5. opencode ------------------------------------------------------------
if command -v opencode >/dev/null; then
  step "configurando opencode"
  mkdir -p "$HOME/.config/opencode/agent"
  sed "s|qwen35-code:latest|$MODEL_NAME:latest|g" "$REPO/opencode/agent-local.md" \
    > "$HOME/.config/opencode/agent/local.md"
  CFG="$HOME/.config/opencode/opencode.jsonc"
  if [ -f "$CFG" ] && grep -q "local-ollama" "$CFG"; then
    echo "   ya tienes el proveedor local-ollama, no lo toco"
  elif [ -f "$CFG" ]; then
    warn "anade a mano el bloque de opencode/provider-snippet.jsonc dentro de \"provider\" en $CFG"
  else
    python3 - "$CFG" "$MODEL_NAME" "$NUM_CTX" <<'PY'
import json, sys
cfg, model, ctx = sys.argv[1], sys.argv[2], int(sys.argv[3])
json.dump({
    "$schema": "https://opencode.ai/config.json",
    "provider": {"local-ollama": {
        "npm": "@ai-sdk/openai-compatible",
        "name": "Ollama (local)",
        "options": {"baseURL": "http://localhost:11434/v1", "apiKey": "ollama"},
        "models": {f"{model}:latest": {
            "name": f"{model} (local)", "tool_call": True, "reasoning": True,
            "limit": {"context": ctx, "output": 8192},
            "options": {"temperature": 0.15, "topP": 0.8}}}}},
}, open(cfg, "w"), indent=2)
print("   config de opencode creada")
PY
  fi
fi

# --- 6. precarga + verificacion --------------------------------------------
step "cargando el modelo en memoria (la primera vez tarda)"
QWEN_MODEL="$MODEL_NAME:latest" bash "$STATE/keeper.sh"

echo
if curl -sf --max-time 120 http://127.0.0.1:11434/api/chat \
     -d "{\"model\":\"$MODEL_NAME:latest\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"stream\":false,\"think\":false,\"options\":{\"num_predict\":4}}" \
     2>/dev/null | grep -q '"eval_count":[1-9]'; then
  echo "${grn}Listo.${off} El modelo genera y se queda residente."
else
  warn "el modelo NO genera. Casi siempre es memoria de GPU: prueba un quant mas"
  warn "pequeno o un NUM_CTX menor. Diagnostico:  qtask doctor"
fi

cat <<EOF

  ${dim}qw "una pregunta"                 chat rapido
  qtask "arregla los tests"        agente con herramientas
  qtask serve                      servidor persistente (tareas 4x mas rapidas)
  qtask status | doctor | unload   estado, reparar, liberar RAM${off}

EOF

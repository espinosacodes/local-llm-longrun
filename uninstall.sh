#!/bin/bash
# Deja la maquina como estaba. No borra modelos de ollama salvo que lo pidas.
set -uo pipefail

STATE="$HOME/.qwen-local"
LA="$HOME/Library/LaunchAgents"
U="$(id -u)"

echo "==> deteniendo servicios"
launchctl bootout "gui/$U/local.opencode.server" 2>/dev/null
launchctl bootout "gui/$U/local.qwen.keeper" 2>/dev/null
rm -f "$LA/local.opencode.server.plist" "$LA/local.qwen.keeper.plist"

echo "==> restaurando el plist de ollama"
if [ -f "$STATE/ai.ollama.ollama.plist.bak" ]; then
  cp "$STATE/ai.ollama.ollama.plist.bak" "$LA/ai.ollama.ollama.plist"
  launchctl kickstart -k "gui/$U/ai.ollama.ollama" 2>/dev/null
else
  echo "   (no habia copia de seguridad; lo dejo como esta)"
fi

echo "==> quitando binarios"
rm -f "$HOME/.local/bin/qw" "$HOME/.local/bin/qtask"

echo
echo "Sin tocar (borralos tu si quieres):"
echo "  $STATE                              estado y logs"
echo "  ~/.config/opencode/agent/local.md   agente de opencode"
echo "  el bloque local-ollama de ~/.config/opencode/opencode.jsonc"
echo "  el modelo:  ollama rm ${MODEL_NAME:-qwen35-code}"

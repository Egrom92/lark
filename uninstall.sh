#!/bin/bash
# Удаляет Lark и его настройки:
#   curl -fsSL https://raw.githubusercontent.com/Egrom92/lark/main/uninstall.sh | bash
set -euo pipefail
for app in "/Applications/Lark.app" "$HOME/Applications/Lark.app"; do
  if [ -d "$app" ]; then
    pkill -x Lark 2>/dev/null || true
    open -n -W "$app" --args --unregister-login >/dev/null 2>&1 || true
    rm -rf "$app"
  fi
done
defaults delete local.lark >/dev/null 2>&1 || true
echo "✓ Lark удалён."

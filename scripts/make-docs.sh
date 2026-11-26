#!/bin/bash
# Картинки для README и сайта: снимки настоящей панели (scripts/shots.swift) → карточки в стиле других программ
# (scripts/docs/*.html) → docs/*.png через Chrome без окна.
#   ./scripts/make-docs.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/shots
mkdir -p build/shotsrc
mkdir -p "$OUT" docs
# Приложение без запуска: последний блок main.swift (запуск) заменяем на shots.swift
python3 - <<'PY'
s = open('Sources/main.swift').read()
i = s.rindex('MainActor.assumeIsolated {\n    let app')
open('build/shotsrc/main.swift', 'w').write(s[:i] + open('scripts/shots.swift').read())
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.2" -o build/LarkShots $(ls Sources/*.swift | grep -v main.swift) build/shotsrc/main.swift
./build/LarkShots "$OUT"
cp docs/icon.png "$OUT/icon.png"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE=$(mktemp -d)
cp scripts/docs/card.css "$OUT/"
for f in scripts/docs/*.html; do
    name=$(basename "$f" .html)
    size=$(grep -o 'data-size="[0-9]*,[0-9]*"' "$f" | grep -o '[0-9]*,[0-9]*')
    cp "$f" "$OUT/$name.html"
    "$CHROME" --headless=new --user-data-dir="$PROFILE" --hide-scrollbars --force-device-scale-factor=1 \
        --window-size="$size" --screenshot="$PWD/docs/$name.png" "file://$PWD/$OUT/$name.html" >/dev/null 2>&1
    echo "docs/$name.png"
done
rm -rf "$PROFILE"

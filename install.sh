#!/bin/bash
# Установка или обновление Lark одной командой (настройки при обновлении сохраняются):
#   curl -fsSL https://raw.githubusercontent.com/Egrom92/lark/main/install.sh | bash
# или из скачанной папки:  ./install.sh
set -euo pipefail

REPO="Egrom92/lark"
say() { printf '\n\033[1m▶︎ %s\033[0m\n' "$*"; }
die() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Lark работает только на macOS."
ver=$(sw_vers -productVersion)
major=${ver%%.*}; rest=${ver#*.}; minor=${rest%%.*}
[ "$major" -gt 14 ] || { [ "$major" -eq 14 ] && [ "${minor:-0}" -ge 2 ]; } || die "Нужна macOS 14.2 Sonoma или новее (у вас $ver)."

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    say "Нужны бесплатные инструменты разработчика Apple (Command Line Tools)"
    echo "Сейчас откроется окно установки: нажмите «Установить», дождитесь окончания"
    echo "(5–15 минут) и запустите эту же команду ещё раз."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

# Исходники: из этой папки или свежие с GitHub
self="${BASH_SOURCE[0]:-}"
if [ -n "$self" ] && [ -f "$(dirname "$self")/Sources/main.swift" ] && [ -f "$(dirname "$self")/Resources/AppIcon.icns" ]; then
    cd "$(dirname "$self")"
else
    say "Скачиваю Lark с GitHub"
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/lark.XXXXXX")
    trap 'rm -rf "$TMP"' EXIT
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$TMP" \
        || die "Не удалось скачать https://github.com/$REPO. Проверьте интернет."
    cd "$TMP/lark-main"
fi

DEST=/Applications
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"   # у обычного (не администратора) пользователя нет прав на /Applications
    mkdir -p "$DEST"
fi
APP="$DEST/Lark.app"
BUILD=build/Lark.app
arch=$(uname -m)

say "Собираю Lark (первый раз около минуты)"
rm -rf "$BUILD"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
swiftc -O -swift-version 5 -target "$arch-apple-macos14.2" -o "$BUILD/Contents/MacOS/Lark" Sources/*.swift \
    || die "Сборка не удалась. Обновите Command Line Tools (Системные настройки → Основные → Обновление ПО) и попробуйте снова."
cp Resources/AppIcon.icns "$BUILD/Contents/Resources/AppIcon.icns"
VERSION=$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 2.1)

# Тексты запросов разрешений на языке macOS
strings() { # язык, про Apple Events, про системный звук
    mkdir -p "$BUILD/Contents/Resources/$1.lproj"
    printf '"NSAppleEventsUsageDescription" = "%s";\n"NSAudioCaptureUsageDescription" = "%s";\n' "$2" "$3" \
        > "$BUILD/Contents/Resources/$1.lproj/InfoPlist.strings"
}
strings en "Lark shows what is playing in Spotify, Music and browser tabs, and pauses it." \
    "Lark changes the volume of individual apps (for example Zoom or Telegram) and mutes them. Nothing is recorded."
strings ru "Lark показывает, что играет в Spotify, Музыке и вкладках браузера, и ставит это на паузу." \
    "Lark меняет громкость отдельных программ (например, Zoom или Telegram) и выключает их звук. Ничего не записывается."
strings et "Lark näitab, mis mängib Spotifys, Muusikas ja brauseri vahekaartidel, ning paneb selle pausile." \
    "Lark muudab üksikute programmide (näiteks Zoomi või Telegrami) helitugevust ja vaigistab neid. Midagi ei salvestata."

cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>local.lark</string>
    <key>CFBundleName</key><string>Lark</string>
    <key>CFBundleDisplayName</key><string>Lark</string>
    <key>CFBundleExecutable</key><string>Lark</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleVersion</key><string>__VERSION__</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string><string>et</string></array>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Lark shows what is playing in Spotify, Music and browser tabs, and pauses it.</string>
    <key>NSAudioCaptureUsageDescription</key><string>Lark changes the volume of individual apps (for example Zoom or Telegram) and mutes them. Nothing is recorded.</string>
    <key>NSHumanReadableCopyright</key><string>Roman Egliens</string>
</dict></plist>
PLIST
sed -i '' "s/__VERSION__/$VERSION/g" "$BUILD/Contents/Info.plist"

# Постоянная подпись: разрешения macOS (управлять Chrome/Spotify, системный звук) привязаны к ней,
# поэтому после обновления Lark не будет спрашивать их заново.
./scripts/setup-signing.sh >/dev/null 2>&1 || true
if security find-identity -p codesigning 2>/dev/null | grep -q "Lark Local Signing"; then
    security unlock-keychain -p lark-local-signing "$HOME/Library/Keychains/lark-signing.keychain-db" 2>/dev/null || true
    codesign --force --sign "Lark Local Signing" --identifier local.lark "$BUILD" 2>/dev/null \
        || codesign --force --sign - "$BUILD" 2>/dev/null
else
    codesign --force --sign - "$BUILD" 2>/dev/null
fi

say "Ставлю в $APP"
pkill -x Lark 2>/dev/null || true
sleep 0.5
rm -rf "$APP"
ditto "$BUILD" "$APP"
open "$APP"

cat <<'DONE'

✅ Готово: значок «колонка и микрофон» в строке меню.
  • Щелчок по значку — панель: слева куда идёт звук, справа какой микрофон, ниже — что сейчас играет.
  • У трека или вкладки — пауза, перемотка и своя громкость; у Zoom, Telegram и других — громкость и «без звука».
  • «＋ Запомнить» — набор «выход + микрофон», включается кнопкой или ⌃⌥1…9.
  • Колесо мыши над значком — громкость. «Держать» — не давать Mac переключаться на AirPods самому.
  • Шестерёнка внизу — язык (русский, English, eesti), автозапуск, обновления и выход.
Lark сам запускается при входе в систему. Обновить — запустить эту же команду ещё раз.
Удалить: curl -fsSL https://raw.githubusercontent.com/Egrom92/lark/main/uninstall.sh | bash
DONE

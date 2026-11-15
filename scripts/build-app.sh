#!/bin/bash
# Сборка HF Selcall.app. Нужны Xcode или Command Line Tools (xcode-select --install).
#   ./scripts/build-app.sh            — сборка под архитектуру этого Mac
#   UNIVERSAL=1 ./scripts/build-app.sh — arm64 + x86_64 (нужен полный Xcode)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="HF Selcall"
BUNDLE_ID="com.ra4pvj.hfselcall"
VERSION="$(tr -d ' \r\n' < VERSION 2>/dev/null || echo 0.1)"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
    ARCH_FLAGS=()
fi

echo "==> swift build (release)"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> самопроверка кодека"
"$BIN/selcall-cli" selftest

APP="build/$APP_NAME.app"
echo "==> сборка $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HFSelcall" "$APP/Contents/MacOS/HFSelcall"
cp "$BIN/selcall-cli" "build/selcall-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>HFSelcall</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Нужен доступ к звуковому входу, чтобы принимать сигналы трансивера.</string>
</dict>
</plist>
PLIST

echo "==> подпись (ad-hoc)"
codesign --force --sign - "$APP"

(cd build && rm -f "HFSelcall.zip" && ditto -c -k --keepParent "$APP_NAME.app" "HFSelcall.zip")
echo
echo "Готово: build/$APP_NAME.app  (архив: build/HFSelcall.zip)"
echo "Запуск: open \"build/$APP_NAME.app\""

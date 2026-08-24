#!/bin/bash
set -e
cd "$(dirname "$0")"
APP="AttentionTimer.app"
BIN="$APP/Contents/MacOS/AttentionTimer"

# 실행 중이면 먼저 종료 (실행 중인 번들을 지우면 프로세스가 죽는다)
pkill -f "AttentionTimer.app/Contents/MacOS/AttentionTimer" 2>/dev/null && sleep 1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ compiling..."
swiftc -O -swift-version 5 src/main.swift -o "$BIN" -framework AppKit

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>AttentionTimer</string>
  <key>CFBundleDisplayName</key>       <string>AttentionTimer</string>
  <key>CFBundleIdentifier</key>        <string>com.gubukson.attentiontimer</string>
  <key>CFBundleExecutable</key>        <string>AttentionTimer</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>집중 시간 동안 브라우저에 열린 탭 주소를 확인해 딴짓 여부만 판단합니다. 주소는 어디에도 전송되지 않고 로컬에서만 비교됩니다.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# /Applications 에 설치돼 있으면 거기도 같이 갱신
if [ -d "/Applications/AttentionTimer.app" ]; then
  rm -rf "/Applications/AttentionTimer.app"
  cp -R "$APP" /Applications/
  echo "▸ /Applications 사본도 갱신함"
fi

echo "▸ done → $(pwd)/$APP"

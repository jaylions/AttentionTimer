#!/bin/bash
# AttentionTimer.app 을 /Applications 로 옮긴다.
# 이후 Launchpad / Spotlight / 더블클릭으로 실행 가능하고,
# ./build.sh 를 다시 돌리면 /Applications 사본도 자동으로 같이 갱신된다.
set -e
cd "$(dirname "$0")"
[ -d AttentionTimer.app ] || ./build.sh
pkill -f "AttentionTimer.app/Contents/MacOS/AttentionTimer" 2>/dev/null && sleep 1
rm -rf /Applications/AttentionTimer.app
cp -R AttentionTimer.app /Applications/
echo "▸ 설치 완료 → /Applications/AttentionTimer.app"
open /Applications/AttentionTimer.app
echo "▸ 실행함. 메뉴바 오른쪽 '◷' 아이콘 확인."

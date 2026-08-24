#!/bin/bash
# 지금 실행 중인 앱들의 번들 ID를 뽑아준다.
# 여기서 골라서 ~/.attentiontimer/config.json 의 distractionApps 에 넣으면 됨.
osascript -e 'tell application "System Events" to get {name, bundle identifier} of every application process whose background only is false' \
| tr ',' '\n' | sed 's/^ //' | paste -d'\t' - /dev/null | awk 'NF' | sort -u

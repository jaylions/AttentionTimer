#!/bin/bash
cd "$(dirname "$0")"
[ -d AttentionTimer.app ] || ./build.sh
pkill -f "AttentionTimer.app/Contents/MacOS/AttentionTimer" 2>/dev/null && sleep 1
open AttentionTimer.app

#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT="${SCRIPT_DIR:h}"
readonly APP="${1:-$ROOT/build/official/SnapFlow.app}"

[[ -d "$APP" ]] || { echo "アプリが見つかりません: $APP" >&2; exit 1; }
echo "Path: $APP"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
/usr/bin/codesign -dvvv "$APP" 2>&1 | /usr/bin/grep -E 'Identifier=|Authority=|TeamIdentifier=|Runtime Version|flags=' || true
/usr/bin/codesign -d -r- "$APP" 2>&1 | /usr/bin/sed -n '/designated =>/p'

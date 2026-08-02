#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT="${SCRIPT_DIR:h}"
readonly INSTALL_DIR="$HOME/Applications"
readonly TARGET="$INSTALL_DIR/SnapFlow Community.app"
readonly STAGED="$ROOT/build/community/SnapFlow Community.app"

fail() {
  echo "エラー: $1" >&2
  exit 1
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "インストールはmacOS上で実行してください。"
if /usr/bin/pgrep -x SnapFlow >/dev/null; then
  fail "起動中のSnapFlowを終了してから再実行してください。"
fi

"$SCRIPT_DIR/build-community.sh"
/bin/mkdir -p "$INSTALL_DIR"
readonly TEMP_DIR="$(/usr/bin/mktemp -d "$INSTALL_DIR/.snapflow-community.XXXXXX")"
trap '/bin/rm -rf "$TEMP_DIR"' EXIT INT TERM
readonly TEMP_APP="$TEMP_DIR/SnapFlow Community.app"
/usr/bin/ditto "$STAGED" "$TEMP_APP"
/usr/bin/codesign --verify --strict --verbose=2 "$TEMP_APP"

readonly BACKUP="$TEMP_DIR/previous.app"
if [[ -e "$TARGET" ]]; then
  /bin/mv "$TARGET" "$BACKUP"
fi
if /bin/mv "$TEMP_APP" "$TARGET"; then
  /bin/rm -rf "$BACKUP"
else
  [[ -e "$BACKUP" ]] && /bin/mv "$BACKUP" "$TARGET"
  fail "インストールに失敗したため以前のアプリを復元しました。"
fi

/usr/bin/open "$TARGET"
echo "Community版をインストールしました: $TARGET"

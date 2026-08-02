#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT="${SCRIPT_DIR:h}"
readonly EDITION="${1:-}"
readonly VERSION_FILE="$ROOT/VERSION"
readonly BUILD_NUMBER_FILE="$ROOT/BUILD_NUMBER"
readonly OFFICIAL_CONFIG="$ROOT/Config/OfficialSigning.plist"

fail() {
  echo "エラー: $1" >&2
  exit 1
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "SnapFlowはmacOS上でビルドしてください。"
[[ -f "$ROOT/Package.swift" ]] || fail "プロジェクトルートを確認できません。"
[[ "$EDITION" == "community" || "$EDITION" == "official" ]] || \
  fail "build-app.shにはcommunityまたはofficialを指定してください。"
[[ -f "$VERSION_FILE" && -f "$BUILD_NUMBER_FILE" ]] || fail "バージョンファイルがありません。"

readonly VERSION="$(/usr/bin/tr -d '[:space:]' < "$VERSION_FILE")"
readonly BUILD_NUMBER="$(/usr/bin/tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$' ]] || fail "VERSIONの形式が不正です。"
[[ "$BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] || fail "BUILD_NUMBERは1以上の整数にしてください。"

if [[ "$EDITION" == "official" ]]; then
  readonly APP_NAME="SnapFlow"
  readonly DISPLAY_NAME="SnapFlow"
  readonly BUNDLE_ID="dev.pent.SnapFlow"
  readonly OUTPUT_DIR="$ROOT/build/official"
else
  readonly APP_NAME="SnapFlow Community"
  readonly DISPLAY_NAME="SnapFlow Community"
  readonly BUNDLE_ID="dev.pent.SnapFlow.community"
  readonly OUTPUT_DIR="$ROOT/build/community"
fi

readonly APP="$OUTPUT_DIR/$APP_NAME.app"
readonly INFO_PLIST="$APP/Contents/Info.plist"
readonly SWIFT_BIN="$(/usr/bin/xcrun --find swift)"
[[ -x "$SWIFT_BIN" ]] || fail "Swiftツールチェーンが見つかりません。"

SOURCE_REVISION="unversioned"
if /usr/bin/git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if SOURCE_REVISION_CANDIDATE="$(/usr/bin/git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null)"; then
    SOURCE_REVISION="$SOURCE_REVISION_CANDIDATE"
  fi
fi
[[ "$SOURCE_REVISION" == "unversioned" || "$SOURCE_REVISION" =~ '^[0-9a-f]{40}$' ]] || \
  fail "ソースリビジョンを検証できません。"
readonly SOURCE_REVISION

echo "Building SnapFlow $VERSION ($EDITION)..."
cd "$ROOT"
"$SWIFT_BIN" package clean
typeset -a SWIFT_BUILD_ARGS
SWIFT_BUILD_ARGS=(-c release)
if [[ "$EDITION" == "official" ]]; then
  SWIFT_BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
"$SWIFT_BIN" build "${SWIFT_BUILD_ARGS[@]}"

readonly BIN_DIR="$("$SWIFT_BIN" build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
readonly BIN="$BIN_DIR/SnapFlow"
[[ -f "$BIN" ]] || fail "ビルド済み実行ファイルが見つかりません。"

case "$APP" in
  "$ROOT"/build/*) ;;
  *) fail "安全でない出力先を拒否しました。" ;;
esac

/bin/rm -rf "$OUTPUT_DIR"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp "$BIN" "$APP/Contents/MacOS/SnapFlow"

/usr/bin/plutil -create xml1 "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleName -string "$DISPLAY_NAME" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleDisplayName -string "$DISPLAY_NAME" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleExecutable -string SnapFlow "$INFO_PLIST"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 13.0 "$INFO_PLIST"
/usr/bin/plutil -insert LSUIElement -bool YES "$INFO_PLIST"
/usr/bin/plutil -insert LSMultipleInstancesProhibited -bool YES "$INFO_PLIST"
/usr/bin/plutil -insert NSHighResolutionCapable -bool YES "$INFO_PLIST"
/usr/bin/plutil -insert NSSupportsAutomaticGraphicsSwitching -bool YES "$INFO_PLIST"
/usr/bin/plutil -insert NSSupportsSuddenTermination -bool YES "$INFO_PLIST"
/usr/bin/plutil -insert NSAccessibilityUsageDescription -string \
  "ウィンドウを移動・サイズ変更してスナップ配置するために使用します。" "$INFO_PLIST"
/usr/bin/plutil -insert NSScreenCaptureUsageDescription -string \
  "利用者が有効にした場合に、配置候補のプレビュー画像を表示するために使用します。" "$INFO_PLIST"
/usr/bin/plutil -insert SnapFlowEdition -string "$EDITION" "$INFO_PLIST"
/usr/bin/plutil -insert SnapFlowSourceRevision -string "$SOURCE_REVISION" "$INFO_PLIST"

if [[ "$EDITION" == "official" ]]; then
  [[ -f "$OFFICIAL_CONFIG" ]] || fail "Config/OfficialSigning.plistがありません。"
  readonly CONFIG_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :BundleIdentifier' "$OFFICIAL_CONFIG")"
  readonly CERTIFICATE_SHA1="$(/usr/libexec/PlistBuddy -c 'Print :CertificateSHA1' "$OFFICIAL_CONFIG" | /usr/bin/tr '[:lower:]' '[:upper:]')"
  [[ "$CONFIG_BUNDLE_ID" == "$BUNDLE_ID" ]] || fail "公式Bundle ID設定が一致しません。"
  [[ "$CERTIFICATE_SHA1" =~ '^[0-9A-F]{40}$' ]] || fail "証明書SHA-1の形式が不正です。"
  [[ "$CERTIFICATE_SHA1" != "0000000000000000000000000000000000000000" ]] || \
    fail "公式署名証明書のSHA-1を設定してください。"
  /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "$CERTIFICATE_SHA1" >/dev/null || \
    fail "指定された公式署名秘密鍵をKeychainで利用できません。"

  readonly REQUIREMENTS_FILE="$OUTPUT_DIR/SnapFlow.requirements"
  /bin/echo "designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERTIFICATE_SHA1\"" > "$REQUIREMENTS_FILE"
  /usr/bin/codesign --force --options runtime --timestamp=none \
    --sign "$CERTIFICATE_SHA1" \
    --requirements "$REQUIREMENTS_FILE" \
    --identifier "$BUNDLE_ID" "$APP"
else
  /usr/bin/codesign --force --options runtime --timestamp=none \
    --sign - --identifier "$BUNDLE_ID" "$APP"
fi

/usr/bin/codesign --verify --strict --verbose=2 "$APP"
echo "完成: $APP"

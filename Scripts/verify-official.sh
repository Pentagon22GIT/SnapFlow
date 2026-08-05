#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT="${SCRIPT_DIR:h}"
readonly APP="${1:-$ROOT/build/official/SnapFlow.app}"
readonly CONFIG="$ROOT/Config/OfficialSigning.plist"

fail() {
  echo "検証失敗: $1" >&2
  exit 1
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "検証はmacOS上で実行してください。"
[[ -d "$APP" ]] || fail "SnapFlow.appが見つかりません: $APP"
[[ -f "$CONFIG" ]] || fail "公式署名設定がありません。"

readonly EXPECTED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :BundleIdentifier' "$CONFIG")"
readonly CERTIFICATE_SHA1="$(/usr/libexec/PlistBuddy -c 'Print :CertificateSHA1' "$CONFIG" | /usr/bin/tr '[:lower:]' '[:upper:]')"
[[ "$EXPECTED_BUNDLE_ID" == "dev.pent.SnapFlow" ]] || fail "想定外の公式Bundle IDです。"
[[ "$CERTIFICATE_SHA1" =~ '^[0-9A-F]{40}$' ]] || fail "証明書SHA-1の形式が不正です。"
[[ "$CERTIFICATE_SHA1" != "0000000000000000000000000000000000000000" ]] || fail "証明書SHA-1が未設定です。"

readonly ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
readonly ACTUAL_EDITION="$(/usr/libexec/PlistBuddy -c 'Print :SnapFlowEdition' "$APP/Contents/Info.plist")"
readonly ACTUAL_SOURCE_REVISION="$(/usr/libexec/PlistBuddy -c 'Print :SnapFlowSourceRevision' "$APP/Contents/Info.plist")"
readonly ACTUAL_SOURCE_DIRTY="$(/usr/libexec/PlistBuddy -c 'Print :SnapFlowSourceDirty' "$APP/Contents/Info.plist")"
[[ "$ACTUAL_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "Bundle IDが公式設定と一致しません。"
[[ "$ACTUAL_EDITION" == "official" ]] || fail "公式Editionではありません。"
[[ "$ACTUAL_SOURCE_REVISION" =~ '^[0-9a-f]{40}$' ]] || fail "公式版のソースリビジョンが不正です。"
[[ "$ACTUAL_SOURCE_DIRTY" == "false" ]] || fail "未コミットのソースから作成された公式版です。"

/usr/bin/codesign --verify --strict --verbose=4 "$APP"
/usr/bin/lipo "$APP/Contents/MacOS/SnapFlow" -verify_arch arm64 x86_64 || \
  fail "公式実行ファイルがUniversal 2（arm64/x86_64）ではありません。"
/usr/bin/codesign --verify --strict --verbose=4 \
  -R="identifier \"$EXPECTED_BUNDLE_ID\" and certificate leaf = H\"$CERTIFICATE_SHA1\"" "$APP"

readonly SIGNATURE_DETAILS="$(/usr/bin/codesign -dvvv "$APP" 2>&1)"
echo "$SIGNATURE_DETAILS" | /usr/bin/grep -E 'flags=.*runtime' >/dev/null || fail "Hardened Runtimeが有効ではありません。"

echo "公式署名を検証しました。"
echo "Path: $APP"
echo "Bundle ID: $ACTUAL_BUNDLE_ID"
echo "Certificate SHA-1: $CERTIFICATE_SHA1"
/usr/bin/codesign -d -r- "$APP" 2>&1 | /usr/bin/sed -n '/designated =>/p'

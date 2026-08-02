#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT="${SCRIPT_DIR:h}"
readonly VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT/VERSION")"
readonly EXPECTED_TAG="v$VERSION"
readonly RELEASE_DIR="$ROOT/release/$EXPECTED_TAG"
readonly APP="$ROOT/build/official/SnapFlow.app"
readonly ARCHIVE="$RELEASE_DIR/SnapFlow-$VERSION.zip"
readonly CHECKSUM_FILE="$RELEASE_DIR/SnapFlow-$VERSION.sha256"
readonly MANIFEST="$RELEASE_DIR/release-manifest.json"

fail() {
  echo "リリース作成失敗: $1" >&2
  exit 1
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "リリースはmacOS上で作成してください。"
/usr/bin/git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "Gitリポジトリではありません。"
[[ -z "$(/usr/bin/git -C "$ROOT" status --porcelain)" ]] || fail "未コミットまたは未追跡の変更があります。"
readonly CURRENT_TAG="$(/usr/bin/git -C "$ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
[[ "$CURRENT_TAG" == "$EXPECTED_TAG" ]] || fail "現在のコミットに$EXPECTED_TAGタグがありません。"
[[ "$(/usr/bin/git -C "$ROOT" cat-file -t "$EXPECTED_TAG")" == "tag" ]] || fail "軽量タグではなく署名付き注釈タグが必要です。"
/usr/bin/git -C "$ROOT" verify-tag "$EXPECTED_TAG" >/dev/null 2>&1 || fail "タグ署名を検証できません。"

"$SCRIPT_DIR/build-official.sh"
"$SCRIPT_DIR/verify-official.sh" "$APP"

/bin/rm -rf "$RELEASE_DIR"
/bin/mkdir -p "$RELEASE_DIR"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

readonly ARCHIVE_SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
readonly SOURCE_REVISION="$(/usr/bin/git -C "$ROOT" rev-parse HEAD)"
readonly CERTIFICATE_SHA1="$(/usr/libexec/PlistBuddy -c 'Print :CertificateSHA1' "$ROOT/Config/OfficialSigning.plist" | /usr/bin/tr '[:lower:]' '[:upper:]')"
echo "$ARCHIVE_SHA256  $(/usr/bin/basename "$ARCHIVE")" > "$CHECKSUM_FILE"

/usr/bin/plutil -create xml1 "$MANIFEST"
/usr/bin/plutil -insert version -string "$VERSION" "$MANIFEST"
/usr/bin/plutil -insert tag -string "$EXPECTED_TAG" "$MANIFEST"
/usr/bin/plutil -insert sourceCommit -string "$SOURCE_REVISION" "$MANIFEST"
/usr/bin/plutil -insert bundleIdentifier -string "dev.pent.SnapFlow" "$MANIFEST"
/usr/bin/plutil -insert architectures -json '["arm64","x86_64"]' "$MANIFEST"
/usr/bin/plutil -insert certificateSHA1 -string "$CERTIFICATE_SHA1" "$MANIFEST"
/usr/bin/plutil -insert archiveName -string "$(/usr/bin/basename "$ARCHIVE")" "$MANIFEST"
/usr/bin/plutil -insert archiveSHA256 -string "$ARCHIVE_SHA256" "$MANIFEST"
/usr/bin/plutil -convert json "$MANIFEST"
/usr/bin/plutil -p "$MANIFEST" >/dev/null

echo "Release assets: $RELEASE_DIR"
echo "SHA-256: $ARCHIVE_SHA256"

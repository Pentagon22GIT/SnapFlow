# Release Process

この文書は公式SnapFlow Releaseを作成する唯一の標準手順です。公開済みReleaseのファイルを同じバージョン名で差し替えません。

## バージョン規則

Semantic Versioningに従います。

- `1.0.1`: 後方互換のバグ・セキュリティ修正
- `1.1.0`: 後方互換の機能追加
- `2.0.0`: 互換性を壊す変更

`BUILD_NUMBER`はReleaseごとに必ず増加させます。`VERSION`と`BUILD_NUMBER`がアプリ、ZIP名、manifestの唯一の情報源です。

## Release前チェック

- [ ] `main`上にいる
- [ ] `git pull --ff-only origin main`済み
- [ ] `git status --porcelain`が空
- [ ] CI成功
- [ ] CodeQL成功
- [ ] DependabotとSecret scanningに未対応の重大警告がない
- [ ] `swift test`成功
- [ ] Community版を実機確認
- [ ] 公式署名証明書の秘密鍵がKeychainで利用可能
- [ ] 公式証明書SHA-1が公開設定と一致
- [ ] ReleaseノートとCHANGELOGを準備
- [ ] 権限、保存、通信、依存関係の変更を明記
- [ ] `SnapFlowSourceRevision`がRelease対象コミット、`SnapFlowSourceDirty`が`false`である

## ローカルでタグを作成する

例としてv1.0.0を作成します。この時点ではタグをGitHubへpushしません。

```zsh
git switch main
git pull --ff-only origin main
git status --short
git tag -s v1.0.0 -m "SnapFlow v1.0.0"
git verify-tag v1.0.0

test "$(git rev-parse HEAD)" = "$(git rev-parse 'v1.0.0^{commit}')" \
  && echo "タグは現在のmainを指しています"
```

タグ署名が正しく、タグが意図したmainのコミットを指していることを確認します。成果物の生成とローカル検証が完了するまでは、タグをGitHubへpushしません。

問題が見つかり、タグをまだGitHubへpushしていない場合は、ローカルタグを削除して修正後に作り直せます。

```zsh
git tag -d v1.0.0
```

## Release資産の生成

```zsh
./Scripts/package-release.sh
```

生成先は次です。

```text
release/v1.0.0/
├── SnapFlow-1.0.0.zip
├── SnapFlow-1.0.0.sha256
└── release-manifest.json
```

スクリプトは次を拒否します。

- Git管理外
- 未コミットまたは未追跡の変更
- HEADに正しいタグがない
- 公式証明書が利用できない
- 証明書指紋またはBundle IDが不一致
- Hardened Runtimeが無効
- 実行ファイルがUniversal 2（arm64／x86_64）ではない
- コード署名検証の失敗
- 公式アプリに記録されたソースリビジョンとRelease対象コミットの不一致

## 手動検証

```zsh
./Scripts/verify-official.sh build/official/SnapFlow.app
lipo -archs build/official/SnapFlow.app/Contents/MacOS/SnapFlow
plutil -p release/v1.0.0/release-manifest.json
plutil -extract SnapFlowSourceRevision raw -o - build/official/SnapFlow.app/Contents/Info.plist
plutil -extract SnapFlowSourceDirty raw -o - build/official/SnapFlow.app/Contents/Info.plist

(
  cd release/v1.0.0
  shasum -a 256 -c SnapFlow-1.0.0.sha256
)

checksum_hash="$(awk '{print $1}' \
  release/v1.0.0/SnapFlow-1.0.0.sha256)"
manifest_hash="$(plutil -extract archiveSHA256 raw -o - \
  release/v1.0.0/release-manifest.json)"
manifest_commit="$(plutil -extract sourceCommit raw -o - \
  release/v1.0.0/release-manifest.json)"

test "$checksum_hash" = "$manifest_hash" \
  && echo "SHA-256ファイルとmanifestは一致しています"

test "$manifest_commit" = "$(git rev-parse 'v1.0.0^{commit}')" \
  && echo "manifestとタグの対象コミットは一致しています"
```

さらに、Release ZIPを一時フォルダへ展開し、その中のアプリを検証します。

```zsh
release_check_dir="$(mktemp -d)"
ditto -x -k release/v1.0.0/SnapFlow-1.0.0.zip "$release_check_dir"
./Scripts/verify-official.sh "$release_check_dir/SnapFlow.app"
```

確認後、一時フォルダだけを削除します。

## タグをGitHubへ公開する

Release成果物、SHA-256、manifest、展開後のアプリ、コード署名、Designated Requirementの検証がすべて成功した場合だけ、タグをGitHubへpushします。

```zsh
git status --short
git verify-tag v1.0.0
git push origin v1.0.0
git ls-remote --tags origin refs/tags/v1.0.0
```

GitHubのTags画面で次を確認します。

- タグ`v1.0.0`が`Verified`と表示される
- タグが意図したmainのコミットを指している
- Release成果物の`release-manifest.json`に記録された`sourceCommit`と一致する

タグをGitHubへpushした後は、同じタグの付け替え、削除、成果物の黙った差し替えを行いません。問題が見つかった場合は、影響を明示してReleaseを取り下げ、新しいPatchバージョンで修正します。

## GitHub Release

1. GitHubの`Releases > Draft a new release`を開きます。
2. タグ`v1.0.0`を選びます。
3. タイトルを`SnapFlow v1.0.0`にします。
4. [v1.0.0 Releaseノート](RELEASE_NOTES_v1.0.0.md)を貼り付け、実際の内容と一致するよう最終確認します。
5. 3つの生成ファイルを添付します。
6. Releaseノートへ変更、権限、既知の制約、更新手順を記載します。
7. 初回はDraftのまま、添付ファイル名とタグを再確認します。
8. `Set as the latest release`を有効にして公開します。

GitHubが自動添付する`Source code (zip)`と`Source code (tar.gz)`がオープンソース配布、Maintainerが添付した`SnapFlow-1.0.0.zip`が公式セキュア版です。別のCommunityバイナリは公開しません。

## 公開後検証

ブラウザの別セッションでReleaseから3ファイルを再ダウンロードします。ローカルで作成したファイルではなく、実際に配布されているファイルを検証します。

- [ ] SHA-256一致
- [ ] ZIP展開成功
- [ ] コード署名とDR一致
- [ ] Bundle ID一致
- [ ] Version一致
- [ ] `arm64`と`x86_64`の両方を含む
- [ ] `releases/latest`が新Releaseへ移動
- [ ] 「更新を確認…」が正しいURLを開く
- [ ] 初回起動と権限案内を確認
- [ ] プレビュー初期OFFを確認

問題がある場合は、同じバージョンの資産を黙って差し替えません。影響があるReleaseを明示し、必要なら取り下げ、新しいPatchバージョンを作成します。

## セキュリティ修正

未公開の問題はGitHub Security Advisoryの非公開Forkで修正します。修正版が利用可能になる前に、悪用手順を公開Issueへ書きません。

通常は次の順序です。

```text
非公開報告
→ 影響確認
→ 修正とテスト
→ Patch Release
→ 利用者への更新案内
→ 必要な範囲で公開
```

## ロールバック

旧バージョンへの戻し方を案内する場合も、過去のRelease資産を変更しません。権限DBや設定形式が変わる更新では、単純なアプリ差し替えだけで戻せるかをReleaseノートに明示します。

## 鍵のローテーション

通常の都合で公式コード署名鍵を頻繁に変更しません。変更するとTCC本人性が変わり、再許可が必要です。

鍵漏えいまたは暗号方式上の理由で変更する場合は、旧鍵で署名できるうちに移行Releaseを出し、新旧指紋を明示します。旧鍵を使用できない場合は、旧権限をリセットし、新版へ明示的に再許可してもらいます。

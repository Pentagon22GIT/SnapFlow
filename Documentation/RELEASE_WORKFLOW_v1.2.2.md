# SnapFlow v1.2.2 Release Workflow

## 1. 修正適用とブランチ確認

この作業は`v1.2.1`から分岐した`fix/v1.2.2-active-window-foregrounding`で行います。

```zsh
cd "$HOME/Downloads/SnapFlow-Clean"
git branch --show-current
git status --short
git log -1 --oneline --decorate
```

修正ZIPをプロジェクトルートへ上書きした後、想定外のファイルが含まれていないことを確認します。

```zsh
git status --short
git diff --stat
git diff --check
git diff -- VERSION BUILD_NUMBER
```

`VERSION=1.2.2`、`BUILD_NUMBER=11`を維持します。v1.2.2はまだ公開前のため、この修正だけを理由にv1.2.3へ上げません。

## 2. 自動検査とCommunityビルド

```zsh
zsh -n Scripts/*.sh
swift test
./Scripts/build-community.sh
```

古いプロセスを終了し、今回のCommunity版だけを起動します。

```zsh
pkill -x SnapFlow 2>/dev/null || true
open "build/community/SnapFlow Community.app"

pgrep -x SnapFlow | while read pid; do
  ps -p "$pid" -o command=
done
```

`Documentation/VALIDATION_v1.2.2.md`の実機項目をすべて確認します。特に次をRelease必須条件とします。

- Mission Control選択後、追加クリックなしで接続相手が前面化する
- 同一アプリの非グループウィンドウを選択しても別グループを誤前面化しない
- 通常クリック、実ドラッグ、連動リサイズが退行していない
- 設定OFFで自動前面化しない
- 10分待機してCPU・メモリが継続増加しない
- すでに前面のグループで点滅や連続AXRaiseが発生しない

## 3. 署名コミット

コミットタイトル:

```text
Finalize selection-driven group foregrounding for v1.2.2
```

コミット説明:

```text
- detect the selected window from the frontmost PID and stable Window Server ID
- use AX notifications only to trigger selection settlement
- require three stable selection observations before resolving a connected group
- isolate Mission Control selection from the existing plain-click fallback
- revalidate PID, window ID, operation state, and current group before AXRaise
- keep the selected window frontmost and bound AXRaise verification to one retry
- reduce idle selection polling to the first matching Window Server record
- update v1.2.2 release, validation, privacy, security, and workflow records
```

実行:

```zsh
git add \
  Sources/SnapFlow/ActiveWindowObserver.swift \
  Sources/SnapFlow/AXWindowService.swift \
  Sources/SnapFlow/SnapController.swift \
  Sources/SnapFlow/SplitLayout.swift \
  Sources/SnapFlow/SettingsWindowController.swift \
  Tests/SnapFlowTests/SplitLayoutTests.swift \
  Documentation/RELEASE_NOTES_v1.2.2.md \
  Documentation/RELEASE_WORKFLOW_v1.2.2.md \
  Documentation/VALIDATION_v1.2.2.md \
  Documentation/PRIVACY.md \
  Documentation/SECURITY_AUDIT.md \
  Documentation/THREAT_MODEL.md \
  APPLY_v1.2.2_FOCUS_FIX.md \
  CHANGELOG.md README.md VERSION BUILD_NUMBER

git diff --cached --check
git diff --cached --stat

git commit -S \
  -m "Finalize selection-driven group foregrounding for v1.2.2" \
  -m "- detect the selected window from the frontmost PID and stable Window Server ID
- use AX notifications only to trigger selection settlement
- require three stable selection observations before resolving a connected group
- isolate Mission Control selection from the existing plain-click fallback
- revalidate PID, window ID, operation state, and current group before AXRaise
- keep the selected window frontmost and bound AXRaise verification to one retry
- reduce idle selection polling to the first matching Window Server record
- update v1.2.2 release, validation, privacy, security, and workflow records"

git status --short
git log -1 --show-signature --stat
```

署名表示で`Good "git" signature`を確認します。`gpg: No such file or directory`が出る場合は、SSH署名設定と`gpg.ssh.allowedSignersFile`を確認します。

## 4. PushとPull Request

```zsh
git push -u origin fix/v1.2.2-active-window-foregrounding
```

Pull Requestタイトル:

```text
Finalize window-selection group foregrounding for v1.2.2
```

Pull Request説明:

```markdown
## Summary
- detects the selected window from frontmost application PID and Window Server ordering
- settles the same PID and CGWindowID three times before resolving the connected group
- keeps AX notifications as signals instead of trusting main/focused AX identities
- separates Mission Control selection from the existing plain-click fallback
- keeps the selected window last in the bounded AXRaise sequence

## Safety
- revalidates frontmost PID and CGWindowID immediately before AXRaise
- raises only members of the current shared-boundary graph
- cancels stale generations when placement, drag, resize, Space, or SnapFlow UI state changes
- permits at most one verification retry
- adds no permission, dependency, network request, screen capture, persistent log, helper, or daemon

## Validation
- `git diff --check`
- `zsh -n Scripts/*.sh`
- `swift test`
- `./Scripts/build-community.sh`
- all mandatory checks in `Documentation/VALIDATION_v1.2.2.md`
```

GitHub Actionsの`build-and-test`が成功し、Files changedと実機結果を再確認してから`Squash and merge`します。

推奨Squashタイトル:

```text
Finalize selection-driven group foregrounding for v1.2.2
```

## 5. mainの確認と署名付きタグ

```zsh
git switch main
git pull --ff-only origin main
git status --short
git log -1 --show-signature --stat
cat VERSION
cat BUILD_NUMBER
```

作業ツリーが空で、`1.2.2`と`11`であることを確認してからタグを作成します。

```zsh
git tag -s v1.2.2 -m "SnapFlow v1.2.2"
git verify-tag v1.2.2
git show --show-signature --stat v1.2.2
git push origin v1.2.2
```

タグをpushする前に誤りを発見した場合だけ、ローカルタグを削除して修正します。公開済みタグとRelease assetは差し替えません。

## 6. 公式Release assets

タグと一致するクリーンな`main`で実行します。

```zsh
git status --short
git describe --tags --exact-match HEAD
./Scripts/package-release.sh
```

生成物と署名を確認します。

```zsh
find release/v1.2.2 -maxdepth 1 -type f -print | sort
shasum -a 256 -c release/v1.2.2/SnapFlow-1.2.2.sha256
./Scripts/verify-official.sh build/official/SnapFlow.app
codesign --verify --deep --strict --verbose=2 build/official/SnapFlow.app
```

GitHub Release:

- タイトル: `SnapFlow v1.2.2`
- 本文: `Documentation/RELEASE_NOTES_v1.2.2.md`
- `SnapFlow-1.2.2.zip`
- `SnapFlow-1.2.2.sha256`
- `release-manifest.json`

公開後はAssetsを新しいフォルダへ再ダウンロードし、次を再確認します。

```zsh
shasum -a 256 -c SnapFlow-1.2.2.sha256
unzip -q SnapFlow-1.2.2.zip -d verified-app
./Scripts/verify-official.sh "verified-app/SnapFlow.app"
```

最後に公開済みアプリで、通常クリック、Mission Control、同一アプリ切替、Space切替のスモークテストを行います。

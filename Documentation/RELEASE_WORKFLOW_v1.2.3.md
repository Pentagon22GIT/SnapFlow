# SnapFlow v1.2.3 Release Workflow

## 1. 適用

`v1.2.2`のクリーンな`main`から作業ブランチを作成し、置き換えZIPの内容をプロジェクトルートへ上書きします。

```zsh
git switch main
git pull --ff-only origin main
git switch -c fix/v1.2.3-monitoring-lifecycle
git status --short
```

適用後、`APPLY_v1.2.3_POWER_LIFECYCLE.md`の対象一覧と`git status --short`を照合します。

## 2. 自動検証

```zsh
git diff --check
zsh -n Scripts/*.sh
swift test
./Scripts/build-community.sh
```

続けて`Documentation/VALIDATION_v1.2.3.md`の実機項目を確認します。Timer停止・再開、Mission Control回帰、powermetrics再測定はRelease必須です。

## 3. CommitとPull Request

推奨Commitタイトル:

```text
Make selection monitoring lifecycle state-driven for v1.2.3
```

推奨説明:

```text
- run 10Hz Window Server selection polling only while its durable feature conditions are usable
- keep the existing 1Hz recovery timer unchanged as the selection lifecycle safety net
- reset baselines and pending selection work whenever polling stops
- keep v1.2.2 selection validation and bounded AXRaise behavior unchanged
- add lifecycle policy tests, validation, power audit, and release records
```

署名Commit、GitHub Actions成功、Files changed、実機結果を確認してからSquash and mergeします。

## 4. TagとRelease

mainへ反映後、`VERSION=1.2.3`、`BUILD_NUMBER=12`、空の作業ツリーを確認します。

```zsh
git tag -s v1.2.3 -m "SnapFlow v1.2.3"
git verify-tag v1.2.3
git push origin v1.2.3
./Scripts/package-release.sh
```

公式アプリ署名、Release ZIP、SHA-256、manifestを検証し、`Documentation/RELEASE_NOTES_v1.2.3.md`を本文として公開します。公開済みv1.2.2のタグとAssetsは変更しません。

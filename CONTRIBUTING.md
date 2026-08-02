# Contributing to SnapFlow

Contributionを歓迎します。提出されたContributionは、別途明示しない限りApache License 2.0の条件でSnapFlowへ提供されます。

## 開発手順

```zsh
git switch main
git pull --ff-only origin main
git switch -c feature/short-description
./Scripts/build-community.sh
swift test
```

変更後は次を確認します。

```zsh
git status
git diff
zsh -n Scripts/*.sh
swift test
./Scripts/build-community.sh
```

## Pull Request

- 1つのPull Requestでは1つの目的を扱ってください。
- 動作変更には理由、確認手順、影響範囲を記載してください。
- Accessibility、画面収録、署名、更新、シェル処理へ触れる場合はセキュリティ上の影響も記載してください。
- 秘密鍵、証明書の秘密部分、トークン、個人情報、実画面のプレビューを含めないでください。
- 公式Bundle IDをCommunityビルドへ使用しないでください。
- 公式Releaseや公式署名の作成はMaintainerだけが行います。

## ブランチ名

```text
feature/<内容>
fix/<内容>
docs/<内容>
security/<内容>
```

## コミット

変更理由が分かる短い命令形のメッセージを使用してください。可能であればSSHまたはGPGでコミットへ署名してください。

```zsh
git commit -S -m "Harden release verification"
```

## セキュリティ問題

未公開の脆弱性はPull RequestやIssueへ投稿せず、[SECURITY.md](SECURITY.md)の非公開報告手順を使用してください。

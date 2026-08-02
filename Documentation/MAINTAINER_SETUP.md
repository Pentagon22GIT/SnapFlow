# Maintainer Setup Guide

この文書は、SnapFlowを新しいGitHubリポジトリとして開始し、非公開状態での初期監査を経て、Community版と公式自己署名版を安全に公開・管理するためのMaintainer向け手順です。コマンドはSnapFlowプロジェクトのルートで実行します。

## 1. 前提

- macOS 13以降
- 最新の安定版Xcode
- Xcode Command Line Tools
- Git 2.34以降
- GitHubアカウント
- GitHubアカウントの二要素認証またはPasskey
- 公式署名秘密鍵を保管する専用のmacOS Keychain

VS Codeを通常のコードエディタとして使用できます。ただし、XCTestの実行と公式Universal 2ビルドには完全なXcodeを使用します。Xcode Command Line Toolsだけの環境では、`XCTest`モジュールが見つからず`swift test`が失敗する場合があります。

使用中のDeveloper Directoryは次で確認します。

```zsh
xcode-select -p
```

## 2. 公開前のファイルを確認する

新しい作業フォルダに古いGit履歴がないことを確認します。

```zsh
if test -e .git; then
  echo "注意: .gitが存在します"
else
  echo "OK: 古いGit履歴はありません"
fi
```

次の生成物や秘密情報を公開準備ツリーへ含めません。

- `.build`、`build`、`release`
- `.p12`、`.pfx`
- 秘密鍵を含む`.pem`、`.key`
- GitHub Personal Access Token
- Apple ID、パスワード、復旧コード
- 非公開にしたいメールアドレス
- 実在ユーザーの画面キャプチャやウィンドウタイトル
- 個人情報を含むログ

候補ファイルを確認します。

```zsh
find . -maxdepth 2 -type d \
  \( -name .git -o -name .build -o -name build -o -name release \) \
  -print

find . -type f \
  \( -iname '*.p12' -o -iname '*.pfx' -o -iname '*.pem' -o -iname '*.key' \) \
  -print
```

非公開にしたいメールアドレスは、値をコマンド履歴へ直接書かずに確認します。

```zsh
read -r "private_email?非公開にしたいメールアドレスを入力してEnter: "
grep -RInF --exclude-dir=.git --exclude-dir=.build -- "$private_email" . \
  || echo "OK: 個人メールアドレスは見つかりません"
unset private_email
```

`.gitignore`は一般的な生成物と秘密鍵拡張子を除外しますが、拡張子を変えた秘密情報までは保証できません。初回コミット前とすべてのPush前に、ステージした差分を確認します。

## 3. Gitの本人性を設定する

アプリのコード署名鍵、GitHubへのSSH接続に使う認証鍵、Gitのコミット署名鍵はそれぞれ別の目的です。GitHub用のコミット署名には専用のSSH署名鍵を使用します。

### メールアドレスの公開を防ぐ

GitHubの`Settings > Emails`で次を設定します。

- `Keep my email addresses private`を有効にする
- `Block command line pushes that expose my email`を有効にする
- 表示されたGitHub提供のnoreplyアドレスを控える

以降の`<GitHubのnoreplyアドレス>`は、GitHubの画面に表示された値へ置き換えます。個人メールアドレスを入力しません。

### SSH署名鍵を作る

既存のSSH認証鍵と分離する場合は次を使います。既に安全に作成・登録済みなら再生成しません。

```zsh
ssh-keygen -t ed25519 -C "SnapFlow Git signing" -f ~/.ssh/snapflow_git_signing
```

秘密鍵`~/.ssh/snapflow_git_signing`を公開しないでください。公開鍵`~/.ssh/snapflow_git_signing.pub`をGitHubの`Settings > SSH and GPG keys > New SSH key`へSigning Keyとして登録します。

Gitへ設定します。

```zsh
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/snapflow_git_signing.pub
git config --global commit.gpgsign true
git config --global tag.gpgSign true
```

ローカルでもSSH署名タグを検証できるよう、`~/.ssh/allowed_signers`へGitHubのnoreplyアドレスと公開鍵を1行で登録します。

```text
GitHubのnoreplyアドレス namespaces="git" ssh-ed25519 公開鍵本体
```

そのファイルをGitへ設定します。

```zsh
git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
```

`allowed_signers`には`.pub`ファイルの`ssh-ed25519`以降を記載し、秘密鍵は記載しません。

GitHubは検証できたSSH、GPG、S/MIME署名を`Verified`として表示します。ただし、Gitの署名鍵はアプリのTCC本人性を保証するコード署名鍵とは別です。Gitの名前とメールアドレスは、リポジトリ初期化後にリポジトリ単位でも固定します。

## 4. GitHubに空のリポジトリを作る

GitHubで`New repository`を選び、次のように設定します。

| 項目             | 値         |
| ---------------- | ---------- |
| Repository name  | `SnapFlow` |
| Visibility       | Private    |
| Add a README     | OFF        |
| Add .gitignore   | None       |
| Choose a license | None       |

README、`.gitignore`、LICENSEは既にプロジェクトへ含まれているため、GitHub側で自動生成しません。最初はPrivateのまま初回コミット、Actions、コミットメタデータを確認し、公開前監査が完了してからPublicへ変更します。

## 5. ローカルでGitを開始する

まだ`.git`がないことを確認して初期化します。

```zsh
git init -b main
git config user.name "Pentagon22GIT"
git config user.email "<GitHubのnoreplyアドレス>"
git config gpg.format ssh
git config user.signingkey ~/.ssh/snapflow_git_signing.pub
git config commit.gpgsign true
git config tag.gpgSign true
git config gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
```

コミット作成前に、Gitが使用する本人情報を確認します。AuthorとCommitterの両方がnoreplyアドレスになっていなければ先へ進みません。

```zsh
git config --show-origin --get user.name
git config --show-origin --get user.email
git var GIT_AUTHOR_IDENT
git var GIT_COMMITTER_IDENT
```

構文検証、テスト、Communityビルドを実行します。

```zsh
zsh -n Scripts/*.sh
swift test
./Scripts/build-community.sh
```

生成物が`.gitignore`の対象であることを確認してから、ソースをステージします。

```zsh
git add .
git status --short
git diff --cached --check
git diff --cached --stat
git diff --cached
git ls-files | grep -Ei '\.(p12|pfx|pem|key)$' \
  || echo "OK: 秘密鍵候補は追跡されていません"
git commit -S -m "Initial secure SnapFlow v1.0.0 project"
```

`git diff --cached`が長くても、秘密鍵、トークン、個人情報がないことを確認します。コミット後、署名とメタデータを確認します。

```zsh
git log --show-signature -1
git show -s --format=fuller HEAD
git log --all --format='%H | author=%an <%ae> | committer=%cn <%ce>'
```

GitHubで表示されたURLを使ってRemoteを登録します。

```zsh
git remote add origin git@github.com:Pentagon22GIT/SnapFlow.git
git remote -v
git push -u origin main
```

Pushはコミット済みの履歴をGitHubへ送ります。未コミットのファイルは送られません。

## 6. GitHubの安全設定

### Private状態での初期監査

最初のPush後、リポジトリをPublicへ変更する前に次を確認します。

- GitHub上の初回コミットが`Verified`である
- AuthorとCommitterがGitHubのnoreplyアドレスである
- 個人メールアドレス、秘密鍵、トークン、ビルド生成物が公開対象にない
- `build-and-test`が成功している
- CodeQL Workflowの内容と権限が意図どおりである（Privateリポジトリで利用できない場合はPublicへの変更後に実行確認する）
- README、LICENSE、SECURITY、公開文書が意図した内容である

監査が完了した場合だけ、`Settings > General > Danger Zone > Change repository visibility`からPublicへ変更します。Publicへ変更した直後に、以下のRules、Actions、Security設定を完成させます。

### General

- Default branchを`main`にします。
- `Automatically delete head branches`を有効にします。
- Merge方式は最初は`Squash merging`だけでも構いません。
- WikiやProjectsを使わない場合は無効化し、管理対象を減らします。

### Rules / Branch protection

`main`を対象に次を設定します。

- Pull Request経由の変更を要求
- CIの`build-and-test`成功を要求
- マージ前にブランチが最新であることを要求
- Force Pushを禁止
- Branch deletionを禁止
- Linear historyを要求
- 署名済みコミットを要求
- 必須承認数は0にする

CodeQLは実行時間と一人開発での停止リスクを考慮し、`main`へマージするための必須Status Checkには設定しません。ただし、公式Releaseを作成する前には、対象となる最新mainのCodeQL `Analyze`が成功していることを必ず確認します。

一人開発では「1人以上の承認必須」を有効にすると、自分のPull Requestを自分で承認できず停止する場合があります。レビュー承認は必須にせず、差分確認、署名済みコミット、Pull Request履歴、CIおよびRelease前のCodeQL確認を使用します。

`v*`タグを対象にしたTag Rulesetも作成します。

- Enforcement statusを`Active`にする
- Target patternを`v*`にする
- Restrict updatesを有効にする
- Restrict deletionsを有効にする
- Block force pushesを有効にする
- Restrict creationsは無効にする
- Bypass権限は追加しない

Tag Rulesetは公開済みタグの付け替えと削除を防ぎます。タグオブジェクト自体の署名は別途`git tag -s`で行い、GitHub上の`Verified`表示も確認します。

### Actions

`Settings > Actions > General`で次を設定します。

- GitHub公式のActionだけを許可
- GitHub以外のMarketplace Actionを許可しない
- Action参照に完全なコミットSHAを要求
- 外部ContributorのWorkflow実行にMaintainerの承認を要求
- Workflow permissionsを`Read repository contents and packages permissions`にする
- GitHub ActionsによるPull Requestの作成と承認を許可しない

Workflowごとに必要な権限だけを明示します。CIは`contents: read`だけを使用し、CodeQLは結果を登録するために`security-events: write`を追加します。

本プロジェクトの外部Actionは完全なコミットSHAへ固定しています。Dependabotが更新Pull Requestを作成した場合、Actionの公式Release、変更ファイル、CI結果を確認してから統合します。

外部ForkからのWorkflowで秘密鍵を使用しないでください。公式コード署名秘密鍵をGitHub SecretsやActionsへ登録しません。

### Security

次を有効化します。

- Private vulnerability reporting
- Dependency graph
- Dependabot alerts
- Dependabot security updates
- Grouped security updates
- Secret Protection
- Push protection
- Code scanning / CodeQL Advanced setup

Copilot AutofixとAI findingsはv1.0.0では無効にします。AIが提示する修正は自動的に採用せず、必要な変更は通常のPull Requestとして差分と検証結果を確認します。

CodeQLはWorkflowから開始されます。`main`への必須Status Checkには含めませんが、公式Release前には最新mainのCodeQLが成功していることを確認します。

## 7. 日常の開発フロー

作業前にmainを最新化します。

```zsh
git switch main
git pull --ff-only origin main
git switch -c feature/short-description
```

変更を確認してコミットします。

```zsh
git status
git diff
zsh -n Scripts/*.sh
swift test
./Scripts/build-community.sh
git add <変更したファイル>
git diff --cached
git commit -S -m "Describe the change"
git push -u origin feature/short-description
```

GitHubでPull Requestを作成し、`Files changed`と自動検査を確認してmainへSquash Mergeします。作業後は次でローカルを更新します。

```zsh
git switch main
git pull --ff-only origin main
git branch -d feature/short-description
```

`main`へ直接Pushしない、`git push --force`を使わない、公開済みコミットを書き換えないことを基本とします。

## 8. 公式自己署名証明書を作る

### 重要な性質

自己署名証明書はAppleの信頼チェーンには入りませんが、秘密鍵を保持するMaintainerだけが同じ署名を生成できます。Designated Requirementへ証明書のSHA-1指紋を固定することで、名前とBundle IDだけをコピーしたアプリが公式版の条件を満たすことを防ぎます。

SHA-1はここでは証明書を識別するコード署名要件の値として使用します。アプリの内容ハッシュやReleaseファイルの整合性確認にはSHA-256を使用します。

### Keychain Access

1. `キーチェーンアクセス`を開きます。
2. `証明書アシスタント > 証明書を作成`を開きます。
3. 名前を`SnapFlow Official Code Signing`など、他と混同しない名前にします。
4. Identity Typeを自己署名ルートにします。
5. Certificate TypeをCode Signingにします。
6. デフォルトを上書きできる場合は、有効期限を運用可能な長さに設定します。
7. 可能ならSHA-256署名と十分な長さの鍵を使用します。
8. 作成後、証明書の下に秘密鍵が表示されることを確認します。

macOSのバージョンによって画面表記が異なるため、最終的には次のコマンドでコード署名Identityとして認識されていることを確認します。

```zsh
security find-identity -v -p codesigning
```

表示された40桁のSHA-1を`Config/OfficialSigning.plist`の`CertificateSHA1`へ設定します。これは公開情報であり、リポジトリへコミットします。秘密鍵は設定ファイルへ書きません。

```xml
<key>CertificateSHA1</key>
<string>40桁の証明書SHA-1</string>
```

設定後に確認します。

```zsh
./Scripts/build-official.sh
./Scripts/verify-official.sh
./Scripts/show-identity.sh
```

DRが次の形になっていることを確認します。

```text
identifier "dev.pent.SnapFlow" and certificate leaf = H"設定したSHA-1"
```

### 秘密鍵バックアップ

- 証明書と秘密鍵をパスワード付き`.p12`へ書き出します。
- `.p12`をGitHub、クラウド同期フォルダ、プロジェクトフォルダへ置きません。
- 強い固有パスワードを使用します。
- 暗号化された外部媒体へ少なくとも1つバックアップします。
- バックアップから復元できるか、公開前に隔離環境で確認します。
- 日常のCommunityビルドでは公式秘密鍵を使用しません。

秘密鍵を失うと同一署名で更新できません。漏えいするとAppleによる失効ができないため、[SECURITY.md](../SECURITY.md)の鍵侵害手順が必要です。

## 9. 旧開発版の権限を移行する

過去に`dev.pent.SnapFlow`をidentifierだけのAd-hoc DRで使用したMacでは、v1.0.0公開前に旧権限を削除します。

```zsh
./Scripts/reset-legacy-permissions.sh
```

公式自己署名版を起動し、Accessibilityと必要に応じて画面収録を改めて許可します。一般公開前に利用者が存在しない場合でも、Maintainer自身の開発端末では実施します。

## 10. v1.0.0を公開する

[Release Process](RELEASE_PROCESS.md)のチェックリストを使用します。概要は次です。

1. mainのCIとCodeQLを成功させる。
2. `VERSION`を`1.0.0`、`BUILD_NUMBER`を`1`にする。
3. 署名済み注釈タグ`v1.0.0`をローカルだけに作成し、署名と対象コミットを検証する。
4. `package-release.sh`で公式版を生成する。
5. ZIP、SHA-256、manifest、展開後のアプリ、コード署名をローカルで検証する。
6. すべての検証に成功した場合だけ、タグをGitHubへpushする。
7. GitHub上でタグの`Verified`表示と対象コミットを確認する。
8. ZIP、SHA-256、manifestをGitHub Releaseへ添付して公開する。
9. 公開後、別フォルダへ3ファイルを再ダウンロードして検証する。
10. `releases/latest`とアプリの「更新を確認…」が新しいReleaseを開くことを確認する。

## 11. GitHubアカウントの侵害対策

- Passkeyまたはセキュリティキーを優先します。
- 復旧コードをオフライン保管します。
- 不要なOAuth Apps、GitHub Apps、Deploy Keysを定期的に削除します。
- Personal Access Tokenを作る場合はFine-grained、短い期限、最小権限にします。
- GitHub ActionsのWorkflow変更は、通常コード以上に慎重にレビューします。
- Release公開前にタグの`Verified`表示と対象コミットを確認します。

GitHubアカウントとコード署名秘密鍵の両方が同時に侵害されないよう、認証経路と保管場所を分離します。

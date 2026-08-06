# SnapFlow

SnapFlowは、macOSのウィンドウを画面端や四隅へドラッグし、決められた領域へ配置するオープンソースのメニューバーアプリです。

本リポジトリにはソースコードと開発用ビルド手順を公開します。一般利用者向けの公式バイナリは、各GitHub Releaseへ`SnapFlow-<version>.zip`として添付します。公式版とソースから各自で作るCommunity版は同じコードを使用しますが、Bundle IDと署名を分離しています。

## 重要な区別

| 種類      | 公式版                             | Community版                   |
| --------- | ---------------------------------- | ----------------------------- |
| 対象      | 一般利用                           | 開発・検証・改造              |
| 表示名    | SnapFlow                           | SnapFlow Community            |
| Bundle ID | `dev.pent.SnapFlow`                | `dev.pent.SnapFlow.community` |
| 署名      | 管理者が保持する固定自己署名証明書 | Ad-hoc署名                    |
| 配布      | GitHub Releases                    | ソースから各自でビルド        |
| 権限      | 公式署名へ結び付く                 | 公式版と共有しない            |

公開ソースを改変すれば同じ表示名やBundle IDを設定できますが、公式署名秘密鍵がなければ公式版と同じコード署名要件を満たせません。公式版を確認するときは、ファイル名やアイコンではなく署名とReleaseのSHA-256を検証してください。

## 動作環境

- macOS 13以降
- Apple SiliconまたはIntel Mac（公式ReleaseはUniversal 2）
- Community版のビルドにはSwift 5.9以降とXcode Command Line Tools
- ウィンドウ操作にはAccessibility権限
- 候補画像を表示する場合だけ画面収録権限

v1.0.0の公開前実機検証は、macOS 26.5.2、Apple Silicon（arm64）、Xcode 26.6、Swift 6.3.3で実施しました。公式バイナリにarm64とx86_64が含まれることは検証済みですが、Intel Macでの実起動は未確認です。複数ディスプレイについても利用可能な実機構成での追加確認が必要です。対応OS・CPUを満たすことは、すべてのMacやアプリとの完全な互換性を保証するものではありません。

## プライバシー設計

SnapFlowには、解析、広告、テレメトリー、クラッシュ自動送信、ユーザーアカウント、外部サーバーへのデータ送信機能がありません。

- ウィンドウタイトルは配置候補の表示にだけ使用します。
- 候補画像は設定で明示的に有効化した場合だけ取得します。
- 候補画像はメモリ内で表示し、ファイルへ保存しません。
- 候補画像やウィンドウタイトルをネットワーク送信しません。
- 「更新を確認…」は固定された公式GitHub Releaseページを既定ブラウザで開くだけです。
- アプリ自身が更新をダウンロード、展開、実行、置換することはありません。

詳細は[プライバシー方針](Documentation/PRIVACY.md)と[脅威モデル](Documentation/THREAT_MODEL.md)を参照してください。

## 主な機能

### 画面端へのスナップ

ウィンドウのタイトルバー、タブバー、または統合ツールバー付近を掴み、画面端へドラッグします。青い候補領域が表示された状態でマウスを離すと配置を確定します。

| ドラッグ先 | 配置       |
| ---------- | ---------- |
| 左端       | 左半分     |
| 右端       | 右半分     |
| 左上       | 左上四分割 |
| 右上       | 右上四分割 |
| 左下       | 左下四分割 |
| 右下       | 右下四分割 |
| 上端中央   | 最大化     |
| 下端中央   | 配置なし   |

上下半分はメニューバーまたは任意のグローバルショートカットから利用できます。

### 配置アシスト

左右半分、上下半分、四分割へ配置すると、残り領域へ置けるウィンドウ候補を表示します。

- 現在のSpaceで見えるウィンドウだけを対象にします。
- 同一アプリの同名ウィンドウも別候補として扱います。
- 候補画像は初期状態で無効です。
- 候補画像を無効にしても、アプリアイコンとタイトルで選択できます。
- 候補画像を有効にした場合、最初の12件を取得し、スクロールに応じて追加取得します。
- 背景クリック、Esc、30秒間無操作、Spaceや画面構成の変更で終了します。

### スナップ済みウィンドウの復元

設定が有効な場合、スナップ済みウィンドウを実際に動かし始めた時点で、スナップ前のサイズへ約0.16秒で戻します。クリックだけ、リサイズ操作、画面端へマウスだけを動かした場合は復元しません。

### 動的スプリットと連動リサイズ

スナップ済みウィンドウが共有する縦線または横線につまみを表示します。つまみを動かすと、左右・上下・三分割・四分割の関係するウィンドウを一緒にリサイズできます。つまみと青いガイドはマウス座標へ直接追従するため、重いアプリの描画が遅れてもガイドの位置計算には影響しません。

ドラッグ中に実際の内容を表示する範囲は設定から選べます。

| モード | ドラッグ中の表示 |
| ------ | ---------------- |
| 軽量 | すべてアイコンで表示し、操作終了後に実リサイズ |
| 標準 | 操作中のメインウィンドウだけ実リサイズ |
| すべて表示 | 関係するすべてのウィンドウを実リサイズ |

初期設定は「標準」です。実リサイズでは処理中の古い目標を蓄積せず、常に最新の目標だけを送ります。アイコン表示の対象にはドラッグ中のAccessibilityリサイズ要求を送りません。操作終了後の確定中は全対象を一時的にぼかして最終補正を隠し、位置とサイズの確認に成功してからガイドを消します。失敗した場合は同じ表示の裏で操作前のフレームへ戻します。

つまみの仮想表示には画面収録を使用しません。通常のウィンドウ境界を直接動かした場合はmacOS標準の単独リサイズとして扱い、そのウィンドウを現在の連動関係から外します。

既存の配置が画面の50%ではない場合、新しいスナップと配置アシストは残り領域を使用します。アプリ固有の最小サイズで収まらない通常のスナップは、実際に受け入れられたサイズを使用し、必要に応じて重なりを許容します。

残り領域が、そのウィンドウで観測した制約サイズに対して設定された許容度を超えて不足する場合は、その配置が到達した縦線または横線の段を一段階再分割します。再分割先のいずれかが同じ許容度を満たせない場合は、新しいウィンドウと既存レイアウトを一括でスナップ前へ戻します。固定ptやディスプレイ全体に対する割合は、この判定には使用しません。

### サイズ制約と失敗時復元

アプリ固有の最小・最大サイズがある場合、SnapFlowは実際のフレームを複数回確認します。必要な外周へ正しく接していない場合は成功として履歴へ保存せず、可能な限り配置前の状態へ戻します。

### 複数Space・複数ディスプレイ

- 現在のSpaceで見えるウィンドウを基準に履歴と占有状態を管理します。
- 別Spaceだけに見えるウィンドウをUndo対象にしません。
- ディスプレイID単位で配置を管理します。
- 共有境界を通過した直後は、意図しないスナップを抑制します。

### グローバルショートカット

左右半分、上下半分、四隅、最大化、直前の配置を戻す操作へ任意のショートカットを割り当てられます。Command、Option、Control、Shiftのいずれかを含む必要があります。

## 必要な権限

### Accessibility

ウィンドウの取得、移動、サイズ変更と、ドラッグ操作の検出に必要です。

```text
システム設定 > プライバシーとセキュリティ > Accessibility
```

Accessibilityは強い権限です。GitHub Releases以外から入手したアプリへ、公式版のつもりで許可しないでください。

### 画面収録

配置アシストの候補画像を表示する場合だけ必要です。初期状態では候補画像が無効なため、許可しなくてもスナップと配置アシストを利用できます。

```text
システム設定 > プライバシーとセキュリティ > 画面収録
```

## 公式版のインストール

1. 公式リポジトリの[Releases](https://github.com/Pentagon22GIT/SnapFlow/releases)を開きます。
2. 最新Releaseの`SnapFlow-<version>.zip`、`.sha256`、`release-manifest.json`をダウンロードします。
3. SHA-256と署名を確認します。
4. ZIPを展開し、`SnapFlow.app`を`~/Applications`または`/Applications`へ移動します。
5. 初回起動時にmacOSの「プライバシーとセキュリティ」で起動を許可します。
6. 必要な権限だけを許可します。

自己署名版はApple Developer IDやNotarizationを使用していないため、Gatekeeperは開発元を自動的には信頼しません。警告を無効化するコマンドやquarantine属性の強制削除は案内しません。システム設定に表示された対象と入手元を確認し、利用者自身の判断で許可してください。

### SHA-256の確認

Releaseファイルを置いたフォルダで実行します。

```zsh
shasum -a 256 -c SnapFlow-1.2.0.sha256
```

SHA-256は、ダウンロードしたZIPがRelease作成時のファイルと一致するかを確認するためのものです。ZIPと`.sha256`を同じReleaseから取得するため、SHA-256だけでは配布元の本人性を独立に証明できません。公式GitHubリポジトリ、署名済みReleaseタグ、アプリのコード署名を組み合わせて確認してください。

### コード署名の確認

```zsh
codesign --verify --strict --verbose=4 SnapFlow.app
codesign -d -r- SnapFlow.app
codesign -dvvv SnapFlow.app
codesign --verify --strict --verbose=4 \
  -R='identifier "dev.pent.SnapFlow" and certificate leaf = H"26479A3C344B9500A9CEFDBD00FB1A086C3D1295"' \
  SnapFlow.app
```

v1.2.0では、表示されたBundle IDが`dev.pent.SnapFlow`であること、証明書SHA-1が`26479A3C344B9500A9CEFDBD00FB1A086C3D1295`であること、Designated Requirementと`release-manifest.json`が同じ値を示すことを確認します。SHA-1はこの証明書をDesignated Requirement内で識別するために使用しており、配布ファイルの完全性確認にはSHA-256を使用します。名前だけの一致は公式版の証明になりません。

## 更新

メニューバーの「更新を確認…」を選択すると、次の固定URLを既定ブラウザで開きます。

```text
https://github.com/Pentagon22GIT/SnapFlow/releases/latest
```

更新は利用者の任意です。Releaseノート、ハッシュ、署名を確認してから、新しい`SnapFlow.app`へ手動で置き換えてください。同じBundle ID、配置先、公式署名証明書が維持されている場合、macOSが既存の権限を同一アプリの更新として扱えるよう設計しています。ただしmacOSの判断や設定状態により再許可が必要になる場合があります。

## Community版のビルド

```zsh
git clone https://github.com/Pentagon22GIT/SnapFlow.git
cd SnapFlow
chmod +x Scripts/*.sh
./Scripts/install-community.sh
```

生成だけの場合は次を使います。

```zsh
./Scripts/build-community.sh
```

出力先は次です。

```text
build/community/SnapFlow Community.app
```

Community版はAd-hoc署名です。公式版の署名や権限を引き継ぎません。改造ビルドへ権限を与える場合は、変更内容を自身で確認してください。
Community版はビルドを実行したMacのCPU向けに生成されます。

## 公式版のビルド

公式版の作成には、管理者が保管する自己署名コード署名秘密鍵が必要です。一般のContributorは公式版を作成できません。公式ビルドはGit管理下にあり、未コミット・未追跡の変更がないソースだけを受け入れます。アプリにはソースコミットとdirty状態を記録し、Release作成時に対象タグとの一致を検証します。セットアップ、証明書管理、タグ、Release作成は[管理者セットアップガイド](Documentation/MAINTAINER_SETUP.md)を参照してください。

## 設定

- ログイン時に起動
- 候補画像の表示（初期OFF）
- スナップ済みウィンドウを動かした際の元サイズ復元
- 分割ウィンドウの連動リサイズ（初期ON）
- ドラッグ中の表示：軽量／標準／すべて表示（初期は標準）
- 左右端で待機した際の四分割判定拡張
- 拡張までの待機時間：0.5〜5.0秒
- 画面端の反応範囲：8〜80pt
- 四隅の反応範囲：60〜300pt
- ウィンドウを小さくする範囲：10〜90%（初期50%）
- 各操作のグローバルショートカット

## アンインストール

1. 設定でログイン時起動を無効にします。
2. SnapFlowを終了します。
3. `SnapFlow.app`をゴミ箱へ移動します。
4. 不要であればシステム設定からAccessibilityと画面収録の許可を削除します。

設定の削除が必要な場合は次を使用できます。

```zsh
defaults delete dev.pent.SnapFlow
```

Community版は`dev.pent.SnapFlow.community`です。

## セキュリティ報告

脆弱性、署名の不一致、権限の不正継承、Release改ざんの疑いは公開Issueへ書かず、GitHubのPrivate Vulnerability Reportingから報告してください。対応方針とサポート対象バージョンは[SECURITY.md](SECURITY.md)に記載しています。

一般的な不具合・質問と、個人開発として提供できる支援範囲は[SUPPORT.md](SUPPORT.md)を確認してください。コードへのContributionは[CONTRIBUTING.md](CONTRIBUTING.md)に従ってください。

## 保証と責任

本ソフトウェアはApache License 2.0に基づき、現状有姿で提供されます。特定目的への適合性、完全な無停止動作、データや作業状態の保全、すべてのアプリとの互換性、安全性の絶対的保証は行いません。重要な作業中は事前に保存し、利用者自身の責任で使用してください。適用法令によって制限できない責任まで排除するものではありません。

この説明は一般的な情報であり、個別の法律相談ではありません。

## ライセンス

Copyright 2026 Pentagon22GIT

Apache License 2.0で公開します。再配布、改変、Contributionの条件は[LICENSE](LICENSE)と[NOTICE](NOTICE)を確認してください。ライセンスはSnapFlowの名称、ロゴ、配布元を公式と誤認させる表示まで許可するものではありません。

## プロジェクト構成

```text
SnapFlow/
├── .github/
│   ├── workflows/
│   │   ├── ci.yml
│   │   └── codeql.yml
│   ├── ISSUE_TEMPLATE/
│   └── dependabot.yml
├── Config/
│   └── OfficialSigning.plist
├── Documentation/
│   ├── MAINTAINER_SETUP.md
│   ├── PRIVACY.md
│   ├── RELEASE_PROCESS.md
│   ├── RELEASE_NOTES_v1.0.0.md
│   ├── RELEASE_NOTES_v1.1.0.md
│   ├── RELEASE_NOTES_v1.1.1.md
│   ├── RELEASE_NOTES_v1.2.0.md
│   ├── SECURITY_AUDIT.md
│   ├── THREAT_MODEL.md
│   ├── VALIDATION.md
│   ├── VALIDATION_v1.1.0.md
│   ├── VALIDATION_v1.1.1.md
│   └── VALIDATION_v1.2.0.md
├── Scripts/
│   ├── build-app.sh
│   ├── build-community.sh
│   ├── build-official.sh
│   ├── install-community.sh
│   ├── package-release.sh
│   ├── reset-legacy-permissions.sh
│   ├── show-identity.sh
│   └── verify-official.sh
├── Sources/SnapFlow/
├── Tests/SnapFlowTests/
├── BUILD_NUMBER
├── VERSION
├── CONTRIBUTING.md
├── LICENSE
├── NOTICE
├── Package.swift
├── README.md
└── SECURITY.md
```

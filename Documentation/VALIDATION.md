# Validation Record

検証基準日: 2026-08-02
対象: SnapFlow v1.0.0公開準備ソース
動的検証対象: SnapFlow v1.0.0公開準備ソース

この記録は、配布前の静的検証、macOS上の動的検証、GitHub上の検証、および公開までに残る検証を区別します。各検証の成功は、脆弱性が存在しないことを完全に証明するものではありません。

## 完了した静的検証

- 全Swiftソース、Package定義、シェルスクリプト、Workflow、公開文書の目視レビュー
- 全シェルスクリプトの`zsh -n`構文検証
- `OfficialSigning.plist`のplist構文検証
- GitHub Workflow、Dependabot、Issue templateのYAML構文検証
- Markdown相対リンクの存在確認
- `VERSION`、`BUILD_NUMBER`、Bundle ID、更新URLの一貫性確認
- 外部Swift Packageが存在しないことの確認
- アプリ本体にURLSession、WebView、socket、外部プロセス実行処理が存在しないことの検索
- 更新確認の通信経路が公式`releases/latest`をブラウザで開く処理だけであることの確認
- quarantine削除、強制終了、設定ファイルの`source`が新スクリプトに存在しないことの確認
- GitHub Actions参照が完全なコミットSHAへ固定されていることの確認
- `.p12`、`.pfx`、`.key`、`.pem`が現在のGit管理対象およびGit履歴に存在しないことの確認
- 既知形式の秘密鍵、GitHub Token、AWS Access Key候補が追跡ファイルから検出されないことの確認
- Apache License 2.0本文が公式本文と一致することの確認

## 完了したmacOSローカル検証

2026-08-02にMaintainerの次の環境で実施しました。

- macOS 26.5.2
- Apple Silicon（arm64）
- Xcode 26.6（Build 17F113）
- Swift 6.3.3（swiftlang-6.3.3.1.3、clang-2100.1.1.101）

- `zsh -n Scripts/*.sh`成功
- `swift test`成功
- XCTest 5件実行、失敗0件
- Community版のReleaseビルド成功
- Community版のAd-hocコード署名検証成功
- 公式版のUniversal 2ビルド成功
- 公式版に`x86_64`と`arm64`が含まれることを確認
- 自己署名証明書による公式コード署名成功
- `codesign --verify --strict`成功
- Designated Requirementの明示評価成功
- Hardened Runtimeの付与を確認
- 公式Bundle IDが`dev.pent.SnapFlow`であることを確認
- 公式バージョンが`1.0.0`であることを確認
- 公式Editionが`official`であることを確認
- 公式証明書SHA-1と`OfficialSigning.plist`の一致を確認
- 公式署名秘密鍵を暗号化された`.p12`としてGit管理外へ保存
- 一時キーチェーンへの`.p12`復元とコード署名試験に成功
- 旧Ad-hoc版のAccessibilityおよび画面収録TCC許可をリセット
- 公式版へAccessibility権限を新規許可し、ウィンドウ操作が成功
- 候補画像を有効化した場合だけ画面収録権限を使用することを確認
- 画面収録権限の新規許可後、候補画像を含む配置アシストが成功
- 候補画像が初期状態で無効であり、無効時にも配置アシストが動作することを確認
- Finderおよびブラウザを含む複数アプリでスナップ動作を確認
- 左右半分、上下半分、四隅、最大化、Undo、元サイズ復元を確認
- グローバルショートカット、設定変更、終了後の再起動を確認
- 複数Spaceにおける基本動作とSpace変更時の取消を確認
- 「更新を確認…」が公式`releases/latest`を既定ブラウザで開くことを確認

## 完了したGitHub検証

- 公開リポジトリを作成
- `main`をPull Request経由、署名済みコミット、CI成功必須として保護
- `main`の削除とForce Pushを禁止
- `v*`を対象とするTag Rulesetを作成
- Releaseタグの更新、削除、Force Pushを禁止
- Actionsの標準権限を読み取り専用に設定
- GitHub公式Actionのみを許可
- Action参照の完全なコミットSHA固定を要求
- 外部ContributorのWorkflow実行にMaintainerの承認を要求
- 最新mainの`build-and-test`成功
- 最新mainのCodeQL `Analyze`成功
- Dependabotによる`actions/checkout v7.0.1`更新を確認して統合
- Dependency graphを有効化
- Dependabot alertsとsecurity updatesを有効化
- Private vulnerability reportingを有効化
- Secret Protectionを有効化
- Push protectionを有効化
- CodeQL Advanced setupを有効化
- Gitコミット署名とタグ署名に専用SSH鍵を設定

## 公開までに残る検証

次は未完了、または公開後の成果物がなければ実施できない検証です。

- 利用可能な範囲での複数ディスプレイ試験
- Intel Macでの実行試験（v1.0.0時点ではIntel実機未確認とREADMEへ明示）
- クリーンな利用環境におけるGatekeeper初回起動表示の確認
- GitHub Releaseから再ダウンロードしたZIPのSHA-256、コード署名、Designated Requirement検証

Intel実機試験と複数ディスプレイ試験が未完了であることは、Universal 2バイナリの生成失敗を意味しません。ただし、その環境での動作保証を示すものでもありません。公開後の再ダウンロード検証は、Releaseを公開する前の最終Draftまたは公開直後に必ず実施します。

## macOSで実施した最低検証コマンド

```zsh
zsh -n Scripts/*.sh
swift test
./Scripts/build-community.sh
codesign --verify --strict --verbose=4 "build/community/SnapFlow Community.app"
./Scripts/build-official.sh
./Scripts/verify-official.sh
lipo -archs build/official/SnapFlow.app/Contents/MacOS/SnapFlow
```

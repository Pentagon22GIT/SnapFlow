# Security and Operational Audit

監査基準日: 2026-08-02
対象: SnapFlow v1.0.0公開準備プロジェクト
監査種別: ソースコード、ビルド、署名、配布、GitHub運用、プライバシー、ライセンスの静的レビュー

## 結論

本プロジェクトは、無料・個人開発・App Store外配布という条件の中で、一般公開前に取れる現実的な防御を組み込んでいます。外部通信、外部Swift依存、自動更新、任意ファイル書き込み、サブプロセス実行をアプリ本体が持たず、攻撃面は比較的小さい構成です。

一方、Accessibilityを使用する以上、アプリまたは公式署名鍵が侵害された場合の影響は小さくありません。また自己署名証明書はAppleによる本人確認、Notarization、失効を提供しません。このため「安全を保証済み」ではなく、「明示した脅威に対して多層防御を実施し、残余リスクを公開した状態」と評価します。

公式v1.0.0公開の条件は、実際のmacOS上でCI、テスト、公式署名、TCC移行が成功し、作成したRelease成果物を再ダウンロードして検証できることです。
実施済み検証と未実施の動的検証は[Validation Record](VALIDATION.md)へ分離して記録しています。

## 対象ファイル

- Swiftソース一式
- Swift Package定義
- Community／公式ビルドスクリプト
- 署名・Release検証スクリプト
- GitHub Actions、Dependabot、Issue template
- README、SECURITY、Privacy、Threat Model、Release手順
- Apache License 2.0、NOTICE、Third-party notices

## 実施した観点

- 外部入力からコード実行へ至る経路
- ネットワーク送信、ファイル保存、ログ、個人情報処理
- Accessibility／画面収録権限の最小利用
- TCC本人性とDesignated Requirement
- コード署名とRelease整合性
- シェルインジェクション、PATHハイジャック、危険な削除
- 更新経路とSupply Chain
- GitHub権限、Action固定、秘密情報管理
- ウィンドウ識別、非同期処理キャンセル、失敗時復元
- ライセンス、免責、商標、特許上の注意

## 改善済み事項

### F-01: identifierだけのDesignated Requirement

重要度: High

以前のDRは`identifier "dev.pent.SnapFlow"`だけであり、第三者が同じBundle IDと明示DRを再現できました。TCC許可の本人性として不十分でした。

対応:

- 公式版DRへ自己署名証明書のleaf SHA-1を追加
- 公式ビルド時に証明書秘密鍵の存在を必須化
- 検証スクリプトで明示Requirementを再評価
- 旧TCC許可のリセット手順を追加
- Community版を別Bundle IDへ分離

完了確認:

`Config/OfficialSigning.plist`へ公式証明書SHA-1 `26479A3C344B9500A9CEFDBD00FB1A086C3D1295`を設定し、公式ビルド、コード署名、明示Requirement評価、秘密鍵バックアップからの復元署名試験に成功しました。ゼロ値や秘密鍵不在では公式ビルドが停止するFail-closed設計を維持しています。

### F-02: quarantine属性の強制削除

重要度: Medium

以前のインストールスクリプトは`com.apple.quarantine`を再帰削除していました。これは利用者のGatekeeper判断を迂回させる方向の処理です。

対応:

- 公式／Communityの新スクリプトからquarantine削除を完全に除去
- READMEでも回避コマンドを案内しない
- 公式版はシステム設定から利用者が明示許可

### F-03: 全キーイベントの常時グローバル監視

重要度: Medium

以前はアプリ起動中、Esc判定のために全keyDownをグローバル監視していました。保存や送信はありませんでしたが、必要以上のイベント取得でした。

対応:

- 通常のグローバル監視をマウスイベントへ限定
- keyDown監視を配置アシスト表示中だけ登録
- Escだけを処理
- 終了、取消、Space変更、選択時に監視を解除

### F-04: 画面プレビューの暗黙的利用

重要度: Medium

候補画像は便利ですが、画面収録権限の利用範囲が広くなります。

対応:

- 候補画像を初期OFF
- 利用者が設定で有効にした場合だけ画像取得APIを呼ぶ
- 無効時も配置アシストを利用可能
- メモリ内キャッシュだけを維持
- Privacy文書へデータフローを明記

### F-05: 公式版とソースビルド版のIdentity混同

重要度: High

公開ビルドスクリプトが公式Bundle IDと弱い署名を組み合わせると、利用者が公式版と誤認する可能性があります。

対応:

- Community版を`dev.pent.SnapFlow.community`へ固定
- 公式版を`dev.pent.SnapFlow`へ固定
- 公式ビルドは証明書設定がなければ失敗
- Info.plistへEditionとsource revisionを記録
- CommunityバイナリをReleaseへ添付しない運用

### F-06: シェル設定ファイルのsource

重要度: Low

以前のスクリプトは`Config/build.env`をシェルとして実行していました。リポジトリ内スクリプト自体が実行可能であるため単独の権限境界ではありませんが、設定値のつもりのファイルが任意コードを実行する構造でした。

対応:

- `source`を廃止
- 公開設定はplistと固定ファイルから読み取る
- バージョン、Build番号、証明書指紋を形式検証
- Bundle IDを固定

### F-07: 更新前の既存アプリ削除

重要度: Low

以前は既存アプリを削除してから新アプリを移動しており、途中失敗でアプリを失う可能性がありました。また同名プロセスを`pkill`していました。

対応:

- Communityインストーラーは起動中なら停止して利用者へ終了を要求
- 一時ディレクトリへstaging
- 既存アプリを一時backupへ移動
- 新規配置失敗時はbackupを復元
- 固定されたCommunityパス以外を削除しない

### F-08: アプリ内自動更新

重要度: Preventive

v1.0.0では自動更新を導入しません。

対応:

- 固定HTTPSの`releases/latest`をブラウザで開くのみ
- アプリ内にダウンロード、展開、置換、実行機能なし
- SHA-256、コード署名、manifestを利用者が確認可能

## Swiftコードの評価

### 良好な点

- URLは固定のGitHub／システム設定URLだけ
- `Process`、`NSTask`、shell実行、AppleScript、動的ライブラリ読込なし
- URLSession、socket、WebViewなし
- ファイル書き込みなし
- クリップボードアクセスなし
- キー文字列の蓄積・ログなし
- ウィンドウ画像の永続保存なし
- UserDefaults値は数値範囲へclamp
- 非同期配置をgenerationで無効化
- 配置結果をAXから読み戻して確定
- 失敗時snapshot rollback
- Space、wake、session inactive、screen変更時にpending処理を取消
- 候補選択時にstableIdentityとmove/resize可否を再確認
- Undo履歴上限30件

### 注意点

- `CFHash(AXUIElement)`は暗号学的な識別子ではありません。PIDとの組み合わせと生存・geometry確認により実用上の混同を抑えていますが、macOS内部実装に依存します。
- 非協力的なアプリや最小サイズ制約により、AX操作が一部成功する可能性があります。複数回の確認とrollbackがありますが、すべてのアプリで完全復元を保証できません。
- 画面上の候補パネルは高いWindow levelを使用します。マウスイベントを扱う必要がありますが、処理終了条件を維持し、セキュア入力を目的とするUIを模倣しないことが必要です。
- Accessibility APIはApp Sandboxと両立しにくいため、本構成ではSandboxを有効化していません。Hardened Runtimeは両Editionで有効化します。
- 配置アシスト表示中はEscによる終了を検出するため、グローバルkeyDownイベントがアプリへ配送されます。実装はEsc以外を処理・保存・送信しませんが、Accessibility権限を持つ非Sandboxアプリとして、この監視範囲を将来の変更でも拡大しないことが重要です。
- XCTestはSnapZoneの境界判定を中心とする5件です。AXウィンドウ操作、TCC、複数Space、各アプリ固有の挙動は主に実機試験で確認しており、自動テストの網羅性には限界があります。

## シェル・配布コードの評価

- `set -euo pipefail`
- macOS判定
- プロジェクトルートと固定出力先の確認
- PATH依存を減らす絶対パス利用
- Bundle ID固定
- VERSION、BUILD_NUMBER、証明書指紋の形式検証
- 公式証明書秘密鍵がなければ停止
- `codesign --deep`を使用しない
- Hardened Runtimeを要求
- 公式DRを明示Requirementで検証
- 公式バイナリをUniversal 2（arm64／x86_64）として検証
- Release前にclean Git treeと正確なタグを要求
- ZIP SHA-256とmanifest生成
- quarantine削除なし

ZIP、SHA-256ファイル、manifestを同じGitHub Releaseから取得する構成のため、SHA-256は転送後の完全性確認には有効ですが、配布元の本人性を単独では証明しません。署名済みGitタグ、公式リポジトリ、アプリ内の固定証明書Requirementを組み合わせて確認します。

## GitHub Supply Chain評価

- 外部Actionは完全なコミットSHAへ固定
- Workflow権限を`contents: read`中心に限定
- CodeQL Swift `security-extended`
- Swift build/testをmacOS runnerで実行
- DependabotでSwiftとGitHub Actionsを監視
- Secret scanningとPrivate Vulnerability Reportingを設定手順化
- 公式署名鍵をActionsへ置かない

Pull Requestから公式署名へ到達するWorkflowはありません。公式ReleaseはMaintainerのMacで明示操作して作成します。

## プライバシー評価

v1.0.0は利用者情報を開発者へ送信しません。画面画像は機密情報・個人情報を含み得るため、初期OFF、ローカルメモリ限定、外部送信なしを維持します。

将来データ収集を追加すると、現在のPrivacy文書と法的評価は成立しなくなります。テレメトリー、クラッシュ送信、自動更新通信を追加する前に、取得情報、利用目的、保存期間、第三者提供、同意・無効化方法を再設計する必要があります。

## ライセンス・法務運用

### 採用ライセンス

Apache License 2.0を採用しています。著作権ライセンス、Contribution、特許ライセンス、NOTICE、商標不許諾、保証否認、責任制限を明文化できます。

### 留意点

- Apache 2.0の免責は、適用法令上排除できない責任まで消すものではありません。
- Apache 2.0の特許条項はContributorが許諾できる特許請求へ作用します。第三者特許を網羅的に調査し、非侵害を保証するものではありません。
- 本監査では特許のFreedom-to-Operate調査を実施していません。
- SnapFlow、ロゴ、配布元の表示は、Forkを公式と誤認させないため別途運用が必要です。
- macOS、Appleの名称や記号について、Appleとの提携・承認を示す表現を使用しません。
- 外部コードを追加する場合、ライセンス、NOTICE、Source提供条件、商用・再配布条件を確認します。
- 生成AIによる補助を利用しても、公開コードと文書の採否・確認・Release責任はMaintainerが負います。

商用化、企業導入、大規模配布、紛争の具体的懸念が生じた場合は、日本法と配布先法域に詳しい弁護士・弁理士へ個別相談してください。本書は法律意見書ではありません。

## 公開前に残る必須作業

- [x] 実際の自己署名Code Signing証明書を作成
- [x] `OfficialSigning.plist`へ実SHA-1を設定
- [x] 公式秘密鍵の暗号化バックアップと復元試験
- [x] 新規GitHub公開リポジトリ作成
- [x] GitHub RulesとSecurity機能の設定
- [x] macOS CIとCodeQLの成功
- [x] Apple Siliconでの実機確認とIntel実機未確認の明記
- [x] 旧Ad-hoc TCC許可のリセット
- [x] 公式v1.0.0の署名・DR・Hardened Runtime検証
- [x] Accessibilityと任意の画面収録権限の新規許可試験
- [x] 主要機能、複数Space、更新確認URLの実機スモークテスト
- [x] 利用可能な範囲での複数ディスプレイ試験
- [ ] Release再ダウンロード後のSHA-256・署名検証
- [ ] Gatekeeper初回起動手順の実機確認
- [ ] LICENSE、NOTICE、READMEの最終名義確認

## 再監査トリガー

次の場合は再監査が必要です。

- macOSの最低対応版変更
- AccessibilityやScreenCapture API変更
- ネットワーク、自動更新、ログ送信追加
- 外部Package追加
- Helper/XPC/Daemon追加
- 署名鍵変更
- GitHub Actionsへ新しいAction追加
- インストーラーが管理者権限を要求する変更
- 個人情報または利用情報の取得開始
- ライセンス変更

## 参考情報

- Apple, macOS Code Signing In Depth: https://developer.apple.com/library/archive/technotes/tn2206/_index.html
- Apple, TN3127 Inside Code Signing Requirements: https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- Apple, NSEvent global monitor: https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29
- GitHub, CodeQL for Swift: https://docs.github.com/en/code-security/reference/code-scanning/codeql/codeql-queries/swift-built-in-queries
- GitHub, Artifact attestations: https://docs.github.com/en/actions/concepts/security/artifact-attestations
- GitHub, Repository security advisories: https://docs.github.com/en/code-security/security-advisories/repository-security-advisories/about-repository-security-advisories
- Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0
- 個人情報保護委員会: https://www.ppc.go.jp/
- e-Gov 著作権法: https://elaws.e-gov.go.jp/document?lawid=345AC0000000048

## 監査の限界

この監査は提供されたソースと今回生成したファイルの静的確認、およびMaintainerが報告したmacOS実機検証結果に基づきます。第三者による独立監査、macOSカーネルレベルの解析、ファジング、侵入試験、全アプリ互換試験、法的意見、第三者特許調査ではありません。実機検証環境はmacOS 26.5.2、Apple Silicon（arm64）、Xcode 26.6、Swift 6.3.3であり、Intel実機と複数ディスプレイ構成の網羅的検証は含みません。

# SnapFlow v1.0.0

SnapFlowの最初の公開Releaseです。macOSのウィンドウを画面端、四隅、メニュー、グローバルショートカットから配置できます。

## ダウンロード

一般利用者向けのアプリは、このReleaseへMaintainerが添付した`SnapFlow-1.0.0.zip`です。

GitHubが自動生成する`Source code (zip)`と`Source code (tar.gz)`はソースコードであり、公式署名済みアプリではありません。

次の3ファイルを同じReleaseから取得してください。

- `SnapFlow-1.0.0.zip`
- `SnapFlow-1.0.0.sha256`
- `release-manifest.json`

## 重要なセキュリティ情報

- 公式版のBundle IDは`dev.pent.SnapFlow`です。
- 公式版は、今後のReleaseでも同じ自己署名コード署名証明書を継続して使用する方針です。
- v1.0.0の公式証明書SHA-1は`26479A3C344B9500A9CEFDBD00FB1A086C3D1295`です。
- Community版のBundle IDは`dev.pent.SnapFlow.community`であり、公式版と権限を共有しません。
- 候補画像は初期状態で無効です。必要な場合だけ設定から有効化してください。
- 更新確認は公式`releases/latest`を既定ブラウザで開くだけです。
- アプリが更新を自動的にダウンロード、展開、実行、置換することはありません。
- Apple Developer IDとNotarizationを使用していないため、macOSによる開発元の自動的な信頼は得られません。入手元、SHA-256、コード署名を確認してください。

ファイル名、アプリ名、アイコン、Bundle IDだけでは公式版であることを証明できません。第三者が同じ名前やBundle IDを設定することは可能です。

## SHA-256の確認

3ファイルを同じフォルダへ置いて、次を実行します。

```zsh
shasum -a 256 -c SnapFlow-1.0.0.sha256
```

SHA-256は、ダウンロードしたZIPがRelease作成時のファイルと一致するかを確認するものです。ただし、ZIPとSHA-256ファイルを同じGitHub Releaseから取得するため、SHA-256だけでは配布元の本人性を独立に証明できません。

公式GitHubリポジトリ、署名済みReleaseタグ、アプリのコード署名を組み合わせて確認してください。

## コード署名の確認

ZIPを展開したフォルダで実行します。

```zsh
codesign --verify --strict --verbose=4 SnapFlow.app
codesign -d -r- SnapFlow.app
codesign -dvvv SnapFlow.app
```

さらに、v1.0.0の公式Bundle IDと証明書を明示的に検証できます。

```zsh
codesign --verify --strict --verbose=4 \
  -R='identifier "dev.pent.SnapFlow" and certificate leaf = H"26479A3C344B9500A9CEFDBD00FB1A086C3D1295"' \
  SnapFlow.app
```

`explicit requirement satisfied`と表示され、コマンドが正常終了することを確認してください。

ここで使用するSHA-1は、自己署名証明書をDesignated Requirement内で識別するための値です。ZIPの完全性確認にはSHA-256を使用します。

## 主な機能

- 左右半分、上下半分、四分割、最大化
- 配置アシスト
- 複数Spaceの管理
- ディスプレイ単位の配置管理
- スナップ前サイズへの復元
- 直前の配置のUndo
- サイズ制約があるアプリでの結果確認と失敗時ロールバック
- 任意のグローバルショートカット
- 利用者の操作による手動更新確認

## 必要な権限

- Accessibility：ウィンドウの取得、移動、サイズ変更、ドラッグ検出に必要です。
- 画面収録：候補画像を設定から明示的に有効化した場合だけ必要です。

候補画像を使用しない場合、画面収録権限を許可しなくてもスナップ機能と配置アシストを利用できます。

## 対応環境

- macOS 13以降
- Apple SiliconおよびIntel Mac
- 公式ZIPはarm64とx86_64を含むUniversal 2形式

v1.0.0の公開前実機検証は、次の環境で実施しました。

- macOS 26.5.2
- Apple Silicon（arm64）
- Xcode 26.6
- Swift 6.3.3

Universal 2バイナリにarm64とx86_64が含まれることは確認済みですが、Intel Macでの実起動は未確認です。

## 既知の制約

- 自己署名のため、初回起動時はmacOSの「プライバシーとセキュリティ」から利用者による明示的な許可が必要になる場合があります。
- Appleによる本人確認、Notarization、証明書の失効機能は利用できません。
- Intel Macでの実起動は未確認です。
- 複数ディスプレイ機能の実機検証範囲は限定的です。
- アプリ固有の最小・最大サイズや独自ウィンドウ実装により、厳密な分割にならない場合があります。
- Accessibilityを許可しない場合、ウィンドウ配置機能は動作しません。
- すべてのmacOSアプリとの互換性を保証するものではありません。
- 自動更新、テレメトリー、クラッシュ自動送信はありません。

詳細なインストール方法、署名検証、プライバシー設計、脅威モデル、残余リスクについては、README、SECURITY.mdおよびDocumentation内の文書を参照してください。

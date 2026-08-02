# Third-Party Notices

SnapFlow v1.0.0のアプリ本体には、外部Swift Packageや同梱された第三者バイナリ依存はありません。AppleがmacOSの一部として提供する次のSystem Frameworkへリンクします。

- AppKit
- ApplicationServices
- CoreGraphics
- QuartzCore
- Carbon
- ServiceManagement

これらはSnapFlowのApache License 2.0によって再ライセンスされるものではなく、利用者のmacOSに含まれる各ライセンス条件が適用されます。

GitHub ActionsではGitHub提供の`actions/checkout`と`github/codeql-action`をビルド・解析時に使用します。これらはSnapFlow.appへ組み込まれません。参照はSupply Chain保護のため完全なコミットSHAへ固定しています。

外部依存を追加する場合は、Release前にこの文書、Package.resolved、LICENSE／NOTICE、Security Auditを更新してください。

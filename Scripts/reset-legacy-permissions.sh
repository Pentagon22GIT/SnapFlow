#!/bin/zsh
set -euo pipefail

echo "旧Ad-hoc版SnapFlowに保存されたAccessibilityと画面収録の許可を削除します。"
echo "実行後、公式署名版で両方の権限を改めて許可する必要があります。"
read "reply?続行する場合は RESET と入力してください: "
[[ "$reply" == "RESET" ]] || { echo "中止しました。"; exit 0; }

/usr/bin/tccutil reset Accessibility dev.pent.SnapFlow
/usr/bin/tccutil reset ScreenCapture dev.pent.SnapFlow
echo "旧権限をリセットしました。"

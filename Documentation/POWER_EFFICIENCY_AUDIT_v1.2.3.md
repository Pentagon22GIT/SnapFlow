# SnapFlow v1.2.3 Power Efficiency and Resident Resilience Audit

監査日: 2026-08-07

## 対象

v1.2.2で追加された100msのWindow Server選択監視の寿命管理を対象とします。既存の1秒Recovery Timerは安全網として変更せず維持します。

## 原因

v1.2.2は`SnapController.start()`で10Hz Timerを無条件生成し、設定OFF、SnapFlow無効、スナップ登録不足を各tick内の`guard`で除外していました。このためWindow Server処理は抑制できても、Timerによる毎秒約10回のWakeupは残りました。

## v1.2.3のアプローチ

長寿命な内部状態から監視の必要性を判定し、必要な期間だけTimerを存在させます。短時間のドラッグ、リサイズ、配置、設定UI表示ではTimerを頻繁に破棄せず、従来どおりtick内のguardで処理を止めます。

選択Timer開始条件:

```text
controller running
AND SnapFlow enabled
AND linked resize enabled
AND connected group foreground enabled
AND locked placements >= 2
```

## 保守境界

今回実施しない変更:

- 10Hzから5Hzへの低下
- idle時間による適応周波数
- AXまたはWorkspace通知が来た場合だけ監視開始
- Accessibility権限状態による停止
- 接続グラフを推測または永続キャッシュしてTimer開始を絞り込む処理
- 既存1秒Recovery Timerの停止、開始条件、周期、tolerance
- `start()`の再呼び出し挙動

Accessibility権限を停止条件にすると、設定画面で後から権限を付与した場合の復帰経路を別途保証する必要があります。接続グラフの厳密な事前判定は偽陰性によってMission Control対応を停止する可能性があります。いずれも今回の省電力修正から分離します。

## 安全性

Timer停止時はTimer、baseline、保留中の選択前面化要求を同時に無効化します。再開時は現在のsnapshotをbaselineとして保存し、再開そのものを選択変更として扱いません。再開条件は外部通知だけでなく設定とスナップ登録の内部状態遷移から評価し、1秒Recoveryでも再確認します。

選択後のPID、CGWindowID、3回安定確認、現在の可視ウィンドウ完全一致、接続グラフ、AXRaise直前確認、世代番号、試行上限は変更していません。

## 期待効果

- 前面化OFF、連動リサイズOFF、登録0〜1件で約10 Wakeups/sを削減
- 接続グループを利用中の検出性能はv1.2.2と同等
- 1秒Recoveryを維持することで、選択Timerの再評価漏れを最大約1秒で自己修復

効果はMac、CPU、電源状態、同時起動アプリによって異なります。powermetrics、top、Instrumentsの実機再測定を公開条件とします。

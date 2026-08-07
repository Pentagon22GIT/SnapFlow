# SnapFlow v1.2.3 Validation Record

検証基準日: 2026-08-07

## 自動・静的確認

```zsh
git status --short
git diff --check
zsh -n Scripts/*.sh
swift test
./Scripts/build-community.sh
```

- [ ] `MonitoringLifecyclePolicy`の全条件テストが成功する
- [ ] `VERSION=1.2.3`、`BUILD_NUMBER=12`である
- [ ] 新しい外部Package、権限、ネットワーク処理、画面取得、永続保存を追加していない
- [ ] 10Hzポーリング内のPID、Window ID、baseline、3回安定確認を変更していない
- [ ] 前面化直前の可視ウィンドウ完全一致、接続グラフ再解決、世代確認、最大試行回数を変更していない

## Timerライフサイクル

- [ ] 起動直後かつ登録0件では選択Timerが存在しない
- [ ] 登録1件では選択Timerが存在しない
- [ ] 有効状態で登録2件になると、通知を待たずに選択Timerが開始する
- [ ] 前面化設定OFFで選択Timerが即時停止する
- [ ] 連動リサイズOFFで選択Timerが即時停止する
- [ ] SnapFlow無効で選択Timerだけが停止し、1秒Recovery Timerは維持される
- [ ] 再有効化で必要な選択Timerが即時再開する
- [ ] 登録が2件未満になると選択Timerが停止する
- [ ] Timer停止時に古い選択前面化が後から実行されない
- [ ] Timer再開直後の最初のsnapshotだけでは前面化しない
- [ ] 1秒Recovery Timerの周期とRunLoop登録がv1.2.2から変わっていない

## Mission Control・選択回帰

- [ ] 左右、上下、三分割、四分割で通常クリック前面化が維持される
- [ ] Mission Control選択後、おおむね200〜400ms以内に接続相手が前面化する
- [ ] Space切替、Cmd+Tab、同一アプリ内ウィンドウ切替で追加クリックが不要
- [ ] 設定OFFからONへ戻した直後の最初の選択を検出できる
- [ ] 一時的なWindow Server `nil`から復帰後の選択を検出できる
- [ ] ドラッグ、手動リサイズ、つまみ操作、配置中は自動前面化を開始しない
- [ ] 選択中に設定OFFまたは登録解除しても古いグループを前面化しない
- [ ] すでに前面のグループで点滅または連続AXRaiseが発生しない

## 電力・負荷測定

同一Mac、同一電源条件、同等のウィンドウ構成で各状態を最低3回、各60秒測定します。

- [ ] 前面化OFFかつ登録2件以上で、選択Timer由来の約10 Wakeups/sが消える
- [ ] 登録0件と1件で同様に約10 Wakeups/sが消える
- [ ] SnapFlow無効時にも1Hz Recoveryが維持され、10Hz選択監視分だけが削減される
- [ ] 接続あり・前面化ONでは10Hz監視が維持される
- [ ] 接続あり・前面化ONのCPU使用率がv1.2.2から有意に悪化しない
- [ ] Window Server側CPU使用率を複数回測定し、中央値とばらつきを記録する
- [ ] 10分待機してCPU、メモリ、Timer数、保留WorkItemが増加し続けない

## 公式版

- [ ] クリーンな`main`と正確な`v1.2.3`タグから公式ビルドする
- [ ] Universal 2、Hardened Runtime、Bundle ID、Designated Requirementを検証する
- [ ] Release ZIP、SHA-256、manifestを再ダウンロードして検証する
- [ ] 公開成果物でMission Control、再有効化、Timer停止・再開を再度スモークテストする

# RateGadget

Claude Code と Codex CLI のレート制限（使用量制限）の使用率を、Macのメニューバーに常駐して表示するガジェット。

![menu bar] メニューバーに `C`（Claude）と `X`（Codex）の2本のゲージバーを常時表示し、クリックすると各ウィンドウ（5時間 / 週次）の使用率・リセット時刻などの詳細が見られる。

## 仕組み

- **Codex**: `codex app-server` をサブプロセスとして常駐起動し、JSON-RPC の
  `account/rateLimits/read` を60秒ごとにポーリングする。
- **Claude Code**: `~/.claude/settings.json` の `statusLine` 機能を使い、
  ブリッジスクリプト（`~/.claude/rate-gadget-statusline.sh`）が statusLine に流れてくる
  `rate_limits`（5時間 / 7日間の使用率とリセット時刻）を
  `~/Library/Application Support/RateGadget/claude-rate.json` へ書き出す。
  アプリはこのファイルを監視して表示に反映する。
  - Claude Code の TUI セッションがアクティブな間しか更新されないため、
    一定時間更新がない場合は「最終更新 X分前」と表示される。
  - **注意**: Claude Code は statusLine コマンドを `/bin/sh` に引用符なしで渡すため、
    スクリプトのパスに空白を含めてはならない（`Application Support` 配下は不可）。

## ビルド

Xcode不要（Command Line Tools + Swift 6 でビルド可能）。

```sh
./build-app.sh
```

`RateGadget.app` が生成される。ad-hoc署名のため、初回起動でGatekeeperに警告された場合は
Finderで右クリック→「開く」。

## 初回起動時の動作

- `~/.claude/settings.json` に `statusLine` 設定が無ければ自動追加する
  （追加前に `settings.json.bak-<timestamp>` へバックアップを作成）。
- 既に他の `statusLine` 設定がある場合は上書きせず、手動連携の案内をログに出す。

## 構成

```
Sources/RateGadget/
  main.swift                   # エントリポイント
  StatusBarController.swift    # NSStatusItem + ドロップダウンメニュー
  GaugeBarView.swift           # ゲージバー描画
  CodexRateLimitPoller.swift   # codex app-server JSON-RPCクライアント
  ClaudeRateLimitWatcher.swift # ブリッジファイル監視
  StatusLineInstaller.swift    # statusLine 自動設定・移行
  Models.swift                 # 共通モデルとパース
Resources/
  claude-statusline.sh         # statusLine ブリッジスクリプト
```

## 注意事項

- Codex の `app-server` はCLIヘルプ上 `[experimental]` の位置づけ。CLI更新でプロトコルが
  変わる可能性があるため、パースが壊れたら `Models.swift` / 各クライアントを修正する。
- 取得した使用率は外部に送信しない（ローカル表示のみ）。

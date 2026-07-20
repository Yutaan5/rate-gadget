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
  - 主な更新タイミングは「Claudeへメッセージを送信し、アシスタントの応答が完了した後」。
    RateGadgetはブリッジファイルを5秒間隔で確認するため、応答完了後、最大5秒で反映される。
    入力中・応答生成中・Claude Codeがアイドルまたは終了中には更新されない。
  - `/compact`の完了、権限モードの変更、Vimモードの切り替えでもstatusLineは更新される。
  - statusLine入力のうち保存するのは使用率・リセット時刻・更新時刻だけ。セッションID、
    作業ディレクトリ、transcriptパスなどの生入力は保存しない。
  - JSON処理にはmacOS標準のJavaScript for Automationを使うため、`jq`等の追加ツールは不要。

## 表示状態

- `C` / `X`: 正常に取得したClaude / Codexの使用率
- `C·` / `X·`: まだデータを取得していない
- `C!` / `X!` + 灰色ゲージ: データが古い
- `C!` / `X!` + 赤色ゲージ: 取得または連携エラー

Claudeは30分、Codexは3分更新がなければ古いデータとして扱う。古い値を破棄はしないが、
正常な現在値とは区別して表示する。

## ビルド

Xcode不要（Command Line Tools + Swift 6 でビルド可能）。

```sh
./build-app.sh
```

`RateGadget.app` が生成される。ad-hoc署名のため、初回起動でGatekeeperに警告された場合は
Finderで右クリック→「開く」。

## 初回起動時の動作

- `~/.claude` が無い場合は安全に作成する。
- `~/.claude/settings.json` に `statusLine` 設定が無ければ自動追加する。
- 既存ファイルを変更する場合は、先に `settings.json.bak-<timestamp>-<id>` へバックアップする。
- 既に他の `statusLine` 設定がある場合は上書きせず、手動連携の案内をメニューに表示する。
- `settings.json` が不正または読み取れない場合は一切上書きせず、エラーを表示する。

## 表示のカスタマイズ

メニューの「Claude を表示」「Codex を表示」で、ソースごとに表示/非表示を切り替えられる
（設定は `UserDefaults` に保存され再起動後も保持）。非表示にしたソースは描画を消すだけでなく
データ収集ごと停止する：

- Codex 非表示 → `codex app-server` サブプロセスを起動しない
  （Codex CLI をインストールしていない人はこれをオフにする）
- Claude 非表示 → RateGadget自身のstatusLine設定、連携スクリプト、保存済みレートファイルを
  安全に削除する。他のstatusLine設定やClaude設定は変更しない。

## テスト

Xcodeや外部テストライブラリなしで、モデル、日時表示、CLIレスポンスのパース、Claude設定の
導入・解除、ブリッジのプライバシーとファイル権限を検証できる。

```sh
./run-tests.sh
```

## 構成

```
Sources/RateGadget/
  Application.swift            # アプリケーションライフサイクル
  StatusBarController.swift    # NSStatusItem + ドロップダウンメニュー
  GaugeBarView.swift           # ゲージバー描画
  CodexRateLimitPoller.swift   # codex app-server JSON-RPCクライアント
  ClaudeRateLimitWatcher.swift # ブリッジファイル監視
  StatusLineInstaller.swift    # statusLine 自動設定・移行
  Models.swift                 # 共通モデルとパース
Sources/RateGadgetApp/
  main.swift                   # エントリポイント
Resources/
  claude-statusline.sh         # statusLine エントリポイント
  claude-statusline.js         # JSON抽出・原子的書き込み
Tests/RateGadgetTests/
  main.swift                   # Xcode不要の回帰テスト
```

## 注意事項

- Codex の `app-server` はCLIヘルプ上 `[experimental]` の位置づけ。CLI更新でプロトコルが
  変わる可能性があるため、パースが壊れたら `Models.swift` / 各クライアントを修正する。
- 取得した使用率は外部に送信しない（ローカル表示のみ）。

# NagiKasten

macOS ネイティブのターミナルアプリ。日本語入力（IME）のインライン表示と、オンデバイス AI によるコマンド提案・エラー解析を備えています。SwiftUI + [SwiftTerm](https://github.com/inugamine/SwiftTerm-fork)（フォーク）+ Apple Foundation Models で構築しています。

> ⚠️ 個人プロジェクトです。実験的な機能を含みます。

## [配布ページを公開しました](https://www.inugamine.live-on.net/nagikasten)

## スクリーンショット

<!-- TODO: スクリーンショットを docs/ などに置いて貼る -->
![Kasten](Docs/Kasten1.png) 
![Kasten](Docs/Kasten2.png) 


## 特徴

- **日本語インライン入力** — 変換中（未確定）の文字をカーソル位置にセルスナップで表示し、長文は折り返します。一般的なターミナルが苦手とする IME 表示を、描画エンジン側で扱います。
- **AI コマンド提案** — 入力の先頭に `?`（または `？`）を付けて質問すると、AI が実行コマンドを提案。カードから「挿入」または「コピー」できます。
- **エラー解析（⌘E）** — 現在のターミナル画面を解析し、エラーの原因と対処コマンドを提示します。
- **コマンドブロックの区切り線** — シェル統合（OSC 133）でコマンドの境界を検出し、出力をブロックごとに区切って表示。終了コードに応じて色が変わります。
- **見やすい 2 行プロンプト** — `📁 ディレクトリ / 🌿 ブランチ` ＋ 入力行、の Warp 風プロンプト（ユーザーの zsh 設定には手を加えず、Kasten 起動時のみ適用）。
- **ホームディレクトリで起動** — 標準のターミナルと同じく `~/` から開始します。

## 必要環境

- macOS 26.0 以降
- Apple Silicon 搭載 Mac（AI 機能に Apple Foundation Models を使用するため）
- Xcode 26 以降（ビルドする場合）

AI 機能（コマンド提案・エラー解析）は Apple のオンデバイス基盤モデル（Apple Foundation Models）を利用します。推論は端末内で完結し、入力内容が外部に送信されることはありません。

## ビルド方法

```sh
git clone https://github.com/inugamine/NagiKasten.git
cd NagiKasten
open Kasten.xcodeproj
```

Xcode で開くと、依存パッケージ（SwiftTerm のフォーク）が自動的に解決されます。解決が終わったら、`Kasten` スキームを選んで実行（⌘R）してください。

> 依存は [inugamine/SwiftTerm-fork](https://github.com/inugamine/SwiftTerm-fork) を参照しています。手動で解決し直す場合は Xcode の File → Packages → Resolve Package Versions を使ってください。

## 使い方

- 通常のコマンドはそのまま入力して実行します。
- 質問したいときは行頭に `?` を付けて入力 → Enter（例: `?git で特定のコミットを取り消す方法`）。AI の回答カードが下部に表示されます。
- 画面にエラーが出たら ⌘E で解析できます。

## 使用しているソフトウェア

- **[SwiftTerm](https://github.com/inugamine/SwiftTerm-fork)**（フォーク） — VT100/Xterm 互換のターミナルエンジン。MIT License, Copyright (c) Miguel de Icaza ほか。本フォークでは CoreGraphics 描画経路に日本語インライン入力（IME）表示を追加しています。

各ライセンスの全文はアプリの「Kasten について」および各リポジトリの `LICENSE` を参照してください。

## ライセンス

[MIT License](LICENSE) © 2026 inugaminé

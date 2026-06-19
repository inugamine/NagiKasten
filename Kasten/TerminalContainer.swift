//
// TerminalContainer.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//


import SwiftUI
import SwiftTerm
import Combine

/// ターミナルへの操作を ViewModel / View 側から呼べるようにする橋渡し役。
///
/// SwiftUI の世界から NSView(LocalProcessTerminalView)を直接触るのは難しいので、
/// この Coordinator 経由で「文字を流し込む」「画面テキストを読む」を行う。
@MainActor
final class TerminalBridge: ObservableObject {
    /// 実体のターミナルビュー。makeNSView で生成後にセットされる。
    fileprivate weak var terminalView: LocalProcessTerminalView?

    /// ターミナルに文字列を送り込む（ユーザーが手で打ったのと同じ扱い）。
    /// 末尾に "\n" を付ければそのまま実行される。
    func sendToTerminal(_ text: String) {
        guard let terminalView else { return }
        let bytes = Array(text.utf8)[...]
        terminalView.send(data: bytes)
    }

    /// 現在ターミナル画面に見えているテキストを丸ごと取得する。
    /// エラー解析で「いま画面に出ているエラー」をAIに渡すために使う。
    ///
    /// 注意: SwiftTerm の Terminal バッファ API は version によって
    /// メソッド名・シグネチャが異なることがある。実機でビルドが通らない場合は
    /// getLine / getScrollInvariantLine など、その版で公開されている
    /// 行取得 API に合わせて調整すること。
    func snapshotVisibleText() -> String {
        guard let terminalView else { return "" }
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        var lines: [String] = []
        lines.reserveCapacity(rows)

        // 可視範囲の各行を、列ごとに CharData を読んで文字へ復元する。
        // getCharacter() は CharData が保持する Character を返す。
        for y in 0..<rows {
            var lineText = ""
            for x in 0..<cols {
                // 可視バッファ上の (col, row) を指定して CharData を取得する。
                let charData = terminal.getCharData(col: x, row: y)
                let ch = charData?.getCharacter() ?? " "
                // NUL(\0)は空セルなので半角スペースに置き換える
                lineText.append(ch == "\0" ? " " : ch)
            }
            // 行末の余分な空白を落とす
            lines.append(String(lineText.reversed().drop(while: { $0 == " " }).reversed()))
        }

        // 末尾の空行をまとめて削る
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

/// SwiftTerm の LocalProcessTerminalView を SwiftUI に橋渡しする
struct TerminalContainer: NSViewRepresentable {
    /// View 階層から渡されるブリッジ。生成したターミナルをここに登録する。
    @ObservedObject var bridge: TerminalBridge

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)

        // OSのデフォルト配色に合わせる
        terminal.configureNativeColors()

        // ユーザーのログインシェルを起動する
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent

        // zsh の場合だけ、OSC 133 シェル統合を仕込む。
        // ZDOTDIR 方式で、ユーザー設定を壊さずにマーカーを後乗せする。
        var environment = makeBaseEnvironment()
        if shellName == "zsh", let setup = ShellIntegrationSetup.prepare() {
            environment["ZDOTDIR"] = setup.zdotdir
        }
        // "KEY=VALUE" の配列に変換して渡す
        let envArray = environment.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: shell,
            args: ["-l"],                  // ログインシェルとして起動
            environment: envArray,
            execName: "-\(shellName)"      // 先頭の "-" でログインシェル扱いになる
        )

        // ブリッジに実体を登録（次のランループで触れるよう非同期で）
        Task { @MainActor in
            bridge.terminalView = terminal
        }
        return terminal
    }

    /// 親プロセスの環境変数をベースに、ターミナル動作に必要な値を補う。
    private func makeBaseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // ターミナルタイプを明示（色・キー入力の互換性のため）
        env["TERM"] = "xterm-256color"
        return env
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

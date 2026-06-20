//
// TerminalContainer.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//


import SwiftUI
import SwiftTerm
import Combine

/// ターミナルへの操作と、コマンド境界イベントの橋渡し役。
@MainActor
final class TerminalBridge: ObservableObject {
    fileprivate weak var terminalView: LocalProcessTerminalView?
    
    /// OSC 133 のコマンド境界イベントを受け取るコールバック。
    /// ViewModel 側がここに登録して、ブロックの区切りを記録する。
    var onShellEvent: ((ShellIntegrationEvent) -> Void)?
    
    /// ターミナルに文字列を送り込む（実行はuser任せ、末尾に改行は付けない）
    func sendToTerminal(_ text: String) {
        guard let terminalView else { return }
        let bytes = Array(text.utf8)[...]
        terminalView.send(data: bytes)
    }
    
    /// 現在ターミナル画面に見えているテキストを丸ごと取得する（エラー解析用）。
    func snapshotVisibleText() -> String {
        guard let terminalView else { return "" }
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        var lines: [String] = []
        lines.reserveCapacity(rows)
        
        for y in 0..<rows {
            var lineText = ""
            for x in 0..<cols {
                let charData = terminal.getCharData(col: x, row: y)
                let ch = charData?.getCharacter() ?? " "
                lineText.append(ch == "\0" ? " " : ch)
            }
            lines.append(String(lineText.reversed().drop(while: { $0 == " " }).reversed()))
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// ブロック区切り線を描くための透明なオーバーレイビュー。
/// SwiftTerm の描画には一切触れず、その上に重ねて線だけを描く。
/// draw(_:) の奪い合いを避けるため、専用の NSView に分離している。
final class BlockSeparatorOverlay: NSView {
    /// 描く区切り線の y ピクセル位置（ビュー上端からの距離）と色の組。
    struct Separator {
        let yFromTop: CGFloat
        let isError: Bool
    }

    var separators: [Separator] = [] {
        didSet { needsDisplay = true }
    }

    // クリックなどのイベントは下のターミナルに素通しする
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        for sep in separators {
            // AppKit は左下原点なので、上端からの距離を下端からに変換
            let yFlipped = bounds.height - sep.yFromTop
            let color: NSColor = sep.isError
                ? NSColor.systemRed.withAlphaComponent(0.5)
                : NSColor.secondaryLabelColor.withAlphaComponent(0.3)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.0)
            context.beginPath()
            context.move(to: CGPoint(x: 0, y: yFlipped))
            context.addLine(to: CGPoint(x: bounds.width, y: yFlipped))
            context.strokePath()
        }
        context.restoreGState()
    }
}

/// LocalProcessTerminalView を継承し、pty の生バイトを覗いて OSC 133 を拾う。
/// 作者推奨の dataReceived override 方式（Discussion #308）。
/// 検出したコマンド境界は、上に重ねた透明オーバーレイに区切り線として描く。
final class KastenTerminalView: LocalProcessTerminalView {
    /// OSC 133 を検出するパーサ（心臓部）
    private let shellParser = ShellIntegrationParser()
    /// 検出したイベントを外へ流すコールバック
    var onShellEvent: ((ShellIntegrationEvent) -> Void)?

    /// コマンド境界の「スクロール不変の絶対行」を記録する。
    /// 各要素は (絶対行, 直前コマンドの終了コード)。
    private var blockBoundaries: [(absoluteRow: Int, exitCode: Int?)] = []
    private let maxBoundaries = 500

    /// 直前の D（コマンド終了）の終了コードを一時保持する。
    /// 線は A（プロンプト開始）の位置に引くが、色はこの終了コードで決める。
    private var pendingExitCode: Int?

    /// 区切り線を描く透明オーバーレイ
    private let overlay = BlockSeparatorOverlay()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupOverlay()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupOverlay()
    }

    private func setupOverlay() {
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.clear.cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// pty からデータが届くたびに呼ばれる。
    /// まず super に渡して通常描画させ、その後パーサに食わせてマーカーを拾う。
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        let events = shellParser.feed(slice)
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events {
                self.handleEventForDrawing(event)
                self.onShellEvent?(event)
            }
            self.refreshSeparators()
        }
    }

    /// 描画用に境界を記録する。
    /// - D（コマンド終了）: 終了コードを覚えておくだけ（線はまだ引かない）。
    /// - A（プロンプト開始）: 「これからプロンプトが始まる行」の真上に線を引く。
    ///   色は直前に覚えた終了コードで決める。
    private func handleEventForDrawing(_ event: ShellIntegrationEvent) {
        switch event {
        case .commandFinished(let exitCode):
            // 線はここでは引かず、終了コードだけ覚えておく
            pendingExitCode = exitCode

        case .promptStart:
            // 初回プロンプト（まだコマンドを何も実行していない）は線を引かない。
            // 直前に D が来ている（= 1コマンド終わった）場合のみ線を引く。
            guard pendingExitCode != nil else { return }
            let terminal = getTerminal()
            // A の瞬間のカーソル行 = これからプロンプトを描く行
            let cursorY = terminal.getCursorLocation().y
            let topRow = terminal.getTopVisibleRow()
            // カーソル行そのものだとプロンプト行の下になってしまうので、1行上に引く。
            let absoluteRow = topRow + cursorY - 1
            blockBoundaries.append((absoluteRow: absoluteRow, exitCode: pendingExitCode))
            if blockBoundaries.count > maxBoundaries {
                blockBoundaries.removeFirst(blockBoundaries.count - maxBoundaries)
            }
            pendingExitCode = nil

        default:
            break
        }
    }

    /// 記録した境界を、現在のスクロール位置に合わせてオーバーレイへ反映する。
    func refreshSeparators() {
        let terminal = getTerminal()
        let rows = terminal.rows
        guard rows > 0, bounds.height > 0 else {
            overlay.separators = []
            return
        }
        let rowHeight = bounds.height / CGFloat(rows)
        let topRow = terminal.getTopVisibleRow()

        var result: [BlockSeparatorOverlay.Separator] = []
        for boundary in blockBoundaries {
            let visibleRow = boundary.absoluteRow - topRow
            guard visibleRow >= 0, visibleRow < rows else { continue }
            let yFromTop = CGFloat(visibleRow + 1) * rowHeight
            let isError = (boundary.exitCode ?? 0) != 0
            result.append(.init(yFromTop: yFromTop, isError: isError))
        }
        overlay.separators = result
    }

    /// セッションリセット時などに境界をクリアする。
    func clearBlockBoundaries() {
        blockBoundaries.removeAll()
        overlay.separators = []
    }

    /// ターミナルがスクロールされたときに SwiftTerm から通知される。
    /// TerminalViewDelegate のメソッド。override して super を呼んだ上で、
    /// 現在のスクロール位置に合わせて区切り線を引き直す。
    public override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        refreshSeparators()
    }
}

/// SwiftTerm の KastenTerminalView を SwiftUI に橋渡しする
struct TerminalContainer: NSViewRepresentable {
    @ObservedObject var bridge: TerminalBridge
    
    func makeNSView(context: Context) -> KastenTerminalView {
        let terminal = KastenTerminalView(frame: .zero)
        terminal.configureNativeColors()
        
        // OSC 133 イベントをブリッジ経由で ViewModel に流す
        terminal.onShellEvent = { [weak bridge] event in
            bridge?.onShellEvent?(event)
        }
        
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        
        // zsh の場合だけ OSC 133 シェル統合を仕込む（ZDOTDIR 方式）
        var environment = makeBaseEnvironment()
        if shellName == "zsh", let setup = ShellIntegrationSetup.prepare() {
            environment["ZDOTDIR"] = setup.zdotdir
        }
        let envArray = environment.map { "\($0.key)=\($0.value)" }
        
        terminal.startProcess(
            executable: shell,
            args: ["-l"],
            environment: envArray,
            execName: "-\(shellName)"
        )
        
        Task { @MainActor in
            bridge.terminalView = terminal
        }
        return terminal
    }
    
    func updateNSView(_ nsView: KastenTerminalView, context: Context) {}
    
    private func makeBaseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        
        // 日本語ファイル名などが "?????" に化けるのを防ぐ。
        // シェルと ls に「UTF-8 で出力していい」と伝えるロケール設定。
        // 既にユーザーが LANG を持っていればそれを尊重し、無ければ補う。
        if env["LANG"] == nil {
            env["LANG"] = "ja_JP.UTF-8"
        }
        // LC_ALL は全ロケールカテゴリを一括上書きする強い設定。
        // ここでは設定しない（ユーザーの細かい設定を壊さないため）。
        // LANG だけで UTF-8 表示は通常解決する。
        
        return env
    }
}

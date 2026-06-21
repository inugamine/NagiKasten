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

    /// AI質問と判定されたとき、質問文を受け取るコールバック。
    var onAIQuery: ((String) -> Void)?
    
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

    /// 右端をどれだけ手前で止めるか（スクロールバー分の余白）。
    var rightInset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    // クリックなどのイベントは下のターミナルに素通しする
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let rightX = max(0, bounds.width - rightInset)

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
            context.addLine(to: CGPoint(x: rightX, y: yFlipped))
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
    /// AI質問と判定したとき、質問文を外へ渡すコールバック
    var onAIQuery: ((String) -> Void)?

    /// コマンド境界の「スクロール不変の絶対行」を記録する。
    /// 各要素は (絶対行, 直前コマンドの終了コード)。
    private var blockBoundaries: [(absoluteRow: Int, exitCode: Int?)] = []
    private let maxBoundaries = 500

    /// 直前の D（コマンド終了）の終了コードを一時保持する。
    /// 線は A（プロンプト開始）の位置に引くが、色はこの終了コードで決める。
    private var pendingExitCode: Int?

    /// 最初のプロンプトをもう処理したか。
    /// 起動直後の初回プロンプトにも線を出すためのフラグ。
    private var hasDrawnFirstPrompt = false

    /// ユーザーが現在の行に打ち込んだ内容を、文字単位で持つミニ行エディタ。
    /// 日本語1文字も1要素として扱う。カーソル位置(cursorIndex)を持つことで、
    /// 矢印キーで途中に戻って修正してもバッファが画面と一致する。
    /// 文字の蓄積は insertText に一本化し、send は制御キーだけ扱う。
    private var lineBuffer: [Character] = []
    /// カーソル位置（0〜lineBuffer.count）。文字はこの位置に挿入される。
    private var cursorIndex: Int = 0

    /// top や vim などのフルスクリーンアプリ（代替画面バッファ）中かどうか。
    /// 代替画面中は区切り線を描かない（top/vim の画面に線が残るのを防ぐ）。
    private var isAlternateScreen = false

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
        // 右端のスクロールバー分だけ線を手前で止める
        overlay.rightInset = 16
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// レイアウト（ウィンドウリサイズやマージン変更）が起きたら、
    /// 区切り線を現在のサイズに合わせて引き直す。
    public override func layout() {
        super.layout()
        refreshSeparators()
    }

    /// pty からデータが届くたびに呼ばれる。
    /// まず super に渡して通常描画させ、その後パーサに食わせてマーカーを拾う。
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        // top/vim などの代替画面バッファの出入りを検出してフラグを更新する。
        updateAlternateScreenState(slice)

        let events = shellParser.feed(slice)
        guard !events.isEmpty else {
            // イベントが無くても、代替画面の出入りで線の表示を切り替える必要がある
            DispatchQueue.main.async { [weak self] in
                self?.refreshSeparators()
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events {
                self.handleEventForDrawing(event)
                self.onShellEvent?(event)
            }
            self.refreshSeparators()
        }
    }

    /// データスライスから代替画面バッファの出入りシーケンスを検出する。
    /// 入る: ESC[?1049h / ESC[?47h / ESC[?1047h
    /// 出る: ESC[?1049l / ESC[?47l / ESC[?1047l
    /// 完全な CSI パーサは作らず、これらのバイト列が含まれるかを見るだけで実用上十分。
    private func updateAlternateScreenState(_ slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        // ESC [ ? = [27, 91, 63]
        let enterSeqs: [[UInt8]] = [
            [27, 91, 63, 49, 48, 52, 57, 104], // ?1049h
            [27, 91, 63, 49, 48, 52, 55, 104], // ?1047h
            [27, 91, 63, 52, 55, 104],         // ?47h
        ]
        let exitSeqs: [[UInt8]] = [
            [27, 91, 63, 49, 48, 52, 57, 108], // ?1049l
            [27, 91, 63, 49, 48, 52, 55, 108], // ?1047l
            [27, 91, 63, 52, 55, 108],         // ?47l
        ]
        if enterSeqs.contains(where: { containsSubsequence(bytes, $0) }) {
            isAlternateScreen = true
        }
        if exitSeqs.contains(where: { containsSubsequence(bytes, $0) }) {
            isAlternateScreen = false
        }
    }

    /// bytes の中に sub が部分列として含まれるか。
    private func containsSubsequence(_ bytes: [UInt8], _ sub: [UInt8]) -> Bool {
        guard !sub.isEmpty, bytes.count >= sub.count else { return false }
        for start in 0...(bytes.count - sub.count) {
            var matched = true
            for i in 0..<sub.count where bytes[start + i] != sub[i] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
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
            // 原則、直前に D（コマンド終了）が来ている場合に線を引く。
            // ただし、起動直後の「初回プロンプト」だけは D が無くても線を引く。
            let isFirstPrompt = !hasDrawnFirstPrompt
            guard pendingExitCode != nil || isFirstPrompt else { return }
            hasDrawnFirstPrompt = true
            let terminal = getTerminal()
            // A の瞬間のカーソル行 = これからプロンプトを描く行
            let cursorY = terminal.getCursorLocation().y
            let topRow = terminal.getTopVisibleRow()
            // カーソル行そのものだとプロンプト行の下になってしまうので、1行上に引く。
            let absoluteRow: Int
            if isFirstPrompt {
                // 初回プロンプトは画面最上段(cursorY=0)。上に一行余裕が無く
                // 画面外で弾かれるため、プロンプト行そのものに置く。
                absoluteRow = topRow + cursorY
            } else {
                absoluteRow = topRow + cursorY - 1
            }
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
        // top/vim などのフルスクリーンアプリ中は線を一切描かない。
        if isAlternateScreen {
            overlay.separators = []
            return
        }

        let terminal = getTerminal()
        let rows = terminal.rows
        guard rows > 0, bounds.height > 0 else {
            overlay.separators = []
            return
        }

        // 1行の高さ。bounds.height/rows だとマージンで半端が出て下の行ほどズレる。
        // フォントの行高さ（ascent+descent+leading）が実際のセル高さに近いので、
        // それを優先して使い、取れない/異常値なら従来の推定にフォールバックする。
        let estimatedRowHeight = bounds.height / CGFloat(rows)
        let fontRowHeight = ceil(font.ascender - font.descender + font.leading)
        let rowHeight: CGFloat
        if fontRowHeight > 1, fontRowHeight <= estimatedRowHeight + 2 {
            rowHeight = fontRowHeight
        } else {
            rowHeight = estimatedRowHeight
        }

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

    /// 現在のカーソル行のテキストを丸ごと読む。
    /// 履歴(↑キー)やペーストで入力された内容は lineBuffer を通らないため、
    /// Enter 時に lineBuffer が空のときのフォールバックとして画面から直接読む。
    private func readCurrentLineText() -> String {
        let terminal = getTerminal()
        let cols = terminal.cols
        let cursorY = terminal.getCursorLocation().y
        guard cursorY >= 0, cursorY < terminal.rows else { return "" }

        var lineText = ""
        for x in 0..<cols {
            let charData = terminal.getCharData(col: x, row: cursorY)
            let ch = charData?.getCharacter() ?? " "
            lineText.append(ch == "\0" ? " " : ch)
        }
        // 右端の余白を落とす
        return String(lineText.reversed().drop(while: { $0 == " " }).reversed())
    }

    /// プロンプト付きの行テキストから、ユーザーが入力した部分だけを取り出す。
    /// Starship などのプロンプトは末尾が "> " や "$ " や "% " で終わることが多い。
    /// 最後に現れたそれらの区切りの後ろを入力内容とみなす（汎用ヒューリスティック）。
    private func extractInputFromPromptLine(_ line: String) -> String {
        let markers = ["❯ ", "> ", "$ ", "% ", "# "]
        var bestRange: Range<String.Index>?
        for marker in markers {
            if let r = line.range(of: marker, options: .backwards) {
                if bestRange == nil || r.upperBound > bestRange!.upperBound {
                    bestRange = r
                }
            }
        }
        if let r = bestRange {
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        // 区切りが見つからなければ行全体を返す
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// ターミナルがスクロールされたときに SwiftTerm から通知される。
    /// TerminalViewDelegate のメソッド。override して super を呼んだ上で、
    /// 現在のスクロール位置に合わせて区切り線を引き直す。
    public override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        refreshSeparators()
    }

    /// ユーザーの制御キーを処理する（文字の蓄積は insertText 側）。
    /// 矢印でカーソル位置を動かし、Backspace でその位置を削除、Enter で判別する。
    /// 描画は zsh に任せるので、制御キーは super をそのまま呼ぶ。
    public override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)

        // ← 左矢印 (ESC [ D): カーソルを1つ左へ
        if bytes == [27, 91, 68] {
            if cursorIndex > 0 { cursorIndex -= 1 }
            super.send(source: source, data: data)
            return
        }
        // → 右矢印 (ESC [ C): カーソルを1つ右へ
        if bytes == [27, 91, 67] {
            if cursorIndex < lineBuffer.count { cursorIndex += 1 }
            super.send(source: source, data: data)
            return
        }
        // ↑↓ 上下矢印 (ESC [ A / B): 履歴呼び出し。
        // 履歴は zsh 側で行が丸ごと差し替わり、バッファとズレる。
        // 今回はスコープ外なので、誤判定を防ぐためバッファをクリアする。
        if bytes == [27, 91, 65] || bytes == [27, 91, 66] {
            lineBuffer.removeAll()
            cursorIndex = 0
            super.send(source: source, data: data)
            return
        }

        for byte in bytes {
            switch byte {
            case 13: // Enter (\r)
                // 通常は lineBuffer を使うが、空のとき（履歴・ペースト）は
                // 画面の現在行を読んでフォールバックする。
                let line: String
                if lineBuffer.isEmpty {
                    let raw = readCurrentLineText()
                    line = extractInputFromPromptLine(raw)
                } else {
                    line = String(lineBuffer)
                }
                let classification = InputClassifier.classify(line)
                switch classification {
                case .aiQuery(let question):
                    // AI質問: Enter を送らず、Ctrl-U(21) で行を消してから AI へ
                    super.send(source: source, data: [21][...])
                    let q = question
                    DispatchQueue.main.async { [weak self] in
                        self?.onAIQuery?(q)
                    }
                case .command:
                    // コマンド: そのまま Enter を送る
                    super.send(source: source, data: [13][...])
                }
                lineBuffer.removeAll()
                cursorIndex = 0

            case 127, 8: // Backspace / Delete
                // カーソルの手前の文字を削除
                if cursorIndex > 0 {
                    lineBuffer.remove(at: cursorIndex - 1)
                    cursorIndex -= 1
                }
                super.send(source: source, data: [byte][...])

            case 21: // Ctrl-U (行全体クリア)
                lineBuffer.removeAll()
                cursorIndex = 0
                super.send(source: source, data: [byte][...])

            case 3: // Ctrl-C
                lineBuffer.removeAll()
                cursorIndex = 0
                super.send(source: source, data: [byte][...])

            default:
                // 文字の蓄積は insertText 側に任せるので、ここでは溜めない。
                // （英語も日本語も文字は insertText を通るため、二重蓄積を避ける）
                super.send(source: source, data: [byte][...])
            }
        }
    }

    /// 英語・日本語を問わず、確定文字はここを通る（NSTextInputClient）。
    /// 現在のカーソル位置に文字を挿入して、カーソルをその分進める。
    /// 覆いたら必ず super を呼んで SwiftTerm 本来の処理を壊さないこと。
    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            text = ""
        }
        // カーソル位置に1文字ずつ挿入していく
        for ch in text {
            let idx = min(max(cursorIndex, 0), lineBuffer.count)
            lineBuffer.insert(ch, at: idx)
            cursorIndex = idx + 1
        }
        super.insertText(string, replacementRange: replacementRange)
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

        // AI質問と判定された入力をブリッジ経由で ViewModel に流す
        terminal.onAIQuery = { [weak bridge] question in
            bridge?.onAIQuery?(question)
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

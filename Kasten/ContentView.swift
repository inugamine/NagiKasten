//
// ContentView.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//


import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = KastenViewModel()
    @StateObject private var bridge = TerminalBridge()
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    /// AI/エラーパネルの実測高さ。ターミナルをこの分だけ持ち上げて被りを防ぐ。
    @State private var panelHeight: CGFloat = 0

    /// 現在のテーマ。system はシステムの明暗に合わせる。
    private var effectiveTheme: KastenTheme {
        switch themeStore.mode {
        case .light:  return .light
        case .dark:   return .dark
        case .custom: return themeStore.customTheme
        case .system: return (colorScheme == .dark) ? .dark : .light
        }
    }

    /// 背景。テーマの上端→下端へ縦グラデを敷く（下端が無いテーマは単色）。
    /// ターミナルのセル背景は透明なので、このグラデが文字の裏まで透けて見える。
    private var effectiveBackground: LinearGradient {
        let theme = effectiveTheme
        return LinearGradient(
            colors: [Color(nsColor: theme.gradientTopColor.nsColor),
                     Color(nsColor: theme.gradientBottomColor.nsColor)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// SwiftUI クローム（AI/エラーパネル）に適用する明暗モード。
    /// ターミナルテーマの選択に追従させ、パネルの material と文字色をまとめて切り替える。
    /// これが無いと、システムがライトでテーマだけダークのとき、
    /// パネルの文字が暗いままダーク背景に埋もれて読めなくなる。
    private var effectiveColorScheme: ColorScheme {
        switch themeStore.mode {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return colorScheme
        case .custom:
            // 背景の相対輝度で明暗を判定する（ITU-R BT.601 係数）。
            let bg = themeStore.customTheme.background
            let luma = 0.299 * Double(bg.r) + 0.587 * Double(bg.g) + 0.114 * Double(bg.b)
            return luma < 128 ? .dark : .light
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // ウィンドウ全体をターミナル背景色で埋める（角丸の内側まで回り込ませる）。
            // これが無いと、ターミナルにマージンを付けたときに角に地が見える。
            effectiveBackground
                .ignoresSafeArea()

            // ターミナル本体。上下左右にマージンを設けて、
            // ウィンドウの角丸で文字（行頭の s など）が見切れるのを防ぐ。
            // 上端はタイトルバー裏に隠れないようセーフエリアを尊重する。
            TerminalContainer(bridge: bridge, themeStore: themeStore)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .ignoresSafeArea(edges: [.bottom])
                // AI/エラーパネルが出ている間は、その高さぶんターミナルを持ち上げて、
                // 末尾の行がパネルに隠れないようにする（スクロールで全行見えるようにする）。
                .padding(.bottom, panelHeight)

            // オーバーレイ群（下からせり上がる）
            VStack(spacing: 0) {
                if viewModel.isAnswerPanelVisible {
                    AIAnswerView(viewModel: viewModel) { command in
                        // 抽出されたコマンドをターミナルに挿入（実行はユーザーに委ねる）
                        bridge.sendToTerminal(command)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if viewModel.isErrorPanelVisible {
                    ErrorPanelView(viewModel: viewModel) { command in
                        bridge.sendToTerminal(command)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                }
            )
            // AI/エラーパネルの明暗を、ターミナルテーマの選択に追従させる。
            .environment(\.colorScheme, effectiveColorScheme)
        }
        .onPreferenceChange(PanelHeightKey.self) { height in
            panelHeight = height
        }
        .onAppear {
            // ターミナルで AI質問と判定された入力を ViewModel へ流す
            bridge.onAIQuery = { question in
                Task { await viewModel.askAI(question) }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // エラー解析（現在の画面を解析）
                Button {
                    let snapshot = bridge.snapshotVisibleText()
                    Task { await viewModel.analyzeTerminal(snapshot: snapshot) }
                } label: {
                    Label("エラー解析", systemImage: "stethoscope")
                }
                .help("現在のターミナル画面のエラーを解析（⌘E）")
            }
        }
        // キーボードショートカット（不可視ボタンで実装）
        .background {
            Group {
                Button("") {
                    let snapshot = bridge.snapshotVisibleText()
                    Task { await viewModel.analyzeTerminal(snapshot: snapshot) }
                }
                .keyboardShortcut("e", modifiers: .command)
            }
            .opacity(0)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeStore())
}

/// AI/エラーパネルの高さを上位ビューへ伝えるための PreferenceKey。
private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

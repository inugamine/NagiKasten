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
    /// AI/エラーパネルの実測高さ。ターミナルをこの分だけ持ち上げて被りを防ぐ。
    @State private var panelHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            // ウィンドウ全体をターミナル背景色で埋める（角丸の内側まで回り込ませる）。
            // これが無いと、ターミナルにマージンを付けたときに角に地が見える。
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()

            // ターミナル本体。上下左右にマージンを設けて、
            // ウィンドウの角丸で文字（行頭の s など）が見切れるのを防ぐ。
            // 上端はタイトルバー裏に隠れないようセーフエリアを尊重する。
            TerminalContainer(bridge: bridge)
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
}

/// AI/エラーパネルの高さを上位ビューへ伝えるための PreferenceKey。
private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

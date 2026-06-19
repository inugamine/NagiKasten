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

    var body: some View {
        ZStack(alignment: .bottom) {
            // ターミナル本体（最背面・上端以外を全面に）
            // 上端だけセーフエリアを尊重して、タイトルバーの裏に行が隠れないようにする。
            TerminalContainer(bridge: bridge)
                .ignoresSafeArea(edges: [.horizontal, .bottom])

            // オーバーレイ群（下からせり上がる）
            VStack(spacing: 0) {
                if viewModel.isErrorPanelVisible {
                    ErrorPanelView(viewModel: viewModel) { command in
                        bridge.sendToTerminal(command)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if viewModel.isCommandBarVisible {
                    CommandBarView(viewModel: viewModel) { command in
                        // サジェストされたコマンドはターミナルに挿入（実行はユーザーに委ねる）
                        bridge.sendToTerminal(command)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // コマンドバー表示トグル
                Button {
                    viewModel.toggleCommandBar()
                } label: {
                    Label("コマンド提案", systemImage: "sparkles")
                }
                .help("自然言語からコマンドを提案（⌘K）")

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
                Button("") { viewModel.toggleCommandBar() }
                    .keyboardShortcut("k", modifiers: .command)

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

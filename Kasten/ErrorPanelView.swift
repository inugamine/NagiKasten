//
// ErrorPanelView.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//

import SwiftUI

/// エラー解析結果を表示するスライドアップパネル
struct ErrorPanelView: View {
    @ObservedObject var viewModel: KastenViewModel
    /// ターミナルにコマンド文字列を挿入する（改行は付けない＝実行はユーザーに委ねる）
    var onInsertCommand: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ヘッダー
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                Text("エラー解析")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Button(action: { viewModel.dismissErrorPanel() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // 検出されたエラー（折りたたみ）
            DisclosureGroup("ターミナル画面の内容") {
                ScrollView {
                    Text(viewModel.detectedError)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 80)
            }
            .font(.system(size: 12))

            if viewModel.isAnalyzing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("解析中...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if let analysis = viewModel.errorAnalysis {
                analysisContent(analysis)
            } else if let message = viewModel.errorMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 8, y: -2)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func analysisContent(_ analysis: ErrorAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 原因
            VStack(alignment: .leading, spacing: 4) {
                Text("原因")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(analysis.cause)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }

            // 解決策
            VStack(alignment: .leading, spacing: 4) {
                Text("解決策")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(analysis.solution)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }

            // 修正コマンド（あれば）
            if !analysis.fixCommand.isEmpty {
                HStack {
                    Text("$")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(analysis.fixCommand)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)

                    Spacer()

                    Button("挿入") {
                        // 改行を付けず、ユーザーが内容を確認してから実行できるようにする
                        onInsertCommand(analysis.fixCommand)
                        viewModel.dismissErrorPanel()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

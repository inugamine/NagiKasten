//
// ErrorPanelView.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//

import SwiftUI

/// エラー解析結果を表示するスライドアップパネル
///
/// 装飾は AI パネルと同じ様式（階段角＋二重ヘアライン＋四隅の補強線）を使うが、
/// 色は意図的に分けている。理由は accent の説明を参照。
struct ErrorPanelView: View {
    @ObservedObject var viewModel: KastenViewModel
    /// 現在の配色。装飾時の色をここから引く。
    var theme: KastenTheme
    /// 装飾を纏うか。AppearanceMode.isOrnamented をそのまま受け取る。
    var isOrnamented: Bool
    /// ターミナルにコマンド文字列を挿入する（改行は付けない＝実行はユーザーに委ねる）
    var onInsertCommand: (String) -> Void

    /// このパネルの性格を示す色。装飾時はオックスブラッド（ANSI 1 番）。
    /// AI パネルの真鍮とは意図的に分けている。
    /// 額縁まで同じ金にすると、パネルがせり上がってきた瞬間に
    /// 「提案」なのか「エラー」なのかが一目で判別できなくなる。
    private var accent: Color {
        isOrnamented ? Color(nsColor: theme.ansi[1].nsColor) : .red
    }

    /// 操作できる場所を示す色。装飾時は真鍮（ANSI 3 番）。
    /// 「押せば何かが起きる」印は、どちらのパネルでも共通にする。
    private var actionColor: Color {
        isOrnamented ? Color(nsColor: theme.ansi[3].nsColor) : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ヘッダー
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(accent)

                Text("エラー解析")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                // 閉じるボタンは accent ではなく actionColor を使う。
                // ここを額縁と同じオックスブラッドにすると、
                // 警告の三角と赤い丸が並んで、どちらが操作対象か読めなくなる。
                PanelCloseButton(isOrnamented: isOrnamented,
                                 accent: actionColor,
                                 knockout: Color(nsColor: theme.background.nsColor)) {
                    viewModel.dismissErrorPanel()
                }
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
                    .foregroundStyle(accent)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        // AI パネルと同じ外装を使う。形は揃え、色だけ分ける。
        .panelChrome(isOrnamented: isOrnamented, accent: accent)
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
                    // 装飾時はシェルの $ を菱形に差し替える。
                    Text(verbatim: isOrnamented ? "◈" : "$")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(isOrnamented ? actionColor : Color.secondary)
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
                    .tint(actionColor)
                    .controlSize(.small)
                }
                .padding(8)
                .background(actionColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

//
// AIAnswerView.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//


import SwiftUI

/// ターミナルで "?〜" と打ったときの、AIコマンド提案を表示するパネル。
/// 自由テキストの長い回答ではなく、コマンド＋短い説明をピンポイントで出す。
///
/// 装飾はテーマに連動する。アール・デコのときだけ真鍮の枠と
/// 字間を開けた見出しを纏い、それ以外のテーマでは既定の見た目のままにする。
struct AIAnswerView: View {
    @ObservedObject var viewModel: KastenViewModel
    /// 現在の配色。装飾時のアクセント色をここから引く。
    var theme: KastenTheme
    /// 装飾を纏うか。AppearanceMode.isOrnamented をそのまま受け取る。
    var isOrnamented: Bool
    /// 提案コマンドをターミナルに挿入するコールバック
    var onInsertCommand: (String) -> Void

    /// アクセント色。装飾時はテーマの真鍮（ANSI 3 番）を使う。
    /// ここで 16 進を直書きしないのはプロンプトと同じ理由で、
    /// 後でパレットを調整したときにカードだけ古い金色が残るのを防ぐため。
    private var accent: Color {
        isOrnamented ? Color(nsColor: theme.ansi[3].nsColor) : .purple
    }

    /// 警告の色。装飾時はオックスブラッド（ANSI 1 番）。
    /// アクセントとは別色に保つことで、警告を警告として読ませる。
    private var warningColor: Color {
        isOrnamented ? Color(nsColor: theme.ansi[1].nsColor) : .orange
    }

    /// 非装飾時の角の丸み。装飾時は角丸ではなく階段状の形を使うのでここは使われない。
    private var cornerRadius: CGFloat { 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            questionRow
            dividerRow
            contentRow
        }
        .padding(16)
        .background(.ultraThinMaterial)
        // 切り抜きと縁取りをまとめて当てる。
        // 装飾時は階段角＋真鍮の二重ヘアライン。
        .panelChrome(isOrnamented: isOrnamented, accent: accent, cornerRadius: cornerRadius)
        .shadow(color: .black.opacity(0.2), radius: 8, y: -2)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// 見出し行。装飾時は菱形＋字間を開けたラベルに差し替える。
    /// ここは等幅グリッドの外なので、ターミナル本体では作れない字間の制御が効く。
    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if isOrnamented {
                Text(verbatim: "◈")
                    .font(.system(size: 12))
                    .foregroundStyle(accent)
                Text(verbatim: "SUGGESTION")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(3)
                    .foregroundStyle(accent)
            } else {
                Image(systemName: "sparkles")
                    .foregroundStyle(accent)
                Text("AI")
                    .font(.system(size: 14, weight: .semibold))
            }
            Spacer()
            Button(action: { viewModel.dismissAnswerPanel() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// 質問文。
    private var questionRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: "Q.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(viewModel.aiQuestion)
                .font(.system(size: 13))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    /// 区切り線。装飾時は両端が消える真鍮の罫と、中央の菱形にする。
    ///
    /// 一本線をそのまま引くと単なる仕切りだが、中央に焦点を置いて
    /// 両端を消すと、線自体が意匠になる。菱形はプロンプトと同じ ◈ を使い、
    /// ターミナル本体と語彙を揃える。
    @ViewBuilder
    private var dividerRow: some View {
        if isOrnamented {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(LinearGradient(colors: [accent.opacity(0), accent.opacity(0.45)],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(height: 1)
                Text(verbatim: "◈")
                    .font(.system(size: 9))
                    .foregroundStyle(accent.opacity(0.9))
                Rectangle()
                    .fill(LinearGradient(colors: [accent.opacity(0.45), accent.opacity(0)],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(height: 1)
            }
        } else {
            Divider()
        }
    }

    /// 中身。回答待ち・提案・エラーのいずれか。
    @ViewBuilder
    private var contentRow: some View {
        if viewModel.isAnswering {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("考え中...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if let suggestion = viewModel.aiSuggestion {
            suggestionCard(suggestion)
        } else if let message = viewModel.errorMessage {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
    }

    /// コマンド提案カード（コマンド＋説明＋警告＋挿入/コピーボタン）。
    @ViewBuilder
    private func suggestionCard(_ suggestion: CommandSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // コマンド表示
            HStack {
                // 装飾時はシェルの $ を菱形に差し替え、真鍮で拾う。
                Text(verbatim: isOrnamented ? "◈" : "$")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(isOrnamented ? accent : Color.secondary)

                Text(suggestion.command)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                Spacer()

                Button("挿入") {
                    onInsertCommand(suggestion.command)
                    viewModel.dismissAnswerPanel()
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.small)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(suggestion.command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // 説明
            Text(suggestion.explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            // 警告（あれば）
            if !suggestion.warning.isEmpty {
                Label(suggestion.warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(warningColor)
            }
        }
    }
}

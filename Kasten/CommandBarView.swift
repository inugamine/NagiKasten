//
// CommandBarView.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//

import SwiftUI

/// 自然言語からコマンドをサジェストするバー（画面下部にオーバーレイ表示）
struct CommandBarView: View {
    @ObservedObject var viewModel: KastenViewModel
    var onInsertCommand: (String) -> Void
    
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // サジェスト結果
            if let suggestion = viewModel.suggestion {
                suggestionCard(suggestion)
            }

            // 失敗メッセージ
            if let message = viewModel.errorMessage, viewModel.suggestion == nil {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            
            // 入力バー
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                    .font(.system(size: 14))
                
                TextField("やりたいことを入力...", text: $viewModel.commandBarInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .default))
                    .focused($isInputFocused)
                    .onSubmit {
                        Task { await viewModel.requestSuggestion() }
                    }
                
                if viewModel.isSuggesting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: {
                        Task { await viewModel.requestSuggestion() }
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.commandBarInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                Button(action: { viewModel.dismissCommandBar() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 8, y: -2)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear { isInputFocused = true }
    }
    
    @ViewBuilder
    private func suggestionCard(_ suggestion: CommandSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // コマンド表示
            HStack {
                Text("$")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Text(suggestion.command)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                
                Spacer()
                
                Button("挿入") {
                    onInsertCommand(suggestion.command)
                    viewModel.dismissCommandBar()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
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
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }
}

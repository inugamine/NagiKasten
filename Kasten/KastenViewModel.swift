//
// KastenViewModel.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//

import Foundation
import SwiftUI
import Combine

/// Kasten のメイン状態管理
@MainActor
final class KastenViewModel: ObservableObject {

    // MARK: - AI サービス

    let aiService = AIService()

    // MARK: - コマンドバー状態

    @Published var commandBarInput: String = ""
    @Published var suggestion: CommandSuggestion?
    @Published var isSuggesting: Bool = false
    @Published var isCommandBarVisible: Bool = false

    // MARK: - エラーパネル状態

    @Published var errorAnalysis: ErrorAnalysis?
    @Published var isAnalyzing: Bool = false
    @Published var isErrorPanelVisible: Bool = false
    @Published var detectedError: String = ""

    // MARK: - エラーメッセージ（サジェスト失敗時など）

    @Published var errorMessage: String?

    // MARK: - ブロック境界（OSC 133）
    
    /// 検出したコマンドブロックの区切り位置（出力テキストの行数ベースで後で使う）。
    /// まずは動作確認のためイベントを受け取れることだけ確認する。
    @Published var blockCount: Int = 0

    // MARK: - コマンドサジェスト

    func requestSuggestion() async {
        let input = commandBarInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        isSuggesting = true
        suggestion = nil
        errorMessage = nil

        do {
            let result = try await aiService.suggestCommand(from: input)
            suggestion = result
        } catch {
            errorMessage = "サジェストに失敗しました: \(error.localizedDescription)"
        }

        isSuggesting = false
    }

    // MARK: - エラー解析

    /// ターミナル画面のスナップショットを渡して解析する。
    /// 画面テキスト全体を AI に見せ、直近のコマンドとエラーを判断させる。
    func analyzeTerminal(snapshot: String) async {
        let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "ターミナルに解析できる内容がありません。"
            return
        }

        detectedError = trimmed
        isErrorPanelVisible = true
        isAnalyzing = true
        errorAnalysis = nil
        errorMessage = nil

        do {
            let result = try await aiService.analyzeError(terminalText: trimmed)
            errorAnalysis = result
        } catch {
            errorMessage = "エラー解析に失敗しました: \(error.localizedDescription)"
        }

        isAnalyzing = false
    }

    func dismissErrorPanel() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isErrorPanelVisible = false
        }
        errorAnalysis = nil
        detectedError = ""
    }

    // MARK: - コマンドバー表示切替

    func toggleCommandBar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isCommandBarVisible.toggle()
        }
        if isCommandBarVisible {
            commandBarInput = ""
            suggestion = nil
        }
    }

    func dismissCommandBar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isCommandBarVisible = false
        }
        commandBarInput = ""
        suggestion = nil
    }
}

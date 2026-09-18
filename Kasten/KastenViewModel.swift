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

    // MARK: - エラーパネル状態

    @Published var errorAnalysis: ErrorAnalysis?
    @Published var isAnalyzing: Bool = false
    @Published var isErrorPanelVisible: Bool = false
    @Published var detectedError: String = ""

    // MARK: - エラーメッセージ（サジェスト失敗時など）

    @Published var errorMessage: String?

    // MARK: - AIコマンド提案（ターミナルで "?〜" と打ったとき）

    /// ユーザーが投げた質問文
    @Published var aiQuestion: String = ""
    /// AI のコマンド提案結果
    @Published var aiSuggestion: CommandSuggestion?
    /// 回答待ち中か
    @Published var isAnswering: Bool = false
    /// 回答パネルを表示するか
    @Published var isAnswerPanelVisible: Bool = false

    /// ターミナルで AI質問を打ち始めたときに呼ばれる。モデルの読み込みを先に始める。
    /// 実際に質問が飛んでくるまでの入力時間が、そのまま読み込みの猶予になる。
    func prewarmAI() {
        aiService.prewarmSuggestion()
    }

    /// ターミナルで AI質問と判定された入力を受けて、コマンドを提案させる。
    func askAI(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        aiQuestion = trimmed
        aiSuggestion = nil
        isAnswerPanelVisible = true
        isAnswering = true
        errorMessage = nil

        do {
            let result = try await aiService.suggestCommand(from: trimmed)
            aiSuggestion = result
        } catch {
            errorMessage = String(localized: "AIへの問い合わせに失敗しました: \(error.localizedDescription)")
        }

        isAnswering = false
    }

    func dismissAnswerPanel() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isAnswerPanelVisible = false
        }
        aiSuggestion = nil
        aiQuestion = ""
        // 使われなかった prewarm 済みセッションを抱えたままにしない。
        aiService.discardPrewarmedSession()
    }

    // MARK: - エラー解析

    /// ターミナル画面のスナップショットを渡して解析する。
    /// 画面テキスト全体を AI に見せ、直近のコマンドとエラーを判断させる。
    func analyzeTerminal(snapshot: String) async {
        let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "ターミナルに解析できる内容がありません。")
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
            errorMessage = String(localized: "エラー解析に失敗しました: \(error.localizedDescription)")
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
}

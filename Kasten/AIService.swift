//
// AIService.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//

import Foundation
import FoundationModels
import Combine

/// Apple Foundation Models をラップしてコマンドサジェストとエラー解析を提供する。
///
/// サジェスト用とエラー解析用でセッションを分けている。
/// Apple は「個別の単発タスクごとに新しいセッションを作る」ことを推奨しているため、
/// 役割ごとに instructions 付きの専用セッションを用意している。
@MainActor
final class AIService: ObservableObject {

    /// モデルが利用可能かどうか
    var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// 利用不可の理由（UI 表示用）。利用可能なら nil。
    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "この Mac は Apple Intelligence に対応していません。"
            case .appleIntelligenceNotEnabled:
                return "設定から Apple Intelligence を有効にしてください。"
            case .modelNotReady:
                return "モデルを準備中です。しばらく待ってから再度お試しください。"
            @unknown default:
                return "Apple Intelligence が利用できません。"
            }
        @unknown default:
            return "Apple Intelligence が利用できません。"
        }
    }

    // MARK: - コマンドサジェスト

    /// 自然言語の説明からシェルコマンドを提案する。
    /// 単発タスクなので呼び出しごとに専用セッションを生成する。
    func suggestCommand(from naturalLanguage: String) async throws -> CommandSuggestion {
        guard isAvailable else { throw AIServiceError.modelUnavailable }

        let instructions = """
        あなたは macOS のターミナルに精通したアシスタントです。
        ユーザーがやりたいことを説明するので、それを実現する適切なシェルコマンドを提案します。
        - command には実行すべきコマンドを1行で入れてください。複数手順が必要なら && でつなぎます。
        - explanation にはそのコマンドが何をするかを日本語で簡潔に書きます。
        - rm -rf やデータを破壊しうるコマンドなど危険な操作の場合のみ、warning に注意書きを書きます。安全なら warning は空文字にします。
        """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: naturalLanguage,
            generating: CommandSuggestion.self
        )
        return response.content
    }

    // MARK: - エラー解析

    /// ターミナルの画面テキストを解析して、原因と解決策を説明する。
    /// こちらも単発タスクなので呼び出しごとに専用セッションを生成する。
    func analyzeError(terminalText: String) async throws -> ErrorAnalysis {
        guard isAvailable else { throw AIServiceError.modelUnavailable }

        let instructions = """
        あなたは macOS のターミナルエラーを解析するアシスタントです。
        ターミナル画面に表示されているテキスト全体を渡すので、その中から直近に実行された
        コマンドとそのエラー出力を読み取り、原因と解決策を説明してください。
        - cause にはエラーの原因を日本語で簡潔に説明します。
        - solution には解決策を日本語で説明します。
        - 修正に使えるコマンドがあれば fixCommand に1行で入れます。なければ空文字にします。
        """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "次のターミナル画面を解析してください:\n\n\(terminalText)",
            generating: ErrorAnalysis.self
        )
        return response.content
    }
}

// MARK: - Generable 構造体

@Generable
struct CommandSuggestion: Equatable {
    @Guide(description: "実行すべきシェルコマンドを1行で")
    var command: String

    @Guide(description: "コマンドの簡潔な説明（日本語）")
    var explanation: String

    @Guide(description: "危険なコマンドの場合の注意書き。安全なら空文字")
    var warning: String
}

@Generable
struct ErrorAnalysis: Equatable {
    @Guide(description: "エラーの原因の簡潔な説明（日本語）")
    var cause: String

    @Guide(description: "解決策の提案（日本語）")
    var solution: String

    @Guide(description: "修正に使えるコマンド（あれば）。なければ空文字")
    var fixCommand: String
}

// MARK: - エラー型

enum AIServiceError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Apple Intelligence が利用できません。設定から有効にしてください。"
        }
    }
}

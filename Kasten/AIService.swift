//
// AIService.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//

import Foundation
import FoundationModels
import NaturalLanguage
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
                return String(localized: "この Mac は Apple Intelligence に対応していません。")
            case .appleIntelligenceNotEnabled:
                return String(localized: "設定から Apple Intelligence を有効にしてください。")
            case .modelNotReady:
                return String(localized: "モデルを準備中です。しばらく待ってから再度お試しください。")
            @unknown default:
                return String(localized: "Apple Intelligence が利用できません。")
            }
        @unknown default:
            return String(localized: "Apple Intelligence が利用できません。")
        }
    }

    // MARK: - 回答言語の決定

    /// OS の優先言語の先頭から言語コード（"ja" "de" など）を取り出す。
    // Locale.current はアプリがローカライズ対応済みの言語に制限されるため、
    // preferredLanguages でユーザー本来の優先言語をそのまま取る。
    private static func preferredLanguageCode() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return Locale(identifier: preferred).language.languageCode?.identifier ?? "en"
    }

    /// 言語コードが Foundation Models のサポート対象ならそのまま、対象外なら "en" を返す。
    /// サポート一覧はモデル自身から取るので、将来対応言語が増えても自動で追従する。
    private static func supportedOrEnglish(_ code: String) -> String {
        let candidate = Locale.Language(identifier: code)
        let supported = SystemLanguageModel.default.supportedLanguages
        let isSupported = supported.contains { $0.languageCode == candidate.languageCode }
        return isSupported ? code : "en"
    }

    /// 言語コードを英語表記の言語名（"Japanese" "German" など）へ変換する。
    /// モデルへ渡す言語指定は英語表記が最も確実に伝わる。
    private static func englishName(forLanguageCode code: String) -> String {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? "English"
    }

    /// エラー解析用：OS の優先言語で回答する（サポート外なら英語）。
    /// 解析対象はほぼ英語のターミナル出力なので、入力テキストからの言語判定は使わない。
    private static func responseLanguageName() -> String {
        englishName(forLanguageCode: supportedOrEnglish(preferredLanguageCode()))
    }

    /// コマンドサジェスト用：質問文そのものの言語で回答する。
    /// 判定不能なら OS 優先言語へ、サポート外なら英語へフォールバックする。
    private static func responseLanguageName(for text: String) -> String {
        // かな・ハングルは言語をほぼ一意に特定できるので、統計的判定より先に見る。
        // ターミナルの質問はコマンド名（ラテン文字）が混ざりやすく、
        // 統計的判定だけだと「git で commit するには？」が英語に倒れてしまう。
        if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) {
            // ひらがな（U+3040-309F）・カタカナ（U+30A0-30FF）→ 日本語確定
            return englishName(forLanguageCode: supportedOrEnglish("ja"))
        }
        if text.unicodeScalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) {
            // ハングル音節文字（U+AC00-D7AF）→ 韓国語確定
            return englishName(forLanguageCode: supportedOrEnglish("ko"))
        }

        let recognizer = NLLanguageRecognizer()
        // 短い入力での誤判定を減らすため、OS の優先言語をヒントとして与える。
        var hints: [NLLanguage: Double] = [:]
        for (index, identifier) in Locale.preferredLanguages.prefix(3).enumerated() {
            if let code = Locale(identifier: identifier).language.languageCode?.identifier {
                hints[NLLanguage(rawValue: code)] = 0.4 - Double(index) * 0.1
            }
        }
        recognizer.languageHints = hints
        recognizer.processString(text)

        let code = recognizer.dominantLanguage?.rawValue ?? preferredLanguageCode()
        return englishName(forLanguageCode: supportedOrEnglish(code))
    }

    // MARK: - エラー解析

    /// ターミナルの画面テキストを解析して、原因と解決策を説明する。
    /// こちらも単発タスクなので呼び出しごとに専用セッションを生成する。
    func analyzeError(terminalText: String) async throws -> ErrorAnalysis {
        guard isAvailable else { throw AIServiceError.modelUnavailable }

        let language = Self.responseLanguageName()
        let instructions = """
        You are an assistant that analyzes macOS terminal errors.
        You will be given the entire text shown on the terminal screen. From it, identify the most recently executed command and its error output, then explain the cause and the solution.
        - In `cause`, concisely explain the cause of the error.
        - In `solution`, explain how to resolve it.
        - If there is a command that can fix the issue, put it on a single line in `fixCommand`. Otherwise leave it as an empty string.
        - Always write `cause` and `solution` in \(language).
        """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Analyze the following terminal screen:\n\n\(terminalText)",
            generating: ErrorAnalysis.self
        )
        return response.content
    }

    // MARK: - コマンドサジェスト

    /// 自然言語の説明からシェルコマンドを提案する。
    /// ターミナルで "?〜" と打ったときに呼ばれる。
    /// 自由テキストの長い回答ではなく、コマンド＋短い説明をピンポイントで返す。
    func suggestCommand(from naturalLanguage: String) async throws -> CommandSuggestion {
        guard isAvailable else { throw AIServiceError.modelUnavailable }

        let language = Self.responseLanguageName(for: naturalLanguage)
        let instructions = """
        You are an assistant well-versed in the macOS terminal.
        The user describes what they want to do; propose an appropriate shell command to achieve it.
        - Put the command to run on a single line in `command`. If multiple steps are required, join them with &&.
        - In `explanation`, concisely describe what the command does.
        - Only when the operation is dangerous (e.g. rm -rf or anything that could destroy data), write a caution in `warning`. If it is safe, leave `warning` as an empty string.
        - Always write `explanation` and `warning` in \(language).
        """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: naturalLanguage,
            generating: CommandSuggestion.self
        )
        return response.content
    }
}

// MARK: - Generable 構造体

@Generable
struct CommandSuggestion: Equatable {
    @Guide(description: "The shell command to run, on a single line")
    var command: String

    @Guide(description: "A concise explanation of what the command does")
    var explanation: String

    @Guide(description: "A caution note when the command is dangerous; empty string if safe")
    var warning: String
}

@Generable
struct ErrorAnalysis: Equatable {
    @Guide(description: "A concise explanation of the cause of the error")
    var cause: String

    @Guide(description: "A proposed solution")
    var solution: String

    @Guide(description: "A command that can fix the issue, if any; empty string otherwise")
    var fixCommand: String
}

// MARK: - エラー型

enum AIServiceError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return String(localized: "Apple Intelligence が利用できません。設定から有効にしてください。")
        }
    }
}

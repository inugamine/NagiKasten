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

    /// 参照するモデル。コンテキスト長やトークン数の計算にも使うので一箇所に束ねる。
    private var model: SystemLanguageModel { .default }

    /// モデルが利用可能かどうか
    var isAvailable: Bool {
        model.isAvailable
    }

    /// 動作中のオンデバイスモデルの表示名（"AFM 3 Core" など）。
    /// macOS 27 から取れるようになった。設定画面などに出す用。
    var modelDisplayName: String? {
        guard #available(macOS 27.0, *) else { return nil }
        return model.variant.displayName
    }

    /// 利用不可の理由（UI 表示用）。利用可能なら nil。
    var unavailableReason: String? {
        switch model.availability {
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

    // MARK: - コンテキスト予算

    /// 応答そのものに残しておくトークン数。
    /// 構造化出力 3 フィールド分の余裕を見て多めに取る。ここをケチると
    /// 生成の途中でコンテキストが尽きて応答が切れる。
    private static let responseReserveTokens = 800

    /// ツール定義（名前・説明・引数スキーマ）が食う分の見積もり。
    /// ツール自体のトークン数も測れるが、測定 API の往復を増やすより
    /// 保守的な固定値で引いておく方が実測で安定していた。
    private static let toolReserveTokens = 700

    /// 入力テキストに割り当ててよいトークン数を求める。
    private func inputBudget(instructions: String, usesTools: Bool) async -> Int {
        let total = model.contextSize

        // instructions は毎回同じ文字列なので実測して差し引く。
        // 測れなかった場合はざっくり 4 文字 1 トークンで見積もる。
        let instructionTokens: Int
        if let measured = try? await model.tokenCount(for: Instructions(instructions)) {
            instructionTokens = measured
        } else {
            instructionTokens = instructions.count / 4
        }

        let reserved = Self.responseReserveTokens
            + instructionTokens
            + (usesTools ? Self.toolReserveTokens : 0)

        return max(0, total - reserved)
    }

    /// テキストを予算内に収める。古い方から削り、直近の出力を残す。
    ///
    /// ターミナルの画面テキストは「下に行くほど新しい」。
    /// 直近のコマンドとそのエラーこそが解析対象なので、頭から削るのが正しい。
    ///
    /// トークン数は文字数から一意に決まらない（日本語はほぼ 1 文字 1 トークン、
    /// 英語は 4 文字程度で 1 トークン）。なので固定の換算率は使わず、
    /// 実測した比率から目標文字数を出して詰め直す、というのを数回まわす。
    private func fitted(_ text: String, within budget: Int) async -> String {
        guard budget > 0 else { return "" }

        // 1 文字 1 トークンを上回ることはないので、この範囲なら測るまでもなく収まる。
        // サジェストの質問文は大半がここで抜け、余計な往復をしない。
        guard text.count > budget else { return text }

        var candidate = text

        for _ in 0..<4 {
            guard let tokens = try? await model.tokenCount(for: Prompt(candidate)) else {
                // 測定できないときは保守的な文字数上限だけかけて抜ける。
                return Self.tail(of: candidate, characters: budget)
            }
            guard tokens > budget else { return candidate }

            // 実測比から目標文字数を出す。0.9 は測り直しの回数を減らすための安全側の余裕。
            let ratio = Double(budget) / Double(tokens)
            let targetCount = Int(Double(candidate.count) * ratio * 0.9)
            guard targetCount > 0 else { return "" }

            candidate = Self.tail(of: candidate, characters: targetCount)
        }

        return candidate
    }

    /// 末尾から指定文字数ぶんを、行の途中で切らないように取り出す。
    private static func tail(of text: String, characters: Int) -> String {
        guard text.count > characters else { return text }

        var cut = String(text.suffix(characters))

        // 先頭が行の途中なら、その半端な行は捨てる。
        // 途中から始まるパスやスタックトレースはモデルを惑わせるだけなので。
        if let newline = cut.firstIndex(of: "\n") {
            cut = String(cut[cut.index(after: newline)...])
        }

        return "...(earlier output omitted)\n" + cut
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
        - Use `checkCommandAvailability` before suggesting a command that may not be installed.
        - Use `lookupManPage` when you need the exact option syntax for a command.
        - Always write `cause` and `solution` in \(language).
        """

        // 「そのコマンドが実際に入っているか」はエラー解析でも効く。
        // command not found の原因切り分けが、記憶頼みでなく実機の状態で判断できる。
        let tools: [any Tool] = [CommandAvailabilityTool(), ManPageTool()]

        let budget = await inputBudget(instructions: instructions, usesTools: true)
        let trimmed = await fitted(terminalText, within: budget)

        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.contextTooSmall
        }

        let prompt = "Analyze the following terminal screen:\n\n\(trimmed)"

        return try await respond(
            to: prompt,
            instructions: instructions,
            tools: tools,
            generating: ErrorAnalysis.self
        )
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
        - Prefer commands that are actually installed. Use `checkCommandAvailability` when unsure.
        - Use `lookupManPage` to confirm option syntax rather than guessing.
        - Always write `explanation` and `warning` in \(language).
        """

        // 履歴ツールは既定で無効。有効なときだけ渡す。
        // 無効なまま渡してもモデルが呼んで断られるだけで、その往復がコンテキストの無駄になる。
        var tools: [any Tool] = [CommandAvailabilityTool(), ManPageTool()]
        if ShellHistoryTool.isEnabled {
            tools.append(ShellHistoryTool())
        }

        let budget = await inputBudget(instructions: instructions, usesTools: true)
        let trimmed = await fitted(naturalLanguage, within: budget)

        return try await respond(
            to: trimmed,
            instructions: instructions,
            tools: tools,
            generating: CommandSuggestion.self
        )
    }

    // MARK: - 応答の共通処理

    /// セッションを立てて構造化出力を取る。
    ///
    /// ツール呼び出しの失敗だけは握って、道具なしでもう一度だけ試す。
    /// man が無い、which がこけた、といった理由で回答そのものが出ないのは筋が悪い。
    /// 精度は落ちるが、モデルの記憶だけでも答えは返せる。
    private func respond<Content: Generable>(
        to prompt: String,
        instructions: String,
        tools: [any Tool],
        generating type: Content.Type
    ) async throws -> Content {
        do {
            let session = LanguageModelSession(tools: tools, instructions: instructions)
            let response = try await session.respond(to: prompt, generating: type)
            return response.content
        } catch is LanguageModelSession.ToolCallError {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: type)
            return response.content
        }
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
    case contextTooSmall

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return String(localized: "Apple Intelligence が利用できません。設定から有効にしてください。")
        case .contextTooSmall:
            return String(localized: "解析できる内容が残りませんでした。ターミナルの表示を減らしてからお試しください。")
        }
    }
}

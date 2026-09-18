//
// AITools.swift
// Kasten
//
// Created by inugaminé on 2026/09/18.
//

import Foundation
import FoundationModels

// MARK: - コマンド実行の土台

/// AI ツールから外部コマンドを叩くための最小限のランナー。
///
/// ここで一番大事なのは **シェルを経由しない** こと。
/// 引数はモデルが生成した文字列なので、`sh -c` に渡すと
/// `foo; rm -rf ~` のような文字列がそのまま実行されてしまう。
/// `Process` に argv を直接渡せばメタ文字は単なる文字として扱われ、
/// この経路自体が成立しない。
enum ProcessRunner {

    enum Failure: Error {
        case timedOut
        case launchFailed(String)
    }

    /// 実行して標準出力を返す。標準エラーは捨てる（man の警告などが混ざるため）。
    ///
    /// - Parameters:
    ///   - timeout: これを過ぎたら SIGTERM を送る。AI の応答待ちを人質に取られないための保険。
    ///   - maxOutputBytes: 読み取り上限。巨大な出力でメモリを食わないようにする。
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 5.0,
        maxOutputBytes: Int = 256 * 1024
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes
            )
        }.value
    }

    /// 同期版の本体。呼び出し元が detached task なので、ここでブロックしてよい。
    private static func runBlocking(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        // 環境変数は必要な分だけ引き渡す。PATH を継承しないと man が groff を見つけられない。
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        // タイムアウト監視。時間切れなら終了させ、下の readDataToEndOfFile を解く。
        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut.mark()
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // パイプは先に読み切る。待ってから読むとバッファが埋まった時点で
        // 子プロセスが書き込みでブロックし、こちらも待ち続けて詰む。
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if timedOut.isMarked { throw Failure.timedOut }

        let clipped = data.count > maxOutputBytes ? data.prefix(maxOutputBytes) : data[...]
        return String(decoding: clipped, as: UTF8.self)
    }

    /// watchdog と待機側の両方から触るので、ロックで包んでおく。
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.lock(); value = true; lock.unlock() }
        var isMarked: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}

// MARK: - 引数の検証

enum CommandName {

    /// モデルが渡してきた文字列をコマンド名として受け入れてよいか判定する。
    ///
    /// `Process` を使う以上シェル実行の危険はないが、それでも絞る理由が二つある。
    /// 一つは `-` 始まりを弾くこと（`man -w` のようにオプションとして解釈される）。
    /// もう一つはパス区切りを弾くこと（`../../somewhere` を見に行かせない）。
    static func sanitized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        guard !trimmed.hasPrefix("-") else { return nil }

        // CharacterSet.alphanumerics は日本語も通してしまうので、ASCII に限って判定する。
        let isAllowed: (Character) -> Bool = { character in
            character.isASCII && (character.isLetter || character.isNumber || "._-+".contains(character))
        }
        guard trimmed.allSatisfy(isAllowed) else { return nil }

        return trimmed
    }
}

// MARK: - man ページ参照

/// man ページから必要な部分だけを抜き出してモデルに渡すツール。
///
/// オンデバイスモデルのコンテキストは 4K トークンしかないので、
/// man ページを丸ごと返すと一撃で溢れる。
/// ここでは「キーワードがあれば該当行の周辺、なければ NAME と SYNOPSIS」
/// という方針で削ってから返す。
struct ManPageTool: Tool {
    let name = "lookupManPage"
    let description = "Looks up the manual page for a command installed on this Mac."

    @Generable
    struct Arguments {
        @Guide(description: "The command name, for example 'tar' or 'git'")
        var command: String

        @Guide(description: "An option or keyword to find within the page, for example '--exclude'. Empty string to get the summary instead.")
        var keyword: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let command = CommandName.sanitized(arguments.command) else {
            return "Invalid command name."
        }

        let raw: String
        do {
            raw = try await ProcessRunner.run(
                executable: "/usr/bin/man",
                arguments: [command],
                // ページャを挟むと対話待ちになるので cat に固定し、
                // 端末幅も決め打ちして折り返しを安定させる。
                environment: [
                    "MANPAGER": "cat",
                    "PAGER": "cat",
                    "MANWIDTH": "80",
                    "TERM": "dumb"
                ]
            )
        } catch {
            return "No manual page found for '\(command)'."
        }

        let text = Self.stripOverstrike(raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No manual page found for '\(command)'."
        }

        let keyword = arguments.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = keyword.isEmpty
            ? Self.summary(of: text)
            : Self.excerpt(of: text, matching: keyword)

        return excerpt.isEmpty
            ? Self.summary(of: text)
            : excerpt
    }

    /// NAME と SYNOPSIS、それと DESCRIPTION の冒頭だけを取る。
    private static func summary(of text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var picked: [String] = []
        var section = ""
        var descriptionLines = 0

        for line in lines {
            // セクション見出しは行頭から始まる大文字の行。
            if let first = line.first, !first.isWhitespace, line == line.uppercased() {
                section = line.trimmingCharacters(in: .whitespaces)
            }

            switch section {
            case "NAME", "SYNOPSIS":
                picked.append(line)
            case "DESCRIPTION":
                guard descriptionLines < 12 else { continue }
                picked.append(line)
                descriptionLines += 1
            default:
                continue
            }
        }

        return clamp(collapse(picked))
    }

    /// キーワードを含む行と、その前後を切り出す。
    private static func excerpt(of text: String, matching keyword: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var picked: [String] = []
        var lastIndex = -10

        for (index, line) in lines.enumerated() {
            guard line.localizedCaseInsensitiveContains(keyword) else { continue }

            // 連続ヒットで同じ範囲を重複して足さないよう、間隔を見る。
            if index - lastIndex > 8 && !picked.isEmpty {
                picked.append("---")
            }
            let lower = max(0, index - 1)
            let upper = min(lines.count - 1, index + 6)
            picked.append(contentsOf: lines[lower...upper])
            lastIndex = index

            if picked.count > 60 { break }
        }

        return clamp(collapse(picked))
    }

    /// 空行の連続を潰して前後の余白を落とす。man は空行が多く、そのままだとトークンの無駄。
    private static func collapse(_ lines: [String]) -> String {
        var result: [String] = []
        var previousWasBlank = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isBlank = trimmed.isEmpty
            if isBlank && previousWasBlank { continue }
            result.append(isBlank ? "" : trimmed)
            previousWasBlank = isBlank
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 最終的な長さの歯止め。ツール出力もコンテキストを食うので必ず上限を設ける。
    private static func clamp(_ text: String, limit: Int = 1500) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n...(truncated)"
    }

    /// man は太字や下線を「文字 + BS + 文字」の重ね打ちで表現する。
    /// 端末を介さずに cat へ流すとこれが生のまま残るので、ここで畳んでおく。
    private static func stripOverstrike(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\u{8}" {
                if !result.isEmpty { result.removeLast() }
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }
}

// MARK: - コマンドの存在確認

/// 指定されたコマンドがこの Mac に実際に入っているかを調べるツール。
///
/// モデルの記憶にあるコマンドと、目の前の Mac に入っているコマンドは別物だ。
/// `gsed` や `rg` や `fd` を平然と提案されても、入っていなければ意味がない。
/// これがあると「入っている方」で答えられる。
struct CommandAvailabilityTool: Tool {
    let name = "checkCommandAvailability"
    let description = "Checks which of the given commands are actually installed on this Mac."

    @Generable
    struct Arguments {
        @Guide(description: "Command names to check, at most 8, for example ['rg', 'grep']")
        var commands: [String]
    }

    func call(arguments: Arguments) async throws -> String {
        var lines: [String] = []

        for raw in arguments.commands.prefix(8) {
            guard let command = CommandName.sanitized(raw) else {
                lines.append("\(raw): invalid name")
                continue
            }

            // which はシェル関数やエイリアスを見ないが、PATH 上の実体は確実に分かる。
            let path = try? await ProcessRunner.run(
                executable: "/usr/bin/which",
                arguments: [command],
                timeout: 2.0
            )
            let resolved = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(resolved.isEmpty ? "\(command): not installed" : "\(command): \(resolved)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - シェル履歴の参照

/// zsh の履歴から、キーワードに一致する過去のコマンドを引くツール。
///
/// 既定では無効。履歴には API キーを環境変数で渡した行や、
/// 社内ホスト名のような外に出したくないものが普通に混ざる。
/// オンデバイスモデルとはいえ、黙って読ませるものではないので
/// 明示的に有効化したときだけ動かす。
struct ShellHistoryTool: Tool {
    let name = "searchShellHistory"
    let description = "Searches the user's zsh history for previously used commands."

    /// 有効化フラグの UserDefaults キー。設定画面から切り替える想定。
    static let enabledDefaultsKey = "KastenAIHistoryToolEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    @Generable
    struct Arguments {
        @Guide(description: "A keyword to search for, for example 'ffmpeg'")
        var keyword: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard Self.isEnabled else {
            return "Shell history access is turned off."
        }

        let keyword = arguments.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return "No keyword given." }

        let historyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zsh_history")

        guard let data = try? Data(contentsOf: historyURL) else {
            return "No shell history available."
        }

        // 履歴はロケール不定のバイト列で、不正な UTF-8 が混ざることがある。
        // decoding: を使うと壊れた箇所が置換文字になるだけで、読み取り自体は続行できる。
        let text = String(decoding: data, as: UTF8.self)

        var matches: [String] = []
        for line in text.components(separatedBy: .newlines).reversed() {
            let command = Self.strippingMetadata(line)
            guard command.localizedCaseInsensitiveContains(keyword) else { continue }
            guard !matches.contains(command) else { continue }
            matches.append(command)
            if matches.count >= 10 { break }
        }

        guard !matches.isEmpty else {
            return "No history entries matching '\(keyword)'."
        }

        return matches.joined(separator: "\n")
    }

    /// zsh の extended history は `: <開始時刻>:<所要秒>;<コマンド>` の形で保存される。
    /// 前半はモデルに渡しても邪魔なだけなので落とす。
    private static func strippingMetadata(_ line: String) -> String {
        guard line.hasPrefix(":"), let separator = line.firstIndex(of: ";") else {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return String(line[line.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
    }
}

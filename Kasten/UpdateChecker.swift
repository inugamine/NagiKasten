//
// UpdateChecker.swift
// Kasten
//
// GitHub Releases の最新タグを見て、自分より新しければ知らせる。
// ダウンロードとインストールまでは踏み込まない（リリースページを開くだけ）。
//

import SwiftUI
import Combine
import AppKit

// MARK: - バージョン

/// "v1.2.3" 形式のバージョン。
///
/// 文字列のまま比べると "1.10" < "1.9" になってしまうので、
/// 数値の列に分解して桁ごとに比較する。桁数が違う場合は足りない側を 0 で埋める
/// （つまり "1.2" と "1.2.0" は等しい）。
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    /// 数値部分。"1.2.3" なら [1, 2, 3]。
    let numbers: [Int]
    /// 表示用の文字列（先頭の v は落とした後のもの）。
    let description: String

    init?(_ string: String) {
        var body = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.first == "v" || body.first == "V" { body.removeFirst() }
        // "1.2.3-beta.1" や "1.2.3+build7" の識別子は比較の対象外にする。
        if let cut = body.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            body = String(body[..<cut])
        }
        let parsed = body.split(separator: ".").map { Int($0) }
        guard !parsed.isEmpty, !parsed.contains(nil) else { return nil }
        self.numbers = parsed.compactMap { $0 }
        self.description = body
    }

    /// 実行中のアプリのバージョン（= ビルド設定の MARKETING_VERSION）。
    static var current: AppVersion? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return nil }
        return AppVersion(raw)
    }

    /// i 桁目。存在しなければ 0 とみなす。
    private func digit(_ i: Int) -> Int { i < numbers.count ? numbers[i] : 0 }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.numbers.count, rhs.numbers.count)
        return (0..<width).allSatisfy { lhs.digit($0) == rhs.digit($0) }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.numbers.count, rhs.numbers.count)
        for i in 0..<width where lhs.digit(i) != rhs.digit(i) {
            return lhs.digit(i) < rhs.digit(i)
        }
        return false
    }
}

// MARK: - GitHub のレスポンス

/// GitHub Releases API のうち、こちらで使う分だけを拾う。
struct GitHubRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
    }

    /// リリースの見出し。name が空ならタグ名で代用する。
    var displayTitle: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        return tagName
    }
}

// MARK: - チェッカー

@MainActor
final class UpdateChecker: ObservableObject {

    /// 監視先のリポジトリ。移設したらここだけ直せばいい。
    private static let owner = "inugamine"
    private static let repo  = "NagiKasten"

    /// 自動チェックの間隔（24 時間）。
    /// 起動のたびに叩くと、頻繁に開け閉めする端末アプリでは API を無駄に消費する。
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case failed(String)
    }

    enum UpdateError: LocalizedError {
        case badResponse
        case rateLimited
        case notFound
        case http(Int)
        case unparsableVersion

        var errorDescription: String? {
            switch self {
            case .badResponse:
                return String(localized: "サーバーからの応答を解釈できませんでした。")
            case .rateLimited:
                return String(localized: "GitHub の API 制限に達しました。しばらく待ってからお試しください。")
            case .notFound:
                return String(localized: "公開されているリリースが見つかりませんでした。")
            case .http(let code):
                return String(localized: "通信に失敗しました（HTTP \(code)）。")
            case .unparsableVersion:
                return String(localized: "バージョン番号を解釈できませんでした。")
            }
        }
    }

    // ThemeStore と同じく、@Published を使わず手動で通知する。
    // （Swift の並行性チェックとの相性のため）
    let objectWillChange = ObservableObjectPublisher()

    private(set) var phase: Phase = .idle {
        willSet { objectWillChange.send() }
    }

    /// 結果シートを出しているか。
    var isPresentingResult: Bool = false {
        willSet { objectWillChange.send() }
    }

    // MARK: 設定の永続化

    private enum Key {
        static let enabled     = "updateCheck.enabled"
        static let lastChecked = "updateCheck.lastCheckedAt"
        static let skipped     = "updateCheck.skippedVersion"
    }

    /// 起動時の自動チェックを行うか。既定は有効。
    var isAutomaticCheckEnabled: Bool {
        get {
            // 未設定なら true。registerDefaults に頼らず、ここで既定値を持つ。
            UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Key.enabled)
        }
    }

    // MARK: 入口

    /// 起動時のチェック。前回から 24 時間経っていなければ何もしない。
    func checkOnLaunchIfNeeded() {
        guard isAutomaticCheckEnabled else { return }
        if let last = UserDefaults.standard.object(forKey: Key.lastChecked) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }
        check(manually: false)
    }

    /// メニューからの手動チェック。結果が「最新です」でも失敗でもシートを出す。
    func checkManually() {
        check(manually: true)
    }

    private func check(manually: Bool) {
        guard phase != .checking else { return }
        phase = .checking

        Task {
            do {
                let release = try await self.fetchLatestRelease()
                UserDefaults.standard.set(Date(), forKey: Key.lastChecked)

                guard let latest = AppVersion(release.tagName),
                      let current = AppVersion.current else {
                    throw UpdateError.unparsableVersion
                }

                if latest > current {
                    // 「スキップ」は自動チェックだけが尊重する。
                    // 手動チェックは「今どうなってる？」への回答なので、隠したら嘘になる。
                    let skipped = UserDefaults.standard.string(forKey: Key.skipped)
                    if !manually, skipped == latest.description {
                        self.phase = .idle
                        return
                    }
                    self.phase = .available(release)
                    self.isPresentingResult = true
                } else {
                    self.phase = .upToDate
                    self.isPresentingResult = manually
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.phase = .failed(message)
                // 自動チェックの失敗は黙って飲む。ネットが繋がっていないだけで
                // 起動のたびにダイアログが出るのは邪魔でしかない。
                self.isPresentingResult = manually
            }
        }
    }

    // MARK: 通信

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let endpoint = "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest"
        guard let url = URL(string: endpoint) else { throw UpdateError.badResponse }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub API は User-Agent を名乗らないと 403 で弾かれることがある。
        request.setValue("NagiKasten/\(AppVersion.current?.description ?? "0")",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        // 更新確認でキャッシュを掴んだら本末転倒なので、毎回取りに行く。
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }

        switch http.statusCode {
        case 200:
            break
        case 403, 429:
            throw UpdateError.rateLimited
        case 404:
            // リリース未公開のときも 404 が返る。
            throw UpdateError.notFound
        default:
            throw UpdateError.http(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.badResponse
        }
    }

    // MARK: シートからの操作

    func openReleasePage() {
        if case .available(let release) = phase {
            NSWorkspace.shared.open(release.htmlURL)
        }
        isPresentingResult = false
    }

    /// このバージョンは今後（自動チェックでは）知らせない。
    func skipCurrentVersion() {
        if case .available(let release) = phase,
           let version = AppVersion(release.tagName) {
            UserDefaults.standard.set(version.description, forKey: Key.skipped)
        }
        isPresentingResult = false
    }

    func dismiss() {
        isPresentingResult = false
    }
}

// MARK: - 結果シート

struct UpdateResultSheet: View {
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch updater.phase {
            case .available(let release):
                availableBody(release)
            case .upToDate:
                simpleBody(
                    icon: "checkmark.seal",
                    title: String(localized: "お使いの NagiKasten は最新です"),
                    detail: String(localized: "バージョン \(AppVersion.current?.description ?? "-")")
                )
            case .failed(let message):
                simpleBody(
                    icon: "exclamationmark.triangle",
                    title: String(localized: "アップデートを確認できませんでした"),
                    detail: message
                )
            case .idle, .checking:
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: 更新あり

    @ViewBuilder
    private func availableBody(_ release: GitHubRelease) -> some View {
        Text("新しいバージョンがあります")
            .font(.headline)

        Text("現在 \(AppVersion.current?.description ?? "-") → 最新 \(AppVersion(release.tagName)?.description ?? release.tagName)")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        if let notes = release.body, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ScrollView {
                Text(notes)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }

        HStack {
            Button("このバージョンをスキップ") { updater.skipCurrentVersion() }
            Spacer()
            Button("後で") { updater.dismiss() }
            Button("ダウンロード") { updater.openReleasePage() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }

    // MARK: 更新なし／失敗

    @ViewBuilder
    private func simpleBody(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }

        HStack {
            Spacer()
            Button("閉じる") { updater.dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }
}

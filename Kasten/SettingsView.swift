//
// SettingsView.swift
// Kasten
//
// ⌘, で開く設定ウィンドウ。外観（テーマ）の切り替えと、カスタム配色の編集。
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore

    /// ANSI 16 色の表示名（0..15）。
    private let ansiLabels = [
        "黒", "赤", "緑", "黄", "青", "マゼンタ", "シアン", "白",
        "明るい黒（グレー）", "明るい赤", "明るい緑", "明るい黄",
        "明るい青", "明るいマゼンタ", "明るいシアン", "明るい白",
    ]

    var body: some View {
        TabView {
            appearanceTab
                .tabItem {
                    Label("外観", systemImage: "paintbrush")
                }
        }
        .frame(width: 480, height: 460)
    }

    private var appearanceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("テーマ", selection: modeBinding) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("「システム」は macOS のライト/ダーク設定に追従します。「カスタム」で各色を自由に設定できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if themeStore.mode == .custom {
                    customColorEditor
                }
            }
            .padding()
        }
    }

    // MARK: - カスタム色エディタ

    private var customColorEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("カスタム色")
                    .font(.headline)
                Spacer()
                Button("ダークから複製") { themeStore.customTheme = .dark }
                Button("ライトから複製") { themeStore.customTheme = .light }
            }

            sectionBox("基本") {
                colorRow("前景", \.foreground)
                colorRow("背景", \.background)
                colorRow("カーソル", \.cursor)
                colorRow("選択範囲", \.selection)
            }

            sectionBox("ANSI（通常）") {
                ForEach(0..<8) { i in
                    colorRow(ansiLabels[i], ansiKeyPath(i))
                }
            }

            sectionBox("ANSI（明るい）") {
                ForEach(8..<16) { i in
                    colorRow(ansiLabels[i], ansiKeyPath(i))
                }
            }
        }
    }

    // MARK: - 部品

    /// セクション枠。タイトル付きで中身を縦に並べる。
    private func sectionBox<Content: View>(_ title: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// モード選択用のバインディング。選択の反映を次のランループに逃がし、
    /// ビュー更新中の objectWillChange 発火（"Publishing changes..." 警告）を避ける。
    private var modeBinding: Binding<AppearanceMode> {
        Binding(
            get: { themeStore.mode },
            set: { newValue in
                DispatchQueue.main.async { themeStore.mode = newValue }
            }
        )
    }

    /// 1 色分の行（ラベル＋カラーピッカー）。
    private func colorRow(_ label: String,
                          _ keyPath: WritableKeyPath<KastenTheme, KastenTheme.RGB>) -> some View {
        ColorPicker(label, selection: colorBinding(keyPath), supportsOpacity: false)
    }

    /// ansi[i] への書き込み可能なキーパス。
    private func ansiKeyPath(_ i: Int) -> WritableKeyPath<KastenTheme, KastenTheme.RGB> {
        \KastenTheme.ansi[i]
    }

    /// customTheme の特定の色を SwiftUI の Color として読み書きするバインディング。
    /// 変更すると customTheme が更新され、永続化＆ライブ適用される。
    private func colorBinding(_ keyPath: WritableKeyPath<KastenTheme, KastenTheme.RGB>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: themeStore.customTheme[keyPath: keyPath].nsColor) },
            set: { newColor in
                // ColorPicker はビュー更新中に値を書き戻すことがあり、その場で
                // store を変更すると "Publishing changes from within view updates" が出る。
                // 変更を次のランループに逃がして回避する。
                let rgb = KastenTheme.RGB(nsColor: NSColor(newColor))
                DispatchQueue.main.async {
                    themeStore.customTheme[keyPath: keyPath] = rgb
                }
            }
        )
    }
}

//
// KastenApp.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//
  

import SwiftUI
import AppKit

@main
struct KastenApp: App {
    @StateObject private var themeStore = ThemeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeStore)
                .frame(minWidth: 700, minHeight: 450)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // 標準の「NagiKasten について」を、利用 OSS のライセンス表示付きに差し替える。
            CommandGroup(replacing: .appInfo) {
                Button("NagiKasten について") {
                    KastenApp.showAboutPanel()
                }
            }
        }

        // ⌘, で開く設定ウィンドウ。
        Settings {
            SettingsView()
                .environmentObject(themeStore)
        }
    }

    /// About パネルを開き、利用しているオープンソース（SwiftTerm / MIT ライセンス）の
    /// 著作権表示とライセンス本文を credits 欄に表示する。MIT の帰属表示義務を満たすため。
    @MainActor
    static func showAboutPanel() {
        let license = """
        SwiftTerm

        Copyright (c) 2019-2022 Miguel de Icaza (https://github.com/migueldeicaza)
        Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
        Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
        Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

        Permission is hereby granted, free of charge, to any person obtaining
        a copy of this software and associated documentation files (the
        "Software"), to deal in the Software without restriction, including
        without limitation the rights to use, copy, modify, merge, publish,
        distribute, sublicense, and/or sell copies of the Software, and to
        permit persons to whom the Software is furnished to do so, subject to
        the following conditions:

        The above copyright notice and this permission notice shall be
        included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
        EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
        MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
        NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
        LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
        OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
        WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """

        let header = String(localized: "NagiKasten は以下のオープンソースソフトウェアを利用しています。\n\n")

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2

        let credits = NSAttributedString(
            string: header + license,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )

        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

//
// KastenApp.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//
  

import SwiftUI

@main
struct KastenApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 450)
        }
        .windowResizability(.contentMinSize)
    }
}

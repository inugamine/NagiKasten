//
// ShellIntegrationSetup.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//
  

import Foundation

enum ShellIntegrationSetup {
    
    struct Result {
        let zdotdir: String   // zsh に渡す ZDOTDIR（Kastenの一時ディレクトリ）
    }
    
    /// Kasten の zsh 統合スクリプト本体（OSC 133 フック）。
    /// 文字列で持つことで Xcode のリソース設定を不要にしている。
    private static let integrationScript = #"""
    # kasten-integration.zsh （Kasten が自動生成）
    if [[ -n "$KASTEN_SHELL_INTEGRATION_LOADED" ]]; then
        return 0
    fi
    typeset -g KASTEN_SHELL_INTEGRATION_LOADED=1
    
    autoload -Uz add-zsh-hook
    typeset -g __kasten_first_prompt=1
    
    __kasten_precmd() {
        local exit_code=$?
        if [[ -n "$__kasten_first_prompt" ]]; then
            unset __kasten_first_prompt
        else
            print -n "\e]133;D;${exit_code}\a"
        fi
        print -n "\e]133;A\a"
    }
    
    __kasten_preexec() {
        print -n "\e]133;C\a"
    }
    
    add-zsh-hook precmd __kasten_precmd
    add-zsh-hook preexec __kasten_preexec
    """#
    
    /// 一時ディレクトリに .zshrc と統合スクリプトを書き出し、ZDOTDIR を返す。
    static func prepare() -> Result? {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.path
        let userZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? homeDir
        
        let kastenDir = fm.temporaryDirectory
            .appendingPathComponent("kasten-shell-integration", isDirectory: true)
        do {
            try fm.createDirectory(at: kastenDir, withIntermediateDirectories: true)
        } catch { return nil }
        
        let scriptURL = kastenDir.appendingPathComponent("kasten-integration.zsh")
        let zshrcURL = kastenDir.appendingPathComponent(".zshrc")
        
        let zshrcContents = """
        # Kasten が自動生成した一時 .zshrc
        export ZDOTDIR="\(userZdotdir)"
        
        if [[ -f "\(userZdotdir)/.zprofile" ]]; then
            source "\(userZdotdir)/.zprofile"
        fi
        
        if [[ -f "\(userZdotdir)/.zshrc" ]]; then
            source "\(userZdotdir)/.zshrc"
        fi
        
        if [[ -f "\(userZdotdir)/.zlogin" ]]; then
            source "\(userZdotdir)/.zlogin"
        fi
        
        if [[ -f "\(scriptURL.path)" ]]; then
            source "\(scriptURL.path)"
        fi
        """
        
        do {
            try integrationScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            try zshrcContents.write(to: zshrcURL, atomically: true, encoding: .utf8)
        } catch { return nil }
        
        return Result(zdotdir: kastenDir.path)
    }
}

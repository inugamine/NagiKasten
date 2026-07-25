//
// ShellIntegrationSetup.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//
  

import Foundation

/// プロンプトの装飾様式。テーマに連動して切り替える。
///
/// 実際の値は一時ファイルに書き出され、zsh が毎プロンプトで読む。
/// アプリ側とシェル側は寿命が違う（シェルは起動時に一度だけスクリプトを読む）ため、
/// このファイル経由の受け渡しが両者を繋ぐ経路になっている。
/// pty に書き込む方法もあるが、それだとユーザが入力中の行に文字を注入してしまう。
enum PromptOrnament: String {
    /// 既定。装飾を持たない配色（凪など）向け。
    case plain
    /// アール・デコ。真鍮の階段と菱形で縁取る。
    case artDeco = "artdeco"

    /// 見た目モードから対応する様式を決める。
    /// 装飾は「名前の付いたプリセット」に従う。
    /// カスタムで色だけ真似ても装飾は付かない。
    init(mode: AppearanceMode) {
        self = mode.isOrnamented ? .artDeco : .plain
    }
}

enum ShellIntegrationSetup {
    
    struct Result {
        let zdotdir: String       // zsh に渡す ZDOTDIR（Kastenの一時ディレクトリ）
        let ornamentFile: String  // プロンプトの装飾様式を書き込むファイル
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

        # ディレクトリ・ブランチはプロンプト開始(A)より先に送る。
        # A で区切り線を引く瞬間に、最新の値が揃っているようにするため。

        # カレントディレクトリを通知（VSCode 互換の OSC 633;P;Cwd=...）
        print -n "\e]633;P;Cwd=${PWD}\a"

        # Git ブランチを通知（Kasten 独自プロパティ）。
        # git リポジトリ外では空文字を送って「ブランチ無し」を伝える。
        local __kasten_branch=""
        if command git rev-parse --is-inside-work-tree &>/dev/null; then
            __kasten_branch=$(command git symbolic-ref --short HEAD 2>/dev/null)
            if [[ -z "$__kasten_branch" ]]; then
                # detached HEAD の場合は短いコミットハッシュ
                __kasten_branch=$(command git rev-parse --short HEAD 2>/dev/null)
            fi
        fi
        print -n "\e]633;P;KastenGitBranch=${__kasten_branch}\a"

        # 最後にプロンプト開始を送る（この時点でディレクトリ・ブランチが揃っている）
        print -n "\e]133;A\a"
    }
    
    __kasten_preexec() {
        print -n "\e]133;C\a"
    }

    # Kasten 専用のプロンプトに上書きする。
    # あなたの設定（Starship 初期化）を source した後にこのスクリプトが読まれるので、
    # このフックは Starship の precmd より後に登録される＝後に実行される。
    # precmd_functions 配列は先頭から順に実行されるため、最後に走るこのフックの
    # PROMPT 上書きが最終的に勝つ。これで Starship が描いた後に Kasten 用へ差し替える。
    # ※ お前の本物の設定ファイルは一切書き換えていない（一時環境の中だけの話）。
    #
    # 2行構成にして、1行目に現在地（ディレクトリ・ブランチ）、2行目に入力記号を置く。
    # こうすると区切り線と被らず、情報は zsh が描くので位置ズレも起きない。
    __kasten_prompt() {
        # フルパス。ホームディレクトリは ~ に短縮する。
        local __kasten_dir="${PWD/#$HOME/~}"

        # Git ブランチ（リポジトリ内のみ）。
        local __kasten_branch=""
        if command git rev-parse --is-inside-work-tree &>/dev/null; then
            __kasten_branch=$(command git symbolic-ref --short HEAD 2>/dev/null)
            if [[ -z "$__kasten_branch" ]]; then
                __kasten_branch=$(command git rev-parse --short HEAD 2>/dev/null)
            fi
        fi

        # 装飾様式を毎回ファイルから読む。アプリがテーマ変更時に書き換えるので、
        # シェルを起動し直さなくても次のプロンプトから新しい様式に切り替わる。
        # ファイルが無い・読めない場合は既定（plain）に倒す。
        local __kasten_ornament="plain"
        if [[ -n "$KASTEN_ORNAMENT_FILE" && -r "$KASTEN_ORNAMENT_FILE" ]]; then
            __kasten_ornament=$(<"$KASTEN_ORNAMENT_FILE")
        fi

        local __kasten_line1 __kasten_line2

        if [[ "$__kasten_ornament" == "artdeco" ]]; then
            # アール・デコ: 真鍮の階段と菱形。
            # 色は必ず ANSI インデックスで指定する。直接 16 進で書くと、
            # テーマを戻したときにプロンプトだけが前の色のまま取り残される。
            # 3 番＝アクセント（アール・デコでは真鍮）、
            # 4 番＝青系（同じくサファイア）、2 番＝緑系（同じく翡翠）。
            __kasten_line1="%F{3}◤▰▰%f %F{4}${__kasten_dir}%f"
            if [[ -n "$__kasten_branch" ]]; then
                __kasten_line1+="  %F{3}◈%f %F{2}${__kasten_branch}%f"
            fi
            # 尾を真鍮にして、金の細罫から入力位置へ導く形にする。
            __kasten_line2="%F{3}╰──%f%F{2}❯%f "
        else
            # 既定（凪）: 絵文字で現在地とブランチを示す。
            __kasten_line1="%F{cyan}📁 ${__kasten_dir}%f"
            if [[ -n "$__kasten_branch" ]]; then
                __kasten_line1+="  %F{magenta}🌿 ${__kasten_branch}%f"
            fi
            __kasten_line2="%F{green}❯%f "
        fi

        # 1行目（情報）＋改行＋2行目（入力記号）
        PROMPT="${__kasten_line1}"$'\n'"${__kasten_line2}"
    }

    add-zsh-hook precmd __kasten_precmd
    add-zsh-hook preexec __kasten_preexec
    add-zsh-hook precmd __kasten_prompt
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
        let ornamentURL = kastenDir.appendingPathComponent("ornament")
        
        let zshrcContents = """
        # Kasten が自動生成した一時 .zshrc
        export ZDOTDIR="\(userZdotdir)"
        
        # プロンプトの装飾様式を書いたファイル。統合スクリプトが毎プロンプトで読む。
        export KASTEN_ORNAMENT_FILE="\(ornamentURL.path)"
        
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
        
        return Result(zdotdir: kastenDir.path, ornamentFile: ornamentURL.path)
    }

    /// 装飾様式を一時ファイルへ書き出す。zsh は毎プロンプトでこれを読む。
    /// atomically 指定によりリネーム置換になるため、シェルが読んでいる最中でも
    /// 中途半端な内容を読むことはない。
    /// 書き込みに失敗しても致命的ではない（zsh 側は読めなければ既定に倒れる）。
    static func writeOrnament(_ ornament: PromptOrnament, to path: String) {
        try? ornament.rawValue.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

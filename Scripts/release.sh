#!/usr/bin/env bash
#
# release.sh — NagiKasten のリリースを一気通貫でやる。
#
#   ./Scripts/release.sh 1.1
#
# 手順:
#   1. 事前チェック（作業ツリー・必要なコマンド・タグの重複・公証プロファイル）
#   2. pbxproj のバージョン更新
#   3. アーカイブ → Developer ID で書き出し
#   4. DMG の作成と署名
#   5. 公証 → ステープル → 検証
#   6. コミット / タグ / push
#   7. GitHub Release の作成と DMG の添付
#   8. ラズパイの公開ページへ DMG を転送する（確認あり）
#
# リリースノートは notes/notes-<バージョン>.md（git 管理外）。
# 無ければ雛形を作って一旦停止する。この判定はビルドの前に置いてある。
# 5 分待たされた末に「ノートを書け」と言われるのは間抜けだからな。
#
# 6 以降は取り返しがつかないので、その手前で一度確認を挟む。
#

set -euo pipefail

# ---- 設定 ------------------------------------------------------------------

PROJECT_NAME="Kasten"                 # .xcodeproj のファイル名
SCHEME="Kasten"                       # スキーム名。ターゲット名（NagiKasten）とは別物。
APP_NAME="NagiKasten"                 # 書き出される .app の名前
GITHUB_REPO="inugamine/NagiKasten"
NOTARY_PROFILE="NagiKasten-notary"    # notarytool store-credentials で保存した名前
SIGN_IDENTITY="Developer ID Application: Shota Nakamura (3WNHDR762B)"
SERVER="pi5@raspi5"                   # 公開ページのあるラズパイ
SERVER_DIR="/var/www/flask_static/nagikasten"

# ---- 下ごしらえ ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/$PROJECT_NAME.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
NOTES_DIR="$REPO_ROOT/notes"          # git 管理外。リリースノートの置き場
APP_PATH="$EXPORT_DIR/$APP_NAME.app"

step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mエラー:\033[0m %s\n' "$*" >&2; exit 1; }

VERSION=""
NOTES_FILE=""
AUTO_NOTES=0
PUBLISH=1
DRY_RUN=0
ASSUME_YES=0
VERSION_BUMPED=0
COMMITTED=0

usage() {
	cat <<'EOF'
使い方:
  ./Scripts/release.sh <バージョン> [オプション]

  <バージョン>  1.1 のような数値のみの形式。先頭の v は付けない。

オプション:
  --notes-file <path>  リリースノートのファイルを明示する
                       省略時は notes/notes-<バージョン>.md。無ければ雛形を作って停止
  --auto-notes         ノートを書かず、GitHub のコミットログ自動生成で済ませる
  --no-publish         push と GitHub Release を行わず、DMG を作るところで止める
  --yes                確認プロンプトを飛ばす
  --dry-run            実際には何もせず、行う手順だけを表示する
  -h, --help           このヘルプ
EOF
}

# 途中で落ちたとき、バージョン変更だけが残るのを防ぐための案内。
on_exit() {
	local code=$?
	if [[ $code -ne 0 && $VERSION_BUMPED -eq 1 && $COMMITTED -eq 0 ]]; then
		warn "途中で失敗した。バージョンの変更を戻すなら:"
		warn "  git -C \"$REPO_ROOT\" checkout -- \"$PBXPROJ\""
	fi
	exit $code
}
trap on_exit EXIT

# ---- 引数 ------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help)    usage; exit 0 ;;
		--notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
		--auto-notes) AUTO_NOTES=1; shift ;;
		--no-publish) PUBLISH=0; shift ;;
		--yes)        ASSUME_YES=1; shift ;;
		--dry-run)    DRY_RUN=1; shift ;;
		-*)           die "知らないオプション: $1" ;;
		*)
			[[ -n "$VERSION" ]] && die "バージョンは 1 つだけ指定しろ。"
			VERSION="$1"; shift ;;
	esac
done

[[ -n "$VERSION" ]] || { usage; exit 1; }

# ---- 1. 事前チェック -------------------------------------------------------

step "事前チェック"

# アプリ側の AppVersion が解釈できる形式か。ここを緩めると
# 「更新があります」が出ない・出っぱなしになる、の両方が起きうる。
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || \
	die "バージョンの形式が不正だ: ${VERSION}（例: 1.1 / 1.2.3。先頭の v は不要）"

for cmd in xcodebuild create-dmg git; do
	command -v "$cmd" >/dev/null 2>&1 || die "$cmd が見つからない。"
done
if [[ $PUBLISH -eq 1 ]]; then
	command -v gh >/dev/null 2>&1 || \
		die "gh（GitHub CLI）が見つからない。Nix の設定に足すか、--no-publish で回避しろ。"
	gh auth status >/dev/null 2>&1 || die "gh が未認証だ。gh auth login を先に済ませろ。"
fi

[[ -f "$PBXPROJ" ]] || die "プロジェクトが見つからない: $PROJECT"

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
	die "作業ツリーが汚れている。コミットするか stash してから出直せ。"
fi

BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || warn "現在のブランチは $BRANCH だ（main ではない）。"

if git -C "$REPO_ROOT" rev-parse "v$VERSION" >/dev/null 2>&1; then
	die "タグ v$VERSION は既に存在する。"
fi

CURRENT_VERSION="$(sed -n -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/p' "$PBXPROJ" | head -1)"
CURRENT_BUILD="$(sed -n -E 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/p' "$PBXPROJ" | head -1)"
info "現在のバージョン : ${CURRENT_VERSION:-不明}"
info "新しいバージョン : $VERSION"
info "ビルド番号       : ${CURRENT_BUILD:-不明}（Xcode で手動管理。スクリプトは変更しない）"
info "ブランチ         : $BRANCH"

# ---- リリースノート ---------------------------------------------------------

if [[ $PUBLISH -eq 1 && $AUTO_NOTES -eq 0 ]]; then
	if [[ -n "$NOTES_FILE" ]]; then
		[[ -f "$NOTES_FILE" ]] || die "リリースノートが見つからない: $NOTES_FILE"
	else
		NOTES_FILE="$NOTES_DIR/notes-$VERSION.md"
	fi

	if [[ ! -f "$NOTES_FILE" ]]; then
		if [[ $DRY_RUN -eq 1 ]]; then
			# --dry-run は何も変更しない約束なので、雛形は作らずに告げるだけ。
			warn "リリースノートがまだ無い: $NOTES_FILE"
			warn "本番実行時は、雛形を作った上で一旦停止する。"
		else
			mkdir -p "$(dirname "$NOTES_FILE")"
			printf '%s\n' '- ここに変更点を書く' > "$NOTES_FILE"
			step "リリースノートの雛形を作った"
			info "$NOTES_FILE"
			info "アプリの通知シートは Markdown を解釈しない。"
			info "見出しは使わず「- 」の箇条書きだけで書け。"
			info "書き終えたら、同じコマンドをもう一度実行しろ。"
			exit 0
		fi
	else
		step "リリースノート"
		sed 's/^/    /' "$NOTES_FILE"
	fi
fi

# 公証プロファイルの存在確認。ここで弾いておかないと、
# 5 分かけてビルドした後に「プロファイルが無い」で落ちることになる。
step "公証プロファイルの確認"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
	die "notarytool のプロファイル \"$NOTARY_PROFILE\" が使えない。
     未保存なら次を実行しろ（App 用パスワードが要る。Apple ID のパスワードではない）:
       xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
         --apple-id <your-apple-id> --team-id 3WNHDR762B --password <app-specific-password>
     保存済みならネットワークを疑え。"
fi
info "OK"

if [[ $DRY_RUN -eq 1 ]]; then
	step "--dry-run のためここで終了する"
	info "この後の手順:"
	info "  1. $PBXPROJ の MARKETING_VERSION を $VERSION に書き換える（ビルド番号には触らない）"
	info "  2. xcodebuild archive → exportArchive（Developer ID）"
	info "  3. create-dmg で $APP_NAME-$VERSION.dmg を作成し codesign"
	info "  4. notarytool submit --wait → stapler staple → 検証"
	if [[ $PUBLISH -eq 1 ]]; then
		info "  5. commit / tag v$VERSION / push"
		if [[ $AUTO_NOTES -eq 1 ]]; then
			info "  6. gh release create v${VERSION}（DMG を添付 / ノートは自動生成）"
		else
			info "  6. gh release create v${VERSION}（DMG を添付 / ${NOTES_FILE}）"
		fi
		info "  7. ${SERVER} へ scp（確認あり）"
	else
		info "  5. --no-publish のため push と Release は行わない"
	fi
	exit 0
fi

# ---- 2. バージョンの更新 ---------------------------------------------------

step "バージョンを更新する"

# agvtool を使わず sed で直に書き換える。このプロジェクトは
# GENERATE_INFOPLIST_FILE = YES で Info.plist の実体を持たないため、
# Info.plist を前提にする agvtool は素直に動かないことがある。
# バージョンの真の置き場所は pbxproj なので、そこを直接触るのが確実。
sed -i '' -E "s/(MARKETING_VERSION = )[^;]*;/\1$VERSION;/g" "$PBXPROJ"
VERSION_BUMPED=1

# CURRENT_PROJECT_VERSION（ビルド番号）には触らない。Xcode 側で手動管理する方針。
# 増やす主体を一つに絞っておかないと、どちらが書いた値か分からなくなる。
info "MARKETING_VERSION       = $VERSION"
info "CURRENT_PROJECT_VERSION = ${CURRENT_BUILD:-不明}（変更なし）"

# ---- 3. ビルドと書き出し ---------------------------------------------------

step "アーカイブを作る（数分かかる）"
rm -rf "$BUILD_DIR"
# ログを全部見たければ -quiet を外せ。
# -allowProvisioningUpdates が無いと、プロファイルの取得・更新が
# 必要になった瞬間に落ちる。GUI の Xcode は勝手に取りに行くので、
# 「Xcode では通るのにコマンドラインだと落ちる」の典型的な原因になる。
xcodebuild archive \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-archivePath "$ARCHIVE" \
	-destination 'generic/platform=macOS' \
	-allowProvisioningUpdates \
	-quiet

step "Developer ID で書き出す"
xcodebuild -exportArchive \
	-archivePath "$ARCHIVE" \
	-exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
	-exportPath "$EXPORT_DIR" \
	-allowProvisioningUpdates \
	-quiet

[[ -d "$APP_PATH" ]] || die "書き出しに失敗したらしい: $APP_PATH が無い"

# ---- 4. DMG ----------------------------------------------------------------

DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
DMG_STAGE="$BUILD_DIR/dmg"

step "DMG に入れるものだけを集める"
# xcodebuild は書き出し先に .app だけでなく DistributionSummary.plist /
# ExportOptions.plist / Packaging.log も置く。書き出しディレクトリを
# そのまま create-dmg に渡すと、それらまで DMG に同梱されてしまう。
# 「余計なものを消す」ではなく「必要なものだけを移す」方式にしておけば、
# Xcode が将来別のファイルを吐くようになっても巻き込まれない。
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
# cp ではなく ditto。拡張属性やシンボリックリンクを落とさずに複製できる。
# 署名済みバンドルを cp -R で扱うと、メタデータが欠けて署名が壊れることがある。
ditto "$APP_PATH" "$DMG_STAGE/$APP_NAME.app"

step "署名を検証する"
# DMG に入る実物そのものを検証する。複製で壊れていないことの確認を兼ねる。
codesign --verify --deep --strict --verbose=2 "$DMG_STAGE/$APP_NAME.app"
info "OK"

step "DMG を作る"
rm -f "$DMG"
create-dmg \
	--volname "$APP_NAME" \
	--window-pos 200 120 \
	--window-size 520 340 \
	--icon-size 96 \
	--icon "$APP_NAME.app" 140 160 \
	--app-drop-link 380 160 \
	"$DMG" \
	"$DMG_STAGE"

step "DMG に署名する"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
info "OK"

# ---- 5. 公証 ---------------------------------------------------------------

step "公証に出す（待つ。数分かかる）"
xcrun notarytool submit "$DMG" \
	--keychain-profile "$NOTARY_PROFILE" \
	--wait \
	|| die "公証に失敗した。詳細は次で見ろ:
     xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\""

step "チケットをステープルする"
# ステープルは api.apple-cloudkit.com を叩く。回線によってはここが
# 塞がれていて時間切れになるので、少し待って数回試す。
stapled=0
for attempt in 1 2 3; do
	if xcrun stapler staple "$DMG"; then
		stapled=1
		break
	fi
	warn "ステープルに失敗（$attempt/3）。30 秒待って再試行する。"
	sleep 30
done
if [[ $stapled -eq 0 ]]; then
	die "ステープルできなかった。api.apple-cloudkit.com への接続が塞がれている可能性が高い。
     テザリングに切り替えてから手で叩け:
       xcrun stapler staple \"$DMG\"
     公証そのものは通っているので、ビルドをやり直す必要はない。"
fi

step "最終検証"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
info "OK: $DMG"

if [[ $PUBLISH -eq 0 ]]; then
	step "--no-publish のためここで終了する"
	info "DMG: $DMG"
	info "バージョン変更はコミットされていない。"
	exit 0
fi

# ---- 6. コミット・タグ・push ------------------------------------------------

if [[ $ASSUME_YES -eq 0 ]]; then
	printf '\n'
	printf 'ここから先は取り消せない（push と GitHub Release の作成）。\n'
	printf '  タグ    : v%s\n' "$VERSION"
	printf '  添付    : %s\n' "$(basename "$DMG")"
	printf '  リポジトリ: %s\n' "$GITHUB_REPO"
	read -r -p '進めるか？ [y/N] ' reply
	[[ "$reply" == "y" || "$reply" == "Y" ]] || die "中止した。"
fi

step "コミットしてタグを打つ"
git -C "$REPO_ROOT" add "$PBXPROJ"
# 既に目的のバージョンが入っていた場合、pbxproj に差分が出ない。
# そのまま commit すると「変更なし」で失敗して、公証まで終わった後に
# スクリプトが死ぬことになるので、その場合は HEAD にタグだけ打つ。
if git -C "$REPO_ROOT" diff --cached --quiet; then
	info "pbxproj に変更なし。コミットは省略して HEAD にタグを打つ。"
else
	git -C "$REPO_ROOT" commit -m "Release $VERSION"
fi
git -C "$REPO_ROOT" tag -a "v$VERSION" -m "$APP_NAME $VERSION"
COMMITTED=1

step "push する"
git -C "$REPO_ROOT" push origin "$BRANCH"
git -C "$REPO_ROOT" push origin "v$VERSION"

# ---- 7. GitHub Release ------------------------------------------------------

step "GitHub Release を作る"
# ドラフトやプレリリースにはしない。アプリ側が見る /releases/latest は
# その両方を除外するので、そうすると更新通知が飛ばなくなる。
if [[ $AUTO_NOTES -eq 1 ]]; then
	# GitHub にコミットログから生成させる。生の Markdown と長い URL が
	# そのまま通知シートに流れるので、常用はするな。
	gh release create "v$VERSION" "$DMG" \
		--repo "$GITHUB_REPO" \
		--title "$APP_NAME $VERSION" \
		--generate-notes
else
	gh release create "v$VERSION" "$DMG" \
		--repo "$GITHUB_REPO" \
		--title "$APP_NAME $VERSION" \
		--notes-file "$NOTES_FILE"
fi

# ---- 8. 自分のサーバーに置く --------------------------------------------

if [[ $ASSUME_YES -eq 1 ]]; then
	reply="y"
else
	printf '\n'
	read -r -p "${SERVER} にも DMG を置くか？ [y/N] " reply
fi

if [[ "$reply" == "y" || "$reply" == "Y" ]]; then
	step "ラズパイに転送する"
	REMOTE_DMG="$SERVER_DIR/$APP_NAME-$VERSION.dmg"
	# ここで失敗しても GitHub Release は既に出ている。作り直す必要は
	# 無いので、スクリプトを殺さずに手で叩き直せるコマンドを出す。
	if scp "$DMG" "$SERVER:$REMOTE_DMG"; then
		info "OK: $SERVER:$REMOTE_DMG"
	else
		warn "転送に失敗した。GitHub Release は公開済みなので、これだけ手で叩けばいい:"
		warn "  scp \"$DMG\" \"$SERVER:$REMOTE_DMG\""
	fi
fi

step "完了"
info "リリース: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
info "これで $VERSION より古い NagiKasten に更新通知が出る。"

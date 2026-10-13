#!/bin/bash
# install.sh — modeless-type のビルド・常駐登録・AppleScript の配置
#
# 使い方:
#   ./install.sh             インストール（再実行で更新）
#   ./install.sh uninstall   アンインストール
#
# 環境変数:
#   BIN_DIR   バイナリの置き場所（既定: ~/bin）

set -euo pipefail

LABEL="local.modeless-type"
BIN_DIR="${BIN_DIR:-$HOME/bin}"
BIN="$BIN_DIR/modeless-type"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DIR="$HOME/Library/Application Scripts/com.coteditor.CotEditor"
SCRIPT_NAME="modeless-convert.applescript"
FIFO="$(getconf DARWIN_USER_TEMP_DIR)modeless-type.fifo"
LOG="$HOME/Library/Logs/modeless-type.log"
DOMAIN="gui/$(id -u)"

SRC="$(cd "$(dirname "$0")" && pwd)/src"

info() { printf '==> %s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
die()  { printf 'エラー: %s\n' "$*" >&2; exit 1; }

is_loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

unload() {
    if is_loaded; then
        launchctl bootout "$DOMAIN/$LABEL" || true
        # bootout は非同期で終わることがあるので、外れるまで待つ
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            is_loaded || return 0
            sleep 0.5
        done
        warn "常駐の停止を確認できませんでした"
    fi
}

# 許可の設定画面を 1 つずつ開き、付け終わるまで待つ
# （続けて open すると、システム設定のウインドウが後の画面で上書きされる）
wait_for_permissions() {
    cat <<EOF

システム設定 → プライバシーとセキュリティ の次の 2 つに、
$BIN を追加してください（+ ボタン → Cmd+Shift+G でパスを入力）。

  - アクセシビリティ（キー送信に必要）
  - 入力監視（Enter の検知に必要）

再インストールした場合は、一覧の modeless-type を - で削除してから + で入れ直す
（再ビルドで署名が変わるため。スイッチのオフオンでは直らない）。

EOF
    if ! [ -t 0 ]; then
        info "許可を付けたあと、次を実行してください: launchctl kickstart -k $DOMAIN/$LABEL"
        exit 0
    fi
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
    read -r -p "アクセシビリティに追加したら Enter: " _
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" || true
    read -r -p "入力監視に追加したら Enter: " _
}

do_install() {
    [ "$(uname -s)" = "Darwin" ] || die "macOS 専用です"
    [ -f "$SRC/modeless-type.swift" ] || die "$SRC/modeless-type.swift が見つかりません"

    # 1. Xcode コマンドラインツール
    #    /usr/bin/swiftc はスタブで常に存在するので、xcode-select -p で判定する
    if ! xcode-select -p >/dev/null 2>&1; then
        info "Xcode コマンドラインツールをインストールします（ダイアログに従ってください）"
        xcode-select --install || true
        info "インストールの完了を待っています（中断は Ctrl+C）"
        until xcode-select -p >/dev/null 2>&1; do sleep 5; done
    fi

    # 2. ビルド
    info "ビルド: $BIN"
    local rebuilt=false
    [ -e "$BIN" ] && rebuilt=true
    mkdir -p "$BIN_DIR"
    swiftc -O "$SRC/modeless-type.swift" -o "$BIN"

    # 3. LaunchAgent（テンプレートのパスを実際の BIN に差し替える）
    info "LaunchAgent: $PLIST"
    unload
    mkdir -p "$(dirname "$PLIST")"
    cp "$SRC/modeless-type.plist" "$PLIST"
    # ダウンロードした zip 由来の quarantine 属性が cp で引き継がれると、
    # launchctl bootstrap が "Input/output error" で失敗する
    xattr -c "$PLIST" 2>/dev/null || true
    # ProgramArguments.0 への -replace は置換ではなく挿入になるので、配列ごと作り直す
    plutil -replace ProgramArguments -array "$PLIST"
    plutil -insert ProgramArguments -string "$BIN" -append "$PLIST"
    plutil -lint -s "$PLIST"

    # 4. AppleScript
    info "AppleScript: $SCRIPT_DIR/$SCRIPT_NAME"
    mkdir -p "$SCRIPT_DIR"
    cp "$SRC/$SCRIPT_NAME" "$SCRIPT_DIR/$SCRIPT_NAME"
    xattr -c "$SCRIPT_DIR/$SCRIPT_NAME" 2>/dev/null || true   # quarantine 属性を引き継がない
    # 名前を変えて置いている旧版があれば知らせる（ショートカット用に改名している場合など）
    local f
    for f in "$SCRIPT_DIR"/modeless-convert* "$SCRIPT_DIR"/ModelessConvert*; do
        [ -e "$f" ] || continue
        [ "$(basename "$f")" = "$SCRIPT_NAME" ] && continue
        warn "別名の旧版があります。不要なら削除してください: $f"
    done

    # 5. 許可
    if $rebuilt; then
        info "再ビルドしたので、許可の入れ直しが必要です"
    fi
    wait_for_permissions

    # 6. 起動と確認
    info "常駐を開始します"
    local before=0
    [ -f "$LOG" ] && before=$(wc -l < "$LOG")
    launchctl bootstrap "$DOMAIN" "$PLIST"
    sleep 1

    if ! [ -p "$FIFO" ]; then
        die "常駐を確認できませんでした（$FIFO がありません）。launchctl print $DOMAIN/$LABEL で状態を確認してください"
    fi
    if [ -f "$LOG" ] && tail -n +"$((before + 1))" "$LOG" | grep -q "tapCreate failed"; then
        warn "入力監視の許可が無効です。許可を付け直してから: launchctl kickstart -k $DOMAIN/$LABEL"
    fi

    cat <<EOF

インストール完了。
最後に、スクリプトメニューの modeless-convert にショートカット（Ctrl+J など）を割り当ててください。
システム設定 → キーボード → キーボードショートカット → アプリのショートカット で、
アプリケーションに CotEditor、メニュータイトルに modeless-convert を指定します。
EOF
}

do_uninstall() {
    info "常駐を停止します"
    unload
    rm -f "$PLIST" "$BIN" "$SCRIPT_DIR/$SCRIPT_NAME"
    cat <<EOF

アンインストール完了。
システム設定 → プライバシーとセキュリティ の アクセシビリティ と 入力監視 から、
modeless-type を - で削除してください。
EOF
}

case "${1:-install}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *) die "使い方: $0 [install|uninstall]" ;;
esac

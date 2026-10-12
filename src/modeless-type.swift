// modeless-type.swift （常駐版）
//
// 役割: 「いま選択されている範囲」を対象に、IME ON → 変換 → 確定後に IME OFF までを行う。
//   1. FIFO（ユーザーごとの一時ディレクトリの modeless-type.fifo）から 1行 = ローマ字テキスト を受け取る
//   2. Delete（選択範囲を削除）→ かな(IME ON) → ローマ字を物理キーで送信 → Space（変換開始）
//   3. Enter / テンキーEnter / Ctrl+M を検知したら 英数 を送って IME OFF
// 各イベントの修飾フラグは明示的に空にするので、Ctrl 押下中でも Ctrl+K などにならない。
// キー送信中・英数の送信待ちに届いた要求は、拒否してビープで知らせる。
// 要求を受け取った時の最前面アプリを覚えておき、最前面が変わったらキー送信を中断する
// （別のアプリに打ち込まないため）。確定キーも、そのアプリで押された時だけ扱う。
//
// 常駐させる理由: CotEditor 経由の起動は約0.5秒かかるため、起動を1回きりにする。
// 終了時（SIGTERM / SIGINT / 通常終了）は FIFO を削除する。FIFO が無ければ
// AppleScript 側が「常駐していない」と判断して、ビープで知らせる。
//
// ビルド:   mkdir -p ~/bin && swiftc -O modeless-type.swift -o ~/bin/modeless-type
// 起動:     LaunchAgent（modeless-type.plist 参照）で常駐
// 必要な許可: システム設定 > プライバシーとセキュリティ >
//           アクセシビリティ と 入力監視 に ~/bin/modeless-type 自身を追加
//           （再ビルドした場合は再度許可設定が必要）
// 送信例:   printf '%s\n' kyouha 1<>"$(getconf DARWIN_USER_TEMP_DIR)modeless-type.fifo"

import Foundation
import CoreGraphics
import AppKit

// ユーザーごとの一時ディレクトリ（/var/folders/.../T/）。getconf DARWIN_USER_TEMP_DIR と同じ値。
// 他のユーザーも書き込める /tmp を避けるため。環境変数 TMPDIR は起動元によって違うことがあるので使わない
func userTempDir() -> String {
    let n = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
    var buf = [CChar](repeating: 0, count: n)
    confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, n)
    return String(cString: buf)
}

let fifoPath = userTempDir() + "modeless-type.fifo"
let logPath = NSHomeDirectory() + "/Library/Logs/modeless-type.log"
let debugLog = false  // 調査時だけ true（失敗系のログは常に ~/Library/Logs/modeless-type.log に出る）

let keyMap: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
    "n": 45, "m": 46, "-": 27, ",": 43, ".": 47, " ": 49,
]
// Shift を押して出す記号（US・JIS 配列とも同じ位置）
let shiftedKeyMap: [Character: CGKeyCode] = [
    "!": 18, "?": 44,
]

// --- キーコード設定（IME や環境に合わせてここだけ変える）---
// IME ON/OFF: 「かな」「英数」の仮想キーコード（物理キーに依存しない）。
//   IME 側でこれらのキーの意味を変えている場合・トグル式にしている場合は調整が必要。
let imeOnKey: CGKeyCode = 104      // かな
let imeOffKey: CGKeyCode = 102     // 英数
let deleteKey: CGKeyCode = 51      // Delete（選択範囲の削除）
let spaceKey: CGKeyCode = 49       // Space（変換開始）
// 変換の確定として扱うキー
let confirmKeyCodes: Set<Int64> = [36, 76]          // Return / テンキー Enter
let confirmWithCtrlKeyCodes: Set<Int64> = [46]      // Ctrl+M（M キー + Control）

// 待ち時間（マイクロ秒）。取りこぼすなら増やす
let afterDeleteWait: UInt32 = 10_000
let imeOnWait: UInt32 = 100_000
let keyGap: UInt32 = 1_000
let beforeSpaceWait: UInt32 = 10_000
let afterConfirmWait: Int = 120_000     // Enter が IME に処理されるのを待つ
let watchTimeoutSec: Double = 30

func log(_ msg: String, force: Bool = false) {
    guard debugLog || force else { return }
    let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, msg)
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

let source = CGEventSource(stateID: .hidSystemState)

func post(_ code: CGKeyCode, shift: Bool = false, hold: UInt32 = 0) {
    for down in [true, false] {
        if !down && hold > 0 { usleep(hold) } // keyDown と keyUp の間隔
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
        e.flags = shift ? .maskShift : CGEventFlags(rawValue: 0) // 物理で押されている修飾キーを無視
        e.post(tap: .cghidEventTap)
    }
}

func postUnicode(_ ch: Character) {
    let utf16 = Array(String(ch).utf16)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
        e.flags = CGEventFlags(rawValue: 0)
        e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        e.post(tap: .cghidEventTap)
    }
}

// --- 状態（main キューからのみ触る） ---
// idle → typing（キー送信中）→ waiting（確定待ち）→ finishing（英数の送信待ち）→ idle
enum Phase { case idle, typing, waiting, finishing }
var phase = Phase.idle
var generation = 0          // 要求ごとに増やす。古いタイマーや中断の通知を無視するため
var targetPid: pid_t = -1   // 要求を受け取った時の最前面アプリ
var eventTap: CFMachPort?

// キー送信は直列のワーカーで行う
let worker = DispatchQueue(label: "modeless.worker", qos: .userInteractive)

// 最前面アプリの pid（main キューから呼ぶ。NSWorkspace の値は main の run loop で更新される）
func frontmostPid() -> pid_t {
    NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
}

// FIFO から 1行届いた時（main キュー）
func handleRequest(_ text: String) {
    switch phase {
    case .typing, .finishing:
        log("busy (\(phase)), rejected: \(text)")
        NSSound.beep()
        return
    // 確定待ちの間に届いた要求は、新しい要求として受け付ける。
    // Enter 以外で確定した・Esc で取り消した場合も waiting のまま残るため、拒否すると最大 30 秒変換できなくなる。
    // 変換中の文字列がある間の Ctrl+J は IME が受け取るので、ここには届かない
    case .idle, .waiting:
        break
    }
    generation += 1
    let g = generation
    let pid = frontmostPid()
    targetPid = pid
    phase = .typing
    worker.async { typeAndConvert(text, pid: pid, generation: g) }
}

func typeAndConvert(_ text: String, pid: pid_t, generation g: Int) {
    log("request: \(text) (pid \(pid))")

    // 最前面のアプリが変わっていたら、それ以上キーを送らない
    func stillFront() -> Bool {
        if DispatchQueue.main.sync(execute: frontmostPid) == pid { return true }
        log("frontmost changed, aborted")
        DispatchQueue.main.async { if generation == g { phase = .idle } }
        return false
    }

    guard stillFront() else { return }
    post(deleteKey)                // Delete（選択範囲を削除）
    log("delete posted")
    usleep(afterDeleteWait)
    guard stillFront() else { return }
    post(imeOnKey)                 // かな (IME ON)
    log("kana posted")
    usleep(imeOnWait)
    for ch in text {
        guard stillFront() else { return }
        let lower = Character(String(ch).lowercased())
        let isUpper = (String(ch) != String(ch).lowercased())
        if let code = keyMap[lower] {
            post(code, shift: isUpper)
        } else if let code = shiftedKeyMap[ch] {
            post(code, shift: true)
        } else {
            postUnicode(ch)
        }
        usleep(keyGap)
    }
    log("typed")
    usleep(beforeSpaceWait)
    guard stillFront() else { return }
    post(spaceKey)                 // Space（変換開始）
    log("space sent")

    // 確定待ちを開始（30秒で自動解除）
    DispatchQueue.main.async {
        guard generation == g else { return }
        phase = .waiting
        DispatchQueue.main.asyncAfter(deadline: .now() + watchTimeoutSec) {
            if generation == g && phase == .waiting { phase = .idle }
        }
    }
}

// --- 確定検知: confirmKeyCodes / Ctrl+confirmWithCtrlKeyCodes（既定: Enter・テンキーEnter・Ctrl+M）---
let confirmCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown && phase == .waiting {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let ctrlConfirm = confirmWithCtrlKeyCodes.contains(code) && event.flags.contains(.maskControl)
        if confirmKeyCodes.contains(code) || ctrlConfirm {
            // 別のアプリで押された確定キーは無視する（元のアプリに戻って確定するのを待ち続ける）
            guard frontmostPid() == targetPid else {
                log("confirm key \(code) in another app, ignored")
                return Unmanaged.passUnretained(event)
            }
            phase = .finishing
            let g = generation
            log("confirm key \(code)")
            worker.asyncAfter(deadline: .now() + .microseconds(afterConfirmWait)) {
                post(imeOffKey, hold: 30_000)    // 英数 (IME OFF)
                log("eisu sent")
                DispatchQueue.main.async { if generation == g { phase = .idle } }
            }
        }
    }
    return Unmanaged.passUnretained(event)
}

// --- 起動 ---
log("daemon start")

unlink(fifoPath)
guard mkfifo(fifoPath, 0o600) == 0 else {
    log("mkfifo failed", force: true)
    exit(1)
}
// 通常終了・シグナル終了のどちらでも FIFO を消す（SIGKILL・クラッシュ時は次回起動時の unlink で掃除）
atexit { _ = unlink(fifoPath) }

// O_RDWR で開くので、書き手がいなくても EOF にならず、書き手の open もブロックしない
let fifoFD = open(fifoPath, O_RDWR)
guard fifoFD >= 0 else {
    log("open fifo failed", force: true)
    exit(1)
}

let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
eventTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: confirmCallback,
    userInfo: nil
)
if let tap = eventTap {
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("tap ok")
} else {
    log("tapCreate failed（入力監視の許可なし？ 許可後はデーモンの再起動が必要）", force: true)
}

// FIFO から 1行ずつ読む
var inputBuffer = Data()
let fifoHandle = FileHandle(fileDescriptor: fifoFD, closeOnDealloc: false)
fifoHandle.readabilityHandler = { h in
    let d = h.availableData
    if d.isEmpty { return }
    inputBuffer.append(d)
    while let nl = inputBuffer.firstIndex(of: 0x0A) {
        let lineData = inputBuffer.subdata(in: inputBuffer.startIndex..<nl)
        inputBuffer.removeSubrange(inputBuffer.startIndex...nl)
        if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
            DispatchQueue.main.async { handleRequest(line) }
        }
    }
}

// SIGTERM（launchctl bootout / kickstart -k）と SIGINT（端末で Ctrl+C）で exit → atexit が FIFO を削除
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { exit(0) }
termSource.resume()
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSource.setEventHandler { exit(0) }
intSource.resume()

CFRunLoopRun()
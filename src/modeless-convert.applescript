-- modeless-convert.applescript
-- カーソル直前の「ASCII 文字（スペース以外）の連なり」を選択し、
-- 常駐している modeless-type（FIFO 経由）に渡して 削除 → IME ON → 変換 → 確定後 IME OFF を行う。
-- 日本語・スペース・タブ・改行・行頭に当たったところで遡りを止める。
-- 前提: CotEditor の range は {location(0始まり), length}
-- 前提: modeless-type が LaunchAgent で常駐していること（modeless-type.swift 冒頭参照）

property maxScan : 100
-- FIFO はユーザーごとの一時ディレクトリに置かれる（modeless-type.swift の fifoPath と同じ）
property fifoShellPath : "\"$(getconf DARWIN_USER_TEMP_DIR)modeless-type.fifo\""

-- 変換対象の文字か: ASCII の印字可能文字（! から ~ まで。スペースは含まない）
-- どのキーで打つかは modeless-type がキーボードレイアウトから決める
on isTargetChar(c)
	try
		set i to id of c
		if class of i is not integer then return false -- 複数のコードポイントからなる文字（絵文字など）
		return i >= 33 and i <= 126
	on error
		return false
	end try
end isTargetChar

set targetText to ""

-- 1) CotEditor からは「本文・カーソル位置・選択長」だけ取得する
tell application "CotEditor"
	if (count of documents) is 0 then return
	tell front document
		set txt to contents
		set sel to range of selection
	end tell
end tell
set loc to item 1 of sel
set len to item 2 of sel

-- 2) 対象範囲の計算（ここは CotEditor の外）
if len is 0 then
	if loc is 0 then return
	set lo to loc - maxScan
	if lo < 0 then set lo to 0
	set seg to text (lo + 1) thru loc of txt
	set segLen to loc - lo -- length は CotEditor 実行環境で解決できないため計算で求める

	set j to segLen
	set k to j
	repeat while j > 0
		if my isTargetChar(character j of seg) then
			set k to j
			set j to j - 1
		else
			exit repeat
		end if
	end repeat
	if j is segLen then return -- 直前がローマ字でなければ何もしない
	set startPos to lo + k - 1
	-- 対象テキストは小さい seg から切り出す（巨大な本文への添字アクセスを避ける）
	set targetText to text k thru segLen of seg
else
	set startPos to loc
	set targetText to text (loc + 1) thru (loc + len) of txt
end if

set n to loc + len - startPos
if n < 1 or targetText is "" then return

-- 選択範囲を使う場合は、変換対象の文字だけで構成されている時に限る
-- （日本語やスペースを含めて選択したまま実行しても、消して再入力しない）
if len > 0 then
	repeat with ch in characters of targetText
		if not my isTargetChar(contents of ch) then
			beep
			return
		end if
	end repeat
end if

-- 3) 範囲を選択（削除は modeless-type が Delete キーで行う）
tell application "CotEditor"
	tell front document
		set range of selection to {startPos, n}
	end tell
end tell

-- 4) 常駐プロセスへ送る。
--    1<> は読み書きで開くので、読み手がいなくてもブロックしない。
--    FIFO が無い（常駐していない）場合はシェルが失敗するので、選択を元に戻してビープで知らせる。
try
	do shell script "f=" & fifoShellPath & "; [ -p \"$f\" ] && printf '%s\\n' " & quoted form of targetText & " 1<>\"$f\""
on error
	try
		tell application "CotEditor"
			tell front document
				set range of selection to {loc, len}
			end tell
		end tell
	end try
	beep
end try

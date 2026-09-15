; =========================================
; 모아치기 (Chord) 입력 보조 도구 - AutoHotkey v2
; 모음 시작 자음+모음 조합에 대해서 입력 순서를 재배열하여 IME로 전달하는 스크립트입니다.
;
; 원리:
;   - 오직 모음으로 시작하는 키 조합에 대해서만 AHK가 개입하여 재배열을 수행합니다.
;   - CHORD_MS 시간 내에서 다음 패턴에 대해서만 재배열이 일어납니다:
;       VC  -> CV
;       VV  -> 정규화된 VV (이중모음에 한정)
;       VCV / VVC / CVV -> CVV
;   - 모음 시작 조합이 아닌 경우 AHK는 개입하지 않고 그대로 IME로 전달합니다.
;   - 종성 처리는 이 스크립트가 아니라 IME가 담당합니다.
; =========================================

#Requires AutoHotkey v2.0
#SingleInstance Force
InstallKeybdHook()

; -------------------------
; 설정 (Settings)
; -------------------------
global CHORD_MS := 25
global MAX_KEYS := 3
global g_enabled := true
global g_lastHandledSessionId := 0

; -------------------------
; 세션 상태 (Session state)
; -------------------------
global g_timerOn := false
global g_keys := []
global g_sessionId := 0

; -------------------------
; 기능 토글 (F8)
; -------------------------
global g_hookKeys := ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"]

F8::ToggleMoachigi()

ToggleMoachigi() {
    global g_enabled

    g_enabled := !g_enabled
    SetMoachigiHooks(g_enabled)
    ResetSession()
    ToolTip("Moachigi = " . (g_enabled ? "On" : "Off"))
    SetTimer(HideTip, -800)
}

SetMoachigiHooks(isOn) {
    global g_hookKeys

    state := isOn ? "On" : "Off"

    for k in g_hookKeys
        Hotkey("$" . k, state)
}

HideTip() {
    ToolTip()
}

; =========================================
; 1) 키 분류 (표준 두벌식 기준)
; =========================================
IsConsonantKey(k) {
    static set := Map(
        "r", 1, "s", 1, "e", 1, "f", 1, "a", 1,
        "q", 1, "t", 1, "d", 1, "w", 1, "c", 1,
        "z", 1, "x", 1, "v", 1, "g", 1
    )
    return set.Has(k)
}

IsVowelKey(k) {
    static set := Map(
        "k", 1, "o", 1, "i", 1, "j", 1, "p", 1, "u", 1,
        "h", 1, "y", 1, "n", 1, "b", 1, "m", 1, "l", 1
    )
    return set.Has(k)
}

; ============================================
; 2) 이중모음 처리 보조 함수 (Diphthong helpers)
; ============================================
IsDiphPair(v1, v2) {
    pair := v1 . "+" . v2

    static table := Map(
        "h+k", 1, "k+h", 1,
        "h+o", 1, "o+h", 1,
        "h+l", 1, "l+h", 1,
        "n+j", 1, "j+n", 1,
        "n+p", 1, "p+n", 1,
        "n+l", 1, "l+n", 1,
        "m+l", 1, "l+m", 1
    )

    return table.Has(pair)
}

NormalizeVowels(v1, v2) {
    pair := v1 . "+" . v2

    static canon := Map(
        "h+k", "h+k", "k+h", "h+k",
        "h+o", "h+o", "o+h", "h+o",
        "h+l", "h+l", "l+h", "h+l",
        "n+j", "n+j", "j+n", "n+j",
        "n+p", "n+p", "p+n", "n+p",
        "n+l", "n+l", "l+n", "n+l",
        "m+l", "m+l", "l+m", "m+l"
    )

    if !canon.Has(pair)
        return [v1, v2]

    return StrSplit(canon[pair], "+")
}

; =========================================
; 3) 보조 함수 (Helpers)
; =========================================
CountCV(arr) {
    c := 0
    v := 0
    o := 0

    for k in arr {
        if IsConsonantKey(k)
            c += 1
        else if IsVowelKey(k)
            v += 1
        else
            o += 1
    }

    return {c: c, v: v, o: o}
}

ClonePush(src, k) {
    out := []
    for x in src
        out.Push(x)
    out.Push(k)
    return out
}

JoinKeys(arr) {
    output := ""

    for k in arr
        output .= k

    return output
}

; SendEvent를 사용하되, {Text}가 아니라 실제 키 이벤트를 보냅니다.
; 이 스크립트의 출력은 최종 영문 텍스트가 아니라
; 날개셋 입력기가 해석할 QWERTY 키열이기 때문입니다.
EmitKeySequence(sequence) {
    if (sequence = "")
        return

    oldLevel := A_SendLevel
    SendLevel 0
    SendEvent(sequence)
    SendLevel oldLevel
}

ResetSession() {
    global g_timerOn, g_keys
    g_timerOn := false
    g_keys := []
    SetTimer(ChordTimeout, 0)
}

StartSessionWith(k) {
    global g_timerOn, g_keys, CHORD_MS, g_sessionId
    ResetSession()
    g_timerOn := true
    g_sessionId += 1
    g_keys.Push(k)
    SetTimer(ChordTimeout, -CHORD_MS)
}

; =========================================
; 4) 후보 조합 규칙 (Candidate policy)
;    세션은 반드시 모음으로 시작해야 합니다.
; =========================================
IsAllowedPrefix(arr) {
    counts := CountCV(arr)
    c := counts.c
    v := counts.v
    o := counts.o

    if (o > 0)
        return false

    len := arr.Length

    ; 모든 세션은 모음으로 시작해야 합니다.
    if !IsVowelKey(arr[1])
        return false

    ; V
    if (len = 1)
        return (v = 1)

    ; VC, VV(이중모음, diphthong)
    if (len = 2) {
        if (c = 1 && v = 1)
            return true
        if (c = 0 && v = 2)
            return IsDiphPair(arr[1], arr[2])
        return false
    }

    ; VCV / VVC / CVV를 다중 집합으로 (모음 시작 세션 중에)
    if (len = 3 && c = 1 && v = 2) {
        vv := []
        for k in arr {
            if IsVowelKey(k)
                vv.Push(k)
        }
        return IsDiphPair(vv[1], vv[2])
    }

    return false
}

IsAllowedFinal(arr) {
    counts := CountCV(arr)
    c := counts.c
    v := counts.v
    o := counts.o

    if (o > 0)
        return false

    len := arr.Length

    if !IsVowelKey(arr[1])
        return false

    ; VC -> CV
    if (len = 2 && c = 1 && v = 1)
        return true

    ; VCV / VVC / CVV -> CVV
    if (len = 3 && c = 1 && v = 2) {
        vv := []
        for k in arr {
            if IsVowelKey(k)
                vv.Push(k)
        }
        return IsDiphPair(vv[1], vv[2])
    }

    return false
}

; =========================================
; 5) 출력 처리 보조 함수 (Emit helpers)
; =========================================
EmitRaw(arr) {
    EmitKeySequence(JoinKeys(arr))
}

EmitReordered(arr) {
    cons := []
    vows := []
    others := []

    for k in arr {
        if IsConsonantKey(k)
            cons.Push(k)
        else if IsVowelKey(k)
            vows.Push(k)
        else
            others.Push(k)
    }

    if (others.Length > 0)
        return false

    ; VC -> CV
    if (arr.Length = 2 && cons.Length = 1 && vows.Length = 1) {
        EmitKeySequence(cons[1] . vows[1])
        return true
    }

    ; VCV / VVC / CVV -> C + 정규화된 VV
    if (arr.Length = 3 && cons.Length = 1 && vows.Length = 2 && IsDiphPair(vows[1], vows[2])) {
        norm := NormalizeVowels(vows[1], vows[2])
        EmitKeySequence(cons[1] . norm[1] . norm[2])
        return true
    }

    return false
}

EmitCurrent() {
    global g_keys

    if (g_keys.Length = 0)
        return

    keys := []
    for k in g_keys
        keys.Push(k)

    g_keys := []
    SetTimer(ChordTimeout, 0)

    if !EmitReordered(keys)
        EmitRaw(keys)
}

; =========================================
; 6) 메인 입력 처리기 (Main input handler)
; =========================================
OnKey(k) {
    global g_enabled, g_timerOn, g_keys, CHORD_MS, MAX_KEYS, g_sessionId

    ; 비활성 상태에서는 Hotkey 자체가 꺼지므로 일반적으로 이 경로에 들어오지 않습니다.
    ; 토글 경계 등에서 호출되었을 경우를 위한 안전 경로입니다.
    if !g_enabled {
        EmitKeySequence(k)
        return
    }

    ; Shift/Ctrl/Alt 중 하나라도 눌린 상태라면 로직을 우회하여 입력 그대로 전달
    if (GetKeyState("Shift", "P") || GetKeyState("Ctrl", "P") || GetKeyState("Alt", "P")) {
        EmitKeySequence(k)
        return
    }

    ; 활성 세션이 없는 경우: 모음으로만 chord 세션을 시작할 수 있습니다.
    if !g_timerOn {
        if IsConsonantKey(k) {
            EmitKeySequence(k)
            return
        }
        StartSessionWith(k)
        return
    }

    ; 활성 세션용 롤링 타이머
    g_sessionId += 1
    SetTimer(ChordTimeout, 0)
    SetTimer(ChordTimeout, -CHORD_MS)

    ; 동일한 키가 한 세션 내에서 반복될 경우 -> 현재 키를 플러시한 후 새로 처리
    for kk in g_keys {
        if (kk = k) {
            EmitCurrent()
            ResetSession()

            if IsConsonantKey(k) {
                EmitKeySequence(k)
                return
            }
            StartSessionWith(k)
            return
        }
    }

    candidate := ClonePush(g_keys, k)

    ; Hard guard: 세션 버퍼는 MAX_KEYS를 초과할 수 없습니다.
    if (g_keys.Length > MAX_KEYS) {
        ResetSession()
    }

    ; 너무 길어지는 경우 -> 현재 세션 플러시 후 현재 키를 새로 처리
    if (candidate.Length > MAX_KEYS) {
        EmitCurrent()
        ResetSession()

        if IsConsonantKey(k) {
            EmitKeySequence(k)
            return
        }
        StartSessionWith(k)
        return
    }

    ; 후보 조합이 허용된 접두어/최종 형태가 아니라면 현재 세션을 종료하고 새로 시작
    if (candidate.Length >= 2) {
        if (!IsAllowedPrefix(candidate) && !IsAllowedFinal(candidate)) {
            EmitCurrent()
            ResetSession()

            if IsConsonantKey(k) {
                EmitKeySequence(k)
                return
            }
            StartSessionWith(k)
            return
        }
    }

    ; 누적
    g_keys.Push(k)

    ; 3-key final이 준비되면 즉시 출력
    if (g_keys.Length = 3 && IsAllowedFinal(g_keys)) {
        SetTimer(ChordTimeout, 0)
        EmitCurrent()
        ResetSession()
    }
}

ChordTimeout() {
    global g_timerOn, g_sessionId, g_lastHandledSessionId

    if (g_sessionId = g_lastHandledSessionId)
        return

    if g_timerOn {
        g_lastHandledSessionId := g_sessionId
        EmitCurrent()
        ResetSession()
    }
}

; =========================================
; 7) 키 훅 (Hooks)
; =========================================
$a::OnKey("a")
$b::OnKey("b")
$c::OnKey("c")
$d::OnKey("d")
$e::OnKey("e")
$f::OnKey("f")
$g::OnKey("g")
$h::OnKey("h")
$i::OnKey("i")
$j::OnKey("j")
$k::OnKey("k")
$l::OnKey("l")
$m::OnKey("m")
$n::OnKey("n")
$o::OnKey("o")
$p::OnKey("p")
$q::OnKey("q")
$r::OnKey("r")
$s::OnKey("s")
$t::OnKey("t")
$u::OnKey("u")
$v::OnKey("v")
$w::OnKey("w")
$x::OnKey("x")
$y::OnKey("y")
$z::OnKey("z")

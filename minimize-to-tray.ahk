#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
SetWorkingDir(A_ScriptDir)

; We hide windows via WinHide, then later need to read their titles, activate,
; and close them while still hidden. WinGetTitle, WinActivate, and WinClose all
; respect DetectHiddenWindows for matching - turn it on globally so they find
; our hidden hwnds. WinShow is exempt and works on hidden windows regardless.
DetectHiddenWindows(true)

;==============================================================================
; minimize-to-tray - minimize the focused window to the system tray, grouped by app.
;
; Triggers:
;   Win+Shift+Z                  - minimize the focused window
;   Middle-click on title bar    - minimize that window
;==============================================================================

;------------------------------------------------------------------------------
; Constants - Win32 messages, Shell_NotifyIcon, WinEvent
;------------------------------------------------------------------------------
global WM_USER             := 0x0400
global WM_TRAYCALLBACK     := WM_USER + 1     ; 0x0401
global WM_LBUTTONUP        := 0x0202
global WM_RBUTTONUP        := 0x0205
global WM_CONTEXTMENU      := 0x007B
global WM_NCHITTEST        := 0x0084

global NIM_ADD             := 0x00000000
global NIM_MODIFY          := 0x00000001
global NIM_DELETE          := 0x00000002

global NIF_MESSAGE         := 0x00000001
global NIF_ICON            := 0x00000002
global NIF_TIP             := 0x00000004

global EVENT_OBJECT_DESTROY  := 0x8001
global OBJID_WINDOW          := 0
global CHILDID_SELF          := 0
global WINEVENT_OUTOFCONTEXT := 0

global HTCAPTION           := 2

; NOTIFYICONDATAW size = 976 bytes on Windows 10/11 x64.
global NID_SIZE := 976

;------------------------------------------------------------------------------
; State
;------------------------------------------------------------------------------
global Groups           := Map()         ; processName -> { windows: Array, trayUid: Int, hIcon: Int }
global nextTrayUid      := 1             ; monotonic UID allocator
global scriptGuiHwnd    := 0             ; hidden recipient hwnd for Shell_NotifyIcon callbacks
global winEventCallback := 0             ; CallbackCreate ptr for OnWinEvent
global hWinEventHook    := 0             ; SetWinEventHook handle

; Velopack update awareness (populated by CheckForUpdateAsync via updater-helper.exe)
global APP_VERSION      := "1.0.6"       ; embedded version, kept in sync with vpk pack --packVersion
global UpdateAvailable  := false         ; true if updater-helper.exe reports a newer release
global UpdateVersion    := ""            ; the new version string from the helper
global pulsePhase       := 0.0           ; phase angle for the About dialog's pulsing dot animation
global appImagePath     := ""            ; resolved at script init - source file in dev, %TEMP% in compiled

; Run-on-login state. The in-process global is the source of truth so dev-mode
; toggles persist within a session without writing the registry (raw .ahk
; A_ScriptFullPath isn't directly executable at Windows login). Compiled .exe
; mirrors writes to HKCU\...\Run\<RUN_REG_VALUE>, and the global is seeded from
; the registry at startup so it survives across launches.
global RUN_REG_KEY       := "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run"
global RUN_REG_VALUE     := "minimize-to-tray"
global RUN_MENU_LABEL    := "&Run on login"
global runOnLoginState   := 0           ; in-process truth; seeded from registry at init
global aboutRunOnLoginCb := 0           ; About-dialog checkbox handle (or 0 when dialog closed)

; Light/Dark theme state. Same source-of-truth pattern as Run-on-login: in-process
; global seeded from registry at init, mirrored to registry on toggle when compiled.
global themeState        := "light"     ; "light" | "dark"; seeded in Initialize()
global aboutThemeIcon    := 0           ; About-dialog theme-toggle Text handle (or 0 when closed)
global aboutControlRefs  := ""          ; Map(role -> Gui.Control) populated in ShowAbout

; App-scoped registry key. Values stored here:
;   FirstRunPending  (REG_DWORD)  v1.0.2: signals "show About on first launch after install"
;   Theme            (REG_SZ)     v1.0.3: "light" | "dark", current theme state
global APP_REG_KEY                 := "HKEY_CURRENT_USER\Software\bilbospocketses\minimize-to-tray"
global FIRST_RUN_PENDING_REG_VALUE := "FirstRunPending"
global APP_THEME_REG_VALUE         := "Theme"

; v1.0.7 rescue mode: persistent hidden-window tracking + diagnostic state.
; APP_DATA_DIR is %LOCALAPPDATA%\bilbospocketses\minimize-to-tray\, created in Initialize().
global APP_DATA_DIR        := ""
global HIDDEN_STATE_FILE   := ""
global HIDDEN_STATE_TMP    := ""
global RESCUE_LOG_FILE     := ""
global rescueGui           := 0    ; modal Gui handle while open; 0 otherwise

;==============================================================================
; Triggers
;==============================================================================
#+z::MinimizeFocused()

#HotIf MouseOverTitleBar()
MButton::MinimizeUnderCursor()
#HotIf

;------------------------------------------------------------------------------
; Initialization
;------------------------------------------------------------------------------
; Velopack lifecycle hook handler. Velopack invokes our main exe with
;   --veloapp-install <ver>     first run after install
;   --veloapp-updated <ver>     first run after update
;   --veloapp-obsoleted <ver>   last run before being replaced by an update
;   --veloapp-uninstall         last run before uninstall
; The .NET SDK's VelopackApp.Build().Run() handles these automatically, but our
; main exe is native AHK-compiled. We have to do it ourselves: detect any
; --veloapp-* arg and exit cleanly so Velopack's installer doesn't report a
; timeout. On uninstall, also wipe the Run-on-login registry entry so Windows
; doesn't keep trying to launch a no-longer-installed exe at login.
for arg in A_Args {
    if (arg = "--veloapp-install") {
        ; Fresh install: default Run-on-login ON, seed Theme from the Windows Apps
        ; theme, and set a first-run marker so the normal-launch path that follows
        ; will surface the About dialog once (giving the user a chance to opt out
        ; of Run-on-login immediately and see the seeded theme).
        try RegWrite(A_ScriptFullPath, "REG_SZ", RUN_REG_KEY, RUN_REG_VALUE)
        try RegWrite(ReadWindowsAppsTheme(), "REG_SZ", APP_REG_KEY, APP_THEME_REG_VALUE)
        try RegWrite(1, "REG_DWORD", APP_REG_KEY, FIRST_RUN_PENDING_REG_VALUE)
        ExitApp 0
    }
    if (arg = "--veloapp-uninstall") {
        ; Wipe everything we wrote so Windows doesn't keep launching a gone exe
        ; at login and we don't leave stray app-scoped values behind.
        try RegDelete(RUN_REG_KEY, RUN_REG_VALUE)
        try RegDeleteKey(APP_REG_KEY)
        ExitApp 0
    }
    if (SubStr(arg, 1, 10) = "--veloapp-") {
        ExitApp 0
    }
}

; Dev-only flags for smoke-testing the update-available UI without a real update.
; /devshowdot         - force UpdateAvailable := true at startup so the dot is
;                       present from the first About open. Tests the dot-at-
;                       creation path.
; /devsimulateupdate  - leave UpdateAvailable := false at startup; on the next
;                       CheckForUpdateAsync run (startup +5s, or every About
;                       open via the v1.0.4 timer), short-circuit the helper
;                       call and flip UpdateAvailable. Tests the live-inject
;                       path added in v1.0.5: open About, watch the dot appear.
global DevSimulateUpdate := false
for arg in A_Args {
    if (arg = "/devshowdot") {
        UpdateAvailable := true
        UpdateVersion := "1.0.99-dev"
    }
    if (arg = "/devsimulateupdate") {
        DevSimulateUpdate := true
    }
}

Initialize()

Initialize() {
    global scriptGuiHwnd, winEventCallback, hWinEventHook

    ; Hidden stub GUI whose hwnd receives Shell_NotifyIcon callback messages.
    ; Never shown. Owns no visible UI.
    scriptGui := Gui("+ToolWindow -Caption", "minimize-to-tray-stub")
    scriptGui.Show("Hide x-1000 y-1000 w1 h1 NoActivate")
    scriptGuiHwnd := scriptGui.Hwnd

    ; Register handler for tray callback message (WM_TRAYCALLBACK = 0x0401).
    OnMessage(WM_TRAYCALLBACK, OnTrayMessage)

    ; Custom app tray icon. When running as compiled .exe, the embedded icon
    ; (set via Ahk2Exe /icon during compile) is already used by default.
    ; When running as raw .ahk source, point to the file in assets/.
    if (!A_IsCompiled) {
        iconPath := A_ScriptDir "\assets\app.ico"
        if (FileExist(iconPath))
            TraySetIcon(iconPath)
    }

    ; Resolve a path to the app PNG (used in the About dialog).
    ; - Raw .ahk: the source file in assets/.
    ; - Compiled .exe: extract once to %TEMP% via FileInstall (Ahk2Exe embeds the file).
    global appImagePath
    if (A_IsCompiled) {
        appImagePath := A_Temp "\minimize-to-tray-app.png"
        if (!FileExist(appImagePath))
            FileInstall("assets\app.png", appImagePath, true)
    } else {
        appImagePath := A_ScriptDir "\assets\app.png"
    }

    ; Resolve app-data paths (rescue state + log). Falls back to A_AppData if
    ; LOCALAPPDATA is empty (rare but possible in stripped service-account profiles).
    global APP_DATA_DIR, HIDDEN_STATE_FILE, HIDDEN_STATE_TMP, RESCUE_LOG_FILE
    base := EnvGet("LOCALAPPDATA")
    if (base == "")
        base := A_AppData
    APP_DATA_DIR      := base "\bilbospocketses\minimize-to-tray"
    HIDDEN_STATE_FILE := APP_DATA_DIR "\hidden.json"
    HIDDEN_STATE_TMP  := APP_DATA_DIR "\hidden.json.tmp"
    RESCUE_LOG_FILE   := APP_DATA_DIR "\rescue.log"
    try DirCreate(APP_DATA_DIR)

    ; Always-visible app tray icon tooltip
    A_IconTip := "minimize-to-tray`n"
              .  "Win+Shift+Z or`n"
              .  "Middle-click title bar`n"
              .  "minimizes focused window to tray"

    A_TrayMenu.Delete()
    A_TrayMenu.Add("&About", ShowAbout)
    A_TrayMenu.Add()
    A_TrayMenu.Add(RUN_MENU_LABEL, ToggleRunOnLoginFromMenu)
    A_TrayMenu.Add()
    A_TrayMenu.Add("E&xit", (*) => ExitApp())
    A_TrayMenu.Default := "&About"
    A_TrayMenu.ClickCount := 1   ; single left-click on the app tray icon opens About (default item)

    ; Seed Run-on-login state from the registry and sync UI
    global runOnLoginState
    runOnLoginState := ReadRegistryRunOnLogin()
    UpdateRunOnLoginUI()

    ; Seed theme state. Compiled installs are seeded by --veloapp-install; existing
    ; pre-v1.0.3 users get a one-time seed from the Windows Apps theme on first run.
    global themeState
    themeState := ReadRegistryTheme()
    if (themeState = "") {
        themeState := ReadWindowsAppsTheme()
        if (A_IsCompiled)
            try RegWrite(themeState, "REG_SZ", APP_REG_KEY, APP_THEME_REG_VALUE)
    }

    ; v1.0.7: surface any windows orphaned by a prior crashed session.
    RescueOrphanedWindows()

    ; Register destroy hook for orphan cleanup.
    ; No "F" (Fast) option - we want the callback marshaled to AHK's main thread
    ; before we touch Groups / call Shell_NotifyIcon.
    winEventCallback := CallbackCreate(OnWinEvent, , 7)
    hWinEventHook := DllCall("SetWinEventHook"
                              , "UInt", EVENT_OBJECT_DESTROY
                              , "UInt", EVENT_OBJECT_DESTROY
                              , "Ptr",  0
                              , "Ptr",  winEventCallback
                              , "UInt", 0       ; idProcess (0 = all processes)
                              , "UInt", 0       ; idThread
                              , "UInt", WINEVENT_OUTOFCONTEXT
                              , "Ptr")

    ; OnExit cleanup
    OnExit(Cleanup)

    ; Schedule an asynchronous Velopack update check 5 seconds after start.
    ; Stub-only until updater-helper.exe is built and packaged with the app.
    SetTimer(CheckForUpdateAsync, -5000)

    ; First-run after a fresh install: the --veloapp-install hook set
    ; FirstRunPending. Pop About so the user sees the Run-on-login default
    ; (now ON) and can opt out immediately. Clear the marker so this only
    ; happens once per install.
    try {
        pending := RegRead(APP_REG_KEY, FIRST_RUN_PENDING_REG_VALUE, 0)
        if (pending) {
            try RegDelete(APP_REG_KEY, FIRST_RUN_PENDING_REG_VALUE)
            SetTimer(ShowAbout, -800)   ; ~800ms after init so the tray icon settles first
        }
    }
}

;==============================================================================
; Run-on-login (Windows registry HKCU\...\Run autostart entry)
;==============================================================================
; Reading + writing the registry value is the single source of truth.
; Both the tray right-click menu item and the About-dialog checkbox sync
; through UpdateRunOnLoginUI() after any toggle.

IsRunOnLoginEnabled() {
    global runOnLoginState
    return runOnLoginState
}

ReadRegistryRunOnLogin() {
    global RUN_REG_KEY, RUN_REG_VALUE
    try {
        val := RegRead(RUN_REG_KEY, RUN_REG_VALUE)
        return (val != "") ? 1 : 0
    } catch {
        return 0
    }
}

ReadRegistryTheme() {
    ; Returns "light" | "dark" if the Theme value is present and valid, else "".
    global APP_REG_KEY, APP_THEME_REG_VALUE
    try {
        val := RegRead(APP_REG_KEY, APP_THEME_REG_VALUE)
        if (val = "light" || val = "dark")
            return val
    }
    return ""
}

ReadWindowsAppsTheme() {
    ; Returns "light" | "dark" based on the Windows Apps theme registry value.
    ; Falls back to "light" if AppsUseLightTheme is missing (some imaged installs).
    try {
        v := RegRead("HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
        return (v = 0) ? "dark" : "light"
    } catch {
        return "light"
    }
}

SetRunOnLogin(enabled) {
    global runOnLoginState, RUN_REG_KEY, RUN_REG_VALUE
    runOnLoginState := enabled ? 1 : 0
    ; Registry write only meaningful in compiled mode - raw .ahk's A_ScriptFullPath
    ; isn't directly executable at Windows login. Dev toggles persist in-session
    ; via the global only.
    if (A_IsCompiled) {
        if (enabled) {
            try RegWrite(A_ScriptFullPath, "REG_SZ", RUN_REG_KEY, RUN_REG_VALUE)
        } else {
            try RegDelete(RUN_REG_KEY, RUN_REG_VALUE)
        }
    }
    UpdateRunOnLoginUI()
}

UpdateRunOnLoginUI() {
    global RUN_MENU_LABEL, aboutRunOnLoginCb, runOnLoginState
    enabled := runOnLoginState

    ; Sync the tray menu checkmark
    try {
        if (enabled)
            A_TrayMenu.Check(RUN_MENU_LABEL)
        else
            A_TrayMenu.Uncheck(RUN_MENU_LABEL)
    }

    ; Sync the About-dialog checkbox (if open)
    if (aboutRunOnLoginCb && IsObject(aboutRunOnLoginCb)) {
        try aboutRunOnLoginCb.Value := enabled
    }
}

ToggleRunOnLoginFromMenu(*) {
    SetRunOnLogin(!IsRunOnLoginEnabled())
}

OnAboutRunOnLoginToggle(ctrl, *) {
    SetRunOnLogin(ctrl.Value)
}

;==============================================================================
; Light/Dark theme - palette + live apply
;==============================================================================
GetThemePalette(name) {
    if (name = "dark") {
        return {
            bg:           "1F1F1F",
            title:        "F2F2F2",
            version:      "A0A0A0",
            shortcut:     "F2F2F2",
            italic:       "B8B8B8",
            url:          "4DA3FF",
            checkbox:     "F2F2F2",
            okButton:     "F2F2F2",
            themeGlyph:   "",          ; emoji moon is color-locked; tint is ignored
            text:         "F2F2F2",    ; v1.0.7: rescue dialog body text
            buttonBg:     "2D2D2D",    ; v1.0.7: owner-drawn button fill (normal)
            buttonFg:     "F2F2F2",    ; v1.0.7: owner-drawn button text
            buttonBorder: "4D4D4D",    ; v1.0.7: owner-drawn button border
            buttonHover:  "383838",    ; v1.0.7: owner-drawn button fill (hover, deferred)
            buttonPressed:"252525",    ; v1.0.7: owner-drawn button fill (pressed)
            buttonDefault:"4DA3FF",    ; v1.0.7: default-pushbutton accent border
            headerBg:     "2D2D2D",    ; v1.0.7: ListView header background
            headerFg:     "F2F2F2",    ; v1.0.7: ListView header text
            focusRing:    "4DA3FF"     ; v1.0.7: focus-ring inside owner-drawn controls
        }
    }
    return {
        bg:           "FFFFFF",
        title:        "000000",
        version:      "707070",
        shortcut:     "000000",
        italic:       "606060",
        url:          "0066CC",
        checkbox:     "000000",
        okButton:     "000000",
        themeGlyph:   "D9A300",        ; gold sun
        text:         "000000",
        buttonBg:     "FDFDFD",
        buttonFg:     "000000",
        buttonBorder: "D1D1D1",
        buttonHover:  "F5F5F5",
        buttonPressed:"E6E6E6",
        buttonDefault:"0078D4",
        headerBg:     "F0F0F0",
        headerFg:     "000000",
        focusRing:    "0078D4"
    }
}

ApplyThemeToAbout() {
    ; Live re-style of the About dialog. No-op when the dialog isn't open.
    global aboutGui, aboutControlRefs, aboutThemeIcon, themeState
    if (!aboutGui || !IsObject(aboutGui))
        return

    pal := GetThemePalette(themeState)
    try aboutGui.BackColor := pal.bg

    if (IsObject(aboutControlRefs)) {
        for role, ctrl in aboutControlRefs {
            if (!IsObject(ctrl))
                continue
            color := pal.%role%
            if (color != "") {
                try ctrl.Opt("c" color)
                try ctrl.Redraw()
            }
        }
    }

    ; Swap the theme-icon glyph + color
    if (IsObject(aboutThemeIcon)) {
        if (themeState = "dark") {
            try aboutThemeIcon.Text := Chr(0x1F319)   ; crescent-moon emoji
        } else {
            try aboutThemeIcon.Text := Chr(0x2600)    ; classic sun
        }
        if (pal.themeGlyph != "")
            try aboutThemeIcon.Opt("c" pal.themeGlyph)
        try aboutThemeIcon.Redraw()
    }

    ; Tell DWM to draw the OS title bar in the matching theme. Without this the
    ; title bar stays Light even when the app body goes Dark. Attribute 20 =
    ; DWMWA_USE_IMMERSIVE_DARK_MODE, supported on Win10 19041+ and all Win11.
    SetAboutTitleBarDark(themeState = "dark")

    ; Force a top-level repaint so the BackColor change is visible immediately
    try aboutGui.Show("NoActivate")
}

SetAboutTitleBarDark(isDark) {
    global aboutGui
    if (!aboutGui || !IsObject(aboutGui))
        return
    val := isDark ? 1 : 0
    try DllCall("dwmapi\DwmSetWindowAttribute"
        , "Ptr",  aboutGui.Hwnd
        , "UInt", 20             ; DWMWA_USE_IMMERSIVE_DARK_MODE
        , "Int*", val
        , "UInt", 4)             ; sizeof(BOOL)
}

ToggleTheme(*) {
    global themeState, APP_REG_KEY, APP_THEME_REG_VALUE
    themeState := (themeState = "light") ? "dark" : "light"
    if (A_IsCompiled) {
        try RegWrite(themeState, "REG_SZ", APP_REG_KEY, APP_THEME_REG_VALUE)
    }
    ApplyThemeToAbout()
}

;==============================================================================
; About menu - custom Gui with pulsing blue update-available dot
;==============================================================================
; A global handle so the pulse timer can reach the live Gui control.
global aboutGui    := 0
global aboutDot    := 0
global pulseTimer  := 0

ShowAbout(*) {
    global aboutGui, aboutDot, pulseTimer, APP_VERSION, UpdateAvailable, UpdateVersion
    global aboutThemeIcon, aboutControlRefs, themeState
    aboutControlRefs := Map()

    ; If a previous About is still showing, just bring it forward.
    if (aboutGui && IsObject(aboutGui)) {
        try {
            aboutGui.Show()
            return
        }
    }

    aboutGui := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "About minimize-to-tray")
    ; MarginX is small here only so AutoSize doesn't pad the dot (the rightmost
    ; control) far from the dialog's right edge. All other controls use explicit
    ; x = 28 so their visual left/right padding is unaffected by this.
    aboutGui.MarginX := 15
    aboutGui.MarginY := 20
    aboutGui.BackColor := "FFFFFF"

    contentW := 440   ; inner content width; outer width = contentW + 2 * MarginX

    ; ---- Title row "cell": image | title+version, centered as a group ----
    ; The image+text pair is treated as a single horizontally-centered unit in the
    ; dialog so the image doesn't hug the left edge while the title floats in the
    ; middle (which read as "off center" visually). Image is a single cell spanning
    ; two text rows; title row 1 and version row 2 share a narrow text band right
    ; after the image, each line centered within that band.
    imgSize    := 96
    imgY       := 24
    textBlockW := 220                                  ; narrow band keeps text tight to image
    imgGap     := 20                                   ; horizontal gap between image and text

    groupW     := imgSize + imgGap + textBlockW        ; 336 total group width
    imgX       := 28 + (contentW - groupW) // 2        ; center the group in contentW
    imgCenterY := imgY + imgSize // 2                  ; vertical anchor for title text
    textStartX := imgX + imgSize + imgGap

    ; Title + version block - combined height ~36px, centered on imgCenterY (72).
    titleY := imgCenterY - 19   ; tuned so title baseline + version sit centered

    ; App image (now horizontally centered with the title block as one group)
    if (FileExist(appImagePath))
        aboutGui.Add("Picture", Format("x{1} y{2} w{3} h{3}", imgX, imgY, imgSize), appImagePath)

    aboutGui.SetFont("s16 Bold c000000", "Segoe UI")
    aboutControlRefs["title"] := aboutGui.Add("Text", Format("x{1} y{2} w{3} Center", textStartX, titleY, textBlockW), "minimize-to-tray")

    aboutGui.SetFont("s9 Norm c707070", "Segoe UI")
    aboutControlRefs["version"] := aboutGui.Add("Text", Format("x{1} y+4 w{2} Center", textStartX, textBlockW), "v" APP_VERSION)

    ; Top-right corner controls. Layout (left -> right):
    ;   [optional update dot]  [theme toggle]
    ; The theme toggle is ALWAYS present. The update dot is only created when
    ; an update is available, and slides 44px to the left of the theme icon.
    iconW       := 32
    rightEdge   := 28 + contentW
    themeIconX  := rightEdge - iconW + 20    ; same x as the old top-right dot
    themeIconY  := 4

    ; Update dot first (if applicable), so the visual left-to-right order matches.
    if (UpdateAvailable) {
        dotX := themeIconX - iconW - 12      ; 12px gap to the left of theme icon
        dotY := themeIconY
        aboutGui.SetFont("s22 Bold cBlue", "Segoe UI Symbol")
        aboutDot := aboutGui.Add("Text", Format("x{1} y{2} w{3} h36 Center", dotX, dotY, iconW), Chr(9679))
        aboutDot.OnEvent("Click", OnClickUpdateDot)
        pulseTimer := PulseDot
        SetTimer(pulseTimer, 40)
    }

    ; Theme toggle (always present). Glyph + tint reflect current themeState;
    ; ApplyThemeToAbout (called at the end of ShowAbout) normalizes both, so the
    ; literal here just needs the right initial character.
    initialGlyph := (themeState = "dark") ? Chr(0x1F319) : Chr(0x2600)
    aboutGui.SetFont("s22 Bold cD9A300", "Segoe UI Symbol")
    aboutThemeIcon := aboutGui.Add("Text", Format("x{1} y{2} w{3} h36 Center", themeIconX, themeIconY, iconW), initialGlyph)
    aboutThemeIcon.OnEvent("Click", ToggleTheme)

    ; Single polling routine for both the dot and theme-icon hover tooltips.
    SetTimer(UpdateAboutHoverTooltips, 100)

    ; ---- Shortcut block ----
    ; Bumped down ~20px from the previous layout (request: more breathing room between
    ; the image/title cell and the shortcut block). Uses an absolute Y so the position
    ; is decoupled from the version control's y+N flow.
    shortcutY := imgY + imgSize + 24   ; image bottom + 24px breathing gap
    aboutGui.SetFont("s11 Norm c000000", "Segoe UI")
    aboutControlRefs["shortcut"] := aboutGui.Add("Text", Format("x28 y{1} w{2} Center", shortcutY, contentW),
                 "Win+Shift+Z   |   or   |   Middle-click on a title bar")

    aboutGui.SetFont("s10 Italic c606060", "Segoe UI")
    aboutControlRefs["italic"] := aboutGui.Add("Text", Format("x28 y+8 w{1} Center", contentW),
                 "minimize focused window to tray")

    ; ---- Run on login (centered checkbox above the URL) ----
    ; AHK Checkbox with `w 440 Center` pins the box to the LEFT of a 440px-wide
    ; control and only centers the label - the box+label combo looks split.
    ; Instead: add at a placeholder x with no explicit width (auto-sizes to label),
    ; measure the actual width, then Move to a calculated centered x. This puts
    ; the box directly to the left of "Run on login" as a tight unit.
    global aboutRunOnLoginCb
    aboutGui.SetFont("s10 Norm c000000", "Segoe UI")
    aboutRunOnLoginCb := aboutGui.Add("Checkbox", "x28 y+20", "Run on login")
    aboutRunOnLoginCb.Value := IsRunOnLoginEnabled()
    aboutRunOnLoginCb.OnEvent("Click", OnAboutRunOnLoginToggle)
    aboutRunOnLoginCb.GetPos(, &cbY, &cbW, )
    aboutRunOnLoginCb.Move(28 + (contentW - cbW) // 2, cbY)
    aboutControlRefs["checkbox"] := aboutRunOnLoginCb

    ; ---- Footer (clickable URL + OK) ----
    ; URL styled as a link (blue + underline). Click opens in default browser.
    githubUrl := "https://github.com/bilbospocketses/minimize-to-tray"
    aboutGui.SetFont("s9 Norm c0066CC Underline", "Segoe UI")
    urlCtrl := aboutGui.Add("Text", Format("x28 y+12 w{1} Center", contentW), githubUrl)
    urlCtrl.OnEvent("Click", (*) => Run(githubUrl))
    aboutControlRefs["url"] := urlCtrl

    okX := 28 + (contentW - 96) // 2
    aboutGui.SetFont("s9 Norm c000000", "Segoe UI")
    okBtn := aboutGui.Add("Button", Format("x{1} y+12 w96 h28 Default", okX), "OK")
    okBtn.OnEvent("Click", (*) => CloseAbout())
    aboutControlRefs["okButton"] := okBtn

    aboutGui.OnEvent("Close",  (*) => CloseAbout())
    aboutGui.OnEvent("Escape", (*) => CloseAbout())

    ; Initial theme paint - applies background + per-control colors before show.
    ApplyThemeToAbout()

    aboutGui.Show("AutoSize Center")

    ; Fire an update check on every About-open (in addition to the 5s-after-init
    ; check from Initialize). SetTimer with -1 schedules the check on the next
    ; message-loop tick so the dialog renders first - no perceived hitch.
    ; If the check finds an update, UpdateAvailable flips and the blue dot will
    ; appear on the NEXT About open. Live-injecting the dot into a currently-
    ; open dialog is deliberately out of scope for v1.0.4.
    SetTimer(CheckForUpdateAsync, -1)
}

CloseAbout() {
    global aboutGui, aboutDot, pulseTimer, aboutRunOnLoginCb, aboutThemeIcon, aboutControlRefs
    if (pulseTimer) {
        SetTimer(pulseTimer, 0)
        pulseTimer := 0
    }
    SetTimer(UpdateAboutHoverTooltips, 0)
    ToolTip()    ; dismiss any lingering hover tooltip
    if (aboutGui && IsObject(aboutGui)) {
        try aboutGui.Destroy()
    }
    aboutGui := 0
    aboutDot := 0
    aboutRunOnLoginCb := 0
    aboutThemeIcon := 0
    aboutControlRefs := ""
}

UpdateAboutHoverTooltips() {
    ; Single polling routine for all About-dialog hover tooltips. Tracks which
    ; control (if any) the cursor is over; shows the matching tooltip; dismisses
    ; on leave. Used by both the update dot and the theme toggle - AHK Text
    ; controls don't fire MouseEnter events, so we sample MouseGetPos at 100ms.
    global aboutGui, aboutDot, aboutThemeIcon, UpdateAvailable, UpdateVersion, themeState
    static showing := ""   ; "" | "dot" | "theme"

    if (!aboutGui || !IsObject(aboutGui)) {
        if (showing != "") {
            ToolTip()
            showing := ""
        }
        return
    }

    try {
        MouseGetPos(, , , &ctrlHwnd, 2)
    } catch {
        ctrlHwnd := 0
    }

    target := ""
    if (UpdateAvailable && IsObject(aboutDot) && ctrlHwnd == aboutDot.Hwnd) {
        target := "dot"
    } else if (IsObject(aboutThemeIcon) && ctrlHwnd == aboutThemeIcon.Hwnd) {
        target := "theme"
    }

    if (target = showing)
        return

    if (target = "dot") {
        ToolTip(
            "Update available: v" UpdateVersion "`n"
          . "Click to download and install.`n`n"
          . "minimize-to-tray`n"
          . "Win+Shift+Z or`n"
          . "Middle-click title bar`n"
          . "minimizes focused window to tray"
        )
    } else if (target = "theme") {
        otherTheme := (themeState = "light") ? "Dark" : "Light"
        ToolTip("Switch to " otherTheme " theme")
    } else {
        ToolTip()
    }
    showing := target
}

PulseDot() {
    global aboutDot, pulsePhase
    if (!aboutDot || !IsObject(aboutDot))
        return

    pulsePhase += 0.18  ; ~1.4 Hz pulse at 40ms tick
    if (pulsePhase > 6.2832)
        pulsePhase -= 6.2832

    ; Sine wave eased to (0.35, 1.0) brightness range
    t := (Sin(pulsePhase) + 1) / 2          ; 0..1
    intensity := 0.35 + 0.65 * t            ; 0.35..1.0

    ; Lerp between a dim blue (#0a3a8a) and a bright blue (#3b82f6)
    r := Round(10  + (59  - 10)  * intensity)
    g := Round(58  + (130 - 58)  * intensity)
    b := Round(138 + (246 - 138) * intensity)
    color := Format("{:02X}{:02X}{:02X}", r, g, b)

    try aboutDot.Opt("c" color)
    try aboutDot.Redraw()
}

OnClickUpdateDot(*) {
    global UpdateAvailable
    if (!UpdateAvailable)
        return

    ; Spawn the Velopack helper to download + apply + restart.
    helperPath := A_ScriptDir "\updater-helper.exe"
    if (!FileExist(helperPath)) {
        MsgBox("Update helper missing at: " helperPath, "minimize-to-tray", "IconX")
        return
    }
    Run(Format('"{1}" update', helperPath))
    ; updater-helper handles the restart; our OnExit fires and Velopack swaps the install.
    ExitApp()
}

;------------------------------------------------------------------------------
; Velopack update check (async, fire-and-forget)
;------------------------------------------------------------------------------
CheckForUpdateAsync() {
    global UpdateAvailable, UpdateVersion, A_IsCompiled, DevSimulateUpdate

    ; Dev short-circuit: /devsimulateupdate flag bypasses the helper entirely
    ; and just flips UpdateAvailable + AddUpdateDotToAbout. Smoke test for the
    ; live-inject path. The "!UpdateAvailable" guard prevents repeated triggers
    ; once already flipped (this function fires from multiple call sites).
    if (DevSimulateUpdate && !UpdateAvailable) {
        UpdateAvailable := true
        UpdateVersion := "1.0.99-dev"
        AddUpdateDotToAbout()
        return
    }

    ; Only check when running as compiled exe inside a Velopack install
    if (!A_IsCompiled)
        return

    helperPath := A_ScriptDir "\updater-helper.exe"
    if (!FileExist(helperPath))
        return

    try {
        shell := ComObject("WScript.Shell")
        exec := shell.Exec(Format('"{1}" check', helperPath))
        exec.StdIn.Close()
        result := Trim(exec.StdOut.ReadAll(), " `t`r`n")
        exitCode := exec.ExitCode
    } catch as err {
        return  ; helper failed; silently swallow
    }

    if (exitCode == 0 && result != "" && result != APP_VERSION) {
        UpdateAvailable := true
        UpdateVersion := result
        ; v1.0.5: if About is currently open, inject the dot live so the user
        ; sees it without having to close + reopen the dialog.
        AddUpdateDotToAbout()
    }
}

AddUpdateDotToAbout() {
    ; Live-inject the pulsing blue update dot into an already-open About dialog.
    ; No-op if About isn't open, the dot already exists, or the theme icon
    ; (which anchors the dot's position) is missing. The hover-tooltip polling
    ; routine picks up the new dot automatically because it re-resolves
    ; aboutDot.Hwnd on every tick.
    global aboutGui, aboutDot, aboutThemeIcon, pulseTimer
    if (!aboutGui || !IsObject(aboutGui))
        return
    if (aboutDot && IsObject(aboutDot))
        return
    if (!aboutThemeIcon || !IsObject(aboutThemeIcon))
        return

    iconW := 32
    aboutThemeIcon.GetPos(&tX, &tY, , )
    dotX := tX - iconW - 12     ; 12px gap to the left of the theme icon
    dotY := tY

    aboutGui.SetFont("s22 Bold cBlue", "Segoe UI Symbol")
    aboutDot := aboutGui.Add("Text", Format("x{1} y{2} w{3} h36 Center", dotX, dotY, iconW), Chr(9679))
    aboutDot.OnEvent("Click", OnClickUpdateDot)
    pulseTimer := PulseDot
    SetTimer(pulseTimer, 40)
}

;==============================================================================
; Triggers - handlers
;==============================================================================
MinimizeFocused() {
    hwnd := WinGetID("A")
    if (!hwnd)
        return
    HideAndStash(hwnd)
}

MouseOverTitleBar() {
    global WM_NCHITTEST, HTCAPTION

    MouseGetPos(&x, &y, &hwnd)
    if (!hwnd)
        return false

    ; SendMessage WM_NCHITTEST with screen-coord lParam (y << 16 | x).
    lParam := ((y & 0xFFFF) << 16) | (x & 0xFFFF)
    try {
        result := SendMessage(WM_NCHITTEST, 0, lParam, , "ahk_id " hwnd, , , , 200)
    } catch {
        return false
    }
    return result == HTCAPTION
}

MinimizeUnderCursor() {
    MouseGetPos(, , &hwnd)
    if (!hwnd)
        return
    ; Resolve to the top-level window (in case the click landed on a child control).
    rootHwnd := DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr")  ; GA_ROOT = 2
    if (rootHwnd)
        HideAndStash(rootHwnd)
    else
        HideAndStash(hwnd)
}

;==============================================================================
; Core flow
;==============================================================================
HideAndStash(hwnd) {
    try {
        pid      := WinGetPID("ahk_id " hwnd)
        procName := ProcessGetName(pid)
        exePath  := ProcessGetPath(pid)
    } catch {
        return  ; window died or we cannot see it
    }

    ; Register in tray group system (creates group + icon if first window of this type)
    if (!RegisterTrayGroup(hwnd, pid, procName, exePath))
        return  ; ShellNotifyAdd failed twice, error already shown

    WinHide("ahk_id " hwnd)

    ; v1.0.7: persist this hide so the next session can rescue it if we crash.
    try {
        title := WinGetTitle("ahk_id " hwnd)
        HiddenState_Append(hwnd, pid, procName, exePath, title)
    } catch as e {
        LogRescue("HideAndStash: HiddenState_Append failed for hwnd=" hwnd ": " e.Message)
    }

    UpdateGroupTooltip(procName)
}

RegisterTrayGroup(hwnd, pid, procName, exePath) {
    ; Shared private helper used by HideAndStash and StashAlreadyHidden.
    ; Adds hwnd to the procName group (creating + registering tray icon if needed).
    ; Returns true on success, false if Shell_NotifyIcon registration failed.
    global Groups, nextTrayUid

    if (Groups.Has(procName)) {
        Groups[procName].windows.Push(hwnd)
        return true
    }

    ; First window of this type - create new group + new tray icon
    hIcon := GetExeIcon(exePath)
    if (!hIcon)
        hIcon := DllCall("LoadIconW", "Ptr", 0, "Ptr", 32512, "Ptr")

    uid := nextTrayUid
    nextTrayUid++

    result := ShellNotifyAdd(uid, hIcon, procName)
    if (!result) {
        Sleep(500)
        result := ShellNotifyAdd(uid, hIcon, procName)
    }
    if (!result) {
        MsgBox("Shell_NotifyIcon(NIM_ADD) failed twice for " procName ". Aborting minimize.",
               "minimize-to-tray", "IconX")
        DllCall("DestroyIcon", "Ptr", hIcon)
        return false
    }

    Groups[procName] := { windows: [hwnd], trayUid: uid, hIcon: hIcon }
    return true
}

StashAlreadyHidden(hwnd, pid, procName, exePath) {
    ; Rescue path: window is already hidden from a previous session. We just
    ; need to re-register it in Groups + tray. The hidden.json entry was
    ; written by the previous session and stays in place (preserved across
    ; this session's RegisterTrayGroup call - we do NOT call HiddenState_Append).
    if (!RegisterTrayGroup(hwnd, pid, procName, exePath))
        return
    UpdateGroupTooltip(procName)
}

UpdateGroupTooltip(procName) {
    global Groups
    if (!Groups.Has(procName))
        return
    group := Groups[procName]
    n := group.windows.Length
    tooltip := procName " (" n " window" (n == 1 ? "" : "s") ")"
    ShellNotifyModifyTooltip(group.trayUid, group.hIcon, tooltip)
}

DestroyGroup(procName) {
    global Groups
    if (!Groups.Has(procName))
        return
    group := Groups[procName]
    ShellNotifyDelete(group.trayUid)
    if (group.hIcon)
        DllCall("DestroyIcon", "Ptr", group.hIcon)
    Groups.Delete(procName)
}

RestoreSpecific(procName, hwnd, *) {
    global Groups
    if (!Groups.Has(procName))
        return
    group := Groups[procName]

    ; Remove hwnd from the stack
    for i, h in group.windows {
        if (h == hwnd) {
            group.windows.RemoveAt(i)
            break
        }
    }
    try {
        WinShow("ahk_id " hwnd)
        WinActivate("ahk_id " hwnd)
    }
    try HiddenState_Remove(hwnd)
    catch as e
        LogRescue("RestoreSpecific: HiddenState_Remove failed for hwnd=" hwnd ": " e.Message)
    if (group.windows.Length == 0)
        DestroyGroup(procName)
    else
        UpdateGroupTooltip(procName)
}

RestoreAll(procName, *) {
    global Groups
    if (!Groups.Has(procName))
        return
    group := Groups[procName]
    ; Restore top-of-stack first
    i := group.windows.Length
    while (i >= 1) {
        hwnd := group.windows[i]
        try {
            WinShow("ahk_id " hwnd)
            WinActivate("ahk_id " hwnd)
        }
        try HiddenState_Remove(hwnd)
        catch as e
            LogRescue("RestoreAll: HiddenState_Remove failed for hwnd=" hwnd ": " e.Message)
        i--
    }
    group.windows := []
    DestroyGroup(procName)
}

CloseAll(procName, *) {
    global Groups
    if (!Groups.Has(procName))
        return
    group := Groups[procName]
    ; Clone the array - WinClose may trigger the destroy hook which mutates the stack.
    snapshot := group.windows.Clone()
    for hwnd in snapshot {
        try WinClose("ahk_id " hwnd)
    }
    ; The EVENT_OBJECT_DESTROY hook handles bookkeeping as windows die.
    ; If a WinClose is blocked (cancel prompt), that window stays in the stack
    ; and the tray icon persists with the survivors.
}

;------------------------------------------------------------------------------
; Shell_NotifyIcon wrappers (NIM_ADD / NIM_MODIFY / NIM_DELETE)
;------------------------------------------------------------------------------
BuildNid(uid, flags, hIcon := 0, tooltip := "") {
    global NID_SIZE, scriptGuiHwnd, WM_TRAYCALLBACK
    nid := Buffer(NID_SIZE, 0)

    NumPut("UInt", NID_SIZE,         nid, 0)    ; cbSize
    NumPut("Ptr",  scriptGuiHwnd,    nid, 8)    ; hWnd
    NumPut("UInt", uid,              nid, 16)   ; uID
    NumPut("UInt", flags,            nid, 20)   ; uFlags
    NumPut("UInt", WM_TRAYCALLBACK,  nid, 24)   ; uCallbackMessage
    NumPut("Ptr",  hIcon,            nid, 32)   ; hIcon

    ; szTip is a WCHAR[128] at offset 40 (Unicode, 256 bytes).
    if (tooltip != "")
        StrPut(tooltip, nid.Ptr + 40, 127, "UTF-16")

    return nid
}

ShellNotifyAdd(uid, hIcon, tooltip) {
    global NIM_ADD, NIF_MESSAGE, NIF_ICON, NIF_TIP
    flags := NIF_MESSAGE | NIF_ICON | NIF_TIP
    nid := BuildNid(uid, flags, hIcon, tooltip)
    return DllCall("shell32\Shell_NotifyIconW", "UInt", NIM_ADD, "Ptr", nid.Ptr, "Int")
}

ShellNotifyModifyTooltip(uid, hIcon, tooltip) {
    global NIM_MODIFY, NIF_ICON, NIF_TIP
    flags := NIF_ICON | NIF_TIP
    nid := BuildNid(uid, flags, hIcon, tooltip)
    return DllCall("shell32\Shell_NotifyIconW", "UInt", NIM_MODIFY, "Ptr", nid.Ptr, "Int")
}

ShellNotifyDelete(uid) {
    global NIM_DELETE
    nid := BuildNid(uid, 0)
    return DllCall("shell32\Shell_NotifyIconW", "UInt", NIM_DELETE, "Ptr", nid.Ptr, "Int")
}

;------------------------------------------------------------------------------
; Helpers
;------------------------------------------------------------------------------
GetExeIcon(exePath) {
    ; Returns an HICON for the first large icon embedded in exePath, or 0 on failure.
    ; Caller is responsible for DestroyIcon.
    hIconLarge := 0
    count := DllCall("shell32\ExtractIconExW"
                     , "WStr", exePath
                     , "Int",  0           ; nIconIndex (0 = first)
                     , "Ptr*", &hIconLarge
                     , "Ptr*", 0           ; phiconSmall - we do not want it
                     , "UInt", 1
                     , "UInt")
    return (count >= 1 && hIconLarge) ? hIconLarge : 0
}

HwndToGroup(hwnd) {
    ; Reverse lookup: returns the processName of the group containing hwnd, or "" if not tracked.
    global Groups
    for procName, group in Groups {
        for trackedHwnd in group.windows {
            if (trackedHwnd == hwnd)
                return procName
        }
    }
    return ""
}

;==============================================================================
; Tray callback (WM_TRAYCALLBACK)
;==============================================================================
OnTrayMessage(wParam, lParam, msg, hwnd) {
    global Groups, WM_LBUTTONUP, WM_RBUTTONUP, WM_CONTEXTMENU

    uid := wParam
    event := lParam & 0xFFFF  ; low word is the mouse event

    ; Find the group with this trayUid
    foundProcName := ""
    for procName, group in Groups {
        if (group.trayUid == uid) {
            foundProcName := procName
            break
        }
    }
    if (foundProcName == "")
        return

    group := Groups[foundProcName]

    if (event == WM_LBUTTONUP) {
        ; Pop the top of the stack and restore
        if (group.windows.Length == 0) {
            DestroyGroup(foundProcName)
            return
        }
        targetHwnd := group.windows.Pop()
        try {
            WinShow("ahk_id " targetHwnd)
            WinActivate("ahk_id " targetHwnd)
        }
        try HiddenState_Remove(targetHwnd)
        catch as e
            LogRescue("OnTrayMessage LBUTTONUP: HiddenState_Remove failed for hwnd=" targetHwnd ": " e.Message)
        ; If stack now empty, destroy group; else update tooltip
        if (group.windows.Length == 0)
            DestroyGroup(foundProcName)
        else
            UpdateGroupTooltip(foundProcName)
        return
    }

    if (event == WM_RBUTTONUP || event == WM_CONTEXTMENU) {
        ShowGroupMenu(foundProcName)
        return
    }
}

ShowGroupMenu(procName) {
    global Groups
    if (!Groups.Has(procName))
        return
    group := Groups[procName]

    groupMenu := Menu()
    ; Per-window items, top of stack first
    i := group.windows.Length
    while (i >= 1) {
        hwnd := group.windows[i]
        title := ""
        try title := WinGetTitle("ahk_id " hwnd)
        if (title == "")
            title := "(no title)"
        ; Truncate long titles for menu sanity
        if (StrLen(title) > 80)
            title := SubStr(title, 1, 77) . "..."
        groupMenu.Add(title, RestoreSpecific.Bind(procName, hwnd))
        i--
    }
    groupMenu.Add()  ; separator
    groupMenu.Add("Restore &All", RestoreAll.Bind(procName))
    groupMenu.Add("Close A&ll",   CloseAll.Bind(procName))
    groupMenu.Show()
}

;==============================================================================
; Orphan cleanup - event-driven via SetWinEventHook(EVENT_OBJECT_DESTROY)
;==============================================================================
OnWinEvent(hHook, event, hwnd, idObject, idChild, idEventThread, dwmsEventTime) {
    global Groups, OBJID_WINDOW, CHILDID_SELF

    ; Filter: only top-level window destroys, not their child object destroys
    if (idObject != OBJID_WINDOW || idChild != CHILDID_SELF)
        return

    procName := HwndToGroup(hwnd)
    if (procName == "")
        return

    group := Groups[procName]
    for i, h in group.windows {
        if (h == hwnd) {
            group.windows.RemoveAt(i)
            break
        }
    }
    try HiddenState_Remove(hwnd)
    catch as e
        LogRescue("OnWinEvent: HiddenState_Remove failed for hwnd=" hwnd ": " e.Message)

    if (group.windows.Length == 0)
        DestroyGroup(procName)
    else
        UpdateGroupTooltip(procName)
}

;==============================================================================
; OnExit cleanup - restore every hidden window before quitting
;==============================================================================
Cleanup(reason, code) {
    global Groups, hWinEventHook

    ; Unhook the WinEvent listener first so destroy events during cleanup do not double-fire.
    if (hWinEventHook) {
        DllCall("UnhookWinEvent", "Ptr", hWinEventHook)
        hWinEventHook := 0
    }

    for procName, group in Groups {
        for hwnd in group.windows {
            try WinShow("ahk_id " hwnd)
        }
        if (group.hIcon)
            DllCall("DestroyIcon", "Ptr", group.hIcon)
        ShellNotifyDelete(group.trayUid)
    }
    Groups.Clear()

    ; v1.0.7: every hidden window was just restored, so the rescue state is empty.
    try HiddenState_Clear()
}

;==============================================================================
; v1.0.7 rescue mode - persistent hidden-window state + log helper
;==============================================================================
LogRescue(message) {
    ; Append a timestamped line to rescue.log. Best-effort - never throws.
    ; Strip embedded newlines from message so multi-line content (window titles,
    ; exception messages) doesn't split a single record into multiple log lines.
    global RESCUE_LOG_FILE
    if (RESCUE_LOG_FILE == "")
        return
    try {
        clean := StrReplace(StrReplace(message, "`r", ""), "`n", " ")
        line  := FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ") " " clean "`n"
        FileAppend(line, RESCUE_LOG_FILE, "UTF-8")
    }
}

JsonEscapeString(s) {
    ; Escape the named JSON control characters (\\, \", \r, \n, \t, \b, \f).
    ; Raw codepoints 0x00-0x08 / 0x0B / 0x0E-0x1F are passed through unchanged.
    ; This is acceptable because our schema is internal (only this app writes
    ; and reads these files) and window titles / paths effectively never
    ; contain those raw codepoints. The file remains valid UTF-8 throughout.
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    s := StrReplace(s, Chr(8),  "\b")
    s := StrReplace(s, Chr(12), "\f")
    return s
}

JsonEncodeHiddenState(windows) {
    ; Minified output. windows is an Array of objects with hwnd/pid/procName/procPath/title/hiddenAt.
    parts := []
    for entry in windows {
        obj :=  '{"hwnd":'        entry.hwnd
            .   ',"pid":'         entry.pid
            .   ',"procName":"'   JsonEscapeString(entry.procName) '"'
            .   ',"procPath":"'   JsonEscapeString(entry.procPath) '"'
            .   ',"title":"'      JsonEscapeString(entry.title)    '"'
            .   ',"hiddenAt":"'   JsonEscapeString(entry.hiddenAt) '"}'
        parts.Push(obj)
    }
    body := ""
    for i, p in parts {
        body .= (i > 1 ? "," : "") p
    }
    return '{"version":1,"windows":[' body "]}"
}

JsonUnescapeString(s) {
    s := StrReplace(s, "\\", Chr(1))         ; placeholder so we don't double-decode
    s := StrReplace(s, '\"', '"')
    s := StrReplace(s, "\r", "`r")
    s := StrReplace(s, "\n", "`n")
    s := StrReplace(s, "\t", "`t")
    s := StrReplace(s, "\b", Chr(8))
    s := StrReplace(s, "\f", Chr(12))
    s := StrReplace(s, "\/", "/")
    s := StrReplace(s, Chr(1), "\")           ; restore literal backslash
    return s
}

FindJsonBalanced(text, startPos, openChar, closeChar) {
    ; Walk `text` starting at the openChar at `startPos`, respecting string
    ; literals ("..." with backslash escapes), until the matching closeChar.
    ; Used to locate array / object boundaries without being fooled by
    ; literal `]` or `}` inside string fields (e.g., window titles like
    ; "[3] Notifications - Chrome" or "[Working] file.ts").
    ; Returns the 1-based position of the matching closeChar, or 0 if not found.
    if (SubStr(text, startPos, 1) != openChar)
        return 0
    depth     := 1
    inString  := false
    escape    := false
    i         := startPos + 1
    len       := StrLen(text)
    while (i <= len) {
        ch := SubStr(text, i, 1)
        if (escape) {
            escape := false
        } else if (ch == "\") {
            escape := true
        } else if (ch == '"') {
            inString := !inString
        } else if (!inString) {
            if (ch == openChar) {
                depth++
            } else if (ch == closeChar) {
                depth--
                if (depth == 0)
                    return i
            }
        }
        i++
    }
    return 0
}

JsonDecodeHiddenState(text) {
    ; Returns Array of entries with .hwnd/.pid (Integer) and .procName/.procPath/.title/.hiddenAt (String).
    ; Returns [] on any parse failure - we re-write fresh on next operation.
    out := []
    if (text == "")
        return out
    ; Find the "windows" array
    pos := InStr(text, '"windows"')
    if (!pos)
        return out
    pos := InStr(text, "[", , pos)
    if (!pos)
        return out
    end := FindJsonBalanced(text, pos, "[", "]")
    if (!end)
        return out
    body := SubStr(text, pos + 1, end - pos - 1)

    ; Iterate object literals { ... }
    p := 1
    while (p <= StrLen(body)) {
        objStart := InStr(body, "{", , p)
        if (!objStart)
            break
        objEnd := FindJsonBalanced(body, objStart, "{", "}")
        if (!objEnd)
            break
        obj := SubStr(body, objStart, objEnd - objStart + 1)
        entry := ParseHiddenEntry(obj)
        if (IsObject(entry))
            out.Push(entry)
        p := objEnd + 1
    }
    return out
}

ParseHiddenEntry(obj) {
    ; obj is the text of a single { ... } literal. Extract known fields.
    entry := { hwnd: 0, pid: 0, procName: "", procPath: "", title: "", hiddenAt: "" }
    ; Integer fields
    if RegExMatch(obj, '"hwnd"\s*:\s*(\d+)', &m)
        entry.hwnd := Integer(m[1])
    if RegExMatch(obj, '"pid"\s*:\s*(\d+)', &m)
        entry.pid := Integer(m[1])
    ; String fields (greedy match up to closing quote, respecting backslash escapes)
    if RegExMatch(obj, '"procName"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        entry.procName := JsonUnescapeString(m[1])
    if RegExMatch(obj, '"procPath"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        entry.procPath := JsonUnescapeString(m[1])
    if RegExMatch(obj, '"title"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        entry.title := JsonUnescapeString(m[1])
    if RegExMatch(obj, '"hiddenAt"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        entry.hiddenAt := JsonUnescapeString(m[1])
    if (entry.hwnd == 0)
        return ""    ; required field missing - drop entry
    return entry
}

HiddenState_AtomicWrite(jsonText) {
    ; Write to .tmp then MoveFileExW(MOVEFILE_REPLACE_EXISTING=1). Crash mid-write
    ; leaves either the old or new file intact, never a partial.
    global HIDDEN_STATE_FILE, HIDDEN_STATE_TMP
    if (HIDDEN_STATE_FILE == "")
        return
    try {
        ; Truncate-overwrite the tmp file
        if FileExist(HIDDEN_STATE_TMP)
            FileDelete(HIDDEN_STATE_TMP)
        FileAppend(jsonText, HIDDEN_STATE_TMP, "UTF-8")
        ok := DllCall("MoveFileExW"
            , "WStr", HIDDEN_STATE_TMP
            , "WStr", HIDDEN_STATE_FILE
            , "UInt", 1                  ; MOVEFILE_REPLACE_EXISTING
            , "Int")
        if (!ok)
            LogRescue("MoveFileExW failed: " A_LastError " (tmp=" HIDDEN_STATE_TMP ", dst=" HIDDEN_STATE_FILE ")")
    } catch as e {
        LogRescue("AtomicWrite threw: " e.Message)
    }
}

HiddenState_Read() {
    global HIDDEN_STATE_FILE
    if (HIDDEN_STATE_FILE == "" || !FileExist(HIDDEN_STATE_FILE))
        return []
    try {
        text := FileRead(HIDDEN_STATE_FILE, "UTF-8")
        return JsonDecodeHiddenState(text)
    } catch as e {
        LogRescue("HiddenState_Read failed: " e.Message)
        return []
    }
}

HiddenState_Clear() {
    HiddenState_AtomicWrite('{"version":1,"windows":[]}')
}

HiddenState_Append(hwnd, pid, procName, procPath, title) {
    entries := HiddenState_Read()
    ; Defensive: drop any existing entry for this hwnd (shouldn't happen, but cheap to enforce).
    survivors := []
    for entry in entries {
        if (entry.hwnd != hwnd)
            survivors.Push(entry)
    }
    survivors.Push({
        hwnd: hwnd,
        pid: pid,
        procName: procName,
        procPath: procPath,
        title: title,
        hiddenAt: FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ")
    })
    HiddenState_AtomicWrite(JsonEncodeHiddenState(survivors))
}

HiddenState_Remove(hwnd) {
    entries := HiddenState_Read()
    survivors := []
    for entry in entries {
        if (entry.hwnd != hwnd)
            survivors.Push(entry)
    }
    HiddenState_AtomicWrite(JsonEncodeHiddenState(survivors))
}

RescueOrphanedWindows() {
    ; Read tracked entries, validate each against current Windows state, prune stale.
    ; If any survivors remain, present the modal rescue dialog. Called once during
    ; Initialize() before tray-icon registration.
    entries := HiddenState_Read()
    if (entries.Length == 0)
        return

    survivors := []
    for entry in entries {
        ; Window still exists?
        if (!DllCall("IsWindow", "Ptr", entry.hwnd, "Int"))
            continue
        ; Same process?
        try {
            currentPid := WinGetPID("ahk_id " entry.hwnd)
        } catch {
            continue
        }
        if (currentPid != entry.pid)
            continue
        try {
            currentPath := ProcessGetPath(currentPid)
        } catch {
            continue
        }
        if (currentPath != entry.procPath)
            continue
        ; Still hidden? (User may have restored it externally.)
        if (DllCall("IsWindowVisible", "Ptr", entry.hwnd, "Int"))
            continue
        survivors.Push(entry)
    }

    ; Always rewrite the file so stale entries are pruned even if we show no dialog.
    HiddenState_AtomicWrite(JsonEncodeHiddenState(survivors))

    if (survivors.Length == 0)
        return

    ; Show modal (Task 10 wires this).
    ShowRescueDialog(survivors)
}

ShowRescueDialog(survivors) {
    ; Build a theme-aware modal listing each orphaned window. User picks via
    ; checkboxes; buttons commit or cancel. Survivors array is the validated
    ; output of RescueOrphanedWindows.
    global rescueGui, themeState

    rescueGui := Gui("+Resize +MinSize640x280", "Restore hidden windows")
    rescueGui.OnEvent("Close", OnRescueCancel)
    rescueGui.OnEvent("Escape", OnRescueCancel)
    rescueGui.MarginX := 14
    rescueGui.MarginY := 14
    rescueGui.SetFont("s10", "Segoe UI")

    intro := "Found " survivors.Length " window"
           . (survivors.Length == 1 ? "" : "s")
           . " hidden by a previous session of minimize-to-tray.`n"
           . "Restore the checked rows to view; unchecked rows return to the tray."
    rescueGui.AddText("xm w612", intro)

    LV := rescueGui.AddListView("xm w612 r10 +Checked +Grid",
        ["Process", "Window title", "Hidden at"])
    LV.ModifyCol(1, 130)
    LV.ModifyCol(2, 380)
    LV.ModifyCol(3, 80)

    ; Stash survivor entries on the LV via a parallel array (LV row index -> entry).
    rescueGui.entries := survivors
    for entry in survivors {
        timeShort := SubStr(entry.hiddenAt, 12, 5)   ; "HH:mm" from "YYYY-MM-DDTHH:mm:ssZ"
        LV.Add("Check", entry.procName, entry.title, timeShort)
    }
    rescueGui.lv := LV

    btnRestoreSelected := rescueGui.AddButton("xm w180 h32", "&Restore Selected")
    btnRestoreSelected.OnEvent("Click", OnRescueRestoreSelected)
    btnRestoreAll := rescueGui.AddButton("x+10 yp w160 h32 Default", "Restore &All")
    btnRestoreAll.OnEvent("Click", OnRescueRestoreAll)
    btnCancel := rescueGui.AddButton("x+10 yp w160 h32", "Send All to &Tray")
    btnCancel.OnEvent("Click", OnRescueCancel)

    rescueGui.btnRestoreSelected := btnRestoreSelected
    rescueGui.btnRestoreAll      := btnRestoreAll
    rescueGui.btnCancel          := btnCancel

    ApplyThemeToRescue()

    rescueGui.Show("AutoSize Center")
}

ApplyThemeToRescue() {
    global rescueGui, themeState
    if (!IsObject(rescueGui))
        return
    pal := GetThemePalette(themeState)
    try rescueGui.BackColor := pal.bg

    ; ListView header + body coloring is limited in AHK Gui - we apply the body
    ; color (close enough for both themes) and leave the header as system-default.
    if (IsObject(rescueGui.lv)) {
        try rescueGui.lv.Opt("Background" pal.bg " c" pal.title)
        try rescueGui.lv.Redraw()
    }

    ; DWM dark title bar (Win10 19041+ / all Win11)
    val := (themeState = "dark") ? 1 : 0
    try DllCall("dwmapi\DwmSetWindowAttribute"
        , "Ptr",  rescueGui.Hwnd
        , "UInt", 20             ; DWMWA_USE_IMMERSIVE_DARK_MODE
        , "Int*", val
        , "UInt", 4)
}

OnRescueRestoreSelected(*) {
    global rescueGui
    if (!IsObject(rescueGui))
        return
    LV := rescueGui.lv
    entries := rescueGui.entries

    ; Build a set of checked row indices for fast lookup
    checkedRows := Map()
    rowIdx := 0
    while (rowIdx := LV.GetNext(rowIdx, "C"))
        checkedRows[rowIdx] := true

    ; Iterate every row; checked => WinShow + Remove from file, unchecked => StashAlreadyHidden
    Loop entries.Length {
        idx := A_Index
        entry := entries[idx]
        if (checkedRows.Has(idx)) {
            ; Checked: restore to view
            try WinShow("ahk_id " entry.hwnd)
            catch as e
                LogRescue("Rescue restore-selected WinShow failed for hwnd=" entry.hwnd ": " e.Message)
            try HiddenState_Remove(entry.hwnd)
            catch as e
                LogRescue("Rescue restore-selected HiddenState_Remove failed for hwnd=" entry.hwnd ": " e.Message)
        } else {
            ; Unchecked: return to the tray. Entry stays in hidden.json (mirrors in-memory Groups).
            StashAlreadyHidden(entry.hwnd, entry.pid, entry.procName, entry.procPath)
        }
    }

    CloseRescue()
}

OnRescueRestoreAll(*) {
    global rescueGui
    if (!IsObject(rescueGui))
        return
    entries := rescueGui.entries
    for entry in entries {
        try WinShow("ahk_id " entry.hwnd)
        catch as e
            LogRescue("Rescue restore-all failed for hwnd=" entry.hwnd ": " e.Message)
    }
    HiddenState_Clear()
    CloseRescue()
}

OnRescueCancel(*) {
    ; "Send All to Tray" semantics: every entry re-registers into the running tray.
    ; hidden.json is left alone - the entries already represent in-memory Groups state
    ; after this call. Also called for Esc / Close X.
    global rescueGui
    if (IsObject(rescueGui)) {
        for entry in rescueGui.entries {
            StashAlreadyHidden(entry.hwnd, entry.pid, entry.procName, entry.procPath)
        }
    }
    CloseRescue()
}

CloseRescue() {
    global rescueGui
    if (IsObject(rescueGui)) {
        try rescueGui.Destroy()
    }
    rescueGui := 0
}

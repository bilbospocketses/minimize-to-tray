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

; Registered at runtime via RegisterWindowMessage("TaskbarCreated"). Explorer
; broadcasts this when the notification area is (re)created — logon race and
; explorer.exe crash/restart both surface here.
global WM_TASKBARCREATED   := 0

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
global APP_VERSION      := "1.0.27"       ; embedded version, kept in sync with vpk pack --packVersion
; Base tray tooltip; SetTrayIconForUpdateState swaps in an "update available" variant.
global BASE_ICON_TIP := "minimize-to-tray`nWin+Shift+Z or`nMiddle-click title bar`nminimizes focused window to tray"
global UpdateAvailable  := false         ; true if updater-helper.exe reports a newer release
global UpdateVersion    := ""            ; the new version string from the helper
global UpdateNotes      := ""            ; release notes for UpdateVersion, from updater-helper check
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

; Run-as-Administrator state. Independent of Run-on-login; persisted in the app
; registry key so the elevation preference survives across sessions even when the
; scheduled task doesn't exist (Run on login unchecked).
global APP_RUNAS_REG_VALUE := "RunAsAdmin"
global ADMIN_MENU_LABEL    := "Run as &Administrator"
global runAsAdminState     := 0           ; in-process truth; seeded from registry at init
global aboutRunAsAdminCb   := 0           ; About-dialog checkbox handle (or 0 when dialog closed)

; Scheduled task name used for Run-on-login (replaces the HKCU\...\Run registry
; key as of v1.0.8). The task is created/updated/deleted via the COM Task Scheduler
; 2.0 API — no external binary.
global SCHED_TASK_NAME := "minimize-to-tray"

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

; v1.0.7 exit flow: default-true so any non-user-initiated exit (logoff, shutdown,
; Velopack update, crash) restores hidden windows for safety. User-initiated Exit
; via the tray menu opens a confirmation dialog that may flip this to false.
global cleanupRestoreOnExit := true
global exitGui              := 0   ; modal Gui handle for the exit confirmation

;==============================================================================
; Triggers
;==============================================================================
#+z::MinimizeFocused()

; v1.0.7 diagnostic hotkey. Dumps the active window's Win32 + DWM state to the
; clipboard so we can characterize windows where WinHide is silently ignored
; (Electron / Chromium with Win11 system backdrops). User runs against the target
; app, then pastes the clipboard contents. No UI feedback - the paste itself is
; the verification. Feeds v1.0.8's Electron-minimize fix design.
+Esc::DumpActiveWindow()

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
; timeout. On uninstall, remove the scheduled task and wipe app-scoped registry.
for arg in A_Args {
    if (arg = "--veloapp-install") {
        ; Fresh install: default Run-on-login ON via scheduled task, seed Theme
        ; from the Windows Apps theme, and set a first-run marker so the normal-
        ; launch path that follows will surface the About dialog once (giving the
        ; user a chance to opt out of Run-on-login immediately).
        CreateOrUpdateScheduledTask(0)
        try RegWrite(ReadWindowsAppsTheme(), "REG_SZ", APP_REG_KEY, APP_THEME_REG_VALUE)
        try RegWrite(1, "REG_DWORD", APP_REG_KEY, FIRST_RUN_PENDING_REG_VALUE)
        ExitApp 0
    }
    if (arg = "--veloapp-uninstall") {
        DeleteScheduledTask()
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
        UpdateNotes := DevSampleNotes()
    }
    if (arg = "/devsimulateupdate") {
        DevSimulateUpdate := true
    }
}

; --- Tray-icon-loss telemetry + self-heal globals ---
DIAG_LOG_FILE := ""
DiagAhkUid := 0
DiagLastAhkPresent := -1

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

    ; Register TaskbarCreated so we re-add tray icons when explorer (re)creates
    ; the notification area — covers the logon race (task fires before explorer
    ; is ready) and explorer.exe crash/restart during a session.
    global WM_TASKBARCREATED
    WM_TASKBARCREATED := DllCall("RegisterWindowMessageW", "Str", "TaskbarCreated", "UInt")
    if (WM_TASKBARCREATED)
        OnMessage(WM_TASKBARCREATED, OnTaskbarCreated)

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

    ; Badged tray icon (app icon + blue update dot), shown when an update is available.
    global appUpdateIconPath
    if (A_IsCompiled) {
        appUpdateIconPath := A_Temp "\minimize-to-tray-app-update.ico"
        if (!FileExist(appUpdateIconPath))
            FileInstall("assets\app-update.ico", appUpdateIconPath, true)
    } else {
        appUpdateIconPath := A_ScriptDir "\assets\app-update.ico"
    }
    ; Apply the right tray icon now (covers /devshowdot forcing UpdateAvailable at startup).
    SetTrayIconForUpdateState()

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

    ; Always-visible app tray icon tooltip (SetTrayIconForUpdateState swaps in an
    ; "update available" variant once an update is found).
    A_IconTip := BASE_ICON_TIP

    A_TrayMenu.Delete()
    A_TrayMenu.Add("&About", ShowAbout)
    A_TrayMenu.Add()
    A_TrayMenu.Add(RUN_MENU_LABEL, ToggleRunOnLoginFromMenu)
    A_TrayMenu.Add(ADMIN_MENU_LABEL, ToggleRunAsAdminFromMenu)
    A_TrayMenu.Add()
    A_TrayMenu.Add("E&xit", ConfirmExitFromMenu)
    A_TrayMenu.Default := "&About"
    A_TrayMenu.ClickCount := 1   ; single left-click on the app tray icon opens About (default item)

    ; Clean up one-shot relaunch task left by a prior de-elevation restart.
    try {
        svc := ComObject("Schedule.Service")
        svc.Connect()
        svc.GetFolder("\").DeleteTask("minimize-to-tray-relaunch", 0)
    }

    ; v1.0.8: migrate Run-on-login from HKCU\...\Run registry key to scheduled task.
    ; If the old registry value exists, create an equivalent task and delete the key.
    global runOnLoginState, RUN_REG_KEY, RUN_REG_VALUE
    if (A_IsCompiled) {
        try {
            val := RegRead(RUN_REG_KEY, RUN_REG_VALUE)
            if (val != "") {
                CreateOrUpdateScheduledTask(0)
                try RegDelete(RUN_REG_KEY, RUN_REG_VALUE)
            }
        }
    }

    ; Seed Run-on-login state from the scheduled task and sync UI
    runOnLoginState := ReadRunOnLoginState()
    UpdateRunOnLoginUI()

    ; Seed Run-as-Administrator state from the registry and sync UI.
    ; If the preference is set but we're not elevated, relaunch with UAC.
    global runAsAdminState
    runAsAdminState := ReadRegistryRunAsAdmin()
    UpdateRunAsAdminUI()
    if (runAsAdminState && !A_IsAdmin && A_IsCompiled) {
        try {
            Run('*RunAs "' A_ScriptFullPath '"')
            ExitApp
        }
    }
    if (runAsAdminState && A_IsAdmin && A_IsCompiled && IsRunOnLoginEnabled())
        CreateOrUpdateScheduledTask(1)

    ; Seed theme state. Compiled installs are seeded by --veloapp-install; existing
    ; pre-v1.0.3 users get a one-time seed from the Windows Apps theme on first run.
    global themeState
    themeState := ReadRegistryTheme()
    if (themeState = "") {
        themeState := ReadWindowsAppsTheme()
        if (A_IsCompiled)
            try RegWrite(themeState, "REG_SZ", APP_REG_KEY, APP_THEME_REG_VALUE)
    }

    ; v1.0.7: set process-level dark/light mode preference BEFORE any Gui is created
    ; (RescueOrphanedWindows below may create the rescue dialog). SetPreferredAppMode
    ; affects which theme class new controls receive by default.
    ApplyAppDarkMode(themeState)

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
    ; Background update watcher: re-check every 5 min so the tray update dot + tooltip
    ; appear on their own, without an app restart or opening the About dialog.
    SetTimer(CheckUpdatesPeriodically, 300000)

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

    ; --- Tray-icon-loss telemetry + self-heal (see TRAY-ICON-LOSS section) ---
    DiagInit()
}

;==============================================================================
; Run-on-login (scheduled task via COM Task Scheduler 2.0 API)
;==============================================================================
; v1.0.8: Run-on-login is managed via a scheduled task instead of the
; HKCU\...\Run registry key. Both the tray right-click menu item and the
; About-dialog checkbox sync through UpdateRunOnLoginUI() after any toggle.

IsRunOnLoginEnabled() {
    global runOnLoginState
    return runOnLoginState
}

ReadRunOnLoginState() {
    if (!A_IsCompiled)
        return 0
    return IsScheduledTaskPresent() ? 1 : 0
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
    global runOnLoginState
    runOnLoginState := enabled ? 1 : 0
    if (A_IsCompiled) {
        if (enabled)
            CreateOrUpdateScheduledTask(IsRunAsAdminEnabled())
        else
            DeleteScheduledTask()
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


;==============================================================================
; Run as Administrator (registry preference + scheduled task RunLevel)
;==============================================================================
; The elevation preference is stored independently in the app registry key.
; When Run-on-login is also enabled, the scheduled task's RunLevel reflects
; this preference. Toggling elevation ON while non-elevated relaunches the app
; via *RunAs (UAC prompt). Toggling OFF while elevated shows an info dialog.

IsRunAsAdminEnabled() {
    global runAsAdminState
    return runAsAdminState
}

ReadRegistryRunAsAdmin() {
    global APP_REG_KEY, APP_RUNAS_REG_VALUE
    try {
        val := RegRead(APP_REG_KEY, APP_RUNAS_REG_VALUE)
        return (val = 1) ? 1 : 0
    } catch {
        return 0
    }
}

SetRunAsAdmin(enabled) {
    global runAsAdminState, APP_REG_KEY, APP_RUNAS_REG_VALUE
    runAsAdminState := enabled ? 1 : 0
    if (A_IsCompiled) {
        try RegWrite(runAsAdminState, "REG_DWORD", APP_REG_KEY, APP_RUNAS_REG_VALUE)
        if (IsRunOnLoginEnabled())
            CreateOrUpdateScheduledTask(runAsAdminState)
    }
    UpdateRunAsAdminUI()
}

UpdateRunAsAdminUI() {
    global ADMIN_MENU_LABEL, aboutRunAsAdminCb, runAsAdminState
    enabled := runAsAdminState
    try {
        if (enabled)
            A_TrayMenu.Check(ADMIN_MENU_LABEL)
        else
            A_TrayMenu.Uncheck(ADMIN_MENU_LABEL)
    }
    if (aboutRunAsAdminCb && IsObject(aboutRunAsAdminCb)) {
        try aboutRunAsAdminCb.Value := enabled
    }
}

ToggleRunAsAdminFromMenu(*) {
    HandleRunAsAdminToggle(!IsRunAsAdminEnabled())
}

HandleRunAsAdminToggle(newValue) {
    SetRunAsAdmin(newValue)
    if (newValue && !A_IsAdmin)
        RelaunchElevated()
    else if (!newValue && A_IsAdmin)
        RelaunchNonElevated()
}

RelaunchElevated() {
    global cleanupRestoreOnExit
    cleanupRestoreOnExit := false
    try {
        Run('*RunAs "' A_ScriptFullPath '"')
        ExitApp
    } catch {
        cleanupRestoreOnExit := true
        SetRunAsAdmin(0)
    }
}

RelaunchNonElevated() {
    global cleanupRestoreOnExit
    cleanupRestoreOnExit := false
    try {
        Run('explorer.exe "' A_ScriptFullPath '"')
        ExitApp
    } catch {
        cleanupRestoreOnExit := true
        SetRunAsAdmin(1)
    }
}

;==============================================================================
; Scheduled Task (COM Task Scheduler 2.0 API)
;==============================================================================
; Replaces the HKCU\...\Run registry key for Run-on-login as of v1.0.8.
; The task is a per-user logon trigger pointing at A_ScriptFullPath. RunLevel
; is TASK_RUNLEVEL_HIGHEST when Run as Administrator is enabled, otherwise
; TASK_RUNLEVEL_LUA (standard user).

CreateOrUpdateScheduledTask(elevated := 0) {
    global SCHED_TASK_NAME
    if (!A_IsCompiled)
        return
    try {
        svc := ComObject("Schedule.Service")
        svc.Connect()
        root := svc.GetFolder("\")
        td := svc.NewTask(0)
        td.RegistrationInfo.Description := "Start minimize-to-tray at user logon"
        td.RegistrationInfo.Author := "bilbospocketses"
        td.Principal.LogonType := 3       ; TASK_LOGON_INTERACTIVE_TOKEN
        td.Principal.RunLevel := elevated ? 1 : 0  ; HIGHEST or LUA
        trigger := td.Triggers.Create(9)  ; TASK_TRIGGER_LOGON
        trigger.UserId := A_UserName
        trigger.Enabled := true
        action := td.Actions.Create(0)    ; TASK_ACTION_EXEC
        ; Fire-and-forget: cmd starts the app detached and exits immediately
        ; so the task transitions to Ready instead of staying Running for the
        ; lifetime of the persistent AHK process.
        action.Path := A_WinDir "\System32\cmd.exe"
        action.Arguments := '/c start "" "' . A_ScriptFullPath . '"'
        s := td.Settings
        s.Enabled := true
        s.StartWhenAvailable := true
        s.DisallowStartIfOnBatteries := false
        s.StopIfGoingOnBatteries := false
        s.ExecutionTimeLimit := "PT30S"
        root.RegisterTaskDefinition(SCHED_TASK_NAME, td, 6, "", "", 3)
    }
}

DeleteScheduledTask() {
    global SCHED_TASK_NAME
    if (!A_IsCompiled)
        return
    try {
        svc := ComObject("Schedule.Service")
        svc.Connect()
        root := svc.GetFolder("\")
        root.DeleteTask(SCHED_TASK_NAME, 0)
    }
}

IsScheduledTaskPresent() {
    global SCHED_TASK_NAME
    try {
        svc := ComObject("Schedule.Service")
        svc.Connect()
        root := svc.GetFolder("\")
        root.GetTask(SCHED_TASK_NAME)
        return true
    } catch {
        return false
    }
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
            checkbox2:    "F2F2F2",
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
            focusRing:    "4DA3FF",    ; v1.0.7: focus-ring inside owner-drawn controls
            gridLine:     "5A5A5A"     ; v1.0.7: rescue header grid separators (tuned to match LV body grid in dark mode)
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
        checkbox2:    "000000",
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
        focusRing:    "0078D4",
        gridLine:     "BFBFBF"        ; matches LV body grid in light mode
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
        ; Icon shows the TARGET action (what a click switches TO), matching the
        ; "Switch to <other> theme" tooltip. The sun keeps the control's gold base
        ; color (dark's pal.themeGlyph is "" so it is not re-tinted); moon is color-locked.
        if (themeState = "dark") {
            try aboutThemeIcon.Text := Chr(0x2600)    ; sun = switch to light
        } else {
            try aboutThemeIcon.Text := Chr(0x1F319)   ; moon = switch to dark
        }
        if (pal.themeGlyph != "")
            try aboutThemeIcon.Opt("c" pal.themeGlyph)
        try aboutThemeIcon.Redraw()
    }

    ; Tell DWM to draw the OS title bar in the matching theme. Without this the
    ; title bar stays Light even when the app body goes Dark. Attribute 20 =
    ; DWMWA_USE_IMMERSIVE_DARK_MODE, supported on Win10 19041+ and all Win11.
    SetAboutTitleBarDark(themeState = "dark")

    ; v1.0.7: uxtheme dark-mode private API - theme native controls (OK button,
    ; Run-on-login checkbox, ListView if any) via SetWindowTheme("DarkMode_Explorer").
    ApplyDarkModeToGui(aboutGui, themeState)

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
    ; Update process-level preferred app mode for any new windows / controls.
    ApplyAppDarkMode(themeState)
    ApplyThemeToAbout()
}

;==============================================================================
; About menu - custom Gui with pulsing blue update-available dot
;==============================================================================
; A global handle so the pulse timer can reach the live Gui control.
global aboutGui    := 0
global aboutDot    := 0
global pulseTimer  := 0
global updateGui   := 0   ; the update-notification modal Gui (or 0 when closed)

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
    initialGlyph := (themeState = "dark") ? Chr(0x2600) : Chr(0x1F319)   ; sun in dark / moon in light = target action
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

    ; ---- Settings checkboxes (centered pair above the URL) ----
    ; AHK Checkbox with `w 440 Center` pins the box to the LEFT of a 440px-wide
    ; control and only centers the label - the box+label combo looks split.
    ; Instead: add at a placeholder x with no explicit width (auto-sizes to label),
    ; measure the actual width, then Move to a calculated centered x. This puts
    ; the box directly to the left of its label as a tight unit.
    global aboutRunOnLoginCb, aboutRunAsAdminCb
    aboutGui.SetFont("s10 Norm c000000", "Segoe UI")

    aboutRunOnLoginCb := aboutGui.Add("Checkbox", "x28 y+20", "Run on login")
    aboutRunOnLoginCb.Value := IsRunOnLoginEnabled()
    aboutRunOnLoginCb.GetPos(, &cbY, &cbW, )
    aboutRunOnLoginCb.Move(28 + (contentW - cbW) // 2, cbY)
    aboutControlRefs["checkbox"] := aboutRunOnLoginCb

    aboutRunAsAdminCb := aboutGui.Add("Checkbox", "x28 y+8", "Run as Administrator")
    aboutRunAsAdminCb.Value := IsRunAsAdminEnabled()
    aboutRunAsAdminCb.GetPos(, &cbY2, &cbW2, )
    aboutRunAsAdminCb.Move(28 + (contentW - cbW2) // 2, cbY2)
    aboutControlRefs["checkbox2"] := aboutRunAsAdminCb

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
    okBtn.OnEvent("Click", (*) => ApplyAboutAndClose())
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

ApplyAboutAndClose() {
    global aboutRunOnLoginCb, aboutRunAsAdminCb
    pendingLogin := (aboutRunOnLoginCb && IsObject(aboutRunOnLoginCb)) ? aboutRunOnLoginCb.Value : IsRunOnLoginEnabled()
    pendingAdmin := (aboutRunAsAdminCb && IsObject(aboutRunAsAdminCb)) ? aboutRunAsAdminCb.Value : IsRunAsAdminEnabled()
    CloseAbout()
    loginChanged := (pendingLogin != IsRunOnLoginEnabled())
    adminChanged := (pendingAdmin != IsRunAsAdminEnabled())
    if (loginChanged)
        SetRunOnLogin(pendingLogin)
    if (adminChanged)
        SetRunAsAdmin(pendingAdmin)
    if (adminChanged) {
        if (pendingAdmin && !A_IsAdmin)
            RelaunchElevated()
        else if (!pendingAdmin && A_IsAdmin)
            RelaunchNonElevated()
    }
}

CloseAbout() {
    global aboutGui, aboutDot, pulseTimer, aboutRunOnLoginCb, aboutRunAsAdminCb
    global aboutThemeIcon, aboutControlRefs
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
    aboutRunAsAdminCb := 0
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

    ctrlHwnd := 0
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
    ; v1.0.21: open the notes dialog instead of updating silently. The actual
    ; Velopack apply now runs from the dialog's "Update now" (UpdateNowFromDialog).
    ShowUpdateDialog()
}

;------------------------------------------------------------------------------
; Velopack update check (async, fire-and-forget)
;------------------------------------------------------------------------------
; 5-min background watcher -> CheckForUpdateAsync. A thin wrapper so it gets its own
; timer identity, separate from the one-shot startup check on CheckForUpdateAsync.
CheckUpdatesPeriodically() {
    CheckForUpdateAsync()
}

CheckForUpdateAsync() {
    global UpdateAvailable, UpdateVersion, UpdateNotes, A_IsCompiled, DevSimulateUpdate

    ; Once an update is already known, skip re-checking: opening About no longer
    ; re-runs a check, and the 5-min watcher stops making redundant network calls
    ; (the tray dot + tooltip are already showing).
    if (UpdateAvailable)
        return

    ; Dev short-circuit: /devsimulateupdate flag bypasses the helper entirely and
    ; flips UpdateAvailable + seeds sample notes + AddUpdateDotToAbout. Smoke test
    ; for the live-inject path AND the update dialog. The "!UpdateAvailable" guard
    ; prevents repeated triggers once flipped (this fires from multiple call sites).
    if (DevSimulateUpdate && !UpdateAvailable) {
        UpdateAvailable := true
        UpdateVersion := "1.0.99-dev"
        UpdateNotes := DevSampleNotes()
        AddUpdateDotToAbout()
        SetTrayIconForUpdateState()
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
        raw := exec.StdOut.ReadAll()
        exitCode := exec.ExitCode
    } catch as err {
        return  ; helper failed; silently swallow
    }

    ; Contract with updater-helper check: line 1 = version, everything after the
    ; first newline = the notes blob. Normalize CRLF->LF first so the split is
    ; line-ending agnostic.
    raw := StrReplace(raw, "`r`n", "`n")
    nlPos := InStr(raw, "`n")
    if (nlPos) {
        verLine := Trim(SubStr(raw, 1, nlPos - 1), " `t`n")
        notesBlob := Trim(SubStr(raw, nlPos + 1), " `t`n")
    } else {
        verLine := Trim(raw, " `t`n")
        notesBlob := ""
    }

    if (exitCode == 0 && verLine != "" && verLine != APP_VERSION) {
        UpdateAvailable := true
        UpdateVersion := verLine
        UpdateNotes := notesBlob
        ; v1.0.5: if About is currently open, inject the dot live so the user
        ; sees it without having to close + reopen the dialog.
        AddUpdateDotToAbout()
        SetTrayIconForUpdateState()
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
; Update-available notes dialog
;==============================================================================
; Clicking the pulsing dot opens this themed modal instead of updating silently.
; It shows the new version + its release notes (raw text, scrollable) and only
; runs the Velopack update when the user clicks "Update now". Structure + theming
; mirror the exit-confirmation dialog (ApplyThemeToExitDialog): BackColor + text
; colors + inline DWM dark title bar + ApplyDarkModeToGui for native controls.

NormalizeToCRLF(s) {
    ; Win32 Edit controls render line breaks only on CRLF. NotesMarkdown may arrive
    ; with bare LF (or already-CRLF). Collapse to LF, then expand to CRLF, so we
    ; never emit CR-CR-LF.
    return StrReplace(StrReplace(s, "`r`n", "`n"), "`n", "`r`n")
}

DevSampleNotes() {
    ; Multi-line sample so /devshowdot + /devsimulateupdate can exercise the dialog
    ; (scrolling, wrapping, theming) without a real release.
    return "### Added`n"
         . "- Update notification dialog: clicking the blue dot now shows what an update contains before installing.`n"
         . "`n"
         . "### Changed`n"
         . "- build.ps1 embeds the CHANGELOG section as Velopack release notes.`n"
         . "- updater-helper check now returns the version and its notes.`n"
         . "`n"
         . "### Notes`n"
         . "- This is sample text shown only under /devshowdot or /devsimulateupdate, long enough to demonstrate vertical scrolling and word wrapping inside the read-only notes box."
}

ShowUpdateDialog() {
    global updateGui, UpdateVersion, UpdateNotes, themeState

    ; Already open (double-click race) -> bring it forward.
    if (IsObject(updateGui)) {
        try updateGui.Show()
        return
    }

    updateGui := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "Update available")
    updateGui.OnEvent("Close",  (*) => CloseUpdateDialog())
    updateGui.OnEvent("Escape", (*) => CloseUpdateDialog())
    updateGui.MarginX := 18
    updateGui.MarginY := 16

    ; Header: app name + new version.
    updateGui.SetFont("s13 Bold", "Segoe UI")
    txtTitle := updateGui.AddText("xm w440", "minimize-to-tray  v" UpdateVersion)

    updateGui.SetFont("s10 Norm", "Segoe UI")
    txtWhat := updateGui.AddText("xm w440", "What's new:")

    ; Notes: read-only, multi-line (r14 rows), vertically scrollable. Win32 Edit
    ; needs CRLF; normalize first. Empty -> friendly fallback.
    notesText := (Trim(UpdateNotes) != "") ? NormalizeToCRLF(UpdateNotes) : "(No release notes provided.)"
    updateGui.SetFont("s9 Norm", "Consolas")
    edNotes := updateGui.Add("Edit", "xm w440 r14 ReadOnly VScroll", notesText)

    ; Buttons: Update now (default) + Later.
    updateGui.SetFont("s10 Norm", "Segoe UI")
    btnUpdate := updateGui.AddButton("xm w150 h32 Default", "&Update now")
    btnUpdate.OnEvent("Click", (*) => UpdateNowFromDialog())
    btnLater := updateGui.AddButton("x+10 yp w110 h32", "&Later")
    btnLater.OnEvent("Click", (*) => CloseUpdateDialog())

    ; Stash control refs on the Gui object (same pattern as the exit dialog).
    updateGui.txtTitle  := txtTitle
    updateGui.txtWhat   := txtWhat
    updateGui.edNotes   := edNotes
    updateGui.btnUpdate := btnUpdate
    updateGui.btnLater  := btnLater

    ApplyThemeToUpdateDialog()

    updateGui.Show("AutoSize Center")

    ; The read-only notes Edit grabs initial focus and auto-selects all its text
    ; (a full blue highlight that survives close/reopen). Clear the selection (caret
    ; to the top) and move focus to the default button, so the notes render clean
    ; and Enter maps to "Update now".
    try PostMessage(0x00B1, 0, 0, edNotes)   ; EM_SETSEL(0,0): deselect, caret to start
    try btnUpdate.Focus()
}

ApplyThemeToUpdateDialog() {
    global updateGui, themeState
    if (!IsObject(updateGui))
        return
    pal := GetThemePalette(themeState)
    try updateGui.BackColor := pal.bg
    if (IsObject(updateGui.txtTitle))
        try updateGui.txtTitle.Opt("c" pal.title)
    if (IsObject(updateGui.txtWhat))
        try updateGui.txtWhat.Opt("c" pal.text)

    ; Notes box: theme its interior to match. In dark mode use the button-fill
    ; shade for subtle contrast against the dialog background; light mode stays
    ; white-on-black. (If a read-only Edit ignores the background on some Win10
    ; builds, the text stays readable regardless -- verified in the dark smoke.)
    if (IsObject(updateGui.edNotes)) {
        editBg := (themeState = "dark") ? pal.buttonBg : "FFFFFF"
        try updateGui.edNotes.Opt("Background" editBg " c" pal.text)
    }

    ; DWM dark title bar (attribute 20 = DWMWA_USE_IMMERSIVE_DARK_MODE).
    val := (themeState = "dark") ? 1 : 0
    try DllCall("dwmapi\DwmSetWindowAttribute"
        , "Ptr",  updateGui.Hwnd
        , "UInt", 20
        , "Int*", val
        , "UInt", 4)

    ; uxtheme dark-mode private API: theme native controls (Edit border/scrollbar,
    ; buttons) with DarkMode_Explorer in dark, Explorer in light.
    ApplyDarkModeToGui(updateGui, themeState)
}

CloseUpdateDialog() {
    global updateGui
    if (IsObject(updateGui)) {
        try updateGui.Destroy()
    }
    updateGui := 0
}

UpdateNowFromDialog() {
    ; The actual Velopack apply path, unchanged from the old OnClickUpdateDot:
    ; spawn the helper to download + apply + restart, then exit so OnExit fires
    ; and Velopack swaps the install.
    helperPath := A_ScriptDir "\updater-helper.exe"
    if (!FileExist(helperPath)) {
        MsgBox("Update helper missing at: " helperPath, "minimize-to-tray", "IconX")
        return
    }
    Run(Format('"{1}" update', helperPath))
    ExitApp()
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

DumpActiveWindow() {
    ; v1.0.7 diagnostic. Snapshots the active window's Win32 + DWM state to the
    ; clipboard. Designed to characterize windows where WinHide is silently
    ; ignored (Electron / Chromium with Win11 system backdrops). User paste the
    ; clipboard contents into a chat / issue / file so we can design v1.0.8.
    hwnd := WinGetID("A")
    if (!hwnd) {
        A_Clipboard := "minimize-to-tray diagnostic: no active window"
        return
    }

    ; Basic window identity.
    cls   := ""
    title := ""
    pid   := 0
    try cls   := WinGetClass("ahk_id " hwnd)
    try title := WinGetTitle("ahk_id " hwnd)
    try pid   := WinGetPID("ahk_id " hwnd)

    procName := ""
    procPath := ""
    try procName := WinGetProcessName("ahk_id " hwnd)
    try procPath := WinGetProcessPath("ahk_id " hwnd)

    ; Win32 styles via GetWindowLongW. GWL_STYLE = -16, GWL_EXSTYLE = -20.
    style   := DllCall("GetWindowLongW", "Ptr", hwnd, "Int", -16, "UInt")
    exStyle := DllCall("GetWindowLongW", "Ptr", hwnd, "Int", -20, "UInt")

    ; Ancestor / owner chain. GA_ROOTOWNER = 3.
    rootOwner := DllCall("GetAncestor", "Ptr", hwnd, "UInt", 3, "Ptr")

    ; Window rect (screen coords).
    rect := Buffer(16, 0)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", rect)
    rectL := NumGet(rect,  0, "Int")
    rectT := NumGet(rect,  4, "Int")
    rectR := NumGet(rect,  8, "Int")
    rectB := NumGet(rect, 12, "Int")

    ; DWM cloak state. DWMWA_CLOAKED = 14. Values: 0=none, 1=DWM_CLOAKED_APP,
    ; 2=DWM_CLOAKED_SHELL, 4=DWM_CLOAKED_INHERITED.
    cloaked := 0
    cloakStr := "<query failed>"
    try {
        cloakBuf := Buffer(4, 0)
        hr := DllCall("dwmapi\DwmGetWindowAttribute"
            , "Ptr",  hwnd
            , "UInt", 14
            , "Ptr",  cloakBuf
            , "UInt", 4)
        if (hr = 0) {
            cloaked := NumGet(cloakBuf, 0, "UInt")
            cloakStr := (cloaked = 0) ? "0 (not cloaked)"
                      : (cloaked = 1) ? "1 (DWM_CLOAKED_APP)"
                      : (cloaked = 2) ? "2 (DWM_CLOAKED_SHELL)"
                      : (cloaked = 4) ? "4 (DWM_CLOAKED_INHERITED)"
                      : cloaked
        }
    }

    ; DWMWA_SYSTEMBACKDROP_TYPE = 38 (Win11 22H2+). 0=auto, 1=none, 2=mainwindow
    ; (Mica), 3=transient (acrylic), 4=tabbedwindow (Mica Alt). Fails on Win10 +
    ; pre-22H2 Win11 - reported as "<unsupported>" in that case.
    backdropStr := "<unsupported on this Windows build>"
    try {
        bdBuf := Buffer(4, 0)
        hr := DllCall("dwmapi\DwmGetWindowAttribute"
            , "Ptr",  hwnd
            , "UInt", 38
            , "Ptr",  bdBuf
            , "UInt", 4)
        if (hr = 0) {
            bd := NumGet(bdBuf, 0, "UInt")
            backdropStr := (bd = 0) ? "0 (auto)"
                         : (bd = 1) ? "1 (none)"
                         : (bd = 2) ? "2 (mainwindow / Mica)"
                         : (bd = 3) ? "3 (transient / Acrylic)"
                         : (bd = 4) ? "4 (tabbedwindow / Mica Alt)"
                         : bd
        }
    }

    ; Build the dump.
    out := "minimize-to-tray Shift+Esc diagnostic`r`n"
         . "==========================================`r`n"
         . "Captured:        " FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ") "`r`n"
         . "App version:     " APP_VERSION "`r`n"
         . "OS:              " A_OSVersion "`r`n"
         . "`r`n"
         . "HWND:            0x" Format("{:X}", hwnd) "`r`n"
         . "Class:           " cls "`r`n"
         . "Title:           " title "`r`n"
         . "Process:         " procName " (PID " pid ")`r`n"
         . "Path:            " procPath "`r`n"
         . "`r`n"
         . "Window rect:     (" rectL "," rectT ")-(" rectR "," rectB ")"
         . " [w=" (rectR - rectL) " h=" (rectB - rectT) "]`r`n"
         . "GWL_STYLE:       0x" Format("{:08X}", style) "`r`n"
         . "GWL_EXSTYLE:     0x" Format("{:08X}", exStyle) "`r`n"
         . "GA_ROOTOWNER:    0x" Format("{:X}", rootOwner)
            . ((rootOwner = hwnd) ? " (self)" : "") "`r`n"
         . "DWMWA_CLOAKED:   " cloakStr "`r`n"
         . "DWMWA_BACKDROP:  " backdropStr "`r`n"

    A_Clipboard := out
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
; TaskbarCreated - explorer (re)created the notification area
;==============================================================================
OnTaskbarCreated(wParam, lParam, msg, hwnd) {
    DiagLog("TASKBARCREATED received")
    ReassertTrayIcons("TaskbarCreated")
}

; Set the tray icon to match the current update state: the blue-dot-badged icon
; when an update is available, otherwise the normal app icon.
SetTrayIconForUpdateState() {
    global UpdateAvailable, appUpdateIconPath, BASE_ICON_TIP
    if (UpdateAvailable && appUpdateIconPath != "" && FileExist(appUpdateIconPath)) {
        try TraySetIcon(appUpdateIconPath)
        ; Tooltip explains the blue dot.
        try A_IconTip := "minimize-to-tray`n"
                       . "** Update available - click the icon for details **`n"
                       . "Win+Shift+Z or middle-click a title bar to minimize"
        return
    }
    try A_IconTip := BASE_ICON_TIP
    if (A_IsCompiled) {
        try TraySetIcon(A_ScriptFullPath)        ; embedded app icon
    } else {
        iconPath := A_ScriptDir "\assets\app.ico"
        if (FileExist(iconPath))
            try TraySetIcon(iconPath)
    }
}

; Re-register all tray icons after the shell dropped them (explorer restart, or the
; long-uptime AHK-icon loss the heartbeat self-heals). AHK still thinks its icon is
; registered, so TraySetIcon alone would NIM_MODIFY a nonexistent icon (silent fail);
; toggling A_IconHidden forces a full NIM_DELETE + NIM_ADD. SetTrayIconForUpdateState
; then re-applies the correct (badged-or-not) icon so the update dot survives recovery.
ReassertTrayIcons(reason) {
    global Groups
    A_IconHidden := true
    A_IconHidden := false
    SetTrayIconForUpdateState()
    for procName, group in Groups {
        ShellNotifyAdd(group.trayUid, group.hIcon, procName)
        UpdateGroupTooltip(procName)
    }
    DiagLog("REASSERT (" reason ")")
}

;==============================================================================
; TRAY-ICON-LOSS TELEMETRY + SELF-HEAL
;------------------------------------------------------------------------------
; The always-on AHK built-in tray icon (A_ScriptHwnd / uID ~0x404) can vanish
; after long uptime while the per-app manual icons (scriptGuiHwnd) survive, and
; only an explorer restart restored it - i.e. the shell drops the AHK icon on an
; event that does NOT raise TaskbarCreated (the process runs elevated). It can't
; be reproduced on demand, so this ships in the release: a 30 s heartbeat probes
; the icon (read-only NIM_MODIFY, no flicker) and, on a present->absent transition,
; logs the coinciding power/session/display event AND re-asserts the icon so it
; self-heals. Surface the log once it fires to confirm the trigger; a targeted
; root-cause fix can follow. Keep until the root cause is confirmed.
; Log: %LOCALAPPDATA%\bilbospocketses\minimize-to-tray\tray-diag.log
;==============================================================================
DiagInit() {
    global APP_DATA_DIR, DIAG_LOG_FILE, scriptGuiHwnd, APP_VERSION
    DIAG_LOG_FILE := APP_DATA_DIR "\tray-diag.log"

    DiagLog("==== DiagInit ==== version=" APP_VERSION
        . " compiled=" (A_IsCompiled ? 1 : 0)
        . " admin=" (A_IsAdmin ? 1 : 0)
        . " ahk=" A_AhkVersion
        . " scriptHwnd=" Format("0x{:X}", A_ScriptHwnd)
        . " stubGuiHwnd=" Format("0x{:X}", scriptGuiHwnd))

    ; Power (WM_POWERBROADCAST 0x0218) + display (WM_DISPLAYCHANGE 0x007E) are
    ; system broadcasts to top-level windows. Session (WM_WTSSESSION_CHANGE 0x02B1)
    ; needs explicit registration to deliver lock/unlock/RDP.
    OnMessage(0x0218, DiagOnPower)
    OnMessage(0x007E, DiagOnDisplay)
    OnMessage(0x02B1, DiagOnSession)
    try DllCall("Wtsapi32\WTSRegisterSessionNotification", "Ptr", A_ScriptHwnd, "UInt", 0)  ; NOTIFY_FOR_THIS_SESSION

    ; Discover the AHK icon uID while it is known-present, then start the heartbeat.
    ; The -3s delay lets the tray icon settle (mirrors the ShowAbout -800 pattern).
    SetTimer(DiagDiscoverAndStart, -3000)
}

DiagLog(msg) {
    global DIAG_LOG_FILE
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "  " msg "`n", DIAG_LOG_FILE, "UTF-8")
}

DiagProbeIconExists(hWnd, uid) {
    ; Read-only existence probe: NIM_MODIFY with uFlags=0 returns nonzero iff the
    ; (hWnd,uid) notify icon is currently registered with the shell. No visible change.
    global NID_SIZE, NIM_MODIFY
    nid := Buffer(NID_SIZE, 0)
    NumPut("UInt", NID_SIZE, nid, 0)    ; cbSize
    NumPut("Ptr",  hWnd,     nid, 8)    ; hWnd
    NumPut("UInt", uid,      nid, 16)   ; uID
    NumPut("UInt", 0,        nid, 20)   ; uFlags = 0 (probe only)
    return DllCall("shell32\Shell_NotifyIconW", "UInt", NIM_MODIFY, "Ptr", nid.Ptr, "Int")
}

DiagDiscoverAndStart() {
    global DiagAhkUid, DiagLastAhkPresent
    DiagAhkUid := 0
    for i, uid in [0x404, 0x405, 0x403, 0x406, 1] {
        if (DiagProbeIconExists(A_ScriptHwnd, uid)) {
            DiagAhkUid := uid
            break
        }
    }
    DiagLog("DISCOVER ahkUid=" (DiagAhkUid ? Format("0x{:X}", DiagAhkUid) : "NOT-FOUND"))
    DiagLastAhkPresent := (DiagAhkUid && DiagProbeIconExists(A_ScriptHwnd, DiagAhkUid)) ? 1 : 0
    DiagHeartbeat()
    SetTimer(DiagHeartbeat, 30000)   ; every 30s
}

DiagHeartbeat() {
    global Groups, scriptGuiHwnd, DiagAhkUid, DiagLastAhkPresent
    ahk := DiagAhkUid ? (DiagProbeIconExists(A_ScriptHwnd, DiagAhkUid) ? 1 : 0) : -1
    total := 0
    present := 0
    for procName, group in Groups {
        total += 1
        if (DiagProbeIconExists(scriptGuiHwnd, group.trayUid))
            present += 1
    }
    DiagLog("HB ahkIcon=" (ahk = 1 ? "present" : (ahk = 0 ? "ABSENT" : "unknown")) " perApp=" present "/" total)

    ; Self-heal: on a present->absent transition, log it (the POWER/SESSION/DISPLAY
    ; markers just above name the trigger), re-assert so the icon returns without an
    ; explorer restart, then re-probe to record whether recovery worked.
    if (DiagLastAhkPresent = 1 && ahk = 0) {
        DiagLog("*** TRANSITION: AHK built-in tray icon LOST (present -> absent) ***")
        ReassertTrayIcons("heartbeat-recover")
        ahk := DiagAhkUid ? (DiagProbeIconExists(A_ScriptHwnd, DiagAhkUid) ? 1 : 0) : -1
        DiagLog("  recover result: ahkIcon=" (ahk = 1 ? "present" : "STILL-ABSENT"))
    } else if (DiagLastAhkPresent = 0 && ahk = 1) {
        DiagLog("--- AHK built-in tray icon RECOVERED (absent -> present) ---")
    }
    if (ahk >= 0)
        DiagLastAhkPresent := ahk
}

DiagOnPower(wParam, lParam, msg, hwnd) {
    static names := Map(0x4,"APMSUSPEND", 0x7,"APMRESUMESUSPEND", 0xA,"APMRESUMECRITICAL", 0x12,"APMRESUMEAUTOMATIC", 0x9,"APMPOWERSTATUSCHANGE")
    DiagLog("POWER " (names.Has(wParam) ? names[wParam] : Format("0x{:X}", wParam)))
}

DiagOnDisplay(wParam, lParam, msg, hwnd) {
    DiagLog("DISPLAYCHANGE bpp=" wParam " " (lParam & 0xFFFF) "x" ((lParam >> 16) & 0xFFFF))
}

DiagOnSession(wParam, lParam, msg, hwnd) {
    static names := Map(0x1,"CONSOLE_CONNECT", 0x2,"CONSOLE_DISCONNECT", 0x3,"REMOTE_CONNECT", 0x4,"REMOTE_DISCONNECT", 0x5,"SESSION_LOGON", 0x6,"SESSION_LOGOFF", 0x7,"SESSION_LOCK", 0x8,"SESSION_UNLOCK", 0x9,"SESSION_REMOTE_CONTROL")
    DiagLog("SESSION " (names.Has(wParam) ? names[wParam] : Format("0x{:X}", wParam)))
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
    global Groups, hWinEventHook, cleanupRestoreOnExit

    ; Unhook the WinEvent listener first so destroy events during cleanup do not double-fire.
    if (hWinEventHook) {
        DllCall("UnhookWinEvent", "Ptr", hWinEventHook)
        hWinEventHook := 0
    }

    ; Tray icons + in-memory state are always cleaned. The only conditional bit is
    ; whether we restore the hidden windows (and clear the rescue state file) - that
    ; depends on the user's choice via ConfirmExitFromMenu (or the safe default true
    ; for non-user-initiated exits like logoff, shutdown, Velopack update).
    for procName, group in Groups {
        if (cleanupRestoreOnExit) {
            for hwnd in group.windows {
                try WinShow("ahk_id " hwnd)
            }
        }
        if (group.hIcon)
            DllCall("DestroyIcon", "Ptr", group.hIcon)
        ShellNotifyDelete(group.trayUid)
    }
    Groups.Clear()

    if (cleanupRestoreOnExit) {
        ; Every hidden window restored - rescue state should be empty.
        try HiddenState_Clear()
    }
    ; Otherwise: leave hidden.json populated so next launch surfaces them via rescue.
}

;==============================================================================
; v1.0.7 rescue mode - persistent hidden-window state + log helper
;==============================================================================

FormatHiddenAtLocalShort(isoUtcString) {
    ; Convert "YYYY-MM-DDTHH:mm:ssZ" (UTC) to local-time "HH:mm".
    ; Storage stays UTC for portability across timezones; display converts on render.
    ; UTC->local offset comes from the difference between local now and UTC now.
    if (StrLen(isoUtcString) < 19)
        return ""
    ; Strip ISO punctuation to AHK's "YYYYMMDDHH24MISS" stamp format.
    stampUtc := SubStr(isoUtcString,  1, 4)
              . SubStr(isoUtcString,  6, 2)
              . SubStr(isoUtcString,  9, 2)
              . SubStr(isoUtcString, 12, 2)
              . SubStr(isoUtcString, 15, 2)
              . SubStr(isoUtcString, 18, 2)
    offsetSeconds := DateDiff(A_Now, A_NowUTC, "Seconds")
    stampLocal := DateAdd(stampUtc, offsetSeconds, "Seconds")
    return FormatTime(stampLocal, "HH:mm")
}

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
    txtIntro := rescueGui.AddText("xm w612", intro)
    rescueGui.txtIntro := txtIntro

    ; Suppress the native LV header (-Hdr) and use 3 Text controls above the LV as
    ; column labels. This sidesteps the WM_PAINT-subclass rabbit hole entirely:
    ; native SysHeader32 doesn't dark-theme via DarkMode_Explorer, and subclassing it
    ; to override paint triggered re-entrancy bugs on column resize. Static column
    ; widths are what we use anyway (ModifyCol below).
    ; Label x-positions are offset 6px from each column's left edge to align with the
    ; LV's internal column text padding.
    sepHorizTop := rescueGui.AddText("xm y+8 w612 h1", "")

    rescueGui.SetFont("s10 Bold", "Segoe UI")
    txtColProcess := rescueGui.AddText("xm+6 y+2 w124",  "Process")
    txtColTitle   := rescueGui.AddText("x+6 yp w374",    "Window title")
    txtColTime    := rescueGui.AddText("x+6 yp w74",     "Hidden at")
    rescueGui.SetFont("s10 Norm", "Segoe UI")
    rescueGui.colHeaders := [txtColProcess, txtColTitle, txtColTime]

    sepHorizBottom := rescueGui.AddText("xm y+2 w612 h1", "")

    LV := rescueGui.AddListView("xm y+0 w612 r10 -Hdr +Checked +Grid",
        ["Process", "Window title", "Hidden at"])
    LV.ModifyCol(1, 130)
    LV.ModifyCol(2, 380)
    LV.ModifyCol(3, 80)

    ; Vertical column separators - 5 total to frame the header row + match LV grid:
    ;   * outer-left, outer-right (match LV's outer border)
    ;   * 3 column-end dividers (Process|Title, Title|Hidden, Hidden|phantom right gutter)
    ;
    ; AHK Gui DIP positioning rounds (lvX_dip + col_dip) * dpiScale to a device pixel.
    ; The LV instead computes col_end_device = lvX_device + col_device (where col_device
    ; is the raw LVM_GETCOLUMNWIDTH value). The two rounding paths can disagree by 1
    ; device pixel, putting our DIP-positioned verticals slightly off the LV grid lines.
    ;
    ; Fix: add the verticals at placeholder positions, then SetWindowPos them in raw
    ; device pixels using the same lvX_device + col_device math the LV uses internally.
    ; Pixel-perfect alignment regardless of DPI rounding direction.
    LV.GetPos(&lvX, &lvY, &lvW, &lvH)
    col1Wdev := DllCall("SendMessageW", "Ptr", LV.Hwnd, "UInt", 0x101D, "Ptr", 0, "Ptr", 0, "Int")
    col2Wdev := DllCall("SendMessageW", "Ptr", LV.Hwnd, "UInt", 0x101D, "Ptr", 1, "Ptr", 0, "Int")
    col3Wdev := DllCall("SendMessageW", "Ptr", LV.Hwnd, "UInt", 0x101D, "Ptr", 2, "Ptr", 0, "Int")
    dpiScale := A_ScreenDPI / 96

    sepHorizTop.GetPos(&topX, &topY, &topW, &topH)
    sepHorizBottom.GetPos(&botX, &botY, &botW, &botH)
    vertY := topY
    vertH := (botY + botH) - topY

    ; Placeholder positions - replaced by SetWindowPos below.
    vertOuterL := rescueGui.AddText("xm yp w1 h1", "")
    vertCol1   := rescueGui.AddText("xm yp w1 h1", "")
    vertCol2   := rescueGui.AddText("xm yp w1 h1", "")
    vertCol3   := rescueGui.AddText("xm yp w1 h1", "")
    vertOuterR := rescueGui.AddText("xm yp w1 h1", "")

    ; Device-pixel coordinates for SetWindowPos.
    lvXdev   := Round(lvX * dpiScale)
    lvWdev   := Round(lvW * dpiScale)
    vertYdev := Round(vertY * dpiScale)
    vertHdev := Round((vertY + vertH) * dpiScale) - vertYdev
    SWP      := 0x0014   ; SWP_NOZORDER | SWP_NOACTIVATE

    ; LV has WS_BORDER (1px outer border). Outer verticals sit ON the border at lvXdev
    ; and lvXdev+lvWdev-1. Inner verticals must use the LV's CLIENT origin which is
    ; 1px inside the outer left border - hence the +1 below.
    lvInnerX := lvXdev + 1

    DllCall("SetWindowPos", "Ptr", vertOuterL.Hwnd, "Ptr", 0,
        "Int", lvXdev,                                          "Int", vertYdev,
        "Int", 1, "Int", vertHdev, "UInt", SWP)
    DllCall("SetWindowPos", "Ptr", vertCol1.Hwnd,   "Ptr", 0,
        "Int", lvInnerX + col1Wdev,                              "Int", vertYdev,
        "Int", 1, "Int", vertHdev, "UInt", SWP)
    DllCall("SetWindowPos", "Ptr", vertCol2.Hwnd,   "Ptr", 0,
        "Int", lvInnerX + col1Wdev + col2Wdev,                   "Int", vertYdev,
        "Int", 1, "Int", vertHdev, "UInt", SWP)
    DllCall("SetWindowPos", "Ptr", vertCol3.Hwnd,   "Ptr", 0,
        "Int", lvInnerX + col1Wdev + col2Wdev + col3Wdev,        "Int", vertYdev,
        "Int", 1, "Int", vertHdev, "UInt", SWP)
    DllCall("SetWindowPos", "Ptr", vertOuterR.Hwnd, "Ptr", 0,
        "Int", lvXdev + lvWdev - 1,                              "Int", vertYdev,
        "Int", 1, "Int", vertHdev, "UInt", SWP)

    rescueGui.colSeparators := [sepHorizTop, sepHorizBottom,
                                 vertOuterL, vertCol1, vertCol2, vertCol3, vertOuterR]

    ; Stash survivor entries on the LV via a parallel array (LV row index -> entry).
    rescueGui.entries := survivors
    for entry in survivors {
        timeShort := FormatHiddenAtLocalShort(entry.hiddenAt)
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

    ; Intro Text color follows pal.text - parent BackColor alone isn't enough because the
    ; Text control retains its initially-set text color (which was the light-theme default).
    if (IsObject(rescueGui.txtIntro)) {
        try rescueGui.txtIntro.Opt("c" pal.text)
        try rescueGui.txtIntro.Redraw()
    }

    ; Column header labels (Text controls above the LV - native header suppressed via -Hdr).
    if (rescueGui.HasProp("colHeaders") && IsObject(rescueGui.colHeaders)) {
        for ctrl in rescueGui.colHeaders {
            try ctrl.Opt("c" pal.headerFg)
            try ctrl.Redraw()
        }
    }

    ; Grid separators (vertical column dividers + horizontal under-header line).
    ; Uses pal.gridLine (separate from buttonBorder) tuned to match the LV body's
    ; auto-drawn grid color in each theme.
    if (rescueGui.HasProp("colSeparators") && IsObject(rescueGui.colSeparators)) {
        for sep in rescueGui.colSeparators {
            try sep.Opt("Background" pal.gridLine)
            try sep.Redraw()
        }
    }

    ; ListView body color via AHK Gui options.
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

    ; uxtheme dark-mode private API: theme every child control (buttons, listview)
    ; with DarkMode_Explorer in dark, Explorer in light. This is the modern Win11 path.
    ApplyDarkModeToGui(rescueGui, themeState)
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

;==============================================================================
; v1.0.7 dark-mode private uxtheme APIs - theme-aware native controls
;
; Replaces what was originally drafted as GDI BS_OWNERDRAW + WM_DRAWITEM owner-draw
; (15+ years dated; AHK silently dropped +0xB on AddButton; the path was a dead-end).
;
; Modern Win11 path: SetPreferredAppMode + AllowDarkModeForWindow + SetWindowTheme.
; This is the same engine File Explorer / Settings / Notepad++ / ShareX use to dark-
; theme native controls (buttons, ListView, checkbox, scrollbars). No painting; the
; OS handles the rendering, hover/pressed states, focus ring, and accessibility tree
; integration. Private uxtheme ordinals are technically undocumented but have been
; stable since Win10 1809 (Oct 2018); Windows itself relies on them.
;
; Ordinals reference (uxtheme.dll):
;   #132 ShouldAppsUseDarkMode (returns BOOL)
;   #133 AllowDarkModeForWindow(hwnd, allow)
;   #135 SetPreferredAppMode(mode)   ; 1=AllowDark, 2=ForceDark, 3=ForceLight, 4=Max
;   #138 ShouldSystemUseDarkMode (returns BOOL)
;==============================================================================

ApplyAppDarkMode(themeStateLocal) {
    ; Process-level mode. Affects controls created AFTER this call. Call once at
    ; startup and again on every theme toggle.
    mode := (themeStateLocal = "dark") ? 2 : 3   ; 2=ForceDark, 3=ForceLight
    try DllCall("uxtheme\#135", "Int", mode, "CDecl Int")
}

ApplyDarkModeToGui(guiObj, themeStateLocal) {
    ; Window-level + per-control theme application. Used for live theme toggling on
    ; already-created Gui windows. Calls AllowDarkModeForWindow on the top-level, then
    ; SetWindowTheme("DarkMode_Explorer" or "Explorer") on each child control. Wrapped
    ; in try blocks because uxtheme ordinals can fail silently on unsupported Win10
    ; builds without taking down the rest of the theme apply.
    if (!IsObject(guiObj))
        return

    allow := (themeStateLocal = "dark") ? 1 : 0
    try DllCall("uxtheme\#133", "Ptr", guiObj.Hwnd, "Int", allow, "CDecl Int")

    themeClass := (themeStateLocal = "dark") ? "DarkMode_Explorer" : "Explorer"
    for hwndKey, ctrl in guiObj {
        if (!IsObject(ctrl))
            continue
        try DllCall("uxtheme\SetWindowTheme"
            , "Ptr",  ctrl.Hwnd
            , "WStr", themeClass
            , "Ptr",  0)
        try DllCall("InvalidateRect", "Ptr", ctrl.Hwnd, "Ptr", 0, "Int", true)
    }

    ; Force an immediate non-client area repaint so the title-bar dark mode and child
    ; control re-theming take effect without waiting for the next user interaction.
    try DllCall("InvalidateRect", "Ptr", guiObj.Hwnd, "Ptr", 0, "Int", true)
}

;==============================================================================
; v1.0.7 exit flow - confirmation dialog when tray-managed windows exist
;==============================================================================

ConfirmExitFromMenu(*) {
    global Groups, exitGui, themeState

    ; Count managed windows across all groups.
    totalWindows := 0
    for procName, group in Groups
        totalWindows += group.windows.Length

    ; If no windows in tray, exit immediately. No dialog needed.
    if (totalWindows == 0) {
        ExitApp()
        return
    }

    ; If a dialog is already open (double-click race), focus it instead of duplicating.
    if (IsObject(exitGui)) {
        try exitGui.Show()
        return
    }

    exitGui := Gui("+AlwaysOnTop +MinSize460x180", "Exit minimize-to-tray")
    exitGui.OnEvent("Close",  (*) => CloseExitDialog())
    exitGui.OnEvent("Escape", (*) => CloseExitDialog())
    exitGui.MarginX := 18
    exitGui.MarginY := 16
    exitGui.SetFont("s10", "Segoe UI")

    countText := "You have " totalWindows " app window" (totalWindows == 1 ? "" : "s") " hidden in the tray."
    txtCount := exitGui.AddText("xm w432", countText)
    bodyText := "Restore all before exiting or leave hidden? Hidden apps can't be recovered after log off or restart."
    txtBody := exitGui.AddText("xm w432", bodyText)

    btnRestore := exitGui.AddButton("xm w130 h32 Default", "&Restore && Exit")
    btnRestore.OnEvent("Click", (*) => DoExitWithChoice(true))
    btnLeave := exitGui.AddButton("x+10 yp w130 h32", "&Leave Hidden")
    btnLeave.OnEvent("Click", (*) => DoExitWithChoice(false))
    btnCancel := exitGui.AddButton("x+10 yp w130 h32", "&Cancel")
    btnCancel.OnEvent("Click", (*) => CloseExitDialog())

    exitGui.txtCount   := txtCount
    exitGui.txtBody    := txtBody
    exitGui.btnRestore := btnRestore
    exitGui.btnLeave   := btnLeave
    exitGui.btnCancel  := btnCancel

    ApplyThemeToExitDialog()

    exitGui.Show("AutoSize Center")
}

ApplyThemeToExitDialog() {
    global exitGui, themeState
    if (!IsObject(exitGui))
        return
    pal := GetThemePalette(themeState)
    try exitGui.BackColor := pal.bg
    if (IsObject(exitGui.txtCount))
        try exitGui.txtCount.Opt("c" pal.text)
    if (IsObject(exitGui.txtBody))
        try exitGui.txtBody.Opt("c" pal.text)

    ; DWM dark title bar
    val := (themeState = "dark") ? 1 : 0
    try DllCall("dwmapi\DwmSetWindowAttribute"
        , "Ptr",  exitGui.Hwnd
        , "UInt", 20
        , "Int*", val
        , "UInt", 4)

    ; uxtheme dark-mode private API: theme every child control with DarkMode_Explorer
    ApplyDarkModeToGui(exitGui, themeState)
}

DoExitWithChoice(restoreFirst) {
    global cleanupRestoreOnExit, exitGui
    cleanupRestoreOnExit := restoreFirst
    CloseExitDialog()
    ExitApp()
}

CloseExitDialog() {
    global exitGui
    if (IsObject(exitGui)) {
        try exitGui.Destroy()
    }
    exitGui := 0
}

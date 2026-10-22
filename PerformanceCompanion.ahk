#Requires AutoHotkey v2.0
#SingleInstance Off      ; handled below, so the Start menu shortcut can talk to the running copy
Persistent
SetTitleMatchMode 2

; ====================================================================
;  PERFORMANCE COMPANION: automatic performance modes for gaming laptops and handhelds
;
;  One machine for work, play and the road. Profiles bundle the settings
;  you'd otherwise change by hand and switch them in one click, by
;  schedule, or when you unplug. Games (and any power-hungry app you add:
;  a DAW, a renderer, a local AI model) are detected automatically and get
;  their own performance mode while they run.
;
;  Two engines, picked automatically:
;    G-Helper            ASUS laptops and handhelds running G-Helper: GPU
;                        modes (Eco / Standard / Ultimate), charge limits,
;                        G-Helper's own and custom performance modes.
;    Windows power plans Everything else (Razer, Lenovo, MSI, Dell, HP,
;                        handhelds with Handheld Companion...). Your maker's
;                        app sets the hardware ceiling once; Performance Companion decides
;                        how much of it Windows uses.
;
;  Performance Companion is the source of truth. On login, plug, unplug, resume and every
;  switch it checks the real state and corrects anything that drifted.
;
;  Install or update: double-click any copy of this file. It copies
;  itself into place, stops the running version, and starts the new
;  one. Updates need no admin prompt; only a first install does.
;  Replaces G14 Control, Laptop Control and Clutch: settings carry over.
; ====================================================================

global SCRIPT_VERSION := "3.0.5"      ; bump on every release so updates announce themselves
global APP_NAME       := "Performance Companion"
global REPO_URL       := "https://github.com/zonearc/PerformanceCompanion"

; ---------- INSTALL LOCATION ----------
global installDir     := A_AppData "\PerformanceCompanion"
global scriptDest     := installDir "\PerformanceCompanion.ahk"
global TASK_MAIN      := "PerformanceCompanion"
global TASK_TOGGLE    := "PerformanceCompanion Toggle"

; Earlier apps Performance Companion replaces (data is imported once, then they're retired).
global OLD_APPS := [
    {name: "G14 Control", dir: A_AppData "\GHelperSmartTurbo", script: "GHelper_Auto_Turbo.ahk",
     tasks: ["GHelperSmartTurbo", "GHelperSmartTurbo Toggle"],
     links: [A_Programs "\G14 Control profiles.lnk", A_Programs "\G14 Profile Toggle.lnk", A_Startup "\GHelper_Auto_Turbo.lnk"]},
    {name: "Laptop Control", dir: A_AppData "\LaptopControl", script: "LaptopControl.ahk",
     tasks: ["LaptopControl", "LaptopControl Toggle"], links: [A_Programs "\Laptop Control profiles.lnk"]},
    {name: "Clutch", dir: A_AppData "\Clutch", script: "Clutch.ahk",
     tasks: ["Clutch", "Clutch Toggle"], links: [A_Programs "\Clutch profiles.lnk"]}
]

; ---------- INSTALL / UPDATE ----------
; Running from anywhere other than the install folder means "install or
; update me". Copying into AppData needs no admin rights. If the elevated
; startup task already exists, launch through it: no UAC prompt, and the
; new copy replaces the running one (see ONE COPY AT A TIME). Only a first
; install, with no task yet, asks for admin.
if (A_ScriptFullPath != scriptDest) {
    DirCreate(installDir)
    try {
        FileCopy(A_ScriptFullPath, scriptDest, true)
    } catch as err {
        MsgBox("Couldn't copy Performance Companion into " installDir ".`n`n" err.Message, "Performance Companion", "Iconx")
        ExitApp()
    }
    if TaskExists(TASK_MAIN)
        Run('schtasks.exe /run /tn "' TASK_MAIN '"', , "Hide")
    else
        try Run('*RunAs "' A_AhkPath '" "' scriptDest '"')
    ExitApp()
}

; ---------- ELEVATION ----------
; The installed copy runs elevated (G-Helper does, and we close, relaunch
; and click it). Normally the startup task handles this with no prompt.
if !A_IsAdmin {
    toggling := (A_Args.Length && A_Args[1] = "toggle")
    if TaskExists(toggling ? TASK_TOGGLE : TASK_MAIN)
        Run('schtasks.exe /run /tn "' (toggling ? TASK_TOGGLE : TASK_MAIN) '"', , "Hide")
    else
        try Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"' (toggling ? " toggle" : ""))
    ExitApp()
}

; ---------- ONE COPY AT A TIME ----------
; A second launch with "toggle" (Start menu shortcut) asks the running copy
; to show the profile picker, so it appears instantly. Any other second
; launch (an update, a reload) replaces the running copy.
global MSG_PICKER := 0x8014
HandleOtherInstance()
OnMessage(MSG_PICKER, (*) => (SetTimer(ShowProfilePicker, -10), 1))

HandleOtherInstance() {
    DetectHiddenWindows(true)
    others := []
    for h in WinGetList(scriptDest " ahk_class AutoHotkey")
        if (h != A_ScriptHwnd)
            others.Push(h)
    if (A_Args.Length && A_Args[1] = "toggle" && others.Length) {
        PostMessage(MSG_PICKER, 0, 0, , "ahk_id " others[1])
        ExitApp()
    }
    for h in others {
        try {
            pid := WinGetPID("ahk_id " h)
            WinClose("ahk_id " h)
            if !ProcessWaitClose(pid, 3)
                ProcessClose(pid)
        }
    }
    DetectHiddenWindows(false)
}

; ====================================================================
;  APP-WIDE SETTINGS (defaults; Tray > Settings saves your choices)
;  Per-profile settings (GPU, charge limit, modes) live in Tray > Profiles.
; ====================================================================
global SHUTDOWN_DELAY      := 10     ; countdown before a restart or shutdown; Win+R "shutdown /a" cancels
global DEFAULT_GAME_MODE   := 1      ; mode for games with no saved mode: 1 Turbo, 0 Balanced, 2 Silent
global LEARNING_ENABLED    := true
global SHOW_POPUPS         := true
global GameLoadForeground  := 35     ; % GPU load that counts as a game when fullscreen/borderless in front
global GameLoadBackground  := 70     ; % GPU load that counts as a game for any single app
global GpuIdleThreshold    := 15     ; game mode ends below this
global SCHEDULES_ENABLED   := false  ; master switch for Tray > Schedules (off until you turn it on)
global CUSTOM_MODES        := true   ; offer G-Helper's custom modes (by their names) as app modes
global ENGINE_CHOICE       := "auto" ; auto | ghelper | plans
global UPDATE_MODE         := "notify" ; notify | auto | off: checking GitHub for new versions
global BATTERY_PROFILE     := ""     ; profile to switch to when unplugged ("" = stay), back on plug-in
global WARN_MINUTES        := 10     ; schedules warn this long before a restart or shutdown

; Detection timing (5 second ticks)
global EnableLoadDetection := true
global HysteresisCycles    := 2      ; sustained load before game mode (10s)
global ReleaseCycles       := 3      ; low load before game mode ends (15s)
global LearnCycles         := 6      ; game-mode load before an app is learned as a game (30s)

; Publisher install folders treated as games (from Windows' installed programs list)
global TargetPublishers := ["Electronic Arts", "Epic Games", "Riot Games", "Ubisoft", "Blizzard", "Activision", "Xbox", "GOG.com", "Bethesda", "Square Enix", "Capcom"]

; No games are listed in the script. Games are detected (Steam, Xbox,
; publisher folders), learned from GPU load, or added in Games and modes.

; Apps that are never games (matched against the full path)
global IgnoredExecutables := ["chrome.exe", "msedge.exe", "firefox.exe", "discord.exe", "MinecraftLauncher.exe",
                              "ApplicationFrameHost.exe", "explorer.exe", "System32", "GHelper.exe", "msedgewebview2.exe",
                              "\NVIDIA Corporation\", "Claude.exe", "Krisp", "obs64.exe", "Spotify.exe",
                              "LeagueClient.exe", "LeagueClientUx"]   ; League lobby/launcher, not the game
global IgnoredSteamAppIDs := ["388080", "993090"]   ; Borderless Gaming, Lossless Scaling: tools that run alongside games

; Launchers and stores: never a game, even inside a publisher folder
global LauncherExecutables := [
    "Battle.net", "\Blizzard Entertainment\Agent\",            ; Blizzard app + update agent
    "\EA Desktop\", "EABackgroundService", "\Origin\",       ; EA app
    "\Epic Games\Launcher\", "EpicWebHelper",                ; Epic
    "\Ubisoft Game Launcher\", "UplayWebCore", "upc.exe",      ; Ubisoft Connect
    "\GOG Galaxy\",                                          ; GOG
    "\Steam\steam.exe", "steamwebhelper", "\Steam\bin\",     ; Steam client
    "XboxPcApp", "Microsoft.GamingApp", "GameBar",              ; Xbox app / Game Bar
    "\Rockstar Games\Launcher\", "SocialClubHelper",          ; Rockstar
    "\Amazon Games\App\",                                     ; Amazon
    "REDprelauncher", "REDlauncher",                            ; CD Projekt launcher
    "RiotClient"                                               ; Riot client, all parts
]

; ====================================================================
;  PATHS AND STATE
; ====================================================================
global CFG         := A_AppData "\GHelper\config.json"
global STATE       := installDir "\state.ini"
global LOGFILE     := installDir "\activity.log"
global LINK_START  := A_Programs "\Performance Companion profiles.lnk"

global importedFrom     := ImportOldApp()      ; G14 Control / Laptop Control data, first launch only
global firstRun         := !FileExist(STATE)    ; no saved state at all = truly new install
global SETTING_DEFAULTS := Map()
LoadSettings()
global BACKEND          := DetectBackend()     ; "ghelper" or "plans"
global DEVICE           := DetectDevice()      ; {maker, model, handheld, kind}

global profiles       := Map()      ; id -> profile object (see PROFILES section)
global profileOrder   := []         ; ids in display order
global profile        := ""         ; id of the active profile
LoadProfiles()                      ; also migrates the old Desk/Travel setup once

global busy           := true      ; held until startup checks finish
global paused         := false
global automationOK   := true
global isTurboMode    := false     ; a game mode is active (name kept from earlier versions)
global manualOverride := "None"
global lastGameState  := false
global cachedGameDirs := []
global turboSource    := ""         ; "game" (known/learned/added) or "load"
global turboExe       := ""
global turboMode      := 1          ; the game's own mode (before any profile cap)
global gameModes      := LoadIniMap("gamemodes")  ; exe -> saved mode
global learned        := LoadIniMap("learned")    ; exe -> date learned
global notGames       := LoadIniMap("notgames")   ; exe -> date ignored
global addedGames     := LoadIniMap("added")      ; exe -> date added
global seenGames      := LoadIniMap("seen")       ; key -> "date|how detected"
global knownHow       := ""
global lastTop        := {pid: 0, exe: "", path: "", util: 0}
global watchGpu       := false
global pdhQuery       := 0
global pdhCounter     := 0
global gpuSrc         := "pdh"      ; switches to "wmi" if the counter API fails
global gpuDiag        := ""
global pdhFailNote    := ""
global hoverTips      := Map()      ; window hwnd -> its tooltip control
global manualSince    := 0          ; when a manual lock started (it expires after LOCK_HOURS)
global LOCK_HOURS     := 3
; power plan engine state (Windows power plans backend)
global overlayOK      := ""         ; whether Windows' power mode can be set ("" = not tried yet)
global refreshPending := ""         ; plan whose screen rate waits until no fullscreen app is in front
global refreshTouched := false      ; we changed the built-in screen's rate this session
global planFails      := 0          ; failed plan switches in a row (backs off after a few)
global planRetryAt    := 0
global appliedMode    := ""         ; mode Performance Companion applied last (plans backend)
global customModes    := Map()      ; G-Helper custom modes: id -> name
global BALANCED_GUID  := "381b4222-f694-41f0-9685-ff5bb260df2e"   ; Windows Balanced plan, the template
global updateInfo     := ""         ; {version, url, notes} when a newer release exists on GitHub
global switching      := false      ; a profile switch is in progress
global schedules      := Map()      ; id -> schedule object (see SCHEDULES section)
global schedOrder     := []
global schedPending   := ""         ; the scheduled switch being warned about / waiting
LoadSchedules()

; ====================================================================
;  STARTUP
; ====================================================================
OnError(GlobalError)                ; log unexpected errors instead of a dialog
OnExit(RestoreScreen)               ; never leave the built-in screen at 60 Hz after exiting
RetireOldApps()                     ; stop and unregister G14 Control / Laptop Control if present
global linksStale := EnsureIcons()       ; new version: refresh shortcut icons too
EnsureInstall()
BuildDynamicGameCache()
GpuPdhInit()
UpdateUI()
SetTimer(WatchPower, 3000)
SetTimer(SmartPlatformMonitor, 5000)
SetTimer(StartupSequence, -500)
SetTimer(PromoteTrayIcon, -8000)
SetTimer(ChargeRateSample, 60000)
OnMessage(0x404, TrayIconMsg)       ; tray icon events

TrayIconMsg(wParam, lParam, *) {
    if (lParam = 0x205)              ; right button up: refresh before the menu shows
        BuildMenu()
}

StartupSequence() {
    global busy, automationOK
    busy := true
    if (BACKEND = "ghelper") {
        ; G-Helper never installed or never run: say so right away, keep waiting
        ; in case the user starts it now.
        if (!FileExist(CFG) && GHelperPath() = "" && !ProcessExist("GHelper.exe"))
            ShowSetupCheck("startup")
        if !ProcessWait("GHelper.exe", 90) {
            busy := false
            gh := GHelperPath()
            if (gh != "" && FileExist(gh)) {
                if (MsgBox("G-Helper isn't running, so Performance Companion can't do anything yet.`n`n"
                    . "Start G-Helper now?`n`n"
                    . "Tip: in G-Helper, tick 'Run on Startup' so this doesn't happen again.",
                    "Performance Companion", "YesNo Icon!") = "Yes") {
                    Run(gh)
                    SetTimer(StartupSequence, -500)
                    return
                }
            } else {
                ShowSetupCheck("startup")
            }
            ShowOSD("G-Helper isn't running. Automation idle.", "Blue")
            Log("STARTUP     G-Helper not running, automation idle")
            return
        }
        GHelperPath()
        Sleep(8000)                     ; let G-Helper finish its own startup
        LoadCustomModes()
    } else {
        if (IniRead(STATE, "app", "plan_before_install", "") = "")
            IniWrite(ActivePlanGuid(), STATE, "app", "plan_before_install")
        automationOK := EnsurePlans()
    }
    busy := false
    AnnounceUpdate()
    if (BACKEND = "ghelper")
        CheckVersion()
    if firstRun
        FirstRunSetup()
    else
        ShowSetupCheck("startup")    ; only pops up if something needs attention
    p := CurP()
    Log("STARTUP     " APP_NAME " " SCRIPT_VERSION ", engine " EngineName() ", " DEVICE.kind " " DEVICE.model
        . ", profile " p.name ", " (OnAC() ? "AC" : "battery") ", up " Round(A_TickCount / 60000) " min since boot")
    CheckBatteryProfile(true)
    EnforceState(true)
    RunProfileAppsIfPending()
    ShowOSD(p.name " profile active (" ProfileSummary(CurP()) ")", "Blue")
    SetTimer(ScheduleTick, 30000)
    ScheduleTick(true)               ; catch up on anything missed while the laptop was off
    SetTimer(CheckForUpdates, -60000)
    SetTimer(DailyUpdateCheck, 3600000)
    if (A_Args.Length && A_Args[1] = "toggle")
        ShowProfilePicker()
}
; ====================================================================
;  SETUP CHECK
;  Each item: level "ok", "warn" (works, but worth knowing) or "error"
;  (Performance Companion can't do its job until fixed), plus plain-language help.
; ====================================================================
SetupItems() {
    items := []
    add(level, name, help := "") => items.Push({level: level, name: name, help: help})

    add("ok", "AutoHotkey v2 (" A_AhkVersion ")")
    add("ok", (DEVICE.handheld != "" ? "Handheld: " DEVICE.handheld " (" DEVICE.model ")" : StrTitle(DEVICE.kind) ": " DEVICE.maker " " DEVICE.model))
    add("ok", "Engine: " EngineName() (ENGINE_CHOICE = "auto" ? " (picked automatically)" : " (set in Settings)"))

    if HasGH() {
        gh := GHelperPath()
        if (gh = "" && !FileExist(CFG)) {
            add("error", "G-Helper not found",
                "Download GHelper.exe from github.com/seerge/g-helper (Releases), put it in a folder "
                . "you'll keep, run it once, and tick 'Run on Startup'. Then reload Performance Companion. "
                . "Or set Settings > Engine to Windows power plans.")
        } else if !ProcessExist("GHelper.exe") {
            add("error", "G-Helper is installed but not running",
                "Start G-Helper. In its window, tick 'Run on Startup' so it's always there at login.")
        } else {
            add("ok", "G-Helper running (" CurrentVersion() ")")
        }
        if (FileExist(CFG) || gh != "") {
            if GHelperStartsWithWindows()
                add("ok", "G-Helper starts with Windows")
            else
                add("warn", "G-Helper doesn't start with Windows",
                    "In G-Helper, tick 'Run on Startup'. Without it, Performance Companion waits for G-Helper at every login.")
        }
        if FileExist(CFG) {
            gm := GetJsonInt(ReadCfg(), "gpu_mode")
            if (gm = "")
                add("warn", "No GPU switching on this machine",
                    "That's normal for many models. Profiles still switch modes, charge limits and apps; "
                    . "leave each profile's GPU on Optimized.")
            else
                add("ok", "GPU switching available (currently " GpuName(gm) ")")
            add("ok", "G-Helper custom modes found: " (customModes.Count ? customModes.Count : "none"))
        }
        conflicts := []
        for p in ["ArmouryCrate.exe", "ArmouryCrate.Service.exe", "ArmourySocketServer.exe",
                  "ArmouryCrateControlInterface.exe", "MyASUS.exe", "AsusOptimization.exe", "ASUSOptimization.exe"]
            if ProcessExist(p)
                conflicts.Push(p)
        if conflicts.Length
            add("warn", "Other ASUS control software running",
                "Found: " Join(conflicts, ", ") ". These can override the charge limit and modes Performance Companion sets. "
                . "G-Helper's Extra settings has a button to stop ASUS services, or uninstall Armoury Crate.")
        else
            add("ok", "No conflicting ASUS software running")
        if (SubStr(A_Language, -2) != "09")
            add("warn", "Windows isn't set to English",
                "Two steps read G-Helper's English text: clicking Ultimate and answering its 'leave Ultimate' prompt. "
                . "On other languages you'll be asked to click those yourself. Everything else works.")
        if !automationOK
            add("error", "G-Helper self-test failed",
                "This G-Helper version didn't respond the way Performance Companion expects, so automation is paused. "
                . "Tray > Help and troubleshooting > Run G-Helper self-test to retry, or check the activity log.")
    } else {
        missing := []
        for k in PlanKeys()
            if !PlanExists(PlanGuid(k))
                missing.Push(ModeName(KeyMode(k)))
        if missing.Length
            add("error", "Power plans missing: " Join(missing, ", "),
                "Performance Companion couldn't create its power plans. Tray > Help and troubleshooting > Reload tries again. "
                . "If it keeps failing, a company policy may be locking power settings.")
        else
            add("ok", "Performance Companion power plans ready (Eco, Work, Performance)")
        if (overlayOK = false)
            add("warn", "Windows' power mode slider can't be set on this PC",
                "Performance Companion's plans still cap the CPU and turbo as set in Settings > advanced > Edit power plans. "
                . "Only the extra Best efficiency / Best performance nudge is skipped.")
        if (InternalDisplayName() = "")
            add("warn", "Built-in screen not found",
                "Screen refresh-rate switching only works on the built-in screen. "
                . "With the lid closed and an external monitor, it's skipped.")
        else
            add("ok", "Built-in screen found (refresh-rate switching available)")
        if ProcessExist("GHelper.exe")
            add("warn", "G-Helper is running",
                "Settings > Engine can switch Performance Companion to G-Helper for GPU modes and charge limits. "
                . "Running G-Helper alongside power plans means two apps changing power settings.")
    }
    if (DEVICE.kind = "desktop")
        add("warn", "No battery found",
            "On a desktop, battery profiles and unplug switching do nothing. Game and app modes work as usual.")

    ; One-time settings in the maker's own app (or Handheld Companion).
    for t in VendorTips()
        add("warn", "Tip: " t.name, t.text)

    ; Performance Companion's own startup task: present, and how its last run went.
    if !TaskExists(TASK_MAIN) {
        add("error", "Performance Companion's startup task is missing",
            "Tray > Help and troubleshooting > Reload recreates it. Without it, Performance Companion won't start at login.")
    } else {
        info := TaskInfo(TASK_MAIN)
        lr := info.Has("Last Result") ? info["Last Result"] : ""
        if (lr = "" || lr = "0" || lr = "267009" || lr = "267011")     ; ok, running, never run yet
            add("ok", "Performance Companion starts with Windows")
        else
            add("warn", "Performance Companion's last automatic start reported code " lr,
                "Last attempt: " (info.Has("Last Run Time") ? info["Last Run Time"] : "unknown")
                . ". If it didn't start at your last login, send this code along with Copy diagnostics.")
    }
    return items
}

; Reads a scheduled task's details (Last Result, Last Run Time, Status...).
TaskInfo(name) {
    info := Map()
    tmp := A_Temp "\g14_task.csv"
    try {
        RunWait(A_ComSpec ' /c schtasks.exe /query /tn "' name '" /v /fo csv > "' tmp '"', , "Hide")
        rows := StrSplit(Trim(FileRead(tmp), "`r`n"), "`n", "`r")
        FileDelete(tmp)
        if (rows.Length >= 2) {
            hdr := ParseCsvLine(rows[1]), val := ParseCsvLine(rows[2])
            for i, h in hdr
                if (i <= val.Length)
                    info[h] := val[i]
        }
    }
    return info
}

ParseCsvLine(line) {
    out := []
    pos := 1
    while RegExMatch(line, '"((?:[^"]|"")*)"', &m, pos) {
        out.Push(StrReplace(m[1], '""', '"'))
        pos := m.Pos(0) + m.Len(0)
    }
    return out
}

; G-Helper's "Run on Startup" has used different mechanisms over time, so
; look for G-Helper itself in Run keys and in any scheduled task's action
; rather than guessing a task name.
GHelperStartsWithWindows() {
    for key in ["HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
                "HKLM\Software\Microsoft\Windows\CurrentVersion\Run"] {
        try {
            Loop Reg key {
                if InStr(RegRead(key, A_LoopRegName), "GHelper")
                    return true
            }
        }
    }
    if TaskExists("GHelper")
        return true
    tmp := A_Temp "\g14_tasks.csv"
    try {
        RunWait(A_ComSpec ' /c schtasks.exe /query /fo csv /v > "' tmp '"', , "Hide")
        out := FileRead(tmp)
        FileDelete(tmp)
        return InStr(out, "GHelper.exe") > 0
    }
    return false
}

; mode "startup": only shows if there's an error or a warning not seen before.
; mode "manual": always shows the full checklist.
ShowSetupCheck(mode := "manual", *) {
    items := SetupItems()
    errors := 0, fresh := 0
    for it in items {
        if (it.level = "error")
            errors++
        if (it.level = "warn" && IniRead(STATE, "setupcheck", it.name, "") = "")
            fresh++
    }
    if (mode = "startup" && !errors && !fresh)
        return

    msg := ""
    for it in items {
        icon := (it.level = "ok") ? "✔" : (it.level = "warn") ? "⚠" : "✖"
        msg .= icon "  " it.name "`n"
        if (it.help != "" && it.level != "ok")
            msg .= "      " it.help "`n"
        if (it.level = "warn")
            IniWrite(1, STATE, "setupcheck", it.name)    ; don't repeat this warning at startup
        if (it.level != "ok")
            Log("SETUP       " StrUpper(it.level) ": " it.name)
    }
    head := errors ? "Performance Companion needs attention before it can work:`n`n"
          : fresh ? "Performance Companion is running. A few things worth knowing:`n`n"
          : "Everything Performance Companion needs is in place:`n`n"
    MsgBox(head msg, "Performance Companion setup check", errors ? "Icon!" : "Iconi")
}

; ====================================================================
;  APP-WIDE SETTINGS
;  Defaults live in the block at the top. Anything changed in the
;  Settings window is saved to state.ini [settings] and wins over them.
;  Per-profile settings (GPU, charge, modes) are in the Profiles window.
; ====================================================================
SettingNames() => ["DEFAULT_GAME_MODE", "LEARNING_ENABLED", "GameLoadForeground", "GameLoadBackground",
    "GpuIdleThreshold", "SHUTDOWN_DELAY", "SHOW_POPUPS", "SCHEDULES_ENABLED", "CUSTOM_MODES", "WARN_MINUTES",
    "ENGINE_CHOICE", "BATTERY_PROFILE", "UPDATE_MODE"]

; Explicit get/set for each setting (clearer and safer than dynamic names).
GetSetting(name) {
    switch name {
        case "DEFAULT_GAME_MODE":  return DEFAULT_GAME_MODE
        case "LEARNING_ENABLED":   return LEARNING_ENABLED
        case "GameLoadForeground": return GameLoadForeground
        case "GameLoadBackground": return GameLoadBackground
        case "GpuIdleThreshold":   return GpuIdleThreshold
        case "SHUTDOWN_DELAY":     return SHUTDOWN_DELAY
        case "SHOW_POPUPS":        return SHOW_POPUPS
        case "SCHEDULES_ENABLED":  return SCHEDULES_ENABLED
        case "CUSTOM_MODES":       return CUSTOM_MODES
        case "WARN_MINUTES":       return WARN_MINUTES
        case "ENGINE_CHOICE":      return ENGINE_CHOICE
        case "BATTERY_PROFILE":    return BATTERY_PROFILE
        case "UPDATE_MODE":        return UPDATE_MODE
    }
    return ""
}

SetSetting(name, v) {
    global DEFAULT_GAME_MODE, LEARNING_ENABLED, GameLoadForeground, GameLoadBackground, GpuIdleThreshold
    global SHUTDOWN_DELAY, SHOW_POPUPS, SCHEDULES_ENABLED, CUSTOM_MODES, WARN_MINUTES, ENGINE_CHOICE, BATTERY_PROFILE, UPDATE_MODE
    switch name {
        case "DEFAULT_GAME_MODE":  DEFAULT_GAME_MODE := v
        case "LEARNING_ENABLED":   LEARNING_ENABLED := v
        case "GameLoadForeground": GameLoadForeground := v
        case "GameLoadBackground": GameLoadBackground := v
        case "GpuIdleThreshold":   GpuIdleThreshold := v
        case "SHUTDOWN_DELAY":     SHUTDOWN_DELAY := v
        case "SHOW_POPUPS":        SHOW_POPUPS := v
        case "SCHEDULES_ENABLED":  SCHEDULES_ENABLED := v
        case "CUSTOM_MODES":       CUSTOM_MODES := v
        case "WARN_MINUTES":       WARN_MINUTES := v
        case "ENGINE_CHOICE":      ENGINE_CHOICE := v
        case "BATTERY_PROFILE":    BATTERY_PROFILE := v
        case "UPDATE_MODE":        UPDATE_MODE := v
    }
}

LoadSettings() {
    for name in SettingNames() {
        SETTING_DEFAULTS[name] := GetSetting(name)
        v := IniRead(STATE, "settings", name, "")
        if (v != "")
            SetSetting(name, IsNumber(v) ? Number(v) : v)
    }
}

SaveSetting(name, value) {
    SetSetting(name, value)
    IniWrite(value, STATE, "settings", name)
}

; Show advanced options in Settings and Profiles (remembered per user).
AdvancedUI() => IniRead(STATE, "app", "ui_advanced", 0) = 1
SetAdvancedUI(on) => IniWrite(on ? 1 : 0, STATE, "app", "ui_advanced")

ShowSettings(*) {
    static open := 0
    if open {
        try WinActivate("ahk_id " open)
        return
    }
    adv := AdvancedUI()
    g := Gui("+AlwaysOnTop", "Performance Companion settings")
    open := g.Hwnd
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 16, g.MarginY := 12
    modeIds := ModeChoices()
    engIds := ["auto", "ghelper", "plans"], updIds := ["notify", "auto", "off"]
    engDdl := 0, custCb := 0, fgSl := 0, bgSl := 0, idSl := 0, delEd := 0, warnEd := 0

    Section(title) {
        g.SetFont("s10 bold")
        g.Add("Text", "xm y+14 w440", title)
        g.SetFont("s10 norm")
    }
    Row(label, tip) {
        t := g.Add("Text", "xm+12 y+8 w210", label)
        AddTip(t, tip)
        return t
    }
    SliderRow(label, val, lo, hi, suffix, tip) {
        Row(label, tip)
        sl := g.Add("Slider", "x+4 yp-4 w150 Range" lo "-" hi " ToolTip", val)
        tx := g.Add("Text", "x+6 yp+4 w60", val suffix)
        sl.OnEvent("Change", (c, *) => tx.Value := c.Value suffix)
        AddTip(sl, tip)
        return sl
    }

    advCb := g.Add("Checkbox", "xm", "Show advanced settings")
    advCb.Value := adv
    AddTip(advCb, "Most people never need these: the engine, detection thresholds,`ncountdowns and G-Helper custom modes.")
    advCb.OnEvent("Click", (*) => (SetAdvancedUI(advCb.Value), Close(), ShowSettings()))
    g.Add("Text", "xm y+6 w440 cGray", "What each profile does is set in Tray > Profiles"
        . (HasGH() ? "." : ", and what each mode does under advanced settings."))

    Section("Everyday")
    Row("When unplugged", "Switch to a profile automatically when you unplug, and back when you plug in.`n"
        . "A profile you pick yourself while unplugged wins.`n"
        . "Skipped if that switch would need a restart.")
    unIds := [""], unNames := ["Stay on the current profile"]
    for pid in profileOrder
        unIds.Push(pid), unNames.Push("Switch to " profiles[pid].name)
    unDdl := g.Add("DropDownList", "x+4 yp-3 w280", unNames)
    unDdl.Choose(IndexOf(unIds, BATTERY_PROFILE))
    Row("Default mode for games", "Mode for games and apps you haven't set a mode for.`n"
        . "Per-app choices (tray menu, Ctrl+Alt+G, Apps and games) always win.`n"
        . "A profile can still cap it (Profiles > Show advanced > Max power for games).")
    names := []
    for m in modeIds
        names.Push(ModeName(m))
    defDdl := g.Add("DropDownList", "x+4 yp-3 w280", names)
    defDdl.Choose(IndexOf(modeIds, DEFAULT_GAME_MODE))
    learnCb := g.Add("Checkbox", "xm+12 y+10", "Learn new games automatically")
    learnCb.Value := LEARNING_ENABLED
    AddTip(learnCb, "When an unlisted app holds heavy GPU load in game mode for " LearnCycles * 5 " seconds,`n"
        . "remember it as a game so it's recognized instantly next time.")
    schCb := g.Add("Checkbox", "xm+12 y+8", "Schedules on (Tray > Schedules)")
    schCb.Value := SCHEDULES_ENABLED
    AddTip(schCb, "Master switch for timed profile switches" (HasGH() ? " and trip charging" : "") ".`n"
        . "Off until you turn it on. Each schedule also has its own on/off.")
    popCb := g.Add("Checkbox", "xm+12 y+8", "Show on-screen popups")
    popCb.Value := SHOW_POPUPS
    AddTip(popCb, "Brief messages when a game is detected, a mode changes, and so on.`n"
        . "Warnings (like Ultimate on battery, or a scheduled restart) always show.")
    Row("Updates", "Performance Companion checks GitHub once a day for a newer release.`n"
        . "Tell me: a message and an Update item in the tray menu.`n"
        . "Install automatically: downloads and installs when no game or switch is running.`n"
        . "Your settings, profiles and games always carry over.")
    updDdl := g.Add("DropDownList", "x+4 yp-3 w280", ["Tell me when there's an update", "Install updates automatically", "Don't check"])
    updDdl.Choose(IndexOf(updIds, UPDATE_MODE))

    if adv {
        Section("Works with")
        Row("Change modes through", "Automatic: G-Helper on ASUS machines that run it, Windows power plans everywhere else.`n"
            . "G-Helper: GPU modes, charge limits, Turbo / Balanced / Silent and your custom modes.`n"
            . "Windows power plans: works on any laptop or handheld; your maker's app sets the ceiling.`n"
            . "Changing this reloads Performance Companion.")
        engDdl := g.Add("DropDownList", "x+4 yp-3 w280", ["Automatic (now: " EngineName() ")", "G-Helper", "Windows power plans"])
        engDdl.Choose(IndexOf(engIds, ENGINE_CHOICE))
        if HasGH() {
            custCb := g.Add("Checkbox", "xm+12 y+10", "Offer my G-Helper custom modes for apps and games")
            custCb.Value := CUSTOM_MODES
            AddTip(custCb, "G-Helper lets you build your own modes (Fans + Power > the + button),`n"
                . "for example Turbo power with a quieter fan curve. They're listed by the names`n"
                . "you gave them, so you can give one to FL Studio, Blender or a game.`n"
                . "Found now: " (customModes.Count ? customModes.Count : "none") ".")
        }

        if !HasGH() {
            pb := g.Add("Button", "xm+12 y+10 w200", "Edit power plans...")
            pb.OnEvent("Click", (*) => (Close(), ShowPlans()))
            AddTip(pb, "What Performance, Work and Eco actually do: CPU limit, turbo boost,`nscreen refresh rate and Energy Saver.")
        }

        Section("Game detection")
        fgSl := SliderRow("Fullscreen game threshold", GameLoadForeground, 10, 90, "%",
            "GPU load that counts as a game when the app is fullscreen or borderless in front.`n"
            . "Lower catches lighter games; higher avoids false triggers.")
        bgSl := SliderRow("Any-app threshold", GameLoadBackground, 30, 100, "%",
            "GPU load that counts as a game for any app, even windowed or in the background.")
        idSl := SliderRow("Release below", GpuIdleThreshold, 5, 40, "%",
            "Game mode ends when the game's load stays under this for " ReleaseCycles * 5 " seconds.")

        Section("Restarts and schedules")
        Row("Countdown (seconds)", "Time before a restart or shutdown. Win+R, shutdown /a cancels it.")
        delEd := g.Add("Edit", "x+4 yp-3 w60 Number", SHUTDOWN_DELAY)
        g.Add("UpDown", "Range3-120", SHUTDOWN_DELAY)
        Row("Schedule warning (minutes)", "How long before a scheduled restart or shutdown the warning appears.`n"
            . "A second reminder comes 2 minutes before.")
        warnEd := g.Add("Edit", "x+4 yp-3 w60 Number", WARN_MINUTES)
        g.Add("UpDown", "Range3-60", WARN_MINUTES)
    }

    b := g.Add("Button", "xm y+18 w100 Default", "Save")
    b.OnEvent("Click", (*) => Save())
    AddTip(b, "Save and apply now.")
    b := g.Add("Button", "x+8 w130", "Reset to defaults")
    b.OnEvent("Click", (*) => Defaults())
    AddTip(b, "Put every setting here (basic and advanced) back to the defaults.`nDoesn't touch your profiles, schedules or games.")
    b := g.Add("Button", "x+8 w90", "Cancel")
    b.OnEvent("Click", (*) => Close())
    g.OnEvent("Close", (*) => Close())
    g.OnEvent("Escape", (*) => Close())
    g.Show()

    Close() {
        open := 0
        ClearTips(g)
        g.Destroy()
    }

    Save() {
        wasSched := SCHEDULES_ENABLED
        SaveSetting("DEFAULT_GAME_MODE", modeIds[defDdl.Value])
        SaveSetting("LEARNING_ENABLED", learnCb.Value)
        SaveSetting("SHOW_POPUPS", popCb.Value)
        SetSchedulesEnabled(schCb.Value, wasSched)
        SaveSetting("BATTERY_PROFILE", unIds[unDdl.Value])
        SaveSetting("UPDATE_MODE", updIds[updDdl.Value])
        engChanged := false
        if adv {
            fg := fgSl.Value, bg := bgSl.Value
            if (bg < fg)
                bg := fg                              ; any-app can't be below fullscreen
            SaveSetting("GameLoadForeground", fg)
            SaveSetting("GameLoadBackground", bg)
            SaveSetting("GpuIdleThreshold", idSl.Value)
            SaveSetting("SHUTDOWN_DELAY", Max(3, Min(120, Integer(delEd.Value = "" ? 10 : delEd.Value))))
            SaveSetting("WARN_MINUTES", Max(3, Min(60, Integer(warnEd.Value = "" ? 10 : warnEd.Value))))
            if custCb
                SaveSetting("CUSTOM_MODES", custCb.Value)
            newEng := engIds[engDdl.Value]
            engChanged := (newEng != ENGINE_CHOICE)
            SaveSetting("ENGINE_CHOICE", newEng)
        }
        Log("SETTINGS    saved: default " ModeName(DEFAULT_GAME_MODE) ", learning " (LEARNING_ENABLED ? "on" : "off")
            ", unplug " (BATTERY_PROFILE = "" ? "stay" : BATTERY_PROFILE) ", updates " UPDATE_MODE
            ", custom modes " (CUSTOM_MODES ? "on" : "off") ", thresholds " GameLoadForeground "/" GameLoadBackground "/" GpuIdleThreshold
            ", countdown " SHUTDOWN_DELAY "s, warning " WARN_MINUTES " min, schedules " (SCHEDULES_ENABLED ? "on" : "off")
            ", popups " (SHOW_POPUPS ? "on" : "off") ", engine " ENGINE_CHOICE)
        Close()
        if engChanged {
            Log("SETTINGS    engine changed; reloading")
            Reload()
            return
        }
        UpdateUI()
        ShowOSD("Settings saved", "Green", true)
    }

    Defaults() {
        if (MsgBox("Reset every setting (basic and advanced) to the defaults?`n`nYour profiles, schedules and games stay as they are.",
            "Performance Companion settings", "YesNo Icon? Owner" g.Hwnd) != "Yes")
            return
        ResetSettings()
        Close()
        UpdateUI()
        ShowSettings()
    }
}

; Puts every app-wide setting back to its default. Reloads if the engine changes.
ResetSettings() {
    wasSched := SCHEDULES_ENABLED, oldEng := ENGINE_CHOICE
    for name in SettingNames() {
        SetSetting(name, SETTING_DEFAULTS[name])
        try IniDelete(STATE, "settings", name)
    }
    SetSchedulesEnabled(SCHEDULES_ENABLED, wasSched)
    Log("SETTINGS    reset to defaults")
    if (ENGINE_CHOICE != oldEng)
        SetTimer(() => Reload(), -500)
}

IndexOf(arr, v) {
    for i, x in arr
        if (x = v)
            return i
    return 1
}

Join(arr, sep := "|") {
    out := ""
    for i, x in arr
        out .= (i = 1 ? "" : sep) x
    return out
}


; ====================================================================
;  PROFILES
;  A profile is a full set of the G-Helper settings you'd otherwise
;  change by hand. Stored in state.ini as [profile.<id>] sections, in the
;  order listed in [profiles] order=. Any number of profiles.
;
;    name      shown in the tray
;    icon      everyday (blue laptop) | desk (red bolt) | travel (teal battery) | custom (purple star)
;    gpu       auto (Eco on battery, Standard plugged in) | ultimate | standard | eco
;    charge    charge limit, 40-100
;    battery   mode on battery with no game: 2 Silent, 0 Balanced
;    ac        mode plugged in with no game: 0 Balanced, 2 Silent
;    games     where game modes work: off | ac | always
;    cap       limit game modes: none | balanced | silent
;    after     auto (restart only if the GPU change needs it) | shutdown (always shut down)
;    launch    programs to open when switching to it, "|" separated
;    close     programs to close when switching to it, "|" separated exe names
; ====================================================================
CurP(id := "") => profiles[id = "" ? profile : id]

NewProfileObj(name, icon, gpu, charge, battery, ac, games, cap, after) {
    return {id: "", name: name, icon: icon, gpu: gpu, charge: charge, battery: battery, ac: ac,
        games: games, cap: cap, after: after, launch: "", close: ""}
}

ProfileIcons()  => ["everyday", "desk", "travel", "custom"]
ProfileGpus()   => ["auto", "ultimate", "standard", "eco"]
ProfileGames()  => ["off", "ac", "always"]
ProfileCaps()   => ["none", "balanced", "silent"]
ProfileAfters() => ["auto", "shutdown"]

; Keeps a value only if it's one of the allowed choices.
PickOf(v, allowed, fallback) {
    for x in allowed
        if (v = x)
            return x
    return fallback
}

ReadProfile(id) {
    sec := "profile." id
    r(k, d) => IniRead(STATE, sec, k, d)
    p := NewProfileObj(r("name", id), r("icon", "custom"), r("gpu", "auto"), r("charge", 80),
        r("battery", 2), r("ac", 0), r("games", "ac"), r("cap", "none"), r("after", "auto"))
    p.id := id
    p.icon  := PickOf(p.icon, ProfileIcons(), "custom")
    p.gpu   := PickOf(p.gpu, ProfileGpus(), "auto")
    p.games := PickOf(p.games, ProfileGames(), "ac")
    p.cap   := PickOf(p.cap = "work" ? "balanced" : p.cap = "eco" ? "silent" : p.cap, ProfileCaps(), "none")   ; Laptop Control names
    p.after := PickOf(p.after, ProfileAfters(), "auto")
    p.charge  := IsInteger(p.charge) ? Max(40, Min(100, Integer(p.charge))) : 80
    p.battery := (p.battery = 0 || p.battery = 1) ? Integer(p.battery) : 2
    p.ac      := (p.ac = 1 || p.ac = 2) ? Integer(p.ac) : 0
    p.launch := r("launch", "")
    p.close  := r("close", "")
    return p
}

WriteProfile(p) {
    sec := "profile." p.id
    for k in ["name", "icon", "gpu", "charge", "battery", "ac", "games", "cap", "after", "launch", "close"]
        IniWrite(p.%k%, STATE, sec, k)
}

SaveProfileOrder() => IniWrite(Join(profileOrder), STATE, "profiles", "order")

LoadProfiles() {
    global profiles, profileOrder, profile
    profiles := Map(), profileOrder := []
    if (IniRead(STATE, "profiles", "order", "") = "")
        CreateDefaultProfiles()
    for id in StrSplit(IniRead(STATE, "profiles", "order", ""), "|") {
        if (id = "" || profiles.Has(id))
            continue
        profiles[id] := ReadProfile(id)
        profileOrder.Push(id)
    }
    if !profileOrder.Length {                 ; order line emptied by hand: start over
        CreateDefaultProfiles()
        return LoadProfiles()
    }
    ; 2.0.0 test builds named these Everyday and Game Night; use the generic names.
    if !IniRead(STATE, "app", "names_v2", 0) {
        for id, nm in Map("everyday", ["Everyday", "Work"], "gaming", ["Game Night", "Gaming"]) {
            if (profiles.Has(id) && profiles[id].name = nm[1]) {
                profiles[id].name := nm[2]
                IniWrite(nm[2], STATE, "profile." id, "name")
            }
        }
        try {
            if (IniRead(STATE, "schedule.gamenight", "name", "") = "Game night")
                IniWrite("Weekly gaming", STATE, "schedule.gamenight", "name")
        }
        IniWrite(1, STATE, "app", "names_v2")
    }
    ; 3.0.5: "Battery Saver" clashed with Windows' own Battery saver.
    if (profiles.Has("travel") && profiles["travel"].name = "Battery Saver") {
        profiles["travel"].name := "Long Battery"
        IniWrite("Long Battery", STATE, "profile.travel", "name")
    }
    profile := IniRead(STATE, "app", "profile", "")
    if (profile = "desk")                      ; 1.x names, in case migration was skipped
        profile := "gaming"
    if !profiles.Has(profile) {
        profile := profileOrder[1]
        IniWrite(profile, STATE, "app", "profile")
    }
}

; Three ready-to-use profiles. A 1.x install carries its Desk / Travel
; settings over: Desk becomes Gaming, Travel stays Travel, and
; Work is new (Optimized GPU with the Desk charge limit).
CreateDefaultProfiles() {
    if (BACKEND = "plans") {
        ; Windows power plans: no GPU or charge settings, instant switches.
        ;   Work            Work plugged in, Eco on battery, game modes plugged in
        ;   Gaming          Performance plugged in, Work on battery, game modes always
        ;   Long Battery    Eco everywhere, game modes off
        wk := NewProfileObj("Work", "everyday", "auto", 80, 2, 0, "ac", "none", "auto")
        wk.id := "everyday"
        gm := NewProfileObj("Gaming", "desk", "auto", 80, 0, 1, "always", "none", "auto")
        gm.id := "gaming"
        bs := NewProfileObj("Long Battery", "travel", "auto", 100, 2, 2, "off", "none", "auto")
        bs.id := "travel"
        for p in [wk, gm, bs]
            WriteProfile(p)
        IniWrite("everyday|gaming|travel", STATE, "profiles", "order")
        IniWrite(1, STATE, "app", "names_v2")
        return
    }
    old     := IniRead(STATE, "app", "profile", "")
    deskC   := IniRead(STATE, "settings", "DESK_CHARGE", 80)
    travC   := IniRead(STATE, "settings", "TRAVEL_CHARGE", 100)
    batt    := IniRead(STATE, "settings", "BATTERY_MODE", 2)
    where   := IniRead(STATE, "settings", "GAME_MODES_WHERE", "ac")
    ends    := IniRead(STATE, "settings", "TRAVEL_SWITCH_ENDS", "shutdown")
    gamesOn := (where = "always") ? "always" : "ac"
    gamesTr := (where = "desk") ? "off" : gamesOn

    ev := NewProfileObj("Work", "everyday", "auto", deskC, batt, 0, gamesTr, "none", "auto")
    ev.id := "everyday"
    gn := NewProfileObj("Gaming", "desk", "ultimate", deskC, batt, 0, gamesOn, "none", "auto")
    gn.id := "gaming"
    tr := NewProfileObj("Travel", "travel", "auto", travC, batt, 0, gamesTr, "none", ends = "restart" ? "auto" : "shutdown")
    tr.id := "travel"
    for p in [ev, gn, tr]
        WriteProfile(p)
    IniWrite("everyday|gaming|travel", STATE, "profiles", "order")

    if (old != "") {
        IniWrite(old = "desk" ? "gaming" : "travel", STATE, "app", "profile")
        IniWrite(old, STATE, "app", "migrated_from")
        for k in ["DESK_CHARGE", "TRAVEL_CHARGE", "BATTERY_MODE", "GAME_MODES_WHERE", "TRAVEL_SWITCH_ENDS"]
            try IniDelete(STATE, "settings", k)
        Log("MIGRATE     1.x " StrUpper(old) " profile -> " (old = "desk" ? "Gaming" : "Travel")
            "; Desk " deskC "%, Travel " travC "%, battery " ModeName(batt) ", game modes " where ", travel ends " ends)
    }
}

UniqueProfileId() {
    n := 1
    while profiles.Has("p" n)
        n++
    return "p" n
}

UniqueProfileName(name, exceptId := "") {
    base := name, n := 1
    loop {
        clash := false
        for id, p in profiles
            if (id != exceptId && p.name = name)
                clash := true
        if !clash
            return name
        name := base " " (++n)
    }
}

; ---------- what a profile means right now ----------
GpuLabel(g) => g = "ultimate" ? "Ultimate" : g = "standard" ? "Standard" : g = "eco" ? "Eco" : "Optimized"
GpuLabelLong(g) => g = "ultimate" ? "Ultimate (NVIDIA straight to the screen, fastest)"
    : g = "standard" ? "Standard (both GPUs, always)"
    : g = "eco" ? "Eco (NVIDIA off, longest battery)"
    : "Optimized (Eco on battery, Standard plugged in)"
GamesLabel(w) => w = "off" ? "off" : w = "always" ? "always, including battery" : "when plugged in"
ProfileSummary(p) {
    if HasGH()
        return GpuLabel(p.gpu) ", " p.charge "%"
    return (p.ac = p.battery) ? ModeName(p.ac) " always" : ModeName(p.ac) " / " ModeName(p.battery) " on battery"
}
MenuText(s) => StrReplace(s, "&", "&&")

; Whether game modes may act right now in the active profile.
GameModesActive() {
    w := CurP().games
    return (w = "always") || (w = "ac" && OnAC())
}

; Silent < Balanced < Turbo (custom modes count as Turbo-class).
CapMode(m, p := "") {
    if !IsObject(p)
        p := CurP()
    if (p.cap = "silent")
        return 2
    if (p.cap = "balanced" && ModeRank(m) > 1)
        return 0
    return m
}

; What switching to a profile involves from where the laptop is now.
; Only entering or leaving Ultimate needs a reboot (the MUX switch is
; read at boot). Eco and Standard change live.
SwitchPlan(id) {
    p := profiles[id]
    if !HasGH()
        return {needsReboot: false, ending: "none", wantUlt: false}        ; power plans switch instantly
    gm := GetJsonInt(ReadCfg(), "gpu_mode")
    wantUlt := (p.gpu = "ultimate")
    needsReboot := (gm != "") && (wantUlt != (gm = 2))
    if needsReboot
        ending := (wantUlt || p.after != "shutdown") ? "restart" : "shutdown"
    else
        ending := (p.after = "shutdown") ? "shutdown" : "none"
    return {needsReboot: needsReboot, ending: ending, wantUlt: wantUlt}
}

EndingWord(e) => e = "restart" ? "restart" : e = "shutdown" ? "shut down" : "instant"

SwitchMenuLabel(id) {
    p := profiles[id]
    return MenuText("Switch to " p.name " (" ProfileSummary(p) ", " EndingWord(SwitchPlan(id).ending) ")")
}

; True when the GPU doesn't match the active profile (an interrupted switch).
ProfileMismatch() {
    if !HasGH()
        return false
    gm := GetJsonInt(ReadCfg(), "gpu_mode")
    if (gm = "")
        return false
    return (CurP().gpu = "ultimate") ? (gm != 2) : (gm = 2)
}

; Charge limit wanted right now: the profile's, unless a trip is
; charging the battery up ahead of departure.
WantCharge() {
    c := CurP().charge
    if !HasGH()
        return c
    ov := IniRead(STATE, "app", "charge_override", "")
    if (ov = "")
        return c
    if (A_Now >= IniRead(STATE, "app", "charge_override_until", "0")) {
        ClearChargeOverride("trip window over")
        return c
    }
    return Max(Integer(ov), c)
}

ClearChargeOverride(why) {
    if (IniRead(STATE, "app", "charge_override", "") = "")
        return
    try IniDelete(STATE, "app", "charge_override")
    try IniDelete(STATE, "app", "charge_override_until")
    Log("CHARGE      trip charge override cleared (" why ")")
}

; ====================================================================
;  PROFILE SWITCHING
; ====================================================================
; source: "manual" (asks first), "schedule" (the schedule already warned),
; "picker" (same as manual), "power" (automatic on unplug / plug-in).
SwitchToProfile(id, source := "manual", *) {
    if (switching || !profiles.Has(id))
        return false
    if (source != "power" && !OnAC())
        IniWrite(1, STATE, "app", "battery_choice")          ; you picked a profile while unplugged
    if (source != "power" && IniRead(STATE, "app", "return_profile", "") != "") {
        try IniDelete(STATE, "app", "return_profile")       ; your choice beats the automatic return
        Log("BATTERY     automatic return cancelled (you picked " profiles[id].name ")")
    }
    p := profiles[id]
    plan := SwitchPlan(id)
    if (source != "schedule" && source != "power") {
        if plan.needsReboot {
            if !ConfirmSwitch("Switch to " p.name, SwitchSteps(p, plan), plan.ending = "shutdown" ? "shuts down" : "restarts")
                return false
        } else if (plan.ending = "shutdown") {
            if (MsgBox(SwitchSteps(p, plan) "`n`nContinue?", "Switch to " p.name, "YesNo Icon? T120") != "Yes")
                return false
        }
    }
    DoSwitch(id, plan, source)
    return true
}

SwitchSteps(p, plan) {
    n := 0
    s := "Switch to " StrUpper(p.name) ":`n`n"
    if HasGH() {
        s .= "    " (++n) ".  Charge limit to " p.charge "%`n"
        s .= "    " (++n) ".  GPU: " GpuLabelLong(p.gpu) "`n"
    }
    s .= "    " (++n) ".  No game: " ModeName(p.battery) " on battery, " ModeName(p.ac) " plugged in`n"
    s .= "    " (++n) ".  Game modes " GamesLabel(p.games)
        . (p.cap = "balanced" ? ", " ModeName(0) " at most" : p.cap = "silent" ? ", always " ModeName(2) : "") "`n"
    if (p.close != "" && !plan.needsReboot)
        s .= "    " (++n) ".  Close: " StrReplace(p.close, "|", ", ") "`n"
    if (p.launch != "")
        s .= "    " (++n) ".  Open: " LaunchNames(p.launch) (plan.ending = "restart" ? " (after the restart)" : "") "`n"
    if (plan.ending = "restart")
        s .= "    " (++n) ".  Restart" (plan.wantUlt ? " (G-Helper restarts the laptop for Ultimate)" : " in " SHUTDOWN_DELAY " seconds") "`n"
    else if (plan.ending = "shutdown")
        s .= "    " (++n) ".  Full shutdown in " SHUTDOWN_DELAY " seconds`n"
    if (plan.ending != "none")
        s .= "`nSave your work first."
    return RTrim(s, "`n")
}

LaunchNames(list) {
    out := []
    for x in StrSplit(list, "|") {
        if (Trim(x) = "")
            continue
        SplitPath(Trim(x, ' "'), &nm)
        out.Push(nm)
    }
    return Join(out, ", ")
}

DoSwitch(id, plan, source) {
    global switching, busy, isTurboMode, manualOverride
    p := profiles[id]
    from := CurP().name
    switching := true, busy := true
    isTurboMode := false, manualOverride := "None"
    Log("PROFILE     " from " -> " p.name " (" source ", " (plan.ending = "none" ? "live" : plan.ending) ")")
    SetProfile(id)
    ov := IniRead(STATE, "app", "charge_override", "")
    if (ov != "" && p.charge >= Integer(ov))            ; the new profile charges at least as high
        ClearChargeOverride("switched to " p.name)
    if HasGH()
        ApplyConfig()

    if plan.needsReboot {
        if (p.launch != "")
            IniWrite(id, STATE, "app", "apps_pending")      ; opened after the reboot
        if plan.wantUlt {
            busy := false
            if !SelectUltimate()
                switching := false
            return
        }
        SendGHelperKey(0x7E)              ; leaving Ultimate: Standard now, Eco after boot if on battery
        AnswerGHelperPrompts()
        busy := false, switching := false
        EndSession(plan.ending, p.name)
        return
    }

    busy := false, switching := false
    if (source != "power")
        CloseProfileApps(p)
    EnforceState(true)
    if (source != "power")
        RunProfileApps(p)
    if (plan.ending = "shutdown")
        EndSession("shutdown", p.name)
    else
        ShowOSD(p.name " profile active (" ProfileSummary(p) ")", "Green", true)
}

EndSession(ending, name) {
    if (ending = "restart") {
        Run('shutdown.exe /r /t ' SHUTDOWN_DELAY ' /c "' name ' profile set. Restarting."', , "Hide")
        ShowOSD(name " set. Restart in " SHUTDOWN_DELAY "s", "Blue", true)
    } else if (ending = "shutdown") {
        Run('shutdown.exe /s /full /t ' SHUTDOWN_DELAY ' /c "' name ' profile set. Shutting down."', , "Hide")
        ShowOSD(name " set. Shutdown in " SHUTDOWN_DELAY "s", "Blue", true)
    } else {
        return
    }
    Log("PROFILE     " ending " in " SHUTDOWN_DELAY "s (Win+R, shutdown /a cancels)")
}

RunProfileApps(p) {
    for x in StrSplit(p.launch, "|") {
        x := Trim(x)
        if (x = "")
            continue
        try {
            Run(x)
            Log("APPS        opened " x)
        } catch as e {
            Log("APPS        couldn't open " x ": " e.Message)
        }
    }
}

; Closing asks politely, like clicking X, so apps can save. Anything that
; refuses is left running (and noted in the log).
CloseProfileApps(p) {
    for x in StrSplit(p.close, "|") {
        x := Trim(x)
        if (x = "")
            continue
        if !InStr(x, ".")
            x .= ".exe"
        if !ProcessExist(x)
            continue
        for h in WinGetList("ahk_exe " x)
            try WinClose("ahk_id " h)
        Log("APPS        asked " x " to close")
    }
}

; After a reboot switch, open the apps the new profile asked for.
RunProfileAppsIfPending() {
    id := IniRead(STATE, "app", "apps_pending", "")
    if (id = "")
        return
    try IniDelete(STATE, "app", "apps_pending")
    if (id = profile)
        RunProfileApps(CurP())
}

; Ctrl+Win+Alt+T and the Start menu shortcut: pick a profile.
ShowProfilePicker(*) {
    m := Menu()
    for id in profileOrder {
        if (id = profile) {
            lbl := MenuText(CurP().name " (current: " ProfileSummary(CurP()) ")")
            m.Add(lbl, (*) => 0)
            m.Check(lbl)
            m.Disable(lbl)
        } else {
            m.Add(SwitchMenuLabel(id), SwitchToProfile.Bind(id, "picker"))
        }
    }
    if ProfileMismatch() {
        m.Add()
        m.Add(MenuText("Finish switching to " CurP().name), FinishSwitch)
    }
    m.Add()
    m.Add("Edit profiles...", ShowProfiles)
    m.Show()
}

; Clicks Ultimate in G-Helper and says Yes to its restart prompt.
; G-Helper's buttons only respond to a click that really lands on them,
; so this moves the pointer there for a moment, clicks, and puts it back.
SelectUltimate() {
    gm := GetJsonInt(ReadCfg(), "gpu_mode")
    if (gm = 2) {
        Log("PROFILE     already in Ultimate")
        return true
    }
    Loop 2 {
        attempt := A_Index
        if !WinExist("G-Helper ahk_exe GHelper.exe")
            SendCombo(0x11, 0x10, 0x7B)               ; Ctrl+Shift+F12 opens G-Helper
        if !WinWait("G-Helper ahk_exe GHelper.exe", , 8) {
            Log("PROFILE     G-Helper window didn't open (attempt " attempt ")")
            continue
        }
        Sleep(attempt = 1 ? 3000 : 5000)              ; let a freshly restarted G-Helper settle
        WinActivate()
        WinWaitActive(, , 3)
        try {
            btn := ControlGetHwnd("Ultimate")
        } catch {
            Log("PROFILE     couldn't find the Ultimate button (attempt " attempt ")")
            continue
        }
        ControlGetPos(&cx, &cy, &cw, &ch, btn)
        ShowOSD("Selecting Ultimate: hands off the mouse for a second", "Blue", true)
        Sleep(1200)
        prevMode := A_CoordModeMouse
        CoordMode("Mouse", "Screen")
        MouseGetPos(&sx, &sy)
        ; Freeze mouse movement for the click so a moving hand can't cancel it.
        ; Keyboard stays live; unlocked no matter what happens.
        try BlockInput("MouseMove")
        try {
            WinActivate("G-Helper ahk_exe GHelper.exe")
            CoordMode("Mouse", "Client")
            Click(cx + cw // 2, cy + ch // 2)
            Sleep(150)
            CoordMode("Mouse", "Screen")
            MouseMove(sx, sy, 0)                       ; pointer back where it was
        }
        try BlockInput("MouseMoveOff")
        CoordMode("Mouse", prevMode)
        Log("PROFILE     clicked Ultimate (attempt " attempt ")")

        ; G-Helper asks "Reboot now? Ultimate Mode requires restart"; the user already confirmed.
        res := PressGHelperPrompt("Yes", 8)
        if (res = "FAILED") {
            MsgBox("G-Helper is asking to restart for Ultimate. Click Yes on its prompt to finish.", "Switch to " CurP().name, "Icon!")
            return false
        }
        if (res != "") {
            ShowOSD("Switching to Ultimate. Restarting...", "Blue", true)
            Sleep(15000)                              ; G-Helper restarts the PC itself
            Log("PROFILE     G-Helper didn't restart; restarting in " SHUTDOWN_DELAY "s")
            Run('shutdown.exe /r /t ' SHUTDOWN_DELAY ' /c "' CurP().name ' profile set. Restarting for Ultimate."', , "Hide")
            return true
        }
        Log("PROMPT      no G-Helper prompt after clicking Ultimate (attempt " attempt ")")
    }
    Log("PROFILE     couldn't switch to Ultimate automatically; asked you to")
    MsgBox(CurP().name " settings are applied (" CurP().charge "% charge limit), but G-Helper didn't respond to the Ultimate click.`n`n"
        . "Click Ultimate in G-Helper and accept its restart to finish.`n"
        . "(Tray > Finish switching tries again.)", "Switch to " CurP().name, "Icon!")
    return false
}

; If a switch was interrupted, the tray offers to finish it.
FinishSwitch(*) {
    global switching
    p := CurP()
    gm := GetJsonInt(ReadCfg(), "gpu_mode")
    if (p.gpu = "ultimate" && gm != 2) {
        if ConfirmSwitch("Finish switching to " p.name, "Performance Companion will select Ultimate in G-Helper, then the laptop restarts.", "restarts")
            SelectUltimate()
    } else if (p.gpu != "ultimate" && gm = 2) {
        ending := (p.after = "shutdown") ? "shutdown" : "restart"
        if ConfirmSwitch("Finish switching to " p.name, "Performance Companion will take the GPU out of Ultimate in G-Helper, then the laptop "
            . (ending = "shutdown" ? "shuts down" : "restarts") ".", ending = "shutdown" ? "shuts down" : "restarts") {
            Log("PROFILE     finishing " p.name ": leave Ultimate, " ending)
            switching := true
            SendGHelperKey(0x7E)
            AnswerGHelperPrompts()
            switching := false
            EndSession(ending, p.name)
        }
    }
}

SetProfile(id) {
    global profile
    profile := id
    IniWrite(id, STATE, "app", "profile")
    UpdateUI()
}

; Finds a G-Helper Yes/No prompt and presses the chosen button, trying
; several methods and confirming the box actually closed. Returns the
; prompt text if handled, "" if no prompt appeared within the timeout.
PressGHelperPrompt(answer := "Yes", timeout := 8) {
    DetectHiddenWindows(false)
    deadline := A_TickCount + timeout * 1000
    hwnd := 0
    while (A_TickCount < deadline) {
        for h in WinGetList("ahk_exe GHelper.exe") {
            try {
                cls := WinGetClass(h)
                txt := WinGetText(h)
                ; Only real dialog boxes (never G-Helper's main window), and only
                ; ones about restarting / Ultimate / the GPU switch.
                if (cls = "#32770" && RegExMatch(txt, "i)restart|reboot|ultimate|mux|gpu")) {
                    hwnd := h
                    break 2
                }
            }
        }
        Sleep(250)
    }
    if !hwnd
        return ""
    text := RegExReplace(WinGetText(hwnd), "\s+", " ")
    methods := ["button", "keyboard", "button text"]
    for i, how in methods {
        try {
            switch i {
                case 1: ControlClick(answer = "Yes" ? "Button1" : "Button2", hwnd)   ; Yes is first on a Yes/No box
                case 2:
                    WinActivate(hwnd)
                    WinWaitActive(hwnd, , 2)
                    Send(answer = "Yes" ? "!y" : "!n")        ; Alt+Y / Alt+N
                case 3: ControlClick("&" answer, hwnd)
            }
        }
        if WinWaitClose(hwnd, , 2) {
            Log("PROMPT      answered " answer " (" how "): " SubStr(text, 1, 120))
            return text
        }
    }
    Log("PROMPT      couldn't press " answer " on: " SubStr(text, 1, 120))
    return "FAILED"
}

; Leaving Ultimate: first prompt confirms the switch (Yes). If a second
; "restart now" prompt follows, answer No because we restart or shut down ourselves.
AnswerGHelperPrompts() {
    first := PressGHelperPrompt("Yes", 6)
    if (first = "") {
        Log("PROMPT      no G-Helper prompt appeared")
        return
    }
    if RegExMatch(first, "i)reboot now|restart now")      ; it was already the restart question
        return
    if (PressGHelperPrompt("No", 4) = "")
        Log("PROMPT      no second prompt")
}

; Profiles back to the three defaults for this engine. Custom profiles are
; removed; the active profile stays if it's one of the defaults.
RestoreDefaultProfiles() {
    for id in profileOrder
        if !InArr(["everyday", "gaming", "travel"], id) {
            DisableSchedulesFor(id)
            try IniDelete(STATE, "profile." id)
        }
    for id in ["everyday", "gaming", "travel"]
        try IniDelete(STATE, "profile." id)
    try IniDelete(STATE, "profiles", "order")
    keep := profile
    if !InArr(["everyday", "gaming", "travel"], keep)
        keep := "everyday"
    try IniDelete(STATE, "app", "profile")
    LoadProfiles()                      ; recreates the defaults
    SetProfile(keep)
    Log("PROFILES    restored the default profiles")
    SetTimer(EnforceState.Bind(true), -200)
}

; ====================================================================
;  PROFILES WINDOW (Tray > Profiles)
; ====================================================================
ShowProfiles(*) {
    static open := 0
    if open {
        try WinActivate("ahk_id " open)
        return
    }
    g := Gui("+AlwaysOnTop", "Performance Companion profiles")
    open := g.Hwnd
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 16, g.MarginY := 12
    cur := ""            ; id shown on the right
    dirty := false
    loading := false

    iconNames := ["Blue laptop", "Red lightning bolt", "Teal battery", "Purple star"]
    gpuNames := ["Optimized: Eco on battery, Standard plugged in", "Ultimate: NVIDIA straight to the screen (fastest)",
                 "Standard: both GPUs, always", "Eco: NVIDIA off, always (longest battery)"]
    gamesNames := ["Off", "When plugged in", "Always, including battery"]
    capNames := ["No limit (each app's own mode)", ModeName(0) " at most", ModeName(2) " for everything"]
    lvlIds := [1, 0, 2], lvlNames := [ModeName(1), ModeName(0), ModeName(2)]
    gh := HasGH()
    adv := AdvancedUI()
    gpuDdl := 0, chSl := 0, chTx := 0, afterDdl := 0, iconDdl := 0, capDdl := 0, closeEd := 0, launchEd := 0
    afterNames := ["Restart only if the GPU change needs it", "Always shut down after switching (pack and go)"]

    g.Add("Text", "xm w700", "Each profile is a full set of performance settings. Switch from the tray, the Start menu (Performance Companion profiles), "
        . "Ctrl+Win+Alt+T, or a schedule. Hover anything for help.")
    advCb := g.Add("Checkbox", "xm y+8", "Show advanced options")
    advCb.Value := adv
    AddTip(advCb, "Adds the tray icon, game mode limit, " (gh ? "what happens after switching, " : "")
        . "apps to open or close when switching,`nreordering, and restoring the default profiles.")
    advCb.OnEvent("Click", (*) => ToggleAdv())
    g.SetFont("s10 bold c1B5E20")
    activeTx := g.Add("Text", "xm y+10 w180", "")
    g.SetFont("s10 norm cDefault")
    AddTip(activeTx, "The profile the laptop is in right now.")
    lb := g.Add("ListBox", "xm y+4 w180 r" (adv ? 18 : 11) " Section")
    AddTip(lb, "Your profiles, in the order they appear in the tray menu.`n"
        . "The active one has a green dot. Pick any profile to edit it on the right.")
    lb.OnEvent("Change", (*) => Picked())

    X := " x216 "
    Lbl(text, tip, first := false) {
        t := g.Add("Text", X (first ? "ys+3" : "y+12") " w170", text)
        AddTip(t, tip)
        return t
    }
    Changed(*) {
        if !loading
            dirty := true
        UpdatePreview()
    }

    tipName := "Shown in the tray menu and on-screen messages."
    Lbl("Name", tipName, true)
    nameEd := g.Add("Edit", "x+4 yp-3 w300")
    AddTip(nameEd, tipName), nameEd.OnEvent("Change", Changed)

    tipIcon := "Tray icon while this profile is active, so you can tell at a glance."
    if adv {
        Lbl("Tray icon", tipIcon)
        iconDdl := g.Add("DropDownList", "x+4 yp-3 w300", iconNames)
        AddTip(iconDdl, tipIcon), iconDdl.OnEvent("Change", Changed)
    }

    tipGpu := "Optimized: NVIDIA off on battery for runtime, on when plugged in. No restart to switch.`n"
        . "Ultimate: NVIDIA wired straight to the screen. Often 20-30% faster in games,`n"
        . "  but the NVIDIA GPU stays on, even on battery. Entering or leaving Ultimate restarts the laptop.`n"
        . "Standard: both GPUs, apps pick (Windows decides which). Eco: NVIDIA always off."
    if gh {
        Lbl("GPU", tipGpu)
        gpuDdl := g.Add("DropDownList", "x+4 yp-3 w300", gpuNames)
        AddTip(gpuDdl, tipGpu), gpuDdl.OnEvent("Change", Changed)
    }

    tipCharge := "Highest charge the battery reaches. 80% is gentler on a battery that's usually plugged in;`n"
        . "100% gives the most runtime. Some models only accept 60, 80 or 100."
    if gh {
        Lbl("Charge limit", tipCharge)
        chSl := g.Add("Slider", "x+4 yp-4 w230 Range40-100 TickInterval10 Line5 Page10 ToolTip", 80)
        chTx := g.Add("Text", "x+6 yp+4 w60", "80%")
        AddTip(chSl, tipCharge)
        chSl.OnEvent("Change", (c, *) => (chTx.Value := Round(c.Value / 5) * 5 "%", Changed()))
    }

    tipBat := "Mode on battery when no game or listed app is running.`n" ModeName(2) " stretches the battery furthest; " ModeName(0) " feels snappier."
    Lbl("On battery", tipBat)
    batDdl := g.Add("DropDownList", "x+4 yp-3 w150", lvlNames)
    AddTip(batDdl, tipBat), batDdl.OnEvent("Change", Changed)

    tipAc := "Mode plugged in when no game or listed app is running.`n" ModeName(0) " is the usual choice; " ModeName(2) " keeps the fans down for calls or late nights;`n"
        . ModeName(1) " keeps everything at full speed all the time."
    Lbl("Plugged in", tipAc)
    acDdl := g.Add("DropDownList", "x+4 yp-3 w150", lvlNames)
    AddTip(acDdl, tipAc), acDdl.OnEvent("Change", Changed)

    tipGames := "When games and listed apps get their own mode (" ModeName(DEFAULT_GAME_MODE) " by default, or whatever you set per app).`n"
        . "Off: everything runs in the 'no game' mode above.`n"
        . "When plugged in: the usual choice.`n"
        . "Always: also on battery (" ModeName(1) " drains it fast)."
    Lbl("Game modes", tipGames)
    gamesDdl := g.Add("DropDownList", "x+4 yp-3 w300", gamesNames)
    AddTip(gamesDdl, tipGames), gamesDdl.OnEvent("Change", Changed)

    tipCap := "Upper limit on game modes in this profile, whatever each game asks for.`n"
        . "Example: a hotel-room or late-night profile that never goes louder than " ModeName(0) "."
    if adv {
        Lbl("Max power for games", tipCap)
        capDdl := g.Add("DropDownList", "x+4 yp-3 w300", capNames)
        AddTip(capDdl, tipCap), capDdl.OnEvent("Change", Changed)
    }

    tipAfter := "Restart only if needed: Eco / Standard / Optimized switch instantly; only entering or`n"
        . "leaving Ultimate restarts.`n"
        . "Always shut down: for a travel profile. Switch, the laptop powers off, pack it,`n"
        . "and it boots ready on the road. (Entering Ultimate always restarts instead.)"
    if (gh && adv) {
        Lbl("After switching to it", tipAfter)
        afterDdl := g.Add("DropDownList", "x+4 yp-3 w300", afterNames)
        AddTip(afterDdl, tipAfter), afterDdl.OnEvent("Change", Changed)
    }

    tipClose := "Programs to close when you switch to this profile, by exe name, separated by commas.`n"
        . "Example for Travel: steam.exe, battle.net.exe. They're asked to close like clicking X,`n"
        . "so they can save first. Skipped when the switch restarts the laptop anyway."
    if adv {
        Lbl("Close these apps", tipClose)
        closeEd := g.Add("Edit", "x+4 yp-3 w300")
        DllCall("SendMessage", "Ptr", closeEd.Hwnd, "UInt", 0x1501, "Ptr", 1, "WStr", "e.g. steam.exe, discord.exe")   ; grey hint in the empty box
        g.SetFont("s9 cGray")
        g.Add("Text", "xp y+2 w380", "Closed when you switch to this profile. Separate with commas.")
        g.SetFont("s10 norm cDefault")
        AddTip(closeEd, tipClose), closeEd.OnEvent("Change", Changed)

        tipLaunch := "Programs, shortcuts or web links to open when you switch to this profile, one per line.`n"
            . "Example: Steam and Discord for Gaming. After a restart they open once you're back in Windows."
        Lbl("Open these apps", tipLaunch)
        launchEd := g.Add("Edit", "x+4 yp-3 w300 r3 -Wrap HScroll")
        AddTip(launchEd, tipLaunch), launchEd.OnEvent("Change", Changed)
        br := g.Add("Button", "xp y+4 w90", "Browse...")
        g.SetFont("s9 cGray")
        g.Add("Text", "x+8 yp+4 w300", "Opened when you switch to this profile. One per line.")
        g.SetFont("s10 norm cDefault")
        br.OnEvent("Click", (*) => Browse())
        AddTip(br, "Pick a program or shortcut to add to the list.")
    }

    preview := g.Add("Text", X "y+12 w480 r2 cGray", "")

    ; ---------- buttons ----------
    b := g.Add("Button", "xm y+14 w80", "New")
    b.OnEvent("Click", (*) => NewProfile(false))
    AddTip(b, "Add a profile with sensible starting settings (Optimized GPU, 80%).")
    b := g.Add("Button", "x+6 w90", "Duplicate")
    b.OnEvent("Click", (*) => NewProfile(true))
    AddTip(b, "Copy the selected profile as a starting point.")
    b := g.Add("Button", "x+6 w80", "Delete")
    b.OnEvent("Click", (*) => DeleteProfile())
    AddTip(b, "Delete the selected profile. The active profile can't be deleted;`nswitch to another one first. Schedules that used it are turned off.")
    if adv {
        b := g.Add("Button", "x+6 w80", "Move up")
        b.OnEvent("Click", (*) => MoveProfile(-1))
        AddTip(b, "Move up in the tray menu.")
        b := g.Add("Button", "x+4 w90", "Move down")
        b.OnEvent("Click", (*) => MoveProfile(1))
        AddTip(b, "Move down in the tray menu.")
        b := g.Add("Button", "x+4 w130", "Restore defaults")
        b.OnEvent("Click", (*) => RestoreDefaults())
        AddTip(b, "Replace all profiles with the three defaults (" (gh ? "Work, Gaming, Travel" : "Work, Gaming, Long Battery") ").`n"
            . "Your games, settings and schedules stay; schedules that used a removed profile are turned off.")
    }
    b := g.Add("Button", "x+18 w100", "Switch to it")
    b.OnEvent("Click", (*) => SwitchNow())
    AddTip(b, "Save, then switch to the selected profile (asks first if it restarts or shuts down).")
    b := g.Add("Button", "x+6 w80 Default", "Save")
    b.OnEvent("Click", (*) => Save())
    AddTip(b, "Save changes to the selected profile. If it's the active profile,`nthe changes apply right away (a charge limit change restarts G-Helper for a few seconds).")
    b := g.Add("Button", "x+6 w80", "Close")
    b.OnEvent("Click", (*) => CloseWin())
    AddTip(b, "Close this window (asks about unsaved changes).")
    g.OnEvent("Close", (*) => (CloseWin(), 1))
    g.OnEvent("Escape", (*) => CloseWin())

    FillList()
    Load(profile)
    g.Show()

    ; ---------- helpers ----------
    FillList() {
        lb.Delete()
        items := []
        for id in profileOrder
            items.Push((id = profile ? "● " : "     ") profiles[id].name)
        activeTx.Value := "● Active: " CurP().name
        lb.Add(items)
    }

    Load(id) {
        loading := true
        cur := id
        p := profiles[id]
        lb.Choose(IndexOf(profileOrder, id))
        nameEd.Value := p.name
        if iconDdl
            iconDdl.Choose(IndexOf(ProfileIcons(), p.icon))
        if gh {
            gpuDdl.Choose(IndexOf(ProfileGpus(), p.gpu))
            chSl.Value := p.charge, chTx.Value := p.charge "%"
            if afterDdl
                afterDdl.Choose(IndexOf(ProfileAfters(), p.after))
        }
        batDdl.Choose(IndexOf(lvlIds, p.battery))
        acDdl.Choose(IndexOf(lvlIds, p.ac))
        gamesDdl.Choose(IndexOf(ProfileGames(), p.games))
        if adv {
            capDdl.Choose(IndexOf(ProfileCaps(), p.cap))
            launchEd.Value := StrReplace(p.launch, "|", "`r`n")
            closeEd.Value := StrReplace(p.close, "|", ", ")
        }
        dirty := false
        loading := false
        UpdatePreview()
    }

    ; Reads the form into a profile object (not saved yet).
    FromForm() {
        old := profiles.Has(cur) ? profiles[cur] : NewProfileObj("", "custom", "auto", 80, 2, 0, "ac", "none", "auto")
        p := NewProfileObj(Trim(nameEd.Value), iconDdl ? ProfileIcons()[iconDdl.Value] : old.icon, gh ? ProfileGpus()[gpuDdl.Value] : old.gpu,
            gh ? Round(chSl.Value / 5) * 5 : old.charge, lvlIds[batDdl.Value], lvlIds[acDdl.Value],
            ProfileGames()[gamesDdl.Value], capDdl ? ProfileCaps()[capDdl.Value] : old.cap, afterDdl ? ProfileAfters()[afterDdl.Value] : old.after)
        p.id := cur
        if !adv {
            p.launch := old.launch, p.close := old.close
            return p
        }
        lines := []
        for x in StrSplit(launchEd.Value, "`n", "`r")
            if (Trim(x) != "")
                lines.Push(Trim(x))
        p.launch := Join(lines)
        names := []
        for x in StrSplit(closeEd.Value, [",", "|", ";"])
            if (Trim(x) != "")
                names.Push(Trim(x))
        p.close := Join(names)
        return p
    }

    UpdatePreview() {
        if (cur = "")
            return
        p := FromForm()
        if !gh {
            preview.Value := (cur = profile) ? "This is the active profile. Saving applies the changes now."
                : "Switching here from " CurP().name " is instant."
        } else if (cur = profile) {
            preview.Value := "This is the active profile. Saving applies the changes now."
                . (p.gpu = "ultimate" && GetJsonInt(ReadCfg(), "gpu_mode") != 2 ? "`nThe GPU change needs a restart: Tray > Finish switching." :
                   p.gpu != "ultimate" && GetJsonInt(ReadCfg(), "gpu_mode") = 2 ? "`nLeaving Ultimate needs a restart: Tray > Finish switching." : "")
        } else {
            gm := GetJsonInt(ReadCfg(), "gpu_mode")
            reboot := (gm != "") && ((p.gpu = "ultimate") != (gm = 2))
            ending := reboot ? ((p.gpu = "ultimate" || p.after != "shutdown") ? "restarts" : "shuts down")
                : (p.after = "shutdown" ? "shuts down" : "switches instantly, no restart")
            preview.Value := "Switching here from " CurP().name ": the laptop " ending "."
        }
    }

    ; Saves the form. Returns false if something needs fixing first.
    Save() {
        if (cur = "")
            return true
        p := FromForm()
        if (p.name = "") {
            MsgBox("Give the profile a name.", "Performance Companion profiles", "Icon!")
            return false
        }
        p.name := UniqueProfileName(p.name, cur)
        old := profiles[cur]
        profiles[cur] := p
        WriteProfile(p)
        Log("PROFILES    saved " p.name ": " GpuLabel(p.gpu) ", " p.charge "%, battery " ModeName(p.battery)
            ", AC " ModeName(p.ac) ", games " p.games ", cap " p.cap ", after " p.after)
        dirty := false
        FillList()
        Load(cur)
        if (cur = profile) {
            UpdateUI()
            SetTimer(EnforceState, -200)
            if (old.gpu != p.gpu && ProfileMismatch())
                ShowOSD(p.name ": GPU change needs a restart. Tray > Finish switching.", "Blue", true)
            else
                ShowOSD(p.name " saved and applied", "Green", true)
        } else {
            UpdateUI()
            ShowOSD(p.name " saved", "Green", true)
        }
        return true
    }

    ; Unsaved changes: Yes saves, No discards, Cancel stays. Returns false on Cancel.
    AskSave() {
        if !dirty
            return true
        r := MsgBox("Save changes to " profiles[cur].name "?", "Performance Companion profiles", "YesNoCancel Icon? Owner" g.Hwnd)
        if (r = "Cancel")
            return false
        if (r = "Yes")
            return Save()
        dirty := false
        return true
    }

    Picked() {
        i := lb.Value
        if (!i || profileOrder[i] = cur)
            return
        if !AskSave() {
            lb.Choose(IndexOf(profileOrder, cur))
            return
        }
        Load(profileOrder[i])
    }

    NewProfile(copy) {
        if !AskSave()
            return
        src := profiles[cur]
        if copy {
            p := NewProfileObj(src.name " copy", src.icon, src.gpu, src.charge, src.battery, src.ac, src.games, src.cap, src.after)
            p.launch := src.launch, p.close := src.close
        } else {
            p := NewProfileObj("New profile", "custom", "auto", 80, 2, 0, "ac", "none", "auto")
        }
        p.id := UniqueProfileId()
        p.name := UniqueProfileName(p.name)
        profiles[p.id] := p
        profileOrder.InsertAt(IndexOf(profileOrder, cur) + 1, p.id)
        WriteProfile(p)
        SaveProfileOrder()
        Log("PROFILES    added " p.name (copy ? " (copy of " src.name ")" : ""))
        FillList()
        Load(p.id)
        UpdateUI()
        nameEd.Focus()
    }

    DeleteProfile() {
        if (cur = profile) {
            MsgBox(profiles[cur].name " is the active profile. Switch to another profile first, then delete it.",
                "Performance Companion profiles", "Iconi Owner" g.Hwnd)
            return
        }
        p := profiles[cur]
        if (MsgBox("Delete the " p.name " profile?", "Performance Companion profiles", "YesNo Icon? Owner" g.Hwnd) != "Yes")
            return
        n := DisableSchedulesFor(cur)
        profiles.Delete(cur)
        profileOrder.RemoveAt(IndexOf(profileOrder, cur))
        try IniDelete(STATE, "profile." cur)
        SaveProfileOrder()
        Log("PROFILES    deleted " p.name (n ? "; turned off " n " schedule(s) that used it" : ""))
        if n
            MsgBox(n " schedule(s) used " p.name " and have been turned off. Tray > Schedules to point them at another profile.",
                "Performance Companion profiles", "Iconi Owner" g.Hwnd)
        dirty := false
        FillList()
        Load(profile)
        UpdateUI()
    }

    MoveProfile(dir) {
        i := IndexOf(profileOrder, cur), j := i + dir
        if (j < 1 || j > profileOrder.Length)
            return
        t := profileOrder[i], profileOrder[i] := profileOrder[j], profileOrder[j] := t
        SaveProfileOrder()
        FillList()
        lb.Choose(j)
        UpdateUI()
    }

    Browse() {
        g.Opt("-AlwaysOnTop")
        f := FileSelect(1, A_ProgramFiles, "Choose a program or shortcut to open", "Programs and shortcuts (*.exe; *.lnk; *.url; *.bat)")
        g.Opt("+AlwaysOnTop")
        if (f = "")
            return
        launchEd.Value := RTrim(launchEd.Value, "`r`n") (launchEd.Value = "" ? "" : "`r`n") f
        Changed()
    }

    SwitchNow() {
        if (dirty && !Save())
            return
        id := cur
        if (id = profile) {
            if ProfileMismatch()
                FinishSwitch()
            else
                ShowOSD(profiles[id].name " is already active", "Blue", true)
            return
        }
        CloseWin()
        SwitchToProfile(id, "manual")
    }

    ToggleAdv() {
        if !AskSave() {
            advCb.Value := adv
            return
        }
        SetAdvancedUI(advCb.Value)
        open := 0
        ClearTips(g)
        g.Destroy()
        ShowProfiles()
    }

    RestoreDefaults() {
        if (MsgBox("Replace all profiles with the three defaults?`n`nYour games, settings and schedules stay. "
            . "Schedules that used a removed profile are turned off.", "Performance Companion profiles", "YesNo Icon? Owner" g.Hwnd) != "Yes")
            return
        RestoreDefaultProfiles()
        dirty := false
        FillList()
        Load(profile)
    }

    CloseWin() {
        if !AskSave()
            return
        open := 0
        ClearTips(g)
        g.Destroy()
    }
}

; ====================================================================
;  SCHEDULES
;  Timed profile switches, stored as [schedule.<id>] in state.ini.
;
;    type      weekly | once | trip
;    enabled   0 / 1 (every schedule ships off; so does the master switch)
;    name      shown in warnings and the log
;    profile   profile to switch to
;    days      weekly: weekdays, comma separated, 1 = Sunday ... 7 = Saturday
;    every     weekly: 1 every week, 2 every other week (counted from anchor)
;    anchor    weekly: yyyyMMdd of a Sunday that starts an "on" week
;    date      once / trip: yyyyMMdd
;    time      HHmm (trip: departure time)
;    end_on    weekly: 1 = switch back later
;    end_time  weekly: HHmm (earlier than time = next day)
;    back      weekly: profile to switch back to
;    before    trip: minutes before departure to switch (0 = only charge)
;    last_start, last_end, last_charge: timestamps already handled
;
;  Rules: restarts and shutdowns are warned WARN_MINUTES and 2 minutes
;  ahead (Snooze / Skip / Switch now), never happen while a game is
;  running, and a switch missed while the laptop was off is offered as a
;  catch-up instead of happening by surprise. Trips raise the charge limit
;  early enough to be full at departure.
; ====================================================================
NewSchedObj(type) {
    now := A_Now
    return {id: "", type: type, enabled: 0, name: "", profile: "", days: "", every: 1,
        anchor: WeekStart(now), date: SubStr(now, 1, 8), time: "1900", end_on: 0, end_time: "2330",
        back: "", before: 15, last_start: now, last_end: now, last_charge: ""}
}

SchedKeys() => ["type", "enabled", "name", "profile", "days", "every", "anchor", "date", "time",
    "end_on", "end_time", "back", "before", "last_start", "last_end", "last_charge"]

ReadSchedule(id) {
    sec := "schedule." id
    s := NewSchedObj(IniRead(STATE, sec, "type", "weekly"))
    for k in SchedKeys()
        s.%k% := IniRead(STATE, sec, k, s.%k%)
    s.id := id
    s.type := PickOf(s.type, ["weekly", "monthly", "once", "trip"], "weekly")
    s.enabled := (s.enabled = 1) ? 1 : 0
    s.end_on := (s.end_on = 1) ? 1 : 0
    s.every := (s.every = 2) ? 2 : 1
    s.before := IsInteger(s.before) ? Integer(s.before) : 15
    s.time := NormHM(s.time, "1900")
    s.end_time := NormHM(s.end_time, "2330")
    return s
}

NormHM(v, d) => RegExMatch(v, "^([01]\d|2[0-3])[0-5]\d$") ? v : d

WriteSchedule(s) {
    for k in SchedKeys()
        IniWrite(s.%k%, STATE, "schedule." s.id, k)
}

SaveSchedOrder() => IniWrite(Join(schedOrder), STATE, "schedules", "order")

LoadSchedules() {
    global schedules, schedOrder
    schedules := Map(), schedOrder := []
    if (IniRead(STATE, "schedules", "order", "!") = "!")
        CreateDefaultSchedules()
    for id in StrSplit(IniRead(STATE, "schedules", "order", ""), "|") {
        if (id = "" || schedules.Has(id))
            continue
        schedules[id] := ReadSchedule(id)
        schedOrder.Push(id)
    }
}

; Two examples, both switched off, ready to adjust and turn on:
;   Weekly gaming: Fridays 19:00 to Gaming, back to Work at 23:30.
;   Trip: a week from today, leaving at 07:00, charged to the Travel
;   limit and switched to Travel 15 minutes before.
CreateDefaultSchedules() {
    gn := NewSchedObj("weekly")
    gn.id := "gamenight", gn.name := "Weekly gaming", gn.profile := "gaming", gn.days := "6"
    gn.time := "1900", gn.end_on := 1, gn.end_time := "2330", gn.back := "everyday"
    tr := NewSchedObj("trip")
    tr.id := "trip", tr.name := "Trip", tr.profile := "travel"
    tr.date := SubStr(DateAdd(A_Now, 7, "Days"), 1, 8), tr.time := "0700", tr.before := 15
    gn.date := SubStr(A_Now, 1, 8)
    if (BACKEND = "ghelper") {
        for s in [gn, tr]
            WriteSchedule(s)
        IniWrite("gamenight|trip", STATE, "schedules", "order")
    } else {
        WriteSchedule(gn)
        IniWrite("gamenight", STATE, "schedules", "order")
    }
}

UniqueSchedId() {
    n := 1
    while schedules.Has("s" n)
        n++
    return "s" n
}

; Turning the master switch on starts the clock from now, so nothing that
; happened while schedules were off is treated as missed.
SetSchedulesEnabled(on, was) {
    SaveSetting("SCHEDULES_ENABLED", on ? 1 : 0)
    if (on && !was) {
        for id, s in schedules {
            s.last_start := A_Now, s.last_end := A_Now
            WriteSchedule(s)
        }
        Log("SCHEDULE    schedules turned on")
        SetTimer(ScheduleTick, -1000)
    } else if (!on && was) {
        CancelPending("schedules turned off")
        Log("SCHEDULE    schedules turned off")
    }
}

DisableSchedulesFor(profileId) {
    n := 0
    for id, s in schedules {
        if (s.profile = profileId || (s.end_on && s.back = profileId)) {
            if s.enabled
                n++
            s.enabled := 0
            if (s.profile = profileId)
                s.profile := ""
            if (s.back = profileId)
                s.back := "", s.end_on := 0
            WriteSchedule(s)
        }
    }
    return n
}

; ---------- date math (pure functions, unit-tested) ----------
DayStart(t) => SubStr(t, 1, 8) "000000"
WDayOf(t) => Integer(FormatTime(t, "WDay"))            ; 1 = Sunday
WeekStart(t) => SubStr(DateAdd(DayStart(t), -(WDayOf(t) - 1), "Days"), 1, 8)

; The moments a schedule acts at. Each trigger is either a fixed moment
; (at) or a weekly pattern (days + hm, shifted a day when it crosses midnight).
Triggers(s) {
    out := []
    endShift := (s.end_time <= s.time) ? 1 : 0           ; an end time earlier than the start = next day
    if (s.type = "weekly" || s.type = "monthly") {
        base := {at: "", hm: s.time, shift: 0, from: s.date}
        if (s.type = "weekly")
            base.days := s.days, base.every := s.every, base.anchor := s.anchor
        else
            base.dom := Integer(SubStr(s.date, 7, 2))
        if ((s.type = "monthly" || s.days != "") && profiles.Has(s.profile)) {
            t := CloneObj(base), t.kind := "start", t.profile := s.profile
            out.Push(t)
        }
        if (s.end_on && (s.type = "monthly" || s.days != "") && profiles.Has(s.back)) {
            t := CloneObj(base), t.kind := "end", t.hm := s.end_time, t.shift := endShift, t.profile := s.back
            out.Push(t)
        }
    } else if (s.type = "once") {
        if profiles.Has(s.profile)
            out.Push({kind: "start", at: s.date s.time "00", profile: s.profile})
        if (s.end_on && profiles.Has(s.back))
            out.Push({kind: "end", at: DateAdd(s.date s.end_time "00", endShift, "Days"), profile: s.back})
    } else if (s.type = "trip") {
        if (s.before > 0 && profiles.Has(s.profile))
            out.Push({kind: "start", at: DateAdd(s.date s.time "00", -s.before, "Minutes"), profile: s.profile})
    }
    return out
}

CloneObj(o) {
    c := {}
    for k, v in o.OwnProps()
        c.%k% := v
    return c
}

DaysInMonth(t) {
    first := SubStr(t, 1, 6) "01000000"
    nextFirst := DateAdd(first, 32, "Days")
    nextFirst := SubStr(nextFirst, 1, 6) "01000000"
    return DateDiff(nextFirst, first, "Days")
}

; The trigger's moment on a given day, or "" if it doesn't act that day.
OccOnDay(trig, day) {
    base := DateAdd(DayStart(day), -trig.shift, "Days")      ; the day the schedule "starts" on
    if (trig.HasOwnProp("from") && trig.from != "" && SubStr(base, 1, 8) < trig.from)
        return ""                                            ; before the schedule's start date
    if trig.HasOwnProp("dom") {
        if (Integer(SubStr(base, 7, 2)) != Min(trig.dom, DaysInMonth(base)))
            return ""
    } else {
        if !InStr("," trig.days ",", "," WDayOf(base) ",")
            return ""
        if (trig.every = 2) {
            weeks := Round(DateDiff(WeekStart(base) "000000", trig.anchor "000000", "Days") / 7)
            if Mod(Abs(weeks), 2)
                return ""
        }
    }
    return SubStr(DayStart(day), 1, 8) trig.hm "00"
}

; How far to search: two weeks for daily and weekly patterns, two months for monthly.
SearchDays(trig) => trig.HasOwnProp("dom") ? 64 : 16

; Latest occurrence at or before t, or "".
PrevOcc(trig, t) {
    if (trig.at != "")
        return (trig.at <= t) ? trig.at : ""
    Loop SearchDays(trig) {
        o := OccOnDay(trig, DateAdd(t, -(A_Index - 1), "Days"))
        if (o != "" && o <= t)
            return o
    }
    return ""
}

; First occurrence strictly after t, or "".
NextOcc(trig, t) {
    if (trig.at != "")
        return (trig.at > t) ? trig.at : ""
    Loop SearchDays(trig) {
        o := OccOnDay(trig, DateAdd(t, A_Index - 1, "Days"))
        if (o != "" && o > t)
            return o
    }
    return ""
}

; How late (minutes) a switch may still happen. An evening schedule with an
; end time is still worth starting until it ends; a trip until an hour
; after departure; anything else for 4 hours.
MaxLate(s, trig, occ) {
    if (s.type = "trip")
        return s.before + 60
    if (trig.kind = "start" && s.type != "trip" && s.end_on) {
        for t in Triggers(s)
            if (t.kind = "end" && (e := NextOcc(t, occ)) != "")
                return Max(0, DateDiff(e, occ, "Minutes") - 15)
    }
    return 240
}

; Next time a schedule will act, for display. "" if never again.
NextAction(s) {
    best := ""
    for t in Triggers(s)
        if ((o := NextOcc(t, A_Now)) != "" && (best = "" || o < best))
            best := o
    return best
}

; ---------- the engine (every 30 seconds) ----------
ScheduleTick(startup := false) {
    if (!SCHEDULES_ENABLED || switching || busy || paused)
        return
    TripChargeCheck()
    if IsObject(schedPending)
        return                                    ; one switch at a time; its own timer drives it
    now := A_Now
    for sid in schedOrder {
        s := schedules[sid]
        if !s.enabled
            continue
        for trig in Triggers(s) {
            last := (trig.kind = "end") ? s.last_end : s.last_start
            plan := SwitchPlan(trig.profile)
            lead := (plan.ending != "none") ? WARN_MINUTES : 0
            occ := PrevOcc(trig, DateAdd(now, lead, "Minutes"))
            if (occ = "" || (last != "" && occ <= last))
                continue
            late := DateDiff(now, occ, "Minutes")
            if (late > MaxLate(s, trig, occ)) {
                MarkDone(s, trig.kind, occ, "missed " s.name " (" FormatTime(occ, "ddd HH:mm") "), too late to catch up")
                continue
            }
            if (trig.profile = profile && !ProfileMismatch()) {
                MarkDone(s, trig.kind, occ, s.name ": already in " CurP().name)
                continue
            }
            BeginScheduled(s, trig, occ, plan, startup || late > 2)
            return
        }
    }
}

MarkDone(s, kind, occ, why := "") {
    if (kind = "end")
        s.last_end := occ
    else if (kind = "charge")
        s.last_charge := occ
    else
        s.last_start := occ
    IniWrite(occ, STATE, "schedule." s.id, "last_" kind)
    if (why != "")
        Log("SCHEDULE    " why)
}

BeginScheduled(s, trig, occ, plan, catchUp) {
    global schedPending
    p := profiles[trig.profile]
    sp := {sid: s.id, kind: trig.kind, occ: occ, due: occ, profile: trig.profile, gui: 0, text: 0,
        warned2: false, hidden: false, force: false, waitingGame: false}
    if catchUp && (plan.ending != "none") {
        MarkDone(s, trig.kind, occ)
        r := MsgBox(s.name " was set to switch to " p.name " at " FormatTime(occ, "ddd HH:mm")
            . ", but the laptop was off or asleep.`n`nSwitch to " p.name " now? The laptop will "
            . EndingWord(plan.ending) ". Save your work first.`n`n(No answer in 5 minutes counts as No.)",
            "Performance Companion schedule", "YesNo Icon? T300")
        if (r != "Yes") {
            Log("SCHEDULE    " s.name ": catch-up declined (" r ")")
            return
        }
        Log("SCHEDULE    " s.name ": catch-up accepted")
        sp.due := A_Now, sp.force := true
    } else {
        Log("SCHEDULE    " s.name ": " (trig.kind = "end" ? "back to " : "switch to ") p.name " at "
            FormatTime(occ, "HH:mm") " (" EndingWord(plan.ending) ")")
    }
    schedPending := sp
    SetTimer(SchedCountdown, 1000)
    SchedCountdown()
}

CancelPending(why) {
    global schedPending
    if !IsObject(schedPending)
        return
    SetTimer(SchedCountdown, 0)
    CloseWarning()
    Log("SCHEDULE    pending switch cancelled (" why ")")
    schedPending := ""
}

; Every second while a scheduled switch is pending.
SchedCountdown() {
    global schedPending
    sp := schedPending
    if !IsObject(sp) {
        SetTimer(SchedCountdown, 0)
        return
    }
    if !schedules.Has(sp.sid) || !profiles.Has(sp.profile) {
        CancelPending("schedule or profile deleted")
        return
    }
    s := schedules[sp.sid], p := profiles[sp.profile]
    plan := SwitchPlan(sp.profile)
    left := DateDiff(sp.due, A_Now, "Seconds")

    if (left > 0) {
        if (plan.ending != "none") {
            if (!sp.gui && !sp.hidden && left <= WARN_MINUTES * 60 + 5)
                ShowWarning(sp)
            if (!sp.warned2 && left <= 120) {
                sp.warned2 := true
                if !sp.gui
                    ShowWarning(sp)
                try WinActivate("ahk_id " sp.gui.Hwnd)
                ShowOSD(s.name ": " p.name " in 2 minutes. The laptop will " EndingWord(plan.ending) ".", "Red", true)
            }
            if sp.gui
                sp.text.Value := WarningText(s, p, plan, left)
        }
        return
    }

    ; Due. Never in the middle of a game, unless you pressed Switch now.
    if (!sp.force && GameActive()) {
        if !sp.waitingGame
            Log("SCHEDULE    " s.name ": game running, waiting for it to finish")
        sp.waitingGame := true
        sp.due := DateAdd(A_Now, 5, "Minutes")
        sp.warned2 := true                       ; no 2-minute nag while waiting on a game
        if sp.gui
            sp.text.Value := "Waiting for your game to finish. Checking again every 5 minutes.`n" WarningText(s, p, plan, 300)
        return
    }
    SetTimer(SchedCountdown, 0)
    CloseWarning()
    schedPending := ""
    MarkDone(s, sp.kind, sp.occ)
    if (sp.profile = profile && !ProfileMismatch()) {
        Log("SCHEDULE    " s.name ": already in " p.name)
        return
    }
    if (plan.ending != "none" && !HandsOffCountdown(p.name, plan.ending)) {
        Log("SCHEDULE    " s.name ": cancelled at the last moment")
        return
    }
    Log("SCHEDULE    " s.name ": switching to " p.name)
    if (s.type = "trip")
        ClearChargeOverride("trip switch")
    DoSwitch(sp.profile, SwitchPlan(sp.profile), "schedule " s.name)
}

GameActive() {
    if (isTurboMode || manualOverride = "Turbo")
        return true
    try {
        if (CheckPassiveGamingState() != false)
            return true
    }
    return false
}

WarningText(s, p, plan, left) {
    mm := left // 60, ss := Mod(left, 60)
    return "At " FormatTime(schedPending.due, "HH:mm") " (in " mm ":" Format("{:02}", ss) ") "
        . (plan.ending = "none" ? "Performance Companion switches to " : "the laptop will " EndingWord(plan.ending) " into ")
        . p.name " (" ProfileSummary(p) ")."
}

OpenAppNames() {
    seen := Map(), out := []
    skip := ["explorer.exe", "ApplicationFrameHost.exe", "TextInputHost.exe", "SystemSettings.exe", "ShellExperienceHost.exe",
        "StartMenuExperienceHost.exe", "SearchHost.exe", "GHelper.exe", "AutoHotkey64.exe", "AutoHotkey32.exe", "AutoHotkey.exe"]
    for h in WinGetList() {
        try {
            if !(WinGetStyle(h) & 0x10000000) || WinGetTitle(h) = "" || (WinGetExStyle(h) & 0x80)
                continue
            exe := WinGetProcessName(h)
            if (seen.Has(exe) || InArr(skip, exe))
                continue
            seen[exe] := 1
            out.Push(RegExReplace(exe, "i)\.exe$"))
        }
    }
    return out
}

ShowWarning(sp) {
    s := schedules[sp.sid], p := profiles[sp.profile]
    plan := SwitchPlan(sp.profile)
    g := Gui("+AlwaysOnTop -MinimizeBox", "Performance Companion schedule")
    g.MarginX := 20, g.MarginY := 16
    g.SetFont("s13 bold", "Segoe UI")
    g.Add("Text", "w500", s.name ": switching to " p.name)
    g.SetFont("s10 norm", "Segoe UI")
    sp.text := g.Add("Text", "w500 y+8 r2", WarningText(s, p, plan, Max(0, DateDiff(sp.due, A_Now, "Seconds"))))
    apps := OpenAppNames()
    if apps.Length {
        list := ""
        for i, a in apps
            if (i <= 10)
                list .= (i = 1 ? "" : ", ") a
        g.Add("Text", "w500 y+8", "Open now: " list (apps.Length > 10 ? " and " apps.Length - 10 " more" : "")
            . ". Save anything unsaved.")
    }
    g.SetFont("s9 cGray")
    g.Add("Text", "w500 y+8", "Tip: Windows can reopen your apps after a restart: Settings > Accounts > Sign-in options > "
        . "'Automatically save my restartable apps'. Games are never interrupted; the switch waits for them.")
    g.SetFont("s10 norm cDefault")
    b1 := g.Add("Button", "w110 y+14", "Switch now")
    b2 := g.Add("Button", "x+8 w130", "Snooze 30 min")
    b3 := g.Add("Button", "x+8 w90", "Skip")
    AddTip(b1, "Switch right away.")
    AddTip(b2, "Ask again in 30 minutes.")
    AddTip(b3, "Don't switch this time. Repeating schedules run again next time as usual.")
    b1.OnEvent("Click", (*) => Act("now"))
    b2.OnEvent("Click", (*) => Act("postpone"))
    b3.OnEvent("Click", (*) => Act("skip"))
    g.OnEvent("Close", (*) => Act("hide"))
    sp.gui := g
    g.Show("NoActivate")
    SoundBeep(880, 120)

    Act(what) {
        global schedPending
        if !IsObject(schedPending)
            return
        switch what {
            case "now":
                schedPending.due := A_Now, schedPending.force := true
                CloseWarning()
                SchedCountdown()
            case "postpone":
                schedPending.due := DateAdd(A_Now, 30, "Minutes"), schedPending.warned2 := false, schedPending.hidden := false
                Log("SCHEDULE    " s.name ": snoozed until " FormatTime(schedPending.due, "HH:mm"))
                CloseWarning()
                ShowOSD(s.name ": snoozed until " FormatTime(schedPending.due, "HH:mm"), "Blue", true)
            case "skip":
                MarkDone(s, schedPending.kind, schedPending.occ, s.name ": skipped this time")
                CancelPending("skipped")
                ShowOSD(s.name ": skipped", "Blue", true)
            case "hide":
                schedPending.hidden := true
                CloseWarning()                    ; it comes back 2 minutes before
        }
    }
}

CloseWarning() {
    if (IsObject(schedPending) && schedPending.gui) {
        try {
            ClearTips(schedPending.gui)
            schedPending.gui.Destroy()
        }
        schedPending.gui := 0
    }
}

; Last 10 seconds before a scheduled restart or shutdown: a big hands-off
; notice with a Cancel button. Returns false if cancelled.
HandsOffCountdown(name, ending, secs := 10) {
    st := {cancel: false}
    g := Gui("+AlwaysOnTop -MinimizeBox -SysMenu", "Performance Companion")
    g.MarginX := 20, g.MarginY := 16
    g.SetFont("s14 bold cB71C1C", "Segoe UI")
    t := g.Add("Text", "w480 r3", "")
    g.SetFont("s10 norm cDefault", "Segoe UI")
    g.Add("Text", "w480 y+8", "Performance Companion clicks G-Helper's buttons for you; a moving mouse can interrupt it.")
    b := g.Add("Button", "w100 y+14", "Cancel")
    b.OnEvent("Click", (*) => st.cancel := true)
    g.Show()
    Loop secs {
        t.Value := "Switching to " name " in " (secs - A_Index + 1) "s. Don't touch the mouse or keyboard until the laptop "
            . (ending = "shutdown" ? "shuts down" : "restarts") "."
        Sleep(1000)
        if st.cancel
            break
    }
    g.Destroy()
    return !st.cancel
}

; ---------- trips: charge up ahead of departure ----------
TripChargeCheck() {
    static lastNag := 0
    if !HasGH()
        return                                    ; charge limits need G-Helper
    now := A_Now
    for sid in schedOrder {
        s := schedules[sid]
        if (!s.enabled || s.type != "trip")
            continue
        dep := s.date s.time "00"
        if (now >= dep || s.last_charge = dep)
            continue
        target := profiles.Has(s.profile) ? profiles[s.profile].charge : 100
        lead := TripLeadMinutes(target, BatteryPct(), ChargeRate())
        if (DateDiff(dep, now, "Minutes") > lead)
            continue
        MarkDone(s, "charge", dep, s.name ": charging to " target "% for departure " FormatTime(dep, "ddd HH:mm")
            " (" lead " min ahead, battery " BatteryPct() "%, rate " ChargeRate() "%/h)")
        IniWrite(target, STATE, "app", "charge_override")
        IniWrite(DateAdd(dep, 120, "Minutes"), STATE, "app", "charge_override_until")
        msg := s.name ": charging to " target "% for " FormatTime(dep, "HH:mm") "." (OnAC() ? "" : " Plug in now.")
        ShowOSD(msg, OnAC() ? "Blue" : "Red", true)
        try TrayTip(msg, "Performance Companion", "Iconi")
        lastNag := A_TickCount
        SetTimer(EnforceState, -200)
    }
    ; While a trip is charging and the laptop is unplugged, remind every 15 minutes.
    if (IniRead(STATE, "app", "charge_override", "") != "" && !OnAC() && BatteryPct() < WantCharge()
        && A_TickCount - lastNag > 900000) {
        lastNag := A_TickCount
        ShowOSD("Trip coming up: plug in to charge to " WantCharge() "%", "Red", true)
    }
}

; Minutes of charging needed, plus a 20 minute buffer, at least 30, at most 6 hours.
TripLeadMinutes(target, pct, rate) => Max(30, Min(360, Round(Max(0, target - pct) / Max(5, rate) * 60) + 20))

BatteryPct() {
    sps := Buffer(12, 0)
    DllCall("GetSystemPowerStatus", "Ptr", sps)
    v := NumGet(sps, 2, "UChar")
    return (v = 255) ? 50 : v
}

ChargeRate() {
    v := IniRead(STATE, "app", "charge_rate", 50)
    return IsNumber(v) ? Number(v) : 50
}

; Learns how fast this laptop charges (%/hour), so trips start early enough.
ChargeRateSample() {
    static lastPct := "", lastT := 0
    sps := Buffer(12, 0)
    DllCall("GetSystemPowerStatus", "Ptr", sps)
    ac := NumGet(sps, 0, "UChar") = 1
    flag := NumGet(sps, 1, "UChar"), pct := NumGet(sps, 2, "UChar")
    if (!ac || !(flag & 8) || pct >= 95 || pct = 255) {
        lastPct := ""
        return
    }
    if (lastPct = "") {
        lastPct := pct, lastT := A_TickCount
        return
    }
    if (pct - lastPct >= 4) {
        rate := (pct - lastPct) / ((A_TickCount - lastT) / 3600000)
        if (rate > 5 && rate < 200) {
            nr := Round(ChargeRate() * 0.7 + rate * 0.3, 1)
            IniWrite(nr, STATE, "app", "charge_rate")
        }
        lastPct := pct, lastT := A_TickCount
    } else if (pct < lastPct) {
        lastPct := pct, lastT := A_TickCount
    }
}

InArr(arr, v) {
    for x in arr
        if (x = v)
            return true
    return false
}
; ====================================================================
;  SCHEDULES WINDOW (Tray > Schedules)
;  Works like a calendar app: a schedule happens once or repeats (every
;  day, every weekday, weekly, every 2 weeks, monthly), switches to a
;  profile, and can switch back later. Trips are their own simple form.
; ====================================================================
DayOrder() => [2, 3, 4, 5, 6, 7, 1]                        ; Mon..Sun shown, WDay values stored
DayShort(d) => ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d]
HM(hm) => SubStr(hm, 1, 2) ":" SubStr(hm, 3, 2)
Ordinal(n) => n (Mod(n, 100) >= 11 && Mod(n, 100) <= 13 ? "th" : Mod(n, 10) = 1 ? "st" : Mod(n, 10) = 2 ? "nd" : Mod(n, 10) = 3 ? "rd" : "th")

DaysText(days) {
    set := "," days ","
    if (days = "2,3,4,5,6")
        return "Weekdays"
    if (days = "1,7" || days = "7,1")
        return "Weekends"
    out := []
    for d in DayOrder()
        if InStr(set, "," d ",")
            out.Push(DayShort(d))
    return out.Length = 7 ? "Every day" : Join(out, " ")
}

PName(id) => profiles.Has(id) ? profiles[id].name : "(none)"

; The repeat choices, as shown and as stored.
RepeatNames(dom) => ["Doesn't repeat", "Every day", "Every weekday (Mon to Fri)", "Every week on...", "Every 2 weeks on...",
    "Every month on the " Ordinal(dom)]
RepeatOf(s) {
    if (s.type = "once")
        return 1
    if (s.type = "monthly")
        return 6
    if (s.every = 2)
        return 5
    n := StrSplit(s.days, ",").Length
    if (n = 7)
        return 2
    if (s.days = "2,3,4,5,6")
        return 3
    return 4
}

WhenText(s) {
    switch s.type {
        case "weekly":
            r := RepeatOf(s)
            return (r = 2 ? "Every day" : r = 3 ? "Weekdays" : (s.every = 2 ? "Every 2 weeks, " : "") DaysText(s.days)) " " HM(s.time)
        case "monthly": return "Monthly on the " Ordinal(Integer(SubStr(s.date, 7, 2))) " at " HM(s.time)
        case "once":    return FormatTime(s.date s.time "00", "ddd MMM d, HH:mm")
        case "trip":    return "Leave " FormatTime(s.date s.time "00", "ddd MMM d, HH:mm")
    }
    return ""
}

ThenText(s) {
    if (s.type != "trip" && s.end_on)
        return "back to " PName(s.back) " at " HM(s.end_time)
    if (s.type = "trip")
        return "charge to " (profiles.Has(s.profile) ? profiles[s.profile].charge : 100) "%"
            . (s.before > 0 ? ", switch " s.before " min before" : ", no switch")
    return ""
}

ShowSchedules(*) {
    static open := 0
    if open {
        try WinActivate("ahk_id " open)
        return
    }
    g := Gui("+AlwaysOnTop", "Performance Companion schedules")
    open := g.Hwnd
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 16, g.MarginY := 12

    g.SetFont("s11 bold")
    g.Add("Text", "xm w760", "Let Performance Companion switch for you")
    g.SetFont("s10 norm")
    ideas := "Weekly game night? Switch to Gaming every Friday at 7 pm, and back to Work at 11:30.`n"
        . "Quiet evenings? Switch to a quiet profile every night at 10 pm.`n"
        . "Work week? Switch to Work every weekday morning at 8."
    if HasGH()
        ideas := "Going on a trip? Tell it when you leave: it charges the battery to full in time and switches to Travel just before you go.`n" ideas
    g.Add("Text", "xm y+6 w760", ideas)
    g.SetFont("s9 cGray")
    g.Add("Text", "xm y+6 w760", "You always get a heads-up before a restart or shutdown (with Snooze and Skip), switches wait while you're "
        . "in a game, and if the laptop was off at the time, you're asked whether to catch up.")
    g.SetFont("s10 norm cDefault")

    master := g.Add("Checkbox", "xm y+12", "Schedules on")
    master.Value := SCHEDULES_ENABLED
    g.SetFont("s10 bold")
    stateTx := g.Add("Text", "x+10 yp w300", "")
    g.SetFont("s10 norm")
    AddTip(master, "Turns all schedules on or off at once.`nSchedules start off, so the laptop never switches by surprise.")
    master.OnEvent("Click", (*) => (SetSchedulesEnabled(master.Value, !master.Value), Refresh(), UpdateUI()))

    lv := g.Add("ListView", "xm y+8 w760 r8 -Multi NoSort", ["On", "Name", "When", "Switch to", "Then", "Next"])
    AddTip(lv, "Double-click a schedule to edit it.")
    lv.OnEvent("DoubleClick", (*) => EditSel())

    b := g.Add("Button", "xm y+10 w130", "New schedule...")
    b.OnEvent("Click", (*) => ShowScheduleEditor("", Refresh))
    AddTip(b, "Switch profiles at a set time: once, or repeating every day, weekday, week, 2 weeks or month.")
    if HasGH() {
        b := g.Add("Button", "x+6 w110", "Plan a trip...")
        b.OnEvent("Click", (*) => ShowTripEditor("", Refresh))
        AddTip(b, "Tell it when you leave. It raises the charge limit early enough to be full at departure,`n"
            . "reminds you to plug in, and can switch to your travel profile just before you go.")
    }
    b := g.Add("Button", "x+18 w70", "Edit...")
    b.OnEvent("Click", (*) => EditSel())
    AddTip(b, "Edit the selected schedule.")
    b := g.Add("Button", "x+6 w70", "On / Off")
    b.OnEvent("Click", (*) => ToggleSel())
    AddTip(b, "Turn the selected schedule on or off.")
    b := g.Add("Button", "x+6 w70", "Delete")
    b.OnEvent("Click", (*) => DeleteSel())
    AddTip(b, "Delete the selected schedule.")
    b := g.Add("Button", "x+18 w70", "Close")
    b.OnEvent("Click", (*) => CloseWin())
    g.OnEvent("Close", (*) => CloseWin())
    g.OnEvent("Escape", (*) => CloseWin())
    Refresh()
    g.Show()

    Refresh(*) {
        stateTx.Value := SCHEDULES_ENABLED ? "Schedules are running" : "Schedules are off"
        stateTx.SetFont(SCHEDULES_ENABLED ? "c1B5E20" : "cB71C1C")
        lv.Delete()
        for sid in schedOrder {
            s := schedules[sid]
            nx := NextAction(s)
            nxt := !s.enabled ? "off" : !SCHEDULES_ENABLED ? "(schedules off)" : nx = "" ? "done" : FormatTime(nx, "ddd HH:mm")
            lv.Add(, s.enabled ? "Yes" : "No", s.name, WhenText(s), PName(s.profile), ThenText(s), nxt)
        }
        lv.ModifyCol(1, 40), lv.ModifyCol(2, 130), lv.ModifyCol(3, 200), lv.ModifyCol(4, 100), lv.ModifyCol(5, 180), lv.ModifyCol(6, "AutoHdr")
    }

    SelId() {
        row := lv.GetNext(0)
        return row ? schedOrder[row] : ""
    }

    EditSel() {
        if ((id := SelId()) = "")
            return
        if (schedules[id].type = "trip")
            ShowTripEditor(id, Refresh)
        else
            ShowScheduleEditor(id, Refresh)
    }

    ToggleSel() {
        if ((id := SelId()) = "")
            return
        s := schedules[id]
        if (!s.enabled && !profiles.Has(s.profile)) {
            MsgBox("Pick a profile for " s.name " first (Edit).", "Performance Companion schedules", "Iconi Owner" g.Hwnd)
            return
        }
        s.enabled := !s.enabled
        if s.enabled
            s.last_start := A_Now, s.last_end := A_Now
        WriteSchedule(s)
        Log("SCHEDULE    " s.name " turned " (s.enabled ? "on" : "off"))
        if (!s.enabled && IsObject(schedPending) && schedPending.sid = id)
            CancelPending(s.name " turned off")
        Refresh()
        if (s.enabled && !SCHEDULES_ENABLED)
            MsgBox(s.name " is on, but schedules as a whole are off. Tick 'Schedules on' at the top to start them.",
                "Performance Companion schedules", "Iconi Owner" g.Hwnd)
    }

    DeleteSel() {
        if ((id := SelId()) = "")
            return
        s := schedules[id]
        if (MsgBox("Delete the schedule " s.name "?", "Performance Companion schedules", "YesNo Icon? Owner" g.Hwnd) != "Yes")
            return
        if (IsObject(schedPending) && schedPending.sid = id)
            CancelPending("deleted")
        schedules.Delete(id)
        schedOrder.RemoveAt(IndexOf(schedOrder, id))
        try IniDelete(STATE, "schedule." id)
        SaveSchedOrder()
        Log("SCHEDULE    deleted " s.name)
        Refresh()
    }

    CloseWin() {
        open := 0
        ClearTips(g)
        g.Destroy()
    }
}

; Saves a schedule from an editor and tells the list. Shared by both editors.
FinishScheduleSave(s, isNew, onSave) {
    s.last_start := A_Now, s.last_end := A_Now        ; editing never triggers a "missed" switch
    if (s.type = "trip")
        s.last_charge := ""
    if isNew {
        s.id := UniqueSchedId()
        schedules[s.id] := s
        schedOrder.Push(s.id)
        SaveSchedOrder()
    } else if (IsObject(schedPending) && schedPending.sid = s.id) {
        CancelPending("schedule edited")
    }
    WriteSchedule(s)
    Log("SCHEDULE    " (isNew ? "added " : "saved ") s.name ": " WhenText(s) " -> " PName(s.profile)
        (ThenText(s) != "" ? ", " ThenText(s) : "") (s.enabled ? "" : " (off)"))
    try onSave()                                       ; the list window may have been closed meanwhile
    if (s.enabled && !SCHEDULES_ENABLED)
        ShowOSD("Saved. Tick 'Schedules on' to start it.", "Blue", true)
    else
        SetTimer(ScheduleTick, -500)
}

; New or edit: one form for one-time and repeating schedules.
ShowScheduleEditor(id, onSave) {
    isNew := (id = "")
    if isNew {
        s := NewSchedObj("once")
        s.name := "", s.enabled := 1, s.days := "6"
        s.profile := profiles.Has("gaming") ? "gaming" : profileOrder[1]
        s.back := profiles.Has("everyday") ? "everyday" : profileOrder[1]
        s.date := SubStr(A_Now, 1, 8), s.time := "1900"
    } else {
        s := schedules[id]
    }
    g := Gui("+AlwaysOnTop", isNew ? "New schedule" : "Edit schedule")
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 16, g.MarginY := 12
    names := []
    for pid in profileOrder
        names.Push(profiles[pid].name)

    Lbl(text, tip := "") {
        t := g.Add("Text", "xm y+12 w120", text)
        if (tip != "")
            AddTip(t, tip)
    }

    Lbl("Name")
    nameEd := g.Add("Edit", "x+4 yp-3 w300", s.name)
    DllCall("SendMessage", "Ptr", nameEd.Hwnd, "UInt", 0x1501, "Ptr", 1, "WStr", "e.g. Game night")
    Lbl("Switch to", "The profile to switch to.")
    profDdl := g.Add("DropDownList", "x+4 yp-3 w300", names)
    profDdl.Choose(profiles.Has(s.profile) ? IndexOf(profileOrder, s.profile) : 1)
    Lbl("Date", "When it happens, or for a repeating schedule, when it starts.")
    dateCtl := g.Add("DateTime", "x+4 yp-3 w220", "ddd, MMM d, yyyy")
    dateCtl.Value := s.date "000000"
    timeCtl := g.Add("DateTime", "x+8 yp w72 1", "HH:mm")
    timeCtl.Value := "20000101" s.time "00"
    Lbl("Repeat")
    repDdl := g.Add("DropDownList", "x+4 yp-3 w300", RepeatNames(Integer(SubStr(s.date, 7, 2))))
    repDdl.Choose(isNew ? 1 : RepeatOf(s))
    Lbl("On these days")
    dayCbs := Map(), first := true
    for d in DayOrder() {
        cb := g.Add("Checkbox", (first ? "x+4 yp" : "x+4 yp") " w48", DayShort(d))
        cb.Value := InStr("," s.days ",", "," d ",") ? 1 : 0
        dayCbs[d] := cb, first := false
    }

    endCb := g.Add("Checkbox", "xm y+16 w120", "Switch back at")
    endCb.Value := s.end_on
    AddTip(endCb, "End it automatically, for example back to Work at 23:30.`n"
        . "A time earlier than the start means the next day. Waits for a running game, too.")
    endTm := g.Add("DateTime", "x+4 yp-3 w90 1", "HH:mm")
    endTm.Value := "20000101" s.end_time "00"
    g.Add("Text", "x+8 yp+3", "to")
    backDdl := g.Add("DropDownList", "x+8 yp-3 w170", names)
    backDdl.Choose(profiles.Has(s.back) ? IndexOf(profileOrder, s.back) : 1)

    enCb := g.Add("Checkbox", "xm y+16", "This schedule is on")
    enCb.Value := s.enabled
    AddTip(enCb, "Also needs 'Schedules on' ticked in the Schedules window.")
    b := g.Add("Button", "xm y+14 w90 Default", "Save")
    b.OnEvent("Click", (*) => Save())
    b := g.Add("Button", "x+8 w90", "Cancel")
    b.OnEvent("Click", (*) => CloseWin())
    g.OnEvent("Close", (*) => CloseWin())
    g.OnEvent("Escape", (*) => CloseWin())

    repDdl.OnEvent("Change", (*) => SyncDays())
    dateCtl.OnEvent("Change", (*) => SyncDays())
    endCb.OnEvent("Click", (*) => SyncDays())
    SyncDays()
    g.Show()

    ; Day boxes only matter for the weekly choices; the monthly label follows the date.
    SyncDays() {
        r := repDdl.Value
        dom := Integer(FormatTime(dateCtl.Value, "d"))
        repDdl.Delete(), repDdl.Add(RepeatNames(dom)), repDdl.Choose(r)
        for d, cb in dayCbs
            cb.Enabled := (r = 4 || r = 5)
        endTm.Enabled := endCb.Value, backDdl.Enabled := endCb.Value
    }

    Save() {
        r := repDdl.Value
        s.name := Trim(nameEd.Value) != "" ? Trim(nameEd.Value) : "Switch to " profiles[profileOrder[profDdl.Value]].name
        s.profile := profileOrder[profDdl.Value]
        s.date := FormatTime(dateCtl.Value, "yyyyMMdd")
        s.time := FormatTime(timeCtl.Value, "HHmm")
        s.every := 1
        switch r {
            case 1: s.type := "once"
            case 2: s.type := "weekly", s.days := "2,3,4,5,6,7,1"
            case 3: s.type := "weekly", s.days := "2,3,4,5,6"
            case 6: s.type := "monthly"
            default:
                ds := []
                for d in DayOrder()
                    if dayCbs[d].Value
                        ds.Push(d)
                if !ds.Length {
                    MsgBox("Pick at least one day.", g.Title, "Icon! Owner" g.Hwnd)
                    return
                }
                s.type := "weekly", s.days := Join(ds, ",")
                if (r = 5)
                    s.every := 2, s.anchor := WeekStart(s.date "000000")
        }
        s.end_on := endCb.Value
        s.end_time := FormatTime(endTm.Value, "HHmm")
        s.back := profileOrder[backDdl.Value]
        if (s.end_on && s.back = s.profile) {
            MsgBox("Switch back to a different profile than the one it switches to.", g.Title, "Icon! Owner" g.Hwnd)
            return
        }
        if (s.type = "once" && (s.date s.time "00") <= A_Now && enCb.Value
            && MsgBox("That time has already passed, so this won't run. Save anyway?", g.Title, "YesNo Icon? Owner" g.Hwnd) != "Yes")
            return
        s.enabled := enCb.Value
        CloseWin()
        FinishScheduleSave(s, isNew, onSave)
    }

    CloseWin() {
        ClearTips(g)
        g.Destroy()
    }
}

; Trips: charge to full in time for departure, then switch to travel.
ShowTripEditor(id, onSave) {
    isNew := (id = "")
    if isNew {
        s := NewSchedObj("trip")
        s.name := "Trip", s.enabled := 1, s.before := 15
        s.profile := profiles.Has("travel") ? "travel" : profileOrder[1]
        s.date := SubStr(DateAdd(A_Now, 1, "Days"), 1, 8), s.time := "0700"
    } else {
        s := schedules[id]
    }
    g := Gui("+AlwaysOnTop", isNew ? "Plan a trip" : "Edit trip")
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 16, g.MarginY := 12
    names := []
    for pid in profileOrder
        names.Push(profiles[pid].name)
    g.SetFont("s11 bold")
    g.Add("Text", "xm w440", "Going on a trip?")
    g.SetFont("s10 norm")
    g.Add("Text", "xm y+4 w440", "Tell Performance Companion when you leave. It charges your battery to full just in time "
        . "(so it isn't sitting at 100% all week), reminds you to plug in, and switches to your travel profile right before you go.")

    Lbl(text, tip := "") {
        t := g.Add("Text", "xm y+12 w130", text)
        if (tip != "")
            AddTip(t, tip)
    }
    Lbl("Leaving on")
    dateCtl := g.Add("DateTime", "x+4 yp-3 w220", "ddd, MMM d, yyyy")
    dateCtl.Value := s.date "000000"
    timeCtl := g.Add("DateTime", "x+8 yp w90 1", "HH:mm")
    timeCtl.Value := "20000101" s.time "00"
    Lbl("Travel profile", "The profile you travel in. Its charge limit is what the battery is charged to.")
    profDdl := g.Add("DropDownList", "x+4 yp-3 w300", names)
    profDdl.Choose(profiles.Has(s.profile) ? IndexOf(profileOrder, s.profile) : 1)
    Lbl("Before you leave", "Switching to a travel profile usually shuts the laptop down, so it's packed and ready.`n"
        . "The battery keeps charging while it's off.")
    beforeDdl := g.Add("DropDownList", "x+4 yp-3 w300", ["Just charge, don't switch", "Switch 15 minutes before",
        "Switch 30 minutes before", "Switch 60 minutes before"])
    beforeDdl.Choose(s.before = 0 ? 1 : s.before = 30 ? 3 : s.before = 60 ? 4 : 2)
    g.SetFont("s9 cGray")
    g.Add("Text", "xm y+10 w440", "Charging starts based on how fast this laptop has charged before (now about "
        . ChargeRate() "% an hour), plus a 20 minute buffer.")
    g.SetFont("s10 norm cDefault")
    enCb := g.Add("Checkbox", "xm y+12", "This trip is on")
    enCb.Value := s.enabled
    b := g.Add("Button", "xm y+14 w90 Default", "Save")
    b.OnEvent("Click", (*) => Save())
    b := g.Add("Button", "x+8 w90", "Cancel")
    b.OnEvent("Click", (*) => CloseWin())
    g.OnEvent("Close", (*) => CloseWin())
    g.OnEvent("Escape", (*) => CloseWin())
    g.Show()

    Save() {
        s.date := FormatTime(dateCtl.Value, "yyyyMMdd")
        s.time := FormatTime(timeCtl.Value, "HHmm")
        s.profile := profileOrder[profDdl.Value]
        s.before := [0, 15, 30, 60][beforeDdl.Value]
        s.name := "Trip " FormatTime(s.date "000000", "MMM d")
        if ((s.date s.time "00") <= A_Now && enCb.Value
            && MsgBox("That time has already passed, so this won't run. Save anyway?", g.Title, "YesNo Icon? Owner" g.Hwnd) != "Yes")
            return
        s.enabled := enCb.Value
        CloseWin()
        FinishScheduleSave(s, isNew, onSave)
    }

    CloseWin() {
        ClearTips(g)
        g.Destroy()
    }
}
; Remembers every game detected, and how, so the Games list shows them all.
NoteSeen(key, how) {
    v := FormatTime(, "yyyy-MM-dd") "|" how
    if (seenGames.Has(key) && seenGames[key] = v)
        return
    seenGames[key] := v
    try IniWrite(v, STATE, "seen", key)
}

; ---------- icons ----------
IconPath(name) => installDir "\icons\" name ".ico"

; Writes the embedded icons to disk once per version.
EnsureIcons() {
    DirCreate(installDir "\icons")
    fresh := (IniRead(STATE, "app", "icons_version", "") != SCRIPT_VERSION)
    for name in ["everyday", "desk", "travel", "custom", "paused"] {
        if (fresh || !FileExist(IconPath(name))) {
            switch name {
                case "everyday": data := IconData_everyday()
                case "desk":     data := IconData_desk()
                case "travel":   data := IconData_travel()
                case "custom":   data := IconData_custom()
                default:         data := IconData_paused()
            }
            try WriteBase64File(data, IconPath(name))
        }
    }
    if fresh
        IniWrite(SCRIPT_VERSION, STATE, "app", "icons_version")
    return fresh
}

WriteBase64File(b64, path) {
    size := 0
    DllCall("Crypt32\CryptStringToBinary", "Str", b64, "UInt", 0, "UInt", 1, "Ptr", 0, "UInt*", &size, "Ptr", 0, "Ptr", 0)
    buf := Buffer(size)
    DllCall("Crypt32\CryptStringToBinary", "Str", b64, "UInt", 0, "UInt", 1, "Ptr", buf, "UInt*", &size, "Ptr", 0, "Ptr", 0)
    f := FileOpen(path, "w")
    f.RawWrite(buf, size)
    f.Close()
}

; Tray icon follows the profile's chosen icon; grey when paused.
UpdateTrayIcon() {
    static last := ""
    name := (paused || !automationOK) ? "paused" : CurP().icon
    if (name = last || !FileExist(IconPath(name)))
        return
    try {
        TraySetIcon(IconPath(name))
        last := name
    }
}

; Windows 11 remembers "show in tray" per program under NotifyIconSettings.
; Every AutoHotkey script runs as the same program, so this shows all of
; them. Done once only: if the user hides it later, that choice stands.
PromoteTrayIcon() {
    static tries := 0
    if IniRead(STATE, "app", "tray_promoted", "")
        return
    SplitPath(A_AhkPath, &ahkName)
    found := false
    try {
        Loop Reg "HKCU\Control Panel\NotifyIconSettings", "K" {
            k := A_LoopRegKey "\" A_LoopRegName
            path := ""
            try path := RegRead(k, "ExecutablePath")
            if (path != "" && SubStr(path, -StrLen(ahkName)) = ahkName) {
                RegWrite(1, "REG_DWORD", k, "IsPromoted")
                found := true
            }
        }
    }
    if found {
        IniWrite(1, STATE, "app", "tray_promoted")
        Log("TRAY        set to always show")
    } else if (++tries < 6) {
        SetTimer(PromoteTrayIcon, -30000)         ; Windows registers the icon a little after it appears
    }
}

; Switch confirmation with a big, unmissable hands-off warning.
ConfirmSwitch(title, steps, ending) {
    res := {v: ""}
    g := Gui("+AlwaysOnTop -MinimizeBox", title)
    g.MarginX := 20, g.MarginY := 16
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "w480", steps)
    g.SetFont("s14 bold cB71C1C", "Segoe UI")
    g.Add("Text", "w480 y+16", "After you click Yes, don't touch the mouse or keyboard until the laptop " ending ".")
    g.SetFont("s10 norm cDefault", "Segoe UI")
    g.Add("Text", "w480 y+8", "Performance Companion clicks G-Helper's buttons for you, and a moving mouse can interrupt it. Save your work first.")
    yes := g.Add("Button", "w130 y+18 Default", "Yes, switch now")
    no := g.Add("Button", "x+10 w100", "Cancel")
    yes.OnEvent("Click", (*) => (res.v := "Yes", g.Destroy()))
    no.OnEvent("Click", (*) => (res.v := "No", g.Destroy()))
    g.OnEvent("Close", (*) => (res.v := "No", g.Destroy()))
    g.OnEvent("Escape", (*) => (res.v := "No", g.Destroy()))
    hw := g.Hwnd
    g.Show()
    WinWaitClose("ahk_id " hw)
    return res.v = "Yes"
}

; Compares this script's version with the one that ran last time.
AnnounceUpdate() {
    prev := IniRead(STATE, "app", "script_version", "")
    if (prev = SCRIPT_VERSION)
        return
    IniWrite(SCRIPT_VERSION, STATE, "app", "script_version")
    if (prev = "" && firstRun)
        return                                   ; brand-new install, welcome covers it
    Log("UPDATE      " (importedFrom != "" ? importedFrom " " : "") (prev = "" ? "(earlier build)" : prev) " -> Performance Companion " SCRIPT_VERSION)
    ShowOSD(importedFrom != "" ? "Performance Companion replaced " importedFrom ". Your settings came along." : "Performance Companion updated to " SCRIPT_VERSION, "Green", true)
}

; First launch on a new machine: match the profile to the GPU mode the
; laptop is already in, instead of assuming one, and explain the basics.
FirstRunSetup() {
    global firstRun
    firstRun := false
    if HasGH() {
        gm := GetJsonInt(ReadCfg(), "gpu_mode")
        first := (gm = 2 && profiles.Has("gaming")) ? "gaming" : profiles.Has("everyday") ? "everyday" : profileOrder[1]
    } else {
        first := profiles.Has("everyday") ? "everyday" : profileOrder[1]
    }
    SetProfile(first)
    Log("FIRST RUN   " DEVICE.kind " " DEVICE.maker " " DEVICE.model (DEVICE.handheld != "" ? " (" DEVICE.handheld ")" : "")
        . ", engine " EngineName() ", starting in " CurP().name)
    msg := "Performance Companion is running in the tray. You're in the " CurP().name " profile.`n`n"
        . "Right-click the tray icon to switch profiles, set modes for games and apps, or change settings. "
        . "In any Performance Companion window, rest the mouse on something to see what it does."
    tips := VendorTips()
    if tips.Length {
        msg .= "`n`nOne-time setup so Performance Companion can use your machine's full power:"
        for t in tips
            msg .= "`n`n" t.name ": " t.text
    }
    MsgBox(msg, "Welcome to Performance Companion", "Iconi")
    for t in tips
        IniWrite(1, STATE, "setupcheck", "Tip: " t.name)          ; already shown; setup check won't repeat it
    ShowSetupCheck("startup")                     ; only if something needs attention
}

; Removes everything this script added to Windows. G-Helper itself and its
; current settings are left exactly as they are; power plans are removed
; and Windows goes back to the plan you used before.
Uninstall(*) {
    global paused
    if (MsgBox("Remove Performance Companion from this PC?`n`n"
        . "This deletes its startup tasks and Start menu shortcut, and stops it.`n"
        . (HasGH() ? "G-Helper and its current settings are left as they are now."
            : "Its three power plans are removed and Windows goes back to the plan you used before."),
        "Uninstall Performance Companion", "YesNo Icon!") != "Yes")
        return
    keep := MsgBox("Keep your profiles, schedules, learned games, saved modes, and activity log?`n`n"
        . "Yes keeps them in case you reinstall. No deletes them.",
        "Uninstall Performance Companion", "YesNo Icon?")
    paused := true                                ; nothing may switch modes while things are removed
    SetTimer(WatchPower, 0)
    SetTimer(SmartPlatformMonitor, 0)
    SetTimer(ScheduleTick, 0)
    Log("UNINSTALL   removing tasks and shortcuts" (HasGH() ? "" : " and power plans") (keep = "No" ? ", deleting data" : ""))
    if (IniRead(STATE, "plans", "work", "") != "")
        RemovePlans()
    for t in [TASK_MAIN, TASK_TOGGLE]
        RunWait('schtasks.exe /delete /tn "' t '" /f', , "Hide")
    try FileDelete(LINK_START)
    if (keep = "No")
        try DirDelete(installDir, true)
    MsgBox("Performance Companion has been removed." (HasGH() ? "" : " Windows is back on " PlanFriendlyName(ActivePlanGuid()) ".")
        . (keep = "No" ? "" : "`nYour data is still in " installDir "."), "Uninstall Performance Companion", "Iconi")
    ExitApp()
}

; ====================================================================
;  INSTALL CHECKS (run every launch, create only what's missing)
; ====================================================================
EnsureInstall() {
    ; Re-register if missing, or if AutoHotkey itself moved (its path is
    ; baked into the tasks).
    ahkChanged := (IniRead(STATE, "app", "ahk_path", "") != A_AhkPath)
    if (ahkChanged || !TaskExists(TASK_MAIN))
        RegisterTask(TASK_MAIN, "", true)
    if (ahkChanged || !TaskExists(TASK_TOGGLE))
        RegisterTask(TASK_TOGGLE, " toggle", false)
    if ahkChanged
        IniWrite(A_AhkPath, STATE, "app", "ahk_path")
    if (linksStale || !FileExist(LINK_START))
        MakeToggleLink(LINK_START, "Pick a Performance Companion profile", "everyday")
}

TaskExists(name) => RunWait('schtasks.exe /query /tn "' name '"', , "Hide") = 0

; Elevated task = no UAC prompt at login or when toggling.
; Battery settings matter: Task Scheduler defaults to "AC power only",
; which would stop this from ever starting on a plane.
RegisterTask(name, extraArgs, atLogon) {
    ps := installDir "\task.ps1"
    trig := atLogon ? " -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $u)" : ""
    lines := [
        "$u = $env:USERDOMAIN + '\' + $env:USERNAME",
        "$q = [char]34",
        "$a = New-ScheduledTaskAction -Execute '" A_AhkPath "' -Argument ($q + '" scriptDest "' + $q + '" extraArgs "')",
        "$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel",
        "$p = New-ScheduledTaskPrincipal -UserId $u -RunLevel Highest -LogonType Interactive",
        "Register-ScheduledTask -TaskName '" name "' -Action $a" trig " -Settings $s -Principal $p -Force | Out-Null"
    ]
    out := ""
    for l in lines
        out .= l "`r`n"
    try FileDelete(ps)
    FileAppend(out, ps, "UTF-8")
    RunWait('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' ps '"', , "Hide")
    try FileDelete(ps)
}

MakeToggleLink(path, desc, icon := "everyday") {
    ico := FileExist(IconPath(icon)) ? IconPath(icon) : A_AhkPath
    FileCreateShortcut(A_WinDir "\System32\schtasks.exe", path, , '/run /tn "' TASK_TOGGLE '"', desc, ico, , 1, 7)
}

; Desktop shortcuts were retired in 1.1.5 (the tray icon shows the profile
; now). Earlier builds created one; quietly remove it if it's still there.
RemoveDesktopLinks() {
    for n in ["Switch to Travel", "Switch to Desk"]
        if FileExist(A_Desktop "\" n ".lnk")
            try FileDelete(A_Desktop "\" n ".lnk")
}
; ====================================================================
;  ENFORCEMENT (login, plug, unplug, resume, every switch)
; ====================================================================
WatchPower() {
    static lastAC := "", lastTick := A_TickCount
    global manualOverride
    ac := OnAC()
    resumed := (A_TickCount - lastTick > 30000)   ; timer gap = woke from sleep/hibernate
    lastTick := A_TickCount
    ; A manual lock (Ctrl+Alt+T / Ctrl+Alt+B) never sticks forever.
    if (manualOverride != "None" && (A_TickCount - manualSince > LOCK_HOURS * 3600000 || (lastAC != "" && ac != lastAC))) {
        Log("MANUAL      lock released (" (lastAC != "" && ac != lastAC ? "power source changed" : LOCK_HOURS " hours passed") ")")
        manualOverride := "None"
        SetTimer(EnforceState.Bind(true), -100)
    }
    if (lastAC != "" && (ac != lastAC || resumed)) {
        Log(resumed ? "RESUME      woke from sleep/hibernate" : (ac ? "POWER       plugged in" : "POWER       unplugged"))
        if (ac != lastAC)
            CheckBatteryProfile()
        ; G-Helper reacts to power changes itself first; give it a moment.
        SetTimer(EnforceState.Bind(true), HasGH() ? -6000 : -2000)
        if resumed
            SetTimer(ScheduleTick.Bind(true), -15000)   ; catch up on schedules missed while asleep
    } else if (!HasGH() && refreshPending != "" && !busy && !FullscreenInFront()) {
        ApplyRefresh(refreshPending)
    } else if (!HasGH() && !busy && !switching && !paused && automationOK && appliedMode != "" && A_TickCount >= planRetryAt) {
        ; Something else (Windows settings, a vendor tool) changed the plan.
        want := PlanGuid(ModeKey(ExpectedPerf()))
        if (want != "" && ActivePlanGuid() != want)
            EnforceState()
    }
    lastAC := ac
    UpdateTip()                                     ; keep the tray tooltip current
}

; Puts the real state back in line with the active profile. force:
; re-apply even if it looks right (after a power change, resume, switch).
EnforceState(force := false, *) {
    if (BACKEND = "plans")
        return EnforcePlans(force)
    return EnforceGHelper()
}

EnforcePlans(force := false) {
    global busy
    Critical()                                      ; a hotkey or switch can't interleave with this
    if (busy || paused || switching || !automationOK)
        return
    busy := true
    want := ExpectedPerf()
    g := PlanGuid(ModeKey(want))
    cur := ActivePlanGuid()
    if (cur != g) {
        if (appliedMode != "" && !force)
            Log("ENFORCE     plan changed outside Performance Companion (" PlanFriendlyName(cur) "), back to " PlanTitle(ModeKey(want)))
        else
            Log("PLAN        " PlanFriendlyName(cur) " -> " PlanTitle(ModeKey(want)) " (" CurP().name ", " (OnAC() ? "AC" : "battery")
                . (isTurboMode ? ", game " turboExe : manualOverride != "None" ? ", manual lock" : "") ")")
        ApplyMode(want, force)
    } else if (force || appliedMode != want) {
        ApplyMode(want, force)
    }
    busy := false
    UpdateUI()
}

EnforceGHelper() {
    global busy
    if (busy || paused || switching || !automationOK || !ProcessExist("GHelper.exe"))
        return
    busy := true
    p := CurP()
    ac := OnAC()

    ; Charge limit, and (while plugged in) the battery mode G-Helper will
    ; use on the next unplug, live in the config. Fixing the battery mode
    ; ahead of time means unplugging never flips to a leftover Turbo.
    ; (On battery the live mode is fixed by hotkey below instead, so a
    ; game running on battery isn't interrupted by a G-Helper restart.)
    want := WantCharge()
    txt := ReadCfg()
    curC := GetJsonInt(txt, "charge_limit"), cur0 := GetJsonInt(txt, "performance_0")
    if (curC != want || (ac && cur0 != p.battery)) {
        Log("ENFORCE     config fix: charge " curC "->" want ", battery mode " ModeName(cur0) "->" ModeName(p.battery))
        ApplyConfig(want)
    }

    gm := GetJsonInt(ReadCfg(), "gpu_mode")
    if (p.gpu = "ultimate") {
        if (gm != "" && gm != 2)
            ShowOSD(p.name " uses Ultimate, but the GPU isn't. Tray > Finish switching.", "Red", true)
        else if !ac
            ShowOSD("Ultimate on battery drains it fast. Consider another profile.", "Red", true)
    } else if (gm = 2) {
        ShowOSD("Still in Ultimate. Restart to finish " p.name ".", "Red", true)
    } else if (gm != "") {
        wantGpu := (p.gpu = "eco") ? 0 : (p.gpu = "standard") ? 1 : (ac ? 1 : 0)
        if (gm != wantGpu) {
            Log("ENFORCE     GPU " GpuName(gm) "->" GpuName(wantGpu) " (" p.name ", " (ac ? "AC" : "battery") ")")
            SendGHelperKey(wantGpu ? 0x7E : 0x7D)   ; F15 Standard / F14 Eco
            Sleep(2000)
        }
    }

    wantPerf := ExpectedPerf()
    curPerf := GetJsonInt(ReadCfg(), PerfKey())
    if (curPerf != wantPerf) {
        Log("ENFORCE     mode " ModeName(curPerf) "->" ModeName(wantPerf) " (" (ac ? "AC" : "battery") ")")
        SetPerfMode(wantPerf)
    }
    busy := false
    UpdateUI()
}

ExpectedPerf() {
    p := CurP()
    if (manualOverride = "Turbo")
        return 1
    if (manualOverride = "Balanced")
        return 0
    if (isTurboMode && GameModesActive())
        return CapMode(turboMode, p)
    return OnAC() ? p.ac : p.battery
}

; ====================================================================
;  VERSION GUARD AND SELF-TEST
; ====================================================================
CurrentVersion() {
    try return FileGetVersion(GHelperPath())
    return "unknown"
}

CheckVersion() {
    ver := CurrentVersion()
    if (ver != IniRead(STATE, "ghelper", "validated", ""))
        SelfTest(ver)
}

; Proves the hotkeys still reach G-Helper and the config keys still exist.
; If anything fails, automation pauses instead of guessing.
SelfTest(ver) {
    global automationOK, busy
    busy := true
    problems := []
    txt := ReadCfg()
    if (txt = "")
        problems.Push("Couldn't read " CFG)
    for k in ["charge_limit", "gpu_mode"]
        if (GetJsonInt(txt, k) = "")
            problems.Push('Config key "' k '" not found')

    key := PerfKey()
    cur := GetJsonInt(txt, key)
    test := (cur = 2) ? 0 : 2
    SendGHelperKey(PerfVK(test))
    Sleep(2500)
    got := GetJsonInt(ReadCfg(), key)
    if (got != test)
        problems.Push("Mode hotkey didn't register (" key ": expected " test ", got " (got = "" ? "nothing" : got) ")")
    SetPerfMode(cur != "" ? cur : ExpectedPerf())
    Sleep(1500)
    busy := false

    if problems.Length {
        automationOK := false
        Log("SELF-TEST   FAILED for G-Helper " ver)
        msg := "G-Helper " ver " failed the self-test:`n`n"
        for p in problems
            msg .= "  - " p "`n"
        msg .= "`nAutomation is paused so nothing runs on bad assumptions. "
            .  "Profile switching and manual hotkeys still work; check results by eye."
        MsgBox(msg, "Performance Companion: self-test failed", "Icon!")
    } else {
        automationOK := true
        IniWrite(ver, STATE, "ghelper", "validated")
        Log("SELF-TEST   passed for G-Helper " ver)
        ShowOSD("G-Helper " ver " verified", "Green")
    }
    UpdateUI()
}

; ====================================================================
;  G-HELPER HELPERS
; ====================================================================
GHelperPath() {
    p := IniRead(STATE, "ghelper", "path", "")
    if ProcessExist("GHelper.exe") {
        try {
            p := ProcessGetPath("GHelper.exe")
            IniWrite(p, STATE, "ghelper", "path")
        }
    }
    return p
}

StopGHelper() {
    if ProcessExist("GHelper.exe") {
        ProcessClose("GHelper.exe")
        ProcessWaitClose("GHelper.exe", 5)
    }
    Sleep(750)
}

StartGHelper(gh) {
    Run(gh)
    ProcessWait("GHelper.exe", 10)
    Sleep(4000)
}

; Charge limit has no hotkey, so it goes through the config with G-Helper
; closed. The profile's remembered battery and AC modes and "Enable GPU on
; shutdown" are set at the same time.
ApplyConfig(charge := "") {
    p := CurP()
    if (charge = "")
        charge := WantCharge()
    gh := GHelperPath()
    if (gh = "" || !FileExist(gh)) {
        MsgBox("Couldn't find GHelper.exe. Start G-Helper and try again.", "Performance Companion", "Iconx")
        return false
    }
    StopGHelper()
    txt := ReadCfg()
    if (txt = "") {
        StartGHelper(gh)
        return false
    }
    try FileCopy(CFG, installDir "\config.backup.json", true)
    SetJsonInt(&txt, "charge_limit", charge)
    SetJsonInt(&txt, "performance_0", p.battery)   ; mode G-Helper uses on battery
    SetJsonInt(&txt, "performance_1", p.ac)        ; mode G-Helper uses plugged in
    SetJsonInt(&txt, "shutdown_gpu", 1)            ; avoids an NVIDIA issue on shutdown with the dGPU off
    WriteCfg(txt)
    StartGHelper(gh)
    return true
}

OnAC() {
    sps := Buffer(12, 0)
    DllCall("GetSystemPowerStatus", "Ptr", sps)
    return NumGet(sps, 0, "UChar") != 0              ; 1 = AC, 255 = unknown (treated as AC)
}

PerfKey() => "performance_" (OnAC() ? 1 : 0)
GpuName(g) => g = 0 ? "Eco" : g = 1 ? "Standard" : g = 2 ? "Ultimate" : "unknown"

; Low-level key injection, the method your turbo script already proved works
SendCombo(keys*) {
    for k in keys
        DllCall("keybd_event", "UChar", k, "UChar", 0, "UInt", 0, "UPtr", 0)
    Sleep(50)
    i := keys.Length
    while (i > 0) {
        DllCall("keybd_event", "UChar", keys[i], "UChar", 0, "UInt", 2, "UPtr", 0)
        i--
    }
}
SendGHelperKey(vk) => SendCombo(0x11, 0x10, 0x12, vk)   ; Ctrl+Shift+Alt+Fxx

; ---------- config.json (flat integer keys only) ----------
ReadCfg() {
    try return FileRead(CFG, "UTF-8")
    return ""
}

GetJsonInt(txt, key) {
    return RegExMatch(txt, '"' key '"\s*:\s*(-?\d+)', &m) ? m[1] : ""
}

SetJsonInt(&txt, key, val) {
    pat := '("' key '"\s*:\s*)-?\d+'
    if RegExMatch(txt, pat)
        txt := RegExReplace(txt, pat, "${1}" val, , 1)
    else if RegExMatch(txt, "^\s*\{\s*\}\s*$")
        txt := '{"' key '": ' val '}'
    else
        txt := RegExReplace(txt, "^\s*\{", '{`n  "' key '": ' val ',', , 1)
}

WriteCfg(txt) {
    f := FileOpen(CFG, "w", "UTF-8-RAW")
    f.Write(txt)
    f.Close()
}
; ====================================================================
;  1. MASTER CACHE BUILDER (unchanged)
; ====================================================================
; A folder guessed from an icon or uninstaller path is only trusted if it's
; a real, specific game folder, not Windows or a drive / Program Files root.
UsableGameDir(dir) {
    if (dir = "" || !DirExist(dir))
        return false
    d := RTrim(dir, "\")
    for bad in [A_WinDir, A_ProgramFiles, EnvGet("ProgramFiles(x86)"), A_AppData, EnvGet("LOCALAPPDATA"), EnvGet("ProgramData")]
        if (bad != "" && (d = RTrim(bad, "\") || InStr(d, A_WinDir) = 1))
            return false
    return StrLen(d) > 3                          ; not a bare drive root
}

BuildDynamicGameCache() {
    global cachedGameDirs

    regRoots := [
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    ]

    for root in regRoots {
        try {
            Loop Reg root, "K" {
                try {
                    k := root "\" A_LoopRegName
                    pub := ""
                    try pub := RegRead(k, "Publisher")
                    if (pub = "")
                        continue
                    isTarget := false
                    for target in TargetPublishers
                        if InStr(pub, target) {
                            isTarget := true
                            break
                        }
                    if !isTarget
                        continue
                    loc := ""
                    try loc := RegRead(k, "InstallLocation")
                    ; Some publishers (Riot for League, for one) leave InstallLocation
                    ; blank. Fall back to the folder of the icon or uninstaller.
                    if (loc = "") {
                        for valName in ["DisplayIcon", "UninstallString"] {
                            v := ""
                            try v := RegRead(k, valName)
                            if RegExMatch(v, 'i)^\s*"?([a-z]:\\[^"]*?\.(?:exe|ico))', &m) {
                                SplitPath(m[1], , &dir)
                                if UsableGameDir(dir) {
                                    loc := dir
                                    break
                                }
                            }
                        }
                    }
                    if (loc != "" && UsableGameDir(loc))
                        cachedGameDirs.Push(RTrim(loc, "\") "\")
                }
            }
        }
    }
}

; ====================================================================
;  2. KVM & DISPLAY STATE MONITOR (COMMENTED OUT - KEPT PER REQUEST)
; ====================================================================
/*
OnMessage(0x007E, OnDisplayChange)

OnDisplayChange(wParam, lParam, msg, hwnd) {
    global isResetting, KvmDisplayDelay, lastMonitorCount, isTurboMode
    if (isResetting)
        return

    Sleep(500)
    currentMonitorCount := SysGet(80)

    if (currentMonitorCount > lastMonitorCount && !isTurboMode) {
        SetTimer(FastGPUReset, -KvmDisplayDelay)
    }

    lastMonitorCount := currentMonitorCount
}

FastGPUReset() {
    global isResetting
    isResetting := true

    dllcall("keybd_event", "UChar", 0x5B, "UChar", 0, "UInt", 0, "UPtr", 0)
    dllcall("keybd_event", "UChar", 0xA2, "UChar", 0, "UInt", 0, "UPtr", 0)
    dllcall("keybd_event", "UChar", 0xA0, "UChar", 0, "UInt", 0, "UPtr", 0)
    dllcall("keybd_event", "UChar", 0x42, "UChar", 0, "UInt", 0, "UPtr", 0)

    Sleep(50)

    dllcall("keybd_event", "UChar", 0x42, "UChar", 0, "UInt", 2, "UPtr", 0)
    dllcall("keybd_event", "UChar", 0xA0, "UChar", 0, "UInt", 2, "UPtr", 0)
    dllcall("keybd_event", "UChar", 0xA2, "UChar", 0, "UInt", 2, "UPtr", 0)
    dllcall("keybd_event", "UChar", 0x5B, "UChar", 0, "UInt", 2, "UPtr", 0)

    Sleep(1500)
    ShowOSD("Display Pipeline Refreshed", "Blue")

    Sleep(4000)
    isResetting := false
}
*/
; ====================================================================
;  3. SMART MONITOR LOOP (wherever the active profile allows game modes)
;
;  Order of checks every 5 seconds:
;    1. Known game running (Steam, publisher folders, your list,
;       Xbox, or a game it learned earlier)  ->  Turbo right away
;    2. Otherwise, which single app is loading the GPU hardest?
;       Heavy + fullscreen in front, or very heavy anywhere  ->  Turbo
;    3. Held under load for 30s  ->  remembered as a game for next time
;    4. Load drops and stays low  ->  Balanced
; ====================================================================
SmartPlatformMonitor() {
    global isTurboMode, manualOverride, lastGameState, lastTop, turboSource, turboExe, turboMode
    static candExe := "", candCount := 0, lowCount := 0, heldCount := 0, recredit := ""

    ; Dormant wherever game modes are switched off (Settings > Game modes work).
    if (busy || paused || !automationOK || !GameModesActive()) {
        candExe := "", candCount := 0, lowCount := 0, heldCount := 0
        if (isTurboMode && !GameModesActive()) {
            isTurboMode := false
            manualOverride := "None"
            SetTimer(EnforceState.Bind(true), -100)   ; back to the profile's plan
            Log("GAME OFF    game modes not active here (" (OnAC() ? "AC" : "battery") ", " profile ")")
        }
        UpdateWatch("Watch: dormant (" (paused ? "paused" : !automationOK ? "engine not ready"
            : busy ? "busy" : "game modes off in " CurP().name (CurP().games = "ac" ? " on battery" : "")) ")")
        return
    }

    known := CheckPassiveGamingState()
    knownBool := (known != false)
    if (knownBool != lastGameState) {
        if (manualOverride != "None")
            ShowOSD("State Change: Manual Lock Released", "Blue")
        manualOverride := "None"
        lastGameState := knownBool
    }
    if (manualOverride != "None") {
        UpdateWatch("Watch: manual " ModeName(manualOverride = "Turbo" ? 1 : 0) " lock")
        return
    }

    if knownBool {
        SplitPath(known, &kExe)
        UpdateWatch("Watch: known game " kExe " | " StrUpper(ModeName(turboMode)))
        candCount := 0, lowCount := 0
        if !isTurboMode
            EngageTurbo("game", known)
        return
    }

    top := EnableLoadDetection ? TopGpuProcess() : {pid: 0, exe: "", path: "", util: 0}
    lastTop := top
    UpdateWatch(WatchText(top))

    if isTurboMode {
        ; release once load stays low
        ; A known game (Steam, publisher folder, added...) that's gone counts as
        ; ended even if a video or another app keeps the GPU busy.
        if (top.util < GpuIdleThreshold || (turboSource = "game" && !QualifiesAsGame(top))) {
            lowCount++
            if (lowCount >= ReleaseCycles) {
                isTurboMode := false
                RestoreIdleMode()
                ShowOSD("Game closed: " ModeName(IdleMode()), "Green")
                Log("GAME OFF    load under " GpuIdleThreshold "% for " ReleaseCycles * 5 "s (was " turboSource ": " turboExe ", " ModeName(turboMode) ")")
                lowCount := 0, heldCount := 0
            }
        } else {
            lowCount := 0
        }

        ; Re-credit turbo to whichever app is actually holding the load.
        ; Example: Battle.net engaged turbo, then MTGA took over the GPU.
        ; Without this, MTGA could never be learned.
        ; Re-credit only after two readings in a row, so one spike can't steal it.
        recredit := (top.exe != "" && top.exe != turboExe && QualifiesAsGame(top)) ? (recredit = top.exe ? top.exe "|2" : top.exe) : ""
        if (InStr(recredit, "|2")) {
            recredit := ""
            Log("RE-CREDIT   turbo now held by " top.exe " at " top.util "% (was " turboSource ": " turboExe ")")
            turboSource := "load", turboExe := top.exe
            heldCount := 0
            if (GameModeFor(turboExe) != turboMode) {
                turboMode := GameModeFor(turboExe)
                SetPerfMode(CapMode(turboMode), "game " turboExe)
                ShowOSD(turboExe ": " ModeShown(turboMode) " (saved)", turboMode = 1 ? "Red" : "Blue")
            }
        }

        ; learn apps that hold real load under turbo
        if (LEARNING_ENABLED && turboSource = "load" && top.exe != "" && top.exe = turboExe
            && top.util >= GameLoadForeground && !learned.Has(top.exe)) {
            heldCount++
            Log("LEARNING    " top.exe " at " top.util "% (" heldCount "/" LearnCycles ")")
            if (heldCount >= LearnCycles)
                LearnGame(top.exe)
        }
        return
    }

    if (top.exe != "" && QualifiesAsGame(top)) {
        candCount := (top.exe = candExe) ? candCount + 1 : 1
        candExe := top.exe
        if (candCount >= HysteresisCycles) {
            EngageTurbo("load", top.path, top.util)
            candCount := 0, lowCount := 0, heldCount := HysteresisCycles
        }
    } else {
        candCount := 0
    }
}

EngageTurbo(source, path, util := "") {
    global isTurboMode, turboSource, turboExe, turboMode
    SplitPath(path, &exe)
    turboExe := StrLower(exe)
    turboSource := source
    turboMode := GameModeFor(turboExe)
    isTurboMode := true
    SetPerfMode(CapMode(turboMode), "game " turboExe)
    NoteSeen(turboExe, source = "load" ? "GPU load" : knownHow)
    saved := gameModes.Has(turboExe) ? " (saved)" : ""
    if (source = "game") {
        ShowOSD(exe ": " ModeShown(turboMode) saved, turboMode = 1 ? "Red" : "Blue")
        Log("GAME ON     known game: " exe ", " ModeName(turboMode) saved)
    } else {
        ShowOSD(exe " at " util "% GPU: " ModeShown(turboMode) saved, turboMode = 1 ? "Red" : "Blue")
        Log("GAME ON     load: " exe " at " util "%, " ModeName(turboMode) saved)
    }
}

GameModeFor(exe) => gameModes.Has(exe) ? Integer(gameModes[exe]) : DEFAULT_GAME_MODE

; Ctrl+Alt+G in a game: cycle Turbo -> Balanced -> Silent, apply now, remember it.
; The app the game controls act on: the detected game if there is one,
; otherwise whatever the Watch panel shows as the top GPU user.
GameTarget() {
    if (isTurboMode && turboExe != "" && manualOverride = "None")
        return {exe: turboExe, path: "", isGame: true}
    if (lastTop.exe != "")
        return {exe: lastTop.exe, path: lastTop.path, isGame: false}
    return {exe: "", path: "", isGame: false}
}

; Save a mode for an app and apply it now. Saving a mode for an app that
; wasn't detected yet also marks it as a game from here on.
ApplyModeTo(exe, path, mode, *) {
    global turboMode, knownHow
    if (mode = "ignore") {
        SetIgnored(exe, true)
        return
    }
    ; "This is a game", or Default on something not yet a game: add it.
    isGameNow := (isTurboMode && exe = turboExe) || addedGames.Has(exe) || learned.Has(exe) || gameModes.Has(exe)
    if (mode = "add" || (mode = "" && !isGameNow)) {
        if notGames.Has(exe)
            SetIgnored(exe, false)
        addedGames[exe] := FormatTime(, "yyyy-MM-dd")
        IniWrite(addedGames[exe], STATE, "added", exe)
        Log("ADDED       " exe " (from tray)")
        mode := ""
    } else {
        SetGameMode(exe, mode)
    }
    if (isTurboMode && exe = turboExe) {
        turboMode := GameModeFor(exe)
        SetPerfMode(CapMode(turboMode), "game " turboExe)
    } else if (path != "" && GameModesActive() && manualOverride = "None") {
        knownHow := addedGames.Has(exe) ? "added by you" : "saved mode"
        EngageTurbo("game", path)
        return
    }
    shown := (mode = "") ? "Default (" ModeName(DEFAULT_GAME_MODE) ")" : ModeName(mode)
    ShowOSD(exe ": " shown " (saved)", GameModeFor(exe) = 1 ? "Red" : "Blue")
}

; Ctrl+Alt+G: cycle the target Turbo -> Balanced -> Silent, apply, remember.
CycleGameMode(*) {
    t := GameTarget()
    if (t.exe = "") {
        ShowOSD("No game or GPU app to set", "Blue")
        return
    }
    cur := (t.isGame && isTurboMode) ? turboMode : GameModeFor(t.exe)
    ch := ModeChoices()
    i := IndexOf(ch, cur)
    ApplyModeTo(t.exe, t.path, ch[Mod(i, ch.Length) + 1])
}

SetGameMode(exe, mode) {
    if notGames.Has(exe)
        SetIgnored(exe, false)
    if (mode = "") {
        gameModes.Delete(exe)
        try IniDelete(STATE, "gamemodes", exe)
        Log("GAME MODE   " exe " reset to default (" ModeName(DEFAULT_GAME_MODE) ")")
    } else {
        gameModes[exe] := mode
        IniWrite(mode, STATE, "gamemodes", exe)
        Log("GAME MODE   " exe " set to " ModeName(mode))
    }
}

; Ignore = "this exe is a launcher / not a game". It never counts as a
; game again (known-game check, load detection, learning) until you pick
; a mode for it. If it's holding a game mode right now, that ends at once.
SetIgnored(exe, on) {
    global isTurboMode
    if on {
        notGames[exe] := FormatTime(, "yyyy-MM-dd")
        IniWrite(notGames[exe], STATE, "notgames", exe)
        if learned.Has(exe) {
            learned.Delete(exe)
            try IniDelete(STATE, "learned", exe)
        }
        if gameModes.Has(exe) {
            gameModes.Delete(exe)
            try IniDelete(STATE, "gamemodes", exe)
        }
        Log("IGNORED     " exe " (launcher / not a game)")
        if (isTurboMode && exe = turboExe) {
            RestoreIdleMode()
            isTurboMode := false
            Log("GAME OFF    " exe " ignored")
        }
        ShowOSD(exe ": marked as not a game", "Blue")
    } else if notGames.Has(exe) {
        notGames.Delete(exe)
        try IniDelete(STATE, "notgames", exe)
        Log("UNIGNORED   " exe)
    }
}

; Forget = clean slate. Drops learned status, saved mode, and ignore,
; so the script can learn it again naturally later.
ForgetGame(exe) {
    if learned.Has(exe) {
        learned.Delete(exe)
        try IniDelete(STATE, "learned", exe)
    }
    if gameModes.Has(exe) {
        gameModes.Delete(exe)
        try IniDelete(STATE, "gamemodes", exe)
    }
    if notGames.Has(exe) {
        notGames.Delete(exe)
        try IniDelete(STATE, "notgames", exe)
    }
    if addedGames.Has(exe) {
        addedGames.Delete(exe)
        try IniDelete(STATE, "added", exe)
    }
    if seenGames.Has(exe) {
        seenGames.Delete(exe)
        try IniDelete(STATE, "seen", exe)
    }
    Log("FORGOT      " exe " (clean slate, can be relearned)")
    ShowOSD("Forgot " exe, "Blue")
}

QualifiesAsGame(top) {
    if (top.util >= GameLoadBackground)
        return true
    return (top.util >= GameLoadForeground && IsFullscreenForeground(top.pid))
}

; True when the front window belongs to this process and covers its whole
; monitor (exclusive fullscreen or borderless). Maximized windows leave the
; taskbar visible, so they don't count.
IsFullscreenForeground(pid) {
    try {
        hwnd := WinExist("A")
        if (!hwnd || WinGetPID(hwnd) != pid)
            return false
        WinGetPos(&x, &y, &w, &h, hwnd)
        mon := DllCall("MonitorFromWindow", "Ptr", hwnd, "UInt", 2, "Ptr")
        mi := Buffer(40, 0)
        NumPut("UInt", 40, mi, 0)
        DllCall("GetMonitorInfoW", "Ptr", mon, "Ptr", mi)
        ml := NumGet(mi, 4, "Int"), mt := NumGet(mi, 8, "Int")
        mr := NumGet(mi, 12, "Int"), mb := NumGet(mi, 16, "Int")
        return (x <= ml && y <= mt && x + w >= mr && y + h >= mb)
    }
    return false
}

; ---------- per-process GPU load (same counters as Task Manager) ----------
GpuPdhInit() {
    global pdhQuery, pdhCounter, gpuDiag
    q := 0, c := 0
    if (r := DllCall("pdh\PdhOpenQueryW", "Ptr", 0, "UPtr", 0, "Ptr*", &q, "UInt")) {
        gpuDiag := "PDH open " Format("0x{:X}", r)
        return false
    }
    ; Full wildcard; 3D engines are filtered by name below. Partial
    ; wildcards like (*engtype_3D) aren't reliable through this API.
    if (r := DllCall("pdh\PdhAddEnglishCounterW", "Ptr", q, "WStr", "\GPU Engine(*)\Utilization Percentage", "UPtr", 0, "Ptr*", &c, "UInt")) {
        DllCall("pdh\PdhCloseQuery", "Ptr", q)
        gpuDiag := "PDH add " Format("0x{:X}", r)
        return false
    }
    DllCall("pdh\PdhCollectQueryData", "Ptr", q)    ; first sample; rates need two
    pdhQuery := q, pdhCounter := c
    return true
}

GpuPdhClose() {
    global pdhQuery, pdhCounter
    if pdhQuery
        DllCall("pdh\PdhCloseQuery", "Ptr", pdhQuery)
    pdhQuery := 0, pdhCounter := 0
}

; Method 1: Windows performance counter API. Returns {map: pid->load, n} or 0.
GatherGpuPdh() {
    global gpuDiag
    static calls := 0
    if (!pdhQuery && !GpuPdhInit())
        return 0
    if (++calls >= 120) {                   ; refresh the query every ~10 minutes
        calls := 0
        GpuPdhClose()
        GpuPdhInit()
        gpuDiag := "PDH re-init"
        return -1                           ; skip this tick: a fresh query has no sample window yet
    }
    if (r := DllCall("pdh\PdhCollectQueryData", "Ptr", pdhQuery, "UInt")) {
        gpuDiag := "PDH collect " Format("0x{:X}", r)
        return 0
    }
    size := 0, count := 0
    r := DllCall("pdh\PdhGetFormattedCounterArrayW", "Ptr", pdhCounter, "UInt", 0x8200, "UInt*", &size, "UInt*", &count, "Ptr", 0, "UInt")
    if !size {
        gpuDiag := "PDH size " Format("0x{:X}", r)
        return 0
    }
    Loop 3 {                                ; a process starting between calls grows the array
        buf := Buffer(size, 0)
        r := DllCall("pdh\PdhGetFormattedCounterArrayW", "Ptr", pdhCounter, "UInt", 0x8200, "UInt*", &size, "UInt*", &count, "Ptr", buf, "UInt")
        if (r != 0x800007D2)                ; PDH_MORE_DATA
            break
    }
    if r {
        gpuDiag := "PDH read " Format("0x{:X}", r)
        return 0
    }
    perPid := Map(), n := 0
    Loop count {
        off := (A_Index - 1) * 24           ; name ptr, status, pad, double
        if (NumGet(buf, off + 8, "UInt") > 1)
            continue
        name := StrGet(NumGet(buf, off, "Ptr"), "UTF-16")
        if !InStr(name, "engtype_3D")
            continue
        if !RegExMatch(name, "^pid_(\d+)_", &m)
            continue
        n++
        pid := Integer(m[1])
        perPid[pid] := (perPid.Has(pid) ? perPid[pid] : 0) + NumGet(buf, off + 16, "Double")
    }
    if !n {
        gpuDiag := "PDH: " count " engines, none 3D"
        return 0
    }
    return {map: perPid, n: n}
}

; Method 2: raw counters through WMI, with the percentage worked out here
; from two samples. Much quicker than WMI's pre-formatted class.
GatherGpuWmiRaw() {
    global gpuDiag
    static svc := 0, prev := Map(), prevT := 0
    try {
        if !svc
            svc := ComObjGet("winmgmts:\\.\root\cimv2")
        cur := Map(), t := 0
        for item in svc.ExecQuery("SELECT Name, UtilizationPercentage, Timestamp_Sys100NS FROM Win32_PerfRawData_GPUPerformanceCounters_GPUEngine WHERE Name LIKE '%engtype_3D'") {
            cur[item.Name] := Integer(item.UtilizationPercentage)
            t := Integer(item.Timestamp_Sys100NS)
        }
        if !cur.Count {
            gpuDiag .= " | WMI raw: no 3D engines"
            return 0
        }
        perPid := Map()
        dt := t - prevT
        if (prevT && dt > 0) {
            for name, u in cur {
                if !prev.Has(name) || !RegExMatch(name, "^pid_(\d+)_", &m)
                    continue
                pct := (u - prev[name]) / dt * 100
                if (pct <= 0)
                    continue
                pid := Integer(m[1])
                perPid[pid] := (perPid.Has(pid) ? perPid[pid] : 0) + pct
            }
        }
        prev := cur, prevT := t
        return {map: perPid, n: cur.Count}
    } catch as e {
        gpuDiag .= " | WMI raw: " e.Message
    }
    return 0
}

; Method 3: WMI's pre-formatted class. Slowest; last resort.
GatherGpuWmi() {
    global gpuDiag
    static svc := 0
    try {
        if !svc
            svc := ComObjGet("winmgmts:\\.\root\cimv2")
        perPid := Map(), n := 0
        for item in svc.ExecQuery("SELECT Name, UtilizationPercentage FROM Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine WHERE Name LIKE '%engtype_3D'") {
            if !RegExMatch(item.Name, "^pid_(\d+)_", &m)
                continue
            n++
            pid := Integer(m[1])
            perPid[pid] := (perPid.Has(pid) ? perPid[pid] : 0) + item.UtilizationPercentage
        }
        if n
            return {map: perPid, n: n}
        gpuDiag .= " | WMI: no 3D engines"
    } catch as e {
        gpuDiag .= " | WMI: " e.Message
    }
    return 0
}

; Returns the single non-ignored app with the highest 3D load right now.
TopGpuProcess() {
    global gpuSrc, gpuDiag, pdhFailNote
    res := {pid: 0, exe: "", path: "", util: 0, rawExe: "", rawUtil: 0, samples: 0}

    static pdhFails := 0
    data := 0
    if (gpuSrc != "wmi") {
        data := GatherGpuPdh()
        if (!IsObject(data) && data = -1)   ; query just refreshed: no reading this tick
            return res
        pdhFails := IsObject(data) ? 0 : pdhFails + 1
        if (!IsObject(data) && pdhFails < 3)
            return res                      ; one bad reading isn't a reason to give up on PDH
    }
    if !IsObject(data) {
        pdhNote := gpuDiag
        data := GatherGpuWmiRaw()
        if !IsObject(data)
            data := GatherGpuWmi()
        if IsObject(data) {
            if (gpuSrc != "wmi") {
                pdhFailNote := (pdhNote = "") ? "no error code" : pdhNote
                Log("COUNTERS    fast method failed (" pdhFailNote "), switched to WMI")
            }
            gpuSrc := "wmi"                 ; PDH failed, WMI works: stick with it
        }
    }
    if !IsObject(data)
        return res
    gpuDiag := ""

    ; Track two things: the top app overall (proves the counters are live,
    ; even when the winner is an ignored app like Chrome) and the top app
    ; that actually counts toward turbo.
    rawExe := "", rawUtil := 0
    for pid, v in data.map {
        if (pid = 0 || (v <= res.util && v <= rawUtil))
            continue
        try
            path := ProcessGetPath(pid)
        catch
            continue
        if (path = "")
            continue
        SplitPath(path, &exe)
        if (v > rawUtil)
            rawExe := StrLower(exe), rawUtil := v
        if (v > res.util && !IsIgnored(path))
            res := {pid: pid, exe: StrLower(exe), path: path, util: Min(Round(v), 100)}
    }
    res.rawExe := rawExe
    res.rawUtil := Min(Round(rawUtil), 100)
    res.samples := data.n
    return res
}

; ---------- activity log ----------
; One line per decision, newest at the bottom. Rolls over at 256 KB,
; keeping the previous file as activity.old.log.
Log(msg) {
    try {
        if (FileExist(LOGFILE) && FileGetSize(LOGFILE) > 262144)
            FileMove(LOGFILE, installDir "\activity.old.log", true)
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " msg "`n", LOGFILE, "UTF-8")
    }
}

; ---------- ignore list, learned games ----------
IsIgnored(path) {
    for x in IgnoredExecutables
        if InStr(path, x)
            return true
    for x in LauncherExecutables
        if InStr(path, x)
            return true
    SplitPath(path, &exe)
    return notGames.Has(StrLower(exe))
}

LoadIniMap(section) {
    m := Map()
    try {
        for line in StrSplit(IniRead(STATE, section), "`n") {
            if (p := InStr(line, "="))
                m[SubStr(line, 1, p - 1)] := SubStr(line, p + 1)
        }
    }
    return m
}

LearnGame(exe) {
    learned[exe] := FormatTime(, "yyyy-MM-dd")
    IniWrite(learned[exe], STATE, "learned", exe)
    Log("LEARNED     " exe " saved as a game")
    ShowOSD("Learned: " exe " is a game", "Green")
}

ShowGames(*) {
    g := Gui("+AlwaysOnTop", "Apps and games")
    g.SetFont("s10", "Segoe UI")
    W := 820
    custom := []
    for m in ModeChoices()
        if (m >= 3)
            custom.Push(m)
    g.Add("Text", "w" W, "Games Performance Companion detected, plus any app you added. Games are the main event, but any power-hungry app works "
        . "the same way: add FL Studio, Blender, Premiere or a local AI model and it gets its own mode while it runs. "
        . "Anything without a saved mode uses the default: " ModeName(DEFAULT_GAME_MODE) ".`n"
        . "Not a game = a launcher or tool that should never trigger. Remove = delete it from the list. Ctrl+Alt+G cycles the mode in-game.")
    lv := g.Add("ListView", "w" W " r14 -Multi Sort", ["App or game", "Detected by", "Mode", "Last seen"])
    AddTip(lv, "Select an app or game, then use a button below.`n"
        . "Detected by: how Performance Companion recognizes it.`n"
        . "  added by you = you added it here`n"
        . "  learned = picked up automatically from sustained GPU load`n"
        . "  Steam / publisher folder / Xbox = recognized from where it's installed`n"
        . "  GPU load = caught by load but not learned yet")

    b := g.Add("Button", "w100", ModeName(1))
    b.OnEvent("Click", (*) => SetSel(1))
    AddTip(b, "Always run this in " ModeName(1) ".`nMaximum power, fans run fastest.`nBest for demanding games, renders and AI models.")

    b := g.Add("Button", "x+8 w100", ModeName(0))
    b.OnEvent("Click", (*) => SetSel(0))
    AddTip(b, "Always run this in " ModeName(0) ".`nPlenty for lighter games and apps.`nLess heat and fan noise than " ModeName(1) ".")

    b := g.Add("Button", "x+8 w100", ModeName(2))
    b.OnEvent("Click", (*) => SetSel(2))
    AddTip(b, "Always run this in " ModeName(2) ".`nLowest power and quietest fans.`nGood for card games, older titles, or late nights.")

    if custom.Length {
        names := []
        for m in custom
            names.Push(ModeName(m))
        cdd := g.Add("DropDownList", "x+16 w170", names)
        cdd.Choose(1)
        AddTip(cdd, "Your own G-Helper modes, by the names you gave them in G-Helper.`n"
            . "For example a quiet mode with full power for music or video work.")
        b := g.Add("Button", "x+4 w60", "Use")
        b.OnEvent("Click", (*) => SetSel(custom[cdd.Value]))
        AddTip(b, "Always run the selected app in the custom mode picked on the left.")
    }

    b := g.Add("Button", "xm y+8 w80", "Default")
    b.OnEvent("Click", (*) => SetSel(""))
    AddTip(b, "Clear this game's saved mode so it follows the default`n(currently " ModeName(DEFAULT_GAME_MODE) "). Also un-ignores it.")

    b := g.Add("Button", "x+8 w90", "Not a game")
    b.OnEvent("Click", (*) => IgnoreSel())
    AddTip(b, "This exe is a launcher or not a game.`nIt will never trigger a game mode again.`nPick any mode later to undo.")

    b := g.Add("Button", "x+8 w80", "Remove")
    b.OnEvent("Click", Forget)
    AddTip(b, "Remove this game from the list completely: added, learned, saved mode,`n"
        . "ignore, and history. If it loads the GPU later, it can be learned again.")

    b := g.Add("Button", "x+8 w150", "Add app or game...")
    b.OnEvent("Click", (*) => AddGame())
    AddTip(b, "Pick a game's or app's .exe file. It gets its mode the moment it opens,`n"
        . "without waiting for GPU load. Use this for DAWs, editors, renderers and AI tools too.")

    b := g.Add("Button", "x+8 w70", "Close")
    b.OnEvent("Click", (*) => CloseGames())
    AddTip(b, "Close this window. Changes are already saved.")
    g.OnEvent("Close", (*) => CloseGames())
    Fill()
    g.Show()

    Fill() {
        lv.Delete()
        all := Map()
        for src in [addedGames, learned, gameModes, notGames, seenGames]
            for exe in src
                all[exe] := 1
        for exe in all {
            last := ""
            seenHow := ""
            if seenGames.Has(exe) {
                parts := StrSplit(seenGames[exe], "|", , 2)
                last := parts[1]
                seenHow := parts.Length > 1 ? parts[2] : ""
            }
            if notGames.Has(exe) {
                lv.Add(, exe, "you ignored it " notGames[exe], "Ignored", last)
                continue
            }
            how := addedGames.Has(exe) ? "added by you"
                : learned.Has(exe) ? "learned " learned[exe]
                : seenHow != "" ? seenHow
                : "saved mode"
            mode := gameModes.Has(exe) ? ModeName(gameModes[exe]) : ModeName(DEFAULT_GAME_MODE) " (default)"
            lv.Add(, exe, how, mode, last = "" ? "not yet" : last)
        }
        lv.ModifyCol(1, 260), lv.ModifyCol(2, 190), lv.ModifyCol(3, 150), lv.ModifyCol(4, "AutoHdr")
    }

    AddGame() {
        g.Opt("-AlwaysOnTop")
        path := FileSelect(1, A_ProgramFiles, "Choose a game or app (.exe)", "Programs (*.exe)")
        g.Opt("+AlwaysOnTop")
        if (path = "")
            return
        SplitPath(path, &exe)
        e := StrLower(exe)
        if notGames.Has(e)
            SetIgnored(e, false)
        addedGames[e] := FormatTime(, "yyyy-MM-dd")
        IniWrite(addedGames[e], STATE, "added", e)
        Log("ADDED       " e " (" path ")")
        ShowOSD("Added " e " as a game", "Green")
        Fill()
    }

    Selected() {
        row := lv.GetNext(0)
        return row ? lv.GetText(row, 1) : ""
    }

    SetSel(mode) {
        global turboMode
        exe := Selected()
        if (exe = "")
            return
        SetGameMode(exe, mode)
        if (isTurboMode && exe = turboExe) {          ; it's running: apply now
            turboMode := GameModeFor(exe)
            SetPerfMode(CapMode(turboMode), "game " turboExe)
        }
        Fill()
    }

    CloseGames() {
        ClearTips(g)
        g.Destroy()
    }

    IgnoreSel() {
        exe := Selected()
        if (exe = "")
            return
        SetIgnored(exe, true)
        Fill()
    }

    Forget(*) {
        exe := Selected()
        if (exe = "")
            return
        ForgetGame(exe)
        Fill()
    }
}

; ---------- hover help for window controls ----------
; Uses Windows' own tooltip control: each window gets one, and every
; control registered with AddTip shows its text when the mouse rests on it.
AddTip(ctrl, text) {
    g := ctrl.Gui
    if !hoverTips.Has(g.Hwnd) {
        ; WS_POPUP | TTS_NOPREFIX | TTS_ALWAYSTIP, topmost so it shows over AlwaysOnTop windows
        tt := DllCall("CreateWindowEx", "UInt", 0x8, "Str", "tooltips_class32", "Ptr", 0, "UInt", 0x80000003,
            "Int", 0x80000000, "Int", 0x80000000, "Int", 0x80000000, "Int", 0x80000000,
            "Ptr", g.Hwnd, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr")
        SendMessage(0x418, 0, 520, tt)            ; TTM_SETMAXTIPWIDTH: wrap long text, honor line breaks
        SendMessage(0x403, 2, 30000, tt)          ; TTM_SETDELAYTIME autopop: stay up 30 s
        SendMessage(0x403, 3, 400, tt)            ; initial delay
        hoverTips[g.Hwnd] := tt
    }
    if (ctrl.Type = "Text")
        ctrl.Opt("+0x100")                        ; SS_NOTIFY: labels must receive the mouse to show a tip
    ti := Buffer(A_PtrSize = 8 ? 72 : 48, 0)      ; TOOLINFOW
    NumPut("UInt", ti.Size, ti, 0)
    NumPut("UInt", 0x11, ti, 4)                   ; TTF_IDISHWND | TTF_SUBCLASS
    NumPut("Ptr", g.Hwnd, ti, 8)
    NumPut("Ptr", ctrl.Hwnd, ti, 8 + A_PtrSize)
    NumPut("Ptr", StrPtr(text), ti, 8 + A_PtrSize * 3 + 16)
    SendMessage(0x432, 0, ti.Ptr, hoverTips[g.Hwnd])   ; TTM_ADDTOOLW (copies the text)
}

; The tooltip window is destroyed along with its owner; just forget it.
ClearTips(g) {
    try {
        if hoverTips.Has(g.Hwnd)
            hoverTips.Delete(g.Hwnd)
    }
}

WatchText(top) {
    turbo := isTurboMode ? " | " StrUpper(ModeName(turboMode)) : ""
    if !top.HasOwnProp("samples") || top.samples = 0
        return "Watch: no GPU data" (gpuDiag != "" ? " (" gpuDiag ")" : " yet") turbo
    src := (gpuSrc = "wmi") ? " [wmi]" : ""
    if (top.exe != "")
        return "Watch: " top.exe " " top.util "%" src turbo
    if (top.rawExe != "" && top.rawUtil > 0)
        return "Watch: idle | top: " top.rawExe " " top.rawUtil "% (ignored)" src turbo
    return "Watch: idle | GPU quiet" src turbo
}

ToggleWatch(*) {
    global watchGpu
    watchGpu := !watchGpu
    UpdateUI()
    UpdateWatch(watchGpu ? "Watch: waiting for first reading..." : "")
}

CheckPassiveGamingState() {
    global knownHow
    try {
        steamAppID := RegRead("HKCU\Software\Valve\Steam", "RunningAppID")
        if (steamAppID != 0 && steamAppID != "") {
            ignoreSteamApp := false
            for id in IgnoredSteamAppIDs {
                if (steamAppID == id) {
                    ignoreSteamApp := true
                    break
                }
            }
            if (!ignoreSteamApp) {
                ; Use Steam's own name for the game so saved modes read
                ; "steam: cyberpunk 2077" instead of a bare number.
                name := ""
                try name := RegRead("HKCU\Software\Valve\Steam\Apps\" steamAppID, "Name")
                name := RegExReplace(name, "[=\[\]\\/]", " ")
                key := (name != "") ? "Steam: " name : "Steam AppID " steamAppID
                if !notGames.Has(StrLower(key)) {
                    knownHow := "Steam"
                    return key
                }
            }
        }
    }

    for hwnd in WinGetList() {
        try {
            if !(WinGetStyle(hwnd) & 0x10000000)
                continue

            procPath := ProcessGetPath(WinGetPID(hwnd))
            if (procPath == "" || IsIgnored(procPath))
                continue

            SplitPath(procPath, &exeName)
            e := StrLower(exeName)
            if addedGames.Has(e) {
                knownHow := "added by you"
                return procPath
            }
            if learned.Has(e) {
                knownHow := "learned " learned[e]
                return procPath
            }
            if gameModes.Has(e) {
                knownHow := "saved mode"
                return procPath
            }
            for gameDir in cachedGameDirs
                if InStr(procPath, gameDir) {
                    knownHow := "publisher folder"
                    return procPath
                }
            if InStr(procPath, "\XboxGames\") {
                knownHow := "Xbox"
                return procPath
            }
        }
    }
    return false
}

; The no-game mode for the active profile and power source.
IdleMode() => OnAC() ? CurP().ac : CurP().battery
RestoreIdleMode() => SetPerfMode(IdleMode(), "no game")

; A game's mode as it will actually run, noting a profile limit if one applies.
ModeShown(m) => (CapMode(m) != m) ? ModeName(CapMode(m)) " (" CurP().name " limit)" : ModeName(m)

; ====================================================================
;  TRAY MENU AND STATUS
; ====================================================================
UpdateUI() {
    BuildMenu()
    UpdateTip()
}

; Rebuilt every time the tray icon is right-clicked, so the game line
; always reflects what's running right now.
BuildMenu() {
    m := A_TrayMenu
    m.Delete()

    if IsObject(updateInfo) {
        upd := "Update to " updateInfo.version
        m.Add(upd, (*) => InstallUpdate())
        m.Add()
    }

    ; --- current game and its mode ---
    t := GameTarget()
    if (t.exe = "") {
        m.Add("Game: none detected", (*) => 0)
        m.Disable("Game: none detected")
    } else {
        cur := GameModeFor(t.exe)
        label := MenuText((t.isGame ? "Game: " : "Top GPU app: ") t.exe " ("
            . (t.isGame ? ModeShown(isTurboMode ? turboMode : cur) : ModeName(cur))
            . (gameModes.Has(t.exe) ? ", saved" : t.isGame ? "" : ", not a game yet") ")")
        sub := Menu()
        if !t.isGame && !gameModes.Has(t.exe) {
            sub.Add("This is a game (add it)", ApplyModeTo.Bind(t.exe, t.path, "add"))
            sub.Add()
        }
        for mode in ModeChoices() {
            item := ModeName(mode)
            sub.Add(item, ApplyModeTo.Bind(t.exe, t.path, mode))
            if (gameModes.Has(t.exe) && Integer(gameModes[t.exe]) = mode)
                sub.Check(item)
        }
        sub.Add()
        sub.Add("Default (" ModeName(DEFAULT_GAME_MODE) ")", ApplyModeTo.Bind(t.exe, t.path, ""))
        if !gameModes.Has(t.exe)
            sub.Check("Default (" ModeName(DEFAULT_GAME_MODE) ")")
        sub.Add()
        sub.Add("Not a game", ApplyModeTo.Bind(t.exe, t.path, "ignore"))
        m.Add(label, sub)
    }
    tip := "      Ctrl+Alt+G cycles this in-game"
    m.Add(tip, (*) => 0)
    m.Disable(tip)
    m.Add()

    ; --- profile switcher: the active one is ticked, click another to switch ---
    p := CurP()
    title := "Switch profile"
    m.Add(title, (*) => 0)
    m.Disable(title)
    target := m
    if (profileOrder.Length > 6) {
        target := Menu()
        m.Add(MenuText(p.name " (active)"), target)
    }
    for id in profileOrder {
        q := profiles[id]
        if (id = profile) {
            lbl := MenuText(q.name "   (" ProfileSummary(q) ")")
            target.Add(lbl, (*) => ShowOSD(CurP().name " is already active", "Blue", true))
            target.Check(lbl)
        } else {
            plan := SwitchPlan(id)
            target.Add(MenuText(q.name "   (" ProfileSummary(q) (plan.ending != "none" ? ", " EndingWord(plan.ending) : "") ")"),
                SwitchToProfile.Bind(id, "manual"))
        }
    }
    if ProfileMismatch() {
        fin := MenuText("Finish switching to " p.name " (" (p.gpu = "ultimate" ? "Ultimate, " : "leave Ultimate, ")
            . (p.gpu != "ultimate" && p.after = "shutdown" ? "shut down" : "restart") ")")
        m.Add(fin, FinishSwitch)
        m.Default := fin
    }
    m.Add()

    ; --- set things up ---
    m.Add("Profiles...", ShowProfiles)
    nx := NextScheduleText()
    m.Add("Schedules..." (nx != "" ? "   (" nx ")" : SCHEDULES_ENABLED ? "" : "   (off)"), ShowSchedules)
    m.Add("Apps and games...", ShowGames)
    m.Add("Settings...", ShowSettings)
    m.Add()

    ; --- help ---
    m.Add("Report an issue...", ReportIssue)
    m.Add("Help and troubleshooting...", ShowHelp)
    m.Add()
    m.Add("Exit", (*) => ExitApp())
}

; Short "next scheduled action" for the tray menu, e.g. "Fri 19:00 Gaming".
NextScheduleText() {
    if !SCHEDULES_ENABLED
        return ""
    if IsObject(schedPending) && schedules.Has(schedPending.sid)
        return "now: " PName(schedPending.profile) " at " FormatTime(schedPending.due, "HH:mm")
    best := "", bestP := ""
    for sid in schedOrder {
        s := schedules[sid]
        if !s.enabled
            continue
        for t in Triggers(s)
            if ((o := NextOcc(t, A_Now)) != "" && (best = "" || o < best))
                best := o, bestP := t.profile
    }
    return best = "" ? "" : "next: " FormatTime(best, "ddd HH:mm") " " PName(bestP)
}

; Tray tooltip: profile plus what's actually happening right now, e.g.
;   PerfCompanion: Gaming | AC | Turbo (eldenring.exe)
;   PerfCompanion: Work | Battery | Eco | Silent
UpdateTip() {
    UpdateTrayIcon()
    ac := OnAC()
    p := CurP()
    tip := "PerfCompanion: " p.name " | " (ac ? "AC" : "Battery " BatteryPct() "%")
    if HasGH() {
        txt := ReadCfg()
        gm := GetJsonInt(txt, "gpu_mode")
        if (p.gpu != "ultimate" && gm != "")
            tip .= " | " GpuName(gm)
        tip .= " | " ModeName(GetJsonInt(txt, PerfKey()))
    } else {
        k := PlanKeyOf(ActivePlanGuid())
        tip .= " | " (k = "" ? "other plan" : ModeName(KeyMode(k)))
    }
    if (manualOverride != "None")
        tip .= " (manual lock)"
    else if (isTurboMode && turboExe != "")
        tip .= " (" turboExe ")"
    if (HasGH() && p.gpu = "ultimate" && !ac && gm = 2)
        tip .= " | Ultimate on battery"
    if ProfileMismatch()
        tip .= " | restart to finish"
    if paused
        tip .= " | PAUSED"
    else if !automationOK
        tip .= " | " (HasGH() ? "self-test failed" : "plans missing")
    A_IconTip := SubStr(tip, 1, 127)
}

TogglePause(*) {
    global paused
    paused := !paused
    Log(paused ? "PAUSE       automation paused" : "PAUSE       automation resumed")
    UpdateUI()
    ShowOSD(paused ? "Automation paused" : "Automation resumed", "Blue")
}

ShowStatus(*) {
    p := CurP()
    t := "Profile: " p.name " (" ProfileSummary(p) ")`n"
        . "Device: " (DEVICE.handheld != "" ? DEVICE.handheld : DEVICE.maker " " DEVICE.model) "`n"
        . "Engine: " EngineName() "`n"
        . "Power: " (OnAC() ? "AC" : "battery (" BatteryPct() "%)") "`n"
        . "Mode now: " ModeName(CurrentPerfMode()) " (wanted: " ModeName(ExpectedPerf()) ")`n"
    if HasGH() {
        txt := ReadCfg()
        ov := IniRead(STATE, "app", "charge_override", "")
        t .= "GPU: " GpuName(GetJsonInt(txt, "gpu_mode")) (ProfileMismatch() ? " (restart to finish switching)" : "") "`n"
            . "Charge limit: " GetJsonInt(txt, "charge_limit") "%" (ov != "" ? " (trip charging; " p.name " is " p.charge "%)" : "") "`n"
            . "G-Helper: " CurrentVersion() " (validated: " IniRead(STATE, "ghelper", "validated", "never") ")"
            . ", custom modes: " customModes.Count "`n"
    } else {
        t .= "Power plan: " PlanFriendlyName(ActivePlanGuid()) "`n"
            . "Windows power mode: " (overlayOK = "" ? "not set yet" : overlayOK ? "set by Performance Companion" : "not accepted on this PC") "`n"
    }
    t .= "Game modes: " GamesLabel(p.games) (p.cap != "none" ? ", limit " ModeName(p.cap = "silent" ? 2 : 0) : "")
            . (GameModesActive() ? " (active now)" : " (not active now)") "`n"
        . "App or game running: " (isTurboMode ? turboExe " (" turboSource ", " ModeShown(turboMode) ")" : "none") "`n"
        . "Automation: " (paused ? "paused" : automationOK ? "active" : "stopped (" (HasGH() ? "self-test failed" : "power plans missing") ")") "`n"
        . "Schedules: " (!SCHEDULES_ENABLED ? "off" : (NextScheduleText() = "" ? "on, nothing coming up" : "on, " NextScheduleText())) "`n"
        . "When unplugged: " (BATTERY_PROFILE = "" ? "stay on the current profile" : "switch to " PName(BATTERY_PROFILE)) "`n"
        . "Performance Companion: " SCRIPT_VERSION "`n`n"
        . "Top GPU app (last check): " (lastTop.exe = "" ? "none" : lastTop.exe " at " lastTop.util "%") "`n"
        . "Learned games: " learned.Count ", added apps: " addedGames.Count ", saved modes: " gameModes.Count "`n"
        . "GPU counters: " (gpuSrc = "wmi" ? "WMI fallback (fast method: " (pdhFailNote = "" ? "unknown" : pdhFailNote) ")" : "fast method (PDH)")
    MsgBox(t, "Performance Companion status", "Iconi")
}

ClearLog(*) {
    if (MsgBox("Delete the activity log? (It also trims itself: at 256 KB it starts fresh and keeps one older copy.)",
        "Performance Companion", "YesNo Icon?") != "Yes")
        return
    for f in [LOGFILE, installDir "\activity.old.log"]
        try FileDelete(f)
    Log("LOG         cleared")
    ShowOSD("Activity log cleared", "Green", true)
}

; ---------- Help and troubleshooting window ----------
; Everything diagnostic in one place, so the tray menu stays short.
ShowHelp(*) {
    static open := 0
    if open {
        try WinActivate("ahk_id " open)
        return
    }
    g := Gui("+AlwaysOnTop", "Performance Companion help and troubleshooting")
    open := g.Hwnd
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 16, g.MarginY := 12
    g.Add("Text", "xm w520", "Something not right? Report an issue sends us everything needed to fix it. "
        . "The rest is here if you want to look under the hood. Version " SCRIPT_VERSION ", " EngineName() ".")

    Btn(label, desc, fn, first := false) {
        b := g.Add("Button", "xm " (first ? "y+14" : "y+6") " w190", label)
        b.OnEvent("Click", fn)
        g.SetFont("s9 cGray")
        g.Add("Text", "x+10 yp+5 w320", desc)
        g.SetFont("s10 norm cDefault")
        return b
    }
    Head(text) {
        g.SetFont("s10 bold")
        g.Add("Text", "xm y+16 w520", text)
        g.SetFont("s10 norm")
    }

    Btn("Report an issue...", "Opens a bug report with your diagnostics filled in.", (*) => (Close(), ReportIssue()), true)
    Btn("Online guide", "The README: setup, everyday use and fixes for common problems.", (*) => Run(REPO_URL "#readme"))
    Btn("Check for updates", "See if there's a newer version now.", (*) => CheckForUpdates(true))

    Head("Look under the hood")
    Btn("Status", "What profile, mode and engine are active right now.", ShowStatus, true)
    Btn("Setup check", "Checks your setup and your maker's app settings.", (*) => ShowSetupCheck("manual"))
    Btn("Open activity log", "One line per decision, with times.",
        (*) => FileExist(LOGFILE) ? Run('notepad.exe "' LOGFILE '"') : ShowOSD("No activity logged yet", "Blue", true))
    Btn("Copy diagnostics", "Copies the full report to paste anywhere yourself.", CopyDiagnostics)
    wb := Btn(watchGpu ? "Hide live GPU usage" : "Show live GPU usage", "A live panel showing which app loads the GPU and by how much.",
        (*) => (ToggleWatch(), wb.Text := watchGpu ? "Hide live GPU usage" : "Show live GPU usage"))
    if HasGH()
        Btn("Run G-Helper self-test", "Re-checks that G-Helper responds as expected.", (*) => SelfTest(CurrentVersion()))

    Head("Fix things")
    pb := Btn(paused ? "Resume" : "Pause", "Stops (or restarts) all automatic switching for now.",
        (*) => (TogglePause(), pb.Text := paused ? "Resume" : "Pause"))
    Btn("Reload", "Restarts Performance Companion. Settings are kept.", (*) => Reload())
    Btn("Clear activity log", "Deletes the log. It also trims itself automatically.", ClearLog)
    Btn("Reset everything...", "Settings, profiles" (HasGH() ? "" : " and power plans") " back to the defaults.", (*) => ResetEverything())
    Btn("Uninstall...", "Removes Performance Companion from this PC.", Uninstall)

    b := g.Add("Button", "xm y+18 w90 Default", "Close")
    b.OnEvent("Click", (*) => Close())
    g.OnEvent("Close", (*) => Close())
    g.OnEvent("Escape", (*) => Close())
    g.Show()

    Close() {
        open := 0
        ClearTips(g)
        g.Destroy()
    }

    ResetEverything() {
        r := MsgBox("Put Performance Companion back to how it was on install?`n`n"
            . "Resets all settings and profiles" (HasGH() ? "" : ", and the power plan settings") ", and turns schedules off.`n`n"
            . "Keep your games and apps list (learned, added and their modes)?`n"
            . "Yes = keep them, No = clear them too, Cancel = do nothing.",
            "Reset everything", "YesNoCancel Icon! Owner" g.Hwnd)
        if (r = "Cancel")
            return
        Log("RESET       everything back to defaults" (r = "No" ? ", games cleared" : ", games kept"))
        ResetSettings()
        SetSchedulesEnabled(false, SCHEDULES_ENABLED)
        if !HasGH()
            for k in PlanKeys() {
                try IniDelete(STATE, "plan." k)
                ApplyPlanSettings(k)
            }
        RestoreDefaultProfiles()
        if (r = "No")
            for sec in ["learned", "added", "gamemodes", "notgames", "seen"]
                try IniDelete(STATE, sec)
        Close()
        Reload()
    }
}
; ====================================================================
;  HOTKEYS
; ====================================================================
^!t:: {                                  ; Ctrl+Alt+T: lock the high mode (releases after 3 h or a power change)
    global manualOverride := "Turbo", manualSince := A_TickCount
    global isTurboMode := true
    SetPerfMode(1, "manual lock")
    ShowOSD("Manual lock: " ModeName(1), "Red")
    Log("MANUAL      " ModeName(1) " lock (Ctrl+Alt+T)")
}

^!b:: {                                  ; Ctrl+Alt+B: lock the middle mode
    global manualOverride := "Balanced", manualSince := A_TickCount
    global isTurboMode := false
    SetPerfMode(0, "manual lock")
    ShowOSD("Manual lock: " ModeName(0), "Green")
    Log("MANUAL      " ModeName(0) " lock (Ctrl+Alt+B)")
}

^#!t:: ShowProfilePicker()              ; Ctrl+Win+Alt+T: pick a profile
^!g:: CycleGameMode()                    ; Ctrl+Alt+G: cycle the current app's mode and save it

; ---------- on-screen popups ----------
; Positions are computed in real pixels inside the main screen's work area
; (above the taskbar), so they land correctly at any display scaling.
OsdScale() => A_ScreenDPI / 96

OsdRect(slot, &x, &y, &w, &h) {
    s := OsdScale()
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    w := Round((slot ? 560 : 380) * s), h := Round(46 * s)   ; watch panel is wider for long app names
    x := r - w - Round(16 * s)
    y := b - h - Round(16 * s) - slot * (h + Round(8 * s))   ; slot 1 stacks above slot 0
}

; One reusable popup: a new message replaces the old one and restarts its
; 3 second timer, instead of stacking windows on top of each other.
ShowOSD(text, color := "Green", force := false) {
    if (!SHOW_POPUPS && !force)
        return
    static g := 0, t := 0, hide := 0
    if !g {
        g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale")
        g.SetFont("s11 w700", "Segoe UI")
        g.MarginX := 0, g.MarginY := 0
        t := g.Add("Text", "cWhite Center 0x200")     ; 0x200 = vertically centered
        hide := () => g.Hide()
    }
    OsdRect(0, &x, &y, &w, &h)
    g.BackColor := (color == "Green") ? "1B5E20" : (color == "Red") ? "B71C1C" : "0D47A1"
    t.Move(0, 0, w, h)
    t.Value := text
    g.Show("NoActivate x" x " y" y " w" w " h" h)
    SetTimer(hide, -3000)
}

; Watch mode: a fixed panel that stays up and updates in place.
UpdateWatch(text := "") {
    static g := 0, t := 0
    if !watchGpu {
        if g
            g.Hide()
        return
    }
    if !g {
        g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale")
        g.SetFont("s10", "Consolas")
        g.MarginX := 0, g.MarginY := 0
        g.BackColor := "202020"
        t := g.Add("Text", "cWhite Center 0x200")
    }
    OsdRect(1, &x, &y, &w, &h)
    t.Move(0, 0, w, h)
    if (text != "")
        t.Value := text
    g.Show("NoActivate x" x " y" y " w" w " h" h)
}


; ====================================================================
;  DIAGNOSTICS AND ERROR CAPTURE
;  Copy diagnostics: one paste-ready report for bug reports. Usernames
;  and personal folders are masked so it's safe to post publicly.
;  Unexpected errors are logged with where they happened, instead of
;  AutoHotkey's error dialog, and the script keeps running.
; ====================================================================
GlobalError(e, mode) {
    global busy, switching
    static lastNotice := 0
    try {
        Log("ERROR       " e.Message " | in " e.What " at line " e.Line
            . (e.Extra != "" ? " | " SubStr(String(e.Extra), 1, 120) : "") " | " mode)
        busy := false, switching := false          ; never leave automation stuck after an error
        if (A_TickCount - lastNotice > 60000) {
            lastNotice := A_TickCount
            ShowOSD("Performance Companion hit an error and logged it. Tray > Report an issue", "Red", true)
        }
    }
    return (mode = "ExitApp") ? 0 : 1                ; 1 = handled: no dialog, keep running
}

Mask(s) {
    for p in [EnvGet("USERPROFILE"), A_AppData, EnvGet("LOCALAPPDATA")]
        if (p != "")
            s := StrReplace(s, p, p = A_AppData ? "%APPDATA%" : p = EnvGet("LOCALAPPDATA") ? "%LOCALAPPDATA%" : "%USERPROFILE%")
    if (A_UserName != "")
        s := RegExReplace(s, "i)\b\Q" A_UserName "\E\b", "<user>")
    if (A_ComputerName != "")
        s := RegExReplace(s, "i)\b\Q" A_ComputerName "\E\b", "<pc>")
    return s
}

WmiFirst(query, prop) {
    try {
        for x in ComObjGet("winmgmts:").ExecQuery(query)
            return Trim(x.%prop%)
    }
    return "unknown"
}

BuildDiagnostics() {
    r := "### Performance Companion diagnostics (" FormatTime(, "yyyy-MM-dd HH:mm") ")`n```````n"
    add(k, v) => r .= Format("{:-22}", k) v "`n"

    ; ---- system ----
    disp := ""
    try disp := RegRead("HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "DisplayVersion")
    gpus := ""
    try {
        for v in ComObjGet("winmgmts:").ExecQuery("SELECT Name FROM Win32_VideoController")
            gpus .= (gpus = "" ? "" : ", ") Trim(v.Name)
    }
    add("Performance Companion", SCRIPT_VERSION (importedFrom != "" ? " (imported from " importedFrom ")" : ""))
    add("Engine", EngineName() " (setting: " ENGINE_CHOICE ")")
    add("Device", DEVICE.kind (DEVICE.handheld != "" ? ", " DEVICE.handheld : "") " / " DEVICE.maker)
    add("AutoHotkey", A_AhkVersion (A_PtrSize = 8 ? " 64-bit" : " 32-bit") (A_IsAdmin ? ", admin" : ", NOT admin"))
    if HasGH()
        add("G-Helper", CurrentVersion() " (validated: " IniRead(STATE, "ghelper", "validated", "never") "), custom modes " customModes.Count)
    vend := []
    for proc in ["RazerAppEngine.exe", "LenovoVantage.exe", "LegionSpace.exe", "MSI Center.exe", "MSI.CentralServer.exe",
                  "AlienwareCommandCenter.exe", "OmenCommandCenterBackground.exe", "ArmouryCrate.exe", "ArmouryCrateSE.exe",
                  "HandheldCompanion.exe", "GHelper.exe"]
        if ProcessExist(proc)
            vend.Push(proc)
    add("Vendor apps running", vend.Length ? Join(vend, ", ") : "none found")
    add("Laptop", WmiFirst("SELECT Manufacturer, Model FROM Win32_ComputerSystem", "Model")
        . " / BIOS " WmiFirst("SELECT SMBIOSBIOSVersion FROM Win32_BIOS", "SMBIOSBIOSVersion"))
    add("GPUs", gpus = "" ? "unknown" : gpus)
    add("Windows", A_OSVersion (disp != "" ? " (" disp ")" : "") ", language " A_Language)
    add("Screen", A_ScreenWidth "x" A_ScreenHeight " at " Round(A_ScreenDPI / 96 * 100) "%")
    add("Power", OnAC() ? "AC" : "battery " BatteryPct() "%")
    add("Up since boot", Round(A_TickCount / 60000) " min")
    add("State", (paused ? "paused" : automationOK ? "active" : "self-test failed")
        . (busy ? ", busy" : "") (switching ? ", switching" : "") (isTurboMode ? ", game mode on (" turboExe ")" : ""))
    add("GPU counters", gpuSrc = "wmi" ? "WMI fallback (" (pdhFailNote = "" ? "?" : pdhFailNote) ")" : "PDH")
    add("Startup task", TaskExists(TASK_MAIN) ? "present" : "MISSING")

    add("Mode now / wanted", ModeName(CurrentPerfMode()) " / " ModeName(ExpectedPerf()))
    if HasGH() {
        ; ---- G-Helper config ----
        txt := ReadCfg()
        r .= "`n[G-Helper config]`n"
        if (txt = "")
            r .= "  could not read config.json`n"
        for k in ["gpu_mode", "gpu_auto", "charge_limit", "performance_0", "performance_1", "shutdown_gpu"]
            add("  " k, GetJsonInt(txt, k) = "" ? "(missing)" : GetJsonInt(txt, k))
        for id, nm in customModes
            add("  custom " id, nm)
    } else {
        r .= "`n[Power plans]`n"
        add("  active", PlanFriendlyName(ActivePlanGuid()))
        for k in PlanKeys()
            add("  " k, (PlanExists(PlanGuid(k)) ? "ok" : "MISSING") ", " PlanSummary(k))
        add("  power mode", overlayOK = "" ? "not tried" : overlayOK ? "accepted" : "not accepted")
        add("  built-in screen", InternalDisplayName() = "" ? "not found" : DisplayHz(InternalDisplayName()) " Hz")
    }

    ; ---- setup check ----
    r .= "`n[Setup check]`n"
    try {
        for it in SetupItems()
            r .= "  " StrUpper(it.level) "  " it.name "`n"
    } catch as e {
        r .= "  failed: " e.Message "`n"
    }

    ; ---- profiles ----
    r .= "`n[Profiles] active: " CurP().name (ProfileMismatch() ? " (GPU doesn't match: switch unfinished)" : "") "`n"
    for id in profileOrder {
        p := profiles[id]
        r .= Format("  {:-14} gpu {:-9} charge {}%  bat {}  ac {}  games {}  cap {}  after {}{}{}`n",
            p.name, HasGH() ? p.gpu : "-", HasGH() ? p.charge : "-", ModeName(p.battery), ModeName(p.ac), p.games, p.cap, p.after,
            p.launch != "" ? "  opens " StrSplit(p.launch, "|").Length : "", p.close != "" ? "  closes " StrSplit(p.close, "|").Length : "")
    }
    ov := IniRead(STATE, "app", "charge_override", "")
    if (ov != "")
        r .= "  trip charge override " ov "% until " IniRead(STATE, "app", "charge_override_until", "?") "`n"

    ; ---- settings ----
    r .= "`n[Settings]`n  "
    for name in SettingNames()
        r .= name "=" GetSetting(name) (GetSetting(name) != SETTING_DEFAULTS[name] ? "*" : "") "  "
    r .= "`n  (* = changed from default)  charge rate " ChargeRate() "%/h`n"

    ; ---- schedules ----
    r .= "`n[Schedules] " (SCHEDULES_ENABLED ? "ON" : "off") (IsObject(schedPending) ? ", one pending" : "") "`n"
    for sid in schedOrder {
        s := schedules[sid]
        nx := NextAction(s)
        r .= "  " (s.enabled ? "on  " : "off ") s.type " | " WhenText(s) " -> " PName(s.profile)
            . (ThenText(s) != "" ? " | " ThenText(s) : "") " | next " (nx = "" ? "none" : FormatTime(nx, "ddd MM-dd HH:mm")) "`n"
    }

    ; ---- games ----
    r .= "`n[Games] learned " learned.Count ", added " addedGames.Count ", saved modes " gameModes.Count
        . ", ignored " notGames.Count ", publisher folders " cachedGameDirs.Length "`n"
    modes := ""
    for exe, m in gameModes
        modes .= exe "=" ModeName(m) "  "
    if (modes != "")
        r .= "  " modes "`n"

    ; ---- log tail ----
    r .= "`n[Last 150 log lines]`n"
    try {
        lines := StrSplit(RTrim(FileRead(LOGFILE, "UTF-8"), "`n"), "`n", "`r")
        start := Max(1, lines.Length - 149)
        Loop lines.Length - start + 1
            r .= lines[start + A_Index - 1] "`n"
    } catch {
        r .= "  (no log yet)`n"
    }
    r .= "```````n"
    return Mask(r)
}

CopyDiagnostics(*) {
    ShowOSD("Collecting diagnostics...", "Blue", true)
    try {
        rep := BuildDiagnostics()
    } catch as e {
        Log("ERROR       diagnostics failed: " e.Message " at line " e.Line)
        MsgBox("Couldn't build the full report (" e.Message ").`nPlease attach the activity log instead.", "Performance Companion", "Icon!")
        return
    }
    f := installDir "\diagnostics.txt"
    try FileDelete(f)
    FileAppend(rep, f, "UTF-8")
    A_Clipboard := rep
    Log("DIAG        diagnostics copied to clipboard")
    if (MsgBox("Diagnostics are on your clipboard, ready to paste into a comment or issue.`n`n"
        . "Your username and PC name are hidden. Open it to review first?", "Performance Companion", "YesNo Iconi") = "Yes")
        Run('notepad.exe "' f '"')
}

; ---------- Report an issue ----------
; Opens a pre-filled bug report on GitHub. Apps can't post issues for
; you without storing a password or token, so this fills in everything
; it can in the browser; you review it and press Submit.

UrlEncode(str) {
    buf := Buffer(StrPut(str, "UTF-8"), 0)
    StrPut(str, buf, "UTF-8")
    out := ""
    Loop buf.Size - 1 {
        b := NumGet(buf, A_Index - 1, "UChar")
        out .= ((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b = 0x2D || b = 0x2E || b = 0x5F || b = 0x7E)
            ? Chr(b) : Format("%{:02X}", b)
    }
    return out
}

ReportIssue(*) {
    g := Gui("+AlwaysOnTop", "Report an issue")
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 16, g.MarginY := 12
    g.Add("Text", "w460", "What went wrong? A sentence or two is plenty. Your browser then opens a bug report with this, "
        . "your device and full diagnostics filled in. You can add more there before pressing Submit.")
    ed := g.Add("Edit", "w460 r5")
    g.SetFont("s9 cGray")
    g.Add("Text", "w460 y+6", "Needs a free GitHub account. Your username and PC name are hidden in the diagnostics.")
    g.SetFont("s10 norm cDefault")
    b := g.Add("Button", "w150 y+12 Default", "Open bug report")
    b.OnEvent("Click", (*) => Go())
    b2 := g.Add("Button", "x+8 w90", "Cancel")
    b2.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.Show()

    Go() {
        what := Trim(ed.Value)
        g.Destroy()
        ShowOSD("Collecting diagnostics...", "Blue", true)
        try {
            rep := BuildDiagnostics()
        } catch as e {
            rep := "Diagnostics failed: " e.Message " (line " e.Line ")"
        }
        f := installDir "\diagnostics.txt"
        try FileDelete(f)
        try FileAppend(rep, f, "UTF-8")
        A_Clipboard := rep
        dev := DEVICE.handheld != "" ? DEVICE.handheld " (" DEVICE.model ")" : DEVICE.maker " " DEVICE.model
        title := "[" SCRIPT_VERSION "] " (what = "" ? "Problem on " dev : SubStr(RegExReplace(what, "\s+", " "), 1, 70))
        url := REPO_URL "/issues/new?template=bug_report.yml&title=" UrlEncode(title)
            . "&what=" UrlEncode(what = "" ? "(describe what happened)" : what)
            . "&device=" UrlEncode(Mask(dev))
        ; Browsers and GitHub cap link length; long reports go via the clipboard.
        inline := UrlEncode(rep)
        pasted := (StrLen(url) + StrLen(inline) < 7500)
        ; Only pre-fill the box when the whole report fits. A pre-filled box
        ; that's later pasted over gets reset by GitHub's form, so long
        ; reports leave it empty for a clean Ctrl+V.
        if pasted
            url .= "&diagnostics=" inline
        Log("REPORT      opened a pre-filled bug report" (pasted ? "" : " (diagnostics on clipboard)"))
        try {
            Run(url)
        } catch {
            MsgBox("Couldn't open your browser. The diagnostics are on your clipboard; paste them at`n" REPO_URL "/issues", "Report an issue", "Icon!")
            return
        }
        if !pasted
            MsgBox("Your browser is opening the bug report.`n`nThe diagnostics are long, so they're on your clipboard: "
                . "click the Diagnostics box and press Ctrl+V, then Submit.", "Report an issue", "Iconi T30")
    }
}

; ====================================================================
;  ENGINES, DEVICE DETECTION AND IMPORT
;
;  Every part of Performance Companion above this layer (profiles, game detection,
;  schedules, the tray) works in three performance modes:
;      1 = high (Turbo / Performance)   0 = middle (Balanced / Work)
;      2 = low (Silent / Eco)
;  plus, on G-Helper, its custom modes (ids 3 and up). The engine turns
;  a mode into real settings:
;      ghelper  G-Helper hotkeys and config.json
;      plans    three Windows power plans managed by Performance Companion
; ====================================================================

; ---------- importing G14 Control / Laptop Control ----------
; First launch only: copy the newest earlier app's settings, games and
; log, so nothing has to be set up again. Returns the app name or "".
ImportOldApp() {
    if FileExist(installDir "\state.ini")
        return ""
    best := "", bestTime := 0
    for app in OLD_APPS {
        f := app.dir "\state.ini"
        if FileExist(f) && (t := FileGetTime(f, "M")) > bestTime
            best := app, bestTime := t
    }
    if !IsObject(best)
        return ""
    DirCreate(installDir)
    try FileCopy(best.dir "\state.ini", installDir "\state.ini", true)
    try FileCopy(best.dir "\activity.log", installDir "\activity.log", true)
    try IniWrite(best.name, installDir "\state.ini", "app", "imported_from")
    try IniDelete(installDir "\state.ini", "app", "ahk_path")        ; re-register tasks under Performance Companion
    try IniDelete(installDir "\state.ini", "app", "tray_promoted")
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  IMPORT      settings, profiles and games from " best.name "`n",
        installDir "\activity.log", "UTF-8")
    return best.name
}

; Stops any earlier app still running and removes its startup tasks and
; shortcuts, so two apps never fight. Its data folder is left as a backup.
RetireOldApps() {
    DetectHiddenWindows(true)
    for app in OLD_APPS {
        found := false
        for h in WinGetList(app.dir "\" app.script " ahk_class AutoHotkey") {
            found := true
            try {
                pid := WinGetPID("ahk_id " h)
                WinClose("ahk_id " h)
                if !ProcessWaitClose(pid, 3)
                    ProcessClose(pid)
            }
        }
        for t in app.tasks
            if TaskExists(t) {
                RunWait('schtasks.exe /delete /tn "' t '" /f', , "Hide")
                found := true
            }
        for l in app.links
            if FileExist(l) {
                try FileDelete(l)
                found := true
            }
        if found
            Log("RETIRE      " app.name " stopped and unregistered (its data stays in " Mask(app.dir) ")")
    }
    DetectHiddenWindows(false)
}

; ---------- which engine ----------
; Settings > Engine can force one; Automatic picks G-Helper on ASUS
; machines that have run it, Windows power plans everywhere else.
DetectBackend() {
    choice := ENGINE_CHOICE
    if (choice = "ghelper" || choice = "plans")
        return choice
    maker := WmiFirst("SELECT Manufacturer FROM Win32_ComputerSystem", "Manufacturer")
    if (FileExist(CFG) && (InStr(maker, "ASUS") || ProcessExist("GHelper.exe")))
        return "ghelper"
    return "plans"
}

EngineName(b := "") => ((b = "" ? BACKEND : b) = "ghelper") ? "G-Helper" : "Windows power plans"
HasGH() => (BACKEND = "ghelper")

; ---------- what kind of device ----------
DetectDevice() {
    maker := WmiFirst("SELECT Manufacturer FROM Win32_ComputerSystem", "Manufacturer")
    model := WmiFirst("SELECT Model FROM Win32_ComputerSystem", "Model")
    fam := ""
    try fam := RegRead("HKLM\HARDWARE\DESCRIPTION\System\BIOS", "SystemFamily")
    id := maker " " model " " fam
    hh := ""
    for pat, nm in Map(
        "i)\bRC7[12]|ROG Ally", "ROG Ally",
        "i)Legion Go|\b83E1\b|\b83L3\b|\b83N[01]\b|\b83Q[23]\b", "Legion Go",
        "i)\bClaw\b|\bMS-1T[0-9]", "MSI Claw",
        "i)\bJupiter\b|\bGalileo\b|Steam Deck", "Steam Deck",
        "i)AYANEO|AYA NEO", "AYANEO",
        "i)ONEXPLAYER|ONE-NETBOOK|OneXFly", "OneXPlayer",
        "i)AOKZOE", "AOKZOE",
        "i)GPD\b|G1618|G1619|G1617|WIN ?Max|WIN ?Mini", "GPD",
        "i)\bLoki\b|\bAyn\b", "Ayn Loki",
        "i)ZOTAC.*ZONE", "ZOTAC Zone") {
        if RegExMatch(id, pat) {
            hh := nm
            break
        }
    }
    sps := Buffer(12, 0)
    DllCall("GetSystemPowerStatus", "Ptr", sps)
    noBattery := (NumGet(sps, 1, "UChar") & 128) != 0
    kind := hh != "" ? "handheld" : noBattery ? "desktop" : "laptop"
    return {maker: maker, model: model, handheld: hh, kind: kind}
}

; ---------- mode names and choices ----------
ModeName(m) {
    if (m = "")
        return "unknown"
    if (BACKEND = "plans")
        return m = 1 ? "Performance" : m = 2 ? "Eco" : m = 0 ? "Work" : "unknown"
    if (m = 0)
        return "Balanced"
    if (m = 1)
        return "Turbo"
    if (m = 2)
        return "Silent"
    return customModes.Has(Integer(m)) ? customModes[Integer(m)] : "Custom " (m - 2)
}

; Modes an app can be given: the three built in, plus G-Helper's custom
; modes (by the names you gave them in G-Helper) when there are any.
ModeChoices() {
    out := [1, 0, 2]
    if (HasGH() && CUSTOM_MODES)
        for id in customModes
            out.Push(id)
    return out
}

; low < middle < high (custom modes count as high).
ModeRank(m) => m = 2 ? 0 : m = 0 ? 1 : 2

; Reads G-Helper's custom modes (slots 3 to 19) and their names.
LoadCustomModes() {
    global customModes
    customModes := Map()
    txt := ReadCfg()
    Loop 17 {
        id := A_Index + 2
        base := GetJsonInt(txt, "mode_base_" id)
        if (base = "" || base < 0)
            continue
        nm := GetJsonStr(txt, "mode_name_" id)
        customModes[id] := (nm = "") ? "Custom " (id - 2) : nm
    }
    return customModes.Count
}

GetJsonStr(txt, key) {
    if !RegExMatch(txt, '"' key '"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
        return ""
    v := m[1]
    v := StrReplace(v, '\"', '"'), v := StrReplace(v, "\\", "\")
    return v
}

; ---------- applying a mode ----------
; The single place a performance mode is set, for either engine.
SetPerfMode(m, why := "") {
    global busy
    if (paused || !automationOK)
        return false
    if (BACKEND = "plans") {
        Critical()
        k := ModeKey(m)
        if (why != "" && (ActivePlanGuid() != PlanGuid(k) || appliedMode != m))
            Log("PLAN        -> " PlanTitle(k) " (" why ")")
        wasBusy := busy
        busy := true
        ok := ApplyMode(m)
        busy := wasBusy
        UpdateTip()
        return ok
    }
    if (m >= 5)
        return CycleGHelperTo(m, why)
    SendGHelperKey(GHKey(m))
    return true
}

; The mode running right now, as the engine reports it.
CurrentPerfMode() {
    if (BACKEND = "plans") {
        k := PlanKeyOf(ActivePlanGuid())
        return k = "" ? "" : KeyMode(k)
    }
    return GetJsonInt(ReadCfg(), PerfKey())
}

; G-Helper's hotkey for a mode (Ctrl+Shift+Alt + this key). Reads any
; remapped keys from G-Helper's config; F16 Silent, F17 Balanced, F18
; Turbo, F19 / F20 its first two custom modes by default.
GHKey(m) {
    static defaults := Map(0, 0x80, 1, 0x81, 2, 0x7F, 3, 0x82, 4, 0x83)
    v := GetJsonInt(ReadCfg(), "keybind_profile_" m)
    return (v != "" && v > 0) ? Integer(v) : defaults.Has(m) ? defaults[m] : 0x81
}
PerfVK(m) => GHKey(m)

; Custom modes past the second have no hotkey: step through G-Helper's
; mode list (Ctrl+Shift+F5) until it lands on the wanted one.
CycleGHelperTo(m, why := "") {
    key := PerfKey()
    Loop 22 {
        if (GetJsonInt(ReadCfg(), key) = m) {
            if (why != "")
                Log("MODE        -> " ModeName(m) " by cycling (" why ")")
            return true
        }
        SendCombo(0x11, 0x10, 0x74)                ; Ctrl+Shift+F5: next mode
        Sleep(450)
    }
    Log("MODE        couldn't reach " ModeName(m) " by cycling; is it still in G-Helper?")
    return false
}

; ---------- unplug: optional automatic profile ----------
; Unplugged: switch to the battery profile (remembering where we were).
; Plugged in: go back, unless you picked a profile yourself meanwhile.
CheckBatteryProfile(startup := false) {
    ac := OnAC()
    back := IniRead(STATE, "app", "return_profile", "")
    if ac {
        try IniDelete(STATE, "app", "battery_choice")
        if (back = "")
            return
        try IniDelete(STATE, "app", "return_profile")
        if (profiles.Has(back) && back != profile && profile = BATTERY_PROFILE) {
            Log("BATTERY     plugged in: back to " profiles[back].name)
            SwitchToProfile(back, "power")
        }
        return
    }
    if (BATTERY_PROFILE = "" || !profiles.Has(BATTERY_PROFILE) || profile = BATTERY_PROFILE)
        return
    if (startup && (back != "" || IniRead(STATE, "app", "battery_choice", "")))
        return                                       ; already handled, or you chose, before a restart
    if SwitchPlan(BATTERY_PROFILE).ending != "none" {
        Log("BATTERY     unplugged, but switching to " profiles[BATTERY_PROFILE].name " needs a restart; skipped")
        return
    }
    IniWrite(profile, STATE, "app", "return_profile")
    Log("BATTERY     unplugged: " CurP().name " -> " profiles[BATTERY_PROFILE].name " (returns on plug-in)")
    SwitchToProfile(BATTERY_PROFILE, "power")
}

; ---------- vendor apps: what to set once ----------
; Performance Companion works under the maker's own performance setting. These are the
; one-time settings that let its high mode actually reach full power.
VendorTips() {
    tips := []
    m := DEVICE.maker " " DEVICE.model
    add(name, procs, makerPat, text) {
        hit := false
        for p in procs
            if ProcessExist(p)
                hit := true
        if (hit || (makerPat != "" && RegExMatch(m, makerPat)))
            tips.Push({name: name, text: text})
    }
    if (BACKEND = "plans") {
        add("Razer Synapse", ["RazerAppEngine.exe", "Razer Synapse 3.exe", "RazerCentralService.exe"], "i)Razer",
            "In Synapse > Performance > Plugged In, choose Custom with CPU Boost and GPU High, fans Auto. "
            . "Synapse limits itself on battery on its own.")
        add("Lenovo Vantage / Legion Space", ["LenovoVantage.exe", "LenovoVantageService.exe", "LegionSpace.exe", "Legion Space.exe"], "i)Lenovo",
            "Set the thermal / power mode to Performance while plugged in (Fn+Q on Legion laptops, Legion Space on a Legion Go), "
            . "and turn off any 'Intelligent' or automatic mode that changes it for you.")
        add("MSI Center", ["MSI.CentralServer.exe", "MSI Center.exe", "MSI_Central_Service.exe", "MSI Center M.exe"], "i)Micro-Star|\bMSI\b",
            "In MSI Center, set User Scenario to Extreme Performance while plugged in (on a Claw, MSI Center M's highest mode), "
            . "and turn off AI / Smart Auto so it doesn't override Windows.")
        add("Alienware / Dell", ["AlienwareCommandCenter.exe", "AWCC.exe", "DellOptimizer.exe", "Dell.PowerManager.exe"], "i)Alienware|Dell",
            "In Alienware Command Center (or Dell Power Manager), choose the Performance thermal mode while plugged in.")
        add("HP OMEN Gaming Hub", ["OmenCommandCenterBackground.exe", "OMEN Command Center.exe", "HP.OMEN.OMENCommandCenter.exe"], "i)\bHP\b|Hewlett",
            "In OMEN Gaming Hub > Performance Control, choose Performance while plugged in.")
        add("ASUS Armoury Crate", ["ArmouryCrate.exe", "ArmouryCrateSE.exe", "ArmouryCrate.Service.exe"], "i)ASUS",
            "Set the operating mode to Turbo (or Performance) while plugged in. For GPU switching, charge limits and "
            . "per-mode control, install G-Helper instead: Performance Companion switches to it automatically.")
    }
    if ProcessExist("HandheldCompanion.exe")
        tips.Push({name: "Handheld Companion",
            text: "Set TDP in Handheld Companion's power profiles (that's its strength). Leave its Power mode, EPP and "
            . "CPU boost overrides off, so Performance Companion's plans and Handheld Companion don't fight over the same settings."})
    if (!tips.Length && BACKEND = "plans" && DEVICE.kind != "desktop")
        tips.Push({name: "Your maker's performance app",
            text: "If your " (DEVICE.handheld != "" ? "handheld" : "laptop") " came with a performance or fan app, "
            . "set it to its highest mode while plugged in. Performance Companion then decides how much of that Windows uses."})
    return tips
}
; ====================================================================
;  POWER PLANS (the backend: what G-Helper was to G14 Control)
;
;  Three plans, created once as copies of Windows' Balanced plan (so your
;  sleep and screen-off timers carry over) and kept in sync with
;  Settings > advanced > Edit power plans. Their GUIDs live in state.ini [plans].
;
;    mode 2  Eco          mode 0  Work          mode 1  Performance
;
;  Each plan sets, plugged in and on battery alike:
;    CPU max %          processor maximum state
;    Turbo              processor boost: Off / Efficient / On / Aggressive
;    CPU bias           energy-performance preference (fixed per plan)
;    Energy Saver       battery level where Windows' Energy Saver turns on
;  and, while the plan is active:
;    Power mode         Windows' Best efficiency / Balanced / Best performance
;    Screen             built-in screen at 60 Hz, highest, or left alone
; ====================================================================

PlanKeys() => ["eco", "work", "performance"]
ModeKey(m) => m = 1 ? "performance" : m = 2 ? "eco" : "work"
KeyMode(k) => k = "performance" ? 1 : k = "eco" ? 2 : 0
PlanTitle(k) => "Performance Companion: " (k = "performance" ? "Performance" : k = "eco" ? "Eco" : "Work")
PlanGuid(k) => IniRead(STATE, "plans", k, "")

; Turbo choices as shown, and Windows' PERFBOOSTMODE values behind them.
TurboNames()  => ["Off", "Efficient", "On", "Aggressive"]
TurboValues() => [0, 3, 1, 2]
TurboName(v) => TurboNames()[IndexOf(TurboValues(), v)]
RefreshIds()   => ["60", "max", "leave"]
RefreshNames() => ["60 Hz (saves battery)", "Highest available", "Don't change"]
SaverIds()     => [100, 20, 0]
SaverNames()   => ["Always on battery", "At 20% battery (Windows default)", "Never"]

PlanDefaults(k) {
    switch k {
        case "eco":         return {cpu: 70,  boost: 0, refresh: "60",  saver: 100}
        case "performance": return {cpu: 100, boost: 2, refresh: "max", saver: 0}
        default:            return {cpu: 100, boost: 3, refresh: "max", saver: 20}
    }
}

; Energy-performance preference: 0 favors speed, 100 favors battery.
PlanEpp(k) => k = "eco" ? 70 : k = "performance" ? 0 : 33

; Windows' power mode slider (Settings > System > Power), as overlay GUIDs.
PlanOverlay(k) => k = "eco" ? "961cc777-2547-4f9d-8174-7d86181b8a7a"
    : k = "performance" ? "ded574b5-45a0-4f42-8737-46345c09c238"
    : "00000000-0000-0000-0000-000000000000"
OverlayName(k) => k = "eco" ? "Best power efficiency" : k = "performance" ? "Best performance" : "Balanced"

ReadPlanSettings(k) {
    d := PlanDefaults(k)
    sec := "plan." k
    cpu := IniRead(STATE, sec, "cpu", d.cpu)
    boost := IniRead(STATE, sec, "boost", d.boost)
    refresh := IniRead(STATE, sec, "refresh", d.refresh)
    saver := IniRead(STATE, sec, "saver", d.saver)
    s := {}
    s.cpu := IsInteger(cpu) ? Max(20, Min(100, Integer(cpu))) : d.cpu
    s.boost := (IsInteger(boost) && InArr(TurboValues(), Integer(boost))) ? Integer(boost) : d.boost
    s.refresh := PickOf(refresh, RefreshIds(), d.refresh)
    s.saver := (IsInteger(saver) && InArr(SaverIds(), Integer(saver))) ? Integer(saver) : d.saver
    return s
}

WritePlanSettings(k, s) {
    sec := "plan." k
    for f in ["cpu", "boost", "refresh", "saver"]
        IniWrite(s.%f%, STATE, sec, f)
}

PlanSummary(k) {
    s := ReadPlanSettings(k)
    return "CPU " s.cpu "%, turbo " StrLower(TurboName(s.boost))
        . (s.refresh = "60" ? ", 60 Hz" : s.refresh = "max" ? ", full Hz" : "")
}

; ---------- GUID helpers ----------
GuidToStr(ptr) {
    s := Buffer(80, 0)
    DllCall("ole32\StringFromGUID2", "Ptr", ptr, "Ptr", s, "Int", 40)
    return StrLower(Trim(StrGet(s, "UTF-16"), "{}"))
}

StrToGuid(str) {
    buf := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "WStr", "{" str "}", "Ptr", buf)
    return buf
}

NewGuidStr() {
    buf := Buffer(16, 0)
    DllCall("ole32\CoCreateGuid", "Ptr", buf)
    return GuidToStr(buf)
}

ActivePlanGuid() {
    p := 0
    try {
        if (DllCall("powrprof\PowerGetActiveScheme", "Ptr", 0, "Ptr*", &p, "UInt") = 0 && p) {
            s := GuidToStr(p)
            DllCall("LocalFree", "Ptr", p)
            return s
        }
    }
    return ""
}

SetActivePlan(guid) {
    try return DllCall("powrprof\PowerSetActiveScheme", "Ptr", 0, "Ptr", StrToGuid(guid), "UInt") = 0
    return false
}

PlanExists(guid) => (guid != "") && RunWait('powercfg.exe /query ' guid, , "Hide") = 0

; Which of our plans a GUID is ("" if it isn't one of ours).
PlanKeyOf(guid) {
    for k in PlanKeys()
        if (guid != "" && PlanGuid(k) = guid)
            return k
    return ""
}

; Friendly name of any plan, ours or not (for the log and status).
PlanFriendlyName(guid) {
    if (guid = "")
        return "unknown"
    k := PlanKeyOf(guid)
    if (k != "")
        return PlanTitle(k)
    size := 0
    try {
        g := StrToGuid(guid)
        DllCall("powrprof\PowerReadFriendlyName", "Ptr", 0, "Ptr", g, "Ptr", 0, "Ptr", 0, "Ptr", 0, "UInt*", &size)
        if size {
            buf := Buffer(size, 0)
            if (DllCall("powrprof\PowerReadFriendlyName", "Ptr", 0, "Ptr", g, "Ptr", 0, "Ptr", 0, "Ptr", buf, "UInt*", &size) = 0)
                return StrGet(buf, "UTF-16")
        }
    }
    return guid
}

; Runs a batch of powercfg lines in one hidden window. Returns the exit code.
PowerCmd(lines) {
    f := installDir "\powercfg.cmd"
    out := "@echo off`r`n"
    for l in lines
        out .= l "`r`n"
    try FileDelete(f)
    FileAppend(out, f, "CP0")
    rc := RunWait(A_ComSpec ' /c "' f '"', , "Hide")
    try FileDelete(f)
    return rc
}

; Creates any missing plan, renames them, and writes their settings.
; Returns false if a plan couldn't be created.
EnsurePlans() {
    ok := true
    for k in PlanKeys() {
        g := PlanGuid(k)
        if !PlanExists(g) {
            g := NewGuidStr()
            RunWait('powercfg.exe /duplicatescheme ' BALANCED_GUID ' ' g, , "Hide")
            if !PlanExists(g) {
                Log("PLANS       couldn't create the " ModeName(KeyMode(k)) " plan")
                ok := false
                continue
            }
            IniWrite(g, STATE, "plans", k)
            Log("PLANS       created " PlanTitle(k) " (" g ")")
        }
        ApplyPlanSettings(k, false)
    }
    return ok
}

; Writes a plan's settings into Windows. If it's the active plan, it's
; re-activated so the changes take effect now.
ApplyPlanSettings(k, reactivate := true) {
    g := PlanGuid(k)
    if (g = "")
        return false
    s := ReadPlanSettings(k)
    epp := PlanEpp(k)
    desc := k = "eco" ? "Longest battery: CPU capped, turbo off. Managed by Performance Companion."
        : k = "performance" ? "Everything uncapped for gaming. Managed by Performance Companion."
        : "Everyday balance of speed, heat and fan noise. Managed by Performance Companion."
    lines := ['powercfg.exe /changename ' g ' "' PlanTitle(k) '" "' desc '"']
    for which in ["ac", "dc"] {
        lines.Push('powercfg.exe /set' which 'valueindex ' g ' SUB_PROCESSOR PROCTHROTTLEMAX ' s.cpu)
        lines.Push('powercfg.exe /set' which 'valueindex ' g ' SUB_PROCESSOR PERFBOOSTMODE ' s.boost)
        lines.Push('powercfg.exe /set' which 'valueindex ' g ' SUB_PROCESSOR PERFEPP ' epp)
        ; Efficiency cores on hybrid Intel CPUs (12th gen and newer). Ignored elsewhere.
        lines.Push('powercfg.exe /set' which 'valueindex ' g ' SUB_PROCESSOR PROCTHROTTLEMAX1 ' s.cpu ' 2>nul')
        lines.Push('powercfg.exe /set' which 'valueindex ' g ' SUB_PROCESSOR PERFEPP1 ' epp ' 2>nul')
    }
    lines.Push('powercfg.exe /setdcvalueindex ' g ' SUB_ENERGYSAVER ESBATTTHRESHOLD ' s.saver)
    ; Power savers the plans inherit from Balanced. Performance turns them all
    ; off; Eco turns them all on; Work keeps Windows' Balanced choices.
    ;   PCIe link power (GPU / SSD wake latency): 0 off, 2 maximum savings
    ;   Core parking: minimum % of cores kept awake
    ;   Wi-Fi power saving: 0 maximum performance, 3 maximum power saving
    ;   USB selective suspend: 0 off, 1 on
    if (k != "work") {
        perf := (k = "performance")
        for which in ["ac", "dc"] {
            lines.Push('powercfg.exe /set' which 'valueindex ' g ' SUB_PCIEXPRESS ASPM ' (perf ? 0 : 2) ' 2>nul')
            lines.Push('powercfg.exe /set' which 'valueindex ' g ' SUB_PROCESSOR CPMINCORES ' (perf ? 100 : 10) ' 2>nul')
            lines.Push('powercfg.exe /set' which 'valueindex ' g ' SUB_PROCESSOR CPMINCORES1 ' (perf ? 100 : 10) ' 2>nul')
            lines.Push('powercfg.exe /set' which 'valueindex ' g ' 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a ' (perf ? 0 : 3) ' 2>nul')
            lines.Push('powercfg.exe /set' which 'valueindex ' g ' 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 ' (perf ? 0 : 1) ' 2>nul')
        }
    }
    if (reactivate && ActivePlanGuid() = g)
        lines.Push('powercfg.exe /setactive ' g)
    PowerCmd(lines)
    return true
}

; Windows' power mode slider. Not every PC accepts it with a custom plan;
; the plan's own settings do the real work either way.
ApplyOverlay(k) {
    global overlayOK
    r := -1
    if (A_PtrSize = 8)        ; the GUID goes by value; only 64-bit AutoHotkey passes it correctly
        try r := DllCall("powrprof\PowerSetActiveOverlayScheme", "Ptr", StrToGuid(PlanOverlay(k)), "UInt")
    ok := (r = 0)
    if (overlayOK = "" || overlayOK != ok)
        Log("POWER MODE  " OverlayName(k) (ok ? " set" : " not accepted (code " r ")"))
    overlayOK := ok
    return ok
}

; The single place plans are switched: plan, Windows power mode, screen.
ApplyMode(m, force := false) {
    global appliedMode, planFails, planRetryAt
    k := ModeKey(m)
    g := PlanGuid(k)
    if (g = "")
        return false
    if (ActivePlanGuid() != g || force) {
        if !SetActivePlan(g) {
            planFails++
            if !PlanExists(g) {
                Log("PLANS       " PlanTitle(k) " is gone; recreating the plans")
                EnsurePlans()
                g := PlanGuid(k)
            }
            if !SetActivePlan(g) {
                if (planFails <= 3)
                    Log("PLANS       couldn't activate " PlanTitle(k) (planFails = 3 ? "; retrying every 5 minutes" : ""))
                if (planFails >= 3)
                    planRetryAt := A_TickCount + 300000
                return false
            }
        }
    }
    planFails := 0, planRetryAt := 0
    ApplyOverlay(k)
    ApplyRefresh(k)
    appliedMode := m
    return true
}

; Removes our plans and goes back to the plan you had before installing
; (or Windows' Balanced plan). Used by uninstall.
RemovePlans() {
    before := IniRead(STATE, "app", "plan_before_install", "")
    if (before = "" || PlanKeyOf(before) != "" || !PlanExists(before) || !SetActivePlan(before))
        SetActivePlan(BALANCED_GUID)
    if (A_PtrSize = 8)
        try DllCall("powrprof\PowerSetActiveOverlayScheme", "Ptr", StrToGuid(PlanOverlay("work")), "UInt")
    RestoreScreen()
    lines := []
    for k in PlanKeys()
        if (PlanGuid(k) != "")
            lines.Push('powercfg.exe /delete ' PlanGuid(k))
    if lines.Length
        PowerCmd(lines)
    try IniDelete(STATE, "plans")
}

; ---------- built-in screen refresh rate ----------
; True when the window in front covers its whole monitor (a game or video).
FullscreenInFront() {
    try {
        hwnd := WinExist("A")
        if !hwnd
            return false
        cls := WinGetClass(hwnd)
        if (cls = "Progman" || cls = "WorkerW" || cls = "Shell_TrayWnd")
            return false
        return IsFullscreenForeground(WinGetPID(hwnd))
    }
    return false
}

; Puts the built-in screen back to its highest rate if Performance Companion
; lowered it (on exit and uninstall), so 60 Hz never outlives the app.
RestoreScreen(*) {
    if !refreshTouched
        return
    name := InternalDisplayName()
    if (name != "")
        SetRefresh(name, "max")
}
; Finds the laptop's own panel (not an external monitor) through Windows'
; display configuration, by its connection type.
InternalDisplayName() {
    np := 0, nm := 0
    if DllCall("GetDisplayConfigBufferSizes", "UInt", 2, "UInt*", &np, "UInt*", &nm, "Int")
        return ""
    if !np
        return ""
    paths := Buffer(np * 72, 0), modes := Buffer(Max(nm, 1) * 64, 0)
    if DllCall("QueryDisplayConfig", "UInt", 2, "UInt*", &np, "Ptr", paths, "UInt*", &nm, "Ptr", modes, "Ptr", 0, "Int")
        return ""
    Loop np {
        off := (A_Index - 1) * 72
        tech := NumGet(paths, off + 36, "UInt")
        ; internal, LVDS, embedded DisplayPort, embedded UDI
        if !(tech = 0x80000000 || tech = 6 || tech = 11 || tech = 13)
            continue
        req := Buffer(84, 0)
        NumPut("Int", 1, req, 0)                                  ; GET_SOURCE_NAME
        NumPut("UInt", 84, req, 4)
        NumPut("UInt", NumGet(paths, off, "UInt"), req, 8)        ; adapter LUID
        NumPut("Int", NumGet(paths, off + 4, "Int"), req, 12)
        NumPut("UInt", NumGet(paths, off + 8, "UInt"), req, 16)   ; source id
        if (DllCall("DisplayConfigGetDeviceInfo", "Ptr", req, "Int") = 0)
            return StrGet(req.Ptr + 20, 32, "UTF-16")
    }
    return ""
}

; Current refresh rate of a display, or 0.
DisplayHz(name) {
    dm := Buffer(220, 0)
    NumPut("UShort", 220, dm, 68)
    if !DllCall("EnumDisplaySettingsW", "WStr", name, "Int", -1, "Ptr", dm)
        return 0
    return NumGet(dm, 184, "UInt")
}

; want: "60" (60 Hz, or the lowest offered) or "max". Keeps resolution.
; Returns the rate now in use, or "" if it couldn't change.
SetRefresh(name, want) {
    dm := Buffer(220, 0)
    NumPut("UShort", 220, dm, 68)
    ; The saved desktop mode, not whatever a fullscreen game set temporarily.
    if !DllCall("EnumDisplaySettingsW", "WStr", name, "Int", -2, "Ptr", dm)
        && !DllCall("EnumDisplaySettingsW", "WStr", name, "Int", -1, "Ptr", dm)
        return ""
    w := NumGet(dm, 172, "UInt"), h := NumGet(dm, 176, "UInt")
    bpp := NumGet(dm, 168, "UInt"), cur := DisplayHz(name)
    best := 0, near60 := 0, i := 0
    loop {
        md := Buffer(220, 0)
        NumPut("UShort", 220, md, 68)
        if !DllCall("EnumDisplaySettingsW", "WStr", name, "Int", i++, "Ptr", md)
            break
        if (NumGet(md, 172, "UInt") != w || NumGet(md, 176, "UInt") != h || NumGet(md, 168, "UInt") != bpp)
            continue
        f := NumGet(md, 184, "UInt")
        if (f <= 1)
            continue
        best := Max(best, f)
        if (near60 = 0 || Abs(f - 60) < Abs(near60 - 60))
            near60 := f
    }
    target := (want = "60") ? near60 : best
    if (!target || target = cur)
        return cur
    NumPut("UInt", 0x400000, dm, 72)                              ; DM_DISPLAYFREQUENCY
    NumPut("UInt", target, dm, 184)
    r := DllCall("ChangeDisplaySettingsExW", "WStr", name, "Ptr", dm, "Ptr", 0, "UInt", 1, "Ptr", 0, "Int")
    return (r = 0) ? target : ""
}

ApplyRefresh(k) {
    global refreshPending, refreshTouched
    s := ReadPlanSettings(k)
    if (s.refresh = "leave")
        return
    name := InternalDisplayName()
    if (name = "")
        return
    ; Changing the rate under an exclusive-fullscreen game can knock it out
    ; of fullscreen: wait until nothing fullscreen is in front.
    if FullscreenInFront() {
        refreshPending := k
        return
    }
    refreshPending := ""
    refreshTouched := true
    before := DisplayHz(name)
    now := SetRefresh(name, s.refresh)
    if (now = "")
        Log("SCREEN      couldn't change the built-in screen's refresh rate")
    else if (now != before)
        Log("SCREEN      built-in screen " before " Hz -> " now " Hz (" ModeName(KeyMode(k)) ")")
}


; ---------- power plans window (Settings > advanced > Edit power plans) ----------
ShowPlans(*) {
    static open := 0
    if open {
        try WinActivate("ahk_id " open)
        return
    }
    g := Gui("+AlwaysOnTop", "Performance Companion power plans")
    open := g.Hwnd
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 16, g.MarginY := 12

    g.Add("Text", "xm w640", "What each plan lets Windows do. Profiles pick which plan runs plugged in, on battery and in games.`n"
        . "These work under your laptop maker's own power setting (Synapse, Vantage...): set that to its highest so Performance can use it all.")

    ctl := Map()
    tipCpu := "Highest CPU speed Windows may use, as a percent of maximum.`n"
        . "Lower = cooler, quieter, longer battery. Under 100% usually also stops turbo boost on Intel CPUs."
    tipBoost := "Turbo boost: short bursts above the CPU's base speed.`n"
        . "Off: coolest and quietest. Efficient: boosts only when it pays off.`n"
        . "On: normal. Aggressive: boosts hardest and longest (most heat and fan noise)."
    tipRef := "Refresh rate of the laptop's built-in screen while this plan runs.`n"
        . "60 Hz saves a noticeable amount of battery; Highest is smoothest for games.`n"
        . "External monitors are never changed."
    tipSav := "When Windows' Energy Saver turns on while unplugged.`n"
        . "It dims the screen a little and limits background activity."

    for k in PlanKeys() {
        s := ReadPlanSettings(k)
        g.SetFont("s10 bold")
        g.Add("Text", "xm y+16 w110", ModeName(KeyMode(k)))
        g.SetFont("s9 norm cGray")
        g.Add("Text", "x+0 yp+1 w500", "Windows power mode: " OverlayName(k))
        g.SetFont("s10 norm cDefault")
        t := g.Add("Text", "xm+12 y+8 w110", "CPU max")
        AddTip(t, tipCpu)
        sl := g.Add("Slider", "x+4 yp-4 w180 Range20-100 TickInterval10 Line5 Page10 ToolTip", s.cpu)
        tx := g.Add("Text", "x+6 yp+4 w50", s.cpu "%")
        sl.OnEvent("Change", ((tx, c, *) => tx.Value := Round(c.Value / 5) * 5 "%").Bind(tx))
        AddTip(sl, tipCpu)
        t := g.Add("Text", "x+16 yp w60", "Turbo")
        AddTip(t, tipBoost)
        bd := g.Add("DropDownList", "x+4 yp-3 w120", TurboNames())
        bd.Choose(IndexOf(TurboValues(), s.boost))
        AddTip(bd, tipBoost)
        t := g.Add("Text", "xm+12 y+12 w110", "Built-in screen")
        AddTip(t, tipRef)
        rd := g.Add("DropDownList", "x+4 yp-3 w180", RefreshNames())
        rd.Choose(IndexOf(RefreshIds(), s.refresh))
        AddTip(rd, tipRef)
        t := g.Add("Text", "x+64 yp+3 w100", "Energy Saver")
        AddTip(t, tipSav)
        sd := g.Add("DropDownList", "x+4 yp-3 w220", SaverNames())
        sd.Choose(IndexOf(SaverIds(), s.saver))
        AddTip(sd, tipSav)
        ctl[k] := {cpu: sl, boost: bd, refresh: rd, saver: sd}
    }

    b := g.Add("Button", "xm y+20 w100 Default", "Save")
    b.OnEvent("Click", (*) => Save())
    AddTip(b, "Save, write the changes into Windows, and apply them now.")
    b := g.Add("Button", "x+8 w120", "Reset to defaults")
    b.OnEvent("Click", (*) => Defaults())
    AddTip(b, "Put all three plans back to Performance Companion's defaults.")
    b := g.Add("Button", "x+8 w90", "Cancel")
    b.OnEvent("Click", (*) => Close())
    g.OnEvent("Close", (*) => Close())
    g.OnEvent("Escape", (*) => Close())
    g.Show()

    Close() {
        open := 0
        ClearTips(g)
        g.Destroy()
    }

    Save() {
        for k in PlanKeys() {
            c := ctl[k]
            s := {cpu: Round(c.cpu.Value / 5) * 5, boost: TurboValues()[c.boost.Value],
                  refresh: RefreshIds()[c.refresh.Value], saver: SaverIds()[c.saver.Value]}
            WritePlanSettings(k, s)
            ApplyPlanSettings(k)
            Log("PLANS       " ModeName(KeyMode(k)) ": CPU " s.cpu "%, turbo " TurboName(s.boost)
                ", screen " s.refresh ", energy saver " s.saver)
        }
        Close()
        EnforceState(true)
        ShowOSD("Power plans saved and applied", "Green", true)
    }

    Defaults() {
        if (MsgBox("Put all three plans back to the defaults?", "Performance Companion power plans", "YesNo Icon?") != "Yes")
            return
        for k in PlanKeys() {
            try IniDelete(STATE, "plan." k)
            ApplyPlanSettings(k)
        }
        Log("PLANS       reset to defaults")
        Close()
        EnforceState(true)
        ShowPlans()
    }
}

; ====================================================================
;  UPDATES
;  Checks GitHub for a newer release a minute after startup and then
;  once a day. Settings > Updates:
;      notify  (default) a message and a tray item "Update to x.y.z"
;      auto    download and install by itself when nothing is running
;      off     never check
;  Installing runs the downloaded file, which replaces this copy the
;  same way a manual update does (no admin prompt) and keeps all data.
; ====================================================================


; "3.0.10" > "3.0.9"; ignores a leading "v".
VersionCompare(a, b) {
    pa := StrSplit(RegExReplace(a, "i)^v"), "."), pb := StrSplit(RegExReplace(b, "i)^v"), ".")
    Loop Max(pa.Length, pb.Length) {
        x := (A_Index <= pa.Length && IsInteger(pa[A_Index])) ? Integer(pa[A_Index]) : 0
        y := (A_Index <= pb.Length && IsInteger(pb[A_Index])) ? Integer(pb[A_Index]) : 0
        if (x != y)
            return x > y ? 1 : -1
    }
    return 0
}

HttpGet(url, timeoutSec := 15) {
    req := ComObject("WinHttp.WinHttpRequest.5.1")
    req.SetTimeouts(timeoutSec * 1000, timeoutSec * 1000, timeoutSec * 1000, timeoutSec * 1000)
    req.Open("GET", url, false)
    req.SetRequestHeader("User-Agent", "PerformanceCompanion/" SCRIPT_VERSION)
    req.SetRequestHeader("Accept", "application/vnd.github+json")
    req.Send()
    if (req.Status != 200)
        throw Error("HTTP " req.Status)
    return req.ResponseText
}

; Reads the latest release. Returns {version, url, notes} or "".
LatestRelease() {
    api := StrReplace(REPO_URL, "https://github.com/", "https://api.github.com/repos/") "/releases/latest"
    j := HttpGet(api)
    if !RegExMatch(j, '"tag_name"\s*:\s*"([^"]+)"', &t)
        return ""
    url := ""
    if RegExMatch(j, '"browser_download_url"\s*:\s*"([^"]+\.ahk)"', &u)
        url := u[1]
    notes := ""
    if RegExMatch(j, '"body"\s*:\s*"((?:[^"\\]|\\.)*)"', &n)
        notes := StrReplace(StrReplace(StrReplace(n[1], "\r\n", "`n"), "\n", "`n"), '\"', '"')
    return {version: RegExReplace(t[1], "i)^v"), url: url, notes: notes}
}

CheckForUpdates(manual := false, *) {
    global updateInfo
    if (UPDATE_MODE = "off" && !manual)
        return
    try {
        rel := LatestRelease()
    } catch as e {
        if manual
            MsgBox("Couldn't reach GitHub to check for updates (" e.Message ").`nYou can always download the latest version from:`n" REPO_URL "/releases/latest",
                "Performance Companion", "Icon!")
        return
    }
    IniWrite(A_Now, STATE, "app", "update_checked")
    if (!IsObject(rel) || VersionCompare(rel.version, SCRIPT_VERSION) <= 0) {
        updateInfo := ""
        if manual
            MsgBox("You're on the latest version (" SCRIPT_VERSION ").", "Performance Companion", "Iconi")
        UpdateUI()
        return
    }
    updateInfo := rel
    UpdateUI()
    if (UPDATE_MODE = "auto" && !manual && rel.url != "") {
        SetTimer(AutoInstallWhenIdle, 60000)
        AutoInstallWhenIdle()
        return
    }
    if (manual || IniRead(STATE, "app", "update_announced", "") != rel.version) {
        IniWrite(rel.version, STATE, "app", "update_announced")
        Log("UPDATE      " rel.version " available (you have " SCRIPT_VERSION ")")
        if manual {
            if (MsgBox("Performance Companion " rel.version " is available (you have " SCRIPT_VERSION ").`n`nInstall it now?",
                "Performance Companion", "YesNo Iconi") = "Yes")
                InstallUpdate()
        } else {
            ShowOSD("Performance Companion " rel.version " is available: tray menu > Update", "Blue", true)
            try TrayTip("Version " rel.version " is available. Right-click the tray icon > Update to install it.", "Performance Companion", "Iconi")
        }
    }
}

; Auto mode: wait until no game or app mode, switch or schedule is active.
AutoInstallWhenIdle() {
    if (!IsObject(updateInfo) || switching || busy || isTurboMode || IsObject(schedPending))
        return
    SetTimer(AutoInstallWhenIdle, 0)
    InstallUpdate(true)
}

InstallUpdate(silent := false, *) {
    if !IsObject(updateInfo) {
        CheckForUpdates(true)
        return
    }
    if (updateInfo.url = "") {
        Run(REPO_URL "/releases/latest")
        return
    }
    tmp := A_Temp "\PerformanceCompanion-" updateInfo.version ".ahk"
    try {
        try FileDelete(tmp)
        Download(updateInfo.url, tmp)
        head := FileRead(tmp, "UTF-8")
        ; Only ever run a real Performance Companion script of the expected version.
        if !(InStr(head, "#Requires AutoHotkey v2") && InStr(head, 'SCRIPT_VERSION := "' updateInfo.version '"')
            && InStr(head, 'APP_NAME       := "Performance Companion"'))
            throw Error("the download doesn't look like Performance Companion " updateInfo.version)
    } catch as e {
        Log("UPDATE      download failed: " e.Message)
        if !silent
            MsgBox("The update couldn't be downloaded (" e.Message ").`nYou can get it from:`n" REPO_URL "/releases/latest",
                "Performance Companion", "Icon!")
        return
    }
    Log("UPDATE      installing " updateInfo.version (silent ? " automatically" : ""))
    ShowOSD("Installing Performance Companion " updateInfo.version "...", "Green", true)
    Run('"' A_AhkPath '" "' tmp '"')        ; installs itself and replaces this copy
}

; Hourly timer; checks when the last check is a day old.
DailyUpdateCheck() {
    last := IniRead(STATE, "app", "update_checked", "")
    if (last = "" || DateDiff(A_Now, last, "Hours") >= 24)
        CheckForUpdates()
}
; ====================================================================
;  EMBEDDED ICONS (written to the install folder once per version)
;  everyday = blue laptop, desk = red bolt, travel = teal battery,
;  custom = purple star, paused = grey.
; ====================================================================
IconData_everyday() => "
(
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
TkSuQmCC
)"

IconData_desk() => "
(
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
)"

IconData_travel() => "
(
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
rkJggg==
)"

IconData_custom() => "
(
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
)"

IconData_paused() => "
(
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
)"


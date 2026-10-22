# Performance Companion

*for gaming laptops and handhelds*

**[Download the latest version](https://github.com/zonearc/PerformanceCompanion/releases/latest)** · **[Report a problem or suggest something](https://github.com/zonearc/PerformanceCompanion/issues/new/choose)** · **[What's new](CHANGELOG.md)**

**Automatic performance modes for gaming laptops and handhelds.** Performance Companion shifts your machine between quiet, everyday and full-power modes on its own: when a game starts, when you open a power-hungry app, when you unplug, or on a schedule. One click switches a whole setup when you want to take over.

It's built for gamers first, but anything that needs full power works the same way. Add FL Studio, Blender, Premiere or a local AI model and it gets its own mode while it runs.

## Why it exists

Performance laptops and handhelds make you babysit them. Full power when you game, quiet when you work, stretched battery on the road, and every change is a trip into your maker's app, Windows settings, or both. Forget once and you're either gaming at half speed or watching the battery melt at the gate.

Performance Companion remembers what you want and does the switching for you. It also checks its work: if something drifts after a reboot, an unplug, or another app's interference, Performance Companion puts it back.

## Works with your machine

Performance Companion detects what it's running on and picks the right engine automatically.

| Your machine | Engine | What you get |
|---|---|---|
| **ASUS laptops and handhelds with [G-Helper](https://github.com/seerge/g-helper)** (Zephyrus, Strix, TUF, ProArt, ROG Ally...) | G-Helper | Everything below, plus GPU modes (Eco / Standard / Ultimate), charge limits, trip charging, and your own G-Helper custom modes by name |
| **Everything else:** Razer, Lenovo Legion, MSI, Alienware / Dell, HP OMEN, ASUS with Armoury Crate, Legion Go, MSI Claw, Steam Deck on Windows, AYANEO, GPD, OneXPlayer... | Windows power plans | Everything below. Your maker's app sets the hardware ceiling once; Performance Companion decides how much of it Windows uses |

On the power plans engine, Performance Companion creates three Windows power plans (Eco, Work, Performance) and manages CPU speed, turbo boost, Windows' power mode, the built-in screen's refresh rate and Energy Saver for each. Uninstalling removes them and puts Windows back the way it was.

**One-time setup on non-G-Helper machines.** Windows power plans can hold your machine *below* what your maker's app allows, never above it. So set your maker's app to its highest mode while plugged in, once. Performance Companion's setup check recognizes Razer Synapse, Lenovo Vantage and Legion Space, MSI Center, Alienware Command Center, OMEN Gaming Hub and Armoury Crate, and tells you exactly what to set.

**Handhelds with Handheld Companion.** Let Handheld Companion handle TDP (its strength) and Performance Companion handle everything else. In Handheld Companion's power profiles, set your TDP and leave its Power mode, EPP and CPU boost overrides off so the two apps don't fight. Performance Companion reminds you of this when it sees Handheld Companion running.

## What it does

### Profiles: one click for a whole setup

A profile bundles everything you'd otherwise change by hand: the mode plugged in and on battery, how games and apps are handled, which apps to open or close, and (with G-Helper) GPU mode and charge limit. Three are ready out of the box; edit, rename, delete or add as many as you like.

**G-Helper:**

| Profile | GPU | Charge limit | Switching |
|---|---|---|---|
| **Work** | Optimized: Eco on battery, Standard plugged in | 80% | Instant |
| **Gaming** | Ultimate: NVIDIA straight to the screen | 80% | Restarts (Ultimate needs it) |
| **Travel** | Optimized | 100% | Shuts down, boots ready on the road |

**Windows power plans:**

| Profile | Plugged in | On battery | Games and apps |
|---|---|---|---|
| **Work** | Work | Eco | Own mode when plugged in |
| **Gaming** | Performance | Work | Own mode always |
| **Battery Saver** | Eco | Eco | Off |

Switch from the tray icon, the Start menu ("Performance Companion profiles"), or **Ctrl+Win+Alt+T** for a profile picker. Settings can also switch profiles automatically when you unplug and back when you plug in.

### Automatic modes for games and apps

- **Recognizes games instantly** from Steam, Xbox, major publisher folders (EA, Epic, Riot, Ubisoft, Blizzard and more), and anything you add.
- **Catches new games** by watching which app is working the GPU hard, using the same numbers as Task Manager.
- **Learns as you play.** A new game that holds real load for 30 seconds is remembered for next time.
- **Any app you add counts too.** DAWs, video editors, renderers, local AI tools: add the .exe in **Apps and games** and it gets its mode the moment it opens.
- **Per-app modes.** Not everything needs full power. Pick a mode per game or app from the tray, or press **Ctrl+Alt+G** in-game to cycle it. With G-Helper, your own custom modes (like a quiet mode with full power for music work) are listed by the names you gave them.
- **Ignores launchers and stores** like Steam, Battle.net, the EA app and the League client.
- **No games are built in.** Your list is built from what you use.

### Schedules (optional, off until you turn them on)

- **Recurring switches**, like Gaming every Friday at 7 pm and back to Work at 11:30.
- **One-time switches** at a date and time.
- **Trips (G-Helper):** tell it when you leave. It raises the charge limit early enough to be full at departure, reminds you to plug in, and can switch to Travel just before you go.

Schedules never surprise you. Before any restart or shutdown you get a warning 10 minutes and 2 minutes ahead with **Postpone**, **Skip** and **Do it now**. Switches wait while a game is running, and if the machine was off at the scheduled time, Performance Companion asks before catching up.

### Always clear about what it's doing

- **Tray icon shows the profile:** blue laptop, red lightning bolt, teal battery, or your pick. Grey when paused.
- **Live tooltip,** for example `PerfCompanion: Gaming | AC | Turbo (eldenring.exe)`.
- **Hover help everywhere.** Rest the mouse on anything in Performance Companion's windows to see what it does.
- **Brief on-screen messages** when something changes (can be turned off).
- **Activity log** with one line per decision, including unexpected errors. It trims itself and can be cleared from the tray.
- **One-click diagnostics** for bug reports, with your username and PC name hidden.

## Requirements

- **Windows 10 or 11** and **[AutoHotkey v2](https://www.autohotkey.com)**.
- **For the G-Helper engine:** G-Helper installed, run at least once, with **Run on Startup** ticked. GPU modes need a model with a MUX switch. Armoury Crate and MyASUS should be uninstalled or stopped, since they fight G-Helper.
- **For the power plans engine:** nothing else. Set your maker's app to its highest mode while plugged in, once.

## Install

1. Install AutoHotkey v2 (and G-Helper, if you use it).
2. Download `PerformanceCompanion.ahk` from the [latest release](https://github.com/zonearc/PerformanceCompanion/releases/latest), put it anywhere, and double-click it.
3. Approve the one administrator prompt.

Performance Companion copies itself into place, starts with Windows, adds a Start menu shortcut, picks its engine and starting profile, and shows a short welcome with any one-time setup for your machine. After that, no popups.

**Coming from G14 Control, Laptop Control or Clutch?** Just install Performance Companion. It imports your profiles, games, schedules and settings, retires the old app's startup tasks and shortcuts, and leaves the old data folder as a backup.

## Updating

Download the new version and double-click it. No admin prompt, no uninstalling. Everything carries over.

## The tray menu

```
Game: eldenring.exe (Turbo)          >  Turbo / Balanced / Silent / your custom modes / Default / Ignore
      Ctrl+Alt+G cycles this in-game
Profile: Gaming (Ultimate, 80%)
Switch to Work (...)
Switch to Travel (...)
Profiles...
Power plans...                          (power plans engine only)
Schedules...   (next: Fri 19:00 Gaming)
Apps and games...
Settings...
Troubleshooting                      >  Status, Copy diagnostics, activity log, GPU watch,
                                        setup check, pause, reload, uninstall
Exit
```

Mode names follow the engine: Turbo / Balanced / Silent with G-Helper, Performance / Work / Eco with power plans.

## Everyday use

| To do this | Do this |
|---|---|
| Switch profiles | Tray menu, Start menu "Performance Companion profiles", or **Ctrl+Win+Alt+T** |
| Change what a profile does, or add one | Tray > **Profiles** |
| Tune what each mode does (power plans) | Tray > **Power plans** |
| Give an app or game its own mode | Tray > **Apps and games** > Add app or game |
| Change the current game's mode | Tray menu, top line, or **Ctrl+Alt+G** in-game |
| Set up timed switches or a trip | Tray > **Schedules** |
| Force the high / middle mode for a while | **Ctrl+Alt+T** / **Ctrl+Alt+B** (releases after 3 hours or a power change) |
| Switch engine, or auto-switch on unplug | Tray > **Settings** |
| See what's happening | Hover the tray icon, or Troubleshooting > **Status** |

## Good to know

- **Restarts only happen for Ultimate** (G-Helper). The GPU's MUX switch is read at boot. Performance Companion clicks G-Helper's buttons for you and asks you to keep hands off the mouse until it restarts.
- **Refresh-rate switching only touches the built-in screen,** waits until no fullscreen game is in front, and restores the highest rate when Performance Companion exits.
- **If something else keeps changing your power plan** (a maker's "smart" mode), Performance Companion puts its plan back and logs it. Turning that feature off is the cleaner fix.
- **Two steps read G-Helper's English text** (clicking Ultimate and its restart prompt). On other Windows languages you'll be asked to click those yourself.
- **The tray icon appears shortly after login,** once Performance Companion (and G-Helper, if used) has started.

## Uninstall

Tray > Troubleshooting > **Uninstall**. It removes the startup tasks and shortcut, removes Performance Companion's power plans and switches Windows back to the plan you used before, and asks whether to keep your data in case you reinstall. G-Helper and its settings are left untouched.

## Troubleshooting

**Reporting a problem:** Tray > Troubleshooting > **Copy diagnostics**, then [open an issue](https://github.com/zonearc/PerformanceCompanion/issues/new/choose) and paste it in. It includes your device, engine, versions, settings and recent activity, with your username and PC name hidden.

| Symptom | Try |
|---|---|
| Nothing happens at all | Troubleshooting > **Setup check**. With G-Helper, it's usually G-Helper not running. |
| Performance mode doesn't feel faster | Set your maker's app to its highest mode while plugged in (Setup check shows how for your brand). |
| The power plan keeps flipping | A maker's app or Handheld Companion is changing it. Turn off its automatic power mode, or its power mode / EPP overrides. |
| A game or app doesn't trigger | Add it in **Apps and games**, or use Troubleshooting > **Watch GPU load**. Check the profile's **Game modes** setting too. |
| Something that isn't a game triggers | Tray menu, top line > **Ignore**. |
| A schedule didn't run | Make sure **Run schedules** is ticked in the Schedules window, and check the date. |
| Wrong engine picked | Tray > Settings > **Engine**. |

## License

MIT. Free to use, share and modify; see [LICENSE](LICENSE).

Performance Companion is an independent project. It isn't affiliated with ASUS, G-Helper, Handheld Companion, or any laptop maker; it works alongside their software.

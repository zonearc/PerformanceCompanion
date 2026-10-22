> Historical design notes from Laptop Control, the Windows power plans version that became Performance Companion's power plans engine. Kept for the reasoning behind its defaults.

# Laptop Control: Fork Notes

How and why Laptop Control was forked from G14 Control, what changed, and the reasoning behind each decision. Read this alongside `LaptopControl.ahk` and its `README.md`.

## Where it came from

G14 Control is an AutoHotkey v2 app written for an ASUS ROG Zephyrus G14. It sits on top of [G-Helper](https://github.com/seerge/g-helper): G-Helper does the hardware work, and G14 Control remembers what you want and tells G-Helper when to do it. Its core value was never G-Helper itself. It was three ideas:

1. **Profiles.** One click switches a whole setup instead of a checklist of settings.
2. **Automatic game modes.** Games are recognized or learned, and get their own performance mode while they run.
3. **Self-correction.** If a setting drifts after a reboot, an unplug or another app's interference, it gets put back.

The question that started this fork was simple: could those three ideas work on a laptop that has no G-Helper? The target was a Razer Blade 15 Advanced (Studio 15: i9-11900H, RTX 3080 Laptop GPU) running Razer Synapse.

## Goals

- **Three modes:** an Eco mode that stretches the battery, a Work mode for everyday use, and an all-out Performance mode for gaming.
- **Keep what made G14 Control useful:** automatic game detection, per-game modes, profiles, the tray icon and the hotkey picker.
- **Switch to Eco automatically on battery** and return when plugged back in.
- **Generic by design:** work on any Windows laptop, not just one brand.
- **Drop what only made sense on the G14.**

## The key decision: don't script Synapse

The first instinct was to have the script drive Synapse the way G14 Control drives G-Helper. That idea was dropped for three reasons:

- **There's no API.** Synapse has no command line or documented interface, so the only option would be clicking its window. That breaks every time Razer redesigns the app.
- **Synapse doesn't follow Windows.** It doesn't read the Windows power plan, so the two can't be linked that way either.
- **It already handles battery.** On battery, Synapse forces its own limited Balanced mode no matter what you pick, so the unplugged case is covered without any help.

The model that came out of this treats power control as two stacked layers:

| Layer | What it controls | Who sets it |
|---|---|---|
| **Vendor tool** (Synapse) | The hardware ceiling: CPU and GPU power limits, fan behavior | Set once, by hand, to its maximum |
| **Windows** | How much of that ceiling gets used: CPU cap, turbo, power mode, refresh rate, Energy Saver | Laptop Control, automatically |

Windows settings can hold the machine *below* the vendor ceiling. They can't push it *above* it.

That's why the one-time setup step matters. In Synapse, set Performance > Plugged In to **Custom, CPU Boost, GPU High**, with fans on **Auto**. Before the fork, the Razer was sitting on Medium/Medium, so its "all out" wasn't actually all out.

Synapse profiles were considered too. Switching between them is still a manual click, so the script can't rely on them.

## What we deliberately left out

- **GPU caps through MSI Afterburner.** Windows power plans can't limit the GPU, and Afterburner could. It was ruled out to keep the app simple and free of extra dependencies. In practice, the GPU idles when no game is running and runs flat out when one is.
- **Forcing the NVIDIA GPU off in Eco.** The Razer has no MUX switch, so it always runs hybrid graphics, and the NVIDIA GPU sleeps on its own when nothing needs it. Disabling it outright saves a little more battery, but it's fragile, and it would black out the HDMI port, which is wired straight to the NVIDIA GPU.
- **Schedules and trips.** On the G14, scheduling existed because entering or leaving Ultimate mode needs a reboot. Without a MUX switch, every switch is instant, so timed switches and trip charging stopped earning their complexity.
- **Charge limits.** Windows has no generic way to set one. Razer's Battery Health Optimizer lives inside Synapse.

## What carried over, what changed, what's new

### G14 concept to Laptop Control equivalent

| G14 Control | Laptop Control |
|---|---|
| G-Helper modes: Turbo / Balanced / Silent | Windows power plans: Performance / Work / Eco (same internal ids 1 / 0 / 2) |
| G-Helper hotkeys and config.json | `powercfg` plus the powrprof and display APIs |
| Profiles: GPU mode, charge limit, battery / AC modes, game rules, apps | Profiles: plugged-in plan, battery plan, game rules, apps |
| Work / Gaming / Travel | Eco Battery / Work / Performance |
| Restarts for Ultimate, shutdown for Travel | Always instant, no restarts |
| G-Helper self-test | Setup check confirms the three plans exist |
| Custom 1 / Custom 2 modes | Removed; tune the plans in Tray > Power plans instead |

### Kept as-is

- Game detection: Steam, Xbox, publisher folders, games you added, and GPU-load detection through the same counters Task Manager uses.
- Learning new games after 30 seconds of real load.
- Launcher and store ignore lists. Razer's own apps were added so Synapse never counts as a game.
- Per-game modes, the Games and modes window, and Ctrl+Alt+G to cycle the mode in-game.
- Tray menu, tooltip and profile icons; Ctrl+Win+Alt+T picker; Start menu shortcut.
- Opening and closing apps per profile.
- Install by double-click, an elevated startup task, and updates with no admin prompt.
- Activity log, Status window, Copy diagnostics with personal details masked, and hover help everywhere.

### Removed

- Everything that talked to G-Helper: hotkeys, config.json editing, prompt clicking, Ultimate switching, self-test.
- Schedules, trips, trip charging and charge-rate learning.
- GPU modes, charge limits, the "after switching" restart and shutdown options.
- ASUS-specific setup checks (Armoury Crate, MyASUS) and the English-language check.
- A leftover AMD game-database reader that never actually worked.

### New

- **Power plan engine.** Creates three plans as copies of Windows' Balanced plan (so sleep and screen-off timers carry over), keeps their settings in sync, and switches them through the Windows power API.
- **Power plans window** (Tray > Power plans). Each plan has editable CPU max %, turbo level, built-in screen refresh rate and Energy Saver threshold.
- **Windows power mode slider**, set per plan (Best efficiency / Balanced / Best performance), on a best-effort basis.
- **Built-in screen refresh rate.** The app finds the laptop's own panel through Windows' display configuration, so external monitors are never touched.
- **Automatic profile on unplug,** with a return on plug-in. A choice you make while unplugged wins, even across restarts.
- **Drift correction.** If anything else changes the power plan, it's put back within about 3 seconds and logged.
- **Vendor-aware setup check.** It detects Synapse and reminds you of the one-time setting. It also warns about G-Helper and other vendor tools that switch power plans themselves.
- **Clean uninstall.** It deletes the three plans and restores the power plan you used before installing.

## The three plans (version 1.0.1 defaults)

| Setting | Eco | Work | Performance |
|---|---|---|---|
| CPU max | 70% | 100% | 100% |
| Turbo boost | Off | Efficient | Aggressive |
| CPU bias (EPP) | 70, battery-leaning | 33 | 0, full speed |
| Windows power mode | Best power efficiency | Balanced | Best performance |
| Built-in screen | 60 Hz | Highest | Highest |
| Energy Saver | Always on battery | At 20% | Never |
| PCIe link power | Maximum savings | Balanced default | Off |
| Core parking | Most cores parked | Balanced default | All cores awake |
| Wi-Fi power saving | Maximum saving | Balanced default | Maximum performance |
| USB selective suspend | On | Balanced default | Off |

**Minimum processor state stays at 5% in every plan, on purpose.** Pinning it at 100% only keeps clocks high while idle, which adds heat and fan noise without making games faster. Turbo and the CPU bias already ramp to full speed the moment there's load.

The bottom four rows were added in 1.0.1. The first build copied Balanced's power savers into every plan, so Performance still had PCIe link power on "Maximum power savings." That added wake-up delay to the GPU and SSD, and it was spotted in Windows' power options during testing.

Turbo and CPU bias don't show in Windows' power options by default. To confirm them, run these while on Performance:

```powershell
powercfg /query SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE
powercfg /query SCHEME_CURRENT SUB_PROCESSOR PERFEPP
```

The AC values should read `0x00000002` (Aggressive) and `0x00000000` (full speed).

## Default profiles

| Profile | Plugged in | On battery | Game modes |
|---|---|---|---|
| Eco Battery | Eco | Eco | Off |
| Work | Work | Eco | When plugged in |
| Performance | Performance | Work | Always |

When you unplug, the laptop switches to Eco Battery. Plugging back in returns it to the profile you were on.

## How it was verified

- **Load check.** The script loads cleanly in AutoHotkey 2.0.18, run under Wine with an immediate exit so that only load-time errors surface. This catches syntax errors and calls to missing functions.
- **Static checks.** No references remain to removed G14 features, and every function that's called is defined.
- **Independent review.** A separate review covered the Win32 structure layouts, the powercfg aliases and the timer logic, then confirmed the display and power API usage was correct. It also found real bugs, all fixed before release:
  - **Uninstall could race the timers.** It could leave you on an orphaned plan that nothing would delete. Automation now pauses before anything is removed.
  - **Manual locks (Ctrl+Alt+T / Ctrl+Alt+B) could stick forever.** They now release when a game starts or stops, when you plug in or unplug, or after 3 hours.
  - **A known game could stay in game mode after it closed**, if a video or another app kept the GPU busy. Known games now release once they're gone.
  - **Refresh-rate changes could knock a fullscreen game out of fullscreen.** Changes now wait until nothing fullscreen is in front, use the saved desktop mode, and restore the highest rate on exit and uninstall.
  - **A single bad GPU-counter reading could switch detection to the slow fallback permanently.** It now takes three failures in a row, and readings right after a counter refresh are skipped.
  - **A publisher entry pointing at a drive root could make every app count as a "known game."** Install folders are now validated.
  - **A refused plan switch retried and logged every 3 seconds forever.** It now backs off, and recreates any plan that was deleted.
- **Real-world testing on the Razer.** Eco and Work switch correctly when unplugging and plugging back in. The PCIe finding from that testing led to 1.0.1.

## Known limitations

- **No GPU power or fan control.** That stays with the vendor tool. Fans follow heat, so a capped CPU runs quieter.
- **The power mode slider isn't guaranteed.** Some PCs ignore Windows' power mode with custom plans. The plans' own CPU and turbo settings apply either way, and Setup check reports it.
- **Refresh switching needs the built-in screen to be on.** With the lid closed and an external monitor, it's skipped.
- **Plan switches only hold if nothing else fights them.** Vendor apps with "smart" power modes can flip plans. Laptop Control puts its plan back and logs it, but the cleaner fix is turning that vendor feature off.
- **Real-machine testing so far is the Razer Blade 15 Advanced only.** Other brands should work, since the app relies only on standard Windows features, but they haven't been tested.

## Version history

| Version | Changes |
|---|---|
| 1.0.0 | First fork from G14 Control 2.0.1. Power plan engine, three plans and profiles, unplug auto-switch, power plans window, review fixes. |
| 1.0.1 | Performance turns off the inherited power savers (PCIe link power, core parking, Wi-Fi power saving, USB selective suspend). Eco turns them all on. Work keeps Balanced's defaults. |

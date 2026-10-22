# Changelog

## 3.0.4 (October 2026)

- **Simpler to use:**
  - The tray menu is grouped at a glance: what's running now, your profiles (the active one ticked, click another to switch), setup, then help.
  - The tray menu ends with **Report an issue** and **Help and troubleshooting**. Diagnostics, logs, pause, reset and uninstall now live in one window.
  - **Settings** and **Profiles** start simple, with a **Show advanced** option for the rest.
  - **Reset everything** puts settings, profiles and power plans back to the defaults, with the option to keep your games.
  - **Restore defaults** in Profiles.
- **Schedules work like a calendar app:**
  - One form for one-time or repeating schedules: every day, every weekday, weekly, every 2 weeks, or monthly.
  - Any schedule can switch back later.
  - A start date.
  - **Plan a trip** is its own simple form.
  - The window opens with examples of what schedules are for.

## 3.0.3 (October 2026)

- **Report an issue:** long diagnostics now paste cleanly into the bug form (the form was resetting a pre-filled box after pasting).

## 3.0.2 (October 2026)

- **Report an issue** (Troubleshooting): opens a pre-filled bug report on GitHub with your device and diagnostics, so problems get to us with everything needed to fix them.
- **Update checks:** looks for a new release once a day and offers it in the tray menu, or installs it by itself if you choose (Settings > Updates). Downloads are verified before they're run.

## 3.0.1 (October 2026)

- **New name: Performance Companion** (briefly called Clutch during testing). Installing it imports settings from G14 Control, Laptop Control or Clutch and retires the old app.

## 3.0.0 (October 2026)

One app for any gaming laptop or handheld, merging G14 Control and its Windows power plans fork, Laptop Control.

- **Two engines, picked automatically:** G-Helper on ASUS machines that run it, Windows power plans everywhere else. Can be overridden in Settings.
- **Device detection** for laptops, desktops and handhelds (ROG Ally, Legion Go, MSI Claw, Steam Deck, AYANEO, GPD, OneXPlayer, AOKZOE, Ayn Loki, ZOTAC Zone).
- **Maker app tips:** the welcome screen and setup check spot Razer Synapse, Lenovo Vantage and Legion Space, MSI Center, Alienware Command Center, OMEN Gaming Hub and Armoury Crate, and say which setting to max out once.
- **Handheld Companion:** detected, with guidance so it handles TDP while Performance Companion handles the rest.
- **G-Helper custom modes** are read from G-Helper and offered by the names you gave them. The first two switch by hotkey; later ones by stepping through G-Helper's mode list.
- **"Apps and games"** (was "Games and modes"): any power-hungry app (DAWs, editors, renderers, local AI) can get its own mode.
- **From Laptop Control:** power plan engine and editor, built-in screen refresh switching, automatic profile on unplug, drift correction, plan restore on uninstall, and its review fixes:
  - Manual locks now release.
  - Known games release once closed.
  - The GPU counters don't give up after one bad reading.
  - Install folders are validated.
- **Three-level modes in profiles:** plugged-in and battery modes can each be high, middle or low.

## G14 Control 2.0.1

- Copy diagnostics for bug reports, with personal details masked.
- Unexpected errors are logged instead of showing AutoHotkey's error dialog.

## G14 Control 2.0.0

- Unlimited user-defined profiles; Work, Gaming and Travel ready out of the box.
- Schedules: recurring and one-time switches, trip charging, warnings with Postpone / Skip / Do it now, never mid-game, catch-up after the laptop was off.
- Native hover help, a short first-run welcome, the active profile highlighted, and a log you can clear.

## G14 Control 1.x

- Desk and Travel profiles for G-Helper, automatic game detection and learning, per-game modes, a self-test against new G-Helper versions, and seamless updates.

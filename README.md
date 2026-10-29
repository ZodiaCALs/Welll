# Welll

Welll is a free battery charge limiter for MacBooks that does what AlDente does, with a window laid out the same way. It stops charging at the level you pick, so a Mac that lives on its charger doesn't sit at 100% all day. Welll was called Plateau; installing it removes Plateau and keeps your settings.

On macOS 26 and later the window uses Liquid Glass; earlier versions get translucent materials. You build it yourself from this folder. It hasn't been tested on every Mac, so check `welllctl status` after installing.

## Features

- **Charge limit** from 20% to 100%
- **Discharge**: run on battery while plugged in until the battery is down to the limit
- **Top up**: charge to 100% once; the limit comes back after you unplug
- **Sailing mode**: let the charge drift down a few percent before charging again
- **Heat protection**: pause charging while the battery is warm
- **Calibration**: charge to 100%, hold for an hour, run down to 15%, charge to 100% again, then return to your limit
- **MagSafe light**: green at the limit, orange while charging
- **Sleep handling**: stop charging when the Mac sleeps, or keep it awake until it reaches the limit
- **Power flow**: live watts from the charger, into the Mac and in or out of the battery, read from the SMC's power sensors and refreshed every 1, 2, 5 or 10 seconds
- **Apps using significant energy**, measured from the energy macOS bills to each app, as in the battery menu
- **Menu bar battery** drawn like macOS 26's own (solid charge, translucent empty part, the bolt cut out), with the percentage outside it on the left
- **Developer options** behind a password: helper tuning, a forced control method, manual control, live SMC keys and raw data
- Battery health, cycle count, temperature, voltage and the battery's own (hardware) percentage
- `welllctl` for Terminal, which also works from Shortcuts through the "Run Shell Script" action

A background helper enforces the limit, so it keeps working after you quit the app.

## What works on your Mac

In 2026 Apple changed the hidden charging controls that AlDente and similar apps rely on. When it starts, Welll checks what your Mac exposes and uses the best method it finds.

| Your Mac | Welll uses | What you get |
|---|---|---|
| Apple silicon whose firmware predates the macOS 27, 26.7 and 15.8 updates | SMC charge control | Every feature |
| Apple silicon on macOS 26.4 or later with the new firmware, including macOS 27 | macOS Charge Limit | Limits from 80% to 100% in 5% steps, held even while the Mac sleeps. macOS drains a battery that's above the limit by itself. Lower limits need "Allow limits below 80%" |
| Apple silicon on macOS 15.8 | Adapter cut-off | Works only with "Limit with adapter cut-off" turned on, and only while the Mac is awake |
| Intel | Firmware limit (BCLM) | Limit held while asleep; no sailing mode |

`welllctl probe` shows what your Mac exposes. The Battery section of the app shows the method in use.

**Adapter cut-off** switches wall power off at the limit, so the Mac runs on battery until the charge is a few percent lower, then switches it back on. That adds shallow charge cycles and only works while the Mac is awake, so it's off until you turn it on. Welll always switches wall power back on before the Mac sleeps and when the helper stops.

**You might not need Welll.** On macOS 26.4 or later, System Settings › Battery › the ⓘ button next to Charging › Charge Limit holds 80–100% with no extra software.

## Install

You need macOS 13 or later and Apple's free command line tools:

    xcode-select --install

**From source, on this Mac.** Open Terminal in this folder and run:

    bash install.sh

It builds Welll, copies it to /Applications, installs the helper (asking for your password once) and opens the app.

**As a disk image.** Run:

    bash release.sh

This creates `build/Welll-<version>.dmg`. Open it, drag Welll to Applications, open Welll, and press **Install helper** in its window. The app installs its own helper from inside its bundle, after checking the bundle's signature is intact.

A disk image signed ad hoc opens fine on the Mac that built it. Other Macs will say it can't be checked for malicious software; there, open it with right-click › Open, or allow it in System Settings › Privacy & Security. To ship it properly, sign with a Developer ID and notarise:

    SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE="profile" bash release.sh

(`NOTARY_PROFILE` is a profile saved with `xcrun notarytool store-credentials`.)

If macOS shows "Background Items Added", leave Welll allowed in System Settings › General › Login Items & Extensions.

Before installing, quit AlDente or any other charge limiter: two tools controlling charging fight each other. With SMC charge control, also turn off Optimized Battery Charging in System Settings › Battery, because it can hold the battery at 80% on its own.

## Using it

Click the battery in the menu bar. The window follows AlDente's layout:

- **The top row** has the limiter switch.
- **The charge** shows as liquid in a glass battery, with a ridge at your limit. Green means charging, teal holding, orange discharging, red paused for heat.
- **Charge limit**: drag the slider.
- **Quick toggles**: Discharge, Top Up and Calibrate run once; Sailing, Heat and Sleep switch those features on and off. Toggles your Mac's control method can't do are dimmed.
- **Power flow** shows live watts; the green dot blinks with each new reading. "Every 2 s" sets how often.
- **Using significant energy** lists apps averaging a watt or more while the window is open.
- **Battery** opens health, cycles, temperature, capacity and condition. **Settings** opens everything else.

macOS updates some battery figures only every few seconds, so the fastest refresh mostly helps you catch changes the moment they happen.

### Developer options

At the bottom of Settings, **Developer options** asks for a password. Inside:

- **Helper**: how often it re-checks, verbose logging, a forced control method (or observe only), Check now, Self-test, Restart
- **Policy tuning**: the lowest charge on battery, the heat resume drop, the adapter cut-off band, calibration hold time and low point
- **Manual control**: for 15 minutes, pause or allow charging, switch wall power off or on, and set the MagSafe light yourself. Wall power still comes back on before sleep and at the lowest charge.
- **SMC keys** read live, the battery's raw properties, the helper's log and the status as JSON
- **Reset** for all settings or just the app's preferences

The password is stored as a SHA-256 digest in `Sources/Welll/DeveloperLock.swift`. It keeps casual users out, but it isn't security: anyone with the app can patch it. To change it, run `echo -n 'new password' | shasum -a 256` and paste the result there.

## Command line

    welllctl status                 # what Welll is doing right now
    welllctl limit 75               # set the limit
    welllctl off                    # charge normally until you run `welllctl on`
    welllctl discharge              # run down to the limit while plugged in
    welllctl topup                  # charge to 100% once
    welllctl set sailing 5          # charge again 5% below the limit
    welllctl set heat 35            # pause charging above 35 °C
    welllctl set adapter-cutoff on  # allow limits below 80% on new firmware
    welllctl probe                  # what this Mac's firmware allows
    welllctl doctor                 # why the app can't reach the helper

Run `welllctl help` for everything else.

## The app icon

`Resources/AppIcon.icns` is drawn by `Scripts/make-icon.py` (Python with Pillow and NumPy). It's flat and abstract: three bars, the "lll" of Welll, each solid up to the same level like the menu bar battery. On macOS 26, Finder may show it on a rounded backdrop, because the full Liquid Glass icon treatment needs an Icon Composer icon built with Xcode.

## How it works

Welll has three parts:

- `wellld` is a LaunchDaemon that runs as root. It reads the battery from the AppleSmartBattery entry in the I/O Registry, reconsiders every 15 seconds and whenever power changes, and talks to the hardware.
- `Welll.app` is the menu bar app. It only talks to the helper, over XPC.
- `welllctl` offers the same controls in Terminal.

The helper uses these controls, in order of preference:

- `CHTE` (newer firmware) or `CH0B` and `CH0C` (older firmware) pause charging while the Mac keeps running from the charger.
- macOS's own Charge Limit, set through `PowerUISmartChargeClient`, the private class System Settings uses. Each call runs in a separate short-lived process, so a crash or hang in Apple's code can't stop the helper; after three failures in a row Welll stops using it and says so. Each change is checked against `pmset -g battlimit`. Welll saves the limit you had before and restores it when you turn the limiter off or uninstall.
- `CHIE` (or `CH0I` on older firmware) switches wall power off. It's used for Discharge, Calibration and adapter cut-off.
- `ACLC` sets the MagSafe light. `BCLM` is the Intel firmware limit.

A key only counts if it has the expected size and the helper can write its current value back. That filters out the empty placeholders and locked keys on new firmware.

The helper only accepts high-level requests (set the limit, start a mode) from root or the user logged in at the screen. It never writes arbitrary SMC keys.

### Where the battery figures come from

macOS 27 moved the battery's capacities into a nested `BatteryData` dictionary and stopped publishing its temperature in the registry. Welll reads capacities from either place, and temperature from the SMC's battery sensors (TB0T to TB2T). Live power comes from the SMC's power rails (PSTR for the Mac, PDTR for the charger), because the registry's power figures only change now and then. Health and condition match System Settings when `system_profiler` reports them; Welll asks it every half hour.

## Limitations

- The SMC keys and PowerUI are undocumented Apple internals. A macOS update can change them, as macOS 27 did. When a change doesn't take, the app shows an error instead of claiming success.
- With SMC charge control, a sleeping Mac keeps charging unless "Stop charging when asleep" is on.
- Some Macs only accept the values System Settings offers through PowerUI. Welll tells you when macOS keeps a different value.
- Heat protection on the macOS Charge Limit method can only pause charging above 80%.
- The app is signed ad hoc for your own Mac and isn't notarized.

## Troubleshooting

- **The build fails.** Update the command line tools with `softwareupdate --list`, then run `bash install.sh` again. The compiler names the file and line at fault.
- **The window says it can't reach the helper.** It also says why: not installed, switched off in Login Items & Extensions, not loaded, or stopping right after it starts. **Restart helper** loads it (macOS asks for your password). If macOS refuses, the window shows what macOS said and offers to open Login Items & Extensions, where `local.welll.daemon` must be switched on.
- **macOS won't load the helper.** Run `sudo /Library/PrivilegedHelperTools/local.welll.loader`. It fixes ownership, clears the "downloaded from the internet" flag, re-enables the helper, tries both `launchctl bootstrap` and the older `launchctl load -w` (macOS 26 sometimes needs the latter), and prints the reason if it still fails.
- **For a full report**, run `welllctl doctor`. It checks the files, launchd, the connection and the code signature, and shows the helper's log and any crash reports.
- **To watch the helper start**, run `sudo /Library/PrivilegedHelperTools/local.welll.daemon --self-test`. It prints which controls it finds and whether macOS's Charge Limit answers.
- **Logs.** `log stream --predicate 'subsystem == "local.welll"'`, or `/var/log/welll.log`.
- **The battery won't charge at all.** Run `welllctl restore`, or uninstall. Restarting the Mac also clears the SMC switches.

## Uninstall

    bash uninstall.sh

This hands charging back to macOS, restores your original macOS Charge Limit, and removes the app, the helper and `welllctl`.

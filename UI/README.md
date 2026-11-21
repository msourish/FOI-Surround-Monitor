# FOI Surround Monitor native UI

The production Objective-C sources are `FOISurroundMonitor.m`,
`FMInputMeterView.m/.h`, and `FMChannelTrimView.m/.h`. The entry point retains the
existing six-channel meters, room view, session trims, bounded telemetry,
explicit Start/Stop control, input-permission action, and verified-cleanup quit
handling. It does not render Atmos or fold a larger channel layout to 5.1.

Build from the repository root:

```sh
zsh UI/build.sh
```

This produces `UI/build/FOISurroundMonitor` and runs its software-only
`--self-test` branch before creating NSApplication. The build uses ARC, strict
warnings, the macOS13 deployment target, Cocoa, AVFoundation and QuartzCore.
Neither building nor self-testing opens audio devices, starts a GUI, requests
permission, or launches a monitoring session.

The app menu's **About FOI Surround Monitor** opens the standard native About
panel and reads bundled `Contents/Resources/Credits.rtf`. Packaging should copy
the repository's staged `Resources/Credits.rtf` there. The credit is
**Created by Sourish Mukherjee (@msourish). AI collaborator: SOURX.**

## Output selection

Use the gear menu → **Output** → a compatible device. **Refresh outputs** runs
read-only discovery. Launching the app also discovers outputs but never starts
audio. A unique compatible candidate may be selected automatically; multiple
candidates require an explicit choice unless the previously selected UID is
still present. An unavailable device is shown but cannot start. The native
backend makes the authoritative availability check again at Start.

Discovery runs asynchronously with a five-second deadline and a 64KiB response
limit. Only its known read-only child may be force-stopped after timeout; the
audio backend retains the separate graceful Stop/restore policy.

Expected read-only interface:

```text
/usr/bin/python3 -B Contents/Resources/Backend/monitor_backend.py --list-outputs
```

Response:

```json
{"schema_version":1,"outputs":[{"uid":"device-uid","name":"Digital output","sample_rate":48000,"encoded_format":"cac3","available":true,"unavailable_reason":null}]}
```

`available` and `unavailable_reason` are optional compatibility fields. Explicit
unavailability disables selection/Start. Duplicate UIDs, invalid formats and
malformed responses are rejected.

Start adds `--output-device <selected UID>` to the usual backend session/status/
stop-file/parent-PID arguments. Output selection is fixed during that session.
An active indicator, meter presentation and trim controls require the reported
running `status.output.uid` to match the session's selected UID, in addition to
the AC-3/48kHz/six-channel/448kb/s status checks. Display text uses the discovered
or active output name. No specific HDMI device name or UID is embedded.

## Public identity and coexistence

- Visible name and session support directory: `FOI Surround Monitor`.
- Bundle identifier and settings suite: `studio.foi.surroundmonitor`.
- Bundle executable: `FOISurroundMonitor`.
- Sessions: `~/Library/Application Support/FOI Surround Monitor/Sessions`.
- A shared per-user application lock prevents competing monitor instances from
  controlling the same hardware.

The new app identity does not imply inherited macOS input authorization. Opening
the app and pressing Start only inspect authorization. Only the distinct
**Request input access…** action can request permission, and its response never
automatically starts audio. No TCC records or permission settings are changed by
the build or tests.

The headless checks cover status/cleanup protocol, bounded telemetry, input and
output identities, output-discovery schema, trims, and metering. They do not
validate rendered layout, actual device selection, receiver decoding or native
audio restoration.

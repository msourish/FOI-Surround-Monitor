# FOI Surround Monitor

Created by Sourish Mukherjee (@msourish) with SOURX, our AI collaborator.

Hear your DaVinci Resolve mix on a home-theater system while the Fairlight timeline plays. FOI Surround Monitor takes six discrete PCM channels from BlackHole, encodes them live as **Dolby Digital 5.1 (AC-3), 48 kHz, 448 kb/s**, and sends the stream to a compatible HDMI output. Track faders, mutes and surround pans are audible through the processed Fairlight bus.

## What you need

- An Apple silicon Mac running macOS 13 or later. The source build uses `clang`, the macOS SDK and `/usr/bin/python3`. Install the current Command Line Tools for Xcode with `xcode-select --install` if needed. [Apple’s installation guide](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/)
- BlackHole **16ch**, the virtual device that passes the six channels from Fairlight to the monitor. With Homebrew, run `brew install --cask blackhole-16ch` and restart the Mac. Confirm **BlackHole 16ch** appears in Audio MIDI Setup. [BlackHole](https://existential.audio/blackhole/) · [Homebrew cask](https://formulae.brew.sh/cask/blackhole-16ch)
- FFmpeg with its AC-3 encoder. Homebrew users can install it with `brew install ffmpeg`. [FFmpeg](https://ffmpeg.org/download.html) · [Homebrew formula](https://formulae.brew.sh/formula/ffmpeg)
- An HDMI device with a single output stream offering 48 kHz encoded AC-3 to Core Audio, and a receiver or soundbar that decodes Dolby Digital. If you use an HDMI-to-optical extractor, it must pass that stream through to the optical input.

## Build and install

Once the prerequisites above are installed, open Terminal on your Apple silicon Mac and run:

```sh
git clone https://github.com/msourish/FOI-Surround-Monitor.git
cd FOI-Surround-Monitor
zsh build.sh && zsh install.sh
```

You can also [download the source ZIP](https://github.com/msourish/FOI-Surround-Monitor/archive/refs/heads/main.zip), unzip it, open Terminal in the extracted folder, and run the last line. The build script compiles and locally signs **build/FOI Surround Monitor.app** and runs software checks. The install script copies it to **~/Applications/FOI Surround Monitor.app**. Open that copy in Finder. For an update, quit the app and move the previous build and installed copy aside before rebuilding.

The build finds FFmpeg on your shell path or in the usual Homebrew locations. To choose another installation, run `zsh build.sh --ffmpeg /absolute/path/to/ffmpeg` before `zsh install.sh`. Keep that FFmpeg installation available because its copied executable can still depend on locally installed libraries.

## Route a Fairlight project

1. Note your usual Resolve output. In **Preferences → System → Video and Audio I/O**, select **BlackHole 16ch** as the output device. Set the project and BlackHole to **48 kHz**.
2. In Fairlight, set **Bus 1** to plain **5.1** with six channels. Route your tracks to it and use the surround panners or a correctly assigned 5.1 source. For six mono speaker files, put each on its own track in the order below, then link those tracks as plain **5.1** under **Fairlight → Link Group**.
3. Open **Fairlight → Patch Input/Output**. Choose **Bus Out** as the source and **Audio Outputs** as the destination. Patch each Bus 1 speaker to its matching BlackHole channel.

| Bus 1 | L | R | C | LFE | Ls | Rs |
|---|---:|---:|---:|---:|---:|---:|
| BlackHole channel | 1 | 2 | 3 | 4 | 5 | 6 |

Recheck this patch after switching Resolve’s output device. Resolve can assign **Control Room L/R** to outputs 1–2 and shift the bus to 3–8. Remove competing Control Room or direct-track patches from outputs 1–6 before patching Bus Out. Bus Out follows the mix faders and bypasses Resolve’s monitor volume and mute, so begin with the receiver volume low.

## Listen and check all six channels

1. Open **FOI Surround Monitor**. On first use, choose **Request input access…** and approve macOS **Microphone** access. The app opens the BlackHole virtual input. You can review the permission in **System Settings → Privacy & Security → Microphone**.
2. In the gear menu, open **Output** and choose the HDMI device connected to your decoder. A sole compatible device can be selected automatically. Press **Start**, then play the Resolve timeline. Select the receiver’s matching input. On the tested Sony HT-S20R, use optical and turn **Multi Speaker OFF**.
3. Play a 5.1 channel-identification cue at low volume, or send a separate quiet cue to each bus channel in the table. Listen for front left, front right, center, a low LFE tone, left surround and right surround in turn. Watch the matching meter for each cue. On the Sony, **Menu → Current Status → Stream Information** should show **DOLBY DIGITAL**. That confirms the receiver is decoding the stream. Hearing each cue in its intended position confirms the mapping. [Sony HT-S20R operating instructions](https://www.sony.com/electronics/support/res/manuals/5010/86e668486c91d9f31ddef04cdbb4258e/50107271M.pdf)
4. Stop timeline playback, click **Stop**, and wait for HDMI restoration before opening another encoded player. Closing the monitor also requests cleanup. To return to your normal Resolve setup, reselect your usual output in Resolve preferences.

**Meters** and **Room** show the same six post-trim peaks. The knobs adjust monitor playback from **−60 to +6 dB**, with a separate **Mute** position. Every session starts at **0 dB**. Double-click a knob to return to unity, or focus it and press **M** to toggle mute. If a red clip indicator lights, reduce that channel’s level and clear the indicator from the gear menu.

If the HDMI device is missing, check the connection and use **Output → Refresh outputs**. If the device is occupied, stop the other player, refresh, then press **Start**. The gear menu’s **Show session logs…** opens the diagnostic information for that session.

## Tested route and format

During development, a Mac mini M4 sent the live stream over **LT1080P HDMI → extractor → optical → Sony HT-S20R**. The Sony reported Dolby Digital and the listener confirmed all six speaker assignments with Multi Speaker off. A separate decode of the stream confirmed all 13 opening cues on their intended channels.

This release monitors a **discrete 5.1 mix**. A stereo source stays in the channels you feed it. Atmos object rendering, height-channel folding and stereo upmixing are outside its format support. HDMI compatibility depends on the encoded formats the device advertises to macOS.

#!/bin/zsh
set -eu

project_root=${0:A:h}
if [[ $(/usr/bin/uname -s) != Darwin || $(/usr/bin/uname -m) != arm64 ]]; then
  print -u2 'This source build currently supports native Apple silicon macOS only.'
  exit 1
fi
if [[ ! -x /usr/bin/python3 ]]; then
  print -u2 'Python 3 is required. Install the Xcode Command Line Tools first.'
  exit 1
fi
compiler=$(/usr/bin/xcrun --find clang)
sdk_root=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
build_root="$project_root/build"
mkdir -p "$build_root/bin" "$build_root/module-cache"
common=(-isysroot "$sdk_root" -arch arm64 -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0)

"$compiler" "${common[@]}" -std=c11 \
  -framework CoreAudio -framework CoreFoundation -framework AudioUnit \
  "$project_root/Backend/auhal_input_continuous.c" \
  -o "$build_root/bin/auhal_input_continuous"
"$compiler" "${common[@]}" -std=c11 \
  -framework CoreAudio -framework CoreFoundation \
  "$project_root/Backend/coreaudio_ac3_monitor_sink.c" \
  -o "$build_root/bin/coreaudio_ac3_monitor_sink"
"$compiler" "${common[@]}" -fobjc-arc -fmodules \
  -fmodules-cache-path="$build_root/module-cache" \
  -framework Cocoa -framework AVFoundation -framework QuartzCore \
  "$project_root/UI/FOISurroundMonitor.m" \
  "$project_root/UI/FMInputMeterView.m" \
  "$project_root/UI/FMChannelTrimView.m" \
  -o "$build_root/bin/FOISurroundMonitor"

# These entry points use synthetic memory buffers and never open audio devices.
"$build_root/bin/auhal_input_continuous" --self-test
"$build_root/bin/coreaudio_ac3_monitor_sink" --self-test
"$build_root/bin/FOISurroundMonitor" --self-test
/usr/bin/python3 -B "$project_root/package_app.py" "$@"

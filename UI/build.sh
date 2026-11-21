#!/bin/zsh
set -eu
ui_root=${0:A:h}
mkdir -p "$ui_root/build"
/usr/bin/clang -fobjc-arc -fmodules -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
  -fmodules-cache-path="$ui_root/build/module-cache" \
  -framework Cocoa -framework AVFoundation -framework QuartzCore \
  "$ui_root/FOISurroundMonitor.m" "$ui_root/FMInputMeterView.m" "$ui_root/FMChannelTrimView.m" \
  -o "$ui_root/build/FOISurroundMonitor"
"$ui_root/build/FOISurroundMonitor" --self-test
